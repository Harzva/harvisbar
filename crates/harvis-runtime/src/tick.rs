use anyhow::{Context, Result};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use toml::Value;

use crate::inbox::{scan_inboxes, ScanOptions};
use crate::memory::sync_memory_candidate_reviews;
use crate::retention::{
    archive_reports, count_archived_reports, DEFAULT_REPORT_KEEP_LATEST,
    DEFAULT_REPORT_RETENTION_DAYS,
};
use crate::runs::{rel, sync_packet_runs, RunSyncItem};
use crate::stalled::{scan_stalled, StalledScanOutcome, DEFAULT_STALLED_THRESHOLD_HOURS};
use crate::termination::count_suspended_runs;
use harvis_core::time::now_rfc3339;

pub const RUNTIME_VERSION: &str = "v0.3-alpha";

const PROFILE_FILES: &[&str] = &[
    "agent.md",
    "policy.md",
    "runtime.toml",
    "skills/planner.md",
    "skills/reviewer.md",
    "skills/executor.md",
    "skills/inbox.md",
    "skills/memory_snapshot.md",
    "contexts/digital_me.md",
    "contexts/agentworkos.md",
];

#[derive(Debug, Clone)]
pub struct TickOptions {
    pub root: PathBuf,
    pub interval_override: Option<u64>,
    pub profile_root: PathBuf,
}

#[derive(Debug, Clone)]
struct RuntimeConfig {
    autonomy_level: i64,
    default_inbox: String,
    default_reports: String,
    status_file: String,
    event_log: String,
    tick_interval_seconds: u64,
    allowlist: Vec<String>,
    state_root: Option<String>,
    stalled_threshold_hours: u64,
    report_retention_days: u64,
    report_keep_latest: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProfileMetadata {
    pub agent: Option<String>,
    pub contexts: Vec<String>,
    pub missing: Vec<String>,
    pub policy: Option<String>,
    pub root: String,
    pub skills: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RuntimeStatus {
    pub agent: &'static str,
    pub allowlist: Vec<String>,
    pub autonomy_level: i64,
    pub errors: Vec<String>,
    pub last_tick_at: String,
    pub mode: &'static str,
    pub packet_status_counts: BTreeMap<String, usize>,
    pub packets_written: Vec<String>,
    pub profile: ProfileMetadata,
    pub reports_archived_total: usize,
    pub runtime_version: &'static str,
    pub runs_written: Vec<RunSyncItem>,
    pub scanned_inboxes: Vec<String>,
    pub stalled_packet_count: usize,
    pub stalled_run_count: usize,
    pub oldest_stalled_at: Option<String>,
    pub suspended_run_count: usize,
    pub state_root: String,
    pub state_store: String,
    pub tick_interval_seconds: u64,
    pub warnings: Vec<String>,
    pub workspace_root: String,
}

#[derive(Debug, Clone, Serialize)]
struct RuntimeEvent {
    at: String,
    errors: usize,
    packets: usize,
    runs: usize,
    status: String,
    #[serde(rename = "type")]
    event_type: &'static str,
    warnings: usize,
}

#[derive(Debug, Clone, Serialize)]
struct StalledScanEvent {
    at: String,
    alerts_created: usize,
    oldest_stalled_at: Option<String>,
    stalled_packets: usize,
    stalled_runs: usize,
    threshold_hours: u64,
    #[serde(rename = "type")]
    event_type: &'static str,
}

pub fn run_tick(options: TickOptions) -> Result<(RuntimeStatus, TickSideEffects)> {
    let start_root = normalize_start_root(&options.root)?;
    let profile_root = expanduser(&options.profile_root);
    let mut errors = Vec::new();
    let mut warnings = Vec::new();

    // T301: discover the authoritative workspace config upward from the
    // invocation root so state resolution no longer depends on the process CWD.
    let discovery = discover_state_config(&start_root);
    let config_path = discovery
        .config_path
        .clone()
        .unwrap_or_else(|| start_root.join(".harvis/harvis.toml"));
    let mut config = match load_config(&config_path) {
        Ok((config, config_errors)) => {
            errors.extend(config_errors);
            config
        }
        Err(error) => {
            errors.push(error.to_string());
            RuntimeConfig::default()
        }
    };
    if let Some(interval) = options.interval_override {
        config.tick_interval_seconds = interval;
    }

    // T301: an explicit state_root (HARVIS_STATE_ROOT env first, then the
    // config key) pins the single authoritative state tree; without it the
    // legacy workspace-root-relative resolution is kept.
    let env_state_root = std::env::var("HARVIS_STATE_ROOT")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let resolution = resolve_state_root(
        &start_root,
        &discovery,
        env_state_root.as_deref(),
        config.state_root.as_deref(),
    );
    if !resolution.explicit && discovery.config_path.is_some() {
        warnings.push(format!(
            "config has no state_root; using legacy workspace-root resolution under {}",
            resolution.workspace_root.display()
        ));
    }

    // T301: a live second state tree outside state_root means the trees would
    // diverge again; warn and refuse to write any state.
    let second_trees = if resolution.explicit {
        detect_second_state_trees(&start_root, &resolution.state_root)
    } else {
        Vec::new()
    };
    let moment = now_rfc3339()?;
    if !second_trees.is_empty() {
        for tree in &second_trees {
            warnings.push(format!(
                "second state tree detected outside state_root: {}",
                tree.display()
            ));
        }
        errors.push(format!(
            "refusing to write state: {} second state tree(s) found outside state_root {}",
            second_trees.len(),
            resolution.state_root.display()
        ));
        let status = RuntimeStatus {
            agent: "H.A.R.V.I.S.",
            runtime_version: RUNTIME_VERSION,
            autonomy_level: config.autonomy_level,
            mode: "read-only",
            workspace_root: resolution.workspace_root.display().to_string(),
            last_tick_at: moment.clone(),
            tick_interval_seconds: config.tick_interval_seconds,
            allowlist: if config.allowlist.is_empty() {
                vec![config.default_inbox.clone()]
            } else {
                config.allowlist.clone()
            },
            scanned_inboxes: Vec::new(),
            stalled_packet_count: 0,
            stalled_run_count: 0,
            oldest_stalled_at: None,
            suspended_run_count: 0,
            state_root: resolution.state_root.display().to_string(),
            packets_written: Vec::new(),
            runs_written: Vec::new(),
            packet_status_counts: BTreeMap::new(),
            reports_archived_total: 0,
            profile: profile_metadata(&profile_root),
            errors,
            warnings,
            state_store: "blocked".to_string(),
        };
        return Ok((
            status,
            TickSideEffects {
                status_path: resolve_state_path(&resolution, &config.status_file),
                report_path: resolve_state_path(&resolution, &config.default_reports)
                    .join(format!("tick-{}.md", timestamp_slug(&moment))),
                writes_refused: true,
            },
        ));
    }

    fs::create_dir_all(&resolution.state_root).with_context(|| {
        format!(
            "workspace .harvis directory unavailable, using fallback state where possible: {}",
            resolution.state_root.display()
        )
    })?;
    let resolution = resolution.canonicalized();
    let root = resolution.workspace_root.clone();
    let profile = profile_metadata(&profile_root);
    let reports_dir = resolve_state_path(&resolution, &config.default_reports);
    let status_path = resolve_state_path(&resolution, &config.status_file);
    let event_log_path = resolve_state_path(&resolution, &config.event_log);
    for directory in [
        &reports_dir,
        status_path.parent().unwrap_or(&reports_dir),
        event_log_path.parent().unwrap_or(&reports_dir),
    ] {
        if let Err(error) = fs::create_dir_all(directory) {
            warnings.push(format!(
                "workspace runtime directory unavailable: {}: {error}",
                rel(directory, &root)
            ));
        }
    }

    let mut scanned_inboxes = Vec::new();
    let mut packets_written = Vec::new();
    let allowlist = if config.allowlist.is_empty() {
        vec![config.default_inbox.clone()]
    } else {
        config.allowlist.clone()
    };
    for raw_path in &allowlist {
        let inbox_path = resolve_state_path(&resolution, raw_path);
        let inbox_fence = if resolution.explicit {
            &resolution.state_root
        } else {
            &root
        };
        if !inbox_path.starts_with(inbox_fence) {
            errors.push(format!(
                "allowlist path outside workspace root: {}",
                inbox_path.display()
            ));
            continue;
        }
        if !inbox_path.exists() {
            errors.push(format!(
                "allowlist inbox not found: {}",
                rel(&inbox_path, &root)
            ));
            continue;
        }
        match scan_inboxes(ScanOptions {
            root: root.clone(),
            inboxes: vec![inbox_path.clone()],
            allow_outside_root: false,
        }) {
            Ok(written) => {
                scanned_inboxes.push(inbox_path);
                packets_written.extend(written);
            }
            Err(error) => errors.push(format!(
                "scanner failed for {}: {error}",
                rel(&inbox_path, &root)
            )),
        }
    }

    let mut runs_written = Vec::new();
    if !packets_written.is_empty() {
        match sync_packet_runs(&root, Some(packets_written.clone()), 500) {
            Ok(sync) => runs_written = sync.runs,
            Err(error) => errors.push(format!("run ledger sync failed: {error}")),
        }
    }

    // T304: after inbox scan + run ledger sync, sweep the state tree for
    // stalled packets/runs so the tick advances stuck work instead of idling.
    let mut stalled_scan = StalledScanOutcome::default();
    match scan_stalled(&root, config.stalled_threshold_hours) {
        Ok(outcome) => {
            warnings.extend(outcome.warnings.clone());
            stalled_scan = outcome;
        }
        Err(error) => errors.push(format!("stalled scan failed: {error}")),
    }

    // T307: reconcile workbench memory candidates with the human review queue
    // — create deduplicated memory_candidate_review approval items for
    // unreviewed candidates and write decided reviews back onto the candidate
    // lines, then refresh memory/index.json. Runs every tick so manual
    // approval-file edits are picked up as well as CLI decisions.
    match sync_memory_candidate_reviews(&root) {
        Ok(outcome) => warnings.extend(outcome.warnings.clone()),
        Err(error) => errors.push(format!("memory candidate review sync failed: {error}")),
    }

    // Packet status counts classify the full outbox after stalled marking so
    // the status file reflects the whole tree, not only freshly scanned input.
    let mut packet_status_counts: BTreeMap<String, usize> = BTreeMap::new();
    let outbox_dir = root.join(".harvis/outbox");
    if let Ok(entries) = fs::read_dir(&outbox_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) == Some("md") && path.is_file() {
                *packet_status_counts
                    .entry(packet_status(&path))
                    .or_insert(0) += 1;
            }
        }
    }

    let mut status = RuntimeStatus {
        agent: "H.A.R.V.I.S.",
        runtime_version: RUNTIME_VERSION,
        autonomy_level: config.autonomy_level,
        mode: "read-only",
        workspace_root: root.display().to_string(),
        last_tick_at: moment.clone(),
        tick_interval_seconds: config.tick_interval_seconds,
        allowlist: allowlist.iter().map(ToOwned::to_owned).collect(),
        scanned_inboxes: scanned_inboxes
            .iter()
            .map(|path| rel(path, &root))
            .collect(),
        stalled_packet_count: stalled_scan.stalled_packets.len(),
        stalled_run_count: stalled_scan.stalled_runs.len(),
        oldest_stalled_at: stalled_scan.oldest_stalled_at.clone(),
        // T309: keep the first-class approval-suspension count fresh on every
        // tick, in the same derived-count style as the T304 stalled counts.
        suspended_run_count: count_suspended_runs(&root),
        state_root: resolution.state_root.display().to_string(),
        packets_written: packets_written
            .iter()
            .map(|path| rel(path, &root))
            .collect(),
        runs_written,
        packet_status_counts,
        reports_archived_total: 0,
        profile,
        errors,
        warnings,
        state_store: "workspace".to_string(),
    };

    let event_status = if status.errors.is_empty() {
        "ok"
    } else {
        "warning"
    };
    let event = RuntimeEvent {
        event_type: "harvis.runtime.tick",
        at: moment.clone(),
        status: event_status.to_string(),
        packets: status.packets_written.len(),
        runs: status.runs_written.len(),
        errors: status.errors.len(),
        warnings: status.warnings.len(),
    };
    let (_, event_warning) = append_text_with_fallback(
        &event_log_path,
        &runtime_fallback_path(&root, "events.jsonl", &profile_root),
        &(serde_json::to_string(&event)? + "\n"),
    );
    if let Some(warning) = event_warning {
        status.warnings.push(warning);
    }

    let stalled_event = StalledScanEvent {
        event_type: "harvis.runtime.stalled_scan",
        at: moment.clone(),
        threshold_hours: config.stalled_threshold_hours,
        stalled_packets: stalled_scan.stalled_packets.len(),
        stalled_runs: stalled_scan.stalled_runs.len(),
        alerts_created: stalled_scan.alerts_created.len(),
        oldest_stalled_at: stalled_scan.oldest_stalled_at.clone(),
    };
    let (_, stalled_event_warning) = append_text_with_fallback(
        &event_log_path,
        &runtime_fallback_path(&root, "events.jsonl", &profile_root),
        &(serde_json::to_string(&stalled_event)? + "\n"),
    );
    if let Some(warning) = stalled_event_warning {
        status.warnings.push(warning);
    }

    let report_path = reports_dir.join(format!("tick-{}.md", timestamp_slug(&moment)));
    let report_content = render_report(&status, event_status);
    let (actual_report_path, report_warning) = write_text_with_fallback(
        &report_path,
        &runtime_fallback_path(
            &root,
            Path::new("reports").join(report_path.file_name().unwrap_or_default()),
            &profile_root,
        ),
        &report_content,
    );
    if let Some(warning) = report_warning {
        status.warnings.push(warning);
    }

    // T305: logrotate-style rotation runs after the fresh report lands and
    // before status.json is rewritten, so reports_archived_total is the
    // derived count of files actually present under archive/reports/.
    let archive_reports_root = resolution.state_root.join("archive/reports");
    match archive_reports(
        &reports_dir,
        &archive_reports_root,
        config.report_retention_days,
        config.report_keep_latest,
    ) {
        Ok(outcome) => {
            status.warnings.extend(outcome.warnings);
        }
        Err(error) => status
            .warnings
            .push(format!("report retention failed: {error}")),
    }
    status.reports_archived_total = count_archived_reports(&archive_reports_root);

    let status_content = serde_json::to_string_pretty(&status)? + "\n";
    let (actual_status_path, status_warning) = write_text_with_fallback(
        &status_path,
        &runtime_fallback_path(&root, "status.json", &profile_root),
        &status_content,
    );
    if let Some(warning) = status_warning {
        status.warnings.push(warning);
        status.state_store = if actual_status_path.is_some() {
            "profile-fallback".to_string()
        } else {
            "unavailable".to_string()
        };
        let status_content = serde_json::to_string_pretty(&status)? + "\n";
        let _ = write_text_with_fallback(
            &status_path,
            &runtime_fallback_path(&root, "status.json", &profile_root),
            &status_content,
        );
    }

    Ok((
        status,
        TickSideEffects {
            status_path: actual_status_path.unwrap_or(status_path),
            report_path: actual_report_path.unwrap_or(report_path),
            writes_refused: false,
        },
    ))
}

#[derive(Debug, Clone)]
pub struct TickSideEffects {
    pub status_path: PathBuf,
    pub report_path: PathBuf,
    pub writes_refused: bool,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            autonomy_level: 1,
            default_inbox: ".harvis/inbox.md".to_string(),
            default_reports: ".harvis/reports".to_string(),
            status_file: ".harvis/status.json".to_string(),
            event_log: ".harvis/events.jsonl".to_string(),
            tick_interval_seconds: 1200,
            allowlist: vec![".harvis/inbox.md".to_string()],
            state_root: None,
            stalled_threshold_hours: DEFAULT_STALLED_THRESHOLD_HOURS,
            report_retention_days: DEFAULT_REPORT_RETENTION_DAYS,
            report_keep_latest: DEFAULT_REPORT_KEEP_LATEST,
        }
    }
}

fn load_config(path: &Path) -> Result<(RuntimeConfig, Vec<String>)> {
    let mut config = RuntimeConfig::default();
    let mut errors = Vec::new();
    if !path.exists() {
        errors.push(format!(
            "config not found, using defaults: {}",
            path.display()
        ));
        return Ok((config, errors));
    }
    let parsed: Value = match fs::read_to_string(path)?.parse() {
        Ok(parsed) => parsed,
        Err(error) => {
            errors.push(format!(
                "invalid config, using defaults: {}: {error}",
                path.display()
            ));
            return Ok((config, errors));
        }
    };
    if let Some(value) = parsed.get("autonomy_level").and_then(Value::as_integer) {
        config.autonomy_level = value;
    }
    if let Some(value) = parsed.get("state_root").and_then(Value::as_str) {
        config.state_root = Some(value.to_string());
    }
    for (key, slot) in [
        ("default_inbox", &mut config.default_inbox),
        ("default_reports", &mut config.default_reports),
        ("status_file", &mut config.status_file),
        ("event_log", &mut config.event_log),
    ] {
        if let Some(value) = parsed.get(key).and_then(Value::as_str) {
            *slot = value.to_string();
        }
    }
    if let Some(value) = parsed
        .get("tick_interval_seconds")
        .and_then(Value::as_integer)
    {
        config.tick_interval_seconds = value.max(0) as u64;
    }
    if let Some(value) = parsed
        .get("stalled_threshold_hours")
        .and_then(Value::as_integer)
    {
        config.stalled_threshold_hours = value.max(1) as u64;
    }
    if let Some(value) = parsed
        .get("report_retention_days")
        .and_then(Value::as_integer)
    {
        config.report_retention_days = value.max(0) as u64;
    }
    if let Some(value) = parsed.get("report_keep_latest").and_then(Value::as_integer) {
        config.report_keep_latest = value.max(0) as u64;
    }
    if let Some(value) = parsed.get("allowlist") {
        if let Some(items) = value.as_array() {
            config.allowlist = items
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect();
        } else {
            errors.push("allowlist is not a list, using default inbox".to_string());
            config.allowlist = vec![config.default_inbox.clone()];
        }
    }
    Ok((config, errors))
}

fn profile_metadata(profile_root: &Path) -> ProfileMetadata {
    let root = expanduser(profile_root);
    let root = root.canonicalize().unwrap_or(root);
    let mut missing = Vec::new();
    let mut present = BTreeSet::new();
    for relative_path in PROFILE_FILES {
        let path = root.join(relative_path);
        if path.exists() {
            present.insert((*relative_path).to_string());
        } else {
            missing.push(format!("profile file missing: {relative_path}"));
        }
    }
    ProfileMetadata {
        root: root.display().to_string(),
        agent: present.contains("agent.md").then(|| "agent.md".to_string()),
        policy: present
            .contains("policy.md")
            .then(|| "policy.md".to_string()),
        skills: present
            .iter()
            .filter(|path| path.starts_with("skills/"))
            .cloned()
            .collect(),
        contexts: present
            .iter()
            .filter(|path| path.starts_with("contexts/"))
            .cloned()
            .collect(),
        missing,
    }
}

fn render_report(status: &RuntimeStatus, report_status: &str) -> String {
    let mut lines = vec![
        "# H.A.R.V.I.S. Tick Report".to_string(),
        String::new(),
        format!("Status: {report_status}"),
        "Autonomy: Level 1 read-only".to_string(),
        format!("Workspace: {}", status.workspace_root),
        format!("State root: {}", status.state_root),
        format!("Scanned: {}", join_or_none(&status.scanned_inboxes)),
        format!("Packets: {}", status.packets_written.len()),
        format!("Stalled packets: {}", status.stalled_packet_count),
        format!("Stalled runs: {}", status.stalled_run_count),
        format!(
            "Oldest stalled at: {}",
            status.oldest_stalled_at.as_deref().unwrap_or("none")
        ),
        format!("Errors: {}", status.errors.len()),
        String::new(),
        "Packet Status Counts:".to_string(),
    ];
    if status.packet_status_counts.is_empty() {
        lines.push("- none: 0".to_string());
    } else {
        for (name, count) in &status.packet_status_counts {
            lines.push(format!("- {name}: {count}"));
        }
    }
    lines.extend([
        String::new(),
        "Next:".to_string(),
        "1. Review new or blocked packets under .harvis/outbox/.".to_string(),
        "2. Ask H.A.R.V.I.S. to execute a packet only after review.".to_string(),
        String::new(),
    ]);
    if !status.errors.is_empty() {
        lines.push("Errors:".to_string());
        for error in &status.errors {
            lines.push(format!("- {error}"));
        }
        lines.push(String::new());
    }
    if !status.warnings.is_empty() {
        lines.push("Warnings:".to_string());
        for warning in &status.warnings {
            lines.push(format!("- {warning}"));
        }
        lines.push(String::new());
    }
    lines.join("\n")
}

fn join_or_none(values: &[String]) -> String {
    if values.is_empty() {
        "none".to_string()
    } else {
        values.join(", ")
    }
}

fn packet_status(packet_path: &Path) -> String {
    let Ok(text) = fs::read_to_string(packet_path) else {
        return "unknown".to_string();
    };
    for line in text.lines() {
        if line.starts_with("Status:") {
            return line
                .split_once(':')
                .map(|(_, value)| value.trim().to_string())
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| "unknown".to_string());
        }
    }
    "unknown".to_string()
}

// T301: unified state-tree resolution. An explicit state_root (absolute path
// from HARVIS_STATE_ROOT or the harvis.toml `state_root` key) pins the single
// authoritative `.harvis` tree; every relative `.harvis/*` config key then
// resolves under state_root with the leading `.harvis` component dropped,
// because state_root already names the tree itself.
#[derive(Debug, Clone)]
struct StateResolution {
    state_root: PathBuf,
    workspace_root: PathBuf,
    explicit: bool,
}

impl StateResolution {
    fn canonicalized(self) -> StateResolution {
        let state_root = canonical_or(self.state_root);
        let workspace_root = if self.explicit {
            workspace_root_of(&state_root, &self.workspace_root)
        } else {
            canonical_or(self.workspace_root)
        };
        StateResolution {
            state_root,
            workspace_root,
            explicit: self.explicit,
        }
    }
}

#[derive(Debug, Clone)]
struct StateConfigDiscovery {
    config_path: Option<PathBuf>,
    anchor: PathBuf,
    state_root_level: Option<PathBuf>,
}

fn discover_state_config(start_root: &Path) -> StateConfigDiscovery {
    let mut discovery = StateConfigDiscovery {
        config_path: None,
        anchor: start_root.to_path_buf(),
        state_root_level: None,
    };
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut found_state_root = false;
    for level in start_root.ancestors() {
        if home.as_deref() == Some(level) {
            // ~/.harvis is the runtime profile root, never a workspace tree.
            continue;
        }
        let candidate = level.join(".harvis/harvis.toml");
        if !candidate.is_file() {
            continue;
        }
        if discovery.config_path.is_none() {
            discovery.config_path = Some(candidate.clone());
            discovery.anchor = level.to_path_buf();
        }
        if let Ok(text) = fs::read_to_string(&candidate) {
            if let Ok(parsed) = text.parse::<Value>() {
                if parsed.get("state_root").and_then(Value::as_str).is_some() {
                    discovery.state_root_level = Some(level.to_path_buf());
                    found_state_root = true;
                }
            }
        }
        if found_state_root {
            break;
        }
    }
    // The nearest config that declares state_root is authoritative, even when a
    // nearer legacy config exists; the nearer tree is then a second-tree suspect.
    if let Some(level) = discovery.state_root_level.clone() {
        discovery.config_path = Some(level.join(".harvis/harvis.toml"));
        discovery.anchor = level;
    }
    discovery
}

fn resolve_state_root(
    start_root: &Path,
    discovery: &StateConfigDiscovery,
    env_override: Option<&str>,
    config_state_root: Option<&str>,
) -> StateResolution {
    if let Some(raw) = env_override {
        let path = expanduser(Path::new(raw));
        let path = if path.is_absolute() {
            path
        } else {
            start_root.join(path)
        };
        let state_root = canonical_or(path);
        return StateResolution {
            workspace_root: workspace_root_of(&state_root, start_root),
            state_root,
            explicit: true,
        };
    }
    if let (Some(raw), Some(level)) = (config_state_root, discovery.state_root_level.as_deref()) {
        let path = expanduser(Path::new(raw));
        let path = if path.is_absolute() {
            path
        } else {
            level.join(path)
        };
        let state_root = canonical_or(path);
        return StateResolution {
            workspace_root: workspace_root_of(&state_root, level),
            state_root,
            explicit: true,
        };
    }
    let anchor = canonical_or(discovery.anchor.clone());
    StateResolution {
        state_root: anchor.join(".harvis"),
        workspace_root: anchor,
        explicit: false,
    }
}

fn workspace_root_of(state_root: &Path, fallback: &Path) -> PathBuf {
    if state_root.file_name().and_then(|value| value.to_str()) == Some(".harvis") {
        return state_root
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| fallback.to_path_buf());
    }
    state_root.to_path_buf()
}

fn resolve_state_path(resolution: &StateResolution, value: &str) -> PathBuf {
    let path = expanduser(Path::new(value));
    if path.is_absolute() {
        return path;
    }
    if resolution.explicit {
        let mut components = path.components();
        if components.next().map(|component| component.as_os_str())
            == Some(std::ffi::OsStr::new(".harvis"))
        {
            return resolution.state_root.join(components.as_path());
        }
        return resolution.state_root.join(path);
    }
    resolution.workspace_root.join(path)
}

fn detect_second_state_trees(start_root: &Path, state_root: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = Vec::new();
    consider_state_tree_candidate(&mut found, start_root.join(".harvis"), state_root);
    if let Ok(entries) = fs::read_dir(start_root) {
        for entry in entries.flatten() {
            if entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {
                consider_state_tree_candidate(&mut found, entry.path().join(".harvis"), state_root);
            }
        }
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    for level in start_root.ancestors().skip(1) {
        if home.as_deref() == Some(level) {
            continue;
        }
        consider_state_tree_candidate(&mut found, level.join(".harvis"), state_root);
    }
    found
}

fn consider_state_tree_candidate(found: &mut Vec<PathBuf>, candidate: PathBuf, state_root: &Path) {
    if same_path(&candidate, state_root) {
        return;
    }
    if found.iter().any(|known| same_path(known, &candidate)) {
        return;
    }
    if has_state_markers(&candidate) {
        found.push(candidate);
    }
}

fn has_state_markers(tree: &Path) -> bool {
    tree.is_dir()
        && ["harvis.toml", "status.json", "events.jsonl"]
            .iter()
            .any(|name| tree.join(name).exists())
}

fn same_path(left: &Path, right: &Path) -> bool {
    canonical_or(left.to_path_buf()) == canonical_or(right.to_path_buf())
}

fn canonical_or(path: PathBuf) -> PathBuf {
    path.canonicalize().unwrap_or(path)
}

fn normalize_start_root(root: &Path) -> Result<PathBuf> {
    let expanded = expanduser(root);
    let absolute = if expanded.is_absolute() {
        expanded
    } else {
        std::env::current_dir()?.join(expanded)
    };
    Ok(canonical_or(absolute))
}

fn write_text_with_fallback(
    primary: &Path,
    fallback: &Path,
    content: &str,
) -> (Option<PathBuf>, Option<String>) {
    match write_text(primary, content) {
        Ok(()) => (Some(primary.to_path_buf()), None),
        Err(primary_error) => match write_text(fallback, content) {
            Ok(()) => (
                Some(fallback.to_path_buf()),
                Some(format!("workspace write failed, used profile fallback: {primary_error}")),
            ),
            Err(fallback_error) => (
                None,
                Some(format!(
                    "workspace write failed and profile fallback write failed: {primary_error}; fallback: {fallback_error}"
                )),
            ),
        },
    }
}

fn append_text_with_fallback(
    primary: &Path,
    fallback: &Path,
    content: &str,
) -> (Option<PathBuf>, Option<String>) {
    match append_text(primary, content) {
        Ok(()) => (Some(primary.to_path_buf()), None),
        Err(primary_error) => match append_text(fallback, content) {
            Ok(()) => (
                Some(fallback.to_path_buf()),
                Some(format!("workspace append failed, used profile fallback: {primary_error}")),
            ),
            Err(fallback_error) => (
                None,
                Some(format!(
                    "workspace append failed and profile fallback append failed: {primary_error}; fallback: {fallback_error}"
                )),
            ),
        },
    }
}

fn write_text(path: &Path, content: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, content)
}

fn append_text(path: &Path, content: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(content.as_bytes())
}

fn runtime_fallback_path(
    root: &Path,
    relative_path: impl AsRef<Path>,
    profile_root: &Path,
) -> PathBuf {
    let mut rel_path = relative_path.as_ref().to_path_buf();
    if rel_path.is_absolute() {
        rel_path = rel_path
            .file_name()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("runtime-state"));
    }
    if rel_path
        .components()
        .next()
        .map(|component| component.as_os_str())
        == Some(std::ffi::OsStr::new(".harvis"))
    {
        rel_path = rel_path.components().skip(1).collect();
    }
    fallback_workspace_dir(root, profile_root).join(rel_path)
}

fn fallback_workspace_dir(root: &Path, profile_root: &Path) -> PathBuf {
    expanduser(profile_root)
        .join("state/workspaces")
        .join(workspace_state_id(root))
}

fn workspace_state_id(root: &Path) -> String {
    let resolved = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let digest = Sha256::digest(resolved.display().to_string().as_bytes());
    let digest = digest
        .iter()
        .take(6)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let label = resolved
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("workspace");
    let safe_label = label
        .chars()
        .map(|character| {
            if character.is_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches(['.', '-'])
        .chars()
        .take(48)
        .collect::<String>();
    format!(
        "{}-{digest}",
        if safe_label.is_empty() {
            "workspace"
        } else {
            &safe_label
        }
    )
}

fn timestamp_slug(moment: &str) -> String {
    moment
        .chars()
        .filter(|character| character.is_ascii_digit())
        .take(14)
        .collect::<String>()
        .split_at(8)
        .pipe(|(date, time)| format!("{date}T{time}Z"))
}

trait Pipe: Sized {
    fn pipe<T>(self, f: impl FnOnce(Self) -> T) -> T {
        f(self)
    }
}
impl<T> Pipe for T {}

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

    // Writes a minimal workspace whose config declares an explicit state_root,
    // bypassing init_workspace so the T301 tests stay independent of the
    // agent-pools fixture pipeline.
    fn init_state_workspace(root: &Path) {
        fs::create_dir_all(root).expect("create root");
        let state_root = root.canonicalize().expect("canonical root").join(".harvis");
        fs::create_dir_all(&state_root).expect("create state root");
        fs::write(
            state_root.join("harvis.toml"),
            format!(
                "state_root = \"{}\"\nautonomy_level = 1\ndefault_inbox = \".harvis/inbox.md\"\ndefault_reports = \".harvis/reports\"\nstatus_file = \".harvis/status.json\"\nevent_log = \".harvis/events.jsonl\"\ntick_interval_seconds = 1200\nallowlist = [\".harvis/inbox.md\"]\n",
                state_root.display()
            ),
        )
        .expect("write config");
    }

    #[test]
    fn tick_writes_status_event_report_and_runs() {
        let root =
            std::env::temp_dir().join(format!("harvis-tick-rust-test-{}", std::process::id()));
        let profile =
            std::env::temp_dir().join(format!("harvis-profile-rust-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&profile);
        init_workspace(&root, false).expect("init workspace");
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis review this fixture.\n\n@harvis use this token: abc\n",
        )
        .expect("write inbox");

        let (status, side_effects) = run_tick(TickOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            interval_override: Some(1200),
        })
        .expect("run tick");

        assert_eq!(status.runtime_version, "v0.3-alpha");
        assert_eq!(status.mode, "read-only");
        assert_eq!(status.state_store, "workspace");
        assert_eq!(status.packets_written.len(), 2);
        assert_eq!(status.runs_written.len(), 2);
        assert!(side_effects.status_path.exists());
        assert!(side_effects.report_path.exists());
        assert!(root.join(".harvis/events.jsonl").exists());

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(profile);
    }

    #[test]
    fn state_root_resolution_strips_harvis_prefix_and_passes_absolute() {
        let state_root = PathBuf::from("/tmp/example/.harvis");
        let explicit = StateResolution {
            state_root: state_root.clone(),
            workspace_root: PathBuf::from("/tmp/example"),
            explicit: true,
        };
        assert_eq!(
            resolve_state_path(&explicit, ".harvis/status.json"),
            state_root.join("status.json")
        );
        assert_eq!(
            resolve_state_path(&explicit, ".harvis/events.jsonl"),
            state_root.join("events.jsonl")
        );
        assert_eq!(
            resolve_state_path(&explicit, "custom/x.json"),
            state_root.join("custom/x.json")
        );
        assert_eq!(
            resolve_state_path(&explicit, "/abs/x.json"),
            PathBuf::from("/abs/x.json")
        );
        let legacy = StateResolution {
            state_root: state_root.clone(),
            workspace_root: PathBuf::from("/tmp/example"),
            explicit: false,
        };
        assert_eq!(
            resolve_state_path(&legacy, ".harvis/status.json"),
            PathBuf::from("/tmp/example/.harvis/status.json")
        );
    }

    #[test]
    fn state_root_prefers_env_override_then_config() {
        let start = Path::new("/tmp/anywhere");
        let discovery = StateConfigDiscovery {
            config_path: Some(start.join(".harvis/harvis.toml")),
            anchor: start.to_path_buf(),
            state_root_level: Some(start.to_path_buf()),
        };
        let from_env = resolve_state_root(
            start,
            &discovery,
            Some("/tmp/from-env/.harvis"),
            Some("/tmp/from-config/.harvis"),
        );
        assert!(from_env.explicit);
        assert_eq!(from_env.state_root, PathBuf::from("/tmp/from-env/.harvis"));
        assert_eq!(from_env.workspace_root, PathBuf::from("/tmp/from-env"));
        let from_config = resolve_state_root(start, &discovery, None, Some(".harvis"));
        assert!(from_config.explicit);
        assert_eq!(from_config.state_root, start.join(".harvis"));
        assert_eq!(from_config.workspace_root, start);
    }

    #[test]
    fn tick_anchors_to_state_root_from_subdirectory() {
        let root =
            std::env::temp_dir().join(format!("harvis-tick-anchor-test-{}", std::process::id()));
        let profile =
            std::env::temp_dir().join(format!("harvis-profile-anchor-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&profile);
        init_state_workspace(&root);
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis review this fixture.\n",
        )
        .expect("write inbox");
        let nested = root.join("nested/project");
        fs::create_dir_all(&nested).expect("create nested dir");

        let (status, side_effects) = run_tick(TickOptions {
            root: nested.clone(),
            profile_root: profile.clone(),
            interval_override: Some(1200),
        })
        .expect("run tick");

        let state_root = root.join(".harvis").canonicalize().expect("canonical");
        assert!(!side_effects.writes_refused);
        assert_eq!(status.state_store, "workspace");
        assert_eq!(status.state_root, state_root.display().to_string());
        assert_eq!(status.packets_written.len(), 1);
        assert!(state_root.join("status.json").exists());
        assert!(state_root.join("events.jsonl").exists());
        assert!(!nested.join(".harvis").exists());

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(profile);
    }

    #[test]
    fn tick_without_state_root_keeps_legacy_resolution_with_warning() {
        let root =
            std::env::temp_dir().join(format!("harvis-tick-legacy-test-{}", std::process::id()));
        let profile =
            std::env::temp_dir().join(format!("harvis-profile-legacy-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&profile);
        let state_dir = root.join(".harvis");
        fs::create_dir_all(&state_dir).expect("create state dir");
        fs::write(
            state_dir.join("harvis.toml"),
            "autonomy_level = 1\ndefault_inbox = \".harvis/inbox.md\"\ndefault_reports = \".harvis/reports\"\nstatus_file = \".harvis/status.json\"\nevent_log = \".harvis/events.jsonl\"\ntick_interval_seconds = 1200\nallowlist = [\".harvis/inbox.md\"]\n",
        )
        .expect("write legacy config");
        fs::write(state_dir.join("inbox.md"), "@harvis review this fixture.\n")
            .expect("write inbox");

        let (status, side_effects) = run_tick(TickOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            interval_override: Some(1200),
        })
        .expect("run tick");

        let state_root = root.join(".harvis").canonicalize().expect("canonical");
        assert!(!side_effects.writes_refused);
        assert_eq!(status.state_store, "workspace");
        assert_eq!(status.state_root, state_root.display().to_string());
        assert!(status
            .warnings
            .iter()
            .any(|warning| warning.contains("no state_root")));
        assert_eq!(status.packets_written.len(), 1);
        assert!(state_root.join("status.json").exists());
        assert!(state_root.join("events.jsonl").exists());

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(profile);
    }

    #[test]
    fn config_reads_stalled_threshold_hours_with_default() {
        let root =
            std::env::temp_dir().join(format!("harvis-config-stalled-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create root");
        let config_path = root.join("harvis.toml");
        fs::write(&config_path, "stalled_threshold_hours = 48\n").expect("write config");
        let (config, errors) = load_config(&config_path).expect("load config");
        assert!(errors.is_empty());
        assert_eq!(config.stalled_threshold_hours, 48);
        fs::write(&config_path, "autonomy_level = 1\n").expect("rewrite config");
        let (config, _) = load_config(&config_path).expect("load config without key");
        assert_eq!(
            config.stalled_threshold_hours,
            DEFAULT_STALLED_THRESHOLD_HOURS
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn tick_marks_stalled_and_raises_deduped_alert() {
        use time::format_description::well_known::Rfc3339;
        use time::{Duration, OffsetDateTime};

        let root =
            std::env::temp_dir().join(format!("harvis-tick-stalled-test-{}", std::process::id()));
        let profile = std::env::temp_dir().join(format!(
            "harvis-profile-stalled-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&profile);
        init_workspace(&root, false).expect("init workspace");
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis review this fixture.\n",
        )
        .expect("write inbox");

        let options = || TickOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            interval_override: Some(1200),
        };
        let (first, _) = run_tick(options()).expect("first tick");
        assert_eq!(first.stalled_packet_count, 0);
        assert_eq!(first.stalled_run_count, 0);
        assert_eq!(first.oldest_stalled_at, None);

        // Age the synced run to 48h ago with a blocked handoff, then re-tick.
        let runs_dir = root.join(".harvis/runs");
        let run_path = fs::read_dir(&runs_dir)
            .expect("runs dir")
            .flatten()
            .map(|entry| entry.path())
            .find(|path| path.extension().and_then(|value| value.to_str()) == Some("json"))
            .expect("run json");
        let mut run: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&run_path).expect("read run"))
                .expect("parse run");
        let old_moment = (OffsetDateTime::now_utc() - Duration::hours(48))
            .format(&Rfc3339)
            .expect("format old moment");
        run["created_at"] = serde_json::json!(old_moment);
        run["outputs"]["latest_handoff_state"] = serde_json::json!("blocked");
        fs::write(
            &run_path,
            serde_json::to_string_pretty(&run).expect("serialize"),
        )
        .expect("rewrite run");
        let run_id = run["run_id"].as_str().expect("run id").to_string();

        let (second, _) = run_tick(options()).expect("second tick");
        assert_eq!(second.stalled_run_count, 1);
        assert!(second.stalled_packet_count >= 1);
        assert!(second.oldest_stalled_at.is_some());
        assert_eq!(second.packet_status_counts.get("stalled").copied(), Some(1));

        let approvals_dir = root.join(".harvis/approvals");
        let alerts: Vec<_> = fs::read_dir(&approvals_dir)
            .expect("approvals dir")
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("json"))
            .collect();
        assert_eq!(alerts.len(), 1);
        let alert: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&alerts[0]).expect("read alert"))
                .expect("parse alert");
        assert_eq!(alert["kind"], "stalled_run_alert");
        assert_eq!(alert["run_id"], run_id);
        assert_eq!(alert["status"], "pending");

        // A third tick must not duplicate the pending alert.
        let (third, _) = run_tick(options()).expect("third tick");
        assert_eq!(third.stalled_run_count, 1);
        let alert_count = fs::read_dir(&approvals_dir)
            .expect("approvals dir")
            .flatten()
            .filter(|entry| {
                entry.path().extension().and_then(|value| value.to_str()) == Some("json")
            })
            .count();
        assert_eq!(alert_count, 1);

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(profile);
    }

    #[test]
    fn config_reads_report_retention_keys_with_defaults() {
        let root = std::env::temp_dir().join(format!(
            "harvis-config-retention-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create root");
        let config_path = root.join("harvis.toml");
        fs::write(
            &config_path,
            "report_retention_days = 7\nreport_keep_latest = 5\n",
        )
        .expect("write config");
        let (config, errors) = load_config(&config_path).expect("load config");
        assert!(errors.is_empty());
        assert_eq!(config.report_retention_days, 7);
        assert_eq!(config.report_keep_latest, 5);
        fs::write(&config_path, "autonomy_level = 1\n").expect("rewrite config");
        let (config, _) = load_config(&config_path).expect("load config without keys");
        assert_eq!(config.report_retention_days, DEFAULT_REPORT_RETENTION_DAYS);
        assert_eq!(config.report_keep_latest, DEFAULT_REPORT_KEEP_LATEST);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn tick_archives_reports_with_zero_retention() {
        let root =
            std::env::temp_dir().join(format!("harvis-tick-retention-test-{}", std::process::id()));
        let profile = std::env::temp_dir().join(format!(
            "harvis-profile-retention-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&profile);
        init_state_workspace(&root);
        let config_path = root.join(".harvis/harvis.toml");
        let mut text = fs::read_to_string(&config_path).expect("read config");
        text.push_str("report_retention_days = 0\nreport_keep_latest = 0\n");
        fs::write(&config_path, text).expect("rewrite config");
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis review this fixture.\n",
        )
        .expect("write inbox");

        let options = || TickOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            interval_override: Some(1200),
        };
        let (first, _) = run_tick(options()).expect("first tick");
        assert!(first.reports_archived_total <= 1);
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let (second, _) = run_tick(options()).expect("second tick");

        let reports_dir = root.join(".harvis/reports");
        let archive_dir = root.join(".harvis/archive/reports");
        let count_md = |dir: &Path| -> usize {
            let mut count = 0;
            let mut stack = vec![dir.to_path_buf()];
            while let Some(dir) = stack.pop() {
                let Ok(entries) = fs::read_dir(&dir) else {
                    continue;
                };
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        stack.push(path);
                    } else if path.extension().and_then(|value| value.to_str()) == Some("md") {
                        count += 1;
                    }
                }
            }
            count
        };
        let live = count_md(&reports_dir);
        let archived = count_md(&archive_dir);
        assert!(live <= 1, "zero retention keeps at most the fresh report");
        assert_eq!(
            live + archived,
            2,
            "two ticks produced two reports, none lost"
        );
        assert_eq!(second.reports_archived_total, archived);

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(profile);
    }

    #[test]
    fn tick_refuses_writes_when_second_state_tree_detected() {
        let root =
            std::env::temp_dir().join(format!("harvis-tick-guard-test-{}", std::process::id()));
        let profile =
            std::env::temp_dir().join(format!("harvis-profile-guard-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&profile);
        init_state_workspace(&root);
        let second_tree = root.join("digital_me/.harvis");
        fs::create_dir_all(&second_tree).expect("create second tree");
        fs::write(second_tree.join("status.json"), "{}\n").expect("write marker");

        let (status, side_effects) = run_tick(TickOptions {
            root: root.clone(),
            profile_root: profile.clone(),
            interval_override: Some(1200),
        })
        .expect("run tick");

        assert!(side_effects.writes_refused);
        assert_eq!(status.state_store, "blocked");
        assert!(status
            .errors
            .iter()
            .any(|error| error.contains("second state tree")));
        assert!(status
            .warnings
            .iter()
            .any(|warning| warning.contains("second state tree")));
        assert!(!root.join(".harvis/status.json").exists());
        assert!(!root.join(".harvis/events.jsonl").exists());

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(profile);
    }
}
