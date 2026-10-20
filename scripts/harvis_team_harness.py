#!/usr/bin/env python3
"""H.A.R.V.I.S. Team Harness v0 primitives.

This module is intentionally conservative: it records conversation bindings,
team tool proposals, and chair dry-run decisions, but it never executes a
dangerous action. Execution remains gated by Harvis approvals and handoffs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


VERSION = "harvis.team-harness.v0"
DEFAULT_CONTROL_RUNTIME = "harvis-conductor"
DEFAULT_HARNESS = "dsh"
DEFAULT_MODEL = "profile-default"
SUPPORTED_CONTROL_RUNTIMES = ["harvis-conductor", "codex-control"]
SUPPORTED_TOOLS = {
    "team_task_create",
    "team_send_message",
    "team_task_update",
    "team_list_models",
    "request_approval",
}
SUPPORTED_HARNESSES = ["dsh", "codex", "cxspark", "claude-code", "kimicode", "likecode", "manual"]
SUPPORTED_MODELS = ["profile-default", "gpt-5.5", "deepseek", "kimi", "claude", "mimo", "spark", "manual"]
DANGEROUS_ACTIONS = {
    "spawn_agent",
    "execute_command",
    "file_write",
    "browser_automation",
    "git_commit",
    "git_push",
    "publish",
    "delete",
    "memory_adopt",
    "external_write",
}
HIGH_RISK_TERMS = [
    "delete",
    "删除",
    "清空",
]
SECURITY_RISK_TERMS = {"secret", "token", "cookie", "credential", "凭据", "密码", "授权"}
NEGATION_MARKERS = [
    "do not",
    "don't",
    "dont",
    "without",
    "no ",
    "不要",
    "不准",
    "不得",
    "不用",
    "无需",
    "不需要",
    "不要真正",
    "别",
    "禁止",
    "不",
]
APPROVAL_ACTION_MAP = {
    "execute_command": "run_command",
    "file_write": "write_file",
    "browser_automation": "run_command",
    "git_commit": "commit",
    "git_push": "push",
    "publish": "publish_projection",
    "delete": "delete",
    "external_write": "write_file",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stable_id(prefix: str, *parts: object) -> str:
    body = "|".join(str(part) for part in parts if part is not None)
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()[:12]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{prefix}_{stamp}_{digest}"


def root_path(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must exist: {root}")
    return root


def agent_room(root: Path) -> Path:
    path = root / ".harvis" / "agent-room"
    path.mkdir(parents=True, exist_ok=True)
    return path


def append_jsonl(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(data, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n")


def read_jsonl(path: Path, limit: int | None = None) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if limit is not None:
        lines = lines[-limit:]
    rows: list[dict[str, Any]] = []
    for line in lines:
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def read_json(path: Path) -> dict[str, Any]:
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return obj if isinstance(obj, dict) else {}


def approved_record_for(root: Path, approval_id: str, action: str, target: str) -> tuple[bool, str]:
    if not approval_id.startswith("approval_"):
        return False, "approval_id must reference a persisted approval_ record"
    approval = read_json(root / ".harvis" / "approvals" / f"{approval_id}.json")
    if not approval:
        return False, "approval record not found"
    if approval.get("status") != "approved":
        return False, f"approval record is {approval.get('status') or 'unknown'}, not approved"
    approval_action = approval.get("action") if isinstance(approval.get("action"), dict) else {}
    expected_type = APPROVAL_ACTION_MAP.get(action)
    actual_type = str(approval_action.get("type") or "")
    if expected_type and actual_type and actual_type != expected_type:
        return False, f"approval action type {actual_type} does not match required {expected_type}"
    if target:
        target_obj = approval_action.get("target") if isinstance(approval_action.get("target"), dict) else {}
        target_text = json.dumps(target_obj or approval_action, ensure_ascii=False)
        if target not in target_text:
            return False, "approval target does not match requested target"
    return True, "Approved Harvis record matches the requested dangerous action."


def binding_file(root: Path) -> Path:
    return agent_room(root) / "conversation_binding.jsonl"


def tool_file(root: Path) -> Path:
    return agent_room(root) / "team_tool_calls.jsonl"


def decision_file(root: Path) -> Path:
    return agent_room(root) / "chair_decisions.jsonl"


def event_file(root: Path) -> Path:
    return agent_room(root) / "events.jsonl"


def conversation_key(transport: str, chat_id: str, message_id: str = "", thread_id: str = "") -> str:
    anchor = thread_id or message_id or chat_id
    return f"{transport}:{chat_id}:{anchor}"


def add_event(root: Path, event_type: str, content: str, refs: list[str] | None = None) -> dict[str, Any]:
    event = {
        "agent_room_version": VERSION,
        "event_id": stable_id("evt", event_type, content),
        "topic_id": "team-harness-v0",
        "agent_id": "harvis-team-harness",
        "role": "control-plane",
        "event_type": event_type,
        "content": content,
        "source_refs": refs or [],
        "sensitivity": "internal",
        "created_at": utc_now(),
    }
    append_jsonl(event_file(root), event)
    return event


def create_binding(args: argparse.Namespace) -> dict[str, Any]:
    root = root_path(args.root)
    key = args.conversation_key or conversation_key(args.transport, args.chat_id, args.message_id, args.thread_id)
    item = {
        "schemaVersion": "harvis.conversation-binding.v0",
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "transport": args.transport,
        "chat_id": args.chat_id,
        "message_id": args.message_id or None,
        "thread_id": args.thread_id or args.message_id or None,
        "sender_id": args.sender_id or None,
        "conversation_key": key,
        "agent_ref": args.agent_ref,
        "harness_ref": args.harness_ref,
        "model_ref": args.model_ref,
        "route_ref": args.route_ref,
        "task_id": args.task_id or None,
        "run_id": args.run_id or None,
        "handoff_id": args.handoff_id or None,
        "codex_thread_id": args.codex_thread_id or None,
        "status": args.status,
    }
    append_jsonl(binding_file(root), item)
    add_event(root, "conversation.binding.created", f"Bound {key} to {args.harness_ref}/{args.model_ref}.")
    return item


def resolve_binding(root: Path, transport: str, chat_id: str, query: str = "", limit: int = 500) -> dict[str, Any] | None:
    for item in reversed(read_jsonl(binding_file(root), limit=limit)):
        if query:
            values = {
                str(item.get("conversation_key") or ""),
                str(item.get("message_id") or ""),
                str(item.get("thread_id") or ""),
                str(item.get("task_id") or ""),
                str(item.get("run_id") or ""),
                str(item.get("handoff_id") or ""),
                str(item.get("codex_thread_id") or ""),
            }
            if query in values:
                return item
            continue
        if item.get("transport") == transport and item.get("chat_id") == chat_id:
            return item
    return None


def route_for_text(text: str) -> dict[str, Any]:
    lowered = text.lower()
    if any(token in lowered for token in ["browser", "网页", "浏览器", "搜索", "点击", "baidu", "google"]):
        return {
            "intent": "browser_operation",
            "recommended_harness": "codex",
            "recommended_model": "gpt-5.5",
            "reason": "Browser or web operation needs Codex tool feedback and JSONL event visibility.",
        }
    if any(token in lowered for token in ["cxspark", "spark"]):
        return {
            "intent": "cxspark_requested",
            "recommended_harness": "cxspark",
            "recommended_model": "spark",
            "reason": "The request explicitly selected the reviewed cxspark helper route.",
        }
    if any(token in lowered for token in ["微信文章", "mp.weixin.qq.com", "论文", "资料", "总结"]):
        return {
            "intent": "external_article_codex_conductor_task",
            "recommended_harness": "codex",
            "recommended_model": "gpt-5.5",
            "reason": "External article tasks need Codex Conductor planning; Kimi or reader tools are workers, not the top-level controller.",
        }
    if any(token in lowered for token in ["digital-me", "digital me", "dsh", "review", "审查", "复核", "diff", "代码", "仓库", "repo", "修复", "debug", "ui"]):
        return {
            "intent": "digital_me_dsh_task",
            "recommended_harness": DEFAULT_HARNESS,
            "recommended_model": DEFAULT_MODEL,
            "reason": "Digital-Me DSH is the default agent loop for general, coding, and review tasks.",
        }
    return {
        "intent": "general_task",
        "recommended_harness": DEFAULT_HARNESS,
        "recommended_model": DEFAULT_MODEL,
        "reason": "Default route for unbound tasks is the Digital-Me DSH/Cordis agent loop.",
    }


def risk_for_text(text: str) -> dict[str, Any]:
    lowered = text.lower()
    matched = high_risk_matches(text)
    if matched:
        return {
            "risk_level": "high",
            "requires_approval": True,
            "auto_execute_allowed": False,
            "reason": "Message mentions delete/destructive removal actions.",
            "matched_terms": matched[:8],
        }
    return {
        "risk_level": "low",
        "requires_approval": False,
        "auto_execute_allowed": True,
        "reason": "No high-risk action markers detected; execution still runs inside Harvis handoff/audit boundaries.",
        "matched_terms": [],
    }


def high_risk_matches(text: str) -> list[str]:
    lowered = text.lower()
    matches: list[str] = []
    for term in HIGH_RISK_TERMS:
        lowered_term = term.lower()
        cursor = 0
        while True:
            index = lowered.find(lowered_term, cursor)
            if index < 0:
                break
            cursor = index + max(len(lowered_term), 1)
            if lowered_term in SECURITY_RISK_TERMS:
                matches.append(term)
                break
            prefix = lowered[max(0, index - 24) : index]
            if any(marker in prefix for marker in NEGATION_MARKERS):
                continue
            matches.append(term)
            break
    return matches


def normalize_control_runtime(value: str) -> str:
    runtime = value or DEFAULT_CONTROL_RUNTIME
    if runtime not in SUPPORTED_CONTROL_RUNTIMES:
        return DEFAULT_CONTROL_RUNTIME
    return runtime


def chair_dry_run(args: argparse.Namespace) -> dict[str, Any]:
    root = root_path(args.root)
    route = route_for_text(args.prompt)
    risk = risk_for_text(args.prompt)
    control_runtime = normalize_control_runtime(args.control_runtime)
    requires_approval = bool(args.requires_approval or risk["requires_approval"])
    auto_execute_allowed = bool(risk["auto_execute_allowed"] and not requires_approval)
    decision = {
        "schemaVersion": "harvis.chair-decision.v0",
        "created_at": utc_now(),
        "decision_id": stable_id("decision", args.prompt, args.transport, args.chat_id),
        "dry_run": True,
        "model_invoked": False,
        "model_ref": args.chair_model,
        "control_runtime": control_runtime,
        "control_runtime_kind": "harvis_policy" if control_runtime == "harvis-conductor" else "codex_route_proposal",
        "control_runtime_switchable": True,
        "transport": args.transport or None,
        "chat_id": args.chat_id or None,
        "prompt_preview": args.prompt[:500],
        "move": "request_approval" if requires_approval else "delegate_task",
        "recommended_harness": args.harness_ref or route["recommended_harness"],
        "recommended_model": args.model_ref or route["recommended_model"],
        "reason": route["reason"],
        "risk": risk,
        "risk_level": risk["risk_level"],
        "requires_approval": requires_approval,
        "auto_execute_allowed": auto_execute_allowed,
        "proposed_tasks": [
            {
                "title": args.title or args.prompt[:80],
                "intent": route["intent"],
                "owner_slot_id": "planner",
                "status": "waiting_approval" if requires_approval else "ready_to_run",
            }
        ],
        "guardrails": {
            "l0_only_safety": True,
            "low_risk_auto_execute": True,
            "dangerous_actions_require_approval": sorted(DANGEROUS_ACTIONS),
            "high_risk_terms_require_approval": HIGH_RISK_TERMS,
        },
    }
    append_jsonl(decision_file(root), decision)
    add_event(root, "chair.route_proposal", f"Chair proposed {decision['recommended_harness']}/{decision['recommended_model']}: {decision['reason']}")
    return decision


def tool_call(args: argparse.Namespace) -> dict[str, Any]:
    root = root_path(args.root)
    if args.tool not in SUPPORTED_TOOLS:
        raise SystemExit(f"tool must be one of: {', '.join(sorted(SUPPORTED_TOOLS))}")
    payload: dict[str, Any]
    if args.payload:
        try:
            loaded = json.loads(args.payload)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"payload must be JSON: {exc}") from exc
        payload = loaded if isinstance(loaded, dict) else {"value": loaded}
    else:
        payload = {}
    item = {
        "schemaVersion": "harvis.team-tool-call.v0",
        "created_at": utc_now(),
        "tool_call_id": stable_id("teamtool", args.tool, args.caller, payload),
        "tool": args.tool,
        "caller": args.caller,
        "dry_run": True,
        "requires_approval": args.tool != "team_list_models",
        "status": "proposal_recorded",
        "payload": payload,
    }
    if args.tool == "team_list_models":
        item["result"] = {
            "harnesses": SUPPORTED_HARNESSES,
            "models": SUPPORTED_MODELS,
            "default": {"harness": DEFAULT_HARNESS, "model": DEFAULT_MODEL},
        }
    append_jsonl(tool_file(root), item)
    add_event(root, f"team.tool.{args.tool}", f"Recorded dry-run team tool call {item['tool_call_id']}.")
    return item


def gate(args: argparse.Namespace) -> dict[str, Any]:
    root = root_path(args.root)
    action = args.action.strip()
    if action in DANGEROUS_ACTIONS:
        allowed, reason = approved_record_for(root, args.approval_id, action, args.target)
    else:
        allowed, reason = True, "Action is low-risk."
    item = {
        "schemaVersion": "harvis.approval-gate-check.v0",
        "created_at": utc_now(),
        "gate_id": stable_id("gate", action, args.target, args.approval_id),
        "action": action,
        "target": args.target,
        "approval_id": args.approval_id or None,
        "allowed": allowed,
        "status": "allowed" if allowed else "denied_missing_approval",
        "reason": reason if allowed else f"Dangerous action requires matching approved Harvis approval record: {reason}",
    }
    append_jsonl(agent_room(root) / "approval_gate_checks.jsonl", item)
    add_event(root, "approval_gate.checked", f"{action} -> {item['status']}: {item['reason']}")
    return item


def print_json(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description="H.A.R.V.I.S. Team Harness v0 dry-run primitives.")
    parser.add_argument(
        "--root",
        default=Path(os.environ.get("HARVIS_WORKSPACE_ROOT", str(Path.cwd()))),
        type=Path,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    bind = sub.add_parser("bind")
    bind.add_argument("--transport", required=True)
    bind.add_argument("--chat-id", required=True)
    bind.add_argument("--message-id", default="")
    bind.add_argument("--thread-id", default="")
    bind.add_argument("--sender-id", default="")
    bind.add_argument("--conversation-key", default="")
    bind.add_argument("--agent-ref", default="harvis-chair")
    bind.add_argument("--harness-ref", default=DEFAULT_HARNESS)
    bind.add_argument("--model-ref", default=DEFAULT_MODEL)
    bind.add_argument("--route-ref", default="default")
    bind.add_argument("--task-id", default="")
    bind.add_argument("--run-id", default="")
    bind.add_argument("--handoff-id", default="")
    bind.add_argument("--codex-thread-id", default="")
    bind.add_argument("--status", default="active")

    resolve = sub.add_parser("resolve")
    resolve.add_argument("--transport", required=True)
    resolve.add_argument("--chat-id", required=True)
    resolve.add_argument("--query", default="")

    dry = sub.add_parser("chair-dry-run")
    dry.add_argument("--prompt", required=True)
    dry.add_argument("--title", default="")
    dry.add_argument("--transport", default="")
    dry.add_argument("--chat-id", default="")
    dry.add_argument("--chair-model", default="deepseek-chair")
    dry.add_argument("--control-runtime", default=os.environ.get("HARVIS_CONTROL_RUNTIME", DEFAULT_CONTROL_RUNTIME))
    dry.add_argument("--harness-ref", default="")
    dry.add_argument("--model-ref", default="")
    dry.add_argument("--requires-approval", action="store_true", default=False)

    tool = sub.add_parser("tool")
    tool.add_argument("--tool", required=True)
    tool.add_argument("--caller", default="harvis-chair")
    tool.add_argument("--payload", default="")

    gate_parser = sub.add_parser("gate")
    gate_parser.add_argument("--action", required=True)
    gate_parser.add_argument("--target", default="")
    gate_parser.add_argument("--approval-id", default="")

    list_parser = sub.add_parser("list-bindings")
    list_parser.add_argument("--limit", type=int, default=50)

    args = parser.parse_args()
    root = root_path(args.root)
    if args.command == "bind":
        print_json(create_binding(args))
        return 0
    if args.command == "resolve":
        binding = resolve_binding(root, args.transport, args.chat_id, args.query)
        print_json({"ok": bool(binding), "binding": binding})
        return 0 if binding else 1
    if args.command == "chair-dry-run":
        print_json(chair_dry_run(args))
        return 0
    if args.command == "tool":
        print_json(tool_call(args))
        return 0
    if args.command == "gate":
        result = gate(args)
        print_json(result)
        return 0 if result.get("allowed") else 2
    if args.command == "list-bindings":
        print_json({"ok": True, "bindings": read_jsonl(binding_file(root), args.limit)})
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
