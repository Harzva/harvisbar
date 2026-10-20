#!/usr/bin/env bash
set -euo pipefail

readonly APP_NAME="HarvisBarVersionUITest.app"
readonly BUNDLE_ID="local.harzva.harvisbar.version-ui-test"
readonly MARKER_NAME=".harvis-version-ui-owner"

usage() {
  cat >&2 <<'EOF'
Usage:
  harvis_bar_version_ui_test_app.sh validate|build|cleanup \
    --scratch-root <path> --owner-token <32-lower-hex> \
    --root-device <decimal> --root-inode <decimal>

The scratch root must be a fresh mode-0700 directory created by:
  mktemp -d "$TMPDIR/harvis-version-ui.XXXXXXXX"
EOF
  exit 2
}

[[ $# -eq 9 ]] || usage
readonly COMMAND="$1"
shift
[[ "$1" == "--scratch-root" && "$3" == "--owner-token" && \
   "$5" == "--root-device" && "$7" == "--root-inode" ]] || usage
readonly SCRATCH_ROOT="$2"
readonly OWNER_TOKEN="$4"
readonly ROOT_DEVICE="$6"
readonly ROOT_INODE="$8"
[[ "$COMMAND" == "validate" || "$COMMAND" == "build" || "$COMMAND" == "cleanup" ]] || usage

[[ -n "${TMPDIR:-}" ]] || {
  echo "TMPDIR is required." >&2
  exit 2
}

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly INFO_PLIST="$REPO_ROOT/tests/fixtures/harvis-version-ui-test/Info.plist"
readonly TARGET_APP="$SCRATCH_ROOT/$APP_NAME"
readonly SWIFT_SCRATCH="$SCRATCH_ROOT/.swift-build"

guard_scratch() {
  local mode="$1"
  /usr/bin/python3 -I - \
    "$mode" "$TMPDIR" "$SCRATCH_ROOT" "$OWNER_TOKEN" \
    "$ROOT_DEVICE" "$ROOT_INODE" "$REPO_ROOT" "$APP_NAME" "$MARKER_NAME" <<'PY'
import os
import re
import stat
import sys

(
    mode,
    tmp_raw,
    scratch_raw,
    token,
    expected_device_raw,
    expected_inode_raw,
    repo_raw,
    app_name,
    marker_name,
) = sys.argv[1:]


def reject(message: str) -> "None":
    raise SystemExit(f"scratch guard rejected: {message}")


if mode not in {"prebuild", "preassemble", "postbuild", "cleanup"}:
    reject("unknown mode")
if not re.fullmatch(r"[0-9a-f]{32}", token):
    reject("owner token")
if not re.fullmatch(r"0|[1-9][0-9]*", expected_device_raw):
    reject("device")
if not re.fullmatch(r"0|[1-9][0-9]*", expected_inode_raw):
    reject("inode")
expected_device = int(expected_device_raw)
expected_inode = int(expected_inode_raw)

if "\x00" in tmp_raw or "\x00" in scratch_raw:
    reject("NUL path")
if not os.path.isabs(tmp_raw) or not os.path.isabs(scratch_raw):
    reject("path is not absolute")
scratch_parts = scratch_raw.split(os.sep)
if ".." in scratch_parts or "." in scratch_parts:
    reject("non-canonical component")
if scratch_raw.endswith(os.sep):
    reject("trailing separator")

tmp_lexical = os.path.normpath(tmp_raw)
scratch_lexical = os.path.normpath(scratch_raw)
if os.path.dirname(scratch_lexical) != tmp_lexical:
    reject("not a direct TMPDIR child")
if not re.fullmatch(r"harvis-version-ui\.[A-Za-z0-9]{8}", os.path.basename(scratch_lexical)):
    reject("scratch basename")

tmp_real = os.path.realpath(tmp_lexical)
scratch_real = os.path.realpath(scratch_lexical)
repo_real = os.path.realpath(repo_raw)
home_real = os.path.realpath(os.path.expanduser("~"))
if os.path.dirname(scratch_real) != tmp_real:
    reject("canonical TMPDIR parent mismatch")
if scratch_real in {os.sep, tmp_real, repo_real, home_real}:
    reject("protected root")
if scratch_real == repo_real or scratch_real.startswith(repo_real + os.sep):
    reject("repository path")

try:
    scratch_lstat = os.lstat(scratch_lexical)
except OSError:
    reject("scratch unavailable")
if not stat.S_ISDIR(scratch_lstat.st_mode) or stat.S_ISLNK(scratch_lstat.st_mode):
    reject("scratch is not a no-follow directory")
if scratch_lstat.st_uid != os.getuid():
    reject("scratch owner")
if stat.S_IMODE(scratch_lstat.st_mode) != 0o700:
    reject("scratch mode")
if (scratch_lstat.st_dev, scratch_lstat.st_ino) != (expected_device, expected_inode):
    reject("scratch identity")

open_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
directory_flags = open_flags | getattr(os, "O_DIRECTORY", 0)
try:
    root_fd = os.open(scratch_lexical, directory_flags)
except OSError:
    reject("scratch open")


def verify_root() -> None:
    current = os.fstat(root_fd)
    if not stat.S_ISDIR(current.st_mode):
        reject("scratch descriptor type")
    if (current.st_dev, current.st_ino) != (expected_device, expected_inode):
        reject("scratch descriptor identity")
    if current.st_uid != os.getuid() or stat.S_IMODE(current.st_mode) != 0o700:
        reject("scratch descriptor permissions")


def verify_marker() -> None:
    try:
        marker_lstat = os.stat(marker_name, dir_fd=root_fd, follow_symlinks=False)
    except OSError:
        reject("marker missing")
    if not stat.S_ISREG(marker_lstat.st_mode):
        reject("marker type")
    if marker_lstat.st_uid != os.getuid() or marker_lstat.st_nlink != 1:
        reject("marker identity")
    if stat.S_IMODE(marker_lstat.st_mode) != 0o600:
        reject("marker mode")
    try:
        marker_fd = os.open(marker_name, open_flags, dir_fd=root_fd)
    except OSError:
        reject("marker open")
    try:
        marker_fstat = os.fstat(marker_fd)
        if (marker_fstat.st_dev, marker_fstat.st_ino) != (
            marker_lstat.st_dev,
            marker_lstat.st_ino,
        ):
            reject("marker changed")
        data = os.read(marker_fd, 34)
        if data != (token + "\n").encode("ascii"):
            reject("marker token")
        if os.read(marker_fd, 1):
            reject("marker size")
    finally:
        os.close(marker_fd)


def verify_top_level(entries: set[str]) -> None:
    allowed = {marker_name, ".swift-build", app_name}
    if not entries <= allowed:
        reject("unexpected scratch entry")
    if marker_name not in entries:
        reject("marker roster")
    if ".swift-build" in entries:
        build_stat = os.stat(".swift-build", dir_fd=root_fd, follow_symlinks=False)
        if not stat.S_ISDIR(build_stat.st_mode) or build_stat.st_uid != os.getuid():
            reject("build directory")
    if app_name in entries:
        app_stat = os.stat(app_name, dir_fd=root_fd, follow_symlinks=False)
        if not stat.S_ISDIR(app_stat.st_mode) or app_stat.st_uid != os.getuid():
            reject("app directory")


try:
    verify_root()
    verify_marker()
    entries = set(os.listdir(root_fd))
    verify_top_level(entries)
    if mode == "prebuild" and entries != {marker_name}:
        reject("scratch is not fresh")
    if mode == "preassemble":
        if entries != {marker_name, ".swift-build"}:
            reject("preassembly roster")
        candidate = os.path.join(scratch_lexical, ".swift-build", "debug", "HarvisBar")
        candidate_real = os.path.realpath(candidate)
        build_real = os.path.realpath(os.path.join(scratch_lexical, ".swift-build"))
        if not candidate_real.startswith(build_real + os.sep):
            reject("binary escaped build root")
        try:
            candidate_stat = os.stat(candidate_real, follow_symlinks=False)
        except OSError:
            reject("binary missing")
        if not stat.S_ISREG(candidate_stat.st_mode) or candidate_stat.st_uid != os.getuid():
            reject("binary identity")
    if mode == "postbuild" and entries != {marker_name, ".swift-build", app_name}:
        reject("postbuild roster")
finally:
    os.close(root_fd)
PY
}

if [[ "$COMMAND" == "validate" ]]; then
  guard_scratch prebuild
  printf 'validated: %s\n' "$SCRATCH_ROOT"
  exit 0
fi

if [[ "$COMMAND" == "cleanup" ]]; then
  guard_scratch cleanup
  /usr/bin/python3 -I - \
    "$TMPDIR" "$SCRATCH_ROOT" "$OWNER_TOKEN" "$ROOT_DEVICE" "$ROOT_INODE" \
    "$APP_NAME" "$MARKER_NAME" <<'PY'
import os
import stat
import sys

tmp_raw, scratch, token, device_raw, inode_raw, app_name, marker_name = sys.argv[1:]
device, inode = int(device_raw), int(inode_raw)
parent = os.path.dirname(scratch)
basename = os.path.basename(scratch)
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
dir_flags = flags | getattr(os, "O_DIRECTORY", 0)
parent_fd = os.open(parent, dir_flags)
root_fd = os.open(basename, dir_flags, dir_fd=parent_fd)


def fail(message: str) -> "None":
    raise SystemExit(f"scratch cleanup rejected: {message}")


def same_root() -> None:
    current = os.fstat(root_fd)
    if (current.st_dev, current.st_ino) != (device, inode):
        fail("scratch identity")
    if current.st_uid != os.getuid() or stat.S_IMODE(current.st_mode) != 0o700:
        fail("scratch permissions")


def marker_matches() -> None:
    marker_stat = os.stat(marker_name, dir_fd=root_fd, follow_symlinks=False)
    if not stat.S_ISREG(marker_stat.st_mode):
        fail("marker type")
    if marker_stat.st_uid != os.getuid() or marker_stat.st_nlink != 1:
        fail("marker identity")
    if stat.S_IMODE(marker_stat.st_mode) != 0o600:
        fail("marker mode")
    marker_fd = os.open(marker_name, flags, dir_fd=root_fd)
    try:
        if os.read(marker_fd, 34) != (token + "\n").encode("ascii") or os.read(marker_fd, 1):
            fail("marker token")
    finally:
        os.close(marker_fd)


def purge_directory(directory_fd: int) -> None:
    for name in os.listdir(directory_fd):
        entry = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISDIR(entry.st_mode):
            child_fd = os.open(name, dir_flags, dir_fd=directory_fd)
            try:
                current = os.fstat(child_fd)
                if (current.st_dev, current.st_ino) != (entry.st_dev, entry.st_ino):
                    fail("child directory changed")
                purge_directory(child_fd)
                os.fsync(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(name, dir_fd=directory_fd)
        else:
            os.unlink(name, dir_fd=directory_fd)


try:
    same_root()
    marker_matches()
    top_level = set(os.listdir(root_fd))
    if not top_level <= {marker_name, ".swift-build", app_name}:
        fail("unexpected top-level entry")
    for child_name in sorted(top_level - {marker_name}):
        child_stat = os.stat(child_name, dir_fd=root_fd, follow_symlinks=False)
        if stat.S_ISDIR(child_stat.st_mode):
            child_fd = os.open(child_name, dir_flags, dir_fd=root_fd)
            try:
                opened = os.fstat(child_fd)
                if (opened.st_dev, opened.st_ino) != (child_stat.st_dev, child_stat.st_ino):
                    fail("top-level directory changed")
                purge_directory(child_fd)
                os.fsync(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(child_name, dir_fd=root_fd)
        else:
            os.unlink(child_name, dir_fd=root_fd)
    same_root()
    marker_matches()
    os.unlink(marker_name, dir_fd=root_fd)
    os.fsync(root_fd)
    os.rmdir(basename, dir_fd=parent_fd)
    os.fsync(parent_fd)
finally:
    os.close(root_fd)
    os.close(parent_fd)
PY
  printf 'cleaned: %s\n' "$SCRATCH_ROOT"
  exit 0
fi

guard_scratch prebuild
[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] || {
  echo "Fixed UI-test Info.plist is missing or unsafe." >&2
  exit 1
}

umask 077
cd "$REPO_ROOT/apps/HarvisBar"
/usr/bin/swift build \
  --scratch-path "$SWIFT_SCRATCH" \
  -c debug \
  --product HarvisBar \
  -Xswiftc -D \
  -Xswiftc HARVIS_VERSION_UI_TESTING \
  -Xswiftc -gnone \
  -Xswiftc -file-prefix-map \
  -Xswiftc "$REPO_ROOT=/src/harvis"

guard_scratch preassemble
readonly BUILT_BINARY="$SWIFT_SCRATCH/debug/HarvisBar"
/usr/bin/install -d -m 0700 "$TARGET_APP/Contents/MacOS"
/usr/bin/install -m 0644 "$INFO_PLIST" "$TARGET_APP/Contents/Info.plist"
/usr/bin/install -m 0755 "$BUILT_BINARY" "$TARGET_APP/Contents/MacOS/HarvisBar"
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$TARGET_APP"
/usr/bin/codesign --verify --strict "$TARGET_APP"
guard_scratch postbuild

printf 'built: %s\n' "$TARGET_APP"
