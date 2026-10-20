use anyhow::{bail, Result};
use regex::Regex;
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use crate::repoatlas::{repoatlas_find_repo, repoatlas_needs_attention};
use crate::status_query::{
    is_approval_query, is_status_query, recent_executions as status_recent_executions,
    single_item_status,
};
use harvis_runtime::agent_pools::{
    load_agent_pools, select_runtime_route, LoadedAgentPools, RuntimeSelectionOptions,
};
use harvis_runtime::agent_room::{
    create_task, find_task_by_packet_id, link_task, list_tasks, recent_conversation_context,
    record_conversation_state, workspace_state, ConversationInput, TaskInput, TaskLinkInput,
};
use harvis_runtime::inbox::{scan_inboxes, ScanOptions};
use harvis_runtime::runs::sync_packet_runs;

pub const ROUTER_VERSION: &str = "harvis.router.v0";

#[derive(Debug, Clone, Copy)]
struct KnownPathAlias {
    alias: &'static str,
    env_var: &'static str,
    label: &'static str,
    keywords: &'static [&'static str],
}

const KNOWN_PATH_ALIASES: &[KnownPathAlias] = &[
    KnownPathAlias {
        alias: "wemedia",
        env_var: "HARVIS_WEMEDIA_ROOT",
        label: "wemedia",
        keywords: &[
            "wemedia",
            "we media",
            "微信发布",
            "公众号",
            "自媒体",
            "09-wemedia",
        ],
    },
    KnownPathAlias {
        alias: "digital-me",
        env_var: "HARVIS_DIGITAL_ME_ROOT",
        label: "Digital-Me / H.A.R.V.I.S. workspace",
        keywords: &[
            "digital-me",
            "digital_me",
            "4-digital-me",
            "harvis workspace",
            "agent room",
        ],
    },
    KnownPathAlias {
        alias: "china-ai-job",
        env_var: "HARVIS_CHINA_AI_JOB_ROOT",
        label: "chinaAI&JOB",
        keywords: &[
            "chinaai",
            "china ai",
            "ai job",
            "02-chinaai",
            "02-chinaai&job",
        ],
    },
    KnownPathAlias {
        alias: "mobile-app",
        env_var: "HARVIS_MOBILE_APP_ROOT",
        label: "mobile-app",
        keywords: &["mobile-app", "mobile app", "07-mobile-app", "mobilecode"],
    },
    KnownPathAlias {
        alias: "codex-managed-agent",
        env_var: "HARVIS_CODEX_MANAGED_AGENT_ROOT",
        label: "codex-managed-agent",
        keywords: &[
            "codex-managed-agent",
            "11-codex-managed-agent",
            "managed agent",
        ],
    },
    KnownPathAlias {
        alias: "knowledge-hub",
        env_var: "HARVIS_KNOWLEDGE_HUB_ROOT",
        label: "local knowledge hub",
        keywords: &[
            "knowledge hub",
            "local knowledge",
            "harzva-local-knowledge-hub",
            "知识库",
        ],
    },
    KnownPathAlias {
        alias: "harvis-plugin",
        env_var: "HARVIS_PLUGIN_ROOT",
        label: "Harvis plugin",
        keywords: &["harvis plugin", "harvis 插件", "harvis repo", "harvis 项目"],
    },
];

#[derive(Debug, Clone)]
pub struct RouteMessageOptions {
    pub root: PathBuf,
    pub transport: String,
    pub sender: String,
    pub text: String,
    pub chat_id: Option<String>,
    pub message_id: Option<String>,
    pub context: Vec<String>,
    pub include_paths: bool,
    pub map_path: Option<PathBuf>,
    pub agent_pools_path: Option<PathBuf>,
}

pub fn route_message(options: RouteMessageOptions) -> Result<Value> {
    let root = normalize_root(&options.root)?;
    let text = options.text.trim();
    if text.is_empty() {
        bail!("text must be non-empty");
    }

    let context_text = options
        .context
        .iter()
        .map(|item| item.trim())
        .filter(|item| !item.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    let combined_text = [text, context_text.as_str()]
        .into_iter()
        .filter(|item| !item.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    let pools = match load_agent_pools(&root, options.agent_pools_path.as_deref()) {
        Ok(pools) => pools,
        Err(error) => {
            let event_id = route_event_id(&options, text)?;
            let event = json!({
                "router_version": ROUTER_VERSION,
                "event_id": event_id,
                "workspace_root": root.display().to_string(),
                "transport": options.transport.clone(),
                "sender": options.sender.clone(),
                "chat_id": options.chat_id.clone(),
                "message_id": options.message_id.clone(),
                "text": text,
                "intent": "router_error",
                "route_state": "error",
                "selected_preset": Value::Null,
                "agent_pools": {
                    "found": false,
                    "preset_count": 0,
                    "is_fixture": false,
                    "error": format!("{error:#}")
                },
                "lifecycle": [
                    {"state": "received", "summary": "Message accepted by Harvis Router."},
                    {"state": "error", "summary": "Agent pools registry unavailable; router failed fast instead of falling back to the sample fixture."}
                ],
                "safety": {
                    "executes_task": false,
                    "requires_approval_for_execution": true,
                    "includes_secrets": false
                },
                "reply_text": format!(
                    "Harvis Router 无法加载 agent pools 注册表，已按 fail-fast 原则停止路由：{error:#}"
                )
            });
            let _ = append_router_event(&root, &event);
            return Err(error.context("agent pools registry unavailable for router"));
        }
    };
    let preset = detect_preset(text, Some(&pools));
    let intent = classify_intent(text, &combined_text);
    let event_id = route_event_id(&options, text)?;

    let mut result = json!({
        "router_version": ROUTER_VERSION,
        "event_id": event_id,
        "workspace_root": root.display().to_string(),
        "transport": options.transport.clone(),
        "sender": options.sender.clone(),
        "chat_id": options.chat_id.clone(),
        "message_id": options.message_id.clone(),
        "text": text,
        "intent": intent,
        "route_state": "received",
        "selected_preset": preset.clone(),
        "agent_pools": {
            "found": true,
            "source": pools.path.display().to_string(),
            "source_display": pools.source_display,
            "is_fixture": pools.is_fixture,
            "preset_count": pools.registry.runtime_preset_pool.len()
        },
        "lifecycle": [
            {"state": "received", "summary": "Message accepted by Harvis Router."},
            {"state": "classified", "summary": "Intent classified without model calls."}
        ],
        "safety": {
            "executes_task": false,
            "requires_approval_for_execution": true,
            "includes_secrets": false
        }
    });

    match intent.as_str() {
        "known_path_lookup" => {
            let lookup = known_path_lookup(text, &combined_text);
            result["route_state"] = json!("verified");
            result["known_path_lookup"] = lookup.clone();
            result["reply_text"] = json!(known_path_lookup_reply(&lookup));
            result["safety"]["requires_approval_for_execution"] = json!(false);
            push_lifecycle(
                &mut result,
                "known_path_lookup",
                "Known workspace alias was resolved without creating a runner task.",
            );
        }
        "approval_query" => {
            let state = workspace_state(&root, None, 20)?;
            let executions = status_recent_executions(&root, 5);
            let target = infer_recent_approval_target(&root, &options).ok().flatten();
            result["route_state"] = json!("status");
            result["workspace_state"] = state.clone();
            result["recent_executions"] = json!(executions);
            result["approval_query"] = json!({
                "target": target,
                "scope": "same_conversation_first"
            });
            result["reply_text"] = json!(approval_query_reply(
                &state,
                result
                    .get("approval_query")
                    .and_then(|value| value.get("target"))
            ));
            push_lifecycle(
                &mut result,
                "approval_query",
                "Approval status query was projected with same-conversation priority.",
            );
        }
        "status_query" => {
            let state = workspace_state(&root, None, 20)?;
            let executions = status_recent_executions(&root, 5);
            let detail = single_item_status(&root, text)?;
            let detail_targeted = !detail.get("target").is_none_or(Value::is_null);
            result["route_state"] = json!("status");
            result["workspace_state"] = state.clone();
            result["recent_executions"] = json!(executions);
            result["status_detail"] = detail.clone();
            result["reply_text"] = if detail_targeted {
                detail
                    .get("response_text")
                    .cloned()
                    .unwrap_or_else(|| json!("H.A.R.V.I.S. 单项进展查询没有生成文本。"))
            } else {
                json!(status_reply(&state, &result["recent_executions"]))
            };
            push_lifecycle(
                &mut result,
                "status_query",
                "Shared workspace status was projected without creating a task.",
            );
        }
        "repo_lookup" => {
            let repo_lookup = route_repo_lookup(
                &combined_text,
                options.map_path.as_deref(),
                options.include_paths,
            )?;
            result["route_state"] = json!("verified");
            result["repo_lookup"] = repo_lookup;
            result["reply_text"] = json!(repo_lookup_reply(&result["repo_lookup"]));
            push_lifecycle(&mut result, "repo_lookup", "RepoAtlas lookup completed.");
        }
        "local_file_lookup" => {
            result["route_state"] = json!("needs_input");
            result["reply_text"] = json!(local_file_lookup_reply(text));
            push_lifecycle(
                &mut result,
                "needs_input",
                "Local file lookup request was recognized, but a search scope is required.",
            );
        }
        "publish_request" => {
            let plan = publish_request_plan(text);
            let route_state = plan
                .get("route_state")
                .and_then(Value::as_str)
                .unwrap_or("needs_input");
            result["route_state"] = json!(route_state);
            result["publish_request"] = plan.clone();
            if route_state == "waiting_approval" {
                let safe_task_text = publish_precheck_task_text(text, &plan);
                let task = enqueue_task(&root, &safe_task_text, &options, preset.as_ref())?;
                result["publish_request_task"] = task;
                if let Ok(selection) = select_runtime_route(RuntimeSelectionOptions {
                    root: root.clone(),
                    path: options.agent_pools_path.clone(),
                    text: safe_task_text,
                    selected_preset: preset.clone(),
                    owner_slot_id: Some("planner".to_string()),
                }) {
                    result["runtime_selection"] = selection;
                }
            }
            result["reply_text"] = json!(publish_request_reply(
                &plan,
                result.get("publish_request_task")
            ));
            result["safety"]["requires_approval_for_execution"] = json!(true);
            push_lifecycle(
                &mut result,
                route_state,
                "Publish request was recognized; external write/public publish is approval-gated.",
            );
        }
        "task_enqueue" => {
            let conductor_ready =
                is_external_article_material_request(text) || is_wechat_draft_box_request(text);
            let task_text = task_enqueue_text(text);
            let task = enqueue_task(&root, &task_text, &options, preset.as_ref())?;
            result["route_state"] = json!(if conductor_ready {
                "ready_to_run"
            } else {
                "waiting_approval"
            });
            result["safety"]["requires_approval_for_execution"] = json!(!conductor_ready);
            result["task_enqueue"] = task;
            result["task_text"] = json!(task_text.clone());
            if let Ok(selection) = select_runtime_route(RuntimeSelectionOptions {
                root: root.clone(),
                path: options.agent_pools_path.clone(),
                text: task_text,
                selected_preset: preset.clone(),
                owner_slot_id: Some(if preset.is_some() {
                    "executor".to_string()
                } else {
                    "planner".to_string()
                }),
            }) {
                result["runtime_selection"] = selection;
            }
            result["reply_text"] = json!(task_reply(
                &result["task_enqueue"],
                preset.as_ref(),
                result.get("runtime_selection"),
                conductor_ready
            ));
            push_lifecycle(
                &mut result,
                "packet_created",
                "Task was written to inbox and scanned into work packets.",
            );
        }
        "approve_execute" => {
            let explicit_packet_id = extract_approval_packet_id(text);
            let inferred = explicit_packet_id
                .as_ref()
                .map(|packet_id| {
                    json!({
                        "packet_id": packet_id,
                        "inferred": false,
                        "reason": "explicit_packet_id"
                    })
                })
                .or_else(|| infer_recent_approval_target(&root, &options).ok().flatten())
                .unwrap_or_else(|| {
                    json!({
                        "packet_id": "",
                        "inferred": false,
                        "reason": "missing_packet_id"
                    })
                });
            let packet_id = inferred
                .get("packet_id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            result["route_state"] = json!("waiting_harness");
            result["approval"] = json!({
                "packet_id": packet_id,
                "action": "execute-approved-packet",
                "executes_task": false,
                "context_resolution": inferred,
                "summary": "Router recognized approval; external harness executor must perform the approved run."
            });
            result["reply_text"] = if packet_id.is_empty() {
                json!("收到批准执行，但没有找到同一会话最近的待审批任务。请回复“批准执行 <packet_id>”。")
            } else {
                json!(format!(
                    "收到批准执行 {packet_id}。Harvis Router 已识别审批，下一步交给受控 harness executor 执行并回传结果。"
                ))
            };
            push_lifecycle(
                &mut result,
                "approval_recognized",
                "Approval phrase recognized.",
            );
        }
        "preset_route" => {
            result["route_state"] = json!("waiting_task");
            result["reply_text"] = json!(preset_reply(preset.as_ref()));
            push_lifecycle(
                &mut result,
                "preset_selected",
                "Runtime preset was selected.",
            );
        }
        _ => {
            result["route_state"] = json!("acknowledged");
            result["reply_text"] = json!("收到。");
        }
    }

    sync_route_to_workbench(&root, &mut result)?;
    record_route_conversation(&root, &result)?;
    append_router_event(&root, &result)?;
    Ok(result)
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

fn detect_preset(text: &str, pools: Option<&LoadedAgentPools>) -> Option<Value> {
    let lower = text.to_ascii_lowercase();
    let pools = pools?;
    pools
        .registry
        .runtime_preset_pool
        .iter()
        .find_map(|preset| {
            let preset_id = preset.get("preset_id").and_then(Value::as_str)?;
            let aliases = preset
                .get("command_aliases")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let matched = lower.contains(&preset_id.to_ascii_lowercase())
                || aliases.iter().filter_map(Value::as_str).any(|alias| {
                    !alias.trim().is_empty() && lower.contains(&alias.trim().to_ascii_lowercase())
                });
            matched.then(|| preset.clone())
        })
}

fn classify_intent(text: &str, combined_text: &str) -> String {
    if is_known_path_lookup_request(text, combined_text) {
        return "known_path_lookup".to_string();
    }
    if is_approval_query(text) {
        return "approval_query".to_string();
    }
    if is_status_query(text) {
        return "status_query".to_string();
    }
    if is_external_article_material_request(text) {
        return "task_enqueue".to_string();
    }
    if is_wechat_draft_box_request(text) {
        return "task_enqueue".to_string();
    }
    if is_publish_request(text) {
        return "publish_request".to_string();
    }
    if is_repo_failure_task(text, combined_text) {
        return "task_enqueue".to_string();
    }
    if is_local_file_task_request(text) {
        return "task_enqueue".to_string();
    }
    // An explicit task marker is an operator intent boundary. Check it before
    // the broad local-file lookup heuristic, which can otherwise mistake
    // safety constraints such as “禁止写文件” plus “读取” for a file search.
    if has_explicit_task_marker(text) {
        return "task_enqueue".to_string();
    }
    if is_local_file_lookup_request(text) {
        return "local_file_lookup".to_string();
    }
    if is_task_request(text) {
        return "task_enqueue".to_string();
    }
    if is_approval_request(text) {
        return "approve_execute".to_string();
    }
    if is_repo_lookup(text)
        || (!extract_repo_candidates(combined_text).is_empty() && has_repo_context(text))
    {
        return "repo_lookup".to_string();
    }
    if detect_preset_name(text).is_some() {
        return "preset_route".to_string();
    }
    "chat_ack".to_string()
}

fn task_enqueue_text(text: &str) -> String {
    if is_external_article_material_request(text) || is_wechat_draft_box_request(text) {
        return external_article_material_task_text(text);
    }
    text.to_string()
}

fn external_article_material_task_text(text: &str) -> String {
    let wemedia_root = known_path_alias("wemedia")
        .and_then(resolve_known_path)
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| "wemedia".to_string());
    let material_root = format!("{wemedia_root}/文章素材库");
    format!(
        "任务：Codex Conductor 动态处理外部文章链接，目标是生成可验收的微信公众号草稿，或明确写出阻塞原因。\n原始请求：{text}\n默认工作区：{wemedia_root}\n素材目标目录：{material_root}\n\nHarvis 角色：只负责入口、状态、审批门、卡片、日志，以及生成 conductor_task.json / conductor_events.jsonl / conductor_result.json 合约文件；不要在 router 里硬编码微信链接固定 workflow。\nCodex Conductor 角色：读取 conductor_task.json 后自行规划步骤，决定是否调用 kimicode、codex、md2wechat、browser 等 worker，并把每一步写入 conductor_events.jsonl，最终写入 conductor_result.json。\n可用 workers：kimicode（长文/微信解析）、codex（本地文件/草稿生成/验证）、md2wechat（image_upload/create_draft/draft_get_verify）、browser（可选草稿箱 UI 抽查）。\n参考 playbook：references/playbooks/wemedia-wechat-draft.md，仅作为经验参考，不是强制固定流程。\n策略：delete / 删除 / 清空 才是高风险审批；create_draft 是允许的公众号草稿箱动作，不等于正式发布。\n验收：exit 0 不等于成功；只有 conductor_result.json 或真实 artifact 证明 draft id、图片数量、artifact 路径和质量门通过，才可以说完成。create_draft 后必须记录 draft/get API proof；API 验证通过即可视为已进入公众号草稿箱，UI 截图只作为可选抽查。失败时 conductor_result.reason 必须说明卡在哪一步，例如正文抓取、图片下载、create_draft、草稿箱 API 验证等。文章结尾必须去掉“文章来源/来源公众号/原文来自/转载自/本文来源于”等来源尾巴。"
    )
}

fn is_known_path_lookup_request(text: &str, combined_text: &str) -> bool {
    let lower = combined_text.to_ascii_lowercase();
    let asks_path = text.contains("路径")
        || text.contains("在哪")
        || text.contains("哪里")
        || text.contains("位置")
        || text.contains("地址")
        || lower.contains("where")
        || lower.contains("path")
        || lower.contains("location");
    asks_path && known_path_alias_for_text(&lower).is_some()
}

fn known_path_lookup(text: &str, combined_text: &str) -> Value {
    let lower = combined_text.to_ascii_lowercase();
    if let Some(entry) = known_path_alias_for_text(&lower) {
        let resolved_path = resolve_known_path(entry);
        let exists = resolved_path.as_ref().is_some_and(|path| path.is_dir());
        let configured = resolved_path.is_some();
        return json!({
            "alias": entry.alias,
            "label": entry.label,
            "path": resolved_path.map(|path| path.display().to_string()),
            "exists": exists,
            "configured": configured,
            "configuration_key": entry.env_var,
            "source": "harvis-known-alias",
            "query": text
        });
    }
    json!({
        "alias": Value::Null,
        "path": Value::Null,
        "exists": false,
        "source": "harvis-known-alias",
        "query": text
    })
}

fn known_path_alias(alias: &str) -> Option<KnownPathAlias> {
    KNOWN_PATH_ALIASES
        .iter()
        .copied()
        .find(|entry| entry.alias == alias)
}

fn known_path_alias_for_text(lower_text: &str) -> Option<KnownPathAlias> {
    KNOWN_PATH_ALIASES.iter().copied().find(|entry| {
        lower_text.contains(entry.alias)
            || entry
                .keywords
                .iter()
                .any(|keyword| lower_text.contains(&keyword.to_ascii_lowercase()))
    })
}

fn resolve_known_path(entry: KnownPathAlias) -> Option<PathBuf> {
    std::env::var_os(entry.env_var)
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
}

fn known_path_lookup_reply(lookup: &Value) -> String {
    let alias = lookup
        .get("alias")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let label = lookup.get("label").and_then(Value::as_str).unwrap_or(alias);
    let path = lookup.get("path").and_then(Value::as_str).unwrap_or("");
    let exists = lookup
        .get("exists")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !path.is_empty() {
        return format!(
            "{label} 路径是：{path}\n状态：{}。\n这是 Harvis 本地常用工程路径字典命中；未命中时再走 RepoAtlas 查找。",
            if exists { "已存在" } else { "路径不存在，请检查挂载" }
        );
    }
    if alias != "unknown" {
        let configuration_key = lookup
            .get("configuration_key")
            .and_then(Value::as_str)
            .unwrap_or("the matching HARVIS_*_ROOT setting");
        return format!("已识别 {label}，但本机路径尚未配置。请设置 {configuration_key} 后重试。");
    }
    "没有命中已知路径别名。".to_string()
}

fn infer_recent_approval_target(
    root: &Path,
    options: &RouteMessageOptions,
) -> Result<Option<Value>> {
    if let Some(context) = recent_conversation_context(
        root,
        &options.transport,
        options.chat_id.as_deref(),
        Some(options.sender.as_str()),
    )? {
        if let Some(packet_id) = context.get("packet_id").and_then(Value::as_str) {
            if !packet_id.is_empty() {
                if let Some(task) = find_task_by_packet_id(root, packet_id)? {
                    if task.get("status").and_then(Value::as_str) == Some("waiting_approval") {
                        return Ok(Some(json!({
                            "packet_id": packet_id,
                            "task_id": task.get("task_id").cloned().unwrap_or(Value::Null),
                            "run_id": task.get("run_id").cloned().unwrap_or(Value::Null),
                            "title": task.get("title").cloned().unwrap_or(Value::Null),
                            "inferred": true,
                            "reason": "conversation_state"
                        })));
                    }
                }
            }
        }
    }
    let tasks = list_tasks(root, None, None, 5000)?;
    let items = tasks
        .get("tasks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let transport = options.transport.as_str();
    let chat_id = options.chat_id.as_deref().filter(|value| !value.is_empty());
    let sender = Some(options.sender.as_str()).filter(|value| !value.is_empty());
    for mode in ["chat_id", "sender"] {
        let matches = items
            .iter()
            .filter(|task| {
                if task.get("status").and_then(Value::as_str) != Some("waiting_approval") {
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
                "run_id": task.get("run_id").cloned().unwrap_or(Value::Null),
                "title": task.get("title").cloned().unwrap_or(Value::Null),
                "inferred": true,
                "reason": format!("recent_waiting_approval_by_{mode}")
            })));
        }
    }
    Ok(None)
}

fn is_repo_failure_task(text: &str, combined_text: &str) -> bool {
    let lower = combined_text.to_ascii_lowercase();
    if extract_repo_candidates(combined_text).is_empty() {
        return false;
    }
    let asks_to_inspect = text.contains("查")
        || text.contains("找")
        || text.contains("检查")
        || text.contains("分析")
        || lower.contains("check")
        || lower.contains("inspect")
        || lower.contains("debug")
        || lower.contains("triage");
    let failure_context = text.contains("失败")
        || text.contains("报错")
        || text.contains("错误")
        || text.contains("原因")
        || lower.contains("fail")
        || lower.contains("error")
        || lower.contains("ci");
    asks_to_inspect && failure_context
}

fn is_repo_lookup(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let has_candidate = !extract_repo_candidates(text).is_empty();
    if has_candidate
        && (lower.contains("repo")
            || lower.contains("repository")
            || lower.contains("where")
            || lower.contains("path")
            || text.contains("查")
            || text.contains("找")
            || text.contains("搜")
            || text.contains("在哪")
            || text.contains("位置")
            || text.contains("路径")
            || text.contains("本地"))
    {
        return true;
    }
    (text.contains("仓库")
        || text.contains("项目")
        || lower.contains("repo")
        || lower.contains("repository"))
        && (text.contains("在哪")
            || text.contains("位置")
            || text.contains("路径")
            || text.contains("本地")
            || text.contains("找到")
            || lower.contains("where")
            || lower.contains("path"))
}

fn has_repo_context(text: &str) -> bool {
    text.contains("这些")
        || text.contains("提到")
        || text.contains("查")
        || text.contains("找")
        || text.contains("搜")
        || text.contains("报错")
        || text.contains("失败")
        || text.contains("仓库")
        || text.to_ascii_lowercase().contains("repo")
}

fn is_task_request(text: &str) -> bool {
    let trimmed = text.trim();
    if has_explicit_task_marker(trimmed) {
        return true;
    }
    if is_external_article_material_request(trimmed) {
        return true;
    }
    if is_local_file_task_request(trimmed) {
        return true;
    }
    if is_browser_operation_request(trimmed) {
        return true;
    }
    trimmed.contains("帮我")
        || trimmed.contains("请你")
        || trimmed.contains("麻烦你")
        || trimmed.contains("写一个")
        || trimmed.contains("做一个")
        || trimmed.contains("开发一个")
        || trimmed.contains("实现一个")
        || trimmed.contains("修复")
}

fn has_explicit_task_marker(text: &str) -> bool {
    // Feishu and copied rich text can add zero-width format characters around
    // a command marker. Ignore those only for intent detection; keep the
    // original message unchanged for the task/audit record.
    let normalized = text
        .chars()
        .filter(|value| {
            !matches!(
                value,
                '\u{200b}' | '\u{200c}' | '\u{200d}' | '\u{2060}' | '\u{feff}'
            )
        })
        .collect::<String>();
    let trimmed = normalized.trim();
    let lower = trimmed.to_ascii_lowercase();
    task_marker_regex().is_match(trimmed)
        || lower.contains("fsrealtask")
        || trimmed.contains("任务:")
        || trimmed.contains("任务：")
        || trimmed.contains("新任务:")
        || trimmed.contains("新任务：")
}

fn is_publish_request(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.starts_with("发布任务:") || trimmed.starts_with("发布任务：") {
        return false;
    }
    if is_wechat_draft_box_request(trimmed) {
        return false;
    }
    if is_publish_precheck_task(trimmed) {
        return false;
    }
    let (scan_text, lower) = publish_signal_text(text);
    scan_text.contains("发布")
        || scan_text.contains("发到公众号")
        || scan_text.contains("发公众号")
        || scan_text.contains("公众号发布")
        || scan_text.contains("发到知乎")
        || scan_text.contains("知乎发布")
        || scan_text.contains("同步发布")
        || scan_text.contains("部署这个页面")
        || scan_text.contains("部署页面")
        || scan_text.contains("发出去")
        || lower.contains("publish")
        || lower.contains("deploy")
        || lower.contains("github pages")
}

fn is_publish_precheck_task(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let task_like = task_marker_regex().is_match(text)
        || text.starts_with("任务:")
        || text.starts_with("任务：")
        || lower.contains("fsrealtask")
        || text.contains("帮我")
        || text.contains("请你")
        || text.contains("准备");
    if !task_like {
        return false;
    }
    text.contains("发布前检查")
        || text.contains("发布预检查")
        || text.contains("预检查并准备发布")
        || text.contains("准备发布")
        || lower.contains("publish precheck")
        || lower.contains("precheck publish")
}

fn publish_signal_text(text: &str) -> (String, String) {
    let mut scan_text = text.to_string();
    for pattern in [
        "不要发布",
        "别发布",
        "不发布",
        "不得发布",
        "不要真正发布",
        "不要同步发布",
        "不要发出去",
        "别发出去",
        "不要部署",
        "别部署",
        "不部署",
        "不得部署",
        "不要推送",
        "别推送",
        "不要提交",
        "别提交",
    ] {
        scan_text = scan_text.replace(pattern, " ");
    }
    let mut lower = scan_text.to_ascii_lowercase();
    for pattern in [
        "do not publish",
        "don't publish",
        "dont publish",
        "not publish",
        "no publish",
        "do not deploy",
        "don't deploy",
        "dont deploy",
        "not deploy",
        "no deploy",
        "do not push",
        "don't push",
        "dont push",
        "not push",
        "no push",
        "do not commit",
        "don't commit",
        "dont commit",
        "not commit",
        "no commit",
    ] {
        lower = lower.replace(pattern, " ");
    }
    (scan_text, lower)
}

fn publish_request_plan(text: &str) -> Value {
    let lower = text.to_ascii_lowercase();
    let mut targets = Vec::new();
    if text.contains("公众号") || text.contains("微信") || lower.contains("wechat") {
        targets.push("微信/公众号");
    }
    if text.contains("知乎") || lower.contains("zhihu") {
        targets.push("知乎");
    }
    if text.contains("飞书") || lower.contains("lark") || lower.contains("feishu") {
        targets.push("飞书文档");
    }
    if lower.contains("github pages") || lower.contains("pages") {
        targets.push("GitHub Pages");
    }
    if text.contains("网页")
        || text.contains("页面")
        || lower.contains("web")
        || lower.contains("deploy")
    {
        targets.push("网页/部署");
    }
    let has_target = !targets.is_empty();
    let has_artifact_hint =
        Regex::new(r"(?i)(/[^[:space:]]+|https?://\S+|\.(md|html|docx|pdf|png|jpg|jpeg|webp)\b)")
            .expect("valid publish artifact regex")
            .is_match(text)
            || text.contains("这篇")
            || text.contains("这个页面")
            || text.contains("这个项目")
            || text.contains("草稿")
            || text.contains("文章");
    let route_state = if has_target && has_artifact_hint {
        "waiting_approval"
    } else {
        "needs_input"
    };
    json!({
        "targets": targets,
        "has_target": has_target,
        "has_artifact_hint": has_artifact_hint,
        "route_state": route_state,
        "requires_approval": true,
        "can_precheck_without_approval": true,
        "approval_reason": "发布/部署/推送会写入外部系统或公网，必须显式审批；当前只允许自动做本地只读预检查。"
    })
}

fn publish_precheck_task_text(text: &str, plan: &Value) -> String {
    let targets = plan
        .get("targets")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|value| value.as_str().map(ToOwned::to_owned))
        .collect::<Vec<_>>();
    format!(
        "任务：预检查并准备发布。\n原始发布请求：{text}\n目标：{}\n安全边界：只允许做本地只读预检查、产物存在性检查、敏感信息扫描、缺失素材列表和发布计划草稿；不得真正 publish/deploy/push/写入外部系统/公网发布。真正发布必须另行显式审批。",
        if targets.is_empty() {
            "未指定".to_string()
        } else {
            targets.join(" / ")
        }
    )
}

fn publish_request_reply(plan: &Value, task: Option<&Value>) -> String {
    let targets = plan
        .get("targets")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|value| value.as_str().map(ToOwned::to_owned))
        .collect::<Vec<_>>();
    let has_target = plan
        .get("has_target")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let has_artifact_hint = plan
        .get("has_artifact_hint")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut lines = vec!["这是发布请求，我不会直接发布。".to_string()];
    if has_target {
        lines.push(format!("目标：{}", targets.join(" / ")));
    } else {
        lines.push(
            "缺少发布目标：请说明要发到公众号、知乎、飞书文档、网页/GitHub Pages，还是其他目标。"
                .to_string(),
        );
    }
    if !has_artifact_hint {
        lines.push("缺少产物：请给出草稿/HTML/文档/图片/页面路径或链接。".to_string());
    }
    lines.push(
        "可以先自动做低风险预检查：确认产物存在、列出待发布文件、检查敏感信息和缺失素材。"
            .to_string(),
    );
    if let Some(task) = task {
        if let Some(packet_id) = task
            .get("packets_written")
            .and_then(Value::as_array)
            .and_then(|packets| packets.first())
            .and_then(Value::as_str)
            .and_then(|path| {
                Path::new(path)
                    .file_stem()
                    .and_then(|value| value.to_str())
                    .map(ToOwned::to_owned)
            })
            .or_else(|| {
                task.get("packet_id")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
        {
            lines.push(format!(
                "已创建发布预检查任务，等待你审批后才会执行预检查。packet_id：{packet_id}"
            ));
            lines.push(format!("回复“批准执行 {packet_id}”后，只会进入受控预检查；真正发布/部署/push 仍然必须审批。"));
        }
    } else {
        lines.push("真正发布、部署、push 或写入外部系统前必须审批；请在信息补齐后发“任务：预检查并准备发布 <目标> <产物>”。".to_string());
    }
    lines.join("\n")
}

fn approval_query_reply(state: &Value, target: Option<&Value>) -> String {
    if let Some(target) = target {
        if let Some(packet_id) = target.get("packet_id").and_then(Value::as_str) {
            if !packet_id.is_empty() {
                let title = target
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("最近待审批任务");
                return format!(
                    "需要你批复：{}\npacket_id：{}\n下一步：如果确认执行，请回复“批准执行 {}”。高风险动作仍会被审批门拦住。",
                    short_title(title),
                    packet_id,
                    packet_id
                );
            }
        }
    }
    let pending = state
        .get("pending_approvals")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if pending.is_empty() {
        return "当前这条飞书会话没有匹配到需要你批复的最近任务；全局也没有可见的等待审批项。"
            .to_string();
    }
    let mut lines = vec![format!("当前有 {} 个等待审批任务。", pending.len())];
    if let Some(item) = pending.first() {
        let title = item
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("待审批任务");
        let packet_id = item.get("packet_id").and_then(Value::as_str).unwrap_or("");
        if packet_id.is_empty() {
            lines.push(format!("最近一项：{}", short_title(title)));
        } else {
            lines.push(format!(
                "最近一项：{}，packet_id：{}",
                short_title(title),
                packet_id
            ));
            lines.push(format!("要执行请回复“批准执行 {packet_id}”。"));
        }
    }
    lines.join("\n")
}

fn is_browser_operation_request(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("browser")
        || lower.contains("chrome")
        || lower.contains("playwright")
        || lower.contains("computer use")
        || lower.contains("computer-use")
        || text.contains("浏览器")
        || text.contains("打开网页")
        || text.contains("打开网站")
        || text.contains("打开百度")
        || text.contains("百度")
        || text.contains("点击网页")
        || text.contains("网页点击")
}

fn is_local_file_lookup_request(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let has_file_word = lower.contains("pdf")
        || lower.contains("docx")
        || lower.contains("doc")
        || lower.contains("pptx")
        || lower.contains("xlsx")
        || lower.contains("txt")
        || lower.contains("md")
        || text.contains("文件")
        || text.contains("文档")
        || text.contains("本地")
        || text.contains("展示")
        || text.contains("打开");
    let has_lookup_word = text.contains("有")
        || text.contains("找")
        || text.contains("查")
        || text.contains("搜索")
        || text.contains("展示")
        || text.contains("打开")
        || text.contains("读取")
        || lower.contains("find")
        || lower.contains("search")
        || lower.contains("show")
        || lower.contains("open");
    has_file_word
        && has_lookup_word
        && (lower.contains("pdf")
            || lower.contains("docx")
            || lower.contains("doc")
            || lower.contains("pptx")
            || lower.contains("xlsx")
            || text.contains("本地")
            || text.contains("文件")
            || text.contains("文档"))
}

fn is_local_file_task_request(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let has_path = Regex::new(r"(?i)(/[^[:space:]]+|~/?[^[:space:]]*)")
        .expect("valid local path regex")
        .is_match(text);
    let has_document_ext = lower.contains(".pdf")
        || lower.contains(".docx")
        || lower.contains(".doc")
        || lower.contains(".pptx")
        || lower.contains(".xlsx")
        || lower.contains(".md")
        || lower.contains(".txt");
    let has_lookup_word = text.contains("搜索")
        || text.contains("查")
        || text.contains("找")
        || text.contains("展示")
        || text.contains("打开")
        || text.contains("读取")
        || lower.contains("search")
        || lower.contains("find")
        || lower.contains("show")
        || lower.contains("open");
    (has_path || has_document_ext) && has_lookup_word
}

fn local_file_lookup_reply(text: &str) -> String {
    let has_path = Regex::new(r"(/[^[:space:]]+|~/?[^[:space:]]*)")
        .expect("valid local path regex")
        .is_match(text);
    if has_path {
        return "可以做本地文件查询。当前只会只读检查你给的路径；如果要执行，请用“任务：在 <路径> 查找/展示 PDF”，我会先生成任务并等待审批。".to_string();
    }
    "可以查本地文件，但这句话缺少搜索范围。请补一句：任务：在 <路径> 查找 PDF 并展示。默认不会扫全盘；当前使用 H.A.R.V.I.S. 私有工作区作为安全边界。"
        .to_string()
}

fn is_external_article_material_request(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("mp.weixin.qq.com/s/")
        || lower.contains("mp.weixin.qq.com/mp/appmsgalbum")
        || lower.contains("zhuanlan.zhihu.com/p/")
        || lower.contains("zhihu.com/question/")
        || lower.contains("zhihu.com/tardis/")
        || lower.contains("blog.csdn.net/")
        || lower.contains("csdn.net/article/")
        || lower.contains("微信文章")
        || lower.contains("微信链接")
        || lower.contains("公众号文章")
        || lower.contains("知乎链接")
        || lower.contains("知乎文章")
        || lower.contains("csdn链接")
        || lower.contains("csdn文章")
        || lower.contains("wechat article")
}

fn is_wechat_draft_box_request(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let mentions_draft_box = text.contains("草稿箱")
        || text.contains("公众号草稿")
        || text.contains("微信草稿")
        || lower.contains("create_draft")
        || lower.contains("draft box")
        || lower.contains("wechat draft");
    if !mentions_draft_box {
        return false;
    }
    let mentions_wechat_surface =
        text.contains("公众号") || text.contains("微信") || lower.contains("wechat");
    let has_external_article = is_external_article_material_request(text);
    let has_formal_publish = text.contains("群发")
        || text.contains("正式发布")
        || text.contains("发出去")
        || lower.contains("freepublish")
        || lower.contains("group-send")
        || lower.contains("mass send")
        || lower.contains("formal publish");
    (mentions_wechat_surface || has_external_article) && !has_formal_publish
}

fn task_marker_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)(^|[\s:：])(?:task|fsrealtask)[A-Za-z0-9_-]*\b")
            .expect("valid task marker regex")
    })
}

fn extract_approval_packet_id(text: &str) -> Option<String> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(r"(?:批准执行|同意执行|开始执行)\s+([A-Za-z0-9_-]{8,64})")
            .expect("valid approval regex")
    });
    re.captures(text)
        .and_then(|capture| capture.get(1).map(|item| item.as_str().to_string()))
}

fn is_approval_request(text: &str) -> bool {
    let trimmed = text.trim();
    if extract_approval_packet_id(trimmed).is_some() {
        return true;
    }
    trimmed == "批准执行"
        || trimmed == "同意执行"
        || trimmed == "开始执行"
        || trimmed == "批准"
        || trimmed.to_ascii_lowercase() == "approve"
}

fn detect_preset_name(text: &str) -> Option<&'static str> {
    let lower = text.to_ascii_lowercase();
    ["cxspark", "cckimi", "mimocode"]
        .into_iter()
        .find(|name| lower.contains(name))
}

fn route_repo_lookup(text: &str, map_path: Option<&Path>, include_paths: bool) -> Result<Value> {
    let candidates = extract_repo_candidates(text);
    let map_path_string = map_path.map(|path| path.display().to_string());
    if candidates.is_empty() {
        let attention = repoatlas_needs_attention(12, map_path_string.as_deref(), include_paths);
        return Ok(json!({
            "mode": "attention_fallback",
            "query_count": 0,
            "queries": [],
            "count": attention.get("count").cloned().unwrap_or_else(|| json!(0)),
            "items": attention.get("items").cloned().unwrap_or_else(|| json!([])),
            "source": "repoatlas/attention",
            "includesLocalAbsolutePaths": include_paths
        }));
    }
    let mut items = Vec::new();
    for query in &candidates {
        let found = repoatlas_find_repo(query, 5, map_path_string.as_deref(), include_paths)?;
        for item in found
            .get("items")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
        {
            items.push(item);
        }
    }
    let mut seen = HashSet::new();
    items.retain(|item| {
        let key = item
            .get("repoKey")
            .and_then(Value::as_str)
            .or_else(|| item.get("nameWithOwner").and_then(Value::as_str))
            .unwrap_or("")
            .to_string();
        !key.is_empty() && seen.insert(key)
    });
    Ok(json!({
        "mode": "candidate_lookup",
        "query_count": candidates.len(),
        "queries": candidates,
        "count": items.len(),
        "items": items,
        "source": "repoatlas/find",
        "includesLocalAbsolutePaths": include_paths
    }))
}

fn extract_repo_candidates(text: &str) -> Vec<String> {
    static RE_OWNER_REPO: OnceLock<Regex> = OnceLock::new();
    static RE_BRACKET_OWNER_REPO: OnceLock<Regex> = OnceLock::new();
    static RE_DDL: OnceLock<Regex> = OnceLock::new();
    static RE_COMPACT_JUSTDDL: OnceLock<Regex> = OnceLock::new();
    let owner_repo = RE_OWNER_REPO.get_or_init(|| {
        Regex::new(r"\b([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\b").expect("valid repo regex")
    });
    let bracket_owner_repo = RE_BRACKET_OWNER_REPO.get_or_init(|| {
        Regex::new(r"\[([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\]").expect("valid bracket repo regex")
    });
    let ddl = RE_DDL.get_or_init(|| {
        Regex::new(r"\b([A-Za-z0-9_.-]+-ddl|[A-Za-z0-9_.-]+_ddl)\b").expect("valid ddl regex")
    });
    let compact_justddl = RE_COMPACT_JUSTDDL
        .get_or_init(|| Regex::new(r"(?i)\b(justddl)\b").expect("valid justddl regex"));
    let mut values = BTreeSet::new();
    for captures in bracket_owner_repo
        .captures_iter(text)
        .chain(owner_repo.captures_iter(text))
    {
        if let Some(value) = captures.get(1).map(|item| item.as_str()) {
            values.insert(
                value
                    .trim_matches(['.', ',', ';', ':', ')', ']', '】'])
                    .to_string(),
            );
            if let Some((_, repo)) = value.rsplit_once('/') {
                values.insert(repo.to_string());
            }
        }
    }
    for captures in ddl.captures_iter(text) {
        if let Some(value) = captures.get(1).map(|item| item.as_str()) {
            values.insert(
                value
                    .trim_matches(['.', ',', ';', ':', ')', ']', '】'])
                    .to_string(),
            );
        }
    }
    for captures in compact_justddl.captures_iter(text) {
        if captures.get(1).is_some() {
            values.insert("just-ddl".to_string());
            values.insert("justddl".to_string());
        }
    }
    values
        .into_iter()
        .filter(|value| !value.is_empty())
        .collect()
}

fn repo_lookup_reply(lookup: &Value) -> String {
    let count = lookup.get("count").and_then(Value::as_u64).unwrap_or(0);
    let Some(items) = lookup.get("items").and_then(Value::as_array) else {
        return "没有查到 RepoAtlas 结果。".to_string();
    };
    if items.is_empty() {
        return "没有从 RepoAtlas 查到匹配仓库。请补充仓库名或 owner/repo。".to_string();
    }
    let mut lines = vec![format!("找到 {count} 个 RepoAtlas 结果：")];
    for (index, item) in items.iter().take(8).enumerate() {
        let name = item
            .get("nameWithOwner")
            .and_then(Value::as_str)
            .or_else(|| item.get("repoKey").and_then(Value::as_str))
            .unwrap_or("unknown");
        let status = item
            .get("localStatus")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let dirty = item.get("dirty").and_then(Value::as_bool).unwrap_or(false);
        let ahead = item.get("ahead").and_then(Value::as_i64).unwrap_or(0);
        let behind = item.get("behind").and_then(Value::as_i64).unwrap_or(0);
        let path_text = item
            .get("localPaths")
            .and_then(Value::as_array)
            .and_then(|paths| paths.first())
            .and_then(Value::as_str)
            .or_else(|| {
                item.get("localPathDisplays")
                    .and_then(Value::as_array)
                    .and_then(|paths| paths.first())
                    .and_then(Value::as_str)
            })
            .unwrap_or("no local path");
        lines.push(format!(
            "{}. {} | {} | dirty={} ahead={} behind={} | {}",
            index + 1,
            name,
            status,
            dirty,
            ahead,
            behind,
            path_text
        ));
    }
    lines.join("\n")
}

fn enqueue_task(
    root: &Path,
    text: &str,
    options: &RouteMessageOptions,
    preset: Option<&Value>,
) -> Result<Value> {
    let harvis_dir = root.join(".harvis");
    fs::create_dir_all(&harvis_dir)?;
    let inbox = harvis_dir.join("inbox.md");
    if !inbox.exists() {
        fs::write(&inbox, "# H.A.R.V.I.S. Inbox\n\n")?;
    }
    let mut body = task_body(text);
    if body.is_empty() {
        body = text.trim().to_string();
    }
    let preset_line = preset.and_then(|preset| {
        let preset_id = preset.get("preset_id").and_then(Value::as_str)?;
        let harness_id = preset
            .get("harness_id")
            .and_then(Value::as_str)
            .unwrap_or("");
        let model_id = preset.get("model_id").and_then(Value::as_str).unwrap_or("");
        Some(format!(
            "Preferred runtime preset: {preset_id} ({harness_id} + {model_id})"
        ))
    });
    let received = harvis_core::time::now_rfc3339()?;
    let mut entry = vec![
        String::new(),
        format!("@harvis {body}"),
        "Scope: Harvis Router transport intake; do not execute automatically.".to_string(),
        format!("Transport: {}", options.transport),
        format!("Sender: {}", options.sender),
    ];
    if let Some(chat_id) = &options.chat_id {
        entry.push(format!("Chat: {chat_id}"));
    }
    if let Some(message_id) = &options.message_id {
        entry.push(format!("Message: {message_id}"));
    }
    if let Some(preset_line) = preset_line {
        entry.push(preset_line);
    }
    entry.push(format!("Received: {received}"));
    if is_external_article_material_request(text) || is_wechat_draft_box_request(text) {
        entry.push(
            "Need: create a Codex Conductor task and run it under the local handoff/audit boundary; only delete / 删除 / 清空 require approval by default. create_draft is an allowed draft-box action."
                .to_string(),
        );
    } else {
        entry.push("Need: triage this request, create a safe plan, and ask for approval before destructive actions.".to_string());
    }
    entry.push(String::new());
    let mut file = OpenOptions::new().create(true).append(true).open(&inbox)?;
    file.write_all(entry.join("\n").as_bytes())?;

    let outbox = harvis_dir.join("outbox");
    let before_packets = list_packet_paths(&outbox)?;
    let scanned_packets = scan_inboxes(ScanOptions {
        root: root.to_path_buf(),
        inboxes: vec![inbox.clone()],
        allow_outside_root: false,
    })?;
    let packets = if before_packets.is_empty() {
        scanned_packets
    } else {
        scanned_packets
            .into_iter()
            .filter(|path| !before_packets.contains(path))
            .collect::<Vec<_>>()
    };
    let runs = if packets.is_empty() {
        json!({"run_count": 0, "runs": []})
    } else {
        serde_json::to_value(sync_packet_runs(root, Some(packets.clone()), 500)?)?
    };
    Ok(json!({
        "inbox": inbox.display().to_string(),
        "packets_written": packets.iter().map(|path| path.display().to_string()).collect::<Vec<_>>(),
        "runs_written": runs.get("runs").cloned().unwrap_or_else(|| json!([]))
    }))
}

fn list_packet_paths(outbox: &Path) -> Result<HashSet<PathBuf>> {
    if !outbox.exists() {
        return Ok(HashSet::new());
    }
    let mut paths = HashSet::new();
    for entry in fs::read_dir(outbox)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) == Some("md") {
            paths.insert(path);
        }
    }
    Ok(paths)
}

fn task_body(text: &str) -> String {
    let mut body = text.trim().to_string();
    body = task_marker_regex().replace(&body, " ").to_string();
    body.trim()
        .trim_start_matches("发布任务")
        .trim_start_matches("新任务")
        .trim_start_matches("任务:")
        .trim_start_matches("任务：")
        .trim()
        .to_string()
}

fn task_reply(
    task: &Value,
    preset: Option<&Value>,
    runtime_selection: Option<&Value>,
    ready_to_run: bool,
) -> String {
    let packets = task
        .get("packets_written")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut lines = vec![if ready_to_run {
        "已创建 H.A.R.V.I.S. 受控任务，当前可进入执行。".to_string()
    } else {
        "已创建 H.A.R.V.I.S. 任务，当前等待审批。".to_string()
    }];
    if task.get("inbox").and_then(Value::as_str).is_some() {
        lines.push("收件箱：H.A.R.V.I.S. 私有任务队列".to_string());
    }
    if let Some(preset) = preset {
        if let Some(preset_id) = preset.get("preset_id").and_then(Value::as_str) {
            lines.push(format!("运行预设：{preset_id}"));
        }
    }
    if let Some(selection) = runtime_selection {
        if let Some(selected) = selection.get("selected").filter(|value| !value.is_null()) {
            let harness = selected
                .get("harness_id")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let model = selected
                .get("model_id")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let preset = selected
                .get("preset_id")
                .and_then(Value::as_str)
                .unwrap_or("none");
            lines.push(format!("推荐 runtime：{preset} | {harness} + {model}"));
            if let Some(recommendation) = selection.get("recommendation") {
                if recommendation
                    .get("fallback_applied")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                {
                    if let Some(note) = recommendation.get("note").and_then(Value::as_str) {
                        lines.push(format!("路由说明：{note}"));
                    }
                }
            }
        }
    }
    if packets.is_empty() {
        lines.push("没有生成新的任务包。".to_string());
    } else {
        lines.push("任务包：".to_string());
        for path in packets.iter().take(5).filter_map(Value::as_str) {
            let packet_id = Path::new(path)
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or(path);
            lines.push(format!("- {packet_id}"));
        }
        if ready_to_run {
            lines.push("低风险任务会按 Harvis listener/Conductor 受控执行；delete / 删除 / 清空 仍需审批。".to_string());
        } else {
            lines.push("回复“批准执行 <packet_id>”后再进入受控执行。".to_string());
        }
    }
    lines.join("\n")
}

fn sync_route_to_workbench(root: &Path, result: &mut Value) -> Result<()> {
    let intent = result.get("intent").and_then(Value::as_str).unwrap_or("");
    match intent {
        "repo_lookup" => {
            let lookup = result
                .get("repo_lookup")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let count = lookup.get("count").and_then(Value::as_u64).unwrap_or(0);
            let task = create_task(
                root,
                TaskInput {
                    topic_id: Some("gwt-workbench".to_string()),
                    title: format!(
                        "Knowledge lookup: {}",
                        short_title(result.get("text").and_then(Value::as_str).unwrap_or(""))
                    ),
                    owner_slot_id: "knowledge".to_string(),
                    status: Some(if count > 0 { "done" } else { "blocked" }.to_string()),
                    source_event_id: result
                        .get("event_id")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned),
                    description: Some("Router classified this message as repo_lookup and assigned it to the knowledge slot.".to_string()),
                    metadata: Some(json!({
                        "intent": "repo_lookup",
                        "transport": result.get("transport").cloned().unwrap_or(Value::Null),
                        "sender": result.get("sender").cloned().unwrap_or(Value::Null),
                        "chat_id": result.get("chat_id").cloned().unwrap_or(Value::Null),
                        "message_id": result.get("message_id").cloned().unwrap_or(Value::Null),
                        "repo_lookup": lookup
                    })),
                    ..TaskInput::default()
                },
            )?;
            result["workbench_task"] = task;
            push_lifecycle(
                result,
                "workbench_task_recorded",
                "Repo lookup was recorded on the shared task board.",
            );
        }
        "task_enqueue" => {
            let task_enqueue = result
                .get("task_enqueue")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let packet_ids = packet_ids_from_task_enqueue(&task_enqueue);
            let run_ids = run_ids_from_task_enqueue(&task_enqueue);
            let owner = if result
                .get("selected_preset")
                .is_some_and(|value| !value.is_null())
            {
                "executor"
            } else {
                "planner"
            };
            let original_text = result.get("text").and_then(Value::as_str).unwrap_or("");
            let conductor_ready = is_external_article_material_request(original_text)
                || is_wechat_draft_box_request(original_text);
            let task = create_task(
                root,
                TaskInput {
                    topic_id: Some("gwt-workbench".to_string()),
                    title: short_title(result.get("text").and_then(Value::as_str).unwrap_or("Task")),
                    owner_slot_id: owner.to_string(),
                    status: Some(
                        if conductor_ready {
                            "pending"
                        } else {
                            "waiting_approval"
                        }
                        .to_string(),
                    ),
                    source_event_id: result
                        .get("event_id")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned),
                    packet_id: packet_ids.first().cloned(),
                    run_id: run_ids.first().cloned(),
                    description: Some(
                        if conductor_ready {
                            "Router created a Codex Conductor task. create_draft is allowed; only delete / 删除 / 清空 require approval by default."
                        } else {
                            "Router task_enqueue bridge created this shared task board item. Execution still requires approval."
                        }
                        .to_string(),
                    ),
                    metadata: Some(json!({
                        "intent": "task_enqueue",
                        "transport": result.get("transport").cloned().unwrap_or(Value::Null),
                        "sender": result.get("sender").cloned().unwrap_or(Value::Null),
                        "chat_id": result.get("chat_id").cloned().unwrap_or(Value::Null),
                        "message_id": result.get("message_id").cloned().unwrap_or(Value::Null),
                        "packet_ids": packet_ids,
                        "run_ids": run_ids,
                        "ready_to_run": conductor_ready,
                        "selected_preset": result.get("selected_preset").cloned().unwrap_or(Value::Null),
                        "runtime_selection": result.get("runtime_selection").cloned().unwrap_or(Value::Null)
                    })),
                    ..TaskInput::default()
                },
            )?;
            result["workbench_task"] = task;
            push_lifecycle(
                result,
                "workbench_task_recorded",
                "Task enqueue was recorded on the shared task board.",
            );
        }
        "publish_request" => {
            let plan = result
                .get("publish_request")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let task_enqueue = result
                .get("publish_request_task")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let packet_ids = packet_ids_from_task_enqueue(&task_enqueue);
            if packet_ids.is_empty() {
                return Ok(());
            }
            let run_ids = run_ids_from_task_enqueue(&task_enqueue);
            let task = create_task(
                root,
                TaskInput {
                    topic_id: Some("gwt-workbench".to_string()),
                    title: format!(
                        "发布预检查：{}",
                        short_title(
                            result
                                .get("text")
                                .and_then(Value::as_str)
                                .unwrap_or("Publish request")
                        )
                    ),
                    owner_slot_id: "planner".to_string(),
                    status: Some("waiting_approval".to_string()),
                    source_event_id: result
                        .get("event_id")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned),
                    packet_id: packet_ids.first().cloned(),
                    run_id: run_ids.first().cloned(),
                    description: Some("Router recognized a publish/deploy request and created an approval-gated precheck task. The task must not publish, deploy, push, or write to external systems.".to_string()),
                    metadata: Some(json!({
                        "intent": "publish_request",
                        "transport": result.get("transport").cloned().unwrap_or(Value::Null),
                        "sender": result.get("sender").cloned().unwrap_or(Value::Null),
                        "chat_id": result.get("chat_id").cloned().unwrap_or(Value::Null),
                        "message_id": result.get("message_id").cloned().unwrap_or(Value::Null),
                        "packet_ids": packet_ids,
                        "run_ids": run_ids,
                        "publish_request": plan,
                        "selected_preset": result.get("selected_preset").cloned().unwrap_or(Value::Null),
                        "runtime_selection": result.get("runtime_selection").cloned().unwrap_or(Value::Null),
                        "approval_reason": "publish/deploy/push/external write is high risk; only local precheck is allowed after this approval"
                    })),
                    ..TaskInput::default()
                },
            )?;
            result["workbench_task"] = task;
            push_lifecycle(
                result,
                "workbench_task_recorded",
                "Publish precheck was recorded on the shared task board.",
            );
        }
        "approve_execute" => {
            let packet_id = result
                .get("approval")
                .and_then(|approval| approval.get("packet_id"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if packet_id.is_empty() {
                return Ok(());
            }
            let run_id = format!("run_{packet_id}");
            let task = match find_task_by_packet_id(root, &packet_id)? {
                Some(task) => {
                    let task_id = task
                        .get("task_id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    let link = link_task(
                        root,
                        TaskLinkInput {
                            task_id,
                            packet_id: Some(packet_id.clone()),
                            run_id: Some(run_id.clone()),
                            status: Some("in_progress".to_string()),
                            note: Some("Router recognized explicit approval and linked the task to the approved packet.".to_string()),
                            ..TaskLinkInput::default()
                        },
                    )?;
                    result["workbench_task_link"] = link;
                    task
                }
                None => create_task(
                    root,
                    TaskInput {
                        topic_id: Some("gwt-workbench".to_string()),
                        title: format!("Approved execution: {packet_id}"),
                        owner_slot_id: "executor".to_string(),
                        status: Some("in_progress".to_string()),
                        source_event_id: result
                            .get("event_id")
                            .and_then(Value::as_str)
                            .map(ToOwned::to_owned),
                        packet_id: Some(packet_id.clone()),
                        run_id: Some(run_id.clone()),
                        description: Some("Router saw an approval for a packet that was not yet linked to a task.".to_string()),
                        metadata: Some(json!({"intent": "approve_execute"})),
                        ..TaskInput::default()
                    },
                )?,
            };
            result["workbench_task"] = task;
            push_lifecycle(
                result,
                "workbench_task_linked",
                "Approval was linked to the shared task board.",
            );
        }
        _ => {}
    }
    Ok(())
}

fn preset_reply(preset: Option<&Value>) -> String {
    let Some(preset) = preset else {
        return "识别到运行预设请求，但没有找到对应 preset。".to_string();
    };
    let preset_id = preset
        .get("preset_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let harness = preset
        .get("harness_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let model = preset
        .get("model_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    format!(
        "已选择运行预设：{preset_id}\n展开为：{harness} + {model}\n请继续说明任务，或发送“任务：...”生成 Harvis 任务包。"
    )
}

fn status_reply(state: &Value, executions: &Value) -> String {
    let open_tasks = state
        .get("open_tasks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let waiting = state
        .get("waiting_approval_queue")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let pending_approvals = state
        .get("pending_approvals")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let handoffs = state
        .get("recent_handoffs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let in_progress = open_tasks
        .iter()
        .filter(|task| task.get("status").and_then(Value::as_str) == Some("in_progress"))
        .count();

    let mut lines = vec![
        "H.A.R.V.I.S. 当前进展：".to_string(),
        format!("- open tasks: {}", open_tasks.len()),
        format!("- waiting approval gates: {}", waiting.len()),
        format!("- pending approvals: {}", pending_approvals.len()),
        format!("- in-progress tasks: {in_progress}"),
    ];

    if let Some(items) = executions.as_array() {
        if !items.is_empty() {
            lines.push("最近执行：".to_string());
            for item in items.iter().take(3) {
                let packet = item
                    .get("packet_id")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let status = item
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let exit_code = item.get("exit_code").cloned().unwrap_or(Value::Null);
                lines.push(format!("- {packet}: {status}, exit={exit_code}"));
            }
        }
    }

    if !waiting.is_empty() {
        lines.push("等待审批：".to_string());
        for task in waiting.iter().take(5) {
            lines.push(format!("- {}", router_task_line(task)));
        }
    } else if !open_tasks.is_empty() {
        lines.push("未关闭任务：".to_string());
        for task in open_tasks.iter().take(5) {
            lines.push(format!("- {}", router_task_line(task)));
        }
    }

    if !handoffs.is_empty() {
        lines.push("最近 handoff：".to_string());
        for handoff in handoffs.iter().take(3) {
            let handoff_id = handoff
                .get("handoff_id")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let state = handoff
                .get("state")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let run_id = handoff
                .get("run_id")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            lines.push(format!("- {handoff_id}: {state} | run={run_id}"));
        }
    }

    lines.join("\n")
}

fn router_task_line(task: &Value) -> String {
    let task_id = task
        .get("task_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let status = task
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let title = task.get("title").and_then(Value::as_str).unwrap_or("");
    let packet = task
        .get("packet_id")
        .and_then(Value::as_str)
        .unwrap_or("none");
    let handoff = task
        .get("handoff_id")
        .and_then(Value::as_str)
        .unwrap_or("none");
    format!("{task_id}: {status} | {title} | packet={packet} | handoff={handoff}")
}

fn packet_ids_from_task_enqueue(task: &Value) -> Vec<String> {
    task.get("packets_written")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter_map(|path| {
            Path::new(path)
                .file_stem()
                .and_then(|value| value.to_str())
                .map(ToOwned::to_owned)
        })
        .collect()
}

fn run_ids_from_task_enqueue(task: &Value) -> Vec<String> {
    task.get("runs_written")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|run| run.get("run_id").and_then(Value::as_str))
        .map(ToOwned::to_owned)
        .collect()
}

fn short_title(text: &str) -> String {
    let title = task_body(text);
    let title = if title.is_empty() {
        text.trim()
    } else {
        title.trim()
    };
    let mut result = title.chars().take(120).collect::<String>();
    if result.is_empty() {
        result = "Untitled router task".to_string();
    }
    result
}

fn push_lifecycle(result: &mut Value, state: &str, summary: &str) {
    if let Some(items) = result.get_mut("lifecycle").and_then(Value::as_array_mut) {
        items.push(json!({"state": state, "summary": summary}));
    }
}

fn route_event_id(options: &RouteMessageOptions, text: &str) -> Result<String> {
    let moment = harvis_core::time::now_rfc3339()?;
    let slug = timestamp_slug(&moment);
    let source = options
        .message_id
        .as_deref()
        .or(options.chat_id.as_deref())
        .unwrap_or(text);
    Ok(format!("router_{slug}_{}", safe_slug(source)))
}

fn timestamp_slug(moment: &str) -> String {
    moment
        .chars()
        .filter(|character| character.is_ascii_digit())
        .take(14)
        .collect::<String>()
}

fn safe_slug(value: &str) -> String {
    let slug = value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .chars()
        .take(48)
        .collect::<String>();
    if slug.is_empty() {
        "message".to_string()
    } else {
        slug
    }
}

fn record_route_conversation(root: &Path, result: &Value) -> Result<()> {
    let intent = result.get("intent").and_then(Value::as_str).unwrap_or("");
    let route_state = result
        .get("route_state")
        .and_then(Value::as_str)
        .unwrap_or("");
    let task = result
        .get("workbench_task_link")
        .filter(|value| !value.is_null())
        .or_else(|| {
            result
                .get("workbench_task")
                .filter(|value| !value.is_null())
        });
    let task_id = task
        .and_then(|task| task.get("task_id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let packet_id = task
        .and_then(|task| task.get("packet_id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| {
            result
                .get("approval")
                .and_then(|approval| approval.get("packet_id"))
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
        });
    let run_id = task
        .and_then(|task| task.get("run_id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let handoff_id = task
        .and_then(|task| task.get("handoff_id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let title = task
        .and_then(|task| task.get("title"))
        .and_then(Value::as_str)
        .unwrap_or_else(|| result.get("text").and_then(Value::as_str).unwrap_or(""));
    let summary = match intent {
        "task_enqueue" => format!("Task enqueued: {}", short_title(title)),
        "publish_request" => format!(
            "Publish request needs precheck/approval: {}",
            short_title(title)
        ),
        "approval_query" => "Approval query projected for this conversation.".to_string(),
        "approve_execute" => packet_id
            .as_deref()
            .map(|packet_id| format!("Approved execution for packet {packet_id}."))
            .unwrap_or_else(|| "Approval phrase received without a packet target.".to_string()),
        "repo_lookup" => format!("Repo lookup: {}", short_title(title)),
        "local_file_lookup" => format!("Local file lookup needs scope: {}", short_title(title)),
        "status_query" => "Status query projected for this conversation.".to_string(),
        _ => format!("Message acknowledged: {}", short_title(title)),
    };
    record_conversation_state(
        root,
        ConversationInput {
            transport: result
                .get("transport")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
            chat_id: result
                .get("chat_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            sender: result
                .get("sender")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            message_id: result
                .get("message_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            intent: Some(intent.to_string()),
            route_state: Some(route_state.to_string()),
            task_id,
            packet_id,
            run_id,
            handoff_id,
            summary: Some(summary),
            metadata: Some(json!({
                "event_id": result.get("event_id").cloned().unwrap_or(Value::Null),
                "selected_preset": result.get("selected_preset").cloned().unwrap_or(Value::Null),
                "runtime_selection": result.get("runtime_selection").cloned().unwrap_or(Value::Null),
                "safety": {"raw_message_stored": false}
            })),
        },
    )?;
    Ok(())
}

fn append_router_event(root: &Path, result: &Value) -> Result<()> {
    let dir = root.join(".harvis/router");
    fs::create_dir_all(&dir)?;
    let path = dir.join("events.jsonl");
    let mut event = result.clone();
    event["recorded_at"] = json!(harvis_core::time::now_rfc3339()?);
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{}", serde_json::to_string(&event)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use harvis_runtime::init::init_workspace;
    use serde::Deserialize;

    #[derive(Debug, Deserialize)]
    struct RouterEvalSet {
        cases: Vec<RouterEvalCase>,
    }

    #[derive(Debug, Deserialize)]
    struct RouterEvalCase {
        id: String,
        text: String,
        expected_intent: String,
        expected_owner_slot_id: String,
    }

    fn assert_external_reply_has_no_private_path(reply: &str) {
        assert!(!reply.contains("/Users/"), "leaked user path: {reply}");
        assert!(!reply.contains("/Volumes/"), "leaked volume path: {reply}");
        assert!(
            !Regex::new(r#"(?i)(?:^|[[:space:]"'])(?:[a-z]:[\\/]|\\\\)"#)
                .expect("valid private path regex")
                .is_match(reply),
            "leaked Windows or UNC path: {reply}"
        );
    }

    #[test]
    fn extracts_repos_from_github_action_subjects() {
        let repos = extract_repo_candidates("[Just-Agent/just-ddl] Run failed; programming-ddl");
        assert!(repos.contains(&"Just-Agent/just-ddl".to_string()));
        assert!(repos.contains(&"just-ddl".to_string()));
        assert!(repos.contains(&"programming-ddl".to_string()));
    }

    #[test]
    fn extracts_compact_justddl_alias() {
        let repos = extract_repo_candidates("查 justddl");
        assert!(repos.contains(&"just-ddl".to_string()));
    }

    #[test]
    fn classifies_presets_as_preset_route() {
        assert_eq!(classify_intent("用 cxspark 审一下", ""), "preset_route");
    }

    #[test]
    fn preset_prefixed_task_is_task_enqueue() {
        assert_eq!(
            classify_intent("用 cxspark 任务：只说 OK，不要改文件", ""),
            "task_enqueue"
        );
    }

    #[test]
    fn repo_failure_lookup_routes_as_task() {
        assert_eq!(
            classify_intent("查 just-ddl 最近失败", "查 just-ddl 最近失败"),
            "task_enqueue"
        );
    }

    #[test]
    fn bare_wechat_article_link_routes_as_task() {
        let text = "https://mp.weixin.qq.com/s/kiHCMo_kqP0fj7zIkm9bQw";
        assert_eq!(classify_intent(text, text), "task_enqueue");
    }

    #[test]
    fn wechat_draft_box_request_routes_to_conductor_without_publish_gate() {
        let text = "https://mp.weixin.qq.com/s/example 最后记得发布到微信草稿箱";
        assert_eq!(classify_intent(text, text), "task_enqueue");
        assert!(!is_publish_request(text));
        let task = task_enqueue_text(text);
        assert!(task.contains("Codex Conductor 动态处理外部文章链接"));
        assert!(task.contains("create_draft 是允许的公众号草稿箱动作"));
        assert!(task.contains("delete / 删除 / 清空 才是高风险审批"));
    }

    #[test]
    fn create_draft_request_routes_to_conductor_without_publish_gate() {
        let text = "把这篇公众号文章 create_draft 到微信草稿箱";
        assert_eq!(classify_intent(text, text), "task_enqueue");
        assert!(!is_publish_request(text));
    }

    #[test]
    fn route_wechat_draft_box_request_is_ready_to_run() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-wechat-draft-ready-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let routed = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit".to_string(),
            text: "https://mp.weixin.qq.com/s/example 最后记得发布到微信草稿箱".to_string(),
            chat_id: Some("chat-wechat-draft".to_string()),
            message_id: Some("msg-wechat-draft".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route wechat draft request");
        assert_eq!(routed["intent"], "task_enqueue");
        assert_eq!(routed["route_state"], "ready_to_run");
        assert_eq!(
            routed["safety"]["requires_approval_for_execution"],
            json!(false)
        );
        assert_eq!(routed["workbench_task"]["status"], "pending");
        assert_eq!(
            routed["workbench_task"]["metadata"]["ready_to_run"],
            json!(true)
        );
        let reply = routed["reply_text"].as_str().unwrap_or_default();
        assert!(reply.contains("受控任务"));
        assert!(reply.contains("delete / 删除 / 清空"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn wemedia_path_question_resolves_known_path_without_runner() {
        let text = "你知道 wemedia 的路径在哪里吗";
        assert_eq!(classify_intent(text, text), "known_path_lookup");
        let lookup = known_path_lookup(text, text);
        assert_eq!(lookup["alias"], json!("wemedia"));
        assert_eq!(lookup["alias"], json!("wemedia"));
        assert_eq!(lookup["source"], json!("harvis-known-alias"));
    }

    #[test]
    fn external_article_task_is_rewritten_to_wemedia_material_pipeline() {
        let text = "https://mp.weixin.qq.com/s/example 讲这个微信文章整理下来相关论文下载到 wemedia 相关文件夹";
        let task = task_enqueue_text(text);
        assert!(task.contains("Codex Conductor 动态处理外部文章链接"));
        assert!(task.contains("素材目标目录："));
        assert!(task.contains("文章素材库"));
        assert!(task.contains("conductor_task.json"));
        assert!(task.contains("conductor_events.jsonl"));
        assert!(task.contains("conductor_result.json"));
        assert!(task.contains("kimi"));
        assert!(task.contains("md2wechat"));
        assert!(task.contains("browser"));
        assert!(task.contains("references/playbooks/wemedia-wechat-draft.md"));
        assert!(task.contains("create_draft"));
        assert!(task.contains("delete / 删除 / 清空"));
        assert!(task.contains("exit 0 不等于成功"));
        assert!(task.contains("文章来源/来源公众号"));
        assert!(!task.contains("固定 workflow stage"));
        assert!(!task.contains("fetch_source_article"));
    }

    #[test]
    fn browser_operation_routes_as_task() {
        let text = "可以打开浏览器的百度吗然后搜索 小狗";
        assert_eq!(classify_intent(text, text), "task_enqueue");
    }

    #[test]
    fn publish_request_is_not_auto_task_enqueue() {
        assert_eq!(
            classify_intent("发布这篇文章", "发布这篇文章"),
            "publish_request"
        );
        assert_eq!(
            classify_intent(
                "部署这个页面到 GitHub Pages /tmp/site/index.html",
                "部署这个页面到 GitHub Pages /tmp/site/index.html"
            ),
            "publish_request"
        );
        assert_eq!(
            classify_intent("发布任务：检查 just-ddl", "发布任务：检查 just-ddl"),
            "task_enqueue"
        );
    }

    #[test]
    fn negated_publish_inside_readonly_task_is_task_enqueue() {
        let text = "任务：只读闭环验证 command_execution 新卡片。请只运行命令：printf '%s\\n' HARVIS_UI_CLOSED_LOOP_20260629_1400。不要修改文件，不要提交，不要发布。";
        assert_eq!(classify_intent(text, text), "task_enqueue");
    }

    #[test]
    fn readonly_task_with_execution_word_is_not_approval() {
        assert_eq!(
            classify_intent(
                "任务：找到 just-ddl 仓库并检查失败原因，不要执行 UIE2E20260628A",
                "任务：找到 just-ddl 仓库并检查失败原因，不要执行 UIE2E20260628A"
            ),
            "task_enqueue"
        );
    }

    #[test]
    fn explicit_approval_routes_as_approval() {
        assert_eq!(
            classify_intent("批准执行 UIE2E20260628A", "批准执行 UIE2E20260628A"),
            "approve_execute"
        );
        assert_eq!(classify_intent("批准执行", "批准执行"), "approve_execute");
    }

    #[test]
    fn approval_query_routes_to_approval_query() {
        for text in [
            "等待审批",
            "需要我批复吗？",
            "需要我审批吗？",
            "要我批复吗？",
            "要我审批吗？",
            "能执行了吗？",
            "审批状态",
            "批准状态",
            "待我审批",
            "待我批复",
            "需要我操作吗？",
            "要我操作吗？",
        ] {
            assert_eq!(classify_intent(text, text), "approval_query", "{text}");
        }
    }

    #[test]
    fn natural_progress_questions_route_as_status_query() {
        for text in [
            "有答案了吗？",
            "开始执行了吗？",
            "跑起来了吗？",
            "完成了吗？",
            "实验进度为什么没有反馈？哪怕是暂时做不了？",
            "正在运行 codex 线程有哪几个？",
            "查询任务",
            "进展如何",
        ] {
            assert_eq!(classify_intent(text, text), "status_query", "{text}");
        }
    }

    #[test]
    fn local_pdf_lookup_without_scope_needs_input() {
        assert_eq!(
            classify_intent("本地有pdf吗展示给我", "本地有pdf吗展示给我"),
            "local_file_lookup"
        );
        let reply = local_file_lookup_reply("本地有pdf吗展示给我");
        assert!(reply.contains("H.A.R.V.I.S. 私有工作区"));
        assert_external_reply_has_no_private_path(&reply);
    }

    #[test]
    fn explicit_lark_task_marker_precedes_local_file_lookup_heuristic() {
        let body =
            "在 HARVIS 隔离执行器中读取当前版本号并回传；禁止写文件、禁止网络、禁止外部消息。";
        for text in [
            format!("任务：{body}"),
            format!(" \n任务:{body}\t"),
            format!("\u{200b}任务：{body}\u{200b}"),
            format!("\u{feff}新任务：{body}\u{2060}"),
        ] {
            assert!(
                is_local_file_lookup_request(&text),
                "fixture must exercise lookup overlap"
            );
            assert_eq!(classify_intent(&text, &text), "task_enqueue", "{text:?}");
        }
    }

    #[test]
    fn exact_lark_task_reply_is_approval_gated_and_path_safe() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-lark-explicit-task-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let text = "任务：在 HARVIS 隔离执行器中读取当前版本号并回传；禁止写文件、禁止网络、禁止外部消息。";
        let routed = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit".to_string(),
            text: text.to_string(),
            chat_id: Some("chat-lark-explicit-task".to_string()),
            message_id: Some("msg-lark-explicit-task".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route explicit Lark task");
        assert_eq!(routed["intent"], "task_enqueue");
        assert_eq!(routed["route_state"], "waiting_approval");
        assert_eq!(
            routed["safety"]["requires_approval_for_execution"],
            json!(true)
        );
        let reply = routed["reply_text"].as_str().unwrap_or_default();
        assert!(reply.contains("当前等待审批"));
        assert!(reply.contains("H.A.R.V.I.S. 私有任务队列"));
        assert!(!reply.contains(&root.display().to_string()));
        assert_external_reply_has_no_private_path(reply);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_reply_redacts_private_inbox_and_packet_paths() {
        let task = json!({
            "inbox": "/Volumes/private/.harvis/inbox.md",
            "packets_written": ["/Users/private/.harvis/outbox/private-packet.md"]
        });
        let reply = task_reply(&task, None, None, false);
        assert!(reply.contains("H.A.R.V.I.S. 私有任务队列"));
        assert!(reply.contains("private-packet"));
        assert_external_reply_has_no_private_path(&reply);
    }

    #[test]
    fn local_docx_path_lookup_routes_as_task_not_browser() {
        let text = "/workspace/harmonyos/guide.docx 搜索这个docx";
        assert_eq!(classify_intent(text, text), "task_enqueue");
    }

    #[test]
    fn browser_search_still_routes_as_browser_task() {
        let text = "可以打开浏览器的百度吗然后搜索 小狗";
        assert_eq!(classify_intent(text, text), "task_enqueue");
        assert!(is_browser_operation_request(text));
    }

    #[test]
    fn routes_explicit_task_into_workbench_task_board() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-workbench-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let routed = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "test".to_string(),
            sender: "unit".to_string(),
            text: "任务：找到 just-ddl 仓库并检查失败原因".to_string(),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-test".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route");
        assert_eq!(routed["intent"], "task_enqueue");
        assert_eq!(routed["workbench_task"]["status"], "waiting_approval");
        assert_eq!(routed["workbench_task"]["owner_slot_id"], "planner");
        let state = workspace_state(&root, None, 20).expect("workspace state");
        let recent_conversation = state["recent_conversations"]
            .as_array()
            .and_then(|items| items.first())
            .expect("recent conversation");
        assert_eq!(recent_conversation["chat_id"], "chat-test");
        assert_eq!(recent_conversation["intent"], "task_enqueue");
        assert_eq!(
            recent_conversation["packet_id"],
            routed["workbench_task"]["packet_id"]
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn route_publish_request_asks_for_minimum_missing_info() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-publish-missing-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let routed = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit".to_string(),
            text: "发布这篇文章".to_string(),
            chat_id: Some("chat-publish".to_string()),
            message_id: Some("msg-publish".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route publish request");
        assert_eq!(routed["intent"], "publish_request");
        assert_eq!(routed["route_state"], "needs_input");
        assert!(routed.get("workbench_task").is_none());
        let text = routed["reply_text"].as_str().unwrap_or_default();
        assert!(text.contains("不会直接发布"));
        assert!(text.contains("缺少发布目标"));
        assert!(text.contains("真正发布"));
        assert!(text.contains("必须审批"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn route_publish_request_with_target_still_requires_approval() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-publish-approval-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let routed = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit".to_string(),
            text: "部署这个页面到 GitHub Pages /tmp/site/index.html".to_string(),
            chat_id: Some("chat-publish".to_string()),
            message_id: Some("msg-publish-target".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route publish request");
        assert_eq!(routed["intent"], "publish_request");
        assert_eq!(routed["route_state"], "waiting_approval");
        assert_eq!(routed["publish_request"]["requires_approval"], true);
        assert!(routed
            .get("workbench_task")
            .is_some_and(|value| !value.is_null()));
        assert_eq!(routed["workbench_task"]["status"], "waiting_approval");
        assert_eq!(routed["workbench_task"]["owner_slot_id"], "planner");
        let packet_id = routed["workbench_task"]["packet_id"]
            .as_str()
            .expect("workbench task packet id");
        assert!(!packet_id.is_empty());
        let text = routed["reply_text"].as_str().unwrap_or_default();
        assert!(text.contains("目标："));
        assert!(text.contains("GitHub Pages"));
        assert!(text.contains("预检查"));
        assert!(text.contains("必须审批"));
        assert!(text.contains("已创建发布预检查任务"));
        assert!(text.contains(packet_id));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn approval_without_packet_infers_latest_waiting_task_in_same_chat() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-approval-context-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let task = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit-a".to_string(),
            text: "任务：找到 just-ddl 仓库并检查失败原因".to_string(),
            chat_id: Some("chat-a".to_string()),
            message_id: Some("msg-task-a".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("task");
        let packet_id = task["workbench_task"]["packet_id"]
            .as_str()
            .expect("packet id")
            .to_string();
        let approval = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit-a".to_string(),
            text: "批准执行".to_string(),
            chat_id: Some("chat-a".to_string()),
            message_id: Some("msg-approval-a".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("approval");
        assert_eq!(approval["intent"], "approve_execute");
        assert_eq!(approval["approval"]["packet_id"], packet_id);
        assert_eq!(approval["approval"]["context_resolution"]["inferred"], true);
        assert_eq!(
            approval["approval"]["context_resolution"]["reason"],
            "conversation_state"
        );
        assert_eq!(
            approval["workbench_task_link"]["packet_id"],
            task["workbench_task"]["packet_id"]
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn approval_without_packet_does_not_cross_chat_context() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-approval-no-cross-chat-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit-a".to_string(),
            text: "任务：找到 just-ddl 仓库并检查失败原因".to_string(),
            chat_id: Some("chat-a".to_string()),
            message_id: Some("msg-task-a".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("task");
        let approval = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit-b".to_string(),
            text: "批准执行".to_string(),
            chat_id: Some("chat-b".to_string()),
            message_id: Some("msg-approval-b".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("approval");
        assert_eq!(approval["intent"], "approve_execute");
        assert_eq!(approval["approval"]["packet_id"], "");
        assert!(approval.get("workbench_task").is_none());
        assert!(approval["reply_text"]
            .as_str()
            .unwrap_or_default()
            .contains("批准执行 <packet_id>"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn approval_without_packet_does_not_cross_transport_context() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-approval-no-cross-transport-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit-a".to_string(),
            text: "任务：找到 just-ddl 仓库并检查失败原因".to_string(),
            chat_id: Some("shared-chat".to_string()),
            message_id: Some("msg-task-a".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("task");
        let approval = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "wechat".to_string(),
            sender: "unit-a".to_string(),
            text: "批准执行".to_string(),
            chat_id: Some("shared-chat".to_string()),
            message_id: Some("msg-approval-b".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("approval");
        assert_eq!(approval["intent"], "approve_execute");
        assert_eq!(approval["approval"]["packet_id"], "");
        assert!(approval.get("workbench_task").is_none());
        assert!(approval["reply_text"]
            .as_str()
            .unwrap_or_default()
            .contains("批准执行 <packet_id>"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn approval_without_packet_does_not_guess_when_sender_context_is_ambiguous() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-approval-ambiguous-sender-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        for (chat_id, message_id) in [("chat-a", "msg-task-a"), ("chat-b", "msg-task-b")] {
            route_message(RouteMessageOptions {
                root: root.clone(),
                transport: "feishu".to_string(),
                sender: "same-user".to_string(),
                text: format!("任务：找到 just-ddl 仓库并检查失败原因 {chat_id}"),
                chat_id: Some(chat_id.to_string()),
                message_id: Some(message_id.to_string()),
                context: Vec::new(),
                include_paths: false,
                map_path: None,
                agent_pools_path: None,
            })
            .expect("task");
        }
        let approval = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "same-user".to_string(),
            text: "批准执行".to_string(),
            chat_id: None,
            message_id: Some("msg-approval-ambiguous".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("approval");
        assert_eq!(approval["intent"], "approve_execute");
        assert_eq!(approval["approval"]["packet_id"], "");
        assert!(approval["reply_text"]
            .as_str()
            .unwrap_or_default()
            .contains("批准执行 <packet_id>"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn router_message_status_query_projects_shared_workspace_without_new_task() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-status-query-test-{}",
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
            message_id: Some("msg-task".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route task");
        assert_eq!(task["intent"], "task_enqueue");

        let routed = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit".to_string(),
            text: "有答案了吗？".to_string(),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-status".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route status");
        assert_eq!(routed["intent"], "status_query");
        assert_eq!(routed["route_state"], "status");
        assert!(routed["workspace_state"]["open_tasks"]
            .as_array()
            .is_some_and(|items| items.len() == 1));
        assert!(routed["reply_text"]
            .as_str()
            .unwrap_or_default()
            .contains("H.A.R.V.I.S. 当前进展"));
        assert!(routed.get("workbench_task").is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn router_message_status_query_can_focus_packet_id() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-status-target-test-{}",
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

        let routed = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit".to_string(),
            text: format!("{packet_id} 进展如何"),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-status-target".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route status");
        assert_eq!(routed["intent"], "status_query");
        assert_eq!(routed["status_detail"]["matched"], true);
        assert_eq!(routed["status_detail"]["target"]["kind"], "packet");
        assert_eq!(routed["status_detail"]["target"]["id"], packet_id);
        assert_eq!(
            routed["status_detail"]["task"]["task_id"],
            task["workbench_task"]["task_id"]
        );
        assert!(routed["reply_text"]
            .as_str()
            .unwrap_or_default()
            .contains("H.A.R.V.I.S. 单项进展"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn local_needs_eval_cases_classify_correctly() {
        let eval: RouterEvalSet = serde_json::from_str(include_str!(
            "../../../fixtures/router-eval.local-needs.json"
        ))
        .expect("router eval fixture");
        for case in eval.cases {
            let intent = classify_intent(&case.text, &case.text);
            assert_eq!(intent, case.expected_intent, "case {}", case.id);
            let owner = match intent.as_str() {
                "repo_lookup" => "knowledge",
                "task_enqueue" => "planner",
                _ => "",
            };
            assert_eq!(owner, case.expected_owner_slot_id, "owner case {}", case.id);
        }
    }

    #[test]
    fn fsrealtask_routes_into_workbench_task_board() {
        let root = std::env::temp_dir().join(format!(
            "harvis-router-fsrealtask-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let routed = route_message(RouteMessageOptions {
            root: root.clone(),
            transport: "feishu".to_string(),
            sender: "unit".to_string(),
            text: "FSREALTASK202606280112 justddl readonly".to_string(),
            chat_id: Some("chat-test".to_string()),
            message_id: Some("msg-fsrealtask".to_string()),
            context: Vec::new(),
            include_paths: false,
            map_path: None,
            agent_pools_path: None,
        })
        .expect("route");
        assert_eq!(routed["intent"], "task_enqueue");
        assert_eq!(routed["workbench_task"]["status"], "waiting_approval");
        assert_eq!(routed["workbench_task"]["owner_slot_id"], "planner");
        assert_eq!(routed["workbench_task"]["title"], "justddl readonly");
        let _ = fs::remove_dir_all(root);
    }
}
