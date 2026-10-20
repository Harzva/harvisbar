//! T308 — Agent Room speaker selection (ROADMAP v0.46) + roster activation
//! (ROADMAP v0.47).
//!
//! Three selector tiers, a design borrowed from AutoGen GroupChat
//! (RoundRobin / Selector / custom selector function — design only, no code):
//!
//! 1. `round_robin` — deterministic rotation across the roster. This is the
//!    default and works with zero configuration.
//! 2. `llm` — the room summary plus candidate agent cards are rendered into a
//!    configurable prompt template and routed through the existing provider
//!    registry. The model answers `{"agent_id": ..., "route_reason": ...}`.
//! 3. `custom_function` — a configured local command receives the room summary
//!    plus candidates as JSON on stdin and answers the same JSON contract on
//!    stdout. Timeout, non-zero exit, or invalid output fall back to
//!    round-robin and the fallback is recorded in `route_reason`.
//!
//! Every selection appends one record to
//! `.harvis/agent-room/chair_decisions.jsonl` carrying `selector_kind`,
//! `route_reason`, `question_id` (explicit null when there is no question
//! context) and `ts`.
//!
//! Roster activation: participants with `execution_mode = "active"` are really
//! executed by `POST /agent-room/step` through their configured local harness
//! (`harness_ref`, run via `/bin/sh -c`) or, when no harness is configured,
//! through a provider-registry route. `record_only` (and `approval_required`)
//! participants keep the previous behavior: the selection is recorded but
//! nothing is executed. Execution failures are recorded as blocked Agent Room
//! events instead of crashing the step.

use anyhow::{bail, Context, Result};
use regex::Regex;
use serde_json::{json, Value};
use std::fs;
use std::io::Write as IoWrite;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::agent_room::{
    add_event_with_metadata, add_message, append_chair_decision, create_topic, init_agent_room,
    list_agent_room, list_participants, read_chair_decisions,
};
use crate::provider_registry::{load_provider_registry, resolve_model_route, ResolvedModelRoute};
use crate::termination::{
    ensure_room_run, evaluate_room_termination, load_termination_config,
    matched_involves_approval_pending, resolve_suspension, resume_room_run, room_run_state,
    suspend_room_run, terminate_room_run, SuspensionResolution, KIND_APPROVAL_PENDING,
    KIND_APPROVAL_RESOLVED, RUN_STATE_SUSPENDED, RUN_STATE_TERMINATED, TERMINATION_VERSION,
};
use crate::trace::{
    load_trace_config, parse_trace_extraction_json, parse_trace_markers, record_reply_traces,
    render_trace_prompt, trace_report, TraceDraft, DEFAULT_LLM_EXTRACTION_MAX_TOKENS,
    TRACE_EXTRACTION_LLM, TRACE_EXTRACTION_RULE, TRACE_EXTRACTION_RULE_FALLBACK,
};
use harvis_core::time::now_rfc3339;

pub const SPEAKER_SELECTION_VERSION: &str = "v0.46-speaker-selection";
pub const SPEAKER_STEP_VERSION: &str = "v0.53-cognitive-host-stepper";
pub const SPEAKER_STEP_POLICY: &str = "harvis.host.v0.53";
pub const CHAIR_DECISION_SCHEMA: &str = "harvis.chair-decision.v1-speaker";
pub const SPEAKER_CONTRACT_ID: &str = "harvis.speaker-selection.v1";

pub const SELECTOR_ROUND_ROBIN: &str = "round_robin";
pub const SELECTOR_LLM: &str = "llm";
pub const SELECTOR_CUSTOM_FUNCTION: &str = "custom_function";
pub const SELECTORS: &[&str] = &[SELECTOR_ROUND_ROBIN, SELECTOR_LLM, SELECTOR_CUSTOM_FUNCTION];

const DEFAULT_LLM_MAX_TOKENS: usize = 400;
const DEFAULT_REPLY_MAX_TOKENS: usize = 520;
const DEFAULT_CUSTOM_TIMEOUT_MS: u64 = 5_000;
const DEFAULT_HARNESS_TIMEOUT_MS: u64 = 15_000;
const MAX_HARNESS_REPLY_CHARS: usize = 4_000;

const DEFAULT_LLM_PROMPT_TEMPLATE: &str = r#"You are the speaker selector for a H.A.R.V.I.S. Agent Room.
Choose exactly one next speaker from the candidates below and reply with STRICT JSON only:
{"agent_id": "<slot_id>", "route_reason": "<one concrete sentence>"}

Weigh these signals: explicit @mentions, unanswered questions, role fit, novelty, disagreement, confidence, cost and time budget.

Topic: {{topic_id}}
Question id: {{question_id}}

Room summary:
{{room_summary}}

Machine-extracted signals:
{{signals}}

Candidates (JSON cards):
{{candidates}}
"#;

// ---------------------------------------------------------------------------
// Configuration (`<root>/.harvis/harvis.toml`, table `[agent_room_speaker]`)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct SpeakerSelectorConfig {
    pub selector: String,
    pub model_alias: Option<String>,
    pub prompt_template: Option<String>,
    pub prompt_template_path: Option<PathBuf>,
    pub max_tokens: usize,
    pub command: Option<String>,
    pub timeout_ms: u64,
    pub harness_timeout_ms: u64,
    pub config_source: String,
    pub config_error: Option<String>,
}

impl Default for SpeakerSelectorConfig {
    fn default() -> Self {
        Self {
            selector: SELECTOR_ROUND_ROBIN.to_string(),
            model_alias: None,
            prompt_template: None,
            prompt_template_path: None,
            max_tokens: DEFAULT_LLM_MAX_TOKENS,
            command: None,
            timeout_ms: DEFAULT_CUSTOM_TIMEOUT_MS,
            harness_timeout_ms: DEFAULT_HARNESS_TIMEOUT_MS,
            config_source: "default (no [agent_room_speaker] table)".to_string(),
            config_error: None,
        }
    }
}

pub fn load_speaker_config(root: &Path) -> SpeakerSelectorConfig {
    let mut config = SpeakerSelectorConfig::default();
    let path = root.join(".harvis/harvis.toml");
    let Ok(text) = fs::read_to_string(&path) else {
        return config;
    };
    let Ok(value) = text.parse::<toml::Value>() else {
        config.config_error = Some("harvis.toml is not valid TOML".to_string());
        return config;
    };
    let Some(table) = value
        .get("agent_room_speaker")
        .and_then(toml::Value::as_table)
    else {
        return config;
    };
    config.config_source = format!("{} [agent_room_speaker]", path.display());
    let string_value = |key: &str| -> Option<String> {
        table
            .get(key)
            .and_then(toml::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    };
    if let Some(selector) = string_value("selector") {
        if SELECTORS.contains(&selector.as_str()) {
            config.selector = selector;
        } else {
            config.config_error = Some(format!(
                "unknown agent_room_speaker selector '{selector}', fell back to round_robin"
            ));
            config.selector = SELECTOR_ROUND_ROBIN.to_string();
        }
    }
    config.model_alias = string_value("model_alias");
    config.prompt_template = string_value("prompt_template");
    config.prompt_template_path = string_value("prompt_template_path").map(|value| {
        let path = PathBuf::from(value);
        if path.is_absolute() {
            path
        } else {
            root.join(path)
        }
    });
    config.command = string_value("command");
    if let Some(value) = table.get("max_tokens").and_then(toml::Value::as_integer) {
        if value > 0 {
            config.max_tokens = value as usize;
        }
    }
    if let Some(value) = table.get("timeout_ms").and_then(toml::Value::as_integer) {
        if value > 0 {
            config.timeout_ms = value as u64;
        }
    }
    if let Some(value) = table
        .get("harness_timeout_ms")
        .and_then(toml::Value::as_integer)
    {
        if value > 0 {
            config.harness_timeout_ms = value as u64;
        }
    }
    config
}

// ---------------------------------------------------------------------------
// Roster candidates
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct SpeakerCandidate {
    pub slot_id: String,
    pub role: String,
    pub display_name: String,
    pub execution_mode: String,
    pub status: String,
    pub provider_ref: Option<String>,
    pub model_ref: Option<String>,
    pub harness_ref: Option<String>,
    pub route_ref: Option<String>,
}

impl SpeakerCandidate {
    pub fn is_active(&self) -> bool {
        self.execution_mode == "active"
    }

    pub fn card(&self) -> Value {
        json!({
            "slot_id": self.slot_id,
            "role": self.role,
            "display_name": self.display_name,
            "execution_mode": self.execution_mode,
            "status": self.status,
            "provider_ref": self.provider_ref,
            "model_ref": self.model_ref,
            "harness_ref": self.harness_ref.is_some(),
            "route_ref": self.route_ref,
        })
    }
}

pub fn load_candidates(root: &Path, topic_id: Option<&str>) -> Result<Vec<SpeakerCandidate>> {
    let participants = list_participants(root, topic_id)?;
    let Some(slots) = participants.get("participants").and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    Ok(slots
        .iter()
        .filter_map(|slot| {
            let slot_id = slot.get("slot_id").and_then(Value::as_str)?.to_string();
            let status = slot
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("idle")
                .to_string();
            if status == "disabled" {
                return None;
            }
            Some(SpeakerCandidate {
                slot_id,
                role: slot
                    .get("role")
                    .and_then(Value::as_str)
                    .unwrap_or("agent")
                    .to_string(),
                display_name: slot
                    .get("display_name")
                    .and_then(Value::as_str)
                    .unwrap_or("agent")
                    .to_string(),
                execution_mode: slot
                    .get("execution_mode")
                    .and_then(Value::as_str)
                    .unwrap_or("record_only")
                    .to_string(),
                status,
                provider_ref: slot
                    .get("provider_ref")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                model_ref: slot
                    .get("model_ref")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                harness_ref: slot
                    .get("harness_ref")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                route_ref: slot
                    .get("route_ref")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            })
        })
        .collect())
}

// ---------------------------------------------------------------------------
// Room context + signals (ROADMAP v0.46 signal list)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct RoomContext {
    pub topic_id: String,
    pub question_id: Option<String>,
    pub latest_message: Option<Value>,
    pub recent_messages: Vec<Value>,
    pub signals: Value,
    pub room_summary: String,
}

pub fn build_room_context(
    root: &Path,
    topic_id: &str,
    question_id: Option<&str>,
    candidates: &[SpeakerCandidate],
) -> Result<RoomContext> {
    build_room_context_with_routing(root, topic_id, question_id, candidates, None)
}

/// `routing_text` is the raw composer text attached to the step request
/// (v0.53 `raw_prompt`); when present it drives the mention / unanswered
/// question signals instead of the stored room messages.
pub fn build_room_context_with_routing(
    root: &Path,
    topic_id: &str,
    question_id: Option<&str>,
    candidates: &[SpeakerCandidate],
    routing_text: Option<&str>,
) -> Result<RoomContext> {
    let room = list_agent_room(root, 80)?;
    let messages: Vec<Value> = room
        .get("messages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|message| message.get("topic_id").and_then(Value::as_str) == Some(topic_id))
        .cloned()
        .collect();
    let latest_message = messages.last().cloned();
    let latest_human = messages
        .iter()
        .rev()
        .find(|message| message.get("agent_id").and_then(Value::as_str) == Some("human"))
        .cloned();
    let mention_text = routing_text
        .map(ToOwned::to_owned)
        .or_else(|| {
            latest_human
                .as_ref()
                .or(latest_message.as_ref())
                .and_then(|message| message.get("content").and_then(Value::as_str))
                .map(ToOwned::to_owned)
        })
        .unwrap_or_default();
    let explicit_mention = detect_mention(&mention_text, candidates);
    let unanswered_question = routing_text
        .map(|text| text.contains('?') || text.contains('？'))
        .or_else(|| {
            latest_human
                .as_ref()
                .and_then(|message| message.get("content").and_then(Value::as_str))
                .map(|content| content.contains('?') || content.contains('？'))
        })
        .unwrap_or(false);

    // Novelty: how many room messages have passed since each candidate last
    // spoke in this topic (null = never spoke in the loaded window).
    let mut turns_since_spoke = serde_json::Map::new();
    for candidate in candidates {
        let turns = messages
            .iter()
            .rev()
            .position(|message| {
                message.get("agent_id").and_then(Value::as_str) == Some(candidate.slot_id.as_str())
            })
            .map(|index| json!(index))
            .unwrap_or(Value::Null);
        turns_since_spoke.insert(candidate.slot_id.clone(), turns);
    }

    let signals = json!({
        "explicit_mention": explicit_mention,
        "unanswered_question": unanswered_question,
        "role_fit": "candidate roles are listed in the candidate cards",
        "novelty": { "turns_since_spoke": turns_since_spoke },
        "disagreement": Value::Null,
        "confidence": Value::Null,
        "cost": "provider route cost policy is not metered yet",
        "time_budget": Value::Null
    });

    let mut summary_lines = Vec::new();
    summary_lines.push(format!("Topic: {topic_id}"));
    if let Some(human) = latest_human.as_ref() {
        summary_lines.push(format!(
            "Latest human message: {}",
            truncate(
                human.get("content").and_then(Value::as_str).unwrap_or(""),
                240
            )
        ));
    } else {
        summary_lines.push("Latest human message: (none)".to_string());
    }
    summary_lines.push("Recent room messages:".to_string());
    if messages.is_empty() {
        summary_lines.push("- (no messages yet)".to_string());
    } else {
        for message in messages.iter().rev().take(6).rev() {
            summary_lines.push(format!(
                "- {}: {}",
                message
                    .get("agent_id")
                    .and_then(Value::as_str)
                    .unwrap_or("?"),
                truncate(
                    message.get("content").and_then(Value::as_str).unwrap_or(""),
                    160
                )
            ));
        }
    }
    summary_lines.push(format!(
        "Unanswered question pending: {}",
        if unanswered_question { "yes" } else { "no" }
    ));

    Ok(RoomContext {
        topic_id: topic_id.to_string(),
        question_id: question_id.map(ToOwned::to_owned),
        latest_message,
        recent_messages: messages,
        signals,
        room_summary: summary_lines.join("\n"),
    })
}

fn detect_mention(text: &str, candidates: &[SpeakerCandidate]) -> Value {
    let Ok(pattern) = Regex::new(r"@([A-Za-z0-9_\-一-鿿]+)") else {
        return Value::Null;
    };
    for capture in pattern.captures_iter(text) {
        let Some(token) = capture.get(1).map(|m| m.as_str().to_lowercase()) else {
            continue;
        };
        for candidate in candidates {
            let slot = candidate.slot_id.to_lowercase();
            let display = candidate.display_name.to_lowercase();
            if slot == token || display.contains(&token) || slot.contains(&token) {
                return json!({
                    "token": format!("@{token}"),
                    "slot_id": candidate.slot_id,
                    "display_name": candidate.display_name
                });
            }
        }
    }
    Value::Null
}

// ---------------------------------------------------------------------------
// LLM call injection (keeps harvis-runtime sync + offline-testable; the HTTP
// crate performs the real provider call through the provider registry route)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct LlmCallRequest {
    pub route: ResolvedModelRoute,
    pub prompt: String,
    pub max_tokens: usize,
    pub purpose: String,
}

#[derive(Debug, Clone)]
pub struct LlmCallResponse {
    pub text: String,
    pub usage: Value,
    pub stop_reason: Option<String>,
}

// ---------------------------------------------------------------------------
// Speaker selection
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct SpeakerSelection {
    pub agent_id: String,
    pub selector_kind: String,
    pub effective_selector: String,
    pub route_reason: String,
    pub question_id: Option<String>,
    pub fallback: bool,
    pub signals: Value,
    pub candidates: Vec<String>,
    pub model_call: bool,
}

pub fn select_speaker(
    root: &Path,
    config: &SpeakerSelectorConfig,
    context: &RoomContext,
    candidates: &[SpeakerCandidate],
    registry_path: Option<&Path>,
    allow_model_call: bool,
    llm: &mut dyn FnMut(&LlmCallRequest) -> Result<LlmCallResponse>,
) -> Result<SpeakerSelection> {
    if candidates.is_empty() {
        bail!("speaker selection requires at least one enabled roster participant");
    }
    let candidate_ids: Vec<String> = candidates.iter().map(|c| c.slot_id.clone()).collect();
    let base_reason = config.config_error.clone();
    let decided = match config.selector.as_str() {
        SELECTOR_LLM => select_with_llm(
            root,
            config,
            context,
            candidates,
            registry_path,
            allow_model_call,
            llm,
        ),
        SELECTOR_CUSTOM_FUNCTION => select_with_custom_function(config, context, candidates),
        _ => {
            let (agent_id, reason) = round_robin_select(root, context, candidates);
            DecidedSelection::decided(SELECTOR_ROUND_ROBIN, agent_id, reason, false)
        }
    };
    let mut selection = match decided {
        Ok(value) => value,
        Err(error) => {
            let (agent_id, reason) = round_robin_select(root, context, candidates);
            DecidedSelection {
                selector_kind: config.selector.clone(),
                effective_selector: SELECTOR_ROUND_ROBIN.to_string(),
                agent_id,
                route_reason: format!(
                    "{} selector failed: {error}; fell back to round_robin ({reason})",
                    config.selector
                ),
                fallback: true,
                model_call: false,
            }
        }
    };
    if let Some(prefix) = base_reason {
        selection.route_reason = format!("{prefix}; {}", selection.route_reason);
    }
    Ok(SpeakerSelection {
        agent_id: selection.agent_id,
        selector_kind: selection.selector_kind,
        effective_selector: selection.effective_selector,
        route_reason: selection.route_reason,
        question_id: context.question_id.clone(),
        fallback: selection.fallback,
        signals: context.signals.clone(),
        candidates: candidate_ids,
        model_call: selection.model_call,
    })
}

struct DecidedSelection {
    selector_kind: String,
    effective_selector: String,
    agent_id: String,
    route_reason: String,
    fallback: bool,
    model_call: bool,
}

impl DecidedSelection {
    fn decided(
        kind: &str,
        agent_id: String,
        route_reason: String,
        model_call: bool,
    ) -> Result<DecidedSelection> {
        Ok(DecidedSelection {
            selector_kind: kind.to_string(),
            effective_selector: kind.to_string(),
            agent_id,
            route_reason,
            fallback: false,
            model_call,
        })
    }

    fn fallback(kind: &str, agent_id: String, route_reason: String) -> DecidedSelection {
        DecidedSelection {
            selector_kind: kind.to_string(),
            effective_selector: SELECTOR_ROUND_ROBIN.to_string(),
            agent_id,
            route_reason,
            fallback: true,
            model_call: false,
        }
    }
}

/// Round-robin rotation. The rotation marker is the last speaker-selection
/// decision recorded for this topic (steps that select a `record_only`
/// participant produce no message, so message history alone cannot advance
/// the rotation); with no prior decision it falls back to the last candidate
/// who spoke in the topic, then to the first candidate.
fn round_robin_select(
    root: &Path,
    context: &RoomContext,
    candidates: &[SpeakerCandidate],
) -> (String, String) {
    let last_decision_speaker = read_chair_decisions(root, 50).ok().and_then(|decisions| {
        decisions
            .iter()
            .rev()
            .filter(|record| {
                record.get("topic_id").and_then(Value::as_str) == Some(context.topic_id.as_str())
            })
            .filter_map(|record| {
                record
                    .get("selected_agent_id")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .find(|agent_id| candidates.iter().any(|c| &c.slot_id == agent_id))
    });
    let last_message_speaker = context
        .recent_messages
        .iter()
        .rev()
        .filter_map(|message| message.get("agent_id").and_then(Value::as_str))
        .find(|agent_id| candidates.iter().any(|c| c.slot_id == *agent_id))
        .map(ToOwned::to_owned);
    let last = last_decision_speaker.or(last_message_speaker);
    match last {
        Some(last_id) => {
            let index = candidates
                .iter()
                .position(|candidate| candidate.slot_id == last_id)
                .unwrap_or(0);
            let next = &candidates[(index + 1) % candidates.len()];
            (
                next.slot_id.clone(),
                format!("round-robin rotation: next speaker after {last_id}"),
            )
        }
        None => (
            candidates[0].slot_id.clone(),
            "round-robin start: no prior speaker or decision in topic".to_string(),
        ),
    }
}

fn select_with_llm(
    root: &Path,
    config: &SpeakerSelectorConfig,
    context: &RoomContext,
    candidates: &[SpeakerCandidate],
    registry_path: Option<&Path>,
    allow_model_call: bool,
    llm: &mut dyn FnMut(&LlmCallRequest) -> Result<LlmCallResponse>,
) -> Result<DecidedSelection> {
    if !allow_model_call {
        let (agent_id, reason) = round_robin_select(root, context, candidates);
        return Ok(DecidedSelection::fallback(
            SELECTOR_LLM,
            agent_id,
            format!(
                "dry_run: llm selector skipped the model call; fell back to round_robin ({reason})"
            ),
        ));
    }
    let alias = config.model_alias.as_deref().unwrap_or("d4f");
    let route = resolve_model_route(alias, registry_path)
        .with_context(|| format!("llm selector route resolution failed for alias '{alias}'"))?;
    let prompt = render_llm_prompt(root, config, context, candidates);
    let response = llm(&LlmCallRequest {
        route,
        prompt,
        max_tokens: config.max_tokens,
        purpose: "speaker_selection".to_string(),
    })
    .context("llm selector provider call failed")?;
    let parsed = parse_selection_json(&response.text)
        .context("llm selector returned no parseable selection JSON")?;
    let agent_id = parsed
        .get("agent_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .context("llm selector returned an empty agent_id")?
        .to_string();
    if !candidates.iter().any(|c| c.slot_id == agent_id) {
        bail!("llm selector picked unknown agent '{agent_id}'");
    }
    let route_reason = parsed
        .get("route_reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .context("llm selector returned an empty route_reason (route_reason is required)")?
        .to_string();
    DecidedSelection::decided(SELECTOR_LLM, agent_id, route_reason, true)
}

fn render_llm_prompt(
    root: &Path,
    config: &SpeakerSelectorConfig,
    context: &RoomContext,
    candidates: &[SpeakerCandidate],
) -> String {
    let template = if let Some(template) = config.prompt_template.as_deref() {
        template.to_string()
    } else if let Some(path) = config.prompt_template_path.as_ref() {
        fs::read_to_string(path).unwrap_or_else(|_| DEFAULT_LLM_PROMPT_TEMPLATE.to_string())
    } else {
        DEFAULT_LLM_PROMPT_TEMPLATE.to_string()
    };
    let _ = root;
    let cards: Vec<Value> = candidates.iter().map(SpeakerCandidate::card).collect();
    template
        .replace("{{topic_id}}", &context.topic_id)
        .replace(
            "{{question_id}}",
            context.question_id.as_deref().unwrap_or("null"),
        )
        .replace("{{room_summary}}", &context.room_summary)
        .replace(
            "{{signals}}",
            &serde_json::to_string_pretty(&context.signals).unwrap_or_else(|_| "{}".to_string()),
        )
        .replace(
            "{{candidates}}",
            &serde_json::to_string_pretty(&cards).unwrap_or_else(|_| "[]".to_string()),
        )
        .replace(
            "{{latest_message}}",
            context
                .latest_message
                .as_ref()
                .and_then(|message| message.get("content").and_then(Value::as_str))
                .unwrap_or(""),
        )
}

/// Parse the shared selector JSON contract
/// (`{"agent_id": ..., "route_reason": ...}`) out of model or script output;
/// tolerates surrounding prose and code fences.
fn parse_selection_json(text: &str) -> Result<Value> {
    let trimmed = text.trim();
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        if value.is_object() {
            return Ok(value);
        }
    }
    let cleaned = trimmed
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();
    if let Ok(value) = serde_json::from_str::<Value>(cleaned) {
        if value.is_object() {
            return Ok(value);
        }
    }
    let Some(start) = trimmed.find('{') else {
        bail!("no JSON object found in selector output");
    };
    let Some(end) = trimmed.rfind('}') else {
        bail!("no JSON object found in selector output");
    };
    if end <= start {
        bail!("no JSON object found in selector output");
    }
    let value: Value = serde_json::from_str(&trimmed[start..=end])
        .context("selector output JSON object is not valid")?;
    if !value.is_object() {
        bail!("selector output JSON is not an object");
    }
    Ok(value)
}

fn select_with_custom_function(
    config: &SpeakerSelectorConfig,
    context: &RoomContext,
    candidates: &[SpeakerCandidate],
) -> Result<DecidedSelection> {
    let Some(command) = config
        .command
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        bail!("custom_function selector has no command configured");
    };
    let cards: Vec<Value> = candidates.iter().map(SpeakerCandidate::card).collect();
    let stdin_payload = json!({
        "version": SPEAKER_CONTRACT_ID,
        "topic_id": context.topic_id,
        "question_id": context.question_id,
        "room_summary": context.room_summary,
        "signals": context.signals,
        "candidates": cards,
    });
    let output = run_command_with_timeout(command, &stdin_payload.to_string(), config.timeout_ms)
        .context("custom_function selector could not be started")?;
    if output.timed_out {
        bail!(
            "custom_function selector timed out after {}ms",
            config.timeout_ms
        );
    }
    if !output.success {
        bail!(
            "custom_function selector exited non-zero (code {:?}): {}",
            output.code,
            truncate(&output.stderr_tail, 200)
        );
    }
    let parsed = parse_selection_json(&output.stdout)
        .context("custom_function selector returned no parseable selection JSON")?;
    let agent_id = parsed
        .get("agent_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .context("custom_function selector returned an empty agent_id")?
        .to_string();
    if !candidates.iter().any(|c| c.slot_id == agent_id) {
        bail!("custom_function selector picked unknown agent '{agent_id}'");
    }
    let route_reason = parsed
        .get("route_reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .context("custom_function selector returned an empty route_reason")?
        .to_string();
    DecidedSelection::decided(SELECTOR_CUSTOM_FUNCTION, agent_id, route_reason, false)
}

struct CommandOutput {
    success: bool,
    code: Option<i32>,
    stdout: String,
    stderr_tail: String,
    timed_out: bool,
}

fn run_command_with_timeout(
    command: &str,
    stdin_data: &str,
    timeout_ms: u64,
) -> Result<CommandOutput> {
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to spawn command: {command}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(stdin_data.as_bytes());
    }
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    loop {
        match child.try_wait()? {
            Some(status) => {
                let mut stdout = String::new();
                if let Some(mut pipe) = child.stdout.take() {
                    use std::io::Read;
                    let _ = pipe.read_to_string(&mut stdout);
                }
                let mut stderr = String::new();
                if let Some(mut pipe) = child.stderr.take() {
                    use std::io::Read;
                    let _ = pipe.read_to_string(&mut stderr);
                }
                return Ok(CommandOutput {
                    success: status.success(),
                    code: status.code(),
                    stdout,
                    stderr_tail: stderr,
                    timed_out: false,
                });
            }
            None => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Ok(CommandOutput {
                        success: false,
                        code: None,
                        stdout: String::new(),
                        stderr_tail: String::new(),
                        timed_out: true,
                    });
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Agent Room stepper (POST /agent-room/step consumes the selector result)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
pub struct SpeakerStepOptions {
    pub root: PathBuf,
    pub topic_id: Option<String>,
    pub prompt: Option<String>,
    pub raw_prompt: Option<String>,
    pub question_id: Option<String>,
    pub dry_run: bool,
    pub provider_registry: Option<PathBuf>,
    pub selector_override: Option<String>,
    pub model_alias: Option<String>,
    pub reply_to_event_id: Option<String>,
    pub reply_to_agent_id: Option<String>,
    pub reply_to_question_id: Option<String>,
}

pub fn agent_room_speaker_step(
    options: &SpeakerStepOptions,
    llm: &mut dyn FnMut(&LlmCallRequest) -> Result<LlmCallResponse>,
) -> Result<Value> {
    let root = resolve_root(&options.root)?;
    init_agent_room(&root)?;
    let seed = options
        .prompt
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("Host, inspect the latest room state and choose the next useful move.")
        .to_string();
    let topic_id = match options
        .topic_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(topic_id) => topic_id.to_string(),
        None => {
            let topic = create_topic(
                &root,
                "H.A.R.V.I.S. Cognitive Host Stepper",
                &seed,
                "harvis",
            )?;
            topic
                .get("topic_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        }
    };
    // T309: composable termination conditions + first-class approval
    // suspension. The room run record lives in `.harvis/runs/`; a terminated
    // room refuses further steps, a suspended room waits for the human
    // decision and then resumes or terminates, and a running room checks its
    // configured conditions before and after the step body.
    let termination_config = load_termination_config(&root);
    let mut termination_view = json!({
        "version": TERMINATION_VERSION,
        "configured": termination_config.configured(),
        "config_source": termination_config.config_source,
        "config_error": termination_config.config_error,
        "matched": Value::Null,
        "resumption": Value::Null,
        "step_status": Value::Null,
        "room_run": Value::Null
    });
    let room_run = ensure_room_run(&root, &topic_id)?;
    match room_run_state(&room_run) {
        RUN_STATE_TERMINATED => {
            termination_view["matched"] = room_run
                .get("termination")
                .and_then(|termination| termination.get("matched"))
                .cloned()
                .unwrap_or(Value::Null);
            termination_view["room_run"] = room_run_summary(&room_run);
            return Ok(step_state_response(
                &topic_id,
                RUN_STATE_TERMINATED,
                options.dry_run,
                termination_view,
            ));
        }
        RUN_STATE_SUSPENDED => match resolve_suspension(&root, &topic_id)? {
            SuspensionResolution::StillPending(pending_ids) => {
                termination_view["matched"] = json!({
                    "kind": KIND_APPROVAL_PENDING,
                    "pending_approval_ids": pending_ids
                });
                termination_view["room_run"] = room_run_summary(&room_run);
                return Ok(step_state_response(
                    &topic_id,
                    RUN_STATE_SUSPENDED,
                    options.dry_run,
                    termination_view,
                ));
            }
            SuspensionResolution::Resume(note) => {
                let resumed = resume_room_run(&root, &topic_id, &note)?;
                termination_view["resumption"] = json!({
                    "condition_kind": KIND_APPROVAL_RESOLVED,
                    "note": note,
                    "run_state": resumed.get("state").cloned().unwrap_or(Value::Null)
                });
            }
            SuspensionResolution::Terminate(matched) => {
                let run = terminate_room_run(&root, &topic_id, &matched)?;
                termination_view["matched"] = matched;
                termination_view["room_run"] = room_run_summary(&run);
                return Ok(step_state_response(
                    &topic_id,
                    RUN_STATE_TERMINATED,
                    options.dry_run,
                    termination_view,
                ));
            }
        },
        _ => {}
    }

    // Pre-step evaluation catches conditions that became true between steps
    // (a pending approval raised elsewhere, an elapsed timeout, ...).
    if let Some(matched) = evaluate_room_termination(&root, &topic_id, &termination_config)? {
        termination_view["matched"] = matched.clone();
        if matched_involves_approval_pending(&matched) {
            let run = suspend_room_run(&root, &topic_id, &matched)?;
            termination_view["room_run"] = room_run_summary(&run);
            return Ok(step_state_response(
                &topic_id,
                RUN_STATE_SUSPENDED,
                options.dry_run,
                termination_view,
            ));
        }
        let run = terminate_room_run(&root, &topic_id, &matched)?;
        termination_view["room_run"] = room_run_summary(&run);
        return Ok(step_state_response(
            &topic_id,
            RUN_STATE_TERMINATED,
            options.dry_run,
            termination_view,
        ));
    }

    let user_message = if options
        .prompt
        .as_deref()
        .map(str::trim)
        .is_some_and(|value| !value.is_empty())
    {
        Some(add_message(
            &root,
            &topic_id,
            "human",
            "user",
            &seed,
            Vec::new(),
            "internal",
            None,
        )?)
    } else {
        None
    };

    let candidates = load_candidates(&root, Some(&topic_id))?;
    if candidates.is_empty() {
        bail!("agent room roster has no enabled participants");
    }
    let question_id = options
        .question_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| make_question_id(&topic_id, &seed));
    let context = build_room_context_with_routing(
        &root,
        &topic_id,
        Some(&question_id),
        &candidates,
        options
            .raw_prompt
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty()),
    )?;
    let lineage = infer_step_lineage(&context, options, &root, &topic_id);

    let mut config = load_speaker_config(&root);
    if let Some(selector) = options
        .selector_override
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        if SELECTORS.contains(&selector) {
            config.selector = selector.to_string();
        }
    }
    if config.model_alias.is_none() {
        config.model_alias = options
            .model_alias
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned);
    }

    let selection = select_speaker(
        &root,
        &config,
        &context,
        &candidates,
        options.provider_registry.as_deref(),
        !options.dry_run,
        llm,
    )?;

    let ts = now_rfc3339()?;
    let decision_record = json!({
        "schemaVersion": CHAIR_DECISION_SCHEMA,
        "decision_id": make_decision_id(&topic_id, &selection.agent_id, &question_id, &ts),
        "version": SPEAKER_SELECTION_VERSION,
        "topic_id": topic_id,
        "selector_kind": selection.selector_kind,
        "effective_selector": selection.effective_selector,
        "selected_agent_id": selection.agent_id,
        "route_reason": selection.route_reason,
        "question_id": selection.question_id,
        "fallback": selection.fallback,
        "signals": selection.signals,
        "candidates": selection.candidates,
        "dry_run": options.dry_run,
        "model_call": selection.model_call,
        "ts": ts,
        "created_at": ts
    });
    append_chair_decision(&root, &decision_record)?;

    let selected = candidates
        .iter()
        .find(|candidate| candidate.slot_id == selection.agent_id)
        .cloned()
        .expect("selector result is validated against candidates");

    let host_event = add_event_with_metadata(
        &root,
        &topic_id,
        "harvis",
        "host",
        "question",
        &format!(
            "Host step selected {}: respond to {}, close one open question, and record the next verifiable step. Seed: {}",
            selected.slot_id,
            lineage
                .get("reply_to_agent_id")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .unwrap_or("the room"),
            seed
        ),
        Vec::new(),
        "internal",
        None,
        json!({
            "version": SPEAKER_STEP_VERSION,
            "speaker_version": SPEAKER_SELECTION_VERSION,
            "policy": SPEAKER_STEP_POLICY,
            "selected_alias": selected.slot_id,
            "selected_agent": selected.display_name,
            "selector_kind": selection.selector_kind,
            "effective_selector": selection.effective_selector,
            "route_reason": selection.route_reason,
            "question_id": question_id,
            "reply_to_event_id": lineage["reply_to_event_id"],
            "reply_to_agent_id": lineage["reply_to_agent_id"],
            "reply_to_question_id": lineage["reply_to_question_id"],
            "dry_run": options.dry_run,
            "stopping_conditions": [
                "decision_record",
                "handoff_note",
                "human_question",
                "blocked"
            ],
            "authority": {
                "executes_files": false,
                "executes_commands": false,
                "requires_handoff_for_mutation": true
            }
        }),
    )?;

    let mut status = "planned".to_string();
    let mut agent_message = Value::Null;
    let mut message_view = Value::Null;
    let mut usage = Value::Null;
    let mut stop_reason = Value::Null;
    let mut blocked_event = Value::Null;
    let mut trace_view = Value::Null;
    let mut execution = json!({
        "mode": selected.execution_mode,
        "via": Value::Null,
        "detail": "dry_run: selection recorded without execution"
    });

    if !options.dry_run {
        if selected.is_active() {
            match execute_active_participant(
                &root,
                &topic_id,
                &question_id,
                &selected,
                &context,
                &lineage,
                &config,
                options.provider_registry.as_deref(),
                llm,
            ) {
                Ok(reply) => {
                    let message = add_message(
                        &root,
                        &topic_id,
                        &selected.slot_id,
                        &selected.role,
                        &reply.content,
                        Vec::new(),
                        "internal",
                        reply.model.as_deref(),
                    )?;
                    message_view = speaker_message_view(
                        &message,
                        &selected,
                        &topic_id,
                        &question_id,
                        &lineage,
                        &selection.route_reason,
                        &reply,
                    );
                    // T311 / ROADMAP v0.45: parse the executed reply for
                    // structured cognitive trace markers and append
                    // protocol-versioned trace events to events.jsonl.
                    // messages.jsonl write/read behavior is untouched.
                    trace_view = run_trace_extraction(
                        &root,
                        &topic_id,
                        &question_id,
                        &selected,
                        &message,
                        &lineage,
                        &reply,
                        options.provider_registry.as_deref(),
                        llm,
                    );
                    usage = reply.usage.clone();
                    stop_reason = reply
                        .stop_reason
                        .as_deref()
                        .map(|value| json!(value))
                        .unwrap_or(Value::Null);
                    execution = json!({
                        "mode": selected.execution_mode,
                        "via": reply.via,
                        "detail": reply.detail
                    });
                    agent_message = message;
                    status = "acted".to_string();
                }
                Err(error) => {
                    blocked_event = add_event_with_metadata(
                        &root,
                        &topic_id,
                        "harvis",
                        "host",
                        "status_change",
                        &format!(
                            "Host step blocked while executing {}: {error}",
                            selected.slot_id
                        ),
                        Vec::new(),
                        "internal",
                        None,
                        json!({
                            "version": SPEAKER_STEP_VERSION,
                            "speaker_version": SPEAKER_SELECTION_VERSION,
                            "policy": SPEAKER_STEP_POLICY,
                            "question_id": question_id,
                            "selected_alias": selected.slot_id,
                            "selector_kind": selection.selector_kind,
                            "route_reason": selection.route_reason,
                            "reply_to_event_id": lineage["reply_to_event_id"],
                            "reply_to_agent_id": lineage["reply_to_agent_id"],
                            "reply_to_question_id": lineage["reply_to_question_id"],
                            "blocked": true,
                            "execution_error": error.to_string(),
                            "requires_human_review": true
                        }),
                    )?;
                    execution = json!({
                        "mode": selected.execution_mode,
                        "via": Value::Null,
                        "detail": format!("execution failed: {error}")
                    });
                    status = "blocked".to_string();
                }
            }
        } else {
            execution = json!({
                "mode": selected.execution_mode,
                "via": Value::Null,
                "detail": format!(
                    "participant '{}' is {}; selection recorded, no execution",
                    selected.slot_id, selected.execution_mode
                )
            });
            status = "recorded".to_string();
        }
    }

    // T309: post-step termination check — the messages and events recorded
    // by this step can satisfy the configured stop conditions.
    if let Some(matched) = evaluate_room_termination(&root, &topic_id, &termination_config)? {
        termination_view["step_status"] = json!(status);
        termination_view["matched"] = matched.clone();
        if matched_involves_approval_pending(&matched) {
            let run = suspend_room_run(&root, &topic_id, &matched)?;
            termination_view["room_run"] = room_run_summary(&run);
            status = RUN_STATE_SUSPENDED.to_string();
        } else {
            let run = terminate_room_run(&root, &topic_id, &matched)?;
            termination_view["room_run"] = room_run_summary(&run);
            status = RUN_STATE_TERMINATED.to_string();
        }
    } else {
        let run = ensure_room_run(&root, &topic_id)?;
        termination_view["room_run"] = room_run_summary(&run);
    }

    Ok(json!({
        "version": SPEAKER_STEP_VERSION,
        "speaker_version": SPEAKER_SELECTION_VERSION,
        "topic_id": topic_id,
        "status": status,
        "dry_run": options.dry_run,
        "termination": termination_view,
        "question_id": question_id,
        "reply_target": lineage,
        "selector": {
            "selector_kind": selection.selector_kind,
            "effective_selector": selection.effective_selector,
            "route_reason": selection.route_reason,
            "fallback": selection.fallback,
            "model_call": selection.model_call,
            "signals": selection.signals,
            "candidates": selection.candidates,
            "config_source": config.config_source
        },
        "speaker": selected.card(),
        "route": {
            "policy": SPEAKER_STEP_POLICY,
            "selected_alias": selected.slot_id,
            "selected_agent": selected.display_name,
            "reason": selection.route_reason,
            "signals": selection.signals,
            "authority": {
                "executes_files": false,
                "executes_commands": false,
                "requires_handoff_for_mutation": true
            }
        },
        "route_reason": selection.route_reason,
        "decision_record": decision_record,
        "host_event": host_event,
        "blocked_event": blocked_event,
        "user_message": user_message,
        "agent_message": agent_message,
        "message": message_view,
        "trace": trace_view,
        "usage": usage,
        "stop_reason": stop_reason,
        "execution": execution,
        "cards": {
            "decision": if options.dry_run { host_event.clone() } else { Value::Null },
            "handoff": Value::Null,
            "blocked": blocked_event,
            "evidence": [{
                "kind": "route_reason",
                "text": selection.route_reason
            }]
        },
        "safety": {
            "executes_files": false,
            "executes_commands": false,
            "requires_handoff_for_mutation": true,
            "participant_execution": "active participants run only their configured local harness or provider route"
        }
    }))
}

/// Compact run view embedded in step responses (T309).
fn room_run_summary(run: &Value) -> Value {
    json!({
        "run_id": run.get("run_id").cloned().unwrap_or(Value::Null),
        "topic_id": run.get("topic_id").cloned().unwrap_or(Value::Null),
        "state": run.get("state").cloned().unwrap_or(Value::Null),
        "suspension": run.get("suspension").cloned().unwrap_or(Value::Null),
        "termination": run.get("termination").cloned().unwrap_or(Value::Null)
    })
}

/// Early-return response for rooms in a first-class non-running state
/// (`suspended_awaiting_approval` / `terminated`).
fn step_state_response(topic_id: &str, status: &str, dry_run: bool, termination: Value) -> Value {
    json!({
        "version": SPEAKER_STEP_VERSION,
        "speaker_version": SPEAKER_SELECTION_VERSION,
        "topic_id": topic_id,
        "status": status,
        "dry_run": dry_run,
        "termination": termination,
        "safety": {
            "executes_files": false,
            "executes_commands": false,
            "requires_handoff_for_mutation": true
        }
    })
}

struct ExecutedReply {
    content: String,
    via: String,
    detail: String,
    model: Option<String>,
    usage: Value,
    stop_reason: Option<String>,
}

#[allow(clippy::too_many_arguments)]
fn execute_active_participant(
    root: &Path,
    topic_id: &str,
    question_id: &str,
    selected: &SpeakerCandidate,
    context: &RoomContext,
    lineage: &Value,
    config: &SpeakerSelectorConfig,
    registry_path: Option<&Path>,
    llm: &mut dyn FnMut(&LlmCallRequest) -> Result<LlmCallResponse>,
) -> Result<ExecutedReply> {
    let task = context
        .recent_messages
        .iter()
        .rev()
        .find(|message| message.get("agent_id").and_then(Value::as_str) == Some("human"))
        .and_then(|message| message.get("content").and_then(Value::as_str))
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| context.room_summary.clone());
    if let Some(harness) = selected
        .harness_ref
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let stdin_payload = json!({
            "version": SPEAKER_CONTRACT_ID,
            "agent_id": selected.slot_id,
            "role": selected.role,
            "display_name": selected.display_name,
            "topic_id": topic_id,
            "question_id": question_id,
            "task": task,
            "room_summary": context.room_summary,
            "signals": context.signals,
            "reply_to_event_id": lineage["reply_to_event_id"],
            "reply_to_agent_id": lineage["reply_to_agent_id"],
            "reply_to_question_id": lineage["reply_to_question_id"]
        });
        let output = run_command_with_timeout(
            harness,
            &stdin_payload.to_string(),
            config.harness_timeout_ms,
        )
        .with_context(|| format!("harness could not be started: {harness}"))?;
        if output.timed_out {
            bail!("harness timed out after {}ms", config.harness_timeout_ms);
        }
        if !output.success {
            bail!(
                "harness exited non-zero (code {:?}): {}",
                output.code,
                truncate(&output.stderr_tail, 200)
            );
        }
        let content = truncate(output.stdout.trim(), MAX_HARNESS_REPLY_CHARS);
        if content.is_empty() {
            bail!("harness produced an empty reply");
        }
        return Ok(ExecutedReply {
            content,
            via: "local_harness".to_string(),
            detail: format!("local harness '{harness}' executed via /bin/sh -c"),
            model: None,
            usage: json!({}),
            stop_reason: Some("harness_exit_0".to_string()),
        });
    }
    let _ = root;
    match resolve_slot_route(selected, registry_path) {
        Ok(Some(route)) => {
            let prompt = format!(
                "You are {} ({}) in H.A.R.V.I.S. Cognitive Host Stepper.\nReply in concise Chinese. Do not reveal hidden reasoning.\nHost question id: {}\nReply target event: {}\nReply target agent: {}\nTask: {}\n",
                selected.display_name,
                selected.role,
                question_id,
                lineage["reply_to_event_id"].as_str().unwrap_or(""),
                lineage["reply_to_agent_id"].as_str().unwrap_or(""),
                task
            );
            let response = llm(&LlmCallRequest {
                route: route.clone(),
                prompt,
                max_tokens: DEFAULT_REPLY_MAX_TOKENS,
                purpose: "participant_reply".to_string(),
            })
            .context("participant provider reply failed")?;
            let content = response.text.trim().to_string();
            if content.is_empty() {
                bail!("participant provider returned an empty reply");
            }
            Ok(ExecutedReply {
                content,
                via: "provider_route".to_string(),
                detail: format!("provider registry route '{}'", route.alias),
                model: Some(route.model.clone()),
                usage: response.usage,
                stop_reason: response.stop_reason,
            })
        }
        Ok(None) => bail!(
            "active participant has neither a local harness_ref nor a resolvable provider route"
        ),
        Err(error) => bail!("participant route resolution failed: {error}"),
    }
}

/// T311 / ROADMAP v0.45 trace extraction for one executed reply. Rule-based
/// marker parsing is the primary path; the configurable llm path (prompt
/// template in `[agent_room_trace]`, routed through the provider registry)
/// is optional and always falls back to rule drafts on failure. Persisted
/// events carry structured points only — never hidden chain-of-thought.
/// Extraction/persistence problems are reported in the returned view instead
/// of crashing the step (the reply itself is already recorded).
#[allow(clippy::too_many_arguments)]
fn run_trace_extraction(
    root: &Path,
    topic_id: &str,
    question_id: &str,
    selected: &SpeakerCandidate,
    message: &Value,
    lineage: &Value,
    reply: &ExecutedReply,
    registry_path: Option<&Path>,
    llm: &mut dyn FnMut(&LlmCallRequest) -> Result<LlmCallResponse>,
) -> Value {
    let config = load_trace_config(root);
    if !config.enabled {
        return trace_report(false, "disabled", &[], &config, None);
    }
    let rule_drafts = parse_trace_markers(&reply.content, config.max_events_per_reply);
    let mut drafts = rule_drafts;
    let mut extraction = TRACE_EXTRACTION_RULE;
    let mut llm_error: Option<String> = None;
    if config.extraction == TRACE_EXTRACTION_LLM {
        let attempt: Result<Vec<TraceDraft>> = (|| {
            let alias = config.model_alias.clone().ok_or_else(|| {
                anyhow::anyhow!("agent_room_trace extraction=llm requires model_alias")
            })?;
            let route = resolve_model_route(&alias, registry_path)
                .map_err(|error| anyhow::anyhow!("trace extraction route '{alias}': {error}"))?;
            let prompt = render_trace_prompt(
                &config.llm_prompt_template(),
                topic_id,
                question_id,
                lineage["reply_to_event_id"].as_str().unwrap_or(""),
                &reply.content,
                config.max_events_per_reply,
            );
            let response = llm(&LlmCallRequest {
                route,
                prompt,
                max_tokens: DEFAULT_LLM_EXTRACTION_MAX_TOKENS,
                purpose: "trace_extraction".to_string(),
            })
            .context("trace extraction model call failed")?;
            let parsed = parse_trace_extraction_json(&response.text, config.max_events_per_reply)?;
            if parsed.is_empty() {
                bail!("trace extraction returned zero drafts");
            }
            Ok(parsed)
        })();
        match attempt {
            Ok(llm_drafts) => {
                drafts = llm_drafts;
                extraction = TRACE_EXTRACTION_LLM;
            }
            Err(error) => {
                llm_error = Some(error.to_string());
                extraction = TRACE_EXTRACTION_RULE_FALLBACK;
            }
        }
    }
    let message_id = message
        .get("message_id")
        .and_then(Value::as_str)
        .unwrap_or("msg_unknown");
    let source_event_id = message
        .get("event_id")
        .and_then(Value::as_str)
        .unwrap_or("");
    match record_reply_traces(
        root,
        topic_id,
        &selected.slot_id,
        &selected.role,
        reply.model.as_deref(),
        message_id,
        source_event_id,
        question_id,
        lineage,
        &drafts,
        extraction,
    ) {
        Ok(events) => trace_report(true, extraction, &events, &config, llm_error.as_deref()),
        Err(error) => {
            let mut report = trace_report(true, extraction, &[], &config, llm_error.as_deref());
            report["persist_error"] = json!(format!("trace events not persisted: {error}"));
            report
        }
    }
}

fn resolve_slot_route(
    selected: &SpeakerCandidate,
    registry_path: Option<&Path>,
) -> Result<Option<ResolvedModelRoute>> {
    if let Some(alias) = selected
        .route_ref
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        if let Ok(route) = resolve_model_route(alias, registry_path) {
            return Ok(Some(route));
        }
    }
    let (Some(provider_ref), Some(model_ref)) = (
        selected.provider_ref.as_deref(),
        selected.model_ref.as_deref(),
    ) else {
        return Ok(None);
    };
    let Ok(registry) = load_provider_registry(registry_path) else {
        return Ok(None);
    };
    let Some((alias, _)) = registry
        .models
        .iter()
        .find(|(_, route)| route.provider == provider_ref && route.model == model_ref)
    else {
        return Ok(None);
    };
    resolve_model_route(alias, registry_path).map(Some)
}

fn speaker_message_view(
    message: &Value,
    selected: &SpeakerCandidate,
    topic_id: &str,
    question_id: &str,
    lineage: &Value,
    route_reason: &str,
    reply: &ExecutedReply,
) -> Value {
    let message_id = message
        .get("message_id")
        .and_then(Value::as_str)
        .unwrap_or("msg_unknown")
        .to_string();
    json!({
        "id": message_id,
        "event_id": message.get("event_id").and_then(Value::as_str).unwrap_or(""),
        "agent": selected.display_name,
        "agent_id": selected.slot_id,
        "alias": selected.slot_id,
        "role": selected.role,
        "event_kind": "agent_message",
        "initial": selected
            .display_name
            .chars()
            .next()
            .unwrap_or('?')
            .to_ascii_uppercase()
            .to_string(),
        "color": "#4f6fd8",
        "time": message.get("created_at").and_then(Value::as_str).unwrap_or(""),
        "topic": topic_id,
        "question_id": question_id,
        "reply_to_event_id": lineage["reply_to_event_id"].as_str().unwrap_or(""),
        "reply_to_agent_id": lineage["reply_to_agent_id"].as_str().unwrap_or(""),
        "reply_to_question_id": lineage["reply_to_question_id"].as_str().unwrap_or(""),
        "route_reason": route_reason,
        "tags": [
            format!("evt_{}_host_step_reply", selected.slot_id),
            message_id,
            format!(
                "usage_out_{}",
                reply.usage.get("output_tokens").and_then(Value::as_i64).unwrap_or(0)
            )
        ],
        "note": format!(
            "H.A.R.V.I.S. speaker step -> {} via {}",
            selected.slot_id, reply.via
        ),
        "content": reply.content
    })
}

fn infer_step_lineage(
    context: &RoomContext,
    options: &SpeakerStepOptions,
    root: &Path,
    topic_id: &str,
) -> Value {
    let explicit = |value: &Option<String>| -> Option<String> {
        value
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    };
    let latest_event = list_agent_room(root, 80)
        .ok()
        .and_then(|room| {
            room.get("events")
                .and_then(Value::as_array)
                .cloned()
                .map(|events| {
                    events.into_iter().rev().find(|event| {
                        event.get("topic_id").and_then(Value::as_str) == Some(topic_id)
                    })
                })
        })
        .flatten();
    let latest_message = context.latest_message.clone();

    let reply_to_event_id = explicit(&options.reply_to_event_id)
        .or_else(|| {
            latest_message
                .as_ref()
                .and_then(|message| message.get("event_id").and_then(Value::as_str))
                .map(ToOwned::to_owned)
        })
        .or_else(|| {
            latest_event
                .as_ref()
                .and_then(|event| event.get("event_id").and_then(Value::as_str))
                .map(ToOwned::to_owned)
        })
        .unwrap_or_default();
    let reply_to_agent_id = explicit(&options.reply_to_agent_id)
        .or_else(|| {
            latest_message
                .as_ref()
                .and_then(|message| message.get("agent_id").and_then(Value::as_str))
                .map(ToOwned::to_owned)
        })
        .or_else(|| {
            latest_event
                .as_ref()
                .and_then(|event| event.get("agent_id").and_then(Value::as_str))
                .map(ToOwned::to_owned)
        })
        .unwrap_or_default();
    let reply_to_question_id = explicit(&options.reply_to_question_id)
        .or_else(|| {
            latest_event
                .as_ref()
                .and_then(|event| event.get("metadata").cloned())
                .and_then(|metadata| {
                    metadata
                        .get("question_id")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                })
        })
        .unwrap_or_default();

    json!({
        "reply_to_event_id": reply_to_event_id,
        "reply_to_agent_id": reply_to_agent_id,
        "reply_to_question_id": reply_to_question_id
    })
}

fn make_question_id(topic_id: &str, seed: &str) -> String {
    use sha2::{Digest, Sha256};
    let moment = now_rfc3339().unwrap_or_else(|_| "now".to_string());
    let digest = Sha256::digest(format!("{topic_id}|{seed}|{moment}").as_bytes())
        .iter()
        .take(5)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("question_{digest}")
}

fn make_decision_id(topic_id: &str, agent_id: &str, question_id: &str, ts: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(format!("{topic_id}|{agent_id}|{question_id}|{ts}").as_bytes())
        .iter()
        .take(6)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("speaker_{digest}")
}

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    value.chars().take(max_chars).collect::<String>()
}

fn resolve_root(value: &Path) -> Result<PathBuf> {
    if value.as_os_str().is_empty() {
        bail!("workspace root must be a non-empty path");
    }
    if value.is_absolute() {
        Ok(value.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(value))
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_room::{
        append_chair_decision, read_chair_decisions, upsert_participant, ParticipantInput,
    };
    use crate::init::init_workspace;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    fn temp_root(tag: &str) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("harvis-speaker-{tag}-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        root.canonicalize().expect("canonical root")
    }

    fn no_llm() -> impl FnMut(&LlmCallRequest) -> Result<LlmCallResponse> {
        |_request: &LlmCallRequest| -> Result<LlmCallResponse> {
            bail!("no llm call expected in this test")
        }
    }

    fn write_script(root: &Path, name: &str, body: &str) -> String {
        let path = root.join(name);
        fs::write(&path, body).expect("write script");
        let mut permissions = fs::metadata(&path).expect("metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&path, permissions).expect("chmod");
        path.display().to_string()
    }

    fn candidates(root: &Path) -> Vec<SpeakerCandidate> {
        load_candidates(root, None).expect("candidates")
    }

    // -- configuration ----------------------------------------------------

    #[test]
    fn speaker_config_defaults_to_round_robin_without_config() {
        let root = temp_root("config-default");
        let config = load_speaker_config(&root);
        assert_eq!(config.selector, SELECTOR_ROUND_ROBIN);
        assert!(config.config_error.is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_config_reads_llm_tier_from_harvis_toml() {
        let root = temp_root("config-llm");
        fs::write(
            root.join(".harvis/harvis.toml"),
            r#"
[agent_room_speaker]
selector = "llm"
model_alias = "d4f"
prompt_template = "pick one from {{candidates}}"
max_tokens = 256
timeout_ms = 2500
"#,
        )
        .expect("write config");
        let config = load_speaker_config(&root);
        assert_eq!(config.selector, SELECTOR_LLM);
        assert_eq!(config.model_alias.as_deref(), Some("d4f"));
        assert_eq!(
            config.prompt_template.as_deref(),
            Some("pick one from {{candidates}}")
        );
        assert_eq!(config.max_tokens, 256);
        assert_eq!(config.timeout_ms, 2500);
        assert!(config.config_error.is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_config_rejects_unknown_selector_with_fallback() {
        let root = temp_root("config-bogus");
        fs::write(
            root.join(".harvis/harvis.toml"),
            "[agent_room_speaker]\nselector = \"bogus\"\n",
        )
        .expect("write config");
        let config = load_speaker_config(&root);
        assert_eq!(config.selector, SELECTOR_ROUND_ROBIN);
        assert!(config
            .config_error
            .as_deref()
            .is_some_and(|error| error.contains("bogus")));
        let _ = fs::remove_dir_all(root);
    }

    // -- round-robin --------------------------------------------------------

    #[test]
    fn speaker_round_robin_rotates_via_decision_records() {
        let root = temp_root("rr-rotate");
        let roster = candidates(&root);
        assert!(roster.len() >= 3);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = SpeakerSelectorConfig::default();
        let mut llm = no_llm();
        let mut picked = Vec::new();
        for _ in 0..3 {
            let selection =
                select_speaker(&root, &config, &context, &roster, None, false, &mut llm)
                    .expect("select");
            assert_eq!(selection.selector_kind, SELECTOR_ROUND_ROBIN);
            assert!(!selection.fallback);
            picked.push(selection.agent_id.clone());
            append_chair_decision(
                &root,
                &json!({
                    "schemaVersion": CHAIR_DECISION_SCHEMA,
                    "topic_id": "gwt-workbench",
                    "selected_agent_id": selection.agent_id,
                    "selector_kind": selection.selector_kind,
                    "route_reason": selection.route_reason,
                    "question_id": Value::Null,
                    "ts": now_rfc3339().expect("ts")
                }),
            )
            .expect("decision");
        }
        assert_eq!(picked[0], roster[0].slot_id);
        assert_eq!(picked[1], roster[1].slot_id);
        assert_eq!(picked[2], roster[2].slot_id);
        let _ = fs::remove_dir_all(root);
    }

    // -- signals ------------------------------------------------------------

    #[test]
    fn speaker_mention_signal_detects_display_name() {
        let root = temp_root("mention");
        add_message(
            &root,
            "gwt-workbench",
            "human",
            "user",
            "@DeepSeek 你怎么看这个方案？",
            Vec::new(),
            "internal",
            None,
        )
        .expect("message");
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        assert_eq!(
            context.signals["explicit_mention"]["slot_id"],
            json!("harvis-chair")
        );
        assert_eq!(context.signals["unanswered_question"], json!(true));
        let _ = fs::remove_dir_all(root);
    }

    // -- llm selector ---------------------------------------------------------

    fn write_registry(root: &Path) -> PathBuf {
        let token_file = root.join("fixture-token");
        fs::write(&token_file, "token: sk-fixturetoken123456").expect("token");
        let registry = root.join("providers.toml");
        fs::write(
            &registry,
            format!(
                r#"
[providers.fixture]
kind = "openai-compatible"
base_url = "http://127.0.0.1:1"
access_file = "{}"

[models.d4f]
provider = "fixture"
model = "fixture-model"
agent = "Fixture"
role = "selector"
"#,
                token_file.display()
            ),
        )
        .expect("registry");
        registry
    }

    fn llm_config(root: &Path) -> SpeakerSelectorConfig {
        fs::write(
            root.join(".harvis/harvis.toml"),
            "[agent_room_speaker]\nselector = \"llm\"\nmodel_alias = \"d4f\"\n",
        )
        .expect("write config");
        load_speaker_config(root)
    }

    #[test]
    fn speaker_llm_selector_parses_model_json_with_mention() {
        let root = temp_root("llm-parse");
        let registry = write_registry(&root);
        add_message(
            &root,
            "gwt-workbench",
            "human",
            "user",
            "@DeepSeek 请评审当前方案",
            Vec::new(),
            "internal",
            None,
        )
        .expect("message");
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", Some("question_test"), &roster)
            .expect("context");
        let config = llm_config(&root);
        let mut llm = |request: &LlmCallRequest| -> Result<LlmCallResponse> {
            assert_eq!(request.route.alias, "d4f");
            assert_eq!(request.purpose, "speaker_selection");
            assert!(request.prompt.contains("@DeepSeek"));
            assert!(request.prompt.contains("harvis-chair"));
            Ok(LlmCallResponse {
                text: "```json\n{\"agent_id\": \"harvis-chair\", \"route_reason\": \"explicit @DeepSeek mention routes to the DeepSeek chair\"}\n```"
                    .to_string(),
                usage: json!({}),
                stop_reason: Some("end_turn".to_string()),
            })
        };
        let selection = select_speaker(
            &root,
            &config,
            &context,
            &roster,
            Some(&registry),
            true,
            &mut llm,
        )
        .expect("select");
        assert_eq!(selection.selector_kind, SELECTOR_LLM);
        assert_eq!(selection.effective_selector, SELECTOR_LLM);
        assert!(!selection.fallback);
        assert!(selection.model_call);
        assert_eq!(selection.agent_id, "harvis-chair");
        assert!(selection.route_reason.contains("@DeepSeek"));
        assert_eq!(selection.question_id.as_deref(), Some("question_test"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_llm_selector_falls_back_on_unknown_agent() {
        let root = temp_root("llm-unknown");
        let registry = write_registry(&root);
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = llm_config(&root);
        let mut llm = |_request: &LlmCallRequest| -> Result<LlmCallResponse> {
            Ok(LlmCallResponse {
                text: "{\"agent_id\": \"nobody\", \"route_reason\": \"hallucinated\"}".to_string(),
                usage: json!({}),
                stop_reason: None,
            })
        };
        let selection = select_speaker(
            &root,
            &config,
            &context,
            &roster,
            Some(&registry),
            true,
            &mut llm,
        )
        .expect("select");
        assert_eq!(selection.selector_kind, SELECTOR_LLM);
        assert_eq!(selection.effective_selector, SELECTOR_ROUND_ROBIN);
        assert!(selection.fallback);
        assert!(selection.route_reason.contains("unknown agent"));
        assert_eq!(selection.agent_id, roster[0].slot_id);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_llm_selector_requires_route_reason() {
        let root = temp_root("llm-noreason");
        let registry = write_registry(&root);
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = llm_config(&root);
        let mut llm = |_request: &LlmCallRequest| -> Result<LlmCallResponse> {
            Ok(LlmCallResponse {
                text: "{\"agent_id\": \"planner\", \"route_reason\": \"\"}".to_string(),
                usage: json!({}),
                stop_reason: None,
            })
        };
        let selection = select_speaker(
            &root,
            &config,
            &context,
            &roster,
            Some(&registry),
            true,
            &mut llm,
        )
        .expect("select");
        assert!(selection.fallback);
        assert!(selection.route_reason.contains("route_reason"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_llm_selector_skips_model_call_in_dry_run() {
        let root = temp_root("llm-dryrun");
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = llm_config(&root);
        let mut llm = no_llm();
        let selection = select_speaker(&root, &config, &context, &roster, None, false, &mut llm)
            .expect("select");
        assert_eq!(selection.selector_kind, SELECTOR_LLM);
        assert_eq!(selection.effective_selector, SELECTOR_ROUND_ROBIN);
        assert!(selection.fallback);
        assert!(!selection.model_call);
        assert!(selection.route_reason.contains("dry_run"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_selection_serializes_null_question_id() {
        let root = temp_root("null-qid");
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = SpeakerSelectorConfig::default();
        let mut llm = no_llm();
        let selection = select_speaker(&root, &config, &context, &roster, None, false, &mut llm)
            .expect("select");
        assert!(selection.question_id.is_none());
        let rendered =
            serde_json::to_string(&json!({"question_id": selection.question_id})).expect("json");
        assert!(rendered.contains("null"));
        let _ = fs::remove_dir_all(root);
    }

    // -- custom function selector -------------------------------------------

    fn custom_config(root: &Path, command: &str, timeout_ms: u64) -> SpeakerSelectorConfig {
        fs::write(
            root.join(".harvis/harvis.toml"),
            format!(
                "[agent_room_speaker]\nselector = \"custom_function\"\ncommand = \"{command}\"\ntimeout_ms = {timeout_ms}\n"
            ),
        )
        .expect("write config");
        load_speaker_config(root)
    }

    #[test]
    fn speaker_custom_function_roundtrip_contract() {
        let root = temp_root("custom-ok");
        let script = write_script(
            &root,
            "selector.sh",
            "#!/bin/sh\ncat >/dev/null\nprintf '%s' '{\"agent_id\": \"executor\", \"route_reason\": \"script picked the executor slot\"}'\n",
        );
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = custom_config(&root, &script, 5_000);
        let mut llm = no_llm();
        let selection = select_speaker(&root, &config, &context, &roster, None, true, &mut llm)
            .expect("select");
        assert_eq!(selection.selector_kind, SELECTOR_CUSTOM_FUNCTION);
        assert_eq!(selection.effective_selector, SELECTOR_CUSTOM_FUNCTION);
        assert!(!selection.fallback);
        assert_eq!(selection.agent_id, "executor");
        assert!(selection.route_reason.contains("script picked"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_custom_function_stdin_carries_room_contract() {
        let root = temp_root("custom-stdin");
        let capture = root.join("captured-stdin.json");
        let script = write_script(
            &root,
            "capture.sh",
            &format!(
                "#!/bin/sh\ncat > {}\nprintf '%s' '{{\"agent_id\": \"planner\", \"route_reason\": \"captured stdin\"}}'\n",
                capture.display()
            ),
        );
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = custom_config(&root, &script, 5_000);
        let mut llm = no_llm();
        select_speaker(&root, &config, &context, &roster, None, true, &mut llm).expect("select");
        let captured: Value =
            serde_json::from_str(&fs::read_to_string(&capture).expect("captured")).expect("json");
        assert_eq!(captured["version"], json!(SPEAKER_CONTRACT_ID));
        assert_eq!(captured["topic_id"], json!("gwt-workbench"));
        assert_eq!(captured["question_id"], Value::Null);
        assert!(captured["candidates"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item["slot_id"] == "planner")));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_custom_function_nonzero_exit_falls_back() {
        let root = temp_root("custom-nonzero");
        let script = write_script(&root, "fail.sh", "#!/bin/sh\nexit 2\n");
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = custom_config(&root, &script, 5_000);
        let mut llm = no_llm();
        let selection = select_speaker(&root, &config, &context, &roster, None, true, &mut llm)
            .expect("select");
        assert_eq!(selection.selector_kind, SELECTOR_CUSTOM_FUNCTION);
        assert_eq!(selection.effective_selector, SELECTOR_ROUND_ROBIN);
        assert!(selection.fallback);
        assert!(selection.route_reason.contains("non-zero"));
        assert_eq!(selection.agent_id, roster[0].slot_id);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_custom_function_timeout_falls_back() {
        let root = temp_root("custom-timeout");
        let script = write_script(&root, "slow.sh", "#!/bin/sh\nsleep 3\n");
        let roster = candidates(&root);
        let context = build_room_context(&root, "gwt-workbench", None, &roster).expect("context");
        let config = custom_config(&root, &script, 150);
        let mut llm = no_llm();
        let selection = select_speaker(&root, &config, &context, &roster, None, true, &mut llm)
            .expect("select");
        assert_eq!(selection.selector_kind, SELECTOR_CUSTOM_FUNCTION);
        assert_eq!(selection.effective_selector, SELECTOR_ROUND_ROBIN);
        assert!(selection.fallback);
        assert!(selection.route_reason.contains("timed out"));
        let _ = fs::remove_dir_all(root);
    }

    // -- step orchestration ---------------------------------------------------

    #[test]
    fn speaker_step_writes_chair_decision_fields() {
        let root = temp_root("step-decision");
        let mut llm = no_llm();
        let result = agent_room_speaker_step(
            &SpeakerStepOptions {
                root: root.clone(),
                topic_id: Some("gwt-workbench".to_string()),
                prompt: Some("请审视当前圆桌状态".to_string()),
                dry_run: true,
                ..SpeakerStepOptions::default()
            },
            &mut llm,
        )
        .expect("step");
        assert_eq!(result["version"], json!(SPEAKER_STEP_VERSION));
        assert_eq!(result["status"], json!("planned"));
        assert_eq!(
            result["selector"]["selector_kind"],
            json!(SELECTOR_ROUND_ROBIN)
        );
        let question_id = result["question_id"]
            .as_str()
            .expect("question id")
            .to_string();
        let decisions = read_chair_decisions(&root, 10).expect("decisions");
        let record = decisions.last().expect("one decision");
        assert_eq!(record["selector_kind"], json!(SELECTOR_ROUND_ROBIN));
        assert_eq!(record["question_id"], json!(question_id));
        assert!(record["route_reason"]
            .as_str()
            .is_some_and(|r| !r.is_empty()));
        assert!(record["ts"].as_str().is_some_and(|t| !t.is_empty()));
        assert_eq!(record["schemaVersion"], json!(CHAIR_DECISION_SCHEMA));
        assert_eq!(record["topic_id"], json!("gwt-workbench"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_step_rotates_speakers_across_steps() {
        let root = temp_root("step-rotate");
        let roster = candidates(&root);
        let mut llm = no_llm();
        let mut picked = Vec::new();
        for _ in 0..3 {
            let result = agent_room_speaker_step(
                &SpeakerStepOptions {
                    root: root.clone(),
                    topic_id: Some("gwt-workbench".to_string()),
                    prompt: None,
                    dry_run: true,
                    ..SpeakerStepOptions::default()
                },
                &mut llm,
            )
            .expect("step");
            picked.push(result["speaker"]["slot_id"].as_str().unwrap().to_string());
        }
        assert_eq!(picked[0], roster[0].slot_id);
        assert_eq!(picked[1], roster[1].slot_id);
        assert_eq!(picked[2], roster[2].slot_id);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_step_record_only_selection_does_not_execute() {
        let root = temp_root("step-record-only");
        let mut llm = no_llm();
        let messages_before = list_agent_room(&root, 200).expect("room")["messages"]
            .as_array()
            .map(Vec::len)
            .unwrap_or(0);
        let result = agent_room_speaker_step(
            &SpeakerStepOptions {
                root: root.clone(),
                topic_id: Some("gwt-workbench".to_string()),
                prompt: Some("记录一步但不执行".to_string()),
                dry_run: false,
                ..SpeakerStepOptions::default()
            },
            &mut llm,
        )
        .expect("step");
        assert_eq!(result["status"], json!("recorded"));
        assert_eq!(result["agent_message"], Value::Null);
        assert_eq!(result["execution"]["mode"], json!("record_only"));
        let room = list_agent_room(&root, 200).expect("room");
        let messages = room["messages"].as_array().expect("messages");
        // exactly one new message: the injected human prompt; no agent reply
        assert_eq!(messages.len(), messages_before + 1);
        assert_eq!(messages.last().unwrap()["agent_id"], json!("human"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_step_active_participant_executes_local_harness() {
        let root = temp_root("step-active");
        let script = write_script(
            &root,
            "echo_harness.sh",
            "#!/bin/sh\ncat >/dev/null\nprintf '%s' '回声 harness 已真实执行：收到任务并回复。'\n",
        );
        upsert_participant(
            &root,
            ParticipantInput {
                slot_id: "echo-bot".to_string(),
                role: "responder".to_string(),
                display_name: "Echo Bot".to_string(),
                execution_mode: Some("active".to_string()),
                harness_ref: Some(script),
                ..ParticipantInput::default()
            },
        )
        .expect("upsert");
        // Seed a decision for the slot right before echo-bot so round-robin
        // lands on echo-bot.
        append_chair_decision(
            &root,
            &json!({
                "schemaVersion": CHAIR_DECISION_SCHEMA,
                "topic_id": "gwt-workbench",
                "selected_agent_id": "mail",
                "selector_kind": SELECTOR_ROUND_ROBIN,
                "route_reason": "seed for rotation",
                "question_id": Value::Null,
                "ts": now_rfc3339().expect("ts")
            }),
        )
        .expect("seed decision");
        let mut llm = no_llm();
        let result = agent_room_speaker_step(
            &SpeakerStepOptions {
                root: root.clone(),
                topic_id: Some("gwt-workbench".to_string()),
                prompt: Some("请回声机器人回复".to_string()),
                dry_run: false,
                ..SpeakerStepOptions::default()
            },
            &mut llm,
        )
        .expect("step");
        assert_eq!(result["status"], json!("acted"));
        assert_eq!(result["speaker"]["slot_id"], json!("echo-bot"));
        assert_eq!(result["execution"]["via"], json!("local_harness"));
        assert_eq!(result["agent_message"]["agent_id"], json!("echo-bot"));
        assert!(result["agent_message"]["content"]
            .as_str()
            .is_some_and(|content| content.contains("真实执行")));
        // the reply really landed in messages.jsonl
        let room = list_agent_room(&root, 200).expect("room");
        assert!(room["messages"]
            .as_array()
            .expect("messages")
            .iter()
            .any(|message| message["agent_id"] == "echo-bot"
                && message["content"]
                    .as_str()
                    .is_some_and(|content| content.contains("真实执行"))));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_step_active_harness_failure_records_blocked_event() {
        let root = temp_root("step-harness-fail");
        let script = write_script(&root, "broken.sh", "#!/bin/sh\necho boom 1>&2\nexit 3\n");
        upsert_participant(
            &root,
            ParticipantInput {
                slot_id: "broken-bot".to_string(),
                role: "responder".to_string(),
                display_name: "Broken Bot".to_string(),
                execution_mode: Some("active".to_string()),
                harness_ref: Some(script),
                ..ParticipantInput::default()
            },
        )
        .expect("upsert");
        append_chair_decision(
            &root,
            &json!({
                "schemaVersion": CHAIR_DECISION_SCHEMA,
                "topic_id": "gwt-workbench",
                "selected_agent_id": "mail",
                "selector_kind": SELECTOR_ROUND_ROBIN,
                "route_reason": "seed for rotation",
                "question_id": Value::Null,
                "ts": now_rfc3339().expect("ts")
            }),
        )
        .expect("seed decision");
        let mut llm = no_llm();
        let result = agent_room_speaker_step(
            &SpeakerStepOptions {
                root: root.clone(),
                topic_id: Some("gwt-workbench".to_string()),
                prompt: Some("触发失败的 harness".to_string()),
                dry_run: false,
                ..SpeakerStepOptions::default()
            },
            &mut llm,
        )
        .expect("step must not crash");
        assert_eq!(result["status"], json!("blocked"));
        assert_eq!(result["speaker"]["slot_id"], json!("broken-bot"));
        assert!(result["blocked_event"]["metadata"]["blocked"]
            .as_bool()
            .unwrap());
        assert!(result["blocked_event"]["metadata"]["execution_error"]
            .as_str()
            .is_some_and(|error| error.contains("non-zero")));
        assert_eq!(result["agent_message"], Value::Null);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn speaker_participant_upsert_rejects_unknown_execution_mode() {
        let root = temp_root("mode-validation");
        let error = upsert_participant(
            &root,
            ParticipantInput {
                slot_id: "bogus-bot".to_string(),
                role: "responder".to_string(),
                display_name: "Bogus Bot".to_string(),
                execution_mode: Some("sometimes".to_string()),
                ..ParticipantInput::default()
            },
        )
        .expect_err("unknown execution_mode must be rejected");
        assert!(error.to_string().contains("execution_mode"));
        upsert_participant(
            &root,
            ParticipantInput {
                slot_id: "active-bot".to_string(),
                role: "responder".to_string(),
                display_name: "Active Bot".to_string(),
                execution_mode: Some("active".to_string()),
                ..ParticipantInput::default()
            },
        )
        .expect("active mode accepted");
        let participants = list_participants(&root, None).expect("participants");
        let file: Value = serde_json::from_str(
            &fs::read_to_string(root.join(".harvis/agent-room/participants.json"))
                .expect("participants file"),
        )
        .expect("json");
        assert_eq!(file["safety"]["record_only"], json!(false));
        assert!(participants["participants"]
            .as_array()
            .expect("array")
            .iter()
            .any(|slot| slot["slot_id"] == "active-bot" && slot["execution_mode"] == "active"));
        let _ = fs::remove_dir_all(root);
    }
}
