#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${HARVIS_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP_NAME="HarvisDesk"
APP_EXECUTABLE="HarvisDesk"
DISPLAY_NAME="${HARVIS_DESKTOP_DISPLAY_NAME:-H.A.R.V.I.S. Desktop}"
BUNDLE_ID="local.harzva.harvisdesk"
APP_VERSION="${HARVIS_DESKTOP_APP_VERSION:-}"
PACKAGE_OUTPUT_ROOT="${HARVIS_PACKAGE_OUTPUT_ROOT:-/private/tmp/harvis-package-output}"
APP_PATH="${HARVIS_DESKTOP_APP_PATH:-$PACKAGE_OUTPUT_ROOT/$APP_NAME.app}"
SIGN_IDENTITY="${HARVIS_DESKTOP_CODESIGN_IDENTITY:--}"
INSTALL_DIR=""
OPEN_AFTER=0
PROVENANCE_STAGE=""
PROVENANCE_SHA256=""

if [[ -n "${HARVIS_DESKTOP_APP_NAME+x}" && "$HARVIS_DESKTOP_APP_NAME" != "$APP_NAME" ]]; then
  echo "HARVIS_DESKTOP_APP_NAME is fixed to HarvisDesk by the package profile." >&2
  exit 2
fi
if [[ -n "${HARVIS_DESKTOP_BUNDLE_ID+x}" && "$HARVIS_DESKTOP_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "HARVIS_DESKTOP_BUNDLE_ID is fixed to local.harzva.harvisdesk by the package profile." >&2
  exit 2
fi

usage() {
  cat <<'USAGE'
Usage: harvis_desktop_package_app.sh [options]

Create a provenance-verified local HarvisDesk.app bundle.

Required:
  --provenance-stage <dir>   Verified release stage containing the fixed artifacts.
  --provenance-sha256 <hash> External SHA-256 of release-provenance-v2.json.

Options:
  --app-path <path>          New output .app under HARVIS_PACKAGE_OUTPUT_ROOT.
  --sign-identity <name>     codesign identity. Use "-" for ad-hoc local signing.
  --install-dir <path>       Copy to a new app in a guarded non-formal directory.
  --open                     Open the verified packaged or installed app.
  -h, --help                 Show this help.

Legacy arbitrary binary/hash, icon-source, and skip-build inputs are rejected.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="$2"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --provenance-stage)
      PROVENANCE_STAGE="$2"
      shift 2
      ;;
    --provenance-sha256)
      PROVENANCE_SHA256="$2"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --open)
      OPEN_AFTER=1
      shift
      ;;
    --runtime-binary|--runtime-sha256|--icon-source|--skip-build)
      echo "$1 is no longer accepted; package only from the externally anchored provenance stage." >&2
      exit 2
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

[[ -n "$PROVENANCE_STAGE" && -n "$PROVENANCE_SHA256" ]] || {
  echo "--provenance-stage and --provenance-sha256 are required." >&2
  exit 2
}
[[ "$PROVENANCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "--provenance-sha256 must be lowercase 64-character hexadecimal." >&2
  exit 2
}
[[ "$APP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "$APP_NAME" != *..* ]] || {
  echo "HARVIS_DESKTOP_APP_NAME is not a safe single path component." >&2
  exit 2
}
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]+$ && "$BUNDLE_ID" != *..* ]] || {
  echo "HARVIS_DESKTOP_BUNDLE_ID is invalid." >&2
  exit 2
}
[[ "$DISPLAY_NAME" != *$'\n'* && "$DISPLAY_NAME" != *$'\r'* && -n "$DISPLAY_NAME" ]] || {
  echo "HARVIS_DESKTOP_DISPLAY_NAME contains an invalid control character." >&2
  exit 2
}
[[ -n "$SIGN_IDENTITY" ]] || {
  echo "A signing identity is required; use - for an ad-hoc local package." >&2
  exit 2
}

guard_path() {
  local kind="$1"
  local value="$2"
  local output_root="${3:-}"
  local result
  local args=(
    "$PLUGIN_ROOT/scripts/harvis_package_path_guard.py"
    --kind "$kind"
    --path "$value"
    --source "$PLUGIN_ROOT"
  )
  if [[ -n "$output_root" ]]; then
    args+=(--output-root "$output_root")
  fi
  result="$(PYTHONDONTWRITEBYTECODE=1 python3 -I "${args[@]}")"
  python3 -I -c 'import json,sys; print(json.load(sys.stdin)["path"])' <<<"$result"
}

PROVENANCE_STAGE="$(guard_path stage "$PROVENANCE_STAGE")"

PYTHONDONTWRITEBYTECODE=1 python3 -I \
  "$PLUGIN_ROOT/scripts/harvis_release_provenance.py" verify \
  --stage "$PROVENANCE_STAGE" \
  --source "$PLUGIN_ROOT" \
  --provenance-sha256 "$PROVENANCE_SHA256" >/dev/null

PROVENANCE_VERSION="$(python3 -I - "$PLUGIN_ROOT/scripts" "$PROVENANCE_STAGE" "$PLUGIN_ROOT" "$PROVENANCE_SHA256" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from harvis_app_bundle_contract import AppBundleContractError, load_provenance_contract  # noqa: E402

try:
    contract = load_provenance_contract(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    print(contract.manifest["source"]["workspaceVersion"])
except AppBundleContractError as exc:
    raise SystemExit(f"ERROR: {exc}") from exc
PY
)"
APP_VERSION="${APP_VERSION:-$PROVENANCE_VERSION}"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || {
  echo "HARVIS_DESKTOP_APP_VERSION must be a numeric dotted version." >&2
  exit 2
}
[[ "$APP_VERSION" == "$PROVENANCE_VERSION" ]] || {
  echo "HARVIS_DESKTOP_APP_VERSION differs from provenance workspace version." >&2
  exit 2
}

PACKAGE_OUTPUT_ROOT="$(guard_path output-root "$PACKAGE_OUTPUT_ROOT")"
mkdir -p "$PACKAGE_OUTPUT_ROOT"
PACKAGE_OUTPUT_ROOT="$(guard_path output-root "$PACKAGE_OUTPUT_ROOT")"
APP_PATH="$(guard_path app-output "$APP_PATH" "$PACKAGE_OUTPUT_ROOT")"

APP_PARENT="$(dirname "$APP_PATH")"
mkdir -p "$APP_PARENT"
APP_PATH="$(guard_path app-output "$APP_PATH" "$PACKAGE_OUTPUT_ROOT")"
ASSEMBLY_ROOT="$(mktemp -d "$APP_PARENT/.harvis-app.XXXXXX")"
BUILD_APP="$ASSEMBLY_ROOT/$APP_NAME.app"

cleanup() {
  if [[ -n "${ASSEMBLY_ROOT:-}" && -d "$ASSEMBLY_ROOT" && ! -L "$ASSEMBLY_ROOT" && \
        "$(dirname "$ASSEMBLY_ROOT")" == "$APP_PARENT" && \
        "$(basename "$ASSEMBLY_ROOT")" == .harvis-app.* ]]; then
    /bin/rm -rf -- "$ASSEMBLY_ROOT"
  fi
}
trap cleanup EXIT

CONTENTS="$BUILD_APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RESOURCES"

BINARY="$PROVENANCE_STAGE/artifacts/HarvisBar"
[[ -f "$BINARY" && -x "$BINARY" && ! -L "$BINARY" ]] || {
  echo "Verified HarvisBar artifact is missing or unsafe." >&2
  exit 1
}
cp "$BINARY" "$MACOS/$APP_EXECUTABLE"
chmod 0755 "$MACOS/$APP_EXECUTABLE"

ICON_SOURCE="$PROVENANCE_STAGE/studio/assets/harvis-app-icon.png"
ICON_SCRIPT="$PROVENANCE_STAGE/scripts/harvis_bar_make_icon.sh"
[[ -f "$ICON_SOURCE" && ! -L "$ICON_SOURCE" && -x "$ICON_SCRIPT" && ! -L "$ICON_SCRIPT" ]] || {
  echo "Verified icon source or icon generator is missing." >&2
  exit 1
}
HARVIS_PLUGIN_ROOT="$PROVENANCE_STAGE" \
  "$ICON_SCRIPT" --source "$ICON_SOURCE" --output "$RESOURCES/HarvisDesk.icns"

python3 -I - "$CONTENTS/Info.plist" "$APP_NAME" "$DISPLAY_NAME" "$BUNDLE_ID" "$APP_VERSION" "$PLUGIN_ROOT/scripts" <<'PY'
import plistlib
import sys

plist_path, app_name, display_name, bundle_id, version, script_root = sys.argv[1:7]
sys.path.insert(0, script_root)
from harvis_app_bundle_contract import REQUIRED_MACOS_USAGE_DESCRIPTIONS

info = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": display_name,
    "CFBundleExecutable": "HarvisDesk",
    "CFBundleIdentifier": bundle_id,
    "CFBundleIconFile": "HarvisDesk",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": app_name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
}
info.update(REQUIRED_MACOS_USAGE_DESCRIPTIONS)
with open(plist_path, "wb") as handle:
    plistlib.dump(info, handle, sort_keys=True)
PY

"$PLUGIN_ROOT/scripts/harvis_app_bundle_runtime.sh" \
  "$CONTENTS" "$SIGN_IDENTITY" "$PROVENANCE_STAGE" "$PROVENANCE_SHA256" \
  desktop "$BUNDLE_ID" "$APP_VERSION" "$APP_EXECUTABLE"

app_entitlements="$PROVENANCE_STAGE/apps/HarvisBar/Resources/HarvisBar.entitlements"
[[ -f "$app_entitlements" && ! -L "$app_entitlements" ]] || {
  echo "Verified app entitlements are missing." >&2
  exit 1
}
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --entitlements "$app_entitlements" "$BUILD_APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements "$app_entitlements" "$BUILD_APP"
fi

PYTHONDONTWRITEBYTECODE=1 python3 -I \
  "$PLUGIN_ROOT/scripts/harvis_app_bundle_verify.py" \
  --app "$BUILD_APP" --source "$PLUGIN_ROOT" \
  --provenance-stage "$PROVENANCE_STAGE" \
  --provenance-sha256 "$PROVENANCE_SHA256" \
  --variant desktop --bundle-id "$BUNDLE_ID" --version "$APP_VERSION" \
  --executable "$APP_EXECUTABLE" --codesign-policy required >/dev/null

# Publish only after the complete temporary bundle has passed provenance,
# receipt, payload, derivative, and code-signature verification.
mv -n "$BUILD_APP" "$APP_PATH"
[[ -d "$APP_PATH" && ! -e "$BUILD_APP" ]] || {
  echo "App output appeared concurrently; refusing to overwrite it." >&2
  exit 1
}

TARGET_APP="$APP_PATH"
if [[ -n "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$(guard_path install-dir "$INSTALL_DIR")"
  mkdir -p "$INSTALL_DIR"
  INSTALL_DIR="$(guard_path install-dir "$INSTALL_DIR")"
  TARGET_APP="$(guard_path app-output "$INSTALL_DIR/$APP_NAME.app" "$INSTALL_DIR")"
  INSTALL_TMP="$(mktemp -d "$INSTALL_DIR/.harvis-install.XXXXXX")"
  cp -R "$APP_PATH" "$INSTALL_TMP/$APP_NAME.app"
  PYTHONDONTWRITEBYTECODE=1 python3 -I \
    "$PLUGIN_ROOT/scripts/harvis_app_bundle_verify.py" \
    --app "$INSTALL_TMP/$APP_NAME.app" --source "$PLUGIN_ROOT" \
    --provenance-stage "$PROVENANCE_STAGE" \
    --provenance-sha256 "$PROVENANCE_SHA256" \
    --variant desktop --bundle-id "$BUNDLE_ID" --version "$APP_VERSION" \
    --executable "$APP_EXECUTABLE" --codesign-policy required >/dev/null
  mv -n "$INSTALL_TMP/$APP_NAME.app" "$TARGET_APP"
  [[ -d "$TARGET_APP" && ! -e "$INSTALL_TMP/$APP_NAME.app" ]] || {
    echo "Install target appeared concurrently; refusing to overwrite it." >&2
    exit 1
  }
  rmdir "$INSTALL_TMP"
fi

printf 'HarvisDesk app packaged: %s\n' "$APP_PATH"
if [[ -n "$INSTALL_DIR" ]]; then
  printf 'HarvisDesk app installed: %s\n' "$TARGET_APP"
fi
if [[ "$OPEN_AFTER" == "1" ]]; then
  open "$TARGET_APP"
fi
