#!/usr/bin/env python3
"""Maintain stable H.A.R.V.I.S. run records for work packets."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


RUN_LEDGER_VERSION = "v0.11-alpha"


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def resolve_workspace_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def rel(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def parse_prefixed_line(text: str, prefix: str) -> str | None:
    for line in text.splitlines():
        if line.startswith(prefix):
            return line.split(":", 1)[1].strip() or None
    return None


def packet_metadata(packet_path: Path, root: Path) -> dict[str, Any]:
    text = packet_path.read_text(encoding="utf-8")
    status = parse_prefixed_line(text, "Status:") or "unknown"
    source = parse_prefixed_line(text, "Source:")
    safety = parse_prefixed_line(text, "Safety:")
    generated = parse_prefixed_line(text, "Generated:")
    return {
        "packet_id": packet_path.stem,
        "packet_path": rel(packet_path, root),
        "status": status,
        "source": source,
        "safety": safety,
        "generated": generated,
    }


def run_id_for_packet(packet_path: Path) -> str:
    return f"run_{packet_path.stem}"


def state_for_packet_status(status: str) -> str:
    if status == "blocked":
        return "blocked"
    if status in {"verified", "archived"}:
        return status
    return "planning"


def run_paths(root: Path, run_id: str) -> tuple[Path, Path]:
    runs_dir = root / ".harvis" / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    return runs_dir / f"{run_id}.json", runs_dir / f"{run_id}.md"


def read_existing(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return loaded if isinstance(loaded, dict) else None


def build_run(root: Path, packet_path: Path) -> dict[str, Any]:
    packet = packet_metadata(packet_path, root)
    run_id = run_id_for_packet(packet_path)
    json_path, _ = run_paths(root, run_id)
    existing = read_existing(json_path) or {}
    created_at = existing.get("created_at") if isinstance(existing.get("created_at"), str) else now_utc()
    state = state_for_packet_status(packet["status"])
    return {
        "run_ledger_version": RUN_LEDGER_VERSION,
        "run_id": run_id,
        "packet_id": packet["packet_id"],
        "state": state,
        "mode": existing.get("mode", "planner"),
        "created_at": created_at,
        "updated_at": now_utc(),
        "origin": {
            "trigger": "file_inbox",
            "source": packet["source"],
        },
        "packet": packet,
        "approval": {
            "required": state == "blocked",
            "pending": False,
            "ids": existing.get("approval", {}).get("ids", []) if isinstance(existing.get("approval"), dict) else [],
        },
        "verification": existing.get("verification", {"status": "not_started"}),
        "outputs": existing.get("outputs", {}),
    }


def write_run_markdown(path: Path, run: dict[str, Any]) -> None:
    lines = [
        f"# H.A.R.V.I.S. Run {run['run_id']}",
        "",
        f"Status: {run['state']}",
        f"Mode: {run['mode']}",
        f"Packet: {run['packet']['packet_path']}",
        f"Created: {run['created_at']}",
        f"Updated: {run['updated_at']}",
        f"Approval Required: {run['approval']['required']}",
        "",
        "Safety:",
        f"- Packet status: {run['packet']['status']}",
        f"- Packet safety note: {run['packet'].get('safety') or 'none recorded'}",
        "",
        "Lifecycle:",
        "- planning: packet accepted and ready for planning/review",
        "- blocked: human review or approval required before execution",
        "- verified: completed and checked",
        "- archived: retained for audit",
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def sync_packet_run(root: Path, packet_path: Path) -> dict[str, Any]:
    run = build_run(root, packet_path)
    json_path, md_path = run_paths(root, run["run_id"])
    json_path.write_text(json.dumps(run, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_run_markdown(md_path, run)
    return {
        "run_id": run["run_id"],
        "state": run["state"],
        "packet_id": run["packet_id"],
        "json_path": rel(json_path, root),
        "markdown_path": rel(md_path, root),
    }


def resolve_packet_path(root: Path, value: str) -> Path:
    candidate = Path(value).expanduser()
    outbox = root / ".harvis" / "outbox"
    if not candidate.is_absolute():
        candidate = root / candidate if candidate.parent != Path(".") else outbox / candidate.name
    candidate = candidate.resolve()
    if not candidate.exists() or not candidate.is_file():
        raise SystemExit(f"packet not found: {candidate}")
    if outbox.resolve() not in candidate.parents:
        raise SystemExit(f"packet must be under .harvis/outbox: {candidate}")
    return candidate


def sync_packet_runs(
    root: Path,
    packet_paths: list[Path] | None = None,
    limit: int = 500,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    outbox = root / ".harvis" / "outbox"
    if packet_paths is None:
        packet_paths = sorted(outbox.glob("*.md"), key=lambda item: item.stat().st_mtime, reverse=True)[:limit]
    synced = [sync_packet_run(root, path.expanduser().resolve()) for path in packet_paths if path.exists()]
    return {
        "workspace_root": str(root),
        "run_count": len(synced),
        "runs": synced,
    }


def list_runs(root: Path, limit: int = 50) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    runs_dir = root / ".harvis" / "runs"
    runs: list[dict[str, Any]] = []
    if runs_dir.exists():
        for path in sorted(runs_dir.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)[:limit]:
            loaded = read_existing(path)
            if not loaded:
                continue
            runs.append(
                {
                    "run_id": loaded.get("run_id"),
                    "state": loaded.get("state"),
                    "mode": loaded.get("mode"),
                    "packet_id": loaded.get("packet_id"),
                    "updated_at": loaded.get("updated_at"),
                    "path": rel(path, root),
                }
            )
    return {
        "workspace_root": str(root),
        "run_count": len(runs),
        "runs": runs,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Maintain H.A.R.V.I.S. run ledger records.")
    parser.add_argument("--root", default=".", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    sync_parser = subparsers.add_parser("sync")
    sync_parser.add_argument("--packet", action="append", default=[])
    sync_parser.add_argument("--limit", type=int, default=500)
    list_parser = subparsers.add_parser("list")
    list_parser.add_argument("--limit", type=int, default=50)
    args = parser.parse_args()

    root = resolve_workspace_root(args.root)
    if args.command == "sync":
        packet_paths = [resolve_packet_path(root, packet) for packet in args.packet] if args.packet else None
        print(json.dumps(sync_packet_runs(root, packet_paths, args.limit), indent=2, sort_keys=True))
        return 0
    if args.command == "list":
        print(json.dumps(list_runs(root, args.limit), indent=2, sort_keys=True))
        return 0
    return 1


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis, use_legacy_python_entrypoint

    if use_legacy_python_entrypoint():
        raise SystemExit(main())
    legacy_args = sys.argv[1:]
    if "sync" in legacy_args:
        mapped = ["sync-runs", *[arg for arg in legacy_args if arg != "sync"]]
    elif "list" in legacy_args:
        mapped = ["runs", *[arg for arg in legacy_args if arg != "list"]]
    else:
        mapped = ["runs", *legacy_args]
    raise SystemExit(exec_harvis(mapped))
