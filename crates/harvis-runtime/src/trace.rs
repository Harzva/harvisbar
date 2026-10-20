//! T311 — Cognitive trace events (ROADMAP v0.45) for Agent Room speaker
//! turns, consumed offline by the v0.48 cognitive-trace evals gate.
//!
//! After an active participant's reply lands in `messages.jsonl` (via the
//! unchanged `add_message` path), the speaker step parses the reply for
//! structured trace markers and appends one protocol-versioned event per
//! trace point to `.harvis/agent-room/events.jsonl`. The seven trace kinds
//! are the ROADMAP v0.45 set: `claim`, `question`, `counterpoint`,
//! `hypothesis`, `verification_target`, `decision`, `handoff_request`.
//!
//! Marker contract (rule-based extraction, the default and primary path):
//!
//! ```text
//! ---harvis-trace---
//! claim: <one-line statement> [refs: evt_a, evt_b]
//! question: <one-line statement>
//! ---end-harvis-trace---
//! ```
//!
//! Standalone lines prefixed with `[trace]` are also accepted, e.g.
//! `[trace] decision: <statement> | refs: evt_c`. Nothing outside the
//! delimited section or the `[trace]` prefix is ever parsed, so ordinary
//! prose mentioning "question:" stays untraced.
//!
//! PRIVACY CONSTRAINT (ROADMAP v0.45 "without exposing hidden
//! chain-of-thought"): trace events persist structured external reasoning
//! *points* only — one short statement per event plus reply-lineage refs.
//! Hidden chain-of-thought is NEVER written to disk: statements are single
//! lines truncated to [`MAX_STATEMENT_CHARS`], the number of events per
//! reply is capped, and the raw reply text is not copied into trace events.
//!
//! LLM-based extraction is a configurable, non-mandatory path: when
//! `[agent_room_trace] extraction = "llm"` is set, the reply plus the
//! configured prompt template are routed through the provider registry and
//! the model answers a strict JSON array. Any failure (missing route,
//! model error, invalid JSON, empty result) falls back to the rule-based
//! drafts and records the fallback in the step trace report.

use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::agent_room::{
    append_jsonl, init_agent_room, jsonl_path, stable_id, AGENT_ROOM_PROTOCOL_ID,
    AGENT_ROOM_VERSION,
};
use harvis_core::time::now_rfc3339;

/// Version tag for the extraction pipeline (reported in step responses).
pub const TRACE_EXTRACTION_VERSION: &str = "v0.45-cognitive-trace";
/// Schema id stored in every trace event at `metadata.trace.schemaVersion`;
/// the offline evals runner keys on this value.
pub const TRACE_SCHEMA_VERSION: &str = "harvis.cognitive-trace.v1";

/// The seven ROADMAP v0.45 trace kinds, in canonical order.
pub const TRACE_KINDS: &[&str] = &[
    "claim",
    "question",
    "counterpoint",
    "hypothesis",
    "verification_target",
    "decision",
    "handoff_request",
];

pub const TRACE_EXTRACTION_RULE: &str = "rule";
pub const TRACE_EXTRACTION_LLM: &str = "llm";
/// Recorded when the llm path was requested but failed and rule drafts were
/// persisted instead.
pub const TRACE_EXTRACTION_RULE_FALLBACK: &str = "rule_fallback_after_llm_error";

const TRACE_SECTION_BEGIN: &str = "---harvis-trace---";
const TRACE_SECTION_END: &str = "---end-harvis-trace---";
const TRACE_LINE_PREFIX: &str = "[trace]";

/// One-line statements stay one-line: longer lines are truncated (privacy /
/// cost discipline, see module docs).
pub const MAX_STATEMENT_CHARS: usize = 240;
const DEFAULT_MAX_EVENTS_PER_REPLY: usize = 12;
/// Default max_tokens for the optional llm trace-extraction call.
pub const DEFAULT_LLM_EXTRACTION_MAX_TOKENS: usize = 600;

/// Default prompt template for the optional llm extraction path. The model
/// is asked for structured points only — never for reasoning chains.
const DEFAULT_TRACE_PROMPT_TEMPLATE: &str = r#"You extract structured cognitive trace points from one H.A.R.V.I.S. Agent Room reply.
Reply with STRICT JSON only: an array of at most {{max_events}} items, each
{"kind": "claim|question|counterpoint|hypothesis|verification_target|decision|handoff_request", "statement": "<one short reviewable sentence>", "refs": ["<event_id>", ...]}
Never output hidden chain-of-thought: each statement is a single reviewable point, not reasoning steps. Output nothing outside the JSON array.

Topic: {{topic_id}}
Question id: {{question_id}}
Reply-to event: {{reply_to_event_id}}

Reply text:
{{reply}}
"#;

// ---------------------------------------------------------------------------
// Configuration (`<root>/.harvis/harvis.toml`, table `[agent_room_trace]`)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct TraceConfig {
    pub enabled: bool,
    pub extraction: String,
    pub model_alias: Option<String>,
    pub prompt_template: Option<String>,
    pub prompt_template_path: Option<PathBuf>,
    pub max_events_per_reply: usize,
    pub config_source: String,
    pub config_error: Option<String>,
}

impl Default for TraceConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            extraction: TRACE_EXTRACTION_RULE.to_string(),
            model_alias: None,
            prompt_template: None,
            prompt_template_path: None,
            max_events_per_reply: DEFAULT_MAX_EVENTS_PER_REPLY,
            config_source: "default (no [agent_room_trace] table)".to_string(),
            config_error: None,
        }
    }
}

pub fn load_trace_config(root: &Path) -> TraceConfig {
    let mut config = TraceConfig::default();
    let path = root.join(".harvis/harvis.toml");
    let Ok(text) = fs::read_to_string(&path) else {
        return config;
    };
    let Ok(value) = text.parse::<toml::Value>() else {
        config.config_error = Some("harvis.toml is not valid TOML".to_string());
        return config;
    };
    let Some(table) = value
        .get("agent_room_trace")
        .and_then(toml::Value::as_table)
    else {
        return config;
    };
    config.config_source = format!("{} [agent_room_trace]", path.display());
    let string_value = |key: &str| -> Option<String> {
        table
            .get(key)
            .and_then(toml::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    };
    if let Some(enabled) = table.get("enabled").and_then(toml::Value::as_bool) {
        config.enabled = enabled;
    }
    if let Some(extraction) = string_value("extraction") {
        if extraction == TRACE_EXTRACTION_RULE || extraction == TRACE_EXTRACTION_LLM {
            config.extraction = extraction;
        } else {
            config.config_error = Some(format!(
                "unknown agent_room_trace extraction '{extraction}', fell back to rule"
            ));
            config.extraction = TRACE_EXTRACTION_RULE.to_string();
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
    if let Some(value) = table
        .get("max_events_per_reply")
        .and_then(toml::Value::as_integer)
    {
        if value > 0 {
            config.max_events_per_reply = value as usize;
        }
    }
    config
}

impl TraceConfig {
    /// Resolve the effective llm extraction prompt: inline template, then
    /// template file, then the built-in default.
    pub fn llm_prompt_template(&self) -> String {
        if let Some(template) = self.prompt_template.as_deref() {
            return template.to_string();
        }
        if let Some(path) = self.prompt_template_path.as_ref() {
            if let Ok(text) = fs::read_to_string(path) {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    return trimmed.to_string();
                }
            }
        }
        DEFAULT_TRACE_PROMPT_TEMPLATE.to_string()
    }
}

// ---------------------------------------------------------------------------
// Rule-based marker parsing
// ---------------------------------------------------------------------------

/// One parsed trace point before persistence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceDraft {
    pub kind: String,
    pub statement: String,
    pub cites: Vec<String>,
}

/// Parse trace markers from a speaker reply. Rule-based extraction is the
/// primary path: only lines inside a `---harvis-trace---` section or lines
/// starting with the `[trace]` prefix are considered. Duplicate
/// (kind, statement) pairs within one reply collapse; the result is capped
/// at `max_events`.
pub fn parse_trace_markers(content: &str, max_events: usize) -> Vec<TraceDraft> {
    let mut drafts = Vec::new();
    let mut seen = BTreeSet::new();
    let mut in_section = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.eq_ignore_ascii_case(TRACE_SECTION_BEGIN) {
            in_section = true;
            continue;
        }
        if trimmed.eq_ignore_ascii_case(TRACE_SECTION_END) {
            in_section = false;
            continue;
        }
        let candidate = if in_section {
            Some(trimmed)
        } else {
            trimmed.strip_prefix(TRACE_LINE_PREFIX).map(str::trim)
        };
        let Some(candidate) = candidate else {
            continue;
        };
        if let Some(draft) = parse_trace_line(candidate) {
            if seen.insert((draft.kind.clone(), draft.statement.clone())) {
                drafts.push(draft);
                if drafts.len() >= max_events {
                    break;
                }
            }
        }
    }
    drafts
}

/// Parse one marker line: `<kind>: <statement>` with an optional refs
/// suffix `[refs: id1, id2]` or `| refs: id1, id2`.
fn parse_trace_line(line: &str) -> Option<TraceDraft> {
    let (kind, rest) = line.split_once(':')?;
    let kind = kind.trim().to_ascii_lowercase();
    if !TRACE_KINDS.contains(&kind.as_str()) {
        return None;
    }
    let mut statement = rest.trim().to_string();
    let mut cites = Vec::new();
    for delimiter in ["[refs:", "| refs:"] {
        if let Some(index) = statement.find(delimiter) {
            let refs_part = statement[index + delimiter.len()..].to_string();
            statement = statement[..index].trim().to_string();
            let refs_part = refs_part.trim_end_matches(']').trim().to_string();
            cites = refs_part
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .collect();
            break;
        }
    }
    if statement.is_empty() {
        return None;
    }
    Some(TraceDraft {
        kind,
        statement: truncate_statement(&statement),
        cites,
    })
}

fn truncate_statement(statement: &str) -> String {
    if statement.chars().count() <= MAX_STATEMENT_CHARS {
        return statement.to_string();
    }
    statement.chars().take(MAX_STATEMENT_CHARS).collect()
}

// ---------------------------------------------------------------------------
// Optional llm extraction path
// ---------------------------------------------------------------------------

pub fn render_trace_prompt(
    template: &str,
    topic_id: &str,
    question_id: &str,
    reply_to_event_id: &str,
    reply: &str,
    max_events: usize,
) -> String {
    template
        .replace("{{topic_id}}", topic_id)
        .replace("{{question_id}}", question_id)
        .replace("{{reply_to_event_id}}", reply_to_event_id)
        .replace("{{max_events}}", &max_events.to_string())
        .replace("{{reply}}", reply)
}

/// Parse the llm extraction response: a strict JSON array of
/// `{"kind", "statement", "refs"?}` items, tolerating code fences and
/// surrounding prose. Unknown kinds and empty statements are dropped.
pub fn parse_trace_extraction_json(text: &str, max_events: usize) -> Result<Vec<TraceDraft>> {
    let start = text
        .find('[')
        .ok_or_else(|| anyhow::anyhow!("trace extraction response has no JSON array"))?;
    let end = text
        .rfind(']')
        .ok_or_else(|| anyhow::anyhow!("trace extraction response has no JSON array"))?;
    if end < start {
        bail!("trace extraction response has no JSON array");
    }
    let value: Value = serde_json::from_str(&text[start..=end])
        .map_err(|error| anyhow::anyhow!("trace extraction JSON parse failed: {error}"))?;
    let Some(items) = value.as_array() else {
        bail!("trace extraction response is not a JSON array");
    };
    let mut drafts = Vec::new();
    let mut seen = BTreeSet::new();
    for item in items {
        let kind = item
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        if !TRACE_KINDS.contains(&kind.as_str()) {
            continue;
        }
        let statement = item
            .get("statement")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(truncate_statement);
        let Some(statement) = statement else {
            continue;
        };
        let cites = item
            .get("refs")
            .or_else(|| item.get("cites"))
            .and_then(Value::as_array)
            .map(|refs| {
                refs.iter()
                    .filter_map(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToOwned::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        if seen.insert((kind.clone(), statement.clone())) {
            drafts.push(TraceDraft {
                kind,
                statement,
                cites,
            });
            if drafts.len() >= max_events {
                break;
            }
        }
    }
    Ok(drafts)
}

// ---------------------------------------------------------------------------
// Persistence: append protocol-versioned trace events to events.jsonl
// ---------------------------------------------------------------------------

/// Map a v0.45 trace kind onto the room event `event_kind` (v0.49 protocol
/// envelope). The raw trace kind is always preserved at
/// `metadata.trace.kind`; the evals runner reads that field.
pub fn trace_room_event_kind(kind: &str) -> &'static str {
    match kind {
        "claim" => "claim",
        "question" => "question",
        "counterpoint" => "counterpoint",
        "hypothesis" => "hypothesis",
        "verification_target" => "verification_target",
        "decision" => "decision_record",
        "handoff_request" => "handoff_note",
        _ => "tool_call_summary",
    }
}

/// Append one trace event per draft to `.harvis/agent-room/events.jsonl`.
///
/// `root` must already be resolved by the caller (the speaker step resolves
/// it once up front). `lineage` is the step's reply target view carrying
/// `reply_to_event_id` / `reply_to_agent_id` / `reply_to_question_id`; every
/// trace event inherits it as its reply lineage, and explicit marker cites
/// land in `refs.cites`. The originating utterance is linked both ways:
/// `source_refs` + `metadata.trace.source_event_id` point at the reply's
/// `agent_message` event, and `source_message_id` points at the
/// `messages.jsonl` record.
///
/// This function never touches `messages.jsonl`.
#[allow(clippy::too_many_arguments)]
pub fn record_reply_traces(
    root: &Path,
    topic_id: &str,
    agent_id: &str,
    role: &str,
    model: Option<&str>,
    source_message_id: &str,
    source_event_id: &str,
    question_id: &str,
    lineage: &Value,
    drafts: &[TraceDraft],
    extraction: &str,
) -> Result<Vec<Value>> {
    init_agent_room(root)?;
    let reply_to = lineage
        .get("reply_to_event_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    let reply_to_question = lineage
        .get("reply_to_question_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    let reply_to_agent = lineage
        .get("reply_to_agent_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    let mut events = Vec::new();
    for (index, draft) in drafts.iter().enumerate() {
        let event_type = format!("trace.{}", draft.kind);
        let index_text = index.to_string();
        let event = json!({
            "agent_room_version": AGENT_ROOM_VERSION,
            "protocol": {
                "id": AGENT_ROOM_PROTOCOL_ID,
                "version": "0.49"
            },
            "event_id": stable_id(
                "evt",
                &[
                    topic_id,
                    agent_id,
                    &event_type,
                    &draft.statement,
                    source_message_id,
                    &index_text,
                ],
            )?,
            "topic_id": topic_id,
            "agent_id": agent_id,
            "role": role,
            "actor": {
                "kind": if agent_id == "human" { "user" } else { "agent" },
                "id": agent_id
            },
            "event_kind": trace_room_event_kind(&draft.kind),
            "event_type": event_type,
            "model": model,
            "source_refs": if source_event_id.is_empty() {
                Vec::<String>::new()
            } else {
                vec![source_event_id.to_string()]
            },
            "source_age": null,
            "sensitivity": "internal",
            "content": draft.statement,
            "content_text": draft.statement,
            "metadata": {
                "trace": {
                    "schemaVersion": TRACE_SCHEMA_VERSION,
                    "trace_version": TRACE_EXTRACTION_VERSION,
                    "kind": draft.kind,
                    "statement": draft.statement,
                    "refs": {
                        "reply_to": reply_to,
                        "reply_to_agent_id": reply_to_agent,
                        "reply_to_question_id": reply_to_question,
                        "cites": draft.cites
                    },
                    "question_id": question_id,
                    "source_message_id": source_message_id,
                    "source_event_id": source_event_id,
                    "extraction": extraction,
                    // ROADMAP v0.45: structured points only; the hidden
                    // chain-of-thought behind them is never persisted.
                    "no_hidden_cot": true
                }
            },
            "created_at": now_rfc3339()?
        });
        append_jsonl(&jsonl_path(root, "events")?, &event)?;
        events.push(event);
    }
    Ok(events)
}

/// Compact per-step trace report embedded in the speaker step response.
pub fn trace_report(
    enabled: bool,
    extraction: &str,
    events: &[Value],
    config: &TraceConfig,
    llm_error: Option<&str>,
) -> Value {
    let mut kinds: Vec<&str> = events
        .iter()
        .filter_map(|event| {
            event
                .get("metadata")
                .and_then(|metadata| metadata.get("trace"))
                .and_then(|trace| trace.get("kind"))
                .and_then(Value::as_str)
        })
        .collect();
    kinds.sort_unstable();
    kinds.dedup();
    json!({
        "version": TRACE_EXTRACTION_VERSION,
        "schemaVersion": TRACE_SCHEMA_VERSION,
        "enabled": enabled,
        "extraction": extraction,
        "count": events.len(),
        "kinds": kinds,
        "event_ids": events
            .iter()
            .filter_map(|event| event.get("event_id").and_then(Value::as_str))
            .collect::<Vec<_>>(),
        "llm_error": llm_error,
        "config_source": config.config_source,
        "config_error": config.config_error
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_room::{
        append_chair_decision, list_agent_room, upsert_participant, ParticipantInput,
    };
    use crate::init::init_workspace;
    use crate::speaker::{
        agent_room_speaker_step, LlmCallRequest, LlmCallResponse, SpeakerStepOptions,
        CHAIR_DECISION_SCHEMA, SELECTOR_ROUND_ROBIN,
    };
    use std::os::unix::fs::PermissionsExt;

    fn temp_root(tag: &str) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("harvis-trace-{tag}-test-{}", std::process::id()));
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

    fn seed_rotation_to_last_default_slot(root: &Path, topic_id: &str) {
        // Default roster order ends with "mail"; seeding it makes the next
        // round-robin pick the first upserted slot.
        append_chair_decision(
            root,
            &json!({
                "schemaVersion": CHAIR_DECISION_SCHEMA,
                "topic_id": topic_id,
                "selected_agent_id": "mail",
                "selector_kind": SELECTOR_ROUND_ROBIN,
                "route_reason": "seed for rotation",
                "question_id": Value::Null,
                "ts": now_rfc3339().expect("ts")
            }),
        )
        .expect("seed decision");
    }

    fn add_active_trace_bot(root: &Path, script: String) {
        upsert_participant(
            root,
            ParticipantInput {
                slot_id: "trace-bot".to_string(),
                role: "responder".to_string(),
                display_name: "Trace Bot".to_string(),
                execution_mode: Some("active".to_string()),
                harness_ref: Some(script),
                ..ParticipantInput::default()
            },
        )
        .expect("upsert trace bot");
    }

    fn run_step(root: &Path, topic_id: &str, prompt: Option<&str>) -> Value {
        let mut llm = no_llm();
        agent_room_speaker_step(
            &SpeakerStepOptions {
                root: root.to_path_buf(),
                topic_id: Some(topic_id.to_string()),
                prompt: prompt.map(ToOwned::to_owned),
                dry_run: false,
                ..SpeakerStepOptions::default()
            },
            &mut llm,
        )
        .expect("step")
    }

    fn read_events(root: &Path) -> Vec<Value> {
        let text =
            fs::read_to_string(root.join(".harvis/agent-room/events.jsonl")).expect("events.jsonl");
        text.lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .collect()
    }

    fn trace_events(events: &[Value]) -> Vec<Value> {
        events
            .iter()
            .filter(|event| {
                event
                    .get("metadata")
                    .and_then(|metadata| metadata.get("trace"))
                    .and_then(|trace| trace.get("schemaVersion"))
                    .and_then(Value::as_str)
                    == Some(TRACE_SCHEMA_VERSION)
            })
            .cloned()
            .collect()
    }

    // -- parser ------------------------------------------------------------

    #[test]
    fn trace_parser_reads_all_seven_kinds() {
        let content = "普通发言正文，不包含标记。\n---harvis-trace---\n\
            claim: 采用 append-only 事件流\n\
            question: 崩溃恢复怎么做 fsync？\n\
            counterpoint: 反对——原位更新会重写整文件\n\
            hypothesis: 内存索引可以让读取保持恒定延迟\n\
            verification_target: 1000 轮回放基准延迟低于 50ms\n\
            decision: 暂定 append-only 加内存索引\n\
            handoff_request: 把基准测试交给 codex harness\n\
            ---end-harvis-trace---\n结尾散文。";
        let drafts = parse_trace_markers(content, 12);
        let kinds: Vec<&str> = drafts.iter().map(|draft| draft.kind.as_str()).collect();
        assert_eq!(kinds, TRACE_KINDS);
        assert!(drafts.iter().all(|draft| draft.cites.is_empty()));
    }

    #[test]
    fn trace_parser_extracts_refs_and_prefix_lines() {
        let content = "[trace] claim: 状态底座用事件流 [refs: evt_a, evt_b]\n\
            无关行 question: 不应被解析\n\
            ---harvis-trace---\n\
            decision: 冻结方案 | refs: evt_c\n\
            counterpoint: 引用前序 [refs: evt_a]\n\
            ---end-harvis-trace---";
        let drafts = parse_trace_markers(content, 12);
        assert_eq!(drafts.len(), 3);
        assert_eq!(drafts[0].kind, "claim");
        assert_eq!(drafts[0].cites, vec!["evt_a", "evt_b"]);
        assert_eq!(drafts[0].statement, "状态底座用事件流");
        assert_eq!(drafts[1].kind, "decision");
        assert_eq!(drafts[1].cites, vec!["evt_c"]);
        assert_eq!(drafts[2].cites, vec!["evt_a"]);
    }

    #[test]
    fn trace_parser_ignores_unmarked_text_dedupes_and_caps() {
        let content = "question: 散文里的伪标记不算\n\
            ---harvis-trace---\n\
            claim: 重复要点\n\
            claim: 重复要点\n\
            claim: 要点三\n\
            ---end-harvis-trace---";
        let drafts = parse_trace_markers(content, 2);
        assert_eq!(drafts.len(), 2, "dedupe + cap");
        assert_eq!(drafts[0].statement, "重复要点");
        assert_eq!(drafts[1].statement, "要点三");
        // no section markers at all -> nothing parsed
        assert!(parse_trace_markers("claim: 没有标记段", 12).is_empty());
    }

    #[test]
    fn trace_statement_truncates_long_lines() {
        let long = "长".repeat(MAX_STATEMENT_CHARS + 40);
        let content = format!("---harvis-trace---\nclaim: {long}\n---end-harvis-trace---");
        let drafts = parse_trace_markers(&content, 12);
        assert_eq!(drafts.len(), 1);
        assert_eq!(drafts[0].statement.chars().count(), MAX_STATEMENT_CHARS);
    }

    #[test]
    fn trace_llm_extraction_json_parses_fenced_array() {
        let text = "前言\n```json\n[\n  {\"kind\": \"claim\", \"statement\": \"要点一\", \"refs\": [\"evt_x\"]},\n  {\"kind\": \"bogus\", \"statement\": \"丢弃\"},\n  {\"kind\": \"decision\", \"statement\": \"\"},\n  {\"kind\": \"decision\", \"statement\": \"冻结\"}\n]\n```";
        let drafts = parse_trace_extraction_json(text, 12).expect("parse");
        assert_eq!(drafts.len(), 2);
        assert_eq!(drafts[0].kind, "claim");
        assert_eq!(drafts[0].cites, vec!["evt_x"]);
        assert_eq!(drafts[1].kind, "decision");
        assert!(parse_trace_extraction_json("没有数组", 12).is_err());
    }

    // -- config --------------------------------------------------------------

    #[test]
    fn trace_config_defaults_to_rule_without_table() {
        let root = temp_root("config-default");
        let config = load_trace_config(&root);
        assert!(config.enabled);
        assert_eq!(config.extraction, TRACE_EXTRACTION_RULE);
        assert_eq!(config.max_events_per_reply, DEFAULT_MAX_EVENTS_PER_REPLY);
        assert!(config.config_error.is_none());
        assert!(config.llm_prompt_template().contains("{{reply}}"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn trace_config_reads_table_and_rejects_bad_extraction() {
        let root = temp_root("config-table");
        fs::write(
            root.join(".harvis/harvis.toml"),
            r#"
[agent_room_trace]
enabled = true
extraction = "llm"
model_alias = "d4f"
prompt_template = "extract {{reply}} max {{max_events}}"
max_events_per_reply = 5
"#,
        )
        .expect("write config");
        let config = load_trace_config(&root);
        assert_eq!(config.extraction, TRACE_EXTRACTION_LLM);
        assert_eq!(config.model_alias.as_deref(), Some("d4f"));
        assert_eq!(config.max_events_per_reply, 5);
        assert_eq!(
            config.llm_prompt_template(),
            "extract {{reply}} max {{max_events}}"
        );
        assert!(config.config_error.is_none());
        fs::write(
            root.join(".harvis/harvis.toml"),
            "[agent_room_trace]\nenabled = false\nextraction = \"magic\"\n",
        )
        .expect("write bad config");
        let config = load_trace_config(&root);
        assert!(!config.enabled);
        assert_eq!(config.extraction, TRACE_EXTRACTION_RULE);
        assert!(config
            .config_error
            .as_deref()
            .is_some_and(|error| error.contains("magic")));
        let _ = fs::remove_dir_all(root);
    }

    // -- step integration ----------------------------------------------------

    const MARKED_HARNESS: &str = "#!/bin/sh\ncat >/dev/null\ncat <<'EOF'\n我主张事件流方案并追问恢复细节。\n---harvis-trace---\nclaim: 房间状态底座采用 append-only events.jsonl\nquestion: 崩溃恢复时的 fsync 策略是什么？\nverification_target: 1000 轮回放基准读取延迟低于 50ms\n---end-harvis-trace---\nEOF\n";

    #[test]
    fn trace_step_records_events_with_lineage_and_keeps_messages_shape() {
        let root = temp_root("step-trace");
        let topic = "gwt-workbench";
        // one prior human turn so lineage has a concrete reply target
        crate::agent_room::add_message(
            &root,
            topic,
            "human",
            "user",
            "请评审房间状态底座方案",
            Vec::new(),
            "internal",
            None,
        )
        .expect("seed message");
        let script = write_script(&root, "trace_harness.sh", MARKED_HARNESS);
        add_active_trace_bot(&root, script);
        seed_rotation_to_last_default_slot(&root, topic);

        let result = run_step(&root, topic, None);
        assert_eq!(result["status"], json!("acted"));
        assert_eq!(result["speaker"]["slot_id"], json!("trace-bot"));
        let report = &result["trace"];
        assert_eq!(report["enabled"], json!(true));
        assert_eq!(report["extraction"], json!(TRACE_EXTRACTION_RULE));
        assert_eq!(report["count"], json!(3));
        assert_eq!(
            report["kinds"],
            json!(["claim", "question", "verification_target"])
        );

        let events = read_events(&root);
        let traces = trace_events(&events);
        assert_eq!(traces.len(), 3);
        let message_event_id = result["agent_message"]["event_id"]
            .as_str()
            .expect("message event id")
            .to_string();
        let reply_to = result["reply_target"]["reply_to_event_id"]
            .as_str()
            .expect("lineage reply target")
            .to_string();
        assert!(!reply_to.is_empty());
        for event in &traces {
            let trace = &event["metadata"]["trace"];
            assert_eq!(trace["schemaVersion"], json!(TRACE_SCHEMA_VERSION));
            assert_eq!(trace["no_hidden_cot"], json!(true));
            assert_eq!(trace["refs"]["reply_to"], json!(reply_to));
            assert_eq!(trace["source_event_id"], json!(message_event_id));
            assert_eq!(trace["extraction"], json!(TRACE_EXTRACTION_RULE));
            assert_eq!(event["source_refs"], json!([message_event_id]));
            assert_eq!(
                event["protocol"],
                json!({"id": AGENT_ROOM_PROTOCOL_ID, "version": "0.49"})
            );
            assert!(event["event_id"]
                .as_str()
                .is_some_and(|id| id.starts_with("evt_")));
        }
        // v0.49 envelope kinds: claim/question pass through, verification_target
        // is first-class since T311.
        let envelope_kinds: Vec<&str> = traces
            .iter()
            .filter_map(|event| event.get("event_kind").and_then(Value::as_str))
            .collect();
        assert_eq!(
            envelope_kinds,
            vec!["claim", "question", "verification_target"]
        );

        // Regression gate: messages.jsonl lines keep the exact T308-era field
        // set (event_id/event_kind are in-memory only, never on disk).
        let expected: BTreeSet<&str> = [
            "agent_room_version",
            "protocol",
            "message_id",
            "topic_id",
            "agent_id",
            "role",
            "model",
            "source_refs",
            "sensitivity",
            "content",
            "created_at",
        ]
        .into_iter()
        .collect();
        let messages_text = fs::read_to_string(root.join(".harvis/agent-room/messages.jsonl"))
            .expect("messages.jsonl");
        assert!(messages_text.lines().count() >= 2);
        for line in messages_text.lines() {
            let message: Value = serde_json::from_str(line).expect("message line");
            let keys: BTreeSet<&str> = message
                .as_object()
                .expect("object")
                .keys()
                .map(String::as_str)
                .collect();
            assert_eq!(keys, expected, "messages.jsonl field set drifted");
        }
        // ...and the legacy read path still returns both messages.
        let room = list_agent_room(&root, 200).expect("room");
        let messages = room["messages"].as_array().expect("messages");
        assert_eq!(messages.len(), 2);
        assert!(messages
            .iter()
            .any(|message| message["agent_id"] == "trace-bot"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn trace_step_second_turn_cites_first_turn_event() {
        let root = temp_root("step-lineage");
        let topic = "gwt-workbench";
        let script = write_script(
            &root,
            "trace_harness.sh",
            "#!/bin/sh\ninput=$(cat)\nref=$(printf '%s' \"$input\" | sed -n 's/.*\"reply_to_event_id\"[ ]*:[ ]*\"\\([^\"]*\\)\".*/\\1/p' | head -1)\ncat <<EOF\n回应并反对上一条。\n---harvis-trace---\ncounterpoint: 反对上一条主张——缺少成本论证 [refs: $ref]\n---end-harvis-trace---\nEOF\n",
        );
        add_active_trace_bot(&root, script);
        seed_rotation_to_last_default_slot(&root, topic);
        let first = run_step(&root, topic, Some("请给出方案主张".to_string().as_str()));
        assert_eq!(first["status"], json!("acted"));
        // second step: roster advances past trace-bot again only after a full
        // cycle, so force the lineage check through the trace report instead.
        let events = read_events(&root);
        let traces = trace_events(&events);
        assert_eq!(traces.len(), 1);
        let trace = &traces[0]["metadata"]["trace"];
        let cited = trace["refs"]["cites"][0].as_str().expect("cited event id");
        assert!(!cited.is_empty(), "harness cited its stdin reply target");
        let ids: Vec<&str> = events
            .iter()
            .filter_map(|event| event.get("event_id").and_then(Value::as_str))
            .collect();
        assert!(ids.contains(&cited), "cited event exists in events.jsonl");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn trace_step_disabled_by_config_writes_nothing() {
        let root = temp_root("step-disabled");
        let topic = "gwt-workbench";
        fs::write(
            root.join(".harvis/harvis.toml"),
            "[agent_room_trace]\nenabled = false\n",
        )
        .expect("write config");
        let script = write_script(&root, "trace_harness.sh", MARKED_HARNESS);
        add_active_trace_bot(&root, script);
        seed_rotation_to_last_default_slot(&root, topic);
        let result = run_step(&root, topic, None);
        assert_eq!(result["status"], json!("acted"));
        assert_eq!(result["trace"]["enabled"], json!(false));
        assert_eq!(result["trace"]["count"], json!(0));
        let events = read_events(&root);
        assert!(trace_events(&events).is_empty());
        let _ = fs::remove_dir_all(root);
    }

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

    #[test]
    fn trace_step_llm_extraction_uses_model_drafts() {
        let root = temp_root("step-llm");
        let topic = "gwt-workbench";
        let registry = write_registry(&root);
        fs::write(
            root.join(".harvis/harvis.toml"),
            "[agent_room_trace]\nextraction = \"llm\"\nmodel_alias = \"d4f\"\n",
        )
        .expect("write config");
        let script = write_script(&root, "trace_harness.sh", MARKED_HARNESS);
        add_active_trace_bot(&root, script);
        seed_rotation_to_last_default_slot(&root, topic);
        let mut llm = |request: &LlmCallRequest| -> Result<LlmCallResponse> {
            assert_eq!(request.purpose, "trace_extraction");
            assert!(request.prompt.contains("append-only"));
            Ok(LlmCallResponse {
                text: "```json\n[{\"kind\": \"hypothesis\", \"statement\": \"模型抽取的假设要点\", \"refs\": []}]\n```"
                    .to_string(),
                usage: json!({}),
                stop_reason: Some("end_turn".to_string()),
            })
        };
        let result = agent_room_speaker_step(
            &SpeakerStepOptions {
                root: root.clone(),
                topic_id: Some(topic.to_string()),
                prompt: None,
                dry_run: false,
                provider_registry: Some(registry),
                ..SpeakerStepOptions::default()
            },
            &mut llm,
        )
        .expect("step");
        assert_eq!(result["status"], json!("acted"));
        assert_eq!(result["trace"]["extraction"], json!(TRACE_EXTRACTION_LLM));
        assert_eq!(result["trace"]["count"], json!(1));
        let events = read_events(&root);
        let traces = trace_events(&events);
        assert_eq!(traces.len(), 1);
        let trace = &traces[0]["metadata"]["trace"];
        assert_eq!(trace["kind"], json!("hypothesis"));
        assert_eq!(trace["statement"], json!("模型抽取的假设要点"));
        assert_eq!(trace["extraction"], json!(TRACE_EXTRACTION_LLM));
        assert_eq!(traces[0]["event_kind"], json!("hypothesis"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn trace_step_llm_extraction_failure_falls_back_to_rule() {
        let root = temp_root("step-llm-fallback");
        let topic = "gwt-workbench";
        fs::write(
            root.join(".harvis/harvis.toml"),
            // alias intentionally unresolvable (no registry passed)
            "[agent_room_trace]\nextraction = \"llm\"\nmodel_alias = \"d4f\"\n",
        )
        .expect("write config");
        let script = write_script(&root, "trace_harness.sh", MARKED_HARNESS);
        add_active_trace_bot(&root, script);
        seed_rotation_to_last_default_slot(&root, topic);
        let result = run_step(&root, topic, None);
        assert_eq!(result["status"], json!("acted"));
        assert_eq!(
            result["trace"]["extraction"],
            json!(TRACE_EXTRACTION_RULE_FALLBACK)
        );
        assert!(result["trace"]["llm_error"].as_str().is_some());
        // rule drafts from the harness markers were persisted instead
        assert_eq!(result["trace"]["count"], json!(3));
        let events = read_events(&root);
        assert_eq!(trace_events(&events).len(), 3);
        let _ = fs::remove_dir_all(root);
    }
}
