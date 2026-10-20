#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HARVIS_PYTHON_LEGACY_ENTRYPOINT=1

python3 - "$PLUGIN_ROOT" <<'PY'
import pathlib
import subprocess
import sys
import tempfile

plugin = pathlib.Path(sys.argv[1])
inbox_text = """@harvis review this fixture.
Scope: current workspace.
Need: safe next action.

# done
"""

with tempfile.TemporaryDirectory(prefix="harvis-inbox-parity-") as tmp:
    py_root = pathlib.Path(tmp) / "py"
    rs_root = pathlib.Path(tmp) / "rs"
    subprocess.run(
        ["python3", str(plugin / "scripts/harvis_init_workspace.py"), "--root", str(py_root)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    subprocess.run(
        [str(plugin / "scripts/harvis"), "init-workspace", "--root", str(rs_root)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    for root in [py_root, rs_root]:
        (root / ".harvis/inbox.md").write_text(inbox_text, encoding="utf-8")

    py_out = subprocess.check_output(
        ["python3", str(plugin / "scripts/harvis_inbox_scan.py"), "--root", str(py_root)],
        text=True,
    )
    rs_out = subprocess.check_output(
        [str(plugin / "scripts/harvis"), "scan-inbox", "--root", str(rs_root)],
        text=True,
    )
    py_packets = sorted((py_root / ".harvis/outbox").glob("*.md"))
    rs_packets = sorted((rs_root / ".harvis/outbox").glob("*.md"))

    def normalize_packet(path):
        lines = path.read_text(encoding="utf-8").splitlines()
        return [line for line in lines if not line.startswith("Generated:")]

    checks = {
        "init_files": all(
            (rs_root / path).exists()
            for path in [".harvis/inbox.md", ".harvis/harvis.toml", ".harvis/knowledge_graph.toml"]
        ),
        "packet_count": len(py_packets) == len(rs_packets) == 1,
        "packet_name": py_packets[0].name == rs_packets[0].name,
        "packet_body_without_generated": normalize_packet(py_packets[0]) == normalize_packet(rs_packets[0]),
        "stdout_shape": py_out.startswith("wrote: ") and rs_out.startswith("wrote: "),
    }
    print({"ok": all(checks.values()), "checks": checks, "packet": py_packets[0].name})
    if not all(checks.values()):
        raise SystemExit(1)
PY
