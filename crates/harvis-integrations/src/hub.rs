use anyhow::{bail, Result};
use regex::Regex;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

pub const ADAPTER_VERSION: &str = "v0.14-alpha";
const DEFAULT_WIKI_ROOT: &str = "~/.harvis/knowledge-hub/wiki";

pub fn hub_status() -> Value {
    let result = run_hub_json(&["status"], Duration::from_secs(8));
    if let Err(error) = result {
        return json!({
            "adapter_version": ADAPTER_VERSION,
            "hub": "unavailable",
            "error": error,
            "redacted": true
        });
    }
    let data = result.unwrap_or(Value::Null);
    let summary = data.get("summary").and_then(Value::as_object);
    let service_items = data
        .get("services")
        .and_then(Value::as_array)
        .map(|services| {
            services
                .iter()
                .filter_map(Value::as_object)
                .take(5)
                .map(|service| {
                    json!({
                        "label": service.get("label").cloned().unwrap_or(Value::Null),
                        "host": service.get("host").cloned().unwrap_or(Value::Null),
                        "configured_port": service.get("configured_port").cloned().unwrap_or(Value::Null),
                        "running": service.get("running").cloned().unwrap_or(Value::Null),
                        "listening": service.get("listening").cloned().unwrap_or(Value::Null),
                        "state": service.get("state").cloned().unwrap_or(Value::Null),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    json!({
        "adapter_version": ADAPTER_VERSION,
        "hub": "available",
        "generated_at": data.get("generated_at").cloned().unwrap_or(Value::Null),
        "summary": {
            "projects": summary.and_then(|value| value.get("projects")).cloned().unwrap_or(Value::Null),
            "repos": summary.and_then(|value| value.get("repos")).cloned().unwrap_or(Value::Null),
            "codex_skills": summary.and_then(|value| value.get("codex_skills")).cloned().unwrap_or(Value::Null),
            "codex_mcp": summary.and_then(|value| value.get("codex_mcp")).cloned().unwrap_or(Value::Null),
            "repoatlas_attention_repos": summary.and_then(|value| value.get("repoatlas_attention_repos")).cloned().unwrap_or(Value::Null),
        },
        "services": service_items,
        "redacted": true,
        "includesLocalAbsolutePaths": false
    })
}

pub fn hub_path_lookup(query: &str, limit: usize) -> Result<Value> {
    let query = query.trim();
    if query.is_empty() {
        bail!("query is required");
    }
    let result = run_hub_json(&["path", "resolve", query], Duration::from_secs(8));
    let Ok(data) = result else {
        return Ok(json!({
            "query": query,
            "count": 0,
            "items": [],
            "error": data_err(result),
            "redacted": true
        }));
    };
    let items = data
        .get("items")
        .and_then(Value::as_array)
        .map(|raw_items| {
            raw_items
                .iter()
                .filter_map(Value::as_object)
                .take(limit.clamp(1, 50))
                .map(|item| {
                    let display_source = item
                        .get("relative_path")
                        .and_then(Value::as_str)
                        .or_else(|| item.get("path").and_then(Value::as_str));
                    json!({
                        "name": item.get("name").cloned()
                            .or_else(|| item.get("relative_path").cloned())
                            .or_else(|| display_source.map(path_display).map(|value| json!(value)))
                            .unwrap_or(Value::Null),
                        "pathDisplay": display_source.and_then(path_display),
                        "status": item.get("status").cloned().unwrap_or(Value::Null),
                        "statusText": item.get("status_text").cloned().unwrap_or(Value::Null),
                        "dirty": item.get("dirty").cloned().unwrap_or(Value::Null),
                        "ahead": item.get("ahead").cloned().unwrap_or(Value::Null),
                        "behind": item.get("behind").cloned().unwrap_or(Value::Null),
                        "platform": item.get("platform").cloned().unwrap_or(Value::Null),
                        "remotePresent": item.get("remote").is_some_and(|value| !value.is_null()),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(json!({
        "query": query,
        "count": items.len(),
        "items": items,
        "redacted": true,
        "includesLocalAbsolutePaths": false
    }))
}

pub fn wiki_search(query: &str, limit: usize, max_excerpt_chars: usize) -> Result<Value> {
    let query = query.trim();
    if query.is_empty() {
        bail!("query is required");
    }
    let root = wiki_root();
    if !root.exists() {
        return Ok(
            json!({"query": query, "count": 0, "items": [], "wiki": "unavailable", "redacted": true}),
        );
    }
    let lowered = query.to_ascii_lowercase();
    let mut scored = Vec::new();
    for path in markdown_files(&root) {
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let text_lower = text.to_ascii_lowercase();
        let score = text_lower.matches(&lowered).count()
            + path
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("")
                .to_ascii_lowercase()
                .matches(&lowered)
                .count()
                * 3;
        if score > 0 {
            scored.push((score, path, text));
        }
    }
    scored.sort_by(|left, right| right.0.cmp(&left.0));
    let items = scored
        .into_iter()
        .take(limit.clamp(1, 50))
        .map(|(score, path, text)| {
            let index = text.to_ascii_lowercase().find(&lowered).unwrap_or(0);
            let start = index.saturating_sub(160);
            let excerpt = text
                .chars()
                .skip(start)
                .take(max_excerpt_chars)
                .collect::<String>();
            json!({
                "title": page_title(&path, &text),
                "page_id": wiki_page_id(&path, &root),
                "rel_path": rel_path(&path, &root),
                "score": score,
                "excerpt": redact_text(&excerpt, max_excerpt_chars)
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "query": query,
        "count": items.len(),
        "items": items,
        "wiki": "available",
        "redacted": true,
        "includesLocalAbsolutePaths": false
    }))
}

pub fn wiki_page(page: &str, max_chars: usize) -> Result<Value> {
    let root = wiki_root();
    let path = resolve_wiki_page(page, &root)?;
    let text = fs::read_to_string(&path)?;
    Ok(json!({
        "page_id": wiki_page_id(&path, &root),
        "rel_path": rel_path(&path, &root),
        "title": page_title(&path, &text),
        "content": redact_text(&text, max_chars),
        "truncated": text.chars().count() > max_chars,
        "redacted": true,
        "includesLocalAbsolutePaths": false
    }))
}

pub fn llmwiki_status() -> Value {
    let lookup =
        hub_path_lookup("llmwiki", 5).unwrap_or_else(|error| json!({"error": error.to_string()}));
    let search = wiki_search("llmwiki", 5, 360)
        .unwrap_or_else(|_| json!({"wiki": "unavailable", "count": 0, "items": []}));
    json!({
        "source_id": "llmwiki.local_project",
        "registered": lookup.get("items").and_then(Value::as_array).is_some_and(|items| !items.is_empty()),
        "lookup": lookup,
        "wiki": {
            "available": search.get("wiki").and_then(Value::as_str) == Some("available"),
            "matches": search.get("count").cloned().unwrap_or_else(|| json!(0)),
            "items": search.get("items").cloned().unwrap_or_else(|| json!([])),
        },
        "policy": {
            "discovery": "harzvahub-only",
            "directFullRepoScan": false,
            "allowlistRequiredForContent": true,
            "redacted": true
        },
        "redacted": true,
        "includesLocalAbsolutePaths": false
    })
}

pub fn redact_text(text: &str, max_chars: usize) -> String {
    let mut result = text
        .lines()
        .map(|line| {
            if sensitive_re().is_match(line) {
                "[redacted sensitive-looking line]".to_string()
            } else {
                local_path_re()
                    .replace_all(line, "[redacted local path]")
                    .to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    if result.chars().count() > max_chars {
        result = result.chars().take(max_chars).collect::<String>();
        result = result.trim_end().to_string() + "\n[truncated]";
    }
    result
}

fn run_hub_json(args: &[&str], timeout: Duration) -> std::result::Result<Value, String> {
    let mut child = Command::new("harzva-hub")
        .args(args)
        .arg("--json")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                "harzva-hub command not found".to_string()
            } else {
                redact_text(&error.to_string(), 500)
            }
        })?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| "harzva-hub stdout pipe unavailable".to_string())?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| "harzva-hub stderr pipe unavailable".to_string())?;
    let stdout_reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.read_to_end(&mut bytes);
        result.map(|_| bytes).map_err(|error| error.to_string())
    });
    let stderr_reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stderr.read_to_end(&mut bytes);
        result.map(|_| bytes).map_err(|error| error.to_string())
    });
    let started = Instant::now();
    loop {
        if child
            .try_wait()
            .map_err(|error| error.to_string())?
            .is_some()
        {
            let status = child.wait().map_err(|error| error.to_string())?;
            let stdout = stdout_reader
                .join()
                .map_err(|_| "harzva-hub stdout reader panicked".to_string())??;
            let stderr = stderr_reader
                .join()
                .map_err(|_| "harzva-hub stderr reader panicked".to_string())??;
            if !status.success() {
                let text =
                    String::from_utf8_lossy(if stderr.is_empty() { &stdout } else { &stderr });
                return Err(redact_text(&text, 500));
            }
            return serde_json::from_slice::<Value>(&stdout)
                .map_err(|error| format!("harzva-hub returned invalid JSON: {error}"));
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err("harzva-hub command timed out".to_string());
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn data_err(result: std::result::Result<Value, String>) -> String {
    result
        .err()
        .unwrap_or_else(|| "harzva-hub unavailable".to_string())
}

fn path_display(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    if value.starts_with('/') {
        return Path::new(value)
            .file_name()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
            .or_else(|| Some("local-path".to_string()));
    }
    Some(value.to_string())
}

fn wiki_root() -> PathBuf {
    std::env::var("HARVIS_HUB_WIKI_ROOT")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| {
            std::env::var("HARZVA_HUB_WIKI_ROOT")
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_WIKI_ROOT))
        .pipe(|path| expanduser(&path))
        .canonicalize()
        .unwrap_or_else(|_| expanduser(Path::new(DEFAULT_WIKI_ROOT)))
}

fn resolve_wiki_page(page: &str, root: &Path) -> Result<PathBuf> {
    let page = page.trim().trim_start_matches('/');
    if page.is_empty() {
        bail!("page is required");
    }
    let mut candidate = root.join(page);
    if candidate.extension().and_then(|value| value.to_str()) != Some("md") {
        candidate.set_extension("md");
    }
    let root = root
        .canonicalize()
        .map_err(|_| anyhow::anyhow!("wiki page not found: {page}"))?;
    let candidate = candidate
        .canonicalize()
        .map_err(|_| anyhow::anyhow!("wiki page not found: {page}"))?;
    if !candidate.starts_with(&root) {
        bail!("page must stay inside HarzvaHub wiki root");
    }
    Ok(candidate)
}

fn markdown_files(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    let mut seen = HashSet::new();
    while let Some(dir) = stack.pop() {
        if !seen.insert(dir.clone()) {
            continue;
        }
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().and_then(|value| value.to_str()) == Some("md") {
                files.push(path);
            }
        }
    }
    files
}

fn page_title(path: &Path, text: &str) -> String {
    text.lines()
        .find_map(|line| line.strip_prefix("# ").map(str::trim))
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| {
            path.file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("page")
                .to_string()
        })
}

fn wiki_page_id(path: &Path, root: &Path) -> String {
    rel_path(path, root).trim_end_matches(".md").to_string()
}

fn rel_path(path: &Path, root: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .strip_prefix(root.canonicalize().unwrap_or_else(|_| root.to_path_buf()))
        .map(|path| {
            path.to_string_lossy()
                .replace(std::path::MAIN_SEPARATOR, "/")
        })
        .unwrap_or_else(|_| path.display().to_string())
}

fn local_path_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?P<path>(?:/Users|/Volumes)/[^\s`),]+)").expect("valid regex"))
}

fn sensitive_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)(api[_-]?key|token|cookie|password|secret|credential|BEGIN\s+(?:RSA|OPENSSH|EC)?\s*PRIVATE\s+KEY)")
            .expect("valid regex")
    })
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

trait Pipe: Sized {
    fn pipe<T>(self, f: impl FnOnce(Self) -> T) -> T {
        f(self)
    }
}

impl<T> Pipe for T {}
