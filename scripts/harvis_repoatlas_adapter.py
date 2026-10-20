#!/usr/bin/env python3
"""Redacted RepoAtlas compact-map adapter for H.A.R.V.I.S."""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Any


ADAPTER_VERSION = "v0.27-alpha"
MAP_ENV_NAMES = (
    "HARVIS_REPOATLAS_MAP",
    "REPOATLAS_MCP_INVENTORY",
    "REPO_ATLAS_DATA",
)
GLOBAL_KNOWLEDGE_RE = re.compile(r"RepoAtlas remote-to-local compact map is `([^`]+)`")


def normalize_repo_key(value: str) -> str:
    text = value.strip()
    for prefix in ("https://github.com/", "http://github.com/", "git@github.com:"):
        text = text.removeprefix(prefix)
    text = text.removesuffix(".git")
    return text.strip("/").lower()


def first_text(*values: Any) -> str:
    for value in values:
        if isinstance(value, str) and value:
            return value
    return ""


def int_sum(items: list[dict[str, Any]], key: str) -> int:
    total = 0
    for item in items:
        try:
            total += int(item.get(key) or 0)
        except (TypeError, ValueError):
            continue
    return total


def path_display(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    path = Path(value)
    if path.is_absolute():
        return path.name or "local-path"
    return value


def global_knowledge_map_candidates() -> list[Path]:
    pointer = os.environ.get("HARZVA_GLOBAL_KNOWLEDGE", "").strip()
    if not pointer:
        return []
    knowledge_path = Path(pointer).expanduser()
    try:
        text = knowledge_path.read_text(encoding="utf-8")
    except OSError:
        return []
    return [Path(match.group(1)).expanduser() for match in GLOBAL_KNOWLEDGE_RE.finditer(text)]


def map_candidates() -> list[Path]:
    candidates: list[Path] = []
    for env_name in MAP_ENV_NAMES:
        value = os.environ.get(env_name, "").strip()
        if value:
            candidates.append(Path(value).expanduser())
    candidates.extend(global_knowledge_map_candidates())
    candidates.extend(
        [
            Path("~/.harvis/repoatlas/repoatlas-local-address-map.json").expanduser(),
            Path.cwd() / "repoatlas-map" / "repoatlas-local-address-map.json",
        ]
    )
    seen: set[str] = set()
    unique: list[Path] = []
    for candidate in candidates:
        key = str(candidate)
        if key not in seen:
            unique.append(candidate)
            seen.add(key)
    return unique


def resolve_map_path(map_path: str | None = None) -> Path | None:
    if map_path:
        path = Path(map_path).expanduser()
        return path if path.exists() and path.is_file() else None
    for candidate in map_candidates():
        if candidate.exists() and candidate.is_file():
            return candidate
    return None


def unavailable_payload(map_path: str | None = None) -> dict[str, Any]:
    provided = path_display(map_path) if map_path else None
    payload: dict[str, Any] = {
        "adapter_version": ADAPTER_VERSION,
        "repoatlas": "unavailable",
        "mapFound": False,
        "error": "repoatlas compact map not found",
        "candidateDisplays": [path_display(str(path)) for path in map_candidates()[:5]],
        "redacted": True,
        "includesLocalAbsolutePaths": False,
    }
    if provided:
        payload["providedMapDisplay"] = provided
    return payload


def load_map(map_path: str | None = None) -> tuple[dict[str, Any] | None, Path | None]:
    path = resolve_map_path(map_path)
    if path is None:
        return None, None
    return json.loads(path.read_text(encoding="utf-8")), path


def compact_repo(repo: dict[str, Any]) -> dict[str, Any]:
    return {
        "repoKey": first_text(repo.get("repoKey"), normalize_repo_key(first_text(repo.get("nameWithOwner"), repo.get("url")))),
        "nameWithOwner": first_text(repo.get("nameWithOwner"), repo.get("repoKey")),
        "url": first_text(repo.get("url")),
        "accountAlias": first_text(repo.get("accountAlias")),
        "accountLogin": first_text(repo.get("accountLogin")),
        "defaultBranch": first_text(repo.get("defaultBranch")),
        "localExists": bool(repo.get("localExists") or repo.get("localPaths")),
        "localPaths": [path for path in repo.get("localPaths", []) if isinstance(path, str)],
        "localStatus": first_text(repo.get("localStatus"), "no-local-copy"),
        "localStatusList": [first_text(repo.get("localStatus"), "no-local-copy")],
        "dirty": bool(repo.get("dirty")),
        "ahead": int(repo.get("ahead") or 0),
        "behind": int(repo.get("behind") or 0),
        "category": first_text(repo.get("category")),
    }


def row_repo(row: dict[str, Any]) -> dict[str, Any]:
    if isinstance(row.get("remote"), dict):
        remote = row.get("remote") or {}
        matches = [match for match in row.get("localMatches", []) if isinstance(match, dict)]
        local_paths = [match.get("path") for match in matches if isinstance(match.get("path"), str)]
        statuses = sorted({match.get("status") for match in matches if isinstance(match.get("status"), str)})
        status = ", ".join(statuses) if statuses else first_text(row.get("localStatus"), "no-local-copy")
        return {
            "repoKey": first_text(remote.get("repoKey"), normalize_repo_key(first_text(remote.get("nameWithOwner"), remote.get("url")))),
            "nameWithOwner": first_text(remote.get("nameWithOwner"), remote.get("repoKey")),
            "url": first_text(remote.get("url")),
            "accountAlias": first_text(remote.get("accountAlias")),
            "accountLogin": first_text(remote.get("accountLogin")),
            "defaultBranch": first_text(
                (row.get("defaultBranchRef") or {}).get("name")
                if isinstance(row.get("defaultBranchRef"), dict)
                else None,
                row.get("defaultBranch"),
            ),
            "localExists": bool(local_paths),
            "localPaths": local_paths,
            "localStatus": status,
            "localStatusList": statuses or [status],
            "dirty": any(bool(match.get("dirty")) for match in matches),
            "ahead": int_sum(matches, "ahead"),
            "behind": int_sum(matches, "behind"),
            "category": "",
        }

    local_paths = [path for path in row.get("localPaths", []) if isinstance(path, str)]
    statuses = [status for status in row.get("localStatusList", []) if isinstance(status, str)]
    matches = [match for match in row.get("localMatches", []) if isinstance(match, dict)]
    status = first_text(row.get("localStatus"), ", ".join(statuses), "no-local-copy")
    return {
        "repoKey": first_text(row.get("repoKey"), normalize_repo_key(first_text(row.get("name"), row.get("url")))),
        "nameWithOwner": first_text(row.get("name"), row.get("nameWithOwner"), row.get("repoKey")),
        "url": first_text(row.get("url")),
        "accountAlias": first_text(row.get("accountAlias")),
        "accountLogin": first_text(row.get("accountLogin"), row.get("owner")),
        "defaultBranch": first_text(row.get("defaultBranch")),
        "localExists": bool(local_paths),
        "localPaths": local_paths,
        "localStatus": status,
        "localStatusList": statuses or [status],
        "dirty": any(bool(match.get("dirty")) for match in matches),
        "ahead": int_sum(matches, "ahead"),
        "behind": int_sum(matches, "behind"),
        "category": first_text(row.get("category"), row.get("categoryLabel")),
    }


def repositories(data: dict[str, Any]) -> list[dict[str, Any]]:
    if isinstance(data.get("repositories"), list):
        return [compact_repo(repo) for repo in data["repositories"] if isinstance(repo, dict)]
    rows = data.get("rows")
    if isinstance(rows, list):
        return [row_repo(row) for row in rows if isinstance(row, dict)]
    return []


def needs_attention(repo: dict[str, Any]) -> bool:
    statuses = {str(status) for status in repo.get("localStatusList", [])}
    status_text = str(repo.get("localStatus") or "")
    status_hit = any(status in {"ahead", "behind", "diverged", "no-upstream"} for status in statuses)
    return (
        status_hit
        or any(token in status_text for token in ("ahead", "behind", "diverged", "no-upstream"))
        or bool(repo.get("dirty"))
        or bool(repo.get("ahead"))
        or bool(repo.get("behind"))
    )


def public_repo(repo: dict[str, Any], include_paths: bool = False) -> dict[str, Any]:
    local_paths = [path for path in repo.get("localPaths", []) if isinstance(path, str)]
    item: dict[str, Any] = {
        "repoKey": repo.get("repoKey"),
        "nameWithOwner": repo.get("nameWithOwner"),
        "url": repo.get("url"),
        "accountAlias": repo.get("accountAlias"),
        "accountLogin": repo.get("accountLogin"),
        "defaultBranch": repo.get("defaultBranch"),
        "localExists": repo.get("localExists"),
        "localPathCount": len(local_paths),
        "localPathDisplays": [path_display(path) for path in local_paths],
        "localStatus": repo.get("localStatus"),
        "dirty": repo.get("dirty"),
        "ahead": repo.get("ahead"),
        "behind": repo.get("behind"),
        "category": repo.get("category"),
    }
    if include_paths:
        item["localPaths"] = local_paths
    return item


def base_payload(
    data: dict[str, Any],
    inventory_path: Path,
    include_paths: bool,
) -> dict[str, Any]:
    repos = repositories(data)
    summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
    matched = sum(1 for repo in repos if repo.get("localExists"))
    missing = len(repos) - matched
    attention = [repo for repo in repos if needs_attention(repo)]
    payload = {
        "adapter_version": ADAPTER_VERSION,
        "repoatlas": "available",
        "mapFound": True,
        "inventoryPathDisplay": path_display(str(inventory_path)),
        "generatedAt": data.get("generatedAt"),
        "summary": {
            "remoteCount": summary.get("remoteCount", data.get("remoteCount", len(repos))),
            "localRepoCount": summary.get("localRepoCount", data.get("localRepoCount")),
            "matchedRemoteCount": summary.get("matchedRemoteCount", matched),
            "missingLocalCount": summary.get("missingLocalCount", missing),
            "attentionCount": summary.get("attentionCount", len(attention)),
        },
        "redacted": not include_paths,
        "includesLocalAbsolutePaths": include_paths,
    }
    if include_paths:
        payload["inventoryPath"] = str(inventory_path)
    return payload


def repoatlas_status(map_path: str | None = None, include_paths: bool = False) -> dict[str, Any]:
    data, path = load_map(map_path)
    if data is None or path is None:
        return unavailable_payload(map_path)
    return base_payload(data, path, include_paths)


def repoatlas_find_repo(
    query: str,
    limit: int = 10,
    map_path: str | None = None,
    include_paths: bool = False,
) -> dict[str, Any]:
    query = query.strip()
    if not query:
        raise SystemExit("query is required")
    data, path = load_map(map_path)
    if data is None or path is None:
        payload = unavailable_payload(map_path)
        payload.update({"query": query, "count": 0, "items": []})
        return payload

    needle = normalize_repo_key(query)
    exact: list[dict[str, Any]] = []
    partial: list[dict[str, Any]] = []
    for repo in repositories(data):
        haystack = " ".join(
            str(repo.get(key) or "").lower()
            for key in ("repoKey", "nameWithOwner", "url", "accountAlias", "accountLogin", "category")
        )
        repo_key = str(repo.get("repoKey") or "").lower()
        if needle and needle == repo_key:
            exact.append(repo)
        elif needle and needle in haystack:
            partial.append(repo)
    matches = (exact + partial)[: max(1, min(limit, 50))]
    payload = base_payload(data, path, include_paths)
    payload.update(
        {
            "query": query,
            "normalizedQuery": needle,
            "count": len(matches),
            "items": [public_repo(repo, include_paths) for repo in matches],
        }
    )
    return payload


def repoatlas_missing_local_copies(
    limit: int = 50,
    map_path: str | None = None,
) -> dict[str, Any]:
    data, path = load_map(map_path)
    if data is None or path is None:
        payload = unavailable_payload(map_path)
        payload.update({"count": 0, "items": []})
        return payload
    items = [repo for repo in repositories(data) if not repo.get("localExists")]
    payload = base_payload(data, path, include_paths=False)
    payload.update(
        {
            "count": len(items),
            "items": [public_repo(repo, include_paths=False) for repo in items[: max(1, min(limit, 200))]],
        }
    )
    return payload


def repoatlas_needs_attention(
    limit: int = 50,
    map_path: str | None = None,
    include_paths: bool = False,
) -> dict[str, Any]:
    data, path = load_map(map_path)
    if data is None or path is None:
        payload = unavailable_payload(map_path)
        payload.update({"count": 0, "items": []})
        return payload
    items = [repo for repo in repositories(data) if needs_attention(repo)]
    payload = base_payload(data, path, include_paths)
    payload.update(
        {
            "count": len(items),
            "items": [public_repo(repo, include_paths) for repo in items[: max(1, min(limit, 200))]],
        }
    )
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description="H.A.R.V.I.S. RepoAtlas adapter.")
    parser.add_argument("--map", dest="map_path", default="", help="Optional compact map path override.")
    parser.add_argument("--include-paths", action="store_true", help="Include local absolute paths in local-only output.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")
    find_parser = subparsers.add_parser("find")
    find_parser.add_argument("query")
    find_parser.add_argument("--limit", type=int, default=10)
    missing_parser = subparsers.add_parser("missing")
    missing_parser.add_argument("--limit", type=int, default=50)
    attention_parser = subparsers.add_parser("attention")
    attention_parser.add_argument("--limit", type=int, default=50)
    args = parser.parse_args()

    map_path = args.map_path or None
    if args.command == "status":
        payload = repoatlas_status(map_path=map_path, include_paths=args.include_paths)
    elif args.command == "find":
        payload = repoatlas_find_repo(args.query, args.limit, map_path=map_path, include_paths=args.include_paths)
    elif args.command == "missing":
        payload = repoatlas_missing_local_copies(args.limit, map_path=map_path)
    elif args.command == "attention":
        payload = repoatlas_needs_attention(args.limit, map_path=map_path, include_paths=args.include_paths)
    else:
        raise SystemExit(f"unknown command: {args.command}")
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def rust_repoatlas_argv(argv: list[str]) -> list[str]:
    from harvis_rust_shim import split_leading_options

    global_args, rest = split_leading_options(
        argv,
        value_options={"--map"},
        flag_options={"--include-paths"},
    )
    if not rest:
        return ["repoatlas", "status", *global_args]
    command, *tail = rest
    return ["repoatlas", command, *global_args, *tail]


if __name__ == "__main__":
    import sys

    from harvis_rust_shim import exec_harvis, use_legacy_python_entrypoint

    if use_legacy_python_entrypoint():
        raise SystemExit(main())
    raise SystemExit(exec_harvis(rust_repoatlas_argv(sys.argv[1:])))
