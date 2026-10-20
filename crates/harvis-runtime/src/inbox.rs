use anyhow::{bail, Result};
use regex::Regex;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use harvis_core::time::now_rfc3339;

#[derive(Debug, Clone)]
pub struct HarvisTask {
    pub source: PathBuf,
    pub line_number: usize,
    pub body: String,
}

impl HarvisTask {
    pub fn task_id(&self, root: &Path) -> String {
        let source_label = source_label(&self.source, root);
        let seed = format!("{}:{}:{}", source_label, self.line_number, self.body);
        let digest = Sha256::digest(seed.as_bytes());
        digest
            .iter()
            .take(6)
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

#[derive(Debug, Clone)]
pub struct ScanOptions {
    pub root: PathBuf,
    pub inboxes: Vec<PathBuf>,
    pub allow_outside_root: bool,
}

pub fn scan_inboxes(options: ScanOptions) -> Result<Vec<PathBuf>> {
    let root = normalize_root(&options.root)?;
    let inboxes = if options.inboxes.is_empty() {
        vec![root.join(".harvis/inbox.md")]
    } else {
        options.inboxes
    };
    let outbox = root.join(".harvis/outbox");
    fs::create_dir_all(&outbox)?;
    let mut written = Vec::new();

    for inbox in inboxes {
        let inbox_path = normalize_inbox_path(&inbox)?;
        if !options.allow_outside_root && !is_within_root(&inbox_path, &root) {
            bail!("refusing to scan outside root: {}", inbox_path.display());
        }
        for task in parse_tasks(&inbox_path)? {
            let task_id = task.task_id(&root);
            let packet_path = outbox.join(format!("{task_id}.md"));
            fs::write(&packet_path, packet_for_task(&task, &root)?)?;
            written.push(packet_path);
        }
    }

    Ok(written)
}

fn normalize_root(value: &Path) -> Result<PathBuf> {
    let root = expanduser(value);
    if root.as_os_str().is_empty() {
        bail!("workspace root must be a non-empty path");
    }
    if root.is_absolute() {
        Ok(root)
    } else {
        Ok(std::env::current_dir()?.join(root))
    }
}

fn normalize_inbox_path(value: &Path) -> Result<PathBuf> {
    let path = expanduser(value);
    if path.as_os_str().is_empty() {
        bail!("inbox path must be non-empty");
    }
    if path.is_absolute() {
        Ok(path)
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

pub fn parse_tasks(inbox_path: &Path) -> Result<Vec<HarvisTask>> {
    let text = fs::read_to_string(inbox_path)?;
    let mut tasks = Vec::new();
    let mut current_start: Option<usize> = None;
    let mut current_lines: Vec<String> = Vec::new();

    for (index, line) in text.lines().enumerate() {
        let line_number = index + 1;
        if is_task_marker(line) {
            flush_task(
                inbox_path,
                &mut tasks,
                &mut current_start,
                &mut current_lines,
            );
            current_start = Some(line_number);
            current_lines.push(line.to_string());
            continue;
        }
        if current_start.is_none() {
            continue;
        }
        if line.trim_start().starts_with('#') {
            flush_task(
                inbox_path,
                &mut tasks,
                &mut current_start,
                &mut current_lines,
            );
            continue;
        }
        current_lines.push(line.to_string());
    }
    flush_task(
        inbox_path,
        &mut tasks,
        &mut current_start,
        &mut current_lines,
    );
    Ok(tasks)
}

fn flush_task(
    inbox_path: &Path,
    tasks: &mut Vec<HarvisTask>,
    current_start: &mut Option<usize>,
    current_lines: &mut Vec<String>,
) {
    let Some(line_number) = current_start.take() else {
        return;
    };
    let body = current_lines
        .iter()
        .map(|line| line.trim_end())
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    current_lines.clear();
    if body.is_empty() {
        return;
    }
    tasks.push(HarvisTask {
        source: inbox_path.to_path_buf(),
        line_number,
        body,
    });
}

fn packet_for_task(task: &HarvisTask, root: &Path) -> Result<String> {
    let task_id = task.task_id(root);
    let (status, safety_note) = classify_task(&task.body);
    let generated_at = now_rfc3339()?;
    let source = source_label(&task.source, root);
    Ok([
        format!("# H.A.R.V.I.S. Work Packet {task_id}"),
        String::new(),
        format!("Status: {status}"),
        format!("Source: {source}:{}", task.line_number),
        format!("Generated: {generated_at}"),
        "Scope: current H.A.R.V.I.S. workspace".to_string(),
        format!("Safety: {safety_note}"),
        String::new(),
        "## Request".to_string(),
        String::new(),
        "```text".to_string(),
        task.body.clone(),
        "```".to_string(),
        String::new(),
        "## Suggested Plan".to_string(),
        String::new(),
        "1. Read local project rules and relevant docs.".to_string(),
        "2. Confirm the request stays inside the current workspace and approved context."
            .to_string(),
        "3. Execute the smallest safe next action, or ask one focused question if blocked."
            .to_string(),
        "4. Verify the result and report files touched, checks run, and follow-ups.".to_string(),
        String::new(),
        "## Verification Checklist".to_string(),
        String::new(),
        "- Confirm no source files outside `.harvis/` were changed by inbox scanning.".to_string(),
        "- Confirm sensitive or private material was not copied into public artifacts.".to_string(),
        "- Confirm any publish, commit, push, or destructive action has explicit approval."
            .to_string(),
        String::new(),
    ]
    .join("\n"))
}

fn is_task_marker(line: &str) -> bool {
    static TASK_MARKER: OnceLock<Regex> = OnceLock::new();
    let regex = TASK_MARKER.get_or_init(|| {
        Regex::new(r"^\s*(?:[-*]\s+(?:\[[ xX]\]\s+)?)?@harvis\b").expect("valid marker regex")
    });
    regex.is_match(line)
}

fn classify_task(body: &str) -> (&'static str, &'static str) {
    if sensitive_patterns()
        .iter()
        .any(|pattern| pattern.is_match(body))
    {
        ("blocked", "sensitive-looking content requires human review")
    } else {
        ("new", "no sensitive marker detected")
    }
}

fn sensitive_patterns() -> &'static [Regex] {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            r"\bapi[_-]?key\b",
            r"\bsecret\b",
            r"\btoken\b",
            r"\bpassword\b",
            r"\bcookie\b",
            r"\bcredential\b",
            r"\bprivate\s+key\b",
            r"\.env\b",
            r"BEGIN\s+(RSA\s+|OPENSSH\s+|EC\s+)?PRIVATE\s+KEY",
        ]
        .iter()
        .map(|pattern| Regex::new(&format!("(?i){pattern}")).expect("valid sensitive regex"))
        .collect()
    })
}

fn source_label(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .map(|relative| {
            relative
                .to_string_lossy()
                .replace(std::path::MAIN_SEPARATOR, "/")
        })
        .unwrap_or_else(|_| path.display().to_string())
}

fn is_within_root(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
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
    fn scans_inbox_into_work_packet() {
        let root =
            std::env::temp_dir().join(format!("harvis-inbox-rust-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init workspace");
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis review this fixture.\nScope: current workspace.\n",
        )
        .expect("write inbox");

        let written = scan_inboxes(ScanOptions {
            root: root.clone(),
            inboxes: Vec::new(),
            allow_outside_root: false,
        })
        .expect("scan inbox");

        assert_eq!(written.len(), 1);
        let packet = fs::read_to_string(&written[0]).expect("read packet");
        assert!(packet.contains("Status: new"));
        assert!(packet.contains("Source: .harvis/inbox.md:1"));
        assert!(packet.contains("@harvis review this fixture."));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn sensitive_tasks_are_blocked() {
        let root = std::env::temp_dir().join(format!(
            "harvis-inbox-sensitive-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init workspace");
        fs::write(
            root.join(".harvis/inbox.md"),
            "@harvis use this token: abc\n",
        )
        .expect("write inbox");

        let written = scan_inboxes(ScanOptions {
            root: root.clone(),
            inboxes: Vec::new(),
            allow_outside_root: false,
        })
        .expect("scan inbox");

        let packet = fs::read_to_string(&written[0]).expect("read packet");
        assert!(packet.contains("Status: blocked"));

        let _ = fs::remove_dir_all(root);
    }
}
