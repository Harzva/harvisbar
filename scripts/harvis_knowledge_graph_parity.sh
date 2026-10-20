#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HARVIS_PYTHON_LEGACY_ENTRYPOINT=1

python3 - "$PLUGIN_ROOT" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

plugin = pathlib.Path(sys.argv[1])

with tempfile.TemporaryDirectory(prefix="harvis-graph-parity-") as tmp:
    root = pathlib.Path(tmp) / "workspace"
    subprocess.run(
        ["python3", str(plugin / "scripts/harvis_init_workspace.py"), "--root", str(root)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    (root / "Index.md").write_text(
        """---
title: Fixture Index
tags: [harvis, rust]
aliases: [Home]
---

# Fixture Index

[[Second Note]] and [Second](Second%20Note.md)

#harvis #rust #2563EB
""",
        encoding="utf-8",
    )
    (root / "Second Note.md").write_text(
        "# Second Note\n\n[[Index]]\n#fixture\n",
        encoding="utf-8",
    )

    python_graph = json.loads(
        subprocess.check_output(
            [
                "python3",
                str(plugin / "scripts/harvis_knowledge_graph.py"),
                "--root",
                str(root),
                "--max-files",
                "50",
                "--max-nodes",
                "100",
            ],
            text=True,
        )
    )
    rust_graph = json.loads(
        subprocess.check_output(
            [
                str(plugin / "scripts/harvis"),
                "knowledge-graph",
                "--root",
                str(root),
                "--max-files",
                "50",
                "--max-nodes",
                "100",
            ],
            text=True,
        )
    )

    def edge_set(graph):
        return {(edge["source"], edge["target"], edge["type"], edge["label"]) for edge in graph["edges"]}

    def node_set(graph):
        return {(node["id"], node["type"], node["title"]) for node in graph["nodes"]}

    checks = {
        "graph_version": python_graph["graph_version"] == rust_graph["graph_version"],
        "read_only": python_graph["read_only"] == rust_graph["read_only"] is True,
        "redacted": python_graph["redacted"] == rust_graph["redacted"] is True,
        "includesLocalAbsolutePaths": python_graph["includesLocalAbsolutePaths"]
        == rust_graph["includesLocalAbsolutePaths"]
        is False,
        "workspace_root": python_graph["workspace_root"] == rust_graph["workspace_root"] is None,
        "node_set": node_set(python_graph) == node_set(rust_graph),
        "edge_set": edge_set(python_graph) == edge_set(rust_graph),
        "note_count": python_graph["stats"]["note_count"] == rust_graph["stats"]["note_count"],
        "tag_count": python_graph["stats"]["tag_count"] == rust_graph["stats"]["tag_count"],
        "missing_count": python_graph["stats"]["missing_count"] == rust_graph["stats"]["missing_count"],
    }
    result = {
        "ok": all(checks.values()),
        "checks": checks,
        "python_counts": python_graph["stats"],
        "rust_counts": rust_graph["stats"],
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    if not result["ok"]:
        raise SystemExit(1)
PY
