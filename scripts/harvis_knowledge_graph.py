#!/usr/bin/env python3
"""Read-only Obsidian-style knowledge graph scanner for H.A.R.V.I.S."""

from __future__ import annotations

import argparse
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import unquote


GRAPH_VERSION = "v0.32-alpha"
DEFAULT_IGNORES = {
    ".git",
    ".obsidian",
    ".trash",
    ".harvis",
    "attachments",
    "adapters",
    "data",
    "logs",
    "models",
    "node_modules",
    "private",
    "runtime",
}
WIKI_LINK_RE = re.compile(r"(?<!!)\[\[([^\]\n]+)\]\]")
MARKDOWN_LINK_RE = re.compile(r"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)")
TAG_RE = re.compile(r"(?<![\w/])#([A-Za-z0-9_\-/]+)")
FRONTMATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*(?:\n|\Z)", re.DOTALL)

JSON = dict[str, Any]


@dataclass(frozen=True)
class GraphConfig:
    vaults: tuple[Path, ...]
    ignore_dirs: tuple[str, ...]
    max_files: int
    max_nodes: int
    max_edges: int
    include_paths: bool
    include_missing_targets: bool


class KnowledgeGraphError(Exception):
    """Raised when graph scanning cannot safely continue."""


def is_within_root(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def slugify(value: str) -> str:
    cleaned = re.sub(r"\s+", "-", value.strip().lower())
    cleaned = re.sub(r"[^a-z0-9._\-/]+", "-", cleaned)
    return cleaned.strip("-") or "node"


def split_csv(value: str) -> list[str]:
    return [item.strip().strip('"').strip("'") for item in value.split(",") if item.strip()]


def parse_scalar(value: str) -> Any:
    stripped = value.strip()
    lowered = stripped.lower()
    if lowered in {"true", "yes", "on"}:
        return True
    if lowered in {"false", "no", "off"}:
        return False
    if stripped.startswith("[") and stripped.endswith("]"):
        return split_csv(stripped[1:-1])
    if stripped.startswith('"') and stripped.endswith('"'):
        return stripped[1:-1]
    if stripped.startswith("'") and stripped.endswith("'"):
        return stripped[1:-1]
    try:
        return int(stripped)
    except ValueError:
        return stripped


def parse_simple_toml(path: Path) -> JSON:
    """Parse the small TOML subset needed for local graph config."""
    data: JSON = {}
    if not path.exists():
        return data
    current: JSON = data
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            current = data.setdefault(section, {})
            continue
        if "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        current[key.strip()] = parse_scalar(raw_value)
    return data


def list_of_strings(value: Any, default: list[str]) -> list[str]:
    if value is None:
        return default
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    return default


def int_value(value: Any, default: int, minimum: int, maximum: int) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return max(minimum, min(maximum, value))
    if isinstance(value, str) and value.strip():
        try:
            return max(minimum, min(maximum, int(value)))
        except ValueError:
            return default
    return default


def bool_value(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "on"}:
            return True
        if lowered in {"0", "false", "no", "off"}:
            return False
    return default


def resolve_config_path(root: Path, config_path: str | None = None) -> Path:
    if config_path:
        path = Path(config_path).expanduser()
        if not path.is_absolute():
            path = root / path
        return path.resolve()
    return (root / ".harvis" / "knowledge_graph.toml").resolve()


def load_graph_config(
    root: Path,
    config_path: str | None = None,
    vault_override: str | None = None,
    include_paths_override: bool | None = None,
    max_files_override: int | None = None,
    max_nodes_override: int | None = None,
) -> GraphConfig:
    resolved_config = resolve_config_path(root, config_path)
    if not is_within_root(resolved_config, root):
        raise KnowledgeGraphError(f"config path is outside workspace allowlist: {resolved_config}")
    parsed = parse_simple_toml(resolved_config)
    graph = parsed.get("graph", {}) if isinstance(parsed.get("graph"), dict) else {}
    raw_vaults = list_of_strings(graph.get("vaults"), [])
    if vault_override:
        raw_vaults = [vault_override]
    if not raw_vaults:
        raw_vaults = ["."]

    vaults: list[Path] = []
    for value in raw_vaults:
        path = Path(value).expanduser()
        if not path.is_absolute():
            path = root / path
        resolved = path.resolve()
        if not is_within_root(resolved, root):
            raise KnowledgeGraphError(f"vault is outside workspace allowlist: {resolved}")
        if not resolved.exists() or not resolved.is_dir():
            raise KnowledgeGraphError(f"vault does not exist or is not a directory: {resolved}")
        vaults.append(resolved)

    ignore_dirs = set(DEFAULT_IGNORES)
    ignore_dirs.update(list_of_strings(graph.get("ignore_dirs"), []))
    max_files = max(1, min(20000, max_files_override or int_value(graph.get("max_files"), 1000, 1, 20000)))
    max_nodes = max(1, min(20000, max_nodes_override or int_value(graph.get("max_nodes"), 1500, 1, 20000)))
    return GraphConfig(
        vaults=tuple(dict.fromkeys(vaults)),
        ignore_dirs=tuple(sorted(ignore_dirs)),
        max_files=max_files,
        max_nodes=max_nodes,
        max_edges=int_value(graph.get("max_edges"), 4000, 1, 100000),
        include_paths=include_paths_override if include_paths_override is not None else bool_value(graph.get("include_paths"), False),
        include_missing_targets=bool_value(graph.get("include_missing_targets"), True),
    )


def strip_frontmatter(text: str) -> tuple[str, JSON]:
    match = FRONTMATTER_RE.match(text)
    if not match:
        return text, {}
    metadata: JSON = {}
    for line in match.group(1).splitlines():
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        key = key.strip()
        if not key:
            continue
        metadata[key] = parse_scalar(raw)
    return text[match.end() :], metadata


def normalize_tag(tag: str) -> str:
    return tag.strip().strip("#").replace(" ", "-")


def is_probable_color_tag(tag: str) -> bool:
    return re.fullmatch(r"[0-9a-fA-F]{3}([0-9a-fA-F]{3})?([0-9a-fA-F]{2})?", tag.strip()) is not None


def body_tags(text: str) -> list[str]:
    return [normalize_tag(item) for item in TAG_RE.findall(text) if not is_probable_color_tag(item)]


def metadata_tags(metadata: JSON) -> list[str]:
    raw = metadata.get("tags") or metadata.get("tag")
    if isinstance(raw, str):
        return [normalize_tag(item) for item in re.split(r"[, ]+", raw) if item.strip()]
    if isinstance(raw, list):
        return [normalize_tag(str(item)) for item in raw if str(item).strip()]
    return []


def note_title(path: Path, metadata: JSON) -> str:
    title = metadata.get("title")
    if isinstance(title, str) and title.strip():
        return title.strip()
    return path.stem


def note_aliases(path: Path, metadata: JSON, workspace_path: str, vault_path: str) -> set[str]:
    aliases = {
        path.stem.lower(),
        path.name.lower(),
        workspace_path.removesuffix(".md").lower(),
        vault_path.removesuffix(".md").lower(),
    }
    raw_aliases = metadata.get("aliases") or metadata.get("alias")
    if isinstance(raw_aliases, str):
        aliases.add(raw_aliases.lower())
    elif isinstance(raw_aliases, list):
        aliases.update(str(item).lower() for item in raw_aliases if str(item).strip())
    title = metadata.get("title")
    if isinstance(title, str) and title.strip():
        aliases.add(title.lower())
    return aliases


def iter_markdown_files(vault: Path, ignore_dirs: set[str], limit: int) -> tuple[list[Path], list[str]]:
    files: list[Path] = []
    warnings: list[str] = []
    for path in sorted(vault.rglob("*.md")):
        if any(part in ignore_dirs for part in path.relative_to(vault).parts):
            continue
        files.append(path)
        if len(files) >= limit:
            warnings.append(f"max_files reached for {vault.name}: {limit}")
            break
    return files, warnings


def normalize_wiki_target(raw: str) -> str:
    target = raw.split("|", 1)[0].split("#", 1)[0].strip()
    return target.removesuffix(".md")


def normalize_markdown_target(raw: str) -> str | None:
    if raw.startswith(("http://", "https://", "mailto:", "#")):
        return None
    target = unquote(raw.split("#", 1)[0].strip())
    if not target or not target.endswith(".md"):
        return None
    return Path(target).stem


def edge_key(source: str, target: str, edge_type: str) -> str:
    return f"{source}->{target}:{edge_type}"


def scan_knowledge_graph(
    root: Path,
    config_path: str | None = None,
    vault_override: str | None = None,
    include_paths_override: bool | None = None,
    max_files_override: int | None = None,
    max_nodes_override: int | None = None,
) -> JSON:
    root = root.expanduser().resolve()
    started = time.time()
    config = load_graph_config(
        root,
        config_path=config_path,
        vault_override=vault_override,
        include_paths_override=include_paths_override,
        max_files_override=max_files_override,
        max_nodes_override=max_nodes_override,
    )
    warnings: list[str] = []
    errors: list[str] = []
    nodes: dict[str, JSON] = {}
    alias_index: dict[str, str] = {}
    pending_edges: list[tuple[str, str, str, str]] = []

    for vault in config.vaults:
        files, vault_warnings = iter_markdown_files(vault, set(config.ignore_dirs), config.max_files)
        warnings.extend(vault_warnings)
        for path in files:
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                text = path.read_text(encoding="utf-8", errors="replace")
                warnings.append(f"decoded with replacement: {path.name}")
            except OSError as exc:
                errors.append(f"read failed: {path.name}: {exc}")
                continue
            body, metadata = strip_frontmatter(text)
            rel = path.resolve().relative_to(root).as_posix()
            vault_rel = path.resolve().relative_to(vault).as_posix()
            node_id = f"note:{slugify(rel.removesuffix('.md'))}"
            tags = sorted(set(metadata_tags(metadata) + body_tags(body)))
            nodes[node_id] = {
                "id": node_id,
                "type": "note",
                "title": note_title(path, metadata),
                "tags": tags,
                "vault": vault.name,
                "workspace_path": rel if config.include_paths else None,
                "modified_at": int(path.stat().st_mtime),
                "size": path.stat().st_size,
                "in_degree": 0,
                "out_degree": 0,
            }
            for alias in note_aliases(path, metadata, rel, vault_rel):
                alias_index[alias] = node_id
            for tag in tags:
                tag_id = f"tag:{slugify(tag)}"
                nodes.setdefault(
                    tag_id,
                    {
                        "id": tag_id,
                        "type": "tag",
                        "title": f"#{tag}",
                        "tags": [],
                        "vault": vault.name,
                        "workspace_path": None,
                        "modified_at": None,
                        "size": 0,
                        "in_degree": 0,
                        "out_degree": 0,
                    },
                )
                pending_edges.append((node_id, tag_id, "tagged", tag))
            for raw in WIKI_LINK_RE.findall(body):
                target = normalize_wiki_target(raw)
                if target:
                    pending_edges.append((node_id, target.lower(), "wiki", target))
            for _label, raw in MARKDOWN_LINK_RE.findall(body):
                target = normalize_markdown_target(raw)
                if target:
                    pending_edges.append((node_id, target.lower(), "markdown", target))

    edges_by_key: dict[str, JSON] = {}
    for source_id, raw_target, edge_type, label in pending_edges:
        if len(edges_by_key) >= config.max_edges:
            warnings.append(f"max_edges reached: {config.max_edges}")
            break
        if edge_type in {"wiki", "markdown"}:
            target_id = alias_index.get(raw_target)
            if not target_id:
                if not config.include_missing_targets:
                    continue
                target_id = f"missing:{slugify(label)}"
                nodes.setdefault(
                    target_id,
                    {
                        "id": target_id,
                        "type": "missing",
                        "title": label,
                        "tags": [],
                        "vault": "",
                        "workspace_path": None,
                        "modified_at": None,
                        "size": 0,
                        "in_degree": 0,
                        "out_degree": 0,
                    },
                )
        else:
            target_id = raw_target
        key = edge_key(source_id, target_id, edge_type)
        edges_by_key.setdefault(
            key,
            {
                "source": source_id,
                "target": target_id,
                "type": edge_type,
                "label": label,
            },
        )

    if len(nodes) > config.max_nodes:
        note_nodes = [node for node in nodes.values() if node.get("type") == "note"]
        other_nodes = [node for node in nodes.values() if node.get("type") != "note"]
        kept = {node["id"]: node for node in (note_nodes + other_nodes)[: config.max_nodes]}
        nodes = kept
        edges_by_key = {
            key: edge
            for key, edge in edges_by_key.items()
            if edge["source"] in nodes and edge["target"] in nodes
        }
        warnings.append(f"max_nodes reached: {config.max_nodes}")

    for edge in edges_by_key.values():
        source = nodes.get(edge["source"])
        target = nodes.get(edge["target"])
        if source:
            source["out_degree"] = int(source.get("out_degree") or 0) + 1
        if target:
            target["in_degree"] = int(target.get("in_degree") or 0) + 1

    node_rows = sorted(nodes.values(), key=lambda node: (node.get("type") != "note", node.get("title") or ""))
    edge_rows = sorted(edges_by_key.values(), key=lambda edge: (edge["source"], edge["target"], edge["type"]))
    tag_counts: dict[str, int] = {}
    for node in node_rows:
        if node.get("type") != "note":
            continue
        for tag in node.get("tags", []):
            tag_counts[tag] = tag_counts.get(tag, 0) + 1

    return {
        "graph_version": GRAPH_VERSION,
        "workspace_root": str(root) if config.include_paths else None,
        "redacted": not config.include_paths,
        "includesLocalAbsolutePaths": bool(config.include_paths),
        "read_only": True,
        "source": {
            "kind": "obsidian-vault",
            "vault_count": len(config.vaults),
            "vaults": [
                {
                    "name": vault.name,
                    "workspace_path": vault.resolve().relative_to(root).as_posix() if is_within_root(vault, root) else None,
                }
                for vault in config.vaults
            ],
            "config_path": resolve_config_path(root, config_path).resolve().relative_to(root).as_posix()
            if is_within_root(resolve_config_path(root, config_path), root)
            else None,
        },
        "limits": {
            "max_files": config.max_files,
            "max_nodes": config.max_nodes,
            "max_edges": config.max_edges,
        },
        "stats": {
            "node_count": len(node_rows),
            "edge_count": len(edge_rows),
            "note_count": sum(1 for node in node_rows if node.get("type") == "note"),
            "tag_count": sum(1 for node in node_rows if node.get("type") == "tag"),
            "missing_count": sum(1 for node in node_rows if node.get("type") == "missing"),
            "tags": sorted(tag_counts.items(), key=lambda item: (-item[1], item[0]))[:50],
            "duration_ms": int((time.time() - started) * 1000),
        },
        "nodes": node_rows,
        "edges": edge_rows,
        "warnings": warnings,
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan an allowlisted local Obsidian vault into a read-only graph JSON.")
    parser.add_argument("--root", required=True, help="Workspace root.")
    parser.add_argument("--config", default="", help="Optional config path, default .harvis/knowledge_graph.toml.")
    parser.add_argument("--vault", default="", help="Optional vault path relative to root.")
    parser.add_argument("--include-paths", action="store_true", help="Include local absolute/workspace paths in output.")
    parser.add_argument("--max-files", type=int, default=0, help="Override max Markdown files.")
    parser.add_argument("--max-nodes", type=int, default=0, help="Override max graph nodes.")
    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        raise SystemExit(f"workspace root must exist: {root}")
    try:
        graph = scan_knowledge_graph(
            root,
            config_path=args.config or None,
            vault_override=args.vault or None,
            include_paths_override=True if args.include_paths else None,
            max_files_override=args.max_files or None,
            max_nodes_override=args.max_nodes or None,
        )
    except KnowledgeGraphError as exc:
        raise SystemExit(str(exc)) from exc
    print(json.dumps(graph, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("knowledge-graph", legacy_main=main))
