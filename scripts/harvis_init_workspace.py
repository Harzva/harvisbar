#!/usr/bin/env python3
"""Initialize a local H.A.R.V.I.S. file-trigger workspace."""

from __future__ import annotations

import argparse
from pathlib import Path


INBOX_TEMPLATE = """# H.A.R.V.I.S. Inbox

Write delegated local tasks by starting a line with the H.A.R.V.I.S. mention.
v0.2 only turns these tasks into work packets under .harvis/outbox/; it does not
edit source files, commit, push, publish, or deploy.

Task format:

    at-harvis review this workspace before publishing.
    Scope: current repository.
    Need: list blockers and safe next actions.

Replace `at-harvis` with the real mention marker when you want to create a task.
"""


CONFIG_TEMPLATE = """# H.A.R.V.I.S. local workspace config.
# v0.3-alpha scans allowlisted inboxes and writes read-only runtime state.
# v0.4 adds private memory snapshots and reviewable candidate signals.
# v0.5 adds a Planner / Executor / Reviewer workbench.
# v0.10 adds run, approval, and local runtime log directories.
# v0.16/v0.17 add harness handoff and Agent Room JSONL directories.
# v0.18/v0.19 add Persona / Copy-Me registry and personality review queue.
# v0.32 adds a read-only local knowledge graph scanner.

autonomy_level = 1
default_inbox = ".harvis/inbox.md"
default_outbox = ".harvis/outbox"
default_reports = ".harvis/reports"
status_file = ".harvis/status.json"
event_log = ".harvis/events.jsonl"
memory_snapshots = ".harvis/memory/snapshots"
memory_signals = ".harvis/memory/signals"
workbench = ".harvis/workbench"
runs = ".harvis/runs"
approvals = ".harvis/approvals"
logs = ".harvis/logs"
handoffs = ".harvis/handoffs"
agent_room = ".harvis/agent-room"
persona_registry = ".harvis/persona"
tick_interval_seconds = 1200
allowlist = [".harvis/inbox.md"]
"""


KNOWLEDGE_GRAPH_TEMPLATE = """# H.A.R.V.I.S. local knowledge graph config.
# The graph scanner is read-only. It scans only vaults allowlisted here and
# returns redacted JSON by default.

[graph]
vaults = ["."]
ignore_dirs = [".obsidian", ".git", "node_modules", "attachments", "data", "logs", "models", "adapters", "runtime", "private"]
max_files = 1000
max_nodes = 1500
max_edges = 4000
include_paths = false
include_missing_targets = true
"""


def write_file(path: Path, content: str, force: bool) -> bool:
    if path.exists() and not force:
        return False
    path.write_text(content, encoding="utf-8")
    return True


def init_workspace(root: Path, force: bool) -> list[str]:
    root = root.expanduser().resolve()
    harvis_dir = root / ".harvis"
    outbox_dir = harvis_dir / "outbox"
    archive_dir = harvis_dir / "archive"
    reports_dir = harvis_dir / "reports"
    memory_snapshots_dir = harvis_dir / "memory" / "snapshots"
    memory_signals_dir = harvis_dir / "memory" / "signals"
    workbench_dir = harvis_dir / "workbench"
    runs_dir = harvis_dir / "runs"
    approvals_dir = harvis_dir / "approvals"
    logs_dir = harvis_dir / "logs"
    handoffs_dir = harvis_dir / "handoffs"
    agent_room_dir = harvis_dir / "agent-room"
    persona_dir = harvis_dir / "persona"

    harvis_dir.mkdir(parents=True, exist_ok=True)
    outbox_dir.mkdir(parents=True, exist_ok=True)
    archive_dir.mkdir(parents=True, exist_ok=True)
    reports_dir.mkdir(parents=True, exist_ok=True)
    memory_snapshots_dir.mkdir(parents=True, exist_ok=True)
    memory_signals_dir.mkdir(parents=True, exist_ok=True)
    workbench_dir.mkdir(parents=True, exist_ok=True)
    runs_dir.mkdir(parents=True, exist_ok=True)
    approvals_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)
    handoffs_dir.mkdir(parents=True, exist_ok=True)
    agent_room_dir.mkdir(parents=True, exist_ok=True)
    persona_dir.mkdir(parents=True, exist_ok=True)

    messages = [
        f"created or verified: {harvis_dir}",
        f"created or verified: {outbox_dir}",
        f"created or verified: {archive_dir}",
        f"created or verified: {reports_dir}",
        f"created or verified: {memory_snapshots_dir}",
        f"created or verified: {memory_signals_dir}",
        f"created or verified: {workbench_dir}",
        f"created or verified: {runs_dir}",
        f"created or verified: {approvals_dir}",
        f"created or verified: {logs_dir}",
        f"created or verified: {handoffs_dir}",
        f"created or verified: {agent_room_dir}",
        f"created or verified: {persona_dir}",
    ]

    inbox_path = harvis_dir / "inbox.md"
    config_path = harvis_dir / "harvis.toml"
    graph_config_path = harvis_dir / "knowledge_graph.toml"

    if write_file(inbox_path, INBOX_TEMPLATE, force):
        messages.append(f"wrote: {inbox_path}")
    else:
        messages.append(f"kept existing: {inbox_path}")

    if write_file(config_path, CONFIG_TEMPLATE, force):
        messages.append(f"wrote: {config_path}")
    else:
        messages.append(f"kept existing: {config_path}")

    if write_file(graph_config_path, KNOWLEDGE_GRAPH_TEMPLATE, force):
        messages.append(f"wrote: {graph_config_path}")
    else:
        messages.append(f"kept existing: {graph_config_path}")

    return messages


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Initialize .harvis inbox, outbox, archive, and config."
    )
    parser.add_argument(
        "--root",
        default=".",
        help="Workspace root where .harvis should be created.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing .harvis/inbox.md and .harvis/harvis.toml.",
    )
    args = parser.parse_args()

    for message in init_workspace(Path(args.root), args.force):
        print(message)
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("init-workspace", legacy_main=main))
