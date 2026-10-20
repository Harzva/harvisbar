#!/usr/bin/env python3
"""Run H.A.R.V.I.S. v0.3-alpha read-only runtime ticks."""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from harvis_inbox_scan import is_within_root, scan_inboxes  # noqa: E402
from harvis_run_ledger import sync_packet_runs  # noqa: E402
from harvis_state_store import (  # noqa: E402
    append_text_with_fallback,
    runtime_fallback_path,
    write_text_with_fallback,
)


RUNTIME_VERSION = "v0.3-alpha"
DEFAULT_CONFIG: dict[str, Any] = {
    "autonomy_level": 1,
    "default_inbox": ".harvis/inbox.md",
    "default_outbox": ".harvis/outbox",
    "default_reports": ".harvis/reports",
    "status_file": ".harvis/status.json",
    "event_log": ".harvis/events.jsonl",
    "tick_interval_seconds": 1200,
    "allowlist": [".harvis/inbox.md"],
}

PROFILE_FILES = [
    "agent.md",
    "policy.md",
    "runtime.toml",
    "skills/planner.md",
    "skills/reviewer.md",
    "skills/executor.md",
    "skills/inbox.md",
    "skills/memory_snapshot.md",
    "contexts/digital_me.md",
    "contexts/agentworkos.md",
]


def now_utc() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def timestamp_slug(moment: datetime) -> str:
    return moment.strftime("%Y%m%dT%H%M%SZ")


def load_toml(path: Path) -> tuple[dict[str, Any], list[str]]:
    config = dict(DEFAULT_CONFIG)
    errors: list[str] = []
    if not path.exists():
        errors.append(f"config not found, using defaults: {path}")
        return config, errors

    try:
        import tomllib

        loaded = tomllib.loads(path.read_text(encoding="utf-8"))
    except ModuleNotFoundError:
        try:
            loaded = parse_minimal_toml(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append(f"invalid config, using defaults: {path}: {exc}")
            return config, errors
    except Exception as exc:  # tomllib errors are intentionally collapsed.
        errors.append(f"invalid config, using defaults: {path}: {exc}")
        return config, errors

    for key in DEFAULT_CONFIG:
        if key in loaded:
            config[key] = loaded[key]
    return config, errors


def parse_minimal_toml(text: str) -> dict[str, Any]:
    loaded: dict[str, Any] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, raw_value = stripped.split("=", 1)
        key = key.strip()
        value = raw_value.strip()
        if value.startswith('"') and value.endswith('"'):
            loaded[key] = value[1:-1]
            continue
        if value.startswith("[") and value.endswith("]"):
            items: list[str] = []
            body = value[1:-1].strip()
            if body:
                for item in body.split(","):
                    item_value = item.strip()
                    if item_value.startswith('"') and item_value.endswith('"'):
                        items.append(item_value[1:-1])
                    else:
                        items.append(item_value)
            loaded[key] = items
            continue
        try:
            loaded[key] = int(value)
        except ValueError:
            loaded[key] = value
    return loaded


def rel(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def resolve_workspace_path(root: Path, value: str) -> Path:
    candidate = Path(value).expanduser()
    if not candidate.is_absolute():
        candidate = root / candidate
    return candidate.resolve()


def packet_status(packet_path: Path) -> str:
    try:
        for line in packet_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("Status:"):
                return line.split(":", 1)[1].strip() or "unknown"
    except OSError:
        return "unknown"
    return "unknown"


def profile_metadata(profile_root: Path) -> dict[str, Any]:
    root = profile_root.expanduser().resolve()
    missing: list[str] = []
    present: list[str] = []
    for relative_path in PROFILE_FILES:
        path = root / relative_path
        if path.exists():
            present.append(relative_path)
        else:
            missing.append(relative_path)

    return {
        "root": str(root),
        "agent": "agent.md" if "agent.md" in present else None,
        "policy": "policy.md" if "policy.md" in present else None,
        "skills": [path for path in present if path.startswith("skills/")],
        "contexts": [path for path in present if path.startswith("contexts/")],
        "missing": [f"profile file missing: {path}" for path in missing],
    }


def render_report(status: dict[str, Any], report_status: str) -> str:
    lines = [
        "# H.A.R.V.I.S. Tick Report",
        "",
        f"Status: {report_status}",
        "Autonomy: Level 1 read-only",
        f"Workspace: {status['workspace_root']}",
        f"Scanned: {', '.join(status['scanned_inboxes']) or 'none'}",
        f"Packets: {len(status['packets_written'])}",
        f"Errors: {len(status['errors'])}",
        "",
        "Packet Status Counts:",
    ]
    if status["packet_status_counts"]:
        for name, count in sorted(status["packet_status_counts"].items()):
            lines.append(f"- {name}: {count}")
    else:
        lines.append("- none: 0")
    lines.extend(
        [
            "",
            "Next:",
            "1. Review new or blocked packets under .harvis/outbox/.",
            "2. Ask H.A.R.V.I.S. to execute a packet only after review.",
            "",
        ]
    )
    if status["errors"]:
        lines.append("Errors:")
        for error in status["errors"]:
            lines.append(f"- {error}")
        lines.append("")
    if status.get("warnings"):
        lines.append("Warnings:")
        for warning in status["warnings"]:
            lines.append(f"- {warning}")
        lines.append("")
    return "\n".join(lines)


def write_report(report_path: Path, status: dict[str, Any], report_status: str) -> None:
    report_path.write_text(render_report(status, report_status), encoding="utf-8")


def run_tick(
    root: Path,
    interval_override: int | None = None,
    profile_root: Path | None = None,
) -> dict[str, Any]:
    root = root.expanduser().resolve()
    harvis_dir = root / ".harvis"
    errors: list[str] = []
    warnings: list[str] = []
    profile_root = (profile_root or Path("~/.harvis")).expanduser().resolve()
    try:
        harvis_dir.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        warnings.append(f"workspace .harvis directory unavailable, using fallback state where possible: {exc}")

    config_path = harvis_dir / "harvis.toml"
    config, config_errors = load_toml(config_path)
    errors.extend(config_errors)
    if interval_override is not None:
        config["tick_interval_seconds"] = interval_override
    profile = profile_metadata(profile_root)

    reports_dir = resolve_workspace_path(root, str(config["default_reports"]))
    status_path = resolve_workspace_path(root, str(config["status_file"]))
    event_log_path = resolve_workspace_path(root, str(config["event_log"]))
    for directory in [reports_dir, status_path.parent, event_log_path.parent]:
        try:
            directory.mkdir(parents=True, exist_ok=True)
        except Exception as exc:
            warnings.append(f"workspace runtime directory unavailable: {rel(directory, root)}: {exc}")

    scanned_inboxes: list[Path] = []
    packets_written: list[Path] = []
    allowlist = config.get("allowlist") or [config["default_inbox"]]
    if not isinstance(allowlist, list):
        allowlist = [config["default_inbox"]]
        errors.append("allowlist is not a list, using default inbox")

    for raw_path in allowlist:
        inbox_path = resolve_workspace_path(root, str(raw_path))
        if not is_within_root(inbox_path, root):
            errors.append(f"allowlist path outside workspace root: {inbox_path}")
            continue
        if not inbox_path.exists():
            errors.append(f"allowlist inbox not found: {rel(inbox_path, root)}")
            continue
        try:
            written = scan_inboxes(root, [inbox_path], allow_outside_root=False)
            scanned_inboxes.append(inbox_path)
            packets_written.extend(written)
        except SystemExit as exc:
            errors.append(f"scanner failed for {rel(inbox_path, root)}: {exc}")
        except Exception as exc:
            errors.append(f"scanner failed for {rel(inbox_path, root)}: {exc}")

    moment = now_utc()
    packet_counts = Counter(packet_status(path) for path in packets_written)
    run_sync: dict[str, Any] = {"run_count": 0, "runs": []}
    if packets_written:
        try:
            run_sync = sync_packet_runs(root, packets_written)
        except Exception as exc:
            errors.append(f"run ledger sync failed: {exc}")
    status = {
        "agent": "H.A.R.V.I.S.",
        "runtime_version": RUNTIME_VERSION,
        "autonomy_level": int(config.get("autonomy_level", 1)),
        "mode": "read-only",
        "workspace_root": str(root),
        "last_tick_at": moment.isoformat(),
        "tick_interval_seconds": int(config.get("tick_interval_seconds", 1200)),
        "allowlist": [str(value) for value in allowlist],
        "scanned_inboxes": [rel(path, root) for path in scanned_inboxes],
        "packets_written": [rel(path, root) for path in packets_written],
        "runs_written": run_sync.get("runs", []),
        "packet_status_counts": dict(sorted(packet_counts.items())),
        "profile": profile,
        "errors": errors,
        "warnings": warnings,
        "state_store": "workspace",
    }

    status_content = json.dumps(status, indent=2, sort_keys=True) + "\n"
    actual_status_path, status_warning = write_text_with_fallback(
        status_path,
        runtime_fallback_path(root, "status.json", profile_root),
        status_content,
    )
    if status_warning:
        warnings.append(status_warning)
        status["warnings"] = warnings
        status["state_store"] = "profile-fallback" if actual_status_path else "unavailable"
        status_content = json.dumps(status, indent=2, sort_keys=True) + "\n"
        actual_status_path, status_warning = write_text_with_fallback(
            status_path,
            runtime_fallback_path(root, "status.json", profile_root),
            status_content,
        )
        if status_warning and "fallback write failed" in status_warning:
            errors.append(status_warning)
            status["errors"] = errors
            status["state_store"] = "unavailable"
    event = {
        "type": "harvis.runtime.tick",
        "at": moment.isoformat(),
        "status": "ok" if not errors else "warning",
        "packets": len(packets_written),
        "runs": int(run_sync.get("run_count", 0)),
        "errors": len(errors),
        "warnings": len(warnings),
    }
    _, event_warning = append_text_with_fallback(
        event_log_path,
        runtime_fallback_path(root, "events.jsonl", profile_root),
        json.dumps(event, sort_keys=True) + "\n",
    )
    if event_warning:
        warnings.append(event_warning)
        status["warnings"] = warnings

    report_path = reports_dir / f"tick-{timestamp_slug(moment)}.md"
    report_content = render_report(status, event["status"])
    actual_report_path, report_warning = write_text_with_fallback(
        report_path,
        runtime_fallback_path(root, Path("reports") / report_path.name, profile_root),
        report_content,
    )
    if report_warning:
        warnings.append(report_warning)
        status["warnings"] = warnings
    print(f"wrote status: {actual_status_path or status_path}")
    print(f"wrote report: {actual_report_path or report_path}")
    print(f"packets: {len(packets_written)}")
    if errors:
        print(f"errors: {len(errors)}")
    if warnings:
        print(f"warnings: {len(warnings)}")
    return status


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run H.A.R.V.I.S. v0.3-alpha read-only runtime ticks."
    )
    parser.add_argument("--root", default=".", help="Workspace root containing .harvis/.")
    parser.add_argument("--once", action="store_true", help="Run one tick and exit.")
    parser.add_argument("--loop", action="store_true", help="Run ticks until interrupted.")
    parser.add_argument("--interval", type=int, help="Override tick interval in seconds.")
    parser.add_argument("--max-ticks", type=int, help="Stop loop after this many ticks.")
    parser.add_argument(
        "--profile-root",
        default="~/.harvis",
        help="H.A.R.V.I.S. runtime profile root. Defaults to ~/.harvis.",
    )
    args = parser.parse_args()

    root = Path(args.root)
    profile_root = Path(args.profile_root)
    if not args.loop:
        run_tick(root, args.interval, profile_root)
        return 0

    ticks = 0
    try:
        while True:
            status = run_tick(root, args.interval, profile_root)
            ticks += 1
            if args.max_ticks is not None and ticks >= args.max_ticks:
                break
            time.sleep(int(status.get("tick_interval_seconds", args.interval or 1200)))
    except KeyboardInterrupt:
        print("H.A.R.V.I.S. runtime stopped.")
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("run-tick", legacy_main=main))
