use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub const HTTP_LABEL: &str = "local.harzva.harvis.http";
pub const TICK_LABEL: &str = "local.harzva.harvis.tick";
pub const DEFAULT_HOST: &str = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8765;
pub const DEFAULT_INTERVAL: u64 = 1200;
const HUB_WIKI_ENV_VARS: [&str; 2] = ["HARVIS_HUB_WIKI_ROOT", "HARZVA_HUB_WIKI_ROOT"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Service {
    Http,
    Tick,
}

impl Service {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "http" => Ok(Self::Http),
            "tick" => Ok(Self::Tick),
            _ => bail!("unsupported service: {value}"),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Http => "http",
            Self::Tick => "tick",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Http => HTTP_LABEL,
            Self::Tick => TICK_LABEL,
        }
    }
}

#[derive(Debug, Clone)]
pub struct LaunchAgentConfig {
    pub service: Service,
    pub plugin_root: PathBuf,
    pub home: PathBuf,
    pub port: u16,
    pub root: PathBuf,
    pub profile_root: PathBuf,
    pub interval: u64,
    pub auth_token_file: Option<PathBuf>,
    pub hub_wiki_root: Option<PathBuf>,
}

impl LaunchAgentConfig {
    pub fn new(service: Service, plugin_root: impl Into<PathBuf>) -> Self {
        let home = home_dir();
        Self {
            service,
            plugin_root: plugin_root.into(),
            home: home.clone(),
            port: DEFAULT_PORT,
            root: std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
            profile_root: PathBuf::from("~/.harvis"),
            interval: DEFAULT_INTERVAL,
            auth_token_file: None,
            hub_wiki_root: discover_hub_wiki_root(&home),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ManagedServiceStatus {
    pub service: String,
    pub label: String,
    pub plist: String,
    pub loaded: bool,
    pub running: bool,
    pub listening: Option<bool>,
    pub logs: Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct LaunchctlResult {
    pub returncode: i32,
    pub stdout: String,
    pub stderr: String,
}

pub fn selected_services(value: &str) -> Result<Vec<Service>> {
    match value {
        "both" => Ok(vec![Service::Http, Service::Tick]),
        "http" | "tick" => Ok(vec![Service::parse(value)?]),
        _ => bail!("unsupported service: {value}"),
    }
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn service_log_dir(home: &Path) -> PathBuf {
    home.join(".harvis/logs")
}

pub fn auth_dir(home: &Path) -> PathBuf {
    home.join(".harvis/auth")
}

pub fn default_token_file(home: &Path) -> PathBuf {
    auth_dir(home).join("http.token")
}

pub fn launch_agent_path(service: Service, home: &Path) -> PathBuf {
    home.join("Library/LaunchAgents")
        .join(format!("{}.plist", service.label()))
}

pub fn runtime_entrypoint(config: &LaunchAgentConfig) -> PathBuf {
    let installed_binary = config.home.join(".harvis/bin/harvis");
    if let Some(source) = runtime_install_source(config) {
        if installed_binary.is_file() && files_have_equal_sha256(&source, &installed_binary) {
            return installed_binary;
        }
        return source;
    }
    if installed_binary.is_file() {
        installed_binary
    } else {
        config.plugin_root.join("scripts/harvis")
    }
}

fn runtime_install_source(config: &LaunchAgentConfig) -> Option<PathBuf> {
    let bundled_binary = config.plugin_root.join("bin/harvis");
    if bundled_binary.is_file() {
        return Some(bundled_binary);
    }
    let release_binary = config.plugin_root.join("target/release/harvis");
    release_binary.is_file().then_some(release_binary)
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn files_have_equal_sha256(left: &Path, right: &Path) -> bool {
    match (sha256_file(left), sha256_file(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

fn receipt_sha256(value: Option<&Value>, label: &str) -> Result<String> {
    let value = value
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("Harvis app bundle receipt has no {label}"))?;
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("Harvis app bundle receipt {label} is invalid");
    }
    Ok(value.to_ascii_lowercase())
}

fn receipt_git_id(value: Option<&Value>, label: &str) -> Result<()> {
    let value = value
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("Harvis app bundle receipt has no {label}"))?;
    if !(40..=64).contains(&value.len()) || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("Harvis app bundle receipt {label} is invalid");
    }
    Ok(())
}

fn validate_bundled_runtime(config: &LaunchAgentConfig, source: &Path) -> Result<String> {
    let metadata = fs::symlink_metadata(source)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!("bundled Harvis runtime must be a regular non-symlink file");
    }
    let resources = config
        .plugin_root
        .parent()
        .ok_or_else(|| anyhow::anyhow!("bundled Harvis plugin root has no Resources parent"))?;
    let receipt_path = resources.join("harvis-bundle-receipt.json");
    let receipt_metadata = fs::symlink_metadata(&receipt_path)
        .context("Harvis app bundle receipt is missing or unreadable")?;
    if receipt_metadata.file_type().is_symlink() || !receipt_metadata.is_file() {
        bail!("Harvis app bundle receipt must be a regular non-symlink file");
    }
    let receipt: Value = serde_json::from_slice(&fs::read(&receipt_path)?)?;
    if receipt.get("schemaVersion").and_then(Value::as_str) != Some("harvis.app-bundle-receipt.v1")
        || receipt.get("pluginRootMarker").and_then(Value::as_str) != Some("HarvisPlugin")
    {
        bail!("Harvis app bundle receipt identity is invalid");
    }
    let artifacts = receipt
        .get("artifacts")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow::anyhow!("Harvis app bundle receipt has no artifact contract"))?;
    let expected = receipt_sha256(artifacts.get("runtimeSha256"), "runtime hash")?;
    receipt_sha256(artifacts.get("appUnsignedSha256"), "app input hash")?;
    receipt_sha256(
        artifacts.get("systemExtensionUnsignedSha256"),
        "system extension input hash",
    )?;
    let records = artifacts
        .get("records")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("Harvis app bundle receipt has no artifact records"))?;
    let required_records = [
        ("harvis-runtime", "bin/harvis"),
        ("harvisbar-main", "artifacts/HarvisBar"),
        (
            "harvis-system-extension",
            "artifacts/HarvisPerAppProxyExtension",
        ),
    ];
    if records.len() != required_records.len() {
        bail!("Harvis app bundle receipt artifact set is invalid");
    }
    for (required_role, required_path) in required_records {
        let record = records
            .iter()
            .find(|record| record.get("role").and_then(Value::as_str) == Some(required_role))
            .ok_or_else(|| {
                anyhow::anyhow!("Harvis app bundle receipt artifact set is incomplete")
            })?;
        if record.get("relativePath").and_then(Value::as_str) != Some(required_path)
            || record.get("mode").and_then(Value::as_str) != Some("0755")
            || record.get("sizeBytes").and_then(Value::as_u64) == Some(0)
            || record.get("sizeBytes").and_then(Value::as_u64).is_none()
        {
            bail!("Harvis app bundle receipt artifact record is invalid");
        }
        let record_sha = receipt_sha256(record.get("sha256"), "artifact record hash")?;
        if required_role == "harvis-runtime" && record_sha != expected {
            bail!("Harvis app bundle receipt runtime records disagree");
        }
    }
    let provenance = receipt
        .get("provenance")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow::anyhow!("Harvis app bundle receipt has no provenance contract"))?;
    receipt_sha256(provenance.get("sha256"), "provenance hash")?;
    receipt_sha256(provenance.get("stagedPayloadSha256"), "staged payload hash")?;
    receipt_git_id(provenance.get("sourceCommit"), "source commit")?;
    receipt_git_id(provenance.get("sourceTree"), "source tree")?;
    let cache_key = provenance
        .get("cacheKey")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("Harvis app bundle receipt has no cache key"))?;
    let Some(binding) = cache_key
        .strip_prefix("personal/harvis/")
        .and_then(|value| value.rsplit_once("+codex.p2-").map(|(_, binding)| binding))
    else {
        bail!("Harvis app bundle receipt cache key is invalid");
    };
    if binding.len() != 64 || !binding.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("Harvis app bundle receipt cache key is invalid");
    }
    let payload = receipt
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow::anyhow!("Harvis app bundle receipt has no payload contract"))?;
    receipt_sha256(payload.get("sha256"), "payload hash")?;
    if payload.get("fileCount").and_then(Value::as_u64) == Some(0)
        || payload.get("fileCount").and_then(Value::as_u64).is_none()
    {
        bail!("Harvis app bundle receipt payload inventory is invalid");
    }
    let app_allowlist = receipt
        .get("appRuntimeAllowlist")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            anyhow::anyhow!("Harvis app bundle receipt has no app allowlist contract")
        })?;
    if app_allowlist.get("relativePath").and_then(Value::as_str)
        != Some("packaging/app-runtime-allowlist-v1.txt")
    {
        bail!("Harvis app bundle receipt app allowlist identity is invalid");
    }
    receipt_sha256(app_allowlist.get("sha256"), "app allowlist hash")?;
    if sha256_file(source)? != expected {
        bail!("bundled Harvis runtime does not match the app bundle receipt");
    }
    Ok(expected)
}

pub fn program_arguments(config: &LaunchAgentConfig) -> Vec<String> {
    let runtime = runtime_entrypoint(config);
    match config.service {
        Service::Http => {
            let mut args = vec![
                runtime.display().to_string(),
                "http".to_string(),
                "--host".to_string(),
                DEFAULT_HOST.to_string(),
                "--port".to_string(),
                config.port.to_string(),
                "--root".to_string(),
                normalize_path(&config.root).display().to_string(),
            ];
            if let Some(token_file) = &config.auth_token_file {
                args.extend([
                    "--auth-token-file".to_string(),
                    normalize_path(token_file).display().to_string(),
                ]);
            }
            args
        }
        Service::Tick => vec![
            runtime.display().to_string(),
            "run-tick".to_string(),
            "--root".to_string(),
            normalize_path(&config.root).display().to_string(),
            "--profile-root".to_string(),
            normalize_path(&config.profile_root).display().to_string(),
            "--interval".to_string(),
            config.interval.to_string(),
            "--loop".to_string(),
        ],
    }
}

pub fn environment(config: &LaunchAgentConfig) -> Vec<(String, String)> {
    let mut env = vec![
        ("HOME".to_string(), config.home.display().to_string()),
        (
            "PATH".to_string(),
            format!(
                "{}/.local/bin:{}/.local/node/current/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                config.home.display(),
                config.home.display()
            ),
        ),
        (
            "HARVIS_HOME".to_string(),
            config.home.join(".harvis").display().to_string(),
        ),
    ];
    if let Some(token_file) = &config.auth_token_file {
        env.push((
            "HARVIS_HTTP_AUTH_TOKEN_FILE".to_string(),
            normalize_path(token_file).display().to_string(),
        ));
    }
    if let Some(root) = config
        .hub_wiki_root
        .clone()
        .or_else(|| discover_hub_wiki_root(&config.home))
    {
        let value = normalize_path(&root).display().to_string();
        for name in HUB_WIKI_ENV_VARS {
            env.push((name.to_string(), value.clone()));
        }
    }
    env
}

pub fn discover_hub_wiki_root(home: &Path) -> Option<PathBuf> {
    for name in HUB_WIKI_ENV_VARS {
        if let Ok(value) = std::env::var(name) {
            let value = value.trim();
            if !value.is_empty() {
                return Some(PathBuf::from(value));
            }
        }
    }
    if let Ok(value) = std::env::var("HARZVA_GLOBAL_KNOWLEDGE") {
        let path = PathBuf::from(value.trim());
        if let Some(root) = discover_hub_wiki_root_from_global_knowledge(&path) {
            return Some(root);
        }
    }
    let profile_default = home.join(".harvis/knowledge-hub/wiki");
    profile_default.is_dir().then_some(profile_default)
}

fn discover_hub_wiki_root_from_global_knowledge(path: &Path) -> Option<PathBuf> {
    let text = fs::read_to_string(path).ok()?;
    hub_wiki_candidates_from_text(&text)
        .into_iter()
        .find(|candidate| candidate.is_dir())
}

fn hub_wiki_candidates_from_text(text: &str) -> Vec<PathBuf> {
    let marker = "harzva-local-knowledge-hub";
    text.split_whitespace()
        .filter_map(|raw| {
            let token = raw.trim_matches(|ch: char| {
                matches!(
                    ch,
                    '`' | '"' | '\'' | ')' | '(' | '[' | ']' | ',' | ';' | ':' | '<' | '>'
                )
            });
            let index = token.find(marker)?;
            let end = index + marker.len();
            let base = &token[..end];
            Some(PathBuf::from(base).join("wiki"))
        })
        .collect()
}

pub fn render_launch_agent(config: &LaunchAgentConfig) -> String {
    let logs = service_log_dir(&config.home);
    let args = program_arguments(config);
    let env = environment(config);
    format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        r#"<?xml version="1.0" encoding="UTF-8"?>"#,
        r#"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
        r#"<plist version="1.0">"#,
        "<dict>",
        plist_key_string("Label", config.service.label()),
        plist_key_array("ProgramArguments", &args),
        plist_key_string(
            "WorkingDirectory",
            &normalize_path(&config.plugin_root).display().to_string(),
        ),
        plist_key_dict("EnvironmentVariables", &env),
        plist_key_string("LimitLoadToSessionType", "Aqua"),
        plist_key_string("ProcessType", "Interactive"),
        format!(
            "{}{}{}{}{}{}{}{}{}",
            plist_key_bool("RunAtLoad", true),
            plist_key_bool("KeepAlive", true),
            plist_key_string(
                "StandardErrorPath",
                &logs
                    .join(format!("{}.err.log", config.service.as_str()))
                    .display()
                    .to_string(),
            ),
            plist_key_string(
                "StandardOutPath",
                &logs
                    .join(format!("{}.out.log", config.service.as_str()))
                    .display()
                    .to_string(),
            ),
            "</dict>\n",
            "</plist>\n",
            "",
            "",
            ""
        )
    )
}

pub fn ensure_log_dir(home: &Path) -> Result<PathBuf> {
    let path = service_log_dir(home);
    fs::create_dir_all(&path)?;
    Ok(path)
}

pub fn write_launch_agent(config: &LaunchAgentConfig) -> Result<PathBuf> {
    ensure_log_dir(&config.home)?;
    install_runtime_binary(config)?;
    let launch_agents = config.home.join("Library/LaunchAgents");
    fs::create_dir_all(&launch_agents)?;
    let path = launch_agent_path(config.service, &config.home);
    fs::write(&path, render_launch_agent(config))?;
    Ok(path)
}

fn install_runtime_binary(config: &LaunchAgentConfig) -> Result<()> {
    let Some(source) = runtime_install_source(config) else {
        return Ok(());
    };
    let expected_sha = if source == config.plugin_root.join("bin/harvis") {
        validate_bundled_runtime(config, &source)?
    } else {
        sha256_file(&source)?
    };
    let bin_dir = config.home.join(".harvis/bin");
    fs::create_dir_all(&bin_dir)?;
    let destination = bin_dir.join("harvis");
    let temporary = bin_dir.join("harvis.next");
    fs::copy(&source, &temporary)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o755))?;
    }
    if sha256_file(&temporary)? != expected_sha {
        let _ = fs::remove_file(&temporary);
        bail!("copied Harvis runtime failed SHA-256 verification");
    }
    fs::rename(&temporary, &destination)?;
    if sha256_file(&destination)? != expected_sha {
        bail!("installed Harvis runtime failed SHA-256 verification");
    }
    Ok(())
}

pub fn launchctl(args: &[String]) -> LaunchctlResult {
    match Command::new("/bin/launchctl").args(args).output() {
        Ok(output) => LaunchctlResult {
            returncode: output.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
        },
        Err(error) => LaunchctlResult {
            returncode: -1,
            stdout: String::new(),
            stderr: error.to_string(),
        },
    }
}

pub fn bootstrap(service: Service, home: &Path) -> LaunchctlResult {
    let uid = unsafe { libc_getuid() };
    let path = launch_agent_path(service, home);
    let _ = launchctl(&[
        "bootout".to_string(),
        format!("gui/{uid}"),
        path.display().to_string(),
    ]);
    launchctl(&[
        "bootstrap".to_string(),
        format!("gui/{uid}"),
        path.display().to_string(),
    ])
}

pub fn bootout(service: Service, home: &Path) -> LaunchctlResult {
    let uid = unsafe { libc_getuid() };
    launchctl(&[
        "bootout".to_string(),
        format!("gui/{uid}"),
        launch_agent_path(service, home).display().to_string(),
    ])
}

pub fn service_status(service: Service, home: &Path, port: u16) -> ManagedServiceStatus {
    let label = service.label();
    let uid = unsafe { libc_getuid() };
    let output = Command::new("/bin/launchctl")
        .args(["print", &format!("gui/{uid}/{label}")])
        .output();
    let (loaded, rendered) = match output {
        Ok(output) => {
            let text = format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            (output.status.success(), text)
        }
        Err(error) => (false, error.to_string()),
    };
    let running = loaded && (rendered.contains("state = running") || rendered.contains("\npid ="));
    ManagedServiceStatus {
        service: service.as_str().to_string(),
        label: label.to_string(),
        plist: launch_agent_path(service, home).display().to_string(),
        loaded,
        running,
        listening: (service == Service::Http).then(|| tcp_listening(DEFAULT_HOST, port)),
        logs: json!({
            "stdout": service_log_dir(home).join(format!("{}.out.log", service.as_str())).display().to_string(),
            "stderr": service_log_dir(home).join(format!("{}.err.log", service.as_str())).display().to_string()
        }),
    }
}

fn tcp_listening(host: &str, port: u16) -> bool {
    let Ok(mut addrs) = (host, port).to_socket_addrs() else {
        return false;
    };
    let Some(addr) = addrs.next() else {
        return false;
    };
    TcpStream::connect_timeout(&addr, Duration::from_millis(500)).is_ok()
}

fn normalize_path(path: &Path) -> PathBuf {
    expanduser(path)
        .canonicalize()
        .unwrap_or_else(|_| expanduser(path))
}

fn expanduser(path: &Path) -> PathBuf {
    let Some(value) = path.to_str() else {
        return path.to_path_buf();
    };
    if value == "~" {
        return home_dir();
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return home_dir().join(rest);
    }
    path.to_path_buf()
}

fn plist_key_string(key: &str, value: &str) -> String {
    format!(
        "<key>{}</key>\n<string>{}</string>\n",
        xml_escape(key),
        xml_escape(value)
    )
}

fn plist_key_bool(key: &str, value: bool) -> String {
    format!(
        "<key>{}</key>\n<{} />\n",
        xml_escape(key),
        if value { "true" } else { "false" }
    )
}

fn plist_key_array(key: &str, values: &[String]) -> String {
    let items = values
        .iter()
        .map(|value| format!("<string>{}</string>\n", xml_escape(value)))
        .collect::<String>();
    format!("<key>{}</key>\n<array>\n{items}</array>\n", xml_escape(key))
}

fn plist_key_dict(key: &str, values: &[(String, String)]) -> String {
    let items = values
        .iter()
        .map(|(key, value)| plist_key_string(key, value))
        .collect::<String>();
    format!("<key>{}</key>\n<dict>\n{items}</dict>\n", xml_escape(key))
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(target_os = "macos")]
unsafe fn libc_getuid() -> u32 {
    extern "C" {
        fn getuid() -> u32;
    }
    getuid()
}

#[cfg(not(target_os = "macos"))]
unsafe fn libc_getuid() -> u32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_bundle_receipt(plugin: &Path, runtime_sha256: &str) {
        let resources = plugin.parent().expect("Resources parent");
        let app_sha256 = "2".repeat(64);
        let extension_sha256 = "3".repeat(64);
        fs::write(
            resources.join("harvis-bundle-receipt.json"),
            serde_json::to_vec_pretty(&json!({
                "schemaVersion": "harvis.app-bundle-receipt.v1",
                "pluginRootMarker": "HarvisPlugin",
                "app": {
                    "bundleIdentifier": "local.harzva.harvisbar",
                    "executable": "HarvisBar",
                    "variant": "bar",
                    "version": "0.33.0"
                },
                "artifacts": {
                    "runtimeSha256": runtime_sha256,
                    "appUnsignedSha256": app_sha256,
                    "systemExtensionUnsignedSha256": extension_sha256,
                    "records": [
                        {
                            "role": "harvis-runtime",
                            "relativePath": "bin/harvis",
                            "mode": "0755",
                            "sizeBytes": 11,
                            "sha256": runtime_sha256
                        },
                        {
                            "role": "harvis-system-extension",
                            "relativePath": "artifacts/HarvisPerAppProxyExtension",
                            "mode": "0755",
                            "sizeBytes": 1,
                            "sha256": extension_sha256
                        },
                        {
                            "role": "harvisbar-main",
                            "relativePath": "artifacts/HarvisBar",
                            "mode": "0755",
                            "sizeBytes": 1,
                            "sha256": app_sha256
                        }
                    ]
                },
                "appRuntimeAllowlist": {
                    "relativePath": "packaging/app-runtime-allowlist-v1.txt",
                    "sha256": "4".repeat(64)
                },
                "payload": {
                    "digestAlgorithm": "sha256(path\\0mode\\0size\\0sha256\\0\\n)",
                    "digestScope": "all files under HarvisPlugin",
                    "fileCount": 1,
                    "sha256": "5".repeat(64)
                },
                "provenance": {
                    "cacheKey": format!("personal/harvis/0.2.0+codex.p2-{}", "6".repeat(64)),
                    "sha256": "7".repeat(64),
                    "sourceCommit": "8".repeat(40),
                    "sourceTree": "9".repeat(40),
                    "stagedPayloadSha256": "a".repeat(64)
                },
                "systemExtension": {
                    "bundleIdentifier": "com.harzva.harvisbar.per-app-proxy",
                    "bundleName": "HarvisPerAppProxyExtension.systemextension",
                    "executable": "HarvisPerAppProxyExtension",
                    "version": "0.33.0"
                }
            }))
            .expect("receipt json"),
        )
        .expect("write receipt");
    }

    #[test]
    fn renders_http_launch_agent_for_rust_runtime() {
        let temp =
            std::env::temp_dir().join(format!("harvis-macos-service-test-{}", std::process::id()));
        let plugin = temp.join("plugin");
        fs::create_dir_all(plugin.join("target/release")).expect("mkdir");
        fs::write(plugin.join("target/release/harvis"), "#!/bin/sh\n").expect("binary");
        let mut config = LaunchAgentConfig::new(Service::Http, &plugin);
        config.home = temp.join("home");
        config.root = temp.join("workspace");
        config.auth_token_file = Some(temp.join("home/.harvis/auth/http.token"));

        let plist = render_launch_agent(&config);
        assert!(plist.contains("local.harzva.harvis.http"));
        assert!(plist.contains("target/release/harvis"));
        assert!(plist.contains("<string>http</string>"));
        assert!(plist.contains("<string>--auth-token-file</string>"));
        assert!(plist.contains("<string>--root</string>"));
        assert!(plist.contains(&config.root.display().to_string()));
        assert!(plist.contains("<key>LimitLoadToSessionType</key>"));
        assert!(plist.contains("<string>Aqua</string>"));
        assert!(plist.contains("<key>ProcessType</key>"));
        assert!(plist.contains("<string>Interactive</string>"));
        assert!(!plist.contains("python3"));
        assert!(!plist.contains("harvis_http_api.py"));

        let plist_path = write_launch_agent(&config).expect("write launch agent");
        let installed_plist = fs::read_to_string(plist_path).expect("read launch agent");
        assert!(installed_plist.contains(".harvis/bin/harvis"));
        assert!(config.home.join(".harvis/bin/harvis").is_file());
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn renders_tick_launch_agent_for_rust_runtime() {
        let temp = std::env::temp_dir().join(format!(
            "harvis-macos-tick-service-test-{}",
            std::process::id()
        ));
        let plugin = temp.join("plugin");
        fs::create_dir_all(plugin.join("scripts")).expect("mkdir");
        fs::write(plugin.join("scripts/harvis"), "#!/bin/sh\n").expect("wrapper");
        let mut config = LaunchAgentConfig::new(Service::Tick, &plugin);
        config.home = temp.join("home");
        config.root = temp.join("workspace");
        config.profile_root = temp.join("profile");
        config.interval = 30;

        let plist = render_launch_agent(&config);
        assert!(plist.contains("local.harzva.harvis.tick"));
        assert!(plist.contains("scripts/harvis"));
        assert!(plist.contains("<string>run-tick</string>"));
        assert!(plist.contains("<string>--loop</string>"));
        assert!(plist.contains("<key>LimitLoadToSessionType</key>"));
        assert!(plist.contains("<string>Aqua</string>"));
        assert!(plist.contains("<key>ProcessType</key>"));
        assert!(plist.contains("<string>Interactive</string>"));
        assert!(!plist.contains("harvis_runtime_tick.py"));
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn verified_bundled_runtime_replaces_stale_installed_runtime() {
        let temp = std::env::temp_dir().join(format!(
            "harvis-macos-bundled-runtime-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&temp);
        let plugin = temp.join("HarvisRuntime.app/Contents/Resources/HarvisPlugin");
        let source = plugin.join("bin/harvis");
        fs::create_dir_all(source.parent().expect("source parent")).expect("mkdir source");
        fs::write(&source, b"new-runtime").expect("write source");
        write_bundle_receipt(&plugin, &sha256_file(&source).expect("source hash"));

        let mut config = LaunchAgentConfig::new(Service::Http, &plugin);
        config.home = temp.join("home");
        let installed = config.home.join(".harvis/bin/harvis");
        fs::create_dir_all(installed.parent().expect("installed parent")).expect("mkdir bin");
        fs::write(&installed, b"old-runtime").expect("write stale runtime");

        let before_install = render_launch_agent(&config);
        assert!(before_install.contains("HarvisPlugin/bin/harvis"));
        assert!(!before_install.contains(".harvis/bin/harvis"));

        let plist_path = write_launch_agent(&config).expect("install verified runtime");
        assert_eq!(
            fs::read(&installed).expect("read installed"),
            b"new-runtime"
        );
        assert_eq!(
            sha256_file(&installed).expect("installed hash"),
            sha256_file(&source).expect("source hash")
        );
        assert!(fs::read_to_string(plist_path)
            .expect("read plist")
            .contains(".harvis/bin/harvis"));
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn bundled_runtime_without_valid_receipt_fails_closed() {
        let temp = std::env::temp_dir().join(format!(
            "harvis-macos-bundled-runtime-reject-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&temp);
        let plugin = temp.join("HarvisRuntime.app/Contents/Resources/HarvisPlugin");
        let source = plugin.join("bin/harvis");
        fs::create_dir_all(source.parent().expect("source parent")).expect("mkdir source");
        fs::write(&source, b"unattested-runtime").expect("write source");

        let mut config = LaunchAgentConfig::new(Service::Http, &plugin);
        config.home = temp.join("home");
        let installed = config.home.join(".harvis/bin/harvis");
        fs::create_dir_all(installed.parent().expect("installed parent")).expect("mkdir bin");
        fs::write(&installed, b"trusted-old-runtime").expect("write old runtime");

        let error = write_launch_agent(&config).expect_err("missing receipt must fail");
        assert!(error.to_string().contains("bundle receipt"));
        assert_eq!(
            fs::read(&installed).expect("read preserved runtime"),
            b"trusted-old-runtime"
        );
        assert!(!launch_agent_path(Service::Http, &config.home).exists());
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn self_reported_runtime_hash_without_provenance_fails_closed() {
        let temp = std::env::temp_dir().join(format!(
            "harvis-macos-self-reported-runtime-reject-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&temp);
        let plugin = temp.join("HarvisRuntime.app/Contents/Resources/HarvisPlugin");
        let source = plugin.join("bin/harvis");
        fs::create_dir_all(source.parent().expect("source parent")).expect("mkdir source");
        fs::write(&source, b"self-reported-runtime").expect("write source");
        let resources = plugin.parent().expect("Resources parent");
        fs::write(
            resources.join("harvis-bundle-receipt.json"),
            serde_json::to_vec_pretty(&json!({
                "schemaVersion": "harvis.app-bundle-receipt.v1",
                "pluginRootMarker": "HarvisPlugin",
                "artifacts": {
                    "runtimeSha256": sha256_file(&source).expect("source hash")
                }
            }))
            .expect("receipt json"),
        )
        .expect("write self-reported receipt");

        let mut config = LaunchAgentConfig::new(Service::Http, &plugin);
        config.home = temp.join("home");
        let installed = config.home.join(".harvis/bin/harvis");
        fs::create_dir_all(installed.parent().expect("installed parent")).expect("mkdir bin");
        fs::write(&installed, b"trusted-old-runtime").expect("write old runtime");

        let error = write_launch_agent(&config).expect_err("unproven receipt must fail");
        assert!(error.to_string().contains("app input hash"));
        assert_eq!(
            fs::read(&installed).expect("read preserved runtime"),
            b"trusted-old-runtime"
        );
        assert!(!launch_agent_path(Service::Http, &config.home).exists());
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn renders_hub_wiki_environment_when_configured() {
        let temp = std::env::temp_dir().join(format!(
            "harvis-macos-hub-wiki-service-test-{}",
            std::process::id()
        ));
        let plugin = temp.join("plugin");
        fs::create_dir_all(plugin.join("target/release")).expect("mkdir");
        fs::write(plugin.join("target/release/harvis"), "#!/bin/sh\n").expect("binary");
        let hub_wiki = temp.join("harzva-local-knowledge-hub/wiki");
        let mut config = LaunchAgentConfig::new(Service::Http, &plugin);
        config.home = temp.join("home");
        config.hub_wiki_root = Some(hub_wiki.clone());

        let plist = render_launch_agent(&config);
        assert!(plist.contains("<key>HARVIS_HUB_WIKI_ROOT</key>"));
        assert!(plist.contains("<key>HARZVA_HUB_WIKI_ROOT</key>"));
        assert!(plist.contains(&hub_wiki.display().to_string()));
        let _ = fs::remove_dir_all(temp);
    }

    #[test]
    fn extracts_hub_wiki_candidates_from_global_knowledge_text() {
        let candidates = hub_wiki_candidates_from_text(
            "Hub lives at `/workspace/harzva-local-knowledge-hub` for this Mac.",
        );
        assert_eq!(
            candidates.first(),
            Some(&PathBuf::from("/workspace/harzva-local-knowledge-hub/wiki"))
        );
    }
}
