#!/usr/bin/env python3
"""Behavioral tests for the isolated Harvis candidate/rollback smoke gate."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SMOKE_SCRIPT = REPO_ROOT / "scripts" / "harvis_local_smoke.sh"


STUB_TEMPLATE = r'''#!/usr/bin/env python3
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import sys

MARKER = __MARKER__
MODE = __MODE__
MUTATION_PATH = __MUTATION_PATH__
EXPECTED_FIXTURE_SHA = __EXPECTED_FIXTURE_SHA__


def option(name):
    index = sys.argv.index(name)
    return sys.argv[index + 1]


def require_rollback_preseed():
    preseed = Path(os.environ["HARVIS_STATE_ROOT"]) / "agent-pools.json"
    if not preseed.is_file() or preseed.is_symlink():
        raise SystemExit(17)
    if hashlib.sha256(preseed.read_bytes()).hexdigest() != EXPECTED_FIXTURE_SHA:
        raise SystemExit(18)


command = sys.argv[1]
if command == "init-workspace":
    if MODE == "rollback_preseed_required":
        require_rollback_preseed()
        if "--force" in sys.argv:
            raise SystemExit(19)
    (Path(option("--root")) / ".harvis").mkdir(parents=True, exist_ok=True)
elif command == "init-profile":
    Path(option("--profile-root")).mkdir(parents=True, exist_ok=True)
elif command == "run-tick":
    if MODE == "fail_tick":
        raise SystemExit(9)
    if MODE == "mutate_guard":
        Path(MUTATION_PATH).write_text("changed by test stub\n", encoding="utf-8")
    if MODE == "rollback_preseed_required":
        require_rollback_preseed()
    if MODE != "stale_tick":
        state_root = Path(os.environ["HARVIS_STATE_ROOT"]).resolve()
        workspace = Path(option("--root")).resolve()
        state_root.mkdir(parents=True, exist_ok=True)
        (state_root / "status.json").write_text(
            json.dumps(
                {
                    "state_root": str(state_root),
                    "workspace_root": str(workspace),
                    "state_store": "workspace",
                    "errors": [],
                    "marker": MARKER,
                }
            ),
            encoding="utf-8",
        )
elif command == "http":
    host = option("--host")
    port = int(option("--port"))
    workspace = str(Path(option("--root")).resolve())
    state_root = Path(os.environ["HARVIS_STATE_ROOT"]).resolve()
    status = json.loads((state_root / "status.json").read_text(encoding="utf-8"))
    token = Path(option("--auth-token-file")).read_text(encoding="utf-8").strip()
    endpoint = f"http://{host}:{port}/a2a/jsonrpc"

    if MODE == "daemon_http":
        child_pid = os.fork()
        if child_pid > 0:
            while True:
                signal.pause()

    class Handler(http.server.BaseHTTPRequestHandler):
        def send_json(self, payload, status_code=200):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/health":
                self.send_json(
                    {"ok": True, "data": {"runtime": "rust", "auth_required": True}}
                )
            elif path == "/ui/bootstrap":
                self.send_json(
                    {
                        "ok": True,
                        "data": {
                            "workspace_root": workspace,
                            "auth_required": True,
                            "token_included": False,
                            "network_scope": "loopback",
                        },
                    }
                )
            elif path == "/status":
                if self.headers.get("Authorization") != f"Bearer {token}":
                    self.send_json({"ok": False}, 401)
                else:
                    self.send_json(
                        {"ok": True, "data": {"workspace_root": workspace, "status": status}}
                    )
            elif path == "/.well-known/agent-card.json":
                self.send_json(
                    {
                        "url": endpoint,
                        "supportedInterfaces": [
                            {"url": endpoint, "protocolBinding": "JSONRPC"}
                        ],
                    }
                )
            else:
                self.send_json({"ok": False}, 404)

        def log_message(self, _format, *_args):
            return

    server = http.server.ThreadingHTTPServer((host, port), Handler)
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(0))
    server.serve_forever()
else:
    raise SystemExit(f"unsupported test command: {command}")
'''


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


class LocalSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture_root = Path(
            tempfile.mkdtemp(prefix=".local-smoke-test-", dir=REPO_ROOT)
        )
        self.guard_path = self.fixture_root / "formal-runtime.bin"
        self.guard_path.write_bytes(b"formal-runtime-baseline\n")
        self.rollback_plugin_root = self.fixture_root / "rollback-plugin"
        (self.rollback_plugin_root / ".codex-plugin").mkdir(parents=True)
        (self.rollback_plugin_root / "fixtures").mkdir(parents=True)
        shutil.copy2(
            REPO_ROOT / ".codex-plugin/plugin.json",
            self.rollback_plugin_root / ".codex-plugin/plugin.json",
        )
        rollback_fixture = self.rollback_plugin_root / "fixtures/agent-pools.sample.json"
        rollback_fixture.write_bytes(
            (REPO_ROOT / "fixtures/agent-pools.sample.json").read_bytes() + b" \n"
        )
        self.rollback_fixture = rollback_fixture

    def tearDown(self) -> None:
        shutil.rmtree(self.fixture_root, ignore_errors=True)

    def make_stub(self, name: str, mode: str = "normal") -> Path:
        path = self.fixture_root / name
        source = (
            STUB_TEMPLATE.replace("__MARKER__", repr(name))
            .replace("__MODE__", repr(mode))
            .replace("__MUTATION_PATH__", repr(str(self.guard_path)))
            .replace("__EXPECTED_FIXTURE_SHA__", repr(sha256(self.rollback_fixture)))
        )
        path.write_text(textwrap.dedent(source), encoding="utf-8")
        path.chmod(0o700)
        return path

    def run_smoke(
        self,
        candidate: Path,
        rollback: Path,
        *,
        candidate_sha: str | None = None,
        rollback_sha: str | None = None,
        rollback_fixture_sha: str | None = None,
        port: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            "bash",
            str(SMOKE_SCRIPT),
            "--candidate",
            str(candidate),
            "--candidate-sha256",
            candidate_sha or sha256(candidate),
            "--rollback",
            str(rollback),
            "--rollback-sha256",
            rollback_sha or sha256(rollback),
            "--rollback-plugin-root",
            str(self.rollback_plugin_root),
            "--rollback-fixture-sha256",
            rollback_fixture_sha or sha256(self.rollback_fixture),
            "--port",
            str(port or free_loopback_port()),
            "--guard-path",
            str(self.guard_path),
        ]
        return subprocess.run(
            command,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=45,
            check=False,
        )

    def test_success_exercises_both_slots_and_finishes_on_rollback(self) -> None:
        candidate = self.make_stub("candidate")
        rollback = self.make_stub("rollback", "rollback_preseed_required")
        guard_before = self.guard_path.read_bytes()

        result = self.run_smoke(candidate, rollback)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["final_slot"], "rollback")
        self.assertEqual(payload["candidate_sha256"], sha256(candidate))
        self.assertEqual(payload["rollback_sha256"], sha256(rollback))
        self.assertEqual(
            payload["rollback_fixture_sha256"], sha256(self.rollback_fixture)
        )
        self.assertEqual(self.guard_path.read_bytes(), guard_before)

    def test_rejects_bad_expected_hash_before_execution(self) -> None:
        candidate = self.make_stub("candidate")
        rollback = self.make_stub("rollback")
        guard_before = self.guard_path.read_bytes()

        result = self.run_smoke(candidate, rollback, candidate_sha="0" * 64)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("candidate source SHA-256", result.stderr)
        self.assertEqual(self.guard_path.read_bytes(), guard_before)

    def test_rejects_bad_rollback_fixture_hash_before_execution(self) -> None:
        candidate = self.make_stub("candidate")
        rollback = self.make_stub("rollback")
        guard_before = self.guard_path.read_bytes()

        result = self.run_smoke(
            candidate, rollback, rollback_fixture_sha="0" * 64
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollback fixture SHA-256", result.stderr)
        self.assertEqual(self.guard_path.read_bytes(), guard_before)

    def test_candidate_failure_fails_closed_and_preserves_guard(self) -> None:
        candidate = self.make_stub("candidate", "fail_tick")
        rollback = self.make_stub("rollback")
        guard_before = self.guard_path.read_bytes()

        result = self.run_smoke(candidate, rollback)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("candidate bounded tick failed", result.stderr)
        self.assertEqual(self.guard_path.read_bytes(), guard_before)

    def test_rollback_cannot_reuse_candidate_status(self) -> None:
        candidate = self.make_stub("candidate")
        rollback = self.make_stub("rollback", "stale_tick")
        guard_before = self.guard_path.read_bytes()

        result = self.run_smoke(candidate, rollback)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rollback tick did not write isolated status", result.stderr)
        self.assertEqual(self.guard_path.read_bytes(), guard_before)

    def test_guard_mutation_is_detected(self) -> None:
        candidate = self.make_stub("candidate", "mutate_guard")
        rollback = self.make_stub("rollback")

        result = self.run_smoke(candidate, rollback)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("formal guard path changed", result.stderr)

    def test_daemonized_listener_is_rejected_and_process_group_is_cleaned(self) -> None:
        candidate = self.make_stub("candidate", "daemon_http")
        rollback = self.make_stub("rollback")
        port = free_loopback_port()

        result = self.run_smoke(candidate, rollback, port=port)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP process did not become ready", result.stderr)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(1)
            self.assertNotEqual(probe.connect_ex(("127.0.0.1", port)), 0)


if __name__ == "__main__":
    unittest.main()
