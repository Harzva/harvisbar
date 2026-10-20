#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${HARVIS_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_DIR="${HARVIS_DESKTOP_INSTALL_DIR:-$HOME/Applications}"

exec "$PLUGIN_ROOT/scripts/harvis_desktop_package_app.sh" --install-dir "$INSTALL_DIR" "$@"
