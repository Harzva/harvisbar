use anyhow::{bail, Result};
use regex::Regex;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub const ADAPTER_VERSION: &str = "v0.27-alpha";
const MAP_ENV_NAMES: &[&str] = &[
    "HARVIS_REPOATLAS_MAP",
    "REPOATLAS_MCP_INVENTORY",
    "REPO_ATLAS_DATA",
];

pub fn repoatlas_status(map_path: Option<&str>, include_paths: bool) -> Value {
    let Some((data, path)) = load_map(map_path) else {
        return unavailable_payload(map_path);
    };
    base_payload(&data, &path, include_paths)
}

pub fn repoatlas_find_repo(
    query: &str,
    limit: usize,
    map_path: Option<&str>,
    include_paths: bool,
) -> Result<Value> {
    let query = query.trim();
    if query.is_empty() {
        bail!("query is required");
    }
    let Some((data, path)) = load_map(map_path) else {
        let mut payload = unavailable_payload(map_path);
        payload["query"] = json!(query);
        payload["count"] = json!(0);
        payload["items"] = json!([]);
        return Ok(payload);
    };
    let needle = normalize_repo_key(query);
    let mut exact = Vec::new();
    let mut partial = Vec::new();
    for repo in repositories(&data) {
        let haystack = [
            "repoKey",
            "nameWithOwner",
            "url",
            "accountAlias",
            "accountLogin",
            "category",
        ]
        .iter()
        .filter_map(|key| repo.get(*key).and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase();
        let repo_key = repo
            .get("repoKey")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_lowercase();
        if !needle.is_empty() && needle == repo_key {
            exact.push(repo);
        } else if !needle.is_empty() && haystack.contains(&needle) {
            partial.push(repo);
        }
    }
    let matches = exact
        .into_iter()
        .chain(partial)
        .take(limit.clamp(1, 50))
        .collect::<Vec<_>>();
    let mut payload = base_payload(&data, &path, include_paths);
    payload["query"] = json!(query);
    payload["normalizedQuery"] = json!(needle);
    payload["count"] = json!(matches.len());
    payload["items"] = json!(matches
        .iter()
        .map(|repo| public_repo(repo, include_paths))
        .collect::<Vec<_>>());
    Ok(payload)
}

pub fn repoatlas_missing_local_copies(limit: usize, map_path: Option<&str>) -> Value {
    let Some((data, path)) = load_map(map_path) else {
        let mut payload = unavailable_payload(map_path);
        payload["count"] = json!(0);
        payload["items"] = json!([]);
        return payload;
    };
    let items = repositories(&data)
        .into_iter()
        .filter(|repo| {
            !repo
                .get("localExists")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .collect::<Vec<_>>();
    let mut payload = base_payload(&data, &path, false);
    payload["count"] = json!(items.len());
    payload["items"] = json!(items
        .iter()
        .take(limit.clamp(1, 200))
        .map(|repo| public_repo(repo, false))
        .collect::<Vec<_>>());
    payload
}

pub fn repoatlas_needs_attention(
    limit: usize,
    map_path: Option<&str>,
    include_paths: bool,
) -> Value {
    let Some((data, path)) = load_map(map_path) else {
        let mut payload = unavailable_payload(map_path);
        payload["count"] = json!(0);
        payload["items"] = json!([]);
        return payload;
    };
    let items = repositories(&data)
        .into_iter()
        .filter(needs_attention)
        .collect::<Vec<_>>();
    let mut payload = base_payload(&data, &path, include_paths);
    payload["count"] = json!(items.len());
    payload["items"] = json!(items
        .iter()
        .take(limit.clamp(1, 200))
        .map(|repo| public_repo(repo, include_paths))
        .collect::<Vec<_>>());
    payload
}

fn load_map(map_path: Option<&str>) -> Option<(Value, PathBuf)> {
    let path = resolve_map_path(map_path)?;
    let text = fs::read_to_string(&path).ok()?;
    let data = serde_json::from_str::<Value>(&text).ok()?;
    Some((data, path))
}

fn resolve_map_path(map_path: Option<&str>) -> Option<PathBuf> {
    if let Some(map_path) = map_path.map(str::trim).filter(|value| !value.is_empty()) {
        let path = expanduser(Path::new(map_path));
        return (path.exists() && path.is_file()).then_some(path);
    }
    map_candidates()
        .into_iter()
        .find(|path| path.exists() && path.is_file())
}

fn unavailable_payload(map_path: Option<&str>) -> Value {
    let mut payload = json!({
        "adapter_version": ADAPTER_VERSION,
        "repoatlas": "unavailable",
        "mapFound": false,
        "error": "repoatlas compact map not found",
        "candidateDisplays": map_candidates()
            .into_iter()
            .take(5)
            .map(|path| path_display(&path.display().to_string()))
            .collect::<Vec<_>>(),
        "redacted": true,
        "includesLocalAbsolutePaths": false
    });
    if let Some(map_path) = map_path {
        payload["providedMapDisplay"] = json!(path_display(map_path));
    }
    payload
}

fn map_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    for name in MAP_ENV_NAMES {
        if let Ok(value) = std::env::var(name) {
            let value = value.trim();
            if !value.is_empty() {
                candidates.push(expanduser(Path::new(value)));
            }
        }
    }
    candidates.extend(global_knowledge_map_candidates());
    candidates.push(expanduser(Path::new(
        "~/.harvis/repoatlas/repoatlas-local-address-map.json",
    )));
    candidates.push(
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join("repoatlas-map/repoatlas-local-address-map.json"),
    );
    let mut seen = HashSet::new();
    candidates
        .into_iter()
        .filter(|path| seen.insert(path.display().to_string()))
        .collect()
}

fn global_knowledge_map_candidates() -> Vec<PathBuf> {
    let Ok(pointer) = std::env::var("HARZVA_GLOBAL_KNOWLEDGE") else {
        return Vec::new();
    };
    if pointer.trim().is_empty() {
        return Vec::new();
    }
    let Ok(text) = fs::read_to_string(expanduser(Path::new(pointer.trim()))) else {
        return Vec::new();
    };
    global_knowledge_re()
        .captures_iter(&text)
        .filter_map(|capture| {
            capture
                .get(1)
                .map(|item| expanduser(Path::new(item.as_str())))
        })
        .collect()
}

fn repositories(data: &Value) -> Vec<Value> {
    if let Some(repos) = data.get("repositories").and_then(Value::as_array) {
        return repos
            .iter()
            .filter(|repo| repo.is_object())
            .map(compact_repo)
            .collect();
    }
    data.get("rows")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter(|row| row.is_object())
                .map(row_repo)
                .collect()
        })
        .unwrap_or_default()
}

fn compact_repo(repo: &Value) -> Value {
    json!({
        "repoKey": first_text(&[repo.get("repoKey"), Some(&json!(normalize_repo_key(&first_text(&[repo.get("nameWithOwner"), repo.get("url")]))))]),
        "nameWithOwner": first_text(&[repo.get("nameWithOwner"), repo.get("repoKey")]),
        "url": first_text(&[repo.get("url")]),
        "accountAlias": first_text(&[repo.get("accountAlias")]),
        "accountLogin": first_text(&[repo.get("accountLogin")]),
        "defaultBranch": first_text(&[repo.get("defaultBranch")]),
        "localExists": repo.get("localExists").and_then(Value::as_bool).unwrap_or(false)
            || repo.get("localPaths").and_then(Value::as_array).is_some_and(|items| !items.is_empty()),
        "localPaths": string_array(repo.get("localPaths")),
        "localStatus": first_text(&[repo.get("localStatus"), Some(&json!("no-local-copy"))]),
        "localStatusList": [first_text(&[repo.get("localStatus"), Some(&json!("no-local-copy"))])],
        "dirty": repo.get("dirty").and_then(Value::as_bool).unwrap_or(false),
        "ahead": repo.get("ahead").and_then(Value::as_i64).unwrap_or(0),
        "behind": repo.get("behind").and_then(Value::as_i64).unwrap_or(0),
        "category": first_text(&[repo.get("category")])
    })
}

fn row_repo(row: &Value) -> Value {
    if let Some(remote) = row.get("remote").filter(|value| value.is_object()) {
        let matches = row
            .get("localMatches")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let local_paths = matches
            .iter()
            .filter_map(|item| {
                item.get("path")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .collect::<Vec<_>>();
        let mut statuses = matches
            .iter()
            .filter_map(|item| {
                item.get("status")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .collect::<Vec<_>>();
        statuses.sort();
        statuses.dedup();
        let status = if statuses.is_empty() {
            first_text(&[row.get("localStatus"), Some(&json!("no-local-copy"))])
        } else {
            statuses.join(", ")
        };
        let default_branch_ref_name = row
            .get("defaultBranchRef")
            .and_then(|value| value.get("name"));
        return json!({
            "repoKey": first_text(&[remote.get("repoKey"), Some(&json!(normalize_repo_key(&first_text(&[remote.get("nameWithOwner"), remote.get("url")]))))]),
            "nameWithOwner": first_text(&[remote.get("nameWithOwner"), remote.get("repoKey")]),
            "url": first_text(&[remote.get("url")]),
            "accountAlias": first_text(&[remote.get("accountAlias")]),
            "accountLogin": first_text(&[remote.get("accountLogin")]),
            "defaultBranch": first_text(&[default_branch_ref_name, row.get("defaultBranch")]),
            "localExists": !local_paths.is_empty(),
            "localPaths": local_paths,
            "localStatus": status,
            "localStatusList": if statuses.is_empty() { vec![status.clone()] } else { statuses },
            "dirty": matches.iter().any(|item| item.get("dirty").and_then(Value::as_bool).unwrap_or(false)),
            "ahead": int_sum(&matches, "ahead"),
            "behind": int_sum(&matches, "behind"),
            "category": ""
        });
    }

    let local_paths = string_array(row.get("localPaths"));
    let statuses = string_array(row.get("localStatusList"));
    let matches = row
        .get("localMatches")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let status = first_text(&[
        row.get("localStatus"),
        Some(&json!(statuses.join(", "))),
        Some(&json!("no-local-copy")),
    ]);
    json!({
        "repoKey": first_text(&[row.get("repoKey"), Some(&json!(normalize_repo_key(&first_text(&[row.get("name"), row.get("url")]))))]),
        "nameWithOwner": first_text(&[row.get("name"), row.get("nameWithOwner"), row.get("repoKey")]),
        "url": first_text(&[row.get("url")]),
        "accountAlias": first_text(&[row.get("accountAlias")]),
        "accountLogin": first_text(&[row.get("accountLogin"), row.get("owner")]),
        "defaultBranch": first_text(&[row.get("defaultBranch")]),
        "localExists": !local_paths.is_empty(),
        "localPaths": local_paths,
        "localStatus": status,
        "localStatusList": if statuses.is_empty() { vec![status.clone()] } else { statuses },
        "dirty": matches.iter().any(|item| item.get("dirty").and_then(Value::as_bool).unwrap_or(false)),
        "ahead": int_sum(&matches, "ahead"),
        "behind": int_sum(&matches, "behind"),
        "category": first_text(&[row.get("category"), row.get("categoryLabel")])
    })
}

fn public_repo(repo: &Value, include_paths: bool) -> Value {
    let local_paths = string_array(repo.get("localPaths"));
    let mut item = json!({
        "repoKey": repo.get("repoKey").cloned().unwrap_or(Value::Null),
        "nameWithOwner": repo.get("nameWithOwner").cloned().unwrap_or(Value::Null),
        "url": repo.get("url").cloned().unwrap_or(Value::Null),
        "accountAlias": repo.get("accountAlias").cloned().unwrap_or(Value::Null),
        "accountLogin": repo.get("accountLogin").cloned().unwrap_or(Value::Null),
        "defaultBranch": repo.get("defaultBranch").cloned().unwrap_or(Value::Null),
        "localExists": repo.get("localExists").cloned().unwrap_or(Value::Null),
        "localPathCount": local_paths.len(),
        "localPathDisplays": local_paths.iter().map(|path| path_display(path)).collect::<Vec<_>>(),
        "localStatus": repo.get("localStatus").cloned().unwrap_or(Value::Null),
        "dirty": repo.get("dirty").cloned().unwrap_or(Value::Null),
        "ahead": repo.get("ahead").cloned().unwrap_or(Value::Null),
        "behind": repo.get("behind").cloned().unwrap_or(Value::Null),
        "category": repo.get("category").cloned().unwrap_or(Value::Null)
    });
    if include_paths {
        item["localPaths"] = json!(local_paths);
    }
    item
}

fn base_payload(data: &Value, inventory_path: &Path, include_paths: bool) -> Value {
    let repos = repositories(data);
    let summary = data.get("summary");
    let matched = repos
        .iter()
        .filter(|repo| {
            repo.get("localExists")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .count();
    let missing = repos.len().saturating_sub(matched);
    let attention = repos.iter().filter(|repo| needs_attention(repo)).count();
    let mut payload = json!({
        "adapter_version": ADAPTER_VERSION,
        "repoatlas": "available",
        "mapFound": true,
        "inventoryPathDisplay": path_display(&inventory_path.display().to_string()),
        "generatedAt": data.get("generatedAt").cloned().unwrap_or(Value::Null),
        "summary": {
            "remoteCount": summary.and_then(|value| value.get("remoteCount")).cloned().or_else(|| data.get("remoteCount").cloned()).unwrap_or_else(|| json!(repos.len())),
            "localRepoCount": summary.and_then(|value| value.get("localRepoCount")).cloned().or_else(|| data.get("localRepoCount").cloned()).unwrap_or(Value::Null),
            "matchedRemoteCount": summary.and_then(|value| value.get("matchedRemoteCount")).cloned().or_else(|| data.get("matchedRemoteCount").cloned()).unwrap_or_else(|| json!(matched)),
            "missingLocalCount": summary.and_then(|value| value.get("missingLocalCount")).cloned().or_else(|| data.get("missingLocalCount").cloned()).unwrap_or_else(|| json!(missing)),
            "attentionCount": summary.and_then(|value| value.get("attentionCount")).cloned().unwrap_or_else(|| json!(attention))
        },
        "redacted": !include_paths,
        "includesLocalAbsolutePaths": include_paths
    });
    if include_paths {
        payload["inventoryPath"] = json!(inventory_path.display().to_string());
    }
    payload
}

fn needs_attention(repo: &Value) -> bool {
    let statuses = string_array(repo.get("localStatusList"));
    let status_text = repo
        .get("localStatus")
        .and_then(Value::as_str)
        .unwrap_or("");
    statuses.iter().any(|status| {
        matches!(
            status.as_str(),
            "ahead" | "behind" | "diverged" | "no-upstream"
        )
    }) || ["ahead", "behind", "diverged", "no-upstream"]
        .iter()
        .any(|token| status_text.contains(token))
        || repo.get("dirty").and_then(Value::as_bool).unwrap_or(false)
        || repo.get("ahead").and_then(Value::as_i64).unwrap_or(0) != 0
        || repo.get("behind").and_then(Value::as_i64).unwrap_or(0) != 0
}

fn normalize_repo_key(value: &str) -> String {
    value
        .trim()
        .strip_prefix("https://github.com/")
        .or_else(|| value.trim().strip_prefix("http://github.com/"))
        .or_else(|| value.trim().strip_prefix("git@github.com:"))
        .unwrap_or(value.trim())
        .strip_suffix(".git")
        .unwrap_or_else(|| {
            value
                .trim()
                .strip_prefix("https://github.com/")
                .or_else(|| value.trim().strip_prefix("http://github.com/"))
                .or_else(|| value.trim().strip_prefix("git@github.com:"))
                .unwrap_or(value.trim())
        })
        .trim_matches('/')
        .to_ascii_lowercase()
}

fn first_text(values: &[Option<&Value>]) -> String {
    values
        .iter()
        .filter_map(|value| value.and_then(Value::as_str))
        .find(|value| !value.is_empty())
        .unwrap_or("")
        .to_string()
}

fn string_array(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn int_sum(items: &[Value], key: &str) -> i64 {
    items
        .iter()
        .filter_map(|item| item.get(key).and_then(Value::as_i64))
        .sum()
}

fn path_display(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    let path = Path::new(value);
    if path.is_absolute() {
        return path
            .file_name()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
            .or_else(|| Some("local-path".to_string()));
    }
    Some(value.to_string())
}

fn global_knowledge_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"RepoAtlas remote-to-local compact map is `([^`]+)`").expect("valid regex")
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
