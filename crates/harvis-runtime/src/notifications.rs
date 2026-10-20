use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use harvis_core::time::now_rfc3339;

pub const NOTIFICATION_VERSION: &str = "v0.13-alpha";

const ALLOWED_KINDS: &[&str] = &["approval", "blocked", "service_unhealthy", "verified"];

pub fn check_notifications(root: &Path, write: bool) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let candidates = derive_notifications(&root)?;
    let mut written = Vec::new();
    let mut skipped = Vec::new();
    for notification in candidates {
        if write && append_unique(&root, &notification)? {
            written.push(notification);
        } else {
            skipped.push(notification);
        }
    }
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "allowed_kinds": ALLOWED_KINDS,
        "candidate_count": written.len() + skipped.len(),
        "written_count": written.len(),
        "written": written,
        "skipped": skipped
    }))
}

pub fn list_notifications(root: &Path, kind: Option<&str>, limit: usize) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    if let Some(kind) = kind.map(str::trim).filter(|value| !value.is_empty()) {
        if !ALLOWED_KINDS.contains(&kind) {
            bail!(
                "notification kind must be one of: {}",
                ALLOWED_KINDS.join(", ")
            );
        }
    }
    let kind_filter = kind.map(str::trim).filter(|value| !value.is_empty());
    let mut rows = Vec::new();
    for item in read_jsonl(&notifications_path(&root)?, limit.max(1) * 4)?
        .into_iter()
        .rev()
    {
        if kind_filter.is_some_and(|kind| item.get("kind").and_then(Value::as_str) != Some(kind)) {
            continue;
        }
        rows.push(item);
        if rows.len() >= limit {
            break;
        }
    }
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "allowed_kinds": ALLOWED_KINDS,
        "notification_count": rows.len(),
        "notifications": rows
    }))
}

fn derive_notifications(root: &Path) -> Result<Vec<Value>> {
    let (runtime_errors, blocked, last_tick) = status_counts(root);
    let pending = pending_approval_count(root);
    let mut notifications = Vec::new();
    if pending > 0 {
        notifications.push(build_notification(
            "approval",
            "H.A.R.V.I.S. approval required",
            &format!("{pending} approval item(s) are pending review."),
            "approvals",
            &format!("approval:{pending}"),
        )?);
    }
    if runtime_errors > 0 || blocked > 0 {
        notifications.push(build_notification(
            "blocked",
            "H.A.R.V.I.S. needs attention",
            &format!("{blocked} blocked packet(s), {runtime_errors} runtime warning(s)."),
            "runtime",
            &format!(
                "blocked:{blocked}:{runtime_errors}:{}",
                last_tick.as_deref().unwrap_or("none")
            ),
        )?);
    }
    if let Some(last_tick) =
        last_tick.filter(|_| pending == 0 && blocked == 0 && runtime_errors == 0)
    {
        notifications.push(build_notification(
            "verified",
            "H.A.R.V.I.S. runtime verified",
            "The latest read-only tick completed without warnings.",
            "runtime",
            &format!("verified:{last_tick}"),
        )?);
    }
    let service_status = read_json(&root.join(".harvis/service-status.json"));
    if service_status
        .as_ref()
        .and_then(|value| value.get("state"))
        .and_then(Value::as_str)
        == Some("unhealthy")
    {
        let updated = service_status
            .as_ref()
            .and_then(|value| value.get("updated_at"))
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        notifications.push(build_notification(
            "service_unhealthy",
            "H.A.R.V.I.S. service unhealthy",
            "A local H.A.R.V.I.S. service reports an unhealthy state.",
            "service",
            &format!("service_unhealthy:{updated}"),
        )?);
    }
    Ok(notifications)
}

fn build_notification(
    kind: &str,
    title: &str,
    body: &str,
    source: &str,
    dedupe_key: &str,
) -> Result<Value> {
    if !ALLOWED_KINDS.contains(&kind) {
        bail!(
            "notification kind must be one of: {}",
            ALLOWED_KINDS.join(", ")
        );
    }
    Ok(json!({
        "notification_version": NOTIFICATION_VERSION,
        "notification_id": notification_id(dedupe_key)?,
        "kind": kind,
        "status": "candidate",
        "created_at": now_rfc3339()?,
        "title": title,
        "body": body,
        "source": source,
        "dedupe_key": dedupe_key,
        "safety": {
            "allowedByPolicy": true,
            "includesSecrets": false,
            "includesRawMemory": false,
            "includesLocalAbsolutePaths": false
        }
    }))
}

fn append_unique(root: &Path, notification: &Value) -> Result<bool> {
    let path = notifications_path(root)?;
    let existing = read_jsonl(&path, 500)?;
    let dedupe_key = notification.get("dedupe_key").and_then(Value::as_str);
    if existing
        .iter()
        .any(|item| item.get("dedupe_key").and_then(Value::as_str) == dedupe_key)
    {
        return Ok(false);
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all((serde_json::to_string(notification)? + "\n").as_bytes())?;
    Ok(true)
}

fn status_counts(root: &Path) -> (usize, usize, Option<String>) {
    let status = read_json(&root.join(".harvis/status.json")).unwrap_or_else(|| json!({}));
    let runtime_errors = status
        .get("errors")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);
    let blocked = status
        .get("packet_status_counts")
        .and_then(|counts| counts.get("blocked"))
        .and_then(Value::as_u64)
        .unwrap_or(0) as usize;
    let last_tick = status
        .get("last_tick_at")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    (runtime_errors, blocked, last_tick)
}

fn pending_approval_count(root: &Path) -> usize {
    let approvals_dir = root.join(".harvis/approvals");
    let Ok(entries) = fs::read_dir(approvals_dir) else {
        return 0;
    };
    entries
        .flatten()
        .filter_map(|entry| read_json(&entry.path()))
        .filter(|value| value.get("status").and_then(Value::as_str) == Some("pending"))
        .count()
}

fn notification_id(dedupe_key: &str) -> Result<String> {
    let timestamp = timestamp_slug(&now_rfc3339()?);
    let digest = Sha256::digest(dedupe_key.as_bytes())
        .iter()
        .take(5)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(format!("notification_{timestamp}_{digest}"))
}

fn notifications_path(root: &Path) -> Result<PathBuf> {
    let harvis = root.join(".harvis");
    fs::create_dir_all(&harvis)?;
    Ok(harvis.join("notifications.jsonl"))
}

fn read_json(path: &Path) -> Option<Value> {
    let text = fs::read_to_string(path).ok()?;
    let value = serde_json::from_str::<Value>(&text).ok()?;
    value.is_object().then_some(value)
}

fn read_jsonl(path: &Path, limit: usize) -> Result<Vec<Value>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    Ok(fs::read_to_string(path)?
        .lines()
        .rev()
        .take(limit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .collect())
}

fn timestamp_slug(moment: &str) -> String {
    let digits = moment
        .chars()
        .filter(|character| character.is_ascii_digit())
        .take(14)
        .collect::<String>();
    let (date, time) = digits.split_at(8);
    format!("{date}T{time}Z")
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

fn expanduser(path: &Path) -> PathBuf {
    let Some(value) = path.to_str() else {
        return path.to_path_buf();
    };
    if value == "~" {
        return std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| path.to_path_buf());
    }
    if let Some(rest) = value.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    path.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::init::init_workspace;

    #[test]
    fn writes_verified_notification_once() {
        let root = std::env::temp_dir().join(format!(
            "harvis-notifications-rust-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        fs::write(
            root.join(".harvis/status.json"),
            json!({
                "last_tick_at": "2026-06-24T00:00:00+00:00",
                "packet_status_counts": {},
                "errors": []
            })
            .to_string(),
        )
        .expect("status");
        let first = check_notifications(&root, true).expect("check");
        let second = check_notifications(&root, true).expect("check again");
        assert_eq!(first["written_count"], 1);
        assert_eq!(second["written_count"], 0);
        let listed = list_notifications(&root, Some("verified"), 50).expect("list");
        assert_eq!(listed["notification_count"], 1);
        let _ = fs::remove_dir_all(root);
    }
}
