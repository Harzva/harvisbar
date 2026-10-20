#!/usr/bin/env python3
"""Inspect and pin Codex threads produced by H.A.R.V.I.S. runs."""

from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urljoin, urlparse, urlunparse

from harvis_state_store import runtime_fallback_path


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def is_mobile_safe_host(hostname: str) -> bool:
    host = hostname.strip().lower()
    return bool(host) and host not in {"localhost", "::1"} and not host.startswith("127.")


def mobile_workbench_url(root: Path) -> str:
    """Resolve a phone-openable mobile workbench URL without leaking bearer tokens."""

    raw = next(
        (
            value.strip()
            for value in [
                os.environ.get("HARVIS_MOBILE_WEBUI_URL", ""),
                os.environ.get("HARVIS_MOBILE_BASE_URL", ""),
                os.environ.get("HARVIS_PUBLIC_BASE_URL", ""),
                os.environ.get("HARVIS_WORKBENCH_PUBLIC_URL", ""),
                os.environ.get("HARVIS_NGROK_URL", ""),
            ]
            if value and value.strip()
        ),
        "",
    )
    if not raw:
        return ""
    parsed = urlparse(raw)
    if parsed.scheme not in {"http", "https"} or not is_mobile_safe_host(parsed.hostname or ""):
        return ""
    path = parsed.path or "/"
    if not path.rstrip("/").endswith("/studio/mobile"):
        path = urljoin(path.rstrip("/") + "/", "studio/mobile/")
    query = parsed.query
    fragment = f"root={quote(str(root), safe='')}"
    return urlunparse((parsed.scheme, parsed.netloc, path, "", query, fragment))


def append_jsonl(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n")


def append_runtime_jsonl(root: Path, relative_path: str | Path, data: dict[str, Any]) -> None:
    primary = root / ".harvis" / Path(relative_path)
    fallback = runtime_fallback_path(root, relative_path)
    written: set[Path] = set()
    errors: list[Exception] = []
    for path in (primary, fallback):
        if path in written:
            continue
        try:
            append_jsonl(path, data)
            written.add(path)
        except Exception as exc:
            errors.append(exc)
    if not written and errors:
        raise errors[-1]


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    items: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            items.append(obj)
    return items


def iter_runtime_jsonl(root: Path, relative_path: str | Path) -> list[dict[str, Any]]:
    seen: set[str] = set()
    items: list[dict[str, Any]] = []
    for path in (root / ".harvis" / Path(relative_path), runtime_fallback_path(root, relative_path)):
        for item in iter_jsonl(path):
            key = json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            if key in seen:
                continue
            seen.add(key)
            items.append(item)
    return items


def load_json(path: Path) -> dict[str, Any]:
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return obj if isinstance(obj, dict) else {}


def binding_path(root: Path) -> Path:
    return root / ".harvis" / "codex-threads" / "bindings.jsonl"


def pin_path(root: Path) -> Path:
    return root / ".harvis" / "codex-threads" / "pins.jsonl"


def last_event(events_jsonl: str) -> dict[str, Any]:
    path = Path(events_jsonl) if events_jsonl else Path()
    if not events_jsonl or not path.exists():
        return {}
    for line in reversed(path.read_text(encoding="utf-8", errors="replace").splitlines()):
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            return obj
    return {}


def status_from_event(event: dict[str, Any]) -> str:
    typ = str(event.get("codex_event_type") or event.get("type") or "")
    if typ in {"turn.completed", "adapter.completed"}:
        return "completed"
    if typ in {"turn.failed", "adapter.failed"}:
        return "failed"
    if typ in {"adapter.started", "thread.started", "item.started", "item_started"}:
        return "in_progress"
    if typ in {"item.completed", "item_completed", "agent_message"}:
        return "running"
    return "unknown"


def enrich_with_event_state(item: dict[str, Any]) -> dict[str, Any]:
    enriched = dict(item)
    event = last_event(str(enriched.get("events_jsonl") or ""))
    if event:
        enriched["last_event_type"] = event.get("codex_event_type") or event.get("type")
        enriched["last_event_at"] = event.get("observed_at") or event.get("created_at")
        enriched["status"] = enriched.get("status") or status_from_event(event)
        if event.get("summary"):
            enriched["last_event_summary"] = str(event.get("summary"))[:500]
    else:
        enriched.setdefault("status", "unknown")
    return enriched


def discover_bindings(root: Path) -> list[dict[str, Any]]:
    bindings = iter_runtime_jsonl(root, Path("codex-threads") / "bindings.jsonl")
    seen = {
        (
            str(item.get("run_id") or ""),
            str(item.get("codex_thread_id") or item.get("codex_session_id") or item.get("codex_thread_binding") or ""),
        )
        for item in bindings
        if item.get("run_id")
    }
    executions = root / ".harvis" / "executions"
    if executions.exists():
        for path in sorted(executions.glob("**/codex-thread.json"), key=lambda item: item.stat().st_mtime):
            obj = load_json(path)
            run_id = str(obj.get("run_id") or "")
            key = (
                run_id,
                str(obj.get("codex_thread_id") or obj.get("codex_session_id") or path),
            )
            if not run_id or key in seen:
                continue
            obj.setdefault("schemaVersion", "harvis.codex-thread-binding.v0")
            obj.setdefault("created_at", utc_now())
            obj.setdefault("codex_thread_binding", str(path))
            bindings.append(obj)
            seen.add(key)
    return [enrich_with_event_state(item) for item in bindings]


def newest_by_thread_or_context(root: Path, query: str = "", chat_id: str = "") -> dict[str, Any] | None:
    query = query.strip()
    chat_id = chat_id.strip()
    for item in reversed(discover_bindings(root)):
        values = {
            str(item.get("codex_thread_id") or ""),
            str(item.get("codex_session_id") or ""),
            str(item.get("task_id") or ""),
            str(item.get("run_id") or ""),
            str(item.get("handoff_id") or ""),
            str(item.get("packet_id") or ""),
        }
        transport = item.get("transport") if isinstance(item.get("transport"), dict) else {}
        if query and query in values:
            return item
        if chat_id and str(transport.get("lark_chat_id") or "") == chat_id:
            return item
        if not query and not chat_id:
            return item
    return None


def active_pins(root: Path) -> list[dict[str, Any]]:
    active: dict[str, dict[str, Any]] = {}
    for item in iter_runtime_jsonl(root, Path("codex-threads") / "pins.jsonl"):
        thread_id = str(item.get("codex_thread_id") or "")
        if not thread_id:
            continue
        if item.get("action") == "unpin":
            active.pop(thread_id, None)
        else:
            active[thread_id] = item
    return [enrich_with_event_state(item) for item in active.values()]


def thread_card(root: Path, limit: int = 6, chat_id: str = "") -> dict[str, Any]:
    pins = active_pins(root)
    if chat_id:
        pins = [
            pin
            for pin in pins
            if str(pin.get("lark_chat_id") or pin.get("chat_id") or "") == chat_id
        ]
    pins = pins[-limit:]
    status_counts: dict[str, int] = {}
    for pin_item in pins:
        status = str(pin_item.get("status") or "unknown")
        status_counts[status] = status_counts.get(status, 0) + 1
    workbench_url = mobile_workbench_url(root)
    actions = [
        {"type": "query", "label": "查看 run timeline", "value": "run_timeline"},
        {"type": "query", "label": "继续这个任务", "value": "continue_thread"},
        {"type": "query", "label": "取消关注", "value": "unpin"},
    ]
    if workbench_url:
        actions.insert(0, {"type": "open_url", "label": "打开移动工作台", "url": workbench_url})
    card = {
        "schemaVersion": "harvis.codex-thread-card.v0",
        "created_at": utc_now(),
        "title": "H.A.R.V.I.S. 当前关注",
        "summary": {
            "total": len(pins),
            "status_counts": status_counts,
            "mobile_workbench_url": workbench_url or None,
        },
        "items": [
            {
                "label": pin_item.get("label") or pin_item.get("task_id") or pin_item.get("run_id") or "Codex thread",
                "status": pin_item.get("status") or "unknown",
                "task_id": pin_item.get("task_id"),
                "run_id": pin_item.get("run_id"),
                "handoff_id": pin_item.get("handoff_id"),
                "packet_id": pin_item.get("packet_id"),
                "codex_thread_id": pin_item.get("codex_thread_id"),
                "codex_session_id": pin_item.get("codex_session_id"),
                "events_jsonl": pin_item.get("events_jsonl"),
                "last_event_type": pin_item.get("last_event_type"),
                "last_event_at": pin_item.get("last_event_at"),
                "last_event_summary": pin_item.get("last_event_summary"),
            }
            for pin_item in pins
        ],
        "actions": actions,
    }
    return card


def pin(root: Path, binding: dict[str, Any], label: str, chat_id: str, message_id: str) -> dict[str, Any]:
    thread_id = str(binding.get("codex_thread_id") or binding.get("codex_session_id") or "")
    if not thread_id:
        raise SystemExit("cannot pin binding without codex_thread_id")
    event = {
        "schemaVersion": "harvis.codex-thread-pin.v0",
        "created_at": utc_now(),
        "action": "pin",
        "label": label or str(binding.get("task_id") or binding.get("run_id") or thread_id),
        "codex_thread_id": thread_id,
        "codex_session_id": binding.get("codex_session_id") or thread_id,
        "task_id": binding.get("task_id"),
        "run_id": binding.get("run_id"),
        "handoff_id": binding.get("handoff_id"),
        "packet_id": binding.get("packet_id"),
        "events_jsonl": binding.get("events_jsonl"),
        "status": binding.get("status") or "unknown",
        "last_event_type": binding.get("last_event_type"),
        "last_event_at": binding.get("last_event_at"),
        "last_event_summary": binding.get("last_event_summary"),
        "lark_chat_id": chat_id or (binding.get("transport") or {}).get("lark_chat_id"),
        "lark_message_id": message_id or (binding.get("transport") or {}).get("lark_message_id"),
    }
    append_runtime_jsonl(root, Path("codex-threads") / "pins.jsonl", event)
    return event


def unpin(root: Path, thread_id: str, label: str = "") -> dict[str, Any]:
    if not thread_id:
        raise SystemExit("unpin requires codex thread id")
    event = {
        "schemaVersion": "harvis.codex-thread-pin.v0",
        "created_at": utc_now(),
        "action": "unpin",
        "label": label,
        "codex_thread_id": thread_id,
    }
    append_runtime_jsonl(root, Path("codex-threads") / "pins.jsonl", event)
    return event


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage H.A.R.V.I.S. Codex thread bindings and pins.")
    parser.add_argument(
        "--root",
        default=Path(os.environ.get("HARVIS_WORKSPACE_ROOT", str(Path.cwd()))),
        type=Path,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    list_parser = sub.add_parser("list")
    list_parser.add_argument("--limit", type=int, default=20)

    latest_parser = sub.add_parser("latest")
    latest_parser.add_argument("--query", default="")
    latest_parser.add_argument("--chat-id", default="")

    pin_parser = sub.add_parser("pin")
    pin_parser.add_argument("--query", default="")
    pin_parser.add_argument("--chat-id", default="")
    pin_parser.add_argument("--message-id", default="")
    pin_parser.add_argument("--label", default="")

    unpin_parser = sub.add_parser("unpin")
    unpin_parser.add_argument("thread_id")
    unpin_parser.add_argument("--label", default="")

    sub.add_parser("pins")

    card_parser = sub.add_parser("card")
    card_parser.add_argument("--limit", type=int, default=6)
    card_parser.add_argument("--chat-id", default="")

    args = parser.parse_args()
    root = args.root.expanduser().resolve()

    if args.command == "list":
        bindings = discover_bindings(root)[-args.limit :]
        print(json.dumps({"ok": True, "bindings": bindings}, ensure_ascii=False, indent=2))
        return 0
    if args.command == "latest":
        binding = newest_by_thread_or_context(root, args.query, args.chat_id)
        print(json.dumps({"ok": bool(binding), "binding": binding}, ensure_ascii=False, indent=2))
        return 0 if binding else 1
    if args.command == "pin":
        binding = newest_by_thread_or_context(root, args.query, args.chat_id)
        if not binding:
            raise SystemExit("no matching Codex thread binding found")
        event = pin(root, binding, args.label, args.chat_id, args.message_id)
        print(json.dumps({"ok": True, "pin": event}, ensure_ascii=False, indent=2))
        return 0
    if args.command == "unpin":
        event = unpin(root, args.thread_id, args.label)
        print(json.dumps({"ok": True, "unpin": event}, ensure_ascii=False, indent=2))
        return 0
    if args.command == "pins":
        print(json.dumps({"ok": True, "pins": active_pins(root)}, ensure_ascii=False, indent=2))
        return 0
    if args.command == "card":
        print(json.dumps({"ok": True, "card": thread_card(root, args.limit, args.chat_id)}, ensure_ascii=False, indent=2))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
