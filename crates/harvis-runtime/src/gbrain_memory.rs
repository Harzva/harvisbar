//! GBrain MEMORY_VERBS v1 adapter.
//!
//! HARVIS keeps approval, routing, and canonical records. This adapter sees
//! only accepted writes and talks to GBrain through the seven-verb MCP surface.

use crate::mcp_stdio::McpToolTransport;
use crate::memory_provider::{
    ApprovedMemoryInput, CommitResult, ContextPackInput, ContextPackResult, EntityInput,
    EntityResult, ExportInput, HarvisMemoryProviderV1, MemoryCapabilities, MemoryProvenance,
    MemoryRecord, PortableMemoryBundle, ProviderHealth, ProviderRef, RecallHit, RecallInput,
    RecallResult,
};
use anyhow::{bail, Context, Result};
use harvis_core::time::now_rfc3339;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

const PROTOCOL_VERSION: u64 = 1;
const VERBS: &[&str] = &[
    "recall",
    "remember",
    "entity",
    "synthesize",
    "forget",
    "context_pack",
    "delta",
];
const PROVENANCE_PREFIX: &str = "harvis-memory-v1:";

pub struct GbrainMemoryProvider {
    id: String,
    transport: Arc<dyn McpToolTransport>,
    reconciliation_path: PathBuf,
}

impl GbrainMemoryProvider {
    pub fn new(
        id: impl Into<String>,
        transport: Arc<dyn McpToolTransport>,
        reconciliation_path: impl Into<PathBuf>,
    ) -> Result<Self> {
        let provider = Self {
            id: id.into(),
            transport,
            reconciliation_path: reconciliation_path.into(),
        };
        if let Some(parent) = provider.reconciliation_path.parent() {
            fs::create_dir_all(parent)?;
        }
        provider.initialize()?;
        Ok(provider)
    }

    fn connect(&self) -> Result<Connection> {
        Connection::open(&self.reconciliation_path).with_context(|| {
            format!(
                "open GBrain reconciliation database: {}",
                self.reconciliation_path.display()
            )
        })
    }

    fn initialize(&self) -> Result<()> {
        let connection = self.connect()?;
        connection.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS gbrain_commits (
                commit_id TEXT PRIMARY KEY,
                memory_id TEXT NOT NULL,
                external_id TEXT NOT NULL,
                result_json TEXT NOT NULL,
                record_json TEXT,
                committed_at TEXT NOT NULL
            );
            ",
        )?;
        let mut statement = connection.prepare("PRAGMA table_info(gbrain_commits)")?;
        let columns = statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        if !columns.iter().any(|column| column == "record_json") {
            connection.execute("ALTER TABLE gbrain_commits ADD COLUMN record_json TEXT", [])?;
        }
        Ok(())
    }

    fn prior_commit(&self, commit_id: &str) -> Result<Option<CommitResult>> {
        let json = self
            .connect()?
            .query_row(
                "SELECT result_json FROM gbrain_commits WHERE commit_id = ?1",
                params![commit_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        json.map(|json| serde_json::from_str(&json).map_err(Into::into))
            .transpose()
    }

    fn save_commit(&self, memory: &MemoryRecord, result: &CommitResult) -> Result<CommitResult> {
        self.connect()?.execute(
            "INSERT OR IGNORE INTO gbrain_commits(
                commit_id, memory_id, external_id, result_json, record_json, committed_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                result.commit_id,
                memory.memory_id,
                result.external_id,
                serde_json::to_string(result)?,
                serde_json::to_string(memory)?,
                now_rfc3339()?,
            ],
        )?;
        self.prior_commit(&result.commit_id)?
            .context("GBrain reconciliation write was not durable")
    }

    fn checked_call(&self, verb: &str, arguments: Value) -> Result<Value> {
        let response = self.transport.call_tool(verb, &arguments)?;
        if response.get("protocol_version").and_then(Value::as_u64) != Some(PROTOCOL_VERSION) {
            bail!("GBrain {verb} response is not MEMORY_VERBS protocol_version 1");
        }
        if let Some(error) = response.get("error").and_then(Value::as_str) {
            let message = response
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown GBrain error");
            bail!("GBrain {verb} failed ({error}): {message}");
        }
        Ok(response)
    }

    pub fn entity(&self, name: &str) -> Result<Value> {
        if name.trim().is_empty() {
            bail!("entity name is required");
        }
        self.checked_call("entity", json!({"name": name}))
    }

    /// Governance must approve expiration before calling this concrete
    /// adapter method. The provider trait intentionally keeps it optional.
    pub fn forget_approved(&self, external_id: &str, reason: Option<&str>) -> Result<Value> {
        if external_id.trim().is_empty() {
            bail!("GBrain fact id is required");
        }
        let mut arguments = Map::new();
        arguments.insert("id".to_string(), json!(external_id));
        if let Some(reason) = reason.filter(|value| !value.trim().is_empty()) {
            arguments.insert("reason".to_string(), json!(reason));
        }
        self.checked_call("forget", Value::Object(arguments))
    }

    fn context_entities(input: &RecallInput) -> Vec<String> {
        let mut entities = Vec::new();
        if let Some(project) = input.project_id.as_deref() {
            entities.push(namespaced("project", project));
        }
        if let Some(user) = input.user_id.as_deref() {
            entities.push(namespaced("user", user));
        }
        if let Some(agent) = input.agent_id.as_deref() {
            entities.push(namespaced("agent", agent));
        }
        entities.extend(input.shared_subjects.iter().cloned());
        entities.sort();
        entities.dedup();
        entities.truncate(8);
        entities
    }
}

impl HarvisMemoryProviderV1 for GbrainMemoryProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn capabilities(&self) -> MemoryCapabilities {
        let mut capabilities = MemoryCapabilities::mvp();
        capabilities.entity = true;
        capabilities.forget_approved = true;
        capabilities.export = true;
        capabilities
    }

    fn health(&self) -> ProviderHealth {
        let required = VERBS
            .iter()
            .map(|name| (*name).to_string())
            .collect::<BTreeSet<_>>();
        let health = self.transport.list_tools().and_then(|tools| {
            let actual = tools.into_iter().collect::<BTreeSet<_>>();
            if actual != required {
                bail!("GBrain must expose exactly the seven MEMORY_VERBS v1 tools");
            }
            Ok(())
        });
        ProviderHealth {
            provider_id: self.id.clone(),
            healthy: health.is_ok(),
            detail: health
                .map(|_| "MEMORY_VERBS v1 ready".to_string())
                .unwrap_or_else(|error| error.to_string()),
            checked_at: now_rfc3339().unwrap_or_default(),
        }
    }

    fn recall(&self, input: &RecallInput) -> Result<RecallResult> {
        input.validate()?;
        let mut arguments = Map::new();
        let fetch_limit = input.limit.saturating_mul(4).clamp(20, 100);
        arguments.insert("limit".to_string(), json!(fetch_limit));
        if let Some(entity) = Self::context_entities(input).into_iter().next() {
            arguments.insert("entity".to_string(), json!(entity));
        }
        if let Some(session_id) = input.session_id.as_deref() {
            arguments.insert("session_id".to_string(), json!(session_id));
        }
        let response = self.checked_call("recall", Value::Object(arguments))?;
        let facts = response
            .get("facts")
            .and_then(Value::as_array)
            .context("GBrain recall response is missing facts[]")?;
        let mut hits = facts
            .iter()
            .filter_map(|fact| fact_to_hit(&self.id, fact, &input.query).transpose())
            .collect::<Result<Vec<_>>>()?;
        hits.sort_by(|left, right| {
            right
                .score
                .total_cmp(&left.score)
                .then_with(|| right.memory.valid_from.cmp(&left.memory.valid_from))
        });
        hits.truncate(input.limit);
        let mut packed = Vec::new();
        let mut token_used = 0;
        for hit in hits {
            if token_used + hit.token_estimate > input.token_budget {
                continue;
            }
            token_used += hit.token_estimate;
            packed.push(hit);
        }
        Ok(RecallResult {
            provider_id: self.id.clone(),
            hits: packed,
            token_used,
            degraded: response.get("search_degraded").is_some(),
            warnings: response
                .get("search_degraded")
                .and_then(Value::as_str)
                .map(|warning| vec![warning.to_string()])
                .unwrap_or_default(),
        })
    }

    fn context_pack(&self, input: &ContextPackInput) -> Result<ContextPackResult> {
        let entities = Self::context_entities(&input.recall);
        let mut warnings = Vec::new();
        if entities.is_empty() {
            warnings.push("GBrain context_pack skipped: no scoped entity".to_string());
        } else {
            let response = self.checked_call(
                "context_pack",
                json!({
                    "entities": entities.join(","),
                    "budget_tokens": input.recall.token_budget,
                    "session_id": input.recall.session_id
                }),
            )?;
            if let Some(reason) = response.get("degraded_reason").and_then(Value::as_str) {
                warnings.push(reason.to_string());
            }
        }
        // Re-read through recall so every injectable item carries the HARVIS
        // memory id encoded in provenance. GBrain context_pack intentionally
        // omits fact provenance, so its raw `text` is never injected directly.
        let mut recall = self.recall(&input.recall)?;
        recall.warnings.extend(warnings);
        Ok(crate::memory_provider::context_from_recall(
            recall,
            input.recall.token_budget,
        ))
    }

    fn commit_approved(&self, input: &ApprovedMemoryInput) -> Result<CommitResult> {
        input.memory.validate()?;
        if input.memory.status != "accepted" {
            bail!("only accepted memories may be committed");
        }
        if input.approval_id.trim().is_empty() || input.commit_id.trim().is_empty() {
            bail!("approval_id and commit_id are required");
        }
        if let Some(mut prior) = self.prior_commit(&input.commit_id)? {
            prior.idempotent_replay = true;
            return Ok(prior);
        }
        let provenance = format!(
            "{PROVENANCE_PREFIX}{}",
            serde_json::to_string(&json!({
                "memory_id": input.memory.memory_id,
                "commit_id": input.commit_id
            }))?
        );
        if provenance.chars().count() > 500 {
            bail!("GBrain provenance exceeds the v1 limit");
        }
        let mut arguments = Map::new();
        arguments.insert("fact".to_string(), json!(input.memory.summary));
        arguments.insert("provenance".to_string(), json!(provenance));
        arguments.insert("entity".to_string(), json!(input.memory.subject));
        arguments.insert("kind".to_string(), json!(gbrain_kind(&input.memory.kind)));
        arguments.insert(
            "visibility".to_string(),
            json!(if input.memory.sensitivity == "private" {
                "private"
            } else {
                "world"
            }),
        );
        if let Some(valid_until) = input.memory.valid_until.as_deref() {
            arguments.insert("ttl".to_string(), json!(valid_until));
        }
        let response = self.checked_call("remember", Value::Object(arguments))?;
        let external_id = response
            .get("id")
            .and_then(Value::as_str)
            .context("GBrain remember response is missing opaque string id")?;
        let status = response
            .get("status")
            .and_then(Value::as_str)
            .context("GBrain remember response is missing status")?;
        if !["inserted", "duplicate", "superseded"].contains(&status) {
            bail!("GBrain remember returned an unknown status: {status}");
        }
        let result = CommitResult {
            provider_id: self.id.clone(),
            commit_id: input.commit_id.clone(),
            external_id: external_id.to_string(),
            idempotent_replay: status == "duplicate",
        };
        self.save_commit(&input.memory, &result)
    }

    fn entity(&self, input: &EntityInput) -> Result<EntityResult> {
        let data = GbrainMemoryProvider::entity(self, &input.name)?;
        Ok(EntityResult {
            provider_id: self.id.clone(),
            found: data.get("found").and_then(Value::as_bool).unwrap_or(false),
            data,
            degraded: false,
            warnings: Vec::new(),
        })
    }

    fn export(&self, input: &ExportInput) -> Result<PortableMemoryBundle> {
        let connection = self.connect()?;
        let mut statement = connection.prepare(
            "SELECT record_json FROM gbrain_commits
             WHERE record_json IS NOT NULL ORDER BY memory_id",
        )?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut records = Vec::new();
        for row in rows {
            let record: MemoryRecord = serde_json::from_str(&row?)?;
            if input.include_inactive || record.status == "accepted" {
                records.push(record);
            }
        }
        PortableMemoryBundle::new(&self.id, records)
    }
}

fn fact_to_hit(provider_id: &str, fact: &Value, query: &str) -> Result<Option<RecallHit>> {
    let provenance = fact
        .get("provenance")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let Some(encoded) = provenance.strip_prefix(PROVENANCE_PREFIX) else {
        return Ok(None);
    };
    let metadata: Value =
        serde_json::from_str(encoded).context("parse HARVIS GBrain provenance")?;
    let memory_id = metadata
        .get("memory_id")
        .and_then(Value::as_str)
        .filter(|value| value.starts_with("mem_"))
        .context("GBrain provenance has no HARVIS memory_id")?;
    let summary = fact
        .get("fact")
        .and_then(Value::as_str)
        .context("GBrain fact has no text")?;
    let external_id = fact
        .get("fact_id")
        .and_then(Value::as_str)
        .or_else(|| fact.get("id").and_then(Value::as_i64).map(|_| ""))
        .unwrap_or_default();
    let external_id = if external_id.is_empty() {
        fact.get("id")
            .map(Value::to_string)
            .unwrap_or_else(|| memory_id.to_string())
    } else {
        external_id.to_string()
    };
    let entity = fact
        .get("entity_slug")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or("gbrain");
    let subject = if entity.contains(':') {
        entity.to_string()
    } else {
        format!("gbrain:{entity}")
    };
    let valid_from = fact
        .get("valid_from")
        .and_then(Value::as_str)
        .or_else(|| fact.get("created_at").and_then(Value::as_str))
        .map(str::to_string)
        .unwrap_or_else(|| now_rfc3339().unwrap_or_default());
    let token_estimate = summary.chars().count().div_ceil(4).max(1);
    Ok(Some(RecallHit {
        memory: MemoryRecord {
            memory_id: memory_id.to_string(),
            schema_version: 1,
            kind: harvis_kind(fact.get("kind").and_then(Value::as_str).unwrap_or("fact")),
            scope: subject
                .split_once(':')
                .map(|part| part.0)
                .filter(|scope| ["user", "project", "session", "agent", "shared"].contains(scope))
                .unwrap_or("shared")
                .to_string(),
            subject,
            summary: summary.to_string(),
            provenance: vec![MemoryProvenance {
                source_type: "gbrain".to_string(),
                source_id: external_id.clone(),
                repo_key: None,
                commit_sha: None,
            }],
            sensitivity: if fact.get("visibility").and_then(Value::as_str) == Some("private") {
                "private".to_string()
            } else {
                "shared".to_string()
            },
            status: "accepted".to_string(),
            confidence: fact
                .get("confidence")
                .and_then(Value::as_f64)
                .unwrap_or(1.0)
                .clamp(0.0, 1.0),
            valid_from,
            valid_until: fact
                .get("valid_until")
                .and_then(Value::as_str)
                .map(str::to_string),
            provider_refs: vec![ProviderRef {
                provider: provider_id.to_string(),
                external_id,
            }],
        },
        provider_id: provider_id.to_string(),
        score: lexical_score(query, summary),
        token_estimate,
        recalled_at: now_rfc3339()?,
    }))
}

fn lexical_score(query: &str, summary: &str) -> f64 {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return 0.5;
    }
    let summary = summary.to_lowercase();
    if summary.contains(&query) {
        return 1.0;
    }
    let terms = query.split_whitespace().collect::<BTreeSet<_>>();
    if terms.is_empty() {
        return 0.5;
    }
    let hits = terms.iter().filter(|term| summary.contains(**term)).count();
    0.2 + 0.8 * hits as f64 / terms.len() as f64
}

fn namespaced(namespace: &str, value: &str) -> String {
    if value.contains(':') {
        value.to_string()
    } else {
        format!("{namespace}:{value}")
    }
}

fn gbrain_kind(kind: &str) -> &str {
    match kind {
        "preference" => "preference",
        "commitment" | "decision" => "commitment",
        "experience" => "event",
        "procedure" => "belief",
        _ => "fact",
    }
}

fn harvis_kind(kind: &str) -> String {
    match kind {
        "preference" => "preference",
        "commitment" => "commitment",
        "event" => "experience",
        "belief" => "procedure",
        _ => "fact",
    }
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory_provider::MemoryProvenance;
    use std::collections::{BTreeMap, VecDeque};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Mutex;

    static NEXT_TEST_ROOT: AtomicU64 = AtomicU64::new(1);

    struct TestRoot(PathBuf);

    impl TestRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "harvis-gbrain-provider-{}-{}",
                std::process::id(),
                NEXT_TEST_ROOT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn join(&self, value: &str) -> PathBuf {
            self.0.join(value)
        }
    }

    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    struct ScriptedTransport {
        tools: Vec<String>,
        responses: Mutex<BTreeMap<String, VecDeque<Value>>>,
        calls: Mutex<Vec<(String, Value)>>,
    }

    impl McpToolTransport for ScriptedTransport {
        fn list_tools(&self) -> Result<Vec<String>> {
            Ok(self.tools.clone())
        }

        fn call_tool(&self, name: &str, arguments: &Value) -> Result<Value> {
            self.calls
                .lock()
                .expect("calls")
                .push((name.to_string(), arguments.clone()));
            self.responses
                .lock()
                .expect("responses")
                .get_mut(name)
                .and_then(VecDeque::pop_front)
                .with_context(|| format!("no scripted response for {name}"))
        }
    }

    fn transport(responses: BTreeMap<String, VecDeque<Value>>) -> Arc<ScriptedTransport> {
        Arc::new(ScriptedTransport {
            tools: VERBS.iter().map(|name| (*name).to_string()).collect(),
            responses: Mutex::new(responses),
            calls: Mutex::new(Vec::new()),
        })
    }

    fn accepted() -> MemoryRecord {
        MemoryRecord {
            memory_id: "mem_gbrain_contract".to_string(),
            schema_version: 1,
            kind: "decision".to_string(),
            scope: "project".to_string(),
            subject: "project:harvis".to_string(),
            summary: "Use the reviewed provider boundary.".to_string(),
            provenance: vec![MemoryProvenance {
                source_type: "run".to_string(),
                source_id: "synthetic-run".to_string(),
                repo_key: None,
                commit_sha: None,
            }],
            sensitivity: "shared".to_string(),
            status: "accepted".to_string(),
            confidence: 1.0,
            valid_from: "2026-08-24T00:00:00Z".to_string(),
            valid_until: None,
            provider_refs: Vec::new(),
        }
    }

    #[test]
    fn requires_exact_seven_verb_surface() {
        let root = TestRoot::new();
        let provider = GbrainMemoryProvider::new(
            "gbrain",
            transport(BTreeMap::new()),
            root.join("reconcile.sqlite3"),
        )
        .unwrap();
        assert!(provider.health().healthy);
    }

    #[test]
    fn approved_remember_is_reconciled_and_idempotent() {
        let root = TestRoot::new();
        let scripted = transport(BTreeMap::from([(
            "remember".to_string(),
            VecDeque::from([json!({
                "id": "41",
                "status": "inserted",
                "status_text": "remembered",
                "entity_slug": "project:harvis",
                "valid_until": null,
                "protocol_version": 1
            })]),
        )]));
        let provider =
            GbrainMemoryProvider::new("gbrain", scripted.clone(), root.join("reconcile.sqlite3"))
                .unwrap();
        let input = ApprovedMemoryInput {
            approval_id: "approval-1".to_string(),
            commit_id: "commit-1".to_string(),
            memory: accepted(),
        };
        let first = provider.commit_approved(&input).unwrap();
        let second = provider.commit_approved(&input).unwrap();
        assert_eq!(first.external_id, "41");
        assert!(second.idempotent_replay);
        assert_eq!(scripted.calls.lock().unwrap().len(), 1);
        let arguments = &scripted.calls.lock().unwrap()[0].1;
        assert_eq!(arguments["kind"], "commitment");
        assert_eq!(arguments["entity"], "project:harvis");
        assert!(arguments["provenance"]
            .as_str()
            .unwrap()
            .starts_with(PROVENANCE_PREFIX));
    }

    #[test]
    fn recall_ignores_foreign_facts_and_preserves_memory_id() {
        let root = TestRoot::new();
        let metadata = format!(
            "{PROVENANCE_PREFIX}{}",
            json!({"memory_id": "mem_gbrain_contract", "commit_id": "commit-1"})
        );
        let scripted = transport(BTreeMap::from([(
            "recall".to_string(),
            VecDeque::from([json!({
                "protocol_version": 1,
                "facts": [
                    {"id": 1, "fact_id": "1", "fact": "foreign", "provenance": "chat"},
                    {
                        "id": 41,
                        "fact_id": "41",
                        "fact": "Use the reviewed provider boundary.",
                        "kind": "commitment",
                        "entity_slug": "project:harvis",
                        "visibility": "world",
                        "valid_from": "2026-08-24T00:00:00Z",
                        "valid_until": null,
                        "provenance": metadata
                    }
                ],
                "total": 2
            })]),
        )]));
        let provider =
            GbrainMemoryProvider::new("gbrain", scripted, root.join("reconcile.sqlite3")).unwrap();
        let result = provider
            .recall(&RecallInput {
                query: "provider boundary".to_string(),
                project_id: Some("harvis".to_string()),
                user_id: None,
                session_id: None,
                agent_id: None,
                shared_subjects: Vec::new(),
                allowed_sensitivities: vec!["shared".to_string()],
                kinds: Vec::new(),
                token_budget: 100,
                limit: 10,
            })
            .unwrap();
        assert_eq!(result.hits.len(), 1);
        assert_eq!(result.hits[0].memory.memory_id, "mem_gbrain_contract");
    }

    #[test]
    fn malformed_protocol_response_fails_closed() {
        let root = TestRoot::new();
        let scripted = transport(BTreeMap::from([(
            "recall".to_string(),
            VecDeque::from([json!({"protocol_version": 2, "facts": []})]),
        )]));
        let provider =
            GbrainMemoryProvider::new("gbrain", scripted, root.join("reconcile.sqlite3")).unwrap();
        let error = provider
            .recall(&RecallInput {
                query: String::new(),
                project_id: None,
                user_id: None,
                session_id: None,
                agent_id: None,
                shared_subjects: Vec::new(),
                allowed_sensitivities: vec!["shared".to_string()],
                kinds: Vec::new(),
                token_budget: 100,
                limit: 10,
            })
            .unwrap_err();
        assert!(error.to_string().contains("protocol_version 1"));
    }

    #[test]
    fn approved_forget_calls_only_the_gbrain_forget_verb() {
        let root = TestRoot::new();
        let scripted = transport(BTreeMap::from([(
            "forget".to_string(),
            VecDeque::from([json!({
                "protocol_version": 1,
                "status": "forgotten",
                "id": "41"
            })]),
        )]));
        let provider =
            GbrainMemoryProvider::new("gbrain", scripted.clone(), root.join("reconcile.sqlite3"))
                .unwrap();

        let result = provider
            .forget_approved("41", Some("approved expiration"))
            .expect("approved forget");

        assert_eq!(result["status"], "forgotten");
        let calls = scripted.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "forget");
        assert_eq!(calls[0].1["id"], "41");
        assert_eq!(calls[0].1["reason"], "approved expiration");
    }
}
