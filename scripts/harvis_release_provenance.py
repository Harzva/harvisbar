#!/usr/bin/env python3
"""Build and verify an allowlisted Harvis release stage.

The producer is deliberately install-free.  It reads committed blobs from a
clean Git ``HEAD`` via ``git ls-tree`` and ``git archive``, writes an isolated
stage outside the source repository, and emits only public-safe relative paths,
hashes, and sanitized toolchain versions.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = "harvis.release-provenance.v2"
PROVENANCE_FILE = "release-provenance-v2.json"
DEFAULT_ALLOWLIST = "packaging/plugin-stage-allowlist-v1.txt"
RELEASE_SCHEMA_FILE = "schemas/release-provenance-v2.schema.json"
PLUGIN_NAME = "harvis"
CACHE_NAMESPACE = "personal/harvis"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ROLE_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
BASE_VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.-]*$")
CACHE_TOKEN_RE = re.compile(r"^p2-[0-9a-f]{64}$")
EFFECTIVE_VERSION_RE = re.compile(
    r"^[0-9A-Za-z][0-9A-Za-z.-]*\+codex\.p2-[0-9a-f]{64}$"
)
_PRIVATE_POSIX_SEGMENTS = ("Users", "Volumes", "var/folders", "private/var/folders")
PRIVATE_PATH_RE = re.compile(
    r"(?:/(?:" + "|".join(_PRIVATE_POSIX_SEGMENTS) + r")/|[A-Za-z]:[\\/]Users[\\/])",
    re.IGNORECASE,
)
STAGE_DIGEST_ALGORITHM = "sha256(path\\0mode\\0size\\0sha256\\0\\n)"
STAGE_DIGEST_SCOPE = f"all files except {PROVENANCE_FILE}"
CACHE_PAYLOAD_SCOPE = "all final files with plugin manifest normalized to committed HEAD"
SAFETY_CONTRACT: dict[str, Any] = {
    "allowlistOnly": True,
    "containsAbsolutePaths": False,
    "installPerformed": False,
    "normalizedMtime": True,
    "outputGuard": "formal-cache-and-runtime-v1",
    "payloadPrivatePathScan": "all-stage-files-v1",
    "sourceKind": "clean-committed-head",
}


class ProvenanceError(RuntimeError):
    """Raised when release provenance cannot be proved safely."""


@dataclasses.dataclass(frozen=True)
class GitEntry:
    mode: str
    kind: str
    object_id: str
    path: str


@dataclasses.dataclass(frozen=True)
class ArtifactSpec:
    role: str
    source: Path
    destination: str


def _run(
    argv: Sequence[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    text: bool = False,
) -> subprocess.CompletedProcess[Any]:
    result = subprocess.run(
        list(argv),
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
        check=False,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() if text else result.stderr.decode("utf-8", "replace").strip()
        raise ProvenanceError(f"command failed: {argv[0]}: {detail or result.returncode}")
    return result


def _git(source: Path, *args: str, text: bool = True) -> str | bytes:
    result = _run(["git", "-C", str(source), *args], text=text)
    return result.stdout.strip() if text else result.stdout


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def _public_safe_relative_path(value: str, *, allow_directory: bool = False) -> str:
    if not value or "\x00" in value or "\\" in value or value.startswith("/"):
        raise ProvenanceError("path must be a non-empty POSIX relative path")
    trailing_slash = value.endswith("/")
    candidate = value[:-1] if trailing_slash else value
    parts = PurePosixPath(candidate).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise ProvenanceError(f"unsafe relative path: {value!r}")
    normalized = "/".join(parts)
    if trailing_slash:
        if not allow_directory:
            raise ProvenanceError(f"directory prefix is not allowed here: {value!r}")
        normalized += "/"
    return normalized


def _case_key(path: str) -> str:
    return unicodedata.normalize("NFC", path).casefold()


def _assert_no_case_collisions(paths: Iterable[str]) -> None:
    seen: dict[str, str] = {}
    for path in sorted(paths):
        key = _case_key(path)
        previous = seen.get(key)
        if previous is not None and previous != path:
            raise ProvenanceError(f"case/Unicode path collision: {previous!r} and {path!r}")
        seen[key] = path


def _repo_root(source: Path) -> Path:
    resolved = source.expanduser().resolve()
    top = Path(str(_git(resolved, "rev-parse", "--show-toplevel"))).resolve()
    if top != resolved:
        raise ProvenanceError("--source must be the Git repository root")
    return resolved


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _protected_output_roots() -> tuple[Path, ...]:
    home = Path.home().resolve()
    roots = (
        home / ".codex" / "plugins",
        home / ".harvis",
        home / ".local" / "share" / "harvis",
        home / "Library" / "Application Support" / "Harvis",
        home / "Library" / "LaunchAgents",
        Path("/Library/LaunchAgents"),
        Path("/Library/PrivilegedHelperTools"),
        Path("/Applications/Harvis.app"),
        Path("/usr/local/bin"),
        Path("/opt/homebrew/bin"),
    )
    return tuple(root.resolve(strict=False) for root in roots)


def _guard_output_path(source: Path, output: Path, *, extra_root: Path | None = None) -> Path:
    """Resolve and reject source, installed-cache, and formal-runtime outputs."""

    resolved = output.expanduser().resolve(strict=False)
    forbidden = [source.resolve(), *_protected_output_roots()]
    if extra_root is not None:
        forbidden.append(extra_root.resolve())
    if any(_is_relative_to(resolved, root) for root in forbidden):
        raise ProvenanceError("release output targets a protected source, cache, or runtime root")
    folded_parts = tuple(part.casefold() for part in resolved.parts)
    joined = "/".join(folded_parts)
    if (
        "/.codex/plugins/" in joined
        or "/.harvis/" in joined
        or "/library/launchagents/" in joined
        or "/application support/harvis/" in joined
    ):
        raise ProvenanceError("release output resembles a formal cache or runtime location")
    return resolved


def _require_clean(source: Path) -> None:
    dirty = str(
        _git(
            source,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignored=no",
        )
    )
    if dirty:
        count = len(dirty.splitlines())
        raise ProvenanceError(f"source worktree is not clean ({count} changed or untracked path(s))")


def _git_head(source: Path) -> tuple[str, str]:
    commit = str(_git(source, "rev-parse", "HEAD"))
    tree = str(_git(source, "rev-parse", "HEAD^{tree}"))
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit) or not re.fullmatch(
        r"[0-9a-f]{40,64}", tree
    ):
        raise ProvenanceError("Git returned an invalid commit or tree id")
    return commit, tree


def _allowlist_from_head(source: Path, allowlist: Path) -> tuple[str, bytes, list[str]]:
    resolved = allowlist.expanduser().resolve()
    try:
        relative = resolved.relative_to(source).as_posix()
    except ValueError as exc:
        raise ProvenanceError("allowlist must be a committed file inside the source repository") from exc
    relative = _public_safe_relative_path(relative)
    try:
        raw = bytes(_git(source, "show", f"HEAD:{relative}", text=False))
    except ProvenanceError as exc:
        raise ProvenanceError("allowlist is not present in committed HEAD") from exc
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ProvenanceError("allowlist must be UTF-8") from exc
    entries: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        try:
            normalized = _public_safe_relative_path(value, allow_directory=True)
        except ProvenanceError as exc:
            raise ProvenanceError(f"invalid allowlist line {line_number}: {exc}") from exc
        if normalized in entries:
            raise ProvenanceError(f"duplicate allowlist entry: {normalized}")
        entries.append(normalized)
    if not entries:
        raise ProvenanceError("allowlist selects no files")
    return relative, raw, entries


def _git_entries(source: Path) -> list[GitEntry]:
    raw = bytes(_git(source, "ls-tree", "-rz", "--full-tree", "HEAD", text=False))
    entries: list[GitEntry] = []
    for record in raw.split(b"\x00"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split(" ", 2)
            path = raw_path.decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise ProvenanceError("Git tree contains an unsupported entry") from exc
        entries.append(
            GitEntry(
                mode=mode,
                kind=kind,
                object_id=object_id,
                path=_public_safe_relative_path(path),
            )
        )
    return entries


def _select_entries(entries: Sequence[GitEntry], specs: Sequence[str]) -> list[GitEntry]:
    selected: dict[str, GitEntry] = {}
    for spec in specs:
        matches = [
            entry
            for entry in entries
            if (entry.path.startswith(spec) if spec.endswith("/") else entry.path == spec)
        ]
        if not matches:
            raise ProvenanceError(f"allowlist entry matches no committed file: {spec}")
        for entry in matches:
            selected[entry.path] = entry
    values = sorted(selected.values(), key=lambda item: item.path)
    _validate_selected_entries(values)
    return values


def _validate_selected_entries(entries: Sequence[GitEntry]) -> None:
    _assert_no_case_collisions(entry.path for entry in entries)
    for entry in entries:
        _public_safe_relative_path(entry.path)
        if entry.mode == "120000":
            raise ProvenanceError(f"symlink is forbidden in release stage: {entry.path}")
        if entry.mode == "160000" or entry.kind == "commit":
            raise ProvenanceError(f"submodule is forbidden in release stage: {entry.path}")
        if entry.kind != "blob" or entry.mode not in {"100644", "100755"}:
            raise ProvenanceError(
                f"unsupported Git entry mode/type for {entry.path}: {entry.mode}/{entry.kind}"
            )


def _archive_head(
    source: Path,
    specs: Sequence[str],
    selected: Sequence[GitEntry],
    destination: Path,
) -> None:
    archive_specs = [spec[:-1] if spec.endswith("/") else spec for spec in specs]
    selected_by_path = {entry.path: entry for entry in selected}
    archived: set[str] = set()
    with tempfile.NamedTemporaryFile(prefix="harvis-release-", suffix=".tar") as handle:
        result = subprocess.run(
            ["git", "-C", str(source), "archive", "--format=tar", "HEAD", "--", *archive_specs],
            stdout=handle,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", "replace").strip()
            raise ProvenanceError(f"git archive failed: {detail or result.returncode}")
        handle.flush()
        handle.seek(0)
        with tarfile.open(fileobj=handle, mode="r:") as archive:
            for member in archive.getmembers():
                if member.isdir():
                    continue
                path = _public_safe_relative_path(member.name)
                if path not in selected_by_path:
                    raise ProvenanceError(f"git archive emitted an unselected path: {path}")
                if not member.isfile() or member.issym() or member.islnk():
                    raise ProvenanceError(f"archive contains a non-regular file: {path}")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ProvenanceError(f"archive file is unreadable: {path}")
                target = destination / PurePosixPath(path)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(stream.read())
                mode = 0o755 if selected_by_path[path].mode == "100755" else 0o644
                target.chmod(mode)
                archived.add(path)
    expected = set(selected_by_path)
    if archived != expected:
        missing = len(expected - archived)
        extra = len(archived - expected)
        raise ProvenanceError(f"git archive selection mismatch (missing={missing}, extra={extra})")


def _file_record(root: Path, relative_path: str) -> dict[str, Any]:
    relative_path = _public_safe_relative_path(relative_path)
    path = root / PurePosixPath(relative_path)
    if path.is_symlink() or not path.is_file():
        raise ProvenanceError(f"stage entry is not a regular file: {relative_path}")
    mode = stat.S_IMODE(path.stat().st_mode)
    return {
        "relativePath": relative_path,
        "mode": f"{mode:04o}",
        "sizeBytes": path.stat().st_size,
        "sha256": _sha256_file(path),
    }


def _payload_digest(records: Sequence[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for record in sorted(records, key=lambda item: item["relativePath"]):
        for field in ("relativePath", "mode", "sizeBytes", "sha256"):
            digest.update(str(record[field]).encode("utf-8"))
            digest.update(b"\x00")
        digest.update(b"\n")
    return digest.hexdigest()


def _schema_input(root: Path, paths: Sequence[str]) -> dict[str, Any]:
    schema_paths = sorted(path for path in paths if path.startswith("schemas/") and path.endswith(".json"))
    if not schema_paths:
        raise ProvenanceError("release stage must contain at least one JSON schema")
    files: list[dict[str, str]] = []
    for relative in schema_paths:
        path = root / PurePosixPath(relative)
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProvenanceError(f"schema is not valid UTF-8 JSON: {relative}") from exc
        files.append({"relativePath": relative, "sha256": _sha256_file(path)})
    digest = hashlib.sha256()
    for item in files:
        digest.update(item["relativePath"].encode("utf-8"))
        digest.update(b"\x00")
        digest.update(item["sha256"].encode("ascii"))
        digest.update(b"\n")
    return {"count": len(files), "files": files, "setSha256": digest.hexdigest()}


def _workspace_version(cargo_toml: Path) -> str:
    current_section = ""
    section_re = re.compile(r"^\s*\[([^]]+)]\s*(?:#.*)?$")
    version_re = re.compile(r'^\s*version\s*=\s*"([^"]+)"\s*(?:#.*)?$')
    for line in cargo_toml.read_text(encoding="utf-8").splitlines():
        section = section_re.match(line)
        if section:
            current_section = section.group(1).strip()
            continue
        if current_section == "workspace.package":
            version = version_re.match(line)
            if version:
                return version.group(1)
    raise ProvenanceError("Cargo.toml has no [workspace.package] version")


def _sanitize_tool_output(output: str) -> str:
    normalized = "\n".join(line.rstrip() for line in output.strip().splitlines())
    if len(normalized) > 4096:
        raise ProvenanceError("toolchain version output is unexpectedly large")
    if normalized.startswith("/") or PRIVATE_PATH_RE.search(normalized):
        raise ProvenanceError("toolchain version output contains a private absolute path")
    return normalized


def _tool_version(argv: Sequence[str]) -> dict[str, Any]:
    try:
        result = _run(argv, check=False, text=True)
    except OSError:
        return {"available": False}
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        return {"available": False}
    return {"available": True, "version": _sanitize_tool_output(output)}


def capture_toolchain() -> dict[str, Any]:
    value: dict[str, Any] = {
        "commands": {
            "cargo": _tool_version(["cargo", "--version"]),
            "rustc": _tool_version(["rustc", "-Vv"]),
            "swift": _tool_version(["swift", "--version"]),
            "xcodebuild": _tool_version(["xcodebuild", "-version"]),
        },
        "python": {
            "implementation": platform.python_implementation(),
            "version": platform.python_version(),
        },
        "platform": {
            "architecture": platform.machine(),
            "release": platform.release(),
            "system": platform.system(),
        },
    }
    value["aggregateSha256"] = _sha256_bytes(_canonical_json(value))
    return value


def _validate_toolchain(value: dict[str, Any]) -> None:
    if not isinstance(value, dict) or set(value) != {
        "aggregateSha256",
        "commands",
        "platform",
        "python",
    }:
        raise ProvenanceError("toolchain shape is invalid")
    expected = dict(value)
    aggregate = expected.pop("aggregateSha256", None)
    if not isinstance(aggregate, str) or not SHA256_RE.fullmatch(aggregate):
        raise ProvenanceError("toolchain aggregate hash is invalid")
    if _sha256_bytes(_canonical_json(expected)) != aggregate:
        raise ProvenanceError("toolchain aggregate hash mismatch")
    commands = value.get("commands")
    if not isinstance(commands, dict) or set(commands) != {
        "cargo",
        "rustc",
        "swift",
        "xcodebuild",
    }:
        raise ProvenanceError("toolchain command set is invalid")
    for command in commands.values():
        if not isinstance(command, dict) or set(command) not in ({"available"}, {"available", "version"}):
            raise ProvenanceError("toolchain command shape is invalid")
        available = command.get("available")
        if not isinstance(available, bool):
            raise ProvenanceError("toolchain availability is invalid")
        if available:
            if set(command) != {"available", "version"} or not isinstance(command["version"], str):
                raise ProvenanceError("available toolchain command has no version")
            _sanitize_tool_output(command["version"])
        elif set(command) != {"available"}:
            raise ProvenanceError("unavailable toolchain command contains extra data")
    platform_value = value.get("platform")
    python_value = value.get("python")
    if not isinstance(platform_value, dict) or set(platform_value) != {
        "architecture",
        "release",
        "system",
    }:
        raise ProvenanceError("toolchain platform shape is invalid")
    if not isinstance(python_value, dict) or set(python_value) != {
        "implementation",
        "version",
    }:
        raise ProvenanceError("toolchain Python shape is invalid")
    if any(not isinstance(item, str) for item in platform_value.values()) or any(
        not isinstance(item, str) for item in python_value.values()
    ):
        raise ProvenanceError("toolchain identity contains a non-string value")
    _assert_public_safe(expected)


def _source_date_epoch(source: Path, explicit: int | None = None) -> int:
    if explicit is not None:
        epoch = explicit
    elif "SOURCE_DATE_EPOCH" in os.environ:
        try:
            epoch = int(os.environ["SOURCE_DATE_EPOCH"])
        except ValueError as exc:
            raise ProvenanceError("SOURCE_DATE_EPOCH must be an integer") from exc
    else:
        epoch = int(str(_git(source, "show", "-s", "--format=%ct", "HEAD")))
    if epoch < 0:
        raise ProvenanceError("SOURCE_DATE_EPOCH must not be negative")
    return epoch


def _timestamp(epoch: int) -> str:
    return dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _input_file(root: Path, relative_path: str) -> dict[str, Any]:
    record = _file_record(root, relative_path)
    return {
        "relativePath": record["relativePath"],
        "sha256": record["sha256"],
        "sizeBytes": record["sizeBytes"],
    }


def _plugin_manifest(stage: Path) -> tuple[dict[str, Any], str]:
    plugin_path = stage / ".codex-plugin" / "plugin.json"
    try:
        plugin = json.loads(plugin_path.read_text(encoding="utf-8"))
        name = plugin["name"]
        source_version = plugin["version"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise ProvenanceError("committed plugin manifest is invalid") from exc
    if name != PLUGIN_NAME:
        raise ProvenanceError("plugin manifest identity must be harvis")
    if not isinstance(source_version, str):
        raise ProvenanceError("plugin version is not cache-key safe")
    base_version = source_version.split("+", 1)[0]
    if not BASE_VERSION_RE.fullmatch(base_version):
        raise ProvenanceError("plugin base version is not cache-key safe")
    return plugin, base_version


def _cache_binding_material(
    *,
    commit: str,
    tree: str,
    base_version: str,
    cache_payload_sha256: str,
    artifacts: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "artifactRecords": list(artifacts),
        "baseVersion": base_version,
        "cachePayloadSha256": cache_payload_sha256,
        "pluginName": PLUGIN_NAME,
        "schemaVersion": SCHEMA_VERSION,
        "sourceCommit": commit,
        "sourceTree": tree,
    }


def _cache_binding_sha256(**kwargs: Any) -> str:
    return _sha256_bytes(_canonical_json(_cache_binding_material(**kwargs)))


def _effective_version(base_version: str, binding_sha256: str) -> str:
    if not BASE_VERSION_RE.fullmatch(base_version) or not SHA256_RE.fullmatch(binding_sha256):
        raise ProvenanceError("cache binding inputs are invalid")
    token = f"p2-{binding_sha256}"
    if not CACHE_TOKEN_RE.fullmatch(token):
        raise ProvenanceError("cache token is invalid")
    effective = f"{base_version}+codex.{token}"
    if not EFFECTIVE_VERSION_RE.fullmatch(effective) or effective.count("+codex.") != 1:
        raise ProvenanceError("effective plugin version is not a single Codex cachebuster")
    return effective


def _render_plugin_manifest(plugin: dict[str, Any], effective: str) -> bytes:
    rewritten = dict(plugin)
    rewritten["version"] = effective
    return (
        json.dumps(rewritten, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")


def _rewrite_plugin_version(stage: Path, plugin: dict[str, Any], effective: str) -> None:
    if plugin.get("name") != PLUGIN_NAME or not EFFECTIVE_VERSION_RE.fullmatch(effective):
        raise ProvenanceError("plugin identity or effective version is invalid")
    plugin_path = stage / ".codex-plugin" / "plugin.json"
    plugin["version"] = effective
    plugin_path.write_bytes(_render_plugin_manifest(plugin, effective))


def _artifact_records(stage: Path, specs: Sequence[ArtifactSpec]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    roles: set[str] = set()
    destinations: set[str] = set()
    for spec in specs:
        if not ROLE_RE.fullmatch(spec.role) or spec.role in roles:
            raise ProvenanceError(f"invalid or duplicate artifact role: {spec.role!r}")
        destination = _public_safe_relative_path(spec.destination)
        if not (destination.startswith("bin/") or destination.startswith("artifacts/")):
            raise ProvenanceError("artifact destination must be under bin/ or artifacts/")
        key = _case_key(destination)
        if key in destinations:
            raise ProvenanceError(f"duplicate artifact destination: {destination}")
        source = spec.source.expanduser()
        if source.is_symlink() or not source.is_file():
            raise ProvenanceError(f"artifact is not a regular file for role {spec.role}")
        target = stage / PurePosixPath(destination)
        if target.exists():
            raise ProvenanceError(f"artifact would overwrite staged source: {destination}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        source_mode = stat.S_IMODE(source.stat().st_mode)
        target.chmod(0o755 if source_mode & 0o111 else 0o644)
        record = _file_record(stage, destination)
        record["role"] = spec.role
        records.append(record)
        roles.add(spec.role)
        destinations.add(key)
    return sorted(records, key=lambda item: item["role"])


def _previous_release(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    try:
        raw = path.expanduser().read_bytes()
        previous = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProvenanceError("previous provenance is unreadable") from exc
    if not isinstance(previous, dict):
        raise ProvenanceError("previous provenance is not an object")
    _manifest_shape(previous)
    _assert_public_safe(previous)
    _validate_toolchain(previous["toolchain"])
    try:
        artifacts = [
            {"role": item["role"], "sha256": item["sha256"]}
            for item in previous.get("artifacts", [])
        ]
        value = {
            "artifactHashes": artifacts,
            "cacheKey": previous["cache"]["cacheKey"],
            "provenanceSha256": _sha256_bytes(raw),
            "sourceCommit": previous["source"]["commit"],
            "sourceTree": previous["source"]["tree"],
        }
    except (KeyError, TypeError) as exc:
        raise ProvenanceError("previous provenance is missing required fields") from exc
    _assert_public_safe(value)
    return value


def _stage_records(stage: Path) -> list[dict[str, Any]]:
    paths: list[str] = []
    for path in stage.rglob("*"):
        if path.is_symlink():
            raise ProvenanceError("stage contains a symlink")
        if path.is_file():
            relative = path.relative_to(stage).as_posix()
            if relative != PROVENANCE_FILE:
                paths.append(_public_safe_relative_path(relative))
        elif not path.is_dir():
            raise ProvenanceError("stage contains a non-regular filesystem entry")
    _assert_no_case_collisions(paths)
    return [_file_record(stage, path) for path in sorted(paths)]


def _stage_directories(stage: Path) -> set[str]:
    directories: set[str] = set()
    for path in stage.rglob("*"):
        if path.is_symlink():
            raise ProvenanceError("stage contains a symlink")
        if path.is_dir():
            directories.add(_public_safe_relative_path(path.relative_to(stage).as_posix()))
    _assert_no_case_collisions(directories)
    return directories


def _parent_directories(paths: Iterable[str]) -> set[str]:
    directories: set[str] = set()
    for value in paths:
        parent = PurePosixPath(value).parent
        while parent != PurePosixPath("."):
            directories.add(parent.as_posix())
            parent = parent.parent
    return directories


def _private_payload_markers(additional_roots: Sequence[Path] = ()) -> tuple[bytes, ...]:
    roots = [Path.home(), Path(tempfile.gettempdir()), *additional_roots]
    for parent in (Path("/Users"), Path("/home"), Path("/Volumes")):
        if parent.is_dir():
            try:
                roots.extend(path for path in parent.iterdir() if path.is_dir())
            except OSError:
                pass
    markers: set[bytes] = set()
    for root in roots:
        expanded = root.expanduser()
        renderings = {
            str(expanded.absolute()).rstrip("/\\"),
            str(expanded.resolve(strict=False)).rstrip("/\\"),
        }
        for rendered in renderings:
            if not rendered:
                continue
            markers.add((rendered + os.sep).encode("utf-8").lower())
            markers.add((rendered.replace("\\", "/") + "/").encode("utf-8").lower())
    return tuple(sorted(markers))


def _assert_payload_public_safe(
    stage: Path,
    *,
    include_provenance: bool,
    additional_private_roots: Sequence[Path] = (),
) -> None:
    markers = _private_payload_markers(additional_private_roots)
    tail_size = max((len(marker) for marker in markers), default=1) - 1
    for path in sorted(stage.rglob("*")):
        if path.is_symlink():
            raise ProvenanceError("stage contains a symlink")
        if not path.is_file():
            continue
        if not include_provenance and path.name == PROVENANCE_FILE:
            continue
        with path.open("rb") as handle:
            tail = b""
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                inspected = (tail + chunk).lower()
                if any(marker in inspected for marker in markers):
                    relative = path.relative_to(stage).as_posix()
                    raise ProvenanceError(
                        f"staged payload contains a private absolute path: {relative}"
                    )
                tail = inspected[-tail_size:] if tail_size else b""


def _normalize_stage_mtime(stage: Path, epoch: int) -> None:
    nanoseconds = epoch * 1_000_000_000
    paths = sorted(stage.rglob("*"), key=lambda item: len(item.parts), reverse=True)
    for path in paths:
        if path.is_symlink():
            raise ProvenanceError("stage contains a symlink")
        os.utime(path, ns=(nanoseconds, nanoseconds), follow_symlinks=False)
    os.utime(stage, ns=(nanoseconds, nanoseconds), follow_symlinks=False)


def _verify_stage_mtime(stage: Path, epoch: int) -> None:
    expected = epoch * 1_000_000_000
    for path in [stage, *stage.rglob("*")]:
        if path.is_symlink():
            raise ProvenanceError("stage contains a symlink")
        if path.stat().st_mtime_ns != expected:
            raise ProvenanceError("stage mtime normalization mismatch")


def _assert_public_safe(value: Any) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise ProvenanceError("manifest contains a non-string key")
            _assert_public_safe(item)
    elif isinstance(value, list):
        for item in value:
            _assert_public_safe(item)
    elif isinstance(value, str):
        if "\x00" in value or value.startswith("~") or value.startswith("file://"):
            raise ProvenanceError("manifest contains a non-public-safe string")
        if value.startswith("/") or PRIVATE_PATH_RE.search(value):
            raise ProvenanceError("manifest contains a private absolute path")


def _require_exact_keys(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ProvenanceError(f"{label} has an invalid shape")
    return value


def _require_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise ProvenanceError(f"{label} is not a SHA-256 value")
    return value


def _validate_input_record(value: Any, expected_path: str, label: str) -> None:
    record = _require_exact_keys(value, {"relativePath", "sha256", "sizeBytes"}, label)
    if record["relativePath"] != expected_path:
        raise ProvenanceError(f"{label} has an unexpected path")
    if not isinstance(record["sizeBytes"], int) or isinstance(record["sizeBytes"], bool) or record["sizeBytes"] < 0:
        raise ProvenanceError(f"{label} has an invalid size")
    _require_sha256(record["sha256"], f"{label} hash")


def _validate_artifact_record(value: Any) -> None:
    record = _require_exact_keys(
        value,
        {"mode", "relativePath", "role", "sha256", "sizeBytes"},
        "artifact record",
    )
    role = record["role"]
    relative = record["relativePath"]
    if not isinstance(role, str) or not ROLE_RE.fullmatch(role):
        raise ProvenanceError("artifact role is invalid")
    if not isinstance(relative, str):
        raise ProvenanceError("artifact path is invalid")
    relative = _public_safe_relative_path(relative)
    if not (relative.startswith("bin/") or relative.startswith("artifacts/")):
        raise ProvenanceError("artifact path is outside the artifact roots")
    if record["mode"] not in {"0644", "0755"}:
        raise ProvenanceError("artifact mode is invalid")
    if not isinstance(record["sizeBytes"], int) or isinstance(record["sizeBytes"], bool) or record["sizeBytes"] < 0:
        raise ProvenanceError("artifact size is invalid")
    _require_sha256(record["sha256"], "artifact hash")


def _manifest_shape(manifest: dict[str, Any]) -> None:
    required = {
        "schemaVersion",
        "generatedAt",
        "sourceDateEpoch",
        "source",
        "inputs",
        "toolchain",
        "stage",
        "cache",
        "artifacts",
        "previousRelease",
        "safety",
    }
    if not isinstance(manifest, dict) or set(manifest) != required:
        raise ProvenanceError("provenance manifest has an invalid top-level shape")
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise ProvenanceError("provenance schema identity is invalid")
    epoch = manifest["sourceDateEpoch"]
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise ProvenanceError("sourceDateEpoch is invalid")
    if manifest["generatedAt"] != _timestamp(epoch):
        raise ProvenanceError("generatedAt does not match sourceDateEpoch")

    source = _require_exact_keys(
        manifest["source"],
        {"clean", "commit", "repositoryId", "tree", "workspaceVersion"},
        "source",
    )
    if source["clean"] is not True or source["repositoryId"] != PLUGIN_NAME:
        raise ProvenanceError("release source identity is invalid")
    if not isinstance(source["workspaceVersion"], str) or not BASE_VERSION_RE.fullmatch(source["workspaceVersion"]):
        raise ProvenanceError("workspace version is invalid")
    for field in (source["commit"], source["tree"]):
        if not isinstance(field, str) or not re.fullmatch(r"[0-9a-f]{40,64}", field):
            raise ProvenanceError("provenance source identity is invalid")

    inputs = _require_exact_keys(
        manifest["inputs"],
        {"allowlist", "cargoLock", "pluginManifest", "schemaSet", "swiftPackage"},
        "inputs",
    )
    allowlist = _require_exact_keys(inputs["allowlist"], {"relativePath", "sha256"}, "allowlist input")
    if allowlist["relativePath"] != DEFAULT_ALLOWLIST:
        raise ProvenanceError("allowlist identity is invalid")
    _require_sha256(allowlist["sha256"], "allowlist hash")
    _validate_input_record(inputs["cargoLock"], "Cargo.lock", "Cargo.lock input")
    _validate_input_record(
        inputs["pluginManifest"], ".codex-plugin/plugin.json", "plugin manifest input"
    )
    _validate_input_record(
        inputs["swiftPackage"], "apps/HarvisBar/Package.swift", "Swift package input"
    )
    schema_set = _require_exact_keys(
        inputs["schemaSet"], {"count", "files", "setSha256"}, "schema set"
    )
    files = schema_set["files"]
    if not isinstance(files, list) or not files or schema_set["count"] != len(files):
        raise ProvenanceError("schema set count is invalid")
    schema_paths: list[str] = []
    for item in files:
        schema_file = _require_exact_keys(item, {"relativePath", "sha256"}, "schema file")
        relative = schema_file["relativePath"]
        if not isinstance(relative, str) or not relative.startswith("schemas/") or not relative.endswith(".json"):
            raise ProvenanceError("schema set contains an invalid path")
        schema_paths.append(_public_safe_relative_path(relative))
        _require_sha256(schema_file["sha256"], "schema file hash")
    if schema_paths != sorted(set(schema_paths)) or RELEASE_SCHEMA_FILE not in schema_paths:
        raise ProvenanceError("schema set is incomplete, duplicated, or unsorted")
    _require_sha256(schema_set["setSha256"], "schema set hash")

    stage = _require_exact_keys(
        manifest["stage"],
        {
            "cachePayloadScope",
            "cachePayloadSha256",
            "digestAlgorithm",
            "digestScope",
            "fileCount",
            "inputPayloadSha256",
            "stagedPayloadSha256",
        },
        "stage",
    )
    if stage["digestAlgorithm"] != STAGE_DIGEST_ALGORITHM or stage["digestScope"] != STAGE_DIGEST_SCOPE:
        raise ProvenanceError("stage digest contract is invalid")
    if stage["cachePayloadScope"] != CACHE_PAYLOAD_SCOPE:
        raise ProvenanceError("cache payload scope is invalid")
    if not isinstance(stage["fileCount"], int) or isinstance(stage["fileCount"], bool) or stage["fileCount"] < 1:
        raise ProvenanceError("stage file count is invalid")
    for key in ("cachePayloadSha256", "inputPayloadSha256", "stagedPayloadSha256"):
        _require_sha256(stage[key], f"stage {key}")

    cache = _require_exact_keys(
        manifest["cache"],
        {"baseVersion", "bindingSha256", "cacheKey", "effectiveVersion", "namespace"},
        "cache",
    )
    if not isinstance(cache["baseVersion"], str) or not BASE_VERSION_RE.fullmatch(cache["baseVersion"]):
        raise ProvenanceError("cache base version is invalid")
    _require_sha256(cache["bindingSha256"], "cache binding")
    expected_effective = _effective_version(cache["baseVersion"], cache["bindingSha256"])
    if cache["effectiveVersion"] != expected_effective:
        raise ProvenanceError("effective version does not match the cache binding")
    if cache["namespace"] != CACHE_NAMESPACE or cache["cacheKey"] != f"{CACHE_NAMESPACE}/{expected_effective}":
        raise ProvenanceError("cache namespace or key identity is invalid")

    artifacts = manifest["artifacts"]
    if not isinstance(artifacts, list):
        raise ProvenanceError("artifacts is not an array")
    for artifact in artifacts:
        _validate_artifact_record(artifact)
    roles = [item["role"] for item in artifacts]
    destinations = [item["relativePath"] for item in artifacts]
    if roles != sorted(set(roles)) or len({_case_key(path) for path in destinations}) != len(destinations):
        raise ProvenanceError("artifact identities are duplicated or unsorted")

    previous = manifest["previousRelease"]
    if previous is not None:
        previous = _require_exact_keys(
            previous,
            {"artifactHashes", "cacheKey", "provenanceSha256", "sourceCommit", "sourceTree"},
            "previous release",
        )
        if not isinstance(previous["artifactHashes"], list) or not isinstance(previous["cacheKey"], str):
            raise ProvenanceError("previous release identity is invalid")
        _require_sha256(previous["provenanceSha256"], "previous provenance hash")
        for key in ("sourceCommit", "sourceTree"):
            if not isinstance(previous[key], str) or not re.fullmatch(r"[0-9a-f]{40,64}", previous[key]):
                raise ProvenanceError("previous source identity is invalid")
        previous_roles: list[str] = []
        for item in previous["artifactHashes"]:
            item = _require_exact_keys(item, {"role", "sha256"}, "previous artifact hash")
            if not isinstance(item["role"], str) or not ROLE_RE.fullmatch(item["role"]):
                raise ProvenanceError("previous artifact role is invalid")
            _require_sha256(item["sha256"], "previous artifact hash")
            previous_roles.append(item["role"])
        if previous_roles != sorted(set(previous_roles)):
            raise ProvenanceError("previous artifact roles are duplicated or unsorted")

    if manifest["safety"] != SAFETY_CONTRACT:
        raise ProvenanceError("release safety contract is invalid")


def create_stage(
    source: Path,
    output: Path,
    *,
    allowlist: Path | None = None,
    artifacts: Sequence[ArtifactSpec] = (),
    previous_provenance: Path | None = None,
    source_date_epoch: int | None = None,
    toolchain_override: dict[str, Any] | None = None,
) -> dict[str, Any]:
    source = _repo_root(source)
    _require_clean(source)
    output = _guard_output_path(source, output)
    if output.exists():
        raise ProvenanceError("release stage output already exists")
    if not output.parent.is_dir():
        raise ProvenanceError("release stage parent directory does not exist")

    commit, tree = _git_head(source)
    allowlist = allowlist or (source / DEFAULT_ALLOWLIST)
    allowlist_relative, allowlist_raw, specs = _allowlist_from_head(source, allowlist)
    all_entries = _git_entries(source)
    selected = _select_entries(all_entries, specs)
    selected_paths = [entry.path for entry in selected]
    all_schema_paths = sorted(
        entry.path
        for entry in all_entries
        if entry.kind == "blob" and entry.path.startswith("schemas/") and entry.path.endswith(".json")
    )
    selected_schema_paths = sorted(path for path in selected_paths if path in all_schema_paths)
    if selected_schema_paths != all_schema_paths:
        raise ProvenanceError("allowlist must include every committed schemas/*.json file")
    if RELEASE_SCHEMA_FILE not in selected_schema_paths:
        raise ProvenanceError("release provenance schema is missing from committed HEAD")
    for required in (
        ".codex-plugin/plugin.json",
        "Cargo.toml",
        "Cargo.lock",
        "apps/HarvisBar/Package.swift",
    ):
        if required not in selected_paths:
            raise ProvenanceError(f"allowlist is missing required provenance input: {required}")

    epoch = _source_date_epoch(source, source_date_epoch)
    toolchain = toolchain_override if toolchain_override is not None else capture_toolchain()
    if "aggregateSha256" not in toolchain:
        toolchain = dict(toolchain)
        toolchain["aggregateSha256"] = _sha256_bytes(_canonical_json(toolchain))
    _validate_toolchain(toolchain)
    previous = _previous_release(previous_provenance)

    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.stage-", dir=output.parent))
    try:
        _archive_head(source, specs, selected, temporary)
        source_records = [_file_record(temporary, path) for path in selected_paths]
        input_payload = _payload_digest(source_records)
        plugin_input = _input_file(temporary, ".codex-plugin/plugin.json")
        cargo_input = _input_file(temporary, "Cargo.lock")
        swift_input = _input_file(temporary, "apps/HarvisBar/Package.swift")
        schemas = _schema_input(temporary, selected_paths)
        workspace_version = _workspace_version(temporary / "Cargo.toml")
        plugin, base_version = _plugin_manifest(temporary)
        artifact_records = _artifact_records(temporary, artifacts)
        cache_payload = _payload_digest(_stage_records(temporary))
        binding_sha256 = _cache_binding_sha256(
            commit=commit,
            tree=tree,
            base_version=base_version,
            cache_payload_sha256=cache_payload,
            artifacts=artifact_records,
        )
        effective_version = _effective_version(base_version, binding_sha256)
        _rewrite_plugin_version(temporary, plugin, effective_version)
        final_records = _stage_records(temporary)
        staged_payload = _payload_digest(final_records)
        cache_key = f"{CACHE_NAMESPACE}/{effective_version}"
        if previous is not None and previous["cacheKey"] == cache_key:
            raise ProvenanceError("previous release cache key equals the current cache key")

        _assert_payload_public_safe(
            temporary, include_provenance=False, additional_private_roots=(source,)
        )

        manifest: dict[str, Any] = {
            "schemaVersion": SCHEMA_VERSION,
            "generatedAt": _timestamp(epoch),
            "sourceDateEpoch": epoch,
            "source": {
                "clean": True,
                "commit": commit,
                "repositoryId": PLUGIN_NAME,
                "tree": tree,
                "workspaceVersion": workspace_version,
            },
            "inputs": {
                "allowlist": {
                    "relativePath": allowlist_relative,
                    "sha256": _sha256_bytes(allowlist_raw),
                },
                "cargoLock": cargo_input,
                "pluginManifest": plugin_input,
                "schemaSet": schemas,
                "swiftPackage": swift_input,
            },
            "toolchain": toolchain,
            "stage": {
                "cachePayloadScope": CACHE_PAYLOAD_SCOPE,
                "cachePayloadSha256": cache_payload,
                "digestAlgorithm": STAGE_DIGEST_ALGORITHM,
                "digestScope": STAGE_DIGEST_SCOPE,
                "fileCount": len(final_records),
                "inputPayloadSha256": input_payload,
                "stagedPayloadSha256": staged_payload,
            },
            "cache": {
                "baseVersion": base_version,
                "bindingSha256": binding_sha256,
                "cacheKey": cache_key,
                "effectiveVersion": effective_version,
                "namespace": CACHE_NAMESPACE,
            },
            "artifacts": artifact_records,
            "previousRelease": previous,
            "safety": dict(SAFETY_CONTRACT),
        }
        _manifest_shape(manifest)
        _assert_public_safe(manifest)
        (temporary / PROVENANCE_FILE).write_text(
            json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        _assert_payload_public_safe(
            temporary, include_provenance=True, additional_private_roots=(source,)
        )
        _normalize_stage_mtime(temporary, epoch)
        provenance_sha256 = _sha256_file(temporary / PROVENANCE_FILE)
        verify_stage(
            temporary,
            source=source,
            expected_provenance_sha256=provenance_sha256,
            expected_artifacts=artifact_records,
        )
        os.replace(temporary, output)
        return manifest
    except BaseException:
        if temporary.exists():
            shutil.rmtree(temporary)
        raise


def _verify_input_file(stage: Path, value: dict[str, Any]) -> None:
    relative = value.get("relativePath")
    if not isinstance(relative, str):
        raise ProvenanceError("provenance input has no relativePath")
    actual = _input_file(stage, relative)
    if actual != value:
        raise ProvenanceError(f"provenance input hash mismatch: {relative}")


def _source_records(source: Path, selected: Sequence[GitEntry]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for entry in selected:
        data = bytes(_git(source, "cat-file", "blob", entry.object_id, text=False))
        records.append(
            {
                "relativePath": entry.path,
                "mode": "0755" if entry.mode == "100755" else "0644",
                "sizeBytes": len(data),
                "sha256": _sha256_bytes(data),
            }
        )
    return records


def verify_stage(
    stage: Path,
    *,
    source: Path,
    expected_provenance_sha256: str | None = None,
    expected_artifacts: Sequence[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    stage = stage.expanduser().resolve()
    manifest_path = stage / PROVENANCE_FILE
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ProvenanceError("stage provenance manifest is missing")
    try:
        manifest_raw = manifest_path.read_bytes()
        manifest = json.loads(manifest_raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProvenanceError("stage provenance manifest is invalid") from exc
    if expected_provenance_sha256 is None:
        raise ProvenanceError("verification requires an external provenance hash trust anchor")
    _require_sha256(expected_provenance_sha256, "expected provenance hash")
    if _sha256_bytes(manifest_raw) != expected_provenance_sha256:
        raise ProvenanceError("provenance trust-anchor hash mismatch")
    _manifest_shape(manifest)
    _assert_public_safe(manifest)
    _validate_toolchain(manifest["toolchain"])
    _assert_payload_public_safe(
        stage, include_provenance=True, additional_private_roots=(source,)
    )
    _verify_stage_mtime(stage, manifest["sourceDateEpoch"])

    source = _repo_root(source)
    _require_clean(source)
    commit, tree = _git_head(source)
    if commit != manifest["source"]["commit"] or tree != manifest["source"]["tree"]:
        raise ProvenanceError("source commit/tree does not match staged provenance")
    allowlist_relative = manifest["inputs"]["allowlist"]["relativePath"]
    relative, raw, specs = _allowlist_from_head(source, source / allowlist_relative)
    if relative != allowlist_relative or _sha256_bytes(raw) != manifest["inputs"]["allowlist"]["sha256"]:
        raise ProvenanceError("source allowlist hash mismatch")
    all_entries = _git_entries(source)
    entries = _select_entries(all_entries, specs)
    selected_paths = [entry.path for entry in entries]
    source_schema_paths = sorted(
        entry.path
        for entry in all_entries
        if entry.kind == "blob" and entry.path.startswith("schemas/") and entry.path.endswith(".json")
    )
    if sorted(path for path in selected_paths if path in source_schema_paths) != source_schema_paths:
        raise ProvenanceError("source allowlist does not cover the complete schema set")
    if RELEASE_SCHEMA_FILE not in source_schema_paths:
        raise ProvenanceError("source release provenance schema is missing")

    records = _stage_records(stage)
    if len(records) != manifest["stage"]["fileCount"]:
        raise ProvenanceError("stage file count mismatch")
    if _payload_digest(records) != manifest["stage"]["stagedPayloadSha256"]:
        raise ProvenanceError("staged payload hash mismatch")

    artifacts = manifest["artifacts"]
    if expected_artifacts is not None and list(expected_artifacts) != artifacts:
        raise ProvenanceError("artifact trust anchor does not match provenance")
    artifact_paths = [item["relativePath"] for item in artifacts]
    expected_paths = set(selected_paths) | set(artifact_paths)
    actual_paths = {item["relativePath"] for item in records}
    if actual_paths != expected_paths:
        raise ProvenanceError("stage inventory contains a missing or rogue self-reported file")
    if _stage_directories(stage) != _parent_directories(expected_paths):
        raise ProvenanceError("stage inventory contains a missing or rogue directory")

    for key in ("cargoLock", "swiftPackage"):
        _verify_input_file(stage, manifest["inputs"][key])
    schema_value = manifest["inputs"]["schemaSet"]
    schema_paths = [item["relativePath"] for item in schema_value["files"]]
    if _schema_input(stage, schema_paths) != schema_value:
        raise ProvenanceError("schema set hash mismatch")

    source_records = _source_records(source, entries)
    source_by_path = {item["relativePath"]: item for item in source_records}
    if _payload_digest(source_records) != manifest["stage"]["inputPayloadSha256"]:
        raise ProvenanceError("source payload hash mismatch")
    for key in ("cargoLock", "pluginManifest", "swiftPackage"):
        expected = manifest["inputs"][key]
        record = source_by_path.get(expected["relativePath"])
        if record is None:
            raise ProvenanceError(f"source input is missing: {key}")
        actual_input = {
            "relativePath": record["relativePath"],
            "sha256": record["sha256"],
            "sizeBytes": record["sizeBytes"],
        }
        if actual_input != expected:
            raise ProvenanceError(f"source input mismatch: {key}")
    if _schema_input(source, source_schema_paths) != schema_value:
        raise ProvenanceError("source schema set does not match provenance")

    record_by_path = {item["relativePath"]: item for item in records}
    plugin_relative = ".codex-plugin/plugin.json"
    for relative_path, source_record in source_by_path.items():
        if relative_path == plugin_relative:
            continue
        if record_by_path.get(relative_path) != source_record:
            raise ProvenanceError(f"staged committed file differs from HEAD: {relative_path}")

    plugin_path = stage / ".codex-plugin" / "plugin.json"
    try:
        plugin = json.loads(plugin_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProvenanceError("staged plugin manifest is invalid") from exc
    plugin_entry = next(entry for entry in entries if entry.path == plugin_relative)
    source_plugin_raw = bytes(_git(source, "cat-file", "blob", plugin_entry.object_id, text=False))
    try:
        source_plugin = json.loads(source_plugin_raw)
        source_name = source_plugin["name"]
        source_version = source_plugin["version"]
    except (KeyError, TypeError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProvenanceError("committed plugin manifest is invalid") from exc
    cache = manifest["cache"]
    if source_name != PLUGIN_NAME or not isinstance(source_version, str):
        raise ProvenanceError("committed plugin identity is invalid")
    if source_version.split("+", 1)[0] != cache["baseVersion"]:
        raise ProvenanceError("cache base version differs from committed plugin manifest")
    expected_effective = _effective_version(cache["baseVersion"], cache["bindingSha256"])
    if plugin.get("name") != PLUGIN_NAME or plugin.get("version") != expected_effective:
        raise ProvenanceError("staged plugin identity/version does not match the cache binding")
    if plugin_path.read_bytes() != _render_plugin_manifest(source_plugin, expected_effective):
        raise ProvenanceError("staged plugin manifest is not the deterministic HEAD rewrite")

    cache_records = list(records)
    plugin_index = next(
        index for index, item in enumerate(cache_records) if item["relativePath"] == plugin_relative
    )
    cache_records[plugin_index] = source_by_path[plugin_relative]
    cache_payload_sha256 = _payload_digest(cache_records)
    if cache_payload_sha256 != manifest["stage"]["cachePayloadSha256"]:
        raise ProvenanceError("cache-bound payload hash mismatch")

    roles: set[str] = set()
    for artifact in artifacts:
        role = artifact.get("role")
        if not isinstance(role, str) or not ROLE_RE.fullmatch(role) or role in roles:
            raise ProvenanceError("artifact role is invalid or duplicated")
        expected = dict(artifact)
        expected.pop("role")
        actual = _file_record(stage, artifact["relativePath"])
        if actual != expected:
            raise ProvenanceError(f"artifact hash mismatch for role {role}")
        roles.add(role)

    binding_sha256 = _cache_binding_sha256(
        commit=commit,
        tree=tree,
        base_version=cache["baseVersion"],
        cache_payload_sha256=cache_payload_sha256,
        artifacts=artifacts,
    )
    if binding_sha256 != cache["bindingSha256"]:
        raise ProvenanceError("cache key is not bound to source, artifacts, and final payload")

    return manifest


def write_deterministic_tar(
    stage: Path,
    output: Path,
    *,
    source: Path,
    expected_provenance_sha256: str,
) -> str:
    """Write a byte-reproducible uncompressed tar from a verified stage."""

    source = _repo_root(source)
    stage = stage.expanduser().resolve()
    manifest = verify_stage(
        stage,
        source=source,
        expected_provenance_sha256=expected_provenance_sha256,
    )
    output = _guard_output_path(source, output, extra_root=stage)
    if output.exists():
        raise ProvenanceError("release tar output already exists")
    if not output.parent.is_dir():
        raise ProvenanceError("release tar parent directory does not exist")

    descriptors: list[tuple[str, Path, bool]] = []
    for path in stage.rglob("*"):
        if path.is_symlink():
            raise ProvenanceError("stage contains a symlink")
        relative = _public_safe_relative_path(path.relative_to(stage).as_posix())
        if path.is_dir():
            descriptors.append((relative, path, True))
        elif path.is_file():
            descriptors.append((relative, path, False))
        else:
            raise ProvenanceError("stage contains a non-regular filesystem entry")
    descriptors.sort(key=lambda item: item[0])

    handle = tempfile.NamedTemporaryFile(
        prefix=f".{output.name}.tmp-", dir=output.parent, delete=False
    )
    temporary = Path(handle.name)
    handle.close()
    try:
        with temporary.open("wb") as stream, tarfile.open(
            fileobj=stream, mode="w", format=tarfile.GNU_FORMAT
        ) as archive:
            for relative, path, is_directory in descriptors:
                name = f"{relative}/" if is_directory else relative
                info = tarfile.TarInfo(name=name)
                info.mtime = manifest["sourceDateEpoch"]
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                if is_directory:
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.size = 0
                    archive.addfile(info)
                else:
                    info.type = tarfile.REGTYPE
                    info.mode = stat.S_IMODE(path.stat().st_mode)
                    info.size = path.stat().st_size
                    with path.open("rb") as payload:
                        archive.addfile(info, payload)
        os.replace(temporary, output)
    except BaseException:
        if temporary.exists():
            temporary.unlink()
        raise
    return _sha256_file(output)


def _artifact_argument(values: Sequence[str]) -> ArtifactSpec:
    role, source, destination = values
    return ArtifactSpec(role=role, source=Path(source), destination=destination)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    stage = subparsers.add_parser("stage", help="Create an isolated allowlisted stage from clean HEAD.")
    stage.add_argument("--source", default=str(Path(__file__).resolve().parents[1]))
    stage.add_argument("--output", required=True)
    stage.add_argument("--allowlist", default="")
    stage.add_argument("--artifact", action="append", nargs=3, default=[], metavar=("ROLE", "SOURCE", "DEST"))
    stage.add_argument("--previous-provenance", default="")
    stage.add_argument("--source-date-epoch", type=int)
    stage.add_argument("--tar-output", default="")

    verify = subparsers.add_parser("verify", help="Verify an existing stage without installing it.")
    verify.add_argument("--stage", required=True)
    verify.add_argument("--source", required=True)
    verify.add_argument("--provenance-sha256", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "stage":
            source = Path(args.source)
            allowlist = Path(args.allowlist) if args.allowlist else None
            if args.tar_output:
                _guard_output_path(_repo_root(source), Path(args.tar_output))
            manifest = create_stage(
                source,
                Path(args.output),
                allowlist=allowlist,
                artifacts=[_artifact_argument(value) for value in args.artifact],
                previous_provenance=(
                    Path(args.previous_provenance) if args.previous_provenance else None
                ),
                source_date_epoch=args.source_date_epoch,
            )
            stage_path = Path(args.output)
            provenance_sha256 = _sha256_file(stage_path / PROVENANCE_FILE)
            tar_sha256 = None
            if args.tar_output:
                tar_sha256 = write_deterministic_tar(
                    stage_path,
                    Path(args.tar_output),
                    source=source,
                    expected_provenance_sha256=provenance_sha256,
                )
            print(
                json.dumps(
                    {
                        "cacheKey": manifest["cache"]["cacheKey"],
                        "provenanceSha256": provenance_sha256,
                        "schemaVersion": manifest["schemaVersion"],
                        "stagedPayloadSha256": manifest["stage"]["stagedPayloadSha256"],
                        **({"tarSha256": tar_sha256} if tar_sha256 is not None else {}),
                    },
                    sort_keys=True,
                )
            )
        else:
            manifest = verify_stage(
                Path(args.stage),
                source=Path(args.source),
                expected_provenance_sha256=args.provenance_sha256,
            )
            print(
                json.dumps(
                    {
                        "cacheKey": manifest["cache"]["cacheKey"],
                        "ok": True,
                        "stagedPayloadSha256": manifest["stage"]["stagedPayloadSha256"],
                    },
                    sort_keys=True,
                )
            )
    except (OSError, ProvenanceError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
