#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARVIS_CLI="${HARVIS_CLI:-$PLUGIN_ROOT/target/release/harvis}"
if [[ ! -x "$HARVIS_CLI" ]]; then
  HARVIS_CLI="$PLUGIN_ROOT/scripts/harvis"
fi

ROOT="${HARVIS_AGENT_GATEWAY_SMOKE_ROOT:-}"
KEEP_ROOT="${HARVIS_AGENT_GATEWAY_SMOKE_KEEP_ROOT:-0}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(mktemp -d /tmp/harvis-agent-gateway-smoke.XXXXXX)"
fi

run_step() {
  local channel="$1"
  local message_id="$2"
  local message="$3"
  "$HARVIS_CLI" agent step \
    --root "$ROOT" \
    --channel "$channel" \
    --sender "smoke:$channel" \
    --chat-id "smoke:$channel" \
    --message-id "$message_id" \
    --message "$message" >"$ROOT/$channel.json"
}

mkdir -p "$ROOT"
run_step feishu feishu-smoke-1 "任务：找到 just-ddl 仓库并检查失败原因，不要执行"
run_step wechat wechat-smoke-1 "task just-ddl readonly"
run_step webview webview-smoke-1 "查 just-ddl 最近失败"
run_step status status-smoke-1 "现在到哪一步了"
cp "$ROOT/status.json" "$ROOT/status-before-runner.json"

"$HARVIS_CLI" agent-room --root "$ROOT" task list --limit 20 >"$ROOT/tasks.json"
"$HARVIS_CLI" chair --root "$ROOT" step --dry-run true >"$ROOT/chair.json"

eval "$(python3 - "$ROOT/tasks.json" <<'PY'
import json
import shlex
import sys

tasks = json.load(open(sys.argv[1], encoding="utf-8")).get("tasks", [])
feishu = next((task for task in tasks if task.get("metadata", {}).get("transport") == "feishu"), tasks[0])
for key in ("task_id", "run_id", "packet_id"):
    print(f"{key.upper()}={shlex.quote(str(feishu.get(key) or ''))}")
PY
)"

"$HARVIS_CLI" agent-room --root "$ROOT" handoff \
  --run-id "$RUN_ID" \
  --harness codex \
  --instruction "Smoke approved execution for packet $PACKET_ID" \
  --topic-id gwt-workbench \
  --requested-by agent-gateway-smoke >"$ROOT/handoff.json"

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
  --note "Agent Gateway smoke linked approval to generic handoff runner." >/dev/null

HARVIS_CLI="$HARVIS_CLI" "$PLUGIN_ROOT/scripts/harvis-handoff-run.sh" \
  --root "$ROOT" \
  --handoff-id "$HANDOFF_ID" \
  --dry-run \
  --runner-id agent-gateway-smoke >"$ROOT/handoff-runner.txt"

"$HARVIS_CLI" agent-room --root "$ROOT" task list --limit 20 >"$ROOT/tasks-after-runner.json"
"$HARVIS_CLI" agent-room --root "$ROOT" handoffs --limit 20 >"$ROOT/handoffs-after-runner.json"
run_step status status-smoke-2 "现在到哪一步了"
mv "$ROOT/status.json" "$ROOT/status-after-runner.json"

"$HARVIS_CLI" agent-room --root "$ROOT" handoff-review \
  --handoff-id "$HANDOFF_ID" \
  --decision approve \
  --reviewer reviewer-smoke \
  --notes "Smoke reviewer accepted the dry-run harness result." >"$ROOT/reviewer-accept.json"

"$HARVIS_CLI" agent-room --root "$ROOT" task list --limit 20 >"$ROOT/tasks-after-review.json"
"$HARVIS_CLI" agent-room --root "$ROOT" handoffs --limit 20 >"$ROOT/handoffs-after-review.json"
"$HARVIS_CLI" memory-candidates --root "$ROOT" --limit 20 >"$ROOT/memory-candidates.json"
run_step status status-smoke-3 "现在到哪一步了"
mv "$ROOT/status.json" "$ROOT/status-after-review.json"

python3 - "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
channels = ("feishu", "wechat", "webview")
steps = {name: json.loads((root / f"{name}.json").read_text(encoding="utf-8")) for name in channels}
status = json.loads((root / "status-before-runner.json").read_text(encoding="utf-8"))
tasks = json.loads((root / "tasks.json").read_text(encoding="utf-8")).get("tasks", [])
tasks_after = json.loads((root / "tasks-after-runner.json").read_text(encoding="utf-8")).get("tasks", [])
handoffs_after = json.loads((root / "handoffs-after-runner.json").read_text(encoding="utf-8")).get("handoffs", [])
chair = json.loads((root / "chair.json").read_text(encoding="utf-8"))
handoff = json.loads((root / "handoff.json").read_text(encoding="utf-8")).get("handoff", {})
status_after = json.loads((root / "status-after-runner.json").read_text(encoding="utf-8"))
review_accept = json.loads((root / "reviewer-accept.json").read_text(encoding="utf-8"))
tasks_after_review = json.loads((root / "tasks-after-review.json").read_text(encoding="utf-8")).get("tasks", [])
handoffs_after_review = json.loads((root / "handoffs-after-review.json").read_text(encoding="utf-8")).get("handoffs", [])
memory_candidates = json.loads((root / "memory-candidates.json").read_text(encoding="utf-8")).get("candidates", [])
status_after_review = json.loads((root / "status-after-review.json").read_text(encoding="utf-8"))

failures = []
for name, payload in steps.items():
    if payload.get("intent") != "task_enqueue":
        failures.append(f"{name}: expected task_enqueue, got {payload.get('intent')}")
    if payload.get("next_expected_action") not in {"request_approval", "delegate_task"}:
        failures.append(f"{name}: unexpected next action {payload.get('next_expected_action')}")

if len(tasks) != 3:
    failures.append(f"expected 3 tasks, got {len(tasks)}")

transports = {task.get("metadata", {}).get("transport") for task in tasks}
if transports != {"feishu", "wechat", "webview"}:
    failures.append(f"unexpected task transports {sorted(transports)}")

statuses = {task.get("status") for task in tasks}
if statuses != {"waiting_approval"}:
    failures.append(f"unexpected task statuses {sorted(statuses)}")

chair_action = (
    chair.get("proposed_move", {}).get("action")
    or chair.get("action")
    or chair.get("move")
)
if chair_action not in {"request_approval", "delegate_task"}:
    failures.append(f"unexpected chair action {chair_action}")

status_text = status.get("response_text") or ""
if "H.A.R.V.I.S. 当前进展" not in status_text and "当前进展" not in status_text:
    failures.append("status query did not return progress text")

handoff_id = handoff.get("handoff_id")
if not handoff_id:
    failures.append("handoff was not created")

matching_after = [task for task in tasks_after if task.get("handoff_id") == handoff_id]
if not matching_after:
    failures.append("linked task not found after handoff runner")
else:
    runner_status = matching_after[-1].get("status")
    if runner_status != "reviewing":
        failures.append(f"expected linked task to be reviewing after dry-run runner, got {runner_status}")

matching_handoffs = [item for item in handoffs_after if item.get("handoff_id") == handoff_id]
if not matching_handoffs:
    failures.append("handoff not listed after runner")
else:
    handoff_state = matching_handoffs[-1].get("state")
    if handoff_state != "reviewing":
        failures.append(f"expected handoff reviewing after dry-run runner, got {handoff_state}")

status_after_text = status_after.get("response_text") or ""
if "reviewing" not in status_after_text and "最近执行" not in status_after_text:
    failures.append("post-runner status query did not mention review/execution state")

reviewed_task = [task for task in tasks_after_review if task.get("handoff_id") == handoff_id]
if not reviewed_task:
    failures.append("linked task not found after reviewer acceptance")
else:
    reviewed_status = reviewed_task[-1].get("status")
    if reviewed_status != "done":
        failures.append(f"expected linked task to be done after reviewer acceptance, got {reviewed_status}")

reviewed_handoff = [item for item in handoffs_after_review if item.get("handoff_id") == handoff_id]
if not reviewed_handoff:
    failures.append("handoff not listed after reviewer acceptance")
else:
    reviewed_handoff_state = reviewed_handoff[-1].get("state")
    if reviewed_handoff_state != "done":
        failures.append(f"expected handoff done after reviewer acceptance, got {reviewed_handoff_state}")

if review_accept.get("safety", {}).get("memory_candidate_only") is not True:
    failures.append("review acceptance did not report memory_candidate_only safety")

if not any(candidate.get("source_id") == handoff_id for candidate in memory_candidates):
    failures.append("memory candidates did not include accepted handoff result")

if not any(candidate.get("source_id") == reviewed_task[-1].get("task_id") for candidate in memory_candidates) if reviewed_task else True:
    failures.append("memory candidates did not include done task result")

status_after_review_text = status_after_review.get("response_text") or ""
if "最近执行" not in status_after_review_text and "done" not in status_after_review_text:
    failures.append("post-review status query did not mention completion/execution state")

summary = {
    "ok": not failures,
    "root": str(root),
    "step_intents": {name: steps[name].get("intent") for name in channels},
    "step_next": {name: steps[name].get("next_expected_action") for name in channels},
    "task_count": len(tasks),
    "task_transports": sorted(transports),
    "task_statuses": sorted(statuses),
    "chair_action": chair_action,
    "handoff_id": handoff_id,
    "post_runner_task_statuses": sorted({task.get("status") for task in tasks_after}),
    "post_review_task_statuses": sorted({task.get("status") for task in tasks_after_review}),
    "post_review_handoff_states": sorted({item.get("state") for item in handoffs_after_review}),
    "memory_candidate_count": len(memory_candidates),
    "status_excerpt": status_text[:500],
    "post_runner_status_excerpt": status_after_text[:500],
    "post_review_status_excerpt": status_after_review_text[:500],
    "failures": failures,
}
print(json.dumps(summary, ensure_ascii=False, indent=2))
if failures:
    raise SystemExit(1)
PY

if [[ "$KEEP_ROOT" != "1" ]]; then
  rm -rf "$ROOT"
fi
