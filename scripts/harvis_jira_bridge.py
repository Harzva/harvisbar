#!/usr/bin/env python3
"""Bridge Jira issue JSON into the H.A.R.V.I.S. execution ledger."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


BRIDGE_VERSION = "harvis-jira-bridge.v0"


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def timestamp_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def resolve_root(value: str) -> Path:
    root = Path(value).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def plugin_root() -> Path:
    return Path(__file__).resolve().parent.parent


def harvis_cli() -> Path:
    return plugin_root() / "scripts" / "harvis"


def load_issue(path: Path) -> dict[str, Any]:
    loaded = json.loads(path.expanduser().read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise SystemExit("issue JSON must be an object")
    if "data" in loaded and isinstance(loaded["data"], dict):
        loaded = loaded["data"]
    if "issue" in loaded and isinstance(loaded["issue"], dict):
        loaded = loaded["issue"]
    if "issues" in loaded and isinstance(loaded["issues"], list) and loaded["issues"]:
        loaded = loaded["issues"][0]
    if "key" not in loaded:
        raise SystemExit("issue JSON does not contain a Jira issue key")
    return loaded


def text_from_adf(value: Any, limit: int = 1200) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return " ".join(value.split())[:limit]
    if isinstance(value, dict):
        pieces: list[str] = []
        if isinstance(value.get("text"), str):
            pieces.append(value["text"])
        for child in value.get("content") or []:
            pieces.append(text_from_adf(child, limit))
        return " ".join(" ".join(pieces).split())[:limit]
    if isinstance(value, list):
        return " ".join(text_from_adf(item, limit) for item in value)[:limit]
    return str(value)[:limit]


def issue_summary(issue: dict[str, Any]) -> dict[str, Any]:
    fields = issue.get("fields") if isinstance(issue.get("fields"), dict) else {}
    status = fields.get("status") if isinstance(fields.get("status"), dict) else {}
    issue_type = fields.get("issuetype") if isinstance(fields.get("issuetype"), dict) else {}
    assignee = fields.get("assignee") if isinstance(fields.get("assignee"), dict) else {}
    return {
        "key": str(issue.get("key", "")).strip(),
        "id": str(issue.get("id", "")).strip() or None,
        "url": issue.get("self"),
        "summary": str(fields.get("summary") or issue.get("summary") or "").strip(),
        "description": text_from_adf(fields.get("description")),
        "status": status.get("name"),
        "issue_type": issue_type.get("name"),
        "assignee": assignee.get("displayName") or assignee.get("emailAddress"),
        "labels": fields.get("labels") or [],
        "issue_links": fields.get("issuelinks") or [],
    }


def safe_text(value: str, limit: int = 1000) -> str:
    return " ".join(value.replace("\x00", "").split())[:limit]


def stable_id(prefix: str, *parts: str) -> str:
    seed = ":".join(parts)
    digest = hashlib.sha256(seed.encode("utf-8")).hexdigest()[:12]
    return f"{prefix}_{digest}"


def append_jsonl(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")


def rel(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.name


def outbox_packets(root: Path) -> set[Path]:
    outbox = root / ".harvis" / "outbox"
    if not outbox.exists():
        return set()
    return {path for path in outbox.glob("*.md") if path.is_file()}


def run_harvis(args: list[str]) -> dict[str, Any]:
    command = [str(harvis_cli()), *args]
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return {
        "command": command,
        "exit_code": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def write_inbox_entry(root: Path, issue: dict[str, Any]) -> Path:
    harvis_dir = root / ".harvis"
    harvis_dir.mkdir(parents=True, exist_ok=True)
    inbox = harvis_dir / "inbox.md"
    if not inbox.exists():
        inbox.write_text("# H.A.R.V.I.S. Inbox\n\n", encoding="utf-8")
    title = issue["summary"] or issue["key"]
    lines = [
        "",
        f"@harvis Jira {issue['key']}: {title}",
        "Scope: Jira issue imported through harvis_jira_bridge; do not execute automatically.",
        f"Jira-Issue-Key: {issue['key']}",
        f"Jira-Status: {issue.get('status') or 'unknown'}",
        f"Jira-Type: {issue.get('issue_type') or 'unknown'}",
        f"Jira-Assignee: {issue.get('assignee') or 'unassigned'}",
        f"Jira-URL: {issue.get('url') or 'unknown'}",
        f"Received: {now_utc()}",
        "Need: triage the issue, choose the smallest safe action, and ask for approval before code, Jira writeback, GitHub PR, publish, deploy, delete, or external side effects.",
        "",
    ]
    with inbox.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    return inbox


def packet_ids(paths: list[Path]) -> list[str]:
    return [path.stem for path in paths]


def create_task_record(
    root: Path,
    *,
    issue: dict[str, Any],
    packets: list[Path],
    runs: list[str],
) -> dict[str, Any]:
    room = root / ".harvis" / "agent-room"
    room.mkdir(parents=True, exist_ok=True)
    task_id = stable_id("task", "jira", issue["key"], issue["summary"])
    packet_id = packet_ids(packets)[0] if packets else None
    run_id = runs[0] if runs else (f"run_{packet_id}" if packet_id else None)
    moment = now_utc()
    task = {
        "agent_room_version": "v0.49-agent-room-protocol",
        "gwt_workbench_version": "v0.55-gwt-cowork-workbench",
        "record_type": "task",
        "task_id": task_id,
        "topic_id": "gwt-workbench",
        "title": safe_text(f"Jira {issue['key']}: {issue['summary']}", 300),
        "description": safe_text(issue.get("description") or "Imported Jira issue.", 1000),
        "owner_slot_id": "planner",
        "status": "waiting_approval",
        "source_event_id": f"jira:{issue['key']}",
        "approval_id": None,
        "handoff_id": None,
        "run_id": run_id,
        "packet_id": packet_id,
        "metadata": {
            "intent": "external_work_item",
            "source_type": "jira",
            "source_id": issue["key"],
            "source_url": issue.get("url"),
            "external_status": issue.get("status"),
            "external_issue_type": issue.get("issue_type"),
            "assignee": issue.get("assignee"),
            "labels": issue.get("labels") or [],
            "packet_ids": packet_ids(packets),
            "run_ids": runs,
            "result_export": {
                "jira_comment_ready": None,
                "jira_transition_ready": None,
                "github_pr_ready": None,
            },
        },
        "created_at": moment,
        "updated_at": None,
        "safety": {"executes_task": False, "record_only": True},
    }
    append_jsonl(room / "tasks.jsonl", task)
    event = {
        "agent_room_version": "v0.49-agent-room-protocol",
        "record_type": "event",
        "event_id": stable_id("event", task_id, moment),
        "topic_id": "gwt-workbench",
        "agent_id": "harvis-jira-bridge",
        "role": "integration",
        "event_type": "task.created",
        "summary": f"Jira issue {issue['key']} imported as waiting_approval task.",
        "created_at": moment,
        "source_refs": [f"jira:{issue['key']}"],
        "metadata": {
            "task_id": task_id,
            "source_type": "jira",
            "packet_id": packet_id,
            "run_id": run_id,
            "record_only": True,
        },
    }
    append_jsonl(room / "events.jsonl", event)
    return task


def parse_runs(stdout: str) -> list[str]:
    try:
        parsed = json.loads(stdout)
    except Exception:
        return []
    runs = parsed.get("runs") if isinstance(parsed, dict) else None
    if not isinstance(runs, list):
        return []
    result: list[str] = []
    for run in runs:
        if isinstance(run, dict) and isinstance(run.get("run_id"), str):
            result.append(run["run_id"])
    return result


def issue_to_work_item(args: argparse.Namespace) -> dict[str, Any]:
    root = resolve_root(args.root)
    issue = issue_summary(load_issue(Path(args.issue_json)))
    if not issue["key"]:
        raise SystemExit("issue key is required")
    before = outbox_packets(root)
    if args.dry_run:
        return {
            "ok": True,
            "dry_run": True,
            "bridge_version": BRIDGE_VERSION,
            "issue": issue,
            "would_write": [
                ".harvis/inbox.md",
                ".harvis/outbox/*.md",
                ".harvis/runs/*.json",
                ".harvis/agent-room/tasks.jsonl",
                ".harvis/agent-room/events.jsonl",
            ],
            "safety": {"executes_task": False, "requires_approval": True},
        }
    inbox = write_inbox_entry(root, issue)
    scan = run_harvis(["scan-inbox", "--root", str(root), str(inbox)])
    after = outbox_packets(root)
    new_packets = sorted(after - before)
    sync = run_harvis(
        ["sync-runs", "--root", str(root), *sum([["--packet", str(path)] for path in new_packets], [])]
    ) if new_packets else {"stdout": "", "stderr": "", "exit_code": 0}
    runs = parse_runs(sync.get("stdout", ""))
    task = create_task_record(root, issue=issue, packets=new_packets, runs=runs)
    return {
        "ok": scan["exit_code"] == 0 and sync["exit_code"] == 0,
        "dry_run": False,
        "bridge_version": BRIDGE_VERSION,
        "issue": issue,
        "inbox": rel(inbox, root),
        "packets": [rel(path, root) for path in new_packets],
        "runs": runs,
        "task": task,
        "scan": {k: scan[k] for k in ["exit_code", "stderr"]},
        "sync": {k: sync[k] for k in ["exit_code", "stderr"]},
    }


def result_export(args: argparse.Namespace) -> dict[str, Any]:
    root = resolve_root(args.root)
    issue_key = safe_text(args.issue_key, 80)
    if not issue_key:
        raise SystemExit("--issue-key is required")
    task_ref = args.task_id or args.packet_id or args.run_id or "unlinked"
    summary = safe_text(args.summary, 4000)
    moment = now_utc()
    body = "\n".join(
        [
            "H.A.R.V.I.S. result ready for review.",
            "",
            f"Summary: {summary}",
            f"Task: {args.task_id or 'unknown'}",
            f"Packet: {args.packet_id or 'unknown'}",
            f"Run: {args.run_id or 'unknown'}",
            "",
            "Safety: this payload was generated locally and does not execute Jira or GitHub writes by itself.",
        ]
    )
    payload = {
        "bridge_version": BRIDGE_VERSION,
        "created_at": moment,
        "source_type": "jira",
        "source_id": issue_key,
        "task_id": args.task_id,
        "packet_id": args.packet_id,
        "run_id": args.run_id,
        "jira_comment_ready": {
            "issue_key": issue_key,
            "body": body,
            "requires_approval": True,
        },
        "jira_transition_ready": {
            "issue_key": issue_key,
            "transition_id": args.transition_id,
            "target_status": args.target_status,
            "requires_approval": True,
        } if args.transition_id or args.target_status else None,
        "github_pr_ready": {
            "enabled": False,
            "reason": "First phase is PR-ready only; no commit, push, or PR creation.",
        },
        "safety": {
            "executes_task": False,
            "writes_jira": False,
            "writes_github": False,
            "requires_approval_for_external_write": True,
        },
    }
    if args.dry_run:
        return {"ok": True, "dry_run": True, "result_export": payload}
    export_dir = root / ".harvis" / "jira" / "exports"
    export_dir.mkdir(parents=True, exist_ok=True)
    export_path = export_dir / f"{issue_key}-{timestamp_slug()}-{stable_id('export', issue_key, task_ref)[-12:]}.json"
    export_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    room = root / ".harvis" / "agent-room"
    append_jsonl(
        room / "events.jsonl",
        {
            "agent_room_version": "v0.49-agent-room-protocol",
            "record_type": "event",
            "event_id": stable_id("event", issue_key, task_ref, moment),
            "topic_id": "gwt-workbench",
            "agent_id": "harvis-jira-bridge",
            "role": "integration",
            "event_type": "result_export.ready",
            "summary": f"Jira writeback payload ready for {issue_key}.",
            "created_at": moment,
            "source_refs": [f"jira:{issue_key}"],
            "metadata": {
                "export_path": rel(export_path, root),
                "task_id": args.task_id,
                "packet_id": args.packet_id,
                "run_id": args.run_id,
                "requires_approval": True,
            },
        },
    )
    return {
        "ok": True,
        "dry_run": False,
        "export_path": rel(export_path, root),
        "result_export": payload,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    issue = sub.add_parser("issue-to-work-item", help="Import a Jira issue JSON fixture into Harvis.")
    issue.add_argument("--root", required=True)
    issue.add_argument("--issue-json", required=True)
    issue.add_argument("--dry-run", action="store_true")
    issue.set_defaults(func=issue_to_work_item)

    export = sub.add_parser("result-export", help="Generate Jira-ready writeback payload.")
    export.add_argument("--root", required=True)
    export.add_argument("--issue-key", required=True)
    export.add_argument("--summary", required=True)
    export.add_argument("--task-id")
    export.add_argument("--packet-id")
    export.add_argument("--run-id")
    export.add_argument("--transition-id")
    export.add_argument("--target-status")
    export.add_argument("--dry-run", action="store_true")
    export.set_defaults(func=result_export)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        print(json.dumps(args.func(args), ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except SystemExit:
        raise
    except Exception as error:
        print(json.dumps({"ok": False, "error": type(error).__name__, "message": str(error)}, indent=2), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
