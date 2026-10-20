use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use crate::agent_pools::load_agent_pools;
use crate::profile::expanduser;
use crate::provider_registry::load_provider_registry;
use crate::runs::rel;

pub const AGENT_ROSTER_VERSION: &str = "v0.1-agent-roster";

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentRoster {
    #[serde(default = "default_roster_version")]
    pub version: String,
    #[serde(default)]
    pub sync_policy: RosterSyncPolicy,
    #[serde(default)]
    pub transports: BTreeMap<String, Value>,
    #[serde(default)]
    pub agents: Vec<AgentDefinition>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RosterSyncPolicy {
    #[serde(default = "default_source")]
    pub source: String,
    #[serde(default = "default_sync_mode")]
    pub mode: String,
    #[serde(default = "default_true")]
    pub require_one_feishu_bot_per_roundtable_agent: bool,
    #[serde(default)]
    pub allow_unmapped_feishu_bots: bool,
}

impl Default for RosterSyncPolicy {
    fn default() -> Self {
        Self {
            source: default_source(),
            mode: default_sync_mode(),
            require_one_feishu_bot_per_roundtable_agent: true,
            allow_unmapped_feishu_bots: false,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentDefinition {
    pub agent_id: String,
    pub display_name: String,
    pub role: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub roundtable: bool,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default = "default_safety")]
    pub safety: String,
    #[serde(default)]
    pub context_policy: AgentContextPolicy,
    pub backend: AgentBackend,
    #[serde(default)]
    pub transport: AgentTransport,
    #[serde(default)]
    pub sync_policy: AgentSyncPolicy,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentContextPolicy {
    #[serde(default)]
    pub harvis_knowledge: HarvisContextAccess,
    #[serde(default)]
    pub harvis_webview: HarvisContextAccess,
}

impl Default for AgentContextPolicy {
    fn default() -> Self {
        Self {
            harvis_knowledge: HarvisContextAccess::default_enabled(),
            harvis_webview: HarvisContextAccess::default_enabled(),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct HarvisContextAccess {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_read_only")]
    pub mode: String,
    #[serde(default)]
    pub max_results: Option<u32>,
    #[serde(default)]
    pub routes: Vec<String>,
}

impl HarvisContextAccess {
    fn default_enabled() -> Self {
        Self {
            enabled: true,
            mode: default_read_only(),
            max_results: Some(3),
            routes: Vec::new(),
        }
    }
}

impl Default for HarvisContextAccess {
    fn default() -> Self {
        Self {
            enabled: false,
            mode: default_read_only(),
            max_results: None,
            routes: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentBackend {
    pub kind: String,
    pub model_or_harness: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub model_alias: Option<String>,
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub harness_id: Option<String>,
    #[serde(default)]
    pub model_id: Option<String>,
    #[serde(default)]
    pub preset_id: Option<String>,
    #[serde(default)]
    pub fallback_harness_ids: Vec<String>,
    #[serde(default)]
    pub fallback_model_ids: Vec<String>,
    #[serde(default)]
    pub fallback_preset_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct AgentTransport {
    #[serde(default)]
    pub feishu: Option<FeishuTransport>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct FeishuTransport {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub profile: String,
    #[serde(default)]
    pub bot_name: String,
    #[serde(default)]
    pub app_id: Option<String>,
    #[serde(default)]
    pub open_id: Option<String>,
    #[serde(default = "default_transport_status")]
    pub status: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentSyncPolicy {
    #[serde(default = "default_true")]
    pub required_transport: bool,
    #[serde(default = "default_true")]
    pub review_gated: bool,
}

impl Default for AgentSyncPolicy {
    fn default() -> Self {
        Self {
            required_transport: true,
            review_gated: true,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RosterValidationOptions {
    pub provider_registry: Option<PathBuf>,
    pub agent_pools: Option<PathBuf>,
    pub root: Option<PathBuf>,
    pub lark_config: Option<PathBuf>,
}

pub fn default_agent_roster_path(root: &Path) -> PathBuf {
    root.join(".harvis/agent-roster.json")
}

pub fn load_agent_roster(root: &Path, path: Option<&Path>) -> Result<AgentRoster> {
    let root = resolve_workspace_root(root)?;
    let path = expanduser(path.unwrap_or(default_agent_roster_path(&root).as_path()));
    let text = fs::read_to_string(&path)
        .with_context(|| format!("agent roster not found: {}", path.display()))?;
    let roster: AgentRoster = serde_json::from_str(&text)
        .with_context(|| format!("invalid agent roster json: {}", path.display()))?;
    Ok(roster)
}

pub fn agent_roster_status(
    root: &Path,
    path: Option<&Path>,
    options: RosterValidationOptions,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let path = expanduser(path.unwrap_or(default_agent_roster_path(&root).as_path()));
    let roster = load_agent_roster(&root, Some(&path))?;
    let validation = validate_agent_roster(&roster, options)?;
    Ok(json!({
        "agent_roster_version": AGENT_ROSTER_VERSION,
        "path": rel(&path, &root),
        "source": "harvis",
        "agents": roster.agents,
        "sync_policy": roster.sync_policy,
        "transports": roster.transports,
        "validation": validation,
        "includesSecrets": false
    }))
}

pub fn validate_agent_roster(
    roster: &AgentRoster,
    options: RosterValidationOptions,
) -> Result<Value> {
    let mut errors = Vec::new();
    let mut warnings = Vec::new();
    let mut seen_ids = BTreeSet::new();
    let mut seen_profiles = BTreeMap::<String, String>::new();
    let mut expected_profiles = BTreeSet::new();
    let mut provider_aliases = BTreeSet::new();
    let pool_refs = load_pool_refs(&options, &mut warnings)?;
    let configured_profiles = load_lark_profiles(options.lark_config.as_deref(), &mut warnings);

    if let Some(path) = options.provider_registry.as_deref() {
        match load_provider_registry(Some(path)) {
            Ok(registry) => {
                provider_aliases.extend(registry.models.keys().cloned());
            }
            Err(error) => warnings.push(format!("provider registry not readable: {error}")),
        }
    } else if let Ok(registry) = load_provider_registry(None) {
        provider_aliases.extend(registry.models.keys().cloned());
    }

    for agent in &roster.agents {
        let id = agent.agent_id.trim();
        if id.is_empty() {
            errors.push("agent_id is required".to_string());
        }
        if !id.starts_with("agent:") {
            errors.push(format!("{id}: agent_id must start with agent:"));
        }
        if !seen_ids.insert(id.to_string()) {
            errors.push(format!("{id}: duplicate agent_id"));
        }
        if agent.display_name.trim().is_empty() {
            errors.push(format!("{id}: display_name is required"));
        }
        if agent.role.trim().is_empty() {
            errors.push(format!("{id}: role is required"));
        }
        validate_context_access(
            id,
            "harvis_knowledge",
            &agent.context_policy.harvis_knowledge,
            &mut errors,
        );
        validate_context_access(
            id,
            "harvis_webview",
            &agent.context_policy.harvis_webview,
            &mut errors,
        );
        if agent.backend.kind.trim().is_empty() {
            errors.push(format!("{id}: backend.kind is required"));
        }
        if agent.backend.model_or_harness.trim().is_empty() {
            errors.push(format!("{id}: backend.model_or_harness is required"));
        }
        match agent.backend.kind.as_str() {
            "provider" => {
                let alias = agent
                    .backend
                    .model_alias
                    .as_deref()
                    .unwrap_or_default()
                    .trim();
                if alias.is_empty() {
                    errors.push(format!(
                        "{id}: backend.model_alias is required for provider"
                    ));
                } else if !provider_aliases.is_empty() && !provider_aliases.contains(alias) {
                    errors.push(format!("{id}: provider model_alias not found: {alias}"));
                }
            }
            "codex" => {
                if agent
                    .backend
                    .model
                    .as_deref()
                    .unwrap_or_default()
                    .trim()
                    .is_empty()
                {
                    errors.push(format!("{id}: backend.model is required for codex"));
                }
            }
            "harness" => {
                let harness = agent
                    .backend
                    .harness
                    .as_deref()
                    .or(agent.backend.harness_id.as_deref())
                    .or(Some(agent.backend.model_or_harness.as_str()))
                    .unwrap_or_default()
                    .trim();
                if harness.is_empty() {
                    errors.push(format!("{id}: backend.harness is required for harness"));
                } else if pool_refs.checked && !pool_refs.harness_ids.contains(harness) {
                    errors.push(format!(
                        "{id}: backend harness not found in agent-pools: {harness}"
                    ));
                }
            }
            "manual" => {}
            other => errors.push(format!("{id}: unsupported backend.kind: {other}")),
        }
        validate_backend_pool_refs(id, &agent.backend, &pool_refs, &mut errors);
        if agent.enabled && agent.roundtable {
            let requires_transport = roster
                .sync_policy
                .require_one_feishu_bot_per_roundtable_agent
                && agent.sync_policy.required_transport;
            match agent.transport.feishu.as_ref() {
                Some(feishu) if feishu.enabled => {
                    if feishu.profile.trim().is_empty() {
                        errors.push(format!("{id}: transport.feishu.profile is required"));
                    } else {
                        expected_profiles.insert(feishu.profile.trim().to_string());
                    }
                    if feishu.bot_name.trim().is_empty() {
                        errors.push(format!("{id}: transport.feishu.bot_name is required"));
                    }
                    if feishu.status == "active" {
                        if feishu
                            .app_id
                            .as_deref()
                            .unwrap_or_default()
                            .trim()
                            .is_empty()
                        {
                            errors.push(format!("{id}: active feishu transport has no app_id"));
                        }
                        if feishu
                            .open_id
                            .as_deref()
                            .unwrap_or_default()
                            .trim()
                            .is_empty()
                        {
                            errors.push(format!("{id}: active feishu transport has no open_id"));
                        }
                    }
                    if feishu.status != "active" {
                        let message =
                            format!("{id}: feishu transport is not active: {}", feishu.status);
                        if requires_transport {
                            errors.push(message);
                        } else {
                            warnings.push(message);
                        }
                    }
                    if let Some(profiles) = configured_profiles.as_ref() {
                        let profile = feishu.profile.trim();
                        if !profile.is_empty() && !profiles.contains(profile) {
                            let message = format!(
                                "{id}: feishu profile not configured in lark-cli: {profile}"
                            );
                            if requires_transport {
                                errors.push(message);
                            } else {
                                warnings.push(message);
                            }
                        }
                    }
                    if !feishu.profile.trim().is_empty() {
                        if let Some(previous) =
                            seen_profiles.insert(feishu.profile.clone(), id.to_string())
                        {
                            errors.push(format!(
                                "{id}: feishu profile {} also mapped to {previous}",
                                feishu.profile
                            ));
                        }
                    }
                }
                _ if requires_transport => {
                    errors.push(format!(
                        "{id}: enabled roundtable agent requires transport.feishu"
                    ));
                }
                _ => {}
            }
        }
    }

    if let Some(profiles) = configured_profiles.as_ref() {
        if !roster.sync_policy.allow_unmapped_feishu_bots {
            for profile in profiles {
                if profile.starts_with("harvis-") && !expected_profiles.contains(profile) {
                    errors.push(format!(
                        "unmapped harvis feishu profile configured in lark-cli: {profile}"
                    ));
                }
            }
        }
    }

    Ok(json!({
        "ok": errors.is_empty(),
        "errors": errors,
        "warnings": warnings,
        "enabled_roundtable_agents": roster.agents.iter().filter(|agent| agent.enabled && agent.roundtable).count(),
        "feishu_projection_count": roster.agents.iter().filter(|agent| {
            agent.enabled
                && agent.roundtable
                && agent.transport.feishu.as_ref().is_some_and(|feishu| feishu.enabled)
        }).count(),
        "lark_config_checked": configured_profiles.is_some(),
        "lark_profile_count": configured_profiles.as_ref().map(BTreeSet::len),
        "agent_pools_checked": pool_refs.checked,
        "agent_pools_source": pool_refs.source,
        "agent_pool_counts": {
            "harnesses": pool_refs.harness_ids.len(),
            "models": pool_refs.model_ids.len(),
            "presets": pool_refs.preset_ids.len()
        }
    }))
}

#[derive(Default)]
struct PoolRefs {
    checked: bool,
    source: Option<String>,
    harness_ids: BTreeSet<String>,
    model_ids: BTreeSet<String>,
    preset_ids: BTreeSet<String>,
}

fn load_pool_refs(
    options: &RosterValidationOptions,
    warnings: &mut Vec<String>,
) -> Result<PoolRefs> {
    let Some(root) = options.root.as_deref().or(Some(Path::new("."))) else {
        return Ok(PoolRefs::default());
    };
    if options.root.is_none() && options.agent_pools.is_none() {
        return Ok(PoolRefs::default());
    }
    match load_agent_pools(root, options.agent_pools.as_deref()) {
        Ok(loaded) => {
            let mut refs = PoolRefs {
                checked: true,
                source: Some(loaded.source_display),
                ..PoolRefs::default()
            };
            refs.harness_ids = collect_value_ids(&loaded.registry.harness_pool, "harness_id");
            refs.model_ids = collect_value_ids(&loaded.registry.model_pool, "model_id");
            refs.preset_ids = collect_value_ids(&loaded.registry.runtime_preset_pool, "preset_id");
            Ok(refs)
        }
        Err(error) if options.agent_pools.is_none() => {
            warnings.push(format!("agent pools not readable: {error}"));
            Ok(PoolRefs::default())
        }
        Err(error) => Err(error),
    }
}

fn collect_value_ids(items: &[Value], key: &str) -> BTreeSet<String> {
    items
        .iter()
        .filter_map(|item| item.get(key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn validate_backend_pool_refs(
    agent_id: &str,
    backend: &AgentBackend,
    pool_refs: &PoolRefs,
    errors: &mut Vec<String>,
) {
    if !pool_refs.checked {
        return;
    }
    validate_optional_ref(
        agent_id,
        "backend.harness_id",
        backend.harness_id.as_deref(),
        &pool_refs.harness_ids,
        errors,
    );
    validate_optional_ref(
        agent_id,
        "backend.model_id",
        backend.model_id.as_deref(),
        &pool_refs.model_ids,
        errors,
    );
    validate_optional_ref(
        agent_id,
        "backend.preset_id",
        backend.preset_id.as_deref(),
        &pool_refs.preset_ids,
        errors,
    );
    for value in &backend.fallback_harness_ids {
        validate_optional_ref(
            agent_id,
            "backend.fallback_harness_ids",
            Some(value),
            &pool_refs.harness_ids,
            errors,
        );
    }
    for value in &backend.fallback_model_ids {
        validate_optional_ref(
            agent_id,
            "backend.fallback_model_ids",
            Some(value),
            &pool_refs.model_ids,
            errors,
        );
    }
    for value in &backend.fallback_preset_ids {
        validate_optional_ref(
            agent_id,
            "backend.fallback_preset_ids",
            Some(value),
            &pool_refs.preset_ids,
            errors,
        );
    }
}

fn validate_optional_ref(
    agent_id: &str,
    label: &str,
    value: Option<&str>,
    allowed: &BTreeSet<String>,
    errors: &mut Vec<String>,
) {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return;
    };
    if !allowed.contains(value) {
        errors.push(format!(
            "{agent_id}: {label} not found in agent-pools: {value}"
        ));
    }
}

fn load_lark_profiles(path: Option<&Path>, warnings: &mut Vec<String>) -> Option<BTreeSet<String>> {
    let path = path
        .map(PathBuf::from)
        .unwrap_or_else(|| expanduser(Path::new("~/.lark-cli/config.json")));
    if !path.exists() {
        return None;
    }
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) => {
            warnings.push(format!("lark config not readable: {error}"));
            return None;
        }
    };
    let value: Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(error) => {
            warnings.push(format!("lark config is invalid json: {error}"));
            return None;
        }
    };
    let mut profiles = BTreeSet::new();
    if let Some(apps) = value.get("apps").and_then(Value::as_array) {
        for app in apps {
            if let Some(name) = app
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
            {
                profiles.insert(name.to_string());
            }
        }
    }
    Some(profiles)
}

fn default_roster_version() -> String {
    AGENT_ROSTER_VERSION.to_string()
}

fn default_source() -> String {
    "harvis".to_string()
}

fn default_sync_mode() -> String {
    "strict".to_string()
}

fn default_safety() -> String {
    "review-gated".to_string()
}

fn default_read_only() -> String {
    "read-only".to_string()
}

fn default_transport_status() -> String {
    "pending".to_string()
}

fn default_true() -> bool {
    true
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

fn validate_context_access(
    agent_id: &str,
    key: &str,
    access: &HarvisContextAccess,
    errors: &mut Vec<String>,
) {
    if !access.enabled {
        return;
    }
    if access.mode.trim() != "read-only" {
        errors.push(format!(
            "{agent_id}: context_policy.{key}.mode must be read-only"
        ));
    }
    if access.max_results.is_some_and(|limit| limit > 10) {
        errors.push(format!(
            "{agent_id}: context_policy.{key}.max_results must be <= 10"
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_lark_config(profiles: &[&str]) -> PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("test clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "harvis-agent-roster-test-{}-{suffix}.json",
            std::process::id()
        ));
        let apps = profiles
            .iter()
            .map(|profile| json!({ "name": profile }))
            .collect::<Vec<_>>();
        fs::write(&path, json!({ "apps": apps }).to_string()).expect("write test lark config");
        path
    }

    fn one_harness_agent(profile: &str, status: &str) -> AgentRoster {
        AgentRoster {
            version: AGENT_ROSTER_VERSION.to_string(),
            sync_policy: RosterSyncPolicy::default(),
            transports: BTreeMap::new(),
            agents: vec![AgentDefinition {
                agent_id: "agent:test".to_string(),
                display_name: "Harvis Test".to_string(),
                role: "reviewer".to_string(),
                enabled: true,
                roundtable: true,
                capabilities: vec!["review".to_string()],
                safety: "review-gated".to_string(),
                context_policy: AgentContextPolicy::default(),
                backend: AgentBackend {
                    kind: "harness".to_string(),
                    model_or_harness: "test-harness".to_string(),
                    model: None,
                    model_alias: None,
                    harness: Some("test-harness".to_string()),
                    harness_id: None,
                    model_id: None,
                    preset_id: None,
                    fallback_harness_ids: Vec::new(),
                    fallback_model_ids: Vec::new(),
                    fallback_preset_ids: Vec::new(),
                },
                transport: AgentTransport {
                    feishu: Some(FeishuTransport {
                        enabled: true,
                        profile: profile.to_string(),
                        bot_name: "Harvis Test".to_string(),
                        app_id: Some("cli_test".to_string()),
                        open_id: Some("ou_test".to_string()),
                        status: status.to_string(),
                    }),
                },
                sync_policy: AgentSyncPolicy::default(),
            }],
        }
    }

    #[test]
    fn validation_errors_when_required_feishu_profile_is_missing() {
        let lark_config = test_lark_config(&["harvis-other-bot"]);
        let roster = one_harness_agent("harvis-test-bot", "active");
        let validation = validate_agent_roster(
            &roster,
            RosterValidationOptions {
                provider_registry: None,
                agent_pools: None,
                root: None,
                lark_config: Some(lark_config),
            },
        )
        .expect("validation result");

        assert_eq!(validation["ok"], false);
        let errors = validation["errors"].as_array().expect("errors");
        assert!(errors.iter().any(|error| error
            .as_str()
            .unwrap_or_default()
            .contains("feishu profile not configured in lark-cli: harvis-test-bot")));
    }

    #[test]
    fn validation_errors_for_orphan_harvis_feishu_profiles() {
        let lark_config = test_lark_config(&["harvis-test-bot", "harvis-extra-bot"]);
        let roster = one_harness_agent("harvis-test-bot", "active");
        let validation = validate_agent_roster(
            &roster,
            RosterValidationOptions {
                provider_registry: None,
                agent_pools: None,
                root: None,
                lark_config: Some(lark_config),
            },
        )
        .expect("validation result");

        assert_eq!(validation["ok"], false);
        let errors = validation["errors"].as_array().expect("errors");
        assert!(errors
            .iter()
            .any(|error| error.as_str().unwrap_or_default().contains(
                "unmapped harvis feishu profile configured in lark-cli: harvis-extra-bot"
            )));
    }

    #[test]
    fn validation_errors_for_unknown_harness_pool_reference() {
        let root =
            std::env::temp_dir().join(format!("harvis-agent-roster-pools-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".harvis")).expect("mkdir");
        crate::agent_pools::init_agent_pools(&root, true).expect("init pools");
        let mut roster = one_harness_agent("harvis-test-bot", "pending");
        roster
            .sync_policy
            .require_one_feishu_bot_per_roundtable_agent = false;
        roster.agents[0].backend.harness = Some("missing-harness".to_string());
        roster.agents[0].backend.model_or_harness = "missing-harness".to_string();
        let validation = validate_agent_roster(
            &roster,
            RosterValidationOptions {
                provider_registry: None,
                agent_pools: None,
                root: Some(root.clone()),
                lark_config: None,
            },
        )
        .expect("validation result");

        assert_eq!(validation["agent_pools_checked"], true);
        assert_eq!(validation["ok"], false);
        let errors = validation["errors"].as_array().expect("errors");
        assert!(errors.iter().any(|error| error
            .as_str()
            .unwrap_or_default()
            .contains("backend harness not found in agent-pools: missing-harness")));
        let _ = fs::remove_dir_all(root);
    }
}
