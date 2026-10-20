#!/usr/bin/env python3
"""Local JSON HTTP API for H.A.R.V.I.S. runtime operations."""

from __future__ import annotations

import argparse
import contextlib
import hmac
import io
import json
import os
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
PANEL_DIR = PLUGIN_ROOT / "panel"
PRESENCE_DIR = PLUGIN_ROOT / "presence"
STUDIO_DIR = PLUGIN_ROOT / "studio"
SCHEMAS_DIR = PLUGIN_ROOT / "schemas"
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from harvis_inbox_scan import is_within_root, scan_inboxes  # noqa: E402
from harvis_agent_room import (  # noqa: E402
    add_event as agent_room_add_event,
    add_message as agent_room_add_message,
    create_topic,
    init_agent_room,
    list_agent_room,
    list_handoffs,
    request_handoff,
)
from harvis_approval_item import create_approval, decide_approval, list_approvals  # noqa: E402
from harvis_agent_harnesses import build_agent_harness_status  # noqa: E402
from harvis_bar_status import build_bar_status  # noqa: E402
from harvis_hub_adapter import hub_path_lookup, hub_status, llmwiki_status, wiki_page, wiki_search  # noqa: E402
from harvis_init_profile import init_profile  # noqa: E402
from harvis_init_workspace import init_workspace  # noqa: E402
from harvis_knowledge_graph import KnowledgeGraphError, scan_knowledge_graph  # noqa: E402
from harvis_memory_snapshot import generate_snapshot, list_memory_candidates, profile_metadata  # noqa: E402
from harvis_notification_policy import check_notifications, list_notifications  # noqa: E402
from harvis_persona_registry import (  # noqa: E402
    create_memory_vault,
    create_persona_card,
    create_personality_candidate,
    create_twin_instance,
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
from harvis_runtime_tick import run_tick  # noqa: E402
from harvis_run_ledger import list_runs, sync_packet_runs  # noqa: E402
from harvis_state_store import read_runtime_json_object  # noqa: E402
from harvis_workbench import prepare_workbench  # noqa: E402


API_VERSION = "v0.32-alpha"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
JSON = dict[str, Any]


class HttpApiError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        status: HTTPStatus = HTTPStatus.BAD_REQUEST,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


def response_payload(endpoint: str, data: Any, warnings: list[str] | None = None) -> JSON:
    return {
        "ok": True,
        "endpoint": endpoint,
        "data": data,
        "warnings": warnings or [],
    }


def error_payload(endpoint: str, error: HttpApiError) -> JSON:
    return {
        "ok": False,
        "endpoint": endpoint,
        "error": {
            "code": error.code,
            "message": error.message,
        },
    }


def require_str(data: JSON, name: str, default: str | None = None) -> str:
    value = data.get(name, default)
    if not isinstance(value, str) or not value.strip():
        raise HttpApiError("invalid_request", f"{name} must be a non-empty string")
    return value.strip()


def optional_bool(data: JSON, name: str, default: bool = False) -> bool:
    value = data.get(name, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "on"}:
            return True
        if lowered in {"0", "false", "no", "off"}:
            return False
    raise HttpApiError("invalid_request", f"{name} must be a boolean")


def optional_int(data: JSON, name: str, default: int, minimum: int, maximum: int) -> int:
    value = data.get(name, default)
    if isinstance(value, str) and value.strip():
        try:
            value = int(value)
        except ValueError as exc:
            raise HttpApiError("invalid_request", f"{name} must be an integer") from exc
    if not isinstance(value, int) or isinstance(value, bool):
        raise HttpApiError("invalid_request", f"{name} must be an integer")
    if value < minimum or value > maximum:
        raise HttpApiError("invalid_request", f"{name} must be between {minimum} and {maximum}")
    return value


def optional_str(data: JSON, name: str) -> str | None:
    value = data.get(name)
    if value is None:
        return None
    if not isinstance(value, str):
        raise HttpApiError("invalid_request", f"{name} must be a string")
    stripped = value.strip()
    return stripped or None


def resolve_root(value: str) -> Path:
    root = Path(value).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise HttpApiError("invalid_root", f"workspace root must be an existing directory: {root}")
    return root


def resolve_workspace_path(root: Path, value: str) -> Path:
    candidate = Path(value).expanduser()
    if not candidate.is_absolute():
        candidate = root / candidate
    candidate = candidate.resolve()
    if not is_within_root(candidate, root):
        raise HttpApiError("invalid_path", f"path is outside workspace root: {candidate}")
    return candidate


def parse_packet_status(path: Path) -> str:
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("Status:"):
                return line.split(":", 1)[1].strip() or "unknown"
    except OSError:
        return "unknown"
    return "unknown"


def list_packets(root: Path, limit: int, include_preview: bool, max_preview_chars: int) -> JSON:
    outbox = root / ".harvis" / "outbox"
    if not outbox.exists():
        raise HttpApiError("not_found", f"outbox not found: {outbox}", HTTPStatus.NOT_FOUND)
    packets: list[JSON] = []
    packet_paths = sorted(outbox.glob("*.md"), key=lambda item: item.stat().st_mtime, reverse=True)[:limit]
    for path in packet_paths:
        item: JSON = {
            "path": path.resolve().as_posix(),
            "workspace_path": path.resolve().relative_to(root).as_posix(),
            "status": parse_packet_status(path),
            "bytes": path.stat().st_size,
            "modified_at": int(path.stat().st_mtime),
        }
        if include_preview:
            item["preview"] = path.read_text(encoding="utf-8")[:max_preview_chars]
        packets.append(item)
    return {
        "workspace_root": str(root),
        "packets": packets,
    }


def read_events(root: Path, limit: int) -> JSON:
    event_log = root / ".harvis" / "events.jsonl"
    if not event_log.exists():
        raise HttpApiError("not_found", f"event log not found: {event_log}", HTTPStatus.NOT_FOUND)
    events: list[JSON] = []
    for line in event_log.read_text(encoding="utf-8").splitlines()[-limit:]:
        if not line.strip():
            continue
        try:
            loaded = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(loaded, dict):
            events.append(loaded)
    return {
        "workspace_root": str(root),
        "events": events,
    }


def query_dict(parsed_query: str) -> JSON:
    values: JSON = {}
    for key, raw_values in parse_qs(parsed_query, keep_blank_values=True).items():
        values[key] = raw_values[-1] if raw_values else ""
    return values


def configured_auth_token() -> str | None:
    direct = os.environ.get("HARVIS_HTTP_AUTH_TOKEN", "").strip()
    if direct:
        return direct
    token_file = os.environ.get("HARVIS_HTTP_AUTH_TOKEN_FILE", "").strip()
    if not token_file:
        return None
    try:
        value = Path(token_file).expanduser().read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value or None


class HarvisRequestHandler(BaseHTTPRequestHandler):
    server_version = "HarvisHTTP/0.32"

    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        super().end_headers()

    def log_message(self, format: str, *args: Any) -> None:
        print(f"[harvis-http] {self.address_string()} {format % args}", file=sys.stderr)

    def write_json(self, status: HTTPStatus, payload: JSON) -> None:
        body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def write_auth_error(self, endpoint: str) -> None:
        error = HttpApiError("unauthorized", "Authorization bearer token is required.", HTTPStatus.UNAUTHORIZED)
        body = json.dumps(error_payload(endpoint, error), indent=2, sort_keys=True).encode("utf-8")
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("WWW-Authenticate", 'Bearer realm="harvis"')
        self.end_headers()
        self.wfile.write(body)

    def request_authorized(self, endpoint: str) -> bool:
        if (
            endpoint == "/health"
            or endpoint.startswith("/schemas/")
            or endpoint.startswith("/panel")
            or endpoint.startswith("/presence")
            or endpoint.startswith("/pet")
            or endpoint.startswith("/studio")
        ):
            return True
        token = configured_auth_token()
        if token is None:
            return True
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not header.startswith(prefix):
            return False
        supplied = header.removeprefix(prefix).strip()
        return hmac.compare_digest(supplied, token)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        endpoint = parsed.path
        if not self.request_authorized(endpoint):
            self.write_auth_error(endpoint)
            return
        if endpoint == "/panel" or endpoint.startswith("/panel/"):
            self.serve_panel(endpoint)
            return
        if endpoint == "/presence" or endpoint.startswith("/presence/"):
            self.serve_presence(endpoint)
            return
        if endpoint == "/pet" or endpoint.startswith("/pet/"):
            self.redirect_legacy_presence_alias(endpoint, parsed.query)
            return
        if endpoint == "/studio" or endpoint.startswith("/studio/"):
            self.serve_studio(endpoint)
            return
        if endpoint.startswith("/schemas/"):
            self.serve_schema(endpoint)
            return
        try:
            data = query_dict(parsed.query)
            result = self.handle_get(endpoint, data)
            self.write_json(HTTPStatus.OK, response_payload(endpoint, result))
        except HttpApiError as exc:
            self.write_json(exc.status, error_payload(endpoint, exc))
        except Exception as exc:
            error = HttpApiError("internal_error", str(exc), HTTPStatus.INTERNAL_SERVER_ERROR)
            self.write_json(error.status, error_payload(endpoint, error))

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        endpoint = parsed.path
        if not self.request_authorized(endpoint):
            self.write_auth_error(endpoint)
            return
        try:
            data = self.read_body()
            result, warnings = self.handle_post(endpoint, data)
            self.write_json(HTTPStatus.OK, response_payload(endpoint, result, warnings))
        except HttpApiError as exc:
            self.write_json(exc.status, error_payload(endpoint, exc))
        except SystemExit as exc:
            error = HttpApiError("operation_failed", str(exc), HTTPStatus.BAD_REQUEST)
            self.write_json(error.status, error_payload(endpoint, error))
        except Exception as exc:
            error = HttpApiError("internal_error", str(exc), HTTPStatus.INTERNAL_SERVER_ERROR)
            self.write_json(error.status, error_payload(endpoint, error))

    def read_body(self) -> JSON:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length == 0:
            return {}
        body = self.rfile.read(length)
        try:
            loaded = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise HttpApiError("invalid_json", f"request body must be JSON: {exc}") from exc
        if not isinstance(loaded, dict):
            raise HttpApiError("invalid_json", "request body must be a JSON object")
        return loaded

    def serve_panel(self, endpoint: str) -> None:
        if endpoint in {"/panel", "/panel/"}:
            path = PANEL_DIR / "index.html"
        elif endpoint == "/panel/styles.css":
            path = PANEL_DIR / "styles.css"
        elif endpoint == "/panel/panel.js":
            path = PANEL_DIR / "panel.js"
        else:
            error = HttpApiError("not_found", f"unknown panel asset: {endpoint}", HTTPStatus.NOT_FOUND)
            self.write_json(error.status, error_payload(endpoint, error))
            return

        if not path.exists():
            error = HttpApiError("not_found", f"panel asset not found: {path}", HTTPStatus.NOT_FOUND)
            self.write_json(error.status, error_payload(endpoint, error))
            return

        content_type = "text/html; charset=utf-8"
        if path.suffix == ".css":
            content_type = "text/css; charset=utf-8"
        elif path.suffix == ".js":
            content_type = "application/javascript; charset=utf-8"
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def redirect_legacy_presence_alias(self, endpoint: str, query: str) -> None:
        target = "/presence/"
        if endpoint == "/pet/styles.css":
            target = "/presence/styles.css"
        elif endpoint == "/pet/pet.js":
            target = "/presence/presence.js"
        elif endpoint not in {"/pet", "/pet/"}:
            target = endpoint.replace("/pet/", "/presence/", 1)
        if query:
            target = f"{target}?{query}"
        self.send_response(HTTPStatus.PERMANENT_REDIRECT)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def serve_presence(self, endpoint: str) -> None:
        if endpoint in {"/presence", "/presence/"}:
            path = PRESENCE_DIR / "index.html"
        elif endpoint == "/presence/styles.css":
            path = PRESENCE_DIR / "styles.css"
        elif endpoint == "/presence/presence.js":
            path = PRESENCE_DIR / "presence.js"
        else:
            error = HttpApiError("not_found", f"unknown presence asset: {endpoint}", HTTPStatus.NOT_FOUND)
            self.write_json(error.status, error_payload(endpoint, error))
            return

        if not path.exists():
            error = HttpApiError("not_found", f"presence asset not found: {path}", HTTPStatus.NOT_FOUND)
            self.write_json(error.status, error_payload(endpoint, error))
            return

        content_type = "text/html; charset=utf-8"
        if path.suffix == ".css":
            content_type = "text/css; charset=utf-8"
        elif path.suffix == ".js":
            content_type = "application/javascript; charset=utf-8"
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_studio(self, endpoint: str) -> None:
        if endpoint in {"/studio", "/studio/"}:
            path = STUDIO_DIR / "index.html"
        elif endpoint == "/studio/styles.css":
            path = STUDIO_DIR / "styles.css"
        elif endpoint == "/studio/studio.js":
            path = STUDIO_DIR / "studio.js"
        elif endpoint.startswith("/studio/assets/") and endpoint.endswith(".png"):
            asset_name = Path(endpoint).name
            allowed_assets = {
                "harvis-persona-system.png",
                "harvis-core-male.png",
                "harvis-core-female.png",
                "harvis-app-icon.png",
            }
            if asset_name not in allowed_assets:
                error = HttpApiError("not_found", f"unknown studio asset: {endpoint}", HTTPStatus.NOT_FOUND)
                self.write_json(error.status, error_payload(endpoint, error))
                return
            path = STUDIO_DIR / "assets" / asset_name
        else:
            error = HttpApiError("not_found", f"unknown studio asset: {endpoint}", HTTPStatus.NOT_FOUND)
            self.write_json(error.status, error_payload(endpoint, error))
            return

        if not path.exists():
            error = HttpApiError("not_found", f"studio asset not found: {path}", HTTPStatus.NOT_FOUND)
            self.write_json(error.status, error_payload(endpoint, error))
            return

        content_type = "text/html; charset=utf-8"
        if path.suffix == ".css":
            content_type = "text/css; charset=utf-8"
        elif path.suffix == ".js":
            content_type = "application/javascript; charset=utf-8"
        elif path.suffix == ".png":
            content_type = "image/png"
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_schema(self, endpoint: str) -> None:
        name = endpoint.removeprefix("/schemas/")
        allowed = {
            "approval.schema.json",
            "agent-pools.schema.json",
            "agent-room.schema.json",
            "bar-status.schema.json",
            "handoff.schema.json",
            "hub-source.schema.json",
            "memory-vault.schema.json",
            "run.schema.json",
            "persona-card.schema.json",
            "personality-candidate.schema.json",
            "task.schema.json",
            "task-progress.schema.json",
            "status.schema.json",
            "twin-instance.schema.json",
            "event.schema.json",
            "notification.schema.json",
            "result.schema.json",
        }
        if name not in allowed:
            error = HttpApiError("not_found", f"unknown schema: {endpoint}", HTTPStatus.NOT_FOUND)
            self.write_json(error.status, error_payload(endpoint, error))
            return
        path = SCHEMAS_DIR / name
        if not path.exists():
            error = HttpApiError("not_found", f"schema not found: {path}", HTTPStatus.NOT_FOUND)
            self.write_json(error.status, error_payload(endpoint, error))
            return
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/schema+json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_get(self, endpoint: str, data: JSON) -> JSON:
        if endpoint == "/health":
            return {
                "agent": "H.A.R.V.I.S.",
                "api_version": API_VERSION,
                "agent_harnesses": "available",
                "mode": "localhost-json",
                "autonomy_level": 1,
                "bar_status": "available",
                "auth_required": configured_auth_token() is not None,
                "persona_studio": "available",
                "permission_probe": "available",
                "repoatlas": "available",
                "knowledge_graph": "available",
            }
        if endpoint == "/bar/status":
            root = resolve_root(require_str(data, "root"))
            return build_bar_status(root, served_by_http=True)
        if endpoint == "/agent-harnesses/status":
            return build_agent_harness_status(run_tests=False)
        if endpoint == "/hub/status":
            return hub_status()
        if endpoint == "/hub/path":
            return hub_path_lookup(
                require_str(data, "query"),
                optional_int(data, "limit", 10, 1, 50),
            )
        if endpoint == "/hub/search":
            return wiki_search(
                require_str(data, "query"),
                optional_int(data, "limit", 10, 1, 50),
                optional_int(data, "max_excerpt_chars", 360, 80, 2000),
            )
        if endpoint == "/hub/wiki/page":
            return wiki_page(
                require_str(data, "page"),
                optional_int(data, "max_chars", 3000, 200, 8000),
            )
        if endpoint == "/hub/llmwiki/status":
            return llmwiki_status()
        if endpoint == "/repoatlas/status":
            return repoatlas_status(
                map_path=optional_str(data, "map_path"),
                include_paths=optional_bool(data, "include_paths", False),
            )
        if endpoint == "/repoatlas/find":
            return repoatlas_find_repo(
                require_str(data, "query"),
                optional_int(data, "limit", 10, 1, 50),
                map_path=optional_str(data, "map_path"),
                include_paths=optional_bool(data, "include_paths", False),
            )
        if endpoint == "/repoatlas/missing":
            return repoatlas_missing_local_copies(
                optional_int(data, "limit", 50, 1, 200),
                map_path=optional_str(data, "map_path"),
            )
        if endpoint == "/repoatlas/attention":
            return repoatlas_needs_attention(
                optional_int(data, "limit", 50, 1, 200),
                map_path=optional_str(data, "map_path"),
                include_paths=optional_bool(data, "include_paths", False),
            )
        if endpoint == "/knowledge-graph":
            root = resolve_root(require_str(data, "root"))
            include_paths = optional_bool(data, "include_paths", False) if "include_paths" in data else None
            max_files = optional_int(data, "max_files", 1000, 1, 20000) if "max_files" in data else None
            max_nodes = optional_int(data, "max_nodes", 1500, 1, 20000) if "max_nodes" in data else None
            try:
                return scan_knowledge_graph(
                    root,
                    config_path=optional_str(data, "config"),
                    vault_override=optional_str(data, "vault"),
                    include_paths_override=include_paths,
                    max_files_override=max_files,
                    max_nodes_override=max_nodes,
                )
            except KnowledgeGraphError as exc:
                raise HttpApiError("invalid_knowledge_graph_config", str(exc)) from exc
        if endpoint == "/status":
            root = resolve_root(require_str(data, "root"))
            status, status_path, state_store = read_runtime_json_object(root, "status.json")
            if not status_path or status is None:
                raise HttpApiError(
                    "not_found",
                    f"status file not found for workspace: {root}",
                    HTTPStatus.NOT_FOUND,
                )
            return {
                "workspace_root": str(root),
                "status_path": str(status_path),
                "state_store": state_store,
                "status": status,
            }
        if endpoint == "/permission-probe":
            root = resolve_root(require_str(data, "root"))
            profile_root = Path(require_str(data, "profile_root", "~/.harvis")).expanduser().resolve()
            return probe_workspace_permissions(root, profile_root, context="http-api")
        if endpoint == "/events":
            root = resolve_root(require_str(data, "root"))
            return read_events(root, optional_int(data, "limit", 50, 1, 1000))
        if endpoint == "/packets":
            root = resolve_root(require_str(data, "root"))
            return list_packets(
                root,
                optional_int(data, "limit", 50, 1, 500),
                optional_bool(data, "include_preview", False),
                optional_int(data, "max_preview_chars", 800, 0, 8000),
            )
        if endpoint == "/runs":
            root = resolve_root(require_str(data, "root"))
            return list_runs(root, optional_int(data, "limit", 50, 1, 500))
        if endpoint == "/agent-room":
            root = resolve_root(require_str(data, "root"))
            return list_agent_room(root, optional_int(data, "limit", 50, 1, 500))
        if endpoint == "/handoffs":
            root = resolve_root(require_str(data, "root"))
            return list_handoffs(root, optional_int(data, "limit", 50, 1, 500))
        if endpoint == "/persona":
            root = resolve_root(require_str(data, "root"))
            return list_persona_state(root, optional_int(data, "limit", 100, 1, 500))
        if endpoint == "/approvals":
            root = resolve_root(require_str(data, "root"))
            status = data.get("status")
            if status is not None and not isinstance(status, str):
                raise HttpApiError("invalid_request", "status must be a string")
            return list_approvals(
                root,
                status=status if isinstance(status, str) else None,
                limit=optional_int(data, "limit", 50, 1, 500),
            )
        if endpoint == "/notifications":
            root = resolve_root(require_str(data, "root"))
            kind = data.get("kind")
            if kind is not None and not isinstance(kind, str):
                raise HttpApiError("invalid_request", "kind must be a string")
            return list_notifications(
                root,
                kind=kind if isinstance(kind, str) and kind.strip() else None,
                limit=optional_int(data, "limit", 50, 1, 500),
            )
        if endpoint == "/memory-candidates":
            root = resolve_root(require_str(data, "root"))
            return list_memory_candidates(root, optional_int(data, "limit", 50, 1, 500))
        if endpoint == "/profile":
            profile_root = Path(require_str(data, "profile_root", "~/.harvis")).expanduser().resolve()
            return profile_metadata(profile_root)
        raise HttpApiError("not_found", f"unknown endpoint: {endpoint}", HTTPStatus.NOT_FOUND)

    def handle_post(self, endpoint: str, data: JSON) -> tuple[JSON, list[str]]:
        if endpoint == "/init-workspace":
            root = resolve_root(require_str(data, "root"))
            return (
                {
                    "workspace_root": str(root),
                    "messages": init_workspace(root, optional_bool(data, "force", False)),
                },
                [],
            )
        if endpoint == "/scan-inbox":
            root = resolve_root(require_str(data, "root"))
            raw_inboxes = data.get("inboxes") or [".harvis/inbox.md"]
            if not isinstance(raw_inboxes, list) or not all(isinstance(item, str) for item in raw_inboxes):
                raise HttpApiError("invalid_request", "inboxes must be an array of strings")
            inboxes = [resolve_workspace_path(root, item) for item in raw_inboxes]
            packets = scan_inboxes(root, inboxes, allow_outside_root=False)
            runs = sync_packet_runs(root, packets) if packets else {"run_count": 0, "runs": []}
            return (
                {
                    "workspace_root": str(root),
                    "inboxes": [str(path) for path in inboxes],
                    "packets_written": [str(path) for path in packets],
                    "runs_written": runs.get("runs", []),
                },
                [],
            )
        if endpoint == "/run-tick":
            root = resolve_root(require_str(data, "root"))
            profile_root = Path(require_str(data, "profile_root", "~/.harvis")).expanduser().resolve()
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                status = run_tick(
                    root,
                    optional_int(data, "interval", 1200, 1, 86400),
                    profile_root,
                )
            return (
                {
                    "workspace_root": str(root),
                    "status": status,
                    "captured_output": captured.getvalue().splitlines(),
                },
                status.get("errors", []),
            )
        if endpoint == "/permission-probe":
            root = resolve_root(require_str(data, "root"))
            profile_root = Path(require_str(data, "profile_root", "~/.harvis")).expanduser().resolve()
            return probe_workspace_permissions(root, profile_root, context="http-api"), []
        if endpoint == "/memory-snapshot":
            root = resolve_root(require_str(data, "root"))
            result = generate_snapshot(
                root,
                Path(require_str(data, "profile_root", "~/.harvis")).expanduser().resolve(),
                max_events=optional_int(data, "max_events", 50, 0, 500),
                max_packets=optional_int(data, "max_packets", 50, 0, 500),
                max_reports=optional_int(data, "max_reports", 10, 0, 100),
                max_excerpt_chars=optional_int(data, "max_excerpt_chars", 1200, 0, 8000),
            )
            return result, result.get("warnings", [])
        if endpoint == "/prepare-workbench":
            root = resolve_root(require_str(data, "root"))
            packet = data.get("packet")
            if packet is not None and (not isinstance(packet, str) or not packet.strip()):
                raise HttpApiError("invalid_request", "packet must be a non-empty string when provided")
            return (
                prepare_workbench(
                    root,
                    Path(require_str(data, "profile_root", "~/.harvis")).expanduser().resolve(),
                    packet=packet.strip() if isinstance(packet, str) else None,
                    limit=optional_int(data, "limit", 5, 1, 100),
                ),
                [],
            )
        if endpoint == "/sync-runs":
            root = resolve_root(require_str(data, "root"))
            return sync_packet_runs(root, limit=optional_int(data, "limit", 500, 1, 5000)), []
        if endpoint == "/agent-room/init":
            root = resolve_root(require_str(data, "root"))
            return init_agent_room(root), []
        if endpoint == "/agent-room/topic":
            root = resolve_root(require_str(data, "root"))
            return (
                create_topic(
                    root,
                    title=require_str(data, "title"),
                    goal=data.get("goal", "") if isinstance(data.get("goal", ""), str) else "",
                    created_by=data.get("created_by", "harvis") if isinstance(data.get("created_by", "harvis"), str) else "harvis",
                ),
                [],
            )
        if endpoint == "/agent-room/event":
            root = resolve_root(require_str(data, "root"))
            return (
                agent_room_add_event(
                    root,
                    topic_id=require_str(data, "topic_id"),
                    agent_id=require_str(data, "agent_id", "harvis"),
                    role=require_str(data, "role", "coordinator"),
                    event_type=require_str(data, "event_type", "note"),
                    content=data.get("content", "") if isinstance(data.get("content", ""), str) else "",
                ),
                [],
            )
        if endpoint == "/agent-room/message":
            root = resolve_root(require_str(data, "root"))
            return (
                agent_room_add_message(
                    root,
                    topic_id=require_str(data, "topic_id"),
                    agent_id=require_str(data, "agent_id", "harvis"),
                    role=require_str(data, "role", "coordinator"),
                    content=require_str(data, "content"),
                ),
                [],
            )
        if endpoint == "/request-handoff":
            root = resolve_root(require_str(data, "root"))
            return (
                request_handoff(
                    root,
                    run_id=require_str(data, "run_id"),
                    harness=require_str(data, "harness"),
                    instruction=data.get("instruction", "") if isinstance(data.get("instruction", ""), str) else "",
                    topic_id=data.get("topic_id") if isinstance(data.get("topic_id"), str) and data.get("topic_id", "").strip() else None,
                    requested_by=data.get("requested_by", "harvis") if isinstance(data.get("requested_by", "harvis"), str) else "harvis",
                ),
                [],
            )
        if endpoint == "/request-approval":
            root = resolve_root(require_str(data, "root"))
            return (
                create_approval(
                    root,
                    run_id=require_str(data, "run_id"),
                    action_type=require_str(data, "action_type"),
                    target=require_str(data, "target"),
                    reason=require_str(data, "reason"),
                    risk=require_str(data, "risk", "medium"),
                    scope=require_str(data, "scope", "one_time"),
                ),
                [],
            )
        if endpoint == "/decide-approval":
            root = resolve_root(require_str(data, "root"))
            return (
                decide_approval(
                    root,
                    approval_id=require_str(data, "approval_id"),
                    decision=require_str(data, "decision"),
                    decided_by=require_str(data, "decided_by", "human"),
                    notes=data.get("notes", "") if isinstance(data.get("notes", ""), str) else "",
                ),
                [],
            )
        if endpoint == "/check-notifications":
            root = resolve_root(require_str(data, "root"))
            return check_notifications(root, write=optional_bool(data, "write", True)), []
        if endpoint == "/agent-harnesses/test":
            resolve_root(require_str(data, "root"))
            return (
                build_agent_harness_status(
                    run_tests=True,
                    timeout_seconds=optional_int(data, "timeout_seconds", 120, 1, 600),
                ),
                [],
            )
        if endpoint == "/persona/init":
            root = resolve_root(require_str(data, "root"))
            return init_persona_registry(root), []
        if endpoint == "/persona/create-vault":
            root = resolve_root(require_str(data, "root"))
            return (
                create_memory_vault(
                    root,
                    display_name=require_str(data, "display_name"),
                    vault_id=data.get("vault_id") if isinstance(data.get("vault_id"), str) and data.get("vault_id", "").strip() else None,
                    owner=data.get("owner", "harzva") if isinstance(data.get("owner", "harzva"), str) else "harzva",
                ),
                [],
            )
        if endpoint == "/persona/create-card":
            root = resolve_root(require_str(data, "root"))
            return (
                create_persona_card(
                    root,
                    display_name=require_str(data, "display_name"),
                    persona_id=data.get("persona_id") if isinstance(data.get("persona_id"), str) and data.get("persona_id", "").strip() else None,
                    visual_asset_id=data.get("visual_asset_id", "") if isinstance(data.get("visual_asset_id", ""), str) else "",
                ),
                [],
            )
        if endpoint == "/persona/update-card":
            root = resolve_root(require_str(data, "root"))
            tone = data.get("tone")
            if tone is not None and not isinstance(tone, dict):
                raise HttpApiError("invalid_request", "tone must be an object")
            decision_style = data.get("decision_style")
            if decision_style is not None and not isinstance(decision_style, dict):
                raise HttpApiError("invalid_request", "decision_style must be an object")
            behavior_rules = data.get("behavior_rules")
            if behavior_rules is not None and (
                not isinstance(behavior_rules, list) or not all(isinstance(item, str) for item in behavior_rules)
            ):
                raise HttpApiError("invalid_request", "behavior_rules must be an array of strings")
            return (
                update_persona_card(
                    root,
                    persona_id=require_str(data, "persona_id"),
                    display_name=data.get("display_name") if isinstance(data.get("display_name"), str) else None,
                    visual_asset_id=data.get("visual_asset_id") if isinstance(data.get("visual_asset_id"), str) else None,
                    base_template=data.get("base_template") if isinstance(data.get("base_template"), str) else None,
                    status=data.get("status") if isinstance(data.get("status"), str) else None,
                    tone=tone if isinstance(tone, dict) else None,
                    decision_style=decision_style if isinstance(decision_style, dict) else None,
                    behavior_rules=behavior_rules if isinstance(behavior_rules, list) else None,
                ),
                [],
            )
        if endpoint == "/persona/create-twin":
            root = resolve_root(require_str(data, "root"))
            permissions = data.get("permissions")
            if permissions is not None and not isinstance(permissions, dict):
                raise HttpApiError("invalid_request", "permissions must be an object")
            return (
                create_twin_instance(
                    root,
                    display_name=require_str(data, "display_name"),
                    memory_vault_id=require_str(data, "memory_vault_id"),
                    persona_card_id=require_str(data, "persona_card_id"),
                    instance_id=data.get("instance_id") if isinstance(data.get("instance_id"), str) and data.get("instance_id", "").strip() else None,
                    permissions=permissions if isinstance(permissions, dict) else None,
                ),
                [],
            )
        if endpoint == "/personality-candidate":
            root = resolve_root(require_str(data, "root"))
            refs = data.get("source_refs", [])
            if refs is not None and (not isinstance(refs, list) or not all(isinstance(item, str) for item in refs)):
                raise HttpApiError("invalid_request", "source_refs must be an array of strings")
            return (
                create_personality_candidate(
                    root,
                    trait=require_str(data, "trait"),
                    target_persona_id=require_str(data, "target_persona_id"),
                    source_type=require_str(data, "source_type", "manual"),
                    source_refs=refs if isinstance(refs, list) else [],
                    trait_type=require_str(data, "trait_type", "decision_style"),
                    confidence=optional_int(data, "confidence_percent", 50, 0, 100) / 100,
                ),
                [],
            )
        if endpoint == "/personality-candidate/decide":
            root = resolve_root(require_str(data, "root"))
            return (
                decide_personality_candidate(
                    root,
                    candidate_id=require_str(data, "candidate_id"),
                    decision=require_str(data, "decision"),
                    decided_by=require_str(data, "decided_by", "human"),
                    notes=data.get("notes", "") if isinstance(data.get("notes", ""), str) else "",
                    edited_trait=data.get("edited_trait", "") if isinstance(data.get("edited_trait", ""), str) else "",
                ),
                [],
            )
        if endpoint == "/init-profile":
            profile_root = Path(require_str(data, "profile_root", "~/.harvis")).expanduser().resolve()
            return (
                {
                    "profile_root": str(profile_root),
                    "messages": init_profile(profile_root, optional_bool(data, "force", False)),
                },
                [],
            )
        raise HttpApiError("not_found", f"unknown endpoint: {endpoint}", HTTPStatus.NOT_FOUND)


def run_server(host: str, port: int) -> None:
    server = ThreadingHTTPServer((host, port), HarvisRequestHandler)
    print(f"H.A.R.V.I.S. HTTP API listening on http://{host}:{port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("H.A.R.V.I.S. HTTP API stopped.", file=sys.stderr)
    finally:
        server.server_close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the local H.A.R.V.I.S. JSON HTTP API.")
    parser.add_argument("--host", default=DEFAULT_HOST, help="Host to bind. Defaults to 127.0.0.1.")
    parser.add_argument("--port", default=DEFAULT_PORT, type=int, help="Port to bind. Defaults to 8765.")
    parser.add_argument("--auth-token", default="", help="Optional bearer token for JSON endpoints.")
    parser.add_argument("--auth-token-file", default="", help="Optional file containing a bearer token.")
    args = parser.parse_args()

    if args.auth_token:
        os.environ["HARVIS_HTTP_AUTH_TOKEN"] = args.auth_token
    if args.auth_token_file:
        os.environ["HARVIS_HTTP_AUTH_TOKEN_FILE"] = args.auth_token_file

    if args.host not in {"127.0.0.1", "localhost", "::1"}:
        print(
            "warning: binding outside localhost expands the API exposure surface",
            file=sys.stderr,
        )
    if configured_auth_token() is not None:
        print("H.A.R.V.I.S. HTTP API bearer token protection enabled.", file=sys.stderr)
    run_server(args.host, args.port)
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("http", legacy_main=main))
