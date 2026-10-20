#!/usr/bin/env bash
set -euo pipefail

readonly FORMAL_HTTP_LABEL="local.harzva.harvis.http"
readonly FORMAL_TICK_LABEL="local.harzva.harvis.tick"

usage() {
  cat <<'EOF'
Usage:
  harvis_local_smoke.sh \
    --candidate <binary> --candidate-sha256 <sha256> \
    --rollback <binary> --rollback-sha256 <sha256> \
    --rollback-plugin-root <dir> --rollback-fixture-sha256 <sha256> \
    --port <port> --guard-path <formal-file> [--guard-path <formal-file> ...]

Environment equivalents:
  HARVIS_CANDIDATE_BIN   Candidate harvis binary.
  HARVIS_CANDIDATE_SHA256  Expected SHA-256 for the candidate binary.
  HARVIS_ROLLBACK_BIN    Trusted rollback harvis binary.
  HARVIS_ROLLBACK_SHA256  Expected SHA-256 for the rollback binary.
  HARVIS_ROLLBACK_PLUGIN_ROOT  Historical plugin root bound to the rollback.
  HARVIS_ROLLBACK_FIXTURE_SHA256  Expected rollback agent-pools fixture digest.
  HARVIS_SMOKE_PORT      Explicit nonzero loopback port.

The smoke accepts only artifacts whose provenance and expected SHA-256 were
verified before invocation. It runs both artifacts directly in isolated
temporary HOME, workspace, profile, and per-slot state trees. Environment
isolation is not a security sandbox: never pass an untrusted executable.
The script never invokes the Harvis service manager or writes a guard path.

Options:
  --candidate <binary>   Candidate artifact to exercise first.
  --candidate-sha256 <sha256>
                         Required expected digest for the candidate.
  --rollback <binary>    Trusted artifact to activate and exercise second.
  --rollback-sha256 <sha256>
                         Required expected digest for the rollback artifact.
  --rollback-plugin-root <dir>
                         Required historical plugin root bound to rollback.
  --rollback-fixture-sha256 <sha256>
                         Required digest of its agent-pools fixture.
  --port <port>          Required loopback port, range 1024-65535 except 8765.
  --guard-path <file>    Repeatable formal binary/metadata file to prove
                         unchanged. Temporary-directory paths are rejected.
  --self-test            Run shell syntax validation only.
  -h, --help             Show this help.
EOF
}

die() {
  printf 'harvis local smoke: %s\n' "$1" >&2
  exit 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  [[ "$#" -eq 1 ]] || die "--self-test does not accept other arguments"
  "${BASH:-bash}" -n "${BASH_SOURCE[0]}"
  printf '{"ok":true,"smoke":"harvis_local_smoke_static"}\n'
  exit 0
fi

candidate_bin="${HARVIS_CANDIDATE_BIN:-}"
candidate_expected_sha="${HARVIS_CANDIDATE_SHA256:-}"
rollback_bin="${HARVIS_ROLLBACK_BIN:-}"
rollback_expected_sha="${HARVIS_ROLLBACK_SHA256:-}"
rollback_plugin_root="${HARVIS_ROLLBACK_PLUGIN_ROOT:-}"
rollback_fixture_expected_sha="${HARVIS_ROLLBACK_FIXTURE_SHA256:-}"
smoke_port="${HARVIS_SMOKE_PORT:-}"
guard_paths=()

while (($# > 0)); do
  case "$1" in
    --candidate)
      [[ "$#" -ge 2 ]] || die "--candidate requires a value"
      candidate_bin="$2"
      shift 2
      ;;
    --candidate=*)
      candidate_bin="${1#*=}"
      shift
      ;;
    --rollback)
      [[ "$#" -ge 2 ]] || die "--rollback requires a value"
      rollback_bin="$2"
      shift 2
      ;;
    --rollback=*)
      rollback_bin="${1#*=}"
      shift
      ;;
    --candidate-sha256)
      [[ "$#" -ge 2 ]] || die "--candidate-sha256 requires a value"
      candidate_expected_sha="$2"
      shift 2
      ;;
    --candidate-sha256=*)
      candidate_expected_sha="${1#*=}"
      shift
      ;;
    --rollback-sha256)
      [[ "$#" -ge 2 ]] || die "--rollback-sha256 requires a value"
      rollback_expected_sha="$2"
      shift 2
      ;;
    --rollback-sha256=*)
      rollback_expected_sha="${1#*=}"
      shift
      ;;
    --rollback-plugin-root)
      [[ "$#" -ge 2 ]] || die "--rollback-plugin-root requires a value"
      rollback_plugin_root="$2"
      shift 2
      ;;
    --rollback-plugin-root=*)
      rollback_plugin_root="${1#*=}"
      shift
      ;;
    --rollback-fixture-sha256)
      [[ "$#" -ge 2 ]] || die "--rollback-fixture-sha256 requires a value"
      rollback_fixture_expected_sha="$2"
      shift 2
      ;;
    --rollback-fixture-sha256=*)
      rollback_fixture_expected_sha="${1#*=}"
      shift
      ;;
    --port)
      [[ "$#" -ge 2 ]] || die "--port requires a value"
      smoke_port="$2"
      shift 2
      ;;
    --port=*)
      smoke_port="${1#*=}"
      shift
      ;;
    --guard-path)
      [[ "$#" -ge 2 ]] || die "--guard-path requires a value"
      guard_paths+=("$2")
      shift 2
      ;;
    --guard-path=*)
      guard_paths+=("${1#*=}")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unsupported argument"
      ;;
  esac
done

[[ -n "$candidate_bin" ]] || die "candidate artifact is required"
[[ -n "$rollback_bin" ]] || die "rollback artifact is required"
[[ -n "$rollback_plugin_root" ]] || die "rollback plugin root is required"
[[ "$candidate_expected_sha" =~ ^[[:xdigit:]]{64}$ ]] ||
  die "candidate expected SHA-256 is required"
[[ "$rollback_expected_sha" =~ ^[[:xdigit:]]{64}$ ]] ||
  die "rollback expected SHA-256 is required"
[[ "$rollback_fixture_expected_sha" =~ ^[[:xdigit:]]{64}$ ]] ||
  die "rollback fixture expected SHA-256 is required"
candidate_expected_sha="$(printf '%s' "$candidate_expected_sha" | tr '[:upper:]' '[:lower:]')"
rollback_expected_sha="$(printf '%s' "$rollback_expected_sha" | tr '[:upper:]' '[:lower:]')"
rollback_fixture_expected_sha="$(printf '%s' "$rollback_fixture_expected_sha" | tr '[:upper:]' '[:lower:]')"
[[ -f "$candidate_bin" && -x "$candidate_bin" ]] ||
  die "candidate artifact must be an executable regular file"
[[ -f "$rollback_bin" && -x "$rollback_bin" ]] ||
  die "rollback artifact must be an executable regular file"

[[ -n "$smoke_port" ]] || die "an explicit smoke port is required"
[[ "$smoke_port" =~ ^[0-9]+$ ]] || die "port must be numeric"
smoke_port=$((10#$smoke_port))
((smoke_port >= 1024 && smoke_port <= 65535)) ||
  die "port must be between 1024 and 65535"
((smoke_port != 8765)) || die "the formal default port 8765 is not allowed"
[[ "${#guard_paths[@]}" -gt 0 ]] ||
  die "at least one formal --guard-path is required"

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

for command_name in awk curl env id install jq launchctl ln lsof mktemp mv openssl \
  perl ps python3 readlink shasum sleep sort tr; do
  require_command "$command_name"
done

formal_home="$(perl -e 'my @entry = getpwuid($<); exit 1 unless @entry; print $entry[7]')" ||
  die "could not resolve the account home from the current uid"
[[ "$formal_home" == /* && -d "$formal_home" ]] ||
  die "the uid account record has an invalid home directory"

normalized_guard_paths=()
for guard_path in "${guard_paths[@]}"; do
  [[ -f "$guard_path" ]] || die "guard path must resolve to an existing regular file"
  normalized_guard_path="$(python3 - "$guard_path" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]))
PY
)"
  resolved_guard_path="$(python3 - "$normalized_guard_path" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
  case "$normalized_guard_path" in
    /tmp/*|/private/tmp/*|/var/tmp/*)
      die "guard paths inside temporary directories are not allowed"
      ;;
  esac
  case "$resolved_guard_path" in
    /tmp/*|/private/tmp/*|/var/tmp/*)
      die "guard paths resolving inside temporary directories are not allowed"
      ;;
  esac
  duplicate_guard=0
  if [[ "${#normalized_guard_paths[@]}" -gt 0 ]]; then
    for existing_guard_path in "${normalized_guard_paths[@]}"; do
      [[ "$existing_guard_path" != "$normalized_guard_path" ]] || duplicate_guard=1
    done
  fi
  [[ "$duplicate_guard" -eq 1 ]] ||
    normalized_guard_paths+=("$normalized_guard_path")
done
guard_paths=("${normalized_guard_paths[@]}")

smoke_root=""
http_pid=""
http_pgid=""
worker_pid=""
worker_pgid=""
guard_snapshot_before=""
guard_snapshot_ready=0
guard_snapshot_verified=0
formal_process_snapshot_before=""

port_is_listening() {
  lsof -nP -a -iTCP:"$smoke_port" -sTCP:LISTEN -t >/dev/null 2>&1
}

wait_for_port_release() {
  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if ! port_is_listening; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

tracked_process_running() {
  local pid="$1"
  local pgid="$2"
  local parent_pid process_group process_state

  kill -0 "$pid" 2>/dev/null || return 1
  parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  process_group="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  process_state="$(ps -o stat= -p "$pid" 2>/dev/null | awk '{print $1}')"
  [[ "$parent_pid" == "$$" && "$process_group" == "$pgid" &&
     -n "$process_state" && "$process_state" != Z* ]]
}

process_group_running() {
  local pgid="$1"
  [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]] || return 1
  ps -axo pgid=,stat= 2>/dev/null |
    awk -v expected="$pgid" '$1 == expected && $2 !~ /^Z/ { found = 1 } END { exit !found }'
}

wait_for_process_group_setup() {
  local pid="$1"
  local attempt process_group
  for ((attempt = 0; attempt < 30; attempt++)); do
    process_group="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [[ "$process_group" == "$pid" ]] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

terminate_tracked_group() {
  local pgid="$1"
  local pid="$2"
  local attempt

  [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -eq "$pid" && "$pgid" -gt 1 ]] ||
    return 1
  if process_group_running "$pgid"; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    for ((attempt = 0; attempt < 50; attempt++)); do
      process_group_running "$pgid" || break
      sleep 0.1
    done
  fi

  if process_group_running "$pgid"; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
      process_group_running "$pgid" || break
      sleep 0.1
    done
  fi

  process_group_running "$pgid" && return 1
  wait "$pid" >/dev/null 2>&1 || true
  return 0
}

cleanup_http_process() {
  local pid="$http_pid"
  local pgid="$http_pgid"
  [[ -n "$pid" ]] || return 0

  terminate_tracked_group "$pgid" "$pid"
  local terminate_code=$?
  http_pid=""
  http_pgid=""
  return "$terminate_code"
}

cleanup_worker_process() {
  local pid="$worker_pid"
  local pgid="$worker_pgid"
  [[ -n "$pid" ]] || return 0

  terminate_tracked_group "$pgid" "$pid"
  local terminate_code=$?
  worker_pid=""
  worker_pgid=""
  return "$terminate_code"
}

snapshot_guard_paths() {
  python3 - "$@" <<'PY'
import hashlib
import json
import os
import stat
import sys


def digest_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def kind(mode):
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "directory"
    return "other"


rows = []
for path in sys.argv[1:]:
    row = {"path": path}
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        row["kind"] = "absent"
        rows.append(row)
        continue

    row.update(
        {
            "kind": kind(info.st_mode),
            "mode": format(stat.S_IMODE(info.st_mode), "04o"),
            "uid": info.st_uid,
            "gid": info.st_gid,
            "size": info.st_size,
        }
    )
    if stat.S_ISREG(info.st_mode):
        row["sha256"] = digest_file(path)
    elif stat.S_ISLNK(info.st_mode):
        row["link_target"] = os.readlink(path)
        try:
            target = os.stat(path)
            row["target_kind"] = kind(target.st_mode)
            row["target_mode"] = format(stat.S_IMODE(target.st_mode), "04o")
            row["target_uid"] = target.st_uid
            row["target_gid"] = target.st_gid
            if stat.S_ISREG(target.st_mode):
                row["target_sha256"] = digest_file(path)
        except FileNotFoundError:
            row["target_kind"] = "absent"
    rows.append(row)

print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
PY
}

snapshot_formal_processes() {
  local account_uid label launch_state launch_pid command_hash
  account_uid="$(id -u)"
  for label in "$FORMAL_HTTP_LABEL" "$FORMAL_TICK_LABEL"; do
    launch_state="$(
      launchctl print "gui/$account_uid/$label" 2>/dev/null |
        awk -F'= ' '/^[[:space:]]*state = / { print $2; exit }'
    )" || true
    launch_pid="$(
      launchctl print "gui/$account_uid/$label" 2>/dev/null |
        awk -F'= ' '/^[[:space:]]*pid = / { print $2; exit }'
    )" || true
    command_hash="absent"
    if [[ "$launch_pid" =~ ^[0-9]+$ ]]; then
      command_hash="$(
        ps -p "$launch_pid" -o command= 2>/dev/null |
          shasum -a 256 |
          awk '{print $1}'
      )" || command_hash="unavailable"
    fi
    printf '%s|%s|%s|%s\n' \
      "$label" "${launch_state:-absent}" "${launch_pid:-absent}" "$command_hash"
  done
  printf 'formal-port|'
  lsof -nP -a -iTCP:8765 -sTCP:LISTEN -t 2>/dev/null | sort -n | tr '\n' ',' || true
  printf '\n'
}

formal_guard_paths=(
  "$formal_home/Library/LaunchAgents/$FORMAL_HTTP_LABEL.plist"
  "$formal_home/Library/LaunchAgents/$FORMAL_TICK_LABEL.plist"
  "${guard_paths[@]}"
)

cleanup() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  set +e

  cleanup_worker_process || exit_code=1
  cleanup_http_process || exit_code=1

  if [[ "$guard_snapshot_ready" -eq 1 &&
        "$guard_snapshot_verified" -ne 1 ]]; then
    guard_snapshot_after="$(snapshot_guard_paths "${formal_guard_paths[@]}")"
    if [[ "$guard_snapshot_before" != "$guard_snapshot_after" ]]; then
      printf 'harvis local smoke: a formal guard path changed\n' >&2
      exit_code=1
    fi
    formal_process_snapshot_after="$(snapshot_formal_processes)"
    if [[ "$formal_process_snapshot_before" != "$formal_process_snapshot_after" ]]; then
      printf 'harvis local smoke: formal service process state changed\n' >&2
      exit_code=1
    fi
  fi

  if [[ -n "$smoke_root" && -d "$smoke_root" ]]; then
    case "$smoke_root" in
      /private/tmp/harvis-local-smoke.*)
        /bin/rm -rf -- "$smoke_root" || exit_code=1
        ;;
      *)
        printf 'harvis local smoke: refused to remove unexpected temp path\n' >&2
        exit_code=1
        ;;
    esac
  fi

  exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

smoke_root="$(mktemp -d /private/tmp/harvis-local-smoke.XXXXXX)"
smoke_home="$smoke_root/home"
smoke_workspace="$smoke_root/workspaces"
smoke_profile="$smoke_root/profiles"
smoke_tmp="$smoke_root/tmp"
smoke_plugin="$smoke_root/plugin"
release_root="$smoke_root/releases"
results_root="$smoke_root/results"
active_binary="$smoke_root/current"

mkdir -p \
  "$smoke_home" \
  "$smoke_workspace" \
  "$smoke_tmp" \
  "$smoke_plugin" \
  "$smoke_profile" \
  "$release_root/candidate" \
  "$release_root/rollback" \
  "$results_root"

port_is_listening && die "requested smoke port is already in use"

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

candidate_source_sha="$(hash_file "$candidate_bin")"
rollback_source_sha="$(hash_file "$rollback_bin")"
[[ "$candidate_source_sha" == "$candidate_expected_sha" ]] ||
  die "candidate source SHA-256 did not match the expected digest"
[[ "$rollback_source_sha" == "$rollback_expected_sha" ]] ||
  die "rollback source SHA-256 did not match the expected digest"

candidate_plugin_root="$(python3 - "$candidate_bin" <<'PY'
import pathlib
import sys

binary = pathlib.Path(sys.argv[1]).resolve(strict=True)
for root in binary.parents:
    if (
        (root / ".codex-plugin/plugin.json").is_file()
        and (root / "fixtures/agent-pools.sample.json").is_file()
    ):
        print(root)
        break
else:
    raise SystemExit(1)
PY
)" || die "candidate artifact is not inside a verified plugin stage"

rollback_plugin_root="$(python3 - "$rollback_plugin_root" <<'PY'
import pathlib
import sys

requested = pathlib.Path(sys.argv[1])
if requested.is_symlink():
    raise SystemExit(1)
root = requested.resolve(strict=True)
if not root.is_dir():
    raise SystemExit(1)
for relative in (".codex-plugin/plugin.json", "fixtures/agent-pools.sample.json"):
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise SystemExit(1)
print(root)
PY
)" || die "rollback plugin root is missing its fixed regular files"
rollback_fixture="$rollback_plugin_root/fixtures/agent-pools.sample.json"
[[ "$(hash_file "$rollback_fixture")" == "$rollback_fixture_expected_sha" ]] ||
  die "rollback fixture SHA-256 did not match the expected digest"

formal_guard_paths+=(
  "$candidate_plugin_root/.codex-plugin/plugin.json"
  "$candidate_plugin_root/fixtures/agent-pools.sample.json"
  "$rollback_plugin_root/.codex-plugin/plugin.json"
  "$rollback_fixture"
)
guard_snapshot_before="$(snapshot_guard_paths "${formal_guard_paths[@]}")"
formal_process_snapshot_before="$(snapshot_formal_processes)"
guard_snapshot_ready=1

install -m 0700 "$candidate_bin" "$release_root/candidate/harvis"
install -m 0700 "$rollback_bin" "$release_root/rollback/harvis"

candidate_sha="$(hash_file "$release_root/candidate/harvis")"
rollback_sha="$(hash_file "$release_root/rollback/harvis")"
[[ "$candidate_sha" == "$candidate_expected_sha" ]] ||
  die "copied candidate SHA-256 did not match the expected digest"
[[ "$rollback_sha" == "$rollback_expected_sha" ]] ||
  die "copied rollback SHA-256 did not match the expected digest"
[[ "$candidate_sha" != "$rollback_sha" ]] ||
  die "candidate and rollback artifacts must have different hashes"

verify_signature_if_present() {
  local artifact="$1"
  if command -v codesign >/dev/null 2>&1 &&
     codesign -dv "$artifact" >/dev/null 2>&1; then
    codesign --verify --strict "$artifact" >/dev/null 2>&1 ||
      die "an artifact has an invalid code signature"
  fi
}

verify_signature_if_present "$release_root/candidate/harvis"
verify_signature_if_present "$release_root/rollback/harvis"

activate_slot() {
  local slot="$1"
  local target expected actual next_link

  case "$slot" in
    candidate)
      expected="$candidate_sha"
      ;;
    rollback)
      expected="$rollback_sha"
      ;;
    *)
      die "invalid release slot"
      ;;
  esac

  target="releases/$slot/harvis"
  next_link="$smoke_root/current.next"
  [[ ! -e "$next_link" && ! -L "$next_link" ]] ||
    die "temporary activation link already exists"

  ln -s "$target" "$next_link"
  mv -f "$next_link" "$active_binary"

  [[ "$(readlink "$active_binary")" == "$target" ]] ||
    die "release activation link verification failed"
  actual="$(hash_file "$active_binary")"
  [[ "$actual" == "$expected" ]] ||
    die "active artifact hash verification failed"
}

token_file="$smoke_root/http.token"
curl_config="$smoke_root/curl-auth.cfg"
umask 077
openssl rand -hex 32 > "$token_file"
[[ -s "$token_file" ]] || die "failed to create an ephemeral HTTP token"
chmod 0600 "$token_file"
printf 'header = "Authorization: Bearer %s"\n' \
  "$(tr -d '\r\n' < "$token_file")" > "$curl_config"
chmod 0600 "$curl_config"

base_env=(
  env -i
  "HOME=$smoke_home"
  "TMPDIR=$smoke_tmp"
  "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  "LANG=C"
  "LC_ALL=C"
  "TZ=UTC"
  "HARVIS_HTTP_AUTH_TOKEN_FILE=$token_file"
  "NO_PROXY=127.0.0.1,localhost,::1"
  "no_proxy=127.0.0.1,localhost,::1"
)

slot_env=()
slot_state=""
slot_workspace=""
slot_profile=""
slot_plugin_root=""
set_slot_env() {
  local slot="$1"
  case "$slot" in
    candidate|rollback) ;;
    *) die "invalid environment slot" ;;
  esac
  slot_workspace="$smoke_workspace/$slot"
  slot_profile="$smoke_profile/$slot"
  slot_state="$slot_workspace/.harvis"
  case "$slot" in
    candidate) slot_plugin_root="$candidate_plugin_root" ;;
    rollback) slot_plugin_root="$rollback_plugin_root" ;;
  esac
  slot_env=(
    "${base_env[@]}"
    "HARVIS_HOME=$slot_profile"
    "HARVIS_PLUGIN_ROOT=$slot_plugin_root"
    "HARVIS_STATE_ROOT=$slot_state"
  )
}

curl_base=(
  curl -q
  --noproxy '*'
  --proto '=http'
  --silent
  --show-error
  --connect-timeout 1
  --max-time 2
)

run_process_bounded() {
  local label="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local wait_code
  shift 3

  perl -e 'my $seconds = shift @ARGV; setpgrp(0, 0); alarm $seconds; exec @ARGV; exit 127' \
    30 "$@" > "$stdout_file" 2> "$stderr_file" &
  worker_pid=$!
  worker_pgid="$worker_pid"
  if ! wait_for_process_group_setup "$worker_pid" &&
     kill -0 "$worker_pid" 2>/dev/null; then
    cleanup_worker_process || true
    die "$label did not establish an isolated process group"
  fi

  set +e
  wait "$worker_pid"
  wait_code=$?
  set -e
  worker_pid=""
  if process_group_running "$worker_pgid"; then
    terminate_tracked_group "$worker_pgid" "$worker_pgid" || true
    worker_pgid=""
    die "$label left a descendant process"
  fi
  worker_pgid=""
  case "$wait_code" in
    0) ;;
    142) die "$label timed out" ;;
    *) die "$label failed" ;;
  esac
}

activate_slot candidate

verify_active_slot() {
  local slot="$1"
  local expected
  case "$slot" in
    candidate) expected="$candidate_sha" ;;
    rollback) expected="$rollback_sha" ;;
    *) die "invalid release slot" ;;
  esac
  [[ "$(hash_file "$active_binary")" == "$expected" ]] ||
    die "$slot artifact is not active"
}

run_bounded_tick() {
  local slot="$1"
  local expected_state expected_workspace verify_log

  set_slot_env "$slot"
  verify_log="$results_root/$slot.verify.stderr"
  [[ ! -e "$slot_state/status.json" ]] ||
    die "$slot state was not pristine before its tick"
  run_process_bounded \
    "$slot bounded tick" \
    "$results_root/$slot.tick.stdout" \
    "$results_root/$slot.tick.stderr" \
    "${slot_env[@]}" "$active_binary" run-tick \
    --root "$slot_workspace" \
    --profile-root "$slot_profile" \
    --loop \
    --interval 1 \
    --max-ticks 2

  [[ -s "$slot_state/status.json" ]] ||
    die "$slot tick did not write isolated status"

  expected_state="$(cd "$slot_state" && pwd -P)"
  expected_workspace="$(cd "$slot_workspace" && pwd -P)"
  jq -e \
    --arg state "$expected_state" \
    --arg workspace "$expected_workspace" \
    '.state_root == $state
      and .workspace_root == $workspace
      and .state_store == "workspace"
      and (.errors | length) == 0' \
    "$slot_state/status.json" \
    >/dev/null 2>> "$verify_log" ||
    die "$slot isolated tick status verification failed"
}

wait_for_http_ready() {
  local base_url="$1"
  local error_log="$2"
  local attempt

  for ((attempt = 0; attempt < 40; attempt++)); do
    tracked_process_running "$http_pid" "$http_pgid" || return 1
    if "${curl_base[@]}" \
      --connect-timeout 0.2 \
      --max-time 0.5 \
      --fail \
      "$base_url/health" \
      2>> "$error_log" |
      jq -e \
        '.ok == true
          and .data.runtime == "rust"
          and .data.auth_required == true' \
        >/dev/null 2>> "$error_log"; then
      listener_owned_by_http_pid || return 1
      return 0
    fi
    sleep 0.1
  done
  return 1
}

listener_owned_by_http_pid() {
  local owner found=0
  while IFS= read -r owner; do
    [[ -n "$owner" ]] || continue
    [[ "$owner" == "$http_pid" ]] || return 1
    found=1
  done < <(lsof -nP -a -iTCP:"$smoke_port" -sTCP:LISTEN -t 2>/dev/null)
  [[ "$found" -eq 1 ]]
}

stop_http_strict() {
  local slot="$1"
  local pid="$http_pid"
  local pgid="$http_pgid"
  local attempt stopped=0 forced=0 wait_code

  [[ -n "$pid" && -n "$pgid" && "$pid" == "$pgid" ]] ||
    die "$slot HTTP PID or process group is missing"
  tracked_process_running "$pid" "$pgid" || {
    terminate_tracked_group "$pgid" "$pid" || true
    wait "$pid" >/dev/null 2>&1 || true
    http_pid=""
    http_pgid=""
    die "$slot HTTP process exited before the stop gate"
  }
  listener_owned_by_http_pid ||
    die "$slot HTTP listener is not owned by the tracked PID"

  kill -TERM -- "-$pgid" || die "$slot HTTP process-group TERM failed"
  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! process_group_running "$pgid"; then
      stopped=1
      break
    fi
    sleep 0.1
  done

  if [[ "$stopped" -ne 1 ]]; then
    forced=1
    kill -KILL -- "-$pgid" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
      if ! process_group_running "$pgid"; then
        stopped=1
        break
      fi
      sleep 0.1
    done
  fi

  [[ "$stopped" -eq 1 ]] || die "$slot HTTP process could not be stopped"

  set +e
  wait "$pid"
  wait_code=$?
  set -e
  http_pid=""
  http_pgid=""

  [[ "$forced" -eq 0 ]] || die "$slot HTTP process ignored TERM"

  case "$wait_code" in
    0|143) ;;
    *) die "$slot HTTP process returned an unexpected stop status" ;;
  esac

  wait_for_port_release || die "$slot HTTP port was not released"
}

run_http_checks() {
  local slot="$1"
  local base_url="http://127.0.0.1:$smoke_port"
  local curl_error_log="$results_root/$slot.curl.stderr"
  local health_file="$results_root/$slot.health.json"
  local bootstrap_file="$results_root/$slot.bootstrap.json"
  local status_file="$results_root/$slot.http-status.json"
  local agent_card_file="$results_root/$slot.agent-card.json"
  local unauthorized_code expected_workspace expected_state

  set_slot_env "$slot"
  port_is_listening && die "$slot HTTP port is already occupied"

  perl -e 'setpgrp(0, 0); exec @ARGV; exit 127' \
    "${slot_env[@]}" "$active_binary" http \
    --host 127.0.0.1 \
    --port "$smoke_port" \
    --root "$slot_workspace" \
    --plugin-root "$smoke_plugin" \
    --auth-token-file "$token_file" \
    > "$results_root/$slot.http.stdout" \
    2> "$results_root/$slot.http.stderr" &
  http_pid=$!
  http_pgid="$http_pid"
  wait_for_process_group_setup "$http_pid" || {
    cleanup_http_process || true
    die "$slot HTTP process did not establish an isolated process group"
  }

  wait_for_http_ready "$base_url" "$curl_error_log" ||
    die "$slot HTTP process did not become ready"

  "${curl_base[@]}" --fail "$base_url/health" \
    > "$health_file" 2>> "$curl_error_log" ||
    die "$slot HTTP health request failed"
  jq -e \
    '.ok == true
      and .data.runtime == "rust"
      and .data.auth_required == true' \
    "$health_file" >/dev/null 2>> "$curl_error_log" ||
    die "$slot HTTP health response failed validation"

  unauthorized_code="$(
    "${curl_base[@]}" \
      --get \
      --data-urlencode "root=$slot_workspace" \
      --data-urlencode "profile_root=$slot_profile" \
      --output /dev/null \
      --write-out '%{http_code}' \
      "$base_url/status" \
      2>> "$curl_error_log"
  )" || die "$slot unauthenticated status request failed"
  [[ "$unauthorized_code" == "401" ]] ||
    die "$slot protected status endpoint did not require authentication"

  "${curl_base[@]}" \
    --config "$curl_config" \
    --fail \
    --get \
    --data-urlencode "root=$slot_workspace" \
    --data-urlencode "profile_root=$slot_profile" \
    "$base_url/status" \
    > "$status_file" 2>> "$curl_error_log" ||
    die "$slot authenticated status request failed"

  expected_workspace="$(cd "$slot_workspace" && pwd -P)"
  expected_state="$(cd "$slot_state" && pwd -P)"
  jq -e \
    --arg workspace "$expected_workspace" \
    --arg state "$expected_state" \
    '.ok == true
      and .data.workspace_root == $workspace
      and .data.status.state_root == $state
      and (.data.status.errors | length) == 0' \
    "$status_file" >/dev/null 2>> "$curl_error_log" ||
    die "$slot authenticated status response failed validation"

  "${curl_base[@]}" --fail "$base_url/ui/bootstrap" \
    > "$bootstrap_file" 2>> "$curl_error_log" ||
    die "$slot bootstrap request failed"
  jq -e \
    --arg workspace "$expected_workspace" \
    '.ok == true
      and .data.workspace_root == $workspace
      and .data.auth_required == true
      and .data.token_included == false
      and .data.network_scope == "loopback"' \
    "$bootstrap_file" >/dev/null 2>> "$curl_error_log" ||
    die "$slot bootstrap response failed validation"

  "${curl_base[@]}" \
    --config "$curl_config" \
    --fail \
    "$base_url/.well-known/agent-card.json" \
    > "$agent_card_file" 2>> "$curl_error_log" ||
    die "$slot Agent Card request failed"
  jq -e \
    --arg endpoint "$base_url/a2a/jsonrpc" \
    '.url == $endpoint
      and .supportedInterfaces[0].url == $endpoint
      and .supportedInterfaces[0].protocolBinding == "JSONRPC"' \
    "$agent_card_file" >/dev/null 2>> "$curl_error_log" ||
    die "$slot Agent Card response failed validation"

  stop_http_strict "$slot"
}

exercise_slot() {
  local slot="$1"
  local rollback_agent_pools

  verify_active_slot "$slot"
  set_slot_env "$slot"
  [[ ! -e "$slot_workspace" ]] || die "$slot workspace was not pristine"
  mkdir -p "$slot_workspace"

  if [[ "$slot" == "rollback" ]]; then
    # The trusted legacy rollback artifact predates relocatable fixture lookup:
    # its fallback fixture path embeds the former source tree.  That initializer
    # intentionally preserves an existing registry unless --force is supplied,
    # so preseed its hash-pinned historical fixture in the pristine isolated
    # state tree.  The rollback artifact then performs its own init-workspace,
    # profile, tick, and HTTP checks without touching the hard-coded fallback.
    mkdir -p "$slot_state"
    [[ -d "$slot_state" && ! -L "$slot_state" ]] ||
      die "rollback preseed did not create a fixed state directory"
    rollback_agent_pools="$slot_state/agent-pools.json"
    [[ ! -e "$rollback_agent_pools" && ! -L "$rollback_agent_pools" ]] ||
      die "rollback agent-pools destination was not pristine"
    install -m 0600 "$rollback_fixture" "$rollback_agent_pools"
    [[ -f "$rollback_agent_pools" && ! -L "$rollback_agent_pools" ]] ||
      die "rollback agent-pools preseed is not a fixed regular file"
    [[ "$(hash_file "$rollback_agent_pools")" == "$rollback_fixture_expected_sha" ]] ||
      die "rollback agent-pools preseed failed digest verification"
  fi
  run_process_bounded \
    "$slot workspace initialization" \
    "$results_root/$slot.init-workspace.stdout" \
    "$results_root/$slot.init-workspace.stderr" \
    "${slot_env[@]}" "$active_binary" init-workspace \
    --root "$slot_workspace"

  if [[ "$slot" == "rollback" ]]; then
    [[ -f "$rollback_agent_pools" && ! -L "$rollback_agent_pools" ]] ||
      die "rollback initializer replaced the fixed agent-pools preseed"
    [[ "$(hash_file "$rollback_agent_pools")" == "$rollback_fixture_expected_sha" ]] ||
      die "rollback initializer changed the agent-pools preseed"
  fi

  run_process_bounded \
    "$slot profile initialization" \
    "$results_root/$slot.init-profile.stdout" \
    "$results_root/$slot.init-profile.stderr" \
    "${slot_env[@]}" "$active_binary" init-profile \
    --profile-root "$slot_profile"
  run_bounded_tick "$slot"
  run_http_checks "$slot"
  verify_active_slot "$slot"
}

exercise_slot candidate

[[ -z "$http_pid" ]] || die "candidate HTTP process was not reaped"
port_is_listening && die "candidate HTTP listener remained before rollback"

activate_slot rollback
exercise_slot rollback

[[ "$(readlink "$active_binary")" == "releases/rollback/harvis" ]] ||
  die "rollback slot is not active at the final gate"
[[ "$(hash_file "$active_binary")" == "$rollback_sha" ]] ||
  die "rollback artifact hash failed at the final gate"

guard_snapshot_after="$(snapshot_guard_paths "${formal_guard_paths[@]}")"
[[ "$guard_snapshot_before" == "$guard_snapshot_after" ]] ||
  die "a formal guard path changed"
formal_process_snapshot_after="$(snapshot_formal_processes)"
[[ "$formal_process_snapshot_before" == "$formal_process_snapshot_after" ]] ||
  die "formal service process state changed"
guard_snapshot_verified=1

printf '{"ok":true,"smoke":"harvis_local_candidate_rollback","final_slot":"rollback","candidate_sha256":"%s","rollback_sha256":"%s","rollback_fixture_sha256":"%s"}\n' \
  "$candidate_sha" "$rollback_sha" "$rollback_fixture_expected_sha"
