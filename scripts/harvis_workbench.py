#!/usr/bin/env python3
"""Prepare H.A.R.V.I.S. Planner / Executor / Reviewer workbench briefs."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from harvis_inbox_scan import SENSITIVE_PATTERNS, is_within_root  # noqa: E402
from harvis_memory_snapshot import profile_metadata  # noqa: E402


WORKBENCH_VERSION = "v0.5"


def now_utc() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def rel(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def resolve_workspace_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def sensitive_detected(text: str) -> bool:
    return any(pattern.search(text) for pattern in SENSITIVE_PATTERNS)


def redact_sensitive_lines(text: str) -> tuple[str, bool]:
    lines: list[str] = []
    found = False
    for line in text.splitlines():
        if sensitive_detected(line):
            found = True
            lines.append("[redacted sensitive-looking line]")
        else:
            lines.append(line)
    return "\n".join(lines).strip(), found


def parse_prefixed_line(text: str, prefix: str) -> str | None:
    for line in text.splitlines():
        if line.startswith(prefix):
            return line.split(":", 1)[1].strip() or None
    return None


def parse_request(text: str) -> str:
    fenced = re.search(r"## Request\s+```text\n(?P<body>.*?)\n```", text, re.DOTALL)
    if fenced:
        return fenced.group("body").strip()
    marker = "## Request"
    if marker in text:
        after = text.split(marker, 1)[1]
        for stop in ["## Suggested Plan", "## Verification Checklist"]:
            if stop in after:
                after = after.split(stop, 1)[0]
        return after.strip()
    return text.strip()


def parse_packet(path: Path, root: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    request, request_had_sensitive = redact_sensitive_lines(parse_request(text))
    return {
        "packet_id": path.stem,
        "path": rel(path, root),
        "status": parse_prefixed_line(text, "Status:") or "unknown",
        "source": parse_prefixed_line(text, "Source:"),
        "safety": parse_prefixed_line(text, "Safety:"),
        "request": request,
        "sensitive_marker_detected": request_had_sensitive or sensitive_detected(text),
    }


def resolve_packet(root: Path, packet: str) -> Path:
    outbox = root / ".harvis" / "outbox"
    candidate = Path(packet).expanduser()
    if not candidate.suffix:
        candidate = outbox / f"{packet}.md"
    elif not candidate.is_absolute() and candidate.parent == Path("."):
        candidate = outbox / candidate.name
    elif not candidate.is_absolute():
        candidate = root / candidate
    candidate = candidate.resolve()
    if not is_within_root(candidate, outbox.resolve()):
        raise SystemExit(f"packet must be under .harvis/outbox: {candidate}")
    if not candidate.exists():
        raise SystemExit(f"packet not found: {candidate}")
    return candidate


def select_packets(root: Path, packet: str | None, limit: int) -> list[Path]:
    if packet:
        return [resolve_packet(root, packet)]
    outbox = root / ".harvis" / "outbox"
    if not outbox.exists():
        raise SystemExit(f"outbox not found: {outbox}")
    return sorted(outbox.glob("*.md"), key=lambda item: item.stat().st_mtime, reverse=True)[:limit]


def write_text(path: Path, lines: list[str]) -> None:
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def planner_lines(packet: dict[str, Any], generated_at: str) -> list[str]:
    return [
        "# Planner Brief",
        "",
        f"Packet: {packet['packet_id']}",
        f"Generated: {generated_at}",
        "Autonomy: Level 1 preparation only",
        "",
        "Request:",
        "```text",
        packet["request"],
        "```",
        "",
        "Scope:",
        f"- Source packet: {packet['path']}",
        f"- Source request: {packet.get('source') or 'unknown'}",
        f"- Current status: {packet['status']}",
        "",
        "Risks:",
        f"- Safety note: {packet.get('safety') or 'none recorded'}",
        f"- Sensitive marker detected: {packet['sensitive_marker_detected']}",
        "- Mutations, commits, publishing, deployment, deletion, and external sharing require approval.",
        "",
        "Plan:",
        "1. Re-read applicable local rules before any execution.",
        "2. Confirm the task stays inside the requested workspace and approved context.",
        "3. Gather only the smallest required context.",
        "4. Produce a bounded implementation or review plan.",
        "5. Verify results before asking H.A.R.V.I.S. to report completion.",
        "",
        "Done When:",
        "- Scope, risks, proposed steps, and verification gates are clear enough for a human-approved execution pass.",
    ]


def executor_lines(packet: dict[str, Any], generated_at: str) -> list[str]:
    return [
        "# Executor Brief",
        "",
        f"Packet: {packet['packet_id']}",
        f"Generated: {generated_at}",
        "Autonomy: Level 1 preparation only",
        "",
        "Execution Boundary:",
        "- This brief does not execute the task.",
        "- Read-only inspection is allowed inside the approved workspace.",
        "- File edits require explicit user approval or a later approved execution mode.",
        "- Commit, push, publish, deploy, delete, reset, and external API actions require explicit approval.",
        "",
        "Read-only Preparation Checklist:",
        "1. Read AGENTS.md and local project rules.",
        "2. Identify exact files or commands that would be needed.",
        "3. Check whether the packet is blocked or sensitive.",
        "4. Prepare a minimal execution path and verification command list.",
        "",
        "Gated Actions:",
        "- Source edits: approval required.",
        "- Destructive operations: approval required.",
        "- Public artifacts: safety scan required before publishing.",
        "- Memory adoption: human review required.",
    ]


def reviewer_lines(packet: dict[str, Any], generated_at: str) -> list[str]:
    return [
        "# Reviewer Brief",
        "",
        f"Packet: {packet['packet_id']}",
        f"Generated: {generated_at}",
        "Autonomy: Level 1 preparation only",
        "",
        "Review Questions:",
        "- Did the work stay inside the packet scope?",
        "- Were local rules and privacy boundaries followed?",
        "- Were tests, smoke checks, or safety scans run?",
        "- Were source files outside `.harvis/` changed only after approval?",
        "- Does any output expose credentials, raw logs, raw memory, hidden prompts, or private access files?",
        "",
        "Verification Checklist:",
        "1. Check packet status and safety note.",
        "2. Confirm generated artifacts are under approved output directories.",
        "3. Confirm public-facing outputs pass safety checks when available.",
        "4. Confirm H.A.R.V.I.S. summary names remaining risks and follow-ups.",
    ]


def summary_lines(packet: dict[str, Any], generated_at: str, output_paths: dict[str, str]) -> list[str]:
    return [
        "# H.A.R.V.I.S. Workbench Summary",
        "",
        f"Packet: {packet['packet_id']}",
        f"Generated: {generated_at}",
        "Status: role briefs prepared",
        "Autonomy: Level 1 preparation only",
        "",
        "Prepared Files:",
        f"- Planner: {output_paths['planner']}",
        f"- Executor: {output_paths['executor']}",
        f"- Reviewer: {output_paths['reviewer']}",
        "",
        "Coordinator View:",
        "- H.A.R.V.I.S. has decomposed the packet into role-specific briefs.",
        "- No code, source file, commit, publish, deploy, or destructive operation was performed.",
        "- The next step is human-approved execution or review of the Planner brief.",
        "",
        "Packet Safety:",
        f"- Packet status: {packet['status']}",
        f"- Safety note: {packet.get('safety') or 'none recorded'}",
        f"- Sensitive marker detected: {packet['sensitive_marker_detected']}",
    ]


def prepare_packet_workbench(root: Path, profile_root: Path, packet_path: Path) -> dict[str, Any]:
    generated_at = now_utc().isoformat()
    packet = parse_packet(packet_path, root)
    workbench_dir = root / ".harvis" / "workbench" / packet["packet_id"]
    workbench_dir.mkdir(parents=True, exist_ok=True)

    paths = {
        "planner": workbench_dir / "planner.md",
        "executor": workbench_dir / "executor.md",
        "reviewer": workbench_dir / "reviewer.md",
        "summary": workbench_dir / "harvis-summary.md",
        "index": workbench_dir / "index.json",
    }
    output_labels = {name: rel(path, root) for name, path in paths.items()}

    write_text(paths["planner"], planner_lines(packet, generated_at))
    write_text(paths["executor"], executor_lines(packet, generated_at))
    write_text(paths["reviewer"], reviewer_lines(packet, generated_at))
    write_text(paths["summary"], summary_lines(packet, generated_at, output_labels))
    index = {
        "workbench_version": WORKBENCH_VERSION,
        "packet_id": packet["packet_id"],
        "packet_path": packet["path"],
        "generated_at": generated_at,
        "autonomy_level": 1,
        "status": "prepared",
        "profile": profile_metadata(profile_root),
        "outputs": output_labels,
    }
    paths["index"].write_text(json.dumps(index, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    return {
        "packet_id": packet["packet_id"],
        "packet_path": packet["path"],
        "workbench_dir": rel(workbench_dir, root),
        "outputs": output_labels,
        "sensitive_marker_detected": packet["sensitive_marker_detected"],
    }


def prepare_workbench(
    root: Path,
    profile_root: Path,
    packet: str | None = None,
    limit: int = 5,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    limit = max(1, min(limit, 100))
    packets = select_packets(root, packet, limit)
    prepared = [prepare_packet_workbench(root, profile_root.expanduser().resolve(), path) for path in packets]
    return {
        "workspace_root": str(root),
        "packet_count": len(prepared),
        "prepared": prepared,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prepare H.A.R.V.I.S. Planner / Executor / Reviewer workbench briefs."
    )
    parser.add_argument("--root", default=".", type=Path, help="Workspace root containing .harvis/.")
    parser.add_argument(
        "--profile-root",
        default="~/.harvis",
        type=Path,
        help="H.A.R.V.I.S. runtime profile root. Defaults to ~/.harvis.",
    )
    parser.add_argument("--packet", help="Packet ID or path under .harvis/outbox/.")
    parser.add_argument("--limit", default=5, type=int, help="Maximum newest packets when --packet is omitted.")
    args = parser.parse_args()

    result = prepare_workbench(args.root, args.profile_root, args.packet, args.limit)
    print(f"prepared packets: {result['packet_count']}")
    for item in result["prepared"]:
        print(f"packet: {item['packet_id']} -> {item['workbench_dir']}")
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("prepare-workbench", legacy_main=main))
