#!/usr/bin/env python3
"""Generate private H.A.R.V.I.S. memory snapshots and reviewable signals."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from harvis_inbox_scan import SENSITIVE_PATTERNS, is_within_root  # noqa: E402
from harvis_hub_adapter import hub_status, llmwiki_status  # noqa: E402
from harvis_runtime_tick import PROFILE_FILES  # noqa: E402


SNAPSHOT_VERSION = "v0.14-alpha"


def now_utc() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def timestamp_slug(moment: datetime) -> str:
    return moment.strftime("%Y%m%dT%H%M%SZ")


def rel(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def resolve_workspace_root(value: Path) -> Path:
    root = value.expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must be an existing directory: {root}")
    return root


def read_json(path: Path, warnings: list[str]) -> dict[str, Any] | None:
    if not path.exists():
        warnings.append(f"missing json file: {path}")
        return None
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        warnings.append(f"could not read json file: {path}: {exc}")
        return None
    if not isinstance(loaded, dict):
        warnings.append(f"json file is not an object: {path}")
        return None
    return loaded


def sensitive_detected(text: str) -> bool:
    return any(pattern.search(text) for pattern in SENSITIVE_PATTERNS)


def redacted_excerpt(text: str, max_chars: int) -> tuple[str, bool]:
    lines: list[str] = []
    found_sensitive = False
    for line in text.splitlines():
        if sensitive_detected(line):
            found_sensitive = True
            lines.append("[redacted sensitive-looking line]")
        else:
            lines.append(line)
    excerpt = "\n".join(lines).strip()
    if len(excerpt) > max_chars:
        excerpt = excerpt[:max_chars].rstrip() + "\n[truncated]"
    return excerpt, found_sensitive


def parse_status_line(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("Status:"):
            return line.split(":", 1)[1].strip() or "unknown"
    return "unknown"


def parse_prefixed_line(text: str, prefix: str) -> str | None:
    for line in text.splitlines():
        if line.startswith(prefix):
            return line.split(":", 1)[1].strip() or None
    return None


def packet_metadata(path: Path, root: Path, max_excerpt_chars: int) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    excerpt, has_sensitive = redacted_excerpt(text, max_excerpt_chars)
    return {
        "path": rel(path, root),
        "bytes": path.stat().st_size,
        "modified_at": int(path.stat().st_mtime),
        "status": parse_status_line(text),
        "source": parse_prefixed_line(text, "Source:"),
        "safety": parse_prefixed_line(text, "Safety:"),
        "sensitive_marker_detected": has_sensitive or sensitive_detected(text),
        "excerpt": excerpt,
    }


def report_metadata(path: Path, root: Path, max_excerpt_chars: int) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    excerpt, has_sensitive = redacted_excerpt(text, max_excerpt_chars)
    return {
        "path": rel(path, root),
        "bytes": path.stat().st_size,
        "modified_at": int(path.stat().st_mtime),
        "status": parse_prefixed_line(text, "Status:"),
        "sensitive_marker_detected": has_sensitive or sensitive_detected(text),
        "excerpt": excerpt,
    }


def read_recent_events(path: Path, max_events: int, warnings: list[str]) -> list[dict[str, Any]]:
    if max_events <= 0:
        return []
    if not path.exists():
        warnings.append(f"missing event log: {path}")
        return []
    rows = path.read_text(encoding="utf-8").splitlines()[-max_events:]
    events: list[dict[str, Any]] = []
    for line in rows:
        if not line.strip():
            continue
        try:
            loaded = json.loads(line)
        except json.JSONDecodeError:
            warnings.append(f"skipped invalid event log line in {path}")
            continue
        if isinstance(loaded, dict):
            events.append(loaded)
    return events


def profile_metadata(profile_root: Path) -> dict[str, Any]:
    root = profile_root.expanduser().resolve()
    files: list[dict[str, Any]] = []
    missing: list[str] = []
    for relative_path in PROFILE_FILES:
        path = root / relative_path
        if path.exists():
            files.append(
                {
                    "path": relative_path,
                    "bytes": path.stat().st_size,
                    "modified_at": int(path.stat().st_mtime),
                }
            )
        else:
            missing.append(relative_path)
    return {
        "root": str(root),
        "exists": root.exists(),
        "files": files,
        "missing": missing,
    }


def knowledge_source_snapshot(warnings: list[str]) -> dict[str, Any]:
    try:
        hub = hub_status()
        llmwiki = llmwiki_status()
    except Exception as exc:
        warnings.append(f"knowledge source snapshot unavailable: {exc}")
        return {
            "redacted": True,
            "includesLocalAbsolutePaths": False,
            "hub": {"state": "unavailable"},
            "sources": [],
            "provenance": [],
        }

    wiki = llmwiki.get("wiki") if isinstance(llmwiki.get("wiki"), dict) else {}
    lookup = llmwiki.get("lookup") if isinstance(llmwiki.get("lookup"), dict) else {}
    policy = llmwiki.get("policy") if isinstance(llmwiki.get("policy"), dict) else {}
    wiki_items = wiki.get("items") if isinstance(wiki.get("items"), list) else []
    provenance_items = []
    for item in wiki_items[:5]:
        if not isinstance(item, dict):
            continue
        provenance_items.append(
            {
                "title": item.get("title"),
                "page_id": item.get("page_id"),
                "rel_path": item.get("rel_path"),
                "score": item.get("score"),
            }
        )
    return {
        "redacted": True,
        "includesLocalAbsolutePaths": False,
        "hub": {
            "state": hub.get("hub"),
            "generated_at": hub.get("generated_at"),
            "summary": hub.get("summary") if isinstance(hub.get("summary"), dict) else {},
        },
        "sources": [
            {
                "source_id": llmwiki.get("source_id", "llmwiki.local_project"),
                "registered": bool(llmwiki.get("registered")),
                "discovery": policy.get("discovery", "harzvahub-only"),
                "direct_full_repo_scan": bool(policy.get("directFullRepoScan")),
                "allowlist_required_for_content": bool(policy.get("allowlistRequiredForContent", True)),
                "wiki_available": bool(wiki.get("available")),
                "wiki_matches": int(wiki.get("matches", 0) or 0),
                "lookup_count": int(lookup.get("count", 0) or 0),
            }
        ],
        "provenance": [
            {
                "source_id": llmwiki.get("source_id", "llmwiki.local_project"),
                "kind": "harzvahub-wiki-search",
                "query": "llmwiki",
                "items": provenance_items,
            }
        ],
    }


def candidate_signal(name: str, summary: str, evidence: list[str]) -> dict[str, Any]:
    return {
        "name": name,
        "status": "candidate",
        "requires_review": True,
        "summary": summary,
        "evidence": evidence,
    }


def distill_signals(snapshot: dict[str, Any]) -> list[dict[str, Any]]:
    signals: list[dict[str, Any]] = []
    packet_counts = snapshot["packet_status_counts"]
    packets = snapshot["packets"]
    warnings = snapshot["warnings"]
    profile_missing = snapshot["profile"]["missing"]

    if packets:
        signals.append(
            candidate_signal(
                "work_intake_active",
                f"H.A.R.V.I.S. has {len(packets)} tracked work packet(s).",
                [f"packet_status_counts={packet_counts}"],
            )
        )
    else:
        signals.append(
            candidate_signal(
                "no_work_packets_observed",
                "No H.A.R.V.I.S. work packets were present during this snapshot.",
                ["packets=0"],
            )
        )

    blocked = packet_counts.get("blocked", 0)
    if blocked:
        signals.append(
            candidate_signal(
                "blocked_packet_needs_review",
                f"{blocked} blocked packet(s) need human review before execution.",
                ["blocked packet status present"],
            )
        )

    sensitive_packets = [packet["path"] for packet in packets if packet["sensitive_marker_detected"]]
    if sensitive_packets:
        signals.append(
            candidate_signal(
                "sensitive_marker_seen",
                "Sensitive-looking packet content was detected and should stay private.",
                sensitive_packets,
            )
        )

    runtime_errors = snapshot.get("runtime_status", {}).get("errors") if snapshot.get("runtime_status") else []
    if runtime_errors:
        signals.append(
            candidate_signal(
                "runtime_warnings_present",
                "The latest runtime status contains warnings or errors.",
                [str(error) for error in runtime_errors],
            )
        )

    if profile_missing:
        signals.append(
            candidate_signal(
                "profile_incomplete",
                "The H.A.R.V.I.S. profile is missing required files.",
                profile_missing,
            )
        )

    knowledge = snapshot.get("knowledge_sources") if isinstance(snapshot.get("knowledge_sources"), dict) else {}
    sources = knowledge.get("sources") if isinstance(knowledge.get("sources"), list) else []
    for source in sources:
        if not isinstance(source, dict):
            continue
        source_id = str(source.get("source_id", "unknown"))
        if source.get("registered"):
            signals.append(
                candidate_signal(
                    "knowledge_source_registered",
                    f"{source_id} is visible as a redacted H.A.R.V.I.S. knowledge source.",
                    [
                        f"discovery={source.get('discovery')}",
                        f"wiki_matches={source.get('wiki_matches')}",
                        f"direct_full_repo_scan={source.get('direct_full_repo_scan')}",
                    ],
                )
            )

    if warnings:
        signals.append(
            candidate_signal(
                "snapshot_warnings_present",
                "The snapshot completed with operational warnings.",
                warnings,
            )
        )

    return signals


def write_signals_markdown(path: Path, snapshot: dict[str, Any], signals: list[dict[str, Any]]) -> None:
    lines = [
        "# H.A.R.V.I.S. Candidate Digital-Me Signals",
        "",
        f"Snapshot: {snapshot['snapshot_id']}",
        f"Generated: {snapshot['generated_at']}",
        "Status: candidate",
        "Adoption: not adopted; human review required",
        "",
        "Summary:",
        f"- Workspace: {snapshot['workspace_root']}",
        f"- Packets: {len(snapshot['packets'])}",
        f"- Events: {len(snapshot['recent_events'])}",
        f"- Reports: {len(snapshot['reports'])}",
        f"- Knowledge sources: {len(snapshot.get('knowledge_sources', {}).get('sources', []))}",
        "",
        "Candidate Signals:",
    ]
    if not signals:
        lines.append("- none")
    for signal in signals:
        lines.append(f"- {signal['name']}: {signal['summary']}")
        lines.append("  Review: required")
        for evidence in signal["evidence"][:5]:
            safe_evidence, _ = redacted_excerpt(str(evidence), 240)
            lines.append(f"  Evidence: {safe_evidence}")
    lines.extend(
        [
            "",
            "Boundaries:",
            "- This file is a candidate signal report, not an adopted memory.",
            "- Do not copy raw private packet bodies into public artifacts.",
            "- Human review is required before any long-term memory update.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def parse_signal_markdown(text: str, limit: int, root: Path | None = None) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    in_signals = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "Candidate Signals:":
            in_signals = True
            continue
        if stripped == "Boundaries:":
            break
        if not in_signals:
            continue
        if stripped.startswith("- ") and ": " in stripped:
            if current is not None:
                candidates.append(current)
                if len(candidates) >= limit:
                    return candidates
            name, summary = stripped[2:].split(": ", 1)
            clean_name = "".join(char.lower() if char.isalnum() else "-" for char in name).strip("-") or "memory-signal"
            current = {
                "candidate_id": f"memory_{len(candidates) + 1}_{clean_name[:48]}",
                "kind": "memory_candidate",
                "name": name.strip(),
                "summary": summary.strip(),
                "status": "candidate",
                "requires_review": True,
                "evidence": [],
            }
            continue
        if current is not None and stripped.startswith("Evidence: "):
            evidence = stripped.split(": ", 1)[1].strip()
            if root is not None:
                evidence = safe_memory_warning(evidence, root)
            current["evidence"].append(evidence)
    if current is not None and len(candidates) < limit:
        candidates.append(current)
    return candidates[:limit]


def safe_memory_warning(value: object, root: Path) -> str:
    warning = str(value)
    root_text = str(root.resolve())
    if root_text and root_text in warning:
        warning = warning.replace(root_text, "<workspace>")
    for marker in ["/Users/", "/Volumes/"]:
        if marker in warning:
            return "redacted local path warning"
    return warning[:240]


def list_memory_candidates(root: Path, limit: int = 50) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    memory_dir = root / ".harvis" / "memory"
    index_path = memory_dir / "index.json"
    if not index_path.exists():
        return {
            "workspace": {"label": root.name or "workspace"},
            "memory_index": {
                "exists": False,
                "latest_generated_at": None,
                "latest_signals": None,
                "candidate_signal_count": 0,
                "warnings": ["memory snapshot has not been generated"],
            },
            "candidate_count": 0,
            "candidates": [],
        }
    try:
        index = json.loads(index_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {
            "workspace": {"label": root.name or "workspace"},
            "memory_index": {
                "exists": True,
                "latest_generated_at": None,
                "latest_signals": None,
                "candidate_signal_count": 0,
                "warnings": [f"could not read memory index: {exc}"],
            },
            "candidate_count": 0,
            "candidates": [],
        }
    if not isinstance(index, dict):
        index = {}
    latest_signals = index.get("latest_signals")
    candidates: list[dict[str, Any]] = []
    warnings: list[str] = []
    if isinstance(latest_signals, str) and latest_signals.strip():
        signal_path = (root / latest_signals).resolve()
        if is_within_root(signal_path, root) and signal_path.exists():
            candidates = parse_signal_markdown(signal_path.read_text(encoding="utf-8"), max(1, min(limit, 500)), root)
        else:
            warnings.append("latest signal report is missing or outside workspace")
    elif index.get("candidate_signal_count"):
        warnings.append("memory index has candidate count but no latest signal report")
    warnings.extend([safe_memory_warning(item, root) for item in index.get("warnings", []) if isinstance(item, str)][:10])
    return {
        "workspace": {"label": root.name or "workspace"},
        "memory_index": {
            "exists": True,
            "latest_generated_at": index.get("latest_generated_at"),
            "latest_signals": latest_signals if isinstance(latest_signals, str) else None,
            "candidate_signal_count": index.get("candidate_signal_count", len(candidates)),
            "packet_status_counts": index.get("packet_status_counts", {}),
            "knowledge_source_count": index.get("knowledge_source_count", 0),
            "warnings": warnings,
        },
        "candidate_count": len(candidates),
        "candidates": candidates[: max(1, min(limit, 500))],
    }


def generate_snapshot(
    root: Path,
    profile_root: Path,
    max_events: int,
    max_packets: int,
    max_reports: int,
    max_excerpt_chars: int,
) -> dict[str, Any]:
    root = resolve_workspace_root(root)
    harvis_dir = root / ".harvis"
    if not is_within_root(harvis_dir, root):
        raise SystemExit(f"refusing to write outside workspace root: {harvis_dir}")

    warnings: list[str] = []
    moment = now_utc()
    snapshot_id = f"snapshot-{timestamp_slug(moment)}"
    memory_dir = harvis_dir / "memory"
    snapshots_dir = memory_dir / "snapshots"
    signals_dir = memory_dir / "signals"
    snapshots_dir.mkdir(parents=True, exist_ok=True)
    signals_dir.mkdir(parents=True, exist_ok=True)

    status_path = harvis_dir / "status.json"
    events_path = harvis_dir / "events.jsonl"
    outbox_dir = harvis_dir / "outbox"
    reports_dir = harvis_dir / "reports"

    runtime_status = read_json(status_path, warnings)
    recent_events = read_recent_events(events_path, max_events, warnings)

    packet_paths = []
    if outbox_dir.exists():
        packet_paths = sorted(outbox_dir.glob("*.md"), key=lambda item: item.stat().st_mtime, reverse=True)
    else:
        warnings.append(f"missing outbox: {outbox_dir}")
    packets = [packet_metadata(path, root, max_excerpt_chars) for path in packet_paths[:max_packets]]

    report_paths = []
    if reports_dir.exists():
        report_paths = sorted(reports_dir.glob("*.md"), key=lambda item: item.stat().st_mtime, reverse=True)
    else:
        warnings.append(f"missing reports: {reports_dir}")
    reports = [report_metadata(path, root, max_excerpt_chars) for path in report_paths[:max_reports]]
    knowledge_sources = knowledge_source_snapshot(warnings)

    snapshot = {
        "snapshot_version": SNAPSHOT_VERSION,
        "snapshot_id": snapshot_id,
        "generated_at": moment.isoformat(),
        "workspace_root": str(root),
        "runtime_status": runtime_status,
        "recent_events": recent_events,
        "packets": packets,
        "packet_status_counts": dict(sorted(Counter(packet["status"] for packet in packets).items())),
        "reports": reports,
        "knowledge_sources": knowledge_sources,
        "profile": profile_metadata(profile_root),
        "warnings": warnings,
        "adoption": {
            "status": "not_adopted",
            "requires_human_review": True,
        },
    }
    signals = distill_signals(snapshot)
    snapshot["candidate_signal_count"] = len(signals)

    snapshot_path = snapshots_dir / f"{snapshot_id}.json"
    signals_path = signals_dir / f"signals-{timestamp_slug(moment)}.md"
    index_path = memory_dir / "index.json"

    snapshot_path.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_signals_markdown(signals_path, snapshot, signals)
    index = {
        "snapshot_version": SNAPSHOT_VERSION,
        "latest_snapshot": rel(snapshot_path, root),
        "latest_signals": rel(signals_path, root),
        "latest_generated_at": moment.isoformat(),
        "packet_status_counts": snapshot["packet_status_counts"],
        "candidate_signal_count": len(signals),
        "knowledge_source_count": len(knowledge_sources.get("sources", [])),
        "warnings": warnings,
    }
    index_path.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    return {
        "workspace_root": str(root),
        "snapshot_path": str(snapshot_path),
        "signals_path": str(signals_path),
        "index_path": str(index_path),
        "packet_status_counts": snapshot["packet_status_counts"],
        "candidate_signal_count": len(signals),
        "knowledge_source_count": len(knowledge_sources.get("sources", [])),
        "warnings": warnings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate private H.A.R.V.I.S. memory snapshot and candidate signals."
    )
    parser.add_argument("--root", default=".", type=Path, help="Workspace root containing .harvis/.")
    parser.add_argument(
        "--profile-root",
        default="~/.harvis",
        type=Path,
        help="H.A.R.V.I.S. runtime profile root. Defaults to ~/.harvis.",
    )
    parser.add_argument("--max-events", default=50, type=int, help="Maximum recent events to include.")
    parser.add_argument("--max-packets", default=50, type=int, help="Maximum packets to include.")
    parser.add_argument("--max-reports", default=10, type=int, help="Maximum reports to include.")
    parser.add_argument(
        "--max-excerpt-chars",
        default=1200,
        type=int,
        help="Maximum redacted excerpt characters for packet/report private snapshot entries.",
    )
    args = parser.parse_args()

    result = generate_snapshot(
        args.root,
        args.profile_root,
        max_events=max(args.max_events, 0),
        max_packets=max(args.max_packets, 0),
        max_reports=max(args.max_reports, 0),
        max_excerpt_chars=max(args.max_excerpt_chars, 0),
    )
    print(f"wrote snapshot: {result['snapshot_path']}")
    print(f"wrote signals: {result['signals_path']}")
    print(f"wrote index: {result['index_path']}")
    print(f"candidate signals: {result['candidate_signal_count']}")
    if result["warnings"]:
        print(f"warnings: {len(result['warnings'])}")
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("memory-snapshot", legacy_main=main))
