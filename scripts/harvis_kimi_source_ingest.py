#!/usr/bin/env python3
"""Run Kimi source ingestion for external article links.

This is a worker adapter, not a fixed Harvis workflow. Codex Conductor may call
it when the worker registry says kimicode is the right source-ingestion worker.
The adapter preserves the authenticated user Kimi home, validates non-empty
output, and writes a small status JSON for conductor audits.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_KIMICODE = Path.home() / ".local" / "bin" / "kimicode"
DEFAULT_AUTH_HOME = Path.home()
DEFAULT_MODEL = "kimi-code/kimi-for-coding"


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def prompt_for(url: str) -> str:
    return f"""Read-only source ingestion only. Do not edit files.

Open and parse this external article URL:
{url}

Return a structured source package in Markdown with these sections:

1. title
2. source_url
3. author_or_account
4. publish_time_if_visible
5. body_summary
6. key_points
7. image_candidates
   - list every usable image URL you can discover
   - include a short note on what each image shows when visible
8. paper_or_project_links
9. source_tail_to_remove
   - list any tail text such as 文章来源, 来源公众号, 原文来自, 转载自, 本文来源于
10. failure_reason
   - null if the article was accessible
   - otherwise explain the exact blocker

If you cannot access the page, still write the source_url and failure_reason.
Do not return an empty file.
"""


def validate_output(path: Path, url: str) -> tuple[bool, list[str]]:
    problems: list[str] = []
    if not path.exists():
        return False, ["output file missing"]
    text = path.read_text(encoding="utf-8", errors="replace").strip()
    if len(text) < 300:
        problems.append(f"output too small: {len(text)} bytes")
    lowered = text.lower()
    required_markers = ["title", "source_url", "body_summary", "image_candidates"]
    for marker in required_markers:
        if marker not in lowered:
            problems.append(f"missing marker: {marker}")
    if url not in text:
        problems.append("source url not present in output")
    if "failure_reason" not in lowered:
        problems.append("missing failure_reason")
    return not problems, problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument(
        "--workspace",
        default=os.environ.get("HARVIS_WEMEDIA_ROOT", str(Path.cwd())),
    )
    parser.add_argument("--material-dir", required=True)
    parser.add_argument("--output")
    parser.add_argument("--status-json")
    parser.add_argument("--kimicode", default=str(DEFAULT_KIMICODE))
    parser.add_argument("--auth-home", default=str(DEFAULT_AUTH_HOME))
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--timeout-seconds", type=int, default=240)
    args = parser.parse_args()

    material_dir = Path(args.material_dir)
    material_dir.mkdir(parents=True, exist_ok=True)
    output_path = Path(args.output) if args.output else material_dir / "kimi-source-package.md"
    status_path = Path(args.status_json) if args.status_json else material_dir / "kimi-source-status.json"
    stdout_path = material_dir / "kimi-source-ingest.stdout"
    stderr_path = material_dir / "kimi-source-ingest.stderr"
    for stale_path in (output_path, status_path, stdout_path, stderr_path):
        if stale_path.exists():
            stale_path.unlink()

    env = os.environ.copy()
    # Kimi Code stores model/provider configuration under the authenticated user
    # home. A workspace-local HOME made Kimi return empty output in smoke tests.
    env["HOME"] = str(Path(args.auth_home).expanduser())

    command = [
        str(Path(args.kimicode)),
        "-p",
        prompt_for(args.url),
        "--output-format",
        "text",
        "-m",
        args.model,
    ]
    started_at = utc_now()
    try:
        completed = subprocess.run(
            command,
            cwd=args.workspace,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=args.timeout_seconds + 30,
            check=False,
        )
        exit_code = completed.returncode
        stdout_path.write_text(completed.stdout or "", encoding="utf-8")
        stderr_path.write_text(completed.stderr or "", encoding="utf-8")
        output_path.write_text(completed.stdout or "", encoding="utf-8")
    except subprocess.TimeoutExpired as exc:
        exit_code = 124
        stdout_path.write_text(exc.stdout or "", encoding="utf-8")
        stderr_path.write_text(f"timeout after {args.timeout_seconds + 30}s\n{exc.stderr or ''}", encoding="utf-8")
    except FileNotFoundError as exc:
        exit_code = 127
        stdout_path.write_text("", encoding="utf-8")
        stderr_path.write_text(str(exc), encoding="utf-8")

    valid, problems = validate_output(output_path, args.url)
    status = {
        "schemaVersion": "harvis.kimi-source-ingest.v0",
        "worker": "kimicode",
        "runtime": "kimi-code-cli",
        "command": str(Path(args.kimicode)),
        "model": args.model,
        "started_at": started_at,
        "finished_at": utc_now(),
        "url": args.url,
        "workspace": args.workspace,
        "material_dir": str(material_dir),
        "output_path": str(output_path),
        "output_bytes": output_path.stat().st_size if output_path.exists() else 0,
        "stdout_path": str(stdout_path),
        "stderr_path": str(stderr_path),
        "exit_code": exit_code,
        "valid_source_package": bool(valid and exit_code == 0),
        "problems": problems,
        "auth_home": str(Path(args.auth_home).expanduser()),
        "note": "auth_home is a path only; no credential values are written.",
    }
    write_json(status_path, status)
    print(json.dumps(status, ensure_ascii=False, indent=2))
    return 0 if status["valid_source_package"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
