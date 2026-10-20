use anyhow::{bail, Context, Result};
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Instant, UNIX_EPOCH};
use toml::Value;
use walkdir::{DirEntry, WalkDir};

const GRAPH_VERSION: &str = "v0.32-alpha";
const DEFAULT_IGNORES: &[&str] = &[
    ".git",
    ".obsidian",
    ".trash",
    ".harvis",
    "attachments",
    "adapters",
    "data",
    "logs",
    "models",
    "node_modules",
    "private",
    "runtime",
];

#[derive(Debug, Clone)]
pub struct KnowledgeGraphOptions {
    pub root: PathBuf,
    pub config_path: Option<PathBuf>,
    pub vault_override: Option<PathBuf>,
    pub include_paths_override: Option<bool>,
    pub max_files_override: Option<usize>,
    pub max_nodes_override: Option<usize>,
}

#[derive(Debug, Clone)]
struct GraphConfig {
    vaults: Vec<PathBuf>,
    ignore_dirs: BTreeSet<String>,
    max_files: usize,
    max_nodes: usize,
    max_edges: usize,
    include_paths: bool,
    include_missing_targets: bool,
}

#[derive(Debug, Serialize)]
pub struct KnowledgeGraph {
    pub edges: Vec<GraphEdge>,
    pub errors: Vec<String>,
    pub graph_version: &'static str,
    #[serde(rename = "includesLocalAbsolutePaths")]
    pub includes_local_absolute_paths: bool,
    pub limits: GraphLimits,
    pub nodes: Vec<GraphNode>,
    pub read_only: bool,
    pub redacted: bool,
    pub source: GraphSource,
    pub stats: GraphStats,
    pub warnings: Vec<String>,
    pub workspace_root: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct GraphSource {
    pub config_path: Option<String>,
    pub kind: &'static str,
    pub vault_count: usize,
    pub vaults: Vec<GraphVault>,
}

#[derive(Debug, Serialize)]
pub struct GraphVault {
    pub name: String,
    pub workspace_path: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct GraphLimits {
    pub max_edges: usize,
    pub max_files: usize,
    pub max_nodes: usize,
}

#[derive(Debug, Serialize)]
pub struct GraphStats {
    pub duration_ms: u128,
    pub edge_count: usize,
    pub missing_count: usize,
    pub node_count: usize,
    pub note_count: usize,
    pub tag_count: usize,
    pub tags: Vec<(String, usize)>,
}

#[derive(Debug, Clone, Serialize)]
pub struct GraphNode {
    pub id: String,
    pub in_degree: usize,
    pub modified_at: Option<u64>,
    pub out_degree: usize,
    pub size: u64,
    pub tags: Vec<String>,
    pub title: String,
    #[serde(rename = "type")]
    pub node_type: String,
    pub vault: String,
    pub workspace_path: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct GraphEdge {
    pub label: String,
    pub source: String,
    pub target: String,
    #[serde(rename = "type")]
    pub edge_type: String,
}

#[derive(Debug, Clone)]
struct PendingEdge {
    source: String,
    raw_target: String,
    edge_type: String,
    label: String,
}

pub fn scan_knowledge_graph(options: KnowledgeGraphOptions) -> Result<KnowledgeGraph> {
    let root = options
        .root
        .expanduser()
        .canonicalize()
        .with_context(|| format!("workspace root must exist: {}", options.root.display()))?;
    if !root.is_dir() {
        bail!("workspace root must be a directory: {}", root.display());
    }

    let started = Instant::now();
    let config_path = resolve_config_path(&root, options.config_path.as_deref())?;
    let config = load_graph_config(&root, &config_path, &options)?;
    let mut warnings = Vec::new();
    let mut errors = Vec::new();
    let mut nodes: BTreeMap<String, GraphNode> = BTreeMap::new();
    let mut alias_index: HashMap<String, String> = HashMap::new();
    let mut pending_edges = Vec::new();

    for vault in &config.vaults {
        let files =
            iter_markdown_files(vault, &config.ignore_dirs, config.max_files, &mut warnings)?;
        for path in files {
            let text = match fs::read_to_string(&path) {
                Ok(text) => text,
                Err(error) if error.kind() == std::io::ErrorKind::InvalidData => {
                    warnings.push(format!(
                        "decoded with replacement: {}",
                        path.file_name()
                            .and_then(|name| name.to_str())
                            .unwrap_or("unknown")
                    ));
                    String::from_utf8_lossy(&fs::read(&path)?).into_owned()
                }
                Err(error) => {
                    errors.push(format!(
                        "read failed: {}: {error}",
                        path.file_name()
                            .and_then(|name| name.to_str())
                            .unwrap_or("unknown")
                    ));
                    continue;
                }
            };
            let (body, metadata) = strip_frontmatter(&text);
            let rel = relative_to(&path, &root)?;
            let vault_rel = relative_to(&path, vault)?;
            let note_key = strip_md_suffix(&rel);
            let node_id = format!("note:{}", slugify(note_key));
            let tags = sorted_unique(
                metadata_tags(&metadata)
                    .into_iter()
                    .chain(body_tags(&body))
                    .collect(),
            );
            let file_metadata = path.metadata()?;
            nodes.insert(
                node_id.clone(),
                GraphNode {
                    id: node_id.clone(),
                    in_degree: 0,
                    modified_at: file_metadata
                        .modified()
                        .ok()
                        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                        .map(|duration| duration.as_secs()),
                    out_degree: 0,
                    size: file_metadata.len(),
                    tags: tags.clone(),
                    title: note_title(&path, &metadata),
                    node_type: "note".to_string(),
                    vault: file_name(vault),
                    workspace_path: config.include_paths.then_some(rel.clone()),
                },
            );
            for alias in note_aliases(&path, &metadata, &rel, &vault_rel) {
                alias_index.insert(alias, node_id.clone());
            }
            for tag in tags {
                let tag_id = format!("tag:{}", slugify(&tag));
                nodes.entry(tag_id.clone()).or_insert_with(|| GraphNode {
                    id: tag_id.clone(),
                    in_degree: 0,
                    modified_at: None,
                    out_degree: 0,
                    size: 0,
                    tags: Vec::new(),
                    title: format!("#{tag}"),
                    node_type: "tag".to_string(),
                    vault: file_name(vault),
                    workspace_path: None,
                });
                pending_edges.push(PendingEdge {
                    source: node_id.clone(),
                    raw_target: tag_id,
                    edge_type: "tagged".to_string(),
                    label: tag,
                });
            }
            for raw in wiki_links(&body) {
                let target = normalize_wiki_target(&raw);
                if !target.is_empty() {
                    pending_edges.push(PendingEdge {
                        source: node_id.clone(),
                        raw_target: target.to_ascii_lowercase(),
                        edge_type: "wiki".to_string(),
                        label: target,
                    });
                }
            }
            for (_label, raw) in markdown_links(&body) {
                if let Some(target) = normalize_markdown_target(&raw) {
                    pending_edges.push(PendingEdge {
                        source: node_id.clone(),
                        raw_target: target.to_ascii_lowercase(),
                        edge_type: "markdown".to_string(),
                        label: target,
                    });
                }
            }
        }
    }

    let mut edges_by_key: BTreeMap<String, GraphEdge> = BTreeMap::new();
    for edge in pending_edges {
        if edges_by_key.len() >= config.max_edges {
            warnings.push(format!("max_edges reached: {}", config.max_edges));
            break;
        }
        let target = if edge.edge_type == "wiki" || edge.edge_type == "markdown" {
            match alias_index.get(&edge.raw_target) {
                Some(target) => target.clone(),
                None if config.include_missing_targets => {
                    let target_id = format!("missing:{}", slugify(&edge.label));
                    nodes.entry(target_id.clone()).or_insert_with(|| GraphNode {
                        id: target_id.clone(),
                        in_degree: 0,
                        modified_at: None,
                        out_degree: 0,
                        size: 0,
                        tags: Vec::new(),
                        title: edge.label.clone(),
                        node_type: "missing".to_string(),
                        vault: String::new(),
                        workspace_path: None,
                    });
                    target_id
                }
                None => continue,
            }
        } else {
            edge.raw_target.clone()
        };
        let key = format!("{}->{}:{}", edge.source, target, edge.edge_type);
        edges_by_key.entry(key).or_insert(GraphEdge {
            label: edge.label,
            source: edge.source,
            target,
            edge_type: edge.edge_type,
        });
    }

    if nodes.len() > config.max_nodes {
        let mut node_rows: Vec<_> = nodes.into_values().collect();
        node_rows.sort_by(node_sort_key);
        nodes = node_rows
            .into_iter()
            .take(config.max_nodes)
            .map(|node| (node.id.clone(), node))
            .collect();
        edges_by_key
            .retain(|_, edge| nodes.contains_key(&edge.source) && nodes.contains_key(&edge.target));
        warnings.push(format!("max_nodes reached: {}", config.max_nodes));
    }

    for edge in edges_by_key.values() {
        if let Some(source) = nodes.get_mut(&edge.source) {
            source.out_degree += 1;
        }
        if let Some(target) = nodes.get_mut(&edge.target) {
            target.in_degree += 1;
        }
    }

    let mut node_rows: Vec<_> = nodes.into_values().collect();
    node_rows.sort_by(node_sort_key);
    let mut edge_rows: Vec<_> = edges_by_key.into_values().collect();
    edge_rows.sort_by(|left, right| {
        (&left.source, &left.target, &left.edge_type).cmp(&(
            &right.source,
            &right.target,
            &right.edge_type,
        ))
    });

    let mut tag_counts: HashMap<String, usize> = HashMap::new();
    for node in &node_rows {
        if node.node_type != "note" {
            continue;
        }
        for tag in &node.tags {
            *tag_counts.entry(tag.clone()).or_insert(0) += 1;
        }
    }
    let mut tags: Vec<_> = tag_counts.into_iter().collect();
    tags.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    tags.truncate(50);

    let edge_count = edge_rows.len();
    let node_count = node_rows.len();
    let note_count = node_rows
        .iter()
        .filter(|node| node.node_type == "note")
        .count();
    let tag_count = node_rows
        .iter()
        .filter(|node| node.node_type == "tag")
        .count();
    let missing_count = node_rows
        .iter()
        .filter(|node| node.node_type == "missing")
        .count();

    Ok(KnowledgeGraph {
        edges: edge_rows,
        errors,
        graph_version: GRAPH_VERSION,
        includes_local_absolute_paths: config.include_paths,
        limits: GraphLimits {
            max_edges: config.max_edges,
            max_files: config.max_files,
            max_nodes: config.max_nodes,
        },
        nodes: node_rows,
        read_only: true,
        redacted: !config.include_paths,
        source: GraphSource {
            config_path: relative_to(&config_path, &root).ok(),
            kind: "obsidian-vault",
            vault_count: config.vaults.len(),
            vaults: config
                .vaults
                .iter()
                .map(|vault| GraphVault {
                    name: file_name(vault),
                    workspace_path: relative_to(vault, &root).ok(),
                })
                .collect(),
        },
        stats: GraphStats {
            duration_ms: started.elapsed().as_millis(),
            edge_count,
            missing_count,
            node_count,
            note_count,
            tag_count,
            tags,
        },
        warnings,
        workspace_root: config.include_paths.then(|| root.display().to_string()),
    })
}

fn load_graph_config(
    root: &Path,
    config_path: &Path,
    options: &KnowledgeGraphOptions,
) -> Result<GraphConfig> {
    let parsed = if config_path.exists() {
        fs::read_to_string(config_path)
            .with_context(|| format!("failed to read config: {}", config_path.display()))?
            .parse::<Value>()
            .with_context(|| format!("invalid config: {}", config_path.display()))?
    } else {
        Value::Table(Default::default())
    };
    let graph = parsed.get("graph");
    let mut raw_vaults =
        string_list(graph.and_then(|value| value.get("vaults"))).unwrap_or_default();
    if let Some(vault) = &options.vault_override {
        raw_vaults = vec![vault.display().to_string()];
    }
    if raw_vaults.is_empty() {
        raw_vaults.push(".".to_string());
    }

    let mut vaults = Vec::new();
    for value in raw_vaults {
        let candidate = resolve_under_root(root, Path::new(&value))?;
        if !candidate.exists() || !candidate.is_dir() {
            bail!(
                "vault does not exist or is not a directory: {}",
                candidate.display()
            );
        }
        vaults.push(candidate.canonicalize()?);
    }
    vaults.sort();
    vaults.dedup();

    let mut ignore_dirs: BTreeSet<String> = DEFAULT_IGNORES
        .iter()
        .map(|value| value.to_string())
        .collect();
    if let Some(extra_ignores) = string_list(graph.and_then(|value| value.get("ignore_dirs"))) {
        ignore_dirs.extend(extra_ignores);
    }

    Ok(GraphConfig {
        vaults,
        ignore_dirs,
        max_files: options.max_files_override.unwrap_or_else(|| {
            int_value(
                graph.and_then(|value| value.get("max_files")),
                1000,
                1,
                20_000,
            )
        }),
        max_nodes: options.max_nodes_override.unwrap_or_else(|| {
            int_value(
                graph.and_then(|value| value.get("max_nodes")),
                1500,
                1,
                20_000,
            )
        }),
        max_edges: int_value(
            graph.and_then(|value| value.get("max_edges")),
            4000,
            1,
            100_000,
        ),
        include_paths: options.include_paths_override.unwrap_or_else(|| {
            bool_value(graph.and_then(|value| value.get("include_paths")), false)
        }),
        include_missing_targets: bool_value(
            graph.and_then(|value| value.get("include_missing_targets")),
            true,
        ),
    })
}

fn iter_markdown_files(
    vault: &Path,
    ignore_dirs: &BTreeSet<String>,
    limit: usize,
    warnings: &mut Vec<String>,
) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for entry in WalkDir::new(vault)
        .sort_by_file_name()
        .into_iter()
        .filter_entry(|entry| !should_skip_entry(entry, vault, ignore_dirs))
    {
        let entry = entry?;
        if !entry.file_type().is_file()
            || entry.path().extension().and_then(|ext| ext.to_str()) != Some("md")
        {
            continue;
        }
        files.push(entry.path().to_path_buf());
        if files.len() >= limit {
            warnings.push(format!(
                "max_files reached for {}: {}",
                file_name(vault),
                limit
            ));
            break;
        }
    }
    files.sort();
    Ok(files)
}

fn should_skip_entry(entry: &DirEntry, vault: &Path, ignore_dirs: &BTreeSet<String>) -> bool {
    let Ok(relative) = entry.path().strip_prefix(vault) else {
        return false;
    };
    relative
        .components()
        .filter_map(|component| match component {
            Component::Normal(value) => value.to_str(),
            _ => None,
        })
        .any(|part| ignore_dirs.contains(part))
}

fn strip_frontmatter(text: &str) -> (String, HashMap<String, MetaValue>) {
    if !text.starts_with("---\n") {
        return (text.to_string(), HashMap::new());
    }
    let Some(end) = text[4..].find("\n---") else {
        return (text.to_string(), HashMap::new());
    };
    let metadata_text = &text[4..4 + end];
    let body_start = 4 + end + "\n---".len();
    let body = text
        .get(body_start..)
        .unwrap_or_default()
        .trim_start_matches('\n')
        .to_string();
    let mut metadata = HashMap::new();
    for line in metadata_text.lines() {
        let Some((key, raw)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue;
        }
        metadata.insert(key.to_string(), parse_meta_scalar(raw));
    }
    (body, metadata)
}

#[derive(Debug, Clone)]
enum MetaValue {
    String(String),
    List(Vec<String>),
    Bool(()),
    Int(()),
}

fn parse_meta_scalar(value: &str) -> MetaValue {
    let stripped = value.trim();
    let lowered = stripped.to_ascii_lowercase();
    if matches!(
        lowered.as_str(),
        "true" | "yes" | "on" | "false" | "no" | "off"
    ) {
        return MetaValue::Bool(());
    }
    if stripped.starts_with('[') && stripped.ends_with(']') {
        return MetaValue::List(split_csv(&stripped[1..stripped.len() - 1]));
    }
    if let Ok(_number) = stripped.parse::<i64>() {
        return MetaValue::Int(());
    }
    MetaValue::String(trim_quotes(stripped).to_string())
}

fn split_csv(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(|item| trim_quotes(item.trim()).to_string())
        .filter(|item| !item.is_empty())
        .collect()
}

fn trim_quotes(value: &str) -> &str {
    value
        .strip_prefix('"')
        .and_then(|item| item.strip_suffix('"'))
        .or_else(|| {
            value
                .strip_prefix('\'')
                .and_then(|item| item.strip_suffix('\''))
        })
        .unwrap_or(value)
}

fn metadata_string(metadata: &HashMap<String, MetaValue>, key: &str) -> Option<String> {
    match metadata.get(key) {
        Some(MetaValue::String(value)) if !value.trim().is_empty() => {
            Some(value.trim().to_string())
        }
        _ => None,
    }
}

fn metadata_list_or_string(metadata: &HashMap<String, MetaValue>, keys: &[&str]) -> Vec<String> {
    for key in keys {
        match metadata.get(*key) {
            Some(MetaValue::String(value)) => {
                return value
                    .split(|character: char| character == ',' || character.is_whitespace())
                    .map(normalize_tag)
                    .filter(|item| !item.is_empty())
                    .collect();
            }
            Some(MetaValue::List(values)) => {
                return values
                    .iter()
                    .map(|value| normalize_tag(value))
                    .filter(|item| !item.is_empty())
                    .collect();
            }
            _ => {}
        }
    }
    Vec::new()
}

fn metadata_tags(metadata: &HashMap<String, MetaValue>) -> Vec<String> {
    metadata_list_or_string(metadata, &["tags", "tag"])
}

fn note_title(path: &Path, metadata: &HashMap<String, MetaValue>) -> String {
    metadata_string(metadata, "title").unwrap_or_else(|| {
        path.file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("Untitled")
            .to_string()
    })
}

fn note_aliases(
    path: &Path,
    metadata: &HashMap<String, MetaValue>,
    workspace_path: &str,
    vault_path: &str,
) -> Vec<String> {
    let mut aliases = BTreeSet::new();
    if let Some(stem) = path.file_stem().and_then(|value| value.to_str()) {
        aliases.insert(stem.to_ascii_lowercase());
    }
    if let Some(name) = path.file_name().and_then(|value| value.to_str()) {
        aliases.insert(name.to_ascii_lowercase());
    }
    aliases.insert(strip_md_suffix(workspace_path).to_ascii_lowercase());
    aliases.insert(strip_md_suffix(vault_path).to_ascii_lowercase());
    for key in ["aliases", "alias"] {
        match metadata.get(key) {
            Some(MetaValue::String(value)) if !value.trim().is_empty() => {
                aliases.insert(value.to_ascii_lowercase());
            }
            Some(MetaValue::List(values)) => {
                aliases.extend(
                    values
                        .iter()
                        .filter(|value| !value.trim().is_empty())
                        .map(|value| value.to_ascii_lowercase()),
                );
            }
            _ => {}
        }
    }
    if let Some(title) = metadata_string(metadata, "title") {
        aliases.insert(title.to_ascii_lowercase());
    }
    aliases.into_iter().collect()
}

fn body_tags(text: &str) -> Vec<String> {
    let bytes = text.as_bytes();
    let mut tags = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'#' {
            index += 1;
            continue;
        }
        if index > 0 {
            let previous = bytes[index - 1] as char;
            if previous.is_ascii_alphanumeric() || previous == '_' || previous == '/' {
                index += 1;
                continue;
            }
        }
        let start = index + 1;
        let mut end = start;
        while end < bytes.len() {
            let value = bytes[end] as char;
            if value.is_ascii_alphanumeric() || value == '_' || value == '-' || value == '/' {
                end += 1;
            } else {
                break;
            }
        }
        if end > start {
            let tag = normalize_tag(&text[start..end]);
            if !is_probable_color_tag(&tag) {
                tags.push(tag);
            }
        }
        index = end.max(index + 1);
    }
    tags
}

fn wiki_links(text: &str) -> Vec<String> {
    static WIKI_LINK_RE: OnceLock<Regex> = OnceLock::new();
    let regex =
        WIKI_LINK_RE.get_or_init(|| Regex::new(r"\[\[([^\]\n]+)\]\]").expect("valid wiki regex"));
    regex
        .captures_iter(text)
        .filter_map(|capture| {
            let whole = capture.get(0)?;
            if whole.start() > 0 && text.as_bytes().get(whole.start() - 1) == Some(&b'!') {
                return None;
            }
            capture.get(1).map(|value| value.as_str().to_string())
        })
        .collect()
}

fn markdown_links(text: &str) -> Vec<(String, String)> {
    static MARKDOWN_LINK_RE: OnceLock<Regex> = OnceLock::new();
    let regex = MARKDOWN_LINK_RE
        .get_or_init(|| Regex::new(r"\[([^\]\n]+)\]\(([^)\n]+)\)").expect("valid markdown regex"));
    regex
        .captures_iter(text)
        .filter_map(|capture| {
            let whole = capture.get(0)?;
            if whole.start() > 0 && text.as_bytes().get(whole.start() - 1) == Some(&b'!') {
                return None;
            }
            Some((
                capture.get(1)?.as_str().to_string(),
                capture.get(2)?.as_str().to_string(),
            ))
        })
        .collect()
}

fn normalize_wiki_target(raw: &str) -> String {
    raw.split('|')
        .next()
        .unwrap_or_default()
        .split('#')
        .next()
        .unwrap_or_default()
        .trim()
        .strip_suffix(".md")
        .unwrap_or_else(|| {
            raw.split('|')
                .next()
                .unwrap_or_default()
                .split('#')
                .next()
                .unwrap_or_default()
                .trim()
        })
        .to_string()
}

fn normalize_markdown_target(raw: &str) -> Option<String> {
    if raw.starts_with("http://")
        || raw.starts_with("https://")
        || raw.starts_with("mailto:")
        || raw.starts_with('#')
    {
        return None;
    }
    let target = percent_decode(raw.split('#').next().unwrap_or_default().trim());
    if target.is_empty() || !target.ends_with(".md") {
        return None;
    }
    Path::new(&target)
        .file_stem()
        .and_then(|value| value.to_str())
        .map(|value| value.to_string())
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Ok(hex) = u8::from_str_radix(&value[index + 1..index + 3], 16) {
                out.push(hex);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn normalize_tag(tag: &str) -> String {
    tag.trim().trim_start_matches('#').replace(' ', "-")
}

fn is_probable_color_tag(tag: &str) -> bool {
    static COLOR_RE: OnceLock<Regex> = OnceLock::new();
    let regex = COLOR_RE
        .get_or_init(|| Regex::new(r"^[0-9a-fA-F]{3}([0-9a-fA-F]{3})?([0-9a-fA-F]{2})?$").unwrap());
    regex.is_match(tag.trim())
}

fn sorted_unique(mut values: Vec<String>) -> Vec<String> {
    values.sort();
    values.dedup();
    values
}

fn slugify(value: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for character in value.trim().to_ascii_lowercase().chars() {
        let mapped =
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-' | '/') {
                character
            } else if character.is_ascii_whitespace() {
                '-'
            } else {
                '-'
            };
        if mapped == '-' {
            if !last_dash {
                out.push(mapped);
            }
            last_dash = true;
        } else {
            out.push(mapped);
            last_dash = false;
        }
    }
    let trimmed = out.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "node".to_string()
    } else {
        trimmed
    }
}

fn strip_md_suffix(value: &str) -> &str {
    value.strip_suffix(".md").unwrap_or(value)
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_string()
}

fn node_sort_key(left: &GraphNode, right: &GraphNode) -> std::cmp::Ordering {
    let left_non_note = left.node_type != "note";
    let right_non_note = right.node_type != "note";
    (left_non_note, &left.title).cmp(&(right_non_note, &right.title))
}

fn relative_to(path: &Path, root: &Path) -> Result<String> {
    Ok(path
        .canonicalize()?
        .strip_prefix(root.canonicalize()?)?
        .to_string_lossy()
        .replace(std::path::MAIN_SEPARATOR, "/")
        .if_empty("."))
}

trait EmptyLabel {
    fn if_empty(self, fallback: &str) -> String;
}

impl EmptyLabel for String {
    fn if_empty(self, fallback: &str) -> String {
        if self.is_empty() {
            fallback.to_string()
        } else {
            self
        }
    }
}

fn resolve_config_path(root: &Path, config_path: Option<&Path>) -> Result<PathBuf> {
    let candidate = match config_path {
        Some(path) if path.is_absolute() => lexical_normalize(path),
        Some(path) => lexical_normalize(&root.join(path)),
        None => root.join(".harvis/knowledge_graph.toml"),
    };
    if !candidate.starts_with(root) {
        bail!(
            "config path is outside workspace allowlist: {}",
            candidate.display()
        );
    }
    Ok(candidate)
}

fn resolve_under_root(root: &Path, value: &Path) -> Result<PathBuf> {
    let candidate = if value.is_absolute() {
        value.to_path_buf()
    } else {
        root.join(value)
    };
    let resolved = candidate
        .canonicalize()
        .with_context(|| format!("path does not exist: {}", candidate.display()))?;
    if !resolved.starts_with(root) {
        bail!(
            "path is outside workspace allowlist: {}",
            resolved.display()
        );
    }
    Ok(resolved)
}

fn lexical_normalize(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                normalized.pop();
            }
            Component::CurDir => {}
            _ => normalized.push(component.as_os_str()),
        }
    }
    normalized
}

fn string_list(value: Option<&Value>) -> Option<Vec<String>> {
    match value {
        Some(Value::String(value)) => Some(vec![value.clone()]),
        Some(Value::Array(values)) => Some(
            values
                .iter()
                .filter_map(|value| match value {
                    Value::String(item) => Some(item.clone()),
                    _ => None,
                })
                .collect(),
        ),
        _ => None,
    }
}

fn int_value(value: Option<&Value>, default: usize, minimum: usize, maximum: usize) -> usize {
    match value {
        Some(Value::Integer(value)) => (*value).max(minimum as i64).min(maximum as i64) as usize,
        Some(Value::String(value)) => value
            .parse::<usize>()
            .map(|value| value.max(minimum).min(maximum))
            .unwrap_or(default),
        _ => default,
    }
}

fn bool_value(value: Option<&Value>, default: bool) -> bool {
    match value {
        Some(Value::Boolean(value)) => *value,
        Some(Value::String(value)) => match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => true,
            "0" | "false" | "no" | "off" => false,
            _ => default,
        },
        _ => default,
    }
}

trait PathExpand {
    fn expanduser(&self) -> PathBuf;
}

impl PathExpand for PathBuf {
    fn expanduser(&self) -> PathBuf {
        expanduser(self)
    }
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

    #[test]
    fn scans_fixture_graph_without_absolute_paths() {
        let root =
            std::env::temp_dir().join(format!("harvis-graph-rust-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join(".harvis")).expect("create harvis dir");
        fs::write(
            root.join(".harvis/knowledge_graph.toml"),
            r#"[graph]
vaults = ["."]
include_paths = false
include_missing_targets = true
"#,
        )
        .expect("write config");
        fs::write(
            root.join("Index.md"),
            r#"---
title: Fixture Index
tags: [harvis, rust]
aliases: [Home]
---

# Fixture Index

[[Second Note]] and [Second](Second%20Note.md)

#harvis #2563EB
"#,
        )
        .expect("write index");
        fs::write(
            root.join("Second Note.md"),
            "# Second Note\n\n[[Index]]\n#fixture\n",
        )
        .expect("write second");

        let graph = scan_knowledge_graph(KnowledgeGraphOptions {
            root: root.clone(),
            config_path: None,
            vault_override: None,
            include_paths_override: None,
            max_files_override: Some(50),
            max_nodes_override: Some(100),
        })
        .expect("scan graph");

        assert_eq!(graph.graph_version, "v0.32-alpha");
        assert!(graph.redacted);
        assert!(!graph.includes_local_absolute_paths);
        assert_eq!(graph.workspace_root, None);
        assert_eq!(graph.stats.note_count, 2);
        assert!(graph.nodes.iter().all(|node| node.workspace_path.is_none()));
        assert!(graph.edges.iter().any(|edge| edge.edge_type == "wiki"));
        assert!(graph.edges.iter().any(|edge| edge.edge_type == "markdown"));
        assert!(graph.nodes.iter().any(|node| node.id == "tag:harvis"));
        assert!(!graph.nodes.iter().any(|node| node.id == "tag:2563eb"));

        let _ = fs::remove_dir_all(root);
    }
}
