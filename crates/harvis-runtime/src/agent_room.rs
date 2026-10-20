use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::approvals::list_approvals;
use crate::memory::{append_memory_candidate, MemoryCandidateInput};
use crate::runs::rel;
use harvis_core::time::now_rfc3339;

pub const AGENT_ROOM_VERSION: &str = "v0.49-agent-room-protocol";
pub const GWT_WORKBENCH_VERSION: &str = "v0.55-gwt-cowork-workbench";
pub const AGENT_ROOM_PROTOCOL_ID: &str = "harvis.agent_room.v1";
pub const HANDOFF_VERSION: &str = "v0.17-alpha";
pub const TASK_PLAN_SCHEMA_VERSION: &str = "harvis.agent-room-task-plan.v1";

const ALLOWED_HARNESSES: &[&str] = &[
    "codex",
    "dsh",
    "claude",
    "claude-code",
    "kimicode",
    "likecode",
    "manual",
];
const TASK_STATUSES: &[&str] = &[
    "pending",
    "in_progress",
    "waiting_approval",
    "blocked",
    "reviewing",
    "done",
    "cancelled",
    "archived",
    "closed",
];
// T311: "hypothesis" and "verification_target" join the supported list so
// v0.45 cognitive trace events keep their native kind in `event_kind`
// (`decision` -> `decision_record` and `handoff_request` -> `handoff_note`
// stay mapped onto the v0.49 kinds). Appending members is backward
// compatible: `normalize_event_kind` only gains new pass-through values and
// every previously written event keeps its stored kind.
const SUPPORTED_EVENT_KINDS: &[&str] = &[
    "agent_message",
    "tool_call_summary",
    "claim",
    "question",
    "counterpoint",
    "hypothesis",
    "verification_target",
    "decision_record",
    "handoff_note",
    "review_comment",
    "status_change",
    "final_report",
];
const HANDOFF_STATES: &[&str] = &[
    "pending_harness",
    "running",
    "reviewing",
    "done",
    "blocked",
    "cancelled",
];

/// Verification states for the handoff contract (T306). Naming follows the
/// OpenTelemetry GenAI convention of explicit, lowercase status values.
pub const HANDOFF_VERIFICATION_STATUSES: &[&str] = &["not_started", "passed", "failed", "skipped"];

/// Roster execution modes (T308 / ROADMAP v0.47). `record_only` participants
/// are recorded but never executed; `approval_required` participants execute
/// only through the approval/handoff flow; `active` participants may be
/// executed by the Agent Room stepper through their configured local harness
/// or provider route.
pub const PARTICIPANT_EXECUTION_MODES: &[&str] = &["record_only", "approval_required", "active"];

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HandoffVerificationStatus {
    #[default]
    NotStarted,
    Passed,
    Failed,
    Skipped,
}

/// Cost block of the handoff contract. All fields are nullable: adapters
/// write `null` when a value is unknown instead of omitting the key.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct HandoffCost {
    #[serde(default)]
    pub currency: Option<String>,
    #[serde(default)]
    pub amount: Option<f64>,
    #[serde(default)]
    pub pricing_source: Option<String>,
}

/// Usage block of the handoff contract. Token field naming borrows the
/// OpenTelemetry GenAI span usage attributes (input/output tokens).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct HandoffUsage {
    #[serde(default)]
    pub input_tokens: Option<u64>,
    #[serde(default)]
    pub output_tokens: Option<u64>,
    #[serde(default)]
    pub model_route: Option<String>,
    #[serde(default)]
    pub provider: Option<String>,
}

/// Verification block of the handoff contract (ROADMAP v0.44: verification
/// evidence persisted as reviewable records).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct HandoffVerification {
    #[serde(default)]
    pub status: HandoffVerificationStatus,
    #[serde(default)]
    pub evidence_refs: Vec<String>,
    #[serde(default)]
    pub verified_at: Option<String>,
}

/// Typed read view of a handoff record. The T306 contract fields use serde
/// defaults so legacy handoffs (handoff_version <= v0.16-alpha, without
/// cost/usage/verification keys) deserialize without error; unknown extra
/// keys are preserved in `extra`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandoffRecord {
    pub handoff_version: String,
    pub handoff_id: String,
    #[serde(default)]
    pub run_id: Option<String>,
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub cost: HandoffCost,
    #[serde(default)]
    pub usage: HandoffUsage,
    #[serde(default)]
    pub verification: HandoffVerification,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// Parse a handoff JSON document into the typed contract view. Legacy
/// handoffs missing cost/usage/verification parse with default values
/// (nulls / not_started), giving version-compatible reads.
pub fn parse_handoff_record(text: &str) -> Result<HandoffRecord> {
    let record: HandoffRecord = serde_json::from_str(text).context("invalid handoff json")?;
    Ok(record)
}

#[derive(Debug, Clone, Default)]
pub struct ParticipantInput {
    pub slot_id: String,
    pub role: String,
    pub display_name: String,
    pub provider_ref: Option<String>,
    pub model_ref: Option<String>,
    pub harness_ref: Option<String>,
    pub route_ref: Option<String>,
    pub execution_mode: Option<String>,
    pub status: Option<String>,
    pub permissions: Option<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct MailboxInput {
    pub topic_id: Option<String>,
    pub from_slot_id: String,
    pub to_slot_id: String,
    pub kind: String,
    pub subject: String,
    pub content: String,
    pub source_event_id: Option<String>,
    pub task_id: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct TaskInput {
    pub topic_id: Option<String>,
    pub title: String,
    pub owner_slot_id: String,
    pub status: Option<String>,
    pub source_event_id: Option<String>,
    pub approval_id: Option<String>,
    pub handoff_id: Option<String>,
    pub run_id: Option<String>,
    pub packet_id: Option<String>,
    pub description: Option<String>,
    pub metadata: Option<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct TaskLinkInput {
    pub task_id: String,
    pub approval_id: Option<String>,
    pub handoff_id: Option<String>,
    pub run_id: Option<String>,
    pub packet_id: Option<String>,
    pub status: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ConversationInput {
    pub transport: String,
    pub chat_id: Option<String>,
    pub sender: Option<String>,
    pub message_id: Option<String>,
    pub intent: Option<String>,
    pub route_state: Option<String>,
    pub task_id: Option<String>,
    pub packet_id: Option<String>,
    pub run_id: Option<String>,
    pub handoff_id: Option<String>,
    pub summary: Option<String>,
    pub metadata: Option<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct HandoffStatusInput {
    pub handoff_id: String,
    pub state: String,
    pub summary: Option<String>,
    pub updated_by: Option<String>,
    pub result_path: Option<String>,
    pub exit_code: Option<i64>,
    pub cost: Option<HandoffCost>,
    pub usage: Option<HandoffUsage>,
    pub verification: Option<HandoffVerification>,
}

#[derive(Debug, Clone, Default)]
pub struct HandoffReviewInput {
    pub handoff_id: String,
    pub decision: String,
    pub reviewer: Option<String>,
    pub notes: Option<String>,
}

pub fn init_agent_room(root: &Path) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let room = agent_room_dir(&root)?;
    for name in [
        "topics",
        "events",
        "messages",
        "mailbox",
        "mailbox_wakes",
        "tasks",
        "conversations",
    ] {
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(room.join(format!("{name}.jsonl")))?;
    }
    handoffs_dir(&root)?;
    ensure_default_participants(&root)?;
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "protocol": {
            "id": AGENT_ROOM_PROTOCOL_ID,
            "version": "0.49"
        },
        "supported_event_kinds": SUPPORTED_EVENT_KINDS,
        "workspace": {"label": workspace_label(&root)},
        "paths": {
            "topics": rel(&room.join("topics.jsonl"), &root),
            "events": rel(&room.join("events.jsonl"), &root),
            "messages": rel(&room.join("messages.jsonl"), &root),
            "participants": rel(&participants_path(&root)?, &root),
            "mailbox": rel(&room.join("mailbox.jsonl"), &root),
            "mailbox_wakes": rel(&room.join("mailbox_wakes.jsonl"), &root),
            "tasks": rel(&room.join("tasks.jsonl"), &root),
            "conversations": rel(&room.join("conversations.jsonl"), &root),
            "handoffs": rel(&root.join(".harvis/handoffs"), &root)
        }
    }))
}

pub fn create_topic(root: &Path, title: &str, goal: &str, created_by: &str) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let title = title.trim();
    if title.is_empty() {
        bail!("topic title is required");
    }
    let topic_id = stable_id("topic", &[title, goal, created_by])?;
    let topic = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "topic_id": topic_id,
        "title": title,
        "goal": goal.trim(),
        "status": "open",
        "created_by": created_by,
        "created_at": now_rfc3339()?
    });
    append_jsonl(&jsonl_path(&root, "topics")?, &topic)?;
    add_event(
        &root,
        topic["topic_id"].as_str().unwrap_or_default(),
        "harvis",
        "coordinator",
        "topic.created",
        &format!("Created Agent Room topic: {title}"),
        Vec::new(),
        "internal",
        None,
    )?;
    Ok(topic)
}

pub fn add_event(
    root: &Path,
    topic_id: &str,
    agent_id: &str,
    role: &str,
    event_type: &str,
    content: &str,
    source_refs: Vec<String>,
    sensitivity: &str,
    model: Option<&str>,
) -> Result<Value> {
    add_event_with_metadata(
        root,
        topic_id,
        agent_id,
        role,
        event_type,
        content,
        source_refs,
        sensitivity,
        model,
        json!({}),
    )
}

#[allow(clippy::too_many_arguments)]
pub fn add_event_with_metadata(
    root: &Path,
    topic_id: &str,
    agent_id: &str,
    role: &str,
    event_type: &str,
    content: &str,
    source_refs: Vec<String>,
    sensitivity: &str,
    model: Option<&str>,
    metadata: Value,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let event_type = event_type.trim();
    if event_type.is_empty() {
        bail!("event_type is required");
    }
    let event_kind = normalize_event_kind(event_type);
    let content = content.trim();
    let event = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "protocol": {
            "id": AGENT_ROOM_PROTOCOL_ID,
            "version": "0.49"
        },
        "event_id": stable_id("evt", &[topic_id, agent_id, event_type, content])?,
        "topic_id": topic_id,
        "agent_id": agent_id,
        "role": role,
        "actor": {
            "kind": if agent_id == "human" { "user" } else { "agent" },
            "id": agent_id
        },
        "event_kind": event_kind,
        "event_type": event_type,
        "model": model,
        "source_refs": source_refs,
        "source_age": null,
        "sensitivity": sensitivity,
        "content": content,
        "content_text": content,
        "metadata": metadata,
        "created_at": now_rfc3339()?
    });
    append_jsonl(&jsonl_path(&root, "events")?, &event)?;
    Ok(event)
}

pub fn add_message(
    root: &Path,
    topic_id: &str,
    agent_id: &str,
    role: &str,
    content: &str,
    source_refs: Vec<String>,
    sensitivity: &str,
    model: Option<&str>,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    if content.trim().is_empty() {
        bail!("message content is required");
    }
    let mut message = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "protocol": {
            "id": AGENT_ROOM_PROTOCOL_ID,
            "version": "0.49"
        },
        "message_id": stable_id("msg", &[topic_id, agent_id, content])?,
        "topic_id": topic_id,
        "agent_id": agent_id,
        "role": role,
        "model": model,
        "source_refs": source_refs,
        "sensitivity": sensitivity,
        "content": content.trim(),
        "created_at": now_rfc3339()?
    });
    append_jsonl(&jsonl_path(&root, "messages")?, &message)?;
    let event = add_event_with_metadata(
        &root,
        topic_id,
        agent_id,
        role,
        "agent_message",
        content,
        Vec::new(),
        sensitivity,
        model,
        json!({
            "message_id": message["message_id"].as_str().unwrap_or("msg_unknown"),
            "compatibility": {
                "also_written_to": "messages.jsonl",
                "legacy_event_type": "message.created"
            }
        }),
    )?;
    message["event_id"] = event["event_id"].clone();
    message["event_kind"] = event["event_kind"].clone();
    Ok(message)
}

pub fn list_agent_room(root: &Path, limit: usize) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "protocol": {
            "id": AGENT_ROOM_PROTOCOL_ID,
            "version": "0.49"
        },
        "supported_event_kinds": SUPPORTED_EVENT_KINDS,
        "workspace": {"label": workspace_label(&root)},
        "topics": read_jsonl(&jsonl_path(&root, "topics")?, limit)?,
        "events": read_jsonl(&jsonl_path(&root, "events")?, limit)?,
        "messages": read_jsonl(&jsonl_path(&root, "messages")?, limit)?,
        "participants": list_participants(&root, None)?.get("participants").cloned().unwrap_or_else(|| json!([])),
        "mailbox": list_mailbox(&root, None, None, limit)?.get("items").cloned().unwrap_or_else(|| json!([])),
        "tasks": list_tasks(&root, None, None, limit)?.get("tasks").cloned().unwrap_or_else(|| json!([])),
        "handoffs": list_handoffs(&root, limit)?.get("handoffs").cloned().unwrap_or_else(|| json!([]))
    }))
}

pub fn list_participants(root: &Path, topic_id: Option<&str>) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let mut participants = ensure_default_participants(&root)?;
    if let Some(topic_id) = topic_id.map(str::trim).filter(|value| !value.is_empty()) {
        participants.retain(|slot| {
            slot.get("topic_id")
                .and_then(Value::as_str)
                .map(|value| value == topic_id)
                .unwrap_or(true)
        });
    }
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "workspace": {"label": workspace_label(&root)},
        "participant_count": participants.len(),
        "participants": participants,
        "paths": {
            "participants": rel(&participants_path(&root)?, &root)
        }
    }))
}

pub fn upsert_participant(root: &Path, input: ParticipantInput) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let slot_id = safe_token(&input.slot_id, "slot_id")?;
    let role = safe_text(&input.role, 80);
    if role.is_empty() {
        bail!("role is required");
    }
    let display_name = safe_text(&input.display_name, 120);
    if display_name.is_empty() {
        bail!("display_name is required");
    }
    let moment = now_rfc3339()?;
    let mut participants = read_participants_file(&root)?;
    let execution_mode =
        clean_optional(input.execution_mode).unwrap_or_else(|| "record_only".to_string());
    if !PARTICIPANT_EXECUTION_MODES.contains(&execution_mode.as_str()) {
        bail!(
            "execution_mode must be one of: {}",
            PARTICIPANT_EXECUTION_MODES.join(", ")
        );
    }
    let mut participant = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "slot_id": slot_id,
        "role": role,
        "display_name": display_name,
        "provider_ref": clean_optional(input.provider_ref),
        "model_ref": clean_optional(input.model_ref),
        "harness_ref": clean_optional(input.harness_ref),
        "route_ref": clean_optional(input.route_ref),
        "execution_mode": execution_mode.clone(),
        "status": clean_optional(input.status).unwrap_or_else(|| "idle".to_string()),
        "permissions": input.permissions.unwrap_or_else(default_slot_permissions),
        "updated_at": moment,
        "safety": {
            "executes_without_approval": false,
            "adopts_memory_without_review": false,
            "public_network_exposure": false
        }
    });
    if let Some(existing) = participants.iter().find(|slot| {
        slot.get("slot_id").and_then(Value::as_str)
            == participant.get("slot_id").and_then(Value::as_str)
    }) {
        participant["created_at"] = existing
            .get("created_at")
            .cloned()
            .unwrap_or_else(|| participant["updated_at"].clone());
    } else {
        participant["created_at"] = participant["updated_at"].clone();
    }
    participants.retain(|slot| {
        slot.get("slot_id").and_then(Value::as_str)
            != participant.get("slot_id").and_then(Value::as_str)
    });
    participants.push(participant.clone());
    write_participants_file(&root, participants)?;
    add_event_with_metadata(
        &root,
        "gwt-workbench",
        "harvis-chair",
        "chair",
        "participant.upserted",
        &format!(
            "Upserted Agent Room slot {}.",
            participant["slot_id"].as_str().unwrap_or("unknown")
        ),
        Vec::new(),
        "internal",
        None,
        json!({
            "slot_id": participant["slot_id"].clone(),
            "execution_mode": execution_mode,
            "record_only": execution_mode == "record_only"
        }),
    )?;
    Ok(participant)
}

pub fn update_participant_status(root: &Path, slot_id: &str, status: &str) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let slot_id = safe_token(slot_id, "slot_id")?;
    let status = safe_text(status, 80);
    if status.is_empty() {
        bail!("status is required");
    }
    let moment = now_rfc3339()?;
    let mut participants = read_participants_file(&root)?;
    let Some(participant) = participants
        .iter_mut()
        .find(|slot| slot.get("slot_id").and_then(Value::as_str) == Some(slot_id.as_str()))
    else {
        bail!("participant not found: {slot_id}");
    };
    participant["status"] = json!(status);
    participant["updated_at"] = json!(moment);
    let updated = participant.clone();
    write_participants_file(&root, participants)?;
    add_event_with_metadata(
        &root,
        "gwt-workbench",
        &slot_id,
        updated
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or("agent"),
        "participant.status",
        &format!("Slot {slot_id} status changed to {status}."),
        Vec::new(),
        "internal",
        None,
        json!({"slot_id": slot_id, "status": status, "record_only": true}),
    )?;
    Ok(updated)
}

pub fn create_mailbox_item(root: &Path, input: MailboxInput) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let from_slot_id = safe_text(&input.from_slot_id, 120);
    let to_slot_id = safe_text(&input.to_slot_id, 120);
    let subject = safe_text(&input.subject, 240);
    let content = safe_text(&input.content, 4000);
    if from_slot_id.is_empty() || to_slot_id.is_empty() {
        bail!("from_slot_id and to_slot_id are required");
    }
    if subject.is_empty() && content.is_empty() {
        bail!("mailbox subject or content is required");
    }
    let topic_id = clean_optional(input.topic_id).unwrap_or_else(|| "gwt-workbench".to_string());
    let kind = clean_optional(Some(input.kind)).unwrap_or_else(|| "request".to_string());
    let item = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "mailbox_item",
        "mail_id": stable_id("mail", &[&topic_id, &from_slot_id, &to_slot_id, &subject, &content])?,
        "topic_id": topic_id,
        "from_slot_id": from_slot_id,
        "to_slot_id": to_slot_id,
        "kind": kind,
        "subject": subject,
        "content": content,
        "status": "unread",
        "source_event_id": clean_optional(input.source_event_id),
        "task_id": clean_optional(input.task_id),
        "created_at": now_rfc3339()?,
        "updated_at": Value::Null,
        "safety": {"executes_task": false, "record_only": true}
    });
    append_jsonl(&jsonl_path(&root, "mailbox")?, &item)?;
    add_event_with_metadata(
        &root,
        item["topic_id"].as_str().unwrap_or("gwt-workbench"),
        item["from_slot_id"].as_str().unwrap_or("unknown"),
        "agent",
        "mailbox.created",
        &format!(
            "Mailbox item created: {}",
            item["subject"].as_str().unwrap_or("")
        ),
        Vec::new(),
        "internal",
        None,
        json!({"mail_id": item["mail_id"].clone(), "to_slot_id": item["to_slot_id"].clone()}),
    )?;
    Ok(item)
}

pub fn mark_mailbox_read(root: &Path, mail_id: &str, read_by: &str) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let mail_id = safe_text(mail_id, 120);
    let read_by = safe_text(read_by, 120);
    if mail_id.is_empty() {
        bail!("mail_id is required");
    }
    let existing = list_mailbox(&root, None, None, 1000)?
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("mail_id").and_then(Value::as_str) == Some(mail_id.as_str()))
                .cloned()
        });
    if existing.is_none() {
        bail!("mailbox item not found: {mail_id}");
    }
    let event = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "mailbox_status",
        "mail_id": mail_id,
        "status": "read",
        "read_by": if read_by.is_empty() { "human" } else { read_by.as_str() },
        "updated_at": now_rfc3339()?,
        "safety": {"executes_task": false, "record_only": true}
    });
    append_jsonl(&jsonl_path(&root, "mailbox")?, &event)?;
    Ok(event)
}

pub fn wake_mailbox_item(
    root: &Path,
    mail_id: &str,
    consumer_slot_id: &str,
    reason: &str,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let mail_id = safe_text(mail_id, 120);
    let consumer_slot_id = safe_text(consumer_slot_id, 120);
    let reason = safe_text(reason, 300);
    if mail_id.is_empty() {
        bail!("mail_id is required");
    }
    if consumer_slot_id.is_empty() {
        bail!("consumer_slot_id is required");
    }
    let mail = list_mailbox(&root, None, None, 1000)?
        .get("items")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("mail_id").and_then(Value::as_str) == Some(mail_id.as_str()))
                .cloned()
        })
        .with_context(|| format!("mailbox item not found: {mail_id}"))?;
    let topic_id = mail
        .get("topic_id")
        .and_then(Value::as_str)
        .unwrap_or("gwt-workbench")
        .to_string();
    let to_slot_id = mail
        .get("to_slot_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let wake = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "mailbox_wake",
        "wake_id": stable_id("wake", &[&mail_id, &consumer_slot_id, &reason])?,
        "mail_id": mail_id,
        "topic_id": topic_id,
        "to_slot_id": to_slot_id,
        "consumer_slot_id": consumer_slot_id,
        "reason": if reason.is_empty() { "manual_or_consumer_wake" } else { reason.as_str() },
        "status": "woken",
        "created_at": now_rfc3339()?,
        "safety": {"executes_task": false, "record_only": true}
    });
    append_jsonl(&jsonl_path(&root, "mailbox_wakes")?, &wake)?;
    add_event_with_metadata(
        &root,
        wake["topic_id"].as_str().unwrap_or("gwt-workbench"),
        wake["consumer_slot_id"].as_str().unwrap_or("harvis-chair"),
        "control-plane",
        "mailbox.wake",
        &format!(
            "Mailbox item woken for {}",
            wake["to_slot_id"].as_str().unwrap_or("unknown")
        ),
        Vec::new(),
        "internal",
        None,
        json!({
            "mail_id": wake["mail_id"].clone(),
            "wake_id": wake["wake_id"].clone(),
            "record_only": true
        }),
    )?;
    Ok(wake)
}

pub fn consume_mailbox(
    root: &Path,
    consumer_slot_id: &str,
    topic_id: Option<&str>,
    limit: usize,
    dry_run: bool,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let consumer_slot_id = safe_text(consumer_slot_id, 120);
    if consumer_slot_id.is_empty() {
        bail!("consumer_slot_id is required");
    }
    let unread = list_mailbox(&root, topic_id, Some("unread"), limit)?
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut consumed = Vec::new();
    for mail in unread {
        let Some(mail_id) = mail.get("mail_id").and_then(Value::as_str) else {
            continue;
        };
        let wake = wake_mailbox_item(&root, mail_id, &consumer_slot_id, "consumer_loop")?;
        let read = if dry_run {
            Value::Null
        } else {
            mark_mailbox_read(&root, mail_id, &consumer_slot_id)?
        };
        consumed.push(json!({
            "mail": mail,
            "wake": wake,
            "read": read,
            "dry_run": dry_run
        }));
    }
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "mailbox_consume_result",
        "consumer_slot_id": consumer_slot_id,
        "topic_id": topic_id,
        "dry_run": dry_run,
        "consumed_count": consumed.len(),
        "consumed": consumed,
        "safety": {"executes_task": false, "record_only": true}
    }))
}

pub fn consume_mailbox_loop(
    root: &Path,
    consumer_slot_id: &str,
    topic_id: Option<&str>,
    limit: usize,
    max_batches: usize,
    dry_run: bool,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let limit = limit.max(1);
    let max_batches = max_batches.max(1);
    let mut batches = Vec::new();
    let mut total_consumed = 0usize;
    for batch_index in 0..max_batches {
        let batch = consume_mailbox(&root, consumer_slot_id, topic_id, limit, dry_run)?;
        let consumed = batch
            .get("consumed_count")
            .and_then(Value::as_u64)
            .unwrap_or(0) as usize;
        total_consumed += consumed;
        batches.push(json!({
            "batch_index": batch_index,
            "consumed_count": consumed,
            "result": batch
        }));
        if consumed < limit || dry_run {
            break;
        }
    }
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "mailbox_consume_loop_result",
        "consumer_slot_id": safe_text(consumer_slot_id, 120),
        "topic_id": topic_id,
        "limit": limit,
        "max_batches": max_batches,
        "dry_run": dry_run,
        "batch_count": batches.len(),
        "total_consumed_count": total_consumed,
        "batches": batches,
        "safety": {"executes_task": false, "record_only": true}
    }))
}

pub fn list_mailbox(
    root: &Path,
    topic_id: Option<&str>,
    status: Option<&str>,
    limit: usize,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let topic_filter = topic_id.map(str::trim).filter(|value| !value.is_empty());
    let status_filter = status.map(str::trim).filter(|value| !value.is_empty());
    let rows = read_jsonl_forward(&jsonl_path(&root, "mailbox")?)?;
    let mut by_id: BTreeMap<String, Value> = BTreeMap::new();
    for row in rows {
        let Some(mail_id) = row.get("mail_id").and_then(Value::as_str) else {
            continue;
        };
        if row.get("record_type").and_then(Value::as_str) == Some("mailbox_status") {
            if let Some(item) = by_id.get_mut(mail_id) {
                item["status"] = row.get("status").cloned().unwrap_or_else(|| json!("read"));
                item["read_by"] = row.get("read_by").cloned().unwrap_or(Value::Null);
                item["updated_at"] = row.get("updated_at").cloned().unwrap_or(Value::Null);
            }
            continue;
        }
        by_id.insert(mail_id.to_string(), row);
    }
    let mut items = by_id.into_values().collect::<Vec<_>>();
    items.retain(|item| {
        topic_filter
            .map(|filter| item.get("topic_id").and_then(Value::as_str) == Some(filter))
            .unwrap_or(true)
            && status_filter
                .map(|filter| item.get("status").and_then(Value::as_str) == Some(filter))
                .unwrap_or(true)
    });
    items.sort_by(|left, right| {
        value_str(right, "created_at")
            .cmp(&value_str(left, "created_at"))
            .then_with(|| value_str(left, "mail_id").cmp(&value_str(right, "mail_id")))
    });
    items.truncate(limit);
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "workspace": {"label": workspace_label(&root)},
        "item_count": items.len(),
        "items": items
    }))
}

pub fn create_task(root: &Path, input: TaskInput) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let title = safe_text(&input.title, 300);
    let owner_slot_id = safe_text(&input.owner_slot_id, 120);
    if title.is_empty() || owner_slot_id.is_empty() {
        bail!("title and owner_slot_id are required");
    }
    let status = clean_optional(input.status).unwrap_or_else(|| "pending".to_string());
    validate_task_status(&status)?;
    let topic_id = clean_optional(input.topic_id).unwrap_or_else(|| "gwt-workbench".to_string());
    let source_event_id = clean_optional(input.source_event_id);
    let task_id = if let Some(source_event_id) = source_event_id.as_deref() {
        stable_id(
            "task",
            &[&topic_id, &owner_slot_id, &title, source_event_id],
        )?
    } else {
        stable_id("task", &[&topic_id, &owner_slot_id, &title])?
    };
    let task = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "task",
        "task_id": task_id,
        "topic_id": topic_id,
        "title": title,
        "description": clean_optional(input.description),
        "owner_slot_id": owner_slot_id,
        "status": status,
        "source_event_id": source_event_id,
        "approval_id": clean_optional(input.approval_id),
        "handoff_id": clean_optional(input.handoff_id),
        "run_id": clean_optional(input.run_id),
        "packet_id": clean_optional(input.packet_id),
        "metadata": input.metadata.unwrap_or_else(|| json!({})),
        "created_at": now_rfc3339()?,
        "updated_at": Value::Null,
        "safety": {"executes_task": false, "record_only": true}
    });
    append_jsonl(&jsonl_path(&root, "tasks")?, &task)?;
    add_event_with_metadata(
        &root,
        task["topic_id"].as_str().unwrap_or("gwt-workbench"),
        task["owner_slot_id"].as_str().unwrap_or("unknown"),
        "agent",
        "task.created",
        &format!("Task created: {}", task["title"].as_str().unwrap_or("")),
        Vec::new(),
        "internal",
        None,
        json!({"task_id": task["task_id"].clone(), "status": task["status"].clone()}),
    )?;
    Ok(task)
}

pub fn update_task_status(root: &Path, task_id: &str, status: &str, note: &str) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let task_id = safe_text(task_id, 120);
    let status = safe_text(status, 80);
    validate_task_status(&status)?;
    let existing = list_tasks(&root, None, None, 1000)?
        .get("tasks")
        .and_then(Value::as_array)
        .and_then(|tasks| {
            tasks
                .iter()
                .find(|task| task.get("task_id").and_then(Value::as_str) == Some(task_id.as_str()))
                .cloned()
        });
    let Some(existing) = existing else {
        bail!("task not found: {task_id}");
    };
    let event = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "task_status",
        "task_id": task_id,
        "topic_id": existing.get("topic_id").cloned().unwrap_or_else(|| json!("gwt-workbench")),
        "status": status,
        "note": safe_text(note, 1000),
        "updated_at": now_rfc3339()?,
        "safety": {"executes_task": false, "record_only": true}
    });
    append_jsonl(&jsonl_path(&root, "tasks")?, &event)?;
    add_event_with_metadata(
        &root,
        event["topic_id"].as_str().unwrap_or("gwt-workbench"),
        existing
            .get("owner_slot_id")
            .and_then(Value::as_str)
            .unwrap_or("harvis-chair"),
        "agent",
        "task.status",
        &format!("Task {} status changed to {}.", task_id, status),
        Vec::new(),
        "internal",
        None,
        json!({"task_id": task_id, "status": status}),
    )?;
    if status == "done" {
        let _ = append_memory_candidate(
            &root,
            MemoryCandidateInput {
                source_type: "task_done".to_string(),
                source_id: task_id.clone(),
                summary: format!(
                    "Task completed: {}",
                    existing
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or("untitled task")
                ),
                evidence: vec![
                    format!("task_id={task_id}"),
                    format!(
                        "owner_slot_id={}",
                        existing
                            .get("owner_slot_id")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown")
                    ),
                    safe_text(note, 500),
                ],
                created_by: Some("agent-room-task-status".to_string()),
            },
        );
    }
    Ok(event)
}

pub fn link_task(root: &Path, input: TaskLinkInput) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let task_id = safe_text(&input.task_id, 120);
    if task_id.is_empty() {
        bail!("task_id is required");
    }
    let existing = list_tasks(&root, None, None, 1000)?
        .get("tasks")
        .and_then(Value::as_array)
        .and_then(|tasks| {
            tasks
                .iter()
                .find(|task| task.get("task_id").and_then(Value::as_str) == Some(task_id.as_str()))
                .cloned()
        });
    let Some(existing) = existing else {
        bail!("task not found: {task_id}");
    };
    if let Some(status) = input.status.as_deref() {
        validate_task_status(status)?;
    }
    let event = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "task_link",
        "task_id": task_id,
        "topic_id": existing.get("topic_id").cloned().unwrap_or_else(|| json!("gwt-workbench")),
        "approval_id": clean_optional(input.approval_id),
        "handoff_id": clean_optional(input.handoff_id),
        "run_id": clean_optional(input.run_id),
        "packet_id": clean_optional(input.packet_id),
        "status": clean_optional(input.status),
        "note": clean_optional(input.note),
        "updated_at": now_rfc3339()?,
        "safety": {"executes_task": false, "record_only": true}
    });
    append_jsonl(&jsonl_path(&root, "tasks")?, &event)?;
    add_event_with_metadata(
        &root,
        event["topic_id"].as_str().unwrap_or("gwt-workbench"),
        existing
            .get("owner_slot_id")
            .and_then(Value::as_str)
            .unwrap_or("harvis-chair"),
        "agent",
        "task.linked",
        &format!("Task {} linked to execution metadata.", task_id),
        Vec::new(),
        "internal",
        None,
        json!({
            "task_id": task_id,
            "approval_id": event["approval_id"].clone(),
            "handoff_id": event["handoff_id"].clone(),
            "run_id": event["run_id"].clone(),
            "packet_id": event["packet_id"].clone()
        }),
    )?;
    Ok(event)
}

pub fn list_tasks(
    root: &Path,
    topic_id: Option<&str>,
    status: Option<&str>,
    limit: usize,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let topic_filter = topic_id.map(str::trim).filter(|value| !value.is_empty());
    let status_filter = status.map(str::trim).filter(|value| !value.is_empty());
    let rows = read_jsonl_forward(&jsonl_path(&root, "tasks")?)?;
    let mut by_id: BTreeMap<String, Value> = BTreeMap::new();
    for row in rows {
        let Some(task_id) = row.get("task_id").and_then(Value::as_str) else {
            continue;
        };
        match row.get("record_type").and_then(Value::as_str) {
            Some("task_status") => {
                if let Some(task) = by_id.get_mut(task_id) {
                    task["status"] = row
                        .get("status")
                        .cloned()
                        .unwrap_or_else(|| json!("pending"));
                    task["updated_at"] = row.get("updated_at").cloned().unwrap_or(Value::Null);
                    task["latest_note"] = row.get("note").cloned().unwrap_or(Value::Null);
                }
                continue;
            }
            Some("task_link") => {
                if let Some(task) = by_id.get_mut(task_id) {
                    for key in ["approval_id", "handoff_id", "run_id", "packet_id"] {
                        if row.get(key).is_some_and(|value| !value.is_null()) {
                            task[key] = row.get(key).cloned().unwrap_or(Value::Null);
                        }
                    }
                    if row.get("status").is_some_and(|value| !value.is_null()) {
                        task["status"] = row
                            .get("status")
                            .cloned()
                            .unwrap_or_else(|| json!("pending"));
                    }
                    task["updated_at"] = row.get("updated_at").cloned().unwrap_or(Value::Null);
                    task["latest_note"] = row.get("note").cloned().unwrap_or(Value::Null);
                }
                continue;
            }
            _ => {}
        }
        by_id.insert(task_id.to_string(), row);
    }
    let mut tasks = by_id.into_values().collect::<Vec<_>>();
    tasks.retain(|task| {
        topic_filter
            .map(|filter| task.get("topic_id").and_then(Value::as_str) == Some(filter))
            .unwrap_or(true)
            && status_filter
                .map(|filter| task.get("status").and_then(Value::as_str) == Some(filter))
                .unwrap_or(true)
    });
    tasks.sort_by(|left, right| {
        latest_time(right)
            .cmp(&latest_time(left))
            .then_with(|| value_str(left, "task_id").cmp(&value_str(right, "task_id")))
    });
    tasks.truncate(limit);
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "workspace": {"label": workspace_label(&root)},
        "task_count": tasks.len(),
        "tasks": tasks
    }))
}

/// Return the narrow, read-only task projection consumed by the native
/// managed-project surface.
///
/// The task ledger is an append-only JSONL file.  This reader intentionally
/// parses the file itself instead of using `list_tasks`: the latter preserves
/// the historical best-effort behavior of dropping malformed rows, while the
/// wire contract needs to report those rows through `invalidRecordCount` and
/// `isValid` so callers can fail closed without losing a previously accepted
/// cache.
pub fn task_plan(root: &Path) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let path = root.join(".harvis/agent-room/tasks.jsonl");
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(unavailable_task_plan());
        }
        Err(_) => return Ok(unavailable_task_plan()),
    };

    let (tasks, invalid_record_count) = fold_task_plan_records(&text);
    let source_revision = task_plan_revision(&tasks)?;
    let is_valid = invalid_record_count == 0;
    Ok(json!({
        "schemaVersion": TASK_PLAN_SCHEMA_VERSION,
        "sourceAvailable": true,
        "sourceRevision": source_revision,
        "isValid": is_valid,
        "invalidRecordCount": invalid_record_count,
        "tasks": tasks.iter().map(TaskPlanTask::to_wire).collect::<Vec<_>>(),
    }))
}

#[derive(Debug, Clone)]
struct TaskPlanTask {
    task_id: String,
    title: String,
    description: Option<String>,
    owner: String,
    status: String,
    updated_at: Option<String>,
    evidence: Vec<TaskPlanEvidence>,
}

#[derive(Debug, Clone)]
struct TaskPlanEvidence {
    kind: &'static str,
    id: String,
}

impl TaskPlanTask {
    fn to_wire(&self) -> Value {
        json!({
            "taskId": self.task_id,
            "title": self.title,
            "description": self.description,
            "owner": self.owner,
            "status": self.status,
            "updatedAt": self.updated_at,
            "evidence": self.evidence.iter().map(|evidence| json!({
                "kind": evidence.kind,
                "id": evidence.id,
            })).collect::<Vec<_>>(),
        })
    }

    fn set_status(&mut self, status: &str, updated_at: &str) {
        self.status = status.to_string();
        self.updated_at = Some(updated_at.to_string());
    }

    fn set_evidence(&mut self, kind: &'static str, id: &str) {
        if let Some(existing) = self.evidence.iter_mut().find(|item| item.kind == kind) {
            existing.id = id.to_string();
        } else {
            self.evidence.push(TaskPlanEvidence {
                kind,
                id: id.to_string(),
            });
        }
    }
}

fn unavailable_task_plan() -> Value {
    json!({
        "schemaVersion": TASK_PLAN_SCHEMA_VERSION,
        "sourceAvailable": false,
        "sourceRevision": Value::Null,
        "isValid": false,
        "invalidRecordCount": 0,
        "tasks": [],
    })
}

fn fold_task_plan_records(text: &str) -> (Vec<TaskPlanTask>, usize) {
    let mut by_id: BTreeMap<String, TaskPlanTask> = BTreeMap::new();
    let mut invalid_record_count = 0usize;

    for line in text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let row = match serde_json::from_str::<Value>(line) {
            Ok(row) => row,
            Err(_) => {
                invalid_record_count += 1;
                continue;
            }
        };
        let Some(record_type) = row.get("record_type").and_then(Value::as_str) else {
            invalid_record_count += 1;
            continue;
        };

        match record_type {
            "task" => match parse_task_plan_task(&row) {
                Some(task) => {
                    by_id.insert(task.task_id.clone(), task);
                }
                None => invalid_record_count += 1,
            },
            "task_status" => {
                let Some(task_id) = valid_task_plan_id(&row, "task_id", 120) else {
                    invalid_record_count += 1;
                    continue;
                };
                let Some(status) = row.get("status").and_then(Value::as_str) else {
                    invalid_record_count += 1;
                    continue;
                };
                let Some(updated_at) = valid_task_plan_timestamp(&row, "updated_at") else {
                    invalid_record_count += 1;
                    continue;
                };
                if !TASK_STATUSES.contains(&status) {
                    invalid_record_count += 1;
                    continue;
                }
                let Some(task) = by_id.get_mut(&task_id) else {
                    invalid_record_count += 1;
                    continue;
                };
                task.set_status(status, &updated_at);
            }
            "task_link" => {
                let Some(task_id) = valid_task_plan_id(&row, "task_id", 120) else {
                    invalid_record_count += 1;
                    continue;
                };
                let Some(updated_at) = valid_task_plan_timestamp(&row, "updated_at") else {
                    invalid_record_count += 1;
                    continue;
                };
                if let Some(status) = row.get("status").and_then(|value| {
                    if value.is_null() {
                        None
                    } else {
                        value.as_str()
                    }
                }) {
                    if !TASK_STATUSES.contains(&status) {
                        invalid_record_count += 1;
                        continue;
                    }
                } else if row.get("status").is_some_and(|value| !value.is_null()) {
                    invalid_record_count += 1;
                    continue;
                }
                let evidence = match task_plan_link_evidence(&row) {
                    Some(evidence) => evidence,
                    None => {
                        invalid_record_count += 1;
                        continue;
                    }
                };
                let Some(task) = by_id.get_mut(&task_id) else {
                    invalid_record_count += 1;
                    continue;
                };
                for (kind, id) in evidence {
                    task.set_evidence(kind, &id);
                }
                if let Some(status) = row.get("status").and_then(Value::as_str) {
                    task.set_status(status, &updated_at);
                } else {
                    task.updated_at = Some(updated_at);
                }
            }
            _ => invalid_record_count += 1,
        }
    }

    let mut tasks = by_id.into_values().collect::<Vec<_>>();
    for task in &mut tasks {
        task.evidence
            .sort_by_key(|evidence| task_plan_evidence_rank(evidence.kind));
    }
    (tasks, invalid_record_count)
}

fn parse_task_plan_task(row: &Value) -> Option<TaskPlanTask> {
    let task_id = valid_task_plan_id(row, "task_id", 120)?;
    let title = row.get("title").and_then(Value::as_str)?;
    if title.trim().is_empty() || title.chars().count() > 300 {
        return None;
    }
    let owner = row.get("owner_slot_id").and_then(Value::as_str)?;
    if owner.trim().is_empty() || owner.chars().count() > 120 {
        return None;
    }
    let status = row.get("status").and_then(Value::as_str)?;
    if !TASK_STATUSES.contains(&status) {
        return None;
    }
    let description = match row.get("description") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) if !value.trim().is_empty() && value.chars().count() <= 500 => {
            Some(value.to_string())
        }
        _ => return None,
    };
    let updated_at = match row.get("updated_at") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) if is_task_plan_timestamp(value) => Some(value.to_string()),
        _ => return None,
    };
    let evidence = task_plan_base_evidence(row)?;
    Some(TaskPlanTask {
        task_id,
        title: title.to_string(),
        description,
        owner: owner.to_string(),
        status: status.to_string(),
        updated_at,
        evidence,
    })
}

fn task_plan_base_evidence(row: &Value) -> Option<Vec<TaskPlanEvidence>> {
    let mut evidence = Vec::new();
    for (key, kind) in [
        ("source_event_id", "source_event_id"),
        ("approval_id", "approval_id"),
        ("handoff_id", "handoff_id"),
        ("run_id", "run_id"),
        ("packet_id", "packet_id"),
    ] {
        let Some(value) = row.get(key) else {
            continue;
        };
        if value.is_null() {
            continue;
        }
        let id = value.as_str()?;
        if !is_task_plan_id(id, 500) {
            return None;
        }
        evidence.push(TaskPlanEvidence {
            kind,
            id: id.to_string(),
        });
    }
    Some(evidence)
}

fn task_plan_link_evidence(row: &Value) -> Option<Vec<(&'static str, String)>> {
    let mut evidence = Vec::new();
    for (key, kind) in [
        ("approval_id", "approval_id"),
        ("handoff_id", "handoff_id"),
        ("run_id", "run_id"),
        ("packet_id", "packet_id"),
    ] {
        let Some(value) = row.get(key) else {
            continue;
        };
        if value.is_null() {
            continue;
        }
        let id = value.as_str()?;
        if !is_task_plan_id(id, 500) {
            return None;
        }
        evidence.push((kind, id.to_string()));
    }
    Some(evidence)
}

fn valid_task_plan_id(row: &Value, key: &str, maximum_length: usize) -> Option<String> {
    let value = row.get(key).and_then(Value::as_str)?;
    is_task_plan_id(value, maximum_length).then(|| value.to_string())
}

fn is_task_plan_id(value: &str, maximum_length: usize) -> bool {
    let length = value.chars().count();
    !value.is_empty()
        && length <= maximum_length
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '-' | '.' | '_')
        })
}

fn valid_task_plan_timestamp(row: &Value, key: &str) -> Option<String> {
    let value = row.get(key).and_then(Value::as_str)?;
    is_task_plan_timestamp(value).then(|| value.to_string())
}

fn is_task_plan_timestamp(value: &str) -> bool {
    OffsetDateTime::parse(value.trim(), &Rfc3339).is_ok()
}

fn task_plan_evidence_rank(kind: &str) -> usize {
    match kind {
        "source_event_id" => 0,
        "approval_id" => 1,
        "handoff_id" => 2,
        "run_id" => 3,
        "packet_id" => 4,
        _ => usize::MAX,
    }
}

fn task_plan_revision(tasks: &[TaskPlanTask]) -> Result<String> {
    let value = Value::Array(tasks.iter().map(TaskPlanTask::to_wire).collect());
    let mut canonical = String::new();
    write_task_plan_canonical_json(&value, &mut canonical)?;
    Ok(format!("sha256:{:x}", Sha256::digest(canonical.as_bytes())))
}

fn write_task_plan_canonical_json(value: &Value, output: &mut String) -> Result<()> {
    match value {
        Value::Object(object) => {
            output.push('{');
            let mut keys = object.keys().collect::<Vec<_>>();
            keys.sort();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                output.push_str(&serde_json::to_string(key)?);
                output.push(':');
                write_task_plan_canonical_json(&object[key], output)?;
            }
            output.push('}');
        }
        Value::Array(items) => {
            output.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                write_task_plan_canonical_json(item, output)?;
            }
            output.push(']');
        }
        _ => output.push_str(&serde_json::to_string(value)?),
    }
    Ok(())
}

pub fn find_task_by_packet_id(root: &Path, packet_id: &str) -> Result<Option<Value>> {
    let root = resolve_workspace_root(root)?;
    let packet_id = safe_text(packet_id, 120);
    if packet_id.is_empty() {
        return Ok(None);
    }
    Ok(list_tasks(&root, None, None, 5000)?
        .get("tasks")
        .and_then(Value::as_array)
        .and_then(|tasks| {
            tasks
                .iter()
                .find(|task| {
                    task.get("packet_id").and_then(Value::as_str) == Some(packet_id.as_str())
                        || task
                            .get("metadata")
                            .and_then(|metadata| metadata.get("packet_ids"))
                            .and_then(Value::as_array)
                            .is_some_and(|ids| {
                                ids.iter()
                                    .filter_map(Value::as_str)
                                    .any(|id| id == packet_id)
                            })
                })
                .cloned()
        }))
}

pub fn record_conversation_state(root: &Path, input: ConversationInput) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let transport = safe_text(&input.transport, 80);
    if transport.is_empty() {
        bail!("transport is required");
    }
    let chat_id = clean_optional(input.chat_id);
    let sender = clean_optional(input.sender);
    let conversation_key = chat_id
        .as_deref()
        .or(sender.as_deref())
        .unwrap_or("unknown");
    let conversation_id = stable_id("conv", &[&transport, conversation_key])?;
    let item = json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "record_type": "conversation_state",
        "conversation_id": conversation_id,
        "transport": transport,
        "chat_id": chat_id,
        "sender": sender,
        "message_id": clean_optional(input.message_id),
        "intent": clean_optional(input.intent),
        "route_state": clean_optional(input.route_state),
        "task_id": clean_optional(input.task_id),
        "packet_id": clean_optional(input.packet_id),
        "run_id": clean_optional(input.run_id),
        "handoff_id": clean_optional(input.handoff_id),
        "summary": clean_optional(input.summary),
        "metadata": input.metadata.unwrap_or_else(|| json!({})),
        "updated_at": now_rfc3339()?,
        "safety": {"executes_task": false, "projection_only": true}
    });
    append_jsonl(&jsonl_path(&root, "conversations")?, &item)?;
    Ok(item)
}

pub fn list_conversations(
    root: &Path,
    transport: Option<&str>,
    chat_id: Option<&str>,
    sender: Option<&str>,
    limit: usize,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let transport_filter = transport.map(str::trim).filter(|value| !value.is_empty());
    let chat_filter = chat_id.map(str::trim).filter(|value| !value.is_empty());
    let sender_filter = sender.map(str::trim).filter(|value| !value.is_empty());
    let rows = read_jsonl_forward(&jsonl_path(&root, "conversations")?)?;
    let mut by_id: BTreeMap<String, Value> = BTreeMap::new();
    for row in rows {
        let Some(conversation_id) = row.get("conversation_id").and_then(Value::as_str) else {
            continue;
        };
        by_id.insert(conversation_id.to_string(), row);
    }
    let mut conversations = by_id.into_values().collect::<Vec<_>>();
    conversations.retain(|item| {
        transport_filter
            .map(|filter| item.get("transport").and_then(Value::as_str) == Some(filter))
            .unwrap_or(true)
            && chat_filter
                .map(|filter| item.get("chat_id").and_then(Value::as_str) == Some(filter))
                .unwrap_or(true)
            && sender_filter
                .map(|filter| item.get("sender").and_then(Value::as_str) == Some(filter))
                .unwrap_or(true)
    });
    conversations.sort_by(|left, right| {
        value_str(right, "updated_at")
            .cmp(&value_str(left, "updated_at"))
            .then_with(|| {
                value_str(left, "conversation_id").cmp(&value_str(right, "conversation_id"))
            })
    });
    conversations.truncate(limit);
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "workspace": {"label": workspace_label(&root)},
        "conversation_count": conversations.len(),
        "conversations": conversations
    }))
}

pub fn recent_conversation_context(
    root: &Path,
    transport: &str,
    chat_id: Option<&str>,
    sender: Option<&str>,
) -> Result<Option<Value>> {
    let chat_id = chat_id.map(str::trim).filter(|value| !value.is_empty());
    let sender = sender.map(str::trim).filter(|value| !value.is_empty());
    if let Some(chat_id) = chat_id {
        if let Some(item) = list_conversations(root, Some(transport), Some(chat_id), None, 1)?
            .get("conversations")
            .and_then(Value::as_array)
            .and_then(|items| items.first())
            .cloned()
        {
            return Ok(Some(item));
        }
    }
    if let Some(sender) = sender {
        let conversations = list_conversations(root, Some(transport), None, Some(sender), 2)?
            .get("conversations")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if conversations.len() == 1 {
            return Ok(conversations.first().cloned());
        }
    }
    Ok(None)
}

pub fn workspace_state(root: &Path, topic_id: Option<&str>, limit: usize) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let participants = list_participants(&root, topic_id)?
        .get("participants")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let chair_slot = participants
        .iter()
        .find(|slot| slot.get("slot_id").and_then(Value::as_str) == Some("harvis-chair"))
        .cloned()
        .unwrap_or(Value::Null);
    let active_slots = participants
        .iter()
        .filter(|slot| slot.get("status").and_then(Value::as_str) != Some("disabled"))
        .cloned()
        .collect::<Vec<_>>();
    let topics = read_jsonl(&jsonl_path(&root, "topics")?, limit)?;
    let active_topic = topic_id
        .and_then(|needle| {
            topics
                .iter()
                .rev()
                .find(|topic| topic.get("topic_id").and_then(Value::as_str) == Some(needle))
                .cloned()
        })
        .or_else(|| {
            topics
                .iter()
                .rev()
                .find(|topic| topic.get("status").and_then(Value::as_str) != Some("closed"))
                .cloned()
        })
        .unwrap_or(Value::Null);
    let open_tasks = list_tasks(&root, topic_id, None, limit)?
        .get("tasks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|task| {
            !matches!(
                task.get("status").and_then(Value::as_str),
                Some("done" | "cancelled" | "archived" | "closed")
            )
        })
        .collect::<Vec<_>>();
    let unread_mailbox = list_mailbox(&root, topic_id, Some("unread"), limit)?
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let all_approvals = list_approvals(&root, None, limit)
        .ok()
        .and_then(|value| value.get("approvals").and_then(Value::as_array).cloned())
        .unwrap_or_default();
    let pending_approvals = all_approvals
        .iter()
        .filter(|approval| approval.get("status").and_then(Value::as_str) == Some("pending"))
        .cloned()
        .collect::<Vec<_>>();
    let waiting_approval_queue = waiting_approval_queue(&open_tasks, &all_approvals, limit.min(50));
    let recent_handoffs = list_handoffs(&root, limit.min(20))?
        .get("handoffs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let recent_events = read_jsonl(&jsonl_path(&root, "events")?, limit)?;
    let recent_decisions = recent_events
        .iter()
        .rev()
        .filter(|event| event.get("event_kind").and_then(Value::as_str) == Some("decision_record"))
        .take(limit.min(12))
        .cloned()
        .collect::<Vec<_>>();
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "workspace": {"label": workspace_label(&root), "root": root.display().to_string()},
        "active_topic": active_topic,
        "chair_slot": chair_slot,
        "active_slots": active_slots,
        "recent_router_events": recent_router_events(&root, limit.min(12))?,
        "open_tasks": open_tasks,
        "unread_mailbox": unread_mailbox,
        "pending_approvals": pending_approvals,
        "waiting_approval_queue": waiting_approval_queue,
        "recent_handoffs": recent_handoffs,
        "recent_conversations": list_conversations(&root, None, None, None, limit.min(12))?
            .get("conversations")
            .cloned()
            .unwrap_or_else(|| json!([])),
        "recent_decisions": recent_decisions,
        "memory_candidates_summary": memory_candidates_summary(&root),
        "rules": {
            "router_executes_harnesses": false,
            "slots_coordinate_through_mailbox_and_tasks": true,
            "memory_adoption_requires_review": true,
            "shell_or_file_mutation_requires_approval_or_handoff": true
        }
    }))
}

pub fn request_handoff(
    root: &Path,
    run_id: &str,
    harness: &str,
    instruction: &str,
    topic_id: Option<&str>,
    requested_by: &str,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let harness = harness.trim().to_ascii_lowercase();
    if !ALLOWED_HARNESSES.contains(&harness.as_str()) {
        bail!("harness must be one of: {}", ALLOWED_HARNESSES.join(", "));
    }
    let run_path = run_json_path(&root, run_id)?;
    let mut run = read_json(&run_path).with_context(|| format!("invalid run json: {run_id}"))?;
    let packet = run.get("packet").and_then(Value::as_object);
    let topic_id = match topic_id.map(str::trim).filter(|value| !value.is_empty()) {
        Some(topic_id) => topic_id.to_string(),
        None => {
            let title = format!("Handoff {run_id} to {harness}");
            let default_goal = format!("Prepare {run_id} for {harness} execution.");
            let goal = if instruction.is_empty() {
                default_goal.as_str()
            } else {
                instruction
            };
            create_topic(&root, &title, goal, requested_by)?["topic_id"]
                .as_str()
                .unwrap_or_default()
                .to_string()
        }
    };
    let handoff_id = stable_id("handoff", &[run_id, &harness, instruction])?;
    let packet_path = packet
        .and_then(|packet| packet.get("packet_path"))
        .cloned()
        .unwrap_or(Value::Null);
    // T306 contract: cost/usage/verification are always present. No token
    // statistics or pricing source exist at request time, so adapters write
    // explicit nulls (never omitted keys); verification starts not_started.
    // Serialization of these plain structs is infallible.
    let cost = serde_json::to_value(HandoffCost::default()).unwrap_or(Value::Null);
    let usage = serde_json::to_value(HandoffUsage::default()).unwrap_or(Value::Null);
    let verification = serde_json::to_value(HandoffVerification::default()).unwrap_or(Value::Null);
    let handoff = json!({
        "handoff_version": HANDOFF_VERSION,
        "handoff_id": handoff_id,
        "run_id": run_id,
        "packet_id": run.get("packet_id").cloned().unwrap_or(Value::Null),
        "packet_path": packet_path,
        "topic_id": topic_id,
        "harness": harness,
        "state": "pending_harness",
        "instruction": instruction.trim(),
        "requested_by": requested_by,
        "created_at": now_rfc3339()?,
        "cost": cost,
        "usage": usage,
        "verification": verification,
        "safety": {
            "executes_task": false,
            "requires_harness": true,
            "requires_human_review_for_mutation": true
        },
        "next": {
            "summary": "Open the handoff in the selected harness and let that harness perform the agent loop.",
            "codex": format!("Use H.A.R.V.I.S. handoff {} for run {}.", handoff_id, run_id),
            "claude": format!("Use H.A.R.V.I.S. handoff {} for run {}.", handoff_id, run_id)
        }
    });
    let path = handoffs_dir(&root)?.join(format!(
        "{}.json",
        handoff["handoff_id"].as_str().unwrap_or("handoff_unknown")
    ));
    write_json(&path, &handoff)?;
    let mut outputs = run.get("outputs").cloned().unwrap_or_else(|| json!({}));
    if !outputs.is_object() {
        outputs = json!({});
    }
    outputs["latest_handoff"] = json!(rel(&path, &root));
    run["outputs"] = outputs;
    run["state"] = json!("handoff_requested");
    run["mode"] = json!(handoff["harness"].as_str().unwrap_or("manual"));
    run["updated_at"] = json!(now_rfc3339()?);
    write_json(&run_path, &run)?;
    add_event(
        &root,
        handoff["topic_id"].as_str().unwrap_or_default(),
        "harvis",
        "coordinator",
        "handoff.requested",
        &format!(
            "Requested {} handoff for {run_id}.",
            handoff["harness"].as_str().unwrap_or("manual")
        ),
        vec![rel(&run_path, &root)],
        "internal",
        None,
    )?;
    Ok(json!({
        "handoff": handoff,
        "path": rel(&path, &root),
        "run_path": rel(&run_path, &root)
    }))
}

pub fn update_handoff_status(root: &Path, input: HandoffStatusInput) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let handoff_id = safe_text(&input.handoff_id, 160);
    if handoff_id.is_empty() {
        bail!("handoff_id is required");
    }
    let state = safe_text(&input.state, 80);
    validate_handoff_state(&state)?;
    let path = handoffs_dir(&root)?.join(format!("{handoff_id}.json"));
    if !path.exists() {
        bail!("handoff not found: {handoff_id}");
    }
    let Some(mut handoff) = read_json(&path) else {
        bail!("invalid handoff json: {handoff_id}");
    };
    let previous_state = handoff
        .get("state")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let moment = now_rfc3339()?;
    let summary = input.summary.unwrap_or_default();
    let updated_by = input
        .updated_by
        .unwrap_or_else(|| "harvis-handoff-status".to_string());
    handoff["state"] = json!(state);
    handoff["updated_at"] = json!(moment);
    handoff["updated_by"] = json!(safe_text(&updated_by, 160));
    if !summary.trim().is_empty() {
        handoff["summary"] = json!(safe_text(&summary, 1000));
    }
    if let Some(result_path) = input.result_path.as_deref() {
        let result_path = safe_text(result_path, 500);
        if !result_path.is_empty() {
            handoff["result_path"] = json!(result_path);
        }
    }
    if let Some(exit_code) = input.exit_code {
        handoff["exit_code"] = json!(exit_code);
    }
    // T306 contract: adapters that know real cost/usage/verification values
    // report them here; unreported fields keep their existing (explicit-null)
    // values. Serialization of these plain structs is infallible.
    if let Some(cost) = input.cost {
        handoff["cost"] = serde_json::to_value(cost).unwrap_or(Value::Null);
    }
    if let Some(usage) = input.usage {
        handoff["usage"] = serde_json::to_value(usage).unwrap_or(Value::Null);
    }
    if let Some(verification) = input.verification {
        handoff["verification"] = serde_json::to_value(verification).unwrap_or(Value::Null);
    }
    let history_item = json!({
        "state": handoff["state"].clone(),
        "previous_state": previous_state,
        "summary": handoff.get("summary").cloned().unwrap_or(Value::Null),
        "updated_by": handoff["updated_by"].clone(),
        "updated_at": handoff["updated_at"].clone(),
        "result_path": handoff.get("result_path").cloned().unwrap_or(Value::Null),
        "exit_code": handoff.get("exit_code").cloned().unwrap_or(Value::Null)
    });
    let mut history = handoff
        .get("history")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    history.push(history_item.clone());
    handoff["history"] = json!(history);
    write_json(&path, &handoff)?;

    let run_id = handoff.get("run_id").and_then(Value::as_str).unwrap_or("");
    if !run_id.is_empty() {
        if let Ok(run_path) = run_json_path(&root, run_id) {
            if let Some(mut run) = read_json(&run_path) {
                run["state"] = json!(format!("handoff_{state}"));
                run["updated_at"] = json!(now_rfc3339()?);
                let mut outputs = run.get("outputs").cloned().unwrap_or_else(|| json!({}));
                if !outputs.is_object() {
                    outputs = json!({});
                }
                outputs["latest_handoff_state"] = json!(state);
                outputs["latest_handoff"] = json!(rel(&path, &root));
                run["outputs"] = outputs;
                let _ = write_json(&run_path, &run);
            }
        }
    }

    let task = task_for_handoff(&root, &handoff_id)?;
    if let Some(task) = task.as_ref() {
        if let Some(task_id) = task.get("task_id").and_then(Value::as_str) {
            let task_status = task_status_for_handoff_state(&state);
            if !task_status.is_empty() {
                let _ = update_task_status(
                    &root,
                    task_id,
                    task_status,
                    &format!(
                        "Handoff {handoff_id} moved to {state}. {}",
                        safe_text(&summary, 500)
                    ),
                );
            }
        }
    }

    let event_content = format!("Handoff {handoff_id} moved to {state}.");
    add_event_with_metadata(
        &root,
        handoff
            .get("topic_id")
            .and_then(Value::as_str)
            .unwrap_or("gwt-workbench"),
        "executor",
        "executor",
        "handoff.status",
        &event_content,
        vec![rel(&path, &root)],
        "internal",
        None,
        json!({
            "handoff_id": handoff_id,
            "state": state,
            "run_id": handoff.get("run_id").cloned().unwrap_or(Value::Null),
            "packet_id": handoff.get("packet_id").cloned().unwrap_or(Value::Null),
            "task_id": task
                .as_ref()
                .and_then(|task| task.get("task_id"))
                .cloned()
                .unwrap_or(Value::Null),
            "result_path": handoff.get("result_path").cloned().unwrap_or(Value::Null),
            "exit_code": handoff.get("exit_code").cloned().unwrap_or(Value::Null)
        }),
    )?;

    if matches!(state.as_str(), "reviewing" | "done" | "blocked") {
        let _ = append_memory_candidate(
            &root,
            MemoryCandidateInput {
                source_type: "handoff_result".to_string(),
                source_id: handoff_id.clone(),
                summary: format!(
                    "Handoff result: state={state}; {}",
                    safe_text(&summary, 800)
                ),
                evidence: vec![
                    format!("handoff_id={handoff_id}"),
                    format!("state={state}"),
                    format!(
                        "run_id={}",
                        handoff.get("run_id").and_then(Value::as_str).unwrap_or("")
                    ),
                    format!(
                        "packet_id={}",
                        handoff
                            .get("packet_id")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                    ),
                    format!(
                        "task_id={}",
                        task.as_ref()
                            .and_then(|task| task.get("task_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                    ),
                ],
                created_by: Some("agent-room-handoff-status".to_string()),
            },
        );
    }

    Ok(json!({
        "handoff": handoff,
        "path": rel(&path, &root),
        "task": task,
        "safety": {
            "executes_task": false,
            "record_only": true,
            "memory_candidate_only": true
        }
    }))
}

pub fn finalize_handoff_review(root: &Path, input: HandoffReviewInput) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    let handoff_id = safe_text(&input.handoff_id, 160);
    if handoff_id.is_empty() {
        bail!("handoff_id is required");
    }
    let decision = safe_text(&input.decision, 80)
        .to_ascii_lowercase()
        .replace('-', "_");
    let target_state = match decision.as_str() {
        "approve" | "approved" | "accept" | "accepted" => "done",
        "reject" | "rejected" | "needs_revision" | "revise" | "revision" => "blocked",
        _ => bail!("review decision must be one of: approve, reject, needs_revision"),
    };
    let path = handoffs_dir(&root)?.join(format!("{handoff_id}.json"));
    if !path.exists() {
        bail!("handoff not found: {handoff_id}");
    }
    let Some(handoff) = read_json(&path) else {
        bail!("invalid handoff json: {handoff_id}");
    };
    let state = handoff
        .get("state")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    if state != "reviewing" {
        bail!("handoff review requires state=reviewing, got: {state}");
    }
    let reviewer = input
        .reviewer
        .map(|value| safe_text(&value, 160))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "reviewer".to_string());
    let notes = input.notes.unwrap_or_default();
    let summary = match target_state {
        "done" => format!(
            "Reviewer {reviewer} accepted the handoff result. {}",
            safe_text(&notes, 800)
        ),
        _ => format!(
            "Reviewer {reviewer} requested changes or rejected the handoff result. {}",
            safe_text(&notes, 800)
        ),
    };
    let reviewed = update_handoff_status(
        &root,
        HandoffStatusInput {
            handoff_id: handoff_id.clone(),
            state: target_state.to_string(),
            summary: Some(summary.clone()),
            updated_by: Some(reviewer.clone()),
            result_path: handoff
                .get("result_path")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            exit_code: handoff.get("exit_code").and_then(Value::as_i64),
            ..HandoffStatusInput::default()
        },
    )?;
    add_event_with_metadata(
        &root,
        reviewed["handoff"]
            .get("topic_id")
            .and_then(Value::as_str)
            .unwrap_or("gwt-workbench"),
        "reviewer",
        "reviewer",
        "handoff.review",
        &summary,
        vec![rel(&path, &root)],
        "internal",
        None,
        json!({
            "handoff_id": handoff_id,
            "decision": decision,
            "target_state": target_state,
            "reviewer": reviewer,
            "task_id": reviewed
                .get("task")
                .and_then(|task| task.get("task_id"))
                .cloned()
                .unwrap_or(Value::Null),
            "memory_candidate_only": true
        }),
    )?;
    Ok(json!({
        "agent_room_version": AGENT_ROOM_VERSION,
        "gwt_workbench_version": GWT_WORKBENCH_VERSION,
        "review": {
            "handoff_id": reviewed["handoff"]["handoff_id"].clone(),
            "decision": decision,
            "reviewer": reviewer,
            "target_state": target_state,
            "notes": safe_text(&notes, 1000)
        },
        "handoff": reviewed["handoff"].clone(),
        "task": reviewed["task"].clone(),
        "safety": {
            "executes_task": false,
            "record_only": true,
            "memory_candidate_only": true
        }
    }))
}

pub fn list_handoffs(root: &Path, limit: usize) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let mut handoffs = Vec::new();
    for path in json_paths_by_mtime_desc(&handoffs_dir(&root)?)? {
        let Some(mut item) = read_json(&path) else {
            continue;
        };
        item["path"] = json!(rel(&path, &root));
        handoffs.push(item);
        if handoffs.len() >= limit {
            break;
        }
    }
    Ok(json!({
        "handoff_version": HANDOFF_VERSION,
        "agent_room_protocol": {
            "id": AGENT_ROOM_PROTOCOL_ID,
            "version": "0.49"
        },
        "workspace": {"label": workspace_label(&root)},
        "handoff_count": handoffs.len(),
        "handoffs": handoffs
    }))
}

fn ensure_default_participants(root: &Path) -> Result<Vec<Value>> {
    let path = participants_path(root)?;
    if path.exists() {
        let participants = read_participants_file(root)?;
        if !participants.is_empty() {
            return Ok(participants);
        }
    }
    let moment = now_rfc3339()?;
    let participants = default_participants(&moment);
    write_participants_file(root, participants.clone())?;
    Ok(participants)
}

fn default_participants(moment: &str) -> Vec<Value> {
    vec![
        json!({
            "agent_room_version": AGENT_ROOM_VERSION,
            "gwt_workbench_version": GWT_WORKBENCH_VERSION,
            "slot_id": "harvis-chair",
            "role": "chair",
            "display_name": "DeepSeek Chair",
            "provider_ref": "deepseek",
            "model_ref": "deepseek-chat",
            "harness_ref": Value::Null,
            "route_ref": "chair.default",
            "execution_mode": "record_only",
            "status": "idle",
            "permissions": default_slot_permissions(),
            "created_at": moment,
            "updated_at": moment,
            "safety": default_slot_safety()
        }),
        json!({
            "agent_room_version": AGENT_ROOM_VERSION,
            "gwt_workbench_version": GWT_WORKBENCH_VERSION,
            "slot_id": "planner",
            "role": "planner",
            "display_name": "Planner",
            "provider_ref": "deepseek",
            "model_ref": "deepseek-chat",
            "harness_ref": Value::Null,
            "route_ref": "planner.default",
            "execution_mode": "record_only",
            "status": "idle",
            "permissions": default_slot_permissions(),
            "created_at": moment,
            "updated_at": moment,
            "safety": default_slot_safety()
        }),
        json!({
            "agent_room_version": AGENT_ROOM_VERSION,
            "gwt_workbench_version": GWT_WORKBENCH_VERSION,
            "slot_id": "executor",
            "role": "executor",
            "display_name": "Approved Harness Executor",
            "provider_ref": "codex",
            "model_ref": "gpt-5-codex",
            "harness_ref": "codex",
            "route_ref": "cxspark",
            "execution_mode": "approval_required",
            "status": "idle",
            "permissions": default_executor_permissions(),
            "created_at": moment,
            "updated_at": moment,
            "safety": default_slot_safety()
        }),
        json!({
            "agent_room_version": AGENT_ROOM_VERSION,
            "gwt_workbench_version": GWT_WORKBENCH_VERSION,
            "slot_id": "reviewer",
            "role": "reviewer",
            "display_name": "Reviewer",
            "provider_ref": "deepseek",
            "model_ref": "deepseek-chat",
            "harness_ref": Value::Null,
            "route_ref": "review.default",
            "execution_mode": "record_only",
            "status": "idle",
            "permissions": default_slot_permissions(),
            "created_at": moment,
            "updated_at": moment,
            "safety": default_slot_safety()
        }),
        json!({
            "agent_room_version": AGENT_ROOM_VERSION,
            "gwt_workbench_version": GWT_WORKBENCH_VERSION,
            "slot_id": "knowledge",
            "role": "knowledge",
            "display_name": "RepoAtlas / HarzvaHub Knowledge",
            "provider_ref": "harvis-local",
            "model_ref": "repoatlas-hub",
            "harness_ref": Value::Null,
            "route_ref": "knowledge.default",
            "execution_mode": "record_only",
            "status": "idle",
            "permissions": default_slot_permissions(),
            "created_at": moment,
            "updated_at": moment,
            "safety": default_slot_safety()
        }),
        json!({
            "agent_room_version": AGENT_ROOM_VERSION,
            "gwt_workbench_version": GWT_WORKBENCH_VERSION,
            "slot_id": "mail",
            "role": "mail",
            "display_name": "Agent Mail Router",
            "provider_ref": "agent-mail",
            "model_ref": "cxspark-summary",
            "harness_ref": Value::Null,
            "route_ref": "mail.daily-summary",
            "execution_mode": "record_only",
            "status": "idle",
            "permissions": default_slot_permissions(),
            "created_at": moment,
            "updated_at": moment,
            "safety": default_slot_safety()
        }),
    ]
}

fn default_slot_permissions() -> Value {
    json!({
        "model_call": "disabled_until_orchestrator",
        "file_read": "shared_workspace_only",
        "file_write": "approval_or_handoff_required",
        "shell": "approval_or_handoff_required",
        "external_send": "approval_required",
        "memory_adoption": "review_required"
    })
}

fn default_executor_permissions() -> Value {
    json!({
        "model_call": "approval_required",
        "file_read": "shared_workspace_only",
        "file_write": "approval_or_handoff_required",
        "shell": "approval_or_handoff_required",
        "git": "manual_review_required",
        "external_send": "approval_required",
        "memory_adoption": "review_required"
    })
}

fn default_slot_safety() -> Value {
    json!({
        "executes_without_approval": false,
        "adopts_memory_without_review": false,
        "public_network_exposure": false,
        "includes_secrets": false
    })
}

fn agent_room_dir(root: &Path) -> Result<PathBuf> {
    let path = root.join(".harvis/agent-room");
    fs::create_dir_all(&path)?;
    Ok(path)
}

fn participants_path(root: &Path) -> Result<PathBuf> {
    Ok(agent_room_dir(root)?.join("participants.json"))
}

fn handoffs_dir(root: &Path) -> Result<PathBuf> {
    let path = root.join(".harvis/handoffs");
    fs::create_dir_all(&path)?;
    Ok(path)
}

pub(crate) fn jsonl_path(root: &Path, name: &str) -> Result<PathBuf> {
    Ok(agent_room_dir(root)?.join(format!("{name}.jsonl")))
}

pub(crate) fn append_jsonl(path: &Path, item: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all((serde_json::to_string(item)? + "\n").as_bytes())?;
    Ok(())
}

fn read_jsonl(path: &Path, limit: usize) -> Result<Vec<Value>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let lines = fs::read_to_string(path)?;
    Ok(lines
        .lines()
        .rev()
        .take(limit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .collect())
}

fn read_jsonl_forward(path: &Path) -> Result<Vec<Value>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let lines = fs::read_to_string(path)?;
    Ok(lines
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .collect())
}

fn read_participants_file(root: &Path) -> Result<Vec<Value>> {
    let path = participants_path(root)?;
    let Some(value) = read_json(&path) else {
        return Ok(Vec::new());
    };
    Ok(value
        .get("participants")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default())
}

fn write_participants_file(root: &Path, participants: Vec<Value>) -> Result<()> {
    let record_only = participants
        .iter()
        .all(|slot| slot.get("execution_mode").and_then(Value::as_str) != Some("active"));
    write_json(
        &participants_path(root)?,
        &json!({
            "agent_room_version": AGENT_ROOM_VERSION,
            "gwt_workbench_version": GWT_WORKBENCH_VERSION,
            "updated_at": now_rfc3339()?,
            "participants": participants,
            "safety": {
                "record_only": record_only,
                "executes_task": false,
                "memory_adoption_requires_review": true
            }
        }),
    )
}

/// Append one speaker-selection decision record (T308 / ROADMAP v0.46) to
/// `.harvis/agent-room/chair_decisions.jsonl`. Records written here carry
/// `selector_kind`, `route_reason`, `question_id` (explicit null when there is
/// no question context) and `ts`.
pub fn append_chair_decision(root: &Path, record: &Value) -> Result<()> {
    let root = resolve_workspace_root(root)?;
    init_agent_room(&root)?;
    append_jsonl(&jsonl_path(&root, "chair_decisions")?, record)
}

/// Read the most recent chair decision records in chronological order.
pub fn read_chair_decisions(root: &Path, limit: usize) -> Result<Vec<Value>> {
    let root = resolve_workspace_root(root)?;
    read_jsonl(&jsonl_path(&root, "chair_decisions")?, limit)
}

fn normalize_event_kind(event_type: &str) -> String {
    let value = event_type.trim();
    if SUPPORTED_EVENT_KINDS.contains(&value) {
        return value.to_string();
    }
    match value {
        "message.created" => "agent_message",
        "handoff.requested" => "handoff_note",
        "topic.created" => "status_change",
        _ if value.contains("handoff") => "handoff_note",
        _ if value.contains("review") => "review_comment",
        _ if value.contains("decision") => "decision_record",
        _ if value.contains("status") || value.contains("created") || value.contains("cancel") => {
            "status_change"
        }
        _ => "tool_call_summary",
    }
    .to_string()
}

fn validate_handoff_state(state: &str) -> Result<()> {
    if !HANDOFF_STATES.contains(&state) {
        bail!(
            "handoff state must be one of: {}",
            HANDOFF_STATES.join(", ")
        );
    }
    Ok(())
}

fn task_status_for_handoff_state(state: &str) -> &'static str {
    match state {
        "pending_harness" => "in_progress",
        "running" => "in_progress",
        "reviewing" => "reviewing",
        "done" => "done",
        "blocked" => "blocked",
        "cancelled" => "cancelled",
        _ => "",
    }
}

fn task_for_handoff(root: &Path, handoff_id: &str) -> Result<Option<Value>> {
    Ok(list_tasks(root, None, None, 1000)?
        .get("tasks")
        .and_then(Value::as_array)
        .and_then(|tasks| {
            tasks
                .iter()
                .find(|task| task.get("handoff_id").and_then(Value::as_str) == Some(handoff_id))
                .cloned()
        }))
}

fn run_json_path(root: &Path, run_id: &str) -> Result<PathBuf> {
    let candidate = root.join(".harvis/runs").join(format!("{run_id}.json"));
    if !candidate.exists() {
        bail!("run not found: {run_id}");
    }
    Ok(candidate)
}

pub(crate) fn stable_id(prefix: &str, parts: &[&str]) -> Result<String> {
    let timestamp = timestamp_slug(&now_rfc3339()?);
    let body = parts
        .iter()
        .filter(|part| !part.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join("|");
    let digest = Sha256::digest(body.as_bytes())
        .iter()
        .take(5)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(format!("{prefix}_{timestamp}_{digest}"))
}

fn write_json(path: &Path, item: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, serde_json::to_string_pretty(item)? + "\n")?;
    Ok(())
}

fn read_json(path: &Path) -> Option<Value> {
    let text = fs::read_to_string(path).ok()?;
    let value = serde_json::from_str::<Value>(&text).ok()?;
    value.is_object().then_some(value)
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

fn workspace_label(root: &Path) -> String {
    root.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("workspace")
        .to_string()
}

fn safe_token(value: &str, name: &str) -> Result<String> {
    let value = value.trim();
    if value.is_empty() {
        bail!("{name} is required");
    }
    if !value
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.'))
    {
        bail!("{name} may only contain letters, numbers, dash, underscore, or dot");
    }
    Ok(value.chars().take(120).collect())
}

fn safe_text(value: &str, max_chars: usize) -> String {
    value
        .trim()
        .chars()
        .filter(|character| !character.is_control() || matches!(character, '\n' | '\t'))
        .take(max_chars)
        .collect::<String>()
}

fn clean_optional(value: Option<String>) -> Option<String> {
    value
        .map(|value| safe_text(&value, 500))
        .filter(|value| !value.is_empty())
}

fn validate_task_status(status: &str) -> Result<()> {
    if !TASK_STATUSES.contains(&status) {
        bail!("task status must be one of: {}", TASK_STATUSES.join(", "));
    }
    Ok(())
}

fn value_str(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn latest_time(value: &Value) -> String {
    value_str(value, "updated_at")
        .is_empty()
        .then(|| value_str(value, "created_at"))
        .unwrap_or_else(|| value_str(value, "updated_at"))
}

fn waiting_approval_queue(open_tasks: &[Value], approvals: &[Value], limit: usize) -> Vec<Value> {
    open_tasks
        .iter()
        .filter(|task| task.get("status").and_then(Value::as_str) == Some("waiting_approval"))
        .take(limit)
        .map(|task| {
            let task_id = task.get("task_id").cloned().unwrap_or(Value::Null);
            let approval_id = task.get("approval_id").cloned().unwrap_or(Value::Null);
            let run_id = task.get("run_id").cloned().unwrap_or(Value::Null);
            let packet_id = task.get("packet_id").cloned().unwrap_or(Value::Null);
            let matched_approval = approvals
                .iter()
                .find(|approval| approval_matches_task(approval, task));
            let approval_status = matched_approval
                .and_then(|approval| approval.get("status").and_then(Value::as_str))
                .unwrap_or("missing");
            let has_pending_approval = approval_status == "pending";
            let has_approved_approval = approval_status == "approved";
            let has_handoff = task
                .get("handoff_id")
                .and_then(Value::as_str)
                .is_some_and(|id| !id.is_empty());
            let next_action = if has_handoff {
                "monitor_handoff"
            } else if has_approved_approval {
                "request_handoff"
            } else if has_pending_approval {
                "approve_or_reject"
            } else if matches!(approval_status, "denied" | "cancelled") {
                "revise_or_cancel"
            } else {
                "request_approval"
            };
            json!({
                "queue_item_type": "task_waiting_approval",
                "task_id": task_id,
                "title": task.get("title").cloned().unwrap_or(Value::Null),
                "owner_slot_id": task.get("owner_slot_id").cloned().unwrap_or(Value::Null),
                "topic_id": task.get("topic_id").cloned().unwrap_or(Value::Null),
                "source_event_id": task.get("source_event_id").cloned().unwrap_or(Value::Null),
                "approval_id": approval_id,
                "handoff_id": task.get("handoff_id").cloned().unwrap_or(Value::Null),
                "run_id": run_id,
                "packet_id": packet_id,
                "created_at": task.get("created_at").cloned().unwrap_or(Value::Null),
                "updated_at": task.get("updated_at").cloned().unwrap_or(Value::Null),
                "status": "waiting_approval",
                "has_pending_approval": has_pending_approval,
                "has_approved_approval": has_approved_approval,
                "approval_status": approval_status,
                "matched_approval_id": matched_approval
                    .and_then(|approval| approval.get("approval_id"))
                    .cloned()
                    .unwrap_or(Value::Null),
                "next_action": next_action,
                "safety": {"executes_task": false, "projection_only": true}
            })
        })
        .collect()
}

fn approval_matches_task(approval: &Value, task: &Value) -> bool {
    let task_approval_id = task.get("approval_id").and_then(Value::as_str);
    if task_approval_id
        .is_some_and(|id| approval.get("approval_id").and_then(Value::as_str) == Some(id))
    {
        return true;
    }
    let task_run_id = task.get("run_id").and_then(Value::as_str);
    if task_run_id.is_some_and(|id| approval.get("run_id").and_then(Value::as_str) == Some(id)) {
        return true;
    }
    let Some(packet_id) = task.get("packet_id").and_then(Value::as_str) else {
        return false;
    };
    approval
        .get("target")
        .and_then(Value::as_str)
        .is_some_and(|target| target.contains(packet_id))
}

fn recent_router_events(root: &Path, limit: usize) -> Result<Vec<Value>> {
    let path = root.join(".harvis/router/events.jsonl");
    let mut events = read_jsonl(&path, limit)?;
    events.reverse();
    Ok(events
        .into_iter()
        .map(|event| {
            json!({
                "event_id": event.get("event_id").cloned().unwrap_or(Value::Null),
                "transport": event.get("transport").cloned().unwrap_or(Value::Null),
                "intent": event.get("intent").cloned().unwrap_or(Value::Null),
                "route_state": event.get("route_state").cloned().unwrap_or(Value::Null),
                "selected_preset": event.get("selected_preset").cloned().unwrap_or(Value::Null),
                "recorded_at": event.get("recorded_at").cloned().unwrap_or(Value::Null),
                "source_event_id": event.get("source_event_id").cloned().unwrap_or(Value::Null),
                "safety": {
                    "redacted_projection": true,
                    "executes_task": false
                }
            })
        })
        .collect())
}

fn memory_candidates_summary(root: &Path) -> Value {
    let index_path = root.join(".harvis/memory/index.json");
    let Some(index) = read_json(&index_path) else {
        return json!({
            "available": false,
            "candidate_count": 0,
            "snapshots": 0,
            "signals": 0,
            "policy": "candidate_only_review_required"
        });
    };
    let snapshot_count = index
        .get("candidate_count")
        .or_else(|| index.get("signal_count"))
        .or_else(|| index.get("candidate_signal_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let workbench_count = index
        .get("workbench_candidates")
        .and_then(|value| value.get("candidate_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    json!({
        "available": true,
        "candidate_count": snapshot_count + workbench_count,
        "snapshots": index.get("snapshot_count").cloned().unwrap_or_else(|| json!(0)),
        "signals": index.get("signal_count").cloned().unwrap_or_else(|| json!(0)),
        "workbench_candidates": index
            .get("workbench_candidates")
            .cloned()
            .unwrap_or_else(|| json!({"candidate_count": 0})),
        "updated_at": index.get("updated_at").cloned().unwrap_or(Value::Null),
        "policy": "candidate_only_review_required"
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::approvals::{create_approval, decide_approval};
    use crate::init::init_workspace;
    use crate::memory::list_memory_candidates;
    use crate::runs::sync_packet_runs;

    #[test]
    fn task_plan_distinguishes_unavailable_and_empty_sources() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-task-plan-unavailable-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);

        let unavailable = task_plan(&root).expect("unavailable task plan");
        assert_eq!(unavailable["schemaVersion"], TASK_PLAN_SCHEMA_VERSION);
        assert_eq!(unavailable["sourceAvailable"], false);
        assert_eq!(unavailable["sourceRevision"], Value::Null);
        assert_eq!(unavailable["isValid"], false);
        assert_eq!(unavailable["invalidRecordCount"], 0);
        assert_eq!(unavailable["tasks"], json!([]));

        let path = root.join(".harvis/agent-room/tasks.jsonl");
        fs::create_dir_all(path.parent().unwrap()).expect("task ledger directory");
        fs::write(&path, "").expect("empty task ledger");
        let empty = task_plan(&root).expect("empty task plan");
        assert_eq!(empty["sourceAvailable"], true);
        assert_eq!(empty["isValid"], true);
        assert_eq!(empty["invalidRecordCount"], 0);
        assert!(empty["sourceRevision"]
            .as_str()
            .is_some_and(|value| value.starts_with("sha256:") && value.len() == 71));
        assert_eq!(empty["tasks"], json!([]));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_plan_folds_status_and_links_and_counts_invalid_rows() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-task-plan-fold-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let path = root.join(".harvis/agent-room/tasks.jsonl");
        fs::create_dir_all(path.parent().unwrap()).expect("task ledger directory");
        let task = json!({
            "record_type": "task",
            "task_id": "task_a",
            "title": "Inspect task source",
            "description": "Read the authoritative ledger.",
            "owner_slot_id": "harvis-chair",
            "status": "pending",
            "source_event_id": "event_a",
            "approval_id": null,
            "handoff_id": null,
            "run_id": null,
            "packet_id": null,
            "updated_at": null,
        });
        let status = json!({
            "record_type": "task_status",
            "task_id": "task_a",
            "status": "in_progress",
            "updated_at": "2026-09-07T01:02:03Z",
        });
        let link = json!({
            "record_type": "task_link",
            "task_id": "task_a",
            "approval_id": "approval_a",
            "handoff_id": null,
            "run_id": "run_a",
            "packet_id": "packet_a",
            "status": "done",
            "updated_at": "2026-09-07T01:03:03Z",
        });
        let contents = format!(
            "{}\n{}\n{}\nnot-json\n",
            serde_json::to_string(&task).unwrap(),
            serde_json::to_string(&status).unwrap(),
            serde_json::to_string(&link).unwrap(),
        );
        fs::write(&path, contents).expect("task ledger");

        let first = task_plan(&root).expect("task plan");
        assert_eq!(first["sourceAvailable"], true);
        assert_eq!(first["isValid"], false);
        assert_eq!(first["invalidRecordCount"], 1);
        assert_eq!(first["tasks"].as_array().unwrap().len(), 1);
        let projected = &first["tasks"][0];
        assert_eq!(projected["taskId"], "task_a");
        assert_eq!(projected["owner"], "harvis-chair");
        assert_eq!(projected["status"], "done");
        assert_eq!(projected["updatedAt"], "2026-09-07T01:03:03Z");
        assert_eq!(
            projected["evidence"],
            json!([
                {"kind": "source_event_id", "id": "event_a"},
                {"kind": "approval_id", "id": "approval_a"},
                {"kind": "run_id", "id": "run_a"},
                {"kind": "packet_id", "id": "packet_a"},
            ])
        );
        let second = task_plan(&root).expect("task plan again");
        assert_eq!(first["sourceRevision"], second["sourceRevision"]);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn records_topic_message_and_handoff() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-rust-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let topic = create_topic(&root, "Test topic", "Goal", "test").expect("topic");
        let topic_id = topic["topic_id"].as_str().unwrap();
        add_message(
            &root,
            topic_id,
            "harvis",
            "coordinator",
            "hello",
            Vec::new(),
            "internal",
            None,
        )
        .expect("message");
        let listed = list_agent_room(&root, 50).expect("list");
        assert_eq!(listed["topics"].as_array().unwrap().len(), 1);
        let event = listed["events"].as_array().unwrap().last().unwrap();
        assert_eq!(event["event_kind"], "agent_message");
        assert_eq!(event["protocol"]["id"], AGENT_ROOM_PROTOCOL_ID);
        let packet = root.join(".harvis/outbox/abc123.md");
        fs::write(&packet, "# H.A.R.V.I.S. Work Packet abc123\n\nStatus: new\nSource: .harvis/inbox.md:1\nSafety: ok\n").expect("packet");
        sync_packet_runs(&root, Some(vec![packet]), 500).expect("sync");
        let handoff = request_handoff(
            &root,
            "run_abc123",
            "codex",
            "inspect",
            Some(topic_id),
            "test",
        )
        .expect("handoff");
        assert_eq!(handoff["handoff"]["state"], "pending_harness");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn handoff_contract_includes_cost_usage_verification() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-handoff-contract-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");
        let packet = root.join(".harvis/outbox/contract.md");
        fs::write(
            &packet,
            "# H.A.R.V.I.S. Work Packet contract\n\nStatus: new\n",
        )
        .expect("packet");
        sync_packet_runs(&root, Some(vec![packet]), 500).expect("sync");
        let handoff = request_handoff(
            &root,
            "run_contract",
            "codex",
            "inspect",
            Some("gwt-workbench"),
            "test",
        )
        .expect("handoff");
        let record = &handoff["handoff"];
        assert_eq!(record["handoff_version"], HANDOFF_VERSION);
        // New contract fields are present with explicit nulls (no token
        // statistics exist at request time) and verification=not_started.
        assert_eq!(
            record["cost"],
            json!({"currency": null, "amount": null, "pricing_source": null})
        );
        assert_eq!(
            record["usage"],
            json!({
                "input_tokens": null,
                "output_tokens": null,
                "model_route": null,
                "provider": null
            })
        );
        assert_eq!(
            record["verification"],
            json!({"status": "not_started", "evidence_refs": [], "verified_at": null})
        );
        // The on-disk JSON round-trips through the typed contract view.
        let path = root
            .join(".harvis/handoffs")
            .join(format!("{}.json", record["handoff_id"].as_str().unwrap()));
        let text = fs::read_to_string(path).expect("handoff file");
        let parsed = parse_handoff_record(&text).expect("parse new handoff");
        assert_eq!(parsed.handoff_version, HANDOFF_VERSION);
        assert_eq!(parsed.cost, HandoffCost::default());
        assert_eq!(parsed.usage, HandoffUsage::default());
        assert_eq!(parsed.verification, HandoffVerification::default());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn handoff_legacy_record_deserializes_with_defaults() {
        // Legacy v0.16-alpha shape (19 keys, no cost/usage/verification).
        let legacy = json!({
            "handoff_version": "v0.16-alpha",
            "handoff_id": "handoff_20260630T054753Z_5d38d2a23c",
            "run_id": "run_faf6b3c895e8",
            "packet_id": "faf6b3c895e8",
            "packet_path": ".harvis/outbox/faf6b3c895e8.md",
            "topic_id": "gwt-workbench",
            "harness": "codex",
            "state": "reviewing",
            "instruction": "inspect",
            "requested_by": "harvis",
            "created_at": "2026-06-30T05:47:53.832582Z",
            "updated_at": "2026-06-30T05:48:10.000000Z",
            "updated_by": "feishu:om_x100b6b01c6a994e0c393d8ea49a0cd2",
            "summary": "legacy handoff",
            "result_path": ".harvis/executions/legacy/final.md",
            "exit_code": 0,
            "history": [],
            "safety": {
                "executes_task": false,
                "requires_harness": true,
                "requires_human_review_for_mutation": true
            },
            "next": {"summary": "legacy"}
        });
        let text = serde_json::to_string_pretty(&legacy).expect("serialize legacy");
        let parsed = parse_handoff_record(&text).expect("legacy handoff must parse");
        assert_eq!(parsed.handoff_version, "v0.16-alpha");
        assert_eq!(parsed.cost, HandoffCost::default());
        assert_eq!(parsed.usage, HandoffUsage::default());
        assert_eq!(
            parsed.verification.status,
            HandoffVerificationStatus::NotStarted
        );
        assert!(parsed.verification.evidence_refs.is_empty());
        assert_eq!(parsed.verification.verified_at, None);
        // Extra legacy keys are preserved, not dropped.
        assert!(parsed.extra.contains_key("history"));
        assert!(parsed.extra.contains_key("safety"));
    }

    #[test]
    fn handoff_verification_status_enum_values() {
        for (text, expected) in [
            ("not_started", HandoffVerificationStatus::NotStarted),
            ("passed", HandoffVerificationStatus::Passed),
            ("failed", HandoffVerificationStatus::Failed),
            ("skipped", HandoffVerificationStatus::Skipped),
        ] {
            let parsed: HandoffVerificationStatus =
                serde_json::from_str(&format!("\"{text}\"")).expect("status parses");
            assert_eq!(parsed, expected);
            assert_eq!(
                serde_json::to_string(&parsed).expect("status serializes"),
                format!("\"{text}\"")
            );
        }
        assert!(serde_json::from_str::<HandoffVerificationStatus>("\"verified\"").is_err());
        // Contract constant stays in sync with the enum.
        assert_eq!(
            HANDOFF_VERIFICATION_STATUSES,
            &["not_started", "passed", "failed", "skipped"]
        );
    }

    #[test]
    fn handoff_status_update_records_cost_usage_verification() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-handoff-usage-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");
        let packet = root.join(".harvis/outbox/usagefill.md");
        fs::write(
            &packet,
            "# H.A.R.V.I.S. Work Packet usagefill\n\nStatus: new\n",
        )
        .expect("packet");
        sync_packet_runs(&root, Some(vec![packet]), 500).expect("sync");
        let handoff = request_handoff(
            &root,
            "run_usagefill",
            "codex",
            "inspect",
            Some("gwt-workbench"),
            "test",
        )
        .expect("handoff");
        let handoff_id = handoff["handoff"]["handoff_id"].as_str().unwrap();
        let updated = update_handoff_status(
            &root,
            HandoffStatusInput {
                handoff_id: handoff_id.to_string(),
                state: "reviewing".to_string(),
                summary: Some("Adapter reported usage.".to_string()),
                updated_by: Some("unit-test".to_string()),
                usage: Some(HandoffUsage {
                    input_tokens: Some(112_544),
                    output_tokens: Some(3_096),
                    model_route: Some("codex.default".to_string()),
                    provider: Some("openai".to_string()),
                }),
                cost: Some(HandoffCost {
                    currency: Some("USD".to_string()),
                    amount: Some(0.42),
                    pricing_source: Some("adapter_reported".to_string()),
                }),
                verification: Some(HandoffVerification {
                    status: HandoffVerificationStatus::Passed,
                    evidence_refs: vec![".harvis/executions/test/final.md".to_string()],
                    verified_at: Some("2026-07-18T00:00:00Z".to_string()),
                }),
                ..HandoffStatusInput::default()
            },
        )
        .expect("update");
        let record = &updated["handoff"];
        assert_eq!(record["usage"]["input_tokens"], json!(112_544));
        assert_eq!(record["usage"]["output_tokens"], json!(3_096));
        assert_eq!(record["usage"]["model_route"], json!("codex.default"));
        assert_eq!(record["usage"]["provider"], json!("openai"));
        assert_eq!(record["cost"]["currency"], json!("USD"));
        assert_eq!(record["cost"]["amount"], json!(0.42));
        assert_eq!(record["cost"]["pricing_source"], json!("adapter_reported"));
        assert_eq!(record["verification"]["status"], json!("passed"));
        assert_eq!(
            record["verification"]["evidence_refs"],
            json!([".harvis/executions/test/final.md"])
        );
        assert_eq!(
            record["verification"]["verified_at"],
            json!("2026-07-18T00:00:00Z")
        );
        // Persisted file parses back into the typed view with real values.
        let path = root
            .join(".harvis/handoffs")
            .join(format!("{handoff_id}.json"));
        let text = fs::read_to_string(path).expect("handoff file");
        let parsed = parse_handoff_record(&text).expect("parse updated handoff");
        assert_eq!(parsed.usage.input_tokens, Some(112_544));
        assert_eq!(
            parsed.verification.status,
            HandoffVerificationStatus::Passed
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn handoff_status_updates_task_and_memory_candidate() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-handoff-status-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");
        let packet = root.join(".harvis/outbox/handoffstatus.md");
        fs::write(
            &packet,
            "# H.A.R.V.I.S. Work Packet handoffstatus\n\nStatus: new\n",
        )
        .expect("packet");
        sync_packet_runs(&root, Some(vec![packet]), 500).expect("sync");
        let handoff = request_handoff(
            &root,
            "run_handoffstatus",
            "codex",
            "inspect",
            Some("gwt-workbench"),
            "test",
        )
        .expect("handoff");
        let handoff_id = handoff["handoff"]["handoff_id"].as_str().unwrap();
        let task = create_task(
            &root,
            TaskInput {
                title: "Review handoff status".to_string(),
                owner_slot_id: "executor".to_string(),
                status: Some("in_progress".to_string()),
                handoff_id: Some(handoff_id.to_string()),
                run_id: Some("run_handoffstatus".to_string()),
                packet_id: Some("handoffstatus".to_string()),
                ..TaskInput::default()
            },
        )
        .expect("task");

        let reviewing = update_handoff_status(
            &root,
            HandoffStatusInput {
                handoff_id: handoff_id.to_string(),
                state: "reviewing".to_string(),
                summary: Some("Harness produced a reviewable result.".to_string()),
                updated_by: Some("unit-test".to_string()),
                result_path: Some(".harvis/executions/test/final.md".to_string()),
                exit_code: Some(0),
                ..HandoffStatusInput::default()
            },
        )
        .expect("reviewing");
        assert_eq!(reviewing["handoff"]["state"], "reviewing");
        let tasks = list_tasks(&root, None, None, 20).expect("tasks");
        let task_id = task["task_id"].as_str().unwrap();
        let latest = tasks["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["task_id"] == task_id)
            .unwrap();
        assert_eq!(latest["status"], "reviewing");

        update_handoff_status(
            &root,
            HandoffStatusInput {
                handoff_id: handoff_id.to_string(),
                state: "done".to_string(),
                summary: Some("Reviewer accepted the result.".to_string()),
                updated_by: Some("unit-test".to_string()),
                ..HandoffStatusInput::default()
            },
        )
        .expect("done");
        let tasks = list_tasks(&root, None, None, 20).expect("tasks done");
        let latest = tasks["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["task_id"] == task_id)
            .unwrap();
        assert_eq!(latest["status"], "done");
        let candidates = list_memory_candidates(&root, 50).expect("candidates");
        assert!(candidates["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .any(|candidate| candidate["source_id"] == handoff_id));
        let state = workspace_state(&root, None, 20).expect("workspace state");
        assert!(state["recent_handoffs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["handoff_id"] == handoff_id && item["state"] == "done"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn finalize_handoff_review_accepts_only_reviewing_handoffs() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-handoff-review-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");
        let packet = root.join(".harvis/outbox/reviewdone.md");
        fs::write(
            &packet,
            "# H.A.R.V.I.S. Work Packet reviewdone\n\nStatus: new\n",
        )
        .expect("packet");
        sync_packet_runs(&root, Some(vec![packet]), 500).expect("sync");
        let handoff = request_handoff(
            &root,
            "run_reviewdone",
            "codex",
            "inspect",
            Some("gwt-workbench"),
            "test",
        )
        .expect("handoff");
        let handoff_id = handoff["handoff"]["handoff_id"].as_str().unwrap();
        let task = create_task(
            &root,
            TaskInput {
                title: "Review and close handoff".to_string(),
                owner_slot_id: "reviewer".to_string(),
                status: Some("in_progress".to_string()),
                handoff_id: Some(handoff_id.to_string()),
                run_id: Some("run_reviewdone".to_string()),
                packet_id: Some("reviewdone".to_string()),
                ..TaskInput::default()
            },
        )
        .expect("task");

        let early = finalize_handoff_review(
            &root,
            HandoffReviewInput {
                handoff_id: handoff_id.to_string(),
                decision: "approve".to_string(),
                reviewer: Some("unit-reviewer".to_string()),
                notes: Some("too early".to_string()),
            },
        );
        assert!(early.is_err());

        update_handoff_status(
            &root,
            HandoffStatusInput {
                handoff_id: handoff_id.to_string(),
                state: "reviewing".to_string(),
                summary: Some("Harness produced result.".to_string()),
                updated_by: Some("unit-test".to_string()),
                result_path: Some(".harvis/executions/test/final.md".to_string()),
                exit_code: Some(0),
                ..HandoffStatusInput::default()
            },
        )
        .expect("reviewing");

        let reviewed = finalize_handoff_review(
            &root,
            HandoffReviewInput {
                handoff_id: handoff_id.to_string(),
                decision: "approve".to_string(),
                reviewer: Some("unit-reviewer".to_string()),
                notes: Some("accepted".to_string()),
            },
        )
        .expect("review accepted");
        assert_eq!(reviewed["handoff"]["state"], "done");
        assert_eq!(reviewed["task"]["task_id"], task["task_id"]);
        let tasks = list_tasks(&root, None, None, 20).expect("tasks");
        let task_id = task["task_id"].as_str().unwrap();
        let latest = tasks["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["task_id"] == task_id)
            .unwrap();
        assert_eq!(latest["status"], "done");
        let candidates = list_memory_candidates(&root, 50).expect("candidates");
        let source_ids = candidates["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|candidate| candidate["source_id"].as_str())
            .collect::<Vec<_>>();
        assert!(source_ids.contains(&handoff_id));
        assert!(source_ids.contains(&task_id));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn finalize_handoff_review_reject_blocks_task() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-handoff-review-reject-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");
        let packet = root.join(".harvis/outbox/reviewblocked.md");
        fs::write(
            &packet,
            "# H.A.R.V.I.S. Work Packet reviewblocked\n\nStatus: new\n",
        )
        .expect("packet");
        sync_packet_runs(&root, Some(vec![packet]), 500).expect("sync");
        let handoff = request_handoff(
            &root,
            "run_reviewblocked",
            "codex",
            "inspect",
            Some("gwt-workbench"),
            "test",
        )
        .expect("handoff");
        let handoff_id = handoff["handoff"]["handoff_id"].as_str().unwrap();
        let task = create_task(
            &root,
            TaskInput {
                title: "Reject handoff".to_string(),
                owner_slot_id: "reviewer".to_string(),
                status: Some("in_progress".to_string()),
                handoff_id: Some(handoff_id.to_string()),
                run_id: Some("run_reviewblocked".to_string()),
                packet_id: Some("reviewblocked".to_string()),
                ..TaskInput::default()
            },
        )
        .expect("task");
        update_handoff_status(
            &root,
            HandoffStatusInput {
                handoff_id: handoff_id.to_string(),
                state: "reviewing".to_string(),
                summary: Some("Harness produced result.".to_string()),
                updated_by: Some("unit-test".to_string()),
                ..HandoffStatusInput::default()
            },
        )
        .expect("reviewing");
        let reviewed = finalize_handoff_review(
            &root,
            HandoffReviewInput {
                handoff_id: handoff_id.to_string(),
                decision: "needs_revision".to_string(),
                reviewer: Some("unit-reviewer".to_string()),
                notes: Some("needs another pass".to_string()),
            },
        )
        .expect("review rejected");
        assert_eq!(reviewed["handoff"]["state"], "blocked");
        let tasks = list_tasks(&root, None, None, 20).expect("tasks");
        let task_id = task["task_id"].as_str().unwrap();
        let latest = tasks["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["task_id"] == task_id)
            .unwrap();
        assert_eq!(latest["status"], "blocked");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn records_gwt_workbench_slots_mailbox_tasks() {
        let root =
            std::env::temp_dir().join(format!("harvis-agent-room-gwt-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");

        let participants = list_participants(&root, None).expect("participants");
        assert_eq!(participants["participant_count"], 6);
        assert!(participants["participants"]
            .as_array()
            .unwrap()
            .iter()
            .any(|slot| slot["slot_id"] == "harvis-chair"));

        let task = create_task(
            &root,
            TaskInput {
                title: "Check shared workbench".to_string(),
                owner_slot_id: "planner".to_string(),
                status: Some("pending".to_string()),
                ..TaskInput::default()
            },
        )
        .expect("task");
        let task_id = task["task_id"].as_str().unwrap().to_string();
        update_task_status(&root, &task_id, "in_progress", "claimed").expect("task status");
        let tasks = list_tasks(&root, None, None, 20).expect("tasks");
        assert_eq!(tasks["tasks"][0]["status"], "in_progress");

        let mail = create_mailbox_item(
            &root,
            MailboxInput {
                from_slot_id: "planner".to_string(),
                to_slot_id: "reviewer".to_string(),
                kind: "request".to_string(),
                subject: "Review task".to_string(),
                content: "Please review the shared task board.".to_string(),
                task_id: Some(task_id),
                ..MailboxInput::default()
            },
        )
        .expect("mail");
        let mail_id = mail["mail_id"].as_str().unwrap().to_string();
        let unread = list_mailbox(&root, None, Some("unread"), 20).expect("unread");
        assert_eq!(unread["item_count"], 1);
        let wake = wake_mailbox_item(&root, &mail_id, "reviewer", "unit_test").expect("wake");
        assert_eq!(wake["record_type"], "mailbox_wake");
        assert_eq!(wake["mail_id"], mail_id);
        let consume = consume_mailbox_loop(&root, "reviewer", None, 20, 2, false).expect("consume");
        assert_eq!(consume["record_type"], "mailbox_consume_loop_result");
        assert_eq!(consume["batch_count"], 1);
        assert_eq!(consume["total_consumed_count"], 1);
        let unread = list_mailbox(&root, None, Some("unread"), 20).expect("unread after");
        assert_eq!(unread["item_count"], 0);
        let wakes = read_jsonl_forward(&jsonl_path(&root, "mailbox_wakes").expect("wake path"))
            .expect("wakes");
        assert!(wakes
            .iter()
            .any(|item| item.get("mail_id").and_then(Value::as_str) == Some(mail_id.as_str())));

        let state = workspace_state(&root, None, 20).expect("workspace state");
        assert_eq!(state["chair_slot"]["slot_id"], "harvis-chair");
        assert_eq!(state["open_tasks"].as_array().unwrap().len(), 1);
        assert_eq!(state["rules"]["memory_adoption_requires_review"], true);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn records_and_projects_conversation_state() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-conversation-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");

        record_conversation_state(
            &root,
            ConversationInput {
                transport: "feishu".to_string(),
                chat_id: Some("chat-a".to_string()),
                sender: Some("user-a".to_string()),
                message_id: Some("msg-1".to_string()),
                intent: Some("task_enqueue".to_string()),
                route_state: Some("waiting_approval".to_string()),
                task_id: Some("task-a".to_string()),
                packet_id: Some("packet-a".to_string()),
                run_id: Some("run_packet-a".to_string()),
                summary: Some("Task enqueued: inspect just-ddl".to_string()),
                ..ConversationInput::default()
            },
        )
        .expect("record first");
        record_conversation_state(
            &root,
            ConversationInput {
                transport: "feishu".to_string(),
                chat_id: Some("chat-a".to_string()),
                sender: Some("user-a".to_string()),
                message_id: Some("msg-2".to_string()),
                intent: Some("status_query".to_string()),
                route_state: Some("status".to_string()),
                task_id: Some("task-a".to_string()),
                packet_id: Some("packet-a".to_string()),
                summary: Some("Status query projected.".to_string()),
                ..ConversationInput::default()
            },
        )
        .expect("record second");

        let context = recent_conversation_context(&root, "feishu", Some("chat-a"), Some("user-a"))
            .expect("context")
            .expect("some context");
        assert_eq!(
            context["conversation_id"]
                .as_str()
                .unwrap()
                .starts_with("conv_"),
            true
        );
        assert_eq!(context["message_id"], "msg-2");
        assert_eq!(context["packet_id"], "packet-a");
        let conversations = list_conversations(&root, Some("feishu"), Some("chat-a"), None, 10)
            .expect("conversations");
        assert_eq!(conversations["conversation_count"], 1);
        let state = workspace_state(&root, None, 20).expect("workspace state");
        assert_eq!(state["recent_conversations"][0]["packet_id"], "packet-a");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn sender_only_conversation_context_fails_closed_when_ambiguous() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-conversation-ambiguous-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");

        for (chat_id, packet_id) in [("chat-a", "packet-a"), ("chat-b", "packet-b")] {
            record_conversation_state(
                &root,
                ConversationInput {
                    transport: "feishu".to_string(),
                    chat_id: Some(chat_id.to_string()),
                    sender: Some("same-user".to_string()),
                    intent: Some("task_enqueue".to_string()),
                    route_state: Some("waiting_approval".to_string()),
                    packet_id: Some(packet_id.to_string()),
                    summary: Some(format!("Task enqueued: {packet_id}")),
                    ..ConversationInput::default()
                },
            )
            .expect("record");
        }

        let inferred =
            recent_conversation_context(&root, "feishu", None, Some("same-user")).expect("context");
        assert!(inferred.is_none());
        let explicit =
            recent_conversation_context(&root, "feishu", Some("chat-b"), Some("same-user"))
                .expect("explicit context")
                .expect("explicit context item");
        assert_eq!(explicit["packet_id"], "packet-b");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn workspace_state_projects_waiting_approval_queue() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-room-approval-queue-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        init_agent_room(&root).expect("agent-room");

        let task = create_task(
            &root,
            TaskInput {
                title: "Inspect just-ddl failure".to_string(),
                owner_slot_id: "planner".to_string(),
                status: Some("waiting_approval".to_string()),
                packet_id: Some("c3643ec6564c".to_string()),
                source_event_id: Some("feishu-test-message".to_string()),
                ..TaskInput::default()
            },
        )
        .expect("task");
        let state = workspace_state(&root, None, 20).expect("workspace state");
        let queue = state["waiting_approval_queue"].as_array().unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0]["queue_item_type"], "task_waiting_approval");
        assert_eq!(queue[0]["task_id"], task["task_id"]);
        assert_eq!(queue[0]["packet_id"], "c3643ec6564c");
        assert_eq!(queue[0]["next_action"], "request_approval");
        assert_eq!(queue[0]["safety"]["projection_only"], true);

        let approval = create_approval(
            &root,
            "run_c3643ec6564c",
            "run_command",
            "codex exec .harvis/outbox/c3643ec6564c.md",
            "Request controlled execution for test task.",
            "medium",
            "one_time",
        )
        .expect("approval");
        link_task(
            &root,
            TaskLinkInput {
                task_id: task["task_id"].as_str().unwrap().to_string(),
                approval_id: Some(approval["approval_id"].as_str().unwrap().to_string()),
                run_id: Some("run_c3643ec6564c".to_string()),
                packet_id: Some("c3643ec6564c".to_string()),
                status: Some("waiting_approval".to_string()),
                note: Some("approval requested".to_string()),
                ..TaskLinkInput::default()
            },
        )
        .expect("link");
        let state = workspace_state(&root, None, 20).expect("workspace state after approval");
        let queue = state["waiting_approval_queue"].as_array().unwrap();
        assert_eq!(queue[0]["has_pending_approval"], true);
        assert_eq!(queue[0]["approval_status"], "pending");
        assert_eq!(queue[0]["next_action"], "approve_or_reject");

        decide_approval(
            &root,
            approval["approval_id"].as_str().unwrap(),
            "approved",
            "test",
            "approved in test",
        )
        .expect("decide");
        let state = workspace_state(&root, None, 20).expect("workspace state after decision");
        let queue = state["waiting_approval_queue"].as_array().unwrap();
        assert_eq!(queue[0]["has_approved_approval"], true);
        assert_eq!(queue[0]["approval_status"], "approved");
        assert_eq!(queue[0]["next_action"], "request_handoff");

        link_task(
            &root,
            TaskLinkInput {
                task_id: task["task_id"].as_str().unwrap().to_string(),
                handoff_id: Some("handoff_test".to_string()),
                run_id: Some("run_c3643ec6564c".to_string()),
                packet_id: Some("c3643ec6564c".to_string()),
                status: Some("in_progress".to_string()),
                note: Some("handoff requested".to_string()),
                ..TaskLinkInput::default()
            },
        )
        .expect("link handoff");
        let state = workspace_state(&root, None, 20).expect("workspace state after handoff");
        assert!(state["waiting_approval_queue"]
            .as_array()
            .unwrap()
            .iter()
            .all(|item| item["task_id"] != task["task_id"]));
        let tasks = list_tasks(&root, None, None, 20).expect("tasks after handoff");
        assert_eq!(tasks["tasks"][0]["status"], "in_progress");
        assert_eq!(tasks["tasks"][0]["handoff_id"], "handoff_test");
        let _ = fs::remove_dir_all(root);
    }
}
