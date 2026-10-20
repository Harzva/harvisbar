#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${HARVIS_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ "$#" -ne 8 ]]; then
  echo "Usage: harvis_app_bundle_runtime.sh <app-contents> <sign-identity> <provenance-stage> <provenance-sha256> <variant> <bundle-id> <version> <executable>" >&2
  exit 2
fi

CONTENTS="$1"
SIGN_IDENTITY="$2"
PROVENANCE_STAGE="$3"
PROVENANCE_SHA256="$4"
APP_VARIANT="$5"
APP_BUNDLE_ID="$6"
APP_VERSION="$7"
APP_EXECUTABLE="$8"
RESOURCES="$CONTENTS/Resources"
PAYLOAD="$RESOURCES/HarvisPlugin"
EXTENSION_NAME="HarvisPerAppProxyExtension"
EXTENSION_ID="com.harzva.harvisbar.per-app-proxy"
EXTENSION_BUNDLE="$CONTENTS/Library/SystemExtensions/$EXTENSION_NAME.systemextension"
EXTENSION_CONTENTS="$EXTENSION_BUNDLE/Contents"
EXTENSION_BINARY="$PROVENANCE_STAGE/artifacts/$EXTENSION_NAME"
EXTENSION_SOURCE="$PROVENANCE_STAGE/apps/HarvisBar/SystemExtensions/HarvisPerAppProxyExtension"

for command_name in codesign git python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Required command unavailable: $command_name" >&2
    exit 1
  }
done

[[ -n "$SIGN_IDENTITY" ]] || {
  echo "A signing identity is required; use - for an ad-hoc local package." >&2
  exit 1
}
[[ -d "$CONTENTS" && -d "$RESOURCES" ]] || {
  echo "App Contents/Resources must exist before bundling runtime resources." >&2
  exit 1
}
[[ "$APP_VARIANT" == "bar" || "$APP_VARIANT" == "desktop" ]] || {
  echo "App variant must be bar or desktop." >&2
  exit 1
}

# The package entrypoint runs this verifier first as an explicit external trust
# gate. Repeat it before reading or copying any stage file so a swapped stage
# fails closed.
PYTHONDONTWRITEBYTECODE=1 python3 -I \
  "$PLUGIN_ROOT/scripts/harvis_release_provenance.py" verify \
  --stage "$PROVENANCE_STAGE" \
  --source "$PLUGIN_ROOT" \
  --provenance-sha256 "$PROVENANCE_SHA256" >/dev/null

source_commit="$(git -C "$PLUGIN_ROOT" rev-parse HEAD)"
source_tree="$(git -C "$PLUGIN_ROOT" rev-parse 'HEAD^{tree}')"
[[ -z "$(git -C "$PLUGIN_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "Refusing to assemble an app from a dirty source tree." >&2
  exit 1
}

python3 -I - \
  "$PLUGIN_ROOT/scripts" \
  "$PROVENANCE_STAGE" "$PLUGIN_ROOT" "$PROVENANCE_SHA256" \
  "$source_commit" "$source_tree" "$PAYLOAD" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from harvis_app_bundle_contract import (  # noqa: E402
    AppBundleContractError,
    load_provenance_contract,
    materialize_runtime_payload,
)

stage, source, provenance_sha, commit, tree, payload = sys.argv[2:8]
try:
    contract = load_provenance_contract(Path(stage), Path(source), provenance_sha)
    if contract.manifest["source"]["commit"] != commit:
        raise AppBundleContractError("provenance source commit changed during packaging")
    if contract.manifest["source"]["tree"] != tree:
        raise AppBundleContractError("provenance source tree changed during packaging")
    materialize_runtime_payload(contract, Path(payload))
except AppBundleContractError as exc:
    raise SystemExit(f"ERROR: {exc}") from exc
PY

printf 'HarvisPlugin\n' > "$RESOURCES/harvis-plugin-root.txt"

fda_source="$PROVENANCE_STAGE/apps/HarvisBar/Resources/FULL_DISK_ACCESS.md"
if [[ -f "$fda_source" && ! -L "$fda_source" ]]; then
  cp "$fda_source" "$RESOURCES/FULL_DISK_ACCESS.md"
fi

[[ -f "$EXTENSION_BINARY" && -x "$EXTENSION_BINARY" && ! -L "$EXTENSION_BINARY" ]] || {
  echo "Verified system extension artifact is missing or unsafe." >&2
  exit 1
}
mkdir -p "$EXTENSION_CONTENTS/MacOS"
cp "$EXTENSION_BINARY" "$EXTENSION_CONTENTS/MacOS/$EXTENSION_NAME"
chmod 0755 "$EXTENSION_CONTENTS/MacOS/$EXTENSION_NAME"

team_prefix="${HARVIS_TEAM_IDENTIFIER_PREFIX:-}"
extension_identity="$SIGN_IDENTITY"
if [[ "$APP_VARIANT" == "bar" ]]; then
  signing_mode="$(python3 -I "$PLUGIN_ROOT/scripts/harvis_local_signing.py" mode --identity "$SIGN_IDENTITY")"
  if [[ "$signing_mode" == "local-certificate" ]]; then
    # A local TCC identity is not an Apple Developer Team. Preserve the existing
    # local extension packaging; never fabricate a Team ID or activation claim.
    extension_identity="-"
  fi
fi
if [[ "$extension_identity" != "-" && -z "$team_prefix" ]]; then
  echo "HARVIS_TEAM_IDENTIFIER_PREFIX is required for certificate-signed system extensions." >&2
  exit 1
fi
if [[ -n "$team_prefix" && "$team_prefix" != *. ]]; then
  team_prefix="$team_prefix."
fi

python3 -I - \
  "$EXTENSION_SOURCE/Info.plist" \
  "$EXTENSION_CONTENTS/Info.plist" \
  "$CONTENTS/Info.plist" \
  "$EXTENSION_NAME" "$EXTENSION_ID" "$team_prefix" <<'PY'
import plistlib
import sys

source, destination, app_plist, executable, extension_id, team_prefix = sys.argv[1:7]
with open(source, "rb") as handle:
    info = plistlib.load(handle)
with open(app_plist, "rb") as handle:
    app_info = plistlib.load(handle)
info["CFBundleExecutable"] = executable
info["CFBundleIdentifier"] = extension_id
info["CFBundleShortVersionString"] = app_info["CFBundleShortVersionString"]
info["CFBundleVersion"] = app_info["CFBundleVersion"]
network = info["NetworkExtension"]
network["NEMachServiceName"] = f"{team_prefix}{extension_id}"
classes = network["NEProviderClasses"]
classes["com.apple.networkextension.app-proxy"] = (
    "HarvisPerAppProxyExtension.TransparentProxyProvider"
)
with open(destination, "wb") as handle:
    plistlib.dump(info, handle, sort_keys=True)
PY

# Re-check the immutable source identity before sealing the receipt.
[[ "$(git -C "$PLUGIN_ROOT" rev-parse HEAD)" == "$source_commit" ]] || {
  echo "Source HEAD changed during app assembly." >&2
  exit 1
}
[[ "$(git -C "$PLUGIN_ROOT" rev-parse 'HEAD^{tree}')" == "$source_tree" ]] || {
  echo "Source tree changed during app assembly." >&2
  exit 1
}
[[ -z "$(git -C "$PLUGIN_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || {
  echo "Source worktree changed during app assembly." >&2
  exit 1
}

python3 -I - \
  "$PLUGIN_ROOT/scripts" \
  "$PROVENANCE_STAGE" "$PLUGIN_ROOT" "$PROVENANCE_SHA256" \
  "$CONTENTS" "$APP_VARIANT" "$APP_BUNDLE_ID" "$APP_VERSION" "$APP_EXECUTABLE" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from harvis_app_bundle_contract import (  # noqa: E402
    AppBundleContractError,
    RECEIPT_FILE,
    build_receipt,
    load_provenance_contract,
    write_receipt,
)

stage, source, provenance_sha, contents, variant, bundle_id, version, executable = sys.argv[2:10]
try:
    contract = load_provenance_contract(Path(stage), Path(source), provenance_sha)
    receipt = build_receipt(
        contract,
        Path(contents),
        variant=variant,
        expected_bundle_id=bundle_id,
        expected_version=version,
        expected_executable=executable,
    )
    write_receipt(Path(contents) / "Resources" / RECEIPT_FILE, receipt)
except AppBundleContractError as exc:
    raise SystemExit(f"ERROR: {exc}") from exc
PY

extension_entitlements="$EXTENSION_SOURCE/HarvisPerAppProxyExtension.entitlements"
if [[ "$extension_identity" == "-" ]]; then
  codesign --force --sign - --entitlements "$extension_entitlements" \
    "$EXTENSION_BUNDLE"
else
  codesign --force --options runtime --timestamp --sign "$extension_identity" \
    --entitlements "$extension_entitlements" "$EXTENSION_BUNDLE"
fi

codesign --verify --strict "$PAYLOAD/bin/harvis"
codesign --verify --strict "$EXTENSION_BUNDLE"
