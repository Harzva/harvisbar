#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HARVIS_PYTHON_LEGACY_ENTRYPOINT=1
HARVIS_RS=(cargo run --quiet --manifest-path "$PLUGIN_ROOT/Cargo.toml" -p harvis-cli --)

python3 - "$PLUGIN_ROOT" "${HARVIS_RS[@]}" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

plugin = pathlib.Path(sys.argv[1])
rust_cmd = sys.argv[2:]
inbox_text = """@harvis review this fixture.
Scope: current workspace.
Need: safe next action.

@harvis use this token: abc123
Scope: current workspace.
Need: should be blocked.
"""


def run_json(command):
    return json.loads(subprocess.check_output(command, text=True))


def init_python(root):
    subprocess.run(
        ["python3", str(plugin / "scripts/harvis_init_workspace.py"), "--root", str(root)],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def init_rust(root):
    subprocess.run(
        rust_cmd + ["init-workspace", "--root", str(root)],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def normalize_sync(payload):
    return {
        "run_count": payload["run_count"],
        "runs": sorted(
            [
                {
                    "run_id": run["run_id"],
                    "state": run["state"],
                    "packet_id": run["packet_id"],
                    "json_path": run["json_path"],
                    "markdown_path": run["markdown_path"],
                }
                for run in payload["runs"]
            ],
            key=lambda run: run["run_id"],
        ),
    }


def normalize_list(payload):
    return {
        "run_count": payload["run_count"],
        "runs": sorted(
            [
                {
                    "run_id": run["run_id"],
                    "state": run["state"],
                    "mode": run["mode"],
                    "packet_id": run["packet_id"],
                    "path": run["path"],
                }
                for run in payload["runs"]
            ],
            key=lambda run: run["run_id"],
        ),
    }


def normalize_status(status):
    return {
        "agent": status["agent"],
        "runtime_version": status["runtime_version"],
        "autonomy_level": status["autonomy_level"],
        "mode": status["mode"],
        "tick_interval_seconds": status["tick_interval_seconds"],
        "allowlist": status["allowlist"],
        "scanned_inboxes": status["scanned_inboxes"],
        "packets_written": sorted(status["packets_written"]),
        "runs_written": sorted(
            [
                {
                    "run_id": run["run_id"],
                    "state": run["state"],
                    "packet_id": run["packet_id"],
                    "json_path": run["json_path"],
                    "markdown_path": run["markdown_path"],
                }
                for run in status["runs_written"]
            ],
            key=lambda run: run["run_id"],
        ),
        "packet_status_counts": status["packet_status_counts"],
        "errors": status["errors"],
        "warnings": status["warnings"],
        "state_store": status["state_store"],
        "profile_missing_count": len(status["profile"]["missing"]),
    }


with tempfile.TemporaryDirectory(prefix="harvis-runtime-core-parity-") as tmp:
    tmp = pathlib.Path(tmp)

    py_root = tmp / "py-runs"
    rs_root = tmp / "rs-runs"
    init_python(py_root)
    init_rust(rs_root)
    for root in [py_root, rs_root]:
        (root / ".harvis/inbox.md").write_text(inbox_text, encoding="utf-8")

    subprocess.run(
        ["python3", str(plugin / "scripts/harvis_inbox_scan.py"), "--root", str(py_root)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    subprocess.run(
        rust_cmd + ["scan-inbox", "--root", str(rs_root)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    py_sync = run_json(["python3", str(plugin / "scripts/harvis_run_ledger.py"), "--root", str(py_root), "sync"])
    rs_sync = run_json(rust_cmd + ["sync-runs", "--root", str(rs_root)])
    py_list = run_json(["python3", str(plugin / "scripts/harvis_run_ledger.py"), "--root", str(py_root), "list"])
    rs_list = run_json(rust_cmd + ["runs", "--root", str(rs_root)])

    py_tick_root = tmp / "py-tick"
    rs_tick_root = tmp / "rs-tick"
    init_python(py_tick_root)
    init_rust(rs_tick_root)
    for root in [py_tick_root, rs_tick_root]:
        (root / ".harvis/inbox.md").write_text(inbox_text, encoding="utf-8")

    py_tick_stdout = subprocess.check_output(
        [
            "python3",
            str(plugin / "scripts/harvis_runtime_tick.py"),
            "--root",
            str(py_tick_root),
            "--profile-root",
            str(tmp / "py-profile"),
            "--once",
        ],
        text=True,
    )
    rs_tick_stdout = subprocess.check_output(
        rust_cmd
        + [
            "run-tick",
            "--root",
            str(rs_tick_root),
            "--profile-root",
            str(tmp / "rs-profile"),
            "--once",
        ],
        text=True,
    )
    py_status = json.loads((py_tick_root / ".harvis/status.json").read_text(encoding="utf-8"))
    rs_status = json.loads((rs_tick_root / ".harvis/status.json").read_text(encoding="utf-8"))
    py_event = json.loads((py_tick_root / ".harvis/events.jsonl").read_text(encoding="utf-8").splitlines()[-1])
    rs_event = json.loads((rs_tick_root / ".harvis/events.jsonl").read_text(encoding="utf-8").splitlines()[-1])

    checks = {
        "sync": normalize_sync(py_sync) == normalize_sync(rs_sync),
        "list": normalize_list(py_list) == normalize_list(rs_list),
        "status": normalize_status(py_status) == normalize_status(rs_status),
        "tick_stdout_shape": all(marker in py_tick_stdout and marker in rs_tick_stdout for marker in ["wrote status:", "wrote report:", "packets: 2"]),
        "event_shape": {
            key: py_event[key] for key in ["type", "status", "packets", "runs", "errors"]
        }
        == {key: rs_event[key] for key in ["type", "status", "packets", "runs", "errors"]},
        "reports_exist": len(list((py_tick_root / ".harvis/reports").glob("tick-*.md"))) == 1
        and len(list((rs_tick_root / ".harvis/reports").glob("tick-*.md"))) == 1,
    }
    result = {"ok": all(checks.values()), "checks": checks}
    print(json.dumps(result, indent=2, sort_keys=True))
    if not result["ok"]:
        raise SystemExit(1)
PY
