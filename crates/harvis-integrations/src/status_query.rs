use anyhow::Result;
use regex::Regex;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use harvis_runtime::agent_room::{list_handoffs, list_tasks};

pub fn is_status_query(text: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(
            r"(?i)(有答案了吗|结果呢|任务状态|查任务|查询任务|任务进度|进度如何|实验进度|进展|哪一步|到哪|卡在哪|卡住|执行状态|运行状态|正在运行|运行中|开始执行了吗|执行了吗|做了吗|跑起来了吗|跑了吗|完成了吗|完了吗|有反馈吗|有没有反馈|为什么没有反馈|没反馈|暂时做不了|做不了吗|需要我批复吗|需要我审批吗|要我批复吗|要我审批吗|等待批复|等待审批|可以执行吗|codex\s*线程|哪些线程|有哪些线程|where\s+are\s+we|task\s+status|run\s+status|execution\s+status|\bstatus\s*\??$|\bprogress\s*\??$)",
        )
        .expect("valid status query regex")
    });
    re.is_match(text)
}

pub fn is_approval_query(text: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(
            r"(?i)(需要我批复吗|需要我审批吗|要我批复吗|要我审批吗|等我批复|等我审批|等待批复|等待审批|可以执行吗|能执行了吗|审批状态|批准状态|待我审批|待我批复|需要我操作吗|要我操作吗)",
        )
        .expect("valid approval query regex")
    });
    re.is_match(text)
}

pub fn recent_executions(root: &Path, limit: usize) -> Vec<Value> {
    let mut rows = Vec::new();
    for exec_root in execution_roots(root) {
        let Ok(entries) = fs::read_dir(exec_root) else {
            continue;
        };
        rows.extend(entries.flatten().filter_map(|entry| {
            let path = entry.path().join("status.json");
            let metadata = fs::metadata(&path).ok()?;
            let modified = metadata.modified().ok()?;
            let text = fs::read_to_string(&path).ok()?;
            let mut value = serde_json::from_str::<Value>(&text).ok()?;
            value["status_path"] = json!(path.display().to_string());
            Some((modified, value))
        }));
    }
    rows.sort_by(|left, right| right.0.cmp(&left.0));
    rows.into_iter()
        .take(limit)
        .map(|(_, value)| value)
        .collect()
}

fn execution_roots(root: &Path) -> Vec<PathBuf> {
    let mut roots = vec![root.join(".harvis/executions")];
    if let Some(home) = std::env::var_os("HOME") {
        let workspace_hash = workspace_hash(root);
        roots.push(
            PathBuf::from(home)
                .join(".harvis/executions")
                .join(workspace_hash),
        );
    }
    roots
}

fn workspace_hash(root: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(root.display().to_string().as_bytes());
    let digest = hasher.finalize();
    digest[..8]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn single_item_status(root: &Path, text: &str) -> Result<Value> {
    let Some(target) = parse_status_target(text) else {
        return Ok(json!({"target": Value::Null, "matched": false}));
    };
    let tasks = list_tasks(root, None, None, 5000)?
        .get("tasks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let handoffs = list_handoffs(root, 5000)?
        .get("handoffs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let executions = recent_executions(root, 5000);

    let task = tasks
        .iter()
        .find(|task| task_matches(task, &target))
        .cloned();
    let handoff = handoffs
        .iter()
        .find(|handoff| handoff_matches(handoff, &target, task.as_ref()))
        .cloned();
    let run = find_run(root, &target, task.as_ref(), handoff.as_ref());
    let execution = executions
        .iter()
        .find(|execution| execution_matches(execution, &target, task.as_ref(), handoff.as_ref()))
        .cloned();
    let matched = task.is_some() || handoff.is_some() || run.is_some() || execution.is_some();
    let response_text = item_response_text(
        &target,
        task.as_ref(),
        handoff.as_ref(),
        run.as_ref(),
        execution.as_ref(),
        matched,
    );

    Ok(json!({
        "target": {
            "kind": target.kind,
            "id": target.id
        },
        "matched": matched,
        "task": task.unwrap_or(Value::Null),
        "handoff": handoff.unwrap_or(Value::Null),
        "run": run.unwrap_or(Value::Null),
        "execution": execution.unwrap_or(Value::Null),
        "response_text": response_text
    }))
}

#[derive(Debug, Clone)]
struct StatusTarget {
    kind: String,
    id: String,
}

fn parse_status_target(text: &str) -> Option<StatusTarget> {
    for (kind, pattern) in [
        ("task", r"\b(task_[A-Za-z0-9_-]{4,120})\b"),
        ("handoff", r"\b(handoff_[A-Za-z0-9_-]{4,160})\b"),
        ("run", r"\b(run_[A-Za-z0-9_-]{4,160})\b"),
        ("packet", r"(?i)\bpacket\s+([A-Za-z0-9_-]{4,80})\b"),
    ] {
        let re = Regex::new(pattern).expect("valid status target regex");
        if let Some(captures) = re.captures(text) {
            if let Some(id) = captures.get(1).map(|item| item.as_str().to_string()) {
                return Some(StatusTarget {
                    kind: kind.to_string(),
                    id,
                });
            }
        }
    }

    static BARE_PACKET: OnceLock<Regex> = OnceLock::new();
    let re = BARE_PACKET
        .get_or_init(|| Regex::new(r"\b([A-Fa-f0-9]{8,24})\b").expect("valid packet regex"));
    re.captures(text)
        .and_then(|captures| captures.get(1).map(|item| item.as_str().to_string()))
        .map(|id| StatusTarget {
            kind: "packet".to_string(),
            id,
        })
}

fn task_matches(task: &Value, target: &StatusTarget) -> bool {
    match target.kind.as_str() {
        "task" => value_eq(task, "task_id", &target.id),
        "run" => value_eq(task, "run_id", &target.id),
        "handoff" => value_eq(task, "handoff_id", &target.id),
        "packet" => {
            value_eq(task, "packet_id", &target.id)
                || task
                    .get("metadata")
                    .and_then(|metadata| metadata.get("packet_ids"))
                    .and_then(Value::as_array)
                    .is_some_and(|ids| {
                        ids.iter()
                            .filter_map(Value::as_str)
                            .any(|id| id == target.id)
                    })
        }
        _ => false,
    }
}

fn handoff_matches(handoff: &Value, target: &StatusTarget, task: Option<&Value>) -> bool {
    match target.kind.as_str() {
        "handoff" => value_eq(handoff, "handoff_id", &target.id),
        "run" => value_eq(handoff, "run_id", &target.id),
        "packet" => value_eq(handoff, "packet_id", &target.id),
        "task" => task
            .and_then(|task| task.get("handoff_id").and_then(Value::as_str))
            .is_some_and(|id| handoff.get("handoff_id").and_then(Value::as_str) == Some(id)),
        _ => false,
    }
}

fn execution_matches(
    execution: &Value,
    target: &StatusTarget,
    task: Option<&Value>,
    handoff: Option<&Value>,
) -> bool {
    if direct_execution_match(execution, target) {
        return true;
    }
    if let Some(task) = task {
        if task
            .get("run_id")
            .and_then(Value::as_str)
            .is_some_and(|id| execution.get("run_id").and_then(Value::as_str) == Some(id))
            || task
                .get("packet_id")
                .and_then(Value::as_str)
                .is_some_and(|id| execution.get("packet_id").and_then(Value::as_str) == Some(id))
        {
            return true;
        }
    }
    if let Some(handoff) = handoff {
        if handoff
            .get("run_id")
            .and_then(Value::as_str)
            .is_some_and(|id| execution.get("run_id").and_then(Value::as_str) == Some(id))
            || handoff
                .get("packet_id")
                .and_then(Value::as_str)
                .is_some_and(|id| execution.get("packet_id").and_then(Value::as_str) == Some(id))
        {
            return true;
        }
    }
    false
}

fn direct_execution_match(execution: &Value, target: &StatusTarget) -> bool {
    match target.kind.as_str() {
        "run" => value_eq(execution, "run_id", &target.id),
        "packet" => value_eq(execution, "packet_id", &target.id),
        "handoff" => value_eq(execution, "handoff_id", &target.id),
        _ => false,
    }
}

fn find_run(
    root: &Path,
    target: &StatusTarget,
    task: Option<&Value>,
    handoff: Option<&Value>,
) -> Option<Value> {
    let run_id = match target.kind.as_str() {
        "run" => Some(target.id.clone()),
        "packet" => task
            .and_then(|task| {
                task.get("run_id")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .or_else(|| Some(format!("run_{}", target.id))),
        "task" => task.and_then(|task| {
            task.get("run_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        }),
        "handoff" => handoff.and_then(|handoff| {
            handoff
                .get("run_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        }),
        _ => None,
    }?;
    let path = root.join(".harvis/runs").join(format!("{run_id}.json"));
    let text = fs::read_to_string(path).ok()?;
    serde_json::from_str::<Value>(&text).ok()
}

fn value_eq(value: &Value, key: &str, expected: &str) -> bool {
    value.get(key).and_then(Value::as_str) == Some(expected)
}

fn item_response_text(
    target: &StatusTarget,
    task: Option<&Value>,
    handoff: Option<&Value>,
    run: Option<&Value>,
    execution: Option<&Value>,
    matched: bool,
) -> String {
    let mut lines = vec![format!(
        "H.A.R.V.I.S. 单项进展：{}={}",
        target.kind, target.id
    )];
    if !matched {
        lines.push("没有在 task board / handoff / run / execution 中找到这个 ID。".to_string());
        lines.push(
            "你可以继续发“查询任务”查看总览，或补充 packet/task/handoff/run ID。".to_string(),
        );
        return lines.join("\n");
    }
    if let Some(task) = task {
        lines.push(format!("Task: {}", task_line(task)));
    }
    if let Some(handoff) = handoff {
        lines.push(format!("Handoff: {}", handoff_line(handoff)));
    }
    if let Some(run) = run {
        lines.push(format!("Run: {}", run_line(run)));
    }
    if let Some(execution) = execution {
        lines.push(format!("Execution: {}", execution_line(execution)));
    }
    lines.join("\n")
}

fn task_line(task: &Value) -> String {
    format!(
        "{} | {} | {} | packet={} | run={} | handoff={}",
        text_field(task, "task_id", "unknown"),
        text_field(task, "status", "unknown"),
        compact_field(task, "title", 120),
        text_field(task, "packet_id", "none"),
        text_field(task, "run_id", "none"),
        text_field(task, "handoff_id", "none")
    )
}

fn handoff_line(handoff: &Value) -> String {
    format!(
        "{} | {} | harness={} | run={} | packet={} | result={} | exit={}",
        text_field(handoff, "handoff_id", "unknown"),
        text_field(handoff, "state", "unknown"),
        text_field(handoff, "harness", "unknown"),
        text_field(handoff, "run_id", "none"),
        text_field(handoff, "packet_id", "none"),
        text_field(handoff, "result_path", "none"),
        text_field(handoff, "exit_code", "none")
    )
}

fn run_line(run: &Value) -> String {
    format!(
        "{} | state={} | packet={} | updated={} | approval_required={}",
        text_field(run, "run_id", "unknown"),
        text_field(run, "state", "unknown"),
        text_field(run, "packet_id", "none"),
        text_field(run, "updated_at", "unknown"),
        run.get("approval")
            .and_then(|approval| approval.get("required"))
            .cloned()
            .unwrap_or(Value::Null)
    )
}

fn execution_line(execution: &Value) -> String {
    format!(
        "status={} | packet={} | run={} | exit={} | log={}",
        text_field(execution, "status", "unknown"),
        text_field(execution, "packet_id", "none"),
        text_field(execution, "run_id", "none"),
        execution
            .get("exit_code")
            .map(Value::to_string)
            .unwrap_or_else(|| "none".to_string()),
        text_field(execution, "exec_dir", "none")
    )
}

fn text_field<'a>(value: &'a Value, key: &str, fallback: &'a str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or(fallback)
}

fn compact_field(value: &Value, key: &str, limit: usize) -> String {
    let text = text_field(value, key, "");
    let clean = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if clean.chars().count() <= limit {
        return clean;
    }
    let mut clipped = clean
        .chars()
        .take(limit.saturating_sub(1))
        .collect::<String>();
    clipped.push('…');
    clipped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_explicit_and_bare_status_targets() {
        let cases = [
            ("c3643ec6564c 进展如何", "packet", "c3643ec6564c"),
            ("packet c3643ec6564c status", "packet", "c3643ec6564c"),
            (
                "task_20260628T065547Z_16f27d8a17 状态",
                "task",
                "task_20260628T065547Z_16f27d8a17",
            ),
            (
                "handoff_20260628T054654Z_3e20909b7b 怎么样",
                "handoff",
                "handoff_20260628T054654Z_3e20909b7b",
            ),
            ("run_c3643ec6564c 有答案了吗", "run", "run_c3643ec6564c"),
        ];
        for (text, kind, id) in cases {
            let target = parse_status_target(text).expect(text);
            assert_eq!(target.kind, kind);
            assert_eq!(target.id, id);
        }
    }
}
