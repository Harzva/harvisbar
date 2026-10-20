use anyhow::{bail, Context, Result};
use regex::Regex;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use crate::profile::{expanduser, PROFILE_FILES};
use crate::runs::rel;
use harvis_core::time::now_rfc3339;

pub const WORKBENCH_VERSION: &str = "v0.5";

#[derive(Debug, Clone)]
pub struct WorkbenchOptions {
    pub root: PathBuf,
    pub profile_root: PathBuf,
    pub packet: Option<String>,
    pub limit: usize,
}

pub fn prepare_workbench(options: WorkbenchOptions) -> Result<Value> {
    let root = resolve_workspace_root(&options.root)?;
    let profile_root = expanduser(&options.profile_root)
        .canonicalize()
        .unwrap_or_else(|_| expanduser(&options.profile_root));
    let limit = options.limit.clamp(1, 100);
    let packets = select_packets(&root, options.packet.as_deref(), limit)?;
    let prepared = packets
        .iter()
        .map(|path| prepare_packet_workbench(&root, &profile_root, path))
        .collect::<Result<Vec<_>>>()?;
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "packet_count": prepared.len(),
        "prepared": prepared
    }))
}

fn resolve_workspace_root(value: &Path) -> Result<PathBuf> {
    let root = expanduser(value).canonicalize().with_context(|| {
        format!(
            "workspace root must be an existing directory: {}",
            value.display()
        )
    })?;
    if !root.is_dir() {
        bail!(
            "workspace root must be an existing directory: {}",
            root.display()
        );
    }
    Ok(root)
}

fn select_packets(root: &Path, packet: Option<&str>, limit: usize) -> Result<Vec<PathBuf>> {
    if let Some(packet) = packet {
        return Ok(vec![resolve_packet(root, packet)?]);
    }
    let outbox = root.join(".harvis/outbox");
    if !outbox.exists() {
        bail!("outbox not found: {}", outbox.display());
    }
    let mut paths = Vec::new();
    for entry in fs::read_dir(&outbox)? {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) == Some("md") && path.is_file() {
            paths.push(path);
        }
    }
    paths.sort_by(|left, right| modified_secs(right).cmp(&modified_secs(left)));
    paths.truncate(limit);
    Ok(paths)
}

fn resolve_packet(root: &Path, packet: &str) -> Result<PathBuf> {
    let outbox = root.join(".harvis/outbox");
    let raw = expanduser(Path::new(packet));
    let candidate = if raw.extension().is_none() {
        outbox.join(format!("{packet}.md"))
    } else if !raw.is_absolute() && raw.parent() == Some(Path::new("")) {
        outbox.join(raw.file_name().unwrap_or_default())
    } else if raw.is_absolute() {
        raw
    } else {
        root.join(raw)
    };
    let candidate = candidate
        .canonicalize()
        .with_context(|| format!("packet not found: {}", candidate.display()))?;
    let outbox = outbox.canonicalize()?;
    if !candidate.starts_with(&outbox) {
        bail!(
            "packet must be under .harvis/outbox: {}",
            candidate.display()
        );
    }
    Ok(candidate)
}

fn prepare_packet_workbench(root: &Path, profile_root: &Path, packet_path: &Path) -> Result<Value> {
    let generated_at = now_rfc3339()?;
    let packet = parse_packet(packet_path, root)?;
    let packet_id = packet["packet_id"].as_str().unwrap_or("packet");
    let workbench_dir = root.join(".harvis/workbench").join(packet_id);
    fs::create_dir_all(&workbench_dir)?;

    let planner = workbench_dir.join("planner.md");
    let executor = workbench_dir.join("executor.md");
    let reviewer = workbench_dir.join("reviewer.md");
    let summary = workbench_dir.join("harvis-summary.md");
    let index = workbench_dir.join("index.json");
    let outputs = json!({
        "planner": rel(&planner, root),
        "executor": rel(&executor, root),
        "reviewer": rel(&reviewer, root),
        "summary": rel(&summary, root),
        "index": rel(&index, root),
    });

    write_lines(&planner, &planner_lines(&packet, &generated_at))?;
    write_lines(&executor, &executor_lines(&packet, &generated_at))?;
    write_lines(&reviewer, &reviewer_lines(&packet, &generated_at))?;
    write_lines(&summary, &summary_lines(&packet, &generated_at, &outputs))?;
    let index_payload = json!({
        "workbench_version": WORKBENCH_VERSION,
        "packet_id": packet["packet_id"],
        "packet_path": packet["path"],
        "generated_at": generated_at,
        "autonomy_level": 1,
        "status": "prepared",
        "profile": profile_metadata(profile_root),
        "outputs": outputs,
    });
    fs::write(&index, serde_json::to_string_pretty(&index_payload)? + "\n")?;

    Ok(json!({
        "packet_id": packet["packet_id"],
        "packet_path": packet["path"],
        "workbench_dir": rel(&workbench_dir, root),
        "outputs": outputs,
        "sensitive_marker_detected": packet["sensitive_marker_detected"]
    }))
}

fn parse_packet(path: &Path, root: &Path) -> Result<Value> {
    let text = fs::read_to_string(path)?;
    let request_raw = parse_request(&text);
    let (request, request_had_sensitive) = redact_sensitive_lines(&request_raw);
    Ok(json!({
        "packet_id": path.file_stem().and_then(|value| value.to_str()).unwrap_or("packet"),
        "path": rel(path, root),
        "status": parse_prefixed_line(&text, "Status:").unwrap_or_else(|| "unknown".to_string()),
        "source": parse_prefixed_line(&text, "Source:"),
        "safety": parse_prefixed_line(&text, "Safety:"),
        "request": request,
        "sensitive_marker_detected": request_had_sensitive || sensitive_detected(&text)
    }))
}

fn parse_request(text: &str) -> String {
    static FENCED: OnceLock<Regex> = OnceLock::new();
    let fenced = FENCED.get_or_init(|| {
        Regex::new(r"(?s)## Request\s+```text\n(?P<body>.*?)\n```").expect("valid regex")
    });
    if let Some(captures) = fenced.captures(text) {
        return captures["body"].trim().to_string();
    }
    let Some((_, after)) = text.split_once("## Request") else {
        return text.trim().to_string();
    };
    let mut body = after;
    for stop in ["## Suggested Plan", "## Verification Checklist"] {
        if let Some((before, _)) = body.split_once(stop) {
            body = before;
        }
    }
    body.trim().to_string()
}

fn parse_prefixed_line(text: &str, prefix: &str) -> Option<String> {
    text.lines().find_map(|line| {
        line.strip_prefix(prefix)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn redact_sensitive_lines(text: &str) -> (String, bool) {
    let mut found = false;
    let lines = text
        .lines()
        .map(|line| {
            if sensitive_detected(line) {
                found = true;
                "[redacted sensitive-looking line]".to_string()
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    (lines, found)
}

fn sensitive_detected(text: &str) -> bool {
    sensitive_patterns()
        .iter()
        .any(|pattern| pattern.is_match(text))
}

fn sensitive_patterns() -> &'static [Regex] {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            r"\bapi[_-]?key\b",
            r"\bsecret\b",
            r"\btoken\b",
            r"\bpassword\b",
            r"\bcookie\b",
            r"\bcredential\b",
            r"\bprivate\s+key\b",
            r"\.env\b",
            r"BEGIN\s+(RSA\s+|OPENSSH\s+|EC\s+)?PRIVATE\s+KEY",
        ]
        .iter()
        .map(|pattern| Regex::new(&format!("(?i){pattern}")).expect("valid regex"))
        .collect()
    })
}

fn planner_lines(packet: &Value, generated_at: &str) -> Vec<String> {
    vec![
        "# Planner Brief".into(),
        "".into(),
        format!("Packet: {}", value_str(packet, "packet_id")),
        format!("Generated: {generated_at}"),
        "Autonomy: Level 1 preparation only".into(),
        "".into(),
        "Request:".into(),
        "```text".into(),
        value_str(packet, "request"),
        "```".into(),
        "".into(),
        "Scope:".into(),
        format!("- Source packet: {}", value_str(packet, "path")),
        format!("- Source request: {}", value_str_or(packet, "source", "unknown")),
        format!("- Current status: {}", value_str(packet, "status")),
        "".into(),
        "Risks:".into(),
        format!("- Safety note: {}", value_str_or(packet, "safety", "none recorded")),
        format!(
            "- Sensitive marker detected: {}",
            packet["sensitive_marker_detected"].as_bool().unwrap_or(false)
        ),
        "- Mutations, commits, publishing, deployment, deletion, and external sharing require approval.".into(),
        "".into(),
        "Plan:".into(),
        "1. Re-read applicable local rules before any execution.".into(),
        "2. Confirm the task stays inside the requested workspace and approved context.".into(),
        "3. Gather only the smallest required context.".into(),
        "4. Produce a bounded implementation or review plan.".into(),
        "5. Verify results before asking H.A.R.V.I.S. to report completion.".into(),
        "".into(),
        "Done When:".into(),
        "- Scope, risks, proposed steps, and verification gates are clear enough for a human-approved execution pass.".into(),
    ]
}

fn executor_lines(packet: &Value, generated_at: &str) -> Vec<String> {
    vec![
        "# Executor Brief".into(),
        "".into(),
        format!("Packet: {}", value_str(packet, "packet_id")),
        format!("Generated: {generated_at}"),
        "Autonomy: Level 1 preparation only".into(),
        "".into(),
        "Execution Boundary:".into(),
        "- This brief does not execute the task.".into(),
        "- Read-only inspection is allowed inside the approved workspace.".into(),
        "- File edits require explicit user approval or a later approved execution mode.".into(),
        "- Commit, push, publish, deploy, delete, reset, and external API actions require explicit approval.".into(),
        "".into(),
        "Read-only Preparation Checklist:".into(),
        "1. Read AGENTS.md and local project rules.".into(),
        "2. Identify exact files or commands that would be needed.".into(),
        "3. Check whether the packet is blocked or sensitive.".into(),
        "4. Prepare a minimal execution path and verification command list.".into(),
        "".into(),
        "Gated Actions:".into(),
        "- Source edits: approval required.".into(),
        "- Destructive operations: approval required.".into(),
        "- Public artifacts: safety scan required before publishing.".into(),
        "- Memory adoption: human review required.".into(),
    ]
}

fn reviewer_lines(packet: &Value, generated_at: &str) -> Vec<String> {
    vec![
        "# Reviewer Brief".into(),
        "".into(),
        format!("Packet: {}", value_str(packet, "packet_id")),
        format!("Generated: {generated_at}"),
        "Autonomy: Level 1 preparation only".into(),
        "".into(),
        "Review Questions:".into(),
        "- Did the work stay inside the packet scope?".into(),
        "- Were local rules and privacy boundaries followed?".into(),
        "- Were tests, smoke checks, or safety scans run?".into(),
        "- Were source files outside `.harvis/` changed only after approval?".into(),
        "- Does any output expose credentials, raw logs, raw memory, hidden prompts, or private access files?".into(),
        "".into(),
        "Verification Checklist:".into(),
        "1. Check packet status and safety note.".into(),
        "2. Confirm generated artifacts are under approved output directories.".into(),
        "3. Confirm public-facing outputs pass safety checks when available.".into(),
        "4. Confirm H.A.R.V.I.S. summary names remaining risks and follow-ups.".into(),
    ]
}

fn summary_lines(packet: &Value, generated_at: &str, outputs: &Value) -> Vec<String> {
    vec![
        "# H.A.R.V.I.S. Workbench Summary".into(),
        "".into(),
        format!("Packet: {}", value_str(packet, "packet_id")),
        format!("Generated: {generated_at}"),
        "Status: role briefs prepared".into(),
        "Autonomy: Level 1 preparation only".into(),
        "".into(),
        "Prepared Files:".into(),
        format!("- Planner: {}", value_str(outputs, "planner")),
        format!("- Executor: {}", value_str(outputs, "executor")),
        format!("- Reviewer: {}", value_str(outputs, "reviewer")),
        "".into(),
        "Coordinator View:".into(),
        "- H.A.R.V.I.S. has decomposed the packet into role-specific briefs.".into(),
        "- No code, source file, commit, publish, deploy, or destructive operation was performed."
            .into(),
        "- The next step is human-approved execution or review of the Planner brief.".into(),
        "".into(),
        "Packet Safety:".into(),
        format!("- Packet status: {}", value_str(packet, "status")),
        format!(
            "- Safety note: {}",
            value_str_or(packet, "safety", "none recorded")
        ),
        format!(
            "- Sensitive marker detected: {}",
            packet["sensitive_marker_detected"]
                .as_bool()
                .unwrap_or(false)
        ),
    ]
}

fn write_lines(path: &Path, lines: &[String]) -> Result<()> {
    fs::write(path, lines.join("\n").trim_end().to_string() + "\n")?;
    Ok(())
}

fn profile_metadata(profile_root: &Path) -> Value {
    let root = expanduser(profile_root);
    let resolved = root.canonicalize().unwrap_or(root);
    let mut files = Vec::new();
    let mut missing = Vec::new();
    for relative_path in PROFILE_FILES {
        let path = resolved.join(relative_path);
        if path.exists() {
            files.push(json!({
                "path": relative_path,
                "bytes": path.metadata().map(|metadata| metadata.len()).unwrap_or(0),
                "modified_at": modified_secs(&path)
            }));
        } else {
            missing.push((*relative_path).to_string());
        }
    }
    json!({"root": resolved.display().to_string(), "exists": resolved.exists(), "files": files, "missing": missing})
}

fn modified_secs(path: &Path) -> u64 {
    path.metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn value_str(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn value_str_or(value: &Value, key: &str, fallback: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_fenced_request() {
        let text =
            "Status: new\n\n## Request\n\n```text\n@harvis do thing\n```\n\n## Suggested Plan\n";
        assert_eq!(parse_request(text), "@harvis do thing");
    }
}
