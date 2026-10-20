#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARVIS_CLI="${HARVIS_CLI:-$PLUGIN_ROOT/target/release/harvis}"
if [[ ! -x "$HARVIS_CLI" ]]; then
  HARVIS_CLI="$PLUGIN_ROOT/scripts/harvis"
fi

ROOT="${HARVIS_HANDOFF_RUNNER_SMOKE_ROOT:-}"
KEEP_ROOT="${HARVIS_HANDOFF_RUNNER_SMOKE_KEEP_ROOT:-0}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(mktemp -d /tmp/harvis-handoff-runner-smoke.XXXXXX)"
fi

mkdir -p "$ROOT"
"$HARVIS_CLI" init-workspace --root "$ROOT" >/dev/null

cat >"$ROOT/.harvis/inbox.md" <<'EOF'
@harvis Smoke-test a successful approved handoff runner path.
Scope: temporary H.A.R.V.I.S. runner smoke workspace.
Need: dry-run only; no source edits.
EOF

"$HARVIS_CLI" scan-inbox --root "$ROOT" >/dev/null
"$HARVIS_CLI" sync-runs --root "$ROOT" >"$ROOT/sync-runs.json"

read -r PACKET_ID RUN_ID < <(python3 - "$ROOT/sync-runs.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
runs = payload.get("runs") or []
if not runs:
    raise SystemExit("sync-runs produced no runs")
run = runs[0]
print(run["packet_id"], run["run_id"])
PY
)

"$HARVIS_CLI" agent-room --root "$ROOT" task create \
  --title "Smoke approved runner auto-review" \
  --owner-slot-id planner \
  --status waiting_approval \
  --packet-id "$PACKET_ID" \
  --run-id "$RUN_ID" \
  --description "Runner smoke task." >"$ROOT/task-created.json"

TASK_ID="$(python3 - "$ROOT/task-created.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])
PY
)"

"$HARVIS_CLI" agent-room --root "$ROOT" handoff \
  --run-id "$RUN_ID" \
  --harness codex \
  --instruction "Dry-run successful handoff runner smoke." \
  --topic-id gwt-workbench \
  --requested-by harvis-handoff-runner-smoke >"$ROOT/handoff-created.json"

HANDOFF_ID="$(python3 - "$ROOT/handoff-created.json" <<'PY'
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
  --note "Runner smoke linked task to handoff." >/dev/null

HARVIS_CLI="$HARVIS_CLI" "$PLUGIN_ROOT/scripts/harvis-handoff-run.sh" \
  --root "$ROOT" \
  --handoff-id "$HANDOFF_ID" \
  --dry-run \
  --auto-review-dry-run \
  --runner-id harvis-handoff-runner-smoke >"$ROOT/runner-exec-dir.txt"

"$HARVIS_CLI" agent-room --root "$ROOT" task list --limit 20 >"$ROOT/tasks-after.json"
"$HARVIS_CLI" agent-room --root "$ROOT" handoffs --limit 20 >"$ROOT/handoffs-after.json"
"$HARVIS_CLI" memory-candidates --root "$ROOT" --limit 20 >"$ROOT/memory-candidates.json"

python3 - "$ROOT" "$TASK_ID" "$HANDOFF_ID" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
task_id = sys.argv[2]
handoff_id = sys.argv[3]
tasks = json.loads((root / "tasks-after.json").read_text(encoding="utf-8")).get("tasks", [])
handoffs = json.loads((root / "handoffs-after.json").read_text(encoding="utf-8")).get("handoffs", [])
candidates = json.loads((root / "memory-candidates.json").read_text(encoding="utf-8")).get("candidates", [])

task = next((item for item in tasks if item.get("task_id") == task_id), None)
handoff = next((item for item in handoffs if item.get("handoff_id") == handoff_id), None)
failures = []
if not task:
    failures.append("task missing after runner")
elif task.get("status") != "done":
    failures.append(f"expected task done, got {task.get('status')}")
if not handoff:
    failures.append("handoff missing after runner")
elif handoff.get("state") != "done":
    failures.append(f"expected handoff done, got {handoff.get('state')}")
if not any(item.get("source_id") == handoff_id for item in candidates):
    failures.append("missing handoff memory candidate")
if not any(item.get("source_id") == task_id for item in candidates):
    failures.append("missing task memory candidate")

summary = {
    "ok": not failures,
    "root": str(root),
    "task_id": task_id,
    "task_status": task.get("status") if task else None,
    "handoff_id": handoff_id,
    "handoff_state": handoff.get("state") if handoff else None,
    "memory_candidate_count": len(candidates),
    "failures": failures,
}
print(json.dumps(summary, ensure_ascii=False, indent=2))
if failures:
    raise SystemExit(1)
PY

if [[ "$KEEP_ROOT" != "1" ]]; then
  rm -rf "$ROOT"
fi
