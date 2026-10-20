use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

use harvis_core::time::now_rfc3339;

pub const RUN_LEDGER_VERSION: &str = "v0.11-alpha";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PacketMetadata {
    pub generated: Option<String>,
    pub packet_id: String,
    pub packet_path: String,
    pub safety: Option<String>,
    pub source: Option<String>,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunOrigin {
    pub source: Option<String>,
    pub trigger: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunApproval {
    pub ids: Vec<Value>,
    pub pending: bool,
    pub required: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunRecord {
    pub approval: RunApproval,
    pub created_at: String,
    pub mode: Value,
    pub origin: RunOrigin,
    pub outputs: Value,
    pub packet: PacketMetadata,
    pub packet_id: String,
    pub run_id: String,
    pub run_ledger_version: String,
    pub state: String,
    pub updated_at: String,
    pub verification: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunSyncItem {
    pub json_path: String,
    pub markdown_path: String,
    pub packet_id: String,
    pub run_id: String,
    pub state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunSyncResponse {
    pub run_count: usize,
    pub runs: Vec<RunSyncItem>,
    pub workspace_root: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunListItem {
    pub mode: Option<Value>,
    pub packet_id: Option<Value>,
    pub path: String,
    pub run_id: Option<Value>,
    pub state: Option<Value>,
    pub updated_at: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunListResponse {
    pub run_count: usize,
    pub runs: Vec<RunListItem>,
    pub workspace_root: String,
}

pub fn sync_packet_runs(
    root: &Path,
    packet_paths: Option<Vec<PathBuf>>,
    limit: usize,
) -> Result<RunSyncResponse> {
    let root = resolve_workspace_root(root)?;
    let outbox = root.join(".harvis/outbox");
    let packets = match packet_paths {
        Some(paths) => paths,
        None => newest_packet_paths(&outbox, limit)?,
    };
    let mut runs = Vec::new();
    for packet_path in packets {
        if packet_path.exists() {
            runs.push(sync_packet_run(&root, &packet_path)?);
        }
    }
    Ok(RunSyncResponse {
        run_count: runs.len(),
        runs,
        workspace_root: root.display().to_string(),
    })
}

pub fn list_runs(root: &Path, limit: usize) -> Result<RunListResponse> {
    let root = resolve_workspace_root(root)?;
    let runs_dir = root.join(".harvis/runs");
    let mut paths = json_paths_by_mtime_desc(&runs_dir)?;
    paths.truncate(limit);
    let mut runs = Vec::new();
    for path in paths {
        let Some(loaded) = read_existing(&path) else {
            continue;
        };
        runs.push(RunListItem {
            run_id: loaded.get("run_id").cloned(),
            state: loaded.get("state").cloned(),
            mode: loaded.get("mode").cloned(),
            packet_id: loaded.get("packet_id").cloned(),
            updated_at: loaded.get("updated_at").cloned(),
            path: rel(&path, &root),
        });
    }
    Ok(RunListResponse {
        run_count: runs.len(),
        runs,
        workspace_root: root.display().to_string(),
    })
}

pub fn resolve_packet_path(root: &Path, value: &Path) -> Result<PathBuf> {
    let root = resolve_workspace_root(root)?;
    let outbox = root.join(".harvis/outbox");
    let mut candidate = expanduser(value);
    if !candidate.is_absolute() {
        candidate = if candidate.parent() != Some(Path::new(""))
            && candidate.parent() != Some(Path::new("."))
        {
            root.join(candidate)
        } else {
            outbox.join(candidate.file_name().unwrap_or_default())
        };
    }
    let candidate = candidate
        .canonicalize()
        .with_context(|| format!("packet not found: {}", candidate.display()))?;
    if !candidate.is_file() {
        bail!("packet not found: {}", candidate.display());
    }
    let outbox = outbox.canonicalize()?;
    if !candidate.starts_with(&outbox) {
        bail!(
            "packet must be under .harvis/outbox: {}",
            candidate.display()
        );
    }
    Ok(candidate)
}

pub fn sync_packet_run(root: &Path, packet_path: &Path) -> Result<RunSyncItem> {
    let run = build_run(root, packet_path)?;
    let (json_path, md_path) = run_paths(root, &run.run_id)?;
    fs::write(&json_path, serde_json::to_string_pretty(&run)? + "\n")?;
    write_run_markdown(&md_path, &run)?;
    Ok(RunSyncItem {
        run_id: run.run_id.clone(),
        state: run.state.clone(),
        packet_id: run.packet_id.clone(),
        json_path: rel(&json_path, root),
        markdown_path: rel(&md_path, root),
    })
}

pub fn build_run(root: &Path, packet_path: &Path) -> Result<RunRecord> {
    let packet = packet_metadata(packet_path, root)?;
    let run_id = run_id_for_packet(packet_path);
    let (json_path, _) = run_paths(root, &run_id)?;
    let existing = read_existing(&json_path).unwrap_or(Value::Object(Default::default()));
    let created_at = existing
        .get("created_at")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or(now_rfc3339()?);
    let mode = existing
        .get("mode")
        .cloned()
        .unwrap_or_else(|| Value::String("planner".to_string()));
    let approval_ids = existing
        .get("approval")
        .and_then(|approval| approval.get("ids"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let verification = existing
        .get("verification")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({"status": "not_started"}));
    let outputs = existing
        .get("outputs")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));
    let state = state_for_packet_status(&packet.status).to_string();
    Ok(RunRecord {
        approval: RunApproval {
            required: state == "blocked",
            pending: false,
            ids: approval_ids,
        },
        created_at,
        mode,
        origin: RunOrigin {
            trigger: "file_inbox".to_string(),
            source: packet.source.clone(),
        },
        outputs,
        packet_id: packet.packet_id.clone(),
        run_id,
        run_ledger_version: RUN_LEDGER_VERSION.to_string(),
        state,
        updated_at: now_rfc3339()?,
        verification,
        packet,
    })
}

pub fn packet_metadata(packet_path: &Path, root: &Path) -> Result<PacketMetadata> {
    let text = fs::read_to_string(packet_path)?;
    let packet_id = packet_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_string();
    Ok(PacketMetadata {
        generated: parse_prefixed_line(&text, "Generated:"),
        packet_id,
        packet_path: rel(packet_path, root),
        safety: parse_prefixed_line(&text, "Safety:"),
        source: parse_prefixed_line(&text, "Source:"),
        status: parse_prefixed_line(&text, "Status:").unwrap_or_else(|| "unknown".to_string()),
    })
}

pub fn run_id_for_packet(packet_path: &Path) -> String {
    format!(
        "run_{}",
        packet_path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
    )
}

pub fn state_for_packet_status(status: &str) -> &'static str {
    match status {
        "blocked" => "blocked",
        "verified" => "verified",
        "archived" => "archived",
        _ => "planning",
    }
}

fn write_run_markdown(path: &Path, run: &RunRecord) -> Result<()> {
    let mode = run.mode.as_str().unwrap_or("planner");
    let lines = [
        format!("# H.A.R.V.I.S. Run {}", run.run_id),
        String::new(),
        format!("Status: {}", run.state),
        format!("Mode: {mode}"),
        format!("Packet: {}", run.packet.packet_path),
        format!("Created: {}", run.created_at),
        format!("Updated: {}", run.updated_at),
        format!("Approval Required: {}", py_bool(run.approval.required)),
        String::new(),
        "Safety:".to_string(),
        format!("- Packet status: {}", run.packet.status),
        format!(
            "- Packet safety note: {}",
            run.packet.safety.as_deref().unwrap_or("none recorded")
        ),
        String::new(),
        "Lifecycle:".to_string(),
        "- planning: packet accepted and ready for planning/review".to_string(),
        "- blocked: human review or approval required before execution".to_string(),
        "- verified: completed and checked".to_string(),
        "- archived: retained for audit".to_string(),
        String::new(),
    ];
    fs::write(path, lines.join("\n"))?;
    Ok(())
}

fn run_paths(root: &Path, run_id: &str) -> Result<(PathBuf, PathBuf)> {
    let runs_dir = root.join(".harvis/runs");
    fs::create_dir_all(&runs_dir)?;
    Ok((
        runs_dir.join(format!("{run_id}.json")),
        runs_dir.join(format!("{run_id}.md")),
    ))
}

fn read_existing(path: &Path) -> Option<Value> {
    let text = fs::read_to_string(path).ok()?;
    let loaded: Value = serde_json::from_str(&text).ok()?;
    loaded.is_object().then_some(loaded)
}

fn parse_prefixed_line(text: &str, prefix: &str) -> Option<String> {
    for line in text.lines() {
        if line.starts_with(prefix) {
            let value = line.split_once(':')?.1.trim();
            return (!value.is_empty()).then(|| value.to_string());
        }
    }
    None
}

fn newest_packet_paths(outbox: &Path, limit: usize) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    if !outbox.exists() {
        return Ok(paths);
    }
    for entry in fs::read_dir(outbox)? {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) == Some("md") && path.is_file() {
            paths.push(path);
        }
    }
    paths.sort_by(|left, right| {
        modified_secs(right)
            .cmp(&modified_secs(left))
            .then_with(|| left.cmp(right))
    });
    paths.truncate(limit);
    Ok(paths)
}

fn json_paths_by_mtime_desc(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    if !dir.exists() {
        return Ok(paths);
    }
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) == Some("json") && path.is_file() {
            paths.push(path);
        }
    }
    paths.sort_by(|left, right| {
        modified_secs(right)
            .cmp(&modified_secs(left))
            .then_with(|| left.cmp(right))
    });
    Ok(paths)
}

fn modified_secs(path: &Path) -> u64 {
    path.metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

pub fn resolve_workspace_root(value: &Path) -> Result<PathBuf> {
    let root = expanduser(value);
    if root.as_os_str().is_empty() {
        bail!("workspace root must be a non-empty path");
    }
    if root.is_absolute() {
        Ok(root)
    } else {
        Ok(std::env::current_dir()?.join(root))
    }
}

pub fn rel(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .map(|relative| {
            relative
                .to_string_lossy()
                .replace(std::path::MAIN_SEPARATOR, "/")
        })
        .unwrap_or_else(|_| path.display().to_string())
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

fn py_bool(value: bool) -> &'static str {
    if value {
        "True"
    } else {
        "False"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inbox::{scan_inboxes, ScanOptions};
    use crate::init::init_workspace;

    #[test]
    fn syncs_packet_runs_and_preserves_state_mapping() {
        let root =
            std::env::temp_dir().join(format!("harvis-runs-rust-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init workspace");
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis review this fixture.\n\n@harvis use this token: abc\n",
        )
        .expect("write inbox");
        let packets = scan_inboxes(ScanOptions {
            root: root.clone(),
            inboxes: Vec::new(),
            allow_outside_root: false,
        })
        .expect("scan inbox");
        let response = sync_packet_runs(&root, Some(packets), 500).expect("sync runs");
        assert_eq!(response.run_count, 2);
        assert!(response.runs.iter().any(|run| run.state == "planning"));
        assert!(response.runs.iter().any(|run| run.state == "blocked"));
        for item in &response.runs {
            assert!(root.join(&item.json_path).exists());
            assert!(root.join(&item.markdown_path).exists());
        }
        let listed = list_runs(&root, 50).expect("list runs");
        assert_eq!(listed.run_count, 2);
        let _ = fs::remove_dir_all(root);
    }
}
