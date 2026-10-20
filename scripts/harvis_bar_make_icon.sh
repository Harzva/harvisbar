#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${HARVIS_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SOURCE="${HARVIS_BAR_ICON_SOURCE:-$PLUGIN_ROOT/studio/assets/harvis-app-icon.png}"
OUTPUT="${HARVIS_BAR_ICON_OUTPUT:-$PLUGIN_ROOT/apps/HarvisBar/.build/release/HarvisBar.icns}"

usage() {
  cat <<'USAGE'
Usage: harvis_bar_make_icon.sh [options]

Generate a macOS .icns icon for HarvisBar from a square PNG.

Options:
  --source <png>     Source PNG. Defaults to studio/assets/harvis-app-icon.png.
  --output <icns>    Output .icns path. Defaults to HarvisBar release build dir.
  -h, --help         Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SOURCE="${SOURCE/#\~/$HOME}"
OUTPUT="${OUTPUT/#\~/$HOME}"
if [[ ! -f "$SOURCE" ]]; then
  echo "Icon source not found: $SOURCE" >&2
  exit 1
fi

if ! command -v sips >/dev/null || ! command -v iconutil >/dev/null; then
  echo "sips and iconutil are required to generate macOS icons." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/harvis-icon.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE="$TMP_DIR/base.png"
ICONSET="$TMP_DIR/HarvisBar.iconset"
mkdir -p "$ICONSET"

sips --cropToHeightWidth 1024 1024 "$SOURCE" --out "$BASE" >/dev/null

make_icon() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$BASE" --out "$ICONSET/$name" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
printf 'HarvisBar icon generated: %s\n' "$OUTPUT"
