use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};

const INBOX_TEMPLATE: &str = r#"# H.A.R.V.I.S. Inbox

Write delegated local tasks by starting a line with the H.A.R.V.I.S. mention.
v0.2 only turns these tasks into work packets under .harvis/outbox/; it does not
edit source files, commit, push, publish, or deploy.

Task format:

    at-harvis review this workspace before publishing.
    Scope: current repository.
    Need: list blockers and safe next actions.

Replace `at-harvis` with the real mention marker when you want to create a task.
"#;

const CONFIG_TEMPLATE: &str = r#"# H.A.R.V.I.S. local workspace config.
# v0.3-alpha scans allowlisted inboxes and writes read-only runtime state.
# v0.4 adds private memory snapshots and reviewable candidate signals.
# v0.5 adds a Planner / Executor / Reviewer workbench.
# v0.10 adds run, approval, and local runtime log directories.
# v0.16/v0.17 add harness handoff and Agent Room JSONL directories.
# v0.18/v0.19 add Persona / Copy-Me registry and personality review queue.
# v0.32 adds a read-only local knowledge graph scanner.
# v0.33 pins an explicit state_root so `.harvis/*` keys resolve independently of the process CWD (T301).
# v0.46/v0.47 add Agent Room speaker selection (round_robin by default) and roster activation (T308).
# v0.46 also adds composable room termination conditions + first-class approval suspension (T309).
# v0.45 adds structured cognitive trace events for executed room speaker turns (T311).

state_root = "{state_root}"
autonomy_level = 1
default_inbox = ".harvis/inbox.md"
default_outbox = ".harvis/outbox"
default_reports = ".harvis/reports"
status_file = ".harvis/status.json"
event_log = ".harvis/events.jsonl"
memory_snapshots = ".harvis/memory/snapshots"
memory_signals = ".harvis/memory/signals"
workbench = ".harvis/workbench"
runs = ".harvis/runs"
approvals = ".harvis/approvals"
logs = ".harvis/logs"
handoffs = ".harvis/handoffs"
agent_room = ".harvis/agent-room"
persona_registry = ".harvis/persona"
tick_interval_seconds = 1200
allowlist = [".harvis/inbox.md"]

# Agent Room speaker selection (T308). Uncomment the table and one tier to
# pick a non-default selector; with no table the room runs round_robin.
# [agent_room_speaker]
# selector = "round_robin"  # round_robin | llm | custom_function
# model_alias = "d4f"       # llm tier: alias in the provider registry
# prompt_template = "..."   # llm tier: inline template ({{room_summary}} {{candidates}} {{signals}} {{topic_id}} {{question_id}} {{latest_message}})
# prompt_template_path = ".harvis/agent-room/speaker_prompt.md"  # llm tier: template file, relative to the workspace root
# max_tokens = 400          # llm tier
# command = "/absolute/path/to/selector"  # custom_function tier: JSON contract on stdin/stdout
# timeout_ms = 5000         # custom_function tier
# harness_timeout_ms = 15000  # execution timeout for active participants' local harness_ref

# Cognitive trace extraction (T311 / ROADMAP v0.45). After each executed
# speaker reply, harvis parses structured trace markers and appends
# protocol-versioned trace events to .harvis/agent-room/events.jsonl
# (messages.jsonl write/read behavior is untouched). Speakers emit markers
# as a delimited section (standalone "[trace] <kind>: ..." lines also work):
#   ---harvis-trace---
#   claim: <one-line statement> [refs: evt_a, evt_b]
#   question: <one-line statement>
#   ---end-harvis-trace---
# kinds: claim / question / counterpoint / hypothesis / verification_target /
# decision / handoff_request. Only one-line statements plus reply-lineage
# refs are persisted; hidden chain-of-thought is never written to disk.
# extraction = "llm" is an optional path: the reply plus the prompt template
# are routed through the provider registry and any failure falls back to the
# rule-based marker parse.
# [agent_room_trace]
# enabled = true
# extraction = "rule"       # rule | llm
# model_alias = "d4f"       # llm path: alias in the provider registry
# prompt_template = "..."   # llm path: inline template ({{topic_id}} {{question_id}} {{reply_to_event_id}} {{max_events}} {{reply}})
# prompt_template_path = ".harvis/agent-room/trace_prompt.md"  # llm path: template file, relative to the workspace root
# max_events_per_reply = 12

# Agent Room termination conditions (T309). With no table the room keeps its
# previous free-running behavior. Conditions compose with any_of (OR) /
# all_of (AND); kinds: text_mention / max_message / timeout /
# approval_pending / decision_reached / budget_exhausted. approval_pending
# suspends the room run into `suspended_awaiting_approval` instead of
# terminating it; the next step after the human decides resumes (approved)
# or terminates (denied/cancelled). Every transition lands in
# .harvis/agent-room/chair_decisions.jsonl with condition_kind + matched.
# [agent_room_termination]
# any_of = ["decision_reached", { all_of = [{ max_message = 20 }, { timeout = "600s" }] }]
# config_json = '{"any_of": ["decision_reached", {"max_message": 20}]}'  # JSON string form
# [agent_room_termination.topics."gwt-workbench"]  # optional per-topic override
# max_message = 3
"#;

fn config_template(root: &Path) -> String {
    CONFIG_TEMPLATE.replace("{state_root}", &root.join(".harvis").display().to_string())
}

const KNOWLEDGE_GRAPH_TEMPLATE: &str = r#"# H.A.R.V.I.S. local knowledge graph config.
# The graph scanner is read-only. It scans only vaults allowlisted here and
# returns redacted JSON by default.

[graph]
vaults = ["."]
ignore_dirs = [".obsidian", ".git", "node_modules", "attachments", "data", "logs", "models", "adapters", "runtime", "private"]
max_files = 1000
max_nodes = 1500
max_edges = 4000
include_paths = false
include_missing_targets = true
"#;

const DIRECTORIES: &[&str] = &[
    ".harvis",
    ".harvis/outbox",
    ".harvis/archive",
    ".harvis/reports",
    ".harvis/memory/snapshots",
    ".harvis/memory/signals",
    ".harvis/workbench",
    ".harvis/runs",
    ".harvis/approvals",
    ".harvis/logs",
    ".harvis/handoffs",
    ".harvis/agent-room",
    ".harvis/persona",
];

pub fn init_workspace(root: &Path, force: bool) -> Result<Vec<String>> {
    let root = normalize_root(root)?;
    let mut messages = Vec::new();
    for relative in DIRECTORIES {
        let path = root.join(relative);
        fs::create_dir_all(&path)
            .with_context(|| format!("failed to create {}", path.display()))?;
        messages.push(format!("created or verified: {}", path.display()));
    }

    write_template(
        &root.join(".harvis/inbox.md"),
        INBOX_TEMPLATE,
        force,
        &mut messages,
    )?;
    write_template(
        &root.join(".harvis/harvis.toml"),
        &config_template(&root),
        force,
        &mut messages,
    )?;
    write_template(
        &root.join(".harvis/knowledge_graph.toml"),
        KNOWLEDGE_GRAPH_TEMPLATE,
        force,
        &mut messages,
    )?;
    let agent_pools = crate::agent_pools::init_agent_pools(&root, force)?;
    let agent_pools_path = agent_pools
        .get("path")
        .and_then(serde_json::Value::as_str)
        .unwrap_or(".harvis/agent-pools.json");
    let agent_pools_action = if agent_pools
        .get("written")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
    {
        "wrote"
    } else {
        "kept existing"
    };
    messages.push(format!("{agent_pools_action}: {agent_pools_path}"));
    Ok(messages)
}

fn write_template(
    path: &Path,
    content: &str,
    force: bool,
    messages: &mut Vec<String>,
) -> Result<()> {
    if path.exists() && !force {
        messages.push(format!("kept existing: {}", path.display()));
        return Ok(());
    }
    fs::write(path, content).with_context(|| format!("failed to write {}", path.display()))?;
    messages.push(format!("wrote: {}", path.display()));
    Ok(())
}

fn normalize_root(root: &Path) -> Result<PathBuf> {
    let expanded = expanduser(root);
    if expanded.exists() {
        return Ok(expanded.canonicalize()?);
    }
    fs::create_dir_all(&expanded)
        .with_context(|| format!("failed to create {}", expanded.display()))?;
    Ok(expanded.canonicalize()?)
}

fn expanduser(path: &Path) -> PathBuf {
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
    fn initializes_workspace_layout() {
        let root =
            std::env::temp_dir().join(format!("harvis-init-rust-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let messages = init_workspace(&root, false).expect("init workspace");
        assert!(root.join(".harvis/inbox.md").exists());
        assert!(root.join(".harvis/harvis.toml").exists());
        assert!(root.join(".harvis/knowledge_graph.toml").exists());
        assert!(root.join(".harvis/agent-pools.json").exists());
        assert!(messages
            .iter()
            .any(|line| line.contains("created or verified")));
        let _ = fs::remove_dir_all(root);
    }
}
