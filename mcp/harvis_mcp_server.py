#!/usr/bin/env python3
"""Compatibility shim for the Rust H.A.R.V.I.S. stdio MCP server."""

from __future__ import annotations

import os
from pathlib import Path


PLUGIN_ROOT = Path(__file__).resolve().parents[1]
RELEASE_BINARY = PLUGIN_ROOT / "target" / "release" / "harvis"
WRAPPER = PLUGIN_ROOT / "scripts" / "harvis"


def main() -> int:
    runtime = RELEASE_BINARY if RELEASE_BINARY.exists() else WRAPPER
    os.execv(str(runtime), [str(runtime), "mcp"])
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
