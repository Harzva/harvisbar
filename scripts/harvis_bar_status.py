#!/usr/bin/env python3
"""Generate a redacted H.A.R.V.I.S. status contract for local menu bar UIs."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harvis_agent_harnesses import build_agent_harness_status
from harvis_hub_adapter import hub_status, llmwiki_status, redact_text
from harvis_state_store import (
    existing_runtime_path,
    read_runtime_json_object,
    runtime_fallback_path,
    write_text_with_fallback,
)


BAR_STATUS_VERSION = "v0.32-alpha"
SCHEMA_VERSION = "harvis.bar-status.v0"
PENDING_APPROVAL_STATES = {
    "pending",
    "requested",
    "waiting",
    "waiting_approval",
    "needs_review",
    "needs-approval",
}


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def resolve_workspace_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def read_json_object(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return loaded if isinstance(loaded, dict) else None


def parse_packet_status(path: Path) -> str:
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("Status:"):
                return line.split(":", 1)[1].strip() or "unknown"
    except OSError:
        return "unknown"
    return "unknown"


def packet_counts(outbox_dir: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    if not outbox_dir.exists():
        return counts
    for path in outbox_dir.glob("*.md"):
        if not path.is_file():
            continue
        status = parse_packet_status(path)
        counts[status] = counts.get(status, 0) + 1
    return dict(sorted(counts.items()))


def read_last_event(event_log: Path) -> dict[str, Any] | None:
    if not event_log.exists():
        return None
    try:
        rows = event_log.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in reversed(rows):
        if not line.strip():
            continue
        try:
            loaded = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(loaded, dict):
            return {
                "type": str(loaded.get("type", "unknown")),
                "status": str(loaded.get("status", "unknown")),
                "at": loaded.get("at") if isinstance(loaded.get("at"), str) else None,
            }
    return None


def approval_is_pending(path: Path) -> bool:
    loaded = read_json_object(path)
    if loaded is None:
        return False
    raw_state = loaded.get("status", loaded.get("state", loaded.get("decision", "pending")))
    state = str(raw_state).strip().lower()
    return state in PENDING_APPROVAL_STATES


def pending_approval_count(approvals_dir: Path) -> int:
    if not approvals_dir.exists():
        return 0
    return sum(1 for path in approvals_dir.glob("*.json") if approval_is_pending(path))


def read_run_summary(path: Path) -> dict[str, Any] | None:
    loaded = read_json_object(path)
    if not loaded:
        return None
    return {
        "runId": loaded.get("run_id"),
        "state": loaded.get("state"),
        "mode": loaded.get("mode"),
        "packetId": loaded.get("packet_id"),
        "updatedAt": loaded.get("updated_at"),
    }


def run_summary(runs_dir: Path) -> tuple[int, dict[str, Any] | None]:
    if not runs_dir.exists():
        return 0, None
    run_paths = sorted(runs_dir.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    latest = None
    for path in run_paths:
        latest = read_run_summary(path)
        if latest:
            break
    return len(run_paths), latest


def public_workspace_label(root: Path) -> str:
    return root.name or "workspace"


def empty_task_progress_status() -> dict[str, Any]:
    """Keep the legacy Python status shape compatible without exposing local data."""

    return {
        "schemaVersion": "harvis.task-progress.v0",
        "safeForHarvisBar": True,
        "generatedAt": now_utc(),
        "status": "skipped",
        "summary": "Task progress is provided by the Rust runtime.",
        "activeCount": 0,
        "items": [],
        "current": None,
        "safety": {
            "redacted": True,
            "includesSecrets": False,
            "includesLocalAbsolutePaths": False,
        },
    }


def count_runtime_errors(status: dict[str, Any] | None) -> int:
    if not status:
        return 0
    errors = status.get("errors")
    return len(errors) if isinstance(errors, list) else 0


def count_runtime_warnings(status: dict[str, Any] | None) -> int:
    if not status:
        return 0
    warnings = status.get("warnings")
    return len(warnings) if isinstance(warnings, list) else 0


def runtime_mode(status: dict[str, Any] | None) -> str:
    if not status:
        return "not-initialized"
    mode = status.get("mode")
    return str(mode) if isinstance(mode, str) and mode else "unknown"


def autonomy_level(status: dict[str, Any] | None) -> int:
    if not status:
        return 1
    value = status.get("autonomy_level", 1)
    if isinstance(value, int) and not isinstance(value, bool):
        return max(0, min(value, 4))
    return 1


def derive_runtime_state(
    status: dict[str, Any] | None,
    counts: dict[str, int],
    pending_approvals: int,
) -> str:
    if pending_approvals:
        return "waiting_approval"
    if count_runtime_errors(status) or counts.get("blocked", 0):
        return "blocked"
    if status and status.get("last_tick_at"):
        return "verified"
    return "idle"


def derive_summary(
    state: str,
    packets: int,
    blocked: int,
    pending_approvals: int,
    runtime_issues: int = 0,
) -> str:
    if state == "waiting_approval":
        return f"{pending_approvals} approval item(s) need review."
    if state == "blocked":
        return f"{blocked} blocked packet(s), {runtime_issues} runtime issue(s) need review."
    if state == "verified":
        return f"Runtime synchronized with {packets} packet(s)."
    return "Runtime is idle or not initialized."


def knowledge_summary() -> dict[str, Any]:
    try:
        hub = hub_status()
        llmwiki = llmwiki_status()
    except Exception as exc:
        return {
            "hub": "unavailable",
            "wiki": "unavailable",
            "activeSources": [],
            "allowlistedSources": 0,
            "lastLookupAt": None,
            "policy": "redacted-local-index",
            "error": redact_text(str(exc), 180),
            "redacted": True,
            "includesLocalAbsolutePaths": False,
        }

    active_sources = ["harzva-local-knowledge-hub"] if hub.get("hub") == "available" else []
    if llmwiki.get("registered"):
        active_sources.append("llmwiki.local_project")
    wiki = llmwiki.get("wiki") if isinstance(llmwiki.get("wiki"), dict) else {}
    return {
        "hub": hub.get("hub", "unavailable"),
        "wiki": "available" if wiki.get("available") else "unavailable",
        "activeSources": active_sources,
        "allowlistedSources": 1 if llmwiki.get("registered") else 0,
        "lastLookupAt": hub.get("generated_at"),
        "policy": "harzvahub-indexed-redacted-read-only",
        "redacted": True,
        "includesLocalAbsolutePaths": False,
    }


def build_bar_status(
    root: Path,
    served_by_http: bool = False,
    profile_root: Path | None = None,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    harvis_dir = root / ".harvis"
    status, _, status_source = read_runtime_json_object(root, "status.json", profile_root)
    events_path = existing_runtime_path(root, "events.jsonl", profile_root)
    outbox_dir = harvis_dir / "outbox"
    approvals_dir = harvis_dir / "approvals"
    runs_dir = harvis_dir / "runs"

    counts = packet_counts(outbox_dir)
    packets = sum(counts.values())
    blocked = counts.get("blocked", 0)
    pending_approvals = pending_approval_count(approvals_dir)
    run_count, active_run = run_summary(runs_dir)
    state = derive_runtime_state(status, counts, pending_approvals)
    errors = count_runtime_errors(status)
    warnings = count_runtime_warnings(status)
    last_event = read_last_event(events_path)
    allowlist = status.get("allowlist") if isinstance(status, dict) else []
    allowlist_count = len(allowlist) if isinstance(allowlist, list) else 0
    last_tick_at = status.get("last_tick_at") if isinstance(status, dict) else None

    service_tick_state = "warning" if errors or blocked else "idle"
    if not status:
        service_tick_state = "not-initialized"

    return {
        "schemaVersion": SCHEMA_VERSION,
        "safeForHarvisBar": True,
        "generatedAt": now_utc(),
        "runtime": {
            "name": "H.A.R.V.I.S.",
            "state": state,
            "mode": runtime_mode(status),
            "autonomyLevel": autonomy_level(status),
            "version": BAR_STATUS_VERSION,
            "sourceRuntimeVersion": status.get("runtime_version") if isinstance(status, dict) else None,
            "summary": derive_summary(state, packets, blocked, pending_approvals, errors + warnings),
        },
        "workspace": {
            "label": public_workspace_label(root),
            "rootDisplay": public_workspace_label(root),
            "configured": harvis_dir.exists() or runtime_fallback_path(root, "status.json", profile_root).exists(),
            "statusPresent": status is not None,
            "allowlistCount": allowlist_count,
            "stateStore": status_source,
        },
        "serviceHealth": {
            "http": "running" if served_by_http else "not-probed",
            "tickRunner": service_tick_state,
            "mcp": "available",
        },
        "work": {
            "packets": packets,
            "packetStatusCounts": counts,
            "blocked": blocked,
            "pendingApprovals": pending_approvals,
            "runtimeErrors": errors,
            "runtimeWarnings": warnings,
            "runs": run_count,
            "activeRun": active_run,
            "lastTickAt": last_tick_at if isinstance(last_tick_at, str) else None,
            "lastEvent": last_event,
        },
        "knowledge": knowledge_summary(),
        "agentHarnesses": build_agent_harness_status(run_tests=False),
        "taskProgress": empty_task_progress_status(),
        "safety": {
            "redacted": True,
            "includesSecrets": False,
            "includesRawMemory": False,
            "includesCredentialPaths": False,
            "includesLocalAbsolutePaths": False,
            "networkExposure": "localhost-only",
        },
    }


def write_bar_status(root: Path, status: dict[str, Any]) -> Path:
    root = resolve_workspace_root(root)
    harvis_dir = root / ".harvis"
    output = harvis_dir / "bar-status.json"
    actual, warning = write_text_with_fallback(
        output,
        runtime_fallback_path(root, "bar-status.json"),
        json.dumps(status, indent=2, sort_keys=True) + "\n",
    )
    if actual is None:
        raise SystemExit(warning or f"failed to write bar status: {output}")
    return actual


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate the redacted H.A.R.V.I.S. menu bar status contract."
    )
    parser.add_argument("--root", default=".", help="Workspace root containing .harvis/.")
    parser.add_argument(
        "--write",
        action="store_true",
        help="Also write .harvis/bar-status.json inside the workspace.",
    )
    args = parser.parse_args()

    root = Path(args.root)
    status = build_bar_status(root)
    if args.write:
        output = write_bar_status(root, status)
        print(f"wrote bar status: {output}")
    print(json.dumps(status, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
