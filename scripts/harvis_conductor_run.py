#!/usr/bin/env python3
"""Create and run H.A.R.V.I.S. conductor contract files.

Harvis owns message intake, policy, cards, and logs. Codex owns dynamic
planning. This helper writes a compact contract for tasks that should be
handled by a Codex Conductor instead of a fixed Harvis workflow, and can also
invoke Codex as that conductor.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "harvis.conductor-task.v0"
EVENT_SCHEMA_VERSION = "harvis.conductor-events.v0"
WORKER_REGISTRY_VERSION = "harvis.worker-registry.v0"
USER_HOME = Path.home()
DEFAULT_WEMEDIA_ROOT = os.environ.get("HARVIS_WEMEDIA_ROOT", str(Path.cwd()))
DEFAULT_CHAIR_HOME = str(USER_HOME / ".harvis" / "codex-conductor-chair")
CHAIR_EXTRA_WRITABLE_DIRS = [
    USER_HOME / ".kimi-code",
    USER_HOME / ".harvis",
]
PLUGIN_ROOT = Path(__file__).resolve().parents[1]
WEMEDIA_PLAYBOOK = PLUGIN_ROOT / "references" / "playbooks" / "wemedia-wechat-draft.md"


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_text(path: Path | None, limit: int = 20000) -> str:
    if not path or not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")[:limit]


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")


def ensure_chair_home(chair_home: Path) -> None:
    chair_home.mkdir(parents=True, exist_ok=True)
    for writable_dir in CHAIR_EXTRA_WRITABLE_DIRS:
        Path(writable_dir).mkdir(parents=True, exist_ok=True)
    config_path = chair_home / "config.toml"
    if not config_path.exists():
        config_path.write_text(
            """# H.A.R.V.I.S. Codex Conductor Chair config.
# This home is intentionally separate from ~/.codex so the
# conductor role can evolve without mutating the normal interactive Codex home.
# The runner uses danger-full-access for the Chair because it must invoke local
# worker CLIs that need network and authenticated user state. Harvis policy and
# approval gates still block delete/group-send/formal publish actions.
model = "gpt-5.5"
approval_policy = "never"
sandbox_mode = "danger-full-access"
""",
            encoding="utf-8",
        )
    source_auth = USER_HOME / ".codex" / "auth.json"
    auth_link = chair_home / "auth.json"
    if source_auth.exists() and not auth_link.exists():
        auth_link.symlink_to(source_auth)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return value if isinstance(value, dict) else {}


def task_created_timestamp(task: dict[str, Any]) -> float | None:
    raw = str(task.get("created_at") or "").strip()
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def is_fresh_for_task(path: Path, task: dict[str, Any]) -> bool:
    created_ts = task_created_timestamp(task)
    if created_ts is None or not path.exists():
        return True
    # Allow tiny filesystem timestamp skew, but never let a previous retry's
    # mirror result satisfy the current task attempt.
    return path.stat().st_mtime >= created_ts - 2


def extract_links(text: str) -> list[str]:
    links = re.findall(r"https?://[^\s\]\)）>'\"`]+", text)
    # Feishu/Lark rich previews and some IM input paths may degrade
    # `https://mp.weixin...` into `https//mp.weixin...` or leave only a bare
    # domain in the markdown label/value. Recover these common article links so
    # the conductor contract still has authoritative inputs.
    degraded = re.findall(r"\bhttps//(mp\.weixin\.qq\.com/s/[A-Za-z0-9_-]+)", text)
    bare = re.findall(r"(?<![\w/])(mp\.weixin\.qq\.com/s/[A-Za-z0-9_-]+)", text)
    for match in degraded + bare:
        links.append(f"https://{match}")
    seen: set[str] = set()
    result = []
    for link in links:
        link = link.rstrip(".,，。")
        if link not in seen:
            seen.add(link)
            result.append(link)
    return result


def is_conductor_task(text: str) -> bool:
    lower = text.lower()
    return any(
        marker in lower
        for marker in (
            "codex-controller",
            "codex conductor",
            "conductor",
            "mp.weixin.qq.com",
            "zhihu.com",
            "csdn.net",
            "公众号草稿",
            "微信草稿",
            "create_draft",
            "wemedia",
        )
    )


def task_kind(text: str) -> str:
    lower = text.lower()
    if any(marker in lower for marker in ("mp.weixin.qq.com", "zhihu.com", "csdn.net", "微信文章", "公众号草稿", "create_draft", "wemedia")):
        return "external_article_to_wechat_draft"
    return "codex_conductor_task"


def worker_registry(wemedia_root: str) -> dict[str, Any]:
    md2wechat = Path(wemedia_root) / "wechat" / "md2wechat-skill" / "scripts" / "md2wechat"
    kimicode = USER_HOME / ".local" / "bin" / "kimicode"
    kimi_ingest = PLUGIN_ROOT / "scripts" / "harvis_kimi_source_ingest.py"
    codex = USER_HOME / ".local" / "bin" / "codex"
    return {
        "schemaVersion": WORKER_REGISTRY_VERSION,
        "created_at": utc_now(),
        "workers": {
            "kimicode": {
                "status": "available" if kimicode.exists() and kimi_ingest.exists() else "unknown",
                "command": str(kimi_ingest),
                "raw_command": str(kimicode),
                "capabilities": [
                    "wechat_article_parse",
                    "wechat_image_discovery",
                    "paper_link_discovery",
                    "long_context_reading",
                ],
                "role": "source_ingestion_worker",
                "preferred_for": ["mp.weixin.qq.com", "zhihu.com", "csdn.net", "long_external_article"],
                "call_first_for": ["mp.weixin.qq.com"],
                "environment": {
                    "preserve_authenticated_home": True,
                    "do_not_override_home_with_workspace_local_dir": True,
                    "reason": "Kimi Code model/provider config lives under the authenticated user HOME; workspace-local HOME produced empty source packages in smoke tests.",
                },
                "usage": {
                    "readonly": [
                        str(kimi_ingest),
                        "--workspace",
                        "{workspace}",
                        "--url",
                        "{url}",
                        "--material-dir",
                        "{material_dir}",
                        "--output",
                        "{material_dir}/kimi-source-package.md",
                        "--status-json",
                        "{material_dir}/kimi-source-status.json",
                    ],
                    "required_output": {
                        "markdown_path": "{material_dir}/kimi-source-package.md",
                        "status_json_path": "{material_dir}/kimi-source-status.json",
                        "must_include": [
                            "source title",
                            "source url",
                            "article outline or extracted body",
                            "image urls or local image candidates",
                            "paper/project links mentioned by the source",
                            "explicit failure reason if source cannot be read",
                        ],
                    },
                },
            },
            "kimi": {
                "status": "alias",
                "alias_for": "kimicode",
                "note": "Backward-compatible worker name only; new conductor contracts should call kimicode.",
            },
            "codex": {
                "status": "available" if codex.exists() else "unknown",
                "command": str(codex),
                "capabilities": ["local_files", "draft_generation", "verification", "dynamic_planning"],
                "role": "conductor_and_local_publisher",
                "must_not": ["directly_claim_wechat_source_extracted_without_kimicode_or_local_artifact"],
            },
            "md2wechat": {
                "status": "available" if md2wechat.exists() else "unknown",
                "command": str(md2wechat),
                "capabilities": ["image_upload", "create_draft", "draft_get_verify"],
                "role": "wechat_draft_worker",
                "requires_inputs": ["final_article_markdown", "uploaded_or_uploadable_images"],
                "verify_command": str(PLUGIN_ROOT / "scripts" / "harvis_wechat_draft_verify.py"),
            },
            "browser": {
                "status": "available",
                "command": "computer-use/browser",
                "capabilities": ["ui_verify"],
                "role": "draft_box_verification_worker",
            },
        },
    }


def contract_paths(task_path: Path, task: dict[str, Any]) -> tuple[Path, Path, Path]:
    contract = task.get("contract") if isinstance(task.get("contract"), dict) else {}
    events_path = Path(str(contract.get("events_path") or task_path.parent / "conductor_events.jsonl"))
    result_path = Path(str(contract.get("result_path") or task_path.parent / "conductor_result.json"))
    registry_path = Path(str(task.get("worker_registry_path") or task_path.parent / "worker-registry.json"))
    return events_path, result_path, registry_path


def mirror_result_path_for_task(task: dict[str, Any]) -> Path | None:
    contract = task.get("contract") if isinstance(task.get("contract"), dict) else {}
    raw = contract.get("mirror_result_path")
    return Path(str(raw)) if raw else None


def result_proves_business_success(result: dict[str, Any]) -> bool:
    return result.get("business_success") is True


def draft_box_ui_verified(result: dict[str, Any]) -> bool:
    artifacts = result.get("artifacts") if isinstance(result.get("artifacts"), dict) else {}
    return any(
        bool(value)
        for value in (
            result.get("draft_box_verified"),
            result.get("ui_verified"),
            artifacts.get("draft_box_verified"),
            artifacts.get("ui_verified"),
            artifacts.get("browser_proof"),
            artifacts.get("browser_proof_path"),
            artifacts.get("draft_box_screenshot"),
            artifacts.get("draft_box_screenshot_path"),
        )
    )


def draft_box_api_verified(result: dict[str, Any]) -> bool:
    artifacts = result.get("artifacts") if isinstance(result.get("artifacts"), dict) else {}
    validation = result.get("validation") if isinstance(result.get("validation"), dict) else {}
    if validation.get("draft_box_api_verified") is True or artifacts.get("draft_box_api_verified") is True:
        return True
    proof_path = artifacts.get("wechat_api_proof") or artifacts.get("draft_get_proof")
    if not proof_path:
        return False
    try:
        proof = json.loads(Path(str(proof_path)).read_text(encoding="utf-8"))
    except Exception:
        return False
    return bool(proof.get("success") is True and proof.get("draft_box_api_verified") is True)


def result_has_draft_artifact(result: dict[str, Any]) -> bool:
    artifacts = result.get("artifacts") if isinstance(result.get("artifacts"), dict) else {}
    validation = result.get("validation") if isinstance(result.get("validation"), dict) else {}
    return any(
        bool(value)
        for value in (
            result.get("draft_id"),
            result.get("media_id"),
            artifacts.get("draft_id"),
            artifacts.get("media_id"),
            artifacts.get("draft_json"),
            artifacts.get("create_draft_result"),
            validation.get("create_draft_returned_media_id"),
        )
    )


def normalize_result_for_task(task: dict[str, Any], result: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    """Normalize WeChat draft results around API-verifiable draft creation."""
    if not isinstance(result, dict):
        return result, False
    kind = str(result.get("kind") or task.get("kind") or "")
    if kind != "external_article_to_wechat_draft":
        return result, False
    status = str(result.get("status") or "").strip()
    draft_created_status = status in {"wechat_draft_created", "draft_created", "completed", "success"}
    if not (draft_created_status or result_has_draft_artifact(result)):
        return result, False
    if draft_box_ui_verified(result):
        return result, False
    api_verified = draft_box_api_verified(result)
    normalized = dict(result)
    artifacts = dict(result.get("artifacts") if isinstance(result.get("artifacts"), dict) else {})
    stage_status = dict(result.get("stage_status") if isinstance(result.get("stage_status"), dict) else {})
    validation = dict(result.get("validation") if isinstance(result.get("validation"), dict) else {})
    artifacts["browser_proof"] = artifacts.get("browser_proof")
    artifacts["browser_proof_required"] = False
    prior_browser_reason = str(artifacts.get("browser_proof_reason") or "")
    artifacts["browser_proof_reason"] = (
        prior_browser_reason
        if prior_browser_reason and "required" not in prior_browser_reason.lower()
        else "Draft-box UI verification is optional; draft/get API verification is the completion proof."
    )
    stage_status.setdefault("create_draft", "passed")
    if api_verified:
        stage_status["draft_box_api_verification"] = "passed"
    validation["create_draft_returned_media_id"] = bool(validation.get("create_draft_returned_media_id") or result_has_draft_artifact(result))
    validation["draft_box_api_verified"] = api_verified
    validation["draft_box_ui_verified"] = False
    if api_verified:
        status = "wechat_draft_created"
        business_success = True
        current_stage = "completed"
        reason = "create_draft returned a draft artifact and WeChat draft/get verified it; UI screenshot is optional."
    else:
        status = "draft_created_ui_unverified"
        business_success = False
        current_stage = "draft_box_api_verification"
        stage_status["draft_box_api_verification"] = "blocked"
        reason = "create_draft returned a draft artifact, but draft/get API verification is missing or blocked."
    normalized.update(
        {
            "status": status,
            "business_success": business_success,
            "current_stage": current_stage,
            "stage_status": stage_status,
            "reason": reason,
            "artifacts": artifacts,
            "validation": validation,
        }
    )
    return normalized, normalized != result


def result_is_missing_write_failure(result: dict[str, Any]) -> bool:
    stage = str(result.get("current_stage") or result.get("stage") or "")
    reason = str(result.get("reason") or "").lower()
    return (
        str(result.get("status") or "") == "workflow_failed"
        and stage == "write_conductor_result"
        and ("without writing conductor_result" in reason or "conductor_result" in reason)
    )


def candidate_mirror_paths(task: dict[str, Any], workspace: Path) -> tuple[list[Path], list[Path]]:
    contract = task.get("contract") if isinstance(task.get("contract"), dict) else {}
    run_id = str(task.get("run_id") or task.get("task_id") or "").strip()
    packet_id = str(task.get("packet_id") or "").strip()
    names = [name for name in dict.fromkeys([run_id, packet_id]) if name]

    result_candidates: list[Path] = []
    event_candidates: list[Path] = []
    if contract.get("mirror_result_path"):
        result_candidates.append(Path(str(contract["mirror_result_path"])))
    if contract.get("mirror_events_path"):
        event_candidates.append(Path(str(contract["mirror_events_path"])))
    for name in names:
        result_candidates.append(workspace / ".harvis-conductor-results" / f"{name}-conductor_result.json")
        event_candidates.append(workspace / ".harvis-conductor-results" / f"{name}-conductor_events.jsonl")

    wanted_results = {f"{name}-conductor_result.json" for name in names}
    wanted_events = {f"{name}-conductor_events.jsonl" for name in names}
    skip_dirs = {".git", "node_modules", ".venv", "venv", "__pycache__", "target", ".next", "dist", "build"}
    visited = 0
    if workspace.exists():
        for root, dirs, files in os.walk(workspace):
            dirs[:] = [item for item in dirs if item not in skip_dirs]
            visited += 1
            if visited > 8000:
                break
            root_path = Path(root)
            for filename in files:
                if filename in wanted_results:
                    result_candidates.append(root_path / filename)
                elif filename in wanted_events:
                    event_candidates.append(root_path / filename)

    deduped_results = list(dict.fromkeys(result_candidates))
    deduped_events = list(dict.fromkeys(event_candidates))
    return deduped_results, deduped_events


def promote_mirror_result(task_path: Path, task: dict[str, Any], workspace: Path, result_path: Path, events_path: Path) -> dict[str, Any] | None:
    existing = load_json(result_path) if result_path.exists() and is_fresh_for_task(result_path, task) else {}
    should_consider_mirror = not existing or result_is_missing_write_failure(existing)
    if not should_consider_mirror:
        if existing:
            normalized, changed = normalize_result_for_task(task, existing)
            if changed:
                write_json(result_path, normalized)
            mirror_result_path = mirror_result_path_for_task(task)
            if mirror_result_path:
                write_json(mirror_result_path, normalized)
            return normalized
        return None

    result_candidates, event_candidates = candidate_mirror_paths(task, workspace)
    for candidate in result_candidates:
        if candidate == result_path or not candidate.exists():
            continue
        if not is_fresh_for_task(candidate, task):
            continue
        mirror = load_json(candidate)
        if not mirror:
            continue
        mirror, _changed = normalize_result_for_task(task, mirror)
        mirror.setdefault("schemaVersion", "harvis.conductor-result.v0")
        mirror["promoted_from_mirror"] = str(candidate)
        mirror["official_result_path"] = str(result_path)
        write_json(result_path, mirror)
        promoted_events = 0
        for event_candidate in event_candidates:
            if not event_candidate.exists() or event_candidate == events_path:
                continue
            for line in event_candidate.read_text(encoding="utf-8", errors="replace").splitlines():
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if isinstance(obj, dict):
                    append_jsonl(events_path, obj)
                    promoted_events += 1
        append_jsonl(
            events_path,
            {
                "schemaVersion": EVENT_SCHEMA_VERSION,
                "observed_at": utc_now(),
                "type": "conductor.result_promoted",
                "summary": f"Promoted workspace mirror conductor result from {candidate}",
                "mirror_result_path": str(candidate),
                "promoted_events": promoted_events,
                "business_success": bool(mirror.get("business_success")),
            },
        )
        return mirror
    return None


def failure_result(task: dict[str, Any], *, status: str, stage: str, reason: str, exit_code: int | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "schemaVersion": "harvis.conductor-result.v0",
        "created_at": utc_now(),
        "task_id": task.get("task_id"),
        "run_id": task.get("run_id"),
        "handoff_id": task.get("handoff_id"),
        "packet_id": task.get("packet_id"),
        "kind": task.get("kind") or "codex_conductor_task",
        "status": status,
        "current_stage": stage,
        "stage_status": {stage: "failed"},
        "business_success": False,
        "reason": reason,
        "artifacts": {},
    }
    if exit_code is not None:
        payload["exit_code"] = exit_code
    return payload


def ensure_result_exists(task_path: Path, *, workspace: Path | None = None, exit_code: int | None = None, reason: str | None = None) -> dict[str, Any]:
    task = load_json(task_path)
    events_path, result_path, _registry_path = contract_paths(task_path, task)
    workspace = workspace or Path(str(task.get("workspace") or task_path.parent)).expanduser()
    promoted = promote_mirror_result(task_path, task, workspace, result_path, events_path)
    if promoted:
        return promoted
    if result_path.exists() and is_fresh_for_task(result_path, task):
        result = load_json(result_path)
        if result:
            result, changed = normalize_result_for_task(task, result)
            if changed:
                write_json(result_path, result)
            mirror_result_path = mirror_result_path_for_task(task)
            if mirror_result_path:
                write_json(mirror_result_path, result)
            return result
        result = failure_result(
            task,
            status="workflow_failed",
            stage="read_conductor_result",
            reason="conductor_result.json exists but is not valid JSON object",
            exit_code=exit_code,
        )
        write_json(result_path, result)
        return result
    result = failure_result(
        task,
        status="workflow_failed",
        stage="write_conductor_result",
        reason=reason or "Codex Conductor finished without writing conductor_result.json",
        exit_code=exit_code,
    )
    write_json(result_path, result)
    return result


def conductor_prompt(task_path: Path, task: dict[str, Any], registry_path: Path) -> str:
    registry_text = read_text(registry_path, 12000)
    playbook_chunks = []
    for item in task.get("playbooks") or []:
        if not isinstance(item, dict):
            continue
        path = Path(str(item.get("path") or ""))
        if path.exists():
            playbook_chunks.append(f"## Playbook: {item.get('name') or path.name}\n{read_text(path, 12000)}")
    playbooks = "\n\n".join(playbook_chunks) or "No playbook loaded."
    return f"""You are the Codex Conductor for a H.A.R.V.I.S. task.

Read and obey this contract. You choose the workflow dynamically; Harvis did not
hard-code the stage sequence.

Critical orchestration rule:
- For `mp.weixin.qq.com` links, Codex Conductor must treat `kimicode` as the source
  ingestion worker. Do not make Codex/curl/web scraping the primary source
  parser for WeChat article bodies. First call the `kimicode` worker command from the
  worker registry to produce a source package under the material directory with
  title/body summary, image candidates, and paper/project links. Preserve the
  authenticated Kimi HOME from the registry; do not replace it with a
  workspace-local HOME. Codex then audits that package, downloads/verifies
  images or paper figures when possible, writes the final article, calls
  md2wechat for image upload/create_draft, verifies the returned media_id with
  the md2wechat registry `verify_command` (`draft/get`) when credentials are
  available, and writes conductor_result.json.
- If `kimicode` cannot produce usable source content, stop with
  `business_success: false` and a specific `source_fetch_blocked` reason. Do
  not create a draft from guessed or empty source material.

Task path:
{task_path}

Task JSON:
```json
{json.dumps(task, ensure_ascii=False, indent=2)}
```

Worker registry:
```json
{registry_text}
```

{playbooks}

Required output files:
- Append progress JSONL events to: {task.get('contract', {}).get('events_path')}
- Write final JSON result to: {task.get('contract', {}).get('result_path')}
- If the official result/events path is outside your writable sandbox, write the
  same JSON/JSONL to the workspace mirror paths:
  - mirror result: {task.get('contract', {}).get('mirror_result_path')}
  - mirror events: {task.get('contract', {}).get('mirror_events_path')}
  The parent Harvis runner will promote a valid mirror result back to the
  official conductor_result.json.

Result schema requirements:
- schemaVersion: harvis.conductor-result.v0
- status: completed | blocked | workflow_failed | wechat_draft_created | draft_created_ui_unverified | draft_created_api_verified_ui_unverified
- business_success: true only when artifacts prove the business outcome
- reason: short human explanation
- current_stage and stage_status
- artifacts: include draft_id/media_id, image_count, article path, material dir,
  WeChat draft/get proof, optional browser proof, and other evidence when
  available
- If `create_draft` returns a media_id and `draft/get` verifies it, write
  `status: wechat_draft_created` with `business_success: true`. Browser/UI
  proof is optional. If only the create_draft response is available, keep
  `business_success: false` until the API verification exists.

Policy:
- High risk: delete / 删除 / 清空.
- create_draft is an allowed WeChat draft-box action.
- Do not group-send, freepublish, formally publish, deploy, push, or delete
  unless the operator explicitly requested that exact action; delete / 删除 /
  清空 still requires approval.
- Exit code 0 is not success; conductor_result.json must prove success.
"""


def run(args: argparse.Namespace) -> int:
    task_path = Path(args.task_path)
    task = load_json(task_path)
    if not task:
        raise SystemExit(f"invalid or missing conductor task: {task_path}")
    events_path, result_path, registry_path = contract_paths(task_path, task)
    workspace = Path(str(task.get("workspace") or args.root or task_path.parent)).expanduser()
    stdout_log = Path(args.stdout_log) if args.stdout_log else task_path.parent / "conductor-codex.out.log"
    stderr_log = Path(args.stderr_log) if args.stderr_log else task_path.parent / "conductor-codex.err.log"
    prompt_path = Path(args.prompt_path) if args.prompt_path else task_path.parent / "conductor-prompt.md"
    chair_home = Path(args.chair_home).expanduser()
    ensure_chair_home(chair_home)
    prompt = conductor_prompt(task_path, task, registry_path)
    prompt_path.write_text(prompt, encoding="utf-8")
    append_jsonl(
        events_path,
        {
            "schemaVersion": EVENT_SCHEMA_VERSION,
            "observed_at": utc_now(),
            "type": "conductor.runner_started",
            "summary": "Codex Conductor runner started",
            "task_path": str(task_path),
            "result_path": str(result_path),
            "workspace": str(workspace),
            "chair_home": str(chair_home),
        },
    )
    if args.dry_run:
        result = failure_result(
            task,
            status="blocked",
            stage="dry_run",
            reason="dry-run only: Codex Conductor was not invoked",
            exit_code=0,
        )
        write_json(result_path, result)
        append_jsonl(events_path, {"schemaVersion": EVENT_SCHEMA_VERSION, "observed_at": utc_now(), "type": "conductor.runner_dry_run", "summary": result["reason"]})
        return 0
    command = [
        args.codex,
        "exec",
        "-C",
        str(workspace),
        "--sandbox",
        args.sandbox,
        "-c",
        'approval_policy="never"',
        "-c",
        'shell_environment_policy.inherit="all"',
    ]
    for writable_dir in CHAIR_EXTRA_WRITABLE_DIRS:
        command.extend(["--add-dir", writable_dir])
    command.extend(["--skip-git-repo-check", "--model", args.model, prompt])
    stdout_log.parent.mkdir(parents=True, exist_ok=True)
    stderr_log.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CODEX_HOME"] = str(chair_home)
    try:
        with stdout_log.open("w", encoding="utf-8") as stdout_handle, stderr_log.open("w", encoding="utf-8") as stderr_handle:
            completed = subprocess.run(
                command,
                env=env,
                text=True,
                stdout=stdout_handle,
                stderr=stderr_handle,
                timeout=args.timeout_seconds,
                check=False,
            )
        exit_code = completed.returncode
    except subprocess.TimeoutExpired:
        exit_code = 124
        stderr_log.write_text(f"Codex Conductor timed out after {args.timeout_seconds}s\n", encoding="utf-8")
    except FileNotFoundError:
        exit_code = 127
        stderr_log.write_text(f"Codex executable not found: {args.codex}\n", encoding="utf-8")
    result = ensure_result_exists(
        task_path,
        workspace=workspace,
        exit_code=exit_code,
        reason=f"Codex Conductor exited with code {exit_code} without writing conductor_result.json",
    )
    append_jsonl(
        events_path,
        {
            "schemaVersion": EVENT_SCHEMA_VERSION,
            "observed_at": utc_now(),
            "type": "conductor.runner_completed" if exit_code == 0 else "conductor.runner_failed",
            "summary": result.get("reason") or f"Codex Conductor exited with code {exit_code}",
            "exit_code": exit_code,
            "business_success": bool(result.get("business_success")),
            "result_path": str(result_path),
        },
    )
    return exit_code


def finalize(args: argparse.Namespace) -> int:
    task_path = Path(args.task_path)
    task = load_json(task_path)
    if not task:
        raise SystemExit(f"invalid or missing conductor task: {task_path}")
    events_path, result_path, _registry_path = contract_paths(task_path, task)
    workspace = Path(str(task.get("workspace") or args.root or task_path.parent)).expanduser()
    result = ensure_result_exists(task_path, workspace=workspace, exit_code=args.exit_code, reason=args.reason)
    append_jsonl(
        events_path,
        {
            "schemaVersion": EVENT_SCHEMA_VERSION,
            "observed_at": utc_now(),
            "type": "conductor.result_finalized",
            "summary": result.get("reason") or "Conductor result finalized",
            "result_path": str(result_path),
            "business_success": bool(result.get("business_success")),
        },
    )
    return 0


def prepare(args: argparse.Namespace) -> int:
    exec_dir = Path(args.exec_dir)
    packet_path = Path(args.packet_path) if args.packet_path else None
    packet_text = read_text(packet_path)
    combined = f"{args.instruction or ''}\n{packet_text}"
    if not is_conductor_task(combined):
        return 0

    wemedia_root = args.wemedia_root or DEFAULT_WEMEDIA_ROOT
    task_path = Path(args.task_path) if args.task_path else exec_dir / "conductor_task.json"
    events_path = Path(args.events_path) if args.events_path else exec_dir / "conductor_events.jsonl"
    result_path = Path(args.result_path) if args.result_path else exec_dir / "conductor_result.json"
    registry_path = Path(args.registry_path) if args.registry_path else exec_dir / "worker-registry.json"
    registry = worker_registry(wemedia_root)
    kind = task_kind(combined)
    links = extract_links(combined)
    task_name = args.run_id or args.packet_id or "harvis-conductor-task"
    mirror_dir = Path(wemedia_root if kind == "external_article_to_wechat_draft" else args.root) / ".harvis-conductor-results"
    mirror_result_path = mirror_dir / f"{task_name}-conductor_result.json"
    mirror_events_path = mirror_dir / f"{task_name}-conductor_events.jsonl"

    write_json(registry_path, registry)
    task = {
        "schemaVersion": SCHEMA_VERSION,
        "created_at": utc_now(),
        "task_id": args.run_id or args.packet_id,
        "run_id": args.run_id,
        "handoff_id": args.handoff_id,
        "packet_id": args.packet_id,
        "kind": kind,
        "goal": "把外部文章链接动态整理成可验收的微信公众号草稿" if kind == "external_article_to_wechat_draft" else "执行 Codex Conductor 动态任务",
        "inputs": {
            "original_instruction": args.instruction,
            "packet_path": str(packet_path) if packet_path else None,
            "packet_excerpt": packet_text[:2000],
            "links": links,
        },
        "workspace": wemedia_root if kind == "external_article_to_wechat_draft" else args.root,
        "requested_workspace": args.root,
        "chair": {
            "runtime": "codex",
            "home": DEFAULT_CHAIR_HOME,
            "role": "conductor_chair",
            "config": str(Path(DEFAULT_CHAIR_HOME) / "config.toml"),
            "sandbox": "danger-full-access",
        },
        "available_workers": ["kimicode", "codex", "md2wechat", "browser"],
        "worker_registry_path": str(registry_path),
        "orchestration_strategy": {
            "mode": "codex_conductor_controls_workers",
            "router_responsibility": [
                "intake",
                "policy",
                "cards",
                "logs",
                "contract_files",
            ],
            "conductor_responsibility": [
                "dynamic_planning",
                "worker_selection",
                "artifact_verification",
                "result_contract",
            ],
            "source_ingestion": {
                "mp.weixin.qq.com": {
                    "primary_worker": "kimicode",
                    "reason": "Codex/curl often cannot access WeChat article bodies; Kimi is the long-context source parser.",
                    "required_before": ["article_generation", "image_upload", "create_draft"],
                    "failure_stage": "source_fetch_blocked",
                }
            },
            "publishing": {
                "article_generation_worker": "codex",
                "draft_worker": "md2wechat",
                "draft_box_verification_worker": "browser",
            },
        }
        if kind == "external_article_to_wechat_draft"
        else {},
        "policy": {
            "high_risk": ["delete", "删除", "清空"],
            "allowed_actions": ["local_write", "wechat_image_upload", "wechat_create_draft"],
            "requires_approval": ["delete", "删除", "清空"],
            "forbidden_without_explicit_operator_command": [
                "group_send",
                "freepublish",
                "formal_publish",
                "deploy",
                "push",
            ],
            "create_draft": "allowed_draft_box_action",
        },
        "contract": {
            "events_path": str(events_path),
            "result_path": str(result_path),
            "mirror_events_path": str(mirror_events_path),
            "mirror_result_path": str(mirror_result_path),
            "success_source": "conductor_result.json or verified artifacts, not process exit code",
        },
        "playbooks": [
            {
                "name": "wemedia-wechat-draft",
                "path": str(WEMEDIA_PLAYBOOK),
                "mode": "reference_only",
            }
        ]
        if kind == "external_article_to_wechat_draft"
        else [],
        "acceptance": {
            "business_success_requires": [
                "conductor_result.business_success == true",
                "draft id or media_id exists when create_draft is requested",
                "WeChat draft/get API proof is recorded for official-account draft-box verification",
                "browser/UI proof is optional and only required when the operator explicitly asks for a visual smoke",
                "image_count > 0 for WeChat article drafts",
                "article ending has no source-account footer",
            ],
            "failure_requires": "conductor_result.reason names the blocked stage and missing artifact",
        },
    }
    # A same run_id may be retried during smoke tests or manual recovery. The
    # new attempt must not inherit an old business result; events remain
    # append-only for audit, but result files are per attempt evidence.
    for stale_result in (result_path, mirror_result_path):
        if stale_result.exists():
            stale_result.unlink()
    write_json(task_path, task)
    append_jsonl(
        events_path,
        {
            "schemaVersion": EVENT_SCHEMA_VERSION,
            "observed_at": utc_now(),
            "type": "conductor.task_created",
            "summary": f"Created conductor task {task['task_id']} ({kind})",
            "task_path": str(task_path),
            "result_path": str(result_path),
            "available_workers": task["available_workers"],
        },
    )
    if args.run_events_jsonl:
        append_jsonl(
            Path(args.run_events_jsonl),
            {
                "schemaVersion": EVENT_SCHEMA_VERSION,
                "observed_at": utc_now(),
                "codex_event_type": "conductor.task_created",
                "type": "conductor.task_created",
                "summary": f"Created conductor task contract: {task_path}",
                "conductor_task": str(task_path),
                "conductor_events": str(events_path),
                "conductor_result": str(result_path),
            },
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prepare_parser = sub.add_parser("prepare")
    prepare_parser.add_argument("--root", required=True)
    prepare_parser.add_argument("--exec-dir", required=True)
    prepare_parser.add_argument("--packet-path")
    prepare_parser.add_argument("--instruction", default="")
    prepare_parser.add_argument("--harness", default="")
    prepare_parser.add_argument("--run-id", default="")
    prepare_parser.add_argument("--handoff-id", default="")
    prepare_parser.add_argument("--packet-id", default="")
    prepare_parser.add_argument("--task-path")
    prepare_parser.add_argument("--events-path")
    prepare_parser.add_argument("--result-path")
    prepare_parser.add_argument("--registry-path")
    prepare_parser.add_argument("--run-events-jsonl")
    prepare_parser.add_argument("--wemedia-root", default=DEFAULT_WEMEDIA_ROOT)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--task-path", required=True)
    run_parser.add_argument("--root", default="")
    run_parser.add_argument("--codex", default=str(USER_HOME / ".local" / "bin" / "codex"))
    run_parser.add_argument("--chair-home", default=DEFAULT_CHAIR_HOME)
    run_parser.add_argument("--sandbox", default="danger-full-access")
    run_parser.add_argument("--model", default="gpt-5.5")
    run_parser.add_argument("--timeout-seconds", type=int, default=900)
    run_parser.add_argument("--stdout-log")
    run_parser.add_argument("--stderr-log")
    run_parser.add_argument("--prompt-path")
    run_parser.add_argument("--dry-run", action="store_true")
    finalize_parser = sub.add_parser("finalize")
    finalize_parser.add_argument("--task-path", required=True)
    finalize_parser.add_argument("--exit-code", type=int, default=None)
    finalize_parser.add_argument("--reason")
    args = parser.parse_args()
    if args.command == "prepare":
        return prepare(args)
    if args.command == "run":
        return run(args)
    if args.command == "finalize":
        return finalize(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
