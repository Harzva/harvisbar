#!/usr/bin/env python3
"""Validate the local H.A.R.V.I.S. plugin structure."""

from __future__ import annotations

import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from harvis_approval_item import create_approval, decide_approval, list_approvals  # noqa: E402
from harvis_agent_room import init_agent_room, list_agent_room, list_handoffs, request_handoff  # noqa: E402
from harvis_bar_status import build_bar_status  # noqa: E402
from harvis_hub_adapter import hub_path_lookup, hub_status, llmwiki_status, wiki_page, wiki_search  # noqa: E402
from harvis_knowledge_graph import scan_knowledge_graph  # noqa: E402
from harvis_memory_snapshot import generate_snapshot, list_memory_candidates  # noqa: E402
from harvis_notification_policy import check_notifications, list_notifications  # noqa: E402
from harvis_persona_registry import (  # noqa: E402
    create_twin_instance,
    create_personality_candidate,
    decide_personality_candidate,
    init_persona_registry,
    list_persona_state,
    update_persona_card,
)
from harvis_permission_probe import probe_workspace_permissions  # noqa: E402
from harvis_repoatlas_adapter import (  # noqa: E402
    repoatlas_find_repo,
    repoatlas_missing_local_copies,
    repoatlas_needs_attention,
    repoatlas_status,
)
from harvis_run_ledger import list_runs, sync_packet_runs  # noqa: E402
from harvis_service_manager import ensure_log_dir, render_launch_agent  # noqa: E402


REQUIRED_FILES = [
    ".codex-plugin/plugin.json",
    ".mcp.json",
    "skills/harvis/SKILL.md",
    "fixtures/bar-status.sample.json",
    "panel/index.html",
    "panel/styles.css",
    "panel/panel.js",
    "presence/index.html",
    "presence/styles.css",
    "presence/presence.js",
    "studio/index.html",
    "studio/styles.css",
    "studio/studio.js",
    "studio/assets/harvis-persona-system.png",
    "studio/assets/harvis-core-male.png",
    "studio/assets/harvis-core-female.png",
    "studio/assets/harvis-app-icon.png",
    "apps/HarvisBar/Package.swift",
    "apps/HarvisBar/Sources/HarvisBar/App/HarvisBarApp.swift",
    "apps/HarvisBar/Sources/HarvisBar/Runtime/HarvisRuntimeModel.swift",
    "apps/HarvisBar/Sources/HarvisBar/PermissionWindowWatcher.swift",
    "apps/HarvisBar/Resources/FULL_DISK_ACCESS.md",
    "schemas/agent-pools.schema.json",
    "schemas/agent-room.schema.json",
    "schemas/approval.schema.json",
    "schemas/bar-status.schema.json",
    "schemas/handoff.schema.json",
    "schemas/hub-source.schema.json",
    "schemas/memory-vault.schema.json",
    "schemas/persona-card.schema.json",
    "schemas/personality-candidate.schema.json",
    "schemas/run.schema.json",
    "schemas/task.schema.json",
    "schemas/task-progress.schema.json",
    "schemas/status.schema.json",
    "schemas/twin-instance.schema.json",
    "schemas/event.schema.json",
    "schemas/notification.schema.json",
    "schemas/result.schema.json",
    "mcp/harvis_mcp_server.py",
    "scripts/harvis_rust_shim.py",
    "scripts/harvis_agent_room.py",
    "scripts/harvis_agent_harnesses.py",
    "scripts/harvis_approval_item.py",
    "scripts/harvis_bar_status.py",
    "scripts/harvis_run_ledger.py",
    "scripts/harvis_state_store.py",
    "scripts/harvis_task_packet.py",
    "scripts/harvis_init_profile.py",
    "scripts/harvis_init_workspace.py",
    "scripts/harvis_inbox_scan.py",
    "scripts/harvis_knowledge_graph.py",
    "scripts/harvis_runtime_tick.py",
    "scripts/harvis_memory_snapshot.py",
    "scripts/harvis_notification_policy.py",
    "scripts/harvis_persona_registry.py",
    "scripts/harvis_permission_probe.py",
    "scripts/harvis_repoatlas_adapter.py",
    "scripts/harvis_workbench.py",
    "scripts/harvis_http_api.py",
    "scripts/harvis_bar_build.sh",
    "scripts/harvis_bar_run.sh",
    "scripts/harvis_bar_make_icon.sh",
    "scripts/harvis_generate_app_icon.py",
    "scripts/harvis_bar_package_app.sh",
    "scripts/harvis_app_bundle_contract.py",
    "scripts/harvis_app_bundle_runtime.sh",
    "scripts/harvis_app_bundle_verify.py",
    "scripts/harvis_package_path_guard.py",
    "scripts/harvis_bar_install_app.sh",
    "scripts/harvis_desktop_package_app.sh",
    "scripts/harvis_desktop_install_app.sh",
    "scripts/harvis_bar_package_dmg.sh",
    "scripts/harvis_bar_release_manifest.py",
    "scripts/harvis_bar_distribution_check.sh",
    "scripts/harvis_hub_adapter.py",
    "scripts/harvis_service_manager.py",
    "scripts/harvis_healthcheck.py",
    "scripts/harvis",
    "Cargo.toml",
    "Cargo.lock",
    "crates/harvis-core/Cargo.toml",
    "crates/harvis-core/src/lib.rs",
    "crates/harvis-runtime/Cargo.toml",
    "crates/harvis-runtime/src/lib.rs",
    "crates/harvis-runtime/src/init.rs",
    "crates/harvis-runtime/src/agent_room.rs",
    "crates/harvis-runtime/src/approvals.rs",
    "crates/harvis-runtime/src/inbox.rs",
    "crates/harvis-runtime/src/knowledge_graph.rs",
    "crates/harvis-runtime/src/memory.rs",
    "crates/harvis-runtime/src/notifications.rs",
    "crates/harvis-runtime/src/persona.rs",
    "crates/harvis-runtime/src/profile.rs",
    "crates/harvis-runtime/src/runs.rs",
    "crates/harvis-runtime/src/tick.rs",
    "crates/harvis-http/Cargo.toml",
    "crates/harvis-http/src/auth.rs",
    "crates/harvis-http/src/lib.rs",
    "crates/harvis-http/src/routes.rs",
    "crates/harvis-http/src/static_assets.rs",
    "crates/harvis-macos/Cargo.toml",
    "crates/harvis-macos/src/lib.rs",
    "crates/harvis-macos/src/service_manager.rs",
    "crates/harvis-mcp/Cargo.toml",
    "crates/harvis-mcp/src/lib.rs",
    "crates/harvis-cli/Cargo.toml",
    "crates/harvis-cli/src/healthcheck.rs",
    "crates/harvis-cli/src/main.rs",
    "tests/golden/README.md",
    "scripts/harvis_capture_golden.sh",
    "scripts/harvis_knowledge_graph_parity.sh",
    "scripts/harvis_init_inbox_parity.sh",
    "scripts/harvis_runtime_core_parity.sh",
    "scripts/harvis_profile_memory_parity.sh",
    "scripts/harvis_http_rust_parity.sh",
]

SCHEMA_FILES = [
    "schemas/approval.schema.json",
    "schemas/agent-pools.schema.json",
    "schemas/agent-room.schema.json",
    "schemas/bar-status.schema.json",
    "schemas/handoff.schema.json",
    "schemas/hub-source.schema.json",
    "schemas/memory-vault.schema.json",
    "schemas/persona-card.schema.json",
    "schemas/personality-candidate.schema.json",
    "schemas/run.schema.json",
    "schemas/task.schema.json",
    "schemas/task-progress.schema.json",
    "schemas/status.schema.json",
    "schemas/twin-instance.schema.json",
    "schemas/event.schema.json",
    "schemas/notification.schema.json",
    "schemas/result.schema.json",
]


def validate_json_files(plugin_root: Path) -> list[str]:
    errors: list[str] = []
    for relative_path in SCHEMA_FILES + ["fixtures/bar-status.sample.json", "fixtures/agent-pools.sample.json"]:
        path = plugin_root / relative_path
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append(f"invalid json: {relative_path}: {exc}")
    return errors


def validate_golden_outputs(plugin_root: Path) -> list[str]:
    errors: list[str] = []
    golden_dir = plugin_root / "tests" / "golden"
    required = [
        "README.md",
        "init_workspace.stdout",
        "inbox_scan.stdout",
        "runtime_tick.stdout",
        "knowledge_graph.json",
        "bar_status.json",
    ]
    forbidden_markers = [
        "/Users/",
        "/Volumes/",
        "HARVIS_HTTP_AUTH_TOKEN",
        ".env",
        "BEGIN PRIVATE KEY",
    ]
    for name in required:
        path = golden_dir / name
        if not path.exists():
            errors.append(f"golden output missing: tests/golden/{name}")
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"golden output unreadable: tests/golden/{name}: {exc}")
            continue
        for marker in forbidden_markers:
            if marker in text:
                errors.append(f"golden output contains forbidden marker {marker!r}: tests/golden/{name}")
    for name in ["knowledge_graph.json", "bar_status.json"]:
        path = golden_dir / name
        if not path.exists():
            continue
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append(f"golden output invalid json: tests/golden/{name}: {exc}")
            continue
        if not isinstance(loaded, dict):
            errors.append(f"golden output must be a json object: tests/golden/{name}")
    return errors


def validate_bar_status_redaction() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-healthcheck-") as tmp:
        root = Path(tmp)
        (root / ".harvis").mkdir()
        (root / ".harvis" / "status.json").write_text(
            json.dumps(
                {
                    "agent": "H.A.R.V.I.S.",
                    "runtime_version": "v0.3-alpha",
                    "autonomy_level": 1,
                    "mode": "read-only",
                    "workspace_root": str(root),
                    "last_tick_at": "2026-06-24T00:00:00+00:00",
                    "allowlist": [".harvis/inbox.md"],
                    "errors": [],
                }
            ),
            encoding="utf-8",
        )
        status = build_bar_status(root, served_by_http=True)
        safety = status.get("safety", {})
        harnesses = status.get("agentHarnesses", {})
        task_progress = status.get("taskProgress", {})
        if status.get("schemaVersion") != "harvis.bar-status.v0":
            errors.append("bar status schemaVersion mismatch")
        if status.get("safeForHarvisBar") is not True:
            errors.append("bar status must be marked safeForHarvisBar")
        if harnesses.get("schemaVersion") != "harvis.agent-harnesses.v0":
            errors.append("bar status must include agent harness status")
        if harnesses.get("includesModelCalls") is not False:
            errors.append("agent harness status must be status-only until Test cxspark is clicked")
        if task_progress.get("schemaVersion") != "harvis.task-progress.v0":
            errors.append("bar status must include task progress status")
        if task_progress.get("safety", {}).get("includesLocalAbsolutePaths") is not False:
            errors.append("task progress must not expose local absolute paths")
        harness_ids = {item.get("id") for item in harnesses.get("items", []) if isinstance(item, dict)}
        expected_harness_ids = {"codex", "dsh", "kimicode", "claude-code", "likecode", "cxspark"}
        if not expected_harness_ids.issubset(harness_ids):
            errors.append("agent harness status should include core harness pool plus cxspark preset")
        for key in [
            "includesSecrets",
            "includesRawMemory",
            "includesCredentialPaths",
            "includesLocalAbsolutePaths",
        ]:
            if safety.get(key) is not False:
                errors.append(f"bar status safety.{key} must be false")
        rendered = json.dumps(status, sort_keys=True)
        if str(root) in rendered:
            errors.append("bar status leaked an absolute workspace path")
    return errors


def validate_bar_status_fallback_state() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-fallback-healthcheck-") as tmp:
        root = Path(tmp) / "workspace"
        profile = Path(tmp) / "profile"
        root.mkdir()
        fallback = profile / "state" / "workspaces"
        fallback.mkdir(parents=True)
        from harvis_state_store import runtime_fallback_path

        status_path = runtime_fallback_path(root, "status.json", profile)
        status_path.parent.mkdir(parents=True, exist_ok=True)
        status_path.write_text(
            json.dumps(
                {
                    "agent": "H.A.R.V.I.S.",
                    "runtime_version": "v0.3-alpha",
                    "autonomy_level": 1,
                    "mode": "read-only",
                    "last_tick_at": "2026-06-24T00:00:00+00:00",
                    "allowlist": [".harvis/inbox.md"],
                    "errors": [],
                    "warnings": ["workspace write failed, used profile fallback"],
                    "state_store": "profile-fallback",
                }
            ),
            encoding="utf-8",
        )
        status = build_bar_status(root, served_by_http=True, profile_root=profile)
        workspace = status.get("workspace", {})
        work = status.get("work", {})
        if workspace.get("stateStore") != "profile-fallback":
            errors.append("bar status must read profile fallback runtime state")
        if work.get("lastTickAt") != "2026-06-24T00:00:00+00:00":
            errors.append("bar status did not surface fallback lastTickAt")
        rendered = json.dumps(status, sort_keys=True)
        for marker in ["/Users/", "/Volumes/", str(root), str(profile)]:
            if marker and marker in rendered:
                errors.append("bar fallback status leaked a local absolute path")
    return errors


def validate_launch_agent_dry_run(plugin_root: Path) -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-launchd-healthcheck-") as tmp:
        home = Path(tmp) / "home"
        workspace = Path(tmp) / "workspace"
        token_file = home / ".harvis" / "auth" / "http.token"
        home.mkdir(parents=True)
        workspace.mkdir()
        log_dir = ensure_log_dir(home)
        probe = log_dir / "write-probe.tmp"
        probe.write_text("ok\n", encoding="utf-8")
        probe.unlink()
        plist_text = render_launch_agent(
            "http",
            plugin=plugin_root,
            home=home,
            port=8765,
            root=workspace,
            auth_token_file=token_file,
        )
        try:
            plist = plistlib.loads(plist_text.encode("utf-8"))
        except Exception as exc:
            return [f"LaunchAgent plist is invalid: {exc}"]

        if plist.get("Label") != "local.harzva.harvis.http":
            errors.append("LaunchAgent label mismatch")
        if plist.get("RunAtLoad") is not True:
            errors.append("LaunchAgent RunAtLoad must be true")
        if plist.get("KeepAlive") is not True:
            errors.append("LaunchAgent KeepAlive must be true")
        args = plist.get("ProgramArguments", [])
        rendered_args = " ".join(str(arg) for arg in args)
        if "harvis_http_api.py" in rendered_args or "/usr/bin/python3" in rendered_args:
            errors.append("LaunchAgent must not run the Python HTTP API")
        if "harvis" not in rendered_args or " http " not in f" {rendered_args} ":
            errors.append("LaunchAgent must run the Rust harvis http service")
        if "127.0.0.1" not in args:
            errors.append("LaunchAgent must bind HTTP service to 127.0.0.1")
        if "--auth-token-file" not in args:
            errors.append("LaunchAgent must pass auth token file to Rust HTTP service")
        env = plist.get("EnvironmentVariables", {})
        if "HARVIS_HTTP_AUTH_TOKEN" in env:
            errors.append("LaunchAgent must not embed plaintext auth tokens")
        if env.get("HARVIS_HTTP_AUTH_TOKEN_FILE") != str(token_file.resolve()):
            errors.append("LaunchAgent must reference the auth token file when configured")
    return errors


def validate_rust_mcp_server(plugin_root: Path) -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-rust-mcp-healthcheck-") as tmp:
        root = Path(tmp) / "workspace"
        root.mkdir()
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "harvis_init_workspace", "arguments": {"root": str(root)}},
            },
        ]
        try:
            proc = subprocess.run(
                [str(plugin_root / "scripts" / "harvis"), "mcp"],
                input="\n".join(json.dumps(message) for message in messages) + "\n",
                text=True,
                cwd=plugin_root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=30,
                check=False,
            )
        except Exception as exc:
            return [f"Rust MCP smoke failed to start: {exc}"]
        if proc.returncode != 0:
            errors.append(f"Rust MCP smoke exited {proc.returncode}: {proc.stderr.strip()[:240]}")
            return errors
        try:
            responses = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
        except json.JSONDecodeError as exc:
            return [f"Rust MCP smoke returned invalid JSON: {exc}"]
        if len(responses) != 3:
            errors.append(f"Rust MCP smoke expected 3 responses, got {len(responses)}")
            return errors
        if responses[0].get("result", {}).get("serverInfo", {}).get("name") != "harvis":
            errors.append("Rust MCP initialize did not report harvis server")
        tools = responses[1].get("result", {}).get("tools", [])
        tool_names = {tool.get("name") for tool in tools if isinstance(tool, dict)}
        for name in ["harvis_init_workspace", "harvis_persona_init", "harvis_repoatlas_find_repo"]:
            if name not in tool_names:
                errors.append(f"Rust MCP tools/list missing {name}")
        try:
            payload = json.loads(responses[2]["result"]["content"][0]["text"])
        except Exception as exc:
            errors.append(f"Rust MCP tool call payload is invalid: {exc}")
        else:
            if payload.get("ok") is not True or payload.get("tool") != "harvis_init_workspace":
                errors.append("Rust MCP harvis_init_workspace tool call failed")
    return errors


def validate_run_ledger() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-run-healthcheck-") as tmp:
        root = Path(tmp)
        outbox = root / ".harvis" / "outbox"
        outbox.mkdir(parents=True)
        packet = outbox / "abc123.md"
        packet.write_text(
            "\n".join(
                [
                    "# H.A.R.V.I.S. Work Packet abc123",
                    "",
                    "Status: new",
                    "Source: .harvis/inbox.md:1",
                    "Generated: 2026-06-24T00:00:00+00:00",
                    "Safety: no sensitive marker detected",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        synced = sync_packet_runs(root, [packet])
        if synced.get("run_count") != 1:
            errors.append("run ledger sync should create one run")
        listed = list_runs(root)
        if listed.get("run_count") != 1:
            errors.append("run ledger list should return one run")
        run_json = root / ".harvis" / "runs" / "run_abc123.json"
        if not run_json.exists():
            errors.append("run ledger json file missing")
        else:
            rendered = run_json.read_text(encoding="utf-8")
            if str(root) in rendered:
                errors.append("run ledger leaked an absolute workspace path")
    return errors


def validate_approval_items() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-approval-healthcheck-") as tmp:
        root = Path(tmp)
        outbox = root / ".harvis" / "outbox"
        outbox.mkdir(parents=True)
        packet = outbox / "abc123.md"
        packet.write_text(
            "\n".join(
                [
                    "# H.A.R.V.I.S. Work Packet abc123",
                    "",
                    "Status: new",
                    "Source: .harvis/inbox.md:1",
                    "Generated: 2026-06-24T00:00:00+00:00",
                    "Safety: no sensitive marker detected",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        sync_packet_runs(root, [packet])
        approval = create_approval(
            root,
            run_id="run_abc123",
            action_type="write_file",
            target=str(root / "src" / "example.py"),
            reason="healthcheck approval record",
        )
        if approval.get("status") != "pending":
            errors.append("approval item should start pending")
        listed = list_approvals(root, status="pending")
        if listed.get("approval_count") != 1:
            errors.append("pending approval list should include one item")
        rendered = json.dumps(approval, sort_keys=True)
        if str(root) in rendered:
            errors.append("approval item leaked an absolute workspace path")
        decided = decide_approval(root, approval["approval_id"], "approved", notes="healthcheck")
        if decided.get("status") != "approved":
            errors.append("approval decision should update status")
        run_json = root / ".harvis" / "runs" / "run_abc123.json"
        run = json.loads(run_json.read_text(encoding="utf-8"))
        approval_state = run.get("approval", {})
        if approval_state.get("pending") is not False:
            errors.append("run approval pending state should clear after decision")
    return errors


def healthcheck_packet(root: Path) -> Path:
    outbox = root / ".harvis" / "outbox"
    outbox.mkdir(parents=True, exist_ok=True)
    packet = outbox / "abc123.md"
    packet.write_text(
        "\n".join(
            [
                "# H.A.R.V.I.S. Work Packet abc123",
                "",
                "Status: new",
                "Source: .harvis/inbox.md:1",
                "Generated: 2026-06-24T00:00:00+00:00",
                "Safety: no sensitive marker detected",
                "",
                "## Request",
                "```text",
                "Review the workspace and prepare a safe next action.",
                "```",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return packet


def validate_agent_room_handoff() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-agent-room-healthcheck-") as tmp:
        root = Path(tmp)
        packet = healthcheck_packet(root)
        sync_packet_runs(root, [packet])
        room = init_agent_room(root)
        if "agent-room" not in json.dumps(room):
            errors.append("agent room init should return agent-room paths")
        handoff = request_handoff(root, "run_abc123", "codex", "healthcheck handoff")
        if handoff.get("handoff", {}).get("state") != "pending_harness":
            errors.append("handoff should start pending_harness")
        listed_room = list_agent_room(root)
        if not listed_room.get("events"):
            errors.append("agent room should record handoff/topic events")
        listed_handoffs = list_handoffs(root)
        if listed_handoffs.get("handoff_count") != 1:
            errors.append("handoff list should include one handoff")
        run = json.loads((root / ".harvis" / "runs" / "run_abc123.json").read_text(encoding="utf-8"))
        if run.get("state") != "handoff_requested":
            errors.append("handoff should update run state")
        rendered = json.dumps({"handoff": handoff, "room": listed_room, "handoffs": listed_handoffs}, sort_keys=True)
        if str(root) in rendered:
            errors.append("agent room/handoff leaked an absolute workspace path")
    return errors


def validate_persona_registry() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-persona-healthcheck-") as tmp:
        root = Path(tmp)
        state = init_persona_registry(root)
        if not state.get("memory_vaults"):
            errors.append("persona init should create at least one memory vault")
        if len(state.get("persona_cards", [])) < 2:
            errors.append("persona init should create core persona cards")
        if not state.get("twin_instances"):
            errors.append("persona init should create a default twin instance")
        candidate = create_personality_candidate(
            root,
            trait="prefers evidence-first review before accepting personality changes",
            target_persona_id="persona_core_male_assistant",
            confidence=0.7,
        )
        if candidate.get("status") != "pending_review":
            errors.append("personality candidate should start pending_review")
        decided = decide_personality_candidate(root, candidate["candidate_id"], "accepted")
        if decided.get("candidate", {}).get("status") != "accepted":
            errors.append("candidate decision should update status")
        updated = update_persona_card(
            root,
            "persona_core_male_assistant",
            display_name="Core Male Assistant",
            tone={"warmth": 8, "directness": 7, "humor": 4, "detail": 8, "encouragement": 6, "criticism": 3},
            decision_style={"evidence_first": True, "prefer_verification": True, "risk_tolerance": "medium"},
            behavior_rules=["Inspect context before acting.", "Surface uncertainty before persona changes."],
        )
        if updated.get("tone", {}).get("warmth") != 8:
            errors.append("persona update should persist tone changes")
        if updated.get("new_traits_require_human_review") is not True:
            errors.append("persona update must keep human review required")
        twin = create_twin_instance(
            root,
            "Healthcheck Builder Twin",
            "vault_default_me",
            "persona_core_male_assistant",
            permissions={
                "read_memory": True,
                "write_candidate_memory": True,
                "write_accepted_memory": False,
                "run_tools": "read_only",
            },
        )
        if twin.get("permissions", {}).get("run_tools") != "read_only":
            errors.append("copy-me builder permissions should persist on twin creation")
        listed = list_persona_state(root)
        rendered = json.dumps(listed, sort_keys=True)
        if str(root) in rendered:
            errors.append("persona registry leaked an absolute workspace path")
    return errors


def validate_permission_probe() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-permission-healthcheck-") as tmp:
        root = Path(tmp) / "workspace"
        profile = Path(tmp) / "profile"
        root.mkdir()
        result = probe_workspace_permissions(root, profile, context="healthcheck")
        if result.get("permission_probe_version") != "v0.21-alpha":
            errors.append("permission probe version mismatch")
        if result.get("ok") is not True:
            errors.append("permission probe should pass for temporary workspace")
        checks = result.get("checks")
        if not isinstance(checks, list) or len(checks) < 5:
            errors.append("permission probe should report multiple checks")
        rendered = json.dumps(result, sort_keys=True)
        for marker in [str(root), str(profile), "/Users/", "/Volumes/"]:
            if marker and marker in rendered:
                errors.append("permission probe leaked a local absolute path")
        for path in root.rglob(".harvis-permission-probe.tmp"):
            errors.append(f"permission probe left temporary file: {path.name}")
    return errors


def validate_notification_policy() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-notification-healthcheck-") as tmp:
        root = Path(tmp)
        harvis_dir = root / ".harvis"
        harvis_dir.mkdir(parents=True)
        (harvis_dir / "status.json").write_text(
            json.dumps(
                {
                    "agent": "H.A.R.V.I.S.",
                    "runtime_version": "v0.3-alpha",
                    "autonomy_level": 1,
                    "mode": "read-only",
                    "workspace_root": str(root),
                    "last_tick_at": "2026-06-24T00:00:00+00:00",
                    "packet_status_counts": {},
                    "errors": [],
                }
            ),
            encoding="utf-8",
        )
        result = check_notifications(root)
        if result.get("written_count") != 1:
            errors.append("notification policy should write one verified candidate")
        listed = list_notifications(root, kind="verified")
        if listed.get("notification_count") != 1:
            errors.append("verified notification should be listable")
        rendered = json.dumps(listed.get("notifications", []), sort_keys=True)
        if str(root) in rendered:
            errors.append("notification record leaked an absolute workspace path")
        try:
            list_notifications(root, kind="noise")
            errors.append("notification policy should reject disallowed kinds")
        except SystemExit:
            pass
    return errors


def validate_memory_snapshot_knowledge_sources() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-memory-healthcheck-") as tmp:
        root = Path(tmp) / "workspace"
        profile = Path(tmp) / "profile"
        (root / ".harvis" / "outbox").mkdir(parents=True)
        (root / ".harvis" / "reports").mkdir(parents=True)
        profile.mkdir(parents=True)
        (root / ".harvis" / "status.json").write_text(
            json.dumps(
                {
                    "agent": "H.A.R.V.I.S.",
                    "runtime_version": "v0.14-alpha",
                    "autonomy_level": 1,
                    "mode": "read-only",
                    "last_tick_at": "2026-06-24T00:00:00+00:00",
                    "errors": [],
                }
            ),
            encoding="utf-8",
        )
        result = generate_snapshot(
            root,
            profile,
            max_events=0,
            max_packets=5,
            max_reports=5,
            max_excerpt_chars=240,
        )
        snapshot = json.loads(Path(result["snapshot_path"]).read_text(encoding="utf-8"))
        listed_candidates = list_memory_candidates(root, limit=10)
        if listed_candidates.get("candidate_count", 0) < 1:
            errors.append("memory candidates should be listable after snapshot")
        rendered_candidates = json.dumps(listed_candidates, sort_keys=True)
        for marker in [str(root), str(profile), "/Users/", "/Volumes/"]:
            if marker and marker in rendered_candidates:
                errors.append("memory candidates leaked a local absolute path")
        knowledge = snapshot.get("knowledge_sources")
        if not isinstance(knowledge, dict):
            errors.append("memory snapshot missing knowledge_sources")
            return errors
        if knowledge.get("redacted") is not True:
            errors.append("memory knowledge_sources must be redacted")
        if knowledge.get("includesLocalAbsolutePaths") is not False:
            errors.append("memory knowledge_sources must mark includesLocalAbsolutePaths false")
        sources = knowledge.get("sources")
        if not isinstance(sources, list) or not sources:
            errors.append("memory knowledge_sources must include at least one source record")
        rendered = json.dumps(knowledge, sort_keys=True)
        for marker in ["/Users/", "/Volumes/"]:
            if marker in rendered:
                errors.append(f"memory knowledge_sources leaked local absolute path marker: {marker}")
    return errors


def validate_no_local_paths(label: str, payload: object) -> list[str]:
    rendered = json.dumps(payload, sort_keys=True)
    errors: list[str] = []
    for marker in ["/Users/", "/Volumes/"]:
        if marker in rendered:
            errors.append(f"{label} leaked local absolute path marker: {marker}")
    if isinstance(payload, dict):
        if payload.get("redacted") is not True and payload.get("hub") != "unavailable":
            errors.append(f"{label} must be marked redacted")
        if payload.get("includesLocalAbsolutePaths") is not False and "includesLocalAbsolutePaths" in payload:
            errors.append(f"{label} includesLocalAbsolutePaths must be false")
    return errors


def validate_hub_adapter_redaction() -> list[str]:
    errors: list[str] = []
    samples: list[tuple[str, object]] = [
        ("hub_status", hub_status()),
        ("hub_path_lookup", hub_path_lookup("llmwiki", limit=5)),
        ("wiki_search", wiki_search("llmwiki", limit=3)),
        ("llmwiki_status", llmwiki_status()),
    ]
    search = samples[2][1]
    if isinstance(search, dict):
        items = search.get("items")
        if isinstance(items, list) and items:
            page_id = items[0].get("page_id") if isinstance(items[0], dict) else None
            if isinstance(page_id, str) and page_id.strip():
                try:
                    samples.append(("wiki_page", wiki_page(page_id, max_chars=1200)))
                except SystemExit:
                    pass
    for label, payload in samples:
        errors.extend(validate_no_local_paths(label, payload))
    return errors


def validate_knowledge_graph_scanner() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-graph-healthcheck-") as tmp:
        root = Path(tmp)
        harvis_dir = root / ".harvis"
        notes = root / "vault"
        harvis_dir.mkdir()
        notes.mkdir()
        (harvis_dir / "knowledge_graph.toml").write_text(
            "\n".join(
                [
                    "[graph]",
                    'vaults = ["vault"]',
                    'ignore_dirs = [".obsidian", ".git", "private"]',
                    "max_files = 20",
                    "max_nodes = 50",
                    "include_paths = false",
                ]
            ),
            encoding="utf-8",
        )
        (notes / "Index.md").write_text(
            "\n".join(
                [
                    "---",
                    "title: Project Index",
                    "tags: [moc]",
                    "---",
                    "",
                    "This links to [[Task Board]] and #strategy.",
                    "Also see [Task Board](Task%20Board.md).",
                ]
            ),
            encoding="utf-8",
        )
        (notes / "Task Board.md").write_text(
            "Back to [[Index]] with #execution.\n",
            encoding="utf-8",
        )
        graph = scan_knowledge_graph(root)
        if graph.get("graph_version") != "v0.32-alpha":
            errors.append("knowledge graph version mismatch")
        if graph.get("read_only") is not True:
            errors.append("knowledge graph must be marked read_only")
        if graph.get("redacted") is not True:
            errors.append("knowledge graph default output must be redacted")
        if graph.get("includesLocalAbsolutePaths") is not False:
            errors.append("knowledge graph must not include local absolute paths by default")
        stats = graph.get("stats", {})
        if stats.get("note_count") != 2:
            errors.append("knowledge graph should include two note nodes")
        if stats.get("edge_count", 0) < 3:
            errors.append("knowledge graph should include wiki/markdown/tag edges")
        rendered = json.dumps(graph, sort_keys=True)
        for marker in [str(root), "/Users/", "/Volumes/"]:
            if marker and marker in rendered:
                errors.append("knowledge graph leaked a local absolute path")
    return errors


def write_repoatlas_fixture(path: Path, local_root: Path) -> None:
    path.write_text(
        json.dumps(
            {
                "generatedAt": "2026-06-24T00:00:00+00:00",
                "summary": {
                    "remoteCount": 2,
                    "localRepoCount": 1,
                    "matchedRemoteCount": 1,
                    "missingLocalCount": 1,
                    "attentionCount": 1,
                },
                "repositories": [
                    {
                        "repoKey": "harzva/mobilecode",
                        "nameWithOwner": "Harzva/mobilecode",
                        "url": "https://github.com/Harzva/mobilecode",
                        "accountAlias": "Harzva",
                        "accountLogin": "Harzva",
                        "localExists": True,
                        "localPaths": [str(local_root / "MobileCode")],
                        "localStatus": "dirty",
                        "dirty": True,
                        "ahead": 0,
                        "behind": 0,
                    },
                    {
                        "repoKey": "harzva/missing",
                        "nameWithOwner": "Harzva/missing",
                        "url": "https://github.com/Harzva/missing",
                        "accountAlias": "Harzva",
                        "accountLogin": "Harzva",
                        "localExists": False,
                        "localPaths": [],
                        "localStatus": "no-local-copy",
                        "dirty": False,
                        "ahead": 0,
                        "behind": 0,
                    },
                ],
            },
            indent=2,
        ),
        encoding="utf-8",
    )


def validate_repoatlas_adapter_redaction() -> list[str]:
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="harvis-repoatlas-healthcheck-") as tmp:
        root = Path(tmp)
        map_path = root / "repoatlas-local-address-map.json"
        local_root = root / "local" / "repos"
        local_root.mkdir(parents=True)
        write_repoatlas_fixture(map_path, local_root)
        samples: list[tuple[str, object]] = [
            ("repoatlas_status", repoatlas_status(str(map_path))),
            ("repoatlas_find_repo", repoatlas_find_repo("Harzva/mobilecode", map_path=str(map_path))),
            ("repoatlas_missing", repoatlas_missing_local_copies(map_path=str(map_path))),
            ("repoatlas_attention", repoatlas_needs_attention(map_path=str(map_path))),
        ]
        for label, payload in samples:
            errors.extend(validate_no_local_paths(label, payload))
        find_payload = samples[1][1]
        if isinstance(find_payload, dict) and find_payload.get("count") != 1:
            errors.append("RepoAtlas find should return one fixture match")
        path_payload = repoatlas_find_repo("Harzva/mobilecode", map_path=str(map_path), include_paths=True)
        if path_payload.get("includesLocalAbsolutePaths") is not True:
            errors.append("RepoAtlas include_paths result should mark local absolute paths")
        rendered = json.dumps(path_payload, sort_keys=True)
        if str(local_root) not in rendered:
            errors.append("RepoAtlas include_paths result should include local paths when explicitly requested")
    return errors


def validate_harvisbar_sources(plugin_root: Path) -> list[str]:
    errors: list[str] = []
    package = plugin_root / "apps" / "HarvisBar" / "Package.swift"
    source_root = plugin_root / "apps" / "HarvisBar" / "Sources" / "HarvisBar"
    build_script = plugin_root / "scripts" / "harvis_bar_build.sh"
    run_script = plugin_root / "scripts" / "harvis_bar_run.sh"
    icon_script = plugin_root / "scripts" / "harvis_bar_make_icon.sh"
    generate_icon_script = plugin_root / "scripts" / "harvis_generate_app_icon.py"
    package_script = plugin_root / "scripts" / "harvis_bar_package_app.sh"
    bundle_runtime_script = plugin_root / "scripts" / "harvis_app_bundle_runtime.sh"
    bundle_contract = plugin_root / "scripts" / "harvis_app_bundle_contract.py"
    bundle_verifier = plugin_root / "scripts" / "harvis_app_bundle_verify.py"
    package_path_guard = plugin_root / "scripts" / "harvis_package_path_guard.py"
    install_script = plugin_root / "scripts" / "harvis_bar_install_app.sh"
    dmg_script = plugin_root / "scripts" / "harvis_bar_package_dmg.sh"
    release_manifest = plugin_root / "scripts" / "harvis_bar_release_manifest.py"
    distribution_check = plugin_root / "scripts" / "harvis_bar_distribution_check.sh"
    fda_guide = plugin_root / "apps" / "HarvisBar" / "Resources" / "FULL_DISK_ACCESS.md"
    package_text = package.read_text(encoding="utf-8")
    swift_sources = sorted(source_root.rglob("*.swift"))
    if not swift_sources:
        return ["HarvisBar modular Swift source tree is empty"]
    source_text = "\n".join(path.read_text(encoding="utf-8") for path in swift_sources)
    icon_script_text = icon_script.read_text(encoding="utf-8")
    package_script_text = package_script.read_text(encoding="utf-8")
    bundle_runtime_text = bundle_runtime_script.read_text(encoding="utf-8")
    bundle_contract_text = bundle_contract.read_text(encoding="utf-8")
    bundle_verifier_text = bundle_verifier.read_text(encoding="utf-8")
    package_path_guard_text = package_path_guard.read_text(encoding="utf-8")
    package_contract_text = (
        package_script_text + "\n" + bundle_runtime_text + "\n" + bundle_contract_text
    )
    install_script_text = install_script.read_text(encoding="utf-8")
    dmg_script_text = dmg_script.read_text(encoding="utf-8")
    release_manifest_text = release_manifest.read_text(encoding="utf-8")
    distribution_text = distribution_check.read_text(encoding="utf-8")
    fda_text = fda_guide.read_text(encoding="utf-8")
    if ".executable(name: \"HarvisBar\"" not in package_text:
        errors.append("HarvisBar Package.swift must expose the HarvisBar executable")
    for marker in [
        "MenuBarExtra",
        "/bar/status",
        "/panel/",
        "service-manager",
        "scripts/harvis",
        "harvis-plugin-root.txt",
        "openFullDiskAccessSettings",
        "startServices",
        "stopServices",
        "restartServices",
        "Proxy Routes",
        "/agent-harnesses/test",
        "testHarnesses",
    ]:
        if marker not in source_text:
            errors.append(f"HarvisBar source missing marker: {marker}")
    generate_icon_text = generate_icon_script.read_text(encoding="utf-8")
    for marker in ["sips", "iconutil", "HarvisBar.icns", "icon_512x512@2x.png", "harvis-app-icon.png"]:
        if marker not in icon_script_text:
            errors.append(f"HarvisBar icon script missing marker: {marker}")
    for marker in ["wave_y", "harvis-app-icon.png", "rounded_rectangle", "draw_arc_layer"]:
        if marker not in generate_icon_text:
            errors.append(f"HarvisBar app icon generator missing marker: {marker}")
    for marker in [
        "HarvisBar.app",
        "Info.plist",
        "CFBundleExecutable",
        "CFBundleIconFile",
        "LSUIElement",
        "HarvisBar.icns",
        "harvis-app-icon.png",
        "FULL_DISK_ACCESS.md",
        "harvis-plugin-root.txt",
        "codesign",
        "--install-dir",
    ]:
        if marker not in package_contract_text:
            errors.append(f"HarvisBar package script missing marker: {marker}")
    for marker in [
        "HarvisPlugin",
        "SystemExtensions",
        "HarvisBar.entitlements",
        "HarvisPerAppProxyExtension.entitlements",
        "EXTENSION_NAME.systemextension",
        "bin/harvis",
        "harvis-bundle-receipt.json",
        "--provenance-stage",
        "--provenance-sha256",
    ]:
        if marker not in package_contract_text:
            errors.append(f"HarvisBar reproducible bundle contract missing marker: {marker}")
    for marker in [
        "harvis-runtime",
        "harvisbar-main",
        "harvis-system-extension",
        "app-runtime-allowlist-v1.txt",
        "stagedPayloadSha256",
        "payload_digest",
    ]:
        if marker not in bundle_contract_text:
            errors.append(f"Harvis app bundle verifier contract missing marker: {marker}")
    for marker in ["codesign-policy", "load_provenance_contract", "verify_bundle"]:
        if marker not in bundle_verifier_text:
            errors.append(f"Harvis app bundle verifier missing marker: {marker}")
    for marker in ["app-output", "dmg-output", "formal runtime/install root", "symlink"]:
        if marker not in package_path_guard_text:
            errors.append(f"Harvis package path guard missing marker: {marker}")
    if "harvis_bar_package_app.sh" not in install_script_text:
        errors.append("HarvisBar install script must call the package script")
    for marker in [
        "hdiutil create",
        "codesign",
        "notarytool submit",
        "stapler staple",
        "--notarize",
        "README-FIRST.txt",
        "harvis_bar_release_manifest.py",
    ]:
        if marker not in dmg_script_text:
            errors.append(f"HarvisBar DMG script missing marker: {marker}")
    for marker in ["sha256", "safeForPublicMetadata", "includesSecrets", "notarized"]:
        if marker not in release_manifest_text:
            errors.append(f"HarvisBar release manifest script missing marker: {marker}")
    for marker in ["Developer ID Application", "notarytool", "HARVIS_BAR_NOTARY_PROFILE"]:
        if marker not in distribution_text:
            errors.append(f"HarvisBar distribution check missing marker: {marker}")
    for marker in [
        "Full Disk Access",
        "LaunchAgent",
        "full permission probe",
        "~/.harvis/bin/harvis",
        "continuityClaim=false",
        "Privacy_AllFiles",
    ]:
        if marker not in fda_text:
            errors.append(f"HarvisBar FDA guide missing marker: {marker}")
    for forbidden in [
        "npm run macos:install",
        "Applications/HarvisRuntime.app/Contents/MacOS/harvis",
    ]:
        if forbidden in fda_text:
            errors.append(f"HarvisBar FDA guide contains retired authority: {forbidden}")
    for script in [
        build_script,
        run_script,
        icon_script,
        generate_icon_script,
        package_script,
        bundle_runtime_script,
        install_script,
        dmg_script,
        release_manifest,
        distribution_check,
    ]:
        if not script.exists():
            errors.append(f"HarvisBar script missing: {script.name}")
        elif not script.stat().st_mode & 0o111:
            errors.append(f"HarvisBar script must be executable: {script.name}")
    return errors


def validate_studio_assets(plugin_root: Path) -> list[str]:
    errors: list[str] = []
    index = (plugin_root / "studio" / "index.html").read_text(encoding="utf-8")
    script = (plugin_root / "studio" / "studio.js").read_text(encoding="utf-8")
    style = (plugin_root / "studio" / "styles.css").read_text(encoding="utf-8")
    for asset_name in ["harvis-persona-system.png", "harvis-core-male.png", "harvis-core-female.png"]:
        asset = plugin_root / "studio" / "assets" / asset_name
        if not asset.exists() or asset.stat().st_size < 1024:
            errors.append(f"Persona Studio visual asset missing or too small: {asset_name}")
    for marker in [
        "Dashboard",
        "Active Twin",
        "Pending Queue",
        "Persona Editor",
        "Live Test Room",
        "Copy Me",
        "Copy Me Builder",
        "Persona Template",
        "Appearance",
        "Behavior",
        "Permissions",
        "Create Twin",
        "Review Center",
        "Memory Vault",
        "Approvals",
        "Agent Room",
        "Handoffs",
        "Knowledge Graph",
        "Local Graph",
        "Galaxy",
    ]:
        if marker not in index:
            errors.append(f"Persona Studio index missing marker: {marker}")
    for endpoint in [
        "/health",
        "/bar/status",
        "/permission-probe",
        "/persona/init",
        "/agent-room/init",
        "/persona/update-card",
        "/persona/create-twin",
        "/personality-candidate",
        "/personality-candidate/decide",
        "/decide-approval",
        "/memory-candidates",
        "/memory-snapshot",
        "/knowledge-graph",
        "/agent-room/topic",
    ]:
        if endpoint not in script:
            errors.append(f"Persona Studio script missing endpoint: {endpoint}")
    for selector in [
        ".dashboard-grid",
        ".persona-layout",
        ".builder-layout",
        ".review-layout",
        ".graph-layout",
        ".graph-stage",
        ".galaxy-mode",
        ".status-pill",
        ".mini-tag",
    ]:
        if selector not in style:
            errors.append(f"Persona Studio CSS missing selector: {selector}")
    if "grid-template-columns" not in style:
        errors.append("Persona Studio CSS should define stable grid layout")
    return errors


def validate_panel_assets(plugin_root: Path) -> list[str]:
    errors: list[str] = []
    index = (plugin_root / "panel" / "index.html").read_text(encoding="utf-8")
    script = (plugin_root / "panel" / "panel.js").read_text(encoding="utf-8")
    style = (plugin_root / "panel" / "styles.css").read_text(encoding="utf-8")
    for marker in ["presence-stage", "cyberme-avatar", "presenceCaption", "/studio/assets/harvis-core-male.png"]:
        if marker not in index and marker not in script:
            errors.append(f"Animated panel missing marker: {marker}")
    for state in ["idle", "reading", "thinking", "acting", "verified", "blocked"]:
        if f'data-chip="{state}"' not in index:
            errors.append(f"Animated panel missing state chip: {state}")
        if f'data-state="{state}"' not in style and f"[data-state=\"{state}\"]" not in style:
            errors.append(f"Animated panel CSS missing state selector: {state}")
        if state not in script:
            errors.append(f"Animated panel script missing state mapping: {state}")
    for animation in ["scan", "act", "verifiedPop", "blockedShake", "siriFlow", "voiceWake"]:
        if f"@keyframes {animation}" not in style:
            errors.append(f"Animated panel missing animation: {animation}")
    return errors


def validate_presence_assets(plugin_root: Path) -> list[str]:
    errors: list[str] = []
    index = (plugin_root / "presence" / "index.html").read_text(encoding="utf-8")
    script = (plugin_root / "presence" / "presence.js").read_text(encoding="utf-8")
    style = (plugin_root / "presence" / "styles.css").read_text(encoding="utf-8")
    for marker in ["H.A.R.V.I.S. Presence", "cyberme-avatar", "presenceRootInput", "/studio/assets/harvis-core-male.png"]:
        if marker not in index:
            errors.append(f"Presence surface missing marker: {marker}")
    for endpoint in ["/health", "/status"]:
        if endpoint not in script:
            errors.append(f"Presence script missing endpoint: {endpoint}")
    for state in ["idle", "reading", "thinking", "acting", "verified", "blocked"]:
        if f'data-chip="{state}"' not in index:
            errors.append(f"Presence surface missing state chip: {state}")
        if f'data-state="{state}"' not in style and f"[data-state=\"{state}\"]" not in style:
            errors.append(f"Presence CSS missing state selector: {state}")
        if state not in script:
            errors.append(f"Presence script missing state mapping: {state}")
    for animation in ["scan", "act", "verifiedPop", "blockedShake", "siriFlow", "voiceWake"]:
        if f"@keyframes {animation}" not in style:
            errors.append(f"Presence surface missing animation: {animation}")
    return errors


def main() -> int:
    plugin_root = Path(__file__).resolve().parents[1]
    missing = [path for path in REQUIRED_FILES if not (plugin_root / path).exists()]
    if missing:
        for path in missing:
            print(f"missing: {path}")
        return 1

    manifest_path = plugin_root / ".codex-plugin" / "plugin.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_name = "harvis"
    if manifest.get("name") != expected_name:
        print(f"manifest name must be {expected_name!r}")
        return 1

    interface = manifest.get("interface", {})
    if interface.get("displayName") != "H.A.R.V.I.S.":
        print("interface.displayName must be 'H.A.R.V.I.S.'")
        return 1

    mcp_config = json.loads((plugin_root / ".mcp.json").read_text(encoding="utf-8"))
    harvis_mcp = mcp_config.get("mcpServers", {}).get("harvis", {})
    if harvis_mcp.get("command") in {"python", "python3", "/usr/bin/python3"}:
        print(".mcp.json must not point the default H.A.R.V.I.S. MCP server at Python")
        return 1
    if harvis_mcp.get("command") != "./scripts/harvis" or harvis_mcp.get("args") != ["mcp"]:
        print(".mcp.json must launch the Rust H.A.R.V.I.S. MCP server via ./scripts/harvis mcp")
        return 1

    errors = (
        validate_json_files(plugin_root)
        + validate_golden_outputs(plugin_root)
        + validate_bar_status_redaction()
        + validate_bar_status_fallback_state()
        + validate_launch_agent_dry_run(plugin_root)
        + validate_rust_mcp_server(plugin_root)
        + validate_run_ledger()
        + validate_approval_items()
        + validate_agent_room_handoff()
        + validate_persona_registry()
        + validate_permission_probe()
        + validate_notification_policy()
        + validate_memory_snapshot_knowledge_sources()
        + validate_hub_adapter_redaction()
        + validate_knowledge_graph_scanner()
        + validate_repoatlas_adapter_redaction()
        + validate_harvisbar_sources(plugin_root)
        + validate_panel_assets(plugin_root)
        + validate_presence_assets(plugin_root)
        + validate_studio_assets(plugin_root)
    )
    if errors:
        for error in errors:
            print(error)
        return 1

    print("H.A.R.V.I.S. plugin healthcheck passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
