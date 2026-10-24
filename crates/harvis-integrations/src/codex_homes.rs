use anyhow::{anyhow, Context, Result};
use base64::Engine;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_AUTH_FILE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_ACCOUNT_FILE_BYTES: u64 = 64 * 1024;
const MAX_CATALOG_FILE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_CONFIGURED_MODELS: usize = 256;
const MAX_CONNECTIONS: usize = 64;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexConfiguredModel {
    pub id: String,
    pub display_name: String,
    pub provider_id: Option<String>,
    pub source: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexAccountConnection {
    pub id: String,
    pub name: String,
    pub provider_id: Option<String>,
    pub endpoint_host: Option<String>,
    pub model_ids: Vec<String>,
    pub access_mode: String,
    pub billing_mode: String,
    pub plan_name: Option<String>,
    pub billing_period: Option<String>,
    pub allowances: Vec<CodexConfiguredAllowance>,
    pub balances: Vec<CodexConfiguredBalance>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexConfiguredAllowance {
    pub id: String,
    pub label: String,
    pub remaining: Option<f64>,
    pub used: Option<f64>,
    pub limit: Option<f64>,
    pub unit: String,
    pub resets_at: Option<i64>,
    pub updated_at: Option<i64>,
    pub source: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexConfiguredBalance {
    pub currency: String,
    pub amount: String,
    pub updated_at: Option<i64>,
    pub source: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHome {
    pub id: String,
    pub label: String,
    pub account_note: Option<String>,
    pub path: String,
    pub source: String,
    pub model: Option<String>,
    pub provider: Option<String>,
    pub provider_id: Option<String>,
    pub configured_models: Vec<CodexConfiguredModel>,
    pub connections: Vec<CodexAccountConnection>,
    pub endpoint_host: Option<String>,
    pub reasoning_effort: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub web_search: Option<String>,
    pub mcp_server_count: usize,
    pub enabled_feature_count: usize,
    pub skill_count: usize,
    pub rule_count: usize,
    pub has_auth: bool,
    pub account_email: Option<String>,
    pub auth_status: String,
    pub auth_expires_at: Option<i64>,
    pub auth_note: Option<String>,
    pub has_config: bool,
    pub quota_mode: String,
    pub quota_note: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeList {
    pub ok: bool,
    pub schema_version: &'static str,
    pub items: Vec<CodexHome>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeLaunchResult {
    pub ok: bool,
    pub action: &'static str,
    pub home_id: String,
    pub user_data_dir: Option<String>,
    pub message: String,
}

pub fn discover_codex_homes() -> Result<CodexHomeList> {
    discover_codex_homes_with_options(false)
}

pub fn discover_codex_homes_with_options(include_external_launchers: bool) -> Result<CodexHomeList> {
    let user_root = home_root()?;
    let explicit = env::var_os("CODEX_HOME").map(PathBuf::from);
    let additional = env::var_os("HARVIS_CODEX_HOMES").map(|paths| env::split_paths(&paths).collect::<Vec<_>>()).unwrap_or_default();
    discover_under(&user_root, explicit.as_deref(), include_external_launchers, &additional)
}

pub fn launch_codex_cli(home: &Path, working_dir: &Path) -> Result<CodexHomeLaunchResult> {
    launch_codex_cli_internal(home, working_dir, None)
}

/// Open one exact Codex session in Terminal under its owning CODEX_HOME.
///
/// The caller must resolve the session against the selected home before
/// reaching this boundary. Keeping the resume id as a positional argument
/// after `--` prevents a malformed value from being interpreted as a CLI flag.
pub fn resume_codex_cli(
    home: &Path,
    working_dir: &Path,
    thread_id: &str,
) -> Result<CodexHomeLaunchResult> {
    let thread_id = validate_resume_thread_id(thread_id)?;
    launch_codex_cli_internal(home, working_dir, Some(thread_id))
}

fn launch_codex_cli_internal(
    home: &Path,
    working_dir: &Path,
    resume_thread_id: Option<&str>,
) -> Result<CodexHomeLaunchResult> {
    let home = validate_requested_home(home)?;
    let working_dir = working_dir.canonicalize().with_context(|| {
        format!(
            "working directory is unavailable: {}",
            working_dir.display()
        )
    })?;
    if !working_dir.is_dir() {
        return Err(anyhow!(
            "working directory is not a directory: {}",
            working_dir.display()
        ));
    }
    let codex = codex_binary().ok_or_else(|| anyhow!("Codex CLI was not found"))?;

    #[cfg(target_os = "macos")]
    {
        let shell_command = codex_cli_shell_command(&home, &working_dir, &codex, resume_thread_id);
        let script = r#"on run argv
tell application "Terminal"
  activate
  do script item 1 of argv
end tell
end run"#;
        // AppleScript returns a Terminal tab description on stdout. Capture it
        // so the caller receives only CodexHomeLaunchResult JSON.
        let output = Command::new("/usr/bin/osascript")
            .args(["-e", script, "--", &shell_command])
            .output()
            .context("failed to ask Terminal to start Codex CLI")?;
        if !output.status.success() {
            return Err(anyhow!("Terminal refused the Codex CLI launch request"));
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (working_dir, codex);
        return Err(anyhow!(
            "interactive Codex CLI launch is currently available on macOS only"
        ));
    }

    Ok(CodexHomeLaunchResult {
        ok: true,
        action: if resume_thread_id.is_some() {
            "resume-cli"
        } else {
            "launch-cli"
        },
        home_id: stable_id(&home),
        user_data_dir: None,
        message: if resume_thread_id.is_some() {
            "Requested Codex CLI to resume the selected session in Terminal with the selected CODEX_HOME"
                .into()
        } else {
            "Codex CLI opened in Terminal with the selected CODEX_HOME".into()
        },
    })
}

fn validate_resume_thread_id(thread_id: &str) -> Result<&str> {
    let trimmed = thread_id.trim();
    if trimmed.is_empty() {
        return Err(anyhow!("Codex thread id is required"));
    }
    if trimmed != thread_id {
        return Err(anyhow!(
            "Codex thread id must not have surrounding whitespace"
        ));
    }
    if trimmed.chars().any(char::is_control) {
        return Err(anyhow!(
            "Codex thread id contains unsupported control characters"
        ));
    }
    Ok(trimmed)
}

pub fn login_codex_home(home: &Path) -> Result<CodexHomeLaunchResult> {
    let home = validate_requested_home(home)?;
    let codex = codex_binary().ok_or_else(|| anyhow!("Codex CLI was not found"))?;

    #[cfg(target_os = "macos")]
    {
        let shell_command = format!(
            "env CODEX_HOME={} {} login",
            shell_quote(&home.to_string_lossy()),
            shell_quote(&codex.to_string_lossy())
        );
        let script = r#"on run argv
tell application "Terminal"
  activate
  do script item 1 of argv
end tell
end run"#;
        let output = Command::new("/usr/bin/osascript")
            .args(["-e", script, "--", &shell_command])
            .output()
            .context("failed to ask Terminal to start Codex login")?;
        if !output.status.success() {
            return Err(anyhow!("Terminal refused the Codex login request"));
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = codex;
        return Err(anyhow!(
            "interactive Codex login is currently available on macOS only"
        ));
    }

    Ok(CodexHomeLaunchResult {
        ok: true,
        action: "login",
        home_id: stable_id(&home),
        user_data_dir: None,
        message: "Codex login opened in Terminal for the selected CODEX_HOME".into(),
    })
}

pub fn launch_codex_desktop(home: &Path) -> Result<CodexHomeLaunchResult> {
    let home = validate_requested_home(home)?;

    #[cfg(target_os = "macos")]
    {
        let app = codex_desktop_app()
            .ok_or_else(|| anyhow!("Codex/ChatGPT desktop app was not found"))?;
        let user_data_dir = home_root()?
            .join("Library/Application Support/HarvisBar/codex-home-desktops")
            .join(stable_id(&home));
        fs::create_dir_all(&user_data_dir).with_context(|| {
            format!(
                "failed to create isolated desktop data directory: {}",
                user_data_dir.display()
            )
        })?;

        let previous = launchctl_getenv("CODEX_HOME")?;
        launchctl_setenv("CODEX_HOME", home.as_os_str())?;
        let open_result = Command::new("/usr/bin/open")
            .args(["-n", "-a"])
            .arg(&app)
            .arg("--args")
            .arg(format!("--user-data-dir={}", user_data_dir.display()))
            .status()
            .context("failed to launch isolated Codex Desktop");
        let restore_result = restore_launchctl_env("CODEX_HOME", previous.as_deref());
        let status = open_result?;
        restore_result?;
        if !status.success() {
            return Err(anyhow!(
                "macOS rejected the isolated Codex Desktop launch request"
            ));
        }

        return Ok(CodexHomeLaunchResult {
            ok: true,
            action: "launch-desktop",
            home_id: stable_id(&home),
            user_data_dir: Some(user_data_dir.to_string_lossy().into_owned()),
            message: "Independent Codex Desktop opened with the selected CODEX_HOME".into(),
        });
    }

    #[cfg(not(target_os = "macos"))]
    Err(anyhow!(
        "isolated Codex Desktop launch is currently available on macOS only"
    ))
}

fn discover_under(user_root: &Path, explicit: Option<&Path>, include_external_launchers: bool, additional: &[PathBuf]) -> Result<CodexHomeList> {
    let mut candidates: BTreeMap<PathBuf, String> = BTreeMap::new();
    add_candidate(&mut candidates, user_root.join(".codex"), "default");
    if let Some(path) = explicit {
        add_candidate(&mut candidates, expand_home(path, user_root), "environment");
    }

    let mut grouped_roots = vec![
        (
            user_root.join(".codex-managed-agent/accounts"),
            "managed-agent",
        ),
    ];
    if include_external_launchers { grouped_roots.extend([
        (
            user_root.join("Library/Application Support/open-codex-launcher/profile-homes"),
            "open-codex-launcher",
        ),
        (
            user_root.join("Library/Application Support/codexuse-desktop/profile-homes"),
            "codexuse-desktop",
        ),
    ]); }
    for (root, source) in grouped_roots {
        add_children(&mut candidates, &root, source);
    }

    for path in additional {
        add_candidate(&mut candidates, expand_home(path, user_root), "harvis-configured");
    }

    let mut items = Vec::new();
    let mut warnings = Vec::new();
    for (path, source) in candidates {
        if !looks_like_codex_home(&path) {
            continue;
        }
        match inspect_home(&path, &source) {
            Ok(item) => items.push(item),
            Err(error) => warnings.push(format!("{}: {error}", path.display())),
        }
    }
    items.sort_by(|left, right| {
        source_rank(&left.source)
            .cmp(&source_rank(&right.source))
            .then(left.label.cmp(&right.label))
    });

    Ok(CodexHomeList {
        ok: true,
        schema_version: "harvis.codex-home-list.v3",
        items,
        warnings,
    })
}

fn inspect_home(path: &Path, source: &str) -> Result<CodexHome> {
    let canonical = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let config_path = canonical.join("config.toml");
    let has_config = config_path.is_file();
    let has_auth = canonical.join("auth.json").is_file();
    let mut model = None;
    let mut provider = None;
    let mut provider_id = None;
    let mut configured_models = Vec::new();
    let mut is_custom_provider = false;
    let mut endpoint_host = None;
    let mut reasoning_effort = None;
    let mut approval_policy = None;
    let mut sandbox_mode = None;
    let mut web_search = None;
    let mut mcp_server_count = 0;
    let mut enabled_feature_count = 0;

    if has_config {
        let content = fs::read_to_string(&config_path)
            .with_context(|| format!("failed to read {}", config_path.display()))?;
        if let Ok(value) = content.parse::<toml::Value>() {
            model = effective_setting(&value, "model")
                .and_then(toml::Value::as_str)
                .and_then(safe_identifier);
            let provider_key = effective_setting(&value, "model_provider")
                .and_then(toml::Value::as_str)
                .unwrap_or("openai");
            provider_id = safe_identifier(provider_key);
            provider = effective_provider_setting(&value, provider_key, "name")
                .and_then(toml::Value::as_str)
                .and_then(|name| safe_label(name, 160))
                .or_else(|| provider_id.clone());
            let endpoint = effective_provider_setting(&value, provider_key, "base_url")
                .and_then(toml::Value::as_str);
            endpoint_host = endpoint.and_then(url_host);
            is_custom_provider = provider_key != "openai"
                || endpoint.is_some_and(|_| endpoint_host.as_deref() != Some("api.openai.com"));
            configured_models =
                configured_models_from_config(&canonical, &value, provider_id.as_deref());
            reasoning_effort = string_setting(&value, "model_reasoning_effort");
            approval_policy = string_setting(&value, "approval_policy");
            sandbox_mode = string_setting(&value, "sandbox_mode");
            web_search = scalar_setting(&value, "web_search");
            mcp_server_count = value
                .get("mcp_servers")
                .and_then(toml::Value::as_table)
                .map(|items| items.len())
                .unwrap_or(0);
            enabled_feature_count = value
                .get("features")
                .and_then(toml::Value::as_table)
                .map(|items| {
                    items
                        .values()
                        .filter(|item| item.as_bool().unwrap_or(false))
                        .count()
                })
                .unwrap_or(0);
        }
    }

    let skill_count = directory_entry_count(&canonical.join("skills"), true);
    let rule_count = directory_entry_count(&canonical.join("rules"), false);
    let (account_note, mut connections) = managed_account_metadata(&canonical);

    let leaf = canonical
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("codex-home");
    let label = match source {
        "default" => "Default Codex".to_owned(),
        "environment" => "Environment Codex".to_owned(),
        _ if source == "open-codex-launcher" && leaf.starts_with("apikey-") => {
            format!("API · {}", provider.as_deref().unwrap_or(leaf))
        }
        _ if source == "open-codex-launcher" && leaf.starts_with("auth-") => {
            "Subscription Profile".to_owned()
        }
        _ => format!("{} · {}", source_title(source), safe_leaf_label(leaf)),
    };
    let auth = inspect_auth(&canonical, source, leaf, is_custom_provider);
    if connections.is_empty() {
        connections.push(CodexAccountConnection {
            id: "current".into(),
            name: provider
                .clone()
                .unwrap_or_else(|| "Current connection".into()),
            provider_id: provider_id.clone(),
            endpoint_host: endpoint_host.clone(),
            model_ids: configured_models
                .iter()
                .filter(|item| item.provider_id == provider_id)
                .map(|item| item.id.clone())
                .collect(),
            access_mode: match auth.quota_mode.as_str() {
                "subscription" => "chatgpt",
                "proxy" | "api-key" => "api",
                _ => "unknown",
            }
            .into(),
            billing_mode: if auth.quota_mode == "subscription" {
                "subscription"
            } else {
                "unknown"
            }
            .into(),
            plan_name: None,
            billing_period: None,
            allowances: Vec::new(),
            balances: Vec::new(),
        });
    } else {
        for model in &mut configured_models {
            if let Some(connection) = connections
                .iter()
                .find(|item| item.model_ids.contains(&model.id))
            {
                if connection.provider_id.is_some() {
                    model.provider_id = connection.provider_id.clone();
                }
            }
        }
    }

    Ok(CodexHome {
        id: stable_id(&canonical),
        label,
        account_note,
        path: canonical.to_string_lossy().into_owned(),
        source: source.to_owned(),
        model,
        provider,
        provider_id,
        configured_models,
        connections,
        endpoint_host,
        reasoning_effort,
        approval_policy,
        sandbox_mode,
        web_search,
        mcp_server_count,
        enabled_feature_count,
        skill_count,
        rule_count,
        has_auth,
        account_email: auth.account_email,
        auth_status: auth.auth_status,
        auth_expires_at: auth.auth_expires_at,
        auth_note: auth.auth_note,
        has_config,
        quota_mode: auth.quota_mode,
        quota_note: auth.quota_note,
    })
}

#[derive(Debug, Default)]
struct CodexAuthProjection {
    account_email: Option<String>,
    auth_status: String,
    auth_expires_at: Option<i64>,
    auth_note: Option<String>,
    quota_mode: String,
    quota_note: Option<String>,
}

pub(crate) fn codex_home_quota_mode(home: &Path) -> Result<String> {
    Ok(inspect_home(home, "requested")?.quota_mode)
}

fn active_profile(config: &toml::Value) -> Option<&toml::Value> {
    let name = config.get("profile")?.as_str()?;
    config
        .get("profiles")?
        .get(name)
        .filter(|profile| profile.is_table())
}

fn effective_setting<'a>(config: &'a toml::Value, key: &str) -> Option<&'a toml::Value> {
    active_profile(config)
        .and_then(|profile| profile.get(key))
        .or_else(|| config.get(key))
}

fn effective_provider_setting<'a>(
    config: &'a toml::Value,
    provider_id: &str,
    key: &str,
) -> Option<&'a toml::Value> {
    active_profile(config)
        .and_then(|profile| profile.get("model_providers"))
        .and_then(|providers| providers.get(provider_id))
        .and_then(|provider| provider.get(key))
        .or_else(|| config.get("model_providers")?.get(provider_id)?.get(key))
}

fn bounded_json(path: &Path, limit: u64) -> Option<serde_json::Value> {
    let metadata = fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > limit {
        return None;
    }
    let file = fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > limit {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > limit {
        return None;
    }
    serde_json::from_slice(&bytes).ok()
}

fn safe_label(value: &str, limit: usize) -> Option<String> {
    let value = value.trim();
    let lower = value.to_ascii_lowercase();
    if value.is_empty()
        || value.chars().count() > limit
        || value.chars().any(char::is_control)
        || value.contains("://")
        || value.contains(['@', '?', '#', '=', '\\'])
        || lower.starts_with("sk-")
        || lower.starts_with("sk_")
        || lower.starts_with("bearer ")
        || lower.starts_with("-----begin")
    {
        return None;
    }
    Some(value.to_owned())
}

fn safe_identifier(value: &str) -> Option<String> {
    let value = safe_label(value, 160)?;
    value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "._-:/".contains(c))
        .then_some(value)
}

pub(crate) fn is_safe_connection_id(value: &str) -> bool {
    let lowered = value.to_ascii_lowercase();
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
        && !["sk-", "sk_", "ghp_", "github_pat_", "glpat-", "bearer"]
            .iter()
            .any(|prefix| lowered.starts_with(prefix))
}

/// Exact decimal text, including legitimate negative monetary balances.
pub(crate) fn bounded_decimal(value: &str) -> Option<String> {
    if value.len() > 128 {
        return None;
    }
    let unsigned = value.strip_prefix('-').unwrap_or(value);
    let mut parts = unsigned.split('.');
    let whole = parts.next()?;
    let fraction = parts.next();
    if whole.is_empty()
        || !whole.bytes().all(|c| c.is_ascii_digit())
        || fraction.is_some_and(|part| part.is_empty() || !part.bytes().all(|c| c.is_ascii_digit()))
        || parts.next().is_some()
    {
        return None;
    }
    Some(value.to_owned())
}

fn configured_models_from_config(
    home: &Path,
    config: &toml::Value,
    provider_id: Option<&str>,
) -> Vec<CodexConfiguredModel> {
    let mut models: Vec<CodexConfiguredModel> = Vec::new();
    let mut add = |id: &str, display_name: Option<&str>, provider: Option<&str>| {
        let Some(id) = safe_identifier(id) else {
            return;
        };
        let display_name = display_name.and_then(|name| safe_label(name, 160));
        if let Some(existing) = models.iter_mut().find(|item| item.id == id) {
            if let Some(name) = display_name {
                existing.display_name = name;
            }
            return;
        }
        if models.len() < MAX_CONFIGURED_MODELS {
            models.push(CodexConfiguredModel {
                display_name: display_name.unwrap_or_else(|| id.clone()),
                id,
                provider_id: provider.and_then(safe_identifier),
                source: "configured",
            });
        }
    };
    if let Some(model) = effective_setting(config, "model").and_then(toml::Value::as_str) {
        add(model, None, provider_id);
    }
    let base_provider_id = config
        .get("model_provider")
        .and_then(toml::Value::as_str)
        .or(Some("openai"));
    if let Some(model) = config.get("model").and_then(toml::Value::as_str) {
        add(model, None, base_provider_id);
    }
    if let Some(profiles) = config.get("profiles").and_then(toml::Value::as_table) {
        for profile in profiles.values().take(MAX_CONFIGURED_MODELS) {
            if let Some(model) = profile.get("model").and_then(toml::Value::as_str) {
                add(
                    model,
                    None,
                    profile
                        .get("model_provider")
                        .and_then(toml::Value::as_str)
                        .or(base_provider_id),
                );
            }
        }
    }
    if let Some(path) =
        effective_setting(config, "model_catalog_json").and_then(toml::Value::as_str)
    {
        let path = Path::new(path);
        let path = if path.is_absolute() {
            path.to_path_buf()
        } else {
            home.join(path)
        };
        if let Some(catalog) = bounded_json(&path, MAX_CATALOG_FILE_BYTES) {
            if let Some(items) = catalog
                .get("models")
                .and_then(serde_json::Value::as_array)
                .or_else(|| catalog.as_array())
            {
                for item in items.iter().take(MAX_CONFIGURED_MODELS) {
                    if let Some(id) = item.get("slug").and_then(serde_json::Value::as_str) {
                        add(
                            id,
                            item.get("display_name").and_then(serde_json::Value::as_str),
                            provider_id,
                        );
                    }
                }
            }
        }
    }
    models
}

fn metadata_string(value: &serde_json::Value, key: &str, limit: usize) -> Option<String> {
    value
        .get(key)?
        .as_str()
        .and_then(|text| safe_label(text, limit))
}

fn metadata_id(value: &serde_json::Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().and_then(safe_identifier)
}

fn metadata_quantity(value: &serde_json::Value, key: &str, signed: bool) -> Option<f64> {
    let quantity = value.get(key)?.as_f64()?;
    (quantity.is_finite() && quantity.abs() <= 1e18 && (signed || quantity >= 0.0))
        .then_some(quantity)
}

fn metadata_timestamp(value: &serde_json::Value, key: &str) -> Option<i64> {
    value.get(key)?.as_i64().filter(|time| *time >= 0)
}

fn project_connection(value: &serde_json::Value) -> Option<CodexAccountConnection> {
    let id = value
        .get("id")?
        .as_str()
        .filter(|id| is_safe_connection_id(id))?
        .to_owned();
    let mut seen_models = BTreeSet::new();
    let model_ids = value
        .get("modelIds")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .take(MAX_CONFIGURED_MODELS)
        .filter_map(|item| item.as_str().and_then(safe_identifier))
        .filter(|id| seen_models.insert(id.clone()))
        .collect();
    let allowances = value
        .get("allowances")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .take(64)
        .filter_map(|item| {
            let id = metadata_id(item, "id")?;
            Some(CodexConfiguredAllowance {
                label: metadata_string(item, "label", 160).unwrap_or_else(|| id.clone()),
                id,
                remaining: metadata_quantity(item, "remaining", true),
                used: metadata_quantity(item, "used", false),
                limit: metadata_quantity(item, "limit", false),
                unit: metadata_string(item, "unit", 32)?,
                resets_at: metadata_timestamp(item, "resetsAt"),
                updated_at: metadata_timestamp(item, "updatedAt"),
                source: "configured",
            })
        })
        .collect();
    let balances = value
        .get("balances")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .take(64)
        .filter_map(|item| {
            let currency = metadata_id(item, "currency")?;
            if currency.len() > 12 || !currency.bytes().all(|c| c.is_ascii_alphabetic()) {
                return None;
            }
            Some(CodexConfiguredBalance {
                currency,
                amount: item.get("amount")?.as_str().and_then(bounded_decimal)?,
                updated_at: metadata_timestamp(item, "updatedAt"),
                source: "configured",
            })
        })
        .collect();
    Some(CodexAccountConnection {
        name: metadata_string(value, "name", 160).unwrap_or_else(|| id.clone()),
        id,
        provider_id: metadata_id(value, "providerId"),
        endpoint_host: value
            .get("endpointHost")
            .and_then(serde_json::Value::as_str)
            .filter(|host| !host.contains(['/', '@', '?', '#', '=']))
            .and_then(url_host),
        model_ids,
        access_mode: match value.get("accessMode").and_then(serde_json::Value::as_str) {
            Some("api") => "api",
            Some("chatgpt") => "chatgpt",
            _ => "unknown",
        }
        .into(),
        billing_mode: match value.get("billingMode").and_then(serde_json::Value::as_str) {
            Some("usage") => "usage",
            Some("subscription") => "subscription",
            _ => "unknown",
        }
        .into(),
        plan_name: metadata_string(value, "planName", 160),
        billing_period: metadata_string(value, "billingPeriod", 60),
        allowances,
        balances,
    })
}

fn managed_account_metadata(home: &Path) -> (Option<String>, Vec<CodexAccountConnection>) {
    let Some(value) = bounded_json(&home.join(".harvis-account.json"), MAX_ACCOUNT_FILE_BYTES)
    else {
        return (None, Vec::new());
    };
    let label = metadata_string(&value, "label", 60);
    if value
        .get("schemaVersion")
        .is_some_and(|version| version.as_str() != Some("harvis.codex-account.v1"))
    {
        return (label, Vec::new());
    }
    let mut seen = BTreeSet::new();
    let connections = value
        .get("connections")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .take(MAX_CONNECTIONS)
        .filter_map(project_connection)
        .filter(|item| seen.insert(item.id.clone()))
        .collect();
    (label, connections)
}

fn inspect_auth(home: &Path, source: &str, leaf: &str, is_proxy: bool) -> CodexAuthProjection {
    let auth_path = home.join("auth.json");
    let source_is_api_key = source == "open-codex-launcher" && leaf.starts_with("apikey-");
    // A stale ChatGPT auth record says nothing about a configured custom provider.
    if is_proxy {
        return CodexAuthProjection {
            auth_status: "configured".into(),
            quota_mode: "proxy".into(),
            quota_note: Some("Custom providers do not expose official ChatGPT quota.".into()),
            ..Default::default()
        };
    }

    let Ok(metadata) = fs::metadata(&auth_path) else {
        return CodexAuthProjection {
            auth_status: "missing".into(),
            quota_mode: if is_proxy {
                "proxy".into()
            } else if source_is_api_key {
                "api-key".into()
            } else {
                "missing-auth".into()
            },
            quota_note: Some("This CODEX_HOME has no configured ChatGPT account.".into()),
            ..Default::default()
        };
    };
    if metadata.len() > MAX_AUTH_FILE_BYTES {
        return invalid_auth_projection("The local auth record is too large to inspect safely.");
    }
    let Ok(bytes) = fs::read(&auth_path) else {
        return invalid_auth_projection("The local auth record could not be read.");
    };
    let Ok(auth_json) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return invalid_auth_projection("The local auth record is not valid JSON.");
    };

    let auth_mode = auth_json
        .get("auth_mode")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let has_api_key = auth_json
        .get("OPENAI_API_KEY")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|value| !value.trim().is_empty());
    if has_api_key || auth_mode.contains("apikey") || source_is_api_key {
        return CodexAuthProjection {
            auth_status: "configured".into(),
            quota_mode: "api-key".into(),
            quota_note: Some("API Key homes do not expose ChatGPT subscription quota.".into()),
            ..Default::default()
        };
    }

    let id_token = auth_json
        .pointer("/tokens/id_token")
        .and_then(serde_json::Value::as_str);
    let refresh_available = auth_json
        .pointer("/tokens/refresh_token")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|value| !value.trim().is_empty());
    let Some(claims) = id_token.and_then(decode_jwt_claims) else {
        return CodexAuthProjection {
            auth_status: "configured".into(),
            quota_mode: if is_proxy { "proxy" } else { "missing-auth" }.into(),
            quota_note: is_proxy
                .then(|| "Proxy homes do not expose official ChatGPT quota.".into()),
            ..Default::default()
        };
    };

    let account_email = claims
        .get("email")
        .and_then(serde_json::Value::as_str)
        .or_else(|| {
            claims
                .pointer("/https:~1~1api.openai.com~1profile/email")
                .and_then(serde_json::Value::as_str)
        })
        .map(str::trim)
        .filter(|email| !email.is_empty() && email.len() <= 320)
        .map(str::to_owned);
    let auth_expires_at = claims.get("exp").and_then(serde_json::Value::as_i64);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
        .unwrap_or_default();
    let (auth_status, auth_note) = match auth_expires_at {
        // Codex refreshes ChatGPT sessions from the refresh token. An expired
        // cached ID token is therefore not an invalid account by itself.
        Some(expiration) if expiration <= now && refresh_available => (
            "valid".into(),
            Some("The cached session is refreshable and the account remains configured.".into()),
        ),
        Some(expiration) if expiration <= now => (
            "expired".into(),
            Some("The session expired; sign in again to refresh this account.".into()),
        ),
        Some(_) => ("valid".into(), None),
        None => ("configured".into(), None),
    };
    let quota_mode = if account_email.is_some() {
        "subscription"
    } else if is_proxy {
        "proxy"
    } else {
        "missing-auth"
    };

    CodexAuthProjection {
        account_email,
        auth_status,
        auth_expires_at,
        auth_note,
        quota_mode: quota_mode.into(),
        quota_note: (quota_mode == "proxy")
            .then(|| "Proxy homes do not expose official ChatGPT quota.".into()),
    }
}

fn invalid_auth_projection(note: &str) -> CodexAuthProjection {
    CodexAuthProjection {
        auth_status: "invalid".into(),
        auth_note: Some(note.into()),
        quota_mode: "missing-auth".into(),
        quota_note: Some("A valid ChatGPT login is required for official quota.".into()),
        ..Default::default()
    }
}

fn decode_jwt_claims(jwt: &str) -> Option<serde_json::Value> {
    let mut parts = jwt.split('.');
    let header = parts.next()?;
    let payload = parts.next()?;
    let signature = parts.next()?;
    if header.is_empty() || payload.is_empty() || signature.is_empty() || parts.next().is_some() {
        return None;
    }
    let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(payload))
        .ok()?;
    serde_json::from_slice(&decoded).ok()
}

fn string_setting(value: &toml::Value, key: &str) -> Option<String> {
    effective_setting(value, key)
        .and_then(toml::Value::as_str)
        .map(str::to_owned)
}

fn scalar_setting(value: &toml::Value, key: &str) -> Option<String> {
    let item = effective_setting(value, key)?;
    if let Some(value) = item.as_str() {
        return Some(value.to_owned());
    }
    item.as_bool().map(|value| value.to_string())
}

fn directory_entry_count(path: &Path, directories_only: bool) -> usize {
    let Ok(entries) = fs::read_dir(path) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|entry| {
            let Ok(kind) = entry.file_type() else {
                return false;
            };
            if directories_only {
                kind.is_dir()
            } else {
                kind.is_file()
            }
        })
        .count()
}

fn add_children(candidates: &mut BTreeMap<PathBuf, String>, root: &Path, source: &str) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {
            add_candidate(candidates, entry.path(), source);
        }
    }
}

fn add_candidate(candidates: &mut BTreeMap<PathBuf, String>, path: PathBuf, source: &str) {
    let key = path.canonicalize().unwrap_or(path);
    candidates.entry(key).or_insert_with(|| source.to_owned());
}

fn looks_like_codex_home(path: &Path) -> bool {
    path.is_dir()
        && (path.join("config.toml").is_file()
            || path.join("auth.json").is_file()
            || path.join("state_5.sqlite").is_file()
            || path.join("sessions").is_dir())
}

fn validate_requested_home(path: &Path) -> Result<PathBuf> {
    let expanded = expand_home(path, &home_root()?);
    if !looks_like_codex_home(&expanded) {
        return Err(anyhow!(
            "not a recognized CODEX_HOME: {}",
            expanded.display()
        ));
    }
    expanded
        .canonicalize()
        .with_context(|| format!("cannot resolve CODEX_HOME: {}", expanded.display()))
}

fn home_root() -> Result<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| anyhow!("HOME is not available"))
}

fn expand_home(path: &Path, user_root: &Path) -> PathBuf {
    let raw = path.to_string_lossy();
    if raw == "~" {
        return user_root.to_path_buf();
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return user_root.join(rest);
    }
    path.to_path_buf()
}

pub(crate) fn stable_id(path: &Path) -> String {
    let mut digest = Sha256::new();
    digest.update(path.to_string_lossy().as_bytes());
    format!("{:x}", digest.finalize())[..12].to_owned()
}

fn source_rank(source: &str) -> u8 {
    match source {
        "default" => 0,
        "environment" => 1,
        "open-codex-launcher" => 2,
        "codexuse-desktop" => 3,
        "managed-agent" => 4,
        _ => 5,
    }
}

fn source_title(source: &str) -> &'static str {
    match source {
        "managed-agent" => "Managed",
        "open-codex-launcher" => "Launcher",
        "codexuse-desktop" => "CodexUse",
        "harvis-configured" => "Custom",
        _ => "Codex",
    }
}

fn safe_leaf_label(value: &str) -> String {
    if value.len() >= 7 && value.chars().all(|character| character.is_ascii_digit()) {
        let suffix = value.chars().rev().take(4).collect::<String>();
        return format!("Account •••{}", suffix.chars().rev().collect::<String>());
    }
    value.to_owned()
}

fn url_host(value: &str) -> Option<String> {
    let value = if value.contains("://") {
        value.to_owned()
    } else {
        format!("https://{value}")
    };
    let url = reqwest::Url::parse(&value).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    let host = url.host_str()?;
    (host.len() <= 253).then(|| host.to_owned())
}

fn codex_binary() -> Option<PathBuf> {
    let candidates = [
        PathBuf::from("/Applications/ChatGPT.app/Contents/Resources/codex"),
        PathBuf::from("/Applications/Codex.app/Contents/Resources/codex"),
        home_root().ok()?.join(".local/bin/codex"),
        PathBuf::from("/opt/homebrew/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
    ];
    candidates.into_iter().find(|path| path.is_file())
}

#[cfg(target_os = "macos")]
fn codex_desktop_app() -> Option<PathBuf> {
    [
        PathBuf::from("/Applications/ChatGPT.app"),
        PathBuf::from("/Applications/Codex.app"),
    ]
    .into_iter()
    .find(|path| path.is_dir())
}

#[cfg(target_os = "macos")]
fn launchctl_getenv(name: &str) -> Result<Option<OsString>> {
    let output = Command::new("/bin/launchctl")
        .args(["getenv", name])
        .output()
        .context("failed to read launchd environment")?;
    if !output.status.success() || output.stdout.is_empty() {
        return Ok(None);
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    Ok((!value.is_empty()).then(|| OsString::from(value)))
}

#[cfg(target_os = "macos")]
fn launchctl_setenv(name: &str, value: &std::ffi::OsStr) -> Result<()> {
    let status = Command::new("/bin/launchctl")
        .arg("setenv")
        .arg(name)
        .arg(value)
        .status()
        .context("failed to set temporary launchd environment")?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("launchctl setenv failed"))
    }
}

#[cfg(target_os = "macos")]
fn restore_launchctl_env(name: &str, previous: Option<&std::ffi::OsStr>) -> Result<()> {
    let mut command = Command::new("/bin/launchctl");
    if let Some(value) = previous {
        command.arg("setenv").arg(name).arg(value);
    } else {
        command.arg("unsetenv").arg(name);
    }
    let status = command
        .status()
        .context("failed to restore launchd environment")?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("failed to restore launchd environment"))
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn codex_cli_shell_command(
    home: &Path,
    working_dir: &Path,
    codex: &Path,
    resume_thread_id: Option<&str>,
) -> String {
    let mut command = format!(
        "cd {} && env CODEX_HOME={} {}",
        shell_quote(&working_dir.to_string_lossy()),
        shell_quote(&home.to_string_lossy()),
        shell_quote(&codex.to_string_lossy())
    );
    if let Some(thread_id) = resume_thread_id {
        command.push_str(" resume -- ");
        command.push_str(&shell_quote(thread_id));
    }
    command
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn account_fixture(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let home = env::temp_dir().join(format!(
            "harvis-account-{name}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&home).unwrap();
        home
    }

    #[test]
    fn configured_catalog_and_connections_are_deduplicated_bounded_and_redacted() {
        let home = account_fixture("catalog");
        let models: Vec<_> = (0..7).map(|index| serde_json::json!({
            "slug": format!("model-{index}"), "display_name": format!("Model {index}"),
            "api_key": "must-not-project-catalog-secret", "internal_url": "https://private.invalid/key"
        })).collect();
        fs::write(
            home.join("catalog.json"),
            serde_json::to_vec(&serde_json::json!({"models": models})).unwrap(),
        )
        .unwrap();
        fs::write(home.join("config.toml"), r#"
model = "model-0"
model_provider = "router"
model_catalog_json = "catalog.json"
[profiles.other]
model = "model-1"
[model_providers.router]
name = "Router"
base_url = "https://user:must-not-project-url-secret@route.example.test/v1?key=must-not-project-query"
"#).unwrap();
        fs::write(home.join(".harvis-account.json"), serde_json::to_vec(&serde_json::json!({
            "schemaVersion": "harvis.codex-account.v1", "label": "Research",
            "connections": [{
                "id": "qwen", "name": "Qwen", "providerId": "qwen",
                "endpointHost": "api.example.test", "modelIds": ["model-0", "model-1", "model-1"],
                "accessMode": "api", "billingMode": "subscription", "planName": "Token plan", "billingPeriod": "month",
                "usage": {"kind": "aliyun-token-plan", "credentialFile": "/private/must-not-project-key"},
                "allowances": [{"id": "requests", "label": "Requests", "remaining": -2, "used": 12, "limit": 10,
                    "unit": "requests", "source": "provider", "updatedAt": 100}],
                "balances": [{"currency": "CNY", "amount": "-0.00000000000000000001", "source": "live"}]
            }]
        })).unwrap()).unwrap();
        let projected = inspect_home(&home, "environment").unwrap();
        assert_eq!(projected.provider_id.as_deref(), Some("router"));
        assert_eq!(
            projected.endpoint_host.as_deref(),
            Some("route.example.test")
        );
        assert_eq!(projected.configured_models.len(), 7);
        assert_eq!(projected.configured_models[0].display_name, "Model 0");
        assert_eq!(
            projected.configured_models[0].provider_id.as_deref(),
            Some("qwen")
        );
        assert_eq!(projected.connections[0].model_ids.len(), 2);
        assert_eq!(projected.connections[0].allowances[0].remaining, Some(-2.0));
        assert_eq!(
            projected.connections[0].balances[0].amount,
            "-0.00000000000000000001"
        );
        let json = serde_json::to_value(&projected).unwrap();
        assert_eq!(json["configuredModels"][0]["source"], "configured");
        assert_eq!(
            json["connections"][0]["allowances"][0]["source"],
            "configured"
        );
        assert_eq!(
            json["connections"][0]["balances"][0]["source"],
            "configured"
        );
        let text = json.to_string();
        for forbidden in [
            "must-not-project",
            "credentialFile",
            "usage",
            "https://",
            "api_key",
        ] {
            assert!(
                !text.contains(forbidden),
                "Unexpected projected private field: {forbidden}"
            );
        }
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn account_projection_bounds_files_models_connections_and_quantities() {
        let home = account_fixture("limits");
        let models: Vec<_> = (0..300).map(|index| serde_json::json!({"slug": format!("model-{index}"), "display_name": "Model"})).collect();
        let catalog = home.join("catalog.json");
        fs::write(&catalog, serde_json::to_vec(&models).unwrap()).unwrap();
        fs::write(
            home.join("config.toml"),
            format!(
                "model_provider = \"custom\"\nmodel_catalog_json = {:?}\n",
                catalog.to_str().unwrap()
            ),
        )
        .unwrap();
        let connections: Vec<_> = (0..70).map(|index| serde_json::json!({
            "id": format!("connection-{index}"), "name": "Configured",
            "accessMode": "surprise", "billingMode": "monthly-from-url",
            "allowances": [{"id": "budget", "label": "Budget", "unit": "tokens", "remaining": 1e100, "used": -1, "limit": 0}],
            "balances": [{"currency": "USD", "amount": "https://secret.invalid"}]
        })).collect();
        fs::write(
            home.join(".harvis-account.json"),
            serde_json::to_vec(&serde_json::json!({"connections": connections})).unwrap(),
        )
        .unwrap();
        let projection = inspect_home(&home, "environment").unwrap();
        assert_eq!(projection.configured_models.len(), 256);
        assert_eq!(projection.connections.len(), 64);
        assert_eq!(projection.connections[0].access_mode, "unknown");
        assert_eq!(projection.connections[0].billing_mode, "unknown");
        assert_eq!(projection.connections[0].allowances[0].remaining, None);
        assert_eq!(projection.connections[0].allowances[0].used, None);
        assert_eq!(projection.connections[0].allowances[0].limit, Some(0.0));
        assert!(projection.connections[0].balances.is_empty());
        fs::write(
            home.join(".harvis-account.json"),
            vec![b' '; MAX_ACCOUNT_FILE_BYTES as usize + 1],
        )
        .unwrap();
        fs::write(&catalog, vec![b' '; MAX_CATALOG_FILE_BYTES as usize + 1]).unwrap();
        let oversized = inspect_home(&home, "environment").unwrap();
        assert!(oversized.account_note.is_none());
        assert!(oversized.configured_models.is_empty());
        assert_eq!(oversized.connections.len(), 1);
        assert_eq!(oversized.connections[0].id, "current");
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn provider_identity_not_display_name_controls_official_auth_and_quota() {
        let home = account_fixture("provider-identity");
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(
                &serde_json::json!({"email": "official@example.test", "exp": 4_102_444_800_i64}),
            )
            .unwrap(),
        );
        fs::write(home.join("auth.json"), serde_json::to_vec(&serde_json::json!({
            "tokens": {"id_token": format!("header.{payload}.signature"), "access_token": "must-not-project"}
        })).unwrap()).unwrap();
        fs::write(
            home.join("config.toml"),
            "[model_providers.openai]\nname = \"OpenAI\"\n",
        )
        .unwrap();
        assert_eq!(
            inspect_home(&home, "environment").unwrap().quota_mode,
            "subscription"
        );
        fs::write(home.join("config.toml"), "model_provider = \"custom\"\n[model_providers.custom]\nname = \"openai\"\nbase_url = \"https://api.openai.com/v1\"\n").unwrap();
        let custom = inspect_home(&home, "environment").unwrap();
        assert_eq!(custom.quota_mode, "proxy");
        assert!(custom.account_email.is_none());
        assert!(custom.auth_expires_at.is_none());
        let blocked = crate::codex_threads::read_codex_home_quota(&home).unwrap();
        assert!(!blocked.available);
        assert!(blocked.buckets.is_empty());
        fs::write(home.join("config.toml"), "[model_providers.openai]\nname = \"OpenAI\"\nbase_url = \"https://proxy.example.test/v1\"\n").unwrap();
        assert_eq!(
            inspect_home(&home, "environment").unwrap().quota_mode,
            "proxy"
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn monetary_decimals_preserve_sign_precision_and_reject_non_decimal_text() {
        for value in ["0", "-0", "12.3400", "-999999999999999999999999999.0001"] {
            assert_eq!(bounded_decimal(value).as_deref(), Some(value));
        }
        for value in [
            "",
            "-",
            "+1",
            " 1",
            "1 ",
            "1e3",
            "NaN",
            "1.",
            ".2",
            "1.2.3",
            "sk-secret",
        ] {
            assert!(
                bounded_decimal(value).is_none(),
                "Accepted invalid decimal {value:?}"
            );
        }
        assert!(bounded_decimal(&"1".repeat(129)).is_none());
    }

    fn write_official_auth(home: &Path) {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&serde_json::json!({
                "email": "official@example.test", "exp": 4_102_444_800_i64
            }))
            .unwrap(),
        );
        fs::write(
            home.join("auth.json"),
            serde_json::to_vec(&serde_json::json!({
                "tokens": {"id_token": format!("header.{payload}.signature")}
            }))
            .unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn active_custom_profile_overrides_official_defaults_and_blocks_quota_rpc() {
        let home = account_fixture("active-custom-profile");
        write_official_auth(&home);
        fs::write(
            home.join("config.toml"),
            r#"
profile = "custom"
model = "official-model"
model_provider = "openai"
[model_providers.openai]
name = "OpenAI"
base_url = "https://api.openai.com/v1"
[model_providers.deepseek]
name = "OpenAI"
base_url = "https://api.deepseek.com/v1"
[profiles.custom]
model = "deepseek-flash"
model_provider = "deepseek"
"#,
        )
        .unwrap();
        let projected = inspect_home(&home, "environment").unwrap();
        assert_eq!(projected.model.as_deref(), Some("deepseek-flash"));
        assert_eq!(projected.provider_id.as_deref(), Some("deepseek"));
        assert_eq!(projected.endpoint_host.as_deref(), Some("api.deepseek.com"));
        assert_eq!(projected.quota_mode, "proxy");
        assert!(projected.account_email.is_none());
        assert!(projected.auth_expires_at.is_none());
        assert_eq!(projected.configured_models[0].id, "deepseek-flash");
        assert_eq!(
            projected.configured_models[0].provider_id.as_deref(),
            Some("deepseek")
        );
        // This returns before looking up/spawning any real Codex CLI.
        let quota = crate::codex_threads::read_codex_home_quota(&home).unwrap();
        assert!(!quota.available);
        assert!(quota.buckets.is_empty());
        assert!(quota.error.as_deref().unwrap().contains("Custom/API key"));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn active_official_profile_overrides_custom_defaults_and_provider_settings() {
        let home = account_fixture("active-official-profile");
        write_official_auth(&home);
        fs::write(
            home.join("config.toml"),
            r#"
profile = "official"
model = "custom-model"
model_provider = "custom"
[model_providers.custom]
name = "Custom"
base_url = "https://custom.example.test/v1"
[model_providers.openai]
name = "OpenAI"
base_url = "https://api.openai.com/v1"
[profiles.official]
model = "official-model"
model_provider = "openai"
"#,
        )
        .unwrap();
        let projected = inspect_home(&home, "environment").unwrap();
        assert_eq!(projected.model.as_deref(), Some("official-model"));
        assert_eq!(projected.provider_id.as_deref(), Some("openai"));
        assert_eq!(projected.endpoint_host.as_deref(), Some("api.openai.com"));
        assert_eq!(
            projected.account_email.as_deref(),
            Some("official@example.test")
        );
        assert_eq!(codex_home_quota_mode(&home).unwrap(), "subscription");
        // An explicit selected-profile provider override is more specific than
        // the matching root provider definition, even with an official ID.
        fs::write(
            home.join("config.toml"),
            r#"
profile = "proxy"
model = "inherited-model"
[model_providers.openai]
base_url = "https://api.openai.com/v1"
[profiles.proxy.model_providers.openai]
base_url = "https://proxy.example.test/v1"
"#,
        )
        .unwrap();
        let proxy = inspect_home(&home, "environment").unwrap();
        assert_eq!(proxy.model.as_deref(), Some("inherited-model"));
        assert_eq!(proxy.endpoint_host.as_deref(), Some("proxy.example.test"));
        assert_eq!(proxy.quota_mode, "proxy");
        assert!(
            !crate::codex_threads::read_codex_home_quota(&home)
                .unwrap()
                .available
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn connection_ids_match_billing_rules_without_restricting_model_slashes() {
        for id in ["deepseek", "qwen_token-plan.v1:region", "A0"] {
            assert!(is_safe_connection_id(id));
        }
        for id in [
            "",
            " leading",
            "provider/connection",
            "sk-secret",
            "sk_secret",
            "ghp_secret",
            "github_pat_secret",
            "glpat-secret",
            "Bearer-secret",
        ] {
            assert!(!is_safe_connection_id(id));
            assert!(project_connection(&serde_json::json!({"id": id})).is_none());
        }
        assert!(!is_safe_connection_id(&"x".repeat(129)));
        let connection =
            project_connection(&serde_json::json!({"id": "safe", "modelIds": ["provider/model"]}))
                .unwrap();
        assert_eq!(connection.model_ids, vec!["provider/model"]);
    }

    #[cfg(unix)]
    #[test]
    fn bounded_json_rejects_fifo_before_open_can_wait_for_a_writer() {
        let home = account_fixture("fifo");
        let fifo = home.join("catalog.json");
        assert!(Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success());
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = sender.send(bounded_json(&fifo, MAX_CATALOG_FILE_BYTES));
        });
        let result = receiver.recv_timeout(std::time::Duration::from_secs(1));
        fs::remove_dir_all(home).unwrap();
        assert!(result
            .expect("A FIFO must be rejected without waiting for a writer")
            .is_none());
    }

    #[test]
    fn external_launcher_discovery_requires_opt_in_but_explicit_homes_remain_supported() {
        let root = env::temp_dir().join(format!("harvis-homes-consent-{}", std::process::id()));
        let default = root.join(".codex");
        let managed = root.join(".codex-managed-agent/accounts/account");
        let external = root.join("Library/Application Support/open-codex-launcher/profile-homes/account");
        for home in [&default, &managed, &external] {
            fs::create_dir_all(home).unwrap(); fs::write(home.join("config.toml"), "model = \"fixture\"\n").unwrap();
        }
        let passive = discover_under(&root, None, false, &[]).unwrap();
        assert_eq!(passive.items.len(), 2);
        assert!(passive.items.iter().all(|home| home.source != "open-codex-launcher"));
        assert_eq!(discover_under(&root, None, true, &[]).unwrap().items.len(), 3);
        assert_eq!(discover_under(&root, Some(&external), false, &[]).unwrap().items.len(), 3);
        assert_eq!(discover_under(&root, None, false, &[external]).unwrap().items.len(), 3);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn discovers_default_and_launcher_api_profiles_without_reading_secret_values() {
        let root = env::temp_dir().join(format!("harvis-codex-homes-{}", std::process::id()));
        let default_home = root.join(".codex");
        let api_home =
            root.join("Library/Application Support/open-codex-launcher/profile-homes/apikey-test");
        fs::create_dir_all(&default_home).unwrap();
        fs::create_dir_all(&api_home).unwrap();
        fs::create_dir_all(api_home.join("skills/example")).unwrap();
        fs::create_dir_all(api_home.join("rules")).unwrap();
        fs::write(api_home.join("rules/default.rules"), "allow").unwrap();
        fs::write(default_home.join("config.toml"), "model = \"gpt-test\"\n").unwrap();
        fs::write(
            api_home.join("config.toml"),
            "model = \"gpt-api\"\nmodel_provider = \"custom\"\nmodel_reasoning_effort = \"high\"\napproval_policy = \"on-request\"\nsandbox_mode = \"workspace-write\"\nweb_search = \"live\"\n[model_providers.custom]\nname = \"Example\"\nbase_url = \"https://api.example.test/v1\"\n[mcp_servers.docs]\ncommand = \"docs-server\"\n[features]\nfast_mode = true\nlegacy_mode = false\n",
        )
        .unwrap();

        let result = discover_under(&root, None, true, &[]).unwrap();
        assert_eq!(result.items.len(), 2);
        assert_eq!(result.items[0].label, "Default Codex");
        assert_eq!(result.items[1].label, "API · Example");
        assert_eq!(
            result.items[1].endpoint_host.as_deref(),
            Some("api.example.test")
        );
        assert_eq!(result.items[1].reasoning_effort.as_deref(), Some("high"));
        assert_eq!(
            result.items[1].approval_policy.as_deref(),
            Some("on-request")
        );
        assert_eq!(
            result.items[1].sandbox_mode.as_deref(),
            Some("workspace-write")
        );
        assert_eq!(result.items[1].web_search.as_deref(), Some("live"));
        assert_eq!(result.items[1].mcp_server_count, 1);
        assert_eq!(result.items[1].enabled_feature_count, 1);
        assert_eq!(result.items[1].skill_count, 1);
        assert_eq!(result.items[1].rule_count, 1);
        assert!(!serde_json::to_string(&result).unwrap().contains("api_key"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn projects_subscription_identity_without_serializing_tokens() {
        let root = env::temp_dir().join(format!(
            "harvis-codex-account-projection-{}",
            std::process::id()
        ));
        let home = root.join(".codex");
        fs::create_dir_all(&home).unwrap();
        fs::write(home.join("config.toml"), "model = \"gpt-test\"\n").unwrap();
        fs::write(
            home.join(".harvis-account.json"),
            r#"{"schemaVersion":"harvis.codex-account.v1","label":"Research"}"#,
        )
        .unwrap();
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&serde_json::json!({
                "email": "research@example.test",
                "exp": 4_102_444_800_i64,
                "https://api.openai.com/auth": {"chatgpt_plan_type": "pro"}
            }))
            .unwrap(),
        );
        let id_token = format!("header.{payload}.signature");
        fs::write(
            home.join("auth.json"),
            serde_json::to_vec(&serde_json::json!({
                "auth_mode": "chatgpt",
                "tokens": {
                    "id_token": id_token,
                    "access_token": "must-never-be-projected",
                    "refresh_token": "must-never-be-projected-either"
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let result = discover_under(&root, None, false, &[]).unwrap();
        let account = &result.items[0];
        assert_eq!(result.schema_version, "harvis.codex-home-list.v3");
        assert_eq!(account.account_note.as_deref(), Some("Research"));
        assert_eq!(
            account.account_email.as_deref(),
            Some("research@example.test")
        );
        assert_eq!(account.auth_status, "valid");
        assert_eq!(account.quota_mode, "subscription");
        let projection = serde_json::to_string(&result).unwrap();
        assert!(!projection.contains("must-never-be-projected"));
        assert!(!projection.contains(&id_token));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn resume_thread_id_is_nonempty_exact_and_shell_safe() {
        assert_eq!(
            validate_resume_thread_id("019f-thread").unwrap(),
            "019f-thread"
        );
        assert!(validate_resume_thread_id("").is_err());
        assert!(validate_resume_thread_id(" 019f-thread").is_err());
        assert!(validate_resume_thread_id("019f-thread ").is_err());
        assert!(validate_resume_thread_id("019f\nthread").is_err());
        assert_eq!(
            shell_quote("019f-thread'quoted"),
            "'019f-thread'\\''quoted'"
        );
    }

    #[test]
    fn interactive_cli_launch_rejects_a_regular_file_as_working_directory() {
        let root = env::temp_dir().join(format!("harvis codex cwd check {}", std::process::id()));
        let home = root.join("CODEX HOME");
        let working_file = root.join("not-a-directory");
        fs::create_dir_all(&home).unwrap();
        fs::write(home.join("config.toml"), "model = \"test\"\n").unwrap();
        fs::write(&working_file, "synthetic").unwrap();

        let error = launch_codex_cli_internal(&home, &working_file, None).unwrap_err();
        assert!(error
            .to_string()
            .contains("working directory is not a directory"));
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn resume_shell_command_preserves_paths_id_and_environment_without_injection() {
        use std::os::unix::fs::PermissionsExt;

        let root = env::temp_dir().join(format!(
            "harvis codex shell 'fixtures' {}",
            std::process::id()
        ));
        let home = root.join("CODEX HOME 'account'");
        let working_dir = root.join("workspace with space's quote");
        let codex = root.join("fake codex's bin");
        let output_path = root.join("synthetic-output.txt");
        let injection_marker = root.join("INJECTION-MARKER");
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&working_dir).unwrap();
        fs::create_dir_all(&codex).unwrap();
        let fake_codex = codex.join("codex");
        fs::write(
            &fake_codex,
            r#"#!/bin/sh
set -eu
{
    printf 'cwd=%s\n' "$PWD"
    printf 'CODEX_HOME=%s\n' "$CODEX_HOME"
    index=1
    for argument in "$@"; do
        printf 'arg%s=%s\n' "$index" "$argument"
        index=$((index + 1))
    done
} > "$HARVIS_SYNTHETIC_OUTPUT"
"#,
        )
        .unwrap();
        let mut permissions = fs::metadata(&fake_codex).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&fake_codex, permissions).unwrap();

        let thread_id = format!("thread id's; touch {}", injection_marker.to_string_lossy());
        let command = codex_cli_shell_command(&home, &working_dir, &fake_codex, Some(&thread_id));
        let result = Command::new("/bin/sh")
            .arg("-c")
            .arg(&command)
            .env("HARVIS_SYNTHETIC_OUTPUT", &output_path)
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "shell command failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );

        let output = fs::read_to_string(&output_path).unwrap();
        assert!(output.contains(&format!("cwd={}", working_dir.display())));
        assert!(output.contains(&format!("CODEX_HOME={}", home.display())));
        assert!(output.contains("arg1=resume\n"));
        assert!(output.contains("arg2=--\n"));
        assert!(output.contains(&format!("arg3={thread_id}\n")));
        assert!(!injection_marker.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
