#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harvis-dsh-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_ROOT"' EXIT

FAKE_DSH="$SMOKE_ROOT/dsh"
PROMPT="$SMOKE_ROOT/prompt.md"
FINAL="$SMOKE_ROOT/final.md"
STDOUT_LOG="$SMOKE_ROOT/stdout.log"
STDERR_LOG="$SMOKE_ROOT/stderr.log"
STATUS="$SMOKE_ROOT/status.json"

printf '%s\n' 'Synthetic DSH adapter prompt.' >"$PROMPT"
printf '%s\n' '#!/usr/bin/env bash' >"$FAKE_DSH"
printf '%s\n' 'set -euo pipefail' >>"$FAKE_DSH"
printf '%s\n' '[[ "$1" == "--profile" ]]' >>"$FAKE_DSH"
printf '%s\n' '[[ "$2" == "digital-me-headless" ]]' >>"$FAKE_DSH"
printf '%s\n' '[[ "$3" == "Synthetic DSH adapter prompt." ]]' >>"$FAKE_DSH"
printf '%s\n' '[[ "$DSH_PERMISSION_MODE" == "read-only" ]]' >>"$FAKE_DSH"
printf '%s\n' 'printf "%s\\n" "synthetic Digital-Me result"' >>"$FAKE_DSH"
chmod +x "$FAKE_DSH"

python3 "$PLUGIN_ROOT/scripts/harvis_dsh_adapter.py" \
  --dsh "$FAKE_DSH" \
  --profile digital-me-headless \
  --root "$SMOKE_ROOT" \
  --prompt-file "$PROMPT" \
  --final-file "$FINAL" \
  --stdout-log "$STDOUT_LOG" \
  --stderr-log "$STDERR_LOG" \
  --status-json "$STATUS" \
  --timeout-seconds 10 \
  --permission-mode read-only

python3 - "$FINAL" "$STATUS" <<'PY'
import json
import sys
from pathlib import Path

final_path, status_path = map(Path, sys.argv[1:])
assert final_path.read_text(encoding="utf-8").strip() == "synthetic Digital-Me result"
status = json.loads(status_path.read_text(encoding="utf-8"))
assert status["status"] == "completed"
assert status["runtime"] == "dsh-cordis"
assert status["profile"] == "digital-me-headless"
assert status["permissionMode"] == "read-only"
assert status["exitCode"] == 0
assert status["includesSecrets"] is False
assert status["includesLocalAbsolutePaths"] is False
PY

if python3 "$PLUGIN_ROOT/scripts/harvis_dsh_adapter.py" \
  --dsh "$FAKE_DSH" \
  --profile digital-me-headless \
  --root "$SMOKE_ROOT" \
  --prompt-file "$PROMPT" \
  --final-file "$FINAL" \
  --stdout-log "$STDOUT_LOG" \
  --stderr-log "$STDERR_LOG" \
  --status-json "$STATUS" \
  --timeout-seconds 10 \
  --permission-mode danger-full-access >/dev/null 2>&1; then
  echo "danger-full-access unexpectedly passed" >&2
  exit 1
fi

echo "HARVIS DSH adapter smoke passed"
