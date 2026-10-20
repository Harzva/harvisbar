#!/usr/bin/env python3
"""Create and decide H.A.R.V.I.S. approval items without executing actions."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


APPROVAL_VERSION = "v0.12-alpha"
PENDING = "pending"
DECISIONS = {"approved", "denied", "cancelled"}
ACTION_TYPES = {
    "write_file",
    "run_command",
    "publish_projection",
    "commit",
    "push",
    "deploy",
    "delete",
    "read_outside_allowlist",
    "install_service",
    "external_send",
    "other",
}


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def timestamp_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def resolve_workspace_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def rel(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.name


def safe_text(value: str, max_chars: int = 1000) -> str:
    cleaned = " ".join(value.replace("\x00", "").split())
    return cleaned[:max_chars]


def target_ref(root: Path, value: str) -> dict[str, str]:
    cleaned = safe_text(value, 500)
    if not cleaned:
        return {"kind": "unspecified", "display": "unspecified"}
    candidate = Path(cleaned).expanduser()
    if candidate.is_absolute():
        try:
            display = candidate.resolve().relative_to(root.resolve()).as_posix()
            return {"kind": "workspace_path", "display": display}
        except ValueError:
            return {"kind": "outside_workspace", "display": candidate.name or "outside-workspace"}
    return {"kind": "relative_or_resource", "display": cleaned}


def approvals_dir(root: Path) -> Path:
    path = root / ".harvis" / "approvals"
    path.mkdir(parents=True, exist_ok=True)
    return path


def runs_dir(root: Path) -> Path:
    path = root / ".harvis" / "runs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def approval_id_for(run_id: str, action_type: str, target: str, reason: str) -> str:
    seed = f"{run_id}:{action_type}:{target}:{reason}:{timestamp_slug()}"
    digest = hashlib.sha256(seed.encode("utf-8")).hexdigest()[:8]
    return f"approval_{timestamp_slug()}_{digest}"


def approval_path(root: Path, approval_id: str) -> Path:
    if not approval_id.startswith("approval_"):
        raise SystemExit("approval_id must start with approval_")
    return approvals_dir(root) / f"{approval_id}.json"


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return loaded if isinstance(loaded, dict) else None


def run_path(root: Path, run_id: str) -> Path:
    return runs_dir(root) / f"{run_id}.json"


def update_run_approval_state(root: Path, run_id: str) -> None:
    path = run_path(root, run_id)
    run = read_json(path)
    if not run:
        return
    ids: list[str] = []
    pending = False
    for approval_file in approvals_dir(root).glob("approval_*.json"):
        approval = read_json(approval_file)
        if not approval or approval.get("run_id") != run_id:
            continue
        approval_id = approval.get("approval_id")
        if isinstance(approval_id, str):
            ids.append(approval_id)
        if approval.get("status") == PENDING:
            pending = True
    run["approval"] = {
        "required": bool(ids),
        "pending": pending,
        "ids": sorted(set(ids)),
    }
    run["updated_at"] = now_utc()
    path.write_text(json.dumps(run, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_approval_markdown(root: Path, approval: dict[str, Any]) -> None:
    path = approvals_dir(root) / f"{approval['approval_id']}.md"
    decision = approval.get("decision") or {}
    lines = [
        f"# H.A.R.V.I.S. Approval {approval['approval_id']}",
        "",
        f"Status: {approval['status']}",
        f"Run: {approval['run_id']}",
        f"Action: {approval['action']['type']}",
        f"Risk: {approval['risk']}",
        f"Scope: {approval['scope']}",
        f"Created: {approval['created_at']}",
        f"Updated: {approval['updated_at']}",
        "",
        "Target:",
        f"- Kind: {approval['action']['target']['kind']}",
        f"- Display: {approval['action']['target']['display']}",
        "",
        "Reason:",
        f"- {approval['action']['reason']}",
        "",
        "Safety:",
        "- This approval item is record-only.",
        "- Creating or approving it does not execute the requested action.",
        "- Execution requires a separate approved runtime policy.",
        "",
    ]
    if decision:
        lines.extend(
            [
                "Decision:",
                f"- By: {decision.get('by', 'unknown')}",
                f"- At: {decision.get('at', 'unknown')}",
                f"- Notes: {decision.get('notes', '')}",
                "",
            ]
        )
    path.write_text("\n".join(lines), encoding="utf-8")


def create_approval(
    root: Path,
    run_id: str,
    action_type: str,
    target: str,
    reason: str,
    risk: str = "medium",
    scope: str = "one_time",
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    run_id = safe_text(run_id, 120)
    if not run_id.startswith("run_"):
        raise SystemExit("run_id must start with run_")
    action_type = action_type.strip()
    if action_type not in ACTION_TYPES:
        raise SystemExit(f"action_type must be one of: {', '.join(sorted(ACTION_TYPES))}")
    approval_id = approval_id_for(run_id, action_type, target, reason)
    moment = now_utc()
    approval = {
        "approval_version": APPROVAL_VERSION,
        "approval_id": approval_id,
        "status": PENDING,
        "run_id": run_id,
        "created_at": moment,
        "updated_at": moment,
        "risk": safe_text(risk, 80) or "medium",
        "scope": safe_text(scope, 80) or "one_time",
        "action": {
            "type": action_type,
            "target": target_ref(root, target),
            "reason": safe_text(reason, 1000),
        },
        "decision": None,
        "safety": {
            "recordOnly": True,
            "executesAction": False,
            "includesSecrets": False,
            "includesRawMemory": False,
            "includesLocalAbsolutePaths": False,
        },
    }
    path = approval_path(root, approval_id)
    path.write_text(json.dumps(approval, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_approval_markdown(root, approval)
    update_run_approval_state(root, run_id)
    return approval


def decide_approval(
    root: Path,
    approval_id: str,
    decision: str,
    decided_by: str = "human",
    notes: str = "",
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    decision = decision.strip().lower()
    if decision not in DECISIONS:
        raise SystemExit(f"decision must be one of: {', '.join(sorted(DECISIONS))}")
    path = approval_path(root, approval_id)
    approval = read_json(path)
    if not approval:
        raise SystemExit(f"approval not found: {approval_id}")
    approval["status"] = decision
    approval["updated_at"] = now_utc()
    approval["decision"] = {
        "by": safe_text(decided_by, 120) or "human",
        "at": approval["updated_at"],
        "notes": safe_text(notes, 1000),
    }
    path.write_text(json.dumps(approval, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_approval_markdown(root, approval)
    run_id = approval.get("run_id")
    if isinstance(run_id, str):
        update_run_approval_state(root, run_id)
    return approval


def summarize_approval(root: Path, path: Path) -> dict[str, Any] | None:
    approval = read_json(path)
    if not approval:
        return None
    action = approval.get("action") if isinstance(approval.get("action"), dict) else {}
    target = action.get("target") if isinstance(action.get("target"), dict) else {}
    return {
        "approval_id": approval.get("approval_id"),
        "status": approval.get("status"),
        "run_id": approval.get("run_id"),
        "risk": approval.get("risk"),
        "scope": approval.get("scope"),
        "action_type": action.get("type"),
        "target": target,
        "updated_at": approval.get("updated_at"),
        "path": rel(path, root),
    }


def list_approvals(root: Path, status: str | None = None, limit: int = 50) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    rows: list[dict[str, Any]] = []
    status_filter = status.strip().lower() if isinstance(status, str) and status.strip() else None
    for path in sorted(approvals_dir(root).glob("approval_*.json"), key=lambda item: item.stat().st_mtime, reverse=True):
        item = summarize_approval(root, path)
        if not item:
            continue
        if status_filter and item.get("status") != status_filter:
            continue
        rows.append(item)
        if len(rows) >= limit:
            break
    return {
        "workspace_root": str(root),
        "approval_count": len(rows),
        "approvals": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Create and decide H.A.R.V.I.S. approval items.")
    parser.add_argument("--root", default=".", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)

    request_parser = subparsers.add_parser("request")
    request_parser.add_argument("--run-id", required=True)
    request_parser.add_argument("--action-type", required=True, choices=sorted(ACTION_TYPES))
    request_parser.add_argument("--target", required=True)
    request_parser.add_argument("--reason", required=True)
    request_parser.add_argument("--risk", default="medium")
    request_parser.add_argument("--scope", default="one_time")

    decide_parser = subparsers.add_parser("decide")
    decide_parser.add_argument("--approval-id", required=True)
    decide_parser.add_argument("--decision", required=True, choices=sorted(DECISIONS))
    decide_parser.add_argument("--decided-by", default="human")
    decide_parser.add_argument("--notes", default="")

    list_parser = subparsers.add_parser("list")
    list_parser.add_argument("--status", default="")
    list_parser.add_argument("--limit", default=50, type=int)

    args = parser.parse_args()
    root = resolve_workspace_root(args.root)
    if args.command == "request":
        result = create_approval(
            root,
            run_id=args.run_id,
            action_type=args.action_type,
            target=args.target,
            reason=args.reason,
            risk=args.risk,
            scope=args.scope,
        )
    elif args.command == "decide":
        result = decide_approval(
            root,
            approval_id=args.approval_id,
            decision=args.decision,
            decided_by=args.decided_by,
            notes=args.notes,
        )
    else:
        result = list_approvals(root, status=args.status, limit=max(1, min(args.limit, 500)))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


def rust_approval_argv(argv: list[str]) -> list[str]:
    from harvis_rust_shim import split_leading_options

    global_args, rest = split_leading_options(argv, value_options={"--root"})
    if not rest:
        return ["approvals", *global_args]
    command, *tail = rest
    if command == "request":
        return ["request-approval", *global_args, *tail]
    if command == "decide":
        return ["decide-approval", *global_args, *tail]
    if command == "list":
        return ["approvals", *global_args, *tail]
    return ["approvals", *global_args, command, *tail]


if __name__ == "__main__":
    import sys

    from harvis_rust_shim import exec_harvis, use_legacy_python_entrypoint

    if use_legacy_python_entrypoint():
        raise SystemExit(main())
    raise SystemExit(exec_harvis(rust_approval_argv(sys.argv[1:])))
