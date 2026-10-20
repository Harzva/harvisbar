#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export HARVIS_PYTHON_LEGACY_ENTRYPOINT=1
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harvis-profile-memory-parity.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PY_ROOT="$TMP_ROOT/python-workspace"
RS_ROOT="$TMP_ROOT/rust-workspace"
PY_PROFILE="$TMP_ROOT/python-profile"
RS_PROFILE="$TMP_ROOT/rust-profile"
PY_PROFILE_OUT="$TMP_ROOT/python-profile.stdout"
RS_PROFILE_OUT="$TMP_ROOT/rust-profile.stdout"
PY_MEMORY_OUT="$TMP_ROOT/python-memory.stdout"
RS_MEMORY_OUT="$TMP_ROOT/rust-memory.stdout"
RS_CANDIDATES_JSON="$TMP_ROOT/rust-candidates.json"

HARVIS_RS=(cargo run --quiet --manifest-path "$PLUGIN_ROOT/Cargo.toml" -p harvis-cli --)

python3 "$PLUGIN_ROOT/scripts/harvis_init_profile.py" \
  --profile-root "$PY_PROFILE" >"$PY_PROFILE_OUT"
"${HARVIS_RS[@]}" init-profile \
  --profile-root "$RS_PROFILE" >"$RS_PROFILE_OUT"

python3 - "$PY_PROFILE" "$RS_PROFILE" "$PY_PROFILE_OUT" "$RS_PROFILE_OUT" <<'PY'
import sys
from pathlib import Path

py_profile = Path(sys.argv[1])
rs_profile = Path(sys.argv[2])
py_stdout = Path(sys.argv[3])
rs_stdout = Path(sys.argv[4])

expected = [
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

for relative in expected:
    py_path = py_profile / relative
    rs_path = rs_profile / relative
    if not py_path.exists():
        raise SystemExit(f"python profile missing {relative}")
    if not rs_path.exists():
        raise SystemExit(f"rust profile missing {relative}")
    if py_path.read_text(encoding="utf-8") != rs_path.read_text(encoding="utf-8"):
        raise SystemExit(f"profile content mismatch: {relative}")

def normalize(text: str, root: Path) -> list[str]:
    return [line.replace(str(root.resolve()), "<profile>") for line in text.splitlines()]

py_lines = normalize(py_stdout.read_text(encoding="utf-8"), py_profile)
rs_lines = normalize(rs_stdout.read_text(encoding="utf-8"), rs_profile)
if py_lines != rs_lines:
    raise SystemExit("profile stdout shape mismatch")
PY

python3 "$PLUGIN_ROOT/scripts/harvis_init_workspace.py" --root "$PY_ROOT" >/dev/null
"${HARVIS_RS[@]}" init-workspace --root "$RS_ROOT" >/dev/null

python3 - "$PY_ROOT" "$RS_ROOT" <<'PY'
import sys
from pathlib import Path

body = "\n".join(
    [
        "# H.A.R.V.I.S. Inbox",
        "",
        "@harvis Review this fixture and prepare a safe next action.",
        "@harvis token=abc123 should be blocked and redacted.",
        "",
    ]
)
for root in [Path(sys.argv[1]), Path(sys.argv[2])]:
    (root / ".harvis" / "inbox.md").write_text(body, encoding="utf-8")
PY

python3 "$PLUGIN_ROOT/scripts/harvis_runtime_tick.py" \
  --root "$PY_ROOT" \
  --profile-root "$PY_PROFILE" \
  --once >/dev/null
"${HARVIS_RS[@]}" run-tick \
  --root "$RS_ROOT" \
  --profile-root "$RS_PROFILE" \
  --once >/dev/null

python3 "$PLUGIN_ROOT/scripts/harvis_memory_snapshot.py" \
  --root "$PY_ROOT" \
  --profile-root "$PY_PROFILE" \
  --max-events 50 \
  --max-packets 50 \
  --max-reports 10 \
  --max-excerpt-chars 240 >"$PY_MEMORY_OUT"
"${HARVIS_RS[@]}" memory-snapshot \
  --root "$RS_ROOT" \
  --profile-root "$RS_PROFILE" \
  --max-events 50 \
  --max-packets 50 \
  --max-reports 10 \
  --max-excerpt-chars 240 >"$RS_MEMORY_OUT"
"${HARVIS_RS[@]}" memory-candidates \
  --root "$RS_ROOT" \
  --limit 50 >"$RS_CANDIDATES_JSON"

python3 - "$PY_ROOT" "$RS_ROOT" "$PY_MEMORY_OUT" "$RS_MEMORY_OUT" "$RS_CANDIDATES_JSON" <<'PY'
import json
import sys
from pathlib import Path

py_root = Path(sys.argv[1])
rs_root = Path(sys.argv[2])
py_stdout = Path(sys.argv[3])
rs_stdout = Path(sys.argv[4])
rs_candidates_path = Path(sys.argv[5])

def load_index(root: Path) -> dict:
    return json.loads((root / ".harvis" / "memory" / "index.json").read_text(encoding="utf-8"))

def load_snapshot(root: Path, index: dict) -> dict:
    return json.loads((root / index["latest_snapshot"]).read_text(encoding="utf-8"))

py_index = load_index(py_root)
rs_index = load_index(rs_root)
py_snapshot = load_snapshot(py_root, py_index)
rs_snapshot = load_snapshot(rs_root, rs_index)

for label, index, snapshot in [
    ("python", py_index, py_snapshot),
    ("rust", rs_index, rs_snapshot),
]:
    if snapshot.get("snapshot_version") != "v0.14-alpha":
        raise SystemExit(f"{label} snapshot version mismatch")
    if index.get("snapshot_version") != "v0.14-alpha":
        raise SystemExit(f"{label} index version mismatch")
    if snapshot.get("adoption", {}).get("status") != "not_adopted":
        raise SystemExit(f"{label} snapshot adoption status mismatch")
    if snapshot.get("adoption", {}).get("requires_human_review") is not True:
        raise SystemExit(f"{label} snapshot must require human review")
    if len(snapshot.get("packets", [])) != 2:
        raise SystemExit(f"{label} snapshot should include two packets")
    if len(snapshot.get("reports", [])) != 1:
        raise SystemExit(f"{label} snapshot should include one tick report")
    if snapshot.get("profile", {}).get("missing"):
        raise SystemExit(f"{label} profile should be complete")
    if len(snapshot.get("profile", {}).get("files", [])) != 10:
        raise SystemExit(f"{label} profile should list ten files")
    knowledge = snapshot.get("knowledge_sources", {})
    if knowledge.get("redacted") is not True:
        raise SystemExit(f"{label} knowledge sources must be redacted")
    if knowledge.get("includesLocalAbsolutePaths") is not False:
        raise SystemExit(f"{label} knowledge sources must not include local paths")
    if not isinstance(knowledge.get("sources"), list):
        raise SystemExit(f"{label} knowledge sources must contain a sources list")
    if index.get("candidate_signal_count", 0) < 1:
        raise SystemExit(f"{label} should produce memory candidates")

if py_index.get("packet_status_counts") != rs_index.get("packet_status_counts"):
    raise SystemExit("packet status counts mismatch")
if py_index.get("candidate_signal_count", 0) < 2 or rs_index.get("candidate_signal_count", 0) < 2:
    raise SystemExit("candidate signal count too low")

for text_path in [py_stdout, rs_stdout]:
    text = text_path.read_text(encoding="utf-8")
    for marker in ["wrote snapshot:", "wrote signals:", "wrote index:", "candidate signals:"]:
        if marker not in text:
            raise SystemExit(f"memory stdout missing {marker}")

rs_candidates = json.loads(rs_candidates_path.read_text(encoding="utf-8"))
if rs_candidates.get("memory_index", {}).get("exists") is not True:
    raise SystemExit("rust memory candidates should report an existing index")
if rs_candidates.get("candidate_count", 0) < 1:
    raise SystemExit("rust memory candidates should list candidates")
rendered_candidates = json.dumps(rs_candidates, sort_keys=True)
for marker in [str(rs_root), "/Users/", "/Volumes/"]:
    if marker and marker in rendered_candidates:
        raise SystemExit("rust memory candidates leaked a local absolute path")
PY

echo "profile/memory parity ok"
