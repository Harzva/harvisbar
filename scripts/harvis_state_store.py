#!/usr/bin/env python3
"""Workspace state helpers with a profile-root fallback for resident services."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


def profile_root_path(profile_root: Path | None = None) -> Path:
    return (profile_root or Path("~/.harvis")).expanduser().resolve()


def workspace_state_id(root: Path) -> str:
    resolved = root.expanduser().resolve()
    digest = hashlib.sha256(str(resolved).encode("utf-8")).hexdigest()[:12]
    label = resolved.name or "workspace"
    safe_label = "".join(char if char.isalnum() or char in "-_." else "-" for char in label)
    safe_label = safe_label.strip(".-")[:48] or "workspace"
    return f"{safe_label}-{digest}"


def fallback_workspace_dir(root: Path, profile_root: Path | None = None) -> Path:
    return profile_root_path(profile_root) / "state" / "workspaces" / workspace_state_id(root)


def runtime_workspace_path(root: Path, relative_path: str | Path) -> Path:
    rel_path = Path(relative_path)
    if rel_path.is_absolute():
        raise ValueError(f"runtime path must be relative: {rel_path}")
    if rel_path.parts and rel_path.parts[0] == ".harvis":
        return root.expanduser().resolve() / rel_path
    return root.expanduser().resolve() / ".harvis" / rel_path


def runtime_fallback_path(
    root: Path,
    relative_path: str | Path,
    profile_root: Path | None = None,
) -> Path:
    rel_path = Path(relative_path)
    if rel_path.is_absolute():
        raise ValueError(f"runtime path must be relative: {rel_path}")
    if rel_path.parts and rel_path.parts[0] == ".harvis":
        rel_path = Path(*rel_path.parts[1:]) if len(rel_path.parts) > 1 else Path(".")
    return fallback_workspace_dir(root, profile_root) / rel_path


def existing_runtime_path(
    root: Path,
    relative_path: str | Path,
    profile_root: Path | None = None,
) -> Path:
    workspace_path = runtime_workspace_path(root, relative_path)
    if workspace_path.exists():
        return workspace_path
    fallback_path = runtime_fallback_path(root, relative_path, profile_root)
    if fallback_path.exists():
        return fallback_path
    return workspace_path


def read_runtime_json_object(
    root: Path,
    relative_path: str | Path,
    profile_root: Path | None = None,
) -> tuple[dict[str, Any] | None, Path | None, str]:
    candidates = [
        ("workspace", runtime_workspace_path(root, relative_path)),
        ("profile-fallback", runtime_fallback_path(root, relative_path, profile_root)),
    ]
    for location, path in candidates:
        if not path.exists():
            continue
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(loaded, dict):
            return loaded, path, location
    return None, None, "missing"


def write_text_with_fallback(
    primary: Path,
    fallback: Path,
    content: str,
) -> tuple[Path | None, str | None]:
    try:
        primary.parent.mkdir(parents=True, exist_ok=True)
        primary.write_text(content, encoding="utf-8")
        return primary, None
    except Exception as primary_exc:
        try:
            fallback.parent.mkdir(parents=True, exist_ok=True)
            fallback.write_text(content, encoding="utf-8")
            return fallback, f"workspace write failed, used profile fallback: {primary_exc}"
        except Exception as fallback_exc:
            return None, (
                "workspace write failed and profile fallback write failed: "
                f"{primary_exc}; fallback: {fallback_exc}"
            )


def append_text_with_fallback(
    primary: Path,
    fallback: Path,
    content: str,
) -> tuple[Path | None, str | None]:
    try:
        primary.parent.mkdir(parents=True, exist_ok=True)
        with primary.open("a", encoding="utf-8") as handle:
            handle.write(content)
        return primary, None
    except Exception as primary_exc:
        try:
            fallback.parent.mkdir(parents=True, exist_ok=True)
            with fallback.open("a", encoding="utf-8") as handle:
                handle.write(content)
            return fallback, f"workspace append failed, used profile fallback: {primary_exc}"
        except Exception as fallback_exc:
            return None, (
                "workspace append failed and profile fallback append failed: "
                f"{primary_exc}; fallback: {fallback_exc}"
            )
