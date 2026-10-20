#!/usr/bin/env python3
"""Run Codex exec in JSONL mode and persist normalized H.A.R.V.I.S. events."""

from __future__ import annotations

import argparse
import json
import os
import queue
import re
import shlex
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urljoin, urlparse, urlunparse

from harvis_state_store import runtime_fallback_path


UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def is_mobile_safe_host(hostname: str) -> bool:
    host = hostname.strip().lower()
    return bool(host) and host not in {"localhost", "::1"} and not host.startswith("127.")


def mobile_workbench_url(root: Path) -> str:
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
    return urlunparse((parsed.scheme, parsed.netloc, path, "", parsed.query, f"root={quote(str(root), safe='')}"))


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def find_task_id(root: Path, packet_id: str, run_id: str, handoff_id: str) -> str:
    path = root / ".harvis" / "agent-room" / "tasks.jsonl"
    if not path.exists():
        return ""
    for line in reversed(path.read_text(encoding="utf-8", errors="replace").splitlines()):
        try:
            obj = json.loads(line)
        except Exception:
            continue
        metadata = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
        packet_ids = metadata.get("packet_ids") if isinstance(metadata.get("packet_ids"), list) else []
        run_ids = metadata.get("run_ids") if isinstance(metadata.get("run_ids"), list) else []
        if (
            obj.get("packet_id") == packet_id
            or packet_id in packet_ids
            or obj.get("run_id") == run_id
            or run_id in run_ids
            or obj.get("handoff_id") == handoff_id
        ):
            value = obj.get("task_id")
            return value if isinstance(value, str) else ""
    return ""


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


def append_mirrored_jsonl(root: Path, path: Path, data: dict[str, Any]) -> None:
    harvis_root = root / ".harvis"
    if path.is_absolute():
        try:
            relative = path.relative_to(harvis_root)
        except ValueError:
            append_jsonl(path, data)
            return
    elif path.parts and path.parts[0] == ".harvis":
        relative = Path(*path.parts[1:])
    else:
        append_jsonl(path, data)
        return
    append_runtime_jsonl(root, relative, data)


def append_thread_binding(root: Path, payload: dict[str, Any]) -> None:
    append_runtime_jsonl(root, Path("codex-threads") / "bindings.jsonl", payload)


def append_conversation_binding(root: Path, payload: dict[str, Any]) -> None:
    append_jsonl(root / ".harvis" / "agent-room" / "conversation_binding.jsonl", payload)


def append_agent_room_event(root: Path, payload: dict[str, Any]) -> None:
    append_jsonl(root / ".harvis" / "agent-room" / "events.jsonl", payload)


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def iter_runtime_jsonl(root: Path, relative_path: str | Path) -> list[dict[str, Any]]:
    seen: set[str] = set()
    rows: list[dict[str, Any]] = []
    for path in (root / ".harvis" / Path(relative_path), runtime_fallback_path(root, relative_path)):
        for item in iter_jsonl(path):
            key = json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            if key in seen:
                continue
            seen.add(key)
            rows.append(item)
    return rows


def resume_approval_status(
    root: Path,
    approval_id: str,
    thread_id: str,
    run_id: str,
    packet_id: str,
    handoff_id: str,
) -> tuple[bool, str]:
    if not thread_id:
        return True, "not a resume run"
    if not approval_id:
        return False, "resume requires --approval-id or HARVIS_APPROVAL_ID"
    if not approval_id.startswith("approval_"):
        return False, "approval_id must reference an approval_ record"
    approval_path = root / ".harvis" / "approvals" / f"{approval_id}.json"
    approval = load_json(approval_path)
    if not approval:
        return False, f"approval record not found: {approval_id}"
    if approval.get("status") != "approved":
        return False, f"approval record is {approval.get('status') or 'unknown'}, not approved"
    action = approval.get("action") if isinstance(approval.get("action"), dict) else {}
    action_type = str(action.get("type") or "")
    if action_type and action_type != "run_command":
        return False, f"approval action type {action_type} does not allow Codex resume execution"
    target = action.get("target") if isinstance(action.get("target"), dict) else {}
    target_text = json.dumps({"target": target, "action": action}, ensure_ascii=False)
    needles = [thread_id, run_id, packet_id, handoff_id]
    record_run_id = str(approval.get("run_id") or "")
    if record_run_id == run_id or any(needle and needle in target_text for needle in needles):
        return True, "approved resume matches this run/thread"
    return False, "approval target does not mention the resume thread, run, packet, or handoff"


def validate_resume_thread(root: Path, thread_id: str, lark_chat_id: str, allow_unbound: bool = False) -> None:
    if not thread_id:
        return
    if allow_unbound:
        return
    for item in reversed(iter_runtime_jsonl(root, Path("codex-threads") / "bindings.jsonl")):
        ids = {
            str(item.get("codex_thread_id") or ""),
            str(item.get("codex_session_id") or ""),
        }
        if thread_id not in ids:
            continue
        if lark_chat_id:
            transport = item.get("transport") if isinstance(item.get("transport"), dict) else {}
            bound_chat_id = str(transport.get("lark_chat_id") or "")
            if bound_chat_id and bound_chat_id != lark_chat_id:
                continue
        return
    raise SystemExit(
        "resume thread is not bound to this H.A.R.V.I.S. workspace/chat; "
        "create or pin a binding first, or set HARVIS_ALLOW_UNBOUND_CODEX_RESUME=1 only for explicit local smoke tests"
    )


def deny_before_exec(
    root: Path,
    events_path: Path,
    status_path: Path,
    task_id: str,
    handoff_id: str,
    run_id: str,
    packet_id: str,
    reason: str,
    lark_cli: str = "",
    lark_message_id: str = "",
    lark_chat_id: str = "",
    stderr_log: Path | None = None,
    model: str = "",
    codex_thread_id: str = "",
) -> int:
    stderr_log = stderr_log or (root / ".harvis" / "runs" / run_id / "stderr.log")
    event = {
        "schemaVersion": "harvis.codex-jsonl-adapter.v0",
        "observed_at": utc_now(),
        "task_id": task_id or None,
        "handoff_id": handoff_id,
        "run_id": run_id,
        "packet_id": packet_id,
        "codex_event_type": "adapter.denied",
        "summary": reason,
        "exit_code": 78,
    }
    append_mirrored_jsonl(root, events_path, event)
    append_agent_room_event(
        root,
        {
            "agent_room_version": "harvis.codex-jsonl-adapter.v0",
            "event_id": f"evt_codex_resume_denied_{run_id}_{packet_id}",
            "topic_id": "gwt-workbench",
            "agent_id": "codex-jsonl-runner",
            "role": "executor",
            "event_type": "approval_gate.checked",
            "content": f"Codex resume denied: {reason}",
            "source_refs": [run_id, handoff_id, packet_id],
            "sensitivity": "internal",
            "created_at": utc_now(),
        },
    )
    status = load_json(status_path)
    status.update(
        {
            "adapter": "codex-jsonl",
            "state": "blocked",
            "exit_code": 78,
            "codex_last_event_type": "adapter.denied",
            "runner_summary": reason,
            "diagnostics": {"approval_gate": reason},
        }
    )
    if task_id:
        status["task_id"] = task_id
    write_json(status_path, status)
    run_dir = events_path.parent
    thread_payload = {
        "codex_thread_id": codex_thread_id or None,
        "codex_session_id": codex_thread_id or None,
    }
    completion_card_path = run_dir / "completion-card.json"
    completion_card = build_completion_card(
        root=root,
        task_id=task_id,
        handoff_id=handoff_id,
        run_id=run_id,
        packet_id=packet_id,
        model=model,
        return_code=78,
        final_file=run_dir / "final.md",
        stdout_log=run_dir / "stdout.jsonl",
        stderr_log=stderr_log,
        events_path=events_path,
        thread_json=run_dir / "codex-thread.json",
        status_path=status_path,
        thread_payload=thread_payload,
        mobile_url=mobile_workbench_url(root),
    )
    write_json(completion_card_path, completion_card)
    status = load_json(status_path)
    status.update(
        {
            "completion_card_json": str(completion_card_path),
            "runner_state": completion_card.get("status"),
            "runner_summary": completion_card.get("summary"),
            "runner_failure": completion_card.get("failure"),
            "workflow": completion_card.get("workflow"),
            "status": completion_card.get("status"),
        }
    )
    write_json(status_path, status)
    denial_text = "\n".join(
        [
            "H.A.R.V.I.S. 执行已被安全门禁拦截。",
            "",
            f"任务包：{packet_id}",
            f"run：{run_id}",
            f"handoff：{handoff_id}",
            "缺少 approval：需要一个 status=approved、action.type=run_command，且 target/run 能匹配当前 resume thread、run、packet 或 handoff 的 Harvis approval record。",
            f"原因：{reason}",
            "",
            lark_completion_text(completion_card),
        ]
    )
    send_lark_text(
        lark_cli,
        lark_message_id,
        lark_chat_id,
        denial_text,
        stderr_log,
    )
    return 78


def event_type(obj: dict[str, Any]) -> str:
    for key in ("type", "event", "name"):
        value = obj.get(key)
        if isinstance(value, str) and value:
            return value
    nested = obj.get("msg") or obj.get("event")
    if isinstance(nested, dict):
        value = nested.get("type") or nested.get("name")
        if isinstance(value, str) and value:
            return value
    return "unknown"


def iter_values(value: Any):
    if isinstance(value, dict):
        for item in value.values():
            yield from iter_values(item)
    elif isinstance(value, list):
        for item in value:
            yield from iter_values(item)
    else:
        yield value


def find_id(obj: dict[str, Any], preferred_keys: tuple[str, ...]) -> str:
    found_uuid = ""

    def visit(value: Any, key: str = "") -> str:
        nonlocal found_uuid
        if isinstance(value, dict):
            for child_key, child_value in value.items():
                key_lower = child_key.lower()
                if key_lower in preferred_keys and isinstance(child_value, str) and child_value:
                    return child_value
                result = visit(child_value, child_key)
                if result:
                    return result
        elif isinstance(value, list):
            for child in value:
                result = visit(child, key)
                if result:
                    return result
        elif isinstance(value, str) and UUID_RE.match(value):
            if not found_uuid:
                found_uuid = value
        return ""

    return visit(obj) or found_uuid


def text_from_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(part for part in (text_from_value(item) for item in value) if part).strip()
    if isinstance(value, dict):
        for key in ("text", "content", "message", "output", "summary"):
            text = text_from_value(value.get(key))
            if text:
                return text
        return ""
    return str(value)


def redact_progress_text(text: str) -> str:
    redacted = re.sub(
        r"(?i)\b(token|secret|password|passwd|api[_-]?key|authorization|cookie)\b\s*[:=]\s*([^\s\"']+)",
        r"\1=<redacted>",
        text,
    )
    redacted = re.sub(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>", redacted)
    return redacted


def normalize_display_text(text: str) -> str:
    clean = ANSI_RE.sub("", str(text or ""))
    clean = CONTROL_RE.sub("", clean)
    clean = clean.replace("\r\n", "\n").replace("\r", "\n")
    clean = clean.replace("\u200b", "").replace("\ufeff", "")
    return redact_progress_text(clean)


def clip_single_line(text: str, limit: int) -> str:
    compact = " ".join(normalize_display_text(text).strip().split())
    if len(compact) <= limit:
        return compact
    return compact[: max(0, limit - 1)].rstrip() + "…"


def shell_inner_command(command: str) -> str:
    raw = " ".join(normalize_display_text(command).strip().split())
    try:
        parts = shlex.split(raw)
    except Exception:
        return raw
    if len(parts) >= 3 and parts[0] in {"/bin/zsh", "/bin/bash", "zsh", "bash"} and parts[1] == "-lc":
        return parts[2]
    return raw


def command_display_title(command: str) -> str:
    inner = shell_inner_command(command)
    try:
        parts = shlex.split(inner)
    except Exception:
        parts = []
    if not parts:
        return clip_single_line(inner, 96)
    head = parts[0]
    head_name = Path(head).name
    joined = " ".join(parts)
    if head_name == "sed" and len(parts) >= 3:
        return f"查看文件片段：{parts[-1]}"
    if head_name == "rg":
        target = parts[-1] if len(parts) > 2 else "当前目录"
        return f"搜索内容：{target}"
    if head_name == "find":
        target = parts[1] if len(parts) > 1 else "."
        return f"列出文件：{target}"
    if head_name == "git" and len(parts) >= 2:
        return f"Git 检查：{' '.join(parts[1:4])}"
    if head_name == "node":
        if "--check" in parts:
            return "Node 语法检查"
        return "运行 Node 检查"
    if head_name in {"pwd", "ls", "wc", "printf", "echo"}:
        labels = {"pwd": "查看当前目录", "ls": "列目录", "wc": "统计文件", "printf": "输出验证文本", "echo": "输出验证文本"}
        return labels[head_name]
    if "playwright" in joined:
        return "Playwright 检查"
    return clip_single_line(inner, 96)


def should_inline_output(text: str) -> bool:
    clean = normalize_display_text(text).strip()
    if not clean:
        return False
    if len(clean) > 360:
        return False
    lines = clean.splitlines()
    if len(lines) > 5:
        return False
    noisy_markers = ("<!DOCTYPE", "<html", "<script", "</", "function ", "const ", "let ", "{", "}")
    noisy_hits = sum(1 for marker in noisy_markers if marker in clean)
    return noisy_hits < 3


def output_tail(text: str, *, max_lines: int = 5, max_chars: int = 360) -> str:
    clean = normalize_display_text(text).strip()
    if not clean:
        return ""
    if not should_inline_output(clean):
        line_count = len(clean.splitlines())
        return f"输出较长（{line_count} 行 / {len(clean)} 字），已写入 events.jsonl。"
    lines = clean.splitlines()[-max_lines:]
    tail = "\n".join(lines).strip()
    if len(tail) > max_chars:
        tail = "…" + tail[-max_chars:]
    return tail


def command_execution_details_from_raw(raw: dict[str, Any]) -> dict[str, Any]:
    item = raw.get("item") if isinstance(raw.get("item"), dict) else {}
    if item.get("type") != "command_execution":
        return {}
    command = text_from_value(item.get("command")).strip()
    if not command:
        return {}
    output = text_from_value(
        item.get("aggregated_output")
        or item.get("output")
        or item.get("stdout")
        or item.get("stderr")
    )
    exit_code = item.get("exit_code")
    return {
        "command": command,
        "command_short": clip_single_line(shell_inner_command(command), 120),
        "command_title": command_display_title(command),
        "output_tail": output_tail(output),
        "output_chars": len(normalize_display_text(output).strip()),
        "exit_code": exit_code,
        "status": str(item.get("status") or ""),
    }


def command_execution_details(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("raw") if isinstance(event.get("raw"), dict) else {}
    return command_execution_details_from_raw(raw)


def extract_agent_message(obj: dict[str, Any], typ: str) -> str:
    if typ not in {"agent_message", "item.completed", "item_completed", "message"}:
        return ""
    for key in ("message", "item", "content", "text", "output"):
        text = text_from_value(obj.get(key))
        if text:
            return text
    return ""


def summarize(obj: dict[str, Any], typ: str) -> str:
    if typ == "thread.started":
        thread_id = find_id(obj, ("thread_id", "threadid", "session_id", "sessionid", "id"))
        return f"Codex thread started: {thread_id or 'unknown'}"
    if typ in {"item.started", "item_started"}:
        details = command_execution_details_from_raw(obj)
        if details:
            return f"command_execution started: {details['command_short']}"
        return "Codex item started"
    if typ in {"item.completed", "item_completed"}:
        details = command_execution_details_from_raw(obj)
        if details:
            exit_code = details.get("exit_code")
            suffix = f" exit={exit_code}" if exit_code is not None else ""
            return f"command_execution completed{suffix}: {details['command_short']}"
        text = extract_agent_message(obj, typ)
        return ("Codex item completed: " + text[:180]) if text else "Codex item completed"
    if typ == "agent_message":
        text = extract_agent_message(obj, typ)
        return ("Codex agent message: " + text[:180]) if text else "Codex agent message"
    if typ == "turn.completed":
        return "Codex turn completed"
    if typ == "turn.failed":
        text = text_from_value(obj.get("message") or obj.get("error") or obj.get("reason"))
        return ("Codex turn failed: " + text[:180]) if text else "Codex turn failed"
    return f"Codex event: {typ}"


LOW_SIGNAL_PROGRESS_MARKERS = (
    "Exceeded skills context budget",
    "Falling back from WebSockets",
    "request timed out",
    "approval_policy=",
    "Codex item started",
    "Codex item completed",
)


def useful_progress_summary(summary: str) -> str:
    text = " ".join(summary.strip().split())
    if not text:
        return ""
    if any(marker in text for marker in LOW_SIGNAL_PROGRESS_MARKERS):
        return ""
    prefixes = (
        "Codex item completed: ",
        "Codex agent message: ",
    )
    for prefix in prefixes:
        if text.startswith(prefix):
            text = text[len(prefix):].strip()
            break
    return text[:360]


def lark_progress_text(event: dict[str, Any], state: dict[str, Any]) -> str:
    typ = str(event.get("codex_event_type") or "")
    run_id = str(state.get("run_id") or "")
    packet_id = str(state.get("packet_id") or "")
    thread_id = str(state.get("codex_thread_id") or event.get("codex_thread_id") or "")
    summary = str(event.get("summary") or "").strip()
    useful_summary = useful_progress_summary(summary)
    command_details = command_execution_details(event)
    lines: list[str] = []

    if typ == "adapter.started":
        lines.append("⏳ command_execution - Codex runner started.")
    elif typ == "thread.started":
        lines.append("🧠 command_execution - Codex thread started.")
    elif typ in {"item.started", "item_started"}:
        if not command_details:
            return ""
        lines.append("⏳ command_execution - command started.")
    elif typ in {"item.completed", "item_completed"}:
        if command_details:
            exit_code = command_details.get("exit_code")
            ok = exit_code in (0, "0", None)
            lines.append(("✅" if ok else "❌") + " command_execution - command completed.")
        elif not useful_summary:
            return ""
        else:
            lines.append("✅ command_execution - Codex step completed.")
    elif typ == "agent_message":
        if not useful_summary:
            return ""
        lines.append("✍️ command_execution - Codex update.")
    elif typ == "turn.completed":
        lines.append("✅ Codex turn completed. The task is moving to review.")
    elif typ in {"turn.failed", "adapter.failed"}:
        lines.append("❌ Codex execution failed or was blocked.")
    else:
        return ""

    if packet_id:
        lines.append(f"packet: {packet_id}")
    if run_id:
        lines.append(f"run: {run_id}")
    if thread_id:
        lines.append(f"thread: {thread_id}")
    if useful_summary:
        lines.append(f"state: {useful_summary}")
    if command_details:
        lines.append(f"command: {command_details.get('command_short')}")
        exit_code = command_details.get("exit_code")
        if exit_code is not None:
            lines.append(f"exit: {exit_code}")
        if command_details.get("output_tail"):
            lines.append("output tail:")
            lines.append(str(command_details["output_tail"]))
    workbench_url = str(state.get("mobile_workbench_url") or "")
    if workbench_url and typ in {"adapter.started", "turn.completed", "turn.failed", "adapter.failed"}:
        lines.append(f"mobile workbench: {workbench_url}")
    return "\n".join(lines)


def progress_phase_for_event(event: dict[str, Any], state: dict[str, Any]) -> dict[str, str]:
    typ = str(event.get("codex_event_type") or "")
    summary = str(event.get("summary") or "").strip()
    useful_summary = useful_progress_summary(summary)
    command_details = command_execution_details(event)
    if typ == "adapter.started":
        return {"icon": "⏳", "label": "启动执行器", "status": "running", "summary": "Codex runner 已启动。"}
    if typ == "thread.started":
        return {"icon": "🧠", "label": "创建 Codex 线程", "status": "running", "summary": "Codex thread 已创建。"}
    if typ in {"item.started", "item_started"}:
        if command_details:
            return {
                "icon": "⏳",
                "label": "命令运行中",
                "status": "running",
                "summary": command_details.get("command_title") or command_details.get("command_short", ""),
                "kind": "command",
                "command": command_details.get("command_short", ""),
                "command_title": command_details.get("command_title", ""),
                "exit_code": "",
                "output_tail": "",
            }
        return {}
    if typ in {"item.completed", "item_completed"}:
        if command_details:
            exit_code = command_details.get("exit_code")
            ok = exit_code in (0, "0", None)
            return {
                "icon": "✅" if ok else "❌",
                "label": "命令完成" if ok else "命令失败",
                "status": "running",
                "summary": command_details.get("command_title") or command_details.get("command_short", ""),
                "kind": "command",
                "command": command_details.get("command_short", ""),
                "command_title": command_details.get("command_title", ""),
                "exit_code": "" if exit_code is None else str(exit_code),
                "output_tail": command_details.get("output_tail", ""),
            }
        if not useful_summary:
            return {}
        return {"icon": "✅", "label": "步骤完成", "status": "running", "summary": useful_summary}
    if typ == "agent_message":
        if not useful_summary:
            return {}
        return {"icon": "✍️", "label": "模型输出", "status": "running", "summary": useful_summary}
    if typ == "turn.completed":
        return {"icon": "✅", "label": "进入复核", "status": "reviewing", "summary": "执行已结束，正在进入复核。"}
    if typ in {"turn.failed", "adapter.failed"}:
        return {"icon": "❌", "label": "执行受阻", "status": "failed_or_blocked", "summary": useful_summary or "Codex execution failed or was blocked."}
    return {}


def progress_card_state_path(state: dict[str, Any]) -> Path:
    stderr_log = Path(str(state.get("stderr_log") or ""))
    if stderr_log:
        return stderr_log.parent / "progress-card-state.json"
    return Path("progress-card-state.json")


def save_progress_card_state(state: dict[str, Any], card: dict[str, Any]) -> None:
    path = progress_card_state_path(state)
    try:
        payload = {
            "schemaVersion": "harvis.lark-progress-card-state.v0",
            "updated_at": utc_now(),
            "message_id": state.get("lark_progress_card_message_id") or None,
            "steps": state.get("lark_progress_steps") or [],
            "card": card,
        }
        write_json(path, payload)
    except Exception as exc:
        stderr_log = Path(str(state.get("stderr_log") or ""))
        if stderr_log:
            with stderr_log.open("a", encoding="utf-8") as handle:
                handle.write(f"\n[harvis-codex-jsonl-adapter] progress card state write failed: {exc}\n")


def progress_card_template(status: str) -> str:
    if status == "reviewing":
        return "blue"
    if status == "failed_or_blocked":
        return "red"
    if status == "completed":
        return "green"
    return "wathet"


def lark_md_escape(text: str) -> str:
    return text.replace("<", "&lt;").replace(">", "&gt;").replace("```", "'''").replace("`", "\\`")


def build_lark_progress_card(event: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    phase = progress_phase_for_event(event, state)
    status = phase.get("status") or str(state.get("lark_progress_card_status") or "running")
    state["lark_progress_card_status"] = status
    packet_id = str(state.get("packet_id") or "")
    run_id = str(state.get("run_id") or "")
    handoff_id = str(state.get("handoff_id") or "")
    thread_id = str(state.get("codex_thread_id") or event.get("codex_thread_id") or "")
    model = str(state.get("model") or "gpt-5.5")
    now = utc_now()
    steps: list[dict[str, str]] = list(state.get("lark_progress_steps") or [])
    if phase:
        steps.append(
            {
                "at": now,
                "icon": phase.get("icon", "•"),
                "label": phase.get("label", "update"),
                "summary": phase.get("summary", ""),
                "kind": phase.get("kind", ""),
                "command": phase.get("command", ""),
                "command_title": phase.get("command_title", ""),
                "exit_code": phase.get("exit_code", ""),
                "output_tail": phase.get("output_tail", ""),
            }
        )
        state["lark_progress_steps"] = steps[-12:]
    steps = list(state.get("lark_progress_steps") or [])
    latest = steps[-1] if steps else {"icon": "⏳", "label": "starting", "summary": "Codex runner is starting."}
    lines = [
        f"{latest.get('icon', '•')} **{lark_md_escape(str(latest.get('label') or 'update'))}**",
    ]
    latest_command = str(latest.get("command") or "")
    latest_command_title = str(latest.get("command_title") or latest.get("summary") or "")
    latest_exit = str(latest.get("exit_code") or "")
    latest_output = str(latest.get("output_tail") or "")
    if latest.get("kind") == "command" and latest_command_title:
        lines.append(f"工具：{lark_md_escape(latest_command_title)}")
    elif latest.get("summary"):
        lines.append(lark_md_escape(str(latest.get("summary") or "")))
    if latest_command and latest_command != latest_command_title and len(latest_command) <= 120:
        lines.append(f"命令：`{lark_md_escape(latest_command)}`")
    if latest_exit:
        lines.append(f"退出码：`{lark_md_escape(latest_exit)}`")
    if latest_output:
        if latest_output.startswith("输出较长"):
            lines.append(lark_md_escape(latest_output))
        else:
            lines.extend(["输出：", f"```text\n{lark_md_escape(latest_output)}\n```"])
    command_steps = [step for step in steps if step.get("kind") == "command"]
    command_lines = []
    for step in command_steps[-5:]:
        command = str(step.get("command") or step.get("summary") or "")
        command_title = str(step.get("command_title") or step.get("summary") or "")
        exit_code = str(step.get("exit_code") or "")
        output = str(step.get("output_tail") or "")
        result = f"退出码 {exit_code}" if exit_code else "执行中"
        command_lines.append(f"{step.get('icon', '•')} **command_execution**")
        command_lines.append(f"动作：{lark_md_escape(command_title)}")
        if command and command != command_title and len(command) <= 120:
            command_lines.append(f"命令：`{lark_md_escape(command)}`")
        command_lines.append(f"结果：{lark_md_escape(result)}")
        if output:
            if output.startswith("输出较长"):
                command_lines.append(lark_md_escape(output))
            else:
                command_lines.append(f"输出：\n```text\n{lark_md_escape(output)}\n```")
    recent_lines = []
    for step in steps[-6:]:
        step_summary = str(step.get("summary") or "")
        if step.get("kind") == "command":
            exit_code = str(step.get("exit_code") or "")
            exit_part = f"（exit {exit_code}）" if exit_code else ""
            step_summary = f"{lark_md_escape(str(step.get('command_title') or step_summary))}{exit_part}"
        else:
            step_summary = lark_md_escape(step_summary)[:180]
        recent_lines.append(
            f"{step.get('icon', '•')} {lark_md_escape(str(step.get('label') or 'update'))}: "
            f"{step_summary}"
        )
    meta_parts = [
        f"packet: `{packet_id}`" if packet_id else "",
        f"run: `{run_id}`" if run_id else "",
        f"handoff: `{handoff_id}`" if handoff_id else "",
        f"harness/model: `codex / {model}`",
        f"thread: `{thread_id}`" if thread_id else "",
    ]
    meta = "\n".join(part for part in meta_parts if part)
    elements: list[dict[str, Any]] = [
        {"tag": "div", "text": {"tag": "lark_md", "content": "\n".join(line for line in lines if line)}},
        {"tag": "hr"},
        {"tag": "div", "text": {"tag": "lark_md", "content": meta}},
    ]
    if recent_lines:
        elements.extend(
            [
                {"tag": "hr"},
                {"tag": "div", "text": {"tag": "lark_md", "content": "**最近进度**\n" + "\n".join(recent_lines)}},
            ]
        )
    if command_lines:
        elements.extend(
            [
                {"tag": "hr"},
                {"tag": "div", "text": {"tag": "lark_md", "content": "**执行过程**\n" + "\n".join(command_lines)}},
            ]
        )
    workbench_url = str(state.get("mobile_workbench_url") or "")
    actions: list[dict[str, Any]] = []
    if workbench_url:
        actions.append(
            {
                "tag": "button",
                "text": {"tag": "plain_text", "content": "打开工作台"},
                "type": "default",
                "url": workbench_url,
            }
        )
    actions.append(
        {
            "tag": "button",
            "text": {"tag": "plain_text", "content": "查看状态"},
            "type": "default",
            "value": {"action": "status_card", "packet_id": packet_id, "run_id": run_id},
        }
    )
    if actions:
        elements.append({"tag": "action", "actions": actions})
    return {
        "config": {"wide_screen_mode": True},
        "header": {
            "template": progress_card_template(status),
            "title": {"tag": "plain_text", "content": "H.A.R.V.I.S. 任务执行中" if status == "running" else "H.A.R.V.I.S. 任务状态更新"},
        },
        "elements": elements,
    }


def parse_lark_message_id(output: str) -> str:
    try:
        payload = json.loads(output)
    except Exception:
        return ""
    data = payload.get("data") if isinstance(payload, dict) else None
    if isinstance(data, dict):
        return str(data.get("message_id") or data.get("messageId") or "")
    return ""


def send_lark_progress_card(event: dict[str, Any], state: dict[str, Any]) -> bool:
    if not state.get("lark_progress_card_enabled") or state.get("lark_progress_card_disabled"):
        return False
    lark_cli = str(state.get("lark_cli") or "")
    message_id = str(state.get("lark_message_id") or "")
    chat_id = str(state.get("lark_chat_id") or "")
    if not lark_cli or (not message_id and not chat_id):
        return False
    if not progress_phase_for_event(event, state):
        return False

    card = build_lark_progress_card(event, state)
    card_content = json.dumps(card, ensure_ascii=False, separators=(",", ":"))
    progress_message_id = str(state.get("lark_progress_card_message_id") or "")
    if progress_message_id:
        cmd = [
            lark_cli,
            "api",
            "PATCH",
            f"/open-apis/im/v1/messages/{progress_message_id}",
            "--as",
            "bot",
            "--data",
            json.dumps({"content": card_content}, ensure_ascii=False),
            "--format",
            "json",
        ]
    elif message_id:
        cmd = [
            lark_cli,
            "im",
            "+messages-reply",
            "--as",
            "bot",
            "--message-id",
            message_id,
            "--msg-type",
            "interactive",
            "--content",
            card_content,
            "--format",
            "json",
        ]
    else:
        cmd = [
            lark_cli,
            "im",
            "+messages-send",
            "--as",
            "bot",
            "--chat-id",
            chat_id,
            "--msg-type",
            "interactive",
            "--content",
            card_content,
            "--format",
            "json",
        ]
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=12, check=True)
        if not progress_message_id:
            new_message_id = parse_lark_message_id(result.stdout)
            if new_message_id:
                state["lark_progress_card_message_id"] = new_message_id
        state["lark_progress_card_last_at"] = time.time()
        save_progress_card_state(state, card)
        return True
    except Exception as exc:
        stderr_log = Path(str(state.get("stderr_log") or ""))
        if stderr_log:
            with stderr_log.open("a", encoding="utf-8") as handle:
                handle.write(f"\n[harvis-codex-jsonl-adapter] lark progress card update failed: {exc}\n")
        state["lark_progress_card_disabled"] = True
        return False


def send_lark_progress(event: dict[str, Any], state: dict[str, Any]) -> None:
    if not state.get("lark_progress_enabled"):
        return
    lark_cli = str(state.get("lark_cli") or "")
    message_id = str(state.get("lark_message_id") or "")
    chat_id = str(state.get("lark_chat_id") or "")
    if not lark_cli or (not message_id and not chat_id):
        return

    typ = str(event.get("codex_event_type") or "")
    if typ == "adapter.failed" and state.get("lark_progress_failure_sent"):
        return
    critical = typ in {"turn.completed", "turn.failed", "adapter.failed"}
    sent = int(state.get("lark_progress_sent", 0))
    max_updates = int(
        state.get(
            "lark_progress_card_max" if state.get("lark_progress_card_enabled") and not state.get("lark_progress_card_disabled") else "lark_progress_max",
            12,
        )
    )
    if sent >= max_updates and not critical:
        return
    now = time.time()

    if state.get("lark_progress_card_enabled"):
        if not progress_phase_for_event(event, state):
            return
        if send_lark_progress_card(event, state):
            state["lark_progress_sent"] = sent + 1
            state["lark_progress_last_at"] = now
            if typ in {"turn.failed", "adapter.failed"}:
                state["lark_progress_failure_sent"] = True
            return

    text = lark_progress_text(event, state)
    if not text:
        return
    if message_id:
        cmd = [lark_cli, "im", "+messages-reply", "--as", "bot", "--message-id", message_id, "--text", text, "--format", "json"]
    else:
        cmd = [lark_cli, "im", "+messages-send", "--as", "bot", "--chat-id", chat_id, "--text", text, "--format", "json"]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=12, check=True)
        state["lark_progress_sent"] = sent + 1
        state["lark_progress_last_at"] = now
        if typ in {"turn.failed", "adapter.failed"}:
            state["lark_progress_failure_sent"] = True
    except Exception as exc:
        stderr_log = Path(str(state.get("stderr_log") or ""))
        if stderr_log:
            with stderr_log.open("a", encoding="utf-8") as handle:
                handle.write(f"\n[harvis-codex-jsonl-adapter] lark progress send failed: {exc}\n")


def send_lark_text(lark_cli: str, message_id: str, chat_id: str, text: str, stderr_log: Path) -> None:
    if not lark_cli or (not message_id and not chat_id) or not text:
        return
    if message_id:
        cmd = [lark_cli, "im", "+messages-reply", "--as", "bot", "--message-id", message_id, "--text", text, "--format", "json"]
    else:
        cmd = [lark_cli, "im", "+messages-send", "--as", "bot", "--chat-id", chat_id, "--text", text, "--format", "json"]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=12, check=True)
    except Exception as exc:
        with stderr_log.open("a", encoding="utf-8") as handle:
            handle.write(f"\n[harvis-codex-jsonl-adapter] lark notice send failed: {exc}\n")


def read_excerpt(path: Path, limit: int = 1200) -> str:
    if not path.exists():
        return ""
    text = path.read_text(encoding="utf-8", errors="replace").strip()
    if len(text) <= limit:
        return text
    return text[-limit:].strip()


def external_article_fallback_verdict(final_text: str, stderr_text: str = "") -> dict[str, Any] | None:
    text = f"{final_text}\n{stderr_text}".strip()
    lower = text.lower()
    if not any(
        marker in lower
        for marker in (
            "mp.weixin.qq.com",
            "wemedia",
            "09-wemedia",
            "文章素材库",
            "微信草稿箱",
            "md2wechat",
            "create_draft",
            "mmbiz.qpic.cn",
        )
    ):
        return None

    stage_status = {
        "material_ingested": "unknown",
        "images_ready": "unknown",
        "draft_generated": "unknown",
        "wechat_draft_created": "unknown",
        "quality_checked": "unknown",
    }
    failures: list[str] = []
    stage = "unknown"

    def fail(stage_name: str, key: str, reason: str) -> None:
        nonlocal stage
        if stage == "unknown":
            stage = stage_name
        stage_status[key] = "failed"
        failures.append(reason)

    if "could not resolve host: mp.weixin.qq.com" in lower or "dns resolution failed" in lower:
        fail("fetch_source_article", "material_ingested", "mp.weixin.qq.com DNS resolution failed")
    if "未下载到 wemedia" in text or "no cached article body" in lower:
        fail("fetch_source_article", "material_ingested", "未下载到 wemedia")
    if "正文图片不足" in text or re.search(r"正文图片数量\s*`?0`?", text):
        fail("prepare_images", "images_ready", "正文图片不足")
    if "未生成 draft json" in lower or "没有 draft json" in lower or "未生成 draft" in text:
        fail("generate_draft", "draft_generated", "draft JSON/HTML 未生成")
    if (
        "未写入微信草稿箱" in text
        or "未调用 `create_draft`" in text
        or "未调用 create_draft" in text
        or "无 `media_id`" in text
        or "无 media_id" in text
        or "没有拿到 media_id" in text
    ):
        fail("create_wechat_draft", "wechat_draft_created", "未写入微信草稿箱")
    if "质量门禁：未运行" in text or "quality gate" in lower and "fail" in lower:
        fail("quality_gate", "quality_checked", "质量门禁未通过或未运行")

    if not failures:
        if re.search(r"(create_draft|微信草稿箱|draft).{0,240}(media_id|errcode[\"']?\s*:\s*0|已写入|写入成功)", lower, re.S):
            stage_status["wechat_draft_created"] = "passed"
        if "mmbiz.qpic.cn" in lower or "image-upload-map.json" in lower:
            stage_status["images_ready"] = "passed"
        if "quality gate" in lower and any(token in lower for token in ("passed", "通过", "0 warnings", "0 errors")):
            stage_status["quality_checked"] = "passed"
        if stage_status["wechat_draft_created"] == "passed" and stage_status["quality_checked"] == "passed":
            return {
                "kind": "external_article_conductor_fallback_verdict",
                "status": "wechat_draft_created",
                "stage": "quality_checked",
                "stage_status": stage_status,
                "reason": "微信草稿已创建且质量门禁通过",
                "business_success": True,
            }
        return {
            "kind": "external_article_conductor_fallback_verdict",
            "status": "needs_review",
            "stage": stage,
            "stage_status": stage_status,
            "reason": "未检测到明确业务失败，但也未证明草稿箱完成",
            "business_success": False,
        }

    return {
        "kind": "external_article_conductor_fallback_verdict",
        "status": "workflow_failed",
        "stage": stage,
        "stage_status": stage_status,
        "reason": "；".join(dict.fromkeys(failures)),
        "business_success": False,
    }


def conductor_result_verdict(exec_dir: Path) -> tuple[dict[str, Any] | None, Any | None]:
    task_path = exec_dir / "conductor_task.json"
    result_path = exec_dir / "conductor_result.json"
    if not task_path.exists():
        return None, None
    if not result_path.exists():
        return {
            "kind": "codex_conductor_task",
            "status": "workflow_failed",
            "stage": "write_conductor_result",
            "stage_status": {"conductor_result": "missing"},
            "reason": "Conductor task was created but conductor_result.json is missing; exit code alone does not prove business success.",
            "business_success": False,
        }, None
    try:
        result = json.loads(result_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {
            "kind": "codex_conductor_task",
            "status": "workflow_failed",
            "stage": "read_conductor_result",
            "stage_status": {"conductor_result": "failed"},
            "reason": f"conductor_result.json could not be parsed: {exc}",
            "business_success": False,
        }, None
    if not isinstance(result, dict):
        return {
            "kind": "codex_conductor_task",
            "status": "workflow_failed",
            "stage": "read_conductor_result",
            "stage_status": {"conductor_result": "failed"},
            "reason": "conductor_result.json is not an object",
            "business_success": False,
        }, result
    status = str(result.get("status") or "needs_review")
    artifacts = result.get("artifacts") if isinstance(result.get("artifacts"), dict) else {}
    validation = result.get("validation") if isinstance(result.get("validation"), dict) else {}
    stage_status = result.get("stage_status") if isinstance(result.get("stage_status"), dict) else {}
    proof_path = artifacts.get("wechat_api_proof") or artifacts.get("draft_get_proof")
    draft_box_api_verified = bool(validation.get("draft_box_api_verified") or artifacts.get("draft_box_api_verified"))
    if proof_path and not draft_box_api_verified:
        try:
            proof = json.loads(Path(str(proof_path)).read_text(encoding="utf-8"))
            draft_box_api_verified = bool(proof.get("success") is True and proof.get("draft_box_api_verified") is True)
        except Exception:
            draft_box_api_verified = False
    if (
        str(result.get("kind") or "") == "external_article_to_wechat_draft"
        and (result.get("business_success") is True or status in {"completed", "success", "wechat_draft_created", "draft_created"})
        and not draft_box_api_verified
        and not any(
            artifacts.get(key)
            for key in (
                "browser_proof",
                "browser_proof_path",
                "draft_box_screenshot",
                "draft_box_screenshot_path",
                "draft_box_verified",
                "ui_verified",
            )
        )
        and not result.get("draft_box_verified")
        and not result.get("ui_verified")
    ):
        stage_status = dict(stage_status)
        stage_status.setdefault("create_draft", "passed")
        stage_status["draft_box_api_verification"] = "blocked"
        artifacts = dict(artifacts)
        artifacts["browser_proof_required"] = False
        artifacts["browser_proof_reason"] = artifacts.get("browser_proof_reason") or "Draft-box UI verification is optional; draft/get API verification is the completion proof."
        return {
            "kind": str(result.get("kind") or "codex_conductor_task"),
            "status": "draft_created_ui_unverified",
            "stage": "draft_box_api_verification",
            "stage_status": stage_status,
            "reason": "create_draft returned a draft artifact, but draft/get API verification is missing or blocked.",
            "business_success": False,
            "artifacts": artifacts,
            "source": str(result_path),
        }, result
    business_success = result.get("business_success") is True
    return {
        "kind": str(result.get("kind") or "codex_conductor_task"),
        "status": status,
        "stage": str(result.get("current_stage") or result.get("stage") or status),
        "stage_status": stage_status,
        "reason": str(result.get("reason") or result.get("summary") or status),
        "business_success": business_success,
        "artifacts": artifacts,
        "source": str(result_path),
    }, result


def meaningful_events(events_path: Path) -> list[dict[str, Any]]:
    events = iter_jsonl(events_path)
    return [event for event in events if str(event.get("codex_event_type") or "") not in {"adapter.started"}]


def last_codex_event(events_path: Path) -> dict[str, Any]:
    for event in reversed(meaningful_events(events_path)):
        typ = str(event.get("codex_event_type") or "")
        if typ and not typ.startswith("adapter."):
            return event
    events = meaningful_events(events_path)
    return events[-1] if events else {}


def build_completion_card(
    *,
    root: Path,
    task_id: str,
    handoff_id: str,
    run_id: str,
    packet_id: str,
    model: str,
    return_code: int,
    final_file: Path,
    stdout_log: Path,
    stderr_log: Path,
    events_path: Path,
    thread_json: Path,
    status_path: Path,
    thread_payload: dict[str, Any],
    mobile_url: str,
) -> dict[str, Any]:
    final_summary = read_excerpt(final_file, 1800)
    stderr_excerpt = read_excerpt(stderr_log, 1600)
    workflow, conductor_result = conductor_result_verdict(status_path.parent)
    if workflow is None:
        workflow = external_article_fallback_verdict(final_summary, stderr_excerpt)
    last_event = last_codex_event(events_path)
    last_event_type = str(last_event.get("codex_event_type") or "not_recorded")
    last_event_summary = str(last_event.get("summary") or "").strip()
    success = return_code == 0 and not (workflow and not workflow.get("business_success"))
    failure_reason = ""
    next_step = "等待 reviewer 复核，然后进入 done / memory candidate 链路。"
    ui_unverified_statuses = {"draft_created_ui_unverified", "draft_created_api_verified_ui_unverified"}
    ui_unverified = bool(workflow and workflow.get("status") in ui_unverified_statuses)
    if workflow and not workflow.get("business_success"):
        failure_reason = str(workflow.get("reason") or "workflow acceptance failed")
        if ui_unverified:
            next_step = "补充公众号草稿箱 draft/get API 验证；确认 media_id 可查询后再标记完成。"
        else:
            next_step = "修复 workflow 阶段失败后重跑；只有 conductor_result 业务验收通过才算完成。"
    if not success:
        if failure_reason:
            pass
        elif return_code == 124:
            failure_reason = "Codex runner timed out before producing a final reviewed result."
        elif last_event_type == "turn.failed":
            failure_reason = last_event_summary or "Codex reported turn.failed."
        elif last_event_type == "adapter.denied":
            failure_reason = last_event_summary or "Harvis approval gate denied execution before Codex started."
        elif stderr_excerpt:
            failure_reason = stderr_excerpt.splitlines()[-1].strip() or f"Codex runner exited with code {return_code}."
        else:
            failure_reason = f"Codex runner exited with code {return_code}; last event was {last_event_type}."
        if not workflow:
            next_step = "查看 stderr / events.jsonl，修复失败原因后重新申请 approval 或继续该 thread。"

    actions: list[dict[str, str]] = []
    if mobile_url:
        actions.append({"type": "open_url", "label": "打开移动工作台", "url": mobile_url})
    workflow_summary = summarize_workflow_for_card(workflow)
    display_summary = final_summary or ("执行完成，等待 reviewer 汇总。" if success else failure_reason)
    if ui_unverified and workflow_summary:
        api_state = "已通过 API 验证" if workflow_summary.get("draft_box_api_verified") else "未完成 API 验证"
        display_summary = (
            "公众号草稿已创建，"
            f"{api_state}；media_id：{workflow_summary.get('media_id') or '-'}；"
            f"图片数：{workflow_summary.get('image_count') or 0}。"
            "当前还缺 draft/get API 证明，因此完整闭环仍标记为待验证。"
        )

    return {
        "schemaVersion": "harvis.completion-card.v0",
        "created_at": utc_now(),
        "title": (
            "H.A.R.V.I.S. 任务完成"
            if success
            else (
                "H.A.R.V.I.S. 草稿已创建，待 API 验证"
                if ui_unverified
                else "H.A.R.V.I.S. 任务失败/阻塞"
            )
        ),
        "status": "completed_pending_review" if success else (workflow.get("status") if workflow else "failed_or_blocked"),
        "workflow": workflow,
        "workflow_summary": workflow_summary,
        "task_id": task_id or None,
        "packet_id": packet_id,
        "handoff_id": handoff_id,
        "run_id": run_id,
        "harness": "codex",
        "model": model or "gpt-5.5",
        "codex_thread_id": thread_payload.get("codex_thread_id") or None,
        "codex_session_id": thread_payload.get("codex_session_id") or None,
        "exit_code": return_code,
        "paths": {
            "exec_dir": str(final_file.parent),
            "events_jsonl": str(events_path),
            "final_file": str(final_file),
            "stdout_log": str(stdout_log),
            "stderr_log": str(stderr_log),
            "status_json": str(status_path),
            "thread_json": str(thread_json),
            "conductor_task": str(status_path.parent / "conductor_task.json"),
            "conductor_events": str(status_path.parent / "conductor_events.jsonl"),
            "conductor_result": str(status_path.parent / "conductor_result.json"),
            "worker_registry": str(status_path.parent / "worker-registry.json"),
        },
        "reviewer": {
            "status": "pending_review" if success else ("pending_api_verification" if ui_unverified else "blocked_before_review"),
            "conclusion": (
                "执行已产出结果，等待 reviewer 复核。"
                if success
                else (
                    "公众号草稿已创建；还缺 draft/get API 证明。"
                    if ui_unverified
                    else "业务验收未通过；执行未形成可复核完成态。"
                )
            ),
        },
        "summary": display_summary,
        "failure": None
        if success or ui_unverified
        else {
            "reason": failure_reason,
            "exit_code": return_code,
            "stderr_excerpt": stderr_excerpt,
            "last_event_type": last_event_type,
            "last_event_summary": last_event_summary,
        },
        "next_step": next_step,
        "mobile_workbench_url": mobile_url or None,
        "actions": actions,
        "root": str(root),
    }


def summarize_workflow_for_card(workflow: dict[str, Any] | None) -> dict[str, Any] | None:
    if not workflow:
        return None
    artifacts = workflow.get("artifacts") if isinstance(workflow.get("artifacts"), dict) else {}
    return {
        "status": workflow.get("status"),
        "stage": workflow.get("stage") or workflow.get("current_stage"),
        "business_success": bool(workflow.get("business_success")),
        "reason": workflow.get("reason"),
        "media_id": artifacts.get("media_id") or artifacts.get("draft_id"),
        "image_count": artifacts.get("image_count") or artifacts.get("wechat_image_url_count"),
        "material_dir": artifacts.get("material_dir"),
        "article_path": artifacts.get("article_path") or artifacts.get("article_md"),
        "draft_json": artifacts.get("draft_json"),
        "wechat_api_proof": artifacts.get("wechat_api_proof") or artifacts.get("draft_get_proof"),
        "draft_box_api_verified": bool(
            workflow.get("validation", {}).get("draft_box_api_verified")
            if isinstance(workflow.get("validation"), dict)
            else artifacts.get("draft_box_api_verified")
        ),
        "browser_proof_required": bool(artifacts.get("browser_proof_required")),
        "browser_proof_reason": artifacts.get("browser_proof_reason"),
    }


def lark_completion_text(card: dict[str, Any]) -> str:
    paths = card.get("paths") if isinstance(card.get("paths"), dict) else {}
    failure = card.get("failure") if isinstance(card.get("failure"), dict) else None
    workflow_summary = card.get("workflow_summary") if isinstance(card.get("workflow_summary"), dict) else None
    lines = [
        str(card.get("title") or "H.A.R.V.I.S. 任务状态"),
        "",
        f"状态：{card.get('status')}",
        f"任务包：{card.get('packet_id')}",
        f"run：{card.get('run_id')}",
        f"handoff：{card.get('handoff_id')}",
        f"harness/model：{card.get('harness')} / {card.get('model')}",
    ]
    if card.get("codex_thread_id"):
        lines.append(f"Codex thread：{card.get('codex_thread_id')}")
    if failure:
        reason_label = "阻塞原因" if card.get("status") in {"draft_created_ui_unverified", "draft_created_api_verified_ui_unverified"} else "失败原因"
        lines.extend(
            [
                "",
                f"{reason_label}：{failure.get('reason')}",
                f"退出码：{failure.get('exit_code')}",
                f"最后事件：{failure.get('last_event_type')} - {failure.get('last_event_summary') or 'no summary recorded'}",
            ]
        )
        if workflow_summary:
            lines.extend(
                [
                    "",
                    "Conductor 状态：",
                    f"- 阶段：{workflow_summary.get('stage')}",
                    f"- media_id：{workflow_summary.get('media_id') or '-'}",
                    f"- 图片数：{workflow_summary.get('image_count') or 0}",
                    f"- 素材目录：{workflow_summary.get('material_dir') or '-'}",
                    f"- 文章：{workflow_summary.get('article_path') or '-'}",
                    f"- draft_json：{workflow_summary.get('draft_json') or '-'}",
                    f"- API 验证：{'通过' if workflow_summary.get('draft_box_api_verified') else '未提供'}",
                    f"- API proof：{workflow_summary.get('wechat_api_proof') or '-'}",
                    f"- UI 验证：{'需要补充' if workflow_summary.get('browser_proof_required') else '未要求/可选'}",
                    f"- 阻塞：{workflow_summary.get('browser_proof_reason') or workflow_summary.get('reason') or '-'}",
                ]
            )
    else:
        summary = str(card.get("summary") or "").strip()
        if summary:
            lines.extend(["", "摘要：", summary[:900]])
    lines.extend(
        [
            "",
            f"events：{paths.get('events_jsonl')}",
            f"日志：{paths.get('stderr_log')}",
            f"下一步：{card.get('next_step')}",
        ]
    )
    if card.get("mobile_workbench_url"):
        lines.append(f"移动工作台：{card.get('mobile_workbench_url')}")
    return "\n".join(lines)


def stderr_worker(stream, stderr_path: Path, errors: "queue.Queue[str]") -> None:
    try:
        with stderr_path.open("ab") as handle:
            for chunk in iter(stream.readline, b""):
                handle.write(chunk)
                handle.flush()
    except Exception as exc:  # pragma: no cover - defensive worker path
        errors.put(f"stderr_worker: {exc}")


def stdout_worker(
    root: Path,
    stream,
    stdout_path: Path,
    events_path: Path,
    status_path: Path,
    state: dict[str, Any],
    errors: "queue.Queue[str]",
) -> None:
    try:
        with stdout_path.open("ab") as stdout_handle:
            for raw in iter(stream.readline, b""):
                stdout_handle.write(raw)
                stdout_handle.flush()
                line = raw.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception as exc:
                    event = {
                        "schemaVersion": "harvis.codex-jsonl-adapter.v0",
                        "observed_at": utc_now(),
                        "codex_event_type": "parse_error",
                        "summary": f"Could not parse Codex JSONL event: {exc}",
                        "raw_line": line[:2000],
                    }
                    append_mirrored_jsonl(root, events_path, event)
                    continue

                typ = event_type(obj)
                state["event_count"] = int(state.get("event_count", 0)) + 1
                state["last_event_type"] = typ
                state["last_event_at"] = utc_now()
                if typ == "thread.started":
                    thread_id = find_id(obj, ("thread_id", "threadid", "session_id", "sessionid", "id"))
                    if thread_id and UUID_RE.match(thread_id):
                        state["codex_thread_id"] = thread_id
                        state["codex_session_id"] = thread_id
                message = extract_agent_message(obj, typ)
                if message:
                    if typ == "agent_message" or not state.get("last_agent_message"):
                        state["last_agent_message"] = message

                event = {
                    "schemaVersion": "harvis.codex-jsonl-adapter.v0",
                    "observed_at": utc_now(),
                    "task_id": state.get("task_id") or None,
                    "handoff_id": state.get("handoff_id"),
                    "run_id": state.get("run_id"),
                    "packet_id": state.get("packet_id"),
                    "codex_event_type": typ,
                    "codex_thread_id": state.get("codex_thread_id"),
                    "codex_session_id": state.get("codex_session_id") or state.get("codex_thread_id"),
                    "summary": summarize(obj, typ),
                    "raw": obj,
                }
                append_mirrored_jsonl(root, events_path, event)
                send_lark_progress(event, state)

                status = load_json(status_path)
                status.update(
                    {
                        "adapter": "codex-jsonl",
                        "codex_event_count": state.get("event_count", 0),
                        "codex_last_event_type": typ,
                        "codex_last_event_at": state.get("last_event_at"),
                    }
                )
                if state.get("codex_thread_id"):
                    status["codex_thread_id"] = state["codex_thread_id"]
                    status["codex_session_id"] = state["codex_thread_id"]
                write_json(status_path, status)
    except Exception as exc:  # pragma: no cover - defensive worker path
        errors.put(f"stdout_worker: {exc}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--final-file", required=True)
    parser.add_argument("--stdout-log", required=True)
    parser.add_argument("--stderr-log", required=True)
    parser.add_argument("--events-jsonl", required=True)
    parser.add_argument("--thread-json", required=True)
    parser.add_argument("--status-json", required=True)
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--handoff-id", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--packet-id", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--lark-cli", default=os.environ.get("LARK_CLI", ""))
    parser.add_argument("--lark-message-id", default=os.environ.get("HARVIS_LARK_MESSAGE_ID", ""))
    parser.add_argument("--lark-chat-id", default=os.environ.get("HARVIS_LARK_CHAT_ID", ""))
    parser.add_argument("--lark-progress-events", default=os.environ.get("HARVIS_LARK_PROGRESS_EVENTS", "0"))
    parser.add_argument("--resume-thread-id", default=os.environ.get("HARVIS_CODEX_RESUME_THREAD_ID", ""))
    parser.add_argument("--approval-id", default=os.environ.get("HARVIS_APPROVAL_ID", ""))
    parser.add_argument(
        "--allow-unbound-resume",
        action="store_true",
        default=os.environ.get("HARVIS_ALLOW_UNBOUND_CODEX_RESUME", "") in {"1", "true", "TRUE", "yes", "YES"},
    )
    args = parser.parse_args()

    codex = Path(args.codex)
    if not codex.exists():
        print(f"missing codex CLI: {codex}", file=sys.stderr)
        return 127

    prompt_file = Path(args.prompt_file)
    final_file = Path(args.final_file)
    stdout_log = Path(args.stdout_log)
    stderr_log = Path(args.stderr_log)
    events_path = Path(args.events_jsonl)
    thread_json = Path(args.thread_json)
    status_path = Path(args.status_json)
    workspace_root = Path(args.root)
    task_id = find_task_id(workspace_root, args.packet_id, args.run_id, args.handoff_id)

    if args.resume_thread_id:
        approved, approval_reason = resume_approval_status(
            workspace_root,
            args.approval_id,
            args.resume_thread_id,
            args.run_id,
            args.packet_id,
            args.handoff_id,
        )
        if not approved:
            return deny_before_exec(
                workspace_root,
                events_path,
                status_path,
                task_id,
                args.handoff_id,
                args.run_id,
                args.packet_id,
                approval_reason,
                args.lark_cli,
                args.lark_message_id,
                args.lark_chat_id,
                stderr_log,
                args.model,
                args.resume_thread_id,
            )
        try:
            validate_resume_thread(workspace_root, args.resume_thread_id, args.lark_chat_id, args.allow_unbound_resume)
        except SystemExit as exc:
            return deny_before_exec(
                workspace_root,
                events_path,
                status_path,
                task_id,
                args.handoff_id,
                args.run_id,
                args.packet_id,
                str(exc),
                args.lark_cli,
                args.lark_message_id,
                args.lark_chat_id,
                stderr_log,
                args.model,
                args.resume_thread_id,
            )
        cmd = [
            str(codex),
            "exec",
            "resume",
            "--json",
            "-c",
            'approval_policy="never"',
            "-c",
            'shell_environment_policy.inherit="all"',
            "--skip-git-repo-check",
            "--output-last-message",
            str(final_file),
        ]
        if args.model:
            cmd.extend(["--model", args.model])
        cmd.extend([args.resume_thread_id, "-"])
    else:
        cmd = [
            str(codex),
            "exec",
            "--json",
            "-C",
            args.root,
            "--sandbox",
            "workspace-write",
            "-c",
            'approval_policy="never"',
            "-c",
            'shell_environment_policy.inherit="all"',
            "--skip-git-repo-check",
            "--output-last-message",
            str(final_file),
        ]
        if args.model:
            cmd.extend(["--model", args.model])
        cmd.append("-")

    state: dict[str, Any] = {
        "task_id": task_id,
        "handoff_id": args.handoff_id,
        "run_id": args.run_id,
        "packet_id": args.packet_id,
        "codex_thread_id": args.resume_thread_id or "",
        "codex_session_id": args.resume_thread_id or "",
        "event_count": 0,
        "model": args.model or "gpt-5.5",
        "stderr_log": str(stderr_log),
        "lark_cli": args.lark_cli,
        "lark_message_id": args.lark_message_id,
        "lark_chat_id": args.lark_chat_id,
        "lark_progress_enabled": args.lark_progress_events not in {"", "0", "false", "False", "no", "NO"},
        "lark_progress_card_enabled": os.environ.get("HARVIS_LARK_PROGRESS_CARD", "1") not in {"", "0", "false", "False", "no", "NO"},
        "lark_progress_max": int(os.environ.get("HARVIS_LARK_PROGRESS_MAX", "6")),
        "lark_progress_card_max": int(os.environ.get("HARVIS_LARK_PROGRESS_CARD_MAX", "24")),
        "mobile_workbench_url": mobile_workbench_url(workspace_root),
    }
    started_event = {
        "schemaVersion": "harvis.codex-jsonl-adapter.v0",
        "observed_at": utc_now(),
        "task_id": task_id or None,
        "handoff_id": args.handoff_id,
        "run_id": args.run_id,
        "packet_id": args.packet_id,
        "codex_event_type": "adapter.started",
        "codex_thread_id": state.get("codex_thread_id") or None,
        "codex_session_id": state.get("codex_session_id") or None,
        "summary": "Codex JSONL adapter started",
        "command": [part if part != str(prompt_file) else "<prompt-file>" for part in cmd],
    }
    append_mirrored_jsonl(workspace_root, events_path, started_event)
    send_lark_progress(started_event, state)

    errors: "queue.Queue[str]" = queue.Queue()
    with prompt_file.open("rb") as stdin:
        proc = subprocess.Popen(
            cmd,
            cwd=args.root,
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=os.environ.copy(),
        )
        assert proc.stdout is not None
        assert proc.stderr is not None
        stdout_thread = threading.Thread(
            target=stdout_worker,
            args=(workspace_root, proc.stdout, stdout_log, events_path, status_path, state, errors),
            daemon=True,
        )
        stderr_thread = threading.Thread(target=stderr_worker, args=(proc.stderr, stderr_log, errors), daemon=True)
        stdout_thread.start()
        stderr_thread.start()
        try:
            return_code = proc.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            proc.kill()
            return_code = 124
            with stderr_log.open("ab") as handle:
                handle.write(f"\n[harvis-codex-jsonl-adapter] timed out after {args.timeout_seconds}s\n".encode())
            if not final_file.exists() or not final_file.read_text(encoding="utf-8", errors="replace").strip():
                final_file.write_text(
                    f"Codex JSONL adapter timed out after {args.timeout_seconds}s before producing a reviewable result.\n",
                    encoding="utf-8",
                )
        stdout_thread.join(timeout=5)
        stderr_thread.join(timeout=5)

    worker_errors = []
    while not errors.empty():
        worker_errors.append(errors.get())
    if worker_errors:
        with stderr_log.open("a", encoding="utf-8") as handle:
            for error in worker_errors:
                handle.write(f"\n[harvis-codex-jsonl-adapter] {error}\n")

    if not final_file.exists() or not final_file.read_text(encoding="utf-8", errors="replace").strip():
        last_message = str(state.get("last_agent_message") or "").strip()
        if last_message:
            final_file.write_text(last_message + "\n", encoding="utf-8")

    thread_payload = {
        "schemaVersion": "harvis.codex-thread-binding.v0",
        "created_at": utc_now(),
        "task_id": task_id or None,
        "handoff_id": args.handoff_id,
        "run_id": args.run_id,
        "packet_id": args.packet_id,
        "codex_thread_id": state.get("codex_thread_id"),
        "codex_session_id": state.get("codex_session_id") or state.get("codex_thread_id"),
        "resumed_from_thread_id": args.resume_thread_id or None,
        "event_count": state.get("event_count", 0),
        "last_event_type": state.get("last_event_type"),
        "last_event_at": state.get("last_event_at"),
        "last_agent_message_preview": str(state.get("last_agent_message") or "")[:500],
        "exec_dir": str(final_file.parent),
        "events_jsonl": str(events_path),
        "final_file": str(final_file),
        "chat_id": args.lark_chat_id or None,
        "message_id": args.lark_message_id or None,
        "transport": {
            "lark_chat_id": args.lark_chat_id or None,
            "lark_message_id": args.lark_message_id or None,
        },
    }
    write_json(thread_json, thread_payload)
    append_thread_binding(workspace_root, thread_payload)

    if args.lark_chat_id or args.lark_message_id:
        binding = {
            "schemaVersion": "harvis.conversation-binding.v0",
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "transport": "feishu",
            "chat_id": args.lark_chat_id or None,
            "message_id": args.lark_message_id or None,
            "thread_id": args.lark_message_id or args.lark_chat_id or None,
            "sender_id": None,
            "conversation_key": f"feishu:{args.lark_chat_id or 'unknown'}:{args.lark_message_id or args.lark_chat_id or 'unknown'}",
            "agent_ref": "codex-jsonl-runner",
            "harness_ref": "codex",
            "model_ref": args.model or None,
            "route_ref": "harvis-codex-jsonl-adapter",
            "task_id": task_id or None,
            "run_id": args.run_id,
            "handoff_id": args.handoff_id,
            "packet_id": args.packet_id,
            "codex_thread_id": thread_payload.get("codex_thread_id"),
            "codex_session_id": thread_payload.get("codex_session_id"),
            "events_jsonl": str(events_path),
            "status": "completed" if return_code == 0 else "blocked",
        }
        append_conversation_binding(workspace_root, binding)
        append_agent_room_event(
            workspace_root,
            {
                "agent_room_version": "harvis.codex-jsonl-adapter.v0",
                "event_id": f"evt_codex_binding_{args.run_id}_{args.packet_id}",
                "topic_id": "gwt-workbench",
                "agent_id": "codex-jsonl-runner",
                "role": "executor",
                "event_type": "conversation.binding.created",
                "content": f"Bound Feishu conversation to Codex thread {thread_payload.get('codex_thread_id') or 'unknown'}.",
                "source_refs": [args.run_id, args.handoff_id, args.packet_id],
                "sensitivity": "internal",
                "created_at": utc_now(),
            },
        )

    status = load_json(status_path)
    status.update(
        {
            "adapter": "codex-jsonl",
            "codex_event_count": state.get("event_count", 0),
            "codex_last_event_type": state.get("last_event_type"),
            "codex_thread_binding": str(thread_json),
            "codex_events_jsonl": str(events_path),
        }
    )
    if thread_payload.get("codex_thread_id"):
        status["codex_thread_id"] = thread_payload["codex_thread_id"]
        status["codex_session_id"] = thread_payload["codex_thread_id"]
    if task_id:
        status["task_id"] = task_id
    write_json(status_path, status)

    completed_event = {
        "schemaVersion": "harvis.codex-jsonl-adapter.v0",
        "observed_at": utc_now(),
        "task_id": task_id or None,
        "handoff_id": args.handoff_id,
        "run_id": args.run_id,
        "packet_id": args.packet_id,
        "codex_event_type": "adapter.completed" if return_code == 0 else "adapter.failed",
        "codex_thread_id": thread_payload.get("codex_thread_id"),
        "codex_session_id": thread_payload.get("codex_session_id"),
        "summary": f"Codex JSONL adapter exited with code {return_code}",
        "exit_code": return_code,
    }
    append_mirrored_jsonl(workspace_root, events_path, completed_event)
    send_lark_progress(completed_event, state)

    completion_card_path = final_file.parent / "completion-card.json"
    completion_card = build_completion_card(
        root=workspace_root,
        task_id=task_id,
        handoff_id=args.handoff_id,
        run_id=args.run_id,
        packet_id=args.packet_id,
        model=args.model,
        return_code=return_code,
        final_file=final_file,
        stdout_log=stdout_log,
        stderr_log=stderr_log,
        events_path=events_path,
        thread_json=thread_json,
        status_path=status_path,
        thread_payload=thread_payload,
        mobile_url=str(state.get("mobile_workbench_url") or ""),
    )
    workflow = completion_card.get("workflow") if isinstance(completion_card.get("workflow"), dict) else None
    if workflow:
        append_mirrored_jsonl(
            workspace_root,
            events_path,
            {
                "schemaVersion": "harvis.workflow-events.v0",
                "observed_at": utc_now(),
                "task_id": task_id or None,
                "handoff_id": args.handoff_id,
                "run_id": args.run_id,
                "packet_id": args.packet_id,
                "harness": "codex",
                "codex_event_type": "workflow.verdict",
                "type": "workflow.verdict",
                "summary": workflow.get("reason"),
                "workflow": workflow,
            },
        )
    write_json(completion_card_path, completion_card)
    status = load_json(status_path)
    status.update(
        {
            "completion_card_json": str(completion_card_path),
            "status": completion_card.get("status"),
            "workflow": completion_card.get("workflow"),
            "runner_state": completion_card.get("status"),
            "runner_summary": completion_card.get("summary"),
            "runner_failure": completion_card.get("failure"),
            "conductor_task": str(final_file.parent / "conductor_task.json"),
            "conductor_events": str(final_file.parent / "conductor_events.jsonl"),
            "conductor_result": str(final_file.parent / "conductor_result.json"),
            "worker_registry": str(final_file.parent / "worker-registry.json"),
            "conductor": {
                "has_task": (final_file.parent / "conductor_task.json").exists(),
                "has_result": (final_file.parent / "conductor_result.json").exists(),
                "task_json": str(final_file.parent / "conductor_task.json"),
                "events_jsonl": str(final_file.parent / "conductor_events.jsonl"),
                "result_json": str(final_file.parent / "conductor_result.json"),
            },
        }
    )
    write_json(status_path, status)
    send_lark_text(
        args.lark_cli,
        args.lark_message_id,
        args.lark_chat_id,
        lark_completion_text(completion_card),
        stderr_log,
    )
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
