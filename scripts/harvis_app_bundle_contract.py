#!/usr/bin/env python3
"""Strict provenance and receipt contract for packaged Harvis macOS apps."""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import unicodedata
from typing import Any, Callable, Iterable, Sequence

from harvis_release_provenance import ProvenanceError, verify_stage


RECEIPT_SCHEMA_VERSION = "harvis.app-bundle-receipt.v1"
RECEIPT_FILE = "harvis-bundle-receipt.json"
MARKER_FILE = "harvis-plugin-root.txt"
PLUGIN_ROOT_MARKER = "HarvisPlugin"
APP_RUNTIME_ALLOWLIST = "packaging/app-runtime-allowlist-v1.txt"
PROVENANCE_FILE = "release-provenance-v2.json"
EXTENSION_NAME = "HarvisPerAppProxyExtension"
APP_ENTITLEMENTS = "apps/HarvisBar/Resources/HarvisBar.entitlements"
EXTENSION_ENTITLEMENTS = (
    f"apps/HarvisBar/SystemExtensions/{EXTENSION_NAME}/{EXTENSION_NAME}.entitlements"
)
EXTENSION_BUNDLE_NAME = f"{EXTENSION_NAME}.systemextension"
EXTENSION_ID = "com.harzva.harvisbar.per-app-proxy"
PAYLOAD_DIGEST_ALGORITHM = "sha256(path\\0mode\\0size\\0sha256\\0\\n)"
PAYLOAD_DIGEST_SCOPE = f"all files under {PLUGIN_ROOT_MARKER}"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

REQUIRED_MACOS_USAGE_DESCRIPTIONS: dict[str, str] = {
    "NSAppleEventsUsageDescription": (
        "H.A.R.V.I.S. uses Apple Events only when you choose an action that "
        "opens Terminal or another local app."
    ),
    "NSDesktopFolderUsageDescription": (
        "H.A.R.V.I.S. reads user-selected workspaces stored on the Desktop."
    ),
    "NSDocumentsFolderUsageDescription": (
        "H.A.R.V.I.S. reads and updates user-selected document workspaces."
    ),
    "NSDownloadsFolderUsageDescription": (
        "H.A.R.V.I.S. reads user-selected downloads used by local tasks."
    ),
    "NSNetworkVolumesUsageDescription": (
        "H.A.R.V.I.S. accesses user-selected workspaces on network volumes."
    ),
    "NSRemovableVolumesUsageDescription": (
        "H.A.R.V.I.S. accesses user-selected workspaces on external volumes."
    ),
}

EXPECTED_ARTIFACT_PATHS: dict[str, str] = {
    "harvis-runtime": "bin/harvis",
    "harvis-system-extension": f"artifacts/{EXTENSION_NAME}",
    "harvisbar-main": "artifacts/HarvisBar",
}
APP_VARIANT_PROFILES: dict[str, dict[str, str]] = {
    "bar": {
        "appName": "HarvisBar",
        "bundleIdentifier": "local.harzva.harvisbar",
        "executable": "HarvisBar",
        "iconFile": "HarvisBar.icns",
    },
    "desktop": {
        "appName": "HarvisDesk",
        "bundleIdentifier": "local.harzva.harvisdesk",
        "executable": "HarvisDesk",
        "iconFile": "HarvisDesk.icns",
    },
}


class AppBundleContractError(RuntimeError):
    """Raised when an app bundle cannot be tied to its external provenance."""


@dataclasses.dataclass(frozen=True)
class GitBlob:
    mode: str
    object_id: str
    path: str


@dataclasses.dataclass(frozen=True)
class ProvenanceContract:
    source: Path
    stage: Path
    provenance_sha256: str
    manifest: dict[str, Any]
    artifacts: dict[str, dict[str, Any]]
    app_runtime_allowlist_raw: bytes
    app_runtime_allowlist_sha256: str


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_relative_path(value: str, *, allow_directory: bool = False) -> str:
    if not value or "\x00" in value or "\\" in value or value.startswith("/"):
        raise AppBundleContractError("path must be a non-empty POSIX relative path")
    trailing = value.endswith("/")
    candidate = value[:-1] if trailing else value
    raw_parts = candidate.split("/")
    if any(part in {"", ".", ".."} for part in raw_parts):
        raise AppBundleContractError(f"unsafe relative path: {value!r}")
    normalized = PurePosixPath(candidate).as_posix()
    if normalized != candidate:
        raise AppBundleContractError(f"non-canonical relative path: {value!r}")
    if trailing:
        if not allow_directory:
            raise AppBundleContractError(f"directory path is not allowed here: {value!r}")
        normalized += "/"
    return normalized


def _case_key(value: str) -> str:
    return unicodedata.normalize("NFC", value).casefold()


def _assert_no_case_collisions(values: Iterable[str]) -> None:
    seen: dict[str, str] = {}
    for value in sorted(values):
        key = _case_key(value)
        previous = seen.get(key)
        if previous is not None and previous != value:
            raise AppBundleContractError(
                f"case/Unicode path collision: {previous!r} and {value!r}"
            )
        seen[key] = value


def _regular_file(path: Path, label: str, *, require_single_link: bool = True) -> os.stat_result:
    if path.is_symlink():
        raise AppBundleContractError(f"{label} must not be a symlink")
    try:
        metadata = path.stat()
    except OSError as exc:
        raise AppBundleContractError(f"{label} is missing or unreadable") from exc
    if not stat.S_ISREG(metadata.st_mode):
        raise AppBundleContractError(f"{label} must be a regular file")
    if require_single_link and metadata.st_nlink != 1:
        raise AppBundleContractError(f"{label} must not be a hardlink")
    return metadata


def file_record(root: Path, relative: str) -> dict[str, Any]:
    relative = _safe_relative_path(relative)
    path = root / PurePosixPath(relative)
    metadata = _regular_file(path, relative)
    return {
        "relativePath": relative,
        "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
        "sizeBytes": metadata.st_size,
        "sha256": sha256_file(path),
    }


def payload_records(payload: Path) -> list[dict[str, Any]]:
    if payload.is_symlink() or not payload.is_dir():
        raise AppBundleContractError("bundled plugin payload is missing or is a symlink")
    paths: list[str] = []
    for current, directories, files in os.walk(payload, followlinks=False):
        current_path = Path(current)
        for directory in list(directories):
            child = current_path / directory
            if child.is_symlink():
                raise AppBundleContractError("bundled plugin payload contains a symlink")
            if not child.is_dir():
                raise AppBundleContractError("bundled plugin payload contains a special entry")
        for filename in files:
            child = current_path / filename
            relative = child.relative_to(payload).as_posix()
            paths.append(_safe_relative_path(relative))
    _assert_no_case_collisions(paths)
    return [file_record(payload, path) for path in sorted(paths)]


def payload_digest(records: Sequence[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for record in sorted(records, key=lambda item: item["relativePath"]):
        for field in ("relativePath", "mode", "sizeBytes", "sha256"):
            digest.update(str(record[field]).encode("utf-8"))
            digest.update(b"\x00")
        digest.update(b"\n")
    return digest.hexdigest()


def _run_git(source: Path, *args: str, binary: bool = False) -> str | bytes:
    result = subprocess.run(
        ["git", "-C", str(source), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise AppBundleContractError(f"git command failed: {detail or result.returncode}")
    if binary:
        return result.stdout
    try:
        return result.stdout.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise AppBundleContractError("git returned non-UTF-8 metadata") from exc


def parse_runtime_allowlist(raw: bytes) -> list[str]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise AppBundleContractError("app runtime allowlist must be UTF-8") from exc
    entries: list[str] = []
    collision_keys: set[str] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        value = line.split("#", 1)[0].strip()
        if not value:
            continue
        try:
            normalized = _safe_relative_path(value, allow_directory=True)
        except AppBundleContractError as exc:
            raise AppBundleContractError(
                f"invalid app runtime allowlist line {line_number}: {exc}"
            ) from exc
        key = _case_key(normalized)
        if key in collision_keys:
            raise AppBundleContractError(
                f"duplicate app runtime allowlist entry: {normalized}"
            )
        collision_keys.add(key)
        entries.append(normalized)
    if not entries:
        raise AppBundleContractError("app runtime allowlist selects no files")
    if APP_RUNTIME_ALLOWLIST not in entries:
        raise AppBundleContractError("app runtime allowlist must include itself")
    return entries


def _git_blobs(source: Path, commit: str) -> list[GitBlob]:
    raw = bytes(
        _run_git(source, "ls-tree", "-rz", "--full-tree", commit, binary=True)
    )
    blobs: list[GitBlob] = []
    for record in raw.split(b"\x00"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split(" ", 2)
            path = _safe_relative_path(raw_path.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise AppBundleContractError("Git tree contains an unsupported entry") from exc
        if kind == "blob":
            blobs.append(GitBlob(mode=mode, object_id=object_id, path=path))
        elif kind == "commit" or mode == "160000":
            blobs.append(GitBlob(mode=mode, object_id=object_id, path=path))
    return blobs


def _selected_runtime_blobs(
    source: Path, commit: str, allowlist_raw: bytes
) -> tuple[list[str], list[GitBlob]]:
    specs = parse_runtime_allowlist(allowlist_raw)
    all_entries = _git_blobs(source, commit)
    selected: dict[str, GitBlob] = {}
    for spec in specs:
        matches = [
            entry
            for entry in all_entries
            if (
                entry.path.startswith(spec)
                if spec.endswith("/")
                else entry.path == spec
            )
        ]
        if not matches:
            raise AppBundleContractError(
                f"app runtime allowlist entry matches no committed file: {spec}"
            )
        for entry in matches:
            selected[entry.path] = entry
    values = sorted(selected.values(), key=lambda item: item.path)
    _assert_no_case_collisions(item.path for item in values)
    for entry in values:
        if entry.mode in {"120000", "160000"}:
            raise AppBundleContractError(
                f"app runtime payload forbids symlinks/submodules: {entry.path}"
            )
        if entry.mode not in {"100644", "100755"}:
            raise AppBundleContractError(
                f"app runtime payload has unsupported Git mode: {entry.path}"
            )
    return specs, values


def staged_runtime_payload_records(contract: ProvenanceContract) -> list[dict[str, Any]]:
    commit = contract.manifest["source"]["commit"]
    _, blobs = _selected_runtime_blobs(
        contract.source, commit, contract.app_runtime_allowlist_raw
    )
    records: list[dict[str, Any]] = []
    for blob in blobs:
        record = file_record(contract.stage, blob.path)
        expected_mode = "0755" if blob.mode == "100755" else "0644"
        if record["mode"] != expected_mode:
            raise AppBundleContractError(
                f"staged app runtime file has an invalid mode: {blob.path}"
            )
        records.append(record)
    return records


def materialize_runtime_payload(contract: ProvenanceContract, payload: Path) -> None:
    if payload.exists() or payload.is_symlink():
        raise AppBundleContractError("runtime payload destination must not already exist")
    commit = contract.manifest["source"]["commit"]
    _, blobs = _selected_runtime_blobs(
        contract.source, commit, contract.app_runtime_allowlist_raw
    )
    payload.mkdir(parents=True, mode=0o755)
    for blob in blobs:
        source = contract.stage / PurePosixPath(blob.path)
        _regular_file(source, f"staged app runtime file {blob.path}")
        target = payload / PurePosixPath(blob.path)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o755 if blob.mode == "100755" else 0o644)

    runtime_source = contract.stage / EXPECTED_ARTIFACT_PATHS["harvis-runtime"]
    runtime_target = payload / "bin" / "harvis"
    if runtime_target.exists() or runtime_target.is_symlink():
        raise AppBundleContractError("runtime artifact would overwrite committed payload")
    runtime_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(runtime_source, runtime_target)
    runtime_target.chmod(0o755)
    expected = contract.artifacts["harvis-runtime"]
    if file_record(payload, "bin/harvis") != {
        key: value for key, value in expected.items() if key != "role"
    }:
        raise AppBundleContractError("copied runtime artifact differs from provenance")


def _read_json(path: Path, label: str) -> dict[str, Any]:
    _regular_file(path, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AppBundleContractError(f"{label} is invalid JSON") from exc
    if not isinstance(value, dict):
        raise AppBundleContractError(f"{label} must be a JSON object")
    return value


def _read_plist(path: Path, label: str) -> dict[str, Any]:
    _regular_file(path, label)
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as exc:
        raise AppBundleContractError(f"{label} is invalid") from exc
    if not isinstance(value, dict):
        raise AppBundleContractError(f"{label} must be a dictionary")
    return value


def _directory_entry_names(path: Path, label: str) -> set[str]:
    if path.is_symlink() or not path.is_dir():
        raise AppBundleContractError(f"{label} is missing or is a symlink")
    values: set[str] = set()
    for child in path.iterdir():
        if child.is_symlink():
            raise AppBundleContractError(f"{label} contains a symlink")
        values.add(child.name)
    _assert_no_case_collisions(values)
    return values


def validate_fixed_artifacts(
    manifest: dict[str, Any], stage: Path
) -> dict[str, dict[str, Any]]:
    raw_artifacts = manifest.get("artifacts")
    if not isinstance(raw_artifacts, list):
        raise AppBundleContractError("provenance artifacts must be an array")
    expected_roles = sorted(EXPECTED_ARTIFACT_PATHS)
    roles = [item.get("role") if isinstance(item, dict) else None for item in raw_artifacts]
    if roles != expected_roles:
        raise AppBundleContractError(
            "macOS app provenance must contain exactly the three fixed artifact roles"
        )
    artifacts: dict[str, dict[str, Any]] = {}
    for item in raw_artifacts:
        if not isinstance(item, dict) or set(item) != {
            "mode",
            "relativePath",
            "role",
            "sha256",
            "sizeBytes",
        }:
            raise AppBundleContractError("provenance artifact record has an invalid shape")
        role = item["role"]
        if item["relativePath"] != EXPECTED_ARTIFACT_PATHS[role]:
            raise AppBundleContractError(f"provenance artifact path is invalid for {role}")
        if item["mode"] != "0755" or not isinstance(item["sizeBytes"], int) or item["sizeBytes"] <= 0:
            raise AppBundleContractError(f"provenance artifact mode/size is invalid for {role}")
        if not isinstance(item["sha256"], str) or not SHA256_RE.fullmatch(item["sha256"]):
            raise AppBundleContractError(f"provenance artifact SHA-256 is invalid for {role}")
        actual = file_record(stage, item["relativePath"])
        expected = {key: value for key, value in item.items() if key != "role"}
        if actual != expected:
            raise AppBundleContractError(f"provenance artifact file mismatch for {role}")
        artifacts[role] = dict(item)
    return artifacts


def load_provenance_contract(
    stage: Path, source: Path, provenance_sha256: str
) -> ProvenanceContract:
    if not SHA256_RE.fullmatch(provenance_sha256):
        raise AppBundleContractError("external provenance SHA-256 must be lowercase hexadecimal")
    if stage.is_symlink():
        raise AppBundleContractError("provenance stage must not be a symlink")
    stage = stage.expanduser().resolve()
    source = source.expanduser().resolve()
    try:
        manifest = verify_stage(
            stage,
            source=source,
            expected_provenance_sha256=provenance_sha256,
        )
    except (OSError, ProvenanceError, ValueError) as exc:
        raise AppBundleContractError(f"provenance stage verification failed: {exc}") from exc
    artifacts = validate_fixed_artifacts(manifest, stage)

    allowlist_path = stage / APP_RUNTIME_ALLOWLIST
    _regular_file(allowlist_path, "staged app runtime allowlist")
    allowlist_raw = allowlist_path.read_bytes()
    commit = manifest["source"]["commit"]
    committed_raw = bytes(
        _run_git(source, "show", f"{commit}:{APP_RUNTIME_ALLOWLIST}", binary=True)
    )
    if allowlist_raw != committed_raw:
        raise AppBundleContractError("staged app runtime allowlist differs from source commit")
    parse_runtime_allowlist(allowlist_raw)
    return ProvenanceContract(
        source=source,
        stage=stage,
        provenance_sha256=provenance_sha256,
        manifest=manifest,
        artifacts=artifacts,
        app_runtime_allowlist_raw=allowlist_raw,
        app_runtime_allowlist_sha256=sha256_bytes(allowlist_raw),
    )


def _expected_payload_records(contract: ProvenanceContract) -> list[dict[str, Any]]:
    records = staged_runtime_payload_records(contract)
    runtime = contract.artifacts["harvis-runtime"]
    records.append(
        {
            "relativePath": "bin/harvis",
            "mode": runtime["mode"],
            "sizeBytes": runtime["sizeBytes"],
            "sha256": runtime["sha256"],
        }
    )
    return sorted(records, key=lambda item: item["relativePath"])


def _artifact_record_without_role(record: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in record.items() if key != "role"}


def _assert_exact_artifact_copy(
    path: Path, record: dict[str, Any], label: str
) -> None:
    metadata = _regular_file(path, label)
    actual = {
        "relativePath": record["relativePath"],
        "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
        "sizeBytes": metadata.st_size,
        "sha256": sha256_file(path),
    }
    if actual != _artifact_record_without_role(record):
        raise AppBundleContractError(f"{label} differs from its provenance artifact")


def build_receipt(
    contract: ProvenanceContract,
    contents: Path,
    *,
    variant: str,
    expected_bundle_id: str,
    expected_version: str,
    expected_executable: str,
    require_unsigned_artifact_copies: bool = True,
) -> dict[str, Any]:
    if variant not in APP_VARIANT_PROFILES:
        raise AppBundleContractError("app variant must be bar or desktop")
    profile = APP_VARIANT_PROFILES[variant]
    if expected_bundle_id != profile["bundleIdentifier"]:
        raise AppBundleContractError("app bundle identifier is not fixed by its variant")
    if expected_executable != profile["executable"]:
        raise AppBundleContractError("app executable is not fixed by its variant")
    app_info = _read_plist(contents / "Info.plist", "app Info.plist")
    expected_app_values = {
        "CFBundleExecutable": expected_executable,
        "CFBundleIdentifier": expected_bundle_id,
        "CFBundleName": profile["appName"],
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": expected_version,
        "CFBundleVersion": expected_version,
    }
    expected_app_values.update(REQUIRED_MACOS_USAGE_DESCRIPTIONS)
    for key, value in expected_app_values.items():
        if app_info.get(key) != value:
            raise AppBundleContractError(f"app Info.plist has an invalid {key}")
    if contract.manifest["source"]["workspaceVersion"] != expected_version:
        raise AppBundleContractError("app version differs from provenance workspace version")

    resources = contents / "Resources"
    icon_name = profile["iconFile"]
    resource_names = _directory_entry_names(resources, "app Resources")
    required_resources = {PLUGIN_ROOT_MARKER, MARKER_FILE, icon_name}
    allowed_resources = required_resources | {"FULL_DISK_ACCESS.md", RECEIPT_FILE}
    if not required_resources.issubset(resource_names) or not resource_names.issubset(
        allowed_resources
    ):
        raise AppBundleContractError("app Resources inventory is missing or contains a rogue entry")
    marker_path = resources / MARKER_FILE
    _regular_file(marker_path, "plugin root marker")
    if marker_path.read_bytes() != f"{PLUGIN_ROOT_MARKER}\n".encode("utf-8"):
        raise AppBundleContractError("plugin root marker must be the exact safe relative marker")
    payload = resources / PLUGIN_ROOT_MARKER
    actual_payload_records = payload_records(payload)
    if actual_payload_records != _expected_payload_records(contract):
        raise AppBundleContractError("bundled runtime payload differs from committed allowlist")

    main = contents / "MacOS" / expected_executable
    runtime = payload / "bin" / "harvis"
    extension_bundle = contents / "Library" / "SystemExtensions" / EXTENSION_BUNDLE_NAME
    extension_contents = extension_bundle / "Contents"
    extension_binary = extension_contents / "MacOS" / EXTENSION_NAME
    if _directory_entry_names(contents / "MacOS", "app executable directory") != {
        expected_executable
    }:
        raise AppBundleContractError("app executable directory has a rogue entry")
    if _directory_entry_names(
        contents / "Library" / "SystemExtensions", "system extension directory"
    ) != {EXTENSION_BUNDLE_NAME}:
        raise AppBundleContractError("system extension directory has an invalid bundle name")
    if _directory_entry_names(
        extension_contents / "MacOS", "system extension executable directory"
    ) != {EXTENSION_NAME}:
        raise AppBundleContractError("system extension executable name is invalid")
    _regular_file(main, "app executable")
    _assert_exact_artifact_copy(runtime, contract.artifacts["harvis-runtime"], "runtime executable")
    _regular_file(extension_binary, "system extension executable")
    if require_unsigned_artifact_copies:
        _assert_exact_artifact_copy(
            main, contract.artifacts["harvisbar-main"], "app executable"
        )
        _assert_exact_artifact_copy(
            extension_binary,
            contract.artifacts["harvis-system-extension"],
            "system extension executable",
        )
    extension_info = _read_plist(extension_contents / "Info.plist", "system extension Info.plist")
    expected_extension_values = {
        "CFBundleExecutable": EXTENSION_NAME,
        "CFBundleIdentifier": EXTENSION_ID,
        "CFBundlePackageType": "SYSX",
        "CFBundleShortVersionString": expected_version,
        "CFBundleVersion": expected_version,
    }
    for key, value in expected_extension_values.items():
        if extension_info.get(key) != value:
            raise AppBundleContractError(f"system extension has an invalid {key}")

    artifacts = [contract.artifacts[role] for role in sorted(contract.artifacts)]
    return {
        "schemaVersion": RECEIPT_SCHEMA_VERSION,
        "pluginRootMarker": PLUGIN_ROOT_MARKER,
        "app": {
            "bundleIdentifier": expected_bundle_id,
            "executable": expected_executable,
            "variant": variant,
            "version": expected_version,
        },
        "artifacts": {
            "runtimeSha256": contract.artifacts["harvis-runtime"]["sha256"],
            "appUnsignedSha256": contract.artifacts["harvisbar-main"]["sha256"],
            "systemExtensionUnsignedSha256": contract.artifacts[
                "harvis-system-extension"
            ]["sha256"],
            "records": artifacts,
        },
        "appRuntimeAllowlist": {
            "relativePath": APP_RUNTIME_ALLOWLIST,
            "sha256": contract.app_runtime_allowlist_sha256,
        },
        "payload": {
            "digestAlgorithm": PAYLOAD_DIGEST_ALGORITHM,
            "digestScope": PAYLOAD_DIGEST_SCOPE,
            "fileCount": len(actual_payload_records),
            "sha256": payload_digest(actual_payload_records),
        },
        "provenance": {
            "cacheKey": contract.manifest["cache"]["cacheKey"],
            "sha256": contract.provenance_sha256,
            "sourceCommit": contract.manifest["source"]["commit"],
            "sourceTree": contract.manifest["source"]["tree"],
            "stagedPayloadSha256": contract.manifest["stage"]["stagedPayloadSha256"],
        },
        "systemExtension": {
            "bundleIdentifier": EXTENSION_ID,
            "bundleName": EXTENSION_BUNDLE_NAME,
            "executable": EXTENSION_NAME,
            "version": expected_version,
        },
    }


def write_receipt(path: Path, value: dict[str, Any]) -> None:
    if path.exists() or path.is_symlink():
        raise AppBundleContractError("bundle receipt destination must not already exist")
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    path.chmod(0o644)


def _canonical_unsigned_hash(path: Path, codesign: str) -> str:
    with tempfile.TemporaryDirectory(prefix="harvis-codesign-canonical-") as temporary:
        copy = Path(temporary) / path.name
        shutil.copyfile(path, copy)
        display = subprocess.run(
            [codesign, "-dv", str(copy)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        original = copy.read_bytes()
        if display.returncode != 0:
            raise AppBundleContractError("provenance derivative requires a signed Mach-O")
        original_vmsize_offset, original_canonical_vmsize = _macho_signature_layout(
            original, require_code_signature=True
        )
        removed = subprocess.run(
            [codesign, "--remove-signature", str(copy)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if removed.returncode != 0:
            raise AppBundleContractError("failed to normalize an executable code signature")
        unsigned = copy.read_bytes()
        return sha256_bytes(
            _normalize_codesign_mutable_macho_fields(
                unsigned,
                expected_vmsize_offset=original_vmsize_offset,
                expected_stale_vmsize=original_canonical_vmsize,
            )
        )


def _normalize_codesign_mutable_macho_fields(
    raw: bytes, *, expected_vmsize_offset: int, expected_stale_vmsize: int
) -> bytes:
    """Normalize the one Mach-O field that ``codesign`` legitimately rewrites.

    Removing a linker-generated signature and removing a later app signature leaves
    the executable bytes identical except for ``__LINKEDIT.vmsize``.  Reconstruct
    that value deterministically from the post-removal ``filesize`` instead of
    ignoring it.  The surrounding load command and every other byte remain covered
    by the derivative hash.  Required-policy callers also verify the complete app
    signature before reaching this normalization.

    Harvis release artifacts are fixed to thin little-endian arm64 Mach-O
    executables.  Fail closed for another format, malformed load commands, a
    residual signature load command, or an invalid ``__LINKEDIT`` layout.
    """

    vmsize_offset, canonical_vmsize = _macho_signature_layout(
        raw, require_code_signature=False
    )
    actual_vmsize = struct.unpack_from("<Q", raw, vmsize_offset)[0]
    if vmsize_offset != expected_vmsize_offset:
        raise AppBundleContractError("codesign changed the Mach-O load command layout")
    if actual_vmsize != expected_stale_vmsize:
        raise AppBundleContractError("codesign changed an unexpected __LINKEDIT vmsize")
    if actual_vmsize % 0x4000 != 0 or actual_vmsize < canonical_vmsize:
        raise AppBundleContractError("post-signature __LINKEDIT vmsize is invalid")
    normalized = bytearray(raw)
    struct.pack_into("<Q", normalized, vmsize_offset, canonical_vmsize)
    return bytes(normalized)


def _macho_signature_layout(
    raw: bytes, *, require_code_signature: bool
) -> tuple[int, int]:
    """Validate the fixed arm64 layout and return vmsize offset/canonical value."""

    if len(raw) < 32:
        raise AppBundleContractError("executable is not a supported 64-bit Mach-O")
    if raw[:4] != b"\xcf\xfa\xed\xfe":
        raise AppBundleContractError("executable is not a supported thin arm64 Mach-O")
    cpu_type = struct.unpack_from("<I", raw, 4)[0]
    if cpu_type != 0x0100000C:
        raise AppBundleContractError("executable is not arm64 Mach-O")

    ncmds, sizeofcmds = struct.unpack_from("<II", raw, 16)
    commands_start = 32
    commands_end = commands_start + sizeofcmds
    if commands_end > len(raw):
        raise AppBundleContractError("Mach-O load commands exceed the executable")

    cursor = commands_start
    segments: list[tuple[bytes, int, int]] = []
    linkedit: tuple[int, int, int, int, int, int, int] | None = None
    signatures: list[tuple[int, int]] = []
    for _ in range(ncmds):
        if cursor + 8 > commands_end:
            raise AppBundleContractError("Mach-O load command header is truncated")
        command, command_size = struct.unpack_from("<II", raw, cursor)
        if command_size < 8 or command_size % 8 != 0 or cursor + command_size > commands_end:
            raise AppBundleContractError("Mach-O load command has an invalid size")
        if command == 0x1D:  # LC_CODE_SIGNATURE
            if command_size != 16:
                raise AppBundleContractError("code signature load command has an invalid size")
            signatures.append(struct.unpack_from("<II", raw, cursor + 8))
        if command == 0x19:  # LC_SEGMENT_64
            if command_size < 72:
                raise AppBundleContractError("Mach-O segment command is truncated")
            segment_name = raw[cursor + 8 : cursor + 24].split(b"\0", 1)[0]
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from(
                "<QQQQ", raw, cursor + 24
            )
            maxprot, initprot, nsects, flags = struct.unpack_from(
                "<iiII", raw, cursor + 56
            )
            if command_size != 72 + nsects * 80:
                raise AppBundleContractError("Mach-O segment command size is inconsistent")
            segments.append((segment_name, fileoff, filesize))
            if segment_name == b"__LINKEDIT":
                if linkedit is not None:
                    raise AppBundleContractError("Mach-O has duplicate __LINKEDIT segments")
                linkedit = (
                    cursor + 32,
                    vmaddr,
                    vmsize,
                    fileoff,
                    filesize,
                    nsects,
                    flags,
                )
                if maxprot != 1 or initprot != 1:
                    raise AppBundleContractError("Mach-O __LINKEDIT protections are invalid")
        cursor += command_size

    if cursor != commands_end:
        raise AppBundleContractError("Mach-O load command table has trailing bytes")
    if linkedit is None:
        raise AppBundleContractError("Mach-O must contain exactly one __LINKEDIT segment")
    vmsize_offset, vmaddr, vmsize, fileoff, filesize, nsects, flags = linkedit
    if nsects != 0 or flags != 0:
        raise AppBundleContractError("Mach-O __LINKEDIT segment metadata is invalid")
    if fileoff == 0 or filesize == 0 or fileoff % 0x4000 != 0 or vmaddr % 0x4000 != 0:
        raise AppBundleContractError("Mach-O __LINKEDIT alignment is invalid")
    if fileoff + filesize != len(raw):
        raise AppBundleContractError("Mach-O __LINKEDIT is not the complete final file segment")
    for name, segment_fileoff, segment_filesize in segments:
        if (
            name != b"__LINKEDIT"
            and segment_filesize > 0
            and segment_fileoff + segment_filesize > fileoff
        ):
            raise AppBundleContractError("Mach-O __LINKEDIT is not the final segment")

    canonical_vmsize = (filesize + 0x3FFF) & ~0x3FFF
    if require_code_signature:
        if len(signatures) != 1:
            raise AppBundleContractError("signed Mach-O must contain one code signature command")
        signature_offset, signature_size = signatures[0]
        if (
            signature_size == 0
            or signature_offset < fileoff
            or signature_offset + signature_size != len(raw)
        ):
            raise AppBundleContractError("Mach-O code signature range is invalid")
        if vmsize != canonical_vmsize:
            raise AppBundleContractError("signed Mach-O __LINKEDIT vmsize is not canonical")
    elif signatures:
        raise AppBundleContractError("code signature load command remains after normalization")
    return vmsize_offset, canonical_vmsize


def _assert_signed_derivative(
    staged: Path, bundled: Path, label: str, codesign: str
) -> None:
    if _canonical_unsigned_hash(staged, codesign) != _canonical_unsigned_hash(
        bundled, codesign
    ):
        raise AppBundleContractError(
            f"signed {label} is not a code-signature-only derivative of provenance"
        )


def verify_codesign_targets(
    app: Path,
    extension: Path,
    runtime: Path,
    *,
    codesign: str | None = None,
    runner: Callable[..., subprocess.CompletedProcess[bytes]] = subprocess.run,
) -> None:
    codesign = codesign or shutil.which("codesign")
    if not codesign:
        raise AppBundleContractError("codesign is required by the selected verification policy")
    for label, target in (
        ("runtime", runtime),
        ("system extension", extension),
        ("app", app),
    ):
        result = runner(
            [codesign, "--verify", "--strict", str(target)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AppBundleContractError(f"{label} code signature verification failed")


def verify_signed_entitlements(
    app: Path,
    extension: Path,
    contract: ProvenanceContract,
    *,
    codesign: str,
    runner: Callable[..., subprocess.CompletedProcess[bytes]] = subprocess.run,
) -> None:
    """Require signed app/extension entitlements to equal the trusted stage plists."""

    targets = (
        ("app", app, APP_ENTITLEMENTS),
        ("system extension", extension, EXTENSION_ENTITLEMENTS),
    )
    for label, target, expected_relative in targets:
        expected = _read_plist(
            contract.stage / expected_relative, f"staged {label} entitlements"
        )
        result = runner(
            [codesign, "-d", "--entitlements", ":-", str(target)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AppBundleContractError(f"{label} signed entitlements are unreadable")
        try:
            actual = plistlib.loads(result.stdout)
        except plistlib.InvalidFileException as exc:
            raise AppBundleContractError(f"{label} signed entitlements are invalid") from exc
        if not isinstance(actual, dict) or actual != expected:
            raise AppBundleContractError(
                f"{label} signed entitlements differ from provenance"
            )


def verify_bundle(
    app: Path,
    contract: ProvenanceContract,
    *,
    variant: str,
    expected_bundle_id: str,
    expected_version: str,
    expected_executable: str,
    codesign_policy: str,
) -> dict[str, Any]:
    if codesign_policy not in {"required", "skip"}:
        raise AppBundleContractError("codesign policy must be required or skip")
    if app.is_symlink() or not app.is_dir():
        raise AppBundleContractError("app bundle is missing or is a symlink")
    contents = app / "Contents"
    receipt_path = contents / "Resources" / RECEIPT_FILE
    receipt = _read_json(receipt_path, "app bundle receipt")
    expected_receipt = build_receipt(
        contract,
        contents,
        variant=variant,
        expected_bundle_id=expected_bundle_id,
        expected_version=expected_version,
        expected_executable=expected_executable,
        require_unsigned_artifact_copies=False,
    )
    if receipt != expected_receipt:
        raise AppBundleContractError("app bundle receipt does not match bundle/provenance")

    main = contents / "MacOS" / expected_executable
    runtime = contents / "Resources" / PLUGIN_ROOT_MARKER / "bin" / "harvis"
    extension = contents / "Library" / "SystemExtensions" / EXTENSION_BUNDLE_NAME
    extension_binary = extension / "Contents" / "MacOS" / EXTENSION_NAME
    if codesign_policy == "required":
        codesign = shutil.which("codesign")
        verify_codesign_targets(app, extension, runtime, codesign=codesign)
        assert codesign is not None
        verify_signed_entitlements(app, extension, contract, codesign=codesign)
        _assert_signed_derivative(
            contract.stage / EXPECTED_ARTIFACT_PATHS["harvisbar-main"],
            main,
            "app executable",
            codesign,
        )
        _assert_signed_derivative(
            contract.stage / EXPECTED_ARTIFACT_PATHS["harvis-system-extension"],
            extension_binary,
            "system extension executable",
            codesign,
        )
    else:
        _assert_exact_artifact_copy(
            main, contract.artifacts["harvisbar-main"], "app executable"
        )
        _assert_exact_artifact_copy(
            extension_binary,
            contract.artifacts["harvis-system-extension"],
            "system extension executable",
        )
    return receipt
