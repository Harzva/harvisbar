use anyhow::{bail, Result};
use regex::Regex;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use crate::router::{route_message, RouteMessageOptions};
use crate::status_query::{
    is_approval_query, is_status_query, recent_executions, single_item_status,
};
use harvis_runtime::agent_room::{
    add_event_with_metadata, list_tasks, recent_conversation_context, record_conversation_state,
    workspace_state, ConversationInput,
};
use harvis_runtime::chair::{chair_step, ChairStepOptions};
use harvis_runtime::projects::{list_projects, ProjectListOptions};

pub const AGENT_GATEWAY_VERSION: &str = "harvis.agent_gateway.v0";

#[derive(Debug, Clone)]
pub struct AgentStepOptions {
    pub root: PathBuf,
    pub channel: String,
    pub sender: String,
    pub message: String,
    pub chat_id: Option<String>,
    pub message_id: Option<String>,
    pub context: Vec<String>,
    pub include_paths: bool,
    pub map_path: Option<PathBuf>,
    pub agent_pools_path: Option<PathBuf>,
    pub topic_id: Option<String>,
    pub chair_dry_run: bool,
}

pub fn agent_step(options: AgentStepOptions) -> Result<Value> {
    let root = normalize_root(&options.root)?;
    let text = options.message.trim();
    if text.is_empty() {
        bail!("message must be non-empty");
    }

    if is_approval_query(text) {
        return routed_step(&root, &options, text);
    }
    if is_status_query(text) {
        return status_step(&root, &options);
    }
    if is_project_lookup_query(text) {
        return project_lookup_step(&root, &options);
    }

    routed_step(&root, &options, text)
}

fn routed_step(root: &Path, options: &AgentStepOptions, text: &str) -> Result<Value> {
    let route = route_message(RouteMessageOptions {
        root: root.to_path_buf(),
        transport: options.channel.clone(),
        sender: options.sender.clone(),
        text: text.to_string(),
        chat_id: options.chat_id.clone(),
        message_id: options.message_id.clone(),
        context: options.context.clone(),
        include_paths: options.include_paths,
        map_path: options.map_path.clone(),
        agent_pools_path: options.agent_pools_path.clone(),
    })?;
    let chair = if options.chair_dry_run {
        chair_step(ChairStepOptions {
            root: root.to_path_buf(),
            topic_id: options.topic_id.clone(),
            dry_run: true,
        })?
    } else {
        Value::Null
    };
    let state = workspace_state(&root, options.topic_id.as_deref(), 20)?;
    let response_text = response_text(&route, &chair);
    let next_expected_action = next_expected_action(&route, &chair);
    let route_next_expected_action = route_next_expected_action(&route);
    let chair_next_expected_action = chair_next_expected_action(&chair);
    let runtime_selection = runtime_selection(&route, &chair);
    let requires_approval_for_execution = route
        .get("safety")
        .and_then(|safety| safety.get("requires_approval_for_execution"))
        .and_then(Value::as_bool)
        .unwrap_or(true);

    Ok(json!({
        "agent_gateway_version": AGENT_GATEWAY_VERSION,
        "status": "ok",
        "channel": options.channel,
        "sender": options.sender,
        "chat_id": options.chat_id,
        "message_id": options.message_id,
        "message": text,
        "intent": route.get("intent").cloned().unwrap_or_else(|| json!("unknown")),
        "route_state": route.get("route_state").cloned().unwrap_or_else(|| json!("unknown")),
        "route": route,
        "chair_dry_run": chair,
        "runtime_selection": runtime_selection,
        "workspace_state": state,
        "response_text": response_text,
        "next_expected_action": next_expected_action,
        "route_next_expected_action": route_next_expected_action,
        "chair_next_expected_action": chair_next_expected_action,
        "safety": {
            "executes_task": false,
            "model_call": false,
            "requires_approval_for_execution": requires_approval_for_execution
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

fn status_step(root: &Path, options: &AgentStepOptions) -> Result<Value> {
    let state = workspace_state(root, options.topic_id.as_deref(), 20)?;
    let chair = if options.chair_dry_run {
        chair_step(ChairStepOptions {
            root: root.to_path_buf(),
            topic_id: options.topic_id.clone(),
            dry_run: true,
        })?
    } else {
        Value::Null
    };
    let executions = recent_executions(root, 8);
    let topic_id = state
        .get("active_topic")
        .and_then(|topic| topic.get("topic_id"))
        .and_then(Value::as_str)
        .unwrap_or("gwt-workbench");
    let _ = add_event_with_metadata(
        root,
        topic_id,
        "harvis-chair",
        "chair",
        "status_query",
        options.message.trim(),
        Vec::new(),
        "internal",
        None,
        json!({
            "channel": options.channel,
            "chat_id": options.chat_id,
            "message_id": options.message_id,
            "agent_gateway_version": AGENT_GATEWAY_VERSION
        }),
    );
    let mut detail = single_item_status(root, options.message.trim())?;
    let mut context_resolution = Value::Null;
    if detail.get("target").is_none_or(Value::is_null) {
        if let Some(context) = infer_recent_status_target(root, options)? {
            if let Some(packet_id) = context.get("packet_id").and_then(Value::as_str) {
                detail = single_item_status(root, &format!("{packet_id} 进展如何"))?;
                context_resolution = context;
            } else if let Some(run_id) = context.get("run_id").and_then(Value::as_str) {
                detail = single_item_status(root, &format!("{run_id} 进展如何"))?;
                context_resolution = context;
            }
        }
    }
    let detail_targeted = !detail.get("target").is_none_or(Value::is_null);
    let response_text = if detail_targeted {
        detail
            .get("response_text")
            .and_then(Value::as_str)
            .unwrap_or("H.A.R.V.I.S. 单项进展查询没有生成文本。")
            .to_string()
    } else {
        status_response_text(&state, &chair, &executions)
    };
    let _ = record_conversation_state(
        root,
        ConversationInput {
            transport: options.channel.clone(),
            chat_id: options.chat_id.clone(),
            sender: Some(options.sender.clone()),
            message_id: options.message_id.clone(),
            intent: Some("status_query".to_string()),
            route_state: Some("status".to_string()),
            task_id: context_resolution
                .get("task_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            packet_id: context_resolution
                .get("packet_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
                .or_else(|| {
                    let target = detail.get("target")?;
                    (target.get("kind").and_then(Value::as_str) == Some("packet"))
                        .then(|| {
                            target
                                .get("id")
                                .and_then(Value::as_str)
                                .map(ToOwned::to_owned)
                        })
                        .flatten()
                }),
            run_id: context_resolution
                .get("run_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            handoff_id: context_resolution
                .get("handoff_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            summary: Some("Status query projected for this conversation.".to_string()),
            metadata: Some(json!({
                "context_resolution": context_resolution.clone(),
                "detail_targeted": detail_targeted,
                "safety": {"raw_message_stored": false}
            })),
        },
    );
    Ok(json!({
        "agent_gateway_version": AGENT_GATEWAY_VERSION,
        "status": "ok",
        "channel": options.channel,
        "sender": options.sender,
        "chat_id": options.chat_id,
        "message_id": options.message_id,
        "message": options.message.trim(),
        "intent": "status_query",
        "route_state": "status",
        "route": Value::Null,
        "chair_dry_run": chair,
        "workspace_state": state,
        "recent_executions": executions,
        "status_detail": detail,
        "context_resolution": context_resolution,
        "response_text": response_text,
        "next_expected_action": "inspect_status",
        "safety": {
            "executes_task": false,
            "model_call": false,
            "requires_approval_for_execution": true
        }
    }))
}

fn infer_recent_status_target(root: &Path, options: &AgentStepOptions) -> Result<Option<Value>> {
    if let Some(context) = recent_conversation_binding_context(root, options)? {
        return Ok(Some(context));
    }
    if let Some(context) = recent_conversation_context(
        root,
        &options.channel,
        options.chat_id.as_deref(),
        Some(options.sender.as_str()),
    )? {
        if let Some(packet_id) = context.get("packet_id").and_then(Value::as_str) {
            if !packet_id.is_empty() {
                return Ok(Some(json!({
                    "packet_id": packet_id,
                    "task_id": context.get("task_id").cloned().unwrap_or(Value::Null),
                    "status": context.get("route_state").cloned().unwrap_or(Value::Null),
                    "title": context.get("summary").cloned().unwrap_or(Value::Null),
                    "inferred": true,
                    "reason": "conversation_state"
                })));
            }
        }
    }
    let tasks = list_tasks(root, options.topic_id.as_deref(), None, 5000)?;
    let items = tasks
        .get("tasks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let transport = options.channel.as_str();
    let chat_id = options.chat_id.as_deref().filter(|value| !value.is_empty());
    let sender = Some(options.sender.as_str()).filter(|value| !value.is_empty());
    for mode in ["chat_id", "sender"] {
        let matches = items
            .iter()
            .filter(|task| {
                if task.get("status").and_then(Value::as_str) == Some("cancelled") {
                    return false;
                }
                if task.get("packet_id").and_then(Value::as_str).is_none() {
                    return false;
                }
                let metadata = task.get("metadata").and_then(Value::as_object);
                if metadata
                    .and_then(|metadata| metadata.get("transport"))
                    .and_then(Value::as_str)
                    != Some(transport)
                {
                    return false;
                }
                match mode {
                    "chat_id" => chat_id.is_some_and(|chat_id| {
                        metadata
                            .and_then(|metadata| metadata.get("chat_id"))
                            .and_then(Value::as_str)
                            == Some(chat_id)
                    }),
                    "sender" => sender.is_some_and(|sender| {
                        metadata
                            .and_then(|metadata| metadata.get("sender"))
                            .and_then(Value::as_str)
                            == Some(sender)
                    }),
                    _ => false,
                }
            })
            .collect::<Vec<_>>();
        let found = match mode {
            "chat_id" => matches.first().copied(),
            "sender" if matches.len() == 1 => matches.first().copied(),
            _ => None,
        };
        if let Some(task) = found {
            return Ok(Some(json!({
                "packet_id": task.get("packet_id").cloned().unwrap_or(Value::Null),
                "task_id": task.get("task_id").cloned().unwrap_or(Value::Null),
                "status": task.get("status").cloned().unwrap_or(Value::Null),
                "title": task.get("title").cloned().unwrap_or(Value::Null),
                "inferred": true,
                "reason": format!("recent_task_by_{mode}")
            })));
        }
    }
    Ok(None)
}

fn recent_conversation_binding_context(
    root: &Path,
    options: &AgentStepOptions,
) -> Result<Option<Value>> {
    let Some(chat_id) = options.chat_id.as_deref().filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    let path = root.join(".harvis/agent-room/conversation_binding.jsonl");
    let Ok(text) = fs::read_to_string(path) else {
        return Ok(None);
    };
    for line in text.lines().rev() {
        let Ok(item) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if item.get("transport").and_then(Value::as_str) != Some(options.channel.as_str()) {
            continue;
        }
        if item.get("chat_id").and_then(Value::as_str) != Some(chat_id) {
            continue;
        }
        let packet_id = item.get("packet_id").and_then(Value::as_str).unwrap_or("");
        let run_id = item.get("run_id").and_then(Value::as_str).unwrap_or("");
        if packet_id.is_empty() && run_id.is_empty() {
            continue;
        }
        return Ok(Some(json!({
            "packet_id": if packet_id.is_empty() { Value::Null } else { json!(packet_id) },
            "run_id": if run_id.is_empty() { Value::Null } else { json!(run_id) },
            "task_id": item.get("task_id").cloned().unwrap_or(Value::Null),
            "handoff_id": item.get("handoff_id").cloned().unwrap_or(Value::Null),
            "codex_thread_id": item.get("codex_thread_id").cloned().unwrap_or(Value::Null),
            "status": item.get("status").cloned().unwrap_or(Value::Null),
            "title": item.get("summary").cloned().unwrap_or(Value::Null),
            "inferred": true,
            "reason": "conversation_binding"
        })));
    }
    Ok(None)
}

fn project_lookup_step(root: &Path, options: &AgentStepOptions) -> Result<Value> {
    let query = project_lookup_query(options.message.trim());
    let projects = list_projects(ProjectListOptions {
        root: root.to_path_buf(),
        query,
    })?;
    let state = workspace_state(root, options.topic_id.as_deref(), 20)?;
    let topic_id = state
        .get("active_topic")
        .and_then(|topic| topic.get("topic_id"))
        .and_then(Value::as_str)
        .unwrap_or("gwt-workbench");
    let _ = add_event_with_metadata(
        root,
        topic_id,
        "knowledge",
        "knowledge",
        "project_lookup",
        options.message.trim(),
        Vec::new(),
        "internal",
        None,
        json!({
            "channel": options.channel,
            "chat_id": options.chat_id,
            "message_id": options.message_id,
            "project_count": projects.get("project_count").cloned().unwrap_or(Value::Null),
            "agent_gateway_version": AGENT_GATEWAY_VERSION
        }),
    );
    let response_text = project_lookup_response_text(&projects);
    let _ = record_conversation_state(
        root,
        ConversationInput {
            transport: options.channel.clone(),
            chat_id: options.chat_id.clone(),
            sender: Some(options.sender.clone()),
            message_id: options.message_id.clone(),
            intent: Some("project_lookup".to_string()),
            route_state: Some("answered".to_string()),
            summary: Some(format!(
                "Project lookup: {}",
                project_lookup_query(options.message.trim())
                    .unwrap_or_else(|| "unknown".to_string())
            )),
            metadata: Some(json!({
                "project_count": projects.get("project_count").cloned().unwrap_or(Value::Null),
                "safety": {"raw_message_stored": false}
            })),
            ..ConversationInput::default()
        },
    );
    Ok(json!({
        "agent_gateway_version": AGENT_GATEWAY_VERSION,
        "status": "ok",
        "channel": options.channel,
        "sender": options.sender,
        "chat_id": options.chat_id,
        "message_id": options.message_id,
        "message": options.message.trim(),
        "intent": "project_lookup",
        "route_state": "answered",
        "route": Value::Null,
        "chair_dry_run": Value::Null,
        "workspace_state": state,
        "projects": projects,
        "response_text": response_text,
        "next_expected_action": "inspect_project",
        "safety": {
            "executes_task": false,
            "model_call": false,
            "requires_approval_for_execution": true
        }
    }))
}

fn is_project_lookup_query(text: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(
            r"(?i)(项目.*(在哪|位置|路径|地址)|控制台.*(在哪|位置|路径|地址)|project2web|webview\s*console|console\s*project|projects?\s+(where|list|find)|[A-Za-z0-9_.-]+\s+(项目|project).*(在哪|位置|路径|地址|where|path|location))",
        )
        .expect("valid project lookup regex")
    });
    re.is_match(text)
}

fn project_lookup_query(text: &str) -> Option<String> {
    if text.to_ascii_lowercase().contains("project2web") || text.contains("控制台") {
        return Some("project2web".to_string());
    }
    static TOKEN_RE: OnceLock<Regex> = OnceLock::new();
    let re = TOKEN_RE.get_or_init(|| {
        Regex::new(r"(?i)[A-Za-z0-9][A-Za-z0-9_.-]{2,}").expect("valid project token regex")
    });
    let stopwords = [
        "project", "projects", "where", "path", "location", "console", "webview",
    ];
    for token in re.find_iter(text).map(|matched| matched.as_str()) {
        let lower = token.to_ascii_lowercase();
        if !stopwords.iter().any(|word| *word == lower) {
            return Some(token.to_string());
        }
    }
    None
}

fn project_lookup_response_text(projects: &Value) -> String {
    let items = projects
        .get("projects")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if items.is_empty() {
        return "没有找到匹配的 Harvis 项目。".to_string();
    }
    let mut lines = vec![format!("找到 {} 个 Harvis 项目：", items.len())];
    for project in items.iter().take(8) {
        let project_id = project
            .get("project_id")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let kind = project
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("project");
        let status = project
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let path = project.get("path").and_then(Value::as_str).unwrap_or("");
        lines.push(format!("- {project_id} | {kind} | {status} | {path}"));
    }
    lines.join("\n")
}

fn response_text(route: &Value, chair: &Value) -> String {
    let base = route
        .get("reply_text")
        .and_then(Value::as_str)
        .unwrap_or("H.A.R.V.I.S. Agent Gateway 已处理。");
    if !wants_internal_debug(route) {
        return base.to_string();
    }
    let Some(move_value) = chair.get("proposed_move") else {
        return base.to_string();
    };
    let action = move_value
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let summary = move_value
        .get("summary")
        .and_then(Value::as_str)
        .unwrap_or("Chair dry-run produced a proposed move.");
    let target = move_value
        .get("target_slot_id")
        .and_then(Value::as_str)
        .unwrap_or("harvis-chair");
    let runtime_line = move_value
        .get("runtime_selection")
        .and_then(runtime_summary_line);
    match runtime_line {
        Some(runtime_line) => {
            format!("{base}\n\nChair dry-run：{action} -> {target}\n{summary}\n{runtime_line}")
        }
        None => format!("{base}\n\nChair dry-run：{action} -> {target}\n{summary}"),
    }
}

fn wants_internal_debug(route: &Value) -> bool {
    let text = route.get("text").and_then(Value::as_str).unwrap_or("");
    let lower = text.to_ascii_lowercase();
    text.contains("路由")
        || text.contains("调试")
        || text.contains("为什么这么分配")
        || lower.contains("debug")
        || lower.contains("trace")
}

fn runtime_summary_line(selection: &Value) -> Option<String> {
    selection.get("selected").and_then(|selected| {
        let harness = selected.get("harness_id").and_then(Value::as_str)?;
        let model = selected.get("model_id").and_then(Value::as_str)?;
        let preset = selected
            .get("preset_id")
            .and_then(Value::as_str)
            .unwrap_or("none");
        let mut line = format!("推荐 runtime：{preset} | {harness} + {model}");
        if let Some(recommendation) = selection.get("recommendation") {
            if recommendation
                .get("fallback_applied")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                if let Some(note) = recommendation.get("note").and_then(Value::as_str) {
                    line.push_str(&format!("\n路由说明：{note}"));
                }
            }
        }
        Some(line)
    })
}

fn runtime_selection(route: &Value, chair: &Value) -> Value {
    route
        .get("runtime_selection")
        .cloned()
        .or_else(|| {
            chair
                .get("proposed_move")
                .and_then(|value| value.get("runtime_selection"))
                .cloned()
        })
        .unwrap_or(Value::Null)
}

fn next_expected_action(route: &Value, chair: &Value) -> String {
    if route.get("intent").and_then(Value::as_str) == Some("approve_execute") {
        return "execute_approved_packet".to_string();
    }
    if route.get("intent").and_then(Value::as_str) == Some("approval_query") {
        return "inspect_approval_status".to_string();
    }
    if route.get("intent").and_then(Value::as_str) == Some("publish_request") {
        return route_next_expected_action(route);
    }
    if route.get("intent").and_then(Value::as_str) == Some("task_enqueue")
        && route.get("route_state").and_then(Value::as_str) == Some("ready_to_run")
    {
        return "run_conductor_task".to_string();
    }
    if let Some(action) = chair
        .get("proposed_move")
        .and_then(|value| value.get("action"))
        .and_then(Value::as_str)
    {
        return action.to_string();
    }
    route
        .get("route_state")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string()
}

fn route_next_expected_action(route: &Value) -> String {
    match route.get("intent").and_then(Value::as_str).unwrap_or("") {
        "approve_execute" => "execute_approved_packet".to_string(),
        "approval_query" => "inspect_approval_status".to_string(),
        "publish_request" => match route.get("route_state").and_then(Value::as_str) {
            Some("waiting_approval") => "wait_for_publish_precheck_approval".to_string(),
            Some("needs_input") => "collect_publish_target_and_artifact".to_string(),
            _ => "inspect_publish_request".to_string(),
        },
        "task_enqueue" => match route.get("route_state").and_then(Value::as_str) {
            Some("ready_to_run") => "run_conductor_task".to_string(),
            Some("waiting_approval") => "wait_for_approval".to_string(),
            _ => "inspect_task_enqueue".to_string(),
        },
        "repo_lookup" => "inspect_lookup_result".to_string(),
        _ => route
            .get("route_state")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string(),
    }
}

fn chair_next_expected_action(chair: &Value) -> Value {
    chair
        .get("proposed_move")
        .and_then(|value| value.get("action"))
        .cloned()
        .unwrap_or(Value::Null)
}

fn status_response_text(state: &Value, _chair: &Value, executions: &[Value]) -> String {
    let open_tasks = state
        .get("open_tasks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let pending_approvals = state
        .get("pending_approvals")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let waiting_approval_queue = state
        .get("waiting_approval_queue")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let in_progress_tasks = open_tasks
        .iter()
        .filter(|task| task.get("status").and_then(Value::as_str) == Some("in_progress"))
        .cloned()
        .collect::<Vec<_>>();
    let handoff_states = handoff_state_map(state);
    let mut lines = vec![
        "H.A.R.V.I.S. 当前进展：".to_string(),
        format!("- open tasks: {}", open_tasks.len()),
        format!("- pending approvals: {}", pending_approvals.len()),
        format!("- waiting approval gates: {}", waiting_approval_queue.len()),
        format!("- in-progress handoffs: {}", in_progress_tasks.len()),
    ];
    if !executions.is_empty() {
        lines.push("最近执行：".to_string());
        for item in executions.iter().take(5) {
            let packet_id = item
                .get("packet_id")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let status = item
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let exit_code = item.get("exit_code").cloned().unwrap_or(Value::Null);
            lines.push(format!("- {packet_id}: {status}, exit={exit_code}"));
        }
    }
    if !in_progress_tasks.is_empty() {
        lines.push("正在推进：".to_string());
        for task in in_progress_tasks.iter().take(5) {
            lines.push(format!(
                "- {}",
                status_task_line(task, "monitor_handoff", &handoff_states)
            ));
        }
    }
    if !waiting_approval_queue.is_empty() {
        lines.push("等待审批队列：".to_string());
        for entry in waiting_approval_queue.iter().take(5) {
            lines.push(format!("- {}", status_queue_line(entry)));
        }
    }
    if !open_tasks.is_empty() {
        let other_tasks = open_tasks
            .iter()
            .filter(|task| {
                !matches!(
                    task.get("status").and_then(Value::as_str),
                    Some("in_progress") | Some("waiting_approval")
                )
            })
            .take(5)
            .collect::<Vec<_>>();
        if !other_tasks.is_empty() {
            lines.push("其他未关闭任务：".to_string());
            for task in other_tasks {
                lines.push(format!(
                    "- {}",
                    status_task_line(task, "inspect_task", &handoff_states)
                ));
            }
        }
    }
    lines.join("\n")
}

fn handoff_state_map(state: &Value) -> HashMap<String, String> {
    state
        .get("recent_handoffs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|handoff| {
            let id = handoff.get("handoff_id").and_then(Value::as_str)?;
            let state = handoff.get("state").and_then(Value::as_str)?;
            Some((id.to_string(), state.to_string()))
        })
        .collect()
}

fn status_task_line(
    task: &Value,
    default_next_action: &str,
    handoff_states: &HashMap<String, String>,
) -> String {
    let task_id = task
        .get("task_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let status = task
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let title = task.get("title").and_then(Value::as_str).unwrap_or("");
    let owner = task
        .get("owner_slot_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let approval_id = task
        .get("approval_id")
        .and_then(Value::as_str)
        .unwrap_or("none");
    let handoff_id = task
        .get("handoff_id")
        .and_then(Value::as_str)
        .unwrap_or("none");
    let handoff_state = handoff_states
        .get(handoff_id)
        .map(String::as_str)
        .unwrap_or("unknown");
    let run_id = task.get("run_id").and_then(Value::as_str).unwrap_or("none");
    let packet_id = task
        .get("packet_id")
        .and_then(Value::as_str)
        .unwrap_or("none");
    format!(
        "{task_id}: {status} | {title} | owner={owner} | approval={approval_id} | handoff={handoff_id} | handoff_state={handoff_state} | run={run_id} | packet={packet_id} | next={default_next_action}"
    )
}

fn status_queue_line(entry: &Value) -> String {
    let next_action = entry
        .get("next_action")
        .and_then(Value::as_str)
        .unwrap_or("request_approval");
    let approval_status = entry
        .get("approval_status")
        .and_then(Value::as_str)
        .unwrap_or("missing");
    format!(
        "{} | approval_status={approval_status} | {}",
        status_task_line(entry, next_action, &HashMap::new()),
        approval_hint(next_action)
    )
}

fn approval_hint(next_action: &str) -> &'static str {
    match next_action {
        "request_approval" => "需要先创建 approval 请求",
        "approve_or_reject" => "等待你批准或拒绝",
        "request_handoff" => "已批准，可以请求 handoff",
        "monitor_handoff" => "已进入 handoff，等待 harness 接手或回传结果",
        "revise_or_cancel" => "审批被拒绝或取消，需要修订或取消任务",
        _ => "需要人工查看下一步",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use harvis_runtime::init::init_workspace;
    use std::fs;

    #[test]
    fn agent_step_routes_task_and_runs_chair_dry_run() {
        let root =
            std::env::temp_dir().join(format!("harvis-agent-step-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "任务：找到 just-ddl 仓库并检查失败原因，不要执行".to_string(),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-test".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "task_enqueue");
        assert_eq!(
            result["chair_dry_run"]["proposed_move"]["action"],
            "request_approval"
        );
        assert_eq!(
            result["runtime_selection"]["selected"]["preset_id"],
            "digital-me-dsh"
        );
        assert_eq!(result["runtime_selection"]["selected"]["harness_id"], "dsh");
        assert_eq!(
            result["runtime_selection"]["selected"]["model_id"],
            "dsh:profile-default"
        );
        assert!(!result["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("Chair dry-run"));
        assert!(result["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("推荐 runtime"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn agent_step_answers_status_query() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-status-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "webview".to_string(),
            sender: "unit".to_string(),
            message: "现在到哪一步了？".to_string(),
            chat_id: None,
            message_id: None,
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "status_query");
        assert!(result["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("H.A.R.V.I.S. 当前进展"));
        assert!(!result["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("Chair dry-run"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn chat_ack_does_not_expose_internal_routing() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-chat-ack-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "你好".to_string(),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-chat-ack".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "chat_ack");
        let text = result["response_text"].as_str().unwrap_or_default();
        assert_eq!(text, "收到。");
        assert!(!text.contains("Chair dry-run"));
        assert!(!text.contains("推荐 runtime"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn local_file_lookup_needs_scope_without_chair_noise() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-local-file-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "本地有pdf吗展示给我".to_string(),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-local-file".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "local_file_lookup");
        assert_eq!(result["route_state"], "needs_input");
        let text = result["response_text"].as_str().unwrap_or_default();
        assert!(text.contains("缺少搜索范围"));
        assert!(text.contains("H.A.R.V.I.S. 私有工作区"));
        assert!(!text.contains(&root.display().to_string()));
        assert!(!text.contains("/Users/"));
        assert!(!text.contains("/Volumes/"));
        assert!(
            !regex::Regex::new(r#"(?i)(?:^|[[:space:]"'])(?:[a-z]:[\\/]|\\\\)"#)
                .expect("valid private path regex")
                .is_match(text)
        );
        assert!(!text.contains("Chair dry-run"));
        assert!(!text.contains("推荐 runtime"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn exact_lark_task_reaches_approval_gate_without_private_path() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-lark-explicit-task-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "任务：在 HARVIS 隔离执行器中读取当前版本号并回传；禁止写文件、禁止网络、禁止外部消息。".to_string(),
            chat_id: Some("chat-lark-explicit-task".to_string()),
            message_id: Some("msg-lark-explicit-task".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "task_enqueue");
        assert_eq!(result["route_state"], "waiting_approval");
        assert_eq!(result["next_expected_action"], "request_approval");
        let text = result["response_text"].as_str().unwrap_or_default();
        assert!(text.contains("当前等待审批"));
        assert!(!text.contains(&root.display().to_string()));
        assert!(!text.contains("/Users/"));
        assert!(!text.contains("/Volumes/"));
        assert!(
            !regex::Regex::new(r#"(?i)(?:^|[[:space:]"'])(?:[a-z]:[\\/]|\\\\)"#)
                .expect("valid private path regex")
                .is_match(text)
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn agent_step_status_query_can_focus_packet_id() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-status-target-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let task = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit".to_string(),
            text: "任务：找到 just-ddl 仓库并检查失败原因".to_string(),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-task-target".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route task");
        let packet_id = task["workbench_task"]["packet_id"]
            .as_str()
            .expect("packet id");

        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "webview".to_string(),
            sender: "unit".to_string(),
            message: format!("{packet_id} 进展如何"),
            chat_id: None,
            message_id: None,
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "status_query");
        assert_eq!(result["status_detail"]["matched"], true);
        assert_eq!(result["status_detail"]["target"]["kind"], "packet");
        assert_eq!(result["status_detail"]["target"]["id"], packet_id);
        assert_eq!(
            result["status_detail"]["task"]["task_id"],
            task["workbench_task"]["task_id"]
        );
        assert!(result["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("H.A.R.V.I.S. 单项进展"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn status_query_infers_recent_task_from_same_chat() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-status-context-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let task = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "任务：找到 just-ddl 仓库并检查失败原因".to_string(),
            chat_id: Some("chat-context".to_string()),
            message_id: Some("msg-task-context".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("task step");
        let packet_id = task["route"]["workbench_task"]["packet_id"]
            .as_str()
            .expect("packet id")
            .to_string();

        let status = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "有答案了吗？".to_string(),
            chat_id: Some("chat-context".to_string()),
            message_id: Some("msg-status-context".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("status step");
        assert_eq!(status["intent"], "status_query");
        assert_eq!(status["context_resolution"]["packet_id"], packet_id);
        assert_eq!(status["status_detail"]["target"]["kind"], "packet");
        assert_eq!(status["status_detail"]["target"]["id"], packet_id);
        assert!(status["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("H.A.R.V.I.S. 单项进展"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn status_query_prefers_recent_conversation_binding() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-status-binding-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let older_task = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "任务：旧任务 A".to_string(),
            chat_id: Some("chat-binding".to_string()),
            message_id: Some("msg-task-a".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("older task");
        let older_packet = older_task["route"]["workbench_task"]["packet_id"]
            .as_str()
            .expect("older packet")
            .to_string();
        let bound_task = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "任务：新绑定任务 B".to_string(),
            chat_id: Some("other-chat".to_string()),
            message_id: Some("msg-task-b".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("bound task");
        let bound_packet = bound_task["route"]["workbench_task"]["packet_id"]
            .as_str()
            .expect("bound packet")
            .to_string();
        let binding_path = root.join(".harvis/agent-room/conversation_binding.jsonl");
        fs::create_dir_all(binding_path.parent().expect("binding parent")).expect("binding dir");
        fs::write(
            &binding_path,
            format!(
                "{}\n",
                json!({
                    "schemaVersion": "harvis.conversation-binding.v0",
                    "transport": "feishu",
                    "chat_id": "chat-binding",
                    "message_id": "msg-binding",
                    "packet_id": bound_packet.clone(),
                    "run_id": "run_binding",
                    "handoff_id": "handoff_binding",
                    "codex_thread_id": "019f2222-2222-7222-8222-222222222222",
                    "status": "in_progress"
                })
            ),
        )
        .expect("write binding");

        let status = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "有答案了吗？".to_string(),
            chat_id: Some("chat-binding".to_string()),
            message_id: Some("msg-status-binding".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("status step");
        assert_eq!(status["intent"], "status_query");
        assert_eq!(
            status["context_resolution"]["reason"],
            "conversation_binding"
        );
        assert_eq!(status["context_resolution"]["packet_id"], bound_packet);
        assert_ne!(status["context_resolution"]["packet_id"], older_packet);
        assert_eq!(status["status_detail"]["target"]["kind"], "packet");
        assert_eq!(status["status_detail"]["target"]["id"], bound_packet);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn status_query_does_not_cross_transport_context() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-status-cross-transport-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "任务：找到 just-ddl 仓库并检查失败原因".to_string(),
            chat_id: Some("shared-chat".to_string()),
            message_id: Some("msg-task-context".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("task step");

        let status = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "webview".to_string(),
            sender: "unit".to_string(),
            message: "有答案了吗？".to_string(),
            chat_id: Some("shared-chat".to_string()),
            message_id: Some("msg-status-context".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("status step");
        assert_eq!(status["intent"], "status_query");
        assert!(status["context_resolution"].is_null());
        assert!(status["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("H.A.R.V.I.S. 当前进展"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn status_response_mentions_approval_and_handoff_state() {
        let state = json!({
            "open_tasks": [
                {
                    "task_id": "task_in_progress",
                    "title": "查 just-ddl 最近失败",
                    "status": "in_progress",
                    "owner_slot_id": "executor",
                    "approval_id": "approval_1",
                    "handoff_id": "handoff_1",
                    "run_id": "run_1",
                    "packet_id": "packet_1"
                },
                {
                    "task_id": "task_waiting",
                    "title": "找到 just-ddl 仓库并检查失败原因",
                    "status": "waiting_approval",
                    "owner_slot_id": "planner",
                    "run_id": "run_2",
                    "packet_id": "packet_2"
                }
            ],
            "pending_approvals": [],
            "recent_handoffs": [
                {
                    "handoff_id": "handoff_1",
                    "state": "reviewing"
                }
            ],
            "waiting_approval_queue": [
                {
                    "task_id": "task_waiting",
                    "title": "找到 just-ddl 仓库并检查失败原因",
                    "status": "waiting_approval",
                    "owner_slot_id": "planner",
                    "run_id": "run_2",
                    "packet_id": "packet_2",
                    "approval_status": "missing",
                    "next_action": "request_approval"
                }
            ]
        });
        let response = status_response_text(&state, &Value::Null, &[]);
        assert!(response.contains("in-progress handoffs: 1"));
        assert!(response.contains("handoff=handoff_1"));
        assert!(response.contains("handoff_state=reviewing"));
        assert!(response.contains("next=monitor_handoff"));
        assert!(response.contains("waiting approval gates: 1"));
        assert!(response.contains("next=request_approval"));
        assert!(response.contains("需要先创建 approval 请求"));
    }

    #[test]
    fn agent_step_answers_project_lookup() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-project-test-{}",
            std::process::id()
        ));
        let project = root.join("project2web-console");
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        fs::create_dir_all(&project).expect("project dir");
        fs::write(project.join("project2web.toml"), "[project]\n").expect("fingerprint");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "webview".to_string(),
            sender: "unit".to_string(),
            message: "控制台在哪里？".to_string(),
            chat_id: None,
            message_id: None,
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "project_lookup");
        assert_eq!(result["route_state"], "answered");
        assert_eq!(result["next_expected_action"], "inspect_project");
        assert!(result["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("project2web-console"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn agent_step_answers_named_generic_project_lookup() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-generic-project-test-{}",
            std::process::id()
        ));
        let project = root.join("digital_me");
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        fs::create_dir_all(&project).expect("project dir");
        fs::write(project.join("pyproject.toml"), "[project]\n").expect("fingerprint");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "webview".to_string(),
            sender: "unit".to_string(),
            message: "digital_me 项目在哪？".to_string(),
            chat_id: None,
            message_id: None,
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "project_lookup");
        assert_eq!(result["projects"]["project_count"], 1);
        assert!(result["response_text"]
            .as_str()
            .unwrap_or_default()
            .contains("digital_me"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn approval_next_action_is_not_masked_by_chair() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-approval-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "批准执行 abcdef123456".to_string(),
            chat_id: None,
            message_id: Some("approval-msg".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "approve_execute");
        assert_eq!(result["next_expected_action"], "execute_approved_packet");
        assert_eq!(
            result["route_next_expected_action"],
            "execute_approved_packet"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn agent_step_wechat_draft_request_runs_conductor_without_approval_gate() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-wechat-draft-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "https://mp.weixin.qq.com/s/example 最后记得发布到微信草稿箱".to_string(),
            chat_id: Some("chat-wechat-draft".to_string()),
            message_id: Some("msg-wechat-draft".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "task_enqueue");
        assert_eq!(result["route_state"], "ready_to_run");
        assert_eq!(result["next_expected_action"], "run_conductor_task");
        assert_eq!(result["route_next_expected_action"], "run_conductor_task");
        assert_eq!(
            result["safety"]["requires_approval_for_execution"],
            json!(false)
        );
        assert_eq!(
            result["route"]["workbench_task"]["metadata"]["ready_to_run"],
            json!(true)
        );
        let text = result["response_text"].as_str().unwrap_or_default();
        assert!(text.contains("受控任务"));
        assert!(!text.contains("批准执行 <packet_id>"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn agent_step_answers_approval_query() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-approval-query-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "需要我批复吗？".to_string(),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-approval-query".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "approval_query");
        assert_eq!(result["route_state"], "status");
        assert_eq!(result["next_expected_action"], "inspect_approval_status");
        assert_eq!(
            result["route_next_expected_action"],
            "inspect_approval_status"
        );
        let text = result["response_text"].as_str().unwrap_or_default();
        assert!(text.contains("当前这条飞书会话"));
        assert!(!text.contains("Chair dry-run"));
        assert!(!text.contains("推荐 runtime"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn agent_step_publish_request_with_target_creates_waiting_approval_task() {
        let root = std::env::temp_dir().join(format!(
            "harvis-agent-step-publish-request-task-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let result = agent_step(AgentStepOptions {
            root: root.clone(),
            channel: "feishu".to_string(),
            sender: "unit".to_string(),
            message: "部署这个页面到 GitHub Pages /tmp/site/index.html".to_string(),
            chat_id: Some("chat-publish".to_string()),
            message_id: Some("msg-publish-target".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
            topic_id: None,
            chair_dry_run: true,
        })
        .expect("agent step");
        assert_eq!(result["intent"], "publish_request");
        assert_eq!(result["route_state"], "waiting_approval");
        assert_eq!(
            result["route"]["workbench_task"]["status"],
            "waiting_approval"
        );
        assert_eq!(
            result["route"]["workbench_task"]["owner_slot_id"],
            "planner"
        );
        assert!(result["route"]["workbench_task"]["run_id"]
            .as_str()
            .is_some_and(|value| !value.is_empty()));
        assert_eq!(
            result["route_next_expected_action"],
            "wait_for_publish_precheck_approval"
        );
        let text = result["response_text"].as_str().unwrap_or_default();
        assert!(text.contains("已创建发布预检查任务"));
        assert!(text.contains("真正发布"));
        let _ = fs::remove_dir_all(root);
    }
}
