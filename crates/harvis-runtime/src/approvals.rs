use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::memory::{append_memory_candidate, sync_memory_candidate_reviews, MemoryCandidateInput};
use crate::runs::rel;
use harvis_core::time::now_rfc3339;

pub const APPROVAL_VERSION: &str = "v0.12-alpha";

const ACTION_TYPES: &[&str] = &[
    "write_file",
    "run_command",
    "publish_projection",
    "commit",
    "push",
    "deploy",
    "delete",
    "read_outside_allowlist",
    "install_service",
    "external_send",
    "other",
];

const DECISIONS: &[&str] = &["approved", "denied", "cancelled"];

pub const STALLED_RUN_ALERT_KIND: &str = "stalled_run_alert";

pub const MEMORY_CANDIDATE_REVIEW_KIND: &str = "memory_candidate_review";

/// T307: raise a memory-candidate review approval asking a human to
/// approve/reject/defer one workbench memory candidate. Deduplicates on
/// (candidate_id, kind) across ALL statuses: a candidate with any existing
/// review item never gets a second one — decided items are written back onto
/// the candidate line by `memory::sync_memory_candidate_reviews` instead.
/// Returns Ok(None) when a review item already exists for the candidate.
pub fn create_memory_candidate_review(root: &Path, candidate: &Value) -> Result<Option<Value>> {
    let root = resolve_workspace_root(root)?;
    let candidate_id = safe_text(
        candidate
            .get("candidate_id")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        160,
    );
    if !candidate_id.starts_with("workbench_") {
        bail!("candidate_id must start with workbench_");
    }
    for path in json_paths_by_mtime_desc(&approvals_dir(&root)?)? {
        let Some(existing) = read_json(&path) else {
            continue;
        };
        if existing.get("candidate_id").and_then(Value::as_str) == Some(candidate_id.as_str())
            && existing.get("kind").and_then(Value::as_str) == Some(MEMORY_CANDIDATE_REVIEW_KIND)
        {
            return Ok(None);
        }
    }
    let source_type = safe_text(
        candidate
            .get("source_type")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        80,
    );
    let source_id = safe_text(
        candidate
            .get("source_id")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        160,
    );
    let summary = safe_text(
        candidate
            .get("summary")
            .and_then(Value::as_str)
            .unwrap_or("Memory candidate requires review."),
        1000,
    );
    // NOTE: keep this reason formula in sync with
    // digital_me/scripts/import_workbench_candidates.py, which builds the
    // isomorphic approval payload for the one-shot backlog import.
    let reason = format!(
        "Memory candidate {candidate_id} ({source_type}/{source_id}) awaits human review: {summary}"
    );
    let evidence = candidate
        .get("evidence")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|item| safe_text(item, 240))
        .take(12)
        .collect::<Vec<_>>();
    let approval_id = approval_id_for(
        &candidate_id,
        MEMORY_CANDIDATE_REVIEW_KIND,
        &candidate_id,
        &reason,
    )?;
    let moment = now_rfc3339()?;
    let approval = json!({
        "approval_version": APPROVAL_VERSION,
        "approval_id": approval_id,
        "kind": MEMORY_CANDIDATE_REVIEW_KIND,
        "status": "pending",
        "candidate_id": candidate_id,
        "created_at": moment,
        "updated_at": moment,
        "risk": "medium",
        "scope": "one_time",
        "action": {
            "type": "other",
            "target": {"kind": "memory_candidate", "display": candidate_id},
            "reason": safe_text(&reason, 1000)
        },
        "options": ["approve", "reject", "defer"],
        "decision": null,
        "candidate": {
            "source_type": source_type,
            "source_id": source_id,
            "summary": summary,
            "created_at": candidate
                .get("created_at")
                .cloned()
                .unwrap_or(Value::Null),
            "evidence": evidence
        },
        "safety": {
            "recordOnly": true,
            "executesAction": false,
            "includesSecrets": false,
            "includesRawMemory": false,
            "includesLocalAbsolutePaths": false
        }
    });
    let path = approval_path(&root, approval["approval_id"].as_str().unwrap_or_default())?;
    fs::write(&path, serde_json::to_string_pretty(&approval)? + "\n")?;
    write_approval_markdown(&root, &approval)?;
    Ok(Some(approval))
}

/// T307: all memory-candidate review items (any status), newest first. Used by
/// the tick-side sync to dedupe pending items and to find decided reviews that
/// still need to be written back onto their candidate lines.
pub fn memory_candidate_review_items(root: &Path) -> Result<Vec<Value>> {
    let root = resolve_workspace_root(root)?;
    let mut items = Vec::new();
    for path in json_paths_by_mtime_desc(&approvals_dir(&root)?)? {
        let Some(item) = read_json(&path) else {
            continue;
        };
        if item.get("kind").and_then(Value::as_str) == Some(MEMORY_CANDIDATE_REVIEW_KIND) {
            items.push(item);
        }
    }
    Ok(items)
}

/// T304: raise a stalled-run alert approval asking a human to pick
/// retry/escalate/cancel. Deduplicates on (run_id, kind, status=pending) so a
/// run with an unresolved alert does not spam a new item every tick.
/// Returns Ok(None) when a pending alert already exists for the run.
pub fn create_stalled_run_alert(
    root: &Path,
    run_id: &str,
    run_created_at: &str,
    threshold_hours: u64,
) -> Result<Option<Value>> {
    let root = resolve_workspace_root(root)?;
    let run_id = safe_text(run_id, 120);
    if !run_id.starts_with("run_") {
        bail!("run_id must start with run_");
    }
    for path in json_paths_by_mtime_desc(&approvals_dir(&root)?)? {
        let Some(existing) = read_json(&path) else {
            continue;
        };
        if existing.get("run_id").and_then(Value::as_str) == Some(run_id.as_str())
            && existing.get("kind").and_then(Value::as_str) == Some(STALLED_RUN_ALERT_KIND)
            && existing.get("status").and_then(Value::as_str) == Some("pending")
        {
            return Ok(None);
        }
    }
    let reason = format!(
        "Run {run_id} has been stuck in planning with a blocked handoff since {run_created_at}, beyond the {threshold_hours}h stalled threshold. Choose retry, escalate, or cancel."
    );
    let approval_id = approval_id_for(&run_id, STALLED_RUN_ALERT_KIND, &run_id, &reason)?;
    let moment = now_rfc3339()?;
    let approval = json!({
        "approval_version": APPROVAL_VERSION,
        "approval_id": approval_id,
        "kind": STALLED_RUN_ALERT_KIND,
        "status": "pending",
        "run_id": run_id,
        "created_at": moment,
        "updated_at": moment,
        "risk": "medium",
        "scope": "one_time",
        "action": {
            "type": "other",
            "target": {"kind": "run", "display": run_id},
            "reason": safe_text(&reason, 1000)
        },
        "options": ["retry", "escalate", "cancel"],
        "decision": null,
        "safety": {
            "recordOnly": true,
            "executesAction": false,
            "includesSecrets": false,
            "includesRawMemory": false,
            "includesLocalAbsolutePaths": false
        }
    });
    let path = approval_path(&root, approval["approval_id"].as_str().unwrap_or_default())?;
    fs::write(&path, serde_json::to_string_pretty(&approval)? + "\n")?;
    write_approval_markdown(&root, &approval)?;
    update_run_approval_state(&root, approval["run_id"].as_str().unwrap_or_default())?;
    Ok(Some(approval))
}

pub fn create_approval(
    root: &Path,
    run_id: &str,
    action_type: &str,
    target: &str,
    reason: &str,
    risk: &str,
    scope: &str,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let run_id = safe_text(run_id, 120);
    if !run_id.starts_with("run_") {
        bail!("run_id must start with run_");
    }
    if !ACTION_TYPES.contains(&action_type.trim()) {
        bail!("action_type must be one of: {}", ACTION_TYPES.join(", "));
    }
    let approval_id = approval_id_for(&run_id, action_type, target, reason)?;
    let moment = now_rfc3339()?;
    let approval = json!({
        "approval_version": APPROVAL_VERSION,
        "approval_id": approval_id,
        "status": "pending",
        "run_id": run_id,
        "created_at": moment,
        "updated_at": moment,
        "risk": safe_text(risk, 80).if_empty("medium"),
        "scope": safe_text(scope, 80).if_empty("one_time"),
        "action": {
            "type": action_type.trim(),
            "target": target_ref(&root, target),
            "reason": safe_text(reason, 1000)
        },
        "decision": null,
        "safety": {
            "recordOnly": true,
            "executesAction": false,
            "includesSecrets": false,
            "includesRawMemory": false,
            "includesLocalAbsolutePaths": false
        }
    });
    let path = approval_path(&root, approval["approval_id"].as_str().unwrap_or_default())?;
    fs::write(&path, serde_json::to_string_pretty(&approval)? + "\n")?;
    write_approval_markdown(&root, &approval)?;
    update_run_approval_state(&root, approval["run_id"].as_str().unwrap_or_default())?;
    Ok(approval)
}

pub fn decide_approval(
    root: &Path,
    approval_id: &str,
    decision: &str,
    decided_by: &str,
    notes: &str,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let decision = decision.trim().to_ascii_lowercase();
    if !DECISIONS.contains(&decision.as_str()) {
        bail!("decision must be one of: {}", DECISIONS.join(", "));
    }
    let path = approval_path(&root, approval_id)?;
    let mut approval =
        read_json(&path).with_context(|| format!("approval not found: {approval_id}"))?;
    let moment = now_rfc3339()?;
    approval["status"] = json!(decision);
    approval["updated_at"] = json!(moment);
    approval["decision"] = json!({
        "by": safe_text(decided_by, 120).if_empty("human"),
        "at": approval["updated_at"].clone(),
        "notes": safe_text(notes, 1000)
    });
    fs::write(&path, serde_json::to_string_pretty(&approval)? + "\n")?;
    write_approval_markdown(&root, &approval)?;
    if let Some(run_id) = approval.get("run_id").and_then(Value::as_str) {
        update_run_approval_state(&root, run_id)?;
    }
    if approval.get("kind").and_then(Value::as_str) == Some(MEMORY_CANDIDATE_REVIEW_KIND) {
        // T307: a candidate-review decision IS the memory record — write it
        // back onto the candidate line and refresh memory/index.json instead
        // of appending a fresh candidate, which would re-enter the same review
        // queue as self-referential noise. The decision file above is already
        // durable; the tick-side sync repeats this writeback idempotently, so
        // manual approval-file edits are picked up on the next tick as well.
        sync_memory_candidate_reviews(&root).context("memory candidate review writeback failed")?;
    } else {
        let _ = append_memory_candidate(
            &root,
            MemoryCandidateInput {
                source_type: "approval_decision".to_string(),
                source_id: approval_id.to_string(),
                summary: format!("Approval {approval_id} was {decision}."),
                evidence: vec![
                    format!("approval_id={approval_id}"),
                    format!("decision={decision}"),
                    format!(
                        "action_type={}",
                        approval["action"]["type"].as_str().unwrap_or("unknown")
                    ),
                    format!("risk={}", approval["risk"].as_str().unwrap_or("medium")),
                ],
                created_by: Some("approval-decision".to_string()),
            },
        );
    }
    Ok(approval)
}

pub fn list_approvals(root: &Path, status: Option<&str>, limit: usize) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let status_filter = status.map(str::trim).filter(|value| !value.is_empty());
    let mut rows = Vec::new();
    for path in json_paths_by_mtime_desc(&approvals_dir(&root)?)? {
        let Some(item) = summarize_approval(&root, &path)? else {
            continue;
        };
        if status_filter
            .is_some_and(|status| item.get("status").and_then(Value::as_str) != Some(status))
        {
            continue;
        }
        rows.push(item);
        if rows.len() >= limit {
            break;
        }
    }
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "approval_count": rows.len(),
        "approvals": rows
    }))
}

fn summarize_approval(root: &Path, path: &Path) -> Result<Option<Value>> {
    let Some(approval) = read_json(path) else {
        return Ok(None);
    };
    let action = approval.get("action").and_then(Value::as_object);
    let target = action
        .and_then(|action| action.get("target"))
        .cloned()
        .unwrap_or(Value::Null);
    Ok(Some(json!({
        "approval_id": approval.get("approval_id").cloned().unwrap_or(Value::Null),
        "status": approval.get("status").cloned().unwrap_or(Value::Null),
        "run_id": approval.get("run_id").cloned().unwrap_or(Value::Null),
        "risk": approval.get("risk").cloned().unwrap_or(Value::Null),
        "scope": approval.get("scope").cloned().unwrap_or(Value::Null),
        "action_type": action.and_then(|action| action.get("type")).cloned().unwrap_or(Value::Null),
        "target": target,
        "updated_at": approval.get("updated_at").cloned().unwrap_or(Value::Null),
        "path": rel(path, root)
    })))
}

fn update_run_approval_state(root: &Path, run_id: &str) -> Result<()> {
    let path = root.join(".harvis/runs").join(format!("{run_id}.json"));
    let Some(mut run) = read_json(&path) else {
        return Ok(());
    };
    let mut ids = BTreeSet::new();
    let mut pending = false;
    for approval_path in json_paths_by_mtime_desc(&approvals_dir(root)?)? {
        let Some(approval) = read_json(&approval_path) else {
            continue;
        };
        if approval.get("run_id").and_then(Value::as_str) != Some(run_id) {
            continue;
        }
        if let Some(approval_id) = approval.get("approval_id").and_then(Value::as_str) {
            ids.insert(approval_id.to_string());
        }
        if approval.get("status").and_then(Value::as_str) == Some("pending") {
            pending = true;
        }
    }
    run["approval"] = json!({
        "required": !ids.is_empty(),
        "pending": pending,
        "ids": ids.into_iter().collect::<Vec<_>>()
    });
    run["updated_at"] = json!(now_rfc3339()?);
    fs::write(path, serde_json::to_string_pretty(&run)? + "\n")?;
    Ok(())
}

fn write_approval_markdown(root: &Path, approval: &Value) -> Result<()> {
    let approval_id = approval["approval_id"]
        .as_str()
        .unwrap_or("approval_unknown");
    let path = approvals_dir(root)?.join(format!("{approval_id}.md"));
    let decision = approval.get("decision").filter(|value| value.is_object());
    let mut lines = vec![
        format!("# H.A.R.V.I.S. Approval {approval_id}"),
        String::new(),
        format!(
            "Status: {}",
            approval["status"].as_str().unwrap_or("unknown")
        ),
        format!(
            "Kind: {}",
            approval
                .get("kind")
                .and_then(Value::as_str)
                .unwrap_or("action_request")
        ),
        // T307: candidate-review items have no run; show the candidate instead.
        match approval.get("candidate_id").and_then(Value::as_str) {
            Some(candidate_id) => format!("Candidate: {candidate_id}"),
            None => format!("Run: {}", approval["run_id"].as_str().unwrap_or("unknown")),
        },
        format!(
            "Action: {}",
            approval["action"]["type"].as_str().unwrap_or("unknown")
        ),
        format!("Risk: {}", approval["risk"].as_str().unwrap_or("medium")),
        format!(
            "Scope: {}",
            approval["scope"].as_str().unwrap_or("one_time")
        ),
        format!(
            "Created: {}",
            approval["created_at"].as_str().unwrap_or("unknown")
        ),
        format!(
            "Updated: {}",
            approval["updated_at"].as_str().unwrap_or("unknown")
        ),
        String::new(),
        "Target:".to_string(),
        format!(
            "- Kind: {}",
            approval["action"]["target"]["kind"]
                .as_str()
                .unwrap_or("unspecified")
        ),
        format!(
            "- Display: {}",
            approval["action"]["target"]["display"]
                .as_str()
                .unwrap_or("unspecified")
        ),
        String::new(),
        "Reason:".to_string(),
        format!(
            "- {}",
            approval["action"]["reason"].as_str().unwrap_or_default()
        ),
        String::new(),
        "Safety:".to_string(),
        "- This approval item is record-only.".to_string(),
        "- Creating or approving it does not execute the requested action.".to_string(),
        "- Execution requires a separate approved runtime policy.".to_string(),
        String::new(),
    ];
    if let Some(options) = approval.get("options").and_then(Value::as_array) {
        let choices = options
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(", ");
        if !choices.is_empty() {
            lines.extend([
                "Options:".to_string(),
                format!("- {choices}"),
                String::new(),
            ]);
        }
    }
    if let Some(decision) = decision {
        lines.extend([
            "Decision:".to_string(),
            format!("- By: {}", decision["by"].as_str().unwrap_or("unknown")),
            format!("- At: {}", decision["at"].as_str().unwrap_or("unknown")),
            format!(
                "- Notes: {}",
                decision["notes"].as_str().unwrap_or_default()
            ),
            String::new(),
        ]);
    }
    fs::write(path, lines.join("\n"))?;
    Ok(())
}

fn approval_id_for(run_id: &str, action_type: &str, target: &str, reason: &str) -> Result<String> {
    let timestamp = timestamp_slug(&now_rfc3339()?);
    let seed = format!("{run_id}:{action_type}:{target}:{reason}:{timestamp}");
    let digest = Sha256::digest(seed.as_bytes())
        .iter()
        .take(4)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(format!("approval_{timestamp}_{digest}"))
}

fn target_ref(root: &Path, value: &str) -> Value {
    let cleaned = safe_text(value, 500);
    if cleaned.is_empty() {
        return json!({"kind": "unspecified", "display": "unspecified"});
    }
    let candidate = expanduser(Path::new(&cleaned));
    if candidate.is_absolute() {
        if let Ok(display) = candidate
            .canonicalize()
            .unwrap_or(candidate.clone())
            .strip_prefix(root)
        {
            return json!({"kind": "workspace_path", "display": display.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/")});
        }
        return json!({"kind": "outside_workspace", "display": candidate.file_name().and_then(|value| value.to_str()).unwrap_or("outside-workspace")});
    }
    json!({"kind": "relative_or_resource", "display": cleaned})
}

fn approval_path(root: &Path, approval_id: &str) -> Result<PathBuf> {
    if !approval_id.starts_with("approval_") {
        bail!("approval_id must start with approval_");
    }
    Ok(approvals_dir(root)?.join(format!("{approval_id}.json")))
}

fn approvals_dir(root: &Path) -> Result<PathBuf> {
    let path = root.join(".harvis/approvals");
    fs::create_dir_all(&path)?;
    Ok(path)
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

fn read_json(path: &Path) -> Option<Value> {
    let text = fs::read_to_string(path).ok()?;
    let value = serde_json::from_str::<Value>(&text).ok()?;
    value.is_object().then_some(value)
}

fn modified_secs(path: &Path) -> u64 {
    path.metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn safe_text(value: &str, max_chars: usize) -> String {
    value
        .replace('\0', "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max_chars)
        .collect()
}

fn timestamp_slug(moment: &str) -> String {
    let digits = moment
        .chars()
        .filter(|character| character.is_ascii_digit())
        .take(14)
        .collect::<String>();
    let (date, time) = digits.split_at(8);
    format!("{date}T{time}Z")
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

trait IfEmpty {
    fn if_empty(self, fallback: &'static str) -> String;
}

impl IfEmpty for String {
    fn if_empty(self, fallback: &'static str) -> String {
        if self.is_empty() {
            fallback.to_string()
        } else {
            self
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::init::init_workspace;
    use crate::runs::sync_packet_runs;

    #[test]
    fn creates_memory_candidate_review_once_and_dedupes() {
        let root = std::env::temp_dir().join(format!(
            "harvis-candidate-review-rust-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let candidate = json!({
            "candidate_id": "workbench_20260718T000000Z_fake-t307-unit",
            "kind": "memory_candidate",
            "source_type": "task_done",
            "source_id": "task_fake_t307",
            "status": "candidate",
            "requires_review": true,
            "summary": "Task completed: T307 unit fixture",
            "evidence": ["task_id=task_fake_t307", "owner_slot_id=reviewer"],
            "created_by": "agent-room-task-status",
            "created_at": "2026-07-18T00:00:00.000000Z"
        });
        let first = create_memory_candidate_review(&root, &candidate)
            .expect("create")
            .expect("new item");
        assert_eq!(first["kind"], MEMORY_CANDIDATE_REVIEW_KIND);
        assert_eq!(first["status"], "pending");
        assert_eq!(
            first["candidate_id"],
            "workbench_20260718T000000Z_fake-t307-unit"
        );
        assert_eq!(first["options"], json!(["approve", "reject", "defer"]));
        assert_eq!(first["decision"], Value::Null);
        assert_eq!(first["candidate"]["source_type"], "task_done");
        let approval_id = first["approval_id"].as_str().expect("approval id");
        let json_path = root
            .join(".harvis/approvals")
            .join(format!("{approval_id}.json"));
        let md_path = json_path.with_extension("md");
        assert!(json_path.exists());
        assert!(md_path.exists());
        let markdown = fs::read_to_string(&md_path).expect("read markdown");
        assert!(markdown.contains("Candidate: workbench_20260718T000000Z_fake-t307-unit"));
        assert!(markdown.contains("Options:"));
        // Second call for the same candidate dedupes, even across statuses.
        let second = create_memory_candidate_review(&root, &candidate).expect("dedupe ok");
        assert!(second.is_none());
        let items = memory_candidate_review_items(&root).expect("items");
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["candidate_id"],
            "workbench_20260718T000000Z_fake-t307-unit"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn creates_and_decides_approval_without_executing_action() {
        let root =
            std::env::temp_dir().join(format!("harvis-approval-rust-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let packet = root.join(".harvis/outbox/abc123.md");
        fs::write(&packet, "# H.A.R.V.I.S. Work Packet abc123\n\nStatus: new\nSource: .harvis/inbox.md:1\nSafety: ok\n").expect("packet");
        sync_packet_runs(&root, Some(vec![packet]), 500).expect("sync");
        let approval = create_approval(
            &root,
            "run_abc123",
            "write_file",
            "src/main.rs",
            "test",
            "medium",
            "one_time",
        )
        .expect("approval");
        assert_eq!(approval["status"], "pending");
        let listed = list_approvals(&root, None, 50).expect("list");
        assert_eq!(listed["approval_count"], 1);
        let decided = decide_approval(
            &root,
            approval["approval_id"].as_str().unwrap(),
            "approved",
            "human",
            "ok",
        )
        .expect("decide");
        assert_eq!(decided["status"], "approved");
        let run = read_json(&root.join(".harvis/runs/run_abc123.json")).expect("run");
        assert_eq!(run["approval"]["pending"], false);
        let _ = fs::remove_dir_all(root);
    }
}
