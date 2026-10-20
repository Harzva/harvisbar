#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARVIS_CLI="${HARVIS_CLI:-$PLUGIN_ROOT/scripts/harvis}"
CODEX_CLI="${CODEX_CLI:-${HOME}/.local/bin/codex}"
CODEX_MODEL="${HARVIS_CODEX_MODEL:-gpt-5.5}"
DSH_CLI="${HARVIS_DSH_CLI:-$(command -v dsh 2>/dev/null || true)}"
DSH_PROFILE="${HARVIS_DSH_PROFILE:-digital-me-headless}"
DSH_PERMISSION_MODE="${HARVIS_DSH_PERMISSION_MODE:-workspace-write}"
KIMICODE_WRAPPER="${KIMICODE_WRAPPER:-${HOME}/.codex/skills/cckimi/scripts/cckimi.sh}"
CLAUDE_CODE_WRAPPER="${CLAUDE_CODE_WRAPPER:-${HOME}/.codex/skills/ccdeepseek/scripts/ccdeepseek.sh}"
MIMOCODE_CLI="${MIMOCODE_CLI:-${HOME}/.local/bin/mimocode}"
LIKECODE_CLI="${LIKECODE_CLI:-$(command -v likecode 2>/dev/null || true)}"
LIKECODE_MODEL="${HARVIS_LIKECODE_MODEL:-d4p}"
ROOT="${HARVIS_WORKSPACE_ROOT:-$PWD}"
HANDOFF_ID=""
DRY_RUN=0
AUTO_REVIEW_DRY_RUN="${HARVIS_HANDOFF_AUTO_REVIEW_DRY_RUN:-0}"
ENABLE_EXPERIMENTAL_HARNESSES="${HARVIS_HANDOFF_ENABLE_EXPERIMENTAL_HARNESSES:-0}"
RUNNER_ID="${HARVIS_HANDOFF_RUNNER_ID:-harvis-handoff-runner}"
TIMEOUT_SECONDS="${HARVIS_HANDOFF_TIMEOUT_SECONDS:-900}"
EXECUTION_ROOT="${HARVIS_EXECUTION_ROOT:-}"

usage() {
  cat <<'USAGE'
Usage: harvis-handoff-run.sh --handoff-id ID [options]

Options:
  --root DIR          Workspace root containing .harvis/.
  --handoff-id ID     Handoff id under .harvis/handoffs/.
  --dry-run           Do not call a harness; only exercise state transitions.
  --auto-review-dry-run
                      After a successful run, perform a rule-based reviewer
                      dry-run closeout by calling agent-room handoff-review.
  --runner-id ID      Actor recorded in handoff status updates.
  --timeout-seconds N Maximum harness runtime before marking blocked. Default: 900.
  -h, --help          Show this help.

This runner is transport-neutral. It advances a pre-existing approved handoff
from pending_harness to running, then to reviewing or blocked. It never marks a
task done; reviewer acceptance must be recorded separately.

Digital-Me DSH is the default general-task adapter. Codex remains the browser,
external-article conductor, and recovery fallback. Other live adapters are
enabled when their local wrapper exists. Set
HARVIS_HANDOFF_ENABLE_EXPERIMENTAL_HARNESSES=0 to force them to block safely
after writing a reviewable adapter contract.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    --handoff-id)
      HANDOFF_ID="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --auto-review-dry-run)
      AUTO_REVIEW_DRY_RUN=1
      shift
      ;;
    --runner-id)
      RUNNER_ID="${2:-}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$HANDOFF_ID" ]]; then
  echo "--handoff-id is required" >&2
  exit 2
fi
if [[ ! "$HANDOFF_ID" =~ ^handoff_[A-Za-z0-9T_-]+$ ]]; then
  echo "invalid handoff id: $HANDOFF_ID" >&2
  exit 2
fi
if [[ ! "$TIMEOUT_SECONDS" =~ ^[0-9]+$ || "$TIMEOUT_SECONDS" -lt 1 ]]; then
  echo "--timeout-seconds must be a positive integer" >&2
  exit 2
fi
if [[ "$AUTO_REVIEW_DRY_RUN" != "0" && "$AUTO_REVIEW_DRY_RUN" != "1" ]]; then
  echo "HARVIS_HANDOFF_AUTO_REVIEW_DRY_RUN must be 0 or 1" >&2
  exit 2
fi
if [[ "$ENABLE_EXPERIMENTAL_HARNESSES" != "0" && "$ENABLE_EXPERIMENTAL_HARNESSES" != "1" ]]; then
  echo "HARVIS_HANDOFF_ENABLE_EXPERIMENTAL_HARNESSES must be 0 or 1" >&2
  exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"
if [[ ! -x "$HARVIS_CLI" ]]; then
  echo "missing harvis CLI: $HARVIS_CLI" >&2
  exit 127
fi

HANDOFF_JSON="$("$HARVIS_CLI" agent-room --root "$ROOT" handoffs --limit 500 | python3 -c '
import json
import sys

handoff_id = sys.argv[1]
payload = json.load(sys.stdin)
for item in payload.get("handoffs", []):
    if item.get("handoff_id") == handoff_id:
        print(json.dumps(item, ensure_ascii=False))
        raise SystemExit(0)
raise SystemExit(3)
' "$HANDOFF_ID")" || {
  echo "handoff not found: $HANDOFF_ID" >&2
  exit 3
}

field() {
  python3 - "$HANDOFF_JSON" "$1" <<'PY'
import json
import sys

item = json.loads(sys.argv[1])
value = item
for part in sys.argv[2].split("."):
    if not isinstance(value, dict):
        print("")
        raise SystemExit(0)
    value = value.get(part)
if value is None:
    print("")
elif isinstance(value, str):
    print(value)
else:
    print(json.dumps(value, ensure_ascii=False))
PY
}

RUN_ID="$(field run_id)"
PACKET_ID="$(field packet_id)"
PACKET_PATH_FIELD="$(field packet_path)"
HARNESS="$(field harness)"
INSTRUCTION="$(field instruction)"
STATE="$(field state)"
TOPIC_ID="$(field topic_id)"

if [[ -z "$RUN_ID" || -z "$PACKET_ID" || -z "$HARNESS" ]]; then
  echo "handoff is missing run_id, packet_id, or harness" >&2
  exit 4
fi
if [[ "$STATE" != "pending_harness" && "$STATE" != "running" ]]; then
  echo "handoff state must be pending_harness or running, got: $STATE" >&2
  exit 4
fi
case "$HARNESS" in
  dsh|codex|kimicode|claude-code|likecode|manual) ;;
  claude) HARNESS="claude-code" ;;
  *)
    "$HARVIS_CLI" agent-room --root "$ROOT" handoff-status \
      --handoff-id "$HANDOFF_ID" \
      --state blocked \
      --summary "Unsupported handoff harness for generic runner: $HARNESS" \
      --updated-by "$RUNNER_ID" >/dev/null || true
    echo "unsupported harness: $HARNESS" >&2
    exit 78
    ;;
esac

if [[ "$PACKET_PATH_FIELD" = /* ]]; then
  PACKET_PATH="$PACKET_PATH_FIELD"
else
  PACKET_PATH="$ROOT/$PACKET_PATH_FIELD"
fi
if [[ ! -f "$PACKET_PATH" ]]; then
  echo "packet not found: $PACKET_PATH" >&2
  exit 4
fi

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
EXEC_DIR_FALLBACK=0
if [[ -n "$EXECUTION_ROOT" ]]; then
  EXEC_DIR="$EXECUTION_ROOT/$RUN_ID-$STAMP-handoff"
  mkdir -p "$EXEC_DIR"
  RESULT_REL="$EXEC_DIR/final.md"
else
  EXEC_DIR="$ROOT/.harvis/executions/$RUN_ID-$STAMP-handoff"
  RESULT_REL=".harvis/executions/$(basename "$EXEC_DIR")/final.md"
fi
MKDIR_ERR="${TMPDIR:-/tmp}/harvis-handoff-mkdir-$$.err"
if [[ -z "$EXECUTION_ROOT" ]] && ! mkdir -p "$EXEC_DIR" 2>"$MKDIR_ERR"; then
  WORKSPACE_HASH="$(python3 - "$ROOT" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:16])
PY
)"
  EXEC_DIR="$HOME/.harvis/executions/$WORKSPACE_HASH/$RUN_ID-$STAMP-handoff"
  mkdir -p "$EXEC_DIR"
  EXEC_DIR_FALLBACK=1
  RESULT_REL="$EXEC_DIR/final.md"
  {
    printf 'workspace execution directory was not writable for this process\n'
    printf 'workspace_root=%s\n' "$ROOT"
    printf 'fallback_exec_dir=%s\n' "$EXEC_DIR"
    printf 'mkdir_error=%s\n' "$(cat "$MKDIR_ERR" 2>/dev/null || true)"
  } >"$EXEC_DIR/workspace-exec-dir-fallback.txt"
fi
rm -f "$MKDIR_ERR"
PROMPT_FILE="$EXEC_DIR/prompt.md"
FINAL_FILE="$EXEC_DIR/final.md"
STDOUT_LOG="$EXEC_DIR/harness.out.log"
STDERR_LOG="$EXEC_DIR/harness.err.log"
STATUS_JSON="$EXEC_DIR/status.json"
DSH_STATUS_JSON="$EXEC_DIR/dsh-status.json"
ADAPTER_JSON="$EXEC_DIR/adapter.json"
REGISTRY_STATUS_JSON="$EXEC_DIR/agent-pools-status.json"
CODEX_THREAD_JSON="$EXEC_DIR/codex-thread.json"
CONDUCTOR_TASK_JSON="$EXEC_DIR/conductor_task.json"
CONDUCTOR_EVENTS_JSONL="$EXEC_DIR/conductor_events.jsonl"
CONDUCTOR_RESULT_JSON="$EXEC_DIR/conductor_result.json"
WORKER_REGISTRY_JSON="$EXEC_DIR/worker-registry.json"
RUN_EVENTS_DIR="$ROOT/.harvis/runs/$RUN_ID"
if mkdir -p "$RUN_EVENTS_DIR" 2>/dev/null; then
  RUN_EVENTS_JSONL="$RUN_EVENTS_DIR/events.jsonl"
else
  RUN_EVENTS_JSONL="$EXEC_DIR/events.jsonl"
fi

append_adapter_event() {
  local event_type="$1"
  local summary="$2"
  python3 - "$RUN_EVENTS_JSONL" "$HANDOFF_ID" "$RUN_ID" "$PACKET_ID" "$HARNESS" "$event_type" "$summary" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
handoff_id, run_id, packet_id, harness, event_type, summary = sys.argv[2:]
event = {
    "schemaVersion": "harvis.harness-adapter-events.v0",
    "observed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "handoff_id": handoff_id,
    "run_id": run_id,
    "packet_id": packet_id,
    "harness": harness,
    "codex_event_type": event_type,
    "type": event_type,
    "summary": summary,
}
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

append_command_event() {
  local phase="$1"
  local command="$2"
  local status="$3"
  local exit_code="${4:-}"
  local output="${5:-}"
  python3 - "$RUN_EVENTS_JSONL" "$HANDOFF_ID" "$RUN_ID" "$PACKET_ID" "$HARNESS" "$phase" "$command" "$status" "$exit_code" "$output" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
handoff_id, run_id, packet_id, harness, phase, command, status, exit_code, output = sys.argv[2:]
event_type = "item.started" if phase == "started" else "item.completed"
item = {
    "id": f"{harness}-{phase}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}",
    "type": "command_execution",
    "command": command,
    "status": status,
}
if exit_code != "":
    try:
        item["exit_code"] = int(exit_code)
    except ValueError:
        item["exit_code"] = exit_code
if output.strip():
    item["aggregated_output"] = output.strip()[:4000]
event = {
    "schemaVersion": "harvis.harness-adapter-events.v0",
    "observed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "handoff_id": handoff_id,
    "run_id": run_id,
    "packet_id": packet_id,
    "harness": harness,
    "codex_event_type": event_type,
    "type": event_type,
    "summary": f"command_execution {'started' if phase == 'started' else 'completed'}: {command}",
    "raw": {"item": item},
}
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

event_preview() {
  python3 - "$FINAL_FILE" "$STDERR_LOG" "$STDOUT_LOG" <<'PY'
import sys
from pathlib import Path

parts = []
for raw in sys.argv[1:]:
    path = Path(raw)
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8", errors="replace").strip()
    if text:
        parts.append(text[-700:])
print("\n---\n".join(parts)[:1200])
PY
}

if ! "$PLUGIN_ROOT/scripts/harvis_conductor_run.py" prepare \
  --root "$ROOT" \
  --exec-dir "$EXEC_DIR" \
  --packet-path "$PACKET_PATH" \
  --instruction "$INSTRUCTION" \
  --harness "$HARNESS" \
  --run-id "$RUN_ID" \
  --handoff-id "$HANDOFF_ID" \
  --packet-id "$PACKET_ID" \
  --task-path "$CONDUCTOR_TASK_JSON" \
  --events-path "$CONDUCTOR_EVENTS_JSONL" \
  --result-path "$CONDUCTOR_RESULT_JSON" \
  --registry-path "$WORKER_REGISTRY_JSON" \
  --run-events-jsonl "$RUN_EVENTS_JSONL"; then
  append_adapter_event "conductor.prepare_failed" "Failed to create conductor contract; continuing with normal harness prompt."
fi

CONDUCTOR_PROMPT_SECTION=""
if [[ -f "$CONDUCTOR_TASK_JSON" ]]; then
  CONDUCTOR_PROMPT_SECTION="$(cat <<EOF

Conductor contract:
- conductor_task: $CONDUCTOR_TASK_JSON
- conductor_events: $CONDUCTOR_EVENTS_JSONL
- conductor_result: $CONDUCTOR_RESULT_JSON
- worker_registry: $WORKER_REGISTRY_JSON

Conductor rules:
- You are the Codex Conductor for this packet.
- Read conductor_task.json first, then dynamically plan the workflow.
- Decide which workers to use from the local registry; do not follow a Harvis hard-coded workflow.
- Write progress events to conductor_events.jsonl.
- Write final business result to conductor_result.json with status, business_success, reason, artifacts, draft_id/media_id when available, image_count, and blocker details.
- create_draft is an allowed WeChat draft-box action. It is not group-send, freepublish, formal publish, deploy, push, or delete.
- Exit code 0 is not success unless conductor_result.json or verified artifacts prove success.
EOF
)"
fi

cat >"$PROMPT_FILE" <<PROMPT
You are a H.A.R.V.I.S. approved harness runner.

Handoff:
- handoff_id: $HANDOFF_ID
- run_id: $RUN_ID
- packet_id: $PACKET_ID
- topic_id: ${TOPIC_ID:-gwt-workbench}
- harness: $HARNESS
- workspace: $ROOT

Instruction:
$INSTRUCTION

Hard boundaries:
- Read local repository rules before acting.
- Stay inside the approved workspace unless the packet explicitly names another local path.
- Do not commit, push, group-send, freepublish, formally publish, deploy, delete, reset, or expose secrets unless the packet explicitly requests that exact action; delete / 删除 / 清空 still requires approval.
- Prefer read-only investigation unless the packet explicitly requires implementation.
- If higher-risk action is required, stop and explain the needed approval.
- Final answer must include what was done, files touched, checks run, and blockers.

$CONDUCTOR_PROMPT_SECTION

Adapter observability for non-Codex harnesses:
- When you run a local command or external write action, include one redacted line in output:
  HARVIS_EVENT {"type":"command_execution","status":"started|completed|failed","label":"short human label","command":"redacted command","exit_code":0}
- Do not include secret values, cookies, tokens, or raw credential material in HARVIS_EVENT.

Packet:

$(cat "$PACKET_PATH")
PROMPT

"$HARVIS_CLI" agent-room --root "$ROOT" handoff-status \
  --handoff-id "$HANDOFF_ID" \
  --state running \
  --summary "Generic handoff runner started. exec_dir=$EXEC_DIR" \
  --updated-by "$RUNNER_ID" \
  --result-path "$RESULT_REL" >/dev/null

cat >"$STATUS_JSON" <<JSON
{
  "status": "running",
  "handoff_id": "$HANDOFF_ID",
  "run_id": "$RUN_ID",
  "packet_id": "$PACKET_ID",
  "harness": "$HARNESS",
  "model_id": "$([[ "$HARNESS" == "dsh" ]] && printf 'dsh:profile-default' || printf 'openai:%s' "$CODEX_MODEL")",
  "experimental_harnesses_enabled": "$ENABLE_EXPERIMENTAL_HARNESSES",
  "started_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "exec_dir": "$EXEC_DIR",
  "exec_dir_fallback": $EXEC_DIR_FALLBACK,
  "events_jsonl": "$RUN_EVENTS_JSONL",
  "dsh_adapter_status": "$DSH_STATUS_JSON",
  "codex_thread_binding": "$CODEX_THREAD_JSON",
  "conductor_task": "$CONDUCTOR_TASK_JSON",
  "conductor_events": "$CONDUCTOR_EVENTS_JSONL",
  "conductor_result": "$CONDUCTOR_RESULT_JSON",
  "worker_registry": "$WORKER_REGISTRY_JSON"
}
JSON
append_adapter_event "adapter.started" "$HARNESS handoff adapter started."
append_command_event "completed" "read packet: $PACKET_PATH" "completed" "0" "Packet loaded into harness prompt."

write_adapter_contract() {
  "$HARVIS_CLI" agent-pools --root "$ROOT" status --query "$HARNESS" >"$REGISTRY_STATUS_JSON" 2>/dev/null || printf '{}\n' >"$REGISTRY_STATUS_JSON"
  python3 - "$ADAPTER_JSON" "$REGISTRY_STATUS_JSON" "$HARNESS" "$CODEX_CLI" "$DSH_CLI" "$DSH_PROFILE" "$DSH_PERMISSION_MODE" "$KIMICODE_WRAPPER" "$CLAUDE_CODE_WRAPPER" "${LIKECODE_CLI:-}" "$ENABLE_EXPERIMENTAL_HARNESSES" <<'PY'
import json
import sys
from pathlib import Path

(
    path,
    registry_status_path,
    harness,
    codex_cli,
    dsh_cli,
    dsh_profile,
    dsh_permission_mode,
    kimicode_wrapper,
    claude_code_wrapper,
    likecode_cli,
    experimental,
) = sys.argv[1:]
try:
    registry_status = json.loads(Path(registry_status_path).read_text(encoding="utf-8"))
except Exception:
    registry_status = {}
registry_harnesses = registry_status.get("harnesses") if isinstance(registry_status.get("harnesses"), list) else []
registry_harness = registry_harnesses[0] if registry_harnesses else {}
registry_adapter = registry_harness.get("adapter") if isinstance(registry_harness.get("adapter"), dict) else {}
adapters = {
    "dsh": {
        "mode": "live-default",
        "command": dsh_cli,
        "profile": dsh_profile,
        "permission_mode": dsh_permission_mode,
        "prompt_input": "arg",
        "result_output": "file",
    },
    "codex": {
        "mode": "live-default",
        "command": codex_cli,
        "prompt_input": "stdin",
        "result_output": "file",
    },
    "kimicode": {
        "mode": "experimental-live" if experimental == "1" else "blocked-unless-enabled",
        "command": kimicode_wrapper,
        "prompt_input": "arg",
        "result_output": "file",
    },
    "claude-code": {
        "mode": "experimental-live" if experimental == "1" else "blocked-unless-enabled",
        "command": claude_code_wrapper,
        "prompt_input": "arg",
        "result_output": "file",
    },
    "likecode": {
        "mode": "experimental-live" if experimental == "1" else "blocked-unless-enabled",
        "command": likecode_cli,
        "prompt_input": "arg",
        "result_output": "stdout",
    },
    "manual": {
        "mode": "manual",
        "command": "",
        "prompt_input": "manual",
        "result_output": "manual",
    },
}
contract = {
    "schemaVersion": "harvis.harness-adapter.v0",
    "harness": harness,
    "registry_status": registry_harness.get("status", "unknown"),
    "registry": {
        "source": registry_status.get("source"),
        "harness": registry_harness,
        "adapter": registry_adapter,
    },
    "adapter": adapters.get(harness, {"mode": "unsupported", "command": ""}),
    "resolved_command": adapters.get(harness, {}).get("command", ""),
    "safety": {
        "executes_without_approval": False,
        "requires_review_gate": True,
        "includesSecrets": False,
    },
}
Path(path).write_text(json.dumps(contract, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

run_codex_adapter() {
  if [[ ! -x "$CODEX_CLI" ]]; then
    echo "missing codex CLI: $CODEX_CLI" >&2
    return 127
  fi
  "$PLUGIN_ROOT/scripts/harvis_codex_jsonl_adapter.py" \
    --codex "$CODEX_CLI" \
    --root "$ROOT" \
    --prompt-file "$PROMPT_FILE" \
    --final-file "$FINAL_FILE" \
    --stdout-log "$STDOUT_LOG" \
    --stderr-log "$STDERR_LOG" \
    --events-jsonl "$RUN_EVENTS_JSONL" \
    --thread-json "$CODEX_THREAD_JSON" \
    --status-json "$STATUS_JSON" \
    --timeout-seconds "$TIMEOUT_SECONDS" \
    --handoff-id "$HANDOFF_ID" \
    --run-id "$RUN_ID" \
    --packet-id "$PACKET_ID" \
    --model "$CODEX_MODEL" \
    --lark-cli "${LARK_CLI:-}" \
    --lark-message-id "${HARVIS_LARK_MESSAGE_ID:-}" \
    --lark-chat-id "${HARVIS_LARK_CHAT_ID:-}" \
    --lark-progress-events "${HARVIS_LARK_PROGRESS_EVENTS:-0}" \
    --approval-id "${APPROVAL_ID:-${HARVIS_APPROVAL_ID:-}}" \
    --resume-thread-id "${HARVIS_CODEX_RESUME_THREAD_ID:-}"
}

run_dsh_adapter() {
  local display_command="dsh --profile $DSH_PROFILE <harvis-prompt>"
  append_command_event "started" "$display_command" "in_progress"
  python3 "$PLUGIN_ROOT/scripts/harvis_dsh_adapter.py" \
    --dsh "$DSH_CLI" \
    --profile "$DSH_PROFILE" \
    --root "$ROOT" \
    --prompt-file "$PROMPT_FILE" \
    --final-file "$FINAL_FILE" \
    --stdout-log "$STDOUT_LOG" \
    --stderr-log "$STDERR_LOG" \
    --status-json "$DSH_STATUS_JSON" \
    --timeout-seconds "$TIMEOUT_SECONDS" \
    --permission-mode "$DSH_PERMISSION_MODE"
  local dsh_exit=$?
  append_command_event "completed" "$display_command" "completed" "$dsh_exit" "$(event_preview)"
  return "$dsh_exit"
}

run_conductor_adapter() {
  if [[ ! -f "$CONDUCTOR_TASK_JSON" ]]; then
    run_codex_adapter
    return $?
  fi
  if [[ ! -x "$CODEX_CLI" ]]; then
    echo "missing codex CLI: $CODEX_CLI" >&2
    return 127
  fi
  "$PLUGIN_ROOT/scripts/harvis_conductor_run.py" run \
    --task-path "$CONDUCTOR_TASK_JSON" \
    --root "$ROOT" \
    --codex "$CODEX_CLI" \
    --model "$CODEX_MODEL" \
    --timeout-seconds "$TIMEOUT_SECONDS" \
    --stdout-log "$STDOUT_LOG" \
    --stderr-log "$STDERR_LOG" \
    --prompt-path "$EXEC_DIR/conductor-prompt.md"
  local conductor_exit=$?
  python3 - "$CONDUCTOR_RESULT_JSON" "$FINAL_FILE" "$RUN_EVENTS_JSONL" "$HANDOFF_ID" "$RUN_ID" "$PACKET_ID" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

result_path = Path(sys.argv[1])
final_path = Path(sys.argv[2])
events_path = Path(sys.argv[3])
handoff_id, run_id, packet_id = sys.argv[4:7]
try:
    result = json.loads(result_path.read_text(encoding="utf-8"))
except Exception as exc:
    result = {
        "status": "workflow_failed",
        "business_success": False,
        "reason": f"Could not read conductor_result.json: {exc}",
        "artifacts": {},
    }
artifacts = result.get("artifacts") if isinstance(result.get("artifacts"), dict) else {}
lines = [
    "H.A.R.V.I.S. Codex Conductor result.",
    "",
    f"status: {result.get('status') or 'unknown'}",
    f"business_success: {result.get('business_success')}",
    f"reason: {result.get('reason') or ''}",
    f"current_stage: {result.get('current_stage') or result.get('stage') or ''}",
]
if artifacts:
    lines.append("")
    lines.append("artifacts:")
    for key in ["draft_id", "media_id", "image_count", "article_md", "article_path", "draft_json", "material_dir", "browser_proof"]:
        value = artifacts.get(key)
        if value not in (None, "", [], {}):
            lines.append(f"- {key}: {value}")
lines.append("")
lines.append(f"conductor_result: {result_path}")
final_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
events_path.parent.mkdir(parents=True, exist_ok=True)
with events_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "schemaVersion": "harvis.conductor-events.v0",
        "observed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "handoff_id": handoff_id,
        "run_id": run_id,
        "packet_id": packet_id,
        "codex_event_type": "conductor.result",
        "type": "conductor.result",
        "summary": result.get("reason") or result.get("status") or "Conductor result recorded",
        "business_success": bool(result.get("business_success")),
        "workflow": result,
    }, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
  return "$conductor_exit"
}

run_wrapper_adapter() {
  local wrapper="$1"
  local label="$2"
  if [[ "$ENABLE_EXPERIMENTAL_HARNESSES" != "1" ]]; then
    local target_note=""
    if grep -Eqi 'mp\.weixin\.qq\.com|wemedia|09-wemedia' "$PROMPT_FILE"; then
      target_note="文件未下载到 wemedia。"
    fi
    cat >"$FINAL_FILE" <<EOF
未执行。原因：$label adapter 被 HARVIS_HANDOFF_ENABLE_EXPERIMENTAL_HARNESSES=0 显式禁用。$target_note

如需允许该 adapter，请设置 HARVIS_HANDOFF_ENABLE_EXPERIMENTAL_HARNESSES=1，或把任务 fallback 到 codex adapter。
Adapter contract: $ADAPTER_JSON
EOF
    echo "$label adapter disabled by HARVIS_HANDOFF_ENABLE_EXPERIMENTAL_HARNESSES=0. $target_note" >"$STDERR_LOG"
    append_command_event "completed" "$label adapter disabled" "completed" "78" "$target_note"
    return 78
  fi
  if [[ ! -x "$wrapper" ]]; then
    cat >"$FINAL_FILE" <<EOF
$label handoff adapter could not start because the wrapper is missing or not executable.

Expected wrapper: $wrapper
EOF
    echo "missing $label wrapper: $wrapper" >"$STDERR_LOG"
    append_command_event "completed" "$label wrapper lookup" "completed" "127" "Expected wrapper missing or not executable: $wrapper"
    return 127
  fi
  local display_command="$wrapper -Cwd $ROOT -Prompt <prompt.md> -OutputPath $FINAL_FILE -TimeoutSeconds $TIMEOUT_SECONDS"
  append_command_event "started" "$display_command" "in_progress" "" ""
  set +e
  "$wrapper" \
    -Cwd "$ROOT" \
    -Prompt "$(cat "$PROMPT_FILE")" \
    -OutputPath "$FINAL_FILE" \
    -TimeoutSeconds "$TIMEOUT_SECONDS" >"$STDOUT_LOG" 2>"$STDERR_LOG"
  local wrapper_exit=$?
  append_command_event "completed" "$display_command" "completed" "$wrapper_exit" "$(event_preview)"
  return "$wrapper_exit"
}

material_ingest_prompt() {
  grep -Eqi 'mp\.weixin\.qq\.com|zhihu\.com|csdn\.net|wemedia|09-wemedia|文章素材库' "$PROMPT_FILE"
}

run_kimicode_adapter() {
  run_wrapper_adapter "$KIMICODE_WRAPPER" "KimiCode"
  local kimi_exit=$?
  if [[ "$kimi_exit" -eq 0 ]]; then
    return 0
  fi
  if ! material_ingest_prompt; then
    return "$kimi_exit"
  fi
  {
    echo
    echo "[harvis] KimiCode adapter exited with code $kimi_exit for a wemedia material-ingestion prompt; trying Claude Code fallback."
  } >>"$STDERR_LOG"
  append_adapter_event "adapter.fallback" "KimiCode exited with code $kimi_exit; trying Claude Code fallback for wemedia material task."
  run_wrapper_adapter "$CLAUDE_CODE_WRAPPER" "Claude Code"
  local claude_exit=$?
  return "$claude_exit"
}

run_likecode_adapter() {
  if [[ "$ENABLE_EXPERIMENTAL_HARNESSES" != "1" ]]; then
    cat >"$FINAL_FILE" <<EOF
LikeCode handoff adapter is registered but live execution is disabled.

Set HARVIS_HANDOFF_ENABLE_EXPERIMENTAL_HARNESSES=1 after installing and smoke-testing the likecode command.
Adapter contract: $ADAPTER_JSON
EOF
    echo "likecode adapter blocked because HARVIS_HANDOFF_ENABLE_EXPERIMENTAL_HARNESSES is not enabled." >"$STDERR_LOG"
    return 78
  fi
  if [[ -z "${LIKECODE_CLI:-}" || ! -x "$LIKECODE_CLI" ]]; then
    cat >"$FINAL_FILE" <<EOF
LikeCode handoff adapter could not start because the likecode command is not installed.
EOF
    echo "missing likecode command" >"$STDERR_LOG"
    return 127
  fi
  "$LIKECODE_CLI" \
    -p \
    --model "$LIKECODE_MODEL" \
    --permission-mode plan \
    --no-session-persistence \
    --output-format text \
    "$(cat "$PROMPT_FILE")" >"$FINAL_FILE" 2>"$STDERR_LOG"
}

write_adapter_contract
HARNESS_REGISTRY_STATUS="$(python3 - "$ADAPTER_JSON" <<'PY'
import json
import sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    print(((data.get("registry") or {}).get("harness") or {}).get("status") or "unknown")
except Exception:
    print("unknown")
PY
)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat >"$FINAL_FILE" <<EOF
Dry run prepared H.A.R.V.I.S. handoff execution.

handoff_id: $HANDOFF_ID
run_id: $RUN_ID
packet_id: $PACKET_ID
harness: $HARNESS
adapter_contract: $ADAPTER_JSON

No harness process was started.
EOF
  EXIT_CODE=0
else
  if [[ "$HARNESS" != "manual" && "$HARNESS_REGISTRY_STATUS" != "active" && "$HARNESS_REGISTRY_STATUS" != "partial" ]]; then
    cat >"$FINAL_FILE" <<EOF
Handoff harness $HARNESS is not active in the agent-pools registry.

registry_status: $HARNESS_REGISTRY_STATUS
adapter_contract: $ADAPTER_JSON
EOF
    echo "harness $HARNESS is not active in registry: $HARNESS_REGISTRY_STATUS" >"$STDERR_LOG"
    EXIT_CODE=78
  else
  set +e
  case "$HARNESS" in
    dsh) run_dsh_adapter ;;
    codex)
      if [[ -f "$CONDUCTOR_TASK_JSON" && "${HARVIS_CONDUCTOR_RUNNER_ENABLED:-1}" == "1" ]]; then
        run_conductor_adapter
      else
        run_codex_adapter
      fi
      ;;
    kimicode) run_kimicode_adapter ;;
    claude-code) run_wrapper_adapter "$CLAUDE_CODE_WRAPPER" "Claude Code" ;;
    likecode) run_likecode_adapter ;;
    manual)
      cat >"$FINAL_FILE" <<EOF
Manual handoff requested. No harness process was started.

Adapter contract: $ADAPTER_JSON
EOF
      echo "manual handoff does not execute a harness" >"$STDERR_LOG"
      (exit 78)
      ;;
  esac
  EXIT_CODE=$?
  set -e
  fi
fi

if [[ "$HARNESS" != "codex" ]]; then
  python3 - "$RUN_EVENTS_JSONL" "$HANDOFF_ID" "$RUN_ID" "$PACKET_ID" "$HARNESS" "$FINAL_FILE" "$STDOUT_LOG" "$STDERR_LOG" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

events_path = Path(sys.argv[1])
handoff_id, run_id, packet_id, harness = sys.argv[2:6]
files = [Path(p) for p in sys.argv[6:]]

def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def append(event: dict) -> None:
    event.setdefault("schemaVersion", "harvis.harness-adapter-events.v0")
    event.setdefault("observed_at", now())
    event.setdefault("handoff_id", handoff_id)
    event.setdefault("run_id", run_id)
    event.setdefault("packet_id", packet_id)
    event.setdefault("harness", harness)
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with events_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")

def command_event(command: str, exit_code, output: str = "") -> None:
    item = {
        "id": f"{harness}-parsed-{abs(hash((command, output))) % 10_000_000}",
        "type": "command_execution",
        "command": command[:300],
        "status": "completed",
        "exit_code": exit_code,
    }
    if output.strip():
        item["aggregated_output"] = output.strip()[:1200]
    append({
        "codex_event_type": "item.completed",
        "type": "item.completed",
        "summary": f"parsed command_execution: {command[:120]}",
        "raw": {"item": item},
    })

texts = []
for path in files:
    if path.exists():
        texts.append(path.read_text(encoding="utf-8", errors="replace"))
text = "\n".join(texts)

for line in text.splitlines():
    marker = "HARVIS_EVENT"
    if marker not in line:
        continue
    raw = line.split(marker, 1)[1].strip()
    if not raw:
        continue
    try:
        payload = json.loads(raw)
    except Exception:
        append({"codex_event_type": "adapter.note", "type": "adapter.note", "summary": f"Unparseable HARVIS_EVENT: {raw[:180]}"})
        continue
    if not isinstance(payload, dict):
        continue
    typ = str(payload.get("type") or "")
    status = str(payload.get("status") or "")
    command = str(payload.get("command") or payload.get("label") or typ or "harness event")
    if typ == "command_execution" or command:
        exit_code = payload.get("exit_code")
        if status in {"started", "in_progress", "running"} and exit_code is None:
            item_status = "in_progress"
            event_type = "item.started"
        else:
            item_status = "completed"
            event_type = "item.completed"
        item = {"type": "command_execution", "command": command[:300], "status": item_status}
        if exit_code is not None:
            item["exit_code"] = exit_code
        append({
            "codex_event_type": event_type,
            "type": event_type,
            "summary": str(payload.get("label") or command)[:180],
            "raw": {"item": item},
        })

lower = text.lower()
if "md2wechat" in lower and "doctor" in lower:
    command_event("md2wechat doctor", 0 if "valid" in lower or "ok" in lower else None, "Detected from Kimi output.")
if "create_draft" in lower:
    pending = bool(re.search(
        r"(未执行|未调用|需调用|需要调用|待执行|交给\s*codex|由\s*codex|stop before|before final draft|not do the final).{0,160}create_draft|"
        r"create_draft.{0,160}(未执行|未调用|需调用|需要调用|待执行|交给\s*codex|由\s*codex|stop before|before final draft|not do the final)",
        lower,
        re.S,
    ))
    failed = bool(re.search(r"(create_draft|草稿).{0,120}(fail|failed|error|未写入|没有拿到|缺少|not configured)", lower, re.S))
    succeeded = bool(re.search(
        r"(create_draft|微信草稿箱|draft).{0,240}(media_id|thumb_media_id|errcode[\"']?\s*:\s*0|已写入|写入成功)|"
        r"(media_id|errcode[\"']?\s*:\s*0|已写入|写入成功).{0,240}(create_draft|微信草稿箱|draft)",
        lower,
        re.S,
    ))
    if pending and not succeeded:
        append({
            "codex_event_type": "adapter.note",
            "type": "adapter.note",
            "summary": "Detected create_draft mention as pending/handoff text, not an executed command.",
        })
    else:
        command_event("md2wechat create_draft <draft_json> --json", 1 if failed else (0 if succeeded else None), "Detected from Kimi output.")
PY
  append_adapter_event "adapter.completed" "$HARNESS adapter exited with code $EXIT_CODE."
fi

RUNNER_SUMMARY="$(python3 - "$STATUS_JSON" "$EXIT_CODE" "$RUN_EVENTS_JSONL" "$STDERR_LOG" "$STDOUT_LOG" "$FINAL_FILE" "$CODEX_THREAD_JSON" "$EXEC_DIR" "$HARNESS" "$RUN_ID" "$HANDOFF_ID" "$PACKET_ID" "$CONDUCTOR_TASK_JSON" "$CONDUCTOR_EVENTS_JSONL" "$CONDUCTOR_RESULT_JSON" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
code = int(sys.argv[2])
events_path = Path(sys.argv[3])
stderr_path = Path(sys.argv[4])
stdout_path = Path(sys.argv[5])
final_path = Path(sys.argv[6])
thread_path = Path(sys.argv[7])
exec_dir = sys.argv[8]
harness = sys.argv[9]
run_id = sys.argv[10]
handoff_id = sys.argv[11]
packet_id = sys.argv[12]
conductor_task_path = Path(sys.argv[13])
conductor_events_path = Path(sys.argv[14])
conductor_result_path = Path(sys.argv[15])

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    data = {}


def read_tail(target: Path, limit: int = 2000) -> str:
    try:
        text = target.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""
    return text[-limit:].strip()

def external_article_fallback_verdict(final_text: str, stderr_text: str = ""):
    text = f"{final_text}\n{stderr_text}".strip()
    lower = text.lower()
    if not any(
        marker in lower
        for marker in (
            "mp.weixin.qq.com",
            "wemedia",
            "09-wemedia",
            "文章素材库",
            "微信草稿箱",
            "md2wechat",
            "create_draft",
            "mmbiz.qpic.cn",
        )
    ):
        return None

    stage_status = {
        "material_ingested": "unknown",
        "images_ready": "unknown",
        "draft_generated": "unknown",
        "wechat_draft_created": "unknown",
        "quality_checked": "unknown",
    }
    failures = []
    stage = "unknown"

    def fail(stage_name, key, reason):
        nonlocal stage
        if stage == "unknown":
            stage = stage_name
        stage_status[key] = "failed"
        failures.append(reason)

    if "could not resolve host: mp.weixin.qq.com" in lower or "dns resolution failed" in lower:
        fail("fetch_source_article", "material_ingested", "mp.weixin.qq.com DNS resolution failed")
    if "未下载到 wemedia" in text or "no cached article body" in lower:
        fail("fetch_source_article", "material_ingested", "未下载到 wemedia")
    if "正文图片不足" in text or re.search(r"正文图片数量\s*`?0`?", text):
        fail("prepare_images", "images_ready", "正文图片不足")
    if "未生成 draft json" in lower or "没有 draft json" in lower or "未生成 draft" in text:
        fail("generate_draft", "draft_generated", "draft JSON/HTML 未生成")
    if (
        "未写入微信草稿箱" in text
        or "未调用 `create_draft`" in text
        or "未调用 create_draft" in text
        or "无 `media_id`" in text
        or "无 media_id" in text
        or "没有拿到 media_id" in text
    ):
        fail("create_wechat_draft", "wechat_draft_created", "未写入微信草稿箱")
    if "质量门禁：未运行" in text or ("quality gate" in lower and "fail" in lower):
        fail("quality_gate", "quality_checked", "质量门禁未通过或未运行")

    if failures:
        return {
            "kind": "external_article_conductor_fallback_verdict",
            "status": "workflow_failed",
            "stage": stage,
            "stage_status": stage_status,
            "reason": "；".join(dict.fromkeys(failures)),
            "business_success": False,
        }
    if re.search(r"(create_draft|微信草稿箱|draft).{0,240}(media_id|errcode[\"']?\s*:\s*0|已写入|写入成功)", lower, re.S):
        stage_status["wechat_draft_created"] = "passed"
    if "mmbiz.qpic.cn" in lower or "image-upload-map.json" in lower:
        stage_status["images_ready"] = "passed"
    if "quality gate" in lower and any(token in lower for token in ("passed", "通过", "0 warnings", "0 errors")):
        stage_status["quality_checked"] = "passed"
    if stage_status["wechat_draft_created"] == "passed" and stage_status["quality_checked"] == "passed":
        return {
            "kind": "external_article_conductor_fallback_verdict",
            "status": "wechat_draft_created",
            "stage": "quality_checked",
            "stage_status": stage_status,
            "reason": "微信草稿已创建且质量门禁通过",
            "business_success": True,
        }
    return {
        "kind": "external_article_conductor_fallback_verdict",
        "status": "needs_review",
        "stage": stage,
        "stage_status": stage_status,
        "reason": "未检测到明确业务失败，但也未证明草稿箱完成",
        "business_success": False,
    }


def conductor_result_verdict(result_path: Path):
    if not result_path.exists():
        return None, None
    try:
        result = json.loads(result_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {
            "kind": "codex_conductor_task",
            "status": "workflow_failed",
            "stage": "read_conductor_result",
            "stage_status": {"conductor_result": "failed"},
            "reason": f"conductor_result.json could not be parsed: {exc}",
            "business_success": False,
        }, None
    if not isinstance(result, dict):
        return {
            "kind": "codex_conductor_task",
            "status": "workflow_failed",
            "stage": "read_conductor_result",
            "stage_status": {"conductor_result": "failed"},
            "reason": "conductor_result.json is not an object",
            "business_success": False,
        }, result

    status = str(result.get("status") or "").strip() or "needs_review"
    business_success = result.get("business_success")
    artifacts = result.get("artifacts") if isinstance(result.get("artifacts"), dict) else {}
    validation = result.get("validation") if isinstance(result.get("validation"), dict) else {}
    reason = str(result.get("reason") or result.get("summary") or status).strip()
    stage = str(result.get("current_stage") or result.get("stage") or status).strip()
    stage_status = result.get("stage_status") if isinstance(result.get("stage_status"), dict) else {}
    proof_path = artifacts.get("wechat_api_proof") or artifacts.get("draft_get_proof")
    draft_box_api_verified = bool(validation.get("draft_box_api_verified") or artifacts.get("draft_box_api_verified"))
    if proof_path and not draft_box_api_verified:
        try:
            proof = json.loads(Path(str(proof_path)).read_text(encoding="utf-8"))
            draft_box_api_verified = bool(proof.get("success") is True and proof.get("draft_box_api_verified") is True)
        except Exception:
            draft_box_api_verified = False
    if (
        str(result.get("kind") or "") == "external_article_to_wechat_draft"
        and (business_success is True or status in {"completed", "success", "wechat_draft_created", "draft_created"})
        and not draft_box_api_verified
        and not any(
            artifacts.get(key)
            for key in (
                "browser_proof",
                "browser_proof_path",
                "draft_box_screenshot",
                "draft_box_screenshot_path",
                "draft_box_verified",
                "ui_verified",
            )
        )
        and not result.get("draft_box_verified")
        and not result.get("ui_verified")
    ):
        stage_status = dict(stage_status)
        stage_status.setdefault("create_draft", "passed")
        stage_status["draft_box_api_verification"] = "blocked"
        artifacts = dict(artifacts)
        artifacts["browser_proof_required"] = False
        artifacts["browser_proof_reason"] = artifacts.get("browser_proof_reason") or "Draft-box UI verification is optional; draft/get API verification is the completion proof."
        return {
            "kind": str(result.get("kind") or "codex_conductor_task"),
            "status": "draft_created_ui_unverified",
            "stage": "draft_box_api_verification",
            "stage_status": stage_status,
            "reason": "create_draft returned a draft artifact, but draft/get API verification is missing or blocked.",
            "business_success": False,
            "artifacts": artifacts,
            "source": str(result_path),
        }, result
    if business_success is True:
        return {
            "kind": str(result.get("kind") or "codex_conductor_task"),
            "status": status,
            "stage": stage,
            "stage_status": stage_status,
            "reason": reason or "Conductor result reports business success",
            "business_success": True,
            "artifacts": artifacts,
            "source": str(result_path),
        }, result
    return {
        "kind": str(result.get("kind") or "codex_conductor_task"),
        "status": status if status not in {"completed_pending_review"} else "needs_review",
        "stage": stage,
        "stage_status": stage_status,
        "reason": reason or "Conductor result does not prove business success",
        "business_success": False,
        "artifacts": artifacts,
        "source": str(result_path),
    }, result


last_event = {}
if events_path.exists():
    try:
        for line in events_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if isinstance(obj, dict):
                last_event = obj
    except Exception:
        last_event = {}

thread_binding = {}
if thread_path.exists():
    try:
        thread_binding = json.loads(thread_path.read_text(encoding="utf-8"))
    except Exception:
        thread_binding = {}

stderr_tail = read_tail(stderr_path)
stdout_tail = read_tail(stdout_path)
final_text = ""
if final_path.exists():
    try:
        final_text = final_path.read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        final_text = ""
conductor_workflow, conductor_result = conductor_result_verdict(conductor_result_path)
if conductor_workflow is not None:
    workflow = conductor_workflow
elif conductor_task_path.exists():
    workflow = {
        "kind": "codex_conductor_task",
        "status": "workflow_failed",
        "stage": "write_conductor_result",
        "stage_status": {"conductor_result": "missing"},
        "reason": "Conductor task was created but conductor_result.json is missing; exit code alone does not prove business success.",
        "business_success": False,
    }
else:
    workflow = external_article_fallback_verdict(final_text, stderr_tail)
last_summary = str(last_event.get("summary") or "").strip()
last_type = str(last_event.get("codex_event_type") or last_event.get("type") or "").strip()
codex_thread_id = thread_binding.get("codex_thread_id") or data.get("codex_thread_id") or last_event.get("codex_thread_id")
codex_session_id = (
    thread_binding.get("codex_session_id")
    or data.get("codex_session_id")
    or last_event.get("codex_session_id")
    or codex_thread_id
)

reason_parts = []
if last_summary:
    reason_parts.append(last_summary)
if stderr_tail:
    reason_parts.append(stderr_tail.splitlines()[-1].strip())
if not reason_parts:
    reason_parts.append(f"harness exited with code {code}")
reason = " | ".join(part for part in reason_parts if part)[:800]

data["process_status"] = "completed_pending_review" if code == 0 else "blocked"
data["workflow"] = workflow
data["status"] = (
    "completed_pending_review"
    if code == 0 and not (workflow and not workflow.get("business_success"))
    else (workflow.get("status") if workflow else "blocked")
)
data["exit_code"] = code
data["finished_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data["exec_dir"] = exec_dir
data["harness"] = harness
data["run_id"] = run_id
data["handoff_id"] = handoff_id
data["packet_id"] = packet_id
data["final_file"] = str(final_path)
data["stdout_log"] = str(stdout_path)
data["stderr_log"] = str(stderr_path)
data["events_jsonl"] = str(events_path)
data["codex_thread_binding"] = str(thread_path)
data["conductor_task"] = str(conductor_task_path)
data["conductor_events"] = str(conductor_events_path)
data["conductor_result"] = str(conductor_result_path)
data["conductor"] = {
    "task_json": str(conductor_task_path),
    "events_jsonl": str(conductor_events_path),
    "result_json": str(conductor_result_path),
    "has_task": conductor_task_path.exists(),
    "has_result": conductor_result_path.exists(),
    "result": conductor_result,
}
data["codex_thread_id"] = codex_thread_id
data["codex_session_id"] = codex_session_id
data["last_event_type"] = last_type or None
data["last_event_summary"] = last_summary or None
data["runner_summary"] = str((workflow or {}).get("reason") or reason)
data["diagnostics"] = {
    "stderr_tail": stderr_tail,
    "stdout_tail": stdout_tail,
    "last_event": last_event,
    "thread_binding": thread_binding,
}

if code != 0 and not final_text:
    final_path.parent.mkdir(parents=True, exist_ok=True)
    final_path.write_text(
        "\n".join(
            [
                "H.A.R.V.I.S. harness failed or was blocked.",
                "",
                f"run_id: {run_id}",
                f"handoff_id: {handoff_id}",
                f"packet_id: {packet_id}",
                f"harness: {harness}",
                f"exit_code: {code}",
                f"codex_thread_id: {codex_thread_id or 'not-started'}",
                f"events_jsonl: {events_path}",
                f"stderr_log: {stderr_path}",
                "",
                "Reason:",
                reason,
                "",
                "Last event:",
                json.dumps(last_event, ensure_ascii=False, indent=2) if last_event else "none",
                "",
                "Stderr tail:",
                stderr_tail or "none",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
if workflow:
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with events_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({
            "schemaVersion": "harvis.workflow-events.v0",
            "observed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "handoff_id": handoff_id,
            "run_id": run_id,
            "packet_id": packet_id,
            "harness": harness,
            "codex_event_type": "workflow.verdict",
            "type": "workflow.verdict",
            "summary": workflow.get("reason"),
            "workflow": workflow,
        }, ensure_ascii=False, separators=(",", ":")) + "\n")
print(reason)
PY
)"

EFFECTIVE_STATUS="$(python3 - "$STATUS_JSON" <<'PY'
import json
import sys
from pathlib import Path
try:
    print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("status") or "")
except Exception:
    print("")
PY
)"

if [[ "$EXIT_CODE" -eq 0 && ( "$EFFECTIVE_STATUS" == "completed_pending_review" || "$EFFECTIVE_STATUS" == "wechat_draft_created" || "$EFFECTIVE_STATUS" == "draft_created_ui_unverified" || "$EFFECTIVE_STATUS" == "draft_created_api_verified_ui_unverified" ) ]]; then
  if [[ "$EFFECTIVE_STATUS" == "completed_pending_review" ]]; then
    HANDOFF_SUMMARY="Harness completed; reviewer acceptance is required before done. $RUNNER_SUMMARY exec_dir=$EXEC_DIR"
  elif [[ "$EFFECTIVE_STATUS" == "wechat_draft_created" ]]; then
    HANDOFF_SUMMARY="Conductor created and API-verified a WeChat draft. $RUNNER_SUMMARY exec_dir=$EXEC_DIR"
  else
    HANDOFF_SUMMARY="Conductor created a WeChat draft artifact, but draft/get API proof is still pending. status=$EFFECTIVE_STATUS; $RUNNER_SUMMARY exec_dir=$EXEC_DIR"
  fi
  "$HARVIS_CLI" agent-room --root "$ROOT" handoff-status \
    --handoff-id "$HANDOFF_ID" \
    --state reviewing \
    --summary "$HANDOFF_SUMMARY" \
    --updated-by "$RUNNER_ID" \
    --result-path "$RESULT_REL" \
    --exit-code "$EXIT_CODE" >/dev/null
  if [[ "$AUTO_REVIEW_DRY_RUN" -eq 1 && "$EFFECTIVE_STATUS" == "completed_pending_review" ]]; then
    REVIEW_JSON="$EXEC_DIR/reviewer-dry-run.json"
    "$HARVIS_CLI" agent-room --root "$ROOT" handoff-review \
      --handoff-id "$HANDOFF_ID" \
      --decision approve \
      --reviewer "${RUNNER_ID}:reviewer-dry-run" \
      --notes "Rule-based auto-review dry-run accepted a successful harness result. No model call was made." >"$REVIEW_JSON"
    python3 - "$STATUS_JSON" "$REVIEW_JSON" <<'PY'
import json
import sys
from pathlib import Path

status_path = Path(sys.argv[1])
review_path = Path(sys.argv[2])
data = json.loads(status_path.read_text(encoding="utf-8"))
review = json.loads(review_path.read_text(encoding="utf-8"))
data["reviewer_dry_run"] = {
    "enabled": True,
    "decision": review.get("review", {}).get("decision"),
    "target_state": review.get("review", {}).get("target_state"),
    "reviewer": review.get("review", {}).get("reviewer"),
}
status_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  fi
else
  "$HARVIS_CLI" agent-room --root "$ROOT" handoff-status \
    --handoff-id "$HANDOFF_ID" \
    --state blocked \
    --summary "Harness did not satisfy workflow acceptance. status=${EFFECTIVE_STATUS:-blocked}; exit_code=$EXIT_CODE. $RUNNER_SUMMARY exec_dir=$EXEC_DIR" \
    --updated-by "$RUNNER_ID" \
    --result-path "$RESULT_REL" \
    --exit-code "$EXIT_CODE" >/dev/null
fi

COMPLETION_CARD_JSON="$EXEC_DIR/completion-card.json"
python3 - "$STATUS_JSON" "$COMPLETION_CARD_JSON" "$ROOT" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urljoin, urlparse, urlunparse

status_path = Path(sys.argv[1])
card_path = Path(sys.argv[2])
root = sys.argv[3]

try:
    status = json.loads(status_path.read_text(encoding="utf-8"))
except Exception:
    status = {}


def safe_mobile_url() -> str:
    raw = (
        os.environ.get("HARVIS_MOBILE_WEBUI_URL")
        or os.environ.get("HARVIS_MOBILE_BASE_URL")
        or os.environ.get("HARVIS_PUBLIC_BASE_URL")
        or os.environ.get("HARVIS_WORKBENCH_PUBLIC_URL")
        or os.environ.get("HARVIS_NGROK_URL")
        or os.environ.get("HARVIS_WORKBENCH_URL")
        or ""
    ).strip()
    if not raw:
        return ""
    parsed = urlparse(raw)
    host = (parsed.hostname or "").lower()
    if parsed.scheme not in {"http", "https"} or not host or host == "localhost" or host.startswith("127."):
        return ""
    path = parsed.path or "/"
    if not path.rstrip("/").endswith("/studio/mobile"):
        path = urljoin(path.rstrip("/") + "/", "studio/mobile/")
    return urlunparse((parsed.scheme, parsed.netloc, path, "", parsed.query, f"root={quote(root, safe='')}"))


def read_excerpt(value: str, limit: int = 900) -> str:
    path = Path(value) if value else Path()
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()[:limit]
    except Exception:
        return ""


def summarize_workflow_for_card(workflow):
    if not isinstance(workflow, dict):
        return None
    artifacts = workflow.get("artifacts") if isinstance(workflow.get("artifacts"), dict) else {}
    return {
        "status": workflow.get("status"),
        "stage": workflow.get("stage") or workflow.get("current_stage"),
        "business_success": bool(workflow.get("business_success")),
        "reason": workflow.get("reason"),
        "media_id": artifacts.get("media_id") or artifacts.get("draft_id"),
        "image_count": artifacts.get("image_count") or artifacts.get("wechat_image_url_count"),
        "material_dir": artifacts.get("material_dir"),
        "article_path": artifacts.get("article_path") or artifacts.get("article_md"),
        "draft_json": artifacts.get("draft_json"),
        "wechat_api_proof": artifacts.get("wechat_api_proof") or artifacts.get("draft_get_proof"),
        "draft_box_api_verified": bool(
            workflow.get("validation", {}).get("draft_box_api_verified")
            if isinstance(workflow.get("validation"), dict)
            else artifacts.get("draft_box_api_verified")
        ),
        "browser_proof_required": bool(artifacts.get("browser_proof_required")),
        "browser_proof_reason": artifacts.get("browser_proof_reason"),
    }


if not card_path.exists():
    exit_code = status.get("exit_code")
    workflow = status.get("workflow") if isinstance(status.get("workflow"), dict) else None
    partial_statuses = {"draft_created_ui_unverified", "draft_created_api_verified_ui_unverified"}
    partial = bool(workflow and workflow.get("status") in partial_statuses)
    ok = exit_code == 0 and not partial and not (workflow and not workflow.get("business_success"))
    final_file = str(status.get("final_file") or "")
    stderr_log = str(status.get("stderr_log") or "")
    events_jsonl = str(status.get("events_jsonl") or "")
    thread_json = str(status.get("codex_thread_binding") or "")
    reviewer = status.get("reviewer_dry_run") if isinstance(status.get("reviewer_dry_run"), dict) else {}
    last_event_type = status.get("last_event_type") or ("adapter.completed" if ok else "adapter.failed")
    runner_summary = str(status.get("runner_summary") or "").strip()
    final_summary = read_excerpt(final_file)
    failure = None
    if not ok and not partial:
        failure = {
            "reason": (workflow or {}).get("reason") or runner_summary or f"harness exited with code {exit_code}",
            "exit_code": exit_code,
            "last_event_type": last_event_type,
            "last_event_summary": status.get("last_event_summary") or runner_summary,
            "stderr_excerpt": read_excerpt(stderr_log),
        }
    card = {
        "schemaVersion": "harvis.completion-card.v0",
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "title": (
            "H.A.R.V.I.S. 任务完成"
            if ok
            else ("H.A.R.V.I.S. 草稿已创建，待 API 验证" if partial else "H.A.R.V.I.S. 任务失败/阻塞")
        ),
        "status": "completed_pending_review" if ok else ((workflow or {}).get("status") or "failed_or_blocked"),
        "workflow": workflow,
        "workflow_summary": summarize_workflow_for_card(workflow),
        "exit_code": exit_code,
        "task_id": status.get("task_id"),
        "packet_id": status.get("packet_id"),
        "handoff_id": status.get("handoff_id"),
        "run_id": status.get("run_id"),
        "harness": status.get("harness"),
        "model": status.get("model_id"),
        "codex_thread_id": status.get("codex_thread_id"),
        "codex_session_id": status.get("codex_session_id"),
        "summary": runner_summary if partial else (final_summary or runner_summary),
        "failure": failure,
        "reviewer": {
            "state": "dry_run" if reviewer else ("pending_review" if ok else ("pending_api_verification" if partial else "blocked_before_review")),
            "decision": reviewer.get("decision"),
            "target_state": reviewer.get("target_state"),
            "reviewer": reviewer.get("reviewer"),
            "conclusion": "公众号草稿已创建；还缺 draft/get API 证明。" if partial else None,
        },
        "paths": {
            "exec_dir": status.get("exec_dir"),
            "events_jsonl": events_jsonl,
            "final_file": final_file,
            "stdout_log": status.get("stdout_log"),
            "stderr_log": stderr_log,
            "status_json": str(status_path),
            "thread_json": thread_json,
        },
        "next_step": (
            "Reviewer accepted dry-run result."
            if ok and reviewer
            else (
                "Review result before marking done."
                if ok
                else (
                    "补充公众号草稿箱 draft/get API 验证；确认 media_id 可查询后再标记完成。"
                    if (workflow or {}).get("status") in {"draft_created_ui_unverified", "draft_created_api_verified_ui_unverified"}
                    else "修复 workflow 阶段失败后重跑；只有 conductor_result 业务验收通过才算完成。"
                )
            )
        ),
        "mobile_workbench_url": safe_mobile_url(),
    }
    actions = []
    if card["mobile_workbench_url"]:
        actions.append({"type": "open_url", "label": "打开移动工作台", "url": card["mobile_workbench_url"]})
    actions.append({"type": "open_path", "label": "查看日志", "path": str(status.get("exec_dir") or "")})
    card["actions"] = actions
    card_path.write_text(json.dumps(card, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

status["completion_card_json"] = str(card_path)
status_path.write_text(json.dumps(status, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

echo "$EXEC_DIR"
exit "$EXIT_CODE"
