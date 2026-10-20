#!/usr/bin/env python3
"""Record H.A.R.V.I.S. notification candidates under a strict allowlist."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


NOTIFICATION_VERSION = "v0.13-alpha"
ALLOWED_KINDS = {"blocked", "approval", "verified", "service_unhealthy"}


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def resolve_workspace_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def notifications_path(root: Path) -> Path:
    harvis_dir = root / ".harvis"
    harvis_dir.mkdir(parents=True, exist_ok=True)
    return harvis_dir / "notifications.jsonl"


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return loaded if isinstance(loaded, dict) else None


def read_jsonl(path: Path, limit: int = 500) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines()[-limit:]:
        if not line.strip():
            continue
        try:
            loaded = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(loaded, dict):
            rows.append(loaded)
    return rows


def notification_id(dedupe_key: str) -> str:
    digest = hashlib.sha256(dedupe_key.encode("utf-8")).hexdigest()[:10]
    return f"notification_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}_{digest}"


def build_notification(kind: str, title: str, body: str, source: str, dedupe_key: str) -> dict[str, Any]:
    if kind not in ALLOWED_KINDS:
        raise SystemExit(f"notification kind must be one of: {', '.join(sorted(ALLOWED_KINDS))}")
    return {
        "notification_version": NOTIFICATION_VERSION,
        "notification_id": notification_id(dedupe_key),
        "kind": kind,
        "status": "candidate",
        "created_at": now_utc(),
        "title": title,
        "body": body,
        "source": source,
        "dedupe_key": dedupe_key,
        "safety": {
            "allowedByPolicy": True,
            "includesSecrets": False,
            "includesRawMemory": False,
            "includesLocalAbsolutePaths": False,
        },
    }


def append_unique(root: Path, notification: dict[str, Any]) -> bool:
    path = notifications_path(root)
    existing = read_jsonl(path)
    dedupe_key = notification["dedupe_key"]
    if any(item.get("dedupe_key") == dedupe_key for item in existing):
        return False
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(notification, sort_keys=True) + "\n")
    return True


def status_counts(root: Path) -> tuple[int, int, str | None]:
    status = read_json(root / ".harvis" / "status.json") or {}
    errors = status.get("errors")
    runtime_errors = len(errors) if isinstance(errors, list) else 0
    packet_counts = status.get("packet_status_counts")
    blocked = 0
    if isinstance(packet_counts, dict):
        raw_blocked = packet_counts.get("blocked", 0)
        blocked = raw_blocked if isinstance(raw_blocked, int) else 0
    last_tick = status.get("last_tick_at") if isinstance(status.get("last_tick_at"), str) else None
    return runtime_errors, blocked, last_tick


def pending_approval_count(root: Path) -> int:
    approvals_dir = root / ".harvis" / "approvals"
    if not approvals_dir.exists():
        return 0
    count = 0
    for path in approvals_dir.glob("approval_*.json"):
        approval = read_json(path)
        if approval and approval.get("status") == "pending":
            count += 1
    return count


def derive_notifications(root: Path) -> list[dict[str, Any]]:
    root = resolve_workspace_root(root)
    runtime_errors, blocked, last_tick = status_counts(root)
    pending = pending_approval_count(root)
    notifications: list[dict[str, Any]] = []

    if pending:
        notifications.append(
            build_notification(
                "approval",
                "H.A.R.V.I.S. approval required",
                f"{pending} approval item(s) are pending review.",
                "approvals",
                f"approval:{pending}",
            )
        )
    if runtime_errors or blocked:
        notifications.append(
            build_notification(
                "blocked",
                "H.A.R.V.I.S. needs attention",
                f"{blocked} blocked packet(s), {runtime_errors} runtime warning(s).",
                "runtime",
                f"blocked:{blocked}:{runtime_errors}:{last_tick or 'none'}",
            )
        )
    if last_tick and not pending and not blocked and not runtime_errors:
        notifications.append(
            build_notification(
                "verified",
                "H.A.R.V.I.S. runtime verified",
                "The latest read-only tick completed without warnings.",
                "runtime",
                f"verified:{last_tick}",
            )
        )
    service_status = read_json(root / ".harvis" / "service-status.json")
    if service_status and service_status.get("state") == "unhealthy":
        notifications.append(
            build_notification(
                "service_unhealthy",
                "H.A.R.V.I.S. service unhealthy",
                "A local H.A.R.V.I.S. service reports an unhealthy state.",
                "service",
                f"service_unhealthy:{service_status.get('updated_at', 'unknown')}",
            )
        )
    return notifications


def check_notifications(root: Path, write: bool = True) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    candidates = derive_notifications(root)
    written: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    for notification in candidates:
        if write and append_unique(root, notification):
            written.append(notification)
        else:
            skipped.append(notification)
    return {
        "workspace_root": str(root),
        "allowed_kinds": sorted(ALLOWED_KINDS),
        "candidate_count": len(candidates),
        "written_count": len(written),
        "written": written,
        "skipped": skipped,
    }


def list_notifications(root: Path, kind: str | None = None, limit: int = 50) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    if kind and kind not in ALLOWED_KINDS:
        raise SystemExit(f"notification kind must be one of: {', '.join(sorted(ALLOWED_KINDS))}")
    rows = []
    for item in reversed(read_jsonl(notifications_path(root), max(limit, 1) * 4)):
        if kind and item.get("kind") != kind:
            continue
        rows.append(item)
        if len(rows) >= limit:
            break
    return {
        "workspace_root": str(root),
        "allowed_kinds": sorted(ALLOWED_KINDS),
        "notification_count": len(rows),
        "notifications": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply H.A.R.V.I.S. notification policy.")
    parser.add_argument("--root", default=".", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("--no-write", action="store_true")
    list_parser = subparsers.add_parser("list")
    list_parser.add_argument("--kind", default="")
    list_parser.add_argument("--limit", default=50, type=int)
    args = parser.parse_args()

    root = resolve_workspace_root(args.root)
    if args.command == "check":
        result = check_notifications(root, write=not args.no_write)
    else:
        result = list_notifications(
            root,
            kind=args.kind.strip() or None,
            limit=max(1, min(args.limit, 500)),
        )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


def rust_notification_argv(argv: list[str]) -> list[str]:
    from harvis_rust_shim import split_leading_options

    global_args, rest = split_leading_options(argv, value_options={"--root"})
    if not rest:
        return ["notifications", *global_args, "list"]
    command, *tail = rest
    if command == "check":
        mapped_tail: list[str] = []
        for item in tail:
            if item == "--no-write":
                mapped_tail.extend(["--write", "false"])
            else:
                mapped_tail.append(item)
        return ["notifications", *global_args, "check", *mapped_tail]
    return ["notifications", *global_args, command, *tail]


if __name__ == "__main__":
    import sys

    from harvis_rust_shim import exec_harvis, use_legacy_python_entrypoint

    if use_legacy_python_entrypoint():
        raise SystemExit(main())
    raise SystemExit(exec_harvis(rust_notification_argv(sys.argv[1:])))
