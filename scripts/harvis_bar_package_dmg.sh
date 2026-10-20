#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${HARVIS_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP_NAME="HarvisBar"
APP_VERSION="${HARVIS_BAR_APP_VERSION:-}"
BUNDLE_ID="local.harzva.harvisbar"
PACKAGE_OUTPUT_ROOT="${HARVIS_PACKAGE_OUTPUT_ROOT:-/private/tmp/harvis-package-output}"
APP_PATH="${HARVIS_BAR_APP_PATH:-$PACKAGE_OUTPUT_ROOT/$APP_NAME.app}"
DMG_PATH="${HARVIS_BAR_DMG_PATH:-}"
SIGN_IDENTITY="${HARVIS_BAR_CODESIGN_IDENTITY:-auto}"
NOTARY_PROFILE="${HARVIS_BAR_NOTARY_PROFILE:-}"
PROVENANCE_STAGE=""
PROVENANCE_SHA256=""
SKIP_BUILD=0
NOTARIZE=0

if [[ -n "${HARVIS_BAR_APP_NAME+x}" && "$HARVIS_BAR_APP_NAME" != "$APP_NAME" ]]; then
  echo "HARVIS_BAR_APP_NAME is fixed to HarvisBar by the package profile." >&2
  exit 2
fi
if [[ -n "${HARVIS_BAR_BUNDLE_ID+x}" && "$HARVIS_BAR_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "HARVIS_BAR_BUNDLE_ID is fixed to local.harzva.harvisbar by the package profile." >&2
  exit 2
fi

usage() {
  cat <<'USAGE'
Usage: harvis_bar_package_dmg.sh [options]

Create a provenance-verified macOS DMG for HarvisBar.app.

Required:
  --provenance-stage <dir>   Verified release stage containing fixed app artifacts.
  --provenance-sha256 <hash> External SHA-256 of release-provenance-v2.json.

Options:
  --app-path <path>          Existing or newly generated app under the package output root.
  --dmg-path <path>          New .dmg path under the package output root.
  --sign-identity <name>     codesign identity. Use "-" for ad-hoc signing.
  --notary-profile <name>    notarytool keychain profile to submit and staple.
  --notarize                 Require notarization after DMG creation.
  --skip-build               Reuse only an app that passes the same anchored verifier.
  -h, --help                 Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="$2"
      shift 2
      ;;
    --dmg-path)
      DMG_PATH="$2"
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
    --notary-profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --notarize)
      NOTARIZE=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --runtime-binary|--runtime-sha256)
      echo "$1 is no longer accepted; DMG packaging requires the provenance stage." >&2
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
  echo "HARVIS_BAR_APP_NAME is not a safe single path component." >&2
  exit 2
}
guard_path() {
  local kind="$1"
  local value="$2"
  local output_root="${3:-}"
  local result
  local args=(
    "$PLUGIN_ROOT/scripts/harvis_package_path_guard.py"
    --kind "$kind" --path "$value" --source "$PLUGIN_ROOT"
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
  --stage "$PROVENANCE_STAGE" --source "$PLUGIN_ROOT" \
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
  echo "HARVIS_BAR_APP_VERSION must be a numeric dotted version." >&2
  exit 2
}
[[ "$APP_VERSION" == "$PROVENANCE_VERSION" ]] || {
  echo "HARVIS_BAR_APP_VERSION differs from provenance workspace version." >&2
  exit 2
}

PACKAGE_OUTPUT_ROOT="$(guard_path output-root "$PACKAGE_OUTPUT_ROOT")"
mkdir -p "$PACKAGE_OUTPUT_ROOT"
PACKAGE_OUTPUT_ROOT="$(guard_path output-root "$PACKAGE_OUTPUT_ROOT")"
DMG_PATH="${DMG_PATH:-$PACKAGE_OUTPUT_ROOT/$APP_NAME-$APP_VERSION-macos-arm64.dmg}"
DMG_PATH="$(guard_path dmg-output "$DMG_PATH" "$PACKAGE_OUTPUT_ROOT")"

SIGN_IDENTITY="$(python3 -I "$PLUGIN_ROOT/scripts/harvis_local_signing.py" resolve --identity "$SIGN_IDENTITY")"
SIGNING_MODE="$(python3 -I "$PLUGIN_ROOT/scripts/harvis_local_signing.py" mode --identity "$SIGN_IDENTITY")"
if [[ "$NOTARIZE" == "1" && "$SIGNING_MODE" != "developer" ]]; then
  echo "Notarization requires a Developer ID identity; local signing does not provide it." >&2
  exit 2
fi
[[ -n "$SIGN_IDENTITY" ]] || {
  echo "A signing identity is required; use - for an ad-hoc local DMG." >&2
  exit 2
}

if [[ "$SKIP_BUILD" == "1" ]]; then
  APP_PATH="$(guard_path app-input "$APP_PATH" "$PACKAGE_OUTPUT_ROOT")"
else
  HARVIS_BAR_APP_VERSION="$APP_VERSION" \
  HARVIS_BAR_BUNDLE_ID="$BUNDLE_ID" \
  HARVIS_PACKAGE_OUTPUT_ROOT="$PACKAGE_OUTPUT_ROOT" \
    "$PLUGIN_ROOT/scripts/harvis_bar_package_app.sh" \
    --app-path "$APP_PATH" \
    --sign-identity "$SIGN_IDENTITY" \
    --provenance-stage "$PROVENANCE_STAGE" \
    --provenance-sha256 "$PROVENANCE_SHA256"
  APP_PATH="$(guard_path app-input "$APP_PATH" "$PACKAGE_OUTPUT_ROOT")"
fi

PYTHONDONTWRITEBYTECODE=1 python3 -I \
  "$PLUGIN_ROOT/scripts/harvis_app_bundle_verify.py" \
  --app "$APP_PATH" --source "$PLUGIN_ROOT" \
  --provenance-stage "$PROVENANCE_STAGE" \
  --provenance-sha256 "$PROVENANCE_SHA256" \
  --variant bar --bundle-id "$BUNDLE_ID" --version "$APP_VERSION" \
  --executable HarvisBar --codesign-policy required >/dev/null
python3 -I "$PLUGIN_ROOT/scripts/harvis_local_signing.py" verify \
  --identity "$SIGN_IDENTITY" --app "$APP_PATH"

command -v hdiutil >/dev/null 2>&1 || {
  echo "hdiutil is required to create a DMG." >&2
  exit 1
}

STAGING="$(mktemp -d /private/tmp/harvis-dmg-stage.XXXXXX)"
DMG_PARENT="$(dirname "$DMG_PATH")"
mkdir -p "$DMG_PARENT"
DMG_PATH="$(guard_path dmg-output "$DMG_PATH" "$PACKAGE_OUTPUT_ROOT")"
DMG_ASSEMBLY="$(mktemp -d "$DMG_PARENT/.harvis-dmg.XXXXXX")"
TEMP_DMG="$DMG_ASSEMBLY/HarvisBar.dmg"

cleanup() {
  if [[ -d "${STAGING:-}" && ! -L "${STAGING:-}" && "${STAGING:-}" == /private/tmp/harvis-dmg-stage.* ]]; then
    /bin/rm -rf -- "$STAGING"
  fi
  if [[ -d "${DMG_ASSEMBLY:-}" && ! -L "${DMG_ASSEMBLY:-}" && \
        "$(dirname "${DMG_ASSEMBLY:-/}")" == "$DMG_PARENT" && \
        "$(basename "${DMG_ASSEMBLY:-/}")" == .harvis-dmg.* ]]; then
    /bin/rm -rf -- "$DMG_ASSEMBLY"
  fi
}
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
python3 -I - "$STAGING/README-FIRST.txt" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    """H.A.R.V.I.S. Bar

Drag HarvisBar.app into Applications, then open it from the menu bar.

If the resident runner cannot read an external-volume workspace, grant Full Disk
Access to the installed Harvis runtime binary, or to the containing app/terminal
process used by the H.A.R.V.I.S. LaunchAgent, and restart the H.A.R.V.I.S.
services from the menu bar.
""",
    encoding="utf-8",
)
PY

hdiutil create \
  -volname "H.A.R.V.I.S. Bar" \
  -srcfolder "$STAGING" \
  -format UDZO \
  "$TEMP_DMG" >/dev/null

if [[ "$SIGNING_MODE" == "local-certificate" ]]; then
  codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$TEMP_DMG"
elif [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$TEMP_DMG"
fi

mv -n "$TEMP_DMG" "$DMG_PATH"
[[ -f "$DMG_PATH" && ! -e "$TEMP_DMG" ]] || {
  echo "DMG output appeared concurrently; refusing to overwrite it." >&2
  exit 1
}

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Notarization requires a Developer ID Application signing identity." >&2
    exit 1
  fi
  [[ -n "$NOTARY_PROFILE" ]] || {
    echo "Notarization requires --notary-profile or HARVIS_BAR_NOTARY_PROFILE." >&2
    exit 1
  }
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  "$PROVENANCE_STAGE/scripts/harvis_bar_release_manifest.py" \
    --artifact "$DMG_PATH" --version "$APP_VERSION" --notarized
else
  "$PROVENANCE_STAGE/scripts/harvis_bar_release_manifest.py" \
    --artifact "$DMG_PATH" --version "$APP_VERSION"
fi

printf 'HarvisBar DMG packaged: %s\n' "$DMG_PATH"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  printf 'Signing: ad-hoc/local\n'
else
  printf 'Signing: Developer ID\n'
fi
if [[ "$NOTARIZE" == "1" ]]; then
  printf 'Notarization: submitted and stapled\n'
else
  printf 'Notarization: skipped\n'
fi
