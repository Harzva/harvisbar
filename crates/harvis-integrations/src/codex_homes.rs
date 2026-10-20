use anyhow::{anyhow, Context, Result};
use base64::Engine;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_AUTH_FILE_BYTES: u64 = 2 * 1024 * 1024;

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
    let user_root = home_root()?;
    let explicit = env::var_os("CODEX_HOME").map(PathBuf::from);
    discover_under(&user_root, explicit.as_deref())
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

fn discover_under(user_root: &Path, explicit: Option<&Path>) -> Result<CodexHomeList> {
    let mut candidates: BTreeMap<PathBuf, String> = BTreeMap::new();
    add_candidate(&mut candidates, user_root.join(".codex"), "default");
    if let Some(path) = explicit {
        add_candidate(&mut candidates, expand_home(path, user_root), "environment");
    }

    let grouped_roots = [
        (
            user_root.join(".codex-managed-agent/accounts"),
            "managed-agent",
        ),
        (
            user_root.join("Library/Application Support/open-codex-launcher/profile-homes"),
            "open-codex-launcher",
        ),
        (
            user_root.join("Library/Application Support/codexuse-desktop/profile-homes"),
            "codexuse-desktop",
        ),
    ];
    for (root, source) in grouped_roots {
        add_children(&mut candidates, &root, source);
    }

    if let Some(extra_roots) = env::var_os("HARVIS_CODEX_HOMES") {
        for path in env::split_paths(&extra_roots) {
            add_candidate(
                &mut candidates,
                expand_home(&path, user_root),
                "harvis-configured",
            );
        }
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
            model = value
                .get("model")
                .and_then(toml::Value::as_str)
                .map(str::to_owned);
            let provider_key = value
                .get("model_provider")
                .and_then(toml::Value::as_str)
                .unwrap_or("openai");
            provider = value
                .get("model_providers")
                .and_then(|item| item.get(provider_key))
                .and_then(|item| item.get("name"))
                .and_then(toml::Value::as_str)
                .map(str::to_owned)
                .or_else(|| Some(provider_key.to_owned()));
            endpoint_host = value
                .get("model_providers")
                .and_then(|item| item.get(provider_key))
                .and_then(|item| item.get("base_url"))
                .and_then(toml::Value::as_str)
                .and_then(url_host);
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
    let account_note = managed_account_note(&canonical);

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
    let auth = inspect_auth(
        &canonical,
        source,
        leaf,
        provider.as_deref(),
        endpoint_host.as_deref(),
    );

    Ok(CodexHome {
        id: stable_id(&canonical),
        label,
        account_note,
        path: canonical.to_string_lossy().into_owned(),
        source: source.to_owned(),
        model,
        provider,
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

fn managed_account_note(home: &Path) -> Option<String> {
    let metadata_path = home.join(".harvis-account.json");
    let metadata = fs::metadata(&metadata_path).ok()?;
    if metadata.len() > 64 * 1024 {
        return None;
    }
    let value: serde_json::Value = serde_json::from_slice(&fs::read(metadata_path).ok()?).ok()?;
    value
        .get("label")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|label| !label.is_empty() && label.chars().count() <= 60)
        .map(str::to_owned)
}

fn inspect_auth(
    home: &Path,
    source: &str,
    leaf: &str,
    provider: Option<&str>,
    endpoint_host: Option<&str>,
) -> CodexAuthProjection {
    let auth_path = home.join("auth.json");
    let is_proxy = provider.is_some_and(|value| value != "openai")
        || endpoint_host.is_some_and(|value| value != "api.openai.com");
    let source_is_api_key = source == "open-codex-launcher" && leaf.starts_with("apikey-");

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
    value
        .get(key)
        .and_then(toml::Value::as_str)
        .map(str::to_owned)
}

fn scalar_setting(value: &toml::Value, key: &str) -> Option<String> {
    let item = value.get(key)?;
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
    let without_scheme = value
        .split_once("://")
        .map(|(_, tail)| tail)
        .unwrap_or(value);
    without_scheme
        .split(['/', ':'])
        .next()
        .filter(|host| !host.is_empty())
        .map(str::to_owned)
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

        let result = discover_under(&root, None).unwrap();
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

        let result = discover_under(&root, None).unwrap();
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
