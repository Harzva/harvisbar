#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTML="$PLUGIN_ROOT/studio/index.html"
JS="$PLUGIN_ROOT/studio/studio.js"

node --check "$JS" >/dev/null

require() {
  local pattern="$1"
  local file="$2"
  local label="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "missing $label: $pattern in $file" >&2
    exit 1
  fi
}

require 'id="workbenchConversations"' "$HTML" "Workbench Conversation Context panel"
require 'id="workbenchCodexBindings"' "$HTML" "Workbench Codex Threads panel"
require 'id="workbenchRunTimeline"' "$HTML" "Workbench Run Timeline panel"
require 'conversationBindings: null' "$JS" "conversation binding state"
require 'state.conversationBindings && state.conversationBindings.bindings' "$JS" "conversation binding render source"
require '/agent-room/conversation-bindings?' "$JS" "conversation binding API fetch"
require '...conversationBindings.map((binding) => ({' "$JS" "conversation binding merged into conversation context"
require 'workbenchCodexBindingItem' "$JS" "Codex binding renderer"
require '/codex-thread-bindings?' "$JS" "Codex binding API fetch"
require '/run-timeline?' "$JS" "run timeline API fetch"

python3 - <<'PY' "$HTML" "$JS"
from pathlib import Path
import sys

html = Path(sys.argv[1]).read_text(encoding="utf-8")
js = Path(sys.argv[2]).read_text(encoding="utf-8")
checks = {
    "Conversation Context title": "Conversation Context" in html,
    "Codex Threads title": "Codex Threads" in html,
    "conversation binding fields": all(token in js for token in ["binding.packet_id", "binding.handoff_id", "binding.run_id"]),
    "thread binding fields": all(token in js for token in ["binding.codex_thread_id", "binding.codex_session_id", "binding.last_event_type"]),
}
missing = [name for name, ok in checks.items() if not ok]
if missing:
    raise SystemExit("missing static Workbench binding coverage: " + ", ".join(missing))
print('{"ok":true,"smoke":"harvis_studio_workbench_static","checks":%d}' % len(checks))
PY
