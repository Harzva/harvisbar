#!/usr/bin/env python3
"""Manage local LaunchAgent services for H.A.R.V.I.S."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import secrets
import socket
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from harvis_permission_probe import probe_workspace_permissions


HTTP_LABEL = "local.harzva.harvis.http"
TICK_LABEL = "local.harzva.harvis.tick"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_INTERVAL = 1200
HUB_WIKI_ENV_VARS = ("HARVIS_HUB_WIKI_ROOT", "HARZVA_HUB_WIKI_ROOT")
SERVICE_LABELS = {
    "http": HTTP_LABEL,
    "tick": TICK_LABEL,
}


def plugin_root() -> Path:
    return Path(__file__).resolve().parents[1]


def home_dir() -> Path:
    return Path.home().resolve()


def service_log_dir(home: Path | None = None) -> Path:
    return (home or home_dir()) / ".harvis" / "logs"


def auth_dir(home: Path | None = None) -> Path:
    return (home or home_dir()) / ".harvis" / "auth"


def default_token_file(home: Path | None = None) -> Path:
    return auth_dir(home) / "http.token"


def launch_agent_path(service: str, home: Path | None = None) -> Path:
    label = service_label(service)
    return (home or home_dir()) / "Library" / "LaunchAgents" / f"{label}.plist"


def service_label(service: str) -> str:
    if service not in SERVICE_LABELS:
        raise ValueError(f"unsupported service: {service}")
    return SERVICE_LABELS[service]


def ensure_log_dir(home: Path | None = None) -> Path:
    path = service_log_dir(home)
    path.mkdir(parents=True, exist_ok=True)
    return path


def ensure_token_file(path: Path) -> tuple[Path, bool]:
    path = path.expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return path, False
    path.write_text(secrets.token_urlsafe(32) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
    return path, True


def rust_runtime_entrypoint(plugin: Path) -> Path:
    release_binary = plugin / "target" / "release" / "harvis"
    if release_binary.exists() and os.access(release_binary, os.X_OK):
        return release_binary
    return plugin / "scripts" / "harvis"


def program_arguments(
    service: str,
    plugin: Path,
    port: int,
    root: Path,
    profile_root: Path,
    interval: int,
    auth_token_file: Path | None = None,
) -> list[str]:
    runtime = rust_runtime_entrypoint(plugin)
    if service == "http":
        args = [
            str(runtime),
            "http",
            "--host",
            DEFAULT_HOST,
            "--port",
            str(port),
        ]
        if auth_token_file is not None:
            args.extend(["--auth-token-file", str(auth_token_file.expanduser().resolve())])
        return args
    if service == "tick":
        return [
            str(runtime),
            "run-tick",
            "--root",
            str(root.expanduser().resolve()),
            "--profile-root",
            str(profile_root.expanduser().resolve()),
            "--interval",
            str(interval),
            "--loop",
        ]
    raise ValueError(f"unsupported service: {service}")


def hub_wiki_candidates_from_text(text: str) -> list[Path]:
    marker = "harzva-local-knowledge-hub"
    candidates: list[Path] = []
    for raw in text.split():
        token = raw.strip("`\"'()[],:;<>")
        index = token.find(marker)
        if index < 0:
            continue
        base = token[: index + len(marker)]
        candidates.append(Path(base) / "wiki")
    return candidates


def discover_hub_wiki_root(home: Path) -> Path | None:
    for name in HUB_WIKI_ENV_VARS:
        value = os.environ.get(name, "").strip()
        if value:
            return Path(value).expanduser()
    global_knowledge = os.environ.get("HARZVA_GLOBAL_KNOWLEDGE", "").strip()
    if global_knowledge:
        try:
            text = Path(global_knowledge).expanduser().read_text(encoding="utf-8")
        except OSError:
            text = ""
        for candidate in hub_wiki_candidates_from_text(text):
            if candidate.is_dir():
                return candidate
    profile_default = home / ".harvis" / "knowledge-hub" / "wiki"
    if profile_default.is_dir():
        return profile_default
    return None


def environment(home: Path, token_file: Path | None) -> dict[str, str]:
    env = {
        "HOME": str(home),
        "PATH": (
            f"{home}/.local/bin:{home}/.local/node/current/bin:"
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ),
        "HARVIS_HOME": str(home / ".harvis"),
    }
    if token_file is not None:
        env["HARVIS_HTTP_AUTH_TOKEN_FILE"] = str(token_file.expanduser().resolve())
    hub_wiki_root = discover_hub_wiki_root(home)
    if hub_wiki_root is not None:
        value = str(hub_wiki_root.expanduser().resolve() if hub_wiki_root.exists() else hub_wiki_root.expanduser())
        for name in HUB_WIKI_ENV_VARS:
            env[name] = value
    return env


def render_launch_agent(
    service: str,
    plugin: Path | None = None,
    home: Path | None = None,
    port: int = DEFAULT_PORT,
    root: Path | None = None,
    profile_root: Path | None = None,
    interval: int = DEFAULT_INTERVAL,
    auth_token_file: Path | None = None,
) -> str:
    home = (home or home_dir()).expanduser().resolve()
    plugin = (plugin or plugin_root()).expanduser().resolve()
    root = (root or Path.cwd()).expanduser().resolve()
    profile_root = (profile_root or Path("~/.harvis")).expanduser()
    logs = service_log_dir(home)
    label = service_label(service)
    plist: dict[str, Any] = {
        "Label": label,
        "ProgramArguments": program_arguments(
            service,
            plugin,
            port,
            root,
            profile_root,
            interval,
            auth_token_file if service == "http" else None,
        ),
        "EnvironmentVariables": environment(home, auth_token_file if service == "http" else None),
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": str(logs / f"{service}.out.log"),
        "StandardErrorPath": str(logs / f"{service}.err.log"),
    }
    return plistlib.dumps(plist, sort_keys=True).decode("utf-8")


def write_launch_agent(
    service: str,
    plugin: Path | None,
    port: int,
    root: Path,
    profile_root: Path,
    interval: int,
    auth_token_file: Path | None,
) -> Path:
    home = home_dir()
    ensure_log_dir(home)
    launch_agents = home / "Library" / "LaunchAgents"
    launch_agents.mkdir(parents=True, exist_ok=True)
    path = launch_agent_path(service, home)
    path.write_text(
        render_launch_agent(
            service,
            plugin=plugin,
            home=home,
            port=port,
            root=root,
            profile_root=profile_root,
            interval=interval,
            auth_token_file=auth_token_file,
        ),
        encoding="utf-8",
    )
    return path


def launchctl(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/launchctl", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def bootstrap(service: str) -> subprocess.CompletedProcess[str]:
    uid = os.getuid()
    path = launch_agent_path(service)
    launchctl("bootout", f"gui/{uid}", str(path))
    return launchctl("bootstrap", f"gui/{uid}", str(path))


def bootout(service: str) -> subprocess.CompletedProcess[str]:
    uid = os.getuid()
    return launchctl("bootout", f"gui/{uid}", str(launch_agent_path(service)))


def service_status(service: str, port: int) -> dict[str, Any]:
    label = service_label(service)
    uid = os.getuid()
    proc = launchctl("print", f"gui/{uid}/{label}")
    output = (proc.stdout or "") + (proc.stderr or "")
    loaded = proc.returncode == 0
    running = loaded and ("state = running" in output or "\npid =" in output)
    listening = False
    if service == "http":
        try:
            with socket.create_connection((DEFAULT_HOST, port), timeout=0.5):
                listening = True
        except OSError:
            listening = False
    return {
        "service": service,
        "label": label,
        "plist": str(launch_agent_path(service)),
        "loaded": loaded,
        "running": running,
        "listening": listening if service == "http" else None,
        "logs": {
            "stdout": str(service_log_dir() / f"{service}.out.log"),
            "stderr": str(service_log_dir() / f"{service}.err.log"),
        },
    }


def selected_services(value: str) -> list[str]:
    if value == "both":
        return ["http", "tick"]
    return [value]


def token_file_from_args(args: argparse.Namespace) -> Path | None:
    if args.auth_token_file:
        return Path(args.auth_token_file).expanduser().resolve()
    if args.ensure_token_file:
        return default_token_file()
    return None


def print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, sort_keys=True))


def read_token(path: Path | None) -> str | None:
    if path is None or not path.exists():
        return None
    value = path.read_text(encoding="utf-8").strip()
    return value or None


def http_permission_probe(root: Path, profile_root: Path, port: int, token_file: Path | None) -> dict[str, Any]:
    query = urllib.parse.urlencode(
        {
            "root": str(root.expanduser().resolve()),
            "profile_root": str(profile_root.expanduser().resolve()),
        }
    )
    request = urllib.request.Request(f"http://{DEFAULT_HOST}:{port}/permission-probe?{query}")
    token = read_token(token_file)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            body = response.read().decode("utf-8")
            return {
                "mode": "http-api",
                "http_status": response.status,
                "response": json.loads(body),
            }
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            parsed: Any = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"raw": body[:300]}
        return {
            "mode": "http-api",
            "http_status": exc.code,
            "response": parsed,
        }
    except OSError as exc:
        return {
            "mode": "http-api",
            "http_status": None,
            "response": {
                "ok": False,
                "error": {
                    "code": "connection_failed",
                    "message": str(exc),
                },
            },
        }


def add_common_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--service", choices=["http", "tick", "both"], default="http")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--root", default=".", help="Workspace root for the tick service.")
    parser.add_argument("--profile-root", default="~/.harvis")
    parser.add_argument("--interval", type=int, default=DEFAULT_INTERVAL)
    parser.add_argument("--plugin-root", default=str(plugin_root()))
    parser.add_argument("--auth-token-file", default="")
    parser.add_argument(
        "--ensure-token-file",
        action="store_true",
        help="Create ~/.harvis/auth/http.token if needed and point the HTTP service at it.",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage H.A.R.V.I.S. LaunchAgent services.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ["plist", "install", "start", "stop", "restart", "status", "logs", "uninstall", "probe"]:
        subparser = subparsers.add_parser(name)
        add_common_options(subparser)
        if name == "probe":
            subparser.add_argument(
                "--via-http",
                action="store_true",
                help="Probe through the running localhost HTTP API to test the LaunchAgent process.",
            )
    args = parser.parse_args()

    services = selected_services(args.service)
    plugin = Path(args.plugin_root).expanduser().resolve()
    root = Path(args.root).expanduser().resolve()
    profile_root = Path(args.profile_root).expanduser()
    token_file = token_file_from_args(args)
    token_info = None
    if args.ensure_token_file and token_file is not None:
        token_file, created = ensure_token_file(token_file)
        token_info = {"token_file": str(token_file), "created": created, "token_value_returned": False}

    if args.command == "plist":
        if len(services) != 1:
            raise SystemExit("plist command requires --service http or --service tick")
        print(
            render_launch_agent(
                services[0],
                plugin=plugin,
                port=args.port,
                root=root,
                profile_root=profile_root,
                interval=args.interval,
                auth_token_file=token_file,
            ),
            end="",
        )
        return 0

    if args.command == "logs":
        ensure_log_dir()
        print_json(
            {
                "log_dir": str(service_log_dir()),
                "services": [service_status(s, args.port) for s in services],
                "token": token_info,
            }
        )
        return 0

    if args.command == "status":
        print_json({"services": [service_status(s, args.port) for s in services], "token": token_info})
        return 0

    if args.command == "probe":
        probe_token_file = token_file or default_token_file()
        if args.via_http:
            print_json(
                {
                    "services": [service_status(s, args.port) for s in services],
                    "probe": http_permission_probe(root, profile_root, args.port, probe_token_file),
                    "token": token_info,
                }
            )
            return 0
        probe_result = probe_workspace_permissions(root, profile_root, context="service-manager-direct")
        print_json(
            {
                "services": [service_status(s, args.port) for s in services],
                "probe": {
                    "mode": "direct",
                    "response": {
                        "ok": probe_result.get("ok") is True,
                        "data": probe_result,
                    },
                },
                "token": token_info,
            }
        )
        return 0

    results = []
    for service in services:
        if args.command in {"install", "start", "restart"}:
            path = write_launch_agent(service, plugin, args.port, root, profile_root, args.interval, token_file)
            if args.command == "restart":
                bootout(service)
            proc = bootstrap(service)
            results.append(
                {
                    "service": service,
                    "plist": str(path),
                    "action": args.command,
                    "returncode": proc.returncode,
                    "stderr": proc.stderr.strip(),
                }
            )
            continue
        if args.command == "stop":
            proc = bootout(service)
            results.append(
                {
                    "service": service,
                    "action": "stop",
                    "returncode": proc.returncode,
                    "stderr": proc.stderr.strip(),
                }
            )
            continue
        if args.command == "uninstall":
            proc = bootout(service)
            path = launch_agent_path(service)
            if path.exists():
                path.unlink()
            results.append(
                {
                    "service": service,
                    "action": "uninstall",
                    "returncode": proc.returncode,
                    "plist_removed": not path.exists(),
                }
            )
            continue
    print_json({"results": results, "token": token_info})
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("service-manager", legacy_main=main))
