#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARVIS_CLI="${HARVIS_CLI:-$PLUGIN_ROOT/target/release/harvis}"
if [[ ! -x "$HARVIS_CLI" ]]; then
  HARVIS_CLI="$PLUGIN_ROOT/scripts/harvis"
fi

ROOT="${HARVIS_HANDOFF_ADAPTERS_SMOKE_ROOT:-}"
KEEP_ROOT="${HARVIS_HANDOFF_ADAPTERS_SMOKE_KEEP_ROOT:-0}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(mktemp -d /tmp/harvis-handoff-adapters-smoke.XXXXXX)"
fi

mkdir -p "$ROOT"
"$HARVIS_CLI" init-workspace --root "$ROOT" >/dev/null

create_run() {
  local label="$1"
  cat >"$ROOT/.harvis/inbox.md" <<EOF
@harvis Smoke-test $label handoff adapter contract.
Scope: temporary H.A.R.V.I.S. adapter smoke workspace.
Need: dry-run only; no source edits.
EOF
  "$HARVIS_CLI" scan-inbox --root "$ROOT" >/dev/null
  local packet_path
  packet_path="$(find "$ROOT/.harvis/outbox" -type f -name '*.md' -print0 | xargs -0 ls -t | head -1)"
  "$HARVIS_CLI" sync-runs --root "$ROOT" --packet "$packet_path" >"$ROOT/sync-runs-$label.json"
  python3 - "$ROOT/sync-runs-$label.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
runs = payload.get("runs") or []
if not runs:
    raise SystemExit("sync-runs produced no runs")
run = runs[0]
print(run["packet_id"], run["run_id"])
PY
}

create_handoff() {
  local harness="$1"
  local packet_id="$2"
  local run_id="$3"
  "$HARVIS_CLI" agent-room --root "$ROOT" task create \
    --title "Smoke $harness adapter" \
    --owner-slot-id executor \
    --status waiting_approval \
    --packet-id "$packet_id" \
    --run-id "$run_id" \
    --description "Adapter smoke task for $harness." >"$ROOT/task-$harness.json"
  local task_id
  task_id="$(python3 - "$ROOT/task-$harness.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])
PY
)"
  "$HARVIS_CLI" agent-room --root "$ROOT" handoff \
    --run-id "$run_id" \
    --harness "$harness" \
    --instruction "Dry-run $harness adapter contract smoke." \
    --topic-id gwt-workbench \
    --requested-by harvis-handoff-adapters-smoke >"$ROOT/handoff-$harness.json"
  local handoff_id
  handoff_id="$(python3 - "$ROOT/handoff-$harness.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["handoff"]["handoff_id"])
PY
)"
  "$HARVIS_CLI" agent-room --root "$ROOT" task link \
    --task-id "$task_id" \
    --handoff-id "$handoff_id" \
    --run-id "$run_id" \
    --packet-id "$packet_id" \
    --status in_progress \
    --note "Adapter smoke linked task to $harness handoff." >/dev/null
  printf '%s %s\n' "$task_id" "$handoff_id"
}

for harness in dsh codex kimicode claude-code likecode; do
  read -r packet_id run_id < <(create_run "$harness")
  read -r task_id handoff_id < <(create_handoff "$harness" "$packet_id" "$run_id")
  HARVIS_CLI="$HARVIS_CLI" "$PLUGIN_ROOT/scripts/harvis-handoff-run.sh" \
    --root "$ROOT" \
    --handoff-id "$handoff_id" \
    --dry-run \
    --auto-review-dry-run \
    --runner-id "harvis-handoff-adapters-smoke:$harness" >"$ROOT/runner-$harness.txt"
done

# Experimental live adapters must block by default unless explicitly enabled.
# DSH is covered above as a first-class dry-run route and by its dedicated
# synthetic/live adapter smoke gates.
read -r packet_id run_id < <(create_run "kimicode-live-blocked")
read -r task_id handoff_id < <(create_handoff "kimicode" "$packet_id" "$run_id")
set +e
HARVIS_CLI="$HARVIS_CLI" "$PLUGIN_ROOT/scripts/harvis-handoff-run.sh" \
  --root "$ROOT" \
  --handoff-id "$handoff_id" \
  --runner-id "harvis-handoff-adapters-smoke:kimicode-live-blocked" >"$ROOT/runner-kimicode-live-blocked.txt" 2>"$ROOT/runner-kimicode-live-blocked.err"
blocked_code=$?
set -e

"$HARVIS_CLI" agent-room --root "$ROOT" task list --limit 100 >"$ROOT/tasks-after.json"
"$HARVIS_CLI" agent-room --root "$ROOT" handoffs --limit 100 >"$ROOT/handoffs-after.json"
"$HARVIS_CLI" memory-candidates --root "$ROOT" --limit 100 >"$ROOT/memory-candidates.json"

python3 - "$ROOT" "$blocked_code" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
blocked_code = int(sys.argv[2])
tasks = json.loads((root / "tasks-after.json").read_text(encoding="utf-8")).get("tasks", [])
handoffs = json.loads((root / "handoffs-after.json").read_text(encoding="utf-8")).get("handoffs", [])
candidates = json.loads((root / "memory-candidates.json").read_text(encoding="utf-8")).get("candidates", [])
failures = []

dry_harnesses = {"dsh", "codex", "kimicode", "claude-code", "likecode"}
for harness in dry_harnesses:
    matching = [item for item in handoffs if item.get("harness") == harness and item.get("state") == "done"]
    if not matching:
        failures.append(f"missing done dry-run handoff for {harness}")
    for handoff in matching:
        hid = handoff.get("handoff_id")
        execs = list((root / ".harvis" / "executions").glob(f"{handoff.get('run_id')}-*-handoff/adapter.json"))
        if not execs:
            failures.append(f"missing adapter contract for {hid}")

blocked = [
    item
    for item in handoffs
    if item.get("harness") == "kimicode" and item.get("state") == "blocked"
]
if blocked_code != 78:
    failures.append(f"expected blocked live kimicode exit 78, got {blocked_code}")
if not blocked:
    failures.append("missing blocked live kimicode handoff")
if len(candidates) < 8:
    failures.append(f"expected memory candidates for task/handoff dry-runs, got {len(candidates)}")

summary = {
    "ok": not failures,
    "root": str(root),
    "dry_run_harnesses": sorted(dry_harnesses),
    "handoff_count": len(handoffs),
    "task_count": len(tasks),
    "memory_candidate_count": len(candidates),
    "blocked_live_kimicode_exit": blocked_code,
    "failures": failures,
}
print(json.dumps(summary, ensure_ascii=False, indent=2))
if failures:
    raise SystemExit(1)
PY

if [[ "$KEEP_ROOT" != "1" ]]; then
  rm -rf "$ROOT"
fi
