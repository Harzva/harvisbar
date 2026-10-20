#!/usr/bin/env python3
"""Run one HARVIS handoff through the isolated Digital-Me DSH profile."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_VERSION = "harvis.dsh-adapter.v0"
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ALLOWED_PERMISSION_MODES = {"read-only", "workspace-write"}


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def write_json(path: Path, value: dict[str, object]) -> None:
    write_text(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=3)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def resolve_dsh(value: str) -> str:
    if value:
        candidate = Path(value).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
        raise SystemExit(f"dsh executable is missing or not executable: {candidate}")
    discovered = shutil.which("dsh")
    if discovered:
        return discovered
    raise SystemExit("dsh executable not found; set HARVIS_DSH_CLI")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsh", default=os.environ.get("HARVIS_DSH_CLI", ""))
    parser.add_argument(
        "--profile",
        default=os.environ.get("HARVIS_DSH_PROFILE", "digital-me-headless"),
    )
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--prompt-file", type=Path, required=True)
    parser.add_argument("--final-file", type=Path, required=True)
    parser.add_argument("--stdout-log", type=Path, required=True)
    parser.add_argument("--stderr-log", type=Path, required=True)
    parser.add_argument("--status-json", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument(
        "--permission-mode",
        default=os.environ.get("HARVIS_DSH_PERMISSION_MODE", "workspace-write"),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.expanduser().resolve()
    prompt_file = args.prompt_file.expanduser().resolve()
    if not root.is_dir():
        raise SystemExit(f"workspace root does not exist: {root}")
    if not prompt_file.is_file():
        raise SystemExit(f"prompt file does not exist: {prompt_file}")
    if not PROFILE_RE.fullmatch(args.profile):
        raise SystemExit("DSH profile must match [a-z0-9][a-z0-9-]*")
    if args.permission_mode not in ALLOWED_PERMISSION_MODES:
        raise SystemExit(
            "HARVIS DSH adapter only permits read-only or workspace-write; "
            "danger-full-access is intentionally unsupported"
        )
    if args.timeout_seconds < 1 or args.timeout_seconds > 3600:
        raise SystemExit("timeout must be between 1 and 3600 seconds")

    dsh = resolve_dsh(args.dsh)
    prompt = prompt_file.read_text(encoding="utf-8")
    prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
    started_at = now_utc()
    env = os.environ.copy()
    env["DSH_PERMISSION_MODE"] = args.permission_mode

    process = subprocess.Popen(
        [dsh, "--profile", args.profile, prompt],
        cwd=root,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=args.timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        stop_process(process)
        stdout, stderr = process.communicate()
        stderr = (stderr.rstrip() + "\nDSH adapter timed out.\n").lstrip()

    exit_code = 124 if timed_out else int(process.returncode or 0)
    write_text(args.stdout_log, stdout)
    write_text(args.stderr_log, stderr)
    final = stdout.strip()
    if not final:
        final = (
            "DSH did not return a final assistant message. "
            "Inspect the redacted HARVIS adapter status and stderr log."
        )
    write_text(args.final_file, final + "\n")
    write_json(
        args.status_json,
        {
            "schemaVersion": SCHEMA_VERSION,
            "status": "completed" if exit_code == 0 else "blocked",
            "runtime": "dsh-cordis",
            "profile": args.profile,
            "permissionMode": args.permission_mode,
            "startedAt": started_at,
            "finishedAt": now_utc(),
            "exitCode": exit_code,
            "timedOut": timed_out,
            "promptSha256": prompt_hash,
            "includesSecrets": False,
            "includesLocalAbsolutePaths": False,
        },
    )
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
