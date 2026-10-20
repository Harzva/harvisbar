#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARVIS_CLI="${HARVIS_CLI:-$PLUGIN_ROOT/target/release/harvis}"
if [[ ! -x "$HARVIS_CLI" ]]; then
  HARVIS_CLI="$PLUGIN_ROOT/scripts/harvis"
fi

ROOT="${HARVIS_HANDOFF_FAILURE_SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/harvis-handoff-failure.XXXXXX")}"
KEEP_ROOT="${HARVIS_HANDOFF_FAILURE_SMOKE_KEEP_ROOT:-0}"
FAKE_CODEX="$ROOT/fake-codex"
PACKET_ID="failure_smoke_001"
PACKET_PATH="$ROOT/.harvis/outbox/$PACKET_ID.md"
RUN_ID="run_$PACKET_ID"

mkdir -p "$ROOT/.harvis/outbox"
cat >"$PACKET_PATH" <<'EOF'
Generated: 2026-06-29T00:00:00Z
Source: handoff-failure-smoke
Status: pending
Safety: local smoke only

# Failure Smoke Packet

This packet intentionally uses a fake Codex binary that emits JSONL events and exits non-zero.
EOF

cat >"$FAKE_CODEX" <<'EOF'
#!/usr/bin/env python3
import json
import sys

for event in [
    {"type": "thread.started", "thread_id": "019f2222-2222-7222-8222-222222222222"},
    {"type": "item.started", "item": {"id": "item_failure_smoke"}},
    {"type": "turn.failed", "message": "simulated codex failure smoke"},
]:
    print(json.dumps(event), flush=True)
print("simulated codex stderr failure detail", file=sys.stderr, flush=True)
sys.exit(42)
EOF
chmod +x "$FAKE_CODEX"

"$HARVIS_CLI" sync-runs --root "$ROOT" --packet "$PACKET_PATH" >"$ROOT/sync-runs.json"
"$HARVIS_CLI" agent-room --root "$ROOT" task create \
  --title "Handoff runner failure smoke" \
  --status in_progress \
  --run-id "$RUN_ID" \
  --packet-id "$PACKET_ID" >"$ROOT/task.json"
"$HARVIS_CLI" agent-room --root "$ROOT" handoff \
  --run-id "$RUN_ID" \
  --harness codex \
  --instruction "Run fake Codex and verify failure feedback is explicit." \
  --topic-id gwt-workbench \
  --requested-by handoff-failure-smoke >"$ROOT/handoff.json"

TASK_ID="$(python3 - "$ROOT/task.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])
PY
)"
HANDOFF_ID="$(python3 - "$ROOT/handoff.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["handoff"]["handoff_id"])
PY
)"

"$HARVIS_CLI" agent-room --root "$ROOT" task link \
  --task-id "$TASK_ID" \
  --handoff-id "$HANDOFF_ID" \
  --run-id "$RUN_ID" \
  --packet-id "$PACKET_ID" \
  --status in_progress \
  --note "Failure smoke linked task to handoff." >/dev/null

set +e
CODEX_CLI="$FAKE_CODEX" HARVIS_CLI="$HARVIS_CLI" HARVIS_CODEX_MODEL=gpt-5.5 \
  "$PLUGIN_ROOT/scripts/harvis-handoff-run.sh" \
  --root "$ROOT" \
  --handoff-id "$HANDOFF_ID" \
  --runner-id handoff-failure-smoke \
  --timeout-seconds 15 >"$ROOT/runner.out" 2>"$ROOT/runner.err"
RUNNER_EXIT=$?
set -e

"$HARVIS_CLI" agent-room --root "$ROOT" handoffs --limit 20 >"$ROOT/handoffs-after.json"

python3 - "$ROOT" "$RUNNER_EXIT" "$HANDOFF_ID" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
runner_exit = int(sys.argv[2])
handoff_id = sys.argv[3]
exec_dir = Path((root / "runner.out").read_text(encoding="utf-8").splitlines()[-1])
status = json.loads((exec_dir / "status.json").read_text(encoding="utf-8"))
final = (exec_dir / "final.md").read_text(encoding="utf-8")
events = [
    json.loads(line)
    for line in (root / ".harvis/runs/run_failure_smoke_001/events.jsonl").read_text(encoding="utf-8").splitlines()
    if line.strip()
]
handoffs = json.loads((root / "handoffs-after.json").read_text(encoding="utf-8")).get("handoffs", [])
handoff = next(item for item in handoffs if item.get("handoff_id") == handoff_id)

failures = []
if runner_exit != 42:
    failures.append(f"expected runner exit 42, got {runner_exit}")
if status.get("status") != "blocked":
    failures.append(f"expected blocked status, got {status.get('status')}")
if status.get("exit_code") != 42:
    failures.append(f"expected status exit_code 42, got {status.get('exit_code')}")
if "Codex JSONL adapter exited with code 42" not in status.get("runner_summary", ""):
    failures.append("status runner_summary missing explicit adapter exit")
if "exit_code: 42" not in final or "Reason:" not in final:
    failures.append("final.md missing explicit failure detail")
if "unknown" in final.lower():
    failures.append("final.md still contains unknown")
if not any(event.get("codex_event_type") == "adapter.failed" and event.get("exit_code") == 42 for event in events):
    failures.append("events.jsonl missing adapter.failed exit_code=42")
if handoff.get("state") != "blocked":
    failures.append(f"expected handoff blocked, got {handoff.get('state')}")
if "Codex JSONL adapter exited with code 42" not in str(handoff.get("summary") or ""):
    failures.append("handoff summary missing explicit adapter exit")

summary = {
    "ok": not failures,
    "root": str(root),
    "exec_dir": str(exec_dir),
    "runner_exit": runner_exit,
    "handoff_id": handoff_id,
    "runner_summary": status.get("runner_summary"),
    "last_event_type": status.get("last_event_type"),
    "failures": failures,
}
print(json.dumps(summary, ensure_ascii=False, indent=2))
if failures:
    raise SystemExit(1)
PY

if [[ "$KEEP_ROOT" != "1" ]]; then
  rm -rf "$ROOT"
fi
