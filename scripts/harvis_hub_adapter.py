#!/usr/bin/env python3
"""Redacted HarzvaHub and local wiki adapter for H.A.R.V.I.S."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any


ADAPTER_VERSION = "v0.14-alpha"
DEFAULT_WIKI_ROOT = Path("~/.harvis/knowledge-hub/wiki")
LOCAL_PATH_RE = re.compile(r"(?P<path>(?:/Users|/Volumes)/[^\s`),]+)")
SENSITIVE_RE = re.compile(
    r"(api[_-]?key|token|cookie|password|secret|credential|BEGIN\s+(?:RSA|OPENSSH|EC)?\s*PRIVATE\s+KEY)",
    re.IGNORECASE,
)


def run_hub_json(args: list[str], timeout: int = 8) -> dict[str, Any]:
    command = ["harzva-hub", *args, "--json"]
    try:
        proc = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return {"ok": False, "error": "harzva-hub command not found"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "harzva-hub command timed out"}
    if proc.returncode != 0:
        return {"ok": False, "error": redact_text((proc.stderr or proc.stdout).strip(), 500)}
    try:
        loaded = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return {"ok": False, "error": f"harzva-hub returned invalid JSON: {exc}"}
    return {"ok": True, "data": loaded}


def redact_text(text: str, max_chars: int = 2000) -> str:
    lines: list[str] = []
    for line in text.splitlines():
        if SENSITIVE_RE.search(line):
            lines.append("[redacted sensitive-looking line]")
            continue
        lines.append(LOCAL_PATH_RE.sub("[redacted local path]", line))
    result = "\n".join(lines).strip()
    if len(result) > max_chars:
        result = result[:max_chars].rstrip() + "\n[truncated]"
    return result


def path_display(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    if value.startswith("/"):
        return Path(value).name or "local-path"
    return value


def wiki_root() -> Path:
    env = os.environ.get("HARVIS_HUB_WIKI_ROOT", "").strip()
    if not env:
        env = os.environ.get("HARZVA_HUB_WIKI_ROOT", "").strip()
    return Path(env).expanduser().resolve() if env else DEFAULT_WIKI_ROOT.expanduser().resolve()


def hub_status() -> dict[str, Any]:
    result = run_hub_json(["status"])
    if not result["ok"]:
        return {
            "adapter_version": ADAPTER_VERSION,
            "hub": "unavailable",
            "error": result["error"],
            "redacted": True,
        }
    data = result["data"]
    summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
    services = data.get("services") if isinstance(data.get("services"), list) else []
    service_items = []
    for service in services[:5]:
        if not isinstance(service, dict):
            continue
        service_items.append(
            {
                "label": service.get("label"),
                "host": service.get("host"),
                "configured_port": service.get("configured_port"),
                "running": service.get("running"),
                "listening": service.get("listening"),
                "state": service.get("state"),
            }
        )
    return {
        "adapter_version": ADAPTER_VERSION,
        "hub": "available",
        "generated_at": data.get("generated_at"),
        "summary": {
            "projects": summary.get("projects"),
            "repos": summary.get("repos"),
            "codex_skills": summary.get("codex_skills"),
            "codex_mcp": summary.get("codex_mcp"),
            "repoatlas_attention_repos": summary.get("repoatlas_attention_repos"),
        },
        "services": service_items,
        "redacted": True,
        "includesLocalAbsolutePaths": False,
    }


def hub_path_lookup(query: str, limit: int = 10) -> dict[str, Any]:
    query = query.strip()
    if not query:
        raise SystemExit("query is required")
    result = run_hub_json(["path", "resolve", query])
    if not result["ok"]:
        return {"query": query, "count": 0, "items": [], "error": result["error"], "redacted": True}
    data = result["data"]
    raw_items = data.get("items") if isinstance(data.get("items"), list) else []
    items = []
    for item in raw_items[: max(1, min(limit, 50))]:
        if not isinstance(item, dict):
            continue
        items.append(
            {
                "name": item.get("name") or item.get("relative_path") or path_display(item.get("path")),
                "pathDisplay": path_display(item.get("relative_path") or item.get("path")),
                "status": item.get("status"),
                "statusText": item.get("status_text"),
                "dirty": item.get("dirty"),
                "ahead": item.get("ahead"),
                "behind": item.get("behind"),
                "platform": item.get("platform"),
                "remotePresent": bool(item.get("remote")),
            }
        )
    return {
        "query": query,
        "count": len(items),
        "items": items,
        "redacted": True,
        "includesLocalAbsolutePaths": False,
    }


def page_title(path: Path, text: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line.removeprefix("# ").strip()
    return path.stem


def wiki_page_id(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root.resolve()).with_suffix("").as_posix()


def wiki_search(query: str, limit: int = 10, max_excerpt_chars: int = 360) -> dict[str, Any]:
    query = query.strip()
    if not query:
        raise SystemExit("query is required")
    root = wiki_root()
    if not root.exists():
        return {"query": query, "count": 0, "items": [], "wiki": "unavailable", "redacted": True}
    lowered = query.lower()
    scored: list[tuple[int, Path, str]] = []
    for path in root.rglob("*.md"):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        score = text.lower().count(lowered) + path.name.lower().count(lowered) * 3
        if score > 0:
            scored.append((score, path, text))
    items = []
    for score, path, text in sorted(scored, key=lambda row: row[0], reverse=True)[: max(1, min(limit, 50))]:
        index = text.lower().find(lowered)
        start = max(0, index - 160) if index >= 0 else 0
        excerpt = text[start : start + max_excerpt_chars]
        items.append(
            {
                "title": page_title(path, text),
                "page_id": wiki_page_id(path, root),
                "rel_path": path.resolve().relative_to(root.resolve()).as_posix(),
                "score": score,
                "excerpt": redact_text(excerpt, max_excerpt_chars),
            }
        )
    return {
        "query": query,
        "count": len(items),
        "items": items,
        "wiki": "available",
        "redacted": True,
        "includesLocalAbsolutePaths": False,
    }


def resolve_wiki_page(page: str) -> Path:
    root = wiki_root()
    page = page.strip().removeprefix("/")
    if not page:
        raise SystemExit("page is required")
    candidate = (root / page).resolve()
    if candidate.suffix != ".md":
        candidate = candidate.with_suffix(".md")
    if root.resolve() not in candidate.parents:
        raise SystemExit("page must stay inside HarzvaHub wiki root")
    if not candidate.exists():
        raise SystemExit(f"wiki page not found: {page}")
    return candidate


def wiki_page(page: str, max_chars: int = 3000) -> dict[str, Any]:
    root = wiki_root()
    path = resolve_wiki_page(page)
    text = path.read_text(encoding="utf-8")
    return {
        "page_id": wiki_page_id(path, root),
        "rel_path": path.resolve().relative_to(root.resolve()).as_posix(),
        "title": page_title(path, text),
        "content": redact_text(text, max_chars),
        "truncated": len(text) > max_chars,
        "redacted": True,
        "includesLocalAbsolutePaths": False,
    }


def llmwiki_status() -> dict[str, Any]:
    lookup = hub_path_lookup("llmwiki", limit=5)
    search = wiki_search("llmwiki", limit=5)
    return {
        "source_id": "llmwiki.local_project",
        "registered": bool(lookup.get("items")),
        "lookup": lookup,
        "wiki": {
            "available": search.get("wiki") == "available",
            "matches": search.get("count", 0),
            "items": search.get("items", []),
        },
        "policy": {
            "discovery": "harzvahub-only",
            "directFullRepoScan": False,
            "allowlistRequiredForContent": True,
            "redacted": True,
        },
        "redacted": True,
        "includesLocalAbsolutePaths": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="H.A.R.V.I.S. HarzvaHub adapter.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")
    path_parser = subparsers.add_parser("path")
    path_parser.add_argument("query")
    path_parser.add_argument("--limit", type=int, default=10)
    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("query")
    search_parser.add_argument("--limit", type=int, default=10)
    search_parser.add_argument("--max-excerpt-chars", type=int, default=360)
    page_parser = subparsers.add_parser("page")
    page_parser.add_argument("page")
    page_parser.add_argument("--max-chars", type=int, default=3000)
    subparsers.add_parser("llmwiki-status")
    args = parser.parse_args()

    if args.command == "status":
        result = hub_status()
    elif args.command == "path":
        result = hub_path_lookup(args.query, args.limit)
    elif args.command == "search":
        result = wiki_search(args.query, args.limit, args.max_excerpt_chars)
    elif args.command == "page":
        result = wiki_page(args.page, args.max_chars)
    else:
        result = llmwiki_status()
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("hub", legacy_main=main))
