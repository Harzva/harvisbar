#!/usr/bin/env python3
"""Compatibility helpers that exec the Rust-first H.A.R.V.I.S. runtime."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def plugin_root() -> Path:
    return Path(__file__).resolve().parent.parent


def exec_harvis(args: list[str]) -> int:
    harvis = plugin_root() / "scripts" / "harvis"
    if not harvis.exists():
        print(f"H.A.R.V.I.S. Rust entrypoint not found: {harvis}", file=sys.stderr)
        return 127
    os.execv(str(harvis), [str(harvis), *args])
    return 127


def use_legacy_python_entrypoint() -> bool:
    return os.environ.get("HARVIS_PYTHON_LEGACY_ENTRYPOINT", "").strip() in {"1", "true", "yes", "on"}


def split_leading_options(
    argv: list[str],
    *,
    value_options: set[str] | None = None,
    flag_options: set[str] | None = None,
) -> tuple[list[str], list[str]]:
    """Split old global CLI options from the remaining subcommand argv."""
    value_options = value_options or set()
    flag_options = flag_options or set()
    leading: list[str] = []
    index = 0
    while index < len(argv):
        item = argv[index]
        option_name, has_equals, option_value = item.partition("=")
        if option_name in value_options:
            if has_equals:
                leading.extend([option_name, option_value])
                index += 1
                continue
            if index + 1 >= len(argv):
                break
            leading.extend([item, argv[index + 1]])
            index += 2
            continue
        if item in flag_options:
            leading.append(item)
            index += 1
            continue
        break
    return leading, argv[index:]


def exec_harvis_command(
    command: str,
    argv: list[str] | None = None,
    legacy_main: object | None = None,
) -> int:
    if use_legacy_python_entrypoint() and callable(legacy_main):
        return int(legacy_main())
    return exec_harvis([command, *(sys.argv[1:] if argv is None else argv)])
