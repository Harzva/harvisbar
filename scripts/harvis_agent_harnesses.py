#!/usr/bin/env python3
"""Safe local agent-harness preflight status for H.A.R.V.I.S. UI surfaces."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "harvis.agent-harnesses.v0"
DEFAULT_TIMEOUT_SECONDS = 120


@dataclass(frozen=True)
class HarnessSpec:
    harness_id: str
    label: str
    pool_kind: str
    runtime: str
    model: str
    commands: tuple[str, ...]
    posix_wrapper: str | None
    windows_wrapper: str | None
    review_scripts: tuple[str, ...]
    smoke_test_target: bool = False
    requires_skill: bool = True
    requires_wrapper: bool = True
    version_args: tuple[str, ...] = ("--version",)


HARNESS_SPECS: tuple[HarnessSpec, ...] = (
    HarnessSpec(
        harness_id="codex",
        label="Codex CLI",
        pool_kind="harness",
        runtime="codex-cli",
        model="openai:gpt-5-codex",
        commands=("codex",),
        posix_wrapper=None,
        windows_wrapper=None,
        review_scripts=(),
        requires_skill=False,
        requires_wrapper=False,
    ),
    HarnessSpec(
        harness_id="dsh",
        label="Digital-Me DSH",
        pool_kind="harness",
        runtime="dsh-cordis",
        model="dsh:profile-default",
        commands=("dsh",),
        posix_wrapper=None,
        windows_wrapper=None,
        review_scripts=(),
        requires_skill=False,
        requires_wrapper=False,
    ),
    HarnessSpec(
        harness_id="kimicode",
        label="Kimi Code",
        pool_kind="harness",
        runtime="kimi-code",
        model="moonshot-kimi:kimi-code/kimi-for-coding",
        commands=("kimicode", "kimi"),
        posix_wrapper=None,
        windows_wrapper=None,
        review_scripts=(),
        requires_skill=False,
        requires_wrapper=False,
    ),
    HarnessSpec(
        harness_id="claude-code",
        label="Claude Code",
        pool_kind="harness",
        runtime="claude-code",
        model="anthropic:claude-code-default",
        commands=("claude",),
        posix_wrapper=None,
        windows_wrapper=None,
        review_scripts=(),
        requires_skill=False,
        requires_wrapper=False,
    ),
    HarnessSpec(
        harness_id="likecode",
        label="LikeCode",
        pool_kind="harness",
        runtime="likecode",
        model="likecode:d4p/deepseek-v4-pro",
        commands=("likecode",),
        posix_wrapper=None,
        windows_wrapper=None,
        review_scripts=(),
        smoke_test_target=True,
        requires_skill=False,
        requires_wrapper=False,
    ),
    HarnessSpec(
        harness_id="cxspark",
        label="CX Spark",
        pool_kind="runtime-preset",
        runtime="codex-cli",
        model="openai:gpt-5.3-codex-spark",
        commands=("codex",),
        posix_wrapper="cxspark.sh",
        windows_wrapper="cxspark.ps1",
        review_scripts=("cxspark-mark-reviewed.sh", "cxspark-mark-reviewed.ps1"),
        smoke_test_target=True,
    ),
)


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def home_root() -> Path:
    value = os.environ.get("HARVIS_AGENT_HARNESS_HOME") or os.environ.get("USERPROFILE") or os.environ.get("HOME")
    return Path(value or "~").expanduser()


def skills_root() -> Path:
    value = os.environ.get("HARVIS_AGENT_HARNESS_SKILLS_ROOT")
    if value:
        return Path(value).expanduser()
    return home_root() / ".codex" / "skills"


def redact_local_paths(value: str, limit: int = 180) -> str:
    text = value.strip().replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"/Users/[^/\s]+", "~", text)
    text = re.sub(r"/Volumes/[^/\s]+", "[volume]", text)
    text = re.sub(r"[A-Za-z]:\\Users\\[^\\\s]+", "~", text)
    home = str(home_root())
    if home:
        text = text.replace(home, "~")
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        return text[: limit - 1].rstrip() + "..."
    return text


def command_path(names: tuple[str, ...]) -> str | None:
    for name in names:
        if shutil.which(name):
            return name
    return None


def native_wrapper_name(spec: HarnessSpec) -> str | None:
    if platform.system().lower().startswith("win"):
        return spec.windows_wrapper
    return spec.posix_wrapper


def wrapper_status(spec: HarnessSpec, skill_dir: Path) -> dict[str, Any]:
    script_dir = skill_dir / "scripts"
    native = native_wrapper_name(spec)
    wrapper_names = [item for item in [spec.posix_wrapper, spec.windows_wrapper] if item]
    wrapper_present = any((script_dir / item).exists() for item in wrapper_names)
    native_present = bool(native and (script_dir / native).exists())
    review_present = any((script_dir / item).exists() for item in spec.review_scripts)
    return {
        "wrapperPresent": wrapper_present,
        "nativeWrapperPresent": native_present,
        "reviewMarkerPresent": review_present,
        "nativeWrapperKind": "powershell" if native and native.endswith(".ps1") else ("shell" if native else "none"),
    }


def count_runs(harness_id: str) -> dict[str, Any]:
    run_dir = home_root() / ".codex" / f"{harness_id}-runs"
    if not run_dir.exists():
        return {
            "pendingReviews": 0,
            "reviewedRuns": 0,
            "latestRun": None,
        }

    pending = []
    reviewed = list(run_dir.glob("*-reviewed.json"))
    for item in run_dir.glob("*-pending.json"):
        if run_file_is_reviewed(item):
            reviewed.append(item)
        else:
            pending.append(item)
    pending = sorted(pending, key=lambda item: item.stat().st_mtime, reverse=True)
    reviewed = sorted(reviewed, key=lambda item: item.stat().st_mtime, reverse=True)
    latest_path = (pending + reviewed)[:1]
    latest = read_run_meta(latest_path[0]) if latest_path else None
    return {
        "pendingReviews": len(pending),
        "reviewedRuns": len(reviewed),
        "latestRun": latest,
    }


def run_file_is_reviewed(path: Path) -> bool:
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return False
    if not isinstance(loaded, dict):
        return False
    return loaded.get("codex_reviewed") is True


def read_run_meta(path: Path) -> dict[str, Any] | None:
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(loaded, dict):
        return None
    return {
        "tool": loaded.get("tool") if isinstance(loaded.get("tool"), str) else None,
        "model": loaded.get("model") if isinstance(loaded.get("model"), str) else None,
        "stage": loaded.get("stage") if isinstance(loaded.get("stage"), str) else None,
        "failureKind": loaded.get("failure_kind") if isinstance(loaded.get("failure_kind"), str) else None,
        "exitCode": loaded.get("exit_code") if isinstance(loaded.get("exit_code"), int) else None,
        "finishedAt": loaded.get("finished_at") if isinstance(loaded.get("finished_at"), str) else None,
        "codexReviewed": loaded.get("codex_reviewed") if isinstance(loaded.get("codex_reviewed"), bool) else None,
    }


def run_preflight_command(command: str | None, args: tuple[str, ...], timeout_seconds: int) -> dict[str, Any]:
    if not command:
        return {
            "status": "skipped",
            "exitCode": None,
            "summary": "CLI command is not on PATH.",
        }
    try:
        completed = subprocess.run(
            [command, *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        return {
            "status": "failed",
            "exitCode": 124,
            "summary": f"{command} preflight timed out.",
        }
    except OSError as exc:
        return {
            "status": "failed",
            "exitCode": None,
            "summary": redact_local_paths(str(exc)),
        }

    text = completed.stdout.strip() or completed.stderr.strip()
    summary = redact_local_paths(text.splitlines()[0] if text else f"{command} returned no output.")
    return {
        "status": "passed" if completed.returncode == 0 else "failed",
        "exitCode": completed.returncode,
        "summary": summary,
    }


def model_smoke_args(spec: HarnessSpec, output_path: Path) -> list[str]:
    prompt = "Availability smoke test only. Do not inspect or modify files. Reply exactly OK."
    if spec.harness_id == "cxspark":
        return [
            "exec",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--ephemeral",
            "--model",
            "gpt-5.3-codex-spark",
            "--sandbox",
            "danger-full-access",
            "--output-last-message",
            str(output_path),
            "--color",
            "never",
            "-c",
            'model_reasoning_effort="low"',
            "--disable",
            "hooks",
            "--dangerously-bypass-approvals-and-sandbox",
            prompt,
        ]
    if spec.harness_id == "likecode":
        return [
            "-p",
            "--model",
            "d4p",
            "--permission-mode",
            "plan",
            "--no-session-persistence",
            "--output-format",
            "text",
            prompt,
        ]
    return spec.version_args and list(spec.version_args) or []


def run_model_smoke_test(spec: HarnessSpec, command: str | None, timeout_seconds: int) -> dict[str, Any]:
    if not spec.smoke_test_target:
        return {
            "status": "not-run",
            "exitCode": None,
            "summary": "This harness is shown in status but not part of Test All.",
            "kind": "not-targeted",
        }
    if not command:
        return {
            "status": "skipped",
            "exitCode": None,
            "summary": "CLI command is not on PATH.",
            "kind": "model-smoke",
        }
    with tempfile.TemporaryDirectory(prefix=f"harvis-{spec.harness_id}-smoke-") as tmp:
        tmp_path = Path(tmp)
        output_path = tmp_path / "last-message.txt"
        args = model_smoke_args(spec, output_path)
        try:
            completed = subprocess.run(
                [command, *args],
                check=False,
                capture_output=True,
                cwd=tmp_path,
                text=True,
                timeout=timeout_seconds,
            )
        except subprocess.TimeoutExpired:
            return {
                "status": "failed",
                "exitCode": 124,
                "summary": f"{spec.label} model smoke test timed out.",
                "kind": "model-smoke",
            }
        except OSError as exc:
            return {
                "status": "failed",
                "exitCode": None,
                "summary": redact_local_paths(str(exc)),
                "kind": "model-smoke",
            }

        output_text = ""
        if output_path.exists():
            output_text = output_path.read_text(encoding="utf-8", errors="replace")
        combined = "\n".join([output_text, completed.stdout, completed.stderr]).strip()
        first_line = combined.splitlines()[0] if combined else f"{spec.label} returned no output."
        ok_seen = "OK" in combined.upper()
        status = "passed" if completed.returncode == 0 and ok_seen else "failed"
        summary = f"{spec.label} smoke test returned OK." if status == "passed" else redact_local_paths(first_line)
        return {
            "status": status,
            "exitCode": completed.returncode,
            "summary": summary,
            "kind": "model-smoke",
        }


def derive_harness_state(
    requires_skill: bool,
    requires_wrapper: bool,
    skill_present: bool,
    wrapper: dict[str, Any],
    cli_present: bool,
    pending_reviews: int,
    test_status: str | None,
) -> tuple[str, str]:
    if requires_skill and not skill_present:
        return "unavailable", "Skill directory is not installed."
    if requires_wrapper and not wrapper["wrapperPresent"]:
        return "unavailable", "Delegation wrapper is missing."
    if not cli_present:
        return "unavailable", "CLI command is not on PATH."
    if test_status == "passed":
        if pending_reviews:
            return "ready", f"Smoke test passed; {pending_reviews} pending review record(s) still need audit."
        return "ready", "Smoke test passed."
    if test_status == "failed":
        return "failed", "Smoke test failed."
    if requires_wrapper and not wrapper["nativeWrapperPresent"]:
        return "partial", "Wrapper exists, but this platform has no native wrapper."
    if pending_reviews:
        return "ready", f"Preflight prerequisites are present; {pending_reviews} pending review record(s) still need audit."
    return "ready", "Preflight prerequisites are present."


def build_harness_item(
    spec: HarnessSpec,
    run_tests: bool,
    timeout_seconds: int,
) -> dict[str, Any]:
    skill_dir = skills_root() / spec.harness_id
    skill_present = skill_dir.exists()
    wrapper = wrapper_status(spec, skill_dir)
    command = command_path(spec.commands)
    runs = count_runs(spec.harness_id)
    test = {
        "status": "not-run",
        "exitCode": None,
        "summary": "Model smoke test has not been run in this response.",
        "kind": "model-smoke",
    }
    if run_tests:
        test = run_model_smoke_test(spec, command, timeout_seconds)
    state, summary = derive_harness_state(
        requires_skill=spec.requires_skill,
        requires_wrapper=spec.requires_wrapper,
        skill_present=skill_present,
        wrapper=wrapper,
        cli_present=command is not None,
        pending_reviews=int(runs["pendingReviews"]),
        test_status=test["status"] if run_tests else None,
    )
    return {
        "id": spec.harness_id,
        "label": spec.label,
        "poolKind": spec.pool_kind,
        "runtime": spec.runtime,
        "model": spec.model,
        "status": state,
        "summary": summary,
        "requiresSkill": spec.requires_skill,
        "requiresWrapper": spec.requires_wrapper,
        "skillPresent": skill_present,
        "wrapperPresent": wrapper["wrapperPresent"],
        "nativeWrapperPresent": wrapper["nativeWrapperPresent"],
        "reviewMarkerPresent": wrapper["reviewMarkerPresent"],
        "nativeWrapperKind": wrapper["nativeWrapperKind"],
        "cliPresent": command is not None,
        "cliCommand": command,
        "pendingReviews": runs["pendingReviews"],
        "reviewedRuns": runs["reviewedRuns"],
        "latestRun": runs["latestRun"],
        "testTarget": spec.smoke_test_target,
        "test": test,
    }


def summarize(items: list[dict[str, Any]], run_tests: bool) -> tuple[str, str]:
    if run_tests:
        targets = [item for item in items if item.get("testTarget")]
        failed = sum(1 for item in targets if item.get("test", {}).get("status") == "failed")
        skipped = sum(1 for item in targets if item.get("test", {}).get("status") == "skipped")
        passed = sum(1 for item in targets if item.get("test", {}).get("status") == "passed")
        if failed:
            return "failed", f"{failed} model smoke test(s) failed; {passed} passed, {skipped} skipped."
        if skipped:
            return "degraded", f"{passed} model smoke test(s) passed; {skipped} skipped."
        return "ready", f"{passed} model smoke test(s) passed."
    pending = sum(1 for item in items if item["status"] == "needs_review")
    failed = sum(1 for item in items if item["status"] == "failed")
    unavailable = sum(1 for item in items if item["status"] == "unavailable")
    partial = sum(1 for item in items if item["status"] == "partial")
    ready = sum(1 for item in items if item["status"] == "ready")
    if pending:
        return "needs_review", f"{pending} harness run(s) are pending Codex review."
    if failed:
        return "failed", f"{failed} harness preflight test(s) failed."
    if unavailable or partial:
        return "degraded", f"{ready} ready, {partial} partial, {unavailable} unavailable."
    return "ready", f"{ready} harness(es) detected and ready."


def build_agent_harness_status(
    run_tests: bool = False,
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    timeout_seconds = max(1, min(timeout_seconds, 600))
    items = [build_harness_item(spec, run_tests, timeout_seconds) for spec in HARNESS_SPECS]
    status, summary = summarize(items, run_tests)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "safeForHarvisBar": True,
        "generatedAt": now_utc(),
        "status": status,
        "summary": summary,
        "testPolicy": "model-smoke-targets" if run_tests else "status-only",
        "includesModelCalls": run_tests,
        "includesSecrets": False,
        "includesLocalAbsolutePaths": False,
        "items": items,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect local agent harness preflight status.")
    parser.add_argument("--test", action="store_true", help="Run one-shot CLI version preflight tests.")
    parser.add_argument("--timeout-seconds", type=int, default=DEFAULT_TIMEOUT_SECONDS)
    args = parser.parse_args()
    print(
        json.dumps(
            build_agent_harness_status(run_tests=args.test, timeout_seconds=args.timeout_seconds),
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("agent-harnesses", legacy_main=main))
