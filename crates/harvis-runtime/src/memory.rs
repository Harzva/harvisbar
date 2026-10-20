use anyhow::{bail, Context, Result};
use regex::Regex;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use crate::memory_provider::commit_reviewed_workbench_candidate;
use crate::profile::{expanduser, PROFILE_FILES};
use crate::runs::rel;
use harvis_core::time::now_rfc3339;

pub const SNAPSHOT_VERSION: &str = "v0.14-alpha";

#[derive(Debug, Clone)]
pub struct MemorySnapshotOptions {
    pub root: PathBuf,
    pub profile_root: PathBuf,
    pub max_events: usize,
    pub max_packets: usize,
    pub max_reports: usize,
    pub max_excerpt_chars: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct MemorySnapshotResult {
    pub candidate_signal_count: usize,
    pub index_path: String,
    pub knowledge_source_count: usize,
    pub packet_status_counts: BTreeMap<String, usize>,
    pub signals_path: String,
    pub snapshot_path: String,
    pub warnings: Vec<String>,
    pub workspace_root: String,
}

#[derive(Debug, Clone, Default)]
pub struct MemoryCandidateInput {
    pub source_type: String,
    pub source_id: String,
    pub summary: String,
    pub evidence: Vec<String>,
    pub created_by: Option<String>,
}

pub fn append_memory_candidate(root: &Path, input: MemoryCandidateInput) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let memory_dir = root.join(".harvis/memory");
    let signals_dir = memory_dir.join("signals");
    fs::create_dir_all(&signals_dir)?;
    let path = signals_dir.join("workbench-candidates.jsonl");
    let source_type = safe_memory_text(&input.source_type, 80);
    let source_id = safe_memory_text(&input.source_id, 160);
    let summary = safe_memory_text(&input.summary, 1000);
    if source_type.is_empty() || source_id.is_empty() || summary.is_empty() {
        bail!("source_type, source_id, and summary are required");
    }
    let candidate_id = format!(
        "workbench_{}_{}",
        timestamp_slug(&now_rfc3339()?),
        sanitize_candidate_name(&format!("{source_type}_{source_id}"))
    );
    let candidate = json!({
        "candidate_id": candidate_id,
        "kind": "memory_candidate",
        "source_type": source_type,
        "source_id": source_id,
        "status": "candidate",
        "requires_review": true,
        "summary": summary,
        "evidence": input
            .evidence
            .into_iter()
            .map(|item| safe_memory_warning(&item, &root))
            .take(12)
            .collect::<Vec<_>>(),
        "created_by": input.created_by.unwrap_or_else(|| "harvis-workbench".to_string()),
        "created_at": now_rfc3339()?,
        "adoption": {
            "status": "not_adopted",
            "requires_human_review": true
        },
        "safety": {
            "candidate_only": true,
            "includes_secrets": false,
            "raw_memory_store": false
        }
    });
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    use std::io::Write;
    writeln!(file, "{}", serde_json::to_string(&candidate)?)?;
    refresh_workbench_candidate_index(&root, &path)?;
    Ok(candidate)
}

pub fn generate_snapshot(options: MemorySnapshotOptions) -> Result<MemorySnapshotResult> {
    let root = resolve_workspace_root(&options.root)?;
    let harvis_dir = root.join(".harvis");
    if !harvis_dir.starts_with(&root) {
        bail!(
            "refusing to write outside workspace root: {}",
            harvis_dir.display()
        );
    }

    let mut warnings = Vec::new();
    let moment = now_rfc3339()?;
    let slug = timestamp_slug(&moment);
    let snapshot_id = format!("snapshot-{slug}");
    let memory_dir = harvis_dir.join("memory");
    let snapshots_dir = memory_dir.join("snapshots");
    let signals_dir = memory_dir.join("signals");
    fs::create_dir_all(&snapshots_dir)?;
    fs::create_dir_all(&signals_dir)?;

    let runtime_status = read_json(&harvis_dir.join("status.json"), &mut warnings);
    let recent_events = read_recent_events(
        &harvis_dir.join("events.jsonl"),
        options.max_events,
        &mut warnings,
    );
    let packets = packet_entries(
        &harvis_dir.join("outbox"),
        &root,
        options.max_packets,
        options.max_excerpt_chars,
        &mut warnings,
    )?;
    let reports = report_entries(
        &harvis_dir.join("reports"),
        &root,
        options.max_reports,
        options.max_excerpt_chars,
        &mut warnings,
    )?;
    let knowledge_sources = knowledge_source_snapshot();

    let packet_status_counts = packet_status_counts(&packets);
    let profile = profile_metadata(&options.profile_root);
    let mut snapshot = json!({
        "snapshot_version": SNAPSHOT_VERSION,
        "snapshot_id": snapshot_id,
        "generated_at": moment,
        "workspace_root": root.display().to_string(),
        "runtime_status": runtime_status,
        "recent_events": recent_events,
        "packets": packets,
        "packet_status_counts": packet_status_counts,
        "reports": reports,
        "knowledge_sources": knowledge_sources,
        "profile": profile,
        "warnings": warnings,
        "adoption": {
            "status": "not_adopted",
            "requires_human_review": true
        }
    });
    let signals = distill_signals(&snapshot);
    snapshot["candidate_signal_count"] = json!(signals.len());

    let snapshot_path = snapshots_dir.join(format!("{snapshot_id}.json"));
    let signals_path = signals_dir.join(format!("signals-{slug}.md"));
    let index_path = memory_dir.join("index.json");
    fs::write(
        &snapshot_path,
        serde_json::to_string_pretty(&snapshot)? + "\n",
    )?;
    write_signals_markdown(&signals_path, &snapshot, &signals)?;
    let knowledge_source_count = snapshot["knowledge_sources"]["sources"]
        .as_array()
        .map(Vec::len)
        .unwrap_or(0);
    let index = json!({
        "snapshot_version": SNAPSHOT_VERSION,
        "latest_snapshot": rel(&snapshot_path, &root),
        "latest_signals": rel(&signals_path, &root),
        "latest_generated_at": snapshot["generated_at"],
        "packet_status_counts": snapshot["packet_status_counts"],
        "candidate_signal_count": signals.len(),
        "knowledge_source_count": knowledge_source_count,
        "warnings": snapshot["warnings"],
    });
    fs::write(&index_path, serde_json::to_string_pretty(&index)? + "\n")?;

    let warnings = snapshot["warnings"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default();
    Ok(MemorySnapshotResult {
        workspace_root: root.display().to_string(),
        snapshot_path: snapshot_path.display().to_string(),
        signals_path: signals_path.display().to_string(),
        index_path: index_path.display().to_string(),
        packet_status_counts: serde_json::from_value(snapshot["packet_status_counts"].clone())?,
        candidate_signal_count: signals.len(),
        knowledge_source_count,
        warnings,
    })
}

pub fn list_memory_candidates(root: &Path, limit: usize) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let memory_dir = root.join(".harvis/memory");
    let index_path = memory_dir.join("index.json");
    if !index_path.exists() {
        return Ok(json!({
            "workspace": {"label": workspace_label(&root)},
            "memory_index": {
                "exists": false,
                "latest_generated_at": null,
                "latest_signals": null,
                "candidate_signal_count": 0,
                "warnings": ["memory snapshot has not been generated"]
            },
            "candidate_count": 0,
            "candidates": []
        }));
    }
    let index = match fs::read_to_string(&index_path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(Value::is_object)
    {
        Some(index) => index,
        None => {
            return Ok(json!({
                "workspace": {"label": workspace_label(&root)},
                "memory_index": {
                    "exists": true,
                    "latest_generated_at": null,
                    "latest_signals": null,
                    "candidate_signal_count": 0,
                    "warnings": ["could not read memory index"]
                },
                "candidate_count": 0,
                "candidates": []
            }));
        }
    };
    let mut warnings = Vec::new();
    let latest_signals = index.get("latest_signals").and_then(Value::as_str);
    let mut candidates = if let Some(relative) =
        latest_signals.filter(|value| !value.trim().is_empty())
    {
        let signal_path = root
            .join(relative)
            .canonicalize()
            .unwrap_or_else(|_| root.join(relative));
        if signal_path.starts_with(&root) && signal_path.exists() {
            parse_signal_markdown(
                &fs::read_to_string(&signal_path)?,
                limit.max(1).min(500),
                Some(&root),
            )
        } else {
            warnings.push("latest signal report is missing or outside workspace".to_string());
            Vec::new()
        }
    } else {
        if index
            .get("candidate_signal_count")
            .and_then(Value::as_u64)
            .unwrap_or(0)
            > 0
        {
            warnings
                .push("memory index has candidate count but no latest signal report".to_string());
        }
        Vec::new()
    };
    candidates.extend(read_workbench_candidates(
        &root,
        limit.saturating_sub(candidates.len()),
    )?);
    candidates.truncate(limit);
    if let Some(items) = index.get("warnings").and_then(Value::as_array) {
        warnings.extend(
            items
                .iter()
                .filter_map(Value::as_str)
                .take(10)
                .map(|item| safe_memory_warning(item, &root)),
        );
    }
    Ok(json!({
        "workspace": {"label": workspace_label(&root)},
        "memory_index": {
            "exists": true,
            "latest_generated_at": index.get("latest_generated_at").cloned().unwrap_or(Value::Null),
            "latest_signals": latest_signals.map(Value::from).unwrap_or(Value::Null),
            "candidate_signal_count": index.get("candidate_signal_count").cloned().unwrap_or_else(|| json!(candidates.len())),
            "packet_status_counts": index.get("packet_status_counts").cloned().unwrap_or_else(|| json!({})),
            "knowledge_source_count": index.get("knowledge_source_count").cloned().unwrap_or_else(|| json!(0)),
            "warnings": warnings
        },
        "candidate_count": candidates.len(),
        "candidates": candidates
    }))
}

fn packet_entries(
    outbox_dir: &Path,
    root: &Path,
    limit: usize,
    max_excerpt_chars: usize,
    warnings: &mut Vec<String>,
) -> Result<Vec<Value>> {
    if !outbox_dir.exists() {
        warnings.push(format!("missing outbox: {}", outbox_dir.display()));
        return Ok(Vec::new());
    }
    let mut paths = md_paths_by_mtime_desc(outbox_dir)?;
    paths.truncate(limit);
    paths
        .iter()
        .map(|path| packet_metadata(path, root, max_excerpt_chars))
        .collect()
}

fn report_entries(
    reports_dir: &Path,
    root: &Path,
    limit: usize,
    max_excerpt_chars: usize,
    warnings: &mut Vec<String>,
) -> Result<Vec<Value>> {
    if !reports_dir.exists() {
        warnings.push(format!("missing reports: {}", reports_dir.display()));
        return Ok(Vec::new());
    }
    let mut paths = md_paths_by_mtime_desc(reports_dir)?;
    paths.truncate(limit);
    paths
        .iter()
        .map(|path| report_metadata(path, root, max_excerpt_chars))
        .collect()
}

fn packet_metadata(path: &Path, root: &Path, max_excerpt_chars: usize) -> Result<Value> {
    let text = fs::read_to_string(path)?;
    let (excerpt, found_sensitive) = redacted_excerpt(&text, max_excerpt_chars);
    Ok(json!({
        "path": rel(path, root),
        "bytes": path.metadata()?.len(),
        "modified_at": modified_secs(path),
        "status": parse_status_line(&text),
        "source": parse_prefixed_line(&text, "Source:"),
        "safety": parse_prefixed_line(&text, "Safety:"),
        "sensitive_marker_detected": found_sensitive || sensitive_detected(&text),
        "excerpt": excerpt
    }))
}

fn report_metadata(path: &Path, root: &Path, max_excerpt_chars: usize) -> Result<Value> {
    let text = fs::read_to_string(path)?;
    let (excerpt, found_sensitive) = redacted_excerpt(&text, max_excerpt_chars);
    Ok(json!({
        "path": rel(path, root),
        "bytes": path.metadata()?.len(),
        "modified_at": modified_secs(path),
        "status": parse_prefixed_line(&text, "Status:"),
        "sensitive_marker_detected": found_sensitive || sensitive_detected(&text),
        "excerpt": excerpt
    }))
}

fn read_json(path: &Path, warnings: &mut Vec<String>) -> Value {
    if !path.exists() {
        warnings.push(format!("missing json file: {}", path.display()));
        return Value::Null;
    }
    match fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(Value::is_object)
    {
        Some(value) => value,
        None => {
            warnings.push(format!("could not read json file: {}", path.display()));
            Value::Null
        }
    }
}

fn read_recent_events(path: &Path, max_events: usize, warnings: &mut Vec<String>) -> Vec<Value> {
    if max_events == 0 {
        return Vec::new();
    }
    if !path.exists() {
        warnings.push(format!("missing event log: {}", path.display()));
        return Vec::new();
    }
    let rows = fs::read_to_string(path).unwrap_or_default();
    rows.lines()
        .rev()
        .take(max_events)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .filter_map(|line| {
            if line.trim().is_empty() {
                return None;
            }
            match serde_json::from_str::<Value>(line) {
                Ok(value) if value.is_object() => Some(value),
                _ => {
                    warnings.push(format!(
                        "skipped invalid event log line in {}",
                        path.display()
                    ));
                    None
                }
            }
        })
        .collect()
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
    json!({
        "root": resolved.display().to_string(),
        "exists": resolved.exists(),
        "files": files,
        "missing": missing
    })
}

fn knowledge_source_snapshot() -> Value {
    json!({
        "redacted": true,
        "includesLocalAbsolutePaths": false,
        "hub": {
            "state": "unavailable",
            "generated_at": null,
            "summary": {}
        },
        "sources": [
            {
                "source_id": "llmwiki.local_project",
                "registered": false,
                "discovery": "harzvahub-only",
                "direct_full_repo_scan": false,
                "allowlist_required_for_content": true,
                "wiki_available": false,
                "wiki_matches": 0,
                "lookup_count": 0
            }
        ],
        "provenance": [
            {
                "source_id": "llmwiki.local_project",
                "kind": "harzvahub-wiki-search",
                "query": "llmwiki",
                "items": []
            }
        ]
    })
}

fn distill_signals(snapshot: &Value) -> Vec<Value> {
    let mut signals = Vec::new();
    let packets = snapshot["packets"].as_array().cloned().unwrap_or_default();
    let packet_counts = snapshot["packet_status_counts"].clone();
    let warnings = snapshot["warnings"].as_array().cloned().unwrap_or_default();
    let profile_missing = snapshot["profile"]["missing"]
        .as_array()
        .cloned()
        .unwrap_or_default();

    if packets.is_empty() {
        signals.push(candidate_signal(
            "no_work_packets_observed",
            "No H.A.R.V.I.S. work packets were present during this snapshot.",
            vec!["packets=0".to_string()],
        ));
    } else {
        signals.push(candidate_signal(
            "work_intake_active",
            &format!("H.A.R.V.I.S. has {} tracked work packet(s).", packets.len()),
            vec![format!("packet_status_counts={packet_counts}")],
        ));
    }
    let blocked = packet_counts
        .get("blocked")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if blocked > 0 {
        signals.push(candidate_signal(
            "blocked_packet_needs_review",
            &format!("{blocked} blocked packet(s) need human review before execution."),
            vec!["blocked packet status present".to_string()],
        ));
    }
    let sensitive_packets: Vec<String> = packets
        .iter()
        .filter(|packet| {
            packet["sensitive_marker_detected"]
                .as_bool()
                .unwrap_or(false)
        })
        .filter_map(|packet| packet["path"].as_str().map(ToOwned::to_owned))
        .collect();
    if !sensitive_packets.is_empty() {
        signals.push(candidate_signal(
            "sensitive_marker_seen",
            "Sensitive-looking packet content was detected and should stay private.",
            sensitive_packets,
        ));
    }
    if let Some(errors) = snapshot["runtime_status"]["errors"]
        .as_array()
        .filter(|errors| !errors.is_empty())
    {
        signals.push(candidate_signal(
            "runtime_warnings_present",
            "The latest runtime status contains warnings or errors.",
            errors.iter().map(ToString::to_string).collect(),
        ));
    }
    if !profile_missing.is_empty() {
        signals.push(candidate_signal(
            "profile_incomplete",
            "The H.A.R.V.I.S. profile is missing required files.",
            profile_missing.iter().map(ToString::to_string).collect(),
        ));
    }
    for source in snapshot["knowledge_sources"]["sources"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if source["registered"].as_bool().unwrap_or(false) {
            let source_id = source["source_id"].as_str().unwrap_or("unknown");
            signals.push(candidate_signal(
                "knowledge_source_registered",
                &format!("{source_id} is visible as a redacted H.A.R.V.I.S. knowledge source."),
                vec![
                    format!("discovery={}", source["discovery"]),
                    format!("wiki_matches={}", source["wiki_matches"]),
                    format!("direct_full_repo_scan={}", source["direct_full_repo_scan"]),
                ],
            ));
        }
    }
    if !warnings.is_empty() {
        signals.push(candidate_signal(
            "snapshot_warnings_present",
            "The snapshot completed with operational warnings.",
            warnings.iter().map(ToString::to_string).collect(),
        ));
    }
    signals
}

fn candidate_signal(name: &str, summary: &str, evidence: Vec<String>) -> Value {
    json!({
        "name": name,
        "status": "candidate",
        "requires_review": true,
        "summary": summary,
        "evidence": evidence
    })
}

fn read_workbench_candidates(root: &Path, limit: usize) -> Result<Vec<Value>> {
    if limit == 0 {
        return Ok(Vec::new());
    }
    let path = root.join(".harvis/memory/signals/workbench-candidates.jsonl");
    if !path.exists() {
        return Ok(Vec::new());
    }
    let text = fs::read_to_string(path)?;
    Ok(text
        .lines()
        .rev()
        .take(limit)
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .collect())
}

fn refresh_workbench_candidate_index(root: &Path, candidates_path: &Path) -> Result<()> {
    let memory_dir = root.join(".harvis/memory");
    let index_path = memory_dir.join("index.json");
    let mut index = fs::read_to_string(&index_path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| {
            json!({
                "snapshot_version": SNAPSHOT_VERSION,
                "latest_snapshot": null,
                "latest_signals": null,
                "latest_generated_at": null,
                "packet_status_counts": {},
                "candidate_signal_count": 0,
                "knowledge_source_count": 0,
                "warnings": []
            })
        });
    let count = fs::read_to_string(candidates_path)
        .map(|text| text.lines().filter(|line| !line.trim().is_empty()).count())
        .unwrap_or(0);
    index["workbench_candidates"] = json!({
        "path": rel(candidates_path, root),
        "candidate_count": count,
        "updated_at": now_rfc3339()?,
        "policy": "candidate_only_review_required"
    });
    fs::write(index_path, serde_json::to_string_pretty(&index)? + "\n")?;
    Ok(())
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct MemoryCandidateReviewSync {
    pub candidate_count: usize,
    pub pending_review_count: usize,
    pub items_created: Vec<String>,
    pub reviews_written_back: Vec<String>,
    pub memories_committed: Vec<String>,
    pub latest_review_at: Option<String>,
    pub warnings: Vec<String>,
}

/// One raw workbench-candidates.jsonl line: parsed object when valid, raw text
/// kept either way so writeback rewrites never silently drop unparsable lines.
struct CandidateLine {
    raw: String,
    value: Option<Value>,
}

/// T307: fold workbench memory candidates into the human review queue.
///
/// One pass is idempotent in both directions:
///   1. every candidate without a `review` record and without an existing
///      kind=memory_candidate_review approval item gets one (dedup is by
///      candidate_id across ALL item statuses);
///   2. a candidate whose review item has been decided gets the decision
///      written back onto its JSONL `review` field (verdict, time,
///      approval_id) — approved/denied/cancelled map to approve/reject/defer;
///   3. memory/index.json is refreshed: candidate_signal_count (total
///      candidates), pending_review_count (candidates still without a review
///      record), latest_review_at, plus the nested workbench_candidates block.
///
/// Trigger points: every runtime tick (tick.rs) and the approval decision
/// path for memory_candidate_review items (approvals::decide_approval), so
/// both CLI decisions and manual approval-file edits are reconciled.
/// latest_snapshot/latest_signals stay untouched (null): distillation into
/// persona/memory keeps the existing review gate and is out of scope here.
///
/// NOTE: digital_me/scripts/import_workbench_candidates.py mirrors this
/// function in stdlib Python for the one-shot backlog import; keep the item
/// format, dedup rule, and index fields in sync when changing either side.
pub fn sync_memory_candidate_reviews(root: &Path) -> Result<MemoryCandidateReviewSync> {
    let root = resolve_workspace_root(root)?;
    let memory_dir = root.join(".harvis/memory");
    let signals_dir = memory_dir.join("signals");
    fs::create_dir_all(&signals_dir)?;
    let candidates_path = signals_dir.join("workbench-candidates.jsonl");
    let mut outcome = MemoryCandidateReviewSync::default();

    let mut lines: Vec<CandidateLine> = match fs::read_to_string(&candidates_path) {
        Ok(text) => text
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                let value = serde_json::from_str::<Value>(line)
                    .ok()
                    .filter(Value::is_object);
                if value.is_none() {
                    outcome.warnings.push(
                        "skipped invalid candidate line in workbench-candidates.jsonl".to_string(),
                    );
                }
                CandidateLine {
                    raw: line.to_string(),
                    value,
                }
            })
            .collect(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("could not read {}", candidates_path.display()))
        }
    };

    // Existing review items keyed by candidate_id (any status — a decided item
    // must not be recreated, only written back).
    let mut items_by_candidate: HashMap<String, Value> = HashMap::new();
    for item in crate::approvals::memory_candidate_review_items(&root)? {
        if let Some(candidate_id) = item.get("candidate_id").and_then(Value::as_str) {
            items_by_candidate
                .entry(candidate_id.to_string())
                .or_insert(item);
        }
    }

    // Phase 1: create review items for unreviewed candidates.
    for line in &lines {
        let Some(candidate) = line.value.as_ref() else {
            continue;
        };
        let Some(candidate_id) = candidate.get("candidate_id").and_then(Value::as_str) else {
            outcome
                .warnings
                .push("candidate line without candidate_id skipped".to_string());
            continue;
        };
        if candidate.get("review").is_some() || items_by_candidate.contains_key(candidate_id) {
            continue;
        }
        match crate::approvals::create_memory_candidate_review(&root, candidate) {
            Ok(Some(item)) => {
                if let Some(approval_id) = item.get("approval_id").and_then(Value::as_str) {
                    outcome.items_created.push(approval_id.to_string());
                }
                items_by_candidate.insert(candidate_id.to_string(), item);
            }
            Ok(None) => {}
            Err(error) => outcome.warnings.push(format!(
                "could not create review item for {candidate_id}: {error}"
            )),
        }
    }

    // Phase 2: write decided reviews back onto candidate lines.
    let mut changed = false;
    for line in &mut lines {
        let Some(candidate) = line.value.as_mut() else {
            continue;
        };
        if candidate.get("review").is_some() {
            continue;
        }
        let Some(candidate_id) = candidate
            .get("candidate_id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
        else {
            continue;
        };
        let Some(item) = items_by_candidate.get(&candidate_id) else {
            continue;
        };
        let Some(status) = item.get("status").and_then(Value::as_str) else {
            continue;
        };
        if status == "pending" {
            continue;
        }
        let decision = item.get("decision").filter(|value| value.is_object());
        let reviewed_at = decision
            .and_then(|value| value.get("at").and_then(Value::as_str))
            .or_else(|| item.get("updated_at").and_then(Value::as_str))
            .unwrap_or_default()
            .to_string();
        let verdict = match status {
            "approved" => "approve",
            "denied" => "reject",
            "cancelled" => "defer",
            other => other,
        };
        candidate["review"] = json!({
            "decision": verdict,
            "approval_decision": status,
            "approval_id": item.get("approval_id").cloned().unwrap_or(Value::Null),
            "reviewed_at": reviewed_at,
            "reviewer": decision
                .and_then(|value| value.get("by").cloned())
                .unwrap_or(Value::Null),
            "notes": decision
                .and_then(|value| value.get("notes").cloned())
                .unwrap_or(Value::Null)
        });
        outcome.reviews_written_back.push(candidate_id.to_string());
        changed = true;
    }

    // Phase 2b: an approved review is reconciled into the canonical accepted
    // store and committed once to the offline provider. Missing commit markers
    // are retried on later ticks with the same stable idempotency key.
    for line in &mut lines {
        let Some(candidate) = line.value.as_mut() else {
            continue;
        };
        if candidate["review"]["decision"].as_str() != Some("approve")
            || candidate["review"]["memory_commit"]["status"].as_str() == Some("committed")
        {
            continue;
        }
        match commit_reviewed_workbench_candidate(&root, candidate) {
            Ok(result) => {
                candidate["review"]["memory_commit"] = json!({
                    "status": "committed",
                    "provider_id": result.provider_id,
                    "commit_id": result.commit_id,
                    "external_id": result.external_id,
                    "committed_at": now_rfc3339()?
                });
                if let Some(candidate_id) = candidate.get("candidate_id").and_then(Value::as_str) {
                    outcome.memories_committed.push(candidate_id.to_string());
                }
                changed = true;
            }
            Err(error) => {
                let candidate_id = candidate
                    .get("candidate_id")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                outcome.warnings.push(format!(
                    "could not commit approved memory candidate {candidate_id}: {error}"
                ));
            }
        }
    }
    if changed {
        let mut serialized = Vec::new();
        for line in &lines {
            match line.value.as_ref() {
                Some(value) => serialized.push(serde_json::to_string(value)?),
                None => serialized.push(line.raw.clone()),
            }
        }
        fs::write(&candidates_path, serialized.join("\n") + "\n")?;
    }

    // Phase 3: refresh memory/index.json, preserving untouched fields such as
    // latest_snapshot/latest_signals (they stay null under T307).
    let candidates: Vec<&Value> = lines
        .iter()
        .filter_map(|line| line.value.as_ref())
        .collect();
    let total = candidates.len();
    let pending = candidates
        .iter()
        .filter(|candidate| candidate.get("review").is_none())
        .count();
    // RFC3339 UTC timestamps from now_rfc3339 share one format, so the latest
    // review marker is the lexicographic max.
    let latest_review_at = candidates
        .iter()
        .filter_map(|candidate| {
            candidate
                .get("review")?
                .get("reviewed_at")
                .and_then(Value::as_str)
        })
        .filter(|value| !value.is_empty())
        .max()
        .map(ToOwned::to_owned);
    let committed_memory_count = candidates
        .iter()
        .filter(|candidate| {
            candidate["review"]["memory_commit"]["status"].as_str() == Some("committed")
        })
        .count();
    let index_path = memory_dir.join("index.json");
    let mut index = fs::read_to_string(&index_path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| {
            json!({
                "snapshot_version": SNAPSHOT_VERSION,
                "latest_snapshot": null,
                "latest_signals": null,
                "latest_generated_at": null,
                "packet_status_counts": {},
                "knowledge_source_count": 0,
                "warnings": []
            })
        });
    index["candidate_signal_count"] = json!(total);
    index["pending_review_count"] = json!(pending);
    index["committed_memory_count"] = json!(committed_memory_count);
    index["latest_review_at"] = latest_review_at
        .clone()
        .map(Value::from)
        .unwrap_or(Value::Null);
    index["workbench_candidates"] = json!({
        "path": rel(&candidates_path, &root),
        "candidate_count": total,
        "updated_at": now_rfc3339()?,
        "policy": "candidate_only_review_required"
    });
    fs::write(&index_path, serde_json::to_string_pretty(&index)? + "\n")?;

    outcome.candidate_count = total;
    outcome.pending_review_count = pending;
    outcome.latest_review_at = latest_review_at;
    outcome.items_created.sort();
    outcome.memories_committed.sort();
    outcome.reviews_written_back.sort();
    Ok(outcome)
}

fn write_signals_markdown(path: &Path, snapshot: &Value, signals: &[Value]) -> Result<()> {
    let mut lines = vec![
        "# H.A.R.V.I.S. Candidate Digital-Me Signals".to_string(),
        String::new(),
        format!(
            "Snapshot: {}",
            snapshot["snapshot_id"].as_str().unwrap_or_default()
        ),
        format!(
            "Generated: {}",
            snapshot["generated_at"].as_str().unwrap_or_default()
        ),
        "Status: candidate".to_string(),
        "Adoption: not adopted; human review required".to_string(),
        String::new(),
        "Summary:".to_string(),
        format!(
            "- Workspace: {}",
            snapshot["workspace_root"].as_str().unwrap_or_default()
        ),
        format!(
            "- Packets: {}",
            snapshot["packets"].as_array().map(Vec::len).unwrap_or(0)
        ),
        format!(
            "- Events: {}",
            snapshot["recent_events"]
                .as_array()
                .map(Vec::len)
                .unwrap_or(0)
        ),
        format!(
            "- Reports: {}",
            snapshot["reports"].as_array().map(Vec::len).unwrap_or(0)
        ),
        format!(
            "- Knowledge sources: {}",
            snapshot["knowledge_sources"]["sources"]
                .as_array()
                .map(Vec::len)
                .unwrap_or(0)
        ),
        String::new(),
        "Candidate Signals:".to_string(),
    ];
    if signals.is_empty() {
        lines.push("- none".to_string());
    }
    for signal in signals {
        lines.push(format!(
            "- {}: {}",
            signal["name"].as_str().unwrap_or("signal"),
            signal["summary"].as_str().unwrap_or_default()
        ));
        lines.push("  Review: required".to_string());
        for evidence in signal["evidence"].as_array().into_iter().flatten().take(5) {
            let (safe, _) = redacted_excerpt(&evidence.to_string(), 240);
            lines.push(format!("  Evidence: {safe}"));
        }
    }
    lines.extend([
        String::new(),
        "Boundaries:".to_string(),
        "- This file is a candidate signal report, not an adopted memory.".to_string(),
        "- Do not copy raw private packet bodies into public artifacts.".to_string(),
        "- Human review is required before any long-term memory update.".to_string(),
        String::new(),
    ]);
    fs::write(path, lines.join("\n"))?;
    Ok(())
}

fn parse_signal_markdown(text: &str, limit: usize, root: Option<&Path>) -> Vec<Value> {
    let mut candidates = Vec::new();
    let mut current: Option<HashMap<String, Value>> = None;
    let mut in_signals = false;
    for line in text.lines() {
        let stripped = line.trim();
        if stripped == "Candidate Signals:" {
            in_signals = true;
            continue;
        }
        if stripped == "Boundaries:" {
            break;
        }
        if !in_signals {
            continue;
        }
        if stripped.starts_with("- ") && stripped.contains(": ") {
            if let Some(current) = current.take() {
                candidates.push(Value::Object(current.into_iter().collect()));
                if candidates.len() >= limit {
                    return candidates;
                }
            }
            let body = &stripped[2..];
            let (name, summary) = body.split_once(": ").unwrap_or((body, ""));
            let clean_name = sanitize_candidate_name(name);
            current = Some(HashMap::from([
                (
                    "candidate_id".to_string(),
                    json!(format!("memory_{}_{}", candidates.len() + 1, clean_name)),
                ),
                ("kind".to_string(), json!("memory_candidate")),
                ("name".to_string(), json!(name.trim())),
                ("summary".to_string(), json!(summary.trim())),
                ("status".to_string(), json!("candidate")),
                ("requires_review".to_string(), json!(true)),
                ("evidence".to_string(), json!([])),
            ]));
            continue;
        }
        if let Some(current) = current.as_mut() {
            if let Some(evidence) = stripped.strip_prefix("Evidence: ") {
                let evidence = root
                    .map(|root| safe_memory_warning(evidence, root))
                    .unwrap_or_else(|| evidence.to_string());
                current
                    .get_mut("evidence")
                    .and_then(Value::as_array_mut)
                    .expect("evidence array")
                    .push(json!(evidence));
            }
        }
    }
    if let Some(current) = current {
        candidates.push(Value::Object(current.into_iter().collect()));
    }
    candidates.truncate(limit);
    candidates
}

fn sanitize_candidate_name(name: &str) -> String {
    let clean = name
        .chars()
        .map(|character| {
            if character.is_alphanumeric() {
                character.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .chars()
        .take(48)
        .collect::<String>();
    if clean.is_empty() {
        "memory-signal".to_string()
    } else {
        clean
    }
}

fn safe_memory_text(value: &str, max_chars: usize) -> String {
    value
        .trim()
        .chars()
        .filter(|character| !character.is_control() || matches!(character, '\n' | '\t'))
        .take(max_chars)
        .collect::<String>()
}

fn safe_memory_warning(value: &str, root: &Path) -> String {
    let mut warning = value.to_string();
    let root_text = root
        .canonicalize()
        .unwrap_or_else(|_| root.to_path_buf())
        .display()
        .to_string();
    if !root_text.is_empty() {
        warning = warning.replace(&root_text, "<workspace>");
    }
    if warning.contains("/Users/") || warning.contains("/Volumes/") {
        return "redacted local path warning".to_string();
    }
    warning.chars().take(240).collect()
}

fn redacted_excerpt(text: &str, max_chars: usize) -> (String, bool) {
    let mut found_sensitive = false;
    let mut lines = Vec::new();
    for line in text.lines() {
        if sensitive_detected(line) {
            found_sensitive = true;
            lines.push("[redacted sensitive-looking line]".to_string());
        } else {
            lines.push(line.to_string());
        }
    }
    let mut excerpt = lines.join("\n").trim().to_string();
    if excerpt.len() > max_chars {
        excerpt = excerpt
            .chars()
            .take(max_chars)
            .collect::<String>()
            .trim_end()
            .to_string();
        excerpt.push_str("\n[truncated]");
    }
    (excerpt, found_sensitive)
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
        .map(|pattern| Regex::new(&format!("(?i){pattern}")).expect("valid sensitive regex"))
        .collect()
    })
}

fn parse_status_line(text: &str) -> String {
    parse_prefixed_line(text, "Status:").unwrap_or_else(|| "unknown".to_string())
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

fn packet_status_counts(packets: &[Value]) -> BTreeMap<String, usize> {
    let mut counts = BTreeMap::new();
    for packet in packets {
        let status = packet["status"].as_str().unwrap_or("unknown").to_string();
        *counts.entry(status).or_insert(0) += 1;
    }
    counts
}

fn md_paths_by_mtime_desc(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(dir)? {
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

fn workspace_label(root: &Path) -> String {
    root.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("workspace")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::approvals::{decide_approval, memory_candidate_review_items};
    use crate::init::init_workspace;
    use crate::profile::init_profile;
    use crate::tick::{run_tick, TickOptions};

    fn fake_candidate(candidate_id: &str, summary: &str) -> Value {
        json!({
            "candidate_id": candidate_id,
            "kind": "memory_candidate",
            "source_type": "task_done",
            "source_id": format!("source_{candidate_id}"),
            "status": "candidate",
            "requires_review": true,
            "summary": summary,
            "evidence": ["fixture evidence"],
            "created_by": "t307-unit-test",
            "created_at": "2026-07-18T00:00:00.000000Z"
        })
    }

    fn write_candidates(root: &Path, candidates: &[Value]) {
        let signals_dir = root.join(".harvis/memory/signals");
        fs::create_dir_all(&signals_dir).expect("signals dir");
        let text = candidates
            .iter()
            .map(serde_json::to_string)
            .collect::<Result<Vec<_>, _>>()
            .expect("serialize")
            .join("\n");
        fs::write(signals_dir.join("workbench-candidates.jsonl"), text + "\n")
            .expect("write candidates");
    }

    fn read_candidates(root: &Path) -> Vec<Value> {
        let text =
            fs::read_to_string(root.join(".harvis/memory/signals/workbench-candidates.jsonl"))
                .expect("read candidates");
        text.lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| serde_json::from_str::<Value>(line).expect("candidate json"))
            .collect()
    }

    fn read_index(root: &Path) -> Value {
        serde_json::from_str(
            &fs::read_to_string(root.join(".harvis/memory/index.json")).expect("read index"),
        )
        .expect("index json")
    }

    #[test]
    fn sync_creates_deduped_review_items_and_updates_index() {
        let root = std::env::temp_dir().join(format!(
            "harvis-candidate-sync-rust-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init workspace");
        write_candidates(
            &root,
            &[
                fake_candidate("workbench_20260718T000000Z_fake-t307-alpha", "alpha"),
                fake_candidate("workbench_20260718T000001Z_fake-t307-beta", "beta"),
            ],
        );

        let first = sync_memory_candidate_reviews(&root).expect("first sync");
        assert_eq!(first.items_created.len(), 2);
        assert_eq!(first.candidate_count, 2);
        assert_eq!(first.pending_review_count, 2);
        assert_eq!(first.latest_review_at, None);
        let items = memory_candidate_review_items(&root).expect("items");
        assert_eq!(items.len(), 2);
        for item in &items {
            assert_eq!(item["status"], "pending");
            let approval_id = item["approval_id"].as_str().expect("approval id");
            assert!(root
                .join(".harvis/approvals")
                .join(format!("{approval_id}.md"))
                .exists());
        }
        let index = read_index(&root);
        assert_eq!(index["candidate_signal_count"], 2);
        assert_eq!(index["pending_review_count"], 2);
        assert_eq!(index["latest_review_at"], Value::Null);
        assert_eq!(index["latest_snapshot"], Value::Null);
        assert_eq!(index["latest_signals"], Value::Null);
        assert_eq!(index["workbench_candidates"]["candidate_count"], 2);

        // Re-sync must not duplicate items for candidates already pending.
        let second = sync_memory_candidate_reviews(&root).expect("second sync");
        assert!(second.items_created.is_empty());
        assert_eq!(second.pending_review_count, 2);
        assert_eq!(
            memory_candidate_review_items(&root).expect("items").len(),
            2
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn decided_review_writes_back_and_decrements_pending() {
        let root = std::env::temp_dir().join(format!(
            "harvis-candidate-writeback-rust-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init workspace");
        write_candidates(
            &root,
            &[
                fake_candidate("workbench_20260718T000000Z_fake-t307-alpha", "alpha"),
                fake_candidate("workbench_20260718T000001Z_fake-t307-beta", "beta"),
            ],
        );
        sync_memory_candidate_reviews(&root).expect("sync");
        let items = memory_candidate_review_items(&root).expect("items");
        let target = items
            .iter()
            .find(|item| item["candidate_id"] == "workbench_20260718T000000Z_fake-t307-alpha")
            .expect("target item");
        let approval_id = target["approval_id"].as_str().expect("approval id");

        // decide_approval triggers the same sync on the decision path, so the
        // writeback and index refresh land immediately.
        let decided = decide_approval(&root, approval_id, "approved", "tester", "looks good")
            .expect("decide");
        assert_eq!(decided["status"], "approved");

        let candidates = read_candidates(&root);
        // The review decision must not spawn a new approval_decision candidate.
        assert_eq!(candidates.len(), 2);
        let alpha = candidates
            .iter()
            .find(|candidate| {
                candidate["candidate_id"] == "workbench_20260718T000000Z_fake-t307-alpha"
            })
            .expect("alpha");
        assert_eq!(alpha["review"]["decision"], "approve");
        assert_eq!(alpha["review"]["approval_decision"], "approved");
        assert_eq!(alpha["review"]["approval_id"], approval_id);
        assert!(alpha["review"]["reviewed_at"]
            .as_str()
            .is_some_and(|value| !value.is_empty()));
        assert_eq!(alpha["review"]["reviewer"], "tester");
        assert_eq!(alpha["review"]["memory_commit"]["status"], "committed");
        assert_eq!(
            alpha["review"]["memory_commit"]["provider_id"],
            "local-sqlite"
        );
        let beta = candidates
            .iter()
            .find(|candidate| {
                candidate["candidate_id"] == "workbench_20260718T000001Z_fake-t307-beta"
            })
            .expect("beta");
        assert!(beta.get("review").is_none());

        let index = read_index(&root);
        assert_eq!(index["candidate_signal_count"], 2);
        assert_eq!(index["pending_review_count"], 1);
        assert_eq!(index["committed_memory_count"], 1);
        assert!(index["latest_review_at"].is_string());

        // A further sync stays stable: no new items, no double writeback.
        let again = sync_memory_candidate_reviews(&root).expect("stable sync");
        assert!(again.items_created.is_empty());
        assert!(again.reviews_written_back.is_empty());
        assert!(again.memories_committed.is_empty());
        assert_eq!(again.pending_review_count, 1);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn tick_creates_review_items_for_backlogged_candidates() {
        let root = std::env::temp_dir().join(format!(
            "harvis-candidate-tick-rust-test-{}",
            std::process::id()
        ));
        let profile = std::env::temp_dir().join(format!(
            "harvis-candidate-tick-profile-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&profile);
        init_workspace(&root, false).expect("init workspace");
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis review this fixture.\n",
        )
        .expect("write inbox");
        write_candidates(
            &root,
            &[fake_candidate(
                "workbench_20260718T000000Z_fake-t307-tick",
                "tick fixture",
            )],
        );

        run_tick(TickOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            interval_override: Some(1200),
        })
        .expect("tick");

        let items = memory_candidate_review_items(&root).expect("items");
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]["candidate_id"],
            "workbench_20260718T000000Z_fake-t307-tick"
        );
        assert_eq!(items[0]["status"], "pending");
        let index = read_index(&root);
        assert_eq!(index["candidate_signal_count"], 1);
        assert_eq!(index["pending_review_count"], 1);

        // A second tick keeps the single deduped item.
        run_tick(TickOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            interval_override: Some(1200),
        })
        .expect("second tick");
        assert_eq!(
            memory_candidate_review_items(&root).expect("items").len(),
            1
        );

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(profile);
    }

    #[test]
    fn generates_snapshot_and_candidates() {
        let root =
            std::env::temp_dir().join(format!("harvis-memory-rust-test-{}", std::process::id()));
        let profile = std::env::temp_dir().join(format!(
            "harvis-memory-profile-rust-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&profile);
        init_workspace(&root, false).expect("init workspace");
        init_profile(&profile, false).expect("init profile");
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis review this fixture.\n",
        )
        .expect("write inbox");
        run_tick(TickOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            interval_override: None,
        })
        .expect("tick");
        let result = generate_snapshot(MemorySnapshotOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            max_events: 50,
            max_packets: 50,
            max_reports: 10,
            max_excerpt_chars: 1200,
        })
        .expect("snapshot");
        assert!(Path::new(&result.snapshot_path).exists());
        assert!(Path::new(&result.signals_path).exists());
        assert!(Path::new(&result.index_path).exists());
        assert!(result.candidate_signal_count > 0);
        let candidates = list_memory_candidates(&root, 50).expect("candidates");
        assert!(candidates["candidate_count"].as_u64().unwrap_or(0) > 0);
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(profile);
    }
}
