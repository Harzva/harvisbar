#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="${HARVIS_WORKSPACE_ROOT:-$PWD}"
PUBLIC_URL="${HARVIS_PUBLIC_BASE_URL:-${HARVIS_WORKBENCH_PUBLIC_URL:-${HARVIS_NGROK_URL:-}}}"
LOCAL_URL="${HARVIS_LOCAL_BASE_URL:-http://127.0.0.1:8765}"
AUTH_TOKEN_FILE="${HARVIS_HTTP_AUTH_TOKEN_FILE:-$HOME/.harvis/auth/http.token}"
LARK_CLI="${LARK_CLI:-${HOME}/.local/bin/lark-cli}"
LARK_APP_ID="${HARVIS_LARK_APP_ID:-}"
VERIFY_MESSAGE_ID=""
STRICT=0
RUN_SMOKES=0

usage() {
  cat <<'USAGE'
Usage: harvis_codex_team_mvp_audit.sh [options]

Audits the current H.A.R.V.I.S. Codex JSONL + Team Harness MVP runtime evidence.
The script is read-only. It never sends Lark messages or executes task work.

Options:
  --root DIR              Workspace root. Default: current directory
  --public-url URL        Public workbench/ngrok base URL. Default: local URL.
  --local-url URL         Local HTTP base URL. Default: http://127.0.0.1:8765
  --auth-token-file FILE  HTTP bearer token file. Default: ~/.harvis/auth/http.token
  --lark-cli FILE         lark-cli path.
  --lark-app-id ID        Your Lark app id. Default: HARVIS_LARK_APP_ID, otherwise unset.
  --verify-message-id ID  Require a real click for this Lark card message id.
  --run-smokes            Run heavier local smoke scripts.
  --strict                Exit 1 when required MVP evidence is missing.
  -h, --help              Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      WORKSPACE_ROOT="${2:-}"
      shift 2
      ;;
    --public-url)
      PUBLIC_URL="${2:-}"
      shift 2
      ;;
    --local-url)
      LOCAL_URL="${2:-}"
      shift 2
      ;;
    --auth-token-file)
      AUTH_TOKEN_FILE="${2:-}"
      shift 2
      ;;
    --lark-cli)
      LARK_CLI="${2:-}"
      shift 2
      ;;
    --lark-app-id)
      LARK_APP_ID="${2:-}"
      shift 2
      ;;
    --verify-message-id)
      VERIFY_MESSAGE_ID="${2:-}"
      shift 2
      ;;
    --run-smokes)
      RUN_SMOKES=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
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

PUBLIC_URL="${PUBLIC_URL:-$LOCAL_URL}"

AUDIT_JSON="$(python3 - "$WORKSPACE_ROOT" "$PUBLIC_URL" "$LOCAL_URL" "$AUTH_TOKEN_FILE" "$LARK_CLI" "$LARK_APP_ID" "$VERIFY_MESSAGE_ID" "$RUN_SMOKES" "$PLUGIN_ROOT" <<'PY'
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

root = Path(sys.argv[1]).expanduser()
public_url = sys.argv[2].rstrip("/")
local_url = sys.argv[3].rstrip("/")
token_file = Path(sys.argv[4]).expanduser()
lark_cli = Path(sys.argv[5]).expanduser()
lark_app_id = sys.argv[6]
verify_message_id = sys.argv[7]
run_smokes = sys.argv[8] == "1"
plugin_root = Path(sys.argv[9]).resolve()

checks = []
warnings = []


def add_check(name, ok, **details):
    checks.append({"name": name, "ok": bool(ok), **details})


def parse_first_json_object(text):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    start = text.find("{")
    if start < 0:
        raise ValueError("no JSON object found in command output")

    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return json.loads(text[start : index + 1])
    raise ValueError("unterminated JSON object in command output")


def run_json(cmd, timeout=20):
    try:
        output = subprocess.check_output(cmd, text=True, stderr=subprocess.PIPE, timeout=timeout)
        return True, parse_first_json_object(output), ""
    except subprocess.CalledProcessError as exc:
        return False, None, (exc.stderr or exc.output or str(exc)).strip()
    except Exception as exc:
        return False, None, str(exc)


def http_json(base, path, token):
    url = f"{base}{path}"
    request = urllib.request.Request(url)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            return True, json.loads(response.read().decode("utf-8")), ""
    except urllib.error.HTTPError as exc:
        try:
            payload = exc.read().decode("utf-8")
        except Exception:
            payload = ""
        return False, None, f"HTTP {exc.code}: {payload[:300]}"
    except Exception as exc:
        return False, None, str(exc)


def http_text(base, path):
    url = f"{base}{path}"
    try:
        with urllib.request.urlopen(url, timeout=12) as response:
            return True, response.read().decode("utf-8", errors="replace"), ""
    except Exception as exc:
        return False, "", str(exc)


token = ""
if token_file.exists():
    token = token_file.read_text(encoding="utf-8", errors="replace").strip()
add_check("http_token_file", bool(token), token_file=str(token_file), token_present=bool(token))

root_q = urllib.parse.quote(str(root), safe="")
card_path = f"/lark/card-actions?root={root_q}&limit=20"
for label, base in [("local", local_url), ("public", public_url)]:
    ok, payload, error = http_json(base, card_path, token)
    data = (payload or {}).get("data") or {}
    add_check(
        f"{label}_card_actions_endpoint",
        ok and (payload or {}).get("ok") is True,
        base=base,
        count=data.get("count"),
        real_clicks=data.get("real_clicks"),
        synthetic_clicks=data.get("synthetic_clicks"),
        state_store=data.get("state_store"),
        error=error or None,
    )

ok, html, error = http_text(public_url, "/studio/mobile/")
add_check(
    "public_mobile_html",
    ok and "larkActionList" in html and "taskStatusList" in html,
    base=public_url,
    contains_lark_actions="larkActionList" in html if ok else False,
    error=error or None,
)

ok, js, error = http_text(public_url, "/studio/mobile.js")
add_check(
    "public_mobile_js",
    ok and "/lark/card-actions" in js and "renderLarkActions" in js,
    base=public_url,
    contains_card_actions="/lark/card-actions" in js if ok else False,
    error=error or None,
)

if lark_cli.exists():
    ok, status, error = run_json([str(lark_cli), "event", "status", "--json"], timeout=20)
    consumers = []
    if ok and isinstance(status, dict):
        for app in status.get("apps", []):
            if app.get("app_id") == lark_app_id:
                consumers.extend(app.get("consumers", []))
    keys = {item.get("event_key"): item for item in consumers}
    add_check(
        "lark_message_consumer",
        "im.message.receive_v1" in keys,
        event_key="im.message.receive_v1",
        pid=(keys.get("im.message.receive_v1") or {}).get("pid"),
        received=(keys.get("im.message.receive_v1") or {}).get("received"),
        dropped=(keys.get("im.message.receive_v1") or {}).get("dropped"),
        error=error or None,
    )
    add_check(
        "lark_card_action_consumer",
        "card.action.trigger" in keys,
        event_key="card.action.trigger",
        pid=(keys.get("card.action.trigger") or {}).get("pid"),
        received=(keys.get("card.action.trigger") or {}).get("received"),
        dropped=(keys.get("card.action.trigger") or {}).get("dropped"),
        error=error or None,
    )
else:
    add_check("lark_cli_exists", False, path=str(lark_cli))

ok, payload, error = http_json(public_url, card_path, token)
data = (payload or {}).get("data") or {}
actions = data.get("actions") if isinstance(data.get("actions"), list) else []
real_clicks = int(data.get("real_clicks") or 0)
matching_real = [
    item
    for item in actions
    if item.get("dry_run") is not True
    and (not verify_message_id or item.get("message_id") == verify_message_id)
]
add_check(
    "real_lark_card_click",
    bool(matching_real),
    required_message_id=verify_message_id or None,
    real_clicks=real_clicks,
    matching_real_clicks=len(matching_real),
    latest_real_observed_at=(matching_real[0].get("observed_at") if matching_real else None),
    error=error or None,
)

if run_smokes:
    smoke_commands = [
        ("mobile_static_smoke", [str(plugin_root / "scripts" / "harvis_mobile_webui_static_smoke.sh")]),
        ("http_rust_parity", [str(plugin_root / "scripts" / "harvis_http_rust_parity.sh")]),
    ]
    for name, cmd in smoke_commands:
        ok, payload, error = run_json(cmd, timeout=60)
        add_check(name, ok and bool(payload and payload.get("ok")), output=payload, error=error or None)
else:
    warnings.append("heavy smoke scripts skipped; pass --run-smokes to include them")

required = [
    "http_token_file",
    "local_card_actions_endpoint",
    "public_card_actions_endpoint",
    "public_mobile_html",
    "public_mobile_js",
    "lark_message_consumer",
    "lark_card_action_consumer",
    "real_lark_card_click",
]
failed_required = [item for item in checks if item["name"] in required and not item["ok"]]
result = {
    "ok": not failed_required,
    "audit": "harvis_codex_team_mvp_audit",
    "workspace_root": str(root),
    "public_url": public_url,
    "required_failed": [item["name"] for item in failed_required],
    "checks": checks,
    "warnings": warnings,
}
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
)"

printf '%s\n' "$AUDIT_JSON"

if [[ "$STRICT" -eq 1 ]]; then
  python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("ok") else 1)' <<<"$AUDIT_JSON"
fi
