//! Read-only project knowledge routing for LLMWiki.
//!
//! LLMWiki is not a personal-memory provider. Its results stay in a separate
//! typed lane so callers can distinguish reviewed memory from generated
//! project knowledge and its immutable source pointers.

use crate::mcp_stdio::McpToolTransport;
use crate::memory_provider::{HarvisMemoryService, ProviderHealth, RecallInput, RecallResult};
use anyhow::{bail, Context, Result};
use harvis_core::time::now_rfc3339;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::sync::Arc;

const LLMWIKI_READ_TOOLS: &[&str] = &[
    "wiki_status",
    "wiki_query",
    "wiki_lint",
    "wiki_list_pages",
    "wiki_list_sources",
    "wiki_read_page",
    "wiki_read_index",
];

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct KnowledgeSource {
    pub source_type: String,
    pub source_id: String,
    pub wiki_path: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct KnowledgeHit {
    pub provider_id: String,
    pub source_type: String,
    pub title: String,
    pub wiki_path: String,
    pub excerpt: String,
    pub score: f64,
    pub token_estimate: usize,
    pub sources: Vec<KnowledgeSource>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct KnowledgeResult {
    pub provider_id: String,
    pub project_id: String,
    pub hits: Vec<KnowledgeHit>,
    pub token_used: usize,
    pub degraded: bool,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct KnowledgeStatus {
    pub provider_id: String,
    pub healthy: bool,
    pub source_count: u64,
    pub wiki_page_count: u64,
    pub orphan_page_count: u64,
    pub index_coverage_pct: f64,
    pub last_ingest_date: Option<String>,
    pub last_lint_date: Option<String>,
    pub checked_at: String,
    pub detail: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct KnowledgeQueryInput {
    pub project_id: String,
    pub query: String,
    pub token_budget: usize,
    pub limit: usize,
}

impl KnowledgeQueryInput {
    fn validate(&self) -> Result<()> {
        if self.project_id.trim().is_empty() || self.query.trim().is_empty() {
            bail!("project knowledge query requires project_id and query");
        }
        if self.limit == 0 {
            bail!("project knowledge query limit must be positive");
        }
        Ok(())
    }
}

pub trait HarvisKnowledgeProviderV1: Send + Sync {
    fn id(&self) -> &str;
    fn health(&self) -> ProviderHealth;
    fn status(&self) -> Result<KnowledgeStatus>;
    fn search(&self, input: &KnowledgeQueryInput) -> Result<KnowledgeResult>;
}

pub struct LlmWikiKnowledgeProvider {
    id: String,
    transport: Arc<dyn McpToolTransport>,
}

impl LlmWikiKnowledgeProvider {
    pub fn new(id: impl Into<String>, transport: Arc<dyn McpToolTransport>) -> Self {
        Self {
            id: id.into(),
            transport,
        }
    }

    fn read_surface_ready(&self) -> Result<()> {
        let actual = self
            .transport
            .list_tools()?
            .into_iter()
            .collect::<BTreeSet<_>>();
        let missing = LLMWIKI_READ_TOOLS
            .iter()
            .filter(|name| !actual.contains(**name))
            .copied()
            .collect::<Vec<_>>();
        if !missing.is_empty() {
            bail!("LLMWiki read surface is missing: {}", missing.join(", "));
        }
        Ok(())
    }

    fn call_read_tool(&self, name: &str, arguments: Value) -> Result<Value> {
        if !LLMWIKI_READ_TOOLS.contains(&name) {
            bail!("LLMWiki adapter refuses non-read tool: {name}");
        }
        self.transport.call_tool(name, &arguments)
    }
}

impl HarvisKnowledgeProviderV1 for LlmWikiKnowledgeProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn health(&self) -> ProviderHealth {
        let result = self
            .read_surface_ready()
            .and_then(|_| self.status().map(|_| ()));
        ProviderHealth {
            provider_id: self.id.clone(),
            healthy: result.is_ok(),
            detail: result
                .map(|_| "LLMWiki read surface ready".to_string())
                .unwrap_or_else(|error| error.to_string()),
            checked_at: now_rfc3339().unwrap_or_default(),
        }
    }

    fn status(&self) -> Result<KnowledgeStatus> {
        let value = self.call_read_tool("wiki_status", json!({}))?;
        let source_count = required_u64(&value, "source_count")?;
        let wiki_page_count = required_u64(&value, "wiki_page_count")?;
        let orphan_page_count = required_u64(&value, "orphan_page_count")?;
        let index_coverage_pct = value
            .get("index_coverage_pct")
            .and_then(Value::as_f64)
            .context("LLMWiki status is missing index_coverage_pct")?;
        let mut notes = Vec::new();
        if orphan_page_count > 0 {
            notes.push(format!("{orphan_page_count} orphan wiki pages"));
        }
        if index_coverage_pct < 100.0 {
            notes.push(format!("index coverage is {index_coverage_pct:.1}%"));
        }
        Ok(KnowledgeStatus {
            provider_id: self.id.clone(),
            healthy: true,
            source_count,
            wiki_page_count,
            orphan_page_count,
            index_coverage_pct,
            last_ingest_date: optional_string(&value, "last_ingest_date"),
            last_lint_date: optional_string(&value, "last_lint_date"),
            checked_at: now_rfc3339()?,
            detail: if notes.is_empty() {
                "ok".to_string()
            } else {
                notes.join("; ")
            },
        })
    }

    fn search(&self, input: &KnowledgeQueryInput) -> Result<KnowledgeResult> {
        input.validate()?;
        let value = self.call_read_tool("wiki_query", json!({"query": input.query}))?;
        if value.get("command").and_then(Value::as_str) != Some("query") {
            bail!("LLMWiki query response has an unknown command envelope");
        }
        let results = value
            .get("results")
            .and_then(Value::as_array)
            .context("LLMWiki query response is missing results[]")?;
        let mut hits = Vec::new();
        let mut token_used = 0;
        let mut degraded = false;
        let mut warnings = Vec::new();
        for result in results.iter().take(input.limit) {
            let title = required_string(result, "title")?;
            let path = required_string(result, "path")?;
            let excerpt = required_string(result, "excerpt")?;
            let score = result
                .get("score")
                .and_then(Value::as_f64)
                .context("LLMWiki query hit is missing score")?;
            let token_estimate = excerpt.chars().count().div_ceil(4).max(1);
            if token_used + token_estimate > input.token_budget {
                continue;
            }
            let sources = match self.call_read_tool("wiki_read_page", json!({"path": path})) {
                Ok(page) => sources_from_page(&path, &page),
                Err(error) => {
                    degraded = true;
                    warnings.push(format!("source metadata unavailable for {path}: {error}"));
                    vec![KnowledgeSource {
                        source_type: "generated_wiki_page".to_string(),
                        source_id: path.clone(),
                        wiki_path: path.clone(),
                    }]
                }
            };
            token_used += token_estimate;
            hits.push(KnowledgeHit {
                provider_id: self.id.clone(),
                source_type: "project_knowledge".to_string(),
                title,
                wiki_path: path,
                excerpt,
                score,
                token_estimate,
                sources,
            });
        }
        Ok(KnowledgeResult {
            provider_id: self.id.clone(),
            project_id: input.project_id.clone(),
            hits,
            token_used,
            degraded,
            warnings,
        })
    }
}

pub struct HarvisKnowledgeService {
    provider: Arc<dyn HarvisKnowledgeProviderV1>,
}

impl HarvisKnowledgeService {
    pub fn new(provider: Arc<dyn HarvisKnowledgeProviderV1>) -> Self {
        Self { provider }
    }

    pub fn health(&self) -> ProviderHealth {
        self.provider.health()
    }

    pub fn status(&self) -> Result<KnowledgeStatus> {
        self.provider.status()
    }

    pub fn search(&self, input: &KnowledgeQueryInput) -> KnowledgeResult {
        self.provider
            .search(input)
            .unwrap_or_else(|error| KnowledgeResult {
                provider_id: self.provider.id().to_string(),
                project_id: input.project_id.clone(),
                hits: Vec::new(),
                token_used: 0,
                degraded: true,
                warnings: vec![format!(
                    "knowledge provider unavailable: {}",
                    error.root_cause()
                )],
            })
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct UnifiedRecallResult {
    pub memory: RecallResult,
    pub knowledge: KnowledgeResult,
    pub token_used: usize,
}

/// HARVIS owns this split. DSH calls the coordinator and never selects a
/// memory or knowledge provider itself.
pub fn recall_with_project_knowledge(
    memory_service: &HarvisMemoryService,
    knowledge_service: &HarvisKnowledgeService,
    input: &RecallInput,
) -> Result<UnifiedRecallResult> {
    input.validate()?;
    let project_id = input
        .project_id
        .as_deref()
        .context("combined recall requires project_id")?;
    let total_budget = input.token_budget;
    let knowledge_budget = total_budget / 2;
    let mut memory_input = input.clone();
    memory_input.token_budget = total_budget - knowledge_budget;
    let memory = memory_service.recall(&memory_input)?;
    let knowledge = knowledge_service.search(&KnowledgeQueryInput {
        project_id: project_id.to_string(),
        query: input.query.clone(),
        token_budget: knowledge_budget,
        limit: input.limit,
    });
    Ok(UnifiedRecallResult {
        token_used: memory.token_used + knowledge.token_used,
        memory,
        knowledge,
    })
}

fn sources_from_page(wiki_path: &str, page: &Value) -> Vec<KnowledgeSource> {
    let frontmatter = page.get("frontmatter").unwrap_or(&Value::Null);
    let mut sources = Vec::new();
    if let Some(source_path) = frontmatter.get("source_path").and_then(Value::as_str) {
        sources.push(KnowledgeSource {
            source_type: "immutable_raw_source".to_string(),
            source_id: source_path.to_string(),
            wiki_path: wiki_path.to_string(),
        });
    }
    if let Some(items) = frontmatter.get("sources").and_then(Value::as_array) {
        for source in items.iter().filter_map(Value::as_str) {
            sources.push(KnowledgeSource {
                source_type: "immutable_raw_source".to_string(),
                source_id: source.to_string(),
                wiki_path: wiki_path.to_string(),
            });
        }
    }
    if sources.is_empty() {
        sources.push(KnowledgeSource {
            source_type: "generated_wiki_page".to_string(),
            source_id: wiki_path.to_string(),
            wiki_path: wiki_path.to_string(),
        });
    }
    sources.sort_by(|left, right| left.source_id.cmp(&right.source_id));
    sources.dedup_by(|left, right| left.source_id == right.source_id);
    sources
}

fn required_string(value: &Value, key: &str) -> Result<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .with_context(|| format!("LLMWiki response is missing {key}"))
}

fn required_u64(value: &Value, key: &str) -> Result<u64> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .with_context(|| format!("LLMWiki status is missing {key}"))
}

fn optional_string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{BTreeMap, VecDeque};
    use std::sync::Mutex;

    struct ScriptedTransport {
        tools: Vec<String>,
        responses: Mutex<BTreeMap<String, VecDeque<Value>>>,
        calls: Mutex<Vec<String>>,
    }

    impl McpToolTransport for ScriptedTransport {
        fn list_tools(&self) -> Result<Vec<String>> {
            Ok(self.tools.clone())
        }

        fn call_tool(&self, name: &str, _arguments: &Value) -> Result<Value> {
            self.calls.lock().unwrap().push(name.to_string());
            self.responses
                .lock()
                .unwrap()
                .get_mut(name)
                .and_then(VecDeque::pop_front)
                .with_context(|| format!("no response for {name}"))
        }
    }

    fn provider() -> (LlmWikiKnowledgeProvider, Arc<ScriptedTransport>) {
        let transport = Arc::new(ScriptedTransport {
            tools: LLMWIKI_READ_TOOLS
                .iter()
                .map(|name| (*name).to_string())
                .chain(["wiki_write_page".to_string()])
                .collect(),
            responses: Mutex::new(BTreeMap::from([
                (
                    "wiki_status".to_string(),
                    VecDeque::from([json!({
                        "command": "status", "api_version": "1",
                        "source_count": 2, "wiki_page_count": 3,
                        "last_ingest_date": "2026-08-24", "last_lint_date": null,
                        "orphan_page_count": 0, "index_coverage_pct": 100
                    })]),
                ),
                (
                    "wiki_query".to_string(),
                    VecDeque::from([json!({
                        "command": "query", "api_version": "1",
                        "query": "memory provider", "matches": 1,
                        "results": [{"title": "Memory Provider",
                            "path": "concepts/memory-provider.md", "score": 8,
                            "excerpt": "The provider remains replaceable."}]
                    })]),
                ),
                (
                    "wiki_read_page".to_string(),
                    VecDeque::from([json!({
                        "frontmatter": {"sources": ["raw/provider-plan.md"]},
                        "body": "generated body"
                    })]),
                ),
            ])),
            calls: Mutex::new(Vec::new()),
        });
        (
            LlmWikiKnowledgeProvider::new("llmwiki", transport.clone()),
            transport,
        )
    }

    #[test]
    fn status_and_search_preserve_source_lane() {
        let (provider, _) = provider();
        assert!(provider.health().healthy);
        let result = provider
            .search(&KnowledgeQueryInput {
                project_id: "harvis".to_string(),
                query: "memory provider".to_string(),
                token_budget: 100,
                limit: 5,
            })
            .unwrap();
        assert_eq!(result.hits[0].source_type, "project_knowledge");
        assert_eq!(
            result.hits[0].sources[0].source_type,
            "immutable_raw_source"
        );
        assert_eq!(result.hits[0].sources[0].source_id, "raw/provider-plan.md");
    }

    #[test]
    fn adapter_never_calls_write_tools() {
        let (provider, transport) = provider();
        provider
            .search(&KnowledgeQueryInput {
                project_id: "harvis".to_string(),
                query: "memory provider".to_string(),
                token_budget: 100,
                limit: 5,
            })
            .unwrap();
        assert!(transport
            .calls
            .lock()
            .unwrap()
            .iter()
            .all(|name| LLMWIKI_READ_TOOLS.contains(&name.as_str())));
        assert!(provider
            .call_read_tool("wiki_write_page", json!({}))
            .is_err());
    }

    #[test]
    fn malformed_query_degrades_at_service_boundary() {
        let transport = Arc::new(ScriptedTransport {
            tools: LLMWIKI_READ_TOOLS
                .iter()
                .map(|name| (*name).to_string())
                .collect(),
            responses: Mutex::new(BTreeMap::from([(
                "wiki_query".to_string(),
                VecDeque::from([json!({"unexpected": true})]),
            )])),
            calls: Mutex::new(Vec::new()),
        });
        let service = HarvisKnowledgeService::new(Arc::new(LlmWikiKnowledgeProvider::new(
            "llmwiki", transport,
        )));
        let result = service.search(&KnowledgeQueryInput {
            project_id: "harvis".to_string(),
            query: "provider".to_string(),
            token_budget: 100,
            limit: 5,
        });
        assert!(result.degraded);
        assert!(result.hits.is_empty());
    }
}
