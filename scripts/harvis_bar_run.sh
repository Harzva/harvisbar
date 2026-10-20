#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${HARVIS_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export HARVIS_PLUGIN_ROOT="$PLUGIN_ROOT"
BINARY="$PLUGIN_ROOT/apps/HarvisBar/.build/release/HarvisBar"
if [[ ! -x "$BINARY" || "${HARVIS_BAR_REBUILD:-0}" == "1" ]]; then
  "$PLUGIN_ROOT/scripts/harvis_bar_build.sh"
fi
exec "$BINARY"
