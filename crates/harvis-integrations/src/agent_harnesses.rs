use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub const SCHEMA_VERSION: &str = "harvis.agent-harnesses.v0";
pub const DEFAULT_TIMEOUT_SECONDS: usize = 120;

struct HarnessSpec {
    harness_id: &'static str,
    label: &'static str,
    pool_kind: &'static str,
    runtime: &'static str,
    model: &'static str,
    launch: Option<LaunchDescriptor>,
    commands: &'static [&'static str],
    posix_wrapper: Option<&'static str>,
    windows_wrapper: Option<&'static str>,
    review_scripts: &'static [&'static str],
    smoke_test_target: bool,
    requires_skill: bool,
    requires_wrapper: bool,
    version_args: &'static [&'static str],
}

#[derive(Clone, Copy)]
struct LaunchDescriptor {
    launcher_id: &'static str,
    product_id: &'static str,
    kind: &'static str,
    mode: &'static str,
    working_directory_policy: &'static str,
}

impl LaunchDescriptor {
    const fn cli(launcher_id: &'static str, product_id: &'static str) -> Self {
        Self {
            launcher_id,
            product_id,
            kind: "cli",
            mode: "new-terminal-session",
            working_directory_policy: "workspace-root",
        }
    }

    fn as_json(self) -> Value {
        json!({
            "launcherID": self.launcher_id,
            "productID": self.product_id,
            "kind": self.kind,
            "mode": self.mode,
            "workingDirectoryPolicy": self.working_directory_policy,
        })
    }
}

const HARNESS_SPECS: &[HarnessSpec] = &[
    HarnessSpec {
        harness_id: "codex",
        label: "Codex CLI",
        pool_kind: "harness",
        runtime: "codex-cli",
        model: "openai:gpt-5-codex",
        launch: Some(LaunchDescriptor::cli("harvis.cli.codex", "codex")),
        commands: &["codex"],
        posix_wrapper: None,
        windows_wrapper: None,
        review_scripts: &[],
        smoke_test_target: false,
        requires_skill: false,
        requires_wrapper: false,
        version_args: &["--version"],
    },
    HarnessSpec {
        harness_id: "dsh",
        label: "Digital-Me DSH",
        pool_kind: "harness",
        runtime: "dsh-cordis",
        model: "dsh:profile-default",
        launch: Some(LaunchDescriptor::cli("harvis.cli.dsh", "dsh")),
        commands: &["dsh"],
        posix_wrapper: None,
        windows_wrapper: None,
        review_scripts: &[],
        smoke_test_target: false,
        requires_skill: false,
        requires_wrapper: false,
        version_args: &["--version"],
    },
    HarnessSpec {
        harness_id: "kimicode",
        label: "Kimi Code",
        pool_kind: "harness",
        runtime: "kimi-code",
        model: "moonshot-kimi:kimi-code/kimi-for-coding",
        launch: Some(LaunchDescriptor::cli("harvis.cli.kimicode", "kimicode")),
        commands: &["kimicode", "kimi"],
        posix_wrapper: None,
        windows_wrapper: None,
        review_scripts: &[],
        smoke_test_target: false,
        requires_skill: false,
        requires_wrapper: false,
        version_args: &["--version"],
    },
    HarnessSpec {
        harness_id: "mimocode",
        label: "MiMoCode",
        pool_kind: "harness",
        runtime: "mimocode",
        model: "xiaomi:mimo-v2.5-pro-ultraspeed",
        launch: Some(LaunchDescriptor::cli("harvis.cli.mimocode", "mimocode")),
        commands: &["mimocode", "mimo"],
        posix_wrapper: None,
        windows_wrapper: None,
        review_scripts: &[],
        smoke_test_target: true,
        requires_skill: false,
        requires_wrapper: false,
        version_args: &["--version"],
    },
    HarnessSpec {
        harness_id: "claude-code",
        label: "Claude Code",
        pool_kind: "harness",
        runtime: "claude-code",
        model: "anthropic:claude-code-default",
        launch: Some(LaunchDescriptor::cli(
            "harvis.cli.claude-code",
            "claude-code",
        )),
        commands: &["claude"],
        posix_wrapper: None,
        windows_wrapper: None,
        review_scripts: &[],
        smoke_test_target: false,
        requires_skill: false,
        requires_wrapper: false,
        version_args: &["--version"],
    },
    HarnessSpec {
        harness_id: "likecode",
        label: "LikeCode",
        pool_kind: "harness",
        runtime: "likecode",
        model: "likecode:d4p/deepseek-v4-pro",
        launch: Some(LaunchDescriptor::cli("harvis.cli.likecode", "likecode")),
        commands: &["likecode"],
        posix_wrapper: None,
        windows_wrapper: None,
        review_scripts: &[],
        smoke_test_target: true,
        requires_skill: false,
        requires_wrapper: false,
        version_args: &["--version"],
    },
    HarnessSpec {
        harness_id: "cxspark",
        label: "CX Spark",
        pool_kind: "runtime-preset",
        runtime: "codex-cli",
        model: "openai:gpt-5.3-codex-spark",
        launch: None,
        commands: &["codex"],
        posix_wrapper: Some("cxspark.sh"),
        windows_wrapper: Some("cxspark.ps1"),
        review_scripts: &["cxspark-mark-reviewed.sh", "cxspark-mark-reviewed.ps1"],
        smoke_test_target: true,
        requires_skill: true,
        requires_wrapper: true,
        version_args: &["--version"],
    },
];

pub fn build_agent_harness_status(run_tests: bool, timeout_seconds: usize) -> Value {
    let timeout_seconds = timeout_seconds.clamp(1, 600);
    let items = HARNESS_SPECS
        .iter()
        .map(|spec| build_harness_item(spec, run_tests, timeout_seconds))
        .collect::<Vec<_>>();
    let (status, summary) = summarize(&items, run_tests);
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "safeForHarvisBar": true,
        "generatedAt": harvis_core::time::now_rfc3339().unwrap_or_else(|_| "unknown".to_string()),
        "status": status,
        "summary": summary,
        "testPolicy": if run_tests { "model-smoke-targets" } else { "status-only" },
        "includesModelCalls": run_tests,
        "includesSecrets": false,
        "includesLocalAbsolutePaths": false,
        "items": items
    })
}

fn build_harness_item(spec: &HarnessSpec, run_tests: bool, timeout_seconds: usize) -> Value {
    let skill_dir = skills_root().join(spec.harness_id);
    let skill_present = skill_dir.exists();
    let wrapper = wrapper_status(spec, &skill_dir);
    let command = command_path(spec.commands);
    let runs = count_runs(spec.harness_id);
    let test = if run_tests {
        run_model_smoke_test(spec, command.as_deref(), timeout_seconds)
    } else {
        json!({
            "status": "not-run",
            "exitCode": null,
            "summary": "Model smoke test has not been run in this response.",
            "kind": "model-smoke"
        })
    };
    let (status, summary) = derive_harness_state(
        spec.requires_skill,
        spec.requires_wrapper,
        skill_present,
        &wrapper,
        command.is_some(),
        runs.get("pendingReviews")
            .and_then(Value::as_u64)
            .unwrap_or(0) as usize,
        if run_tests {
            test.get("status").and_then(Value::as_str)
        } else {
            None
        },
    );
    let launch = spec.launch.map(LaunchDescriptor::as_json);
    json!({
        "id": spec.harness_id,
        "label": spec.label,
        "poolKind": spec.pool_kind,
        "runtime": spec.runtime,
        "model": spec.model,
        "launch": launch,
        "status": status,
        "summary": summary,
        "requiresSkill": spec.requires_skill,
        "requiresWrapper": spec.requires_wrapper,
        "skillPresent": skill_present,
        "wrapperPresent": wrapper["wrapperPresent"],
        "nativeWrapperPresent": wrapper["nativeWrapperPresent"],
        "reviewMarkerPresent": wrapper["reviewMarkerPresent"],
        "nativeWrapperKind": wrapper["nativeWrapperKind"],
        "cliPresent": command.is_some(),
        "cliCommand": command,
        "pendingReviews": runs["pendingReviews"],
        "reviewedRuns": runs["reviewedRuns"],
        "latestRun": runs["latestRun"],
        "testTarget": spec.smoke_test_target,
        "test": test
    })
}

fn wrapper_status(spec: &HarnessSpec, skill_dir: &Path) -> Value {
    let script_dir = skill_dir.join("scripts");
    let native = native_wrapper_name(spec);
    let wrapper_present = [spec.posix_wrapper, spec.windows_wrapper]
        .into_iter()
        .flatten()
        .any(|name| script_dir.join(name).exists());
    let native_wrapper_present = native.is_some_and(|name| script_dir.join(name).exists());
    let review_marker_present = spec
        .review_scripts
        .iter()
        .any(|name| script_dir.join(name).exists());
    json!({
        "wrapperPresent": wrapper_present,
        "nativeWrapperPresent": native_wrapper_present,
        "reviewMarkerPresent": review_marker_present,
        "nativeWrapperKind": native.map(|name| if name.ends_with(".ps1") { "powershell" } else { "shell" }).unwrap_or("none")
    })
}

fn native_wrapper_name(spec: &HarnessSpec) -> Option<&'static str> {
    if cfg!(windows) {
        spec.windows_wrapper
    } else {
        spec.posix_wrapper
    }
}

fn count_runs(harness_id: &str) -> Value {
    let run_dir = home_root()
        .join(".codex")
        .join(format!("{harness_id}-runs"));
    if !run_dir.exists() {
        return json!({"pendingReviews": 0, "reviewedRuns": 0, "latestRun": null});
    }
    let pending_files = glob_suffix(&run_dir, "-pending.json");
    let mut pending = Vec::new();
    let mut reviewed = glob_suffix(&run_dir, "-reviewed.json");
    for path in pending_files {
        if run_file_is_reviewed(&path) {
            reviewed.push(path);
        } else {
            pending.push(path);
        }
    }
    pending.sort_by(|left, right| modified_secs(right).cmp(&modified_secs(left)));
    reviewed.sort_by(|left, right| modified_secs(right).cmp(&modified_secs(left)));
    let latest = pending
        .iter()
        .chain(reviewed.iter())
        .max_by_key(|path| modified_secs(path))
        .and_then(|path| read_run_meta(path));
    json!({"pendingReviews": pending.len(), "reviewedRuns": reviewed.len(), "latestRun": latest})
}

fn run_file_is_reviewed(path: &Path) -> bool {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|loaded| loaded.get("codex_reviewed").and_then(Value::as_bool))
        .unwrap_or(false)
}

fn read_run_meta(path: &Path) -> Option<Value> {
    let loaded = serde_json::from_str::<Value>(&fs::read_to_string(path).ok()?).ok()?;
    Some(json!({
        "tool": string_or_null(&loaded, "tool"),
        "model": string_or_null(&loaded, "model"),
        "stage": string_or_null(&loaded, "stage"),
        "failureKind": string_or_null(&loaded, "failure_kind"),
        "exitCode": loaded.get("exit_code").and_then(Value::as_i64),
        "finishedAt": string_or_null(&loaded, "finished_at"),
        "codexReviewed": loaded.get("codex_reviewed").and_then(Value::as_bool)
    }))
}

fn run_model_smoke_test(
    spec: &HarnessSpec,
    command: Option<&str>,
    timeout_seconds: usize,
) -> Value {
    if !spec.smoke_test_target {
        return json!({
            "status": "not-run",
            "exitCode": null,
            "summary": "This harness is shown in status but not part of Test All.",
            "kind": "not-targeted"
        });
    }
    let Some(command) = command else {
        return json!({
            "status": "skipped",
            "exitCode": null,
            "summary": "CLI command is not on PATH.",
            "kind": "model-smoke"
        });
    };
    let smoke_dir = std::env::temp_dir().join(format!(
        "harvis-{}-smoke-{}",
        spec.harness_id,
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&smoke_dir);
    if let Err(error) = fs::create_dir_all(&smoke_dir) {
        return json!({"status": "failed", "exitCode": null, "summary": redact_local_paths(&error.to_string(), 180), "kind": "model-smoke"});
    }
    let output_path = smoke_dir.join("last-message.txt");
    let args = model_smoke_args(spec, &output_path);
    let output = run_command(
        command,
        &args,
        Some(&smoke_dir),
        Duration::from_secs(timeout_seconds as u64),
    );
    let _ = fs::remove_dir_all(&smoke_dir);
    let Ok(output) = output else {
        return json!({
            "status": "failed",
            "exitCode": if output.as_ref().err().is_some_and(|error| error == "timeout") { 124 } else { 0 },
            "summary": format!("{} model smoke test timed out.", spec.label),
            "kind": "model-smoke"
        });
    };
    let output_text = fs::read_to_string(&output_path).unwrap_or_default();
    let combined = format!("{output_text}\n{}\n{}", output.stdout, output.stderr);
    let ok_seen = combined.to_ascii_uppercase().contains("OK");
    let status = if output.exit_code == 0 && ok_seen {
        "passed"
    } else {
        "failed"
    };
    let first_line = combined
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or_else(|| "");
    let summary = if status == "passed" {
        format!("{} smoke test returned OK.", spec.label)
    } else if first_line.is_empty() {
        format!("{} returned no output.", spec.label)
    } else {
        redact_local_paths(first_line, 180)
    };
    json!({"status": status, "exitCode": output.exit_code, "summary": summary, "kind": "model-smoke"})
}

fn model_smoke_args(spec: &HarnessSpec, output_path: &Path) -> Vec<String> {
    let prompt = "Availability smoke test only. Do not inspect or modify files. Reply exactly OK.";
    if spec.harness_id == "cxspark" {
        return vec![
            "exec".into(),
            "--ignore-rules".into(),
            "--skip-git-repo-check".into(),
            "--ephemeral".into(),
            "--model".into(),
            "gpt-5.3-codex-spark".into(),
            "--sandbox".into(),
            "danger-full-access".into(),
            "--output-last-message".into(),
            output_path.display().to_string(),
            "--color".into(),
            "never".into(),
            "-c".into(),
            "model_reasoning_effort=\"low\"".into(),
            "--disable".into(),
            "hooks".into(),
            "--dangerously-bypass-approvals-and-sandbox".into(),
            prompt.into(),
        ];
    }
    if spec.harness_id == "likecode" {
        return vec![
            "-p".into(),
            "--model".into(),
            "d4p".into(),
            "--permission-mode".into(),
            "plan".into(),
            "--no-session-persistence".into(),
            "--output-format".into(),
            "text".into(),
            prompt.into(),
        ];
    }
    if spec.harness_id == "cckimi" {
        return vec!["-p".into(), prompt.into()];
    }
    if spec.harness_id == "mimocode" {
        return vec![
            "run".into(),
            "-m".into(),
            "xiaomi/mimo-v2.5-pro-ultraspeed".into(),
            "--dir".into(),
            "/tmp".into(),
            prompt.into(),
        ];
    }
    spec.version_args
        .iter()
        .map(|arg| (*arg).to_string())
        .collect()
}

fn derive_harness_state(
    requires_skill: bool,
    requires_wrapper: bool,
    skill_present: bool,
    wrapper: &Value,
    cli_present: bool,
    pending_reviews: usize,
    test_status: Option<&str>,
) -> (&'static str, String) {
    if requires_skill && !skill_present {
        return (
            "unavailable",
            "Skill directory is not installed.".to_string(),
        );
    }
    if requires_wrapper && !wrapper["wrapperPresent"].as_bool().unwrap_or(false) {
        return ("unavailable", "Delegation wrapper is missing.".to_string());
    }
    if !cli_present {
        return ("unavailable", "CLI command is not on PATH.".to_string());
    }
    if test_status == Some("passed") {
        if pending_reviews > 0 {
            return (
                "ready",
                format!("Smoke test passed; {pending_reviews} pending review record(s) still need audit."),
            );
        }
        return ("ready", "Smoke test passed.".to_string());
    }
    if test_status == Some("failed") {
        return ("failed", "Smoke test failed.".to_string());
    }
    if requires_wrapper && !wrapper["nativeWrapperPresent"].as_bool().unwrap_or(false) {
        return (
            "partial",
            "Wrapper exists, but this platform has no native wrapper.".to_string(),
        );
    }
    if pending_reviews > 0 {
        return (
            "ready",
            format!("Preflight prerequisites are present; {pending_reviews} pending review record(s) still need audit."),
        );
    }
    ("ready", "Preflight prerequisites are present.".to_string())
}

fn summarize(items: &[Value], run_tests: bool) -> (&'static str, String) {
    if run_tests {
        let targets = items
            .iter()
            .filter(|item| {
                item.get("testTarget")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            })
            .collect::<Vec<_>>();
        let failed = targets
            .iter()
            .filter(|item| item["test"]["status"].as_str() == Some("failed"))
            .count();
        let skipped = targets
            .iter()
            .filter(|item| item["test"]["status"].as_str() == Some("skipped"))
            .count();
        let passed = targets
            .iter()
            .filter(|item| item["test"]["status"].as_str() == Some("passed"))
            .count();
        if failed > 0 {
            return (
                "failed",
                format!("{failed} model smoke test(s) failed; {passed} passed, {skipped} skipped."),
            );
        }
        if skipped > 0 {
            return (
                "degraded",
                format!("{passed} model smoke test(s) passed; {skipped} skipped."),
            );
        }
        return ("ready", format!("{passed} model smoke test(s) passed."));
    }
    let count_status = |status: &str| {
        items
            .iter()
            .filter(|item| item.get("status").and_then(Value::as_str) == Some(status))
            .count()
    };
    let pending = count_status("needs_review");
    let failed = count_status("failed");
    let unavailable = count_status("unavailable");
    let partial = count_status("partial");
    let ready = count_status("ready");
    if pending > 0 {
        return (
            "needs_review",
            format!("{pending} harness run(s) are pending Codex review."),
        );
    }
    if failed > 0 {
        return (
            "failed",
            format!("{failed} harness preflight test(s) failed."),
        );
    }
    if unavailable > 0 || partial > 0 {
        return (
            "degraded",
            format!("{ready} ready, {partial} partial, {unavailable} unavailable."),
        );
    }
    ("ready", format!("{ready} harness(es) detected and ready."))
}

struct CommandOutput {
    exit_code: i32,
    stdout: String,
    stderr: String,
}

fn run_command(
    command: &str,
    args: &[String],
    cwd: Option<&Path>,
    timeout: Duration,
) -> Result<CommandOutput, String> {
    let mut command_builder = Command::new(command);
    command_builder
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = cwd {
        command_builder.current_dir(cwd);
    }
    let mut child = command_builder
        .spawn()
        .map_err(|error| redact_local_paths(&error.to_string(), 180))?;
    let started = Instant::now();
    loop {
        if child
            .try_wait()
            .map_err(|error| error.to_string())?
            .is_some()
        {
            let output = child
                .wait_with_output()
                .map_err(|error| error.to_string())?;
            return Ok(CommandOutput {
                exit_code: output.status.code().unwrap_or(1),
                stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            });
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err("timeout".to_string());
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn glob_suffix(dir: &Path, suffix: &str) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .ok()
        .into_iter()
        .flat_map(|entries| entries.flatten())
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(suffix))
        })
        .collect()
}

fn command_path(names: &[&str]) -> Option<String> {
    names
        .iter()
        .find(|name| command_exists(name))
        .map(|name| (*name).to_string())
}

fn command_exists(name: &str) -> bool {
    let path = Path::new(name);
    if path.components().count() > 1 {
        return path.exists();
    }
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(name).exists()))
        .unwrap_or(false)
}

fn redact_local_paths(value: &str, limit: usize) -> String {
    let mut text = value.trim().replace("\r\n", "\n").replace('\r', "\n");
    text = regex_replace(&text, r"/Users/[^/\s]+", "~");
    text = regex_replace(&text, r"/Volumes/[^/\s]+", "[volume]");
    text = regex_replace(&text, r"[A-Za-z]:\\Users\\[^\\\s]+", "~");
    let home = home_root().display().to_string();
    if !home.is_empty() {
        text = text.replace(&home, "~");
    }
    text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() > limit {
        return text
            .chars()
            .take(limit.saturating_sub(1))
            .collect::<String>()
            .trim_end()
            .to_string()
            + "...";
    }
    text
}

fn regex_replace(text: &str, pattern: &str, replacement: &str) -> String {
    regex::Regex::new(pattern)
        .map(|regex| regex.replace_all(text, replacement).to_string())
        .unwrap_or_else(|_| text.to_string())
}

fn skills_root() -> PathBuf {
    std::env::var("HARVIS_AGENT_HARNESS_SKILLS_ROOT")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| home_root().join(".codex/skills"))
}

fn home_root() -> PathBuf {
    std::env::var("HARVIS_AGENT_HARNESS_HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .or_else(|_| std::env::var("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("~"))
}

fn modified_secs(path: &Path) -> u64 {
    path.metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn string_or_null(value: &Value, key: &str) -> Value {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(|value| json!(value))
        .unwrap_or(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn agent_harnesses_launcher_ids_are_unique() {
        let mut launcher_ids = HashSet::new();

        for spec in HARNESS_SPECS {
            let Some(launch) = spec.launch else {
                continue;
            };
            assert!(
                launcher_ids.insert(launch.launcher_id),
                "duplicate launcherID: {}",
                launch.launcher_id
            );
        }
    }

    #[test]
    fn agent_harnesses_harness_entries_have_launch_descriptors() {
        for spec in HARNESS_SPECS
            .iter()
            .filter(|spec| spec.pool_kind == "harness")
        {
            assert!(
                spec.launch.is_some(),
                "interactive harness {} is missing a launch descriptor",
                spec.harness_id
            );
        }
    }

    #[test]
    fn agent_harnesses_cxspark_has_no_launch_descriptor() {
        let cxspark = HARNESS_SPECS
            .iter()
            .find(|spec| spec.harness_id == "cxspark")
            .expect("cxspark route must remain registered");

        assert_eq!(cxspark.pool_kind, "runtime-preset");
        assert!(cxspark.launch.is_none());
    }

    #[test]
    fn agent_harnesses_launch_json_contains_only_restricted_fields() {
        let expected_fields = [
            "kind",
            "launcherID",
            "mode",
            "productID",
            "workingDirectoryPolicy",
        ]
        .into_iter()
        .collect::<HashSet<_>>();

        for spec in HARNESS_SPECS.iter().filter(|spec| spec.launch.is_some()) {
            let launch = spec
                .launch
                .expect("launch descriptor checked above")
                .as_json();
            let object = launch
                .as_object()
                .expect("launch must serialize as an object");
            let actual_fields = object.keys().map(String::as_str).collect::<HashSet<_>>();

            assert_eq!(actual_fields, expected_fields, "{} launch", spec.harness_id);
            assert_eq!(object.get("kind").and_then(Value::as_str), Some("cli"));
            assert_eq!(
                object.get("mode").and_then(Value::as_str),
                Some("new-terminal-session")
            );
            assert_eq!(
                object.get("workingDirectoryPolicy").and_then(Value::as_str),
                Some("workspace-root")
            );
            for forbidden in ["command", "path", "args"] {
                assert!(
                    !object.contains_key(forbidden),
                    "{} launch exposed forbidden field {forbidden}",
                    spec.harness_id
                );
            }
        }
    }
}
