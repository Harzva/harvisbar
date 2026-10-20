#!/usr/bin/env python3
"""H.A.R.V.I.S. Agent Room JSONL store and harness handoff contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


AGENT_ROOM_VERSION = "v0.17-alpha"
HANDOFF_VERSION = "v0.17-alpha"
ALLOWED_HARNESSES = {
    "codex",
    "dsh",
    "claude",
    "claude-code",
    "kimicode",
    "likecode",
    "manual",
}


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def timestamp_compact() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def resolve_workspace_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def rel(path: Path, root: Path) -> str:
    try:
        return path.expanduser().resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.name


def stable_id(prefix: str, *parts: object) -> str:
    body = "|".join(str(part) for part in parts if part is not None)
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()[:10]
    return f"{prefix}_{timestamp_compact()}_{digest}"


def agent_room_dir(root: Path) -> Path:
    path = root / ".harvis" / "agent-room"
    path.mkdir(parents=True, exist_ok=True)
    return path


def handoffs_dir(root: Path) -> Path:
    path = root / ".harvis" / "handoffs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def jsonl_path(root: Path, name: str) -> Path:
    return agent_room_dir(root) / f"{name}.jsonl"


def append_jsonl(path: Path, item: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(item, sort_keys=True) + "\n")


def read_jsonl(path: Path, limit: int = 50) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    for line in lines[-limit:]:
        if not line.strip():
            continue
        try:
            loaded = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(loaded, dict):
            rows.append(loaded)
    return rows


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return loaded if isinstance(loaded, dict) else None


def write_json(path: Path, item: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(item, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def init_agent_room(root: Path) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    room = agent_room_dir(root)
    for name in ["topics", "events", "messages"]:
        (room / f"{name}.jsonl").touch(exist_ok=True)
    handoffs_dir(root)
    return {
        "agent_room_version": AGENT_ROOM_VERSION,
        "workspace": {"label": root.name or "workspace"},
        "paths": {
            "topics": rel(room / "topics.jsonl", root),
            "events": rel(room / "events.jsonl", root),
            "messages": rel(room / "messages.jsonl", root),
            "handoffs": rel(root / ".harvis" / "handoffs", root),
        },
    }


def create_topic(root: Path, title: str, goal: str = "", created_by: str = "harvis") -> dict[str, Any]:
    root = resolve_workspace_root(root)
    init_agent_room(root)
    title = title.strip()
    if not title:
        raise SystemExit("topic title is required")
    topic_id = stable_id("topic", title, goal, created_by)
    topic = {
        "agent_room_version": AGENT_ROOM_VERSION,
        "topic_id": topic_id,
        "title": title,
        "goal": goal.strip(),
        "status": "open",
        "created_by": created_by,
        "created_at": now_utc(),
    }
    append_jsonl(jsonl_path(root, "topics"), topic)
    add_event(
        root,
        topic_id=topic_id,
        agent_id="harvis",
        role="coordinator",
        event_type="topic.created",
        content=f"Created Agent Room topic: {title}",
        source_refs=[],
    )
    return topic


def add_event(
    root: Path,
    topic_id: str,
    agent_id: str,
    role: str,
    event_type: str,
    content: str = "",
    source_refs: list[str] | None = None,
    source_age: str | None = None,
    sensitivity: str = "internal",
    model: str | None = None,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    init_agent_room(root)
    event = {
        "agent_room_version": AGENT_ROOM_VERSION,
        "event_id": stable_id("evt", topic_id, agent_id, event_type, content),
        "topic_id": topic_id,
        "agent_id": agent_id,
        "role": role,
        "event_type": event_type,
        "model": model,
        "source_refs": source_refs or [],
        "source_age": source_age,
        "sensitivity": sensitivity,
        "content": content.strip(),
        "created_at": now_utc(),
    }
    append_jsonl(jsonl_path(root, "events"), event)
    return event


def add_message(
    root: Path,
    topic_id: str,
    agent_id: str,
    role: str,
    content: str,
    source_refs: list[str] | None = None,
    sensitivity: str = "internal",
    model: str | None = None,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    init_agent_room(root)
    if not content.strip():
        raise SystemExit("message content is required")
    message = {
        "agent_room_version": AGENT_ROOM_VERSION,
        "message_id": stable_id("msg", topic_id, agent_id, content),
        "topic_id": topic_id,
        "agent_id": agent_id,
        "role": role,
        "model": model,
        "source_refs": source_refs or [],
        "sensitivity": sensitivity,
        "content": content.strip(),
        "created_at": now_utc(),
    }
    append_jsonl(jsonl_path(root, "messages"), message)
    add_event(
        root,
        topic_id=topic_id,
        agent_id=agent_id,
        role=role,
        event_type="message.created",
        content=f"Message recorded: {message['message_id']}",
        source_refs=source_refs or [],
        sensitivity=sensitivity,
        model=model,
    )
    return message


def list_agent_room(root: Path, limit: int = 50) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    return {
        "agent_room_version": AGENT_ROOM_VERSION,
        "workspace": {"label": root.name or "workspace"},
        "topics": read_jsonl(jsonl_path(root, "topics"), limit),
        "events": read_jsonl(jsonl_path(root, "events"), limit),
        "messages": read_jsonl(jsonl_path(root, "messages"), limit),
        "handoffs": list_handoffs(root, limit).get("handoffs", []),
    }


def run_json_path(root: Path, run_id: str) -> Path:
    candidate = root / ".harvis" / "runs" / f"{run_id}.json"
    if not candidate.exists():
        raise SystemExit(f"run not found: {run_id}")
    return candidate


def request_handoff(
    root: Path,
    run_id: str,
    harness: str,
    instruction: str = "",
    topic_id: str | None = None,
    requested_by: str = "harvis",
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    init_agent_room(root)
    harness = harness.strip().lower()
    if harness not in ALLOWED_HARNESSES:
        raise SystemExit(f"harness must be one of: {', '.join(sorted(ALLOWED_HARNESSES))}")
    run_path = run_json_path(root, run_id)
    run = read_json(run_path)
    if not run:
        raise SystemExit(f"invalid run json: {run_id}")
    packet = run.get("packet") if isinstance(run.get("packet"), dict) else {}
    if not topic_id:
        topic = create_topic(
            root,
            title=f"Handoff {run_id} to {harness}",
            goal=instruction or f"Prepare {run_id} for {harness} execution.",
            created_by=requested_by,
        )
        topic_id = topic["topic_id"]
    handoff_id = stable_id("handoff", run_id, harness, instruction)
    handoff = {
        "handoff_version": HANDOFF_VERSION,
        "handoff_id": handoff_id,
        "run_id": run_id,
        "packet_id": run.get("packet_id"),
        "packet_path": packet.get("packet_path"),
        "topic_id": topic_id,
        "harness": harness,
        "state": "pending_harness",
        "instruction": instruction.strip(),
        "requested_by": requested_by,
        "created_at": now_utc(),
        # T306 contract: keys always present; unknown values are explicit
        # nulls (no token statistics exist at request time).
        "cost": {"currency": None, "amount": None, "pricing_source": None},
        "usage": {
            "input_tokens": None,
            "output_tokens": None,
            "model_route": None,
            "provider": None,
        },
        "verification": {"status": "not_started", "evidence_refs": [], "verified_at": None},
        "safety": {
            "executes_task": False,
            "requires_harness": True,
            "requires_human_review_for_mutation": True,
        },
        "next": {
            "summary": "Open the handoff in the selected harness and let that harness perform the agent loop.",
            "codex": f"Use H.A.R.V.I.S. handoff {handoff_id} for run {run_id}.",
            "claude": f"Use H.A.R.V.I.S. handoff {handoff_id} for run {run_id}.",
        },
    }
    path = handoffs_dir(root) / f"{handoff_id}.json"
    write_json(path, handoff)
    outputs = run.get("outputs") if isinstance(run.get("outputs"), dict) else {}
    outputs["latest_handoff"] = rel(path, root)
    run["outputs"] = outputs
    run["state"] = "handoff_requested"
    run["mode"] = harness
    run["updated_at"] = now_utc()
    write_json(run_path, run)
    add_event(
        root,
        topic_id=topic_id,
        agent_id="harvis",
        role="coordinator",
        event_type="handoff.requested",
        content=f"Requested {harness} handoff for {run_id}.",
        source_refs=[rel(run_path, root), str(packet.get("packet_path") or "")],
    )
    return {
        "handoff": handoff,
        "path": rel(path, root),
        "run_path": rel(run_path, root),
    }


def list_handoffs(root: Path, limit: int = 50) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    handoffs = []
    directory = handoffs_dir(root)
    for path in sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)[:limit]:
        loaded = read_json(path)
        if loaded:
            item = dict(loaded)
            item["path"] = rel(path, root)
            handoffs.append(item)
    return {
        "handoff_version": HANDOFF_VERSION,
        "workspace": {"label": root.name or "workspace"},
        "handoff_count": len(handoffs),
        "handoffs": handoffs,
    }


def print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage H.A.R.V.I.S. Agent Room and harness handoffs.")
    parser.add_argument("--root", default=".", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init")

    topic_parser = subparsers.add_parser("topic")
    topic_parser.add_argument("--title", required=True)
    topic_parser.add_argument("--goal", default="")

    event_parser = subparsers.add_parser("event")
    event_parser.add_argument("--topic-id", required=True)
    event_parser.add_argument("--agent-id", default="harvis")
    event_parser.add_argument("--role", default="coordinator")
    event_parser.add_argument("--event-type", default="note")
    event_parser.add_argument("--content", default="")

    message_parser = subparsers.add_parser("message")
    message_parser.add_argument("--topic-id", required=True)
    message_parser.add_argument("--agent-id", default="harvis")
    message_parser.add_argument("--role", default="coordinator")
    message_parser.add_argument("--content", required=True)

    handoff_parser = subparsers.add_parser("handoff")
    handoff_parser.add_argument("--run-id", required=True)
    handoff_parser.add_argument("--harness", required=True)
    handoff_parser.add_argument("--instruction", default="")
    handoff_parser.add_argument("--topic-id", default="")

    list_parser = subparsers.add_parser("list")
    list_parser.add_argument("--limit", type=int, default=50)

    handoffs_parser = subparsers.add_parser("handoffs")
    handoffs_parser.add_argument("--limit", type=int, default=50)

    args = parser.parse_args()
    root = resolve_workspace_root(args.root)
    if args.command == "init":
        print_json(init_agent_room(root))
        return 0
    if args.command == "topic":
        print_json(create_topic(root, args.title, args.goal))
        return 0
    if args.command == "event":
        print_json(add_event(root, args.topic_id, args.agent_id, args.role, args.event_type, args.content))
        return 0
    if args.command == "message":
        print_json(add_message(root, args.topic_id, args.agent_id, args.role, args.content))
        return 0
    if args.command == "handoff":
        print_json(request_handoff(root, args.run_id, args.harness, args.instruction, args.topic_id or None))
        return 0
    if args.command == "list":
        print_json(list_agent_room(root, args.limit))
        return 0
    if args.command == "handoffs":
        print_json(list_handoffs(root, args.limit))
        return 0
    return 1


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("agent-room", legacy_main=main))
