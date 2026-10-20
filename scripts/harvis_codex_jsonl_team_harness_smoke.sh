#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${HARVIS_SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/harvis-jsonl-team.XXXXXX")}"
FAKE_CODEX="$ROOT/fake-codex"
FAKE_LARK="$ROOT/fake-lark-cli"
PROGRESS_LOG="$ROOT/lark-progress.jsonl"
PROMPT="$ROOT/prompt.md"
export HARVIS_MOBILE_BASE_URL="https://harvis.example.test/base"

mkdir -p "$ROOT/.harvis/agent-room" "$ROOT/.harvis/approvals"
cat >"$PROMPT" <<'EOF'
Say a concise H.A.R.V.I.S. JSONL smoke result.
EOF

cat >"$ROOT/.harvis/agent-room/tasks.jsonl" <<'EOF'
{"task_id":"task_smoke_001","packet_id":"packet_smoke_001","run_id":"run_smoke_001","handoff_id":"handoff_smoke_001","metadata":{"packet_ids":["packet_smoke_resume"],"run_ids":["run_smoke_resume"]}}
EOF

cat >"$FAKE_CODEX" <<'EOF'
#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
resume_thread = ""
if "resume" in args:
    idx = args.index("resume")
    for value in args[idx + 1:]:
        if value and not value.startswith("-") and value != "resume":
            resume_thread = value
            break
thread = resume_thread or "019f1111-1111-7111-8111-111111111111"
events = [
    {"type": "thread.started", "thread_id": thread},
    {"type": "item.started", "item": {"id": "item_1"}},
    {"type": "agent_message", "message": "fallback final from agent message"},
    {"type": "item.started", "item": {"id": "cmd_1", "type": "command_execution", "command": "/bin/echo smoke-command", "aggregated_output": "", "exit_code": None, "status": "in_progress"}},
    {"type": "item.completed", "item": {"id": "cmd_1", "type": "command_execution", "command": "/bin/echo smoke-command", "aggregated_output": "smoke-output\n", "exit_code": 0, "status": "completed"}},
    {"type": "item.completed", "item": {"output": "command_execution completed"}},
]
if "--fake-fail" in args or __import__("os").environ.get("FAKE_CODEX_FAIL") == "1":
    events.append({"type": "turn.failed", "message": "simulated failure"})
    code = 42
else:
    events.append({"type": "turn.completed", "usage": {"input_tokens": 1}})
    code = 0
for event in events:
    print(json.dumps(event), flush=True)
sys.exit(code)
EOF
chmod +x "$FAKE_CODEX"

cat >"$FAKE_LARK" <<'EOF'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
text = ""
content = ""
data = ""
message_id = ""
chat_id = ""
for index, value in enumerate(args):
    if value == "--text" and index + 1 < len(args):
        text = args[index + 1]
    if value == "--content" and index + 1 < len(args):
        content = args[index + 1]
    if value == "--data" and index + 1 < len(args):
        data = args[index + 1]
    if value == "--message-id" and index + 1 < len(args):
        message_id = args[index + 1]
    if value == "--chat-id" and index + 1 < len(args):
        chat_id = args[index + 1]

def card_text(card):
    bits = []
    if isinstance(card, dict):
        header = card.get("header") or {}
        title = header.get("title") or {}
        if isinstance(title, dict):
            bits.append(str(title.get("content") or ""))
        for element in card.get("elements") or []:
            if not isinstance(element, dict):
                continue
            text_obj = element.get("text")
            if isinstance(text_obj, dict):
                bits.append(str(text_obj.get("content") or ""))
            for action in element.get("actions") or []:
                if not isinstance(action, dict):
                    continue
                action_text = action.get("text")
                if isinstance(action_text, dict):
                    bits.append(str(action_text.get("content") or ""))
                if action.get("url"):
                    bits.append(str(action.get("url")))
    return "\n".join(bit for bit in bits if bit)

card = None
if content:
    try:
        card = json.loads(content)
        text = card_text(card)
    except Exception:
        pass
if data:
    try:
        body = json.loads(data)
        body_content = body.get("content")
        if isinstance(body_content, str):
            card = json.loads(body_content)
            text = card_text(card)
    except Exception:
        pass
record = {
    "args": args,
    "text": text,
    "content": content,
    "data": data,
    "card": card,
    "message_id": message_id,
    "chat_id": chat_id,
}
with open(os.environ["HARVIS_FAKE_LARK_PROGRESS_LOG"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
if "api" in args:
    print(json.dumps({"ok": True, "data": {"message_id": message_id or "om_progress_smoke"}}))
else:
    print(json.dumps({"ok": True, "data": {"message_id": "om_progress_smoke"}}))
EOF
chmod +x "$FAKE_LARK"

run_adapter() {
  local run_id="$1"
  local packet_id="$2"
  local handoff_id="$3"
  local final_file="$ROOT/.harvis/runs/$run_id/final.md"
  local stdout_log="$ROOT/.harvis/runs/$run_id/stdout.jsonl"
  local stderr_log="$ROOT/.harvis/runs/$run_id/stderr.log"
  local events_jsonl="$ROOT/.harvis/runs/$run_id/events.jsonl"
  local thread_json="$ROOT/.harvis/runs/$run_id/codex-thread.json"
  local status_json="$ROOT/.harvis/runs/$run_id/status.json"
  shift 3
  local fake_fail=0
  local filtered=()
  for arg in "$@"; do
    if [[ "$arg" == "--fake-fail" ]]; then
      fake_fail=1
    else
      filtered+=("$arg")
    fi
  done
  set +e
  env FAKE_CODEX_FAIL="$fake_fail" HARVIS_FAKE_LARK_PROGRESS_LOG="$PROGRESS_LOG" "$PLUGIN_ROOT/scripts/harvis_codex_jsonl_adapter.py" \
    --codex "$FAKE_CODEX" \
    --root "$ROOT" \
    --prompt-file "$PROMPT" \
    --final-file "$final_file" \
    --stdout-log "$stdout_log" \
    --stderr-log "$stderr_log" \
    --events-jsonl "$events_jsonl" \
    --thread-json "$thread_json" \
    --status-json "$status_json" \
    --timeout-seconds 15 \
    --handoff-id "$handoff_id" \
    --run-id "$run_id" \
    --packet-id "$packet_id" \
    --model gpt-5.5 \
    --lark-cli "$FAKE_LARK" \
    --lark-chat-id chat_smoke \
    --lark-message-id msg_smoke \
    --lark-progress-events 1 \
    ${filtered[@]+"${filtered[@]}"}
  local code=$?
  set -e
  return "$code"
}

run_adapter run_smoke_001 packet_smoke_001 handoff_smoke_001
run_adapter run_smoke_resume_denied packet_smoke_resume_denied handoff_smoke_resume_denied \
  --resume-thread-id 019f1111-1111-7111-8111-111111111111 || true
cat >"$ROOT/.harvis/approvals/approval_smoke_resume_approved.json" <<'EOF'
{
  "approval_id": "approval_smoke_resume_approved",
  "status": "approved",
  "run_id": "run_smoke_resume",
  "action": {
    "type": "run_command",
    "target": {
      "kind": "relative_or_resource",
      "display": "codex exec resume 019f1111-1111-7111-8111-111111111111"
    },
    "reason": "Smoke approval for Codex resume."
  },
  "risk": "medium",
  "scope": "one_time"
}
EOF
run_adapter run_smoke_resume packet_smoke_resume handoff_smoke_resume \
  --resume-thread-id 019f1111-1111-7111-8111-111111111111 \
  --approval-id approval_smoke_resume_approved
run_adapter run_smoke_fail packet_smoke_fail handoff_smoke_fail --allow-unbound-resume \
  --resume-thread-id 019f1111-1111-7111-8111-111111111111 \
  --approval-id approval_smoke_resume_approved \
  --fake-fail || true

"$PLUGIN_ROOT/scripts/harvis_codex_thread_board.py" --root "$ROOT" latest --chat-id chat_smoke >/tmp/harvis-smoke-latest-chat.json
"$PLUGIN_ROOT/scripts/harvis_codex_thread_board.py" --root "$ROOT" latest --query run_smoke_001 >/tmp/harvis-smoke-latest-run.json
"$PLUGIN_ROOT/scripts/harvis_codex_thread_board.py" --root "$ROOT" pin --query run_smoke_001 --label "Smoke pinned Codex thread" >/tmp/harvis-smoke-pin.json
"$PLUGIN_ROOT/scripts/harvis_codex_thread_board.py" --root "$ROOT" pin --chat-id chat_smoke --label "Smoke pinned current conversation" >/tmp/harvis-smoke-pin-chat.json
"$PLUGIN_ROOT/scripts/harvis_codex_thread_board.py" --root "$ROOT" card --chat-id chat_smoke >/tmp/harvis-smoke-thread-card.json
HARVIS_MOBILE_BASE_URL="http://127.0.0.1:8765" "$PLUGIN_ROOT/scripts/harvis_codex_thread_board.py" --root "$ROOT" card --chat-id chat_smoke >/tmp/harvis-smoke-thread-card-localhost.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" bind --transport feishu --chat-id chat_smoke --message-id msg_smoke --sender-id user_smoke --task-id task_smoke_001 --run-id run_smoke_001 --handoff-id handoff_smoke_001 --codex-thread-id 019f1111-1111-7111-8111-111111111111 >/tmp/harvis-smoke-bind.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" bind --transport wechat --chat-id chat_smoke --message-id msg_wechat --sender-id user_smoke --task-id task_smoke_wechat --run-id run_smoke_wechat --handoff-id handoff_smoke_wechat --codex-thread-id 019f3333-3333-7333-8333-333333333333 >/tmp/harvis-smoke-bind-wechat.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" bind --transport webui --chat-id chat_smoke --message-id msg_webui --sender-id user_smoke --task-id task_smoke_webui --run-id run_smoke_webui --handoff-id handoff_smoke_webui --codex-thread-id 019f4444-4444-7444-8444-444444444444 >/tmp/harvis-smoke-bind-webui.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" resolve --transport feishu --chat-id chat_smoke >/tmp/harvis-smoke-resolve-chat.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" resolve --transport feishu --chat-id chat_smoke --query run_smoke_001 >/tmp/harvis-smoke-resolve-run.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" resolve --transport wechat --chat-id chat_smoke >/tmp/harvis-smoke-resolve-wechat.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" resolve --transport webui --chat-id chat_smoke >/tmp/harvis-smoke-resolve-webui.json
HARVIS_CONTROL_RUNTIME=harvis-conductor "$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" chair-dry-run --prompt "review this code with cxspark" --transport feishu --chat-id chat_smoke >/tmp/harvis-smoke-decision.json
HARVIS_CONTROL_RUNTIME=harvis-conductor "$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" chair-dry-run --prompt "可以打开浏览器的百度吗然后搜索 小狗" --transport feishu --chat-id chat_smoke >/tmp/harvis-smoke-decision-browser.json
HARVIS_CONTROL_RUNTIME=harvis-conductor "$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" chair-dry-run --prompt "https://mp.weixin.qq.com/s/kiHCMo_kqP0fj7zIkm9bQw" --transport feishu --chat-id chat_smoke >/tmp/harvis-smoke-decision-wechat-article.json
HARVIS_CONTROL_RUNTIME=harvis-conductor "$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" chair-dry-run --prompt "整理一个普通执行任务" --transport feishu --chat-id chat_smoke >/tmp/harvis-smoke-decision-default.json
HARVIS_CONTROL_RUNTIME=harvis-conductor "$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" chair-dry-run --prompt "删除这个仓库并 push" --transport feishu --chat-id chat_smoke >/tmp/harvis-smoke-decision-high-risk.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" chair-dry-run --prompt "整理一个普通执行任务" --transport feishu --chat-id chat_smoke --control-runtime codex-control >/tmp/harvis-smoke-decision-codex-control.json
"$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" tool --tool team_list_models >/tmp/harvis-smoke-models.json
for action in spawn_agent execute_command file_write browser_automation git_commit git_push publish delete memory_adopt external_write; do
  if "$PLUGIN_ROOT/scripts/harvis_team_harness.py" --root "$ROOT" gate --action "$action" --target smoke >/tmp/harvis-smoke-gate-"$action".json 2>/tmp/harvis-smoke-gate-"$action".err; then
    echo "expected approval gate denial for $action" >&2
    exit 1
  fi
done

python3 - "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])

def rows(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]

def require(condition, message):
    if not condition:
        raise SystemExit(message)

run_events = rows(root / ".harvis/runs/run_smoke_001/events.jsonl")
event_types = {event.get("codex_event_type") for event in run_events}
for expected in ["adapter.started", "thread.started", "item.started", "agent_message", "item.completed", "turn.completed", "adapter.completed"]:
    require(expected in event_types, f"missing event type {expected}")
for event in run_events:
    for key in ["observed_at", "task_id", "run_id", "handoff_id", "packet_id", "codex_thread_id", "codex_session_id", "codex_event_type", "summary"]:
        require(key in event, f"event missing {key}: {event}")
require((root / ".harvis/runs/run_smoke_001/final.md").read_text(encoding="utf-8").strip() == "fallback final from agent message", "final fallback did not use agent_message")
completion_card = json.loads((root / ".harvis/runs/run_smoke_001/completion-card.json").read_text(encoding="utf-8"))
require(completion_card.get("schemaVersion") == "harvis.completion-card.v0", "completion card missing schema")
require(completion_card.get("status") == "completed_pending_review", f"completion card status wrong: {completion_card.get('status')}")
require(completion_card.get("run_id") == "run_smoke_001", "completion card missing run_id")
require(completion_card.get("packet_id") == "packet_smoke_001", "completion card missing packet_id")
require(completion_card.get("harness") == "codex", "completion card missing harness")
require(completion_card.get("model") == "gpt-5.5", "completion card missing model")
require(completion_card.get("codex_thread_id") == "019f1111-1111-7111-8111-111111111111", "completion card missing codex thread")
require(completion_card.get("paths", {}).get("events_jsonl") == str(root / ".harvis/runs/run_smoke_001/events.jsonl"), "completion card missing events path")
require(completion_card.get("mobile_workbench_url", "").startswith("https://harvis.example.test/base/studio/mobile/#root="), "completion card missing mobile URL")
require(any(action.get("type") == "open_url" for action in completion_card.get("actions", [])), "completion card missing mobile open action")

resume_thread = json.loads((root / ".harvis/runs/run_smoke_resume/codex-thread.json").read_text(encoding="utf-8"))
require(resume_thread.get("resumed_from_thread_id") == "019f1111-1111-7111-8111-111111111111", "resume binding missing resumed_from_thread_id")

fail_events = rows(root / ".harvis/runs/run_smoke_fail/events.jsonl")
require(any(event.get("codex_event_type") == "adapter.failed" and event.get("exit_code") == 42 for event in fail_events), "failure event missing explicit exit code")
failure_card = json.loads((root / ".harvis/runs/run_smoke_fail/completion-card.json").read_text(encoding="utf-8"))
require(failure_card.get("schemaVersion") == "harvis.completion-card.v0", "failure card missing schema")
require(failure_card.get("status") == "failed_or_blocked", f"failure card status wrong: {failure_card.get('status')}")
require(failure_card.get("codex_thread_id") == "019f1111-1111-7111-8111-111111111111", "failure card did not preserve resume thread id")
failure = failure_card.get("failure") or {}
require(failure.get("exit_code") == 42, "failure card missing explicit exit code")
require("simulated failure" in (failure.get("reason") or ""), "failure card did not preserve Codex failure reason")
require(failure.get("last_event_type") == "turn.failed", "failure card missing last codex event")
require("unknown" not in json.dumps(failure_card, ensure_ascii=False).lower(), "failure card contains unhelpful unknown text")
denied_events = rows(root / ".harvis/runs/run_smoke_resume_denied/events.jsonl")
require(any(event.get("codex_event_type") == "adapter.denied" and event.get("exit_code") == 78 for event in denied_events), "resume without approval was not denied")
denied_status = json.loads((root / ".harvis/runs/run_smoke_resume_denied/status.json").read_text(encoding="utf-8"))
require(denied_status.get("state") == "blocked", "resume denial did not block status")
require("approval" in json.dumps(denied_status, ensure_ascii=False).lower(), "resume denial did not explain missing approval")
denied_card = json.loads((root / ".harvis/runs/run_smoke_resume_denied/completion-card.json").read_text(encoding="utf-8"))
require(denied_card.get("schemaVersion") == "harvis.completion-card.v0", "approval-denied card missing schema")
require(denied_card.get("status") == "failed_or_blocked", "approval-denied card missing blocked status")
require(denied_card.get("codex_thread_id") == "019f1111-1111-7111-8111-111111111111", "approval-denied card missing requested resume thread")
denied_failure = denied_card.get("failure") or {}
require(denied_failure.get("exit_code") == 78, "approval-denied card missing gate exit code")
require("approval" in (denied_failure.get("reason") or "").lower(), "approval-denied card did not explain missing approval")
require("unknown" not in json.dumps(denied_card, ensure_ascii=False).lower(), "approval-denied card contains unhelpful unknown text")
require(denied_status.get("completion_card_json") == str(root / ".harvis/runs/run_smoke_resume_denied/completion-card.json"), "denied status missing completion card path")

bindings = rows(root / ".harvis/codex-threads/bindings.jsonl")
require(len(bindings) >= 3, "expected append-audited codex thread bindings")
first_binding = next(item for item in bindings if item.get("run_id") == "run_smoke_001")
require(first_binding.get("exec_dir") == str(root / ".harvis/runs/run_smoke_001"), "thread binding missing exec_dir")
require(first_binding.get("chat_id") == "chat_smoke", "thread binding missing chat_id")
require(first_binding.get("message_id") == "msg_smoke", "thread binding missing message_id")
pins = rows(root / ".harvis/codex-threads/pins.jsonl")
require(sum(1 for pin in pins if pin.get("action") == "pin") >= 2, "pin events missing explicit and chat-current paths")
latest_chat = json.loads(Path("/tmp/harvis-smoke-latest-chat.json").read_text(encoding="utf-8"))
latest_run = json.loads(Path("/tmp/harvis-smoke-latest-run.json").read_text(encoding="utf-8"))
require(latest_chat.get("ok") is True and latest_chat.get("binding", {}).get("run_id"), "latest by chat did not resolve a binding")
require(latest_run.get("ok") is True and latest_run.get("binding", {}).get("run_id") == "run_smoke_001", "latest by explicit run id did not resolve")
thread_card = json.loads(Path("/tmp/harvis-smoke-thread-card.json").read_text(encoding="utf-8")).get("card", {})
require(thread_card.get("schemaVersion") == "harvis.codex-thread-card.v0", "pin board status card missing schema")
require(thread_card.get("items"), "pin board status card missing items")
mobile_url = thread_card.get("summary", {}).get("mobile_workbench_url") or ""
require(mobile_url.startswith("https://harvis.example.test/base/studio/mobile/#root="), "pin board card missing mobile workbench URL")
require(any(action.get("type") == "open_url" and action.get("url") == mobile_url for action in thread_card.get("actions", [])), "pin board card missing open mobile workbench action")
localhost_card = json.loads(Path("/tmp/harvis-smoke-thread-card-localhost.json").read_text(encoding="utf-8")).get("card", {})
require(not (localhost_card.get("summary", {}).get("mobile_workbench_url")), "localhost must not become mobile workbench URL")
require(not any(action.get("type") == "open_url" for action in localhost_card.get("actions", [])), "localhost card must not include open_url action")
conv = rows(root / ".harvis/agent-room/conversation_binding.jsonl")
require(any(item.get("transport") == "feishu" and item.get("harness_ref") == "dsh" for item in conv), "Digital-Me DSH conversation binding missing")
resolve_chat = json.loads(Path("/tmp/harvis-smoke-resolve-chat.json").read_text(encoding="utf-8"))
resolve_run = json.loads(Path("/tmp/harvis-smoke-resolve-run.json").read_text(encoding="utf-8"))
resolve_wechat = json.loads(Path("/tmp/harvis-smoke-resolve-wechat.json").read_text(encoding="utf-8"))
resolve_webui = json.loads(Path("/tmp/harvis-smoke-resolve-webui.json").read_text(encoding="utf-8"))
require(resolve_chat.get("ok") is True and resolve_chat.get("binding", {}).get("chat_id") == "chat_smoke", "conversation binding did not resolve by chat")
require(resolve_run.get("ok") is True and resolve_run.get("binding", {}).get("run_id") == "run_smoke_001", "conversation binding did not resolve explicit run id")
require(resolve_wechat.get("binding", {}).get("transport") == "wechat", "wechat binding did not resolve within its transport")
require(resolve_webui.get("binding", {}).get("transport") == "webui", "webui binding did not resolve within its transport")
transport_threads = {
    resolve_chat.get("binding", {}).get("transport"): resolve_chat.get("binding", {}).get("codex_thread_id"),
    resolve_wechat.get("binding", {}).get("transport"): resolve_wechat.get("binding", {}).get("codex_thread_id"),
    resolve_webui.get("binding", {}).get("transport"): resolve_webui.get("binding", {}).get("codex_thread_id"),
}
require(len(set(transport_threads.values())) == 3, f"cross transport bindings were mixed: {transport_threads}")
decisions = rows(root / ".harvis/agent-room/chair_decisions.jsonl")
review_decision = json.loads(Path("/tmp/harvis-smoke-decision.json").read_text(encoding="utf-8"))
browser_decision = json.loads(Path("/tmp/harvis-smoke-decision-browser.json").read_text(encoding="utf-8"))
wechat_decision = json.loads(Path("/tmp/harvis-smoke-decision-wechat-article.json").read_text(encoding="utf-8"))
default_decision = json.loads(Path("/tmp/harvis-smoke-decision-default.json").read_text(encoding="utf-8"))
high_risk_decision = json.loads(Path("/tmp/harvis-smoke-decision-high-risk.json").read_text(encoding="utf-8"))
codex_control_decision = json.loads(Path("/tmp/harvis-smoke-decision-codex-control.json").read_text(encoding="utf-8"))
for decision in [review_decision, browser_decision, wechat_decision, default_decision]:
    require(decision.get("dry_run") is True, f"chair decision was not dry-run: {decision}")
    require(decision.get("model_invoked") is False, f"chair dry-run invoked a model: {decision}")
    require(decision.get("control_runtime") == "harvis-conductor", f"chair decision missing Conductor runtime: {decision}")
    require(decision.get("move") == "delegate_task", f"low-risk chair decision did not delegate: {decision}")
    require(decision.get("requires_approval") is False, f"low-risk chair decision still requires approval: {decision}")
    require(decision.get("auto_execute_allowed") is True, f"low-risk chair decision did not allow auto execution: {decision}")
    require(decision.get("risk_level") == "low", f"low-risk chair decision has wrong risk: {decision}")
require(review_decision.get("recommended_harness") == "cxspark", "chair dry-run did not propose cxspark for review task")
require(browser_decision.get("recommended_harness") == "codex", "browser task did not recommend codex")
require(browser_decision.get("recommended_model") == "gpt-5.5", "browser task did not recommend gpt-5.5")
require(browser_decision.get("proposed_tasks", [{}])[0].get("intent") == "browser_operation", "browser task did not classify as browser_operation")
require(wechat_decision.get("recommended_harness") == "codex", "wechat article did not recommend Codex conductor")
require(wechat_decision.get("recommended_model") == "gpt-5.5", "wechat article did not recommend gpt-5.5")
require(wechat_decision.get("proposed_tasks", [{}])[0].get("intent") == "external_article_codex_conductor_task", "wechat article did not classify as conductor task")
require(default_decision.get("recommended_harness") == "dsh", "default task did not recommend Digital-Me DSH")
require(default_decision.get("recommended_model") == "profile-default", "default task did not preserve the DSH profile model")
require(high_risk_decision.get("move") == "request_approval", "high-risk task did not request approval")
require(high_risk_decision.get("requires_approval") is True, "high-risk task skipped approval")
require(high_risk_decision.get("auto_execute_allowed") is False, "high-risk task allowed auto execution")
require(high_risk_decision.get("risk_level") == "high", "high-risk task did not classify as high")
require(codex_control_decision.get("control_runtime") == "codex-control", "control runtime did not switch to codex-control")
require(codex_control_decision.get("control_runtime_kind") == "codex_route_proposal", "codex-control kind missing")
require(codex_control_decision.get("move") == "delegate_task", "codex-control low-risk route should delegate")
tools = rows(root / ".harvis/agent-room/team_tool_calls.jsonl")
require(tools and tools[-1].get("tool") == "team_list_models", "team_list_models call missing")
gates = rows(root / ".harvis/agent-room/approval_gate_checks.jsonl")
dangerous = {"spawn_agent", "execute_command", "file_write", "browser_automation", "git_commit", "git_push", "publish", "delete", "memory_adopt", "external_write"}
denied = {gate.get("action") for gate in gates if gate.get("allowed") is False}
require(dangerous.issubset(denied), f"hard approval gate did not deny all dangerous actions: {sorted(dangerous - denied)}")
events = rows(root / ".harvis/agent-room/events.jsonl")
require(any(event.get("event_type") == "chair.route_proposal" for event in events), "chair event missing")
progress = rows(root / "lark-progress.jsonl")
progress_text = "\n".join(str(item.get("text") or "") for item in progress)
for expected in [
    "H.A.R.V.I.S. 执行已被安全门禁拦截",
    "缺少 approval",
    "H.A.R.V.I.S. 任务执行中",
    "Codex runner 已启动",
    "Codex thread 已创建",
    "命令运行中",
    "命令完成",
    "command_execution",
    "/bin/echo smoke-command",
    "smoke-output",
    "退出码 0",
    "执行已结束，正在进入复核",
    "Codex turn failed: simulated failure",
    "https://harvis.example.test/base/studio/mobile/#root=",
    "H.A.R.V.I.S. 任务完成",
    "H.A.R.V.I.S. 任务失败/阻塞",
    "失败原因：Codex turn failed: simulated failure",
    "移动工作台：https://harvis.example.test/base/studio/mobile/#root=",
]:
    require(expected in progress_text, f"fake lark progress missing: {expected}")
require(any(item.get("content") and "--msg-type" in item.get("args", []) and "interactive" in item.get("args", []) for item in progress), "progress did not send an interactive card")
require(any(item.get("args", [])[:3] == ["api", "PATCH", "/open-apis/im/v1/messages/om_progress_smoke"] for item in progress), "progress card was not updated through message PATCH")
progress_state = json.loads((root / ".harvis/runs/run_smoke_001/progress-card-state.json").read_text(encoding="utf-8"))
require(progress_state.get("message_id") == "om_progress_smoke", "progress card state missing updated message id")
require(progress_state.get("steps"), "progress card state missing steps")
require("Codex step started" not in progress_text, "compact lark progress should not send low-signal step-start messages")
require("Exceeded skills context budget" not in progress_text, "compact lark progress should filter internal skill-budget noise")
print(json.dumps({
    "ok": True,
    "root": str(root),
    "events": len(run_events),
    "bindings": len(bindings),
    "pins": len(pins),
    "conversation_bindings": len(conv),
    "decisions": len(decisions),
    "route_proposals_checked": 4,
    "tool_calls": len(tools),
    "approval_gate_checks": len(gates),
    "lark_progress_messages": len(progress)
}, ensure_ascii=False, indent=2))
PY
