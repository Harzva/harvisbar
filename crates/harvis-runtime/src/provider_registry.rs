use anyhow::{bail, Context, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::profile::expanduser;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ProviderRegistry {
    #[serde(default)]
    pub providers: BTreeMap<String, ProviderConfig>,
    #[serde(default)]
    pub models: BTreeMap<String, ModelRoute>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ProviderConfig {
    #[serde(default = "default_anthropic_compatible")]
    pub kind: String,
    pub base_url: String,
    #[serde(default)]
    pub access_file: Option<PathBuf>,
    #[serde(default)]
    pub env_key: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ModelRoute {
    pub provider: String,
    pub model: String,
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub role: Option<String>,
    #[serde(default)]
    pub initial: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ResolvedModelRoute {
    pub alias: String,
    pub provider: String,
    pub provider_kind: String,
    pub base_url: String,
    pub model: String,
    pub agent: String,
    pub role: String,
    pub initial: String,
    pub color: String,
    pub auth_token: String,
}

fn default_anthropic_compatible() -> String {
    "anthropic-compatible".to_string()
}

pub fn default_registry_path() -> PathBuf {
    std::env::var_os("HARVIS_PROVIDER_REGISTRY")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("~/.harvis/providers.toml"))
}

pub fn load_provider_registry(path: Option<&Path>) -> Result<ProviderRegistry> {
    let default_path = default_registry_path();
    let path = expanduser(path.unwrap_or(default_path.as_path()));
    let text = fs::read_to_string(&path)
        .with_context(|| format!("provider registry not found: {}", path.display()))?;
    let registry: ProviderRegistry = toml::from_str(&text)
        .with_context(|| format!("invalid provider registry: {}", path.display()))?;
    Ok(registry)
}

pub fn provider_registry_status(path: Option<&Path>) -> Value {
    let default_path = default_registry_path();
    let path = expanduser(path.unwrap_or(default_path.as_path()));
    match load_provider_registry(Some(&path)) {
        Ok(registry) => json!({
            "path": path.display().to_string(),
            "exists": true,
            "providers": registry.providers.keys().cloned().collect::<Vec<_>>(),
            "models": registry.models.iter().map(|(alias, route)| json!({
                "alias": alias,
                "provider": route.provider,
                "model": route.model,
                "agent": route.agent,
                "role": route.role
            })).collect::<Vec<_>>(),
            "includesSecrets": false
        }),
        Err(error) => json!({
            "path": path.display().to_string(),
            "exists": path.exists(),
            "error": error.to_string(),
            "includesSecrets": false
        }),
    }
}

pub fn resolve_model_route(alias: &str, path: Option<&Path>) -> Result<ResolvedModelRoute> {
    let alias = alias.trim();
    if alias.is_empty() {
        bail!("model_alias is required");
    }
    let registry = load_provider_registry(path)?;
    let route = registry.models.get(alias).with_context(|| {
        format!("model alias not found in H.A.R.V.I.S. provider registry: {alias}")
    })?;
    let provider = registry.providers.get(&route.provider).with_context(|| {
        format!(
            "provider not found for model alias {alias}: {}",
            route.provider
        )
    })?;
    if provider.kind != "anthropic-compatible"
        && provider.kind != "openai-compatible"
        && provider.kind != "openai-responses"
    {
        bail!(
            "provider kind is not supported for live roundtable yet: {}",
            provider.kind
        );
    }
    let auth_token = read_provider_token(provider)?;
    Ok(ResolvedModelRoute {
        alias: alias.to_string(),
        provider: route.provider.clone(),
        provider_kind: provider.kind.clone(),
        base_url: provider.base_url.clone(),
        model: route.model.clone(),
        agent: route.agent.clone().unwrap_or_else(|| route.model.clone()),
        role: route
            .role
            .clone()
            .unwrap_or_else(|| "participant".to_string()),
        initial: route.initial.clone().unwrap_or_else(|| {
            alias
                .chars()
                .next()
                .unwrap_or('?')
                .to_ascii_uppercase()
                .to_string()
        }),
        color: route.color.clone().unwrap_or_else(|| "#4f6fd8".to_string()),
        auth_token,
    })
}

fn read_provider_token(provider: &ProviderConfig) -> Result<String> {
    if let Some(env_key) = provider
        .env_key
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
    {
        if let Ok(value) = std::env::var(env_key) {
            let value = value.trim();
            if !value.is_empty() {
                return Ok(value.to_string());
            }
        }
    }
    let Some(access_file) = provider.access_file.as_ref() else {
        bail!("provider has no env_key value and no access_file");
    };
    let path = expanduser(access_file);
    let text = fs::read_to_string(&path)
        .with_context(|| format!("provider access file not readable: {}", path.display()))?;
    extract_access_token(&text).with_context(|| {
        format!(
            "provider access file has no token candidate: {}",
            path.display()
        )
    })
}

fn extract_access_token(text: &str) -> Result<String> {
    let explicit =
        Regex::new(r#"(?i)(?:DEEPSEEK_API_KEY|apiKey|authToken|token)\s*[:=]\s*['"]?([^'"\s]+)"#)?;
    if let Some(capture) = explicit.captures(text).and_then(|captures| captures.get(1)) {
        return Ok(capture.as_str().trim().to_string());
    }
    let sk = Regex::new(r#"sk-[A-Za-z0-9_-]{12,}"#)?;
    if let Some(candidate) = sk.find(text) {
        return Ok(candidate.as_str().to_string());
    }
    let generic = Regex::new(r#"\b[A-Za-z0-9_-]{32,}\b"#)?;
    if let Some(candidate) = generic.find(text) {
        return Ok(candidate.as_str().to_string());
    }
    bail!("no token candidate found")
}
