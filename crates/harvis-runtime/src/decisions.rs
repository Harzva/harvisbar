//! T310 — immutable, hash-chained Agent Room decision record snapshots
//! (ROADMAP v0.46/v0.49: a converged room must produce a reviewable decision
//! artifact; v0.48 artifact checklist: summary, open questions, decision log,
//! next action, selected harness, verification plan).
//!
//! Design borrowed from LangGraph checkpointer's immutable checkpoint /
//! append-only snapshot semantics — "snapshots are immutable + chain-verified"
//! design only, no code.
//!
//! When a room run terminates through a `decision_reached` condition match
//! (T309), this module mints exactly one snapshot:
//!
//! ```text
//! .harvis/agent-room/decisions/decision_<id>.json
//! ```
//!
//! Each snapshot carries the six v0.48 content elements (fields may be empty
//! but are always present), a `prev_hash` pointing at the content hash of the
//! previous snapshot (`"genesis"` for the first one) and its own content
//! `hash` (sha256 over the canonical serialization of the record without the
//! `hash` field), forming a hash chain. Files are written once and then made
//! read-only (mode 0444). `harvis decisions verify` re-checks every snapshot
//! and the chain linkage; any tampering, broken link, or gap is reported with
//! the offending file and a non-zero exit.

use anyhow::{bail, Context, Result};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::agent_room::{list_agent_room, list_handoffs, read_chair_decisions};
use crate::termination::build_room_snapshot;
use harvis_core::time::now_rfc3339;

pub const DECISIONS_VERSION: &str = "v0.48-decision-records";
pub const DECISION_RECORD_SCHEMA: &str = "harvis.decision-record.v1";
/// Explicit `prev_hash` marker of the first snapshot in the chain.
pub const GENESIS_PREV_HASH: &str = "genesis";
pub const DECISION_FILE_PREFIX: &str = "decision_";

/// The six ROADMAP v0.48 content elements. All keys are always present in a
/// minted snapshot; values may be empty/null when the room left no evidence.
pub const CONTENT_ELEMENTS: [&str; 6] = [
    "summary",
    "open_questions",
    "decision_log",
    "next_action",
    "selected_harness",
    "verification_plan",
];

// ---------------------------------------------------------------------------
// Minting
// ---------------------------------------------------------------------------

/// Mint one immutable decision record snapshot for a room that converged
/// (terminated through a `decision_reached` match). Returns the record as
/// written (including `prev_hash` / `hash`).
///
/// The caller (termination trigger) decides *when* this runs; this function
/// only runs for decision-reached terminations — operational stops such as
/// `max_message` / `timeout` / `budget_exhausted` / `approval_denied` produce
/// no room decision and therefore no snapshot.
pub fn record_room_decision(
    root: &Path,
    topic_id: &str,
    run: &Value,
    matched: &Value,
) -> Result<Value> {
    let root = resolve_root(root)?;
    let moment = now_rfc3339()?;
    let run_id = run
        .get("run_id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let content = build_decision_content(&root, topic_id, matched)?;
    let decision_id = stable_decision_id(topic_id, &run_id, &moment, &content);
    let prev_hash = latest_chain_tip(&root)?;
    let mut record = json!({
        "schemaVersion": DECISION_RECORD_SCHEMA,
        "version": DECISIONS_VERSION,
        "decision_id": decision_id,
        "topic_id": topic_id,
        "run_id": run_id,
        "created_at": moment,
        "trigger": {
            "source": "room_termination",
            "condition_kind": matched.get("kind").cloned().unwrap_or(Value::Null),
            "matched": matched
        },
        "content": content,
        "prev_hash": prev_hash
    });
    let hash = content_hash(&record);
    record["hash"] = json!(hash);
    write_readonly_snapshot(&root, &record)?;
    Ok(record)
}

/// Assemble the six v0.48 content elements from the live room state.
fn build_decision_content(root: &Path, topic_id: &str, matched: &Value) -> Result<Value> {
    let run = crate::termination::load_room_run(root, topic_id)?
        .unwrap_or_else(|| json!({"run_id": Value::Null}));
    let snapshot = build_room_snapshot(root, topic_id, &run)?;

    // summary: the converging decision_record event content, falling back to
    // the matched excerpt recorded by the termination condition.
    let summary = snapshot
        .decision_event
        .as_ref()
        .and_then(|event| event.get("content"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            matched
                .get("excerpt")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
        })
        .unwrap_or_default();

    // open_questions: question events still visible in the room for this
    // topic (empty array when none were recorded).
    let room = list_agent_room(root, 500)?;
    let open_questions: Vec<Value> = room
        .get("events")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|event| {
            event.get("topic_id").and_then(Value::as_str) == Some(topic_id)
                && event.get("event_kind").and_then(Value::as_str) == Some("question")
        })
        .take(20)
        .map(|event| {
            json!({
                "event_id": event.get("event_id").cloned().unwrap_or(Value::Null),
                "agent_id": event.get("agent_id").cloned().unwrap_or(Value::Null),
                "content": event.get("content").cloned().unwrap_or(Value::Null),
                "created_at": event.get("created_at").cloned().unwrap_or(Value::Null)
            })
        })
        .collect();

    // decision_log: projected chair/termination decision trail for the topic.
    let decision_log: Vec<Value> = read_chair_decisions(root, 500)
        .unwrap_or_default()
        .iter()
        .filter(|record| record.get("topic_id").and_then(Value::as_str) == Some(topic_id))
        .map(|record| {
            json!({
                "decision_id": record.get("decision_id").cloned().unwrap_or(Value::Null),
                "decision_kind": record
                    .get("decision_kind")
                    .cloned()
                    .or_else(|| record.get("selector_kind").cloned())
                    .unwrap_or(Value::Null),
                "condition_kind": record.get("condition_kind").cloned().unwrap_or(Value::Null),
                "selected_agent_id": record.get("selected_agent_id").cloned().unwrap_or(Value::Null),
                "ts": record.get("ts").cloned().unwrap_or(Value::Null)
            })
        })
        .collect();

    // selected_harness: harness of the most recent handoff tied to the topic,
    // when the converged room requested one.
    let selected_harness = list_handoffs(root, 50)
        .ok()
        .map(|listing| {
            listing
                .get("handoffs")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        })
        .unwrap_or_default()
        .into_iter()
        .find(|handoff| handoff.get("topic_id").and_then(Value::as_str) == Some(topic_id))
        .and_then(|handoff| {
            handoff
                .get("harness")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .map(Value::String)
        .unwrap_or(Value::Null);

    // next_action / verification_plan: no reliable machine source yet — the
    // keys exist (v0.48 checklist) with explicit null values.
    let mut content = Map::new();
    content.insert("summary".to_string(), json!(summary));
    content.insert("open_questions".to_string(), json!(open_questions));
    content.insert("decision_log".to_string(), json!(decision_log));
    content.insert("next_action".to_string(), Value::Null);
    content.insert("selected_harness".to_string(), selected_harness);
    content.insert("verification_plan".to_string(), Value::Null);
    Ok(Value::Object(content))
}

// ---------------------------------------------------------------------------
// Hash chain
// ---------------------------------------------------------------------------

/// sha256 (hex) over the canonical serialization of a record with the `hash`
/// field removed. serde_json maps are B-tree ordered, so `to_string` is a
/// deterministic canonical form.
pub fn content_hash(record: &Value) -> String {
    let mut canonical = record.clone();
    if let Some(map) = canonical.as_object_mut() {
        map.remove("hash");
    }
    let serialized = serde_json::to_string(&canonical).unwrap_or_default();
    hex_sha256(serialized.as_bytes())
}

fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn stable_decision_id(topic_id: &str, run_id: &str, moment: &str, content: &Value) -> String {
    let serialized = serde_json::to_string(content).unwrap_or_default();
    let digest = hex_sha256(format!("{topic_id}|{run_id}|{moment}|{serialized}").as_bytes());
    format!("{DECISION_FILE_PREFIX}{}", &digest[..12])
}

fn decisions_dir(root: &Path) -> PathBuf {
    root.join(".harvis/agent-room/decisions")
}

fn decision_path(root: &Path, decision_id: &str) -> PathBuf {
    decisions_dir(root).join(format!("{decision_id}.json"))
}

/// Stored snapshots in file-scan order (path, parsed record).
fn scan_snapshots(root: &Path) -> Result<Vec<(PathBuf, Value)>> {
    let dir = decisions_dir(root);
    let mut snapshots = Vec::new();
    if !dir.exists() {
        return Ok(snapshots);
    }
    let mut paths: Vec<PathBuf> = Vec::new();
    for entry in fs::read_dir(&dir)? {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        if name.starts_with(DECISION_FILE_PREFIX)
            && path.extension().and_then(|value| value.to_str()) == Some("json")
        {
            paths.push(path);
        }
    }
    paths.sort();
    for path in paths {
        let text = fs::read_to_string(&path)
            .with_context(|| format!("could not read {}", path.display()))?;
        let record: Value = serde_json::from_str(&text)
            .with_context(|| format!("{} is not valid JSON", path.display()))?;
        if !record.is_object() {
            bail!("{} must contain a JSON object", path.display());
        }
        snapshots.push((path, record));
    }
    Ok(snapshots)
}

/// Stored hash of the current chain tip (the record whose hash no other
/// record references as `prev_hash`), or None for an empty store.
fn latest_chain_tip(root: &Path) -> Result<Value> {
    let snapshots = scan_snapshots(root)?;
    if snapshots.is_empty() {
        return Ok(Value::String(GENESIS_PREV_HASH.to_string()));
    }
    let referenced: std::collections::BTreeSet<String> = snapshots
        .iter()
        .filter_map(|(_, record)| {
            record
                .get("prev_hash")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .collect();
    let tips: Vec<&Value> = snapshots
        .iter()
        .map(|(_, record)| record)
        .filter(|record| {
            record
                .get("hash")
                .and_then(Value::as_str)
                .is_some_and(|hash| !referenced.contains(hash))
        })
        .collect();
    match tips.len() {
        1 => Ok(tips[0].get("hash").cloned().unwrap_or(Value::Null)),
        other => bail!(
            "decision store chain tip is ambiguous ({other} unreferenced hashes); \
             run `harvis decisions verify` before minting further snapshots"
        ),
    }
}

/// Write the snapshot file once, then drop every write bit (0444). Existing
/// files are never overwritten: a colliding decision_id is an error.
fn write_readonly_snapshot(root: &Path, record: &Value) -> Result<PathBuf> {
    let decision_id = record
        .get("decision_id")
        .and_then(Value::as_str)
        .context("record requires decision_id")?;
    let dir = decisions_dir(root);
    fs::create_dir_all(&dir)?;
    let path = decision_path(root, decision_id);
    if path.exists() {
        bail!("decision snapshot already exists: {}", path.display());
    }
    fs::write(&path, serde_json::to_string_pretty(record)? + "\n")?;
    let mut permissions = fs::metadata(&path)?.permissions();
    permissions.set_readonly(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        permissions = fs::Permissions::from_mode(0o444);
    }
    fs::set_permissions(&path, permissions)?;
    Ok(path)
}

// ---------------------------------------------------------------------------
// Verification (`harvis decisions verify`)
// ---------------------------------------------------------------------------

/// Verify every snapshot under `.harvis/agent-room/decisions/`: recompute
/// each content hash and re-walk the `prev_hash` chain from genesis. The
/// returned report carries `ok`, `record_count`, the chain-ordered
/// `decision_ids` and one entry per violation (`file`, `check`, `detail`).
/// A missing/empty store verifies clean with zero records.
pub fn verify_decision_chain(root: &Path) -> Result<Value> {
    let root = resolve_root(root)?;
    let snapshots = scan_snapshots(&root)?;
    let mut errors: Vec<Value> = Vec::new();

    // -- per-record content hash ------------------------------------------
    let mut by_hash: BTreeMap<String, (&PathBuf, &Value)> = BTreeMap::new();
    for (path, record) in &snapshots {
        let file = path.display().to_string();
        let decision_id = record
            .get("decision_id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let expected_name = format!("{decision_id}.json");
        if path.file_name().and_then(|value| value.to_str()) != Some(expected_name.as_str()) {
            errors.push(json!({
                "file": file,
                "check": "file_name_matches_decision_id",
                "detail": format!("file name does not match decision_id '{decision_id}'")
            }));
        }
        let stored_hash = record
            .get("hash")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if stored_hash.is_empty() {
            errors.push(json!({
                "file": file,
                "check": "hash_field_present",
                "detail": "record has no hash field"
            }));
        } else {
            let recomputed = content_hash(record);
            if recomputed != stored_hash {
                errors.push(json!({
                    "file": file,
                    "check": "content_hash",
                    "detail": format!(
                        "content hash mismatch: stored {stored_hash}, recomputed {recomputed}"
                    )
                }));
            }
            if by_hash
                .insert(stored_hash.to_string(), (path, record))
                .is_some()
            {
                errors.push(json!({
                    "file": file,
                    "check": "hash_unique",
                    "detail": format!("duplicate content hash {stored_hash}")
                }));
            }
        }
        let content = record.get("content").and_then(Value::as_object);
        for element in CONTENT_ELEMENTS {
            if content.is_none() || content.is_some_and(|map| !map.contains_key(element)) {
                errors.push(json!({
                    "file": file,
                    "check": "content_elements",
                    "detail": format!("content is missing required element '{element}'")
                }));
            }
        }
    }

    // -- chain linkage -------------------------------------------------------
    let mut ordered_ids: Vec<String> = Vec::new();
    if !snapshots.is_empty() {
        let mut prev_index: BTreeMap<String, (&PathBuf, &Value)> = BTreeMap::new();
        let mut genesis: Option<(&PathBuf, &Value)> = None;
        for (path, record) in &snapshots {
            let file = path.display().to_string();
            let prev_hash = record
                .get("prev_hash")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if prev_hash.is_empty() {
                errors.push(json!({
                    "file": file,
                    "check": "prev_hash_present",
                    "detail": "record has no prev_hash field"
                }));
                continue;
            }
            if prev_hash == GENESIS_PREV_HASH {
                if genesis.is_some() {
                    errors.push(json!({
                        "file": file,
                        "check": "genesis_unique",
                        "detail": "more than one record claims the genesis prev_hash"
                    }));
                } else {
                    genesis = Some((path, record));
                }
            } else {
                prev_index.insert(prev_hash.to_string(), (path, record));
            }
        }
        match genesis {
            None => errors.push(json!({
                "file": Value::Null,
                "check": "genesis_present",
                "detail": format!("no record with prev_hash '{GENESIS_PREV_HASH}' found")
            })),
            Some((_, first)) => {
                let mut current = first;
                let mut visited = 0usize;
                loop {
                    visited += 1;
                    ordered_ids.push(
                        current
                            .get("decision_id")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                    );
                    let hash = current
                        .get("hash")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let Some((_, next)) = prev_index.remove(hash) else {
                        break;
                    };
                    current = next;
                    if visited > snapshots.len() {
                        errors.push(json!({
                            "file": Value::Null,
                            "check": "chain_acyclic",
                            "detail": "prev_hash chain contains a cycle"
                        }));
                        break;
                    }
                }
                // Anything left in prev_index (or a genesis sibling) was not
                // reachable from genesis: a deleted/tampered middle link.
                let unreachable = snapshots.len().saturating_sub(visited);
                if unreachable > 0 {
                    for (path, record) in &snapshots {
                        let id = record
                            .get("decision_id")
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        if ordered_ids.iter().any(|seen| seen == id) {
                            continue;
                        }
                        let prev_hash = record
                            .get("prev_hash")
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        let anchor_known = by_hash.contains_key(prev_hash);
                        errors.push(json!({
                            "file": path.display().to_string(),
                            "check": if anchor_known { "chain_reachable" } else { "prev_hash_links" },
                            "detail": if anchor_known {
                                "record is not reachable from the genesis record (chain gap)"
                                    .to_string()
                            } else {
                                format!("prev_hash {prev_hash} matches no stored record hash")
                            }
                        }));
                    }
                }
            }
        }
    }

    let ok = errors.is_empty();
    Ok(json!({
        "version": DECISIONS_VERSION,
        "schema": DECISION_RECORD_SCHEMA,
        "root": root.display().to_string(),
        "store": decisions_dir(&root).display().to_string(),
        "ok": ok,
        "record_count": snapshots.len(),
        "decision_ids": ordered_ids,
        "errors": errors
    }))
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn resolve_root(value: &Path) -> Result<PathBuf> {
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_room::add_event_with_metadata;
    use crate::init::init_workspace;
    use crate::termination::{
        evaluate_room_termination, terminate_room_run, TerminationCondition, TerminationConfig,
        KIND_DECISION_REACHED, KIND_MAX_MESSAGE,
    };

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "harvis-decisions-{tag}-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        root.canonicalize().expect("canonical root")
    }

    /// Converge one topic: record a decision_record event (the manual-confirm
    /// path converges the same way), evaluate decision_reached, terminate.
    fn converge_topic(root: &Path, topic: &str, summary: &str) -> Value {
        add_event_with_metadata(
            root,
            topic,
            "harvis-chair",
            "chair",
            "decision_record",
            summary,
            Vec::new(),
            "internal",
            None,
            json!({}),
        )
        .expect("decision event");
        let config = TerminationConfig {
            condition: Some(TerminationCondition::DecisionReached),
            ..TerminationConfig::default()
        };
        let matched = evaluate_room_termination(root, topic, &config)
            .expect("evaluate")
            .expect("decision_reached must match");
        terminate_room_run(root, topic, &matched).expect("terminate")
    }

    fn snapshot_files(root: &Path) -> Vec<PathBuf> {
        let dir = decisions_dir(root);
        let mut paths: Vec<PathBuf> = fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("json"))
            .collect();
        paths.sort();
        paths
    }

    fn read_snapshot(path: &Path) -> Value {
        serde_json::from_str(&fs::read_to_string(path).expect("read")).expect("json")
    }

    #[cfg(unix)]
    fn make_writable(path: &Path) {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o644)).expect("chmod +w");
    }

    #[test]
    fn decision_record_serialization_has_six_elements() {
        let root = temp_root("six-elements");
        converge_topic(&root, "gwt-alpha", "决定采用方案 A。");
        let files = snapshot_files(&root);
        assert_eq!(files.len(), 1);
        let record = read_snapshot(&files[0]);
        assert_eq!(record["schemaVersion"], json!(DECISION_RECORD_SCHEMA));
        assert_eq!(record["topic_id"], json!("gwt-alpha"));
        assert!(record["hash"].as_str().is_some_and(|h| h.len() == 64));
        assert_eq!(record["prev_hash"], json!(GENESIS_PREV_HASH));
        let content = record["content"].as_object().expect("content object");
        for element in CONTENT_ELEMENTS {
            assert!(content.contains_key(element), "missing element {element}");
        }
        assert_eq!(content["summary"], json!("决定采用方案 A。"));
        assert!(content["open_questions"].is_array());
        assert!(content["decision_log"].is_array());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn decision_hash_chain_links_sequential_records() {
        let root = temp_root("chain-links");
        converge_topic(&root, "gwt-one", "第一题定稿。");
        converge_topic(&root, "gwt-two", "第二题定稿。");
        let files = snapshot_files(&root);
        assert_eq!(files.len(), 2);
        // Filename order is digest order, not chain order: identify the
        // genesis record by its prev_hash marker.
        let records: Vec<Value> = files.iter().map(|path| read_snapshot(path)).collect();
        let first = records
            .iter()
            .find(|record| record["prev_hash"] == json!(GENESIS_PREV_HASH))
            .expect("genesis record");
        let second = records
            .iter()
            .find(|record| record["prev_hash"] != json!(GENESIS_PREV_HASH))
            .expect("second record");
        assert_eq!(second["prev_hash"], first["hash"]);
        assert_ne!(first["hash"], second["hash"]);
        let report = verify_decision_chain(&root).expect("verify");
        assert_eq!(report["ok"], json!(true), "errors: {}", report["errors"]);
        assert_eq!(report["record_count"], json!(2));
        assert_eq!(report["decision_ids"].as_array().expect("ids").len(), 2);
        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn decision_tampered_content_is_detected() {
        let root = temp_root("tamper-content");
        converge_topic(&root, "gwt-one", "第一题定稿。");
        converge_topic(&root, "gwt-two", "第二题定稿。");
        let files = snapshot_files(&root);
        let target = files[0].clone();
        make_writable(&target);
        let mut record = read_snapshot(&target);
        record["content"]["summary"] = json!("事后篡改的结论。");
        fs::write(
            &target,
            serde_json::to_string_pretty(&record).unwrap() + "\n",
        )
        .expect("rewrite");
        let report = verify_decision_chain(&root).expect("verify");
        assert_eq!(report["ok"], json!(false));
        let errors = report["errors"].as_array().expect("errors");
        assert!(
            errors.iter().any(|error| {
                error["file"].as_str() == Some(target.to_string_lossy().as_ref())
                    && error["check"] == json!("content_hash")
            }),
            "expected content_hash error for {target:?}: {errors:?}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn decision_tampered_prev_hash_is_detected() {
        let root = temp_root("tamper-prev");
        converge_topic(&root, "gwt-one", "第一题定稿。");
        converge_topic(&root, "gwt-two", "第二题定稿。");
        let files = snapshot_files(&root);
        // Filename order is digest order, not chain order: tamper the record
        // that actually links to the genesis record.
        let records: Vec<(PathBuf, Value)> = files
            .iter()
            .map(|path| (path.clone(), read_snapshot(path)))
            .collect();
        let (target, _) = records
            .iter()
            .find(|(_, record)| record["prev_hash"] != json!(GENESIS_PREV_HASH))
            .expect("non-genesis record")
            .clone();
        make_writable(&target);
        let mut record = read_snapshot(&target);
        record["prev_hash"] = json!("deadbeef".repeat(8));
        // Re-hash so only the chain link is broken, isolating the check.
        record["hash"] = json!(content_hash(&record));
        fs::write(
            &target,
            serde_json::to_string_pretty(&record).unwrap() + "\n",
        )
        .expect("rewrite");
        let report = verify_decision_chain(&root).expect("verify");
        assert_eq!(report["ok"], json!(false));
        let errors = report["errors"].as_array().expect("errors");
        assert!(
            errors
                .iter()
                .any(|error| { error["file"].as_str() == Some(target.to_string_lossy().as_ref()) }),
            "expected an error naming {target:?}: {errors:?}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn decision_deleted_middle_record_is_detected() {
        let root = temp_root("deleted-middle");
        converge_topic(&root, "gwt-one", "第一题定稿。");
        converge_topic(&root, "gwt-two", "第二题定稿。");
        converge_topic(&root, "gwt-three", "第三题定稿。");
        let files = snapshot_files(&root);
        assert_eq!(files.len(), 3);
        // Filename order is not chain order: locate the true middle link —
        // the record whose hash another record points to via prev_hash while
        // its own prev_hash is not genesis.
        let records: Vec<(PathBuf, Value)> = files
            .iter()
            .map(|path| (path.clone(), read_snapshot(path)))
            .collect();
        let referenced: std::collections::BTreeSet<&str> = records
            .iter()
            .filter_map(|(_, record)| record["prev_hash"].as_str())
            .collect();
        let (middle, _) = records
            .iter()
            .find(|(_, record)| {
                record["prev_hash"].as_str() != Some(GENESIS_PREV_HASH)
                    && record["hash"]
                        .as_str()
                        .is_some_and(|hash| referenced.contains(hash))
            })
            .expect("a middle link exists")
            .clone();
        make_writable(&middle);
        fs::remove_file(&middle).expect("delete middle");
        let report = verify_decision_chain(&root).expect("verify");
        assert_eq!(report["ok"], json!(false));
        let errors = report["errors"].as_array().expect("errors");
        assert!(
            errors.iter().any(|error| {
                error["check"] == json!("prev_hash_links")
                    || error["check"] == json!("chain_reachable")
            }),
            "expected a chain linkage error: {errors:?}"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn decision_snapshot_is_written_readonly() {
        use std::os::unix::fs::PermissionsExt;
        let root = temp_root("readonly");
        converge_topic(&root, "gwt-alpha", "决定采用方案 A。");
        let files = snapshot_files(&root);
        assert_eq!(files.len(), 1);
        let mode = fs::metadata(&files[0])
            .expect("metadata")
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o444, "expected 0444, got {mode:o}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn decision_operational_termination_mints_no_snapshot() {
        let root = temp_root("no-mint");
        let topic = "gwt-budget";
        // max_message is an operational stop: the room halted without a
        // decision, so no snapshot may be minted (see terminate_room_run).
        let matched = json!({
            "kind": KIND_MAX_MESSAGE,
            "limit": 3,
            "message_count": 3
        });
        terminate_room_run(&root, topic, &matched).expect("terminate");
        assert!(snapshot_files(&root).is_empty());
        assert!(!decisions_dir(&root).exists());
        let report = verify_decision_chain(&root).expect("verify");
        assert_eq!(report["ok"], json!(true));
        assert_eq!(report["record_count"], json!(0));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn decision_empty_store_verifies_clean() {
        let root = temp_root("empty-store");
        let report = verify_decision_chain(&root).expect("verify");
        assert_eq!(report["ok"], json!(true));
        assert_eq!(report["record_count"], json!(0));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn decision_record_is_minted_once_per_run() {
        let root = temp_root("mint-once");
        let topic = "gwt-alpha";
        let run = converge_topic(&root, topic, "决定采用方案 A。");
        assert_eq!(run["state"], json!("terminated"));
        // Terminating the same run again is a no-op and must not mint twice.
        let matched = json!({"kind": KIND_DECISION_REACHED});
        terminate_room_run(&root, topic, &matched).expect("re-terminate no-op");
        assert_eq!(snapshot_files(&root).len(), 1);
        let _ = fs::remove_dir_all(&root);
    }
}
