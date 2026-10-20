use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

use crate::agent_pools::{select_runtime_route, RuntimeSelectionOptions};
use crate::agent_room::{add_event_with_metadata, workspace_state};
use harvis_core::time::now_rfc3339;

pub const CHAIR_ORCHESTRATOR_VERSION: &str = "v0.56-chair-dry-run";

#[derive(Debug, Clone)]
pub struct ChairStepOptions {
    pub root: PathBuf,
    pub topic_id: Option<String>,
    pub dry_run: bool,
}

pub fn chair_step(options: ChairStepOptions) -> Result<Value> {
    if !options.dry_run {
        bail!("chair dry-run=false is not enabled yet; model calls require the next approval gate");
    }
    let root = resolve_workspace_root(&options.root)?;
    let state = workspace_state(&root, options.topic_id.as_deref(), 50)?;
    let proposed_move = propose_move(&root, &state);
    let topic_id = state
        .get("active_topic")
        .and_then(|topic| topic.get("topic_id"))
        .and_then(Value::as_str)
        .unwrap_or("gwt-workbench");
    let decision = add_event_with_metadata(
        &root,
        topic_id,
        "harvis-chair",
        "chair",
        "decision_record",
        proposed_move
            .get("summary")
            .and_then(Value::as_str)
            .unwrap_or("Chair dry-run proposed a move."),
        Vec::new(),
        "internal",
        None,
        json!({
            "chair_orchestrator_version": CHAIR_ORCHESTRATOR_VERSION,
            "dry_run": true,
            "proposed_move": proposed_move,
            "route_reason": proposed_move.get("reason").cloned().unwrap_or(Value::Null),
            "model_call": false,
            "executes_task": false
        }),
    )?;
    Ok(json!({
        "chair_orchestrator_version": CHAIR_ORCHESTRATOR_VERSION,
        "dry_run": true,
        "model_call": false,
        "workspace": state.get("workspace").cloned().unwrap_or(Value::Null),
        "proposed_move": proposed_move,
        "decision_record": decision,
        "created_at": now_rfc3339()?,
        "safety": {
            "executes_task": false,
            "calls_model": false,
            "requires_approval_for_execution": true
        }
    }))
}

fn propose_move(root: &Path, state: &Value) -> Value {
    let open_tasks = state
        .get("open_tasks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let unread_mailbox = state
        .get("unread_mailbox")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let pending_approvals = state
        .get("pending_approvals")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    if let Some(approval) = pending_approvals.first() {
        return json!({
            "action": "ask_user",
            "target_slot_id": "harvis-chair",
            "reason": "pending_approval_exists",
            "summary": "A pending approval requires human decision before execution can continue.",
            "approval_id": approval.get("approval_id").cloned().unwrap_or(Value::Null)
        });
    }
    let waiting_approval_tasks: Vec<Value> = open_tasks
        .iter()
        .filter(|task| task.get("status").and_then(Value::as_str) == Some("waiting_approval"))
        .cloned()
        .collect();
    if let Some(task) = waiting_approval_tasks.first() {
        let runtime_selection = runtime_selection_for_task(root, task);
        return json!({
            "action": "request_approval",
            "target_slot_id": task.get("owner_slot_id").cloned().unwrap_or_else(|| json!("executor")),
            "reason": "task_waiting_approval",
            "summary": if waiting_approval_tasks.len() > 1 {
                format!("{} tasks are waiting for explicit approval before execution.", waiting_approval_tasks.len())
            } else {
                "A task is waiting for explicit approval before execution.".to_string()
            },
            "task_id": task.get("task_id").cloned().unwrap_or(Value::Null),
            "packet_id": task.get("packet_id").cloned().unwrap_or(Value::Null),
            "runtime_selection": runtime_selection,
            "waiting_approval_count": waiting_approval_tasks.len(),
            "waiting_approval_tasks": waiting_approval_tasks.iter().take(5).map(task_summary).collect::<Vec<_>>()
        });
    }
    if let Some(mail) = unread_mailbox.first() {
        return json!({
            "action": "summarize",
            "target_slot_id": mail.get("to_slot_id").cloned().unwrap_or_else(|| json!("harvis-chair")),
            "reason": "unread_mailbox",
            "summary": "There is unread slot mailbox coordination that should be reviewed.",
            "mail_id": mail.get("mail_id").cloned().unwrap_or(Value::Null)
        });
    }
    if let Some(task) = open_tasks
        .iter()
        .find(|task| task.get("status").and_then(Value::as_str) == Some("pending"))
    {
        let owner = task
            .get("owner_slot_id")
            .and_then(Value::as_str)
            .unwrap_or("planner");
        let runtime_selection = runtime_selection_for_task(root, task);
        return json!({
            "action": "delegate_task",
            "target_slot_id": owner,
            "reason": "pending_task",
            "summary": format!("Delegate pending task to {owner}."),
            "task_id": task.get("task_id").cloned().unwrap_or(Value::Null),
            "runtime_selection": runtime_selection
        });
    }
    if let Some(task) = open_tasks
        .iter()
        .find(|task| task.get("status").and_then(Value::as_str) == Some("reviewing"))
    {
        return json!({
            "action": "summarize",
            "target_slot_id": "reviewer",
            "reason": "task_in_review",
            "summary": "A task is in review; summarize outcome and decide whether it can be marked done.",
            "task_id": task.get("task_id").cloned().unwrap_or(Value::Null)
        });
    }
    json!({
        "action": "ask_user",
        "target_slot_id": "harvis-chair",
        "reason": "no_open_work",
        "summary": "No open task requires action. Ask the user for the next task."
    })
}

fn runtime_selection_for_task(root: &Path, task: &Value) -> Value {
    let text = [
        task.get("title").and_then(Value::as_str).unwrap_or(""),
        task.get("description")
            .and_then(Value::as_str)
            .unwrap_or(""),
    ]
    .into_iter()
    .filter(|item| !item.trim().is_empty())
    .collect::<Vec<_>>()
    .join("\n");
    let selected_preset = task
        .get("metadata")
        .and_then(|metadata| metadata.get("selected_preset"))
        .filter(|value| !value.is_null())
        .cloned();
    match select_runtime_route(RuntimeSelectionOptions {
        root: root.to_path_buf(),
        path: None,
        text,
        selected_preset,
        owner_slot_id: task
            .get("owner_slot_id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    }) {
        Ok(value) => value,
        Err(error) => json!({
            "schemaVersion": "harvis.agent-pools.v0",
            "selection_version": "harvis.runtime-selection.v0",
            "error": error.to_string(),
            "selected": Value::Null,
            "safety": {
                "executes_task": false,
                "model_call": false,
                "requires_approval_for_execution": true
            }
        }),
    }
}

fn task_summary(task: &Value) -> Value {
    json!({
        "task_id": task.get("task_id").cloned().unwrap_or(Value::Null),
        "title": task.get("title").cloned().unwrap_or(Value::Null),
        "owner_slot_id": task.get("owner_slot_id").cloned().unwrap_or(Value::Null),
        "status": task.get("status").cloned().unwrap_or(Value::Null),
        "packet_id": task.get("packet_id").cloned().unwrap_or(Value::Null)
    })
}

fn resolve_workspace_root(value: &Path) -> Result<PathBuf> {
    if value.as_os_str().is_empty() {
        bail!("workspace root must be a non-empty path");
    }
    if value.is_absolute() {
        Ok(value.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(value))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_room::{create_task, TaskInput};
    use crate::init::init_workspace;
    use std::fs;

    #[test]
    fn dry_run_requests_approval_for_waiting_task() {
        let root =
            std::env::temp_dir().join(format!("harvis-chair-dry-run-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        create_task(
            &root,
            TaskInput {
                title: "Needs approval".to_string(),
                owner_slot_id: "executor".to_string(),
                status: Some("waiting_approval".to_string()),
                packet_id: Some("packet12345".to_string()),
                ..TaskInput::default()
            },
        )
        .expect("task");
        let result = chair_step(ChairStepOptions {
            root: root.clone(),
            topic_id: None,
            dry_run: true,
        })
        .expect("chair step");
        assert_eq!(result["proposed_move"]["action"], "request_approval");
        assert_eq!(result["model_call"], false);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn dry_run_exposes_multiple_waiting_approval_tasks() {
        let root = std::env::temp_dir().join(format!(
            "harvis-chair-multi-waiting-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        for index in 0..2 {
            create_task(
                &root,
                TaskInput {
                    title: format!("Needs approval {index}"),
                    owner_slot_id: "executor".to_string(),
                    status: Some("waiting_approval".to_string()),
                    packet_id: Some(format!("packet{index}")),
                    ..TaskInput::default()
                },
            )
            .expect("task");
        }
        let result = chair_step(ChairStepOptions {
            root: root.clone(),
            topic_id: None,
            dry_run: true,
        })
        .expect("chair step");
        assert_eq!(result["proposed_move"]["action"], "request_approval");
        assert_eq!(result["proposed_move"]["waiting_approval_count"], 2);
        assert_eq!(
            result["proposed_move"]["waiting_approval_tasks"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        let _ = fs::remove_dir_all(root);
    }
}
