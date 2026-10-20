use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

pub const PROJECTS_VERSION: &str = "harvis.projects.v1";

#[derive(Debug, Clone)]
pub struct ProjectListOptions {
    pub root: PathBuf,
    pub query: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ProjectDiscoverOptions {
    pub root: PathBuf,
    pub write: bool,
    pub query: Option<String>,
}

pub fn list_projects(options: ProjectListOptions) -> Result<Value> {
    let root = normalize_root(&options.root)?;
    let index_path = projects_index_path(&root);
    let mut warnings = Vec::new();
    let mut projects = read_index_projects(&index_path, &mut warnings);
    merge_projects(&mut projects, discover_project_values(&root)?);
    annotate_projects(&mut projects);
    filter_projects(&mut projects, options.query.as_deref());

    Ok(json!({
        "projects_version": PROJECTS_VERSION,
        "root": root,
        "index_path": index_path,
        "project_count": projects.len(),
        "projects": projects,
        "warnings": warnings,
        "safety": {
            "read_only": true,
            "deep_scan": false,
            "executes_project_code": false
        }
    }))
}

pub fn discover_projects(options: ProjectDiscoverOptions) -> Result<Value> {
    let root = normalize_root(&options.root)?;
    let index_path = projects_index_path(&root);
    let mut warnings = Vec::new();
    let mut indexed = read_index_projects(&index_path, &mut warnings);
    let discovered = discover_project_values(&root)?;
    let discovered_count = discovered.len();
    merge_projects(&mut indexed, discovered);
    annotate_projects(&mut indexed);

    if options.write {
        if let Some(parent) = index_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(
            &index_path,
            serde_json::to_string_pretty(&json!({
                "schema": PROJECTS_VERSION,
                "projects": indexed,
            }))? + "\n",
        )?;
    }

    let mut projects = indexed;
    filter_projects(&mut projects, options.query.as_deref());

    Ok(json!({
        "projects_version": PROJECTS_VERSION,
        "root": root,
        "index_path": index_path,
        "discovered_count": discovered_count,
        "project_count": projects.len(),
        "projects": projects,
        "wrote_index": options.write,
        "warnings": warnings,
        "safety": {
            "read_only": !options.write,
            "deep_scan": false,
            "executes_project_code": false
        }
    }))
}

fn normalize_root(value: &Path) -> Result<PathBuf> {
    if value.as_os_str().is_empty() {
        bail!("workspace root must be a non-empty path");
    }
    if value.is_absolute() {
        Ok(value.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(value))
    }
}

fn projects_index_path(root: &Path) -> PathBuf {
    root.join(".harvis/projects.json")
}

fn read_index_projects(index_path: &Path, warnings: &mut Vec<String>) -> Vec<Value> {
    let Ok(text) = fs::read_to_string(index_path) else {
        return Vec::new();
    };
    match serde_json::from_str::<Value>(&text) {
        Ok(value) => value
            .get("projects")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        Err(error) => {
            warnings.push(format!(
                "invalid projects index {}: {}",
                index_path.display(),
                error
            ));
            Vec::new()
        }
    }
}

fn discover_project_values(root: &Path) -> Result<Vec<Value>> {
    let mut projects = Vec::new();
    if looks_like_workspace_project(root) {
        projects.push(generic_project(root.to_path_buf(), Some("workspace-root")));
    }

    let project2web_path = root.join("project2web-console");
    if looks_like_project2web_console(&project2web_path) {
        projects.push(project2web_console_project(project2web_path));
    }

    let Ok(entries) = fs::read_dir(root) else {
        return Ok(projects);
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path == root.join("project2web-console")
            || !path.is_dir()
            || should_skip_project_dir(&path)
        {
            continue;
        }
        if looks_like_project2web_console(&path) {
            projects.push(project2web_console_project(path));
        } else if looks_like_workspace_project(&path) {
            projects.push(generic_project(path, None));
        }
    }
    Ok(projects)
}

fn should_skip_project_dir(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
        return true;
    };
    matches!(
        name,
        ".git"
            | ".harvis"
            | ".venv"
            | ".tox"
            | ".mypy_cache"
            | ".pytest_cache"
            | ".ruff_cache"
            | ".next"
            | ".nuxt"
            | ".turbo"
            | ".cache"
            | "__pycache__"
            | "node_modules"
            | "target"
            | "dist"
            | "build"
            | "coverage"
            | "DerivedData"
            | ".build"
    )
}

fn looks_like_project2web_console(path: &Path) -> bool {
    path.join("project2web.toml").is_file()
        || path
            .join("skills/project2management-console-webview/SKILL.md")
            .is_file()
        || path
            .file_name()
            .and_then(|value| value.to_str())
            .is_some_and(|name| name == "project2web-console")
}

fn project2web_console_project(path: PathBuf) -> Value {
    let project_id = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("project2web-console")
        .to_string();
    json!({
        "project_id": project_id,
        "name": "project2web-console",
        "kind": "console-source-pack",
        "status": "available",
        "path": path,
        "description": "Reusable local webview/control-console source pack for project management dashboards.",
        "default_port": 7861,
        "entrypoints": [
            {"kind": "readme", "path": path.join("README.md")},
            {"kind": "installer", "path": path.join("skills/project2management-console-webview/scripts/create_management_console.py")},
            {"kind": "skill", "path": path.join("skills/project2management-console-webview/SKILL.md")}
        ],
        "safety": {
            "repo_bounded_reads": true,
            "arbitrary_shell_input": false,
            "requires_whitelisted_launchers": true
        }
    })
}

fn looks_like_workspace_project(path: &Path) -> bool {
    [
        "AGENTS.md",
        "README.md",
        "Cargo.toml",
        "package.json",
        "pyproject.toml",
        "project2web.toml",
    ]
    .iter()
    .any(|marker| path.join(marker).is_file())
        || path.join(".git").is_dir()
}

fn generic_project(path: PathBuf, explicit_id: Option<&str>) -> Value {
    let project_id = explicit_id
        .map(ToString::to_string)
        .or_else(|| {
            path.file_name()
                .and_then(|value| value.to_str())
                .map(ToString::to_string)
        })
        .unwrap_or_else(|| "project".to_string());
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(&project_id)
        .to_string();
    let kind = infer_project_kind(&path);
    let entrypoints = project_entrypoints(&path);
    let aliases = project_aliases(&project_id, &name);

    json!({
        "project_id": project_id,
        "name": name,
        "kind": kind,
        "status": "available",
        "path": path,
        "description": "Local project discovered by shallow Harvis project locator fingerprints.",
        "aliases": aliases,
        "entrypoints": entrypoints,
        "discovery": {
            "source": "shallow-fingerprint",
            "depth": 1,
            "executes_project_code": false
        },
        "safety": {
            "repo_bounded_reads": true,
            "arbitrary_shell_input": false,
            "requires_whitelisted_launchers": true
        }
    })
}

fn infer_project_kind(path: &Path) -> &'static str {
    if path.join(".harvis").is_dir() || path.join("AGENTS.md").is_file() {
        "harvis-workspace"
    } else if path.join("Cargo.toml").is_file() {
        "rust-project"
    } else if path.join("package.json").is_file() {
        "node-project"
    } else if path.join("pyproject.toml").is_file() {
        "python-project"
    } else if path.join(".git").is_dir() {
        "git-project"
    } else {
        "local-project"
    }
}

fn project_entrypoints(path: &Path) -> Vec<Value> {
    [
        ("agents", "AGENTS.md"),
        ("readme", "README.md"),
        ("rust-manifest", "Cargo.toml"),
        ("node-manifest", "package.json"),
        ("python-manifest", "pyproject.toml"),
        ("project2web", "project2web.toml"),
    ]
    .iter()
    .filter_map(|(kind, relative)| {
        let entrypoint = path.join(relative);
        entrypoint
            .is_file()
            .then(|| json!({"kind": kind, "path": entrypoint}))
    })
    .collect()
}

fn project_aliases(project_id: &str, name: &str) -> Vec<String> {
    let mut aliases = Vec::new();
    for value in [project_id, name] {
        push_alias(&mut aliases, value);
        push_alias(&mut aliases, &value.replace('_', "-"));
        push_alias(&mut aliases, &value.replace('-', "_"));
    }
    aliases
}

fn push_alias(aliases: &mut Vec<String>, value: &str) {
    let value = value.trim();
    if value.is_empty() || aliases.iter().any(|existing| existing == value) {
        return;
    }
    aliases.push(value.to_string());
}

fn merge_projects(projects: &mut Vec<Value>, discovered: Vec<Value>) {
    for project in discovered {
        let Some(project_id) = project.get("project_id").and_then(Value::as_str) else {
            continue;
        };
        if projects.iter().any(|existing| {
            existing
                .get("project_id")
                .and_then(Value::as_str)
                .is_some_and(|existing_id| existing_id == project_id)
        }) {
            continue;
        }
        projects.push(project);
    }
}

fn annotate_projects(projects: &mut [Value]) {
    for project in projects {
        let Some(object) = project.as_object_mut() else {
            continue;
        };
        let exists = object
            .get("path")
            .and_then(Value::as_str)
            .map(|path| Path::new(path).exists())
            .unwrap_or(false);
        object.insert("exists".to_string(), json!(exists));
    }
}

fn filter_projects(projects: &mut Vec<Value>, query: Option<&str>) {
    let Some(query) = query.map(str::trim).filter(|value| !value.is_empty()) else {
        return;
    };
    let needle = query.to_ascii_lowercase();
    projects.retain(|project| project_match_score(project, &needle).is_some());
    projects.sort_by_key(|project| project_match_score(project, &needle).unwrap_or(99));
}

fn project_match_score(project: &Value, needle: &str) -> Option<u8> {
    let direct_fields = ["project_id", "name"];
    if direct_fields.iter().any(|field| {
        project
            .get(field)
            .and_then(Value::as_str)
            .map(|value| value.eq_ignore_ascii_case(needle))
            .unwrap_or(false)
    }) {
        return Some(0);
    }
    if array_field_matches(project, "aliases", needle, MatchMode::Exact)
        || array_field_matches(project, "tags", needle, MatchMode::Exact)
    {
        return Some(1);
    }
    if direct_fields.iter().any(|field| {
        project
            .get(field)
            .and_then(Value::as_str)
            .map(|value| value.to_ascii_lowercase().starts_with(needle))
            .unwrap_or(false)
    }) {
        return Some(2);
    }
    if array_field_matches(project, "aliases", needle, MatchMode::Contains)
        || array_field_matches(project, "tags", needle, MatchMode::Contains)
    {
        return Some(3);
    }
    if ["project_id", "name", "kind", "description"]
        .iter()
        .any(|field| string_field_contains(project, field, needle))
    {
        return Some(4);
    }
    if string_field_contains(project, "path", needle) {
        return Some(5);
    }
    if project
        .get("entrypoints")
        .and_then(Value::as_array)
        .map(|entrypoints| {
            entrypoints.iter().any(|entrypoint| {
                entrypoint
                    .get("path")
                    .and_then(Value::as_str)
                    .map(|value| value.to_ascii_lowercase().contains(needle))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
    {
        return Some(6);
    }
    None
}

#[derive(Clone, Copy)]
enum MatchMode {
    Exact,
    Contains,
}

fn string_field_contains(project: &Value, field: &str, needle: &str) -> bool {
    project
        .get(field)
        .and_then(Value::as_str)
        .map(|value| value.to_ascii_lowercase().contains(needle))
        .unwrap_or(false)
}

fn array_field_matches(project: &Value, field: &str, needle: &str, mode: MatchMode) -> bool {
    project
        .get(field)
        .and_then(Value::as_array)
        .map(|values| {
            values.iter().any(|value| {
                value
                    .as_str()
                    .map(|value| {
                        let value = value.to_ascii_lowercase();
                        match mode {
                            MatchMode::Exact => value == needle,
                            MatchMode::Contains => value.contains(needle),
                        }
                    })
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovers_project2web_console_by_fingerprint() {
        let root =
            std::env::temp_dir().join(format!("harvis-projects-test-{}", std::process::id()));
        let project = root.join("project2web-console");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&project).expect("project dir");
        fs::write(project.join("project2web.toml"), "[project]\n").expect("fingerprint");

        let value = discover_projects(ProjectDiscoverOptions {
            root: root.clone(),
            write: false,
            query: None,
        })
        .expect("discover");
        assert_eq!(value["project_count"], 1);
        assert_eq!(value["projects"][0]["project_id"], "project2web-console");
        assert_eq!(value["projects"][0]["exists"], true);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn discovers_shallow_generic_projects() {
        let root = std::env::temp_dir().join(format!(
            "harvis-generic-projects-test-{}",
            std::process::id()
        ));
        let project = root.join("digital_me");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&project).expect("project dir");
        fs::write(project.join("pyproject.toml"), "[project]\n").expect("fingerprint");

        let value = discover_projects(ProjectDiscoverOptions {
            root: root.clone(),
            write: false,
            query: Some("digital-me".to_string()),
        })
        .expect("discover");
        assert_eq!(value["project_count"], 1);
        assert_eq!(value["projects"][0]["project_id"], "digital_me");
        assert_eq!(value["projects"][0]["kind"], "python-project");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn exact_project_match_sorts_before_path_contains() {
        let root =
            std::env::temp_dir().join(format!("harvis-project-rank-test-{}", std::process::id()));
        let exact = root.join("digital_me");
        let contains = root.join("digital_me_public");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&exact).expect("exact dir");
        fs::create_dir_all(&contains).expect("contains dir");
        fs::write(exact.join("pyproject.toml"), "[project]\n").expect("exact fingerprint");
        fs::write(contains.join("pyproject.toml"), "[project]\n").expect("contains fingerprint");

        let value = list_projects(ProjectListOptions {
            root: root.clone(),
            query: Some("digital_me".to_string()),
        })
        .expect("list");
        assert_eq!(value["projects"][0]["project_id"], "digital_me");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn skips_common_build_and_dependency_dirs() {
        let root =
            std::env::temp_dir().join(format!("harvis-project-skip-test-{}", std::process::id()));
        let skipped = root.join("node_modules");
        let kept = root.join("app");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&skipped).expect("skipped dir");
        fs::create_dir_all(&kept).expect("kept dir");
        fs::write(skipped.join("package.json"), "{}\n").expect("skipped fingerprint");
        fs::write(kept.join("package.json"), "{}\n").expect("kept fingerprint");

        let value = list_projects(ProjectListOptions {
            root: root.clone(),
            query: None,
        })
        .expect("list");
        let ids = value["projects"].as_array().expect("projects");
        assert!(ids.iter().any(|project| project["project_id"] == "app"));
        assert!(!ids
            .iter()
            .any(|project| project["project_id"] == "node_modules"));

        let _ = fs::remove_dir_all(&root);
    }
}
