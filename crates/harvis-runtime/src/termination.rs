//! T309 — composable Agent Room termination conditions + first-class
//! approval-pending suspension state (ROADMAP v0.46 stop policy: the room
//! stops only when it reaches a decision, asks the human a concrete question,
//! requests a harness handoff, hits a budget, or records a blocker).
//!
//! Design borrowed from AutoGen `TerminationCondition` combination semantics
//! (`&` / `|` operators, TextMentionTermination / MaxMessageTermination /
//! TimeoutTermination) and from LangGraph `interrupt` human-in-the-loop
//! suspension semantics — design only, no code.
//!
//! Declarative configuration lives in `<root>/.harvis/harvis.toml` under
//! `[agent_room_termination]` (optionally with per-topic overrides under
//! `[agent_room_termination.topics.<topic_id>]`). Conditions compose with
//! `any_of` (OR) and `all_of` (AND), e.g.:
//!
//! ```toml
//! [agent_room_termination]
//! any_of = ["decision_reached", { all_of = [{ max_message = 20 }, { timeout = "600s" }] }]
//! ```
//!
//! or as a JSON string (`config_json = '{"any_of": [...]}'`).
//!
//! Condition kinds: `text_mention` / `max_message` / `timeout` /
//! `approval_pending` / `decision_reached` / `budget_exhausted`. Unknown
//! kinds are reported as configuration errors, never silently ignored.
//!
//! `approval_pending` is special: instead of terminating, the room run moves
//! into the first-class run state `suspended_awaiting_approval` (recorded in
//! the run JSON under `.harvis/runs/` and counted in `.harvis/status.json`
//! via `suspended_run_count`). The next step after the human decides the
//! approval resumes the room (`approved`) or terminates it
//! (`denied`/`cancelled`); every transition is appended to
//! `.harvis/agent-room/chair_decisions.jsonl` with `condition_kind` and the
//! matched details, and mirrored as an Agent Room `status_change` event.

use anyhow::{bail, Context, Result};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime};

use crate::agent_room::{
    add_event_with_metadata, append_chair_decision, list_agent_room, read_chair_decisions,
};
use harvis_core::time::now_rfc3339;

pub const TERMINATION_VERSION: &str = "v0.46-termination-conditions";
pub const TERMINATION_DECISION_SCHEMA: &str = "harvis.chair-decision.v1-termination";

pub const RUN_STATE_RUNNING: &str = "running";
pub const RUN_STATE_SUSPENDED: &str = "suspended_awaiting_approval";
pub const RUN_STATE_TERMINATED: &str = "terminated";

pub const KIND_TEXT_MENTION: &str = "text_mention";
pub const KIND_MAX_MESSAGE: &str = "max_message";
pub const KIND_TIMEOUT: &str = "timeout";
pub const KIND_APPROVAL_PENDING: &str = "approval_pending";
pub const KIND_DECISION_REACHED: &str = "decision_reached";
pub const KIND_BUDGET_EXHAUSTED: &str = "budget_exhausted";
pub const KIND_ALL_OF: &str = "all_of";
pub const KIND_ANY_OF: &str = "any_of";

/// Extra terminal record kind used when a suspended room is terminated by a
/// denied/cancelled human approval decision (not a configurable condition).
pub const KIND_APPROVAL_DENIED: &str = "approval_denied";
/// Record kind used on the resumption chair decision after an approval.
pub const KIND_APPROVAL_RESOLVED: &str = "approval_resolved";

// ---------------------------------------------------------------------------
// Condition tree
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum TerminationCondition {
    TextMention {
        texts: Vec<String>,
    },
    MaxMessage {
        limit: usize,
    },
    Timeout {
        seconds: u64,
    },
    ApprovalPending,
    DecisionReached,
    BudgetExhausted {
        max_steps: Option<usize>,
        max_events: Option<usize>,
    },
    AllOf {
        conditions: Vec<TerminationCondition>,
    },
    AnyOf {
        conditions: Vec<TerminationCondition>,
    },
}

impl TerminationCondition {
    pub fn kind(&self) -> &'static str {
        match self {
            TerminationCondition::TextMention { .. } => KIND_TEXT_MENTION,
            TerminationCondition::MaxMessage { .. } => KIND_MAX_MESSAGE,
            TerminationCondition::Timeout { .. } => KIND_TIMEOUT,
            TerminationCondition::ApprovalPending => KIND_APPROVAL_PENDING,
            TerminationCondition::DecisionReached => KIND_DECISION_REACHED,
            TerminationCondition::BudgetExhausted { .. } => KIND_BUDGET_EXHAUSTED,
            TerminationCondition::AllOf { .. } => KIND_ALL_OF,
            TerminationCondition::AnyOf { .. } => KIND_ANY_OF,
        }
    }
}

// ---------------------------------------------------------------------------
// Configuration (`<root>/.harvis/harvis.toml`, table `[agent_room_termination]`)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
pub struct TerminationConfig {
    pub condition: Option<TerminationCondition>,
    pub topic_overrides: BTreeMap<String, TerminationCondition>,
    pub config_source: String,
    pub config_error: Option<String>,
}

impl TerminationConfig {
    pub fn effective_condition(&self, topic_id: &str) -> Option<&TerminationCondition> {
        self.topic_overrides
            .get(topic_id)
            .or(self.condition.as_ref())
    }

    pub fn configured(&self) -> bool {
        self.condition.is_some() || !self.topic_overrides.is_empty()
    }
}

pub fn load_termination_config(root: &Path) -> TerminationConfig {
    let mut config = TerminationConfig {
        config_source: "default (no [agent_room_termination] table)".to_string(),
        ..TerminationConfig::default()
    };
    let path = root.join(".harvis/harvis.toml");
    let Ok(text) = fs::read_to_string(&path) else {
        return config;
    };
    let Ok(value) = text.parse::<toml::Value>() else {
        config.config_error = Some("harvis.toml is not valid TOML".to_string());
        return config;
    };
    let Some(table) = value
        .get("agent_room_termination")
        .and_then(toml::Value::as_table)
    else {
        return config;
    };
    config.config_source = format!("{} [agent_room_termination]", path.display());
    let json = match serde_json::to_value(table) {
        Ok(json) => json,
        Err(error) => {
            config.config_error = Some(format!(
                "[agent_room_termination] could not be normalized: {error}"
            ));
            return config;
        }
    };
    let Some(map) = json.as_object() else {
        return config;
    };
    match condition_from_table(map) {
        Ok(condition) => config.condition = condition,
        Err(error) => {
            config.config_error = Some(error.to_string());
            return config;
        }
    }
    if let Some(topics) = map.get("topics").and_then(Value::as_object) {
        for (topic_id, spec) in topics {
            let Some(spec_map) = spec.as_object() else {
                config.config_error = Some(format!(
                    "[agent_room_termination.topics.{topic_id}] must be a table"
                ));
                continue;
            };
            match condition_from_table(spec_map) {
                Ok(Some(condition)) => {
                    config.topic_overrides.insert(topic_id.clone(), condition);
                }
                Ok(None) => {}
                Err(error) => {
                    config.config_error = Some(format!(
                        "[agent_room_termination.topics.{topic_id}]: {error}"
                    ));
                }
            }
        }
    }
    config
}

/// Parse a condition table: either an explicit `any_of` / `all_of`
/// combinator, a `config_json` string holding the same grammar in JSON, or
/// one or more leaf keys (multiple leaf keys compose as an implicit
/// `all_of`). Returns Ok(None) when the table carries no condition keys.
fn condition_from_table(map: &Map<String, Value>) -> Result<Option<TerminationCondition>> {
    let reserved = ["topics"];
    if let Some(raw) = map.get("config_json").and_then(Value::as_str) {
        let parsed: Value = serde_json::from_str(raw)
            .context("[agent_room_termination] config_json is not valid JSON")?;
        let parsed_map = parsed
            .as_object()
            .context("[agent_room_termination] config_json must be a JSON object")?;
        return condition_from_table(parsed_map);
    }
    let has_any = map.contains_key(KIND_ANY_OF);
    let has_all = map.contains_key(KIND_ALL_OF);
    if has_any && has_all {
        bail!("use only one of any_of / all_of at the same level");
    }
    if has_any {
        return parse_combinator(KIND_ANY_OF, &map[KIND_ANY_OF]).map(Some);
    }
    if has_all {
        return parse_combinator(KIND_ALL_OF, &map[KIND_ALL_OF]).map(Some);
    }
    let mut leaves = Vec::new();
    for (key, value) in map {
        if reserved.contains(&key.as_str()) {
            continue;
        }
        // boolean-false leaf switches are treated as absent.
        if value.is_boolean() && value.as_bool() == Some(false) {
            continue;
        }
        let single = Map::from_iter([(key.clone(), value.clone())]);
        leaves.push(parse_condition(&Value::Object(single))?);
    }
    Ok(match leaves.len() {
        0 => None,
        1 => leaves.into_iter().next(),
        _ => Some(TerminationCondition::AllOf { conditions: leaves }),
    })
}

fn parse_combinator(kind: &str, value: &Value) -> Result<TerminationCondition> {
    let items = value
        .as_array()
        .with_context(|| format!("{kind} must be an array of conditions"))?;
    if items.is_empty() {
        bail!("{kind} requires at least one condition");
    }
    let mut conditions = Vec::new();
    for item in items {
        conditions.push(parse_condition(item)?);
    }
    Ok(match kind {
        KIND_ALL_OF => TerminationCondition::AllOf { conditions },
        _ => TerminationCondition::AnyOf { conditions },
    })
}

fn parse_condition(value: &Value) -> Result<TerminationCondition> {
    match value {
        Value::String(name) => match name.as_str() {
            KIND_APPROVAL_PENDING => Ok(TerminationCondition::ApprovalPending),
            KIND_DECISION_REACHED => Ok(TerminationCondition::DecisionReached),
            other => bail!(
                "unknown termination condition '{other}' (string form supports only \
                 'approval_pending' and 'decision_reached'; use table form for \
                 text_mention / max_message / timeout / budget_exhausted)"
            ),
        },
        Value::Object(map) => {
            if map.len() != 1 {
                bail!("termination condition table must have exactly one key");
            }
            let (key, spec) = map.iter().next().expect("len checked");
            match key.as_str() {
                KIND_TEXT_MENTION => {
                    let texts = match spec {
                        Value::String(text) => vec![text.clone()],
                        Value::Array(items) => items
                            .iter()
                            .filter_map(|item| item.as_str().map(ToOwned::to_owned))
                            .collect::<Vec<_>>(),
                        _ => bail!("text_mention must be a string or an array of strings"),
                    };
                    let texts = texts
                        .into_iter()
                        .map(|text| text.trim().to_string())
                        .filter(|text| !text.is_empty())
                        .collect::<Vec<_>>();
                    if texts.is_empty() {
                        bail!("text_mention requires at least one non-empty text");
                    }
                    Ok(TerminationCondition::TextMention { texts })
                }
                KIND_MAX_MESSAGE => {
                    let limit = spec
                        .as_u64()
                        .with_context(|| "max_message must be a positive integer")?;
                    if limit == 0 {
                        bail!("max_message must be a positive integer");
                    }
                    Ok(TerminationCondition::MaxMessage {
                        limit: limit as usize,
                    })
                }
                KIND_TIMEOUT => {
                    let seconds = parse_timeout_seconds(spec)?;
                    Ok(TerminationCondition::Timeout { seconds })
                }
                KIND_APPROVAL_PENDING => Ok(TerminationCondition::ApprovalPending),
                KIND_DECISION_REACHED => Ok(TerminationCondition::DecisionReached),
                KIND_BUDGET_EXHAUSTED => {
                    let table = spec
                        .as_object()
                        .with_context(|| "budget_exhausted must be a table")?;
                    let max_steps = table
                        .get("max_steps")
                        .and_then(Value::as_u64)
                        .map(|value| value as usize);
                    let max_events = table
                        .get("max_events")
                        .and_then(Value::as_u64)
                        .map(|value| value as usize);
                    if max_steps.is_none() && max_events.is_none() {
                        bail!("budget_exhausted requires max_steps and/or max_events");
                    }
                    Ok(TerminationCondition::BudgetExhausted {
                        max_steps,
                        max_events,
                    })
                }
                KIND_ALL_OF | KIND_ANY_OF => parse_combinator(key, spec),
                other => bail!("unknown termination condition kind '{other}'"),
            }
        }
        _ => bail!("termination condition must be a string or a table"),
    }
}

fn parse_timeout_seconds(spec: &Value) -> Result<u64> {
    if let Some(seconds) = spec.as_u64() {
        if seconds == 0 {
            bail!("timeout must be positive");
        }
        return Ok(seconds);
    }
    let Some(text) = spec.as_str() else {
        bail!("timeout must be seconds (integer) or a duration string like \"600s\"");
    };
    let text = text.trim().to_ascii_lowercase();
    let (digits, factor) = match text.strip_suffix('s') {
        Some(rest) => (rest, 1),
        None => match text.strip_suffix('m') {
            Some(rest) => (rest, 60),
            None => match text.strip_suffix('h') {
                Some(rest) => (rest, 3600),
                None => (text.as_str(), 1),
            },
        },
    };
    let base: u64 = digits
        .trim()
        .parse()
        .with_context(|| format!("timeout duration '{text}' is not a number of seconds"))?;
    let seconds = base.saturating_mul(factor);
    if seconds == 0 {
        bail!("timeout must be positive");
    }
    Ok(seconds)
}

// ---------------------------------------------------------------------------
// Room state snapshot + condition evaluation
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct RoomStateSnapshot {
    pub topic_id: String,
    pub run_id: String,
    pub message_count: usize,
    pub messages: Vec<Value>,
    pub run_created_at: Option<OffsetDateTime>,
    pub now: OffsetDateTime,
    pub decision_event: Option<Value>,
    pub pending_approval_ids: Vec<String>,
    pub speaker_step_count: usize,
    pub topic_event_count: usize,
}

pub fn build_room_snapshot(root: &Path, topic_id: &str, run: &Value) -> Result<RoomStateSnapshot> {
    let run_id = run
        .get("run_id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let room = list_agent_room(root, 500)?;
    let messages: Vec<Value> = room
        .get("messages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|message| message.get("topic_id").and_then(Value::as_str) == Some(topic_id))
        .cloned()
        .collect();
    let events: Vec<Value> = room
        .get("events")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|event| event.get("topic_id").and_then(Value::as_str) == Some(topic_id))
        .cloned()
        .collect();
    let decision_event = events
        .iter()
        .rev()
        .find(|event| event.get("event_kind").and_then(Value::as_str) == Some("decision_record"))
        .cloned();
    let speaker_step_count = read_chair_decisions(root, 500)
        .unwrap_or_default()
        .iter()
        .filter(|record| {
            record.get("topic_id").and_then(Value::as_str) == Some(topic_id)
                && record
                    .get("selected_agent_id")
                    .and_then(Value::as_str)
                    .is_some_and(|value| !value.is_empty())
        })
        .count();
    Ok(RoomStateSnapshot {
        topic_id: topic_id.to_string(),
        run_id: run_id.clone(),
        message_count: messages.len(),
        messages,
        run_created_at: run
            .get("created_at")
            .and_then(Value::as_str)
            .and_then(parse_rfc3339),
        now: OffsetDateTime::now_utc(),
        decision_event,
        pending_approval_ids: pending_approval_ids_for_run(root, &run_id)?,
        speaker_step_count,
        topic_event_count: events.len(),
    })
}

/// Evaluate one condition against the room snapshot. Returns Some(detail)
/// when the condition matches; the detail always carries `kind` plus
/// condition-specific matched evidence.
pub fn evaluate_condition(
    condition: &TerminationCondition,
    snapshot: &RoomStateSnapshot,
) -> Option<Value> {
    match condition {
        TerminationCondition::TextMention { texts } => {
            for message in &snapshot.messages {
                let content = message
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                for text in texts {
                    if content.contains(&text.to_ascii_lowercase()) {
                        return Some(json!({
                            "kind": KIND_TEXT_MENTION,
                            "text": text,
                            "message_id": message.get("message_id").cloned().unwrap_or(Value::Null),
                            "agent_id": message.get("agent_id").cloned().unwrap_or(Value::Null),
                            "excerpt": truncate(content.trim(), 200)
                        }));
                    }
                }
            }
            None
        }
        TerminationCondition::MaxMessage { limit } => {
            if snapshot.message_count >= *limit {
                Some(json!({
                    "kind": KIND_MAX_MESSAGE,
                    "limit": limit,
                    "message_count": snapshot.message_count
                }))
            } else {
                None
            }
        }
        TerminationCondition::Timeout { seconds } => {
            let started = snapshot.run_created_at?;
            let elapsed = snapshot.now - started;
            if elapsed >= Duration::seconds(*seconds as i64) {
                Some(json!({
                    "kind": KIND_TIMEOUT,
                    "timeout_seconds": seconds,
                    "elapsed_seconds": elapsed.whole_seconds(),
                    "run_created_at": started.format(&Rfc3339).ok()
                }))
            } else {
                None
            }
        }
        TerminationCondition::ApprovalPending => {
            if snapshot.pending_approval_ids.is_empty() {
                None
            } else {
                Some(json!({
                    "kind": KIND_APPROVAL_PENDING,
                    "pending_approval_ids": snapshot.pending_approval_ids
                }))
            }
        }
        TerminationCondition::DecisionReached => snapshot.decision_event.as_ref().map(|event| {
            json!({
                "kind": KIND_DECISION_REACHED,
                "event_id": event.get("event_id").cloned().unwrap_or(Value::Null),
                "excerpt": truncate(
                    event.get("content").and_then(Value::as_str).unwrap_or_default(),
                    200
                )
            })
        }),
        TerminationCondition::BudgetExhausted {
            max_steps,
            max_events,
        } => {
            let steps_exhausted =
                max_steps.is_some_and(|limit| snapshot.speaker_step_count >= limit);
            let events_exhausted =
                max_events.is_some_and(|limit| snapshot.topic_event_count >= limit);
            if steps_exhausted || events_exhausted {
                Some(json!({
                    "kind": KIND_BUDGET_EXHAUSTED,
                    "max_steps": max_steps,
                    "speaker_step_count": snapshot.speaker_step_count,
                    "max_events": max_events,
                    "topic_event_count": snapshot.topic_event_count
                }))
            } else {
                None
            }
        }
        TerminationCondition::AllOf { conditions } => {
            let mut matched = Vec::new();
            for child in conditions {
                matched.push(evaluate_condition(child, snapshot)?);
            }
            Some(json!({
                "kind": KIND_ALL_OF,
                "matched": matched
            }))
        }
        TerminationCondition::AnyOf { conditions } => {
            for (index, child) in conditions.iter().enumerate() {
                if let Some(detail) = evaluate_condition(child, snapshot) {
                    return Some(json!({
                        "kind": KIND_ANY_OF,
                        "matched_index": index,
                        "matched": [detail]
                    }));
                }
            }
            None
        }
    }
}

/// True when any node of the matched tree is an approval_pending match —
/// those matches suspend the run instead of terminating it.
pub fn matched_involves_approval_pending(matched: &Value) -> bool {
    if matched.get("kind").and_then(Value::as_str) == Some(KIND_APPROVAL_PENDING) {
        return true;
    }
    matched
        .get("matched")
        .and_then(Value::as_array)
        .is_some_and(|children| children.iter().any(matched_involves_approval_pending))
}

/// True when any node of the matched tree is a decision_reached match — those
/// terminations mint an immutable T310 decision record snapshot.
pub fn matched_involves_decision_reached(matched: &Value) -> bool {
    if matched.get("kind").and_then(Value::as_str) == Some(KIND_DECISION_REACHED) {
        return true;
    }
    matched
        .get("matched")
        .and_then(Value::as_array)
        .is_some_and(|children| children.iter().any(matched_involves_decision_reached))
}

/// Evaluate the effective configured condition for a topic against the live
/// room state. Returns Ok(None) when nothing is configured or nothing
/// matched.
pub fn evaluate_room_termination(
    root: &Path,
    topic_id: &str,
    config: &TerminationConfig,
) -> Result<Option<Value>> {
    let Some(condition) = config.effective_condition(topic_id) else {
        return Ok(None);
    };
    let run = ensure_room_run(root, topic_id)?;
    let snapshot = build_room_snapshot(root, topic_id, &run)?;
    Ok(evaluate_condition(condition, &snapshot))
}

// ---------------------------------------------------------------------------
// Room run record (first-class states live in `.harvis/runs/<run_id>.json`)
// ---------------------------------------------------------------------------

pub fn room_run_id(topic_id: &str) -> String {
    let sanitized: String = topic_id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '-'
            }
        })
        .collect();
    format!("run_room_{sanitized}")
}

pub fn room_run_path(root: &Path, topic_id: &str) -> PathBuf {
    root.join(".harvis/runs")
        .join(format!("{}.json", room_run_id(topic_id)))
}

pub fn load_room_run(root: &Path, topic_id: &str) -> Result<Option<Value>> {
    Ok(read_json(&room_run_path(root, topic_id)))
}

/// Load the room run, creating a `running` record on first use.
pub fn ensure_room_run(root: &Path, topic_id: &str) -> Result<Value> {
    let path = room_run_path(root, topic_id);
    if let Some(run) = read_json(&path) {
        return Ok(run);
    }
    let moment = now_rfc3339()?;
    let run = json!({
        "run_id": room_run_id(topic_id),
        "kind": "agent_room_run",
        "topic_id": topic_id,
        "state": RUN_STATE_RUNNING,
        "mode": "agent_room",
        "created_at": moment,
        "updated_at": moment,
        "origin": {
            "trigger": "agent_room_step",
            "source": "harvis-runtime/termination"
        },
        "approval": {"required": false, "pending": false, "ids": []},
        "suspension": Value::Null,
        "termination": Value::Null,
        "outputs": {}
    });
    write_json(&path, &run)?;
    Ok(run)
}

pub fn room_run_state(run: &Value) -> &str {
    run.get("state")
        .and_then(Value::as_str)
        .unwrap_or(RUN_STATE_RUNNING)
}

/// Move a room run into `suspended_awaiting_approval`: persist the run JSON,
/// append the suspension chair decision, mirror a room event and refresh the
/// suspended count in status.json.
pub fn suspend_room_run(root: &Path, topic_id: &str, matched: &Value) -> Result<Value> {
    let path = room_run_path(root, topic_id);
    let mut run = match read_json(&path) {
        Some(run) => run,
        None => ensure_room_run(root, topic_id)?,
    };
    if room_run_state(&run) == RUN_STATE_SUSPENDED {
        return Ok(run);
    }
    let moment = now_rfc3339()?;
    let pending_ids = matched
        .get("pending_approval_ids")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    run["state"] = json!(RUN_STATE_SUSPENDED);
    run["suspension"] = json!({
        "reason": KIND_APPROVAL_PENDING,
        "approval_ids": pending_ids,
        "since": moment,
        "matched": matched
    });
    run["updated_at"] = json!(moment);
    write_json(&path, &run)?;
    append_transition_decision(root, topic_id, &run, "suspension", matched)?;
    add_transition_event(root, topic_id, &run, "suspension", matched)?;
    sync_status_suspended_count(root)?;
    Ok(run)
}

/// Resume a suspended room run after the linked approvals were decided
/// without denial.
pub fn resume_room_run(root: &Path, topic_id: &str, note: &str) -> Result<Value> {
    let path = room_run_path(root, topic_id);
    let Some(mut run) = read_json(&path) else {
        bail!("room run not found for resume: {topic_id}");
    };
    let moment = now_rfc3339()?;
    run["state"] = json!(RUN_STATE_RUNNING);
    run["suspension"] = Value::Null;
    run["last_resumption"] = json!({"at": moment, "note": note});
    run["updated_at"] = json!(moment);
    write_json(&path, &run)?;
    let matched = json!({
        "kind": KIND_APPROVAL_RESOLVED,
        "decision": "approved",
        "note": note
    });
    append_transition_decision(root, topic_id, &run, "resumption", &matched)?;
    add_transition_event(root, topic_id, &run, "resumption", &matched)?;
    sync_status_suspended_count(root)?;
    Ok(run)
}

/// Terminate a room run with the matched condition evidence.
pub fn terminate_room_run(root: &Path, topic_id: &str, matched: &Value) -> Result<Value> {
    let path = room_run_path(root, topic_id);
    let mut run = match read_json(&path) {
        Some(run) => run,
        None => ensure_room_run(root, topic_id)?,
    };
    if room_run_state(&run) == RUN_STATE_TERMINATED {
        return Ok(run);
    }
    let moment = now_rfc3339()?;
    run["state"] = json!(RUN_STATE_TERMINATED);
    run["suspension"] = Value::Null;
    run["termination"] = json!({
        "condition_kind": matched.get("kind").cloned().unwrap_or(Value::Null),
        "matched": matched,
        "at": moment
    });
    run["updated_at"] = json!(moment);
    write_json(&path, &run)?;
    // T310: a decision-reached termination (including the human-confirm path,
    // which converges into the same decision_record room event) mints exactly
    // one immutable hash-chained decision snapshot under
    // `.harvis/agent-room/decisions/`. Operational stops (max_message,
    // timeout, budget_exhausted, text_mention, approval_denied) halt the room
    // without a decision, so they deliberately mint nothing. Snapshot
    // failures never block termination; they are recorded on the run instead.
    if matched_involves_decision_reached(matched) {
        match crate::decisions::record_room_decision(root, topic_id, &run, matched) {
            Ok(record) => {
                run["termination"]["decision_record_id"] =
                    record.get("decision_id").cloned().unwrap_or(Value::Null);
                run["termination"]["decision_record_path"] = json!(format!(
                    ".harvis/agent-room/decisions/{}.json",
                    record
                        .get("decision_id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                ));
            }
            Err(error) => {
                run["termination"]["decision_record_error"] = json!(error.to_string());
            }
        }
        write_json(&path, &run)?;
    }
    append_transition_decision(root, topic_id, &run, "termination", matched)?;
    add_transition_event(root, topic_id, &run, "termination", matched)?;
    sync_status_suspended_count(root)?;
    Ok(run)
}

/// Outcome of re-checking a suspended room run's linked approvals.
#[derive(Debug, Clone, PartialEq)]
pub enum SuspensionResolution {
    /// At least one linked approval is still pending: stay suspended.
    StillPending(Vec<String>),
    /// Every linked approval was decided and none denied/cancelled: resume.
    Resume(String),
    /// A linked approval was denied or cancelled: terminate the run.
    Terminate(Value),
}

pub fn resolve_suspension(root: &Path, topic_id: &str) -> Result<SuspensionResolution> {
    let run_id = room_run_id(topic_id);
    let mut pending = Vec::new();
    let mut denied: Option<Value> = None;
    let mut decided = 0usize;
    for approval in approvals_for_run(root, &run_id)? {
        match approval.get("status").and_then(Value::as_str) {
            Some("pending") => {
                if let Some(id) = approval.get("approval_id").and_then(Value::as_str) {
                    pending.push(id.to_string());
                }
            }
            Some("denied") | Some("cancelled") => {
                decided += 1;
                if denied.is_none() {
                    denied = Some(approval);
                }
            }
            Some(_) => decided += 1,
            None => {}
        }
    }
    if !pending.is_empty() {
        pending.sort();
        return Ok(SuspensionResolution::StillPending(pending));
    }
    if let Some(approval) = denied {
        let decision = approval
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("denied")
            .to_string();
        return Ok(SuspensionResolution::Terminate(json!({
            "kind": KIND_APPROVAL_DENIED,
            "approval_id": approval.get("approval_id").cloned().unwrap_or(Value::Null),
            "decision": decision,
            "decided_by": approval
                .get("decision")
                .and_then(|value| value.get("by"))
                .cloned()
                .unwrap_or(Value::Null)
        })));
    }
    Ok(SuspensionResolution::Resume(format!(
        "all linked approvals decided ({decided}); no denial recorded"
    )))
}

// ---------------------------------------------------------------------------
// status.json suspended count (T304 stalled_run_count style)
// ---------------------------------------------------------------------------

/// Count run JSONs under `.harvis/runs/` in `suspended_awaiting_approval`.
pub fn count_suspended_runs(root: &Path) -> usize {
    let dir = root.join(".harvis/runs");
    let mut count = 0;
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            if let Some(run) = read_json(&path) {
                if run.get("state").and_then(Value::as_str) == Some(RUN_STATE_SUSPENDED) {
                    count += 1;
                }
            }
        }
    }
    count
}

/// Read-modify-write `.harvis/status.json`, preserving every existing field
/// and refreshing only `suspended_run_count`.
pub fn sync_status_suspended_count(root: &Path) -> Result<usize> {
    let count = count_suspended_runs(root);
    let path = root.join(".harvis/status.json");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut status = read_json(&path).unwrap_or_else(|| json!({}));
    status["suspended_run_count"] = json!(count);
    fs::write(&path, serde_json::to_string_pretty(&status)? + "\n")?;
    Ok(count)
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn append_transition_decision(
    root: &Path,
    topic_id: &str,
    run: &Value,
    decision_kind: &str,
    matched: &Value,
) -> Result<()> {
    let moment = now_rfc3339()?;
    let record = json!({
        "schemaVersion": TERMINATION_DECISION_SCHEMA,
        "decision_id": stable_transition_id(topic_id, decision_kind, &moment),
        "version": TERMINATION_VERSION,
        "topic_id": topic_id,
        "run_id": run.get("run_id").cloned().unwrap_or(Value::Null),
        "run_state": run.get("state").cloned().unwrap_or(Value::Null),
        "decision_kind": decision_kind,
        "condition_kind": matched.get("kind").cloned().unwrap_or(Value::Null),
        "matched": matched,
        "ts": moment,
        "created_at": moment
    });
    append_chair_decision(root, &record)
}

fn add_transition_event(
    root: &Path,
    topic_id: &str,
    run: &Value,
    decision_kind: &str,
    matched: &Value,
) -> Result<Value> {
    let condition_kind = matched
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let state = run
        .get("state")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let content = match decision_kind {
        "suspension" => format!(
            "Room run suspended awaiting approval (condition {condition_kind}); state={state}."
        ),
        "resumption" => format!("Room run resumed after approval resolution; state={state}."),
        _ => format!("Room run terminated by condition {condition_kind}; state={state}."),
    };
    add_event_with_metadata(
        root,
        topic_id,
        "harvis",
        "host",
        "status_change",
        &content,
        Vec::new(),
        "internal",
        None,
        json!({
            "version": TERMINATION_VERSION,
            "run_id": run.get("run_id").cloned().unwrap_or(Value::Null),
            "run_state": state,
            "decision_kind": decision_kind,
            "condition_kind": condition_kind,
            "matched": matched
        }),
    )
}

fn approvals_for_run(root: &Path, run_id: &str) -> Result<Vec<Value>> {
    let dir = root.join(".harvis/approvals");
    let mut approvals = Vec::new();
    if !dir.exists() {
        return Ok(approvals);
    }
    for entry in fs::read_dir(&dir)? {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        if let Some(approval) = read_json(&path) {
            if approval.get("run_id").and_then(Value::as_str) == Some(run_id) {
                approvals.push(approval);
            }
        }
    }
    Ok(approvals)
}

fn pending_approval_ids_for_run(root: &Path, run_id: &str) -> Result<Vec<String>> {
    let mut ids: Vec<String> = approvals_for_run(root, run_id)?
        .iter()
        .filter(|approval| approval.get("status").and_then(Value::as_str) == Some("pending"))
        .filter_map(|approval| {
            approval
                .get("approval_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .collect();
    ids.sort();
    Ok(ids)
}

fn stable_transition_id(topic_id: &str, decision_kind: &str, moment: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(format!("{topic_id}|{decision_kind}|{moment}").as_bytes())
        .iter()
        .take(6)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("termination_{decision_kind}_{digest}")
}

fn parse_rfc3339(value: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value.trim(), &Rfc3339).ok()
}

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    value.chars().take(max_chars).collect::<String>()
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_room::{add_message, read_chair_decisions};
    use crate::approvals::{create_approval, decide_approval};
    use crate::init::init_workspace;
    use crate::speaker::{
        agent_room_speaker_step, LlmCallRequest, LlmCallResponse, SpeakerStepOptions,
    };

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "harvis-termination-{tag}-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        root.canonicalize().expect("canonical root")
    }

    fn no_llm() -> impl FnMut(&LlmCallRequest) -> Result<LlmCallResponse> {
        |_request: &LlmCallRequest| -> Result<LlmCallResponse> {
            bail!("no llm call expected in this test")
        }
    }

    fn write_termination_config(root: &Path, table: &str) {
        fs::write(root.join(".harvis/harvis.toml"), table).expect("write config");
    }

    fn backdate_run(root: &Path, topic_id: &str, created_at: &str) {
        let path = room_run_path(root, topic_id);
        let mut run = read_json(&path).expect("run json");
        run["created_at"] = json!(created_at);
        write_json(&path, &run).expect("backdate");
    }

    // -- configuration ------------------------------------------------------

    #[test]
    fn termination_config_parses_simple_max_message() {
        let root = temp_root("cfg-simple");
        write_termination_config(&root, "[agent_room_termination]\nmax_message = 3\n");
        let config = load_termination_config(&root);
        assert!(config.config_error.is_none());
        assert_eq!(
            config.condition,
            Some(TerminationCondition::MaxMessage { limit: 3 })
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_config_parses_any_of_all_of_combination() {
        let root = temp_root("cfg-combo");
        write_termination_config(
            &root,
            r#"[agent_room_termination]
any_of = ["decision_reached", { all_of = [{ max_message = 20 }, { timeout = "600s" }] }]
"#,
        );
        let config = load_termination_config(&root);
        assert!(config.config_error.is_none());
        assert_eq!(
            config.condition,
            Some(TerminationCondition::AnyOf {
                conditions: vec![
                    TerminationCondition::DecisionReached,
                    TerminationCondition::AllOf {
                        conditions: vec![
                            TerminationCondition::MaxMessage { limit: 20 },
                            TerminationCondition::Timeout { seconds: 600 },
                        ]
                    },
                ]
            })
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_config_rejects_unknown_condition_loudly() {
        let root = temp_root("cfg-unknown");
        write_termination_config(
            &root,
            "[agent_room_termination]\nany_of = [\"decision_reached\", { teleport = 1 }]\n",
        );
        let config = load_termination_config(&root);
        let error = config.config_error.expect("unknown kinds must error");
        assert!(error.contains("teleport"), "error names the kind: {error}");
        assert!(config.condition.is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_config_parses_json_string_form() {
        let root = temp_root("cfg-json");
        write_termination_config(
            &root,
            r#"[agent_room_termination]
config_json = '{"any_of": [{"text_mention": ["STOP"]}, {"timeout": "10m"}]}'
"#,
        );
        let config = load_termination_config(&root);
        assert!(config.config_error.is_none());
        assert_eq!(
            config.condition,
            Some(TerminationCondition::AnyOf {
                conditions: vec![
                    TerminationCondition::TextMention {
                        texts: vec!["STOP".to_string()]
                    },
                    TerminationCondition::Timeout { seconds: 600 },
                ]
            })
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_config_supports_topic_override() {
        let root = temp_root("cfg-topic");
        write_termination_config(
            &root,
            r#"[agent_room_termination]
max_message = 50

[agent_room_termination.topics."gwt-workbench"]
max_message = 3
"#,
        );
        let config = load_termination_config(&root);
        assert!(config.config_error.is_none());
        assert_eq!(
            config.effective_condition("gwt-workbench"),
            Some(&TerminationCondition::MaxMessage { limit: 3 })
        );
        assert_eq!(
            config.effective_condition("other-topic"),
            Some(&TerminationCondition::MaxMessage { limit: 50 })
        );
        let _ = fs::remove_dir_all(root);
    }

    // -- leaf condition evaluation ------------------------------------------

    fn snapshot(root: &Path, topic_id: &str) -> RoomStateSnapshot {
        let run = ensure_room_run(root, topic_id).expect("run");
        build_room_snapshot(root, topic_id, &run).expect("snapshot")
    }

    #[test]
    fn termination_max_message_matches_at_limit() {
        let root = temp_root("eval-maxmsg");
        let topic = "gwt-workbench";
        for index in 0..2 {
            add_message(
                &root,
                topic,
                "human",
                "user",
                &format!("m{index}"),
                Vec::new(),
                "internal",
                None,
            )
            .expect("message");
        }
        let condition = TerminationCondition::MaxMessage { limit: 3 };
        assert!(evaluate_condition(&condition, &snapshot(&root, topic)).is_none());
        add_message(
            &root,
            topic,
            "human",
            "user",
            "m3",
            Vec::new(),
            "internal",
            None,
        )
        .expect("message");
        let matched = evaluate_condition(&condition, &snapshot(&root, topic)).expect("matched");
        assert_eq!(matched["kind"], json!(KIND_MAX_MESSAGE));
        assert_eq!(matched["limit"], json!(3));
        assert_eq!(matched["message_count"], json!(3));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_text_mention_matches_token_case_insensitive() {
        let root = temp_root("eval-text");
        let topic = "gwt-workbench";
        let condition = TerminationCondition::TextMention {
            texts: vec!["决策完成".to_string(), "DONE".to_string()],
        };
        add_message(
            &root,
            topic,
            "human",
            "user",
            "还在讨论中",
            Vec::new(),
            "internal",
            None,
        )
        .expect("message");
        assert!(evaluate_condition(&condition, &snapshot(&root, topic)).is_none());
        let hit = add_message(
            &root,
            topic,
            "planner",
            "agent",
            "结论：方案 A，done！",
            Vec::new(),
            "internal",
            None,
        )
        .expect("message");
        let matched = evaluate_condition(&condition, &snapshot(&root, topic)).expect("matched");
        assert_eq!(matched["kind"], json!(KIND_TEXT_MENTION));
        assert_eq!(matched["text"], json!("DONE"));
        assert_eq!(matched["message_id"], hit["message_id"]);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_timeout_matches_elapsed_run() {
        let root = temp_root("eval-timeout");
        let topic = "gwt-workbench";
        ensure_room_run(&root, topic).expect("run");
        let condition = TerminationCondition::Timeout { seconds: 600 };
        assert!(evaluate_condition(&condition, &snapshot(&root, topic)).is_none());
        backdate_run(&root, topic, "2026-07-17T00:00:00Z");
        let matched = evaluate_condition(&condition, &snapshot(&root, topic)).expect("matched");
        assert_eq!(matched["kind"], json!(KIND_TIMEOUT));
        assert_eq!(matched["timeout_seconds"], json!(600));
        assert!(matched["elapsed_seconds"].as_i64().unwrap() > 600);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_decision_reached_matches_decision_event() {
        let root = temp_root("eval-decision");
        let topic = "gwt-workbench";
        let condition = TerminationCondition::DecisionReached;
        assert!(evaluate_condition(&condition, &snapshot(&root, topic)).is_none());
        add_event_with_metadata(
            &root,
            topic,
            "harvis-chair",
            "chair",
            "decision_record",
            "决定采用方案 A。",
            Vec::new(),
            "internal",
            None,
            json!({}),
        )
        .expect("decision event");
        let matched = evaluate_condition(&condition, &snapshot(&root, topic)).expect("matched");
        assert_eq!(matched["kind"], json!(KIND_DECISION_REACHED));
        assert!(matched["event_id"]
            .as_str()
            .is_some_and(|id| id.starts_with("evt_")));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_approval_pending_matches_linked_pending_approval() {
        let root = temp_root("eval-approval");
        let topic = "gwt-workbench";
        ensure_room_run(&root, topic).expect("run");
        let run_id = room_run_id(topic);
        let condition = TerminationCondition::ApprovalPending;
        assert!(evaluate_condition(&condition, &snapshot(&root, topic)).is_none());
        let approval = create_approval(
            &root,
            &run_id,
            "run_command",
            "cargo test",
            "room step needs a human decision",
            "medium",
            "one_time",
        )
        .expect("approval");
        let matched = evaluate_condition(&condition, &snapshot(&root, topic)).expect("matched");
        assert_eq!(matched["kind"], json!(KIND_APPROVAL_PENDING));
        assert_eq!(
            matched["pending_approval_ids"],
            json!([approval["approval_id"].clone()])
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_budget_exhausted_matches_speaker_steps() {
        let root = temp_root("eval-budget");
        let topic = "gwt-workbench";
        ensure_room_run(&root, topic).expect("run");
        let condition = TerminationCondition::BudgetExhausted {
            max_steps: Some(2),
            max_events: None,
        };
        assert!(evaluate_condition(&condition, &snapshot(&root, topic)).is_none());
        for index in 0..2 {
            append_chair_decision(
                &root,
                &json!({
                    "topic_id": topic,
                    "selected_agent_id": "planner",
                    "route_reason": format!("seed step {index}"),
                    "ts": now_rfc3339().expect("ts")
                }),
            )
            .expect("seed decision");
        }
        let matched = evaluate_condition(&condition, &snapshot(&root, topic)).expect("matched");
        assert_eq!(matched["kind"], json!(KIND_BUDGET_EXHAUSTED));
        assert_eq!(matched["max_steps"], json!(2));
        assert_eq!(matched["speaker_step_count"], json!(2));
        let _ = fs::remove_dir_all(root);
    }

    // -- AND / OR composition -------------------------------------------------

    #[test]
    fn termination_all_of_requires_every_child() {
        let root = temp_root("eval-allof");
        let topic = "gwt-workbench";
        ensure_room_run(&root, topic).expect("run");
        for index in 0..2 {
            add_message(
                &root,
                topic,
                "human",
                "user",
                &format!("m{index}"),
                Vec::new(),
                "internal",
                None,
            )
            .expect("message");
        }
        let condition = TerminationCondition::AllOf {
            conditions: vec![
                TerminationCondition::MaxMessage { limit: 2 },
                TerminationCondition::Timeout { seconds: 600 },
            ],
        };
        // max_message already met, timeout not: AND must not fire.
        assert!(evaluate_condition(&condition, &snapshot(&root, topic)).is_none());
        backdate_run(&root, topic, "2026-07-17T00:00:00Z");
        let matched = evaluate_condition(&condition, &snapshot(&root, topic)).expect("matched");
        assert_eq!(matched["kind"], json!(KIND_ALL_OF));
        let children = matched["matched"].as_array().expect("children");
        assert_eq!(children.len(), 2);
        assert_eq!(children[0]["kind"], json!(KIND_MAX_MESSAGE));
        assert_eq!(children[1]["kind"], json!(KIND_TIMEOUT));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_any_of_matches_first_available_child() {
        let root = temp_root("eval-anyof");
        let topic = "gwt-workbench";
        ensure_room_run(&root, topic).expect("run");
        for index in 0..2 {
            add_message(
                &root,
                topic,
                "human",
                "user",
                &format!("m{index}"),
                Vec::new(),
                "internal",
                None,
            )
            .expect("message");
        }
        let condition = TerminationCondition::AnyOf {
            conditions: vec![
                TerminationCondition::DecisionReached,
                TerminationCondition::MaxMessage { limit: 2 },
            ],
        };
        let matched = evaluate_condition(&condition, &snapshot(&root, topic)).expect("matched");
        assert_eq!(matched["kind"], json!(KIND_ANY_OF));
        assert_eq!(matched["matched_index"], json!(1));
        assert_eq!(matched["matched"][0]["kind"], json!(KIND_MAX_MESSAGE));
        let _ = fs::remove_dir_all(root);
    }

    // -- step-level state machine --------------------------------------------

    fn step(root: &Path, prompt: Option<&str>) -> Value {
        let mut llm = no_llm();
        agent_room_speaker_step(
            &SpeakerStepOptions {
                root: root.to_path_buf(),
                topic_id: Some("gwt-workbench".to_string()),
                prompt: prompt.map(ToOwned::to_owned),
                dry_run: true,
                ..SpeakerStepOptions::default()
            },
            &mut llm,
        )
        .expect("step")
    }

    #[test]
    fn termination_step_stops_room_after_third_message() {
        let root = temp_root("step-maxmsg");
        write_termination_config(&root, "[agent_room_termination]\nmax_message = 3\n");
        let first = step(&root, Some("第一条"));
        assert_eq!(first["status"], json!("planned"));
        assert_eq!(first["termination"]["matched"], Value::Null);
        let second = step(&root, Some("第二条"));
        assert_eq!(second["status"], json!("planned"));
        let third = step(&root, Some("第三条"));
        assert_eq!(third["status"], json!(RUN_STATE_TERMINATED));
        assert_eq!(
            third["termination"]["matched"]["kind"],
            json!(KIND_MAX_MESSAGE)
        );
        assert_eq!(third["termination"]["matched"]["message_count"], json!(3));
        // run JSON records the first-class terminated state
        let run = load_room_run(&root, "gwt-workbench")
            .expect("run")
            .expect("some");
        assert_eq!(run["state"], json!(RUN_STATE_TERMINATED));
        assert_eq!(
            run["termination"]["condition_kind"],
            json!(KIND_MAX_MESSAGE)
        );
        // chair_decisions.jsonl carries condition_kind + matched detail
        let decisions = read_chair_decisions(&root, 20).expect("decisions");
        let record = decisions
            .iter()
            .rev()
            .find(|record| record["decision_kind"] == "termination")
            .expect("termination record");
        assert_eq!(record["condition_kind"], json!(KIND_MAX_MESSAGE));
        assert_eq!(record["matched"]["message_count"], json!(3));
        // further steps are refused without adding messages
        let before = snapshot(&root, "gwt-workbench").message_count;
        let fourth = step(&root, Some("第四条"));
        assert_eq!(fourth["status"], json!(RUN_STATE_TERMINATED));
        assert_eq!(snapshot(&root, "gwt-workbench").message_count, before);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_step_suspends_then_resumes_after_approval() {
        let root = temp_root("step-suspend");
        write_termination_config(&root, "[agent_room_termination]\napproval_pending = true\n");
        let topic = "gwt-workbench";
        // first step creates the room run
        let created = step(&root, Some("开工"));
        assert_eq!(created["status"], json!("planned"));
        let run_id = room_run_id(topic);
        // a human-gated action raises a pending approval linked to the room run
        let approval = create_approval(
            &root,
            &run_id,
            "run_command",
            "deploy.sh",
            "room step requested a gated command",
            "high",
            "one_time",
        )
        .expect("approval");
        let approval_id = approval["approval_id"].as_str().unwrap().to_string();
        // next step suspends instead of acting
        let suspended = step(&root, Some("继续"));
        assert_eq!(suspended["status"], json!(RUN_STATE_SUSPENDED));
        assert_eq!(
            suspended["termination"]["matched"]["kind"],
            json!(KIND_APPROVAL_PENDING)
        );
        let run = load_room_run(&root, topic).expect("run").expect("some");
        assert_eq!(run["state"], json!(RUN_STATE_SUSPENDED));
        assert_eq!(
            run["suspension"]["approval_ids"],
            json!([approval_id.clone()])
        );
        // status.json carries the suspended count
        let status: Value = serde_json::from_str(
            &fs::read_to_string(root.join(".harvis/status.json")).expect("status.json"),
        )
        .expect("status json");
        assert_eq!(status["suspended_run_count"], json!(1));
        // while pending, further steps stay suspended without new messages
        let messages_before = snapshot(&root, topic).message_count;
        let again = step(&root, Some("还在吗"));
        assert_eq!(again["status"], json!(RUN_STATE_SUSPENDED));
        assert_eq!(snapshot(&root, topic).message_count, messages_before);
        // approve; the next step resumes and proceeds
        decide_approval(&root, &approval_id, "approved", "human", "go").expect("decide");
        let resumed = step(&root, Some("审批过了，继续"));
        assert_eq!(resumed["status"], json!("planned"));
        assert_eq!(
            resumed["termination"]["resumption"]["condition_kind"],
            json!(KIND_APPROVAL_RESOLVED)
        );
        let run = load_room_run(&root, topic).expect("run").expect("some");
        assert_eq!(run["state"], json!(RUN_STATE_RUNNING));
        let status: Value = serde_json::from_str(
            &fs::read_to_string(root.join(".harvis/status.json")).expect("status.json"),
        )
        .expect("status json");
        assert_eq!(status["suspended_run_count"], json!(0));
        let decisions = read_chair_decisions(&root, 30).expect("decisions");
        assert!(decisions.iter().any(|record| {
            record["decision_kind"] == "suspension"
                && record["condition_kind"] == KIND_APPROVAL_PENDING
        }));
        assert!(decisions.iter().any(|record| {
            record["decision_kind"] == "resumption"
                && record["condition_kind"] == KIND_APPROVAL_RESOLVED
        }));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_step_denied_approval_terminates_room() {
        let root = temp_root("step-deny");
        write_termination_config(&root, "[agent_room_termination]\napproval_pending = true\n");
        let topic = "gwt-workbench";
        step(&root, Some("开工"));
        let approval = create_approval(
            &root,
            &room_run_id(topic),
            "delete",
            "tmp/cache",
            "room step requested a deletion",
            "high",
            "one_time",
        )
        .expect("approval");
        let approval_id = approval["approval_id"].as_str().unwrap().to_string();
        let suspended = step(&root, None);
        assert_eq!(suspended["status"], json!(RUN_STATE_SUSPENDED));
        decide_approval(&root, &approval_id, "denied", "human", "too risky").expect("decide");
        let terminated = step(&root, None);
        assert_eq!(terminated["status"], json!(RUN_STATE_TERMINATED));
        assert_eq!(
            terminated["termination"]["matched"]["kind"],
            json!(KIND_APPROVAL_DENIED)
        );
        assert_eq!(
            terminated["termination"]["matched"]["approval_id"],
            json!(approval_id)
        );
        let run = load_room_run(&root, topic).expect("run").expect("some");
        assert_eq!(run["state"], json!(RUN_STATE_TERMINATED));
        assert_eq!(
            run["termination"]["condition_kind"],
            json!(KIND_APPROVAL_DENIED)
        );
        let decisions = read_chair_decisions(&root, 30).expect("decisions");
        assert!(decisions.iter().any(|record| {
            record["decision_kind"] == "termination"
                && record["condition_kind"] == KIND_APPROVAL_DENIED
        }));
        let status: Value = serde_json::from_str(
            &fs::read_to_string(root.join(".harvis/status.json")).expect("status.json"),
        )
        .expect("status json");
        assert_eq!(status["suspended_run_count"], json!(0));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_step_without_config_keeps_previous_behavior() {
        let root = temp_root("step-none");
        let result = step(&root, Some("无终止配置"));
        assert_eq!(result["status"], json!("planned"));
        assert_eq!(result["termination"]["configured"], json!(false));
        assert_eq!(result["termination"]["matched"], Value::Null);
        let run = load_room_run(&root, "gwt-workbench")
            .expect("run")
            .expect("some");
        assert_eq!(run["state"], json!(RUN_STATE_RUNNING));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn termination_count_suspended_runs_scans_run_ledger() {
        let root = temp_root("count-suspended");
        assert_eq!(count_suspended_runs(&root), 0);
        let topic = "gwt-workbench";
        ensure_room_run(&root, topic).expect("run");
        assert_eq!(count_suspended_runs(&root), 0);
        suspend_room_run(
            &root,
            topic,
            &json!({"kind": KIND_APPROVAL_PENDING, "pending_approval_ids": ["approval_x"]}),
        )
        .expect("suspend");
        assert_eq!(count_suspended_runs(&root), 1);
        terminate_room_run(
            &root,
            topic,
            &json!({"kind": KIND_APPROVAL_DENIED, "decision": "denied"}),
        )
        .expect("terminate");
        assert_eq!(count_suspended_runs(&root), 0);
        let _ = fs::remove_dir_all(root);
    }
}
