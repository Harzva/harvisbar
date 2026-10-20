mod plugin_inventory;
mod process_identity;

use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::process::CommandExt;

const CATALOG_SCHEMA: &str = "harvis.dsh-catalog.v1";
const STATUS_SCHEMA: &str = "harvis.dsh-web.v1";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PluginItem {
    name: String,
    spec: String,
    kind: &'static str,
    #[serde(flatten)]
    detail: plugin_inventory::PluginDetail,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProfileItem {
    id: String,
    name: String,
    path: String,
    mode: String,
    launchable: bool,
    launch_command: Option<String>,
    plugin_count: usize,
    custom_plugin_count: usize,
    plugins: Vec<PluginItem>,
    inventory_warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct RunningProfile {
    profile: String,
    pid: u32,
    ports: Vec<u16>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct HomeItem {
    id: String,
    label: String,
    path: String,
    version: Option<String>,
    runtime_path: Option<String>,
    executable: Option<String>,
    status: &'static str,
    default_profile: Option<String>,
    profile_count: usize,
    plugin_count: usize,
    custom_plugin_count: usize,
    profiles: Vec<ProfileItem>,
    running_profiles: Vec<RunningProfile>,
    preset_previews: Vec<plugin_inventory::PresetPreview>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeItem {
    id: String,
    version: String,
    path: String,
    executable: String,
    source: &'static str,
    launchable: bool,
    linked_home_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusItem {
    pid: u32,
    command: String,
    cwd: String,
    home: String,
    profile: String,
    ports: Vec<u16>,
    runtime_path: Option<String>,
    version: Option<String>,
}

/// The part of a DSH Home identity that can be discovered without opening
/// runtime or Profile manifests.  The lightweight `running` command uses
/// these roots so a broken or slow external runtime cannot stall discovery.
#[derive(Debug, Clone)]
struct HomeRoot {
    id: String,
    path: PathBuf,
    runtime_executables: Vec<PathBuf>,
    runtime_path: Option<String>,
    version: Option<String>,
}

impl HomeRoot {
    fn new(path: PathBuf) -> Self {
        let id = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .trim_start_matches('.')
            .to_string();
        let runtime_executables = runtime_executable_paths(&path);
        Self {
            id,
            path,
            runtime_executables,
            runtime_path: None,
            version: None,
        }
    }

    fn from_home(home: &HomeItem) -> Self {
        let mut root = Self::new(PathBuf::from(&home.path));
        root.runtime_path = home.runtime_path.clone();
        root.version = home.version.clone();
        root
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, PartialOrd, Ord)]
struct RunningEndpoint {
    #[serde(rename = "homeID")]
    home_id: String,
    profile: String,
    port: u16,
}

pub fn catalog() -> Result<Value> {
    let mut homes = discover_homes()?;
    let status = discover_running(&homes);
    for home in &mut homes {
        home.running_profiles = status
            .iter()
            .filter(|item| item.home == home.path)
            .map(|item| RunningProfile {
                profile: item.profile.clone(),
                pid: item.pid,
                ports: item.ports.clone(),
            })
            .collect();
    }
    let runtimes = runtime_items(&homes);
    Ok(json!({
        "ok": true,
        "schemaVersion": CATALOG_SCHEMA,
        "homeCount": homes.len(),
        "runtimeCount": runtimes.len(),
        "homes": homes,
        "runtimes": runtimes,
        "warnings": [],
        "includesSecrets": false,
    }))
}

pub fn status() -> Result<Value> {
    let homes = discover_homes()?;
    let items = discover_running(&homes);
    Ok(json!({
        "ok": true,
        "schemaVersion": STATUS_SCHEMA,
        "running": !items.is_empty(),
        "count": items.len(),
        "items": items,
        "includesSecrets": false,
    }))
}

/// Return only active DSH endpoints.  This deliberately discovers Home roots
/// and running process metadata, but never reads runtime or Profile manifests.
pub fn running() -> Result<Value> {
    let (_, roots) = discover_home_roots()?;
    let items = discover_running_from_roots(&roots, true, false);
    let endpoints = running_endpoints(&roots, &items);
    Ok(json!({
        "ok": true,
        "includesSecrets": false,
        "endpoints": endpoints,
    }))
}

pub fn start(home: &Path, profile: &str, port: u16) -> Result<Value> {
    validate_profile_name(profile)?;
    let homes = discover_homes()?;
    let requested = fs::canonicalize(home).context("the requested DSH home is unavailable")?;
    let selected = homes
        .iter()
        .find(|item| fs::canonicalize(&item.path).ok().as_ref() == Some(&requested))
        .ok_or_else(|| {
            anyhow::anyhow!("the requested DSH home is not in the discovered runtime catalog")
        })?;
    let selected_profile = selected
        .profiles
        .iter()
        .find(|item| item.name == profile)
        .ok_or_else(|| {
            anyhow::anyhow!("the requested Profile is not registered under this DSH home")
        })?;
    if !selected_profile.launchable {
        bail!("the requested Profile is not a detected Web runtime");
    }
    let executable = selected
        .executable
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("this DSH home has no launchable runtime executable"))?;
    if !Path::new(executable).is_file() {
        bail!("the cataloged DSH executable is no longer available");
    }
    let selected_port = if port == 0 { reserve_port()? } else { port };
    let before: BTreeSet<u32> = discover_running(&homes)
        .into_iter()
        .map(|item| item.pid)
        .collect();
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let session = format!(
        "harvis-dsh-{}-{}-{suffix}",
        safe_id(&selected.id),
        safe_id(profile)
    );
    let log_dir = Path::new(&selected.path).join("logs");
    fs::create_dir_all(&log_dir)?;
    let log_path = log_dir.join(format!("{session}.log"));
    let node = managed_node_path();
    let launched_pid = spawn_web_process(
        Path::new(&selected.path),
        executable,
        profile,
        selected_port,
        &log_path,
        node.as_deref(),
    )?
    .id();

    let deadline = Instant::now() + Duration::from_secs(45);
    while Instant::now() < deadline {
        let current = discover_running(&homes);
        if let Some(item) = current.into_iter().find(|item| {
            !before.contains(&item.pid)
                && item.home == selected.path
                && item.profile == profile
                && item.ports.contains(&selected_port)
        }) {
            thread::sleep(Duration::from_millis(1500));
            let stable = discover_running(&homes).into_iter().any(|candidate| {
                candidate.pid == item.pid
                    && candidate.home == selected.path
                    && candidate.profile == profile
                    && candidate.ports.contains(&selected_port)
            });
            if !stable {
                continue;
            }
            return Ok(json!({
                "ok": true,
                "action": "start",
                "homeId": selected.id,
                "home": selected.path,
                "version": selected.version,
                "profile": profile,
                "pid": item.pid,
                "port": selected_port,
                "url": format!("http://127.0.0.1:{selected_port}/"),
                "tmuxSession": session,
                "runtime": selected.runtime_path,
                "includesSecrets": false,
            }));
        }
        thread::sleep(Duration::from_millis(250));
    }
    let _ = Command::new("/bin/kill")
        .args(["-TERM", &launched_pid.to_string()])
        .status();
    bail!("DSH Profile did not become discoverable before timeout")
}

fn spawn_web_process(
    home: &Path,
    executable: &str,
    profile: &str,
    port: u16,
    log_path: &Path,
    node: Option<&Path>,
) -> Result<Child> {
    let stdout = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    let stderr = stdout.try_clone()?;
    let mut launch = Command::new("/usr/bin/nohup");
    launch.arg("/usr/bin/env");
    launch.arg(format!("DSH_HOME={}", home.display()));
    if let Some(node) = node {
        launch.arg(node).arg(executable);
    } else {
        launch.arg(executable);
    }
    // `nohup` only ignores SIGHUP; it does not detach from the bounded
    // caller's process group. Keep the long-lived Web Profile in a fresh
    // PGID so the caller can reap its own group without killing the server.
    #[cfg(unix)]
    launch.process_group(0);
    launch
        .args(["--profile", profile, "--host", "127.0.0.1", "--port"])
        .arg(port.to_string())
        .arg("--no-open")
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .spawn()
        .context("could not start the selected DSH Profile")
}

pub fn restart(port: Option<u16>) -> Result<Value> {
    let homes = discover_homes()?;
    let mut targets = discover_running(&homes);
    if let Some(port) = port {
        targets.retain(|item| item.ports.contains(&port));
        if targets.is_empty() {
            bail!("no running DSH profile instance matched the requested port");
        }
    }
    let mut restarted = Vec::new();
    for item in targets {
        let restart_port = item
            .ports
            .first()
            .copied()
            .ok_or_else(|| anyhow::anyhow!("running DSH profile has no listening port"))?;
        let stopped = Command::new("/bin/kill")
            .args(["-TERM", &item.pid.to_string()])
            .status()?;
        if !stopped.success() {
            bail!("failed to stop dsh web pid {}", item.pid);
        }
        let deadline = Instant::now() + Duration::from_secs(15);
        while process_exists(item.pid) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(200));
        }
        if process_exists(item.pid) {
            bail!("dsh web pid {} did not stop after SIGTERM", item.pid);
        }
        restarted.push(start(Path::new(&item.home), &item.profile, restart_port)?);
    }
    Ok(
        json!({"ok": true, "action": "restart", "count": restarted.len(), "items": restarted, "includesSecrets": false}),
    )
}

fn discover_homes() -> Result<Vec<HomeItem>> {
    let (home_root, roots) = discover_home_roots()?;
    let mut homes = Vec::new();
    for root in roots {
        if let Some(home) = read_home(&home_root, &root.path)? {
            homes.push(home);
        }
    }
    homes.sort_by_key(|item| (item.id != "dsh", item.label.clone()));
    Ok(homes)
}

/// Discover only the Home roots needed to associate a running process with a
/// stable Home ID.  In particular, this must not call `read_home`,
/// `resolve_runtime`, or inspect any package.json file.
fn discover_home_roots() -> Result<(PathBuf, Vec<HomeRoot>)> {
    let home_root = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow::anyhow!("HOME is unavailable for local DSH catalog discovery"))?;
    let mut paths = Vec::new();
    for entry in fs::read_dir(&home_root)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if (name == ".dsh" || name.starts_with(".dsh-")) && entry.path().join("profiles").is_dir() {
            paths.push(entry.path());
        }
    }
    paths.sort();
    Ok((home_root, paths.into_iter().map(HomeRoot::new).collect()))
}

fn read_home(home_root: &Path, path: &Path) -> Result<Option<HomeItem>> {
    let id = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .trim_start_matches('.')
        .to_string();
    let profiles_root = path.join("profiles");
    let (runtime_path, executable, version) = resolve_runtime(path);
    let mut profiles = Vec::new();
    for entry in fs::read_dir(&profiles_root)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() || !entry.path().join("package.json").is_file() {
            continue;
        }
        if let Some(profile) =
            read_profile(home_root, &id, path, &entry.path(), executable.as_deref())?
        {
            profiles.push(profile);
        }
    }
    profiles.sort_by_key(|item| (item.name != "web", item.name.clone()));
    if profiles.is_empty() {
        return Ok(None);
    }
    let plugin_count = profiles.iter().map(|item| item.plugin_count).sum();
    let custom_plugin_count = profiles.iter().map(|item| item.custom_plugin_count).sum();
    let preset_previews =
        plugin_inventory::preset_previews(path, runtime_path.as_deref().map(Path::new));
    Ok(Some(HomeItem {
        id: id.clone(),
        label: home_label(&id),
        path: path.display().to_string(),
        version,
        runtime_path,
        executable,
        status: if profiles.iter().any(|item| item.launchable) {
            "ready"
        } else {
            "degraded"
        },
        default_profile: profiles
            .iter()
            .find(|item| item.name == "web" && item.launchable)
            .map(|item| item.name.clone())
            .or_else(|| {
                profiles
                    .iter()
                    .find(|item| item.launchable)
                    .map(|item| item.name.clone())
            }),
        profile_count: profiles.len(),
        plugin_count,
        custom_plugin_count,
        profiles,
        running_profiles: Vec::new(),
        preset_previews,
    }))
}

fn read_profile(
    home_root: &Path,
    home_id: &str,
    home: &Path,
    path: &Path,
    executable: Option<&str>,
) -> Result<Option<ProfileItem>> {
    let manifest: Value = serde_json::from_slice(&fs::read(path.join("package.json"))?)?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_string();
    validate_profile_name(&name)?;
    let mut specs = BTreeMap::new();
    for key in ["dependencies", "optionalDependencies"] {
        if let Some(values) = manifest.get(key).and_then(Value::as_object) {
            for (name, spec) in values {
                if let Some(spec) = spec.as_str() {
                    specs.insert(name.clone(), spec.to_string());
                }
            }
        }
    }
    let bundles = manifest
        .pointer("/dsh/profile/bundles")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let (plugins, inventory_warnings) = plugin_inventory::scan(home, path, &specs, &bundles);
    let has_web = plugins
        .iter()
        .any(|item| item.name == "@deepseek-ai/dsh-web-app");
    let has_headless = plugins
        .iter()
        .any(|item| item.name == "@deepseek-ai/dsh-headless");
    let mode = if name == "desktop" {
        "desktop"
    } else if has_web {
        "web"
    } else if has_headless {
        "headless"
    } else if name == "tui" {
        "tui"
    } else {
        "custom"
    };
    let launchable = has_web && executable.is_some();
    let shown_path = path
        .strip_prefix(home_root)
        .map(|relative| format!("~/{}", relative.display()))
        .unwrap_or_else(|_| path.display().to_string());
    let launch_command = executable.filter(|_| launchable).map(|executable| {
        format!(
            "DSH_HOME='{}' '{}' --profile '{}' --port 0 --no-open",
            home.display(),
            executable,
            name
        )
    });
    let custom_plugin_count = plugins.iter().filter(|item| item.kind == "custom").count();
    Ok(Some(ProfileItem {
        id: format!("{home_id}.{name}"),
        name,
        path: shown_path,
        mode: mode.to_string(),
        launchable,
        launch_command,
        plugin_count: plugins.len(),
        custom_plugin_count,
        plugins,
        inventory_warnings,
    }))
}

fn resolve_runtime(home: &Path) -> (Option<String>, Option<String>, Option<String>) {
    let candidates = [
        home.join("profiles/node_modules/@deepseek-ai/dsh"),
        home.join("prefix/node_modules/@deepseek-ai/dsh"),
        home.join("node_modules/@deepseek-ai/dsh"),
        home.join("dsh-app-rc6"),
    ];
    for visible in candidates {
        let manifest_path = visible.join("package.json");
        let executable = visible.join("lib/bin.js");
        if !manifest_path.is_file() || !executable.is_file() {
            continue;
        }
        let manifest: Value = serde_json::from_slice(&fs::read(&manifest_path).unwrap_or_default())
            .unwrap_or(Value::Null);
        let version = manifest
            .get("version")
            .and_then(Value::as_str)
            .map(str::to_string);
        let runtime = fs::canonicalize(&visible).unwrap_or(visible);
        return (
            Some(runtime.display().to_string()),
            Some(executable.display().to_string()),
            version,
        );
    }
    (None, None, None)
}

/// Return executable spellings that may appear in `ps` for a Home.  This only
/// reads directory-entry symlink metadata; it intentionally never follows a
/// runtime directory or opens package.json.
fn runtime_executable_paths(home: &Path) -> Vec<PathBuf> {
    let candidates = [
        home.join("profiles/node_modules/@deepseek-ai/dsh"),
        home.join("prefix/node_modules/@deepseek-ai/dsh"),
        home.join("node_modules/@deepseek-ai/dsh"),
        home.join("dsh-app-rc6"),
    ];
    let mut paths = Vec::new();
    for visible in candidates {
        paths.push(visible.join("lib/bin.js"));
        let Ok(link) = fs::read_link(&visible) else {
            continue;
        };
        let target = if link.is_absolute() {
            link
        } else {
            visible
                .parent()
                .map(|parent| parent.join(link))
                .unwrap_or_else(|| visible.clone())
        };
        let executable = target.join("lib/bin.js");
        if !paths.contains(&executable) {
            paths.push(executable);
        }
    }
    paths
}

fn runtime_items(homes: &[HomeItem]) -> Vec<RuntimeItem> {
    let mut grouped: BTreeMap<String, (String, String, BTreeSet<String>)> = BTreeMap::new();
    for home in homes {
        let (Some(path), Some(executable), Some(version)) =
            (&home.runtime_path, &home.executable, &home.version)
        else {
            continue;
        };
        let entry = grouped
            .entry(path.clone())
            .or_insert_with(|| (version.clone(), executable.clone(), BTreeSet::new()));
        entry.2.insert(home.id.clone());
    }
    grouped
        .into_iter()
        .enumerate()
        .map(
            |(index, (path, (version, executable, home_ids)))| RuntimeItem {
                id: format!("dsh-runtime-{}", index + 1),
                version,
                path,
                executable,
                source: "managed-root",
                launchable: true,
                linked_home_ids: home_ids.into_iter().collect(),
            },
        )
        .collect()
}

fn discover_running(homes: &[HomeItem]) -> Vec<StatusItem> {
    let roots: Vec<HomeRoot> = homes.iter().map(HomeRoot::from_home).collect();
    discover_running_from_roots(&roots, false, true)
}

/// Parse the process listing once and resolve each process to a known Home.
/// `match_runtime_executable` is used by the lightweight command because DSH
/// often resolves a Home's symlink before it appears in `ps`.  The legacy
/// catalog/status paths retain their historical default-Home fallback.
fn discover_running_from_roots(
    roots: &[HomeRoot],
    match_runtime_executable: bool,
    fallback_default_home: bool,
) -> Vec<StatusItem> {
    let output = Command::new("/bin/ps")
        .args(["-axo", "pid=,command="])
        .output();
    let Ok(output) = output else {
        return Vec::new();
    };
    parse_running_processes(
        String::from_utf8_lossy(&output.stdout).lines(),
        roots,
        |pid| listening_ports(pid),
        |pid| process_cwd(pid),
        process_identity::read,
        match_runtime_executable,
        fallback_default_home,
    )
}

fn parse_running_processes<'a, I, P, C, S>(
    lines: I,
    roots: &[HomeRoot],
    mut ports_for_pid: P,
    mut cwd_for_pid: C,
    mut snapshot_for_pid: S,
    match_runtime_executable: bool,
    fallback_default_home: bool,
) -> Vec<StatusItem>
where
    I: IntoIterator<Item = &'a str>,
    P: FnMut(u32) -> Vec<u16>,
    C: FnMut(u32) -> String,
    S: FnMut(u32) -> Option<process_identity::Snapshot>,
{
    let mut items = Vec::new();
    for line in lines {
        let trimmed = line.trim_start();
        let Some((pid_text, command)) = trimmed.split_once(char::is_whitespace) else {
            continue;
        };
        let Ok(pid) = pid_text.parse::<u32>() else {
            continue;
        };
        let command = command.trim();
        // ps is only a cheap candidate filter. Authoritative args and Home come
        // from one bounded native snapshot; inaccessible environments fail closed.
        if !(command.contains("/dsh") || command.contains("/bin.js"))
            || !(command.contains("--profile") || command.contains(" dsh web"))
        {
            continue;
        }
        let Some(snapshot) = snapshot_for_pid(pid) else {
            continue;
        };
        let command = snapshot.command.as_str();
        if !(command.contains("/dsh") || command.contains("/bin.js")) {
            continue;
        }
        let profile = if let Some(value) = argument_after(command, "--profile") {
            value
        } else if command.contains(" dsh web ") || command.ends_with(" dsh web") {
            "web".to_string()
        } else {
            continue;
        };
        let ports = ports_for_pid(pid);
        if ports.is_empty() {
            continue;
        }
        let Some(selected) = select_running_home(
            command,
            roots,
            snapshot.home.as_deref(),
            match_runtime_executable,
            fallback_default_home,
        ) else {
            continue;
        };
        let cwd = cwd_for_pid(pid);
        if snapshot_for_pid(pid).as_ref() != Some(&snapshot) {
            continue;
        }
        items.push(StatusItem {
            pid,
            command: format!("dsh --profile {profile} --port {}", ports[0]),
            cwd,
            home: selected.path.display().to_string(),
            profile,
            ports,
            runtime_path: selected.runtime_path.clone(),
            version: selected.version.clone(),
        });
    }
    items.sort_by_key(|item| item.pid);
    items
}

fn select_running_home<'a>(
    command: &str,
    roots: &'a [HomeRoot],
    explicit_home: Option<&Path>,
    match_runtime_executable: bool,
    fallback_default_home: bool,
) -> Option<&'a HomeRoot> {
    if let Some(home) = explicit_home {
        // An explicit unknown/ambiguous Home must never fall back to runtime or default.
        let canonical = fs::canonicalize(home).ok()?;
        let mut matches = roots
            .iter()
            .filter(|root| fs::canonicalize(&root.path).ok().as_ref() == Some(&canonical));
        let selected = matches.next()?;
        return matches.next().is_none().then_some(selected);
    }
    let path_matches: Vec<&HomeRoot> = roots
        .iter()
        .filter(|root| command_mentions_path(command, &root.path))
        .collect();
    if let Some(root) = path_matches.first().copied() {
        return if fallback_default_home || path_matches.len() == 1 {
            Some(root)
        } else {
            None
        };
    }

    if match_runtime_executable {
        let runtime_matches: Vec<&HomeRoot> = roots
            .iter()
            .filter(|root| {
                root.runtime_executables
                    .iter()
                    .any(|path| command_mentions_path(command, path))
            })
            .collect();
        if runtime_matches.len() == 1 {
            return runtime_matches.first().copied();
        }
    }

    if fallback_default_home {
        roots.iter().find(|root| root.id == "dsh")
    } else {
        None
    }
}

fn command_mentions_path(command: &str, path: &Path) -> bool {
    let expected = path.to_string_lossy();
    if expected.is_empty() {
        return false;
    }
    command.match_indices(expected.as_ref()).any(|(start, _)| {
        let end = start + expected.len();
        let before = command[..start].chars().next_back();
        let after = command[end..].chars().next();
        before.is_none_or(path_boundary) && after.is_none_or(path_boundary)
    })
}

fn path_boundary(value: char) -> bool {
    value.is_whitespace() || matches!(value, '\'' | '"' | '=' | ':' | '/')
}

fn running_endpoints(roots: &[HomeRoot], items: &[StatusItem]) -> Vec<RunningEndpoint> {
    let mut endpoints = BTreeSet::new();
    for item in items {
        let Some(home) = roots
            .iter()
            .find(|root| root.path.display().to_string() == item.home)
        else {
            continue;
        };
        for &port in &item.ports {
            if port == 0 {
                continue;
            }
            endpoints.insert(RunningEndpoint {
                home_id: home.id.clone(),
                profile: item.profile.clone(),
                port,
            });
        }
    }
    endpoints.into_iter().collect()
}

fn listening_ports(pid: u32) -> Vec<u16> {
    let output = Command::new("/usr/sbin/lsof")
        .args([
            "-Pan",
            "-p",
            &pid.to_string(),
            "-iTCP",
            "-sTCP:LISTEN",
            "-Fn",
        ])
        .output();
    let Ok(output) = output else {
        return Vec::new();
    };
    let mut ports = BTreeSet::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if let Some((_, port)) = line
            .strip_prefix('n')
            .and_then(|value| value.rsplit_once(':'))
        {
            if let Ok(port) = port.parse::<u16>() {
                ports.insert(port);
            }
        }
    }
    ports.into_iter().collect()
}

fn process_cwd(pid: u32) -> String {
    let output = Command::new("/usr/sbin/lsof")
        .args(["-a", "-p", &pid.to_string(), "-d", "cwd", "-Fn"])
        .output();
    output
        .ok()
        .and_then(|value| String::from_utf8(value.stdout).ok())
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.strip_prefix('n').map(str::to_string))
        })
        .unwrap_or_default()
}

fn argument_after(command: &str, flag: &str) -> Option<String> {
    let mut tokens = command.split_whitespace();
    while let Some(token) = tokens.next() {
        if token == flag {
            return tokens
                .next()
                .map(|value| value.trim_matches(['\'', '"']).to_string());
        }
    }
    None
}

fn safe_manifest_spec(spec: &str) -> String {
    let lower = spec.to_ascii_lowercase();
    let authority_has_credentials = spec
        .split_once("://")
        .and_then(|(_, suffix)| suffix.split('/').next())
        .is_some_and(|authority| authority.contains('@'));
    if authority_has_credentials
        || ["token=", "password=", "passwd=", "_auth=", "_authToken="]
            .iter()
            .any(|needle| lower.contains(&needle.to_ascii_lowercase()))
    {
        "[REDACTED]".to_string()
    } else {
        spec.to_string()
    }
}

fn reserve_port() -> Result<u16> {
    Ok(TcpListener::bind(("127.0.0.1", 0))?.local_addr()?.port())
}

fn managed_node_path() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("HARVIS_NODE_PATH") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        candidates.push(home.join("Library/Application Support/HarvisBar/Tools/node"));
        candidates.push(home.join("Library/Application Support/HarvisRuntime/bin/node"));
    }
    candidates.extend(
        ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
            .into_iter()
            .map(PathBuf::from),
    );
    candidates.into_iter().find(|path| path.is_file())
}

fn process_exists(pid: u32) -> bool {
    Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .status()
        .is_ok_and(|status| status.success())
}

fn validate_profile_name(profile: &str) -> Result<()> {
    if profile.is_empty()
        || !profile
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        bail!("invalid DSH Profile identifier");
    }
    Ok(())
}

fn safe_id(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' {
                ch
            } else {
                '-'
            }
        })
        .collect()
}

fn home_label(id: &str) -> String {
    match id {
        "dsh" => "Default DSH".to_string(),
        "dsh-rc8-home" => "RC8 Isolated".to_string(),
        "dsh-next" => "Next".to_string(),
        "dsh-dev" => "Development".to_string(),
        "dsh-brandos" => "BrandOS".to_string(),
        "dsh-harvis-meta" => "Harvis Project Brain".to_string(),
        _ => id.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_snapshot(fixture: &str, pid: u32) -> Option<process_identity::Snapshot> {
        let line = fixture
            .lines()
            .find(|line| line.trim().starts_with(&format!("{pid} ")))?;
        Some(process_identity::Snapshot {
            command: line.trim().split_once(' ')?.1.to_string(),
            home: None,
            started: (1, 0),
        })
    }

    #[test]
    fn profile_names_are_strict() {
        assert!(validate_profile_name("digital-me").is_ok());
        assert!(validate_profile_name("../web").is_err());
        assert!(validate_profile_name("web profile").is_err());
    }

    #[test]
    fn profile_argument_is_parsed_without_running_dsh() {
        assert_eq!(
            argument_after("node /tmp/dsh --profile digital-me --port 1", "--profile").as_deref(),
            Some("digital-me")
        );
    }

    #[test]
    fn manifest_specs_do_not_expose_credentials() {
        assert_eq!(
            safe_manifest_spec("https://user:pass@example.test/package.tgz"),
            "[REDACTED]"
        );
        assert_eq!(safe_manifest_spec("^1.2.3"), "^1.2.3");
    }

    #[test]
    fn running_fixture_maps_known_processes_without_profile_metadata() {
        let roots = vec![
            HomeRoot {
                id: "dsh".to_string(),
                path: PathBuf::from("/Users/test/.dsh"),
                runtime_executables: vec![PathBuf::from("/opt/dsh/apps/cli/lib/bin.js")],
                runtime_path: None,
                version: None,
            },
            HomeRoot {
                id: "dsh-next".to_string(),
                path: PathBuf::from("/Users/test/.dsh-next"),
                runtime_executables: vec![PathBuf::from("/opt/dsh-next/lib/bin.js")],
                runtime_path: None,
                version: None,
            },
        ];
        let ps_fixture = concat!(
            " 101 /opt/dsh/apps/cli/lib/bin.js --profile digital-me --no-open\n",
            " 102 /unknown/dsh/lib/bin.js --profile unknown --no-open\n",
            " 103 /opt/dsh/apps/cli/lib/bin.js --profile digital-me --no-open\n",
            " 104 /opt/dsh/apps/cli/lib/bin.js --profile no-port --no-open\n",
        );
        let items = parse_running_processes(
            ps_fixture.lines(),
            &roots,
            |pid| match pid {
                101 => vec![64746, 64747],
                102 => vec![64748],
                103 => vec![64746],
                104 => Vec::new(),
                _ => Vec::new(),
            },
            |_| String::new(),
            |pid| fixture_snapshot(ps_fixture, pid),
            true,
            false,
        );

        let endpoints = running_endpoints(&roots, &items);
        assert_eq!(
            endpoints,
            vec![
                RunningEndpoint {
                    home_id: "dsh".to_string(),
                    profile: "digital-me".to_string(),
                    port: 64746,
                },
                RunningEndpoint {
                    home_id: "dsh".to_string(),
                    profile: "digital-me".to_string(),
                    port: 64747,
                },
            ]
        );
    }

    #[test]
    fn running_home_matching_preserves_boundaries_and_rejects_shared_runtime() {
        let roots = vec![
            HomeRoot {
                id: "dsh".into(),
                path: PathBuf::from("/tmp/user space/.dsh"),
                runtime_executables: vec![PathBuf::from("/opt/shared runtime/lib/bin.js")],
                runtime_path: Some("/opt/shared runtime".into()),
                version: Some("test".into()),
            },
            HomeRoot {
                id: "dsh-next".into(),
                path: PathBuf::from("/tmp/user space/.dsh-next"),
                runtime_executables: vec![PathBuf::from("/opt/shared runtime/lib/bin.js")],
                runtime_path: None,
                version: None,
            },
        ];
        let command = "node /tmp/user space/.dsh-next/profiles/lib/bin.js --profile web";
        assert!(!command_mentions_path(command, &roots[0].path));
        assert_eq!(
            select_running_home(command, &roots, None, true, false)
                .unwrap()
                .id,
            "dsh-next"
        );
        assert!(select_running_home(
            "node /opt/shared runtime/lib/bin.js --profile web",
            &roots,
            None,
            true,
            false
        )
        .is_none());
        let items = parse_running_processes(
            ["101 node /tmp/user space/.dsh/profiles/lib/bin.js --profile web"],
            &roots,
            |_| vec![3080],
            |_| String::new(),
            |pid| {
                fixture_snapshot(
                    "101 node /tmp/user space/.dsh/profiles/lib/bin.js --profile web",
                    pid,
                )
            },
            false,
            true,
        );
        assert_eq!(
            items[0].runtime_path.as_deref(),
            Some("/opt/shared runtime")
        );
        assert_eq!(items[0].version.as_deref(), Some("test"));
    }

    #[test]
    fn explicit_process_home_recovers_external_runtime_and_rejects_unknown_or_ambiguous_home() {
        let base = std::env::temp_dir().join(format!("harvis-process-home-{}", std::process::id()));
        let home = base.join("user space/.dsh");
        fs::create_dir_all(&home).unwrap();
        let roots = vec![HomeRoot::new(home.clone())];
        let command = "node /external/runtime/apps/cli/lib/bin.js --profile digital-me";
        let snapshot = process_identity::Snapshot {
            command: command.into(),
            home: Some(home.clone()),
            started: (1, 0),
        };
        let items = parse_running_processes(
            ["892 node /external/runtime/apps/cli/lib/bin.js --profile digital-me"],
            &roots,
            |_| vec![64746],
            |_| String::new(),
            |_| Some(snapshot.clone()),
            true,
            false,
        );
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].home, home.display().to_string());
        assert_eq!(items[0].profile, "digital-me");
        let matching_runtime = format!("node {}/runtime/lib/bin.js --profile web", home.display());
        fs::create_dir_all(base.join("unknown")).unwrap();
        assert!(select_running_home(
            &matching_runtime,
            &roots,
            Some(&base.join("unknown")),
            true,
            true
        )
        .is_none());
        let aliases = vec![roots[0].clone(), roots[0].clone()];
        assert!(select_running_home(command, &aliases, Some(&home), true, true).is_none());
        // An explicit Home wins over runtime routing, even when another Home owns that runtime.
        let other = base.join(".dsh-other");
        fs::create_dir_all(&other).unwrap();
        let mut other_root = HomeRoot::new(other);
        other_root.runtime_executables =
            vec![PathBuf::from("/external/runtime/apps/cli/lib/bin.js")];
        let all = vec![roots[0].clone(), other_root];
        assert_eq!(
            select_running_home(command, &all, Some(&home), true, false)
                .unwrap()
                .path,
            home
        );
        #[cfg(unix)]
        {
            let alias = base.join("alias");
            std::os::unix::fs::symlink(&home, &alias).unwrap();
            assert_eq!(
                select_running_home(command, &roots, Some(&alias), true, false)
                    .unwrap()
                    .path,
                home
            );
        }
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn candidate_snapshot_failure_or_identity_change_is_rejected() {
        let root = HomeRoot {
            id: "dsh".into(),
            path: PathBuf::from("/tmp/.dsh"),
            runtime_executables: vec![],
            runtime_path: None,
            version: None,
        };
        let fixture = "892 node /tmp/.dsh/lib/bin.js --profile web";
        assert!(parse_running_processes(
            [fixture],
            &[root.clone()],
            |_| vec![64746],
            |_| String::new(),
            |_| None,
            true,
            false
        )
        .is_empty());
        let mut calls = 0;
        assert!(parse_running_processes(
            [fixture],
            &[root],
            |_| vec![64746],
            |_| String::new(),
            |pid| {
                calls += 1;
                let mut snapshot = fixture_snapshot(fixture, pid)?;
                snapshot.started = (calls, 0);
                Some(snapshot)
            },
            true,
            false
        )
        .is_empty());
        assert_eq!(calls, 2);
    }

    #[test]
    fn running_endpoint_serialization_uses_exact_home_id_key() {
        let value = serde_json::to_value(RunningEndpoint {
            home_id: "dsh".to_string(),
            profile: "web".to_string(),
            port: 64746,
        })
        .expect("endpoint serializes");
        assert_eq!(value["homeID"], "dsh");
        assert!(value.get("homeId").is_none());
    }

    #[cfg(unix)]
    #[test]
    fn persistent_web_process_owns_a_separate_process_group() {
        struct Fixture {
            child: Child,
            root: PathBuf,
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = self.child.kill();
                let _ = self.child.wait();
                let _ = fs::remove_dir_all(&self.root);
            }
        }
        fn process_group(pid: u32) -> u32 {
            let output = Command::new("/bin/ps")
                .args(["-o", "pgid=", "-p", &pid.to_string()])
                .output()
                .expect("process group is readable");
            assert!(output.status.success());
            String::from_utf8_lossy(&output.stdout)
                .trim()
                .parse()
                .expect("process group is numeric")
        }

        let root = std::env::temp_dir().join(format!(
            "harvis-dsh-group-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let script = root.join("fixture.sh");
        // The fixture accepts the production arguments but opens no socket and
        // reads no runtime configuration. exec leaves no extra child to clean.
        fs::write(&script, "exec /bin/sleep 30\n").unwrap();
        let child = spawn_web_process(
            &root,
            script.to_str().unwrap(),
            "web",
            31_245,
            &root.join("launch.log"),
            Some(Path::new("/bin/sh")),
        )
        .expect("persistent process starts");
        let mut fixture = Fixture { child, root };
        let pid = fixture.child.id();
        assert_eq!(process_group(pid), pid, "server must lead its own group");
        assert_ne!(
            process_group(pid),
            process_group(std::process::id()),
            "bounded caller cleanup must target a different group"
        );
        assert!(fixture.child.try_wait().unwrap().is_none());
    }
}
