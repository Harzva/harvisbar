#!/usr/bin/env python3
"""Initialize the standalone H.A.R.V.I.S. runtime profile."""

from __future__ import annotations

import argparse
from pathlib import Path


FILES = {
    "agent.md": """# H.A.R.V.I.S. Agent Profile

H.A.R.V.I.S. means Harzva Adaptive Runtime for Voice, Identity, and Systems.

Role: local-first teammate coordinator.

Purpose:
- receive delegated work through file inboxes, CLI, future MCP tools, and future local APIs;
- keep work scoped, auditable, and privacy-aware;
- coordinate future Planner, Executor, and Reviewer roles without becoming an uncontrolled autonomous actor.

Default posture:
- read local rules before acting;
- prefer work packets and status reports before mutation;
- ask for approval before destructive, publishing, commit, PR, or external-sharing actions;
- keep raw private material out of public artifacts.
""",
    "policy.md": """# H.A.R.V.I.S. Runtime Policy

Default autonomy: Level 1.

Autonomy levels:
- Level 0: observe and report only.
- Level 1: generate work packets, status, and reports.
- Level 2: create drafts under approved output directories.
- Level 3: edit project files after explicit user approval.
- Level 4: commit, PR, publish, deploy, or destructive actions only after explicit approval and safety checks.

Never expose:
- credentials, tokens, cookies, private keys, .env values, access-file contents, provider dumps;
- raw chat logs, raw memories, hidden prompts, or private source exports;
- sensitive local paths in public artifacts unless represented as safe source classes or lookup hints.

v0.3 runtime ticks stay at Level 1.
""",
    "runtime.toml": """# H.A.R.V.I.S. global runtime profile config.

profile_version = "v0.3-beta"
default_autonomy_level = 1
default_tick_interval_seconds = 1200
default_mode = "read-only"
skill_registry = "skills"
context_registry = "contexts"
""",
    "skills/planner.md": """# Planner Skill

Planner decomposes a request into a small, reviewable work packet.

Planner should identify:
- goal;
- scope;
- inputs;
- risks;
- proposed steps;
- verification.

Planner does not mutate project source by itself.
""",
    "skills/reviewer.md": """# Reviewer Skill

Reviewer checks outputs for correctness, safety, privacy, and verification gaps.

Reviewer should ask:
- did the work stay inside scope?
- were tests or checks run?
- did any output expose private material?
- is a human approval gate required?
""",
    "skills/executor.md": """# Executor Skill

Executor turns an approved plan into a bounded execution checklist.

Executor should separate:
- read-only preparation;
- source edits that require approval;
- destructive, publishing, commit, push, deploy, or external actions that require explicit approval.

Executor does not run unchecked autonomous work.
""",
    "skills/inbox.md": """# Inbox Skill

Inbox skill governs file-triggered work intake.

Accepted trigger:
- task lines that start with @harvis inside allowlisted inbox files.

Default result:
- generate a work packet under .harvis/outbox/;
- update runtime status;
- do not execute the task automatically.
""",
    "skills/memory_snapshot.md": """# Memory Snapshot Skill

Memory snapshots separate observation from memory adoption.

Pipeline:
1. private snapshot in ignored local storage;
2. distilled candidate signals;
3. human review;
4. versioned Digital-Me memory only after approval.

Do not treat H.A.R.V.I.S. as a raw-memory search interface.
""",
    "contexts/digital_me.md": """# Digital-Me Context

Digital-Me is the canonical project for privacy-preserving Harzva digital twin work.

Use distilled identity, facets, policies, evals, and public-safe docs.

Do not copy raw logs, private memories, credentials, hidden prompts, or source exports into profile files or public artifacts.
""",
    "contexts/agentworkos.md": """# AgentWorkOS Context

AgentWorkOS is the environment and package-management layer for local agents, skills, plugins, and runtime projections.

Use local project rules and machine-level indexes as lookup hints when needed.

Keep platform-specific paths and private access material out of public artifacts.
""",
}


def write_file(path: Path, content: str, force: bool) -> str:
    if path.exists() and not force:
        return f"kept existing: {path}"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return f"wrote: {path}"


def init_profile(profile_root: Path, force: bool) -> list[str]:
    root = profile_root.expanduser().resolve()
    (root / "skills").mkdir(parents=True, exist_ok=True)
    (root / "contexts").mkdir(parents=True, exist_ok=True)
    messages = [
        f"created or verified: {root}",
        f"created or verified: {root / 'skills'}",
        f"created or verified: {root / 'contexts'}",
    ]
    for relative_path, content in FILES.items():
        messages.append(write_file(root / relative_path, content, force))
    return messages


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Initialize the standalone H.A.R.V.I.S. runtime profile."
    )
    parser.add_argument(
        "--profile-root",
        default="~/.harvis",
        help="Profile root to initialize. Defaults to ~/.harvis.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing profile files.",
    )
    args = parser.parse_args()

    for message in init_profile(Path(args.profile_root), args.force):
        print(message)
    return 0


if __name__ == "__main__":
    from harvis_rust_shim import exec_harvis_command

    raise SystemExit(exec_harvis_command("init-profile", legacy_main=main))
