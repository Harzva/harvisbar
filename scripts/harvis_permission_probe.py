#!/usr/bin/env python3
"""Probe H.A.R.V.I.S. workspace write permissions without touching source files."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PERMISSION_PROBE_VERSION = "v0.21-alpha"


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def resolve_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def safe_target(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        return path.name


def check_result(name: str, target: str, ok: bool, detail: str = "ok") -> dict[str, Any]:
    return {
        "name": name,
        "target": target,
        "ok": ok,
        "detail": detail,
    }


def mkdir_check(root: Path, path: Path, name: str) -> dict[str, Any]:
    try:
        path.mkdir(parents=True, exist_ok=True)
        return check_result(name, safe_target(root, path), True)
    except OSError as exc:
        return check_result(name, safe_target(root, path), False, f"{type(exc).__name__}: {exc.strerror or exc}")


def read_check(root: Path, path: Path, name: str) -> dict[str, Any]:
    try:
        path.iterdir()
        return check_result(name, safe_target(root, path), True)
    except OSError as exc:
        return check_result(name, safe_target(root, path), False, f"{type(exc).__name__}: {exc.strerror or exc}")


def rw_check(root: Path, directory: Path, name: str) -> dict[str, Any]:
    probe = directory / ".harvis-permission-probe.tmp"
    try:
        directory.mkdir(parents=True, exist_ok=True)
        probe.write_text("ok\n", encoding="utf-8")
        if probe.read_text(encoding="utf-8") != "ok\n":
            return check_result(name, safe_target(root, directory), False, "probe readback mismatch")
        probe.unlink()
        return check_result(name, safe_target(root, directory), True)
    except OSError as exc:
        with contextlib.suppress(OSError):
            probe.unlink()
        return check_result(name, safe_target(root, directory), False, f"{type(exc).__name__}: {exc.strerror or exc}")


def probe_workspace_permissions(
    root: Path,
    profile_root: Path | None = None,
    context: str = "direct",
) -> dict[str, Any]:
    root = resolve_root(root)
    profile_root = (profile_root or Path("~/.harvis")).expanduser().resolve()
    harvis_dir = root / ".harvis"
    checks: list[dict[str, Any]] = [
        read_check(root, root, "workspace_read"),
        mkdir_check(root, harvis_dir, "harvis_dir_create"),
        rw_check(root, harvis_dir, "harvis_dir_read_write"),
        rw_check(root, harvis_dir / "persona", "persona_store_read_write"),
        rw_check(root, harvis_dir / "agent-room", "agent_room_read_write"),
        rw_check(root, harvis_dir / "reports", "reports_read_write"),
        rw_check(root, harvis_dir / "handoffs", "handoffs_read_write"),
    ]

    profile_probe = profile_root / "state" / ".harvis-permission-probe.tmp"
    profile_ok = True
    profile_detail = "ok"
    try:
        profile_probe.parent.mkdir(parents=True, exist_ok=True)
        profile_probe.write_text("ok\n", encoding="utf-8")
        profile_probe.unlink()
    except OSError as exc:
        profile_ok = False
        profile_detail = f"{type(exc).__name__}: {exc.strerror or exc}"
        with contextlib.suppress(OSError):
            profile_probe.unlink()

    checks.append(
        {
            "name": "profile_fallback_read_write",
            "target": "profile/state",
            "ok": profile_ok,
            "detail": profile_detail,
        }
    )

    workspace_checks = [check for check in checks if not check["name"].startswith("profile_")]
    ok = all(bool(check.get("ok")) for check in workspace_checks)
    external_volume = root.as_posix().startswith("/Volumes/")
    recommendations: list[str] = []
    if not ok and external_volume:
        recommendations.append(
            "Grant Full Disk Access to the installed Harvis runtime binary or the containing terminal/app process used by the LaunchAgent, then restart H.A.R.V.I.S. services."
        )
        recommendations.append(
            "If resident access still fails, run the session foreground runner from an already-authorized terminal."
        )
    elif not ok:
        recommendations.append("Check workspace ownership, filesystem permissions, and parent directory access.")
    if not profile_ok:
        recommendations.append("Check the H.A.R.V.I.S. profile fallback directory permissions.")

    return {
        "permission_probe_version": PERMISSION_PROBE_VERSION,
        "generated_at": now_utc(),
        "ok": ok,
        "context": context,
        "workspace": {
            "label": root.name or "workspace",
            "external_volume": external_volume,
        },
        "process": {
            "pid": os.getpid(),
            "python": Path(sys.executable).name,
        },
        "checks": checks,
        "recommendations": recommendations,
    }


def print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe H.A.R.V.I.S. workspace permissions.")
    parser.add_argument("--root", default=".", type=Path)
    parser.add_argument("--profile-root", default="~/.harvis", type=Path)
    parser.add_argument("--context", default="cli")
    args = parser.parse_args()
    print_json(probe_workspace_permissions(args.root, args.profile_root, args.context))
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("permission-probe", legacy_main=main))
