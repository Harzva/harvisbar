#!/usr/bin/env python3
"""Scan H.A.R.V.I.S. inbox files and emit local work packets."""

from __future__ import annotations

import argparse
import hashlib
import re
import textwrap
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


SENSITIVE_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in [
        r"\bapi[_-]?key\b",
        r"\bsecret\b",
        r"\btoken\b",
        r"\bpassword\b",
        r"\bcookie\b",
        r"\bcredential\b",
        r"\bprivate\s+key\b",
        r"\.env\b",
        r"BEGIN\s+(RSA\s+|OPENSSH\s+|EC\s+)?PRIVATE\s+KEY",
    ]
]

TASK_MARKER = re.compile(r"^\s*(?:[-*]\s+(?:\[[ xX]\]\s+)?)?@harvis\b")


@dataclass(frozen=True)
class HarvisTask:
    source: Path
    line_number: int
    body: str

    def task_id(self, root: Path) -> str:
        try:
            source_label = self.source.resolve().relative_to(root).as_posix()
        except ValueError:
            source_label = self.source.resolve().as_posix()
        seed = f"{source_label}:{self.line_number}:{self.body}"
        return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:12]


def is_within_root(path: Path, root: Path) -> bool:
    resolved_path = path.expanduser().resolve()
    resolved_root = root.expanduser().resolve()
    return resolved_path == resolved_root or resolved_root in resolved_path.parents


def classify_task(body: str) -> tuple[str, str]:
    for pattern in SENSITIVE_PATTERNS:
        if pattern.search(body):
            return "blocked", "sensitive-looking content requires human review"
    return "new", "no sensitive marker detected"


def parse_tasks(inbox_path: Path) -> list[HarvisTask]:
    lines = inbox_path.read_text(encoding="utf-8").splitlines()
    tasks: list[HarvisTask] = []
    current_start: int | None = None
    current_lines: list[str] = []

    def flush() -> None:
        nonlocal current_start, current_lines
        if current_start is None:
            return
        body = "\n".join(line.rstrip() for line in current_lines).strip()
        if body:
            tasks.append(HarvisTask(inbox_path, current_start, body))
        current_start = None
        current_lines = []

    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        if TASK_MARKER.search(line):
            flush()
            current_start = index
            current_lines = [line]
            continue
        if current_start is None:
            continue
        if stripped.startswith("#"):
            flush()
            continue
        current_lines.append(line)

    flush()
    return tasks


def packet_for_task(task: HarvisTask, root: Path) -> str:
    task_id = task.task_id(root)
    status, safety_note = classify_task(task.body)
    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    try:
        source_label = task.source.resolve().relative_to(root).as_posix()
    except ValueError:
        source_label = task.source.resolve().as_posix()

    request_block = textwrap.indent(task.body, "")
    return "\n".join(
        [
            f"# H.A.R.V.I.S. Work Packet {task_id}",
            "",
            f"Status: {status}",
            f"Source: {source_label}:{task.line_number}",
            f"Generated: {generated_at}",
            "Scope: current H.A.R.V.I.S. workspace",
            f"Safety: {safety_note}",
            "",
            "## Request",
            "",
            "```text",
            request_block,
            "```",
            "",
            "## Suggested Plan",
            "",
            "1. Read local project rules and relevant docs.",
            "2. Confirm the request stays inside the current workspace and approved context.",
            "3. Execute the smallest safe next action, or ask one focused question if blocked.",
            "4. Verify the result and report files touched, checks run, and follow-ups.",
            "",
            "## Verification Checklist",
            "",
            "- Confirm no source files outside `.harvis/` were changed by inbox scanning.",
            "- Confirm sensitive or private material was not copied into public artifacts.",
            "- Confirm any publish, commit, push, or destructive action has explicit approval.",
            "",
        ]
    )


def scan_inboxes(root: Path, inboxes: list[Path], allow_outside_root: bool) -> list[Path]:
    root = root.expanduser().resolve()
    outbox = root / ".harvis" / "outbox"
    outbox.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    for inbox in inboxes:
        inbox_path = inbox.expanduser().resolve()
        if not allow_outside_root and not is_within_root(inbox_path, root):
            raise SystemExit(f"refusing to scan outside root: {inbox_path}")
        if not inbox_path.exists():
            raise SystemExit(f"inbox not found: {inbox_path}")
        for task in parse_tasks(inbox_path):
            task_id = task.task_id(root)
            packet_path = outbox / f"{task_id}.md"
            packet_path.write_text(packet_for_task(task, root), encoding="utf-8")
            written.append(packet_path)

    return written


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Scan .harvis inbox files and generate H.A.R.V.I.S. work packets."
    )
    parser.add_argument(
        "inboxes",
        nargs="*",
        type=Path,
        help="Explicit inbox files. Defaults to .harvis/inbox.md under --root.",
    )
    parser.add_argument(
        "--root",
        default=".",
        type=Path,
        help="Workspace root containing .harvis/.",
    )
    parser.add_argument(
        "--allow-outside-root",
        action="store_true",
        help="Allow explicit inbox files outside --root.",
    )
    args = parser.parse_args()

    root = args.root.expanduser().resolve()
    inboxes = args.inboxes or [root / ".harvis" / "inbox.md"]
    written = scan_inboxes(root, inboxes, args.allow_outside_root)
    if not written:
        print("No @harvis tasks found.")
        return 0
    for path in written:
        print(f"wrote: {path}")
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("scan-inbox", legacy_main=main))
