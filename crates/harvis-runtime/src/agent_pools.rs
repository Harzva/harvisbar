use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::profile::expanduser;
use crate::runs::rel;

pub const AGENT_POOLS_VERSION: &str = "harvis.agent-pools.v0";
pub const ALLOW_FIXTURE_POOLS_ENV: &str = "HARVIS_ALLOW_FIXTURE_POOLS";

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentPoolsRegistry {
    #[serde(default = "default_version")]
    pub version: String,
    #[serde(default)]
    pub safety: Value,
    #[serde(default)]
    pub routing_policy: Value,
    #[serde(default)]
    pub harness_pool: Vec<Value>,
    #[serde(default)]
    pub model_pool: Vec<Value>,
    #[serde(default)]
    pub runtime_preset_pool: Vec<Value>,
}

#[derive(Debug, Clone)]
pub struct LoadedAgentPools {
    pub path: PathBuf,
    pub source_display: String,
    pub is_fixture: bool,
    pub registry: AgentPoolsRegistry,
}

#[derive(Debug, Clone)]
pub struct AgentPoolsOptions {
    pub root: PathBuf,
    pub path: Option<PathBuf>,
    pub query: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RuntimeSelectionOptions {
    pub root: PathBuf,
    pub path: Option<PathBuf>,
    pub text: String,
    pub selected_preset: Option<Value>,
    pub owner_slot_id: Option<String>,
}

fn default_version() -> String {
    AGENT_POOLS_VERSION.to_string()
}

pub fn default_agent_pools_path(root: &Path) -> PathBuf {
    root.join(".harvis/agent-pools.json")
}

const FIXTURE_AGENT_POOLS_RELATIVE_PATH: &str = "fixtures/agent-pools.sample.json";

pub fn fixture_agent_pools_path() -> PathBuf {
    if let Some(root) = std::env::var_os("HARVIS_PLUGIN_ROOT").map(PathBuf::from) {
        return root.join(FIXTURE_AGENT_POOLS_RELATIVE_PATH);
    }

    for start in [std::env::current_exe().ok(), std::env::current_dir().ok()]
        .into_iter()
        .flatten()
    {
        if let Some(path) = fixture_path_in_ancestors(&start) {
            return path;
        }
    }

    PathBuf::from(FIXTURE_AGENT_POOLS_RELATIVE_PATH)
}

fn fixture_path_in_ancestors(start: &Path) -> Option<PathBuf> {
    start
        .ancestors()
        .take(8)
        .map(|root| root.join(FIXTURE_AGENT_POOLS_RELATIVE_PATH))
        .find(|candidate| candidate.is_file())
}

/// The bundled sample fixture is a development aid, never a silent production
/// fallback. It may only be used through an explicit opt-in: the
/// `--allow-fixture-pools` CLI flag (which sets this env var for the process)
/// or `HARVIS_ALLOW_FIXTURE_POOLS` set to a truthy value.
pub fn fixture_pools_allowed() -> bool {
    std::env::var(ALLOW_FIXTURE_POOLS_ENV)
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

pub fn load_agent_pools(root: &Path, explicit: Option<&Path>) -> Result<LoadedAgentPools> {
    load_agent_pools_with_fixture_mode(root, explicit, fixture_pools_allowed())
}

fn load_agent_pools_with_fixture_mode(
    root: &Path,
    explicit: Option<&Path>,
    allow_fixture: bool,
) -> Result<LoadedAgentPools> {
    let root = resolve_workspace_root(root)?;
    let mut candidates = Vec::new();
    if let Some(path) = explicit {
        candidates.push(expanduser(path));
    }
    if let Ok(value) = std::env::var("HARVIS_AGENT_POOLS") {
        if !value.trim().is_empty() {
            candidates.push(expanduser(Path::new(value.trim())));
        }
    }
    candidates.push(default_agent_pools_path(&root));
    if allow_fixture {
        candidates.push(fixture_agent_pools_path());
    }

    let mut failures = Vec::new();
    for path in candidates {
        match read_agent_pools_file(&path) {
            Ok(registry) => {
                let validation = validate_agent_pools(&registry);
                if validation_has_errors(&validation) {
                    bail!("agent pools registry failed validation: {}", path.display());
                }
                let is_fixture = path == fixture_agent_pools_path();
                return Ok(LoadedAgentPools {
                    is_fixture,
                    source_display: display_path(&path),
                    path,
                    registry,
                });
            }
            Err(error) => failures.push(format!("{}: {error}", path.display())),
        }
    }
    let mut message = format!(
        "agent pools registry not found or invalid: {}",
        failures.join("; ")
    );
    if !allow_fixture {
        message.push_str(
            " (fixture fallback disabled; pass --allow-fixture-pools or set HARVIS_ALLOW_FIXTURE_POOLS=1 to allow the sample fixture)",
        );
    }
    bail!("{message}")
}

pub fn agent_pools_status(options: AgentPoolsOptions) -> Result<Value> {
    let root = resolve_workspace_root(&options.root)?;
    let loaded = load_agent_pools(&root, options.path.as_deref())?;
    let validation = validate_agent_pools(&loaded.registry);
    let query = options
        .query
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty());
    let harnesses = filter_items(&loaded.registry.harness_pool, "harness_id", query);
    let models = filter_items(&loaded.registry.model_pool, "model_id", query);
    let presets = filter_items(&loaded.registry.runtime_preset_pool, "preset_id", query);
    let adapters = adapter_summary(&loaded.registry.harness_pool, query);
    Ok(json!({
        "schemaVersion": AGENT_POOLS_VERSION,
        "schemaPath": "schemas/agent-pools.schema.json",
        "path": rel(&loaded.path, &root),
        "source": loaded.source_display,
        "root": root.display().to_string(),
        "query": query,
        "version": loaded.registry.version,
        "counts": {
            "harnesses": loaded.registry.harness_pool.len(),
            "models": loaded.registry.model_pool.len(),
            "presets": loaded.registry.runtime_preset_pool.len()
        },
        "harnesses": harnesses,
        "models": models,
        "presets": presets,
        "adapters": adapters,
        "routing_policy": loaded.registry.routing_policy,
        "safety": loaded.registry.safety,
        "validation": validation,
        "includesSecrets": false
    }))
}

pub fn select_runtime_route(options: RuntimeSelectionOptions) -> Result<Value> {
    let root = resolve_workspace_root(&options.root)?;
    let loaded = load_agent_pools(&root, options.path.as_deref())?;
    let text = options.text.trim();
    let intent = classify_runtime_intent(text);
    let explicit_preset = options
        .selected_preset
        .as_ref()
        .and_then(|preset| item_id(preset, "preset_id"));
    let prefer_explicit_harness = explicit_preset.is_none()
        && intent.preferred_harness_id.is_some()
        && intent.preferred_preset_id.is_none();
    let preset = explicit_preset
        .and_then(|preset_id| {
            find_item(&loaded.registry.runtime_preset_pool, "preset_id", preset_id)
        })
        .or_else(|| {
            intent.preferred_preset_id.and_then(|preset_id| {
                find_item(&loaded.registry.runtime_preset_pool, "preset_id", preset_id)
            })
        })
        .or_else(|| {
            if prefer_explicit_harness {
                None
            } else {
                detect_preset_from_text(&loaded.registry.runtime_preset_pool, text)
            }
        })
        .or_else(|| {
            if prefer_explicit_harness {
                None
            } else {
                choose_preset_by_capability(&loaded.registry, text)
            }
        });

    let (harness, model, mode, reason) = if let Some(preset) = preset {
        let harness_id = item_id(preset, "harness_id").unwrap_or("");
        let model_id = item_id(preset, "model_id").unwrap_or("");
        (
            find_item(&loaded.registry.harness_pool, "harness_id", harness_id),
            find_item(&loaded.registry.model_pool, "model_id", model_id),
            "preset".to_string(),
            if explicit_preset.is_some() {
                "explicit_preset".to_string()
            } else if intent.preferred_preset_id.is_some() {
                intent.reason.to_string()
            } else {
                "text_or_capability_preset".to_string()
            },
        )
    } else {
        let harness = intent
            .preferred_harness_id
            .and_then(|harness_id| {
                find_item(&loaded.registry.harness_pool, "harness_id", harness_id)
            })
            .or_else(|| choose_harness_by_capability(&loaded.registry, text))
            .or_else(|| first_usable(&loaded.registry.harness_pool));
        let model = harness
            .and_then(|harness| item_id(harness, "default_model_id"))
            .and_then(|model_id| find_item(&loaded.registry.model_pool, "model_id", model_id))
            .or_else(|| first_usable(&loaded.registry.model_pool));
        (
            harness,
            model,
            "harness-default".to_string(),
            if intent.preferred_harness_id.is_some() {
                intent.reason.to_string()
            } else {
                "capability_or_default_harness".to_string()
            },
        )
    };

    let selected = match (harness, model) {
        (Some(harness), Some(model)) => {
            let preset_value = preset.cloned();
            let harness_id = item_id(harness, "harness_id").unwrap_or("unknown");
            let model_id = item_id(model, "model_id").unwrap_or("unknown");
            let preset_id = preset_value
                .as_ref()
                .and_then(|value| item_id(value, "preset_id"))
                .map(ToOwned::to_owned);
            json!({
                "preset_id": preset_id,
                "harness_id": harness_id,
                "harness_kind": harness.get("kind").cloned().unwrap_or(Value::Null),
                "harness_label": harness.get("label").cloned().unwrap_or(Value::Null),
                "harness_status": harness.get("status").cloned().unwrap_or(Value::Null),
                "model_id": model_id,
                "model_label": model.get("label").cloned().unwrap_or(Value::Null),
                "model_provider": model.get("provider").cloned().unwrap_or(Value::Null),
                "model_status": model.get("status").cloned().unwrap_or(Value::Null),
                "review_gate": preset_value
                    .as_ref()
                    .and_then(|value| value.get("review_gate"))
                    .cloned()
                    .or_else(|| harness.get("review_gate").cloned())
                    .unwrap_or_else(|| json!("required")),
                "adapter": harness.get("adapter").cloned().unwrap_or_else(|| json!({}))
            })
        }
        _ => Value::Null,
    };

    let alternatives = loaded
        .registry
        .runtime_preset_pool
        .iter()
        .filter(|preset| item_status_is_usable(preset))
        .take(5)
        .map(|preset| {
            json!({
                "preset_id": item_id(preset, "preset_id").unwrap_or("unknown"),
                "harness_id": item_id(preset, "harness_id").unwrap_or("unknown"),
                "model_id": item_id(preset, "model_id").unwrap_or("unknown"),
                "status": preset.get("status").cloned().unwrap_or(Value::Null)
            })
        })
        .collect::<Vec<_>>();

    Ok(json!({
        "schemaVersion": AGENT_POOLS_VERSION,
        "selection_version": "harvis.runtime-selection.v0",
        "source": loaded.source_display,
        "mode": mode,
        "reason": reason,
        "recommendation": {
            "intent": intent.intent,
            "preferred_preset_id": intent.preferred_preset_id,
            "preferred_harness_id": intent.preferred_harness_id,
            "preferred_model_id": intent.preferred_model_id,
            "reason": intent.reason,
            "confidence": intent.confidence,
            "fallback_applied": selected.get("harness_id").and_then(Value::as_str) != intent.preferred_harness_id
                && selected.get("preset_id").and_then(Value::as_str) != intent.preferred_preset_id,
            "note": route_note(&loaded.registry, &intent, &selected)
        },
        "owner_slot_id": options.owner_slot_id,
        "selected": selected,
        "alternatives": alternatives,
        "routing_policy": loaded.registry.routing_policy,
        "safety": {
            "executes_task": false,
            "model_call": false,
            "requires_approval_for_execution": true,
            "includesSecrets": false
        }
    }))
}

pub fn init_agent_pools(root: &Path, overwrite: bool) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let target = default_agent_pools_path(&root);
    if target.exists() && !overwrite {
        return Ok(json!({
            "ok": true,
            "written": false,
            "path": rel(&target, &root),
            "reason": "exists"
        }));
    }
    let fixture = fixture_agent_pools_path();
    let registry = read_agent_pools_file(&fixture)
        .with_context(|| format!("read fixture agent pools: {}", fixture.display()))?;
    let validation = validate_agent_pools(&registry);
    if !validation
        .get("errors")
        .and_then(Value::as_array)
        .is_some_and(|items| items.is_empty())
    {
        bail!("fixture agent pools registry is invalid");
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }
    let text = serde_json::to_string_pretty(&registry)?;
    fs::write(&target, format!("{text}\n"))?;
    Ok(json!({
        "ok": true,
        "written": true,
        "path": rel(&target, &root),
        "counts": {
            "harnesses": registry.harness_pool.len(),
            "models": registry.model_pool.len(),
            "presets": registry.runtime_preset_pool.len()
        },
        "validation": validation
    }))
}

fn read_agent_pools_file(path: &Path) -> Result<AgentPoolsRegistry> {
    let text = fs::read_to_string(path)
        .with_context(|| format!("agent pools registry not readable: {}", path.display()))?;
    let registry: AgentPoolsRegistry = serde_json::from_str(&text)
        .with_context(|| format!("invalid agent pools json: {}", path.display()))?;
    Ok(registry)
}

fn validate_agent_pools(registry: &AgentPoolsRegistry) -> Value {
    let mut errors = Vec::new();
    let mut warnings = Vec::new();
    validate_top_level_schema(registry, &mut errors);
    if registry.version != AGENT_POOLS_VERSION {
        warnings.push(format!(
            "version is {}, expected {}",
            registry.version, AGENT_POOLS_VERSION
        ));
    }
    let harness_ids = collect_unique_ids("harness_id", &registry.harness_pool, &mut errors);
    let model_ids = collect_unique_ids("model_id", &registry.model_pool, &mut errors);
    collect_unique_ids("preset_id", &registry.runtime_preset_pool, &mut errors);

    for preset in &registry.runtime_preset_pool {
        let preset_id = item_id(preset, "preset_id").unwrap_or("unknown");
        match item_id(preset, "harness_id") {
            Some(id) if harness_ids.contains(id) => {}
            Some(id) => errors.push(format!("{preset_id}: unknown harness_id {id}")),
            None => errors.push(format!("{preset_id}: harness_id is required")),
        }
        match item_id(preset, "model_id") {
            Some(id) if model_ids.contains(id) => {}
            Some(id) => errors.push(format!("{preset_id}: unknown model_id {id}")),
            None => errors.push(format!("{preset_id}: model_id is required")),
        }
        if item_id(preset, "review_gate") != Some("required") {
            warnings.push(format!("{preset_id}: review_gate should be required"));
        }
    }
    if secret_like_value(&serde_json::to_value(registry).unwrap_or(Value::Null)) {
        errors.push("registry contains secret-like key or value".to_string());
    }
    json!({
        "ok": errors.is_empty(),
        "schema": "schemas/agent-pools.schema.json",
        "errors": errors,
        "warnings": warnings
    })
}

fn validate_top_level_schema(registry: &AgentPoolsRegistry, errors: &mut Vec<String>) {
    validate_safety(&registry.safety, errors);
    validate_routing_policy(&registry.routing_policy, errors);
    for harness in &registry.harness_pool {
        validate_harness(harness, errors);
    }
    for model in &registry.model_pool {
        validate_model(model, errors);
    }
    for preset in &registry.runtime_preset_pool {
        validate_preset(preset, errors);
    }
}

fn validate_safety(safety: &Value, errors: &mut Vec<String>) {
    require_bool_const(safety, "safety.includesSecrets", false, errors);
    require_bool_const(safety, "safety.includesCredentialValues", false, errors);
    require_bool_const(safety, "safety.includesCredentialPaths", false, errors);
    require_bool_const(safety, "safety.reviewGateRequired", true, errors);
}

fn validate_routing_policy(policy: &Value, errors: &mut Vec<String>) {
    require_string_const(
        policy,
        "routing_policy.agent_identity_source",
        "agent-roster",
        errors,
    );
    require_string_enum(
        policy,
        "routing_policy.harness_selection",
        &["agent-default", "task-capability", "explicit-user-choice"],
        errors,
    );
    require_string_enum(
        policy,
        "routing_policy.model_selection",
        &["agent-default", "task-capability", "explicit-user-choice"],
        errors,
    );
    require_string_enum(
        policy,
        "routing_policy.fallback_mode",
        &["ordered", "disabled"],
        errors,
    );
}

fn validate_harness(harness: &Value, errors: &mut Vec<String>) {
    let id = item_id(harness, "harness_id").unwrap_or("unknown");
    for key in [
        "harness_id",
        "label",
        "kind",
        "status",
        "command_aliases",
        "adapter",
        "default_model_id",
        "allowed_model_ids",
        "review_gate",
    ] {
        require_present(harness, &format!("harness {id}.{key}"), key, errors);
    }
    require_string_enum(
        harness,
        &format!("harness {id}.kind"),
        &[
            "codex",
            "dsh",
            "kimi-code",
            "claude-code",
            "likecode",
            "manual",
            "other",
        ],
        errors,
    );
    validate_status(harness, &format!("harness {id}.status"), errors);
    require_string_enum(
        harness,
        &format!("harness {id}.review_gate"),
        &["required", "recommended", "not-allowed"],
        errors,
    );
    let adapter = harness.get("adapter").unwrap_or(&Value::Null);
    require_string_enum(
        adapter,
        &format!("harness {id}.adapter.mode"),
        &["cli", "mcp", "http", "manual"],
        errors,
    );
    require_string_enum(
        adapter,
        &format!("harness {id}.adapter.prompt_input"),
        &["stdin", "arg", "file", "manual"],
        errors,
    );
    require_string_enum(
        adapter,
        &format!("harness {id}.adapter.result_output"),
        &["stdout", "file", "json", "manual"],
        errors,
    );
}

fn validate_model(model: &Value, errors: &mut Vec<String>) {
    let id = item_id(model, "model_id").unwrap_or("unknown");
    for key in [
        "model_id",
        "label",
        "provider",
        "status",
        "credential_ref",
        "capabilities",
        "preferred_harness_ids",
    ] {
        require_present(model, &format!("model {id}.{key}"), key, errors);
    }
    require_string_enum(
        model,
        &format!("model {id}.provider"),
        &[
            "openai",
            "moonshot-kimi",
            "deepseek",
            "anthropic",
            "minimax",
            "siliconflow",
            "local",
            "other",
        ],
        errors,
    );
    validate_status(model, &format!("model {id}.status"), errors);
    let credential = model.get("credential_ref").unwrap_or(&Value::Null);
    require_string_enum(
        credential,
        &format!("model {id}.credential_ref.kind"),
        &[
            "env",
            "cli-profile",
            "keychain",
            "local-access-note",
            "none",
        ],
        errors,
    );
    match item_id(credential, "ref") {
        Some(value) if looks_like_sensitive_path(value) => errors.push(format!(
            "model {id}.credential_ref.ref must be a label, not a local secret path"
        )),
        Some(_) => {}
        None => errors.push(format!("model {id}.credential_ref.ref is required")),
    }
    require_bool_const(
        credential,
        &format!("model {id}.credential_ref.contains_secret_value"),
        false,
        errors,
    );
}

fn validate_preset(preset: &Value, errors: &mut Vec<String>) {
    let id = item_id(preset, "preset_id").unwrap_or("unknown");
    for key in [
        "preset_id",
        "label",
        "harness_id",
        "model_id",
        "status",
        "command_aliases",
        "review_gate",
    ] {
        require_present(preset, &format!("preset {id}.{key}"), key, errors);
    }
    validate_status(preset, &format!("preset {id}.status"), errors);
    require_string_enum(
        preset,
        &format!("preset {id}.review_gate"),
        &["required", "recommended", "not-allowed"],
        errors,
    );
}

fn validate_status(value: &Value, label: &str, errors: &mut Vec<String>) {
    require_string_enum(
        value,
        label,
        &["active", "partial", "pending", "disabled"],
        errors,
    );
}

fn require_present(value: &Value, label: &str, key: &str, errors: &mut Vec<String>) {
    if value.get(key).is_none_or(Value::is_null) {
        errors.push(format!("{label} is required"));
    }
}

fn require_bool_const(value: &Value, dotted: &str, expected: bool, errors: &mut Vec<String>) {
    let actual = get_last_key(value, dotted).and_then(Value::as_bool);
    if actual != Some(expected) {
        errors.push(format!("{dotted} must be {expected}"));
    }
}

fn require_string_const(value: &Value, dotted: &str, expected: &str, errors: &mut Vec<String>) {
    let actual = get_last_key(value, dotted).and_then(Value::as_str);
    if actual != Some(expected) {
        errors.push(format!("{dotted} must be {expected}"));
    }
}

fn require_string_enum(value: &Value, dotted: &str, allowed: &[&str], errors: &mut Vec<String>) {
    let actual = get_last_key(value, dotted).and_then(Value::as_str);
    if !actual.is_some_and(|item| allowed.contains(&item)) {
        errors.push(format!("{dotted} must be one of {}", allowed.join(", ")));
    }
}

fn get_last_key<'a>(value: &'a Value, dotted: &str) -> Option<&'a Value> {
    let key = dotted.rsplit('.').next().unwrap_or(dotted);
    value.get(key)
}

fn looks_like_sensitive_path(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    value.starts_with('/')
        || value.starts_with("~/")
        || lower.contains(".env")
        || lower.contains("access")
        || lower.contains("token")
        || lower.contains("secret")
        || lower.contains("cookie")
}

fn adapter_summary(harnesses: &[Value], query: Option<&str>) -> Vec<Value> {
    let query = query.map(str::to_ascii_lowercase);
    harnesses
        .iter()
        .filter_map(|harness| {
            let harness_id = item_id(harness, "harness_id")?;
            let adapter = harness.get("adapter").cloned().unwrap_or_else(|| json!({}));
            let label = harness
                .get("label")
                .and_then(Value::as_str)
                .unwrap_or(harness_id);
            let text = format!(
                "{harness_id} {label} {} {} {}",
                adapter.get("mode").and_then(Value::as_str).unwrap_or(""),
                adapter
                    .get("prompt_input")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
                adapter
                    .get("result_output")
                    .and_then(Value::as_str)
                    .unwrap_or("")
            )
            .to_ascii_lowercase();
            if query.as_ref().is_some_and(|query| !text.contains(query)) {
                return None;
            }
            Some(json!({
                "harness_id": harness_id,
                "label": label,
                "kind": harness.get("kind").cloned().unwrap_or(Value::Null),
                "status": harness.get("status").cloned().unwrap_or(Value::Null),
                "review_gate": harness.get("review_gate").cloned().unwrap_or(Value::Null),
                "adapter": adapter
            }))
        })
        .collect()
}

fn detect_preset_from_text<'a>(presets: &'a [Value], text: &str) -> Option<&'a Value> {
    let lower = text.to_ascii_lowercase();
    presets.iter().find(|preset| {
        if !item_status_is_usable(preset) {
            return false;
        }
        let preset_id = item_id(preset, "preset_id").unwrap_or("");
        lower.contains(&preset_id.to_ascii_lowercase())
            || preset
                .get("command_aliases")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .any(|alias| {
                    let alias = alias.trim().to_ascii_lowercase();
                    !alias.is_empty() && lower.contains(&alias)
                })
    })
}

#[derive(Debug, Clone, Copy)]
struct RuntimeIntent {
    intent: &'static str,
    preferred_preset_id: Option<&'static str>,
    preferred_harness_id: Option<&'static str>,
    preferred_model_id: Option<&'static str>,
    reason: &'static str,
    confidence: f64,
}

fn classify_runtime_intent(text: &str) -> RuntimeIntent {
    let lower = text.to_ascii_lowercase();
    if is_external_article_material_text(&lower) {
        return RuntimeIntent {
            intent: "external_article_codex_conductor_task",
            preferred_preset_id: Some("codex-controller"),
            preferred_harness_id: Some("codex"),
            preferred_model_id: Some("openai:gpt-5.5"),
            reason: "external_article_links_need_codex_conductor_dynamic_planning",
            confidence: 0.9,
        };
    }
    if lower.contains("cckimi") || lower.contains("kimicode") || lower.contains("kimi") {
        return RuntimeIntent {
            intent: "long_context_or_kimi_requested",
            preferred_preset_id: Some("cckimi"),
            preferred_harness_id: Some("kimicode"),
            preferred_model_id: Some("moonshot-kimi:kimi-code/kimi-for-coding"),
            reason: "explicit_kimi_or_long_context_route",
            confidence: 0.92,
        };
    }
    if lower.contains("mimocode") || lower.contains("mimo") {
        return RuntimeIntent {
            intent: "mimocode_requested",
            preferred_preset_id: Some("mimocode"),
            preferred_harness_id: Some("mimocode"),
            preferred_model_id: Some("xiaomi:mimo-v2.5-pro-ultraspeed"),
            reason: "explicit_mimocode_route",
            confidence: 0.9,
        };
    }
    if lower.contains("claude") {
        return RuntimeIntent {
            intent: "claude_requested",
            preferred_preset_id: None,
            preferred_harness_id: Some("claude-code"),
            preferred_model_id: Some("anthropic:claude-code-default"),
            reason: "explicit_claude_route",
            confidence: 0.84,
        };
    }
    if lower.contains("likecode") {
        return RuntimeIntent {
            intent: "likecode_requested",
            preferred_preset_id: None,
            preferred_harness_id: Some("likecode"),
            preferred_model_id: Some("deepseek:deepseek-v4-pro"),
            reason: "explicit_likecode_route",
            confidence: 0.88,
        };
    }
    if lower.contains("digital-me") || lower.contains("digital me") || lower.contains("dsh") {
        return RuntimeIntent {
            intent: "digital_me_dsh_requested",
            preferred_preset_id: Some("digital-me-dsh"),
            preferred_harness_id: Some("dsh"),
            preferred_model_id: Some("dsh:profile-default"),
            reason: "explicit_digital_me_dsh_route",
            confidence: 0.94,
        };
    }
    if lower.contains("deepseek") {
        return RuntimeIntent {
            intent: "deepseek_requested",
            preferred_preset_id: Some("ccdeepseek"),
            preferred_harness_id: Some("claude-code"),
            preferred_model_id: Some("deepseek:deepseek-v4-pro"),
            reason: "explicit_deepseek_claude_code_route",
            confidence: 0.9,
        };
    }
    if lower.contains("长上下文")
        || lower.contains("long-context")
        || lower.contains("长文")
        || lower.contains("论文")
        || lower.contains("paper")
        || lower.contains("总结文章")
    {
        return RuntimeIntent {
            intent: "long_context_reading",
            preferred_preset_id: Some("cckimi"),
            preferred_harness_id: Some("kimicode"),
            preferred_model_id: Some("moonshot-kimi:kimi-code/kimi-for-coding"),
            reason: "long_context_reading_route",
            confidence: 0.78,
        };
    }
    if lower.contains("审查")
        || lower.contains("review")
        || lower.contains("风险")
        || lower.contains("复核")
        || lower.contains("辩证")
    {
        return RuntimeIntent {
            intent: "review_or_risk_analysis",
            preferred_preset_id: Some("mimocode"),
            preferred_harness_id: Some("mimocode"),
            preferred_model_id: Some("xiaomi:mimo-v2.5-pro-ultraspeed"),
            reason: "review_or_risk_analysis_route",
            confidence: 0.72,
        };
    }
    if is_local_file_lookup_text(&lower) {
        return RuntimeIntent {
            intent: "local_file_lookup",
            preferred_preset_id: Some("cxgpt55"),
            preferred_harness_id: Some("codex"),
            preferred_model_id: Some("openai:gpt-5.5"),
            reason: "local_file_lookup_route",
            confidence: 0.82,
        };
    }
    if lower.contains("browser")
        || lower.contains("chrome")
        || lower.contains("playwright")
        || lower.contains("computer use")
        || lower.contains("computer-use")
        || lower.contains("浏览器")
        || lower.contains("打开网页")
        || lower.contains("打开网站")
        || lower.contains("打开百度")
        || lower.contains("百度")
        || lower.contains("搜索")
        || lower.contains("点击网页")
        || lower.contains("网页点击")
    {
        return RuntimeIntent {
            intent: "browser_operation",
            preferred_preset_id: Some("cxgpt55"),
            preferred_harness_id: Some("codex"),
            preferred_model_id: Some("openai:gpt-5.5"),
            reason: "browser_or_computer_use_route",
            confidence: 0.84,
        };
    }
    if lower.contains("cxspark") || lower.contains("spark") {
        return RuntimeIntent {
            intent: "cxspark_requested",
            preferred_preset_id: Some("cxspark"),
            preferred_harness_id: Some("codex"),
            preferred_model_id: Some("openai:gpt-5.3-codex-spark"),
            reason: "explicit_cxspark_route",
            confidence: 0.9,
        };
    }
    if lower.contains("debug")
        || lower.contains("repo")
        || lower.contains("仓库")
        || lower.contains("代码")
        || lower.contains("前端")
        || lower.contains("webview")
        || lower.contains("ui")
        || lower.contains("写网页")
        || lower.contains("修复")
    {
        return RuntimeIntent {
            intent: "coding_or_repo_work",
            preferred_preset_id: Some("digital-me-dsh"),
            preferred_harness_id: Some("dsh"),
            preferred_model_id: Some("dsh:profile-default"),
            reason: "digital_me_dsh_coding_repo_or_ui_route",
            confidence: 0.8,
        };
    }
    RuntimeIntent {
        intent: "default_digital_me_route",
        preferred_preset_id: Some("digital-me-dsh"),
        preferred_harness_id: Some("dsh"),
        preferred_model_id: Some("dsh:profile-default"),
        reason: "default_digital_me_dsh_route",
        confidence: 0.55,
    }
}

fn is_local_file_lookup_text(lower: &str) -> bool {
    let has_local_path = lower.contains("/volumes/")
        || lower.contains("/users/")
        || lower.contains("~/")
        || lower.contains(".harvis/")
        || lower.contains(".codex/");
    let has_document_ext = lower.contains(".pdf")
        || lower.contains(".docx")
        || lower.contains(".doc")
        || lower.contains(".pptx")
        || lower.contains(".xlsx")
        || lower.contains(".md")
        || lower.contains(".txt");
    let has_local_word = lower.contains("本地") || lower.contains("文件") || lower.contains("文档");
    let has_lookup_word = lower.contains("搜索")
        || lower.contains("查")
        || lower.contains("找")
        || lower.contains("展示")
        || lower.contains("打开")
        || lower.contains("读取")
        || lower.contains("extract")
        || lower.contains("search")
        || lower.contains("show")
        || lower.contains("open");
    (has_local_path || has_document_ext || has_local_word) && has_lookup_word
}

fn route_note(registry: &AgentPoolsRegistry, intent: &RuntimeIntent, selected: &Value) -> String {
    let selected_harness = selected.get("harness_id").and_then(Value::as_str);
    let selected_preset = selected.get("preset_id").and_then(Value::as_str);
    if selected_harness == intent.preferred_harness_id
        || selected_preset == intent.preferred_preset_id
    {
        return "preferred route is available in the registry".to_string();
    }
    if let Some(harness_id) = intent.preferred_harness_id {
        if let Some(harness) =
            find_item_any_status(&registry.harness_pool, "harness_id", harness_id)
        {
            let status = harness
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            return format!(
                "preferred harness {harness_id} is {status}; selected a safe available fallback"
            );
        }
    }
    if let Some(preset_id) = intent.preferred_preset_id {
        if let Some(preset) =
            find_item_any_status(&registry.runtime_preset_pool, "preset_id", preset_id)
        {
            let status = preset
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            return format!(
                "preferred preset {preset_id} is {status}; selected a safe available fallback"
            );
        }
    }
    "preferred route was not found; selected a safe available fallback".to_string()
}

fn choose_preset_by_capability<'a>(
    registry: &'a AgentPoolsRegistry,
    text: &str,
) -> Option<&'a Value> {
    let lower = text.to_ascii_lowercase();
    let preferred = if lower.contains("kimi")
        || lower.contains("长上下文")
        || lower.contains("long-context")
        || lower.contains("长文")
    {
        Some("cckimi")
    } else if lower.contains("mimocode") || lower.contains("mimo") {
        Some("mimocode")
    } else if lower.contains("spark")
        || lower.contains("cxspark")
        || lower.contains("快")
        || lower.contains("快速")
    {
        Some("cxspark")
    } else {
        Some("digital-me-dsh")
    };
    preferred
        .and_then(|preset_id| find_item(&registry.runtime_preset_pool, "preset_id", preset_id))
        .or_else(|| find_item(&registry.runtime_preset_pool, "preset_id", "digital-me-dsh"))
        .or_else(|| find_item(&registry.runtime_preset_pool, "preset_id", "cxgpt55"))
        .filter(|preset| item_status_is_usable(preset))
}

fn choose_harness_by_capability<'a>(
    registry: &'a AgentPoolsRegistry,
    text: &str,
) -> Option<&'a Value> {
    let lower = text.to_ascii_lowercase();
    let preferred =
        if lower.contains("digital-me") || lower.contains("digital me") || lower.contains("dsh") {
            Some("dsh")
        } else if lower.contains("likecode") {
            Some("likecode")
        } else if lower.contains("deepseek") {
            Some("claude-code")
        } else if lower.contains("claude") {
            Some("claude-code")
        } else if lower.contains("kimi") {
            Some("kimicode")
        } else {
            Some("dsh")
        };
    preferred
        .and_then(|harness_id| find_item(&registry.harness_pool, "harness_id", harness_id))
        .filter(|harness| item_status_is_usable(harness))
}

fn is_external_article_material_text(lower: &str) -> bool {
    lower.contains("mp.weixin.qq.com")
        || lower.contains("zhuanlan.zhihu.com")
        || lower.contains("zhihu.com/question")
        || lower.contains("zhihu.com/tardis")
        || lower.contains("blog.csdn.net")
        || lower.contains("csdn.net")
        || lower.contains("微信链接")
        || lower.contains("微信文章")
        || lower.contains("公众号")
        || lower.contains("知乎链接")
        || lower.contains("知乎文章")
        || lower.contains("csdn链接")
        || lower.contains("csdn文章")
        || lower.contains("wechat article")
}

fn first_usable(items: &[Value]) -> Option<&Value> {
    items.iter().find(|item| item_status_is_usable(item))
}

fn find_item<'a>(items: &'a [Value], key: &str, expected: &str) -> Option<&'a Value> {
    items
        .iter()
        .find(|item| item_id(item, key) == Some(expected) && item_status_is_usable(item))
}

fn find_item_any_status<'a>(items: &'a [Value], key: &str, expected: &str) -> Option<&'a Value> {
    items
        .iter()
        .find(|item| item_id(item, key) == Some(expected))
}

fn item_status_is_usable(item: &Value) -> bool {
    matches!(
        item.get("status").and_then(Value::as_str),
        Some("active") | Some("partial")
    )
}

fn validation_has_errors(validation: &Value) -> bool {
    validation
        .get("errors")
        .and_then(Value::as_array)
        .is_some_and(|items| !items.is_empty())
}

fn collect_unique_ids<'a>(
    key: &str,
    items: &'a [Value],
    errors: &mut Vec<String>,
) -> BTreeSet<&'a str> {
    let mut ids = BTreeSet::new();
    for item in items {
        let Some(id) = item_id(item, key) else {
            errors.push(format!("{key} is required"));
            continue;
        };
        if !ids.insert(id) {
            errors.push(format!("duplicate {key}: {id}"));
        }
    }
    ids
}

fn item_id<'a>(item: &'a Value, key: &str) -> Option<&'a str> {
    item.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|v| !v.is_empty())
}

fn filter_items(items: &[Value], primary_key: &str, query: Option<&str>) -> Vec<Value> {
    let Some(query) = query else {
        return items.to_vec();
    };
    let query = query.to_ascii_lowercase();
    items
        .iter()
        .filter(|item| {
            let text = [
                item.get(primary_key).and_then(Value::as_str).unwrap_or(""),
                item.get("label").and_then(Value::as_str).unwrap_or(""),
                item.get("kind").and_then(Value::as_str).unwrap_or(""),
                item.get("provider").and_then(Value::as_str).unwrap_or(""),
            ]
            .join(" ")
            .to_ascii_lowercase();
            text.contains(&query)
        })
        .cloned()
        .collect()
}

fn secret_like_value(value: &Value) -> bool {
    match value {
        Value::Object(map) => map.iter().any(|(key, value)| {
            let key = key.to_ascii_lowercase();
            (key.contains("token")
                || key.contains("secret")
                || key.contains("password")
                || key.contains("api_key"))
                && !matches!(value, Value::Bool(false) | Value::Null)
                || secret_like_value(value)
        }),
        Value::Array(items) => items.iter().any(secret_like_value),
        Value::String(text) => text.starts_with("sk-") || text.contains("BEGIN PRIVATE KEY"),
        _ => false,
    }
}

fn resolve_workspace_root(root: &Path) -> Result<PathBuf> {
    if root.as_os_str().is_empty() {
        bail!("workspace root must be non-empty");
    }
    if root.is_absolute() {
        Ok(root.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(root))
    }
}

fn display_path(path: &Path) -> String {
    let mut text = path.display().to_string();
    if let Some(home) = std::env::var_os("HOME") {
        let home = home.to_string_lossy();
        text = text.replace(home.as_ref(), "~");
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn fixture_agent_pools_validate() {
        let loaded = load_agent_pools(Path::new("/tmp"), Some(&fixture_agent_pools_path()))
            .expect("fixture should load");
        let status = agent_pools_status(AgentPoolsOptions {
            root: PathBuf::from("/tmp"),
            path: Some(loaded.path),
            query: Some("cxspark".to_string()),
        })
        .expect("status");
        assert_eq!(status["counts"]["harnesses"], json!(6));
        assert_eq!(status["presets"][0]["preset_id"], json!("cxspark"));
        assert_eq!(status["validation"]["ok"], json!(true));
        let full_status = agent_pools_status(AgentPoolsOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            query: None,
        })
        .expect("full status");
        assert_eq!(full_status["adapters"][0]["harness_id"], json!("codex"));
    }

    #[test]
    fn select_runtime_defaults_to_digital_me_dsh_preset() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "任务：检查 just-ddl 失败原因".to_string(),
            selected_preset: None,
            owner_slot_id: Some("executor".to_string()),
        })
        .expect("selection");
        assert_eq!(selected["selected"]["preset_id"], json!("digital-me-dsh"));
        assert_eq!(selected["selected"]["harness_id"], json!("dsh"));
        assert_eq!(
            selected["selected"]["model_id"],
            json!("dsh:profile-default")
        );
        assert_eq!(selected["safety"]["executes_task"], json!(false));
    }

    #[test]
    fn select_runtime_honors_explicit_dsh_text() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "任务：请用 Digital-Me DSH 处理这个请求".to_string(),
            selected_preset: None,
            owner_slot_id: Some("executor".to_string()),
        })
        .expect("selection");
        assert_eq!(
            selected["recommendation"]["intent"],
            json!("digital_me_dsh_requested")
        );
        assert_eq!(selected["selected"]["preset_id"], json!("digital-me-dsh"));
        assert_eq!(selected["selected"]["harness_id"], json!("dsh"));
    }

    #[test]
    fn select_runtime_honors_kimi_text() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "任务：用 Kimi 长上下文阅读这些文档".to_string(),
            selected_preset: None,
            owner_slot_id: Some("planner".to_string()),
        })
        .expect("selection");
        assert_eq!(selected["selected"]["preset_id"], json!("cckimi"));
        assert_eq!(selected["selected"]["harness_id"], json!("kimicode"));
    }

    #[test]
    fn select_runtime_routes_external_article_materials_to_codex() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "任务：处理 https://mp.weixin.qq.com/s/example 这个微信文章链接，入库到 wemedia 文章素材库并生成微信公众号草稿".to_string(),
            selected_preset: None,
            owner_slot_id: Some("planner".to_string()),
        })
        .expect("selection");
        assert_eq!(
            selected["recommendation"]["intent"],
            json!("external_article_codex_conductor_task")
        );
        assert_eq!(selected["selected"]["preset_id"], json!("codex-controller"));
        assert_eq!(selected["selected"]["harness_id"], json!("codex"));
        assert_eq!(selected["selected"]["model_id"], json!("openai:gpt-5.5"));
        assert_eq!(selected["safety"]["executes_task"], json!(false));
    }

    #[test]
    fn external_article_codex_route_wins_over_kimi_helper_text() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "外部文章链接入库并生成带图片的微信公众号草稿 https://mp.weixin.qq.com/s/example；Kimi 只可作为长文理解辅助，不负责最终图文草稿闭环。".to_string(),
            selected_preset: None,
            owner_slot_id: Some("planner".to_string()),
        })
        .expect("selection");
        assert_eq!(
            selected["recommendation"]["intent"],
            json!("external_article_codex_conductor_task")
        );
        assert_eq!(selected["selected"]["preset_id"], json!("codex-controller"));
        assert_eq!(selected["selected"]["harness_id"], json!("codex"));
    }

    #[test]
    fn select_runtime_routes_ui_work_to_digital_me_dsh() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "任务：修复 Harvis WebView UI 布局".to_string(),
            selected_preset: None,
            owner_slot_id: Some("executor".to_string()),
        })
        .expect("selection");
        assert_eq!(
            selected["recommendation"]["intent"],
            json!("coding_or_repo_work")
        );
        assert_eq!(selected["selected"]["preset_id"], json!("digital-me-dsh"));
        assert_eq!(selected["selected"]["harness_id"], json!("dsh"));
        assert_eq!(
            selected["selected"]["model_id"],
            json!("dsh:profile-default")
        );
    }

    #[test]
    fn select_runtime_routes_local_docx_lookup_to_codex_gpt55() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "/workspace/harmonyos/guide.docx 搜索这个docx".to_string(),
            selected_preset: None,
            owner_slot_id: Some("executor".to_string()),
        })
        .expect("selection");
        assert_eq!(
            selected["recommendation"]["intent"],
            json!("local_file_lookup")
        );
        assert_eq!(selected["selected"]["preset_id"], json!("cxgpt55"));
        assert_eq!(selected["selected"]["harness_id"], json!("codex"));
        assert_eq!(selected["selected"]["model_id"], json!("openai:gpt-5.5"));
    }

    #[test]
    fn select_runtime_routes_browser_work_to_codex_gpt55() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "任务：打开浏览器的百度然后搜索 小狗".to_string(),
            selected_preset: None,
            owner_slot_id: Some("executor".to_string()),
        })
        .expect("selection");
        assert_eq!(
            selected["recommendation"]["intent"],
            json!("browser_operation")
        );
        assert_eq!(selected["selected"]["preset_id"], json!("cxgpt55"));
        assert_eq!(selected["selected"]["harness_id"], json!("codex"));
        assert_eq!(selected["selected"]["model_id"], json!("openai:gpt-5.5"));
        assert_eq!(selected["safety"]["executes_task"], json!(false));
    }

    #[test]
    fn select_runtime_routes_likecode_when_active() {
        let selected = select_runtime_route(RuntimeSelectionOptions {
            root: PathBuf::from("/tmp"),
            path: Some(fixture_agent_pools_path()),
            text: "任务：用 deepseek / likecode 判断方案".to_string(),
            selected_preset: None,
            owner_slot_id: Some("planner".to_string()),
        })
        .expect("selection");
        assert_eq!(
            selected["recommendation"]["preferred_harness_id"],
            json!("likecode")
        );
        assert_eq!(selected["recommendation"]["fallback_applied"], json!(false));
        assert_eq!(selected["selected"]["harness_id"], json!("likecode"));
        assert_eq!(
            selected["selected"]["model_id"],
            json!("deepseek:deepseek-v4-pro")
        );
    }

    #[test]
    fn invalid_root_registry_does_not_fallback_to_fixture() {
        let root =
            std::env::temp_dir().join(format!("harvis-agent-pools-invalid-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".harvis")).expect("mkdir");
        fs::write(
            root.join(".harvis/agent-pools.json"),
            r#"{
              "version": "harvis.agent-pools.v0",
              "safety": {
                "includesSecrets": false,
                "includesCredentialValues": false,
                "includesCredentialPaths": false,
                "reviewGateRequired": true
              },
              "routing_policy": {
                "agent_identity_source": "agent-roster",
                "harness_selection": "task-capability",
                "model_selection": "task-capability",
                "fallback_mode": "ordered"
              },
              "harness_pool": [{
                "harness_id": "codex",
                "label": "Codex",
                "kind": "codex",
                "status": "active",
                "command_aliases": ["codex"],
                "adapter": {"mode": "cli", "prompt_input": "stdin", "result_output": "file"},
                "supports_model_override": true,
                "default_model_id": "openai:gpt-5-codex",
                "allowed_model_ids": ["openai:gpt-5-codex"],
                "review_gate": "required"
              }],
              "model_pool": [],
              "runtime_preset_pool": [{
                "preset_id": "bad",
                "label": "Bad",
                "harness_id": "codex",
                "model_id": "missing:model",
                "status": "active",
                "command_aliases": ["bad"],
                "review_gate": "required"
              }]
            }"#,
        )
        .expect("write invalid registry");

        let error = load_agent_pools(&root, None).expect_err("invalid root should fail");
        assert!(
            error
                .to_string()
                .contains("agent pools registry failed validation"),
            "{error}"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_registry_rejects_fixture_fallback_by_default() {
        let root =
            std::env::temp_dir().join(format!("harvis-agent-pools-missing-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".harvis")).expect("mkdir");

        let error = load_agent_pools_with_fixture_mode(&root, None, false)
            .expect_err("missing registry must fail when the fixture fallback is not allowed");
        let text = error.to_string();
        assert!(
            text.contains("agent pools registry not found or invalid"),
            "{text}"
        );
        assert!(text.contains("fixture fallback disabled"), "{text}");
        assert!(
            !text.contains("agent-pools.sample.json: "),
            "fixture must not be attempted silently: {text}"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_registry_uses_fixture_only_with_explicit_allowance() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-pools-fixture-allowed-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".harvis")).expect("mkdir");

        let loaded = load_agent_pools_with_fixture_mode(&root, None, true)
            .expect("fixture should load when explicitly allowed");
        assert!(loaded.is_fixture);
        assert_eq!(loaded.path, fixture_agent_pools_path());
        assert_eq!(loaded.registry.runtime_preset_pool.len(), 7);

        let _ = fs::remove_dir_all(root);
    }
}
