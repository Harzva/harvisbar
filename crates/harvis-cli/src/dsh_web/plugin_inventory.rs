//! Read-only declaration inventory. Never boots DSH, imports plugin code,
//! evaluates !!js, or serializes a configuration value. This is deliberately
//! not an effective Loader projection: later patches, includes and conditions
//! can change activation. See docs/dsh-profile-inventory.md.
use super::{safe_manifest_spec, PluginItem};
use serde::Serialize;
use serde_json::Value;
use serde_yaml_ng::Value as Yaml;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PluginDetail {
    origin: String,
    origin_evidence: String,
    installed_version: Option<String>,
    installation: String,
    package_type: String,
    description: Option<String>,
    repository: Option<String>,
    declared_in: Vec<String>,
    declarations: Vec<String>,
    client_contribution: bool,
}

#[derive(Default)]
struct Reference {
    sources: BTreeSet<String>,
    states: BTreeSet<String>,
    anchors: Vec<PathBuf>,
    bundle: bool,
}

fn package_name(value: &str) -> Option<String> {
    let parts: Vec<_> = value.split('/').collect();
    let count = if value.starts_with('@') { 2 } else { 1 };
    if parts.len() < count
        || parts[..count]
            .iter()
            .any(|s| s.is_empty() || *s == "." || *s == "..")
    {
        return None;
    }
    let name = parts[..count].join("/");
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "@/._-".contains(c))
    {
        return None;
    }
    Some(name)
}

fn manifest(path: &Path) -> Option<Value> {
    let meta = fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > 2_000_000 {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn resolve(name: &str, anchors: &[PathBuf]) -> Option<(PathBuf, Value)> {
    for anchor in anchors {
        // Canonical package ancestors include pnpm's own node_modules siblings.
        for root in anchor.ancestors() {
            let p = root.join("node_modules").join(name);
            if let Some(m) = manifest(&p.join("package.json")) {
                if m.get("name").and_then(Value::as_str) == Some(name) {
                    return Some((fs::canonicalize(&p).unwrap_or(p), m));
                }
            }
        }
    }
    None
}

fn repository(m: &Value) -> Option<String> {
    let r = m.get("repository")?;
    let raw = r.as_str().or_else(|| r.get("url")?.as_str())?;
    let raw = raw.strip_prefix("git+").unwrap_or(raw);
    // Expose a source URL only, never userinfo, query strings or arbitrary schemes.
    if !raw.starts_with("https://") || raw.contains(['?', '#', '\\']) || raw[8..].contains('@') {
        return None;
    }
    Some(raw.trim_end_matches(".git").chars().take(300).collect())
}

fn origin(name: &str, spec: &str, repo: Option<&str>) -> (&'static str, &'static str) {
    let local = ["file:", "link:", "workspace:", "/", "."]
        .iter()
        .any(|p| spec.starts_with(p));
    if name.starts_with("@deepseek-ai/") {
        if local {
            return ("unknown", "官方命名空间的本地来源；未验证与官方发行包一致");
        }
        if repo == Some("https://github.com/deepseek-ai/deepseek-harness") {
            return (
                "official",
                "包名属于 @deepseek-ai，仓库元数据指向官方 DSH；非签名认证",
            );
        }
        return ("unknown", "官方命名空间，缺少可核对的官方仓库元数据");
    }
    if name.starts_with('@') || repo.is_some() {
        (
            "third-party",
            "非 DeepSeek 官方命名空间或仓库；来源依据为本地包元数据",
        )
    } else {
        (
            "unknown",
            "未提供可识别的发布者或仓库；不能仅凭名称确认来源",
        )
    }
}

fn add_reference(
    refs: &mut BTreeMap<String, Reference>,
    name: &str,
    source: &str,
    state: &str,
    anchor: &Path,
) {
    let Some(name) = package_name(name) else {
        return;
    };
    let item = refs.entry(name).or_default();
    item.sources.insert(source.into());
    item.states.insert(state.into());
    item.anchors.push(anchor.into());
}

fn rows(
    value: &Yaml,
    source: &str,
    anchor: &Path,
    refs: &mut BTreeMap<String, Reference>,
    warnings: &mut BTreeSet<String>,
    depth: usize,
) {
    if depth > 24 {
        warnings.insert("配置嵌套超过读取上限，清单不完整".into());
        return;
    }
    let Some(items) = value.as_sequence() else {
        return;
    };
    if items.len() > 4096 {
        warnings.insert("配置条目超过读取上限，清单不完整".into());
    }
    for item in items.iter().take(4096) {
        if let Some(insert) = item.get("insert") {
            rows(insert, source, anchor, refs, warnings, depth + 1);
        }
        if let Some(name) = item.get("name").and_then(Yaml::as_str) {
            if package_name(name).is_none() {
                warnings.insert("存在本地文件或特殊加载条目，未解析为 npm 插件包".into());
            }
            let state = match item.get("disabled") {
                Some(Yaml::Bool(true)) => "disabled-declaration",
                Some(Yaml::Bool(false) | Yaml::Null) | None => "reference",
                _ => "conditional-declaration",
            };
            add_reference(refs, name, source, state, anchor);
            if name.contains("plugin-include") {
                warnings.insert("存在 include：外部配置未展开，清单不保证覆盖其内部插件".into());
            }
        }
        if item.get("group").and_then(Yaml::as_bool) == Some(true) {
            if let Some(config) = item.get("config") {
                rows(config, source, anchor, refs, warnings, depth + 1);
            }
        }
    }
}

fn read_rows(
    file: &Path,
    source: &str,
    anchor: &Path,
    refs: &mut BTreeMap<String, Reference>,
    warnings: &mut BTreeSet<String>,
) {
    let Some(meta) = fs::metadata(file).ok() else {
        warnings.insert(format!("{source}：配置文件不可读取"));
        return;
    };
    if !meta.is_file() || meta.len() > 2_000_000 {
        warnings.insert(format!("{source}：配置超过读取限制"));
        return;
    }
    let parsed = fs::read(file)
        .ok()
        .and_then(|bytes| serde_yaml_ng::from_slice::<Yaml>(&bytes).ok());
    if let Some(value) = parsed.filter(|v| v.is_sequence()) {
        rows(&value, source, anchor, refs, warnings, 0);
    } else {
        // Parse errors may contain configuration values. Do not return the raw error.
        warnings.insert(format!("{source}：无法解析插件声明；未读取执行状态"));
    }
}

pub(super) fn scan(
    home: &Path,
    profile: &Path,
    specs: &BTreeMap<String, String>,
    bundles: &[Value],
) -> (Vec<PluginItem>, Vec<String>) {
    let mut refs: BTreeMap<String, Reference> = BTreeMap::new();
    let mut warnings = BTreeSet::new();
    if bundles.len() > 256 {
        warnings.insert("组合包超过读取上限，清单不完整".into());
    }
    for name in specs.keys() {
        add_reference(&mut refs, name, "Profile 依赖", "dependency", profile);
    }
    for bundle in bundles.iter().filter_map(Value::as_str).take(256) {
        add_reference(&mut refs, bundle, "Profile 组合", "bundle", profile);
        if let Some(item) = refs.get_mut(bundle) {
            item.bundle = true;
        }
        if let Some((dir, m)) = resolve(bundle, &[profile.into()]) {
            if let Some(patch) = m.pointer("/dsh/bundle/patch").and_then(Value::as_str) {
                let path = dir.join(patch);
                // A bundle's declared patch must stay inside its package.
                if fs::canonicalize(&path)
                    .ok()
                    .is_some_and(|p| p.starts_with(&dir))
                {
                    read_rows(&path, bundle, &dir, &mut refs, &mut warnings);
                } else {
                    warnings.insert(format!("{bundle}：组合文件缺失或越出包目录"));
                }
            } else {
                warnings.insert(format!("{bundle}：未找到 dsh.bundle.patch"));
            }
        } else {
            warnings.insert(format!("{bundle}：未解析到已安装包"));
        }
    }
    for (file, label) in [
        (profile.join("cordis.yml"), "Profile 根配置"),
        (profile.join("cordis.patch.yml"), "Profile 补丁"),
        (home.join("cordis.patch.yml"), "HOME 共享补丁"),
    ] {
        if file.exists() {
            read_rows(&file, label, profile, &mut refs, &mut warnings);
        }
    }
    let plugins = refs
        .into_iter()
        .map(|(name, r)| {
            let mut anchors = vec![profile.into()];
            anchors.extend(r.anchors);
            let resolved = resolve(&name, &anchors);
            let m = resolved.as_ref().map(|(_, m)| m);
            let spec = specs.get(&name).map(String::as_str).unwrap_or("");
            let repo = m.and_then(repository);
            let (origin, evidence) = origin(&name, spec, repo.as_deref());
            let declared = r.states.iter().any(|s| s != "dependency");
            let package_type = if r.bundle {
                "bundle"
            } else if declared || m.is_some_and(|m| m.get("dsh").is_some()) {
                "plugin"
            } else {
                "dependency"
            };
            PluginItem {
                name,
                spec: if spec.is_empty() {
                    "由组合或配置引用".into()
                } else {
                    safe_manifest_spec(spec)
                },
                kind: if origin == "official" {
                    "core"
                } else {
                    "custom"
                },
                detail: PluginDetail {
                    origin: origin.into(),
                    origin_evidence: evidence.into(),
                    installed_version: m
                        .and_then(|m| m.get("version")?.as_str())
                        .map(|s| s.chars().take(120).collect()),
                    installation: if m.is_some() {
                        "resolved"
                    } else {
                        "unresolved"
                    }
                    .into(),
                    package_type: package_type.into(),
                    description: m
                        .and_then(|m| m.get("description")?.as_str())
                        .map(|s| safe_manifest_spec(&s.chars().take(500).collect::<String>())),
                    repository: repo,
                    declared_in: r.sources.into_iter().collect(),
                    declarations: r.states.into_iter().collect(),
                    client_contribution: m.is_some_and(|m| {
                        m.pointer("/dsh/client")
                            .is_some_and(|v| !v.is_null() && v != &Value::Bool(false))
                    }),
                },
            }
        })
        .collect();
    (plugins, warnings.into_iter().collect())
}

/// Offline file declarations, deliberately not the effective live preset roster.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PresetPreview {
    id: String,
    name: String,
    source: String,
    plugins: Vec<String>,
    conditional_plugins: Vec<String>,
    warnings: Vec<String>,
}

pub(super) fn preset_previews(home: &Path, runtime: Option<&Path>) -> Vec<PresetPreview> {
    let mut roots = vec![(home.join(".agent-presets"), "HOME 本地")];
    if let Some(runtime) = runtime {
        roots.push((runtime.join("config/agent-presets"), "程序自带"));
    }
    let mut result = Vec::new();
    for (root, source) in roots {
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        let mut paths: Vec<_> = entries
            .filter_map(Result::ok)
            .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
            .map(|e| e.path())
            .collect();
        paths.sort();
        let truncated = paths.len() > 128;
        for path in paths.into_iter().take(128) {
            let name = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            if name.len() > 128
                || !name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_-".contains(c))
            {
                continue;
            }
            let mut refs = BTreeMap::new();
            let mut warnings = BTreeSet::new();
            read_rows(
                &path.join("agent.cordis.yml"),
                "Preset 声明",
                &path,
                &mut refs,
                &mut warnings,
            );
            if truncated {
                warnings.insert("此根目录超过 128 项，预览已截断".into());
            }
            let conditional_plugins = refs
                .iter()
                .filter(|(_, r)| {
                    r.states.contains("conditional-declaration")
                        || r.states.contains("disabled-declaration")
                })
                .map(|(name, _)| name.clone())
                .collect();
            result.push(PresetPreview {
                id: format!("{source}:{name}"),
                name,
                source: source.into(),
                plugins: refs.into_keys().collect(),
                conditional_plugins,
                warnings: warnings.into_iter().collect(),
            });
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preset_preview_separates_sources_and_never_outputs_config_values() {
        let root =
            std::env::temp_dir().join(format!("harvis-preset-preview-{}", std::process::id()));
        let runtime = root.join("runtime");
        let user = root.join(".agent-presets/demo");
        let shipped = runtime.join("config/agent-presets/demo");
        fs::create_dir_all(&user).unwrap();
        fs::create_dir_all(&shipped).unwrap();
        fs::write(user.join("agent.cordis.yml"), "- name: '@vendor/tool'\n  disabled: !!js true\n  config:\n    token: DO_NOT_EXPOSE_PREVIEW\n").unwrap();
        fs::write(shipped.join("agent.cordis.yml"), "- name: '@vendor/core'\n").unwrap();
        let previews = preset_previews(&root, Some(&runtime));
        assert_eq!(previews.len(), 2);
        assert_ne!(previews[0].id, previews[1].id);
        assert_eq!(previews[0].conditional_plugins, vec!["@vendor/tool"]);
        let encoded = serde_json::to_string(&previews).unwrap();
        assert!(!encoded.contains("DO_NOT_EXPOSE_PREVIEW"));
        fs::write(
            user.join("agent.cordis.yml"),
            "invalid: [SECRET_PARSE_FRAGMENT",
        )
        .unwrap();
        let previews = preset_previews(&root, Some(&runtime));
        assert!(!previews[0].warnings.is_empty());
        assert!(!serde_json::to_string(&previews)
            .unwrap()
            .contains("SECRET_PARSE_FRAGMENT"));
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn scope_is_not_proof_of_official_distribution() {
        let repo = Some("https://github.com/deepseek-ai/deepseek-harness");
        assert_eq!(origin("@deepseek-ai/dsh-base", "1.0", repo).0, "official");
        assert_eq!(
            origin("@deepseek-ai/dsh-base", "file:local", repo).0,
            "unknown"
        );
        assert_eq!(origin("@deepseek-ai/dsh-base", "1.0", None).0, "unknown");
        assert_eq!(origin("@vendor/plugin", "1.0", None).0, "third-party");
        assert_eq!(origin("mystery", "1.0", None).0, "unknown");
    }
    #[test]
    fn config_data_and_expressions_never_become_plugin_rows() {
        let yaml: Yaml = serde_yaml_ng::from_str("- insert:\n  - id: x\n    name: '@vendor/a'\n    config:\n      name: secret-value\n      key: !!js process.env.SECRET\n  - name: '@vendor/b'\n    disabled: true\n  - group: true\n    config:\n    - name: '@vendor/c'\n      disabled: !!js true\n").unwrap();
        let mut refs = BTreeMap::new();
        let mut warnings = BTreeSet::new();
        rows(
            &yaml,
            "test",
            Path::new("/tmp"),
            &mut refs,
            &mut warnings,
            0,
        );
        assert_eq!(refs.len(), 3);
        assert!(refs["@vendor/b"].states.contains("disabled-declaration"));
        assert!(refs["@vendor/c"].states.contains("conditional-declaration"));
        assert!(!refs.contains_key("secret-value"));
    }
    #[test]
    fn inventory_expands_bundles_resolves_shared_packages_and_reports_missing() {
        let root = std::env::temp_dir().join(format!("harvis-inventory-{}", std::process::id()));
        let profile = root.join("profiles/web");
        let bundle = root.join("profiles/node_modules/@deepseek-ai/dsh-base");
        fs::create_dir_all(&profile).unwrap();
        fs::create_dir_all(&bundle).unwrap();
        fs::write(bundle.join("package.json"), r#"{"name":"@deepseek-ai/dsh-base","version":"1.2.3","repository":"https://github.com/deepseek-ai/deepseek-harness.git","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#).unwrap();
        fs::write(
            bundle.join("cordis.patch.yml"),
            "- insert:\n  - name: '@vendor/missing'\n    config:\n      password: DO_NOT_EXPOSE\n",
        )
        .unwrap();
        let (plugins, warnings) = scan(
            &root,
            &profile,
            &BTreeMap::from([("plain-library".into(), "^2".into())]),
            &[Value::String("@deepseek-ai/dsh-base".into())],
        );
        assert!(warnings.is_empty());
        assert_eq!(plugins.len(), 3);
        let base = plugins
            .iter()
            .find(|p| p.name == "@deepseek-ai/dsh-base")
            .unwrap();
        assert_eq!(base.detail.installed_version.as_deref(), Some("1.2.3"));
        assert_eq!(base.detail.origin, "official");
        assert_eq!(
            plugins
                .iter()
                .find(|p| p.name == "plain-library")
                .unwrap()
                .detail
                .package_type,
            "dependency"
        );
        assert!(!serde_json::to_string(&plugins)
            .unwrap()
            .contains("DO_NOT_EXPOSE"));
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn source_links_reject_credentials_and_spoofed_host() {
        assert!(
            repository(&serde_json::json!({"repository":"https://user:secret@host/repo"}))
                .is_none()
        );
        assert!(
            repository(&serde_json::json!({"repository":"https://host/repo?token=secret"}))
                .is_none()
        );
        assert_eq!(
            origin(
                "@deepseek-ai/dsh-a",
                "1",
                Some("https://github.com/deepseek-ai/deepseek-harness.evil")
            )
            .0,
            "unknown"
        );
        assert!(package_name("../../auth.json").is_none());
    }
}
