#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="${HARVIS_PLUGIN_ROOT:-$SCRIPT_ROOT}"
HTML="$PLUGIN_ROOT/studio/mobile.html"
CSS="$PLUGIN_ROOT/studio/mobile.css"
JS="$PLUGIN_ROOT/studio/mobile.js"
ROUTES="$PLUGIN_ROOT/crates/harvis-http/src/routes.rs"
STATIC="$PLUGIN_ROOT/crates/harvis-http/src/static_assets.rs"

for file in "$HTML" "$CSS" "$JS" "$ROUTES" "$STATIC"; do
  test -f "$file"
done

node --check "$JS" >/dev/null

grep -q '/studio/mobile' "$ROUTES"
grep -q 'studio_mobile' "$STATIC"
grep -q 'id="taskStatusList"' "$HTML"
grep -q 'id="pinBoardList"' "$HTML"
grep -q 'id="runTimelineList"' "$HTML"
grep -q 'id="bindingList"' "$HTML"
grep -q 'id="larkActionList"' "$HTML"
grep -q 'id="larkActionCount"' "$HTML"

grep -q '/agent-room/workspace-state?' "$JS"
grep -q '/codex-thread-pins?' "$JS"
grep -q '/lark/card-actions?' "$JS"
grep -q '/run-timeline?' "$JS"
grep -q '/agent-room/conversation-bindings?' "$JS"
grep -q 'function renderLarkActions' "$JS"
grep -q 'function scrub' "$JS"
grep -q 'isSensitiveKey' "$JS"
grep -q '/ui/runtime.js' "$HTML"
grep -q 'HarvisRuntime.bootstrap()' "$JS"

if grep -q 'params.get("token")\|searchParams.get("token")\|token=\|localStorage\|sessionStorage' "$JS"; then
  echo "mobile JS must not read bearer material from query params" >&2
  exit 1
fi

if grep -q 'method: "POST"\|method: '\''POST'\''' "$JS"; then
  echo "mobile page must remain read-only" >&2
  exit 1
fi

printf '{"ok":true,"smoke":"harvis_mobile_webui_static","checks":16}\n'
