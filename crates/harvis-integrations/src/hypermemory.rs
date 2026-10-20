use anyhow::{bail, Context, Result};
use harvis_core::redaction::redact_sensitive_text;
use reqwest::blocking::Client;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use serde::Serialize;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const ADAPTER_VERSION: &str = "v0.50-hypermemory-adapter";

#[derive(Debug, Clone)]
pub struct HyperMemoryPushOptions {
    pub root: PathBuf,
    pub base_url: Option<String>,
    pub api_token: Option<String>,
    pub api_token_file: Option<PathBuf>,
    pub tenant_id: String,
    pub dry_run: bool,
    pub timeout_seconds: u64,
}

#[derive(Debug, Clone)]
pub struct PushRunLessonOptions {
    pub common: HyperMemoryPushOptions,
    pub run_id: String,
}

#[derive(Debug, Clone)]
pub struct PushMemorySnapshotOptions {
    pub common: HyperMemoryPushOptions,
    pub snapshot: Option<PathBuf>,
    pub signals: Option<PathBuf>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HindsightLessonPayload {
    tenant_id: String,
    scope: String,
    title: String,
    summary: String,
    evidence_refs: String,
    pattern: String,
    recommended_action: String,
    confidence: String,
}

pub fn push_run_lesson(options: PushRunLessonOptions) -> Result<Value> {
    let root = resolve_workspace_root(&options.common.root)?;
    let run_path = resolve_run_path(&root, &options.run_id)?;
    let run = read_json(&run_path)?;
    let payload = run_lesson_payload(&options.common.tenant_id, &root, &run_path, &run)?;
    push_payload(&options.common, payload)
}

pub fn push_memory_snapshot(options: PushMemorySnapshotOptions) -> Result<Value> {
    let root = resolve_workspace_root(&options.common.root)?;
    let snapshot_path = resolve_snapshot_path(&root, options.snapshot.as_deref())?;
    let signals_path = resolve_signals_path(&root, options.signals.as_deref())?;
    let snapshot = read_json(&snapshot_path)?;
    let signals_text = fs::read_to_string(&signals_path)
        .with_context(|| format!("failed to read signals: {}", signals_path.display()))?;
    let payload = snapshot_lesson_payload(
        &options.common.tenant_id,
        &root,
        &snapshot_path,
        &signals_path,
        &snapshot,
        &signals_text,
    )?;
    push_payload(&options.common, payload)
}

pub fn check_surfaces(options: HyperMemoryPushOptions) -> Result<Value> {
    if options.dry_run {
        return Ok(json!({
            "adapter_version": ADAPTER_VERSION,
            "dry_run": true,
            "hindsight": {"endpoint": endpoint_preview_for(options.base_url.as_deref(), "/api/hindsight/lessons"), "checked": false},
            "policy": {"endpoint": endpoint_preview_for(options.base_url.as_deref(), "/api/policy/candidates"), "checked": false},
            "cognitive_cycle": {
                "direct_endpoint": null,
                "through": ["/api/agent/chat", "/api/hyper/chat", "/api/hyper/chat/with-sources"],
                "note": "CognitiveCycleService is a runtime boundary behind Agent/HyperMemory, not a standalone public API."
            },
            "review_gate": "adapter checks surfaces only; it does not approve lessons, approve policies, or execute packets"
        }));
    }
    let hindsight_endpoint = endpoint_for(options.base_url.as_deref(), "/api/hindsight/lessons")?;
    let policy_endpoint = endpoint_for(options.base_url.as_deref(), "/api/policy/candidates")?;
    let headers = auth_headers(&options)?;
    let client = Client::builder()
        .timeout(Duration::from_secs(options.timeout_seconds.max(1)))
        .build()?;
    let hindsight = get_json(
        &client,
        &headers,
        &format!(
            "{}?tenantId={}&status=ACCEPTED",
            hindsight_endpoint,
            normalize_tenant(&options.tenant_id)
        ),
    )?;
    let policy = get_json(
        &client,
        &headers,
        &format!(
            "{}?tenantId={}&approvalState=APPROVED",
            policy_endpoint,
            normalize_tenant(&options.tenant_id)
        ),
    )?;
    Ok(json!({
        "adapter_version": ADAPTER_VERSION,
        "dry_run": false,
        "hindsight": hindsight,
        "policy": policy,
        "cognitive_cycle": {
            "direct_endpoint": null,
            "through": ["/api/agent/chat", "/api/hyper/chat", "/api/hyper/chat/with-sources"],
            "note": "CognitiveCycleService is exercised through Agent/HyperMemory chat surfaces."
        },
        "review_gate": "checked recall surfaces only; no lesson/policy approval was performed"
    }))
}

fn push_payload(
    options: &HyperMemoryPushOptions,
    payload: HindsightLessonPayload,
) -> Result<Value> {
    if options.dry_run {
        return Ok(json!({
            "adapter_version": ADAPTER_VERSION,
            "dry_run": true,
            "would_post": false,
            "endpoint": endpoint_preview(options.base_url.as_deref()),
            "payload": payload,
            "review_gate": "HyperMemory HindsightService will store this as DRAFT; approval/promotion remains human/admin gated."
        }));
    }
    let base_url = options
        .base_url
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("--base-url is required unless --dry-run is set"))?;
    let endpoint = format!("{}/api/hindsight/lessons", base_url.trim_end_matches('/'));
    let headers = auth_headers(options)?;
    let client = Client::builder()
        .timeout(Duration::from_secs(options.timeout_seconds.max(1)))
        .build()?;
    let response = client
        .post(&endpoint)
        .headers(headers)
        .json(&payload)
        .send()?;
    let status = response.status();
    let body = response.text().unwrap_or_default();
    if !status.is_success() {
        bail!(
            "HyperMemory lesson POST failed with status {}: {}",
            status,
            redact_sensitive_text(&body)
        );
    }
    let body_json = serde_json::from_str::<Value>(&body).unwrap_or_else(|_| json!({"raw": body}));
    Ok(json!({
        "adapter_version": ADAPTER_VERSION,
        "dry_run": false,
        "posted": true,
        "endpoint": endpoint,
        "status": status.as_u16(),
        "response": body_json,
        "review_gate": "created lesson remains DRAFT until accepted/promoted in HyperMemory"
    }))
}

fn get_json(client: &Client, headers: &HeaderMap, endpoint: &str) -> Result<Value> {
    let response = client.get(endpoint).headers(headers.clone()).send()?;
    let status = response.status();
    let body = response.text().unwrap_or_default();
    if !status.is_success() {
        bail!(
            "HyperMemory GET failed with status {}: {}",
            status,
            redact_sensitive_text(&body)
        );
    }
    let body_json = serde_json::from_str::<Value>(&body).unwrap_or_else(|_| json!({"raw": body}));
    Ok(json!({
        "endpoint": endpoint,
        "status": status.as_u16(),
        "response": body_json
    }))
}

fn auth_headers(options: &HyperMemoryPushOptions) -> Result<HeaderMap> {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    if let Some(token) = resolve_api_token(options)? {
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {}", token.trim()))
                .context("invalid authorization token header")?,
        );
    }
    Ok(headers)
}

fn run_lesson_payload(
    tenant_id: &str,
    root: &Path,
    run_path: &Path,
    run: &Value,
) -> Result<HindsightLessonPayload> {
    let run_id = str_at(run, &["run_id"]).unwrap_or("unknown-run");
    let state = str_at(run, &["state"]).unwrap_or("unknown");
    let packet_id = str_at(run, &["packet_id"]).unwrap_or("unknown-packet");
    let packet_path = str_at(run, &["packet", "packet_path"]).unwrap_or("");
    let packet_status = str_at(run, &["packet", "status"]).unwrap_or("unknown");
    let origin = str_at(run, &["origin", "trigger"]).unwrap_or("unknown");
    let source = str_at(run, &["origin", "source"]).unwrap_or("");
    let verification = run
        .get("verification")
        .cloned()
        .unwrap_or_else(|| json!({"status": "unknown"}));
    let outputs = run.get("outputs").cloned().unwrap_or_else(|| json!({}));
    let handoff_refs = handoff_refs_for_run(root, run_id)?;
    Ok(HindsightLessonPayload {
        tenant_id: normalize_tenant(tenant_id),
        scope: "harvis-run".to_string(),
        title: truncate_line(&format!("Review Harvis run outcome: {run_id}"), 240),
        summary: format!(
            "DRAFT lesson candidate from Harvis run {run_id}. State={state}; packet={packet_id}; packet_status={packet_status}. Review before adopting as HyperMemory experience or policy."
        ),
        evidence_refs: redact_sensitive_text(&format!(
            "adapter_version={}\nrun_path={}\nrun_id={}\nstate={}\npacket_id={}\npacket_path={}\norigin={}\nsource={}\nverification={}\noutputs={}\nhandoff_refs={}",
            ADAPTER_VERSION,
            rel(run_path, root),
            run_id,
            state,
            packet_id,
            packet_path,
            origin,
            source,
            compact_json(&verification, 1200),
            compact_json(&outputs, 1200),
            handoff_refs.join(", ")
        )),
        pattern: format!(
            "Harvis run ledger completed or changed state under review-gated workflow: state={state}, packet_status={packet_status}."
        ),
        recommended_action: "Review this run outcome in HyperMemory Hindsight before accepting it as a reusable lesson or promoting it to policy.".to_string(),
        confidence: "LOW".to_string(),
    })
}

fn snapshot_lesson_payload(
    tenant_id: &str,
    root: &Path,
    snapshot_path: &Path,
    signals_path: &Path,
    snapshot: &Value,
    signals_text: &str,
) -> Result<HindsightLessonPayload> {
    let snapshot_id = str_at(snapshot, &["snapshot_id"]).unwrap_or("unknown-snapshot");
    let generated_at = str_at(snapshot, &["generated_at"]).unwrap_or("unknown-time");
    let candidate_count = snapshot
        .get("candidate_signal_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let packet_counts = snapshot
        .get("packet_status_counts")
        .cloned()
        .unwrap_or_else(|| json!({}));
    Ok(HindsightLessonPayload {
        tenant_id: normalize_tenant(tenant_id),
        scope: "harvis-memory-snapshot".to_string(),
        title: truncate_line(&format!("Review Harvis memory snapshot: {snapshot_id}"), 240),
        summary: format!(
            "DRAFT lesson candidate from Harvis memory snapshot {snapshot_id}. It contains {candidate_count} candidate signal(s) and still requires human review before adoption."
        ),
        evidence_refs: redact_sensitive_text(&format!(
            "adapter_version={}\nsnapshot_path={}\nsignals_path={}\nsnapshot_id={}\ngenerated_at={}\ncandidate_signal_count={}\npacket_status_counts={}\nsignals_excerpt={}",
            ADAPTER_VERSION,
            rel(snapshot_path, root),
            rel(signals_path, root),
            snapshot_id,
            generated_at,
            candidate_count,
            compact_json(&packet_counts, 800),
            safe_workspace_excerpt(signals_text, root, 1600)
        )),
        pattern: "Harvis memory snapshot produced reviewable candidate signals; candidates are not adopted memory until reviewed.".to_string(),
        recommended_action: "Review the snapshot signals in HyperMemory Hindsight and accept only durable, non-sensitive operational lessons.".to_string(),
        confidence: "LOW".to_string(),
    })
}

fn resolve_api_token(options: &HyperMemoryPushOptions) -> Result<Option<String>> {
    if let Some(token) = &options.api_token {
        if !token.trim().is_empty() {
            return Ok(Some(token.trim().to_string()));
        }
    }
    if let Some(path) = &options.api_token_file {
        let token = fs::read_to_string(expanduser(path))
            .with_context(|| format!("failed to read token file: {}", path.display()))?;
        let token = token.trim();
        if !token.is_empty() {
            return Ok(Some(token.to_string()));
        }
    }
    Ok(None)
}

fn resolve_workspace_root(root: &Path) -> Result<PathBuf> {
    let root = expanduser(root)
        .canonicalize()
        .with_context(|| format!("workspace root not found: {}", root.display()))?;
    if !root.is_dir() {
        bail!("workspace root is not a directory: {}", root.display());
    }
    Ok(root)
}

fn resolve_run_path(root: &Path, run_id: &str) -> Result<PathBuf> {
    let clean = run_id.trim();
    if clean.is_empty() {
        bail!("run id is required");
    }
    let file = if clean.ends_with(".json") {
        clean.to_string()
    } else {
        format!("{clean}.json")
    };
    resolve_inside(root, &root.join(".harvis/runs").join(file))
}

fn resolve_snapshot_path(root: &Path, explicit: Option<&Path>) -> Result<PathBuf> {
    if let Some(path) = explicit {
        return resolve_inside(root, &path_from_root(root, path));
    }
    let index = read_json(&root.join(".harvis/memory/index.json"))?;
    let relative = str_at(&index, &["latest_snapshot"])
        .ok_or_else(|| anyhow::anyhow!("memory index has no latest_snapshot"))?;
    resolve_inside(root, &root.join(relative))
}

fn resolve_signals_path(root: &Path, explicit: Option<&Path>) -> Result<PathBuf> {
    if let Some(path) = explicit {
        return resolve_inside(root, &path_from_root(root, path));
    }
    let index = read_json(&root.join(".harvis/memory/index.json"))?;
    let relative = str_at(&index, &["latest_signals"])
        .ok_or_else(|| anyhow::anyhow!("memory index has no latest_signals"))?;
    resolve_inside(root, &root.join(relative))
}

fn resolve_inside(root: &Path, path: &Path) -> Result<PathBuf> {
    let resolved = path
        .canonicalize()
        .with_context(|| format!("path not found: {}", path.display()))?;
    if !resolved.starts_with(root) {
        bail!(
            "path must stay inside workspace root: {}",
            resolved.display()
        );
    }
    Ok(resolved)
}

fn path_from_root(root: &Path, path: &Path) -> PathBuf {
    let expanded = expanduser(path);
    if expanded.is_absolute() {
        expanded
    } else {
        root.join(expanded)
    }
}

fn read_json(path: &Path) -> Result<Value> {
    let text =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    serde_json::from_str(&text).with_context(|| format!("invalid json: {}", path.display()))
}

fn handoff_refs_for_run(root: &Path, run_id: &str) -> Result<Vec<String>> {
    let dir = root.join(".harvis/handoffs");
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut refs = Vec::new();
    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let text = fs::read_to_string(&path).unwrap_or_default();
        if text.contains(run_id) {
            refs.push(rel(&path, root));
        }
    }
    refs.sort();
    Ok(refs)
}

fn str_at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    let mut current = value;
    for key in path {
        current = current.get(*key)?;
    }
    current.as_str()
}

fn compact_json(value: &Value, limit: usize) -> String {
    truncate_text(
        &serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()),
        limit,
    )
}

fn truncate_text(value: &str, limit: usize) -> String {
    let clean = value.replace('\r', " ").replace('\n', " ");
    if clean.chars().count() <= limit {
        return clean;
    }
    clean
        .chars()
        .take(limit.saturating_sub(14))
        .collect::<String>()
        + " [truncated]"
}

fn truncate_line(value: &str, limit: usize) -> String {
    truncate_text(value, limit).trim().to_string()
}

fn normalize_tenant(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        "default".to_string()
    } else {
        trimmed.to_ascii_lowercase()
    }
}

fn endpoint_preview(base_url: Option<&str>) -> Value {
    endpoint_preview_for(base_url, "/api/hindsight/lessons")
}

fn endpoint_preview_for(base_url: Option<&str>, path: &str) -> Value {
    base_url
        .filter(|value| !value.trim().is_empty())
        .map(|value| json!(format!("{}{}", value.trim_end_matches('/'), path)))
        .unwrap_or(Value::Null)
}

fn endpoint_for(base_url: Option<&str>, path: &str) -> Result<String> {
    let base_url = base_url
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("--base-url is required unless --dry-run is set"))?;
    Ok(format!("{}{}", base_url.trim_end_matches('/'), path))
}

fn safe_workspace_excerpt(value: &str, root: &Path, limit: usize) -> String {
    truncate_text(value, limit).replace(&root.display().to_string(), "[workspace_root]")
}

fn rel(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .display()
        .to_string()
}

fn expanduser(path: &Path) -> PathBuf {
    let raw = path.display().to_string();
    if raw == "~" {
        return home_dir();
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return home_dir().join(rest);
    }
    path.to_path_buf()
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}
