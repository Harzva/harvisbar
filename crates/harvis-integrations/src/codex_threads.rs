use crate::codex_homes::stable_id;
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

const AUTO_TITLE_PREFIX: &str = "AUTO ·";
const CONTROL_THREAD_TITLE: &str = "定时任务控制台";

#[derive(Debug, Clone, Default)]
pub struct CodexArchiveOptions {
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexArchiveFailure {
    pub thread_id: String,
    pub error: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexArchiveResult {
    pub ok: bool,
    pub action: &'static str,
    pub automation_names: usize,
    pub matched: usize,
    pub archived: usize,
    pub failed: usize,
    pub failures: Vec<CodexArchiveFailure>,
    pub by_title: BTreeMap<String, usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexThreadListResult {
    pub ok: bool,
    pub schema_version: &'static str,
    pub home: String,
    pub items: Vec<CodexThreadSummary>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexThreadSummary {
    pub id: String,
    pub title: String,
    pub title_source: Option<String>,
    pub has_meaningful_title: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub tokens_used: i64,
    pub model: Option<String>,
    pub cwd: String,
    pub archived: bool,
    pub running: bool,
    pub thread_source: Option<String>,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub agent_path: Option<String>,
    pub parent_thread_id: Option<String>,
    pub agent_depth: Option<u32>,
    pub root_thread_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeQuotaResult {
    pub ok: bool,
    pub schema_version: &'static str,
    pub home_id: String,
    pub available: bool,
    pub plan_type: Option<String>,
    pub buckets: Vec<CodexQuotaBucket>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexQuotaBucket {
    pub limit_id: String,
    pub limit_name: Option<String>,
    pub plan_type: Option<String>,
    pub primary: Option<CodexQuotaWindow>,
    pub secondary: Option<CodexQuotaWindow>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexQuotaWindow {
    pub used_percent: i64,
    pub window_duration_mins: Option<i64>,
    pub resets_at: Option<i64>,
}

pub fn list_codex_threads(home: &Path, limit: usize) -> Result<CodexThreadListResult> {
    let home = home
        .canonicalize()
        .with_context(|| format!("CODEX_HOME is unavailable: {}", home.display()))?;
    if !home.is_dir() {
        bail!("CODEX_HOME is not a directory")
    }
    let codex_binary = find_codex_binary()?;
    let mut client = AppServerClient::start_for_home(&codex_binary, Some(&home))?;
    let result = client.request(
        "thread/list",
        json!({
            "archived": false,
            "limit": limit.clamp(1, 200),
            "sourceKinds": [
                "cli", "vscode", "exec", "appServer", "subAgent",
                "subAgentReview", "subAgentCompact", "subAgentThreadSpawn",
                "subAgentOther", "unknown"
            ],
            "sortKey": "updated_at",
            "sortDirection": "desc"
        }),
    )?;
    let items = result
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(project_thread)
        .collect();
    Ok(CodexThreadListResult {
        ok: true,
        schema_version: "harvis.codex-thread-list.v1",
        home: home.to_string_lossy().into_owned(),
        items,
    })
}

pub fn read_codex_home_quota(home: &Path) -> Result<CodexHomeQuotaResult> {
    let home = home
        .canonicalize()
        .with_context(|| format!("CODEX_HOME is unavailable: {}", home.display()))?;
    if !home.is_dir() {
        bail!("CODEX_HOME is not a directory")
    }
    let codex_binary = find_codex_binary()?;
    let mut client = AppServerClient::start_for_home(&codex_binary, Some(&home))?;
    let result = client.request("account/rateLimits/read", Value::Null)?;
    let mut buckets = Vec::new();
    if let Some(by_id) = result.get("rateLimitsByLimitId").and_then(Value::as_object) {
        let mut entries: Vec<_> = by_id.iter().collect();
        entries.sort_by(|left, right| left.0.cmp(right.0));
        for (limit_id, snapshot) in entries {
            if let Some(bucket) = project_quota_bucket(snapshot, Some(limit_id)) {
                buckets.push(bucket);
            }
        }
    }
    if buckets.is_empty() {
        if let Some(snapshot) = result.get("rateLimits") {
            if let Some(bucket) = project_quota_bucket(snapshot, Some("codex")) {
                buckets.push(bucket);
            }
        }
    }
    let plan_type = buckets.iter().find_map(|bucket| bucket.plan_type.clone());
    Ok(CodexHomeQuotaResult {
        ok: true,
        schema_version: "harvis.codex-home-quota.v1",
        home_id: stable_id(&home),
        available: !buckets.is_empty(),
        plan_type,
        error: buckets
            .is_empty()
            .then(|| "No official quota bucket was returned.".into()),
        buckets,
    })
}

fn project_thread(item: &Value) -> Option<CodexThreadSummary> {
    let id = item.get("id")?.as_str()?.to_owned();
    let explicit_name = nonempty_json_string(item.get("name"));
    let preview = nonempty_json_string(item.get("preview"));
    let (title, title_source, has_meaningful_title) = if let Some(name) = explicit_name {
        (bounded_single_line(name, 160), Some("name".into()), true)
    } else if let Some(preview) = preview {
        (
            bounded_single_line(preview, 160),
            Some("preview".into()),
            true,
        )
    } else {
        ("Untitled chat".into(), None, false)
    };
    let parent_thread_id = nonempty_json_string(item.get("parentThreadId")).map(str::to_owned);
    let agent_nickname = nonempty_json_string(item.get("agentNickname")).map(str::to_owned);
    let is_subagent = parent_thread_id.is_some() || agent_nickname.is_some();
    let status = item
        .pointer("/status/type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let source = nonempty_json_string(item.get("threadSource"))
        .or_else(|| nonempty_json_string(item.get("source")))
        .map(str::to_owned);

    Some(CodexThreadSummary {
        id,
        title,
        title_source,
        has_meaningful_title,
        created_at: item
            .get("createdAt")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        updated_at: item
            .get("updatedAt")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        tokens_used: 0,
        model: nonempty_json_string(item.get("modelProvider")).map(str::to_owned),
        cwd: item
            .get("cwd")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        archived: false,
        running: status == "active",
        thread_source: if is_subagent {
            Some("subagent".into())
        } else {
            source
        },
        agent_nickname,
        agent_role: nonempty_json_string(item.get("agentRole")).map(str::to_owned),
        agent_path: None,
        parent_thread_id,
        agent_depth: is_subagent.then_some(1),
        root_thread_id: nonempty_json_string(item.get("sessionId")).map(str::to_owned),
    })
}

fn project_quota_bucket(snapshot: &Value, fallback_id: Option<&str>) -> Option<CodexQuotaBucket> {
    let object = snapshot.as_object()?;
    let limit_id = nonempty_json_string(object.get("limitId"))
        .or(fallback_id)
        .unwrap_or("codex")
        .to_owned();
    Some(CodexQuotaBucket {
        limit_id,
        limit_name: nonempty_json_string(object.get("limitName")).map(str::to_owned),
        plan_type: nonempty_json_string(object.get("planType")).map(str::to_owned),
        primary: object.get("primary").and_then(project_quota_window),
        secondary: object.get("secondary").and_then(project_quota_window),
    })
}

fn project_quota_window(value: &Value) -> Option<CodexQuotaWindow> {
    let object = value.as_object()?;
    Some(CodexQuotaWindow {
        used_percent: object
            .get("usedPercent")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        window_duration_mins: object.get("windowDurationMins").and_then(Value::as_i64),
        resets_at: object.get("resetsAt").and_then(Value::as_i64),
    })
}

fn nonempty_json_string(value: Option<&Value>) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn bounded_single_line(value: &str, max_chars: usize) -> String {
    let normalized = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut chars = normalized.chars();
    let bounded: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{bounded}…")
    } else {
        bounded
    }
}

#[derive(Debug, Deserialize)]
struct AutomationConfig {
    name: Option<String>,
}

#[derive(Debug, Clone)]
struct ThreadCandidate {
    id: String,
    name: String,
    updated_at: i64,
}

pub fn archive_automation_threads(options: CodexArchiveOptions) -> Result<CodexArchiveResult> {
    let codex_home = codex_home()?;
    let automation_names = load_automation_names(&codex_home)?;
    if automation_names.is_empty() {
        bail!("no local Codex automation definitions were found");
    }

    let codex_binary = find_codex_binary()?;
    let mut client = AppServerClient::start(&codex_binary)?;
    let candidates = collect_candidates(&mut client, &automation_names)?;
    let mut archived = 0usize;
    let mut failures = Vec::new();

    if !options.dry_run {
        for candidate in &candidates {
            match client.request("thread/archive", json!({ "threadId": candidate.id })) {
                Ok(_) => archived += 1,
                Err(error) => failures.push(CodexArchiveFailure {
                    thread_id: candidate.id.clone(),
                    error: error.to_string(),
                }),
            }
        }
    }

    let mut by_title = BTreeMap::new();
    for candidate in &candidates {
        *by_title.entry(candidate.name.clone()).or_insert(0) += 1;
    }

    Ok(CodexArchiveResult {
        ok: failures.is_empty(),
        action: if options.dry_run {
            "dry-run"
        } else {
            "archive"
        },
        automation_names: automation_names.len(),
        matched: candidates.len(),
        archived,
        failed: failures.len(),
        failures,
        by_title,
    })
}

fn codex_home() -> Result<PathBuf> {
    if let Some(value) = env::var_os("CODEX_HOME") {
        return Ok(PathBuf::from(value));
    }
    let home = env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".codex"))
}

fn load_automation_names(codex_home: &Path) -> Result<BTreeSet<String>> {
    let root = codex_home.join("automations");
    let mut names = BTreeSet::new();
    let entries = match fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(names),
        Err(error) => return Err(error).with_context(|| format!("read {}", root.display())),
    };

    for entry in entries.flatten() {
        let path = entry.path().join("automation.toml");
        let Ok(contents) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(config) = toml::from_str::<AutomationConfig>(&contents) else {
            continue;
        };
        if let Some(name) = config.name.map(|value| value.trim().to_string()) {
            if !name.is_empty() {
                names.insert(name);
            }
        }
    }
    Ok(names)
}

fn find_codex_binary() -> Result<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(value) = env::var_os("HARVIS_CODEX_BIN") {
        candidates.push(PathBuf::from(value));
    }
    candidates.extend([
        PathBuf::from("/Applications/ChatGPT.app/Contents/Resources/codex"),
        PathBuf::from("/Applications/Codex.app/Contents/Resources/codex"),
        PathBuf::from("/Applications/Codex.app/Contents/MacOS/codex"),
    ]);
    if let Some(value) = command_on_path("codex") {
        candidates.push(value);
    }
    if let Some(home) = env::var_os("HOME") {
        candidates.push(PathBuf::from(home).join(".local/bin/codex"));
    }
    candidates.extend([
        PathBuf::from("/opt/homebrew/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
    ]);

    candidates
        .into_iter()
        .find(|candidate| candidate.is_file())
        .ok_or_else(|| anyhow!("Codex CLI not found; set HARVIS_CODEX_BIN"))
}

fn command_on_path(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

fn collect_candidates(
    client: &mut AppServerClient,
    automation_names: &BTreeSet<String>,
) -> Result<Vec<ThreadCandidate>> {
    let mut candidates: HashMap<String, ThreadCandidate> = HashMap::new();
    for search_term in automation_names
        .iter()
        .map(String::as_str)
        .chain(std::iter::once(AUTO_TITLE_PREFIX))
    {
        for thread in list_threads_for_term(client, search_term)? {
            if is_managed_title(&thread.name, automation_names) {
                candidates.insert(thread.id.clone(), thread);
            }
        }
    }

    let mut values: Vec<_> = candidates.into_values().collect();
    values.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(values)
}

fn is_managed_title(title: &str, automation_names: &BTreeSet<String>) -> bool {
    title != CONTROL_THREAD_TITLE
        && (automation_names.contains(title) || title.starts_with(AUTO_TITLE_PREFIX))
}

fn list_threads_for_term(
    client: &mut AppServerClient,
    search_term: &str,
) -> Result<Vec<ThreadCandidate>> {
    let mut threads = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut params = json!({
            "archived": false,
            "limit": 200,
            "searchTerm": search_term,
            "sourceKinds": [],
            "sortKey": "updated_at",
            "sortDirection": "desc"
        });
        if let Some(value) = cursor.as_ref() {
            params["cursor"] = Value::String(value.clone());
        }
        let result = client.request("thread/list", params)?;
        if let Some(data) = result.get("data").and_then(Value::as_array) {
            for item in data {
                let Some(id) = item.get("id").and_then(Value::as_str) else {
                    continue;
                };
                let Some(name) = item.get("name").and_then(Value::as_str) else {
                    continue;
                };
                let updated_at = item.get("updatedAt").and_then(Value::as_i64).unwrap_or(0);
                threads.push(ThreadCandidate {
                    id: id.to_string(),
                    name: name.trim().to_string(),
                    updated_at,
                });
            }
        }
        cursor = result
            .get("nextCursor")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        if cursor.is_none() {
            return Ok(threads);
        }
    }
}

struct AppServerClient {
    child: Child,
    stdin: BufWriter<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
}

impl AppServerClient {
    fn start(binary: &Path) -> Result<Self> {
        Self::start_for_home(binary, None)
    }

    fn start_for_home(binary: &Path, home: Option<&Path>) -> Result<Self> {
        let mut command = Command::new(binary);
        command.args(["app-server", "--stdio"]);
        if let Some(home) = home {
            command.env("CODEX_HOME", home);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("start {} app-server", binary.display()))?;
        let stdin = child
            .stdin
            .take()
            .context("Codex app-server stdin unavailable")?;
        let stdout = child
            .stdout
            .take()
            .context("Codex app-server stdout unavailable")?;
        let mut client = Self {
            child,
            stdin: BufWriter::new(stdin),
            stdout: BufReader::new(stdout),
            next_id: 1,
        };
        client.request(
            "initialize",
            json!({
                "clientInfo": {
                    "name": "harvis-codex-integration",
                    "version": "1.0"
                }
            }),
        )?;
        client.notify("initialized", None)?;
        Ok(client)
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        self.write(&json!({ "id": id, "method": method, "params": params }))?;

        let mut line = String::new();
        loop {
            line.clear();
            let read = self.stdout.read_line(&mut line)?;
            if read == 0 {
                bail!("Codex app-server exited while waiting for {method}");
            }
            let Ok(message) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if message.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if let Some(error) = message.get("error") {
                let detail = error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown app-server error");
                bail!("{method}: {detail}");
            }
            return Ok(message.get("result").cloned().unwrap_or(Value::Null));
        }
    }

    fn notify(&mut self, method: &str, params: Option<Value>) -> Result<()> {
        let mut payload = json!({ "method": method });
        if let Some(value) = params {
            payload["params"] = value;
        }
        self.write(&payload)
    }

    fn write(&mut self, payload: &Value) -> Result<()> {
        serde_json::to_writer(&mut self.stdin, payload)?;
        self.stdin.write_all(b"\n")?;
        self.stdin.flush()?;
        Ok(())
    }
}

impl Drop for AppServerClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strict_match_accepts_automation_and_auto_titles_only() {
        let names = BTreeSet::from(["daily-report".to_string()]);
        assert!(is_managed_title("daily-report", &names));
        assert!(is_managed_title("AUTO · daily-report · 2026-07-19", &names));
        assert!(!is_managed_title(
            "ordinary conversation about daily-report",
            &names
        ));
        assert!(!is_managed_title(CONTROL_THREAD_TITLE, &names));
    }

    #[test]
    fn thread_projection_is_bounded_and_never_exposes_rollout_path() {
        let source = json!({
            "id": "thread-1",
            "sessionId": "root-1",
            "parentThreadId": "parent-1",
            "preview": "  investigate\naccount   discovery  ",
            "createdAt": 10,
            "updatedAt": 20,
            "cwd": "/workspace",
            "modelProvider": "openai",
            "path": "/private/rollout/secret.jsonl",
            "status": {"type": "active"},
            "source": "cli",
            "agentNickname": "reader",
            "agentRole": "inspect"
        });
        let projected = project_thread(&source).unwrap();
        assert_eq!(projected.title, "investigate account discovery");
        assert_eq!(projected.thread_source.as_deref(), Some("subagent"));
        assert!(projected.running);
        assert!(projected.agent_path.is_none());
        let serialized = serde_json::to_string(&projected).unwrap();
        assert!(!serialized.contains("secret.jsonl"));
    }

    #[test]
    fn quota_projection_uses_public_rate_limit_fields_only() {
        let source = json!({
            "limitId": "codex",
            "limitName": "Codex",
            "planType": "pro",
            "primary": {
                "usedPercent": 12,
                "windowDurationMins": 300,
                "resetsAt": 4_102_444_800_i64
            },
            "credits": {"balance": "must-not-be-projected"}
        });
        let projected = project_quota_bucket(&source, None).unwrap();
        assert_eq!(projected.limit_id, "codex");
        assert_eq!(projected.primary.as_ref().unwrap().used_percent, 12);
        assert!(!serde_json::to_string(&projected)
            .unwrap()
            .contains("must-not-be-projected"));
    }
}
