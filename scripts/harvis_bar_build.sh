#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${HARVIS_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SWIFT_SCRATCH_PATH="${HARVIS_SWIFT_SCRATCH_PATH:-$PLUGIN_ROOT/apps/HarvisBar/.build}"
cd "$PLUGIN_ROOT/apps/HarvisBar"
swift build \
  --scratch-path "$SWIFT_SCRATCH_PATH" \
  -c release \
  -Xswiftc -gnone \
  -Xswiftc -file-prefix-map \
  -Xswiftc "$PLUGIN_ROOT=/src/harvis"
printf 'HarvisBar built: %s\n' "$SWIFT_SCRATCH_PATH/release/HarvisBar"
