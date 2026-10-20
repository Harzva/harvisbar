#!/usr/bin/env bash
set -euo pipefail

echo "H.A.R.V.I.S. Bar distribution readiness"
echo

check_tool() {
  local name="$1"
  if command -v "$name" >/dev/null; then
    printf 'tool %-12s ok %s\n' "$name" "$(command -v "$name")"
  else
    printf 'tool %-12s missing\n' "$name"
  fi
}

check_tool hdiutil
check_tool codesign
check_tool sips
check_tool iconutil
check_tool xcrun

echo
echo "Developer ID Application identities:"
security find-identity -v -p codesigning 2>/dev/null | rg "Developer ID Application" || true

echo
echo "Apple Development identities:"
security find-identity -v -p codesigning 2>/dev/null | rg "Apple Development" || true

echo
if xcrun notarytool --help >/dev/null 2>&1; then
  echo "notarytool: available"
else
  echo "notarytool: unavailable"
fi

if [[ -n "${HARVIS_BAR_NOTARY_PROFILE:-}" ]]; then
  echo "HARVIS_BAR_NOTARY_PROFILE: configured"
else
  echo "HARVIS_BAR_NOTARY_PROFILE: not configured"
fi

echo
echo "Status:"
if security find-identity -v -p codesigning 2>/dev/null | rg -q "Developer ID Application"; then
  echo "- Developer ID signing appears possible."
else
  echo "- Developer ID signing is not available; local/ad-hoc DMG builds are possible."
fi
if [[ -n "${HARVIS_BAR_NOTARY_PROFILE:-}" ]]; then
  echo "- Notarization can be attempted with the configured keychain profile."
else
  echo "- Notarization needs a stored notarytool keychain profile."
fi
