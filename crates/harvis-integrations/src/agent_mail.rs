use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const CLI_NAME: &str = "agently-cli";
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(8);
const STATUS_CACHE_TTL_SECS: i64 = 300;

pub fn agent_mail_status() -> Value {
    if let Some(cached) = read_status_cache() {
        return cached;
    }
    match agent_mail_status_inner() {
        Ok(value) => {
            write_status_cache(&value);
            value
        }
        Err(error) => {
            let value = json!({
            "available": false,
            "status": "unavailable",
            "loggedIn": false,
            "tokenStatus": "unknown",
            "cliPresent": find_cli().is_some(),
            "account": null,
            "unreadProbe": "not-run",
            "unreadPreviewCount": 0,
            "summary": redact_error(&error.to_string()),
            "safeForHarvisBar": true,
            "includesSecrets": false,
            "includesRawBody": false,
            "generatedAt": now()
            });
            write_status_cache(&value);
            value
        }
    }
}

pub fn unread_summary(limit: usize) -> Result<Value> {
    let limit = limit.clamp(1, 20);
    let limit_string = limit.to_string();
    let root = run_cli(&[
        "message",
        "+list",
        "--dir",
        "inbox",
        "--is-unread",
        "--limit",
        &limit_string,
    ])?;
    let data = root.get("data").cloned().unwrap_or_else(|| json!({}));
    let messages = data
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let items = messages
        .iter()
        .map(summarize_message)
        .collect::<Vec<Value>>();
    let has_more = data
        .get("pagination")
        .and_then(|value| value.get("has_more"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(json!({
        "status": "ok",
        "kind": "unread-summary",
        "count": items.len(),
        "hasMore": has_more,
        "items": items,
        "summary": if items.is_empty() {
            "No unread inbox messages found."
        } else {
            "Unread inbox summary refreshed."
        },
        "safeForHarvisBar": true,
        "includesSecrets": false,
        "includesRawBody": false,
        "generatedAt": now()
    }))
}

fn agent_mail_status_inner() -> Result<Value> {
    let auth = run_cli(&["auth", "status"]).context("Agent Mail auth status failed")?;
    let logged_in = bool_at(&auth, &["data", "logged_in"]);
    let token_status = str_at(&auth, &["data", "token_status"]).unwrap_or("unknown");
    let account = if logged_in {
        run_cli(&["+me"])
            .ok()
            .and_then(|value| primary_alias(&value))
    } else {
        None
    };
    let unread_probe = if logged_in {
        match run_cli(&[
            "message",
            "+list",
            "--dir",
            "inbox",
            "--is-unread",
            "--limit",
            "5",
        ]) {
            Ok(value) => {
                let count = value
                    .get("data")
                    .and_then(|data| data.get("data"))
                    .and_then(Value::as_array)
                    .map(Vec::len)
                    .unwrap_or(0);
                json!({"status": "ok", "previewCount": count})
            }
            Err(error) => {
                json!({"status": "failed", "previewCount": 0, "summary": redact_error(&error.to_string())})
            }
        }
    } else {
        json!({"status": "auth-required", "previewCount": 0})
    };
    let probe_status = unread_probe
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let preview_count = unread_probe
        .get("previewCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let status = if !logged_in || token_status != "valid" {
        "auth-required"
    } else if probe_status == "ok" {
        "ready"
    } else {
        "limited"
    };
    let summary = if status == "ready" {
        "Agent Mail is authorized and inbox read probe is available."
    } else if status == "limited" {
        "Agent Mail auth is valid, but the inbox probe is temporarily limited."
    } else {
        "Agent Mail needs OAuth login."
    };
    Ok(json!({
        "available": logged_in && token_status == "valid",
        "status": status,
        "loggedIn": logged_in,
        "tokenStatus": token_status,
        "cliPresent": find_cli().is_some(),
        "account": account,
        "unreadProbe": probe_status,
        "unreadPreviewCount": preview_count,
        "summary": summary,
        "safeForHarvisBar": true,
        "includesSecrets": false,
        "includesRawBody": false,
        "generatedAt": now()
    }))
}

fn summarize_message(value: &Value) -> Value {
    let from = value.get("from").unwrap_or(&Value::Null);
    let from_label = str_at(from, &["name"])
        .filter(|name| !name.trim().is_empty())
        .map(truncate_text)
        .or_else(|| str_at(from, &["email"]).map(redact_email))
        .unwrap_or_else(|| "Unknown sender".to_string());
    json!({
        "messageId": str_at(value, &["message_id"]).map(redact_id),
        "createdAt": str_at(value, &["created_at"]),
        "from": from_label,
        "subject": str_at(value, &["subject"]).map(truncate_text).unwrap_or_else(|| "(no subject)".to_string()),
        "snippet": str_at(value, &["snippet"]).map(truncate_text).unwrap_or_default(),
        "hasAttachments": bool_at(value, &["has_attachments"]),
        "isRead": bool_at(value, &["is_read"])
    })
}

fn primary_alias(value: &Value) -> Option<Value> {
    let aliases = value.get("data")?.get("aliases")?.as_array()?;
    let alias = aliases
        .iter()
        .find(|item| bool_at(item, &["is_primary"]))
        .or_else(|| aliases.first())?;
    let email = str_at(alias, &["email"])?;
    Some(json!({
        "email": redact_email(email),
        "name": str_at(alias, &["name"]).map(truncate_text),
        "isPrimary": bool_at(alias, &["is_primary"])
    }))
}

fn run_cli(args: &[&str]) -> Result<Value> {
    let cli = find_cli().context("agently-cli not found in PATH or ~/.local/bin")?;
    let mut child = Command::new(cli)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start agently-cli")?;
    let started = Instant::now();
    loop {
        if child.try_wait()?.is_some() {
            let output = child.wait_with_output()?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                let stdout = String::from_utf8_lossy(&output.stdout);
                bail!(
                    "{}",
                    redact_error(if stderr.trim().is_empty() {
                        &stdout
                    } else {
                        &stderr
                    })
                );
            }
            let stdout = String::from_utf8_lossy(&output.stdout);
            return parse_json_stdout(&stdout);
        }
        if started.elapsed() > DEFAULT_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            bail!("agently-cli timed out");
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn parse_json_stdout(stdout: &str) -> Result<Value> {
    let trimmed = stdout.trim();
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        return Ok(value);
    }
    if let Some(start) = trimmed.find('{') {
        let candidate = &trimmed[start..];
        if let Ok(value) = serde_json::from_str::<Value>(candidate) {
            return Ok(value);
        }
    }
    bail!("agently-cli did not return a JSON envelope");
}

fn find_cli() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(home) = env::var("HOME") {
        candidates.push(PathBuf::from(home).join(".local/bin").join(CLI_NAME));
    }
    candidates.push(PathBuf::from("/opt/homebrew/bin").join(CLI_NAME));
    candidates.push(PathBuf::from("/usr/local/bin").join(CLI_NAME));
    if let Some(path) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&path).map(|dir| dir.join(CLI_NAME)));
    }
    candidates.into_iter().find(|path| path.exists())
}

fn read_status_cache() -> Option<Value> {
    let path = status_cache_path()?;
    let metadata = fs::metadata(&path).ok()?;
    let modified = metadata.modified().ok()?;
    let age = modified.elapsed().ok()?.as_secs();
    if age > STATUS_CACHE_TTL_SECS as u64 {
        return None;
    }
    let value = fs::read_to_string(path).ok()?;
    let data = serde_json::from_str::<Value>(&value).ok()?;
    Some(data)
}

fn write_status_cache(value: &Value) {
    let Some(path) = status_cache_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(
        path,
        serde_json::to_string_pretty(value).unwrap_or_default(),
    );
}

fn status_cache_path() -> Option<PathBuf> {
    let home = env::var("HOME").ok()?;
    Some(Path::new(&home).join(".harvis/cache/agent-mail-status.json"))
}

fn str_at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    let mut current = value;
    for key in path {
        current = current.get(*key)?;
    }
    current.as_str()
}

fn bool_at(value: &Value, path: &[&str]) -> bool {
    let mut current = value;
    for key in path {
        let Some(next) = current.get(*key) else {
            return false;
        };
        current = next;
    }
    current.as_bool().unwrap_or(false)
}

fn redact_email(email: &str) -> String {
    let Some((name, domain)) = email.split_once('@') else {
        return truncate_text(email);
    };
    let prefix: String = name.chars().take(2).collect();
    format!("{prefix}***@{domain}")
}

fn redact_id(id: &str) -> String {
    let prefix: String = id.chars().take(8).collect();
    format!("{prefix}...")
}

fn truncate_text(text: &str) -> String {
    let clean = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut output = clean.chars().take(140).collect::<String>();
    if clean.chars().count() > 140 {
        output.push_str("...");
    }
    output
}

fn redact_error(text: &str) -> String {
    let redacted = match env::var("HOME") {
        Ok(home) if !home.is_empty() => text.replace(&home, "~"),
        _ => text.to_string(),
    };
    redacted
        .replace("/Users/", "[local]/")
        .replace("/Volumes/", "[volume]/")
        .split_whitespace()
        .take(40)
        .collect::<Vec<_>>()
        .join(" ")
}

fn now() -> String {
    harvis_core::time::now_rfc3339().unwrap_or_else(|_| "unknown".to_string())
}
