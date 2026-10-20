#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$PLUGIN_ROOT/tests/golden"
export HARVIS_PYTHON_LEGACY_ENTRYPOINT=1
TMP="$(mktemp -d)"
TMP_RESOLVED="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$TMP")"
WORKSPACE="$TMP/workspace"

trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"

sanitize() {
  HARVIS_GOLDEN_TMP="$TMP" HARVIS_GOLDEN_TMP_RESOLVED="$TMP_RESOLVED" python3 -c '
import os
import sys

text = sys.stdin.read()
for value in {os.environ.get("HARVIS_GOLDEN_TMP", ""), os.environ.get("HARVIS_GOLDEN_TMP_RESOLVED", "")}:
    if value:
        text = text.replace(value, "<tmp>")
text = text.replace("/private<tmp>", "<tmp>")
sys.stdout.write(text)
'
}

python3 "$PLUGIN_ROOT/scripts/harvis_init_workspace.py" --root "$WORKSPACE" \
  | sanitize > "$OUT/init_workspace.stdout"

cat > "$WORKSPACE/.harvis/inbox.md" <<'EOF'
# H.A.R.V.I.S. Inbox

@harvis review this temporary fixture workspace.
Scope: current repository.
Need: list safe next actions only.
EOF

cat > "$WORKSPACE/Index.md" <<'EOF'
---
title: Fixture Index
tags: [harvis, rust]
aliases: [Home]
---

# Fixture Index

This note links to [[Second Note]] and [External Label](Second%20Note.md).

#harvis #rust
EOF

cat > "$WORKSPACE/Second Note.md" <<'EOF'
# Second Note

Backlink to [[Index]].

#fixture
EOF

python3 "$PLUGIN_ROOT/scripts/harvis_inbox_scan.py" --root "$WORKSPACE" \
  | sanitize > "$OUT/inbox_scan.stdout"
python3 "$PLUGIN_ROOT/scripts/harvis_runtime_tick.py" --root "$WORKSPACE" --once \
  | sanitize > "$OUT/runtime_tick.stdout"
python3 "$PLUGIN_ROOT/scripts/harvis_knowledge_graph.py" --root "$WORKSPACE" --max-files 50 --max-nodes 100 \
  | sanitize > "$OUT/knowledge_graph.json"
python3 "$PLUGIN_ROOT/scripts/harvis_bar_status.py" --root "$WORKSPACE" \
  | sanitize > "$OUT/bar_status.json"

python3 - "$OUT" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
for name in ["knowledge_graph.json", "bar_status.json"]:
    json.loads((out / name).read_text(encoding="utf-8"))

for path in out.iterdir():
    if not path.is_file():
        continue
    text = path.read_text(encoding="utf-8")
    for marker in ["/Users/", "/Volumes/", "HARVIS_HTTP_AUTH_TOKEN", ".env"]:
        if marker in text:
            raise SystemExit(f"unsafe marker {marker!r} found in {path.name}")
PY

echo "captured public-safe golden outputs in $OUT"
