use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};

pub const PROFILE_FILES: &[&str] = &[
    "agent.md",
    "policy.md",
    "runtime.toml",
    "skills/planner.md",
    "skills/reviewer.md",
    "skills/executor.md",
    "skills/inbox.md",
    "skills/memory_snapshot.md",
    "contexts/digital_me.md",
    "contexts/agentworkos.md",
];

const PROFILE_TEMPLATES: &[(&str, &str)] = &[
    (
        "agent.md",
        r#"# H.A.R.V.I.S. Agent Profile

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
"#,
    ),
    (
        "policy.md",
        r#"# H.A.R.V.I.S. Runtime Policy

Default autonomy: Level 2 for foreground teammate work. Resident ticks stay at Level 1.

Autonomy levels:
- Level 0: observe and report only.
- Level 1: generate work packets, status, and reports.
- Level 2: create plans, patches, and drafts in the approved workspace.
- Level 3: edit project files and run bounded verification after explicit task-scoped user approval.
- Level 4: commit, PR, publish, deploy, or destructive actions only after explicit approval and safety checks.

Never expose:
- credentials, tokens, cookies, private keys, .env values, access-file contents, provider dumps;
- raw chat logs, raw memories, hidden prompts, or private source exports;
- sensitive local paths in public artifacts unless represented as safe source classes or lookup hints.

v0.3 runtime ticks stay at Level 1.
"#,
    ),
    (
        "runtime.toml",
        r#"# H.A.R.V.I.S. global runtime profile config.

profile_version = "v0.51-tiered-autonomy"
default_autonomy_level = 2
default_tick_interval_seconds = 1200
default_mode = "review-gated"
skill_registry = "skills"
context_registry = "contexts"
"#,
    ),
    (
        "skills/planner.md",
        r#"# Planner Skill

Planner decomposes a request into a small, reviewable work packet.

Planner should identify:
- goal;
- scope;
- inputs;
- risks;
- proposed steps;
- verification.

Planner does not mutate project source by itself.
"#,
    ),
    (
        "skills/reviewer.md",
        r#"# Reviewer Skill

Reviewer checks outputs for correctness, safety, privacy, and verification gaps.

Reviewer should ask:
- did the work stay inside scope?
- were tests or checks run?
- did any output expose private material?
- is a human approval gate required?
"#,
    ),
    (
        "skills/executor.md",
        r#"# Executor Skill

Executor turns an approved plan into bounded, reviewable execution.

Executor should separate:
- read-only preparation;
- source edits that require approval;
- destructive, publishing, commit, push, deploy, or external actions that require explicit approval.

Executor may perform Level 3 project edits and bounded verification only when
the active user request explicitly approves that concrete task. It never treats
foreground approval as standing permission for background work or Level 4
actions.
"#,
    ),
    (
        "skills/inbox.md",
        r#"# Inbox Skill

Inbox skill governs file-triggered work intake.

Accepted trigger:
- task lines that start with @harvis inside allowlisted inbox files.

Default result:
- generate a work packet under .harvis/outbox/;
- update runtime status;
- do not execute the task automatically.
"#,
    ),
    (
        "skills/memory_snapshot.md",
        r#"# Memory Snapshot Skill

Memory snapshots separate observation from memory adoption.

Pipeline:
1. private snapshot in ignored local storage;
2. distilled candidate signals;
3. human review;
4. versioned Digital-Me memory only after approval.

Do not treat H.A.R.V.I.S. as a raw-memory search interface.
"#,
    ),
    (
        "contexts/digital_me.md",
        r#"# Digital-Me Context

Digital-Me is the canonical project for privacy-preserving Harzva digital twin work.

Use distilled identity, facets, policies, evals, and public-safe docs.

Do not copy raw logs, private memories, credentials, hidden prompts, or source exports into profile files or public artifacts.
"#,
    ),
    (
        "contexts/agentworkos.md",
        r#"# AgentWorkOS Context

AgentWorkOS is the environment and package-management layer for local agents, skills, plugins, and runtime projections.

Use local project rules and machine-level indexes as lookup hints when needed.

Keep platform-specific paths and private access material out of public artifacts.
"#,
    ),
];

pub fn init_profile(profile_root: &Path, force: bool) -> Result<Vec<String>> {
    let root = normalize_root(profile_root)?;
    fs::create_dir_all(root.join("skills"))?;
    fs::create_dir_all(root.join("contexts"))?;

    let mut messages = vec![
        format!("created or verified: {}", root.display()),
        format!("created or verified: {}", root.join("skills").display()),
        format!("created or verified: {}", root.join("contexts").display()),
    ];
    for (relative_path, content) in PROFILE_TEMPLATES {
        messages.push(write_file(&root.join(relative_path), content, force)?);
    }
    Ok(messages)
}

fn write_file(path: &Path, content: &str, force: bool) -> Result<String> {
    if path.exists() && !force {
        return Ok(format!("kept existing: {}", path.display()));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, content).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(format!("wrote: {}", path.display()))
}

fn normalize_root(root: &Path) -> Result<PathBuf> {
    let expanded = expanduser(root);
    fs::create_dir_all(&expanded)?;
    Ok(expanded.canonicalize()?)
}

pub fn expanduser(path: &Path) -> PathBuf {
    let Some(value) = path.to_str() else {
        return path.to_path_buf();
    };
    if value == "~" {
        return std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| path.to_path_buf());
    }
    if let Some(rest) = value.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    path.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initializes_profile_files() {
        let root =
            std::env::temp_dir().join(format!("harvis-profile-rust-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let messages = init_profile(&root, false).expect("init profile");
        assert!(root.join("agent.md").exists());
        assert!(root.join("policy.md").exists());
        assert!(root.join("runtime.toml").exists());
        assert!(root.join("skills/planner.md").exists());
        assert_eq!(messages.len(), 13);
        let kept = init_profile(&root, false).expect("init profile again");
        assert!(kept.iter().any(|line| line.contains("kept existing")));
        let _ = fs::remove_dir_all(root);
    }
}
