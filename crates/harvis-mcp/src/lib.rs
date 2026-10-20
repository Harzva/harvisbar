use anyhow::{bail, Context, Result};
use harvis_core::time::now_rfc3339;
use harvis_integrations::hub::{
    hub_path_lookup, hub_status, llmwiki_status, wiki_page, wiki_search,
};
use harvis_integrations::repoatlas::{
    repoatlas_find_repo, repoatlas_missing_local_copies, repoatlas_needs_attention,
    repoatlas_status,
};
use harvis_runtime::agent_room::{
    add_event_with_metadata, add_message, create_topic, init_agent_room, list_agent_room,
    list_handoffs, request_handoff,
};
use harvis_runtime::agent_roster::{agent_roster_status, RosterValidationOptions};
use harvis_runtime::approvals::{create_approval, decide_approval, list_approvals};
use harvis_runtime::gbrain_memory::GbrainMemoryProvider;
use harvis_runtime::inbox::{scan_inboxes, ScanOptions};
use harvis_runtime::init::init_workspace;
use harvis_runtime::knowledge_provider::{
    recall_with_project_knowledge, HarvisKnowledgeService, KnowledgeResult,
    LlmWikiKnowledgeProvider,
};
use harvis_runtime::mcp_stdio::McpStdioTransport;
use harvis_runtime::memory::{generate_snapshot, MemorySnapshotOptions};
use harvis_runtime::memory_profiles::{built_in_memory_profiles, memory_profile, MemoryProfile};
use harvis_runtime::memory_provider::{
    ContextPackInput, EntityInput, ExportInput, HarvisMemoryService, LocalSqliteMemoryProvider,
    MemoryProvenance, MemoryRecord, RecallInput, ReviewDecision, ReviewOutcome,
};
use harvis_runtime::notifications::{check_notifications, list_notifications};
use harvis_runtime::persona::{
    create_persona_card, create_personality_candidate, create_twin_instance,
    decide_personality_candidate, init_persona_registry, list_persona_state, update_persona_card,
};
use harvis_runtime::profile::{expanduser, init_profile, PROFILE_FILES};
use harvis_runtime::runs::{list_runs, sync_packet_runs};
use harvis_runtime::tick::{run_tick, TickOptions};
use harvis_runtime::workbench::{prepare_workbench, WorkbenchOptions};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// Declared MCP specification baseline (T312). Negotiation falls back to this
/// version, which is the latest this server supports.
pub const PROTOCOL_VERSION: &str = "2025-11-25";
/// Protocol versions this server can negotiate per the MCP lifecycle spec:
/// echo the requested version when supported, otherwise answer with
/// `PROTOCOL_VERSION` (the latest supported).
pub const SUPPORTED_PROTOCOL_VERSIONS: &[&str] =
    &["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];
pub const SERVER_NAME: &str = "harvis";
pub const SERVER_VERSION: &str = "0.38.0-rust-alpha";

const TOOL_NAMES: &[&str] = &[
    "harvis_init_profile",
    "harvis_init_workspace",
    "harvis_scan_inbox",
    "harvis_run_tick",
    "harvis_get_status",
    "harvis_permission_probe",
    "harvis_list_packets",
    "harvis_list_profile",
    "harvis_memory_snapshot",
    "harvis_prepare_workbench",
    "harvis_list_runs",
    "harvis_sync_runs",
    "harvis_list_approvals",
    "harvis_request_approval",
    "harvis_decide_approval",
    "harvis_check_notifications",
    "harvis_list_notifications",
    "harvis_hub_status",
    "harvis_hub_path_lookup",
    "harvis_hub_search",
    "harvis_hub_wiki_page",
    "harvis_llmwiki_status",
    "harvis_repoatlas_status",
    "harvis_repoatlas_find_repo",
    "harvis_repoatlas_missing_local_copies",
    "harvis_repoatlas_needs_attention",
    "harvis_agent_room_init",
    "harvis_agent_room_list",
    "harvis_agent_room_topic",
    "harvis_agent_room_message",
    "harvis_agent_room_live",
    "harvis_agent_room_send",
    "harvis_agent_room_autochat",
    "harvis_agent_roster",
    "harvis_request_handoff",
    "harvis_list_handoffs",
    "harvis_persona_init",
    "harvis_persona_list",
    "harvis_persona_create_card",
    "harvis_persona_update_card",
    "harvis_copyme_create",
    "harvis_personality_candidate_create",
    "harvis_personality_candidate_decide",
    "harvis_memory_recall",
    "harvis_memory_context",
    "harvis_memory_entity",
    "harvis_memory_propose",
    "harvis_memory_status",
    "harvis_memory_candidates",
    "harvis_memory_review",
    "harvis_memory_export",
    "harvis_memory_migrate",
    "harvis_memory_rollback",
];

pub fn mcp_label() -> &'static str {
    "harvis-mcp"
}

pub fn serve_stdio() -> Result<()> {
    eprintln!("[harvis-mcp] starting {SERVER_NAME} MCP server {SERVER_VERSION}");
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        let raw = line.trim();
        if raw.is_empty() {
            continue;
        }
        let response = match handle_raw_request(raw) {
            Ok(response) => response,
            Err(response) => response,
        };
        if let Some(response) = response {
            writeln!(stdout, "{}", serde_json::to_string(&response)?)?;
            stdout.flush()?;
        }
    }
    Ok(())
}

pub fn handle_raw_request(raw: &str) -> std::result::Result<Option<Value>, Option<Value>> {
    let message = match serde_json::from_str::<Value>(raw) {
        Ok(message @ Value::Object(_)) => message,
        Ok(_) => {
            return Err(Some(error_response(
                Value::Null,
                -32600,
                "request must be a JSON object",
            )))
        }
        Err(error) => {
            return Err(Some(error_response(
                Value::Null,
                -32700,
                &format!("parse error: {error}"),
            )))
        }
    };
    // MCP 2025-11-25 base protocol: notifications carry no `id` member and the
    // receiver MUST NOT send a response; request ids MUST be a string or
    // integer and (unlike base JSON-RPC) MUST NOT be null.
    let has_id = message
        .as_object()
        .map(|object| object.contains_key("id"))
        .unwrap_or(false);
    if !has_id {
        return Ok(None);
    }
    let message_id = message.get("id").cloned().unwrap_or(Value::Null);
    if !message_id.is_string() && !message_id.is_i64() && !message_id.is_u64() {
        return Err(Some(error_response(
            Value::Null,
            -32600,
            "request id must be a string or integer and must not be null",
        )));
    }
    if message.get("jsonrpc") != Some(&json!("2.0")) {
        return Err(Some(error_response(
            message_id,
            -32600,
            "jsonrpc must be \"2.0\"",
        )));
    }
    match handle_request(&message) {
        Ok(response) => Ok(response),
        Err(error) => Err(Some(error_response(message_id, error.code, &error.message))),
    }
}

fn handle_request(message: &Value) -> std::result::Result<Option<Value>, RpcError> {
    let message_id = message.get("id").cloned().unwrap_or(Value::Null);
    let Some(method) = message.get("method").and_then(Value::as_str) else {
        return Err(RpcError::new(-32600, "method must be a string"));
    };
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    match method {
        "initialize" => Ok(Some(json!({
            "jsonrpc": "2.0",
            "id": message_id,
            "result": initialize(&params)
        }))),
        "notifications/initialized" => Ok(None),
        "ping" => Ok(Some(
            json!({"jsonrpc": "2.0", "id": message_id, "result": {}}),
        )),
        "tools/list" => Ok(Some(json!({
            "jsonrpc": "2.0",
            "id": message_id,
            "result": {"tools": tools()}
        }))),
        "tools/call" => {
            let params = require_object(&params)?;
            let name = params
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::new(-32602, "tool name must be a string"))?;
            if !TOOL_NAMES.contains(&name) {
                return Err(RpcError::new(-32602, format!("unknown tool: {name}")));
            }
            let arguments = params
                .get("arguments")
                .map(require_object)
                .transpose()?
                .unwrap_or_else(serde_json::Map::new);
            // MCP 2025-11-25 server/tools error handling: protocol errors
            // (unknown tool, malformed request) stay JSON-RPC errors; tool
            // execution failures (input validation, business logic, internal
            // errors) are reported in the result envelope with isError: true.
            let result = match call_tool(name, &Value::Object(arguments)) {
                Ok(result) => result,
                Err(error) => tool_error_result(&error.message),
            };
            Ok(Some(json!({
                "jsonrpc": "2.0",
                "id": message_id,
                "result": result
            })))
        }
        _ => Err(RpcError::new(-32601, format!("method not found: {method}"))),
    }
}

fn initialize(params: &Value) -> Value {
    let requested = params
        .get("protocolVersion")
        .and_then(Value::as_str)
        .unwrap_or(PROTOCOL_VERSION);
    // Version negotiation (MCP 2025-11-25 lifecycle): if the requested version
    // is supported respond with the same version, otherwise respond with the
    // latest version this server supports.
    let protocol_version = if SUPPORTED_PROTOCOL_VERSIONS.contains(&requested) {
        requested
    } else {
        PROTOCOL_VERSION
    };
    json!({
        "protocolVersion": protocol_version,
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        "instructions": "Use H.A.R.V.I.S. tools for local file inbox, read-only runtime ticks, memory snapshots, status, packets, runs, approvals, notification policy, Agent Room, persona registry, and repository routing. Rust-native tools never execute work packets automatically."
    })
}

fn tools() -> Vec<Value> {
    TOOL_NAMES
        .iter()
        .map(|name| {
            json!({
                "name": name,
                "description": tool_description(name),
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": true
                }
            })
        })
        .collect()
}

fn tool_description(name: &str) -> &'static str {
    match name {
        "harvis_init_profile" => "Create or verify the standalone H.A.R.V.I.S. runtime profile.",
        "harvis_init_workspace" => "Create or verify .harvis workspace directories and templates.",
        "harvis_scan_inbox" => {
            "Scan @harvis inbox tasks and generate work packets without executing them."
        }
        "harvis_run_tick" => "Run one Level 1 read-only runtime tick.",
        "harvis_get_status" => "Read workspace runtime status.",
        "harvis_permission_probe" => "Probe workspace/profile write access for the MCP process.",
        "harvis_list_packets" => "List work packets under .harvis/outbox.",
        "harvis_list_profile" => "List profile files and missing required entries.",
        "harvis_memory_snapshot" => "Generate a private memory snapshot and candidate signals.",
        "harvis_prepare_workbench" => {
            "Prepare multi-agent workbench briefs under .harvis/workbench."
        }
        "harvis_list_runs" => "List stable run ledger records.",
        "harvis_sync_runs" => "Synchronize outbox packets into run ledger records.",
        "harvis_list_approvals" => "List approval items.",
        "harvis_request_approval" => "Create a record-only approval item.",
        "harvis_decide_approval" => "Record a human approval decision.",
        "harvis_check_notifications" => "Create allowlisted notification candidates.",
        "harvis_list_notifications" => "List notification candidates.",
        "harvis_hub_status"
        | "harvis_hub_path_lookup"
        | "harvis_hub_search"
        | "harvis_hub_wiki_page"
        | "harvis_llmwiki_status" => "Redacted HarzvaHub/LLMWiki local knowledge adapter.",
        "harvis_repoatlas_status"
        | "harvis_repoatlas_find_repo"
        | "harvis_repoatlas_missing_local_copies"
        | "harvis_repoatlas_needs_attention" => "Redacted RepoAtlas compact-map adapter.",
        "harvis_agent_room_init" => "Create or verify Agent Room JSONL stores.",
        "harvis_agent_room_list" => "List Agent Room topics, events, messages, and handoffs.",
        "harvis_agent_room_topic" => "Create an Agent Room topic.",
        "harvis_agent_room_message" => "Record an Agent Room message.",
        "harvis_agent_room_live" => "Read Agent Room state for MCP roundtable clients.",
        "harvis_agent_room_send" => {
            "Record an MCP-originated Agent Room message and host route event without executing models."
        }
        "harvis_agent_room_autochat" => {
            "Record an MCP-originated autochat seed and host planning event without executing models."
        }
        "harvis_agent_roster" => "Read and validate the canonical H.A.R.V.I.S. agent roster.",
        "harvis_request_handoff" => "Create a record-only harness handoff.",
        "harvis_list_handoffs" => "List harness handoff records.",
        "harvis_persona_init" => "Create or verify persona registry stores.",
        "harvis_persona_list" => "List persona registry records.",
        "harvis_persona_create_card" => "Create a persona card.",
        "harvis_persona_update_card" => "Append an updated persona card.",
        "harvis_copyme_create" => "Create a Copy-Me twin instance.",
        "harvis_personality_candidate_create" => "Create a personality candidate for review.",
        "harvis_personality_candidate_decide" => "Record a personality candidate decision.",
        "harvis_memory_recall" => "Recall only approved, committed HARVIS memory within explicit scope and budget.",
        "harvis_memory_context" => "Build an injection-safe, budgeted context from approved HARVIS memory.",
        "harvis_memory_entity" => "Look up an optional provider entity card without granting provider write access.",
        "harvis_memory_propose" => "Create a review-required memory candidate; this never writes a Provider.",
        "harvis_memory_status" => "Read the active HARVIS memory Provider capability and health JSON.",
        "harvis_memory_candidates" => "List HARVIS canonical memory candidates for the review control plane.",
        "harvis_memory_review" => "Record a human memory review and commit only an accepted candidate.",
        "harvis_memory_export" => "Export a hash-verified portable bundle from canonical committed memory.",
        "harvis_memory_migrate" => "Dry-run or explicitly confirm a Provider migration with count/hash/sample reconciliation.",
        "harvis_memory_rollback" => "Explicitly roll back a completed Provider migration without deleting target data.",
        _ => "H.A.R.V.I.S. MCP tool.",
    }
}

fn call_tool(name: &str, args: &Value) -> std::result::Result<Value, RpcError> {
    let data = match name {
        "harvis_init_profile" => {
            let profile_root = optional_path(args, "profile_root", "~/.harvis");
            let messages = init_profile(&profile_root, optional_bool(args, "force", false)?)?;
            json!({"profile_root": normalize(&profile_root), "messages": messages})
        }
        "harvis_init_workspace" => {
            let root = root(args)?;
            let messages = init_workspace(&root, optional_bool(args, "force", false)?)?;
            json!({"workspace_root": root.display().to_string(), "messages": messages})
        }
        "harvis_scan_inbox" => {
            let root = root(args)?;
            let inboxes = inboxes(args, &root)?;
            let packets = scan_inboxes(ScanOptions {
                root: root.clone(),
                inboxes: inboxes.clone(),
                allow_outside_root: false,
            })?;
            let runs = if packets.is_empty() {
                json!({"run_count": 0, "runs": []})
            } else {
                serde_json::to_value(sync_packet_runs(&root, Some(packets.clone()), 500)?)?
            };
            json!({
                "workspace_root": root.display().to_string(),
                "inboxes": inboxes.iter().map(|path| path.display().to_string()).collect::<Vec<_>>(),
                "packets_written": packets.iter().map(|path| path.display().to_string()).collect::<Vec<_>>(),
                "runs_written": runs.get("runs").cloned().unwrap_or_else(|| json!([]))
            })
        }
        "harvis_run_tick" => {
            let root = root(args)?;
            let profile_root = optional_path(args, "profile_root", "~/.harvis");
            let interval = optional_int(args, "interval", 1200, 1, 86400)? as u64;
            let (status, side_effects) = run_tick(TickOptions {
                root: root.clone(),
                interval_override: Some(interval),
                profile_root,
            })?;
            json!({
                "workspace_root": root.display().to_string(),
                "status": status,
                "captured_output": [
                    format!("wrote status: {}", side_effects.status_path.display()),
                    format!("wrote report: {}", side_effects.report_path.display())
                ]
            })
        }
        "harvis_get_status" => {
            let root = root(args)?;
            let path = root.join(".harvis/status.json");
            if !path.exists() {
                return Err(RpcError::new(
                    -32602,
                    format!("status file not found for workspace: {}", root.display()),
                ));
            }
            json!({
                "workspace_root": root.display().to_string(),
                "status_path": path.display().to_string(),
                "state_store": "workspace",
                "status": read_json(&path)?
            })
        }
        "harvis_permission_probe" => permission_probe(args)?,
        "harvis_list_packets" => list_packets_tool(args)?,
        "harvis_list_profile" => list_profile_tool(args)?,
        "harvis_memory_snapshot" => {
            let root = root(args)?;
            let result = generate_snapshot(MemorySnapshotOptions {
                root,
                profile_root: optional_path(args, "profile_root", "~/.harvis"),
                max_events: optional_int(args, "max_events", 50, 0, 500)?,
                max_packets: optional_int(args, "max_packets", 50, 0, 500)?,
                max_reports: optional_int(args, "max_reports", 10, 0, 100)?,
                max_excerpt_chars: optional_int(args, "max_excerpt_chars", 1200, 0, 8000)?,
            })?;
            serde_json::to_value(result)?
        }
        "harvis_memory_recall" => memory_recall_tool(args)?,
        "harvis_memory_context" => memory_context_tool(args)?,
        "harvis_memory_entity" => memory_entity_tool(args)?,
        "harvis_memory_propose" => memory_propose_tool(args)?,
        "harvis_memory_status" => memory_status_tool(args)?,
        "harvis_memory_candidates" => memory_candidates_tool(args)?,
        "harvis_memory_review" => memory_review_tool(args)?,
        "harvis_memory_export" => memory_export_tool(args)?,
        "harvis_memory_migrate" => memory_migrate_tool(args)?,
        "harvis_memory_rollback" => memory_rollback_tool(args)?,
        "harvis_prepare_workbench" => {
            let root = root(args)?;
            prepare_workbench(WorkbenchOptions {
                root,
                profile_root: optional_path(args, "profile_root", "~/.harvis"),
                packet: optional_string(args, "packet"),
                limit: optional_int(args, "limit", 5, 1, 100)?,
            })?
        }
        "harvis_hub_status" => hub_status(),
        "harvis_hub_path_lookup" => hub_path_lookup(
            &require_str(args, "query", None)?,
            optional_int(args, "limit", 10, 1, 50)?,
        )?,
        "harvis_hub_search" => wiki_search(
            &require_str(args, "query", None)?,
            optional_int(args, "limit", 10, 1, 50)?,
            optional_int(args, "max_excerpt_chars", 360, 80, 2000)?,
        )?,
        "harvis_hub_wiki_page" => wiki_page(
            &require_str(args, "page", None)?,
            optional_int(args, "max_chars", 3000, 200, 8000)?,
        )?,
        "harvis_llmwiki_status" => llmwiki_status(),
        "harvis_repoatlas_status" => repoatlas_status(
            optional_string(args, "map_path").as_deref(),
            optional_bool(args, "include_paths", false)?,
        ),
        "harvis_repoatlas_find_repo" => repoatlas_find_repo(
            &require_str(args, "query", None)?,
            optional_int(args, "limit", 10, 1, 50)?,
            optional_string(args, "map_path").as_deref(),
            optional_bool(args, "include_paths", false)?,
        )?,
        "harvis_repoatlas_missing_local_copies" => repoatlas_missing_local_copies(
            optional_int(args, "limit", 50, 1, 200)?,
            optional_string(args, "map_path").as_deref(),
        ),
        "harvis_repoatlas_needs_attention" => repoatlas_needs_attention(
            optional_int(args, "limit", 50, 1, 200)?,
            optional_string(args, "map_path").as_deref(),
            optional_bool(args, "include_paths", false)?,
        ),
        "harvis_list_runs" => {
            let root = root(args)?;
            serde_json::to_value(list_runs(&root, optional_int(args, "limit", 50, 1, 500)?)?)?
        }
        "harvis_sync_runs" => {
            let root = root(args)?;
            serde_json::to_value(sync_packet_runs(
                &root,
                None,
                optional_int(args, "limit", 500, 1, 5000)?,
            )?)?
        }
        "harvis_list_approvals" => {
            let root = root(args)?;
            list_approvals(
                &root,
                optional_string(args, "status").as_deref(),
                optional_int(args, "limit", 50, 1, 500)?,
            )?
        }
        "harvis_request_approval" => {
            let root = root(args)?;
            create_approval(
                &root,
                &require_str(args, "run_id", None)?,
                &require_str(args, "action_type", None)?,
                &require_str(args, "target", None)?,
                &require_str(args, "reason", None)?,
                &require_str(args, "risk", Some("medium"))?,
                &require_str(args, "scope", Some("one_time"))?,
            )?
        }
        "harvis_decide_approval" => {
            let root = root(args)?;
            decide_approval(
                &root,
                &require_str(args, "approval_id", None)?,
                &require_str(args, "decision", None)?,
                &require_str(args, "decided_by", Some("human"))?,
                optional_string(args, "notes").as_deref().unwrap_or(""),
            )?
        }
        "harvis_check_notifications" => {
            let root = root(args)?;
            check_notifications(&root, optional_bool(args, "write", true)?)?
        }
        "harvis_list_notifications" => {
            let root = root(args)?;
            list_notifications(
                &root,
                optional_string(args, "kind").as_deref(),
                optional_int(args, "limit", 50, 1, 500)?,
            )?
        }
        "harvis_agent_room_init" => {
            let root = root(args)?;
            init_agent_room(&root)?
        }
        "harvis_agent_room_list" => {
            let root = root(args)?;
            list_agent_room(&root, optional_int(args, "limit", 50, 1, 500)?)?
        }
        "harvis_agent_room_topic" => {
            let root = root(args)?;
            create_topic(
                &root,
                &require_str(args, "title", None)?,
                optional_string(args, "goal").as_deref().unwrap_or(""),
                "mcp",
            )?
        }
        "harvis_agent_room_message" => {
            let root = root(args)?;
            add_message(
                &root,
                &require_str(args, "topic_id", None)?,
                &require_str(args, "agent_id", Some("harvis"))?,
                &require_str(args, "role", Some("coordinator"))?,
                &require_str(args, "content", None)?,
                Vec::new(),
                "internal",
                None,
            )?
        }
        "harvis_agent_room_live" => {
            let root = root(args)?;
            json!({
                "room": list_agent_room(&root, optional_int(args, "limit", 50, 1, 500)?)?,
                "roundtable": {
                    "mcp": "record-only",
                    "send": "harvis_agent_room_send",
                    "autochat": "harvis_agent_room_autochat",
                    "live": "harvis_agent_room_live",
                    "writes": ".harvis/agent-room/events.jsonl"
                }
            })
        }
        "harvis_agent_room_send" => {
            let root = root(args)?;
            let prompt = require_str(args, "prompt", None)?;
            let topic_id = match optional_string(args, "topic_id")
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
            {
                Some(topic_id) => topic_id,
                None => create_topic(&root, "MCP Agent Room message", &prompt, "mcp")?
                    .get("topic_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
            };
            let message = add_message(
                &root,
                &topic_id,
                &require_str(args, "agent_id", Some("mcp_client"))?,
                &require_str(args, "role", Some("external_agent"))?,
                &prompt,
                Vec::new(),
                "internal",
                None,
            )?;
            let route = add_event_with_metadata(
                &root,
                &topic_id,
                "harvis",
                "host",
                "status_change",
                "MCP message recorded; model execution requires HTTP provider call or explicit handoff.",
                Vec::new(),
                "internal",
                None,
                json!({
                    "policy": "harvis.host.v0.50",
                    "transport": "mcp",
                    "requires_handoff_for_mutation": true
                }),
            )?;
            json!({
                "topic_id": topic_id,
                "message": message,
                "route_event": route,
                "status": "recorded"
            })
        }
        "harvis_agent_room_autochat" => {
            let root = root(args)?;
            let seed = require_str(args, "seed", None)?;
            let topic_id = match optional_string(args, "topic_id")
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
            {
                Some(topic_id) => topic_id,
                None => create_topic(&root, "MCP Agent Room autochat seed", &seed, "mcp")?
                    .get("topic_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
            };
            let seed_message = add_message(
                &root,
                &topic_id,
                "harvis",
                "host",
                &seed,
                Vec::new(),
                "internal",
                None,
            )?;
            let decision = add_event_with_metadata(
                &root,
                &topic_id,
                "harvis",
                "host",
                "decision_record",
                "MCP autochat seed recorded for H.A.R.V.I.S. Agent Room; live model turns are not executed inside MCP.",
                Vec::new(),
                "internal",
                None,
                json!({
                    "policy": "harvis.host.v0.50",
                    "transport": "mcp",
                    "mcp_is_tool_interface": true,
                    "a2a_is_agent_interface": true,
                    "requires_handoff_for_mutation": true
                }),
            )?;
            json!({
                "topic_id": topic_id,
                "seed_message": seed_message,
                "decision_record": decision,
                "status": "recorded"
            })
        }
        "harvis_agent_roster" => {
            let root = root(args)?;
            let roster_path = optional_string(args, "roster_path")
                .or_else(|| optional_string(args, "roster"))
                .map(PathBuf::from)
                .map(|path| expanduser(&path));
            let provider_registry = optional_string(args, "provider_registry")
                .map(PathBuf::from)
                .map(|path| expanduser(&path));
            let agent_pools = optional_string(args, "agent_pools")
                .map(PathBuf::from)
                .map(|path| expanduser(&path));
            let lark_config = optional_string(args, "lark_config")
                .map(PathBuf::from)
                .map(|path| expanduser(&path));
            agent_roster_status(
                &root,
                roster_path.as_deref(),
                RosterValidationOptions {
                    provider_registry,
                    agent_pools,
                    root: Some(root.clone()),
                    lark_config,
                },
            )?
        }
        "harvis_request_handoff" => {
            let root = root(args)?;
            request_handoff(
                &root,
                &require_str(args, "run_id", None)?,
                &require_str(args, "harness", Some("codex"))?,
                optional_string(args, "instruction")
                    .as_deref()
                    .unwrap_or(""),
                optional_string(args, "topic_id").as_deref(),
                "mcp",
            )?
        }
        "harvis_list_handoffs" => {
            let root = root(args)?;
            list_handoffs(&root, optional_int(args, "limit", 50, 1, 500)?)?
        }
        "harvis_persona_init" => {
            let root = root(args)?;
            init_persona_registry(&root)?
        }
        "harvis_persona_list" => {
            let root = root(args)?;
            list_persona_state(&root, optional_int(args, "limit", 100, 1, 500)?)?
        }
        "harvis_persona_create_card" => {
            let root = root(args)?;
            create_persona_card(
                &root,
                &require_str(args, "display_name", None)?,
                optional_string(args, "persona_id").as_deref(),
                optional_string(args, "visual_asset_id")
                    .as_deref()
                    .unwrap_or(""),
            )?
        }
        "harvis_persona_update_card" => {
            let root = root(args)?;
            let tone = json!({
                "warmth": optional_int(args, "warmth", 7, 0, 10)?,
                "directness": optional_int(args, "directness", 7, 0, 10)?,
                "humor": optional_int(args, "humor", 3, 0, 10)?,
                "detail": optional_int(args, "detail", 8, 0, 10)?,
            });
            update_persona_card(
                &root,
                &require_str(args, "persona_id", None)?,
                optional_string(args, "display_name").as_deref(),
                optional_string(args, "visual_asset_id").as_deref(),
                None,
                None,
                Some(&tone),
                None,
                None,
            )?
        }
        "harvis_copyme_create" => {
            let root = root(args)?;
            create_twin_instance(
                &root,
                &require_str(args, "display_name", None)?,
                &require_str(args, "memory_vault_id", None)?,
                &require_str(args, "persona_card_id", None)?,
                optional_string(args, "instance_id").as_deref(),
                None,
                None,
            )?
        }
        "harvis_personality_candidate_create" => {
            let root = root(args)?;
            create_personality_candidate(
                &root,
                &require_str(args, "trait", None)?,
                &require_str(args, "target_persona_id", None)?,
                &require_str(args, "source_type", Some("manual"))?,
                Vec::new(),
                &require_str(args, "trait_type", Some("decision_style"))?,
                optional_int(args, "confidence_percent", 50, 0, 100)? as f64 / 100.0,
            )?
        }
        "harvis_personality_candidate_decide" => {
            let root = root(args)?;
            decide_personality_candidate(
                &root,
                &require_str(args, "candidate_id", None)?,
                &require_str(args, "decision", None)?,
                &require_str(args, "decided_by", Some("human"))?,
                optional_string(args, "notes").as_deref().unwrap_or(""),
                optional_string(args, "edited_trait")
                    .as_deref()
                    .unwrap_or(""),
            )?
        }
        _ => return Err(RpcError::new(-32602, format!("unknown tool: {name}"))),
    };
    Ok(tool_result(name, data, Vec::new()))
}

struct MemoryHost {
    profile_id: String,
    provider_id: String,
    service: HarvisMemoryService,
    knowledge: Option<HarvisKnowledgeService>,
    knowledge_error: Option<String>,
}

static MEMORY_HOSTS: OnceLock<Mutex<BTreeMap<PathBuf, MemoryHost>>> = OnceLock::new();
static NEXT_MEMORY_ID: AtomicU64 = AtomicU64::new(1);

fn with_memory_service<T>(
    args: &Value,
    operation: impl FnOnce(&mut HarvisMemoryService) -> Result<T>,
) -> std::result::Result<T, RpcError> {
    with_memory_host(args, |host, _, _| operation(&mut host.service))
}

fn with_memory_host<T>(
    args: &Value,
    operation: impl FnOnce(&mut MemoryHost, &MemoryProfile, &Path) -> Result<T>,
) -> std::result::Result<T, RpcError> {
    let root = root(args)?;
    let profile = requested_memory_profile(args)?;
    let provider_id = profile.primary.clone();
    let hosts = MEMORY_HOSTS.get_or_init(|| Mutex::new(BTreeMap::new()));
    let mut hosts = hosts
        .lock()
        .map_err(|_| RpcError::new(-32603, "memory host registry lock poisoned"))?;
    if let Some(host) = hosts.get(&root) {
        if host.profile_id != profile.id || host.provider_id != provider_id {
            return Err(RpcError::new(
                -32602,
                "memory Profile changes require an explicit HARVIS MCP restart",
            ));
        }
        let host = hosts.get_mut(&root).expect("existing memory host");
        return operation(host, &profile, &state_root_for(&root)).map_err(Into::into);
    }
    let state_root = root.join(".harvis");
    let mut service = HarvisMemoryService::new(&state_root, &provider_id)?;
    register_memory_provider(&mut service, &state_root, &provider_id)?;
    if let Some(fallback) = profile.fallback.as_deref().filter(|id| *id != provider_id) {
        register_memory_provider(&mut service, &state_root, fallback)?;
    }
    for (kind, route) in &profile.routing {
        service.route_kind(kind, route)?;
    }
    let (knowledge, knowledge_error) = start_knowledge_service(&profile, &root);
    hosts.insert(
        root.clone(),
        MemoryHost {
            profile_id: profile.id.clone(),
            provider_id,
            service,
            knowledge,
            knowledge_error,
        },
    );
    operation(
        hosts.get_mut(&root).expect("inserted memory host"),
        &profile,
        &state_root,
    )
    .map_err(Into::into)
}

fn start_knowledge_service(
    profile: &MemoryProfile,
    root: &Path,
) -> (Option<HarvisKnowledgeService>, Option<String>) {
    if profile.knowledge.as_deref() != Some("llmwiki") {
        return (None, None);
    }
    let command =
        std::env::var("HARVIS_LLMWIKI_COMMAND").unwrap_or_else(|_| "llmwiki-mcp".to_string());
    let wiki_root = std::env::var_os("HARVIS_LLMWIKI_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join(".wiki"));
    match McpStdioTransport::spawn(
        &command,
        &[wiki_root.display().to_string()],
        &BTreeMap::new(),
    ) {
        Ok(transport) => {
            let provider = Arc::new(LlmWikiKnowledgeProvider::new(
                "llmwiki",
                Arc::new(transport),
            ));
            (Some(HarvisKnowledgeService::new(provider)), None)
        }
        Err(error) => (None, Some(error.to_string())),
    }
}

fn state_root_for(root: &Path) -> PathBuf {
    root.join(".harvis")
}

fn requested_memory_profile(args: &Value) -> std::result::Result<MemoryProfile, RpcError> {
    let explicit_profile =
        optional_string(args, "profile").or_else(|| std::env::var("HARVIS_MEMORY_PROFILE").ok());
    let legacy_provider =
        optional_string(args, "provider").or_else(|| std::env::var("HARVIS_MEMORY_PROVIDER").ok());
    let profile_id = match (explicit_profile, legacy_provider.as_deref()) {
        (Some(profile), _) => profile,
        (None, Some("gbrain")) => "local-fast".to_string(),
        (None, Some("local-sqlite") | None) => "minimal".to_string(),
        (None, Some(provider)) => {
            return Err(RpcError::new(
                -32602,
                format!("unknown legacy HARVIS memory Provider: {provider}"),
            ))
        }
    };
    let profile = memory_profile(&profile_id)?;
    profile.validate_runtime_enabled()?;
    if let Some(required) = profile.required_confirmation() {
        let actual = optional_string(args, "profile_confirmation")
            .or_else(|| std::env::var("HARVIS_MEMORY_PROFILE_CONFIRMATION").ok());
        if actual.as_deref() != Some(required.as_str()) {
            return Err(RpcError::new(
                -32602,
                format!("production memory Profile requires confirmation: {required}"),
            ));
        }
    }
    Ok(profile)
}

fn register_memory_provider(
    service: &mut HarvisMemoryService,
    state_root: &Path,
    provider_id: &str,
) -> std::result::Result<(), RpcError> {
    match provider_id {
        "local-sqlite" => service.register_provider(Arc::new(LocalSqliteMemoryProvider::new(
            state_root.join("memory-v1/providers/local-sqlite.sqlite3"),
            provider_id,
        )?))?,
        "gbrain" => {
            let command =
                std::env::var("HARVIS_GBRAIN_COMMAND").unwrap_or_else(|_| "gbrain".to_string());
            let transport = Arc::new(McpStdioTransport::spawn(
                &command,
                &[
                    "serve".to_string(),
                    "--surface".to_string(),
                    "verbs".to_string(),
                ],
                &BTreeMap::new(),
            )?);
            service.register_provider(Arc::new(GbrainMemoryProvider::new(
                provider_id,
                transport,
                state_root.join("memory-v1/providers/gbrain-reconciliation.sqlite3"),
            )?))?;
        }
        _ => {
            return Err(RpcError::new(
                -32602,
                format!("HARVIS memory Provider is not runtime-enabled: {provider_id}"),
            ))
        }
    }
    Ok(())
}

fn memory_recall_input(args: &Value) -> std::result::Result<RecallInput, RpcError> {
    Ok(RecallInput {
        query: optional_string(args, "query").unwrap_or_default(),
        project_id: optional_string(args, "project_id"),
        user_id: optional_string(args, "user_id"),
        session_id: optional_string(args, "session_id"),
        agent_id: optional_string(args, "agent_id"),
        shared_subjects: optional_string_array(args, "shared_subjects")?,
        allowed_sensitivities: match optional_string_array(args, "allowed_sensitivities")? {
            values if values.is_empty() => vec![
                "private".to_string(),
                "shared".to_string(),
                "public_safe".to_string(),
            ],
            values => values,
        },
        kinds: optional_string_array(args, "kinds")?,
        token_budget: optional_int(args, "token_budget", 1000, 1, 32000)?,
        limit: optional_int(args, "limit", 12, 1, 100)?,
    })
}

fn memory_recall_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let input = memory_recall_input(args)?;
    let include_knowledge = optional_bool(args, "include_project_knowledge", false)?;
    with_memory_host(args, |host, profile, _| {
        if !include_knowledge {
            return serde_json::to_value(host.service.recall(&input)?).map_err(Into::into);
        }
        let unified = if let Some(knowledge) = host.knowledge.as_ref() {
            recall_with_project_knowledge(&host.service, knowledge, &input)?
        } else {
            let memory = host.service.recall(&input)?;
            let knowledge = KnowledgeResult {
                provider_id: profile
                    .knowledge
                    .clone()
                    .unwrap_or_else(|| "none".to_string()),
                project_id: input.project_id.clone().unwrap_or_default(),
                hits: Vec::new(),
                token_used: 0,
                degraded: profile.knowledge.is_some(),
                warnings: host
                    .knowledge_error
                    .as_ref()
                    .map(|error| vec![format!("knowledge provider unavailable: {error}")])
                    .unwrap_or_default(),
            };
            harvis_runtime::knowledge_provider::UnifiedRecallResult {
                token_used: memory.token_used,
                memory,
                knowledge,
            }
        };
        Ok(json!({
            "provider_id": unified.memory.provider_id,
            "hits": unified.memory.hits,
            "token_used": unified.token_used,
            "degraded": unified.memory.degraded || unified.knowledge.degraded,
            "warnings": unified.memory.warnings.iter()
                .chain(unified.knowledge.warnings.iter()).cloned().collect::<Vec<_>>(),
            "memory": unified.memory,
            "knowledge": unified.knowledge,
            "lanes": ["reviewed_memory", "project_knowledge"]
        }))
    })
}

fn memory_context_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let input = ContextPackInput {
        recall: memory_recall_input(args)?,
    };
    with_memory_service(args, |service| service.context_pack(&input))
        .and_then(|result| serde_json::to_value(result).map_err(Into::into))
}

fn memory_entity_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let input = EntityInput {
        name: require_str(args, "name", None)?,
    };
    with_memory_service(args, |service| service.entity(&input))
        .and_then(|result| serde_json::to_value(result).map_err(Into::into))
}

fn memory_propose_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let provenance_value = args
        .get("provenance")
        .cloned()
        .ok_or_else(|| RpcError::new(-32602, "provenance is required"))?;
    let provenance: Vec<MemoryProvenance> = serde_json::from_value(provenance_value)
        .map_err(|error| RpcError::new(-32602, format!("invalid provenance: {error}")))?;
    let summary = require_str(args, "summary", None)?;
    let subject = require_str(args, "subject", None)?;
    let proposed_at = now_rfc3339().map_err(|error| RpcError::new(-32603, error.to_string()))?;
    let id_seed = format!(
        "{}-{}-{}-{}",
        subject,
        summary,
        proposed_at,
        NEXT_MEMORY_ID.fetch_add(1, Ordering::Relaxed)
    );
    let memory = MemoryRecord {
        memory_id: format!("mem_{}", compact_identifier(&id_seed)),
        schema_version: 1,
        kind: require_str(args, "kind", Some("fact"))?,
        scope: require_str(args, "scope", Some("project"))?,
        subject,
        summary,
        provenance,
        sensitivity: require_str(args, "sensitivity", Some("private"))?,
        status: "candidate".to_string(),
        confidence: args
            .get("confidence")
            .and_then(Value::as_f64)
            .unwrap_or(0.5),
        valid_from: optional_string(args, "valid_from").unwrap_or(proposed_at),
        valid_until: optional_string(args, "valid_until"),
        provider_refs: Vec::new(),
    };
    with_memory_service(args, |service| service.propose_candidate(&memory))
        .and_then(|result| serde_json::to_value(result).map_err(Into::into))
}

fn memory_status_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let profile = requested_memory_profile(args)?;
    with_memory_host(args, |host, _, _| {
        let knowledge = match host.knowledge.as_ref() {
            Some(service) => match service.status() {
                Ok(status) => serde_json::to_value(status)?,
                Err(error) => json!({"provider_id": "llmwiki", "healthy": false,
                    "detail": error.to_string()}),
            },
            None => json!({
                "provider_id": profile.knowledge,
                "healthy": profile.knowledge.is_none(),
                "detail": host.knowledge_error
            }),
        };
        Ok(json!({
            "profile": profile,
            "provider_id": host.service.primary_provider_id(),
            "capabilities": host.service.primary_capabilities()?,
            "health": host.service.primary_health()?,
            "knowledge": knowledge,
            "governance": {
                "write_policy": "review_required",
                "candidate_store": "separate",
                "single_production_provider": true
            }
        }))
    })
}

fn memory_candidates_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let limit = optional_int(args, "limit", 50, 1, 500)?;
    with_memory_service(args, |service| service.list_candidates(limit))
        .and_then(|result| serde_json::to_value(result).map_err(Into::into))
}

fn memory_review_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let candidate_id = require_str(args, "candidate_id", None)?;
    let decision = require_str(args, "decision", None)?;
    with_memory_service(args, |service| {
        let outcome = match decision.as_str() {
            "accept" => service.review_candidate(
                &candidate_id,
                ReviewDecision::Accept {
                    approval_id: require_str(args, "approval_id", None)
                        .map_err(|error| anyhow::anyhow!(error.message))?,
                },
            )?,
            "reject" => service.review_candidate(
                &candidate_id,
                ReviewDecision::Reject {
                    reason: require_str(args, "reason", None)
                        .map_err(|error| anyhow::anyhow!(error.message))?,
                },
            )?,
            _ => bail!("memory review decision must be accept or reject"),
        };
        match outcome {
            ReviewOutcome::Accepted(state) => Ok(json!({
                "outcome": "accepted",
                "candidate_id": candidate_id,
                "commit": service.commit_approved(&state.memory.memory_id)?,
                "state": service.accepted_memory(&state.memory.memory_id)?
            })),
            ReviewOutcome::Rejected(candidate) => Ok(json!({
                "outcome": "rejected",
                "candidate": candidate
            })),
        }
    })
}

fn memory_export_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let include_inactive = optional_bool(args, "include_inactive", false)?;
    with_memory_service(args, |service| {
        service.export_primary(&ExportInput { include_inactive })
    })
    .and_then(|bundle| serde_json::to_value(bundle).map_err(Into::into))
}

fn memory_migrate_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let target_profile = memory_profile(&require_str(args, "target_profile", None)?)?;
    target_profile.validate_runtime_enabled()?;
    let dry_run = optional_bool(args, "dry_run", true)?;
    let confirmation = optional_string(args, "confirmation");
    with_memory_host(args, |host, _, state_root| {
        let registered = host
            .service
            .registered_provider_ids()
            .into_iter()
            .collect::<std::collections::BTreeSet<_>>();
        if !registered.contains(&target_profile.primary) {
            register_memory_provider(&mut host.service, state_root, &target_profile.primary)
                .map_err(|error| anyhow::anyhow!(error.message))?;
        }
        if let Some(fallback) = target_profile.fallback.as_deref() {
            if !registered.contains(fallback)
                && fallback != target_profile.primary
                && !host
                    .service
                    .registered_provider_ids()
                    .iter()
                    .any(|id| id == fallback)
            {
                register_memory_provider(&mut host.service, state_root, fallback)
                    .map_err(|error| anyhow::anyhow!(error.message))?;
            }
        }
        let bundle = host.service.export_primary(&ExportInput::default())?;
        let report = host.service.migrate_bundle(
            &bundle,
            &target_profile.primary,
            dry_run,
            confirmation.as_deref(),
        )?;
        if report.status == "switched" {
            let workspace_root = state_root.parent().unwrap_or(state_root);
            let (knowledge, knowledge_error) =
                start_knowledge_service(&target_profile, workspace_root);
            host.profile_id = target_profile.id.clone();
            host.provider_id = target_profile.primary.clone();
            host.knowledge = knowledge;
            host.knowledge_error = knowledge_error;
        }
        Ok(report)
    })
    .and_then(|report| serde_json::to_value(report).map_err(Into::into))
}

fn memory_rollback_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let migration_id = require_str(args, "migration_id", None)?;
    let confirmation = require_str(args, "confirmation", None)?;
    with_memory_host(args, |host, _, state_root| {
        let rollback = host
            .service
            .rollback_migration(&migration_id, &confirmation)?;
        let source_profile = built_in_memory_profiles()
            .into_values()
            .find(|profile| !profile.experimental && profile.primary == rollback.source_provider)
            .context("rolled-back Provider has no runtime-enabled built-in Profile")?;
        let workspace_root = state_root.parent().unwrap_or(state_root);
        let (knowledge, knowledge_error) = start_knowledge_service(&source_profile, workspace_root);
        host.profile_id = source_profile.id;
        host.provider_id = source_profile.primary;
        host.knowledge = knowledge;
        host.knowledge_error = knowledge_error;
        Ok(rollback)
    })
    .and_then(|rollback| serde_json::to_value(rollback).map_err(Into::into))
}

fn optional_string_array(args: &Value, name: &str) -> std::result::Result<Vec<String>, RpcError> {
    let Some(value) = args.get(name) else {
        return Ok(Vec::new());
    };
    let values = value
        .as_array()
        .ok_or_else(|| RpcError::new(-32602, format!("{name} must be an array of strings")))?;
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .ok_or_else(|| {
                    RpcError::new(-32602, format!("{name} must contain non-empty strings"))
                })
        })
        .collect()
}

fn compact_identifier(value: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(value.as_bytes());
    digest[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn tool_result(tool: &str, data: Value, warnings: Vec<String>) -> Value {
    let payload = json!({"ok": true, "tool": tool, "data": data, "warnings": warnings});
    json!({
        "content": [{"type": "text", "text": serde_json::to_string_pretty(&payload).unwrap_or_else(|_| "{}".to_string())}],
        "isError": false
    })
}

/// Tool execution error envelope (MCP 2025-11-25): actionable feedback for the
/// model inside the result, flagged with isError: true.
fn tool_error_result(message: &str) -> Value {
    let payload = json!({"ok": false, "error": message});
    json!({
        "content": [{"type": "text", "text": serde_json::to_string_pretty(&payload).unwrap_or_else(|_| "{}".to_string())}],
        "isError": true
    })
}

fn permission_probe(args: &Value) -> std::result::Result<Value, RpcError> {
    let root = root(args)?;
    let profile_root = optional_path(args, "profile_root", "~/.harvis");
    let mut checks = Vec::new();
    checks.push(probe_dir("workspace-root", &root));
    checks.push(probe_dir("workspace-harvis", &root.join(".harvis")));
    checks.push(probe_dir("profile-root", &profile_root));
    let ok = checks
        .iter()
        .all(|check| check.get("ok").and_then(Value::as_bool).unwrap_or(false));
    Ok(json!({
        "permission_probe_version": "v0.38-rust-mcp",
        "ok": ok,
        "context": "rust-mcp-process",
        "checks": checks,
        "redacted": true,
        "includesLocalAbsolutePaths": false
    }))
}

fn probe_dir(label: &str, path: &Path) -> Value {
    let exists = path.exists();
    let writable = fs::create_dir_all(path)
        .and_then(|_| {
            let probe = path.join(".harvis-permission-probe.tmp");
            fs::write(&probe, "ok\n")?;
            fs::remove_file(probe)
        })
        .is_ok();
    json!({"label": label, "exists": exists || path.exists(), "ok": writable, "writable": writable})
}

fn list_packets_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let root = root(args)?;
    let outbox = root.join(".harvis/outbox");
    if !outbox.exists() {
        return Err(RpcError::new(
            -32602,
            format!("outbox not found: {}", outbox.display()),
        ));
    }
    let include_preview = optional_bool(args, "include_preview", false)?;
    let max_preview_chars = optional_int(args, "max_preview_chars", 800, 0, 4000)?;
    let mut paths = Vec::new();
    for entry in fs::read_dir(&outbox)? {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) == Some("md") && path.is_file() {
            paths.push(path);
        }
    }
    paths.sort_by(|left, right| modified_secs(right).cmp(&modified_secs(left)));
    paths.truncate(optional_int(args, "limit", 50, 1, 200)?);
    let mut packets = Vec::new();
    for path in paths {
        let mut item = json!({
            "path": path.display().to_string(),
            "status": parse_packet_status(&path),
            "bytes": path.metadata().map(|metadata| metadata.len()).unwrap_or(0),
            "modified_at": modified_secs(&path)
        });
        if include_preview {
            item["preview"] = json!(fs::read_to_string(&path)
                .unwrap_or_default()
                .chars()
                .take(max_preview_chars)
                .collect::<String>());
        }
        packets.push(item);
    }
    Ok(
        json!({"workspace_root": root.display().to_string(), "outbox": outbox.display().to_string(), "packets": packets}),
    )
}

fn list_profile_tool(args: &Value) -> std::result::Result<Value, RpcError> {
    let profile_root = optional_path(args, "profile_root", "~/.harvis");
    let mut files = Vec::new();
    let mut missing = Vec::new();
    for relative in PROFILE_FILES {
        let path = profile_root.join(relative);
        if path.exists() {
            files.push(json!({
                "path": relative,
                "bytes": path.metadata().map(|metadata| metadata.len()).unwrap_or(0),
                "modified_at": modified_secs(&path)
            }));
        } else {
            missing.push(relative.to_string());
        }
    }
    Ok(
        json!({"profile_root": profile_root.display().to_string(), "exists": profile_root.exists(), "files": files, "missing": missing}),
    )
}

fn inboxes(args: &Value, root: &Path) -> std::result::Result<Vec<PathBuf>, RpcError> {
    let raw = args
        .get("inboxes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_else(|| vec![json!(".harvis/inbox.md")]);
    let mut paths = Vec::new();
    for item in raw {
        let Some(value) = item.as_str() else {
            return Err(RpcError::new(-32602, "inboxes must be an array of strings"));
        };
        paths.push(workspace_path(root, value)?);
    }
    Ok(paths)
}

fn workspace_path(root: &Path, raw: &str) -> std::result::Result<PathBuf, RpcError> {
    let mut path = expanduser(Path::new(raw));
    if !path.is_absolute() {
        path = root.join(path);
    }
    let path = path
        .canonicalize()
        .map_err(|error| RpcError::new(-32602, error.to_string()))?;
    if !path.starts_with(root) {
        return Err(RpcError::new(
            -32602,
            format!("path is outside workspace root: {}", path.display()),
        ));
    }
    Ok(path)
}

fn root(args: &Value) -> std::result::Result<PathBuf, RpcError> {
    let root = expanduser(Path::new(&require_str(args, "root", None)?))
        .canonicalize()
        .map_err(|_| RpcError::new(-32602, "workspace root must be an existing directory"))?;
    if !root.is_dir() {
        return Err(RpcError::new(
            -32602,
            "workspace root must be an existing directory",
        ));
    }
    Ok(root)
}

fn optional_path(args: &Value, name: &str, default: &str) -> PathBuf {
    optional_string(args, name)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(default))
        .pipe(|path| expanduser(&path))
}

fn require_object(value: &Value) -> std::result::Result<serde_json::Map<String, Value>, RpcError> {
    value
        .as_object()
        .cloned()
        .ok_or_else(|| RpcError::new(-32602, "tool arguments must be an object"))
}

fn require_str(
    args: &Value,
    name: &str,
    default: Option<&str>,
) -> std::result::Result<String, RpcError> {
    let value = args.get(name).and_then(Value::as_str).or(default);
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| RpcError::new(-32602, format!("{name} must be a non-empty string")))
}

fn optional_string(args: &Value, name: &str) -> Option<String> {
    args.get(name)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn optional_bool(args: &Value, name: &str, default: bool) -> std::result::Result<bool, RpcError> {
    match args.get(name) {
        None => Ok(default),
        Some(Value::Bool(value)) => Ok(*value),
        _ => Err(RpcError::new(-32602, format!("{name} must be a boolean"))),
    }
}

fn optional_int(
    args: &Value,
    name: &str,
    default: usize,
    minimum: usize,
    maximum: usize,
) -> std::result::Result<usize, RpcError> {
    let value = match args.get(name) {
        None => default,
        Some(Value::Number(value)) => value
            .as_u64()
            .ok_or_else(|| RpcError::new(-32602, format!("{name} must be an integer")))?
            as usize,
        _ => return Err(RpcError::new(-32602, format!("{name} must be an integer"))),
    };
    if value < minimum || value > maximum {
        return Err(RpcError::new(
            -32602,
            format!("{name} must be between {minimum} and {maximum}"),
        ));
    }
    Ok(value)
}

fn read_json(path: &Path) -> std::result::Result<Value, RpcError> {
    let text = fs::read_to_string(path)?;
    serde_json::from_str(&text).map_err(Into::into)
}

fn parse_packet_status(path: &Path) -> String {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .find_map(|line| {
            line.strip_prefix("Status:")
                .map(str::trim)
                .map(ToOwned::to_owned)
        })
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

fn modified_secs(path: &Path) -> u64 {
    path.metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn normalize(path: &Path) -> String {
    expanduser(path)
        .canonicalize()
        .unwrap_or_else(|_| expanduser(path))
        .display()
        .to_string()
}

trait Pipe: Sized {
    fn pipe<T>(self, f: impl FnOnce(Self) -> T) -> T {
        f(self)
    }
}

impl<T> Pipe for T {}

#[derive(Debug)]
struct RpcError {
    code: i64,
    message: String,
}

impl RpcError {
    fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl From<anyhow::Error> for RpcError {
    fn from(error: anyhow::Error) -> Self {
        Self::new(-32603, error.to_string())
    }
}

impl From<std::io::Error> for RpcError {
    fn from(error: std::io::Error) -> Self {
        Self::new(-32603, error.to_string())
    }
}

impl From<serde_json::Error> for RpcError {
    fn from(error: serde_json::Error) -> Self {
        Self::new(-32603, error.to_string())
    }
}

fn error_response(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_existing_python_tool_names() {
        let response = handle_raw_request(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            .expect("request")
            .expect("response");
        let tools = response["result"]["tools"].as_array().expect("tools");
        assert!(tools
            .iter()
            .any(|tool| tool["name"] == "harvis_init_workspace"));
        assert!(tools
            .iter()
            .any(|tool| tool["name"] == "harvis_persona_init"));
        assert!(tools
            .iter()
            .any(|tool| tool["name"] == "harvis_repoatlas_find_repo"));
        assert!(tools
            .iter()
            .any(|tool| tool["name"] == "harvis_agent_room_live"));
        assert!(tools
            .iter()
            .any(|tool| tool["name"] == "harvis_agent_room_send"));
        assert!(tools
            .iter()
            .any(|tool| tool["name"] == "harvis_agent_room_autochat"));
        assert!(tools
            .iter()
            .any(|tool| tool["name"] == "harvis_agent_roster"));
        assert_eq!(tools.len(), TOOL_NAMES.len());
    }

    #[test]
    fn initializes_with_supported_protocol() {
        let response = handle_raw_request(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
        )
        .expect("request")
        .expect("response");
        assert_eq!(response["result"]["serverInfo"]["name"], SERVER_NAME);
        assert_eq!(response["result"]["protocolVersion"], "2025-06-18");
    }

    #[test]
    fn initialize_echoes_2025_11_25_baseline() {
        let response = handle_raw_request(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
        )
        .expect("request")
        .expect("response");
        assert_eq!(response["result"]["protocolVersion"], "2025-11-25");
        assert_eq!(
            response["result"]["capabilities"]["tools"]["listChanged"],
            false
        );
        assert!(response["result"]["serverInfo"]["version"].is_string());
    }

    #[test]
    fn initialize_falls_back_to_latest_supported_version() {
        // Unsupported or non-dated requests get the server's latest version
        // per MCP lifecycle version negotiation.
        for requested in ["1.0.0", "latest", "1999-01-01"] {
            let response = handle_raw_request(&format!(
                r#"{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":"{requested}"}}}}"#
            ))
            .expect("request")
            .expect("response");
            assert_eq!(response["result"]["protocolVersion"], PROTOCOL_VERSION);
        }
    }

    #[test]
    fn notifications_never_get_a_response() {
        // notifications/initialized is a notification: no id, no response.
        assert!(
            handle_raw_request(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                .expect("notification")
                .is_none()
        );
        // Unknown notification methods are still notifications: silent.
        assert!(handle_raw_request(
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#
        )
        .expect("notification")
        .is_none());
        // Even a request-shaped method without an id is a notification.
        assert!(
            handle_raw_request(r#"{"jsonrpc":"2.0","method":"tools/list"}"#)
                .expect("notification")
                .is_none()
        );
    }

    #[test]
    fn null_request_id_is_rejected() {
        let response = handle_raw_request(r#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
            .expect_err("invalid request")
            .expect("response");
        assert_eq!(response["error"]["code"], -32600);
    }

    #[test]
    fn missing_or_wrong_jsonrpc_version_is_rejected() {
        let response = handle_raw_request(r#"{"id":1,"method":"ping"}"#)
            .expect_err("invalid request")
            .expect("response");
        assert_eq!(response["error"]["code"], -32600);
        let response = handle_raw_request(r#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)
            .expect_err("invalid request")
            .expect("response");
        assert_eq!(response["error"]["code"], -32600);
    }

    #[test]
    fn ping_uses_standard_envelope() {
        let response = handle_raw_request(r#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
            .expect("request")
            .expect("response");
        assert_eq!(response["jsonrpc"], "2.0");
        assert_eq!(response["id"], "abc");
        assert_eq!(response["result"], json!({}));
    }

    #[test]
    fn tools_list_entries_match_official_tool_shape() {
        let response = handle_raw_request(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            .expect("request")
            .expect("response");
        assert_eq!(response["jsonrpc"], "2.0");
        let tools = response["result"]["tools"].as_array().expect("tools");
        assert!(!tools.is_empty());
        for tool in tools {
            assert!(tool["name"].is_string(), "tool name required");
            assert!(tool["description"].is_string(), "description required");
            assert_eq!(tool["inputSchema"]["type"], "object");
        }
    }

    #[test]
    fn tools_call_unknown_tool_is_protocol_error() {
        let response = handle_raw_request(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope_tool"}}"#,
        )
        .expect_err("protocol error")
        .expect("response");
        assert_eq!(response["error"]["code"], -32602);
        assert!(response["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("unknown tool"));
    }

    #[test]
    fn tools_call_success_carries_is_error_false() {
        let root = std::env::temp_dir().join(format!("harvis-mcp-test-{}", std::process::id()));
        fs::create_dir_all(&root).expect("root");
        let response = handle_raw_request(&format!(
            r#"{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"harvis_init_workspace","arguments":{{"root":"{}"}}}}}}"#,
            root.display()
        ))
        .expect("request")
        .expect("response");
        assert_eq!(response["result"]["isError"], false);
        let content = response["result"]["content"].as_array().expect("content");
        assert_eq!(content[0]["type"], "text");
        assert!(content[0]["text"].is_string());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn tools_call_execution_error_uses_is_error_true_envelope() {
        // Input validation failure inside the tool (missing required argument)
        // is a tool execution error: reported in the result, not as a
        // JSON-RPC protocol error.
        let response = handle_raw_request(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"harvis_get_status","arguments":{}}}"#,
        )
        .expect("request")
        .expect("response");
        assert_eq!(response["result"]["isError"], true);
        let content = response["result"]["content"].as_array().expect("content");
        assert_eq!(content[0]["type"], "text");
        assert!(content[0]["text"]
            .as_str()
            .unwrap_or_default()
            .contains("root"));
    }
}
