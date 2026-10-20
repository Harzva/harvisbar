#!/usr/bin/env python3
"""Fail-closed path guard for Harvis package outputs and package inputs."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import sys


class PackagePathError(RuntimeError):
    """Raised when a package path is ambiguous, unsafe, or destructive."""


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _lexical_absolute(raw: str, label: str) -> Path:
    if not raw or any(ord(character) < 32 or ord(character) == 127 for character in raw):
        raise PackagePathError(f"{label} must not be empty")
    expanded = os.path.expanduser(raw)
    if not os.path.isabs(expanded):
        raise PackagePathError(f"{label} must be absolute")
    if "//" in expanded:
        raise PackagePathError(f"{label} must not contain repeated slashes")
    parts = expanded.split("/")[1:]
    if any(part in {".", ".."} for part in parts):
        raise PackagePathError(f"{label} must not contain dot path components")
    normalized = os.path.normpath(expanded)
    if normalized != expanded.rstrip("/") or normalized == "/":
        raise PackagePathError(f"{label} must be a canonical non-root path")
    return Path(normalized)


def _assert_no_symlink_components(path: Path, label: str) -> None:
    current = Path(path.anchor)
    for index, part in enumerate(path.parts[1:], start=1):
        current /= part
        if not os.path.lexists(current):
            continue
        metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise PackagePathError(f"{label} contains a symlink component")
        if index < len(path.parts) - 1 and not stat.S_ISDIR(metadata.st_mode):
            raise PackagePathError(f"{label} has a non-directory parent component")


def _canonical_existing_root(source: Path) -> Path:
    source = _lexical_absolute(str(source.expanduser()), "source root")
    _assert_no_symlink_components(source, "source root")
    if not source.is_dir():
        raise PackagePathError("source root must be an existing directory")
    return source.resolve(strict=True)


def protected_roots(home: Path | None = None) -> tuple[Path, ...]:
    home = (home or Path.home()).resolve(strict=False)
    values = (
        home / ".codex" / "plugins",
        home / ".harvis",
        home / ".local" / "share" / "harvis",
        home / "Library" / "Application Support" / "Harvis",
        home / "Library" / "LaunchAgents",
        home / "Applications" / "HarvisRuntime.app",
        Path("/Applications"),
        Path("/Library/LaunchAgents"),
        Path("/Library/PrivilegedHelperTools"),
        Path("/usr/local/bin"),
        Path("/opt/homebrew/bin"),
    )
    return tuple(value.resolve(strict=False) for value in values)


def _reject_protected(path: Path, source: Path) -> None:
    resolved = path.resolve(strict=False)
    if _is_relative_to(resolved, source):
        raise PackagePathError("package path must not target the source repository")
    for root in protected_roots():
        if resolved == root or _is_relative_to(resolved, root):
            raise PackagePathError("package path must not target a formal runtime/install root")


def guard_path(
    raw_path: str,
    *,
    source: Path,
    kind: str,
    output_root: str | None = None,
) -> Path:
    if kind not in {
        "app-input",
        "app-output",
        "dmg-output",
        "install-dir",
        "output-root",
        "stage",
    }:
        raise PackagePathError("unsupported package path kind")
    source = _canonical_existing_root(source)
    path = _lexical_absolute(raw_path, kind)
    _assert_no_symlink_components(path, kind)
    _reject_protected(path, source)

    root: Path | None = None
    if output_root is not None:
        root = _lexical_absolute(output_root, "package output root")
        _assert_no_symlink_components(root, "package output root")
        _reject_protected(root, source)
        if path == root or not _is_relative_to(path, root):
            raise PackagePathError("package path must be a strict child of the output root")

    if kind in {"app-input", "app-output"} and path.suffix != ".app":
        raise PackagePathError("app path must have the .app suffix")
    if kind == "dmg-output" and path.suffix != ".dmg":
        raise PackagePathError("DMG path must have the .dmg suffix")

    if kind in {"app-output", "dmg-output"}:
        if path.exists() or path.is_symlink():
            raise PackagePathError("package output already exists; refusing to replace it")
        if path.parent.exists() and not path.parent.is_dir():
            raise PackagePathError("package output parent is not a directory")
    elif kind in {"app-input", "stage"}:
        if path.is_symlink() or not path.is_dir():
            raise PackagePathError(f"{kind} must be an existing non-symlink directory")
    elif kind in {"install-dir", "output-root"} and path.exists() and not path.is_dir():
        raise PackagePathError(f"{kind} path is not a directory")
    return path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", required=True, choices=(
        "app-input",
        "app-output",
        "dmg-output",
        "install-dir",
        "output-root",
        "stage",
    ))
    parser.add_argument("--path", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output-root", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        value = guard_path(
            args.path,
            source=Path(args.source),
            kind=args.kind,
            output_root=args.output_root or None,
        )
    except (OSError, PackagePathError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, "path": str(value)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
