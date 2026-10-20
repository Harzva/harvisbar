#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harvis-http-rust-parity.XXXXXX")"
PORT="${HARVIS_HTTP_RUST_PARITY_PORT:-$((23000 + RANDOM % 20000))}"
TOKEN="harvis-rust-parity-token"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

ROOT="$TMP_ROOT/workspace"
PROFILE="$TMP_ROOT/profile"
HARVIS_RS=(cargo run --quiet --manifest-path "$PLUGIN_ROOT/Cargo.toml" -p harvis-cli --)

"${HARVIS_RS[@]}" init-workspace --root "$ROOT" >/dev/null
"${HARVIS_RS[@]}" init-profile --profile-root "$PROFILE" >/dev/null
cat >"$ROOT/.harvis/inbox.md" <<'EOF'
@harvis Review this Rust HTTP parity fixture.
@harvis token=abc should be blocked and redacted.
EOF
"${HARVIS_RS[@]}" run-tick --root "$ROOT" --profile-root "$PROFILE" --once >/dev/null

"${HARVIS_RS[@]}" http \
  --host 127.0.0.1 \
  --port "$PORT" \
  --plugin-root "$PLUGIN_ROOT" \
  --auth-token "$TOKEN" >"$TMP_ROOT/server.stdout" 2>"$TMP_ROOT/server.stderr" &
SERVER_PID="$!"

python3 - "$PORT" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
deadline = time.time() + 20
while time.time() < deadline:
    with socket.socket() as sock:
        sock.settimeout(0.5)
        if sock.connect_ex(("127.0.0.1", port)) == 0:
            raise SystemExit(0)
    time.sleep(0.1)
raise SystemExit("server did not start")
PY

python3 - "$ROOT" "$PROFILE" "$PORT" "$TOKEN" "$PLUGIN_ROOT" <<'PY'
import json
import subprocess
import sys
import urllib.parse
from pathlib import Path

root, profile, port, token, plugin_root = sys.argv[1:]
base = f"http://127.0.0.1:{port}"

def request(path, *, auth=True, method="GET", body=None, raw=False):
    cmd = ["curl", "-fsS"]
    if auth:
        cmd += ["-H", f"Authorization: Bearer {token}"]
    if method == "POST":
        cmd += ["-H", "Content-Type: application/json", "-X", "POST", "--data", json.dumps(body or {})]
    cmd.append(base + path)
    output = subprocess.check_output(cmd, text=not raw)
    return output if raw else json.loads(output)

def qs(**kwargs):
    return "?" + urllib.parse.urlencode(kwargs)

health = request("/health", auth=False)
assert health["ok"] is True
assert health["endpoint"] == "/health"
assert health["data"]["api_version"] == "v0.40-rust-alpha"
assert health["data"]["auth_required"] is True

unauth_code = subprocess.check_output(
    [
        "curl",
        "-s",
        "-o",
        str(Path(root) / ".harvis" / "unauth.json"),
        "-w",
        "%{http_code}",
        base + "/bar/status" + qs(root=root, profile_root=profile),
    ],
    text=True,
)
assert unauth_code == "401", unauth_code

bar = request("/bar/status" + qs(root=root, profile_root=profile, full="true"))
assert bar["ok"] is True
assert bar["data"]["schemaVersion"] == "harvis.bar-status.v0"
assert bar["data"]["safeForHarvisBar"] is True
assert bar["data"]["serviceHealth"]["http"] == "running"
assert bar["data"]["safety"]["includesLocalAbsolutePaths"] is False
assert "runtime" in bar["data"] and "work" in bar["data"]
rendered_bar = json.dumps(bar["data"], sort_keys=True)
for marker in [root, profile, "/Users/", "/Volumes/"]:
    assert marker not in rendered_bar, "bar status leaked local absolute path"

status = request("/status" + qs(root=root, profile_root=profile))
assert status["ok"] is True
assert status["data"]["status"]["agent"] == "H.A.R.V.I.S."

packets = request("/packets" + qs(root=root, limit=10))
assert packets["ok"] is True
assert len(packets["data"]["packets"]) == 2

runs = request("/runs" + qs(root=root, limit=10))
assert runs["ok"] is True
assert runs["data"]["run_count"] == 2
run_id = runs["data"]["runs"][0]["run_id"]

lark_actions_path = Path(root) / ".harvis" / "lark" / "card-actions.jsonl"
lark_actions_path.parent.mkdir(parents=True, exist_ok=True)
lark_actions_path.write_text(
    "\n".join(
        [
            json.dumps(
                {
                    "schemaVersion": "harvis.lark-card-action.v0",
                    "observed_at": "2026-06-29T00:00:00Z",
                    "event_key": "card.action.trigger",
                    "action": "status_card",
                    "message_id": "om_synthetic_parity",
                    "chat_id": "oc_parity",
                    "dry_run": True,
                    "no_reply": False,
                    "payload": {"action_value": {"action": "status_card", "run_id": run_id}},
                },
                ensure_ascii=False,
            ),
            json.dumps(
                {
                    "schemaVersion": "harvis.lark-card-action.v0",
                    "observed_at": "2026-06-29T00:01:00Z",
                    "event_key": "card.action.trigger",
                    "action": "status_card",
                    "message_id": "om_real_parity",
                    "chat_id": "oc_parity",
                    "dry_run": False,
                    "no_reply": False,
                    "payload": {"action_value": {"action": "status_card", "run_id": run_id}},
                },
                ensure_ascii=False,
            ),
        ]
    )
    + "\n",
    encoding="utf-8",
)

lark_actions = request("/lark/card-actions" + qs(root=root, limit=10))
assert lark_actions["ok"] is True
assert lark_actions["data"]["count"] == 2
assert lark_actions["data"]["real_clicks"] == 1
assert lark_actions["data"]["synthetic_clicks"] == 1
assert lark_actions["data"]["actions"][0]["message_id"] == "om_real_parity"

workbench = request(
    "/prepare-workbench",
    method="POST",
    body={"root": root, "profile_root": profile, "limit": 2},
)
assert workbench["ok"] is True
assert workbench["data"]["packet_count"] == 2
for item in workbench["data"]["prepared"]:
    for rel_path in item["outputs"].values():
        assert (Path(root) / rel_path).exists(), f"missing workbench output: {rel_path}"

harnesses = request("/agent-harnesses/status")
assert harnesses["ok"] is True
assert harnesses["data"]["schemaVersion"] == "harvis.agent-harnesses.v0"
assert harnesses["data"]["includesModelCalls"] is False

hub = request("/hub/status")
assert hub["ok"] is True
assert hub["data"]["redacted"] is True
llmwiki = request("/hub/llmwiki/status")
assert llmwiki["ok"] is True
assert llmwiki["data"]["includesLocalAbsolutePaths"] is False

repo_map = Path(root) / ".harvis" / "repoatlas-local-address-map.json"
local_root = Path(root) / "local" / "repos"
local_root.mkdir(parents=True, exist_ok=True)
repo_map.write_text(
    json.dumps(
        {
            "generatedAt": "2026-06-24T00:00:00+00:00",
            "summary": {
                "remoteCount": 2,
                "localRepoCount": 1,
                "matchedRemoteCount": 1,
                "missingLocalCount": 1,
                "attentionCount": 1,
            },
            "repositories": [
                {
                    "repoKey": "harzva/mobilecode",
                    "nameWithOwner": "Harzva/mobilecode",
                    "url": "https://github.com/Harzva/mobilecode",
                    "accountAlias": "Harzva",
                    "accountLogin": "Harzva",
                    "localExists": True,
                    "localPaths": [str(local_root / "MobileCode")],
                    "localStatus": "dirty",
                    "dirty": True,
                    "ahead": 0,
                    "behind": 0,
                },
                {
                    "repoKey": "harzva/missing",
                    "nameWithOwner": "Harzva/missing",
                    "url": "https://github.com/Harzva/missing",
                    "accountAlias": "Harzva",
                    "accountLogin": "Harzva",
                    "localExists": False,
                    "localPaths": [],
                    "localStatus": "no-local-copy",
                    "dirty": False,
                    "ahead": 0,
                    "behind": 0,
                },
            ],
        },
        indent=2,
    ),
    encoding="utf-8",
)
repo_status = request("/repoatlas/status" + qs(map_path=str(repo_map)))
assert repo_status["ok"] is True
assert repo_status["data"]["repoatlas"] == "available"
assert repo_status["data"]["includesLocalAbsolutePaths"] is False
repo_find = request("/repoatlas/find" + qs(query="Harzva/mobilecode", map_path=str(repo_map)))
assert repo_find["ok"] is True
assert repo_find["data"]["count"] == 1
repo_missing = request("/repoatlas/missing" + qs(map_path=str(repo_map)))
assert repo_missing["ok"] is True
assert repo_missing["data"]["count"] == 1
repo_attention = request("/repoatlas/attention" + qs(map_path=str(repo_map)))
assert repo_attention["ok"] is True
assert repo_attention["data"]["count"] == 1
rendered_repo = json.dumps(
    [repo_status["data"], repo_find["data"], repo_missing["data"], repo_attention["data"]],
    sort_keys=True,
)
for marker in [root, profile, "/Users/", "/Volumes/"]:
    assert marker not in rendered_repo, "RepoAtlas redacted route leaked local absolute path"

persona_init = request("/persona/init", method="POST", body={"root": root})
assert persona_init["ok"] is True
assert len(persona_init["data"]["memory_vaults"]) >= 1
assert len(persona_init["data"]["persona_cards"]) >= 2
vault_id = persona_init["data"]["memory_vaults"][0]["vault_id"]
persona_id = persona_init["data"]["persona_cards"][0]["persona_id"]

created_card = request(
    "/persona/create-card",
    method="POST",
    body={"root": root, "display_name": "Parity Specialist", "visual_asset_id": "harvis-persona-system"},
)
assert created_card["ok"] is True
assert created_card["data"]["persona_id"].startswith("persona_")

updated_card = request(
    "/persona/update-card",
    method="POST",
    body={
        "root": root,
        "persona_id": persona_id,
        "tone": {"warmth": 8, "directness": 7, "humor": 3, "detail": 8},
        "decision_style": {"evidence_first": True, "prefer_verification": True, "risk_tolerance": "medium"},
        "behavior_rules": ["Inspect context before acting.", "Keep runtime changes auditable."],
    },
)
assert updated_card["ok"] is True
assert updated_card["data"]["new_traits_require_human_review"] is True

candidate = request(
    "/personality-candidate",
    method="POST",
    body={
        "root": root,
        "target_persona_id": persona_id,
        "trait": "Prefers concise status plus the next concrete action.",
        "source_type": "rust-http-parity",
        "trait_type": "behavior_rule",
        "confidence_percent": 65,
    },
)
assert candidate["ok"] is True
assert candidate["data"]["status"] == "pending_review"

candidate_decision = request(
    "/personality-candidate/decide",
    method="POST",
    body={
        "root": root,
        "candidate_id": candidate["data"]["candidate_id"],
        "decision": "accepted",
        "decided_by": "rust-http-parity",
    },
)
assert candidate_decision["ok"] is True
assert candidate_decision["data"]["candidate"]["status"] == "accepted"

twin = request(
    "/persona/create-twin",
    method="POST",
    body={
        "root": root,
        "display_name": "Parity Twin",
        "memory_vault_id": vault_id,
        "persona_card_id": persona_id,
        "permissions": {"run_tools": "approval_required", "write_files": False, "network": False},
    },
)
assert twin["ok"] is True
assert twin["data"]["permissions"]["run_tools"] == "approval_required"

persona = request("/persona" + qs(root=root, limit=100))
assert persona["ok"] is True
assert len(persona["data"]["twin_instances"]) >= 2

room_init = request("/agent-room/init", method="POST", body={"root": root})
assert room_init["ok"] is True
assert room_init["data"]["agent_room_version"].startswith("v")

topic = request(
    "/agent-room/topic",
    method="POST",
    body={"root": root, "title": "Rust HTTP parity", "goal": "Keep Studio routes native Rust.", "created_by": "rust-http-parity"},
)
assert topic["ok"] is True
topic_id = topic["data"]["topic_id"]

event = request(
    "/agent-room/event",
    method="POST",
    body={"root": root, "topic_id": topic_id, "event_type": "parity.checked", "content": "Event path works."},
)
assert event["ok"] is True
assert event["data"]["event_type"] == "parity.checked"

message = request(
    "/agent-room/message",
    method="POST",
    body={"root": root, "topic_id": topic_id, "content": "Message path works."},
)
assert message["ok"] is True

router_task = request(
    "/router/message",
    method="POST",
    body={
        "root": root,
        "transport": "feishu",
        "sender": "rust-http-parity",
        "text": "任务：找到 just-ddl 仓库并检查失败原因，不要执行",
        "chat_id": "parity-chat",
        "message_id": "parity-router-task",
    },
)
assert router_task["ok"] is True
assert router_task["data"]["intent"] == "task_enqueue"
assert router_task["data"]["workbench_task"]["status"] == "waiting_approval"
router_conversations = request(
    "/agent-room/conversations" + qs(root=root, transport="feishu", chat_id="parity-chat", limit=10)
)
assert router_conversations["ok"] is True
assert router_conversations["data"]["conversation_count"] == 1
assert router_conversations["data"]["conversations"][0]["intent"] == "task_enqueue"
assert router_conversations["data"]["conversations"][0]["packet_id"] == router_task["data"]["workbench_task"]["packet_id"]

router_status = request(
    "/router/message",
    method="POST",
    body={
        "root": root,
        "transport": "feishu",
        "sender": "rust-http-parity",
        "text": "有答案了吗？",
        "chat_id": "parity-chat",
        "message_id": "parity-router-status",
    },
)
assert router_status["ok"] is True
assert router_status["data"]["intent"] == "status_query"
assert router_status["data"]["route_state"] == "status"
assert "workspace_state" in router_status["data"]
assert "recent_executions" in router_status["data"]
assert "H.A.R.V.I.S. 当前进展" in router_status["data"]["reply_text"]
packet_id = router_task["data"]["workbench_task"]["packet_id"]

router_item_status = request(
    "/router/message",
    method="POST",
    body={
        "root": root,
        "transport": "feishu",
        "sender": "rust-http-parity",
        "text": f"{packet_id} 进展如何",
        "chat_id": "parity-chat",
        "message_id": "parity-router-item-status",
    },
)
assert router_item_status["ok"] is True
assert router_item_status["data"]["intent"] == "status_query"
assert router_item_status["data"]["status_detail"]["matched"] is True
assert router_item_status["data"]["status_detail"]["target"]["kind"] == "packet"
assert router_item_status["data"]["status_detail"]["target"]["id"] == packet_id
assert "H.A.R.V.I.S. 单项进展" in router_item_status["data"]["reply_text"]

agent_status = request(
    "/agent/step",
    method="POST",
    body={
        "root": root,
        "channel": "webview",
        "sender": "rust-http-parity",
        "message": "正在运行 codex 线程有哪几个？",
        "chat_id": "parity-webview",
        "message_id": "parity-agent-status",
        "chair_dry_run": True,
    },
)
assert agent_status["ok"] is True
assert agent_status["data"]["intent"] == "status_query"
assert agent_status["data"]["next_expected_action"] == "inspect_status"
assert "workspace_state" in agent_status["data"]
assert "recent_executions" in agent_status["data"]
assert "H.A.R.V.I.S. 当前进展" in agent_status["data"]["response_text"]

agent_item_status = request(
    "/agent/step",
    method="POST",
    body={
        "root": root,
        "channel": "webview",
        "sender": "rust-http-parity",
        "message": f"packet {packet_id} status",
        "chat_id": "parity-webview",
        "message_id": "parity-agent-item-status",
        "chair_dry_run": True,
    },
)
assert agent_item_status["ok"] is True
assert agent_item_status["data"]["intent"] == "status_query"
assert agent_item_status["data"]["status_detail"]["matched"] is True
assert agent_item_status["data"]["status_detail"]["target"]["kind"] == "packet"
assert agent_item_status["data"]["status_detail"]["target"]["id"] == packet_id
assert "H.A.R.V.I.S. 单项进展" in agent_item_status["data"]["response_text"]

room = request("/agent-room" + qs(root=root, limit=80))
assert room["ok"] is True
assert room["data"]["topics"]
assert room["data"]["messages"]

approval = request(
    "/request-approval",
    method="POST",
    body={
        "root": root,
        "run_id": run_id,
        "action_type": "write_file",
        "target": ".harvis/parity.txt",
        "reason": "HTTP parity approval record",
        "risk": "low",
    },
)
assert approval["ok"] is True
assert approval["data"]["status"] == "pending"

approvals = request("/approvals" + qs(root=root, status="pending", limit=50))
assert approvals["ok"] is True
assert approvals["data"]["approval_count"] >= 1

notification_check = request("/check-notifications", method="POST", body={"root": root, "write": True})
assert notification_check["ok"] is True
assert notification_check["data"]["candidate_count"] >= 1

notifications = request("/notifications" + qs(root=root, limit=50))
assert notifications["ok"] is True
assert notifications["data"]["notification_count"] >= 1

decided_approval = request(
    "/decide-approval",
    method="POST",
    body={
        "root": root,
        "approval_id": approval["data"]["approval_id"],
        "decision": "approved",
        "decided_by": "rust-http-parity",
        "notes": "Decision path works.",
    },
)
assert decided_approval["ok"] is True
assert decided_approval["data"]["status"] == "approved"

handoff = request(
    "/request-handoff",
    method="POST",
    body={
        "root": root,
        "run_id": run_id,
        "harness": "codex",
        "instruction": "Use this as a no-execution parity handoff.",
        "topic_id": topic_id,
    },
)
assert handoff["ok"] is True
assert handoff["data"]["handoff"]["state"] == "pending_harness"

handoffs = request("/handoffs" + qs(root=root, limit=40))
assert handoffs["ok"] is True
assert handoffs["data"]["handoff_count"] >= 1

snapshot = request(
    "/memory-snapshot",
    method="POST",
    body={"root": root, "profile_root": profile, "max_excerpt_chars": 240},
)
assert snapshot["ok"] is True
assert snapshot["data"]["candidate_signal_count"] >= 1

candidates = request("/memory-candidates" + qs(root=root, limit=10))
assert candidates["ok"] is True
assert candidates["data"]["candidate_count"] >= 1
rendered_candidates = json.dumps(candidates["data"], sort_keys=True)
for marker in [root, profile, "/Users/", "/Volumes/"]:
    assert marker not in rendered_candidates, "memory candidates leaked local absolute path"

graph = request("/knowledge-graph" + qs(root=root, max_files=10, max_nodes=20))
assert graph["ok"] is True
assert graph["data"]["read_only"] is True
assert graph["data"]["redacted"] is True

panel = request("/panel/", auth=False, raw=True).decode("utf-8")
assert "H.A.R.V.I.S." in panel

schema = request("/schemas/status.schema.json", auth=False)
assert isinstance(schema, dict)

print(json.dumps({"ok": True, "port": port, "routes_checked": 43}, indent=2))
PY

echo "rust http parity ok"
