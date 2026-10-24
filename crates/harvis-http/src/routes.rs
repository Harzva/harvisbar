use anyhow::{bail, Context, Result};
use axum::body::Bytes;
use axum::extract::{Json, Path as AxumPath, Query, State};
use axum::http::{Method, StatusCode, Uri};
use axum::middleware;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc,
};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::process::Command;
use tokio::time::timeout;

use crate::auth::require_auth;
use crate::static_assets;
use crate::AppState;
use harvis_integrations::agent_gateway::AgentStepOptions;
use harvis_integrations::agent_harnesses::build_agent_harness_status;
use harvis_integrations::agent_mail::{
    agent_mail_status as integration_agent_mail_status, unread_summary as agent_mail_unread_summary,
};
use harvis_integrations::hub::{
    hub_path_lookup, hub_status as integration_hub_status, llmwiki_status, wiki_page, wiki_search,
};
use harvis_integrations::local_ports::local_ports_status;
use harvis_integrations::repoatlas::{
    repoatlas_find_repo, repoatlas_missing_local_copies, repoatlas_needs_attention,
    repoatlas_status as integration_repoatlas_status,
};
use harvis_integrations::router::{route_message, RouteMessageOptions};
use harvis_runtime::agent_pools::{agent_pools_status, AgentPoolsOptions};
use harvis_runtime::agent_room::{
    add_event, add_event_with_metadata, add_message, consume_mailbox_loop, create_mailbox_item,
    create_task, create_topic, init_agent_room, link_task, list_agent_room, list_conversations,
    list_handoffs, list_mailbox, list_participants, list_tasks, mark_mailbox_read, request_handoff,
    update_handoff_status, update_participant_status, update_task_status, upsert_participant,
    wake_mailbox_item, workspace_state, HandoffCost, HandoffStatusInput, HandoffUsage,
    HandoffVerification, MailboxInput, ParticipantInput, TaskInput, TaskLinkInput,
    AGENT_ROOM_PROTOCOL_ID,
};
use harvis_runtime::agent_roster::{agent_roster_status, RosterValidationOptions};
use harvis_runtime::approvals::{create_approval, decide_approval, list_approvals};
use harvis_runtime::chair::{chair_step, ChairStepOptions};
use harvis_runtime::inbox::{scan_inboxes, ScanOptions};
use harvis_runtime::init::init_workspace;
use harvis_runtime::knowledge_graph::{scan_knowledge_graph, KnowledgeGraphOptions};
use harvis_runtime::memory::{generate_snapshot, list_memory_candidates, MemorySnapshotOptions};
use harvis_runtime::notifications::{check_notifications, list_notifications};
use harvis_runtime::persona::{
    create_memory_vault, create_persona_card, create_personality_candidate, create_twin_instance,
    decide_personality_candidate, init_persona_registry, list_persona_state, update_persona_card,
};
use harvis_runtime::profile::{expanduser, init_profile, PROFILE_FILES};
use harvis_runtime::projects::{list_projects, ProjectListOptions};
use harvis_runtime::provider_registry::{
    load_provider_registry, provider_registry_status, resolve_model_route, ResolvedModelRoute,
};
use harvis_runtime::runs::{list_runs, rel, sync_packet_runs};
use harvis_runtime::speaker::{
    agent_room_speaker_step, LlmCallRequest, LlmCallResponse, SpeakerStepOptions,
};
use harvis_runtime::tick::{run_tick, TickOptions};
use harvis_runtime::workbench::{prepare_workbench, WorkbenchOptions};

pub const API_VERSION: &str = "v0.40-rust-alpha";
pub const BAR_STATUS_VERSION: &str = "v0.40-rust-alpha";

#[derive(Debug, Serialize)]
struct ApiEnvelope<T: Serialize> {
    ok: bool,
    endpoint: String,
    data: Option<T>,
    warnings: Vec<String>,
    error: Option<ApiErrorBody>,
}

#[derive(Debug, Serialize)]
struct ApiErrorBody {
    code: String,
    message: String,
}

#[derive(Debug)]
struct HttpApiError {
    code: &'static str,
    message: String,
    status: StatusCode,
}

impl HttpApiError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            status: StatusCode::BAD_REQUEST,
        }
    }

    fn status(mut self, status: StatusCode) -> Self {
        self.status = status;
        self
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .merge(crate::group_chat::router())
        .route("/health", get(health))
        .route("/ui/bootstrap", get(ui_bootstrap))
        .route("/ui/tokens.css", get(static_assets::ui_tokens_css))
        .route("/ui/runtime.js", get(static_assets::ui_runtime_js))
        .route("/ui/operator.css", get(static_assets::ui_operator_css))
        .route("/ui/operator.js", get(static_assets::ui_operator_js))
        .route("/ui/t317-smoke.json", get(static_assets::ui_t317_smoke))
        .route("/ui/integrations", get(ui_integrations_get))
        .route("/bar/status", get(bar_status))
        .route(
            "/task-progress",
            get(task_progress_get).post(task_progress_post),
        )
        .route("/status", get(status))
        .route(
            "/permission-probe",
            get(permission_probe_get).post(permission_probe_post),
        )
        .route("/events", get(events))
        .route("/packets", get(packets))
        .route("/runs", get(runs))
        .route("/run-timeline", get(run_timeline_get))
        .route("/codex-thread-bindings", get(codex_thread_bindings_get))
        .route("/codex-thread-pins", get(codex_thread_pins_get))
        .route("/lark/card-actions", get(lark_card_actions_get))
        .route("/approvals", get(approvals))
        .route("/notifications", get(notifications))
        .route("/memory-candidates", get(memory_candidates))
        .route("/profile", get(profile))
        .route("/knowledge-graph", get(knowledge_graph))
        .route("/hub/status", get(hub_status_get))
        .route("/hub/path", get(hub_path_get))
        .route("/hub/search", get(hub_search_get))
        .route("/hub/wiki/page", get(hub_wiki_page_get))
        .route("/hub/llmwiki/status", get(hub_llmwiki_status_get))
        .route("/webview/status", get(webview_status_get))
        .route("/repoatlas/status", get(repoatlas_status_get))
        .route("/repoatlas/find", get(repoatlas_find_get))
        .route("/repoatlas/missing", get(repoatlas_missing_get))
        .route("/repoatlas/attention", get(repoatlas_attention_get))
        .route("/projects", get(projects_get))
        .route("/agent-pools", get(agent_pools_get))
        .route("/router/events", get(router_events_get))
        .route("/router/message", post(router_message_post))
        .route("/agent/step", post(agent_step_post))
        .route("/agent-mail/status", get(agent_mail_status_get))
        .route("/ports/status", get(ports_status_get))
        .route(
            "/agent-mail/unread-summary",
            post(agent_mail_unread_summary_post),
        )
        .route("/agent-harnesses/status", get(agent_harnesses_status))
        .route("/agent-roster", get(agent_roster_get))
        .route("/agent-room", get(agent_room))
        .route("/agent-room/live", get(agent_room_live))
        .route("/agent-room/participants", get(agent_room_participants_get))
        .route("/agent-room/participant", post(agent_room_participant_post))
        .route(
            "/agent-room/participant/status",
            post(agent_room_participant_status_post),
        )
        .route(
            "/agent-room/mailbox",
            get(agent_room_mailbox_get).post(agent_room_mailbox_post),
        )
        .route(
            "/agent-room/mailbox/mark-read",
            post(agent_room_mailbox_mark_read_post),
        )
        .route(
            "/agent-room/mailbox/wake",
            post(agent_room_mailbox_wake_post),
        )
        .route(
            "/agent-room/mailbox/consume",
            post(agent_room_mailbox_consume_post),
        )
        .route("/agent-room/tasks", get(agent_room_tasks_get))
        .route("/agent-room/task", post(agent_room_task_post))
        .route("/agent-room/task/status", post(agent_room_task_status_post))
        .route("/agent-room/task/link", post(agent_room_task_link_post))
        .route(
            "/agent-room/conversations",
            get(agent_room_conversations_get),
        )
        .route(
            "/agent-room/conversation-bindings",
            get(agent_room_conversation_bindings_get),
        )
        .route("/agent-room/team-harness", get(agent_room_team_harness_get))
        .route(
            "/agent-room/workspace-state",
            get(agent_room_workspace_state_get),
        )
        .route("/chair/step", post(chair_step_post))
        .route("/handoffs", get(handoffs))
        .route("/persona", get(persona))
        .route("/init-workspace", post(init_workspace_post))
        .route("/init-profile", post(init_profile_post))
        .route("/scan-inbox", post(scan_inbox_post))
        .route("/run-tick", post(run_tick_post))
        .route("/memory-snapshot", post(memory_snapshot_post))
        .route("/sync-runs", post(sync_runs_post))
        .route("/prepare-workbench", post(prepare_workbench_post))
        .route("/agent-room/init", post(agent_room_init_post))
        .route("/agent-room/topic", post(agent_room_topic_post))
        .route("/agent-room/event", post(agent_room_event_post))
        .route("/agent-room/message", post(agent_room_message_post))
        .route("/agent-room/send", post(agent_room_send_post))
        .route("/agent-room/autochat", post(agent_room_autochat_post))
        .route("/agent-room/step", post(agent_room_step_post))
        .route("/.well-known/agent-card.json", get(a2a_agent_card))
        .route("/a2a/jsonrpc", post(a2a_jsonrpc_post))
        .route("/a2a/message/send", post(a2a_message_send_post))
        .route("/message/send", post(a2a_message_send_post))
        .route("/a2a/message/stream", post(a2a_message_stream_post))
        .route("/message/stream", post(a2a_message_stream_post))
        .route("/a2a/tasks/:task_id/cancel", post(a2a_task_cancel_post))
        .route("/tasks/:task_id/cancel", post(a2a_task_cancel_post))
        .route("/request-handoff", post(request_handoff_post))
        .route("/handoff/status", post(handoff_status_post))
        .route("/agent-room/handoff/status", post(handoff_status_post))
        .route("/request-approval", post(request_approval_post))
        .route("/decide-approval", post(decide_approval_post))
        .route("/check-notifications", post(check_notifications_post))
        .route("/agent-harnesses/test", post(agent_harnesses_test_post))
        .route("/persona/init", post(persona_init_post))
        .route("/persona/create-vault", post(persona_create_vault_post))
        .route("/persona/create-card", post(persona_create_card_post))
        .route("/persona/update-card", post(persona_update_card_post))
        .route("/persona/create-twin", post(persona_create_twin_post))
        .route("/personality-candidate", post(personality_candidate_post))
        .route(
            "/personality-candidate/decide",
            post(personality_candidate_decide_post),
        )
        .route("/panel", get(static_assets::panel_index))
        .route("/panel/", get(static_assets::panel_index))
        .route("/panel/styles.css", get(static_assets::panel_css))
        .route("/panel/panel.js", get(static_assets::panel_js))
        .route("/presence", get(static_assets::presence_index))
        .route("/presence/", get(static_assets::presence_index))
        .route("/presence/styles.css", get(static_assets::presence_css))
        .route("/presence/presence.js", get(static_assets::presence_js))
        .route("/pet", get(static_assets::pet_index))
        .route("/pet/", get(static_assets::pet_index))
        .route("/pet/styles.css", get(static_assets::pet_css))
        .route("/pet/pet.js", get(static_assets::pet_js))
        .route("/studio", get(static_assets::studio_index))
        .route("/studio/", get(static_assets::studio_index))
        .route("/studio/roundtable", get(static_assets::studio_roundtable))
        .route("/studio/roundtable/", get(static_assets::studio_roundtable))
        .route("/studio/mobile", get(static_assets::studio_mobile))
        .route("/studio/mobile/", get(static_assets::studio_mobile))
        .route("/studio/styles.css", get(static_assets::studio_css))
        .route("/studio/studio.js", get(static_assets::studio_js))
        .route("/studio/mobile.css", get(static_assets::studio_mobile_css))
        .route("/studio/mobile.js", get(static_assets::studio_mobile_js))
        .route("/studio/assets/:name", get(static_assets::studio_asset))
        .route("/schemas/:name", get(static_assets::schema))
        .fallback(fallback)
        .with_state(state.clone())
        .layer(middleware::from_fn_with_state(state, require_auth))
}

pub fn error_envelope(endpoint: &str, code: &str, message: &str) -> Json<Value> {
    Json(json!({
        "ok": false,
        "endpoint": endpoint,
        "error": {
            "code": code,
            "message": message
        }
    }))
}

fn ok(endpoint: &str, data: impl Serialize) -> Json<ApiEnvelope<impl Serialize>> {
    Json(ApiEnvelope {
        ok: true,
        endpoint: endpoint.to_string(),
        data: Some(data),
        warnings: Vec::new(),
        error: None,
    })
}

fn ok_with_warnings(
    endpoint: &str,
    data: impl Serialize,
    warnings: Vec<String>,
) -> Json<ApiEnvelope<impl Serialize>> {
    Json(ApiEnvelope {
        ok: true,
        endpoint: endpoint.to_string(),
        data: Some(data),
        warnings,
        error: None,
    })
}

fn fail(endpoint: &str, error: HttpApiError) -> Response {
    let payload = ApiEnvelope::<Value> {
        ok: false,
        endpoint: endpoint.to_string(),
        data: None,
        warnings: Vec::new(),
        error: Some(ApiErrorBody {
            code: error.code.to_string(),
            message: error.message,
        }),
    };
    (error.status, Json(payload)).into_response()
}

async fn health(State(state): State<AppState>) -> Response {
    ok(
        "/health",
        json!({
            "agent": "H.A.R.V.I.S.",
            "api_version": API_VERSION,
            "agent_harnesses": "available",
            "mode": "localhost-json-rust",
            "autonomy_level": 1,
            "bar_status": "available",
            "auth_required": state.auth_token.is_some(),
            "persona_studio": "available",
            "permission_probe": "available",
            "hub": "available",
            "repoatlas": "available",
            "router": "available",
            "knowledge_graph": "available",
            "agent_mail": "available",
            "ports": "available",
            "runtime": "rust"
        }),
    )
    .into_response()
}

/// A deliberately credential-free bootstrap for static localhost surfaces.
///
/// The route is public only so an unconfigured browser can discover the
/// workspace before it has an in-memory bearer token. It refuses to answer
/// when the server is bound beyond loopback, never returns a credential, and
/// does not grant access to any protected API route.
async fn ui_bootstrap(State(state): State<AppState>) -> Response {
    if !state.loopback_only {
        return fail(
            "/ui/bootstrap",
            HttpApiError::new(
                "loopback_required",
                "UI bootstrap is available only on a loopback-bound runtime",
            )
            .status(StatusCode::FORBIDDEN),
        );
    }
    let label = state
        .workspace_root
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("workspace");
    ok(
        "/ui/bootstrap",
        json!({
            "workspace_root": state.workspace_root.display().to_string(),
            "workspace_label": label,
            "auth_required": state.auth_token.is_some(),
            "token_included": false,
            "network_scope": "loopback"
        }),
    )
    .into_response()
}

async fn ui_integrations_get(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let data = query_to_value(query);
    let root = match require_str(&data, "root", None).and_then(resolve_root) {
        Ok(root) => root,
        Err(error) => return fail("/ui/integrations", map_error(error)),
    };
    match build_ui_integrations(&root, &state.plugin_root).await {
        Ok(value) => ok("/ui/integrations", value).into_response(),
        Err(error) => fail("/ui/integrations", map_error(error)),
    }
}

async fn build_ui_integrations(root: &Path, plugin_root: &Path) -> Result<Value> {
    use time::format_description::well_known::Rfc3339;
    use time::OffsetDateTime;

    let registry_path = root
        .join("digital_me")
        .join("registry")
        .join("harvis_lark_bridge.json");
    let registry: Value = if registry_path.is_file() {
        serde_json::from_slice(&fs::read(&registry_path)?)?
    } else {
        json!({})
    };
    let chains = registry
        .get("consumer_chains")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut seen = std::collections::BTreeSet::new();
    let mut profiles = Vec::new();
    for chain in chains {
        let profile_role = safe_ui_label(&chain, "profile_role", "unregistered");
        let source_role = safe_ui_label(&chain, "source_role", "listener");
        let event_type = safe_ui_label(&chain, "event_type", "unknown_event");
        let launch_label = safe_ui_label(&chain, "launch_label", "");
        let key = format!("{profile_role}:{event_type}");
        let unique = seen.insert(key);
        let listener_health = launch_label_online(&launch_label).await;
        profiles.push(json!({
            "profile_role": profile_role,
            "source_role": source_role,
            "event_type": event_type,
            "listener_health": listener_health,
            "consumer_unique": unique
        }));
    }

    let lark_root = root.join(".harvis").join("lark");
    let card_actions = lark_root.join("card-actions.jsonl");
    let last_card_action_age_seconds = card_actions
        .metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .map(|duration| duration.as_secs());
    let lock_present = lark_root.join(".session-store.lock").is_file();
    let duplicate_guard = lock_present
        && profiles.iter().all(|profile| {
            profile
                .get("consumer_unique")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });
    let all_online = !profiles.is_empty()
        && profiles.iter().all(|profile| {
            profile.get("listener_health").and_then(Value::as_str) == Some("online")
        });
    let smoke_path = plugin_root.join("ui").join("t317-smoke.json");
    let smoke: Value = if smoke_path.is_file() {
        serde_json::from_slice(&fs::read(&smoke_path)?)?
    } else {
        json!({})
    };
    let observed_at = smoke
        .get("observed_at")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let evidence_age_seconds =
        OffsetDateTime::parse(observed_at, &Rfc3339)
            .ok()
            .and_then(|observed| {
                let age = (OffsetDateTime::now_utc() - observed).whole_seconds();
                (age >= 0).then_some(age as u64)
            });
    let evidence_fresh = evidence_age_seconds.is_some_and(|age| age <= 30 * 24 * 60 * 60);
    let evidence_mode = smoke
        .get("mode")
        .and_then(Value::as_str)
        .filter(|value| ["fixture", "live", "unknown"].contains(value))
        .unwrap_or("unknown");
    let evidence_status = smoke
        .get("status")
        .and_then(Value::as_str)
        .filter(|value| ["verified", "failed", "unknown"].contains(value))
        .unwrap_or("unknown");
    let reported_live_complete = smoke
        .get("live_complete")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let live_complete = evidence_fresh
        && evidence_mode == "live"
        && evidence_status == "verified"
        && reported_live_complete;
    let scope_status = smoke
        .get("scope_status")
        .and_then(Value::as_str)
        .filter(|value| ["verified", "missing", "unknown"].contains(value))
        .unwrap_or("unknown");
    let membership_status = smoke
        .get("membership_status")
        .and_then(Value::as_str)
        .filter(|value| {
            [
                "verified",
                "owner_confirmation_pending",
                "missing",
                "unknown",
            ]
            .contains(value)
        })
        .unwrap_or("unknown");
    let source_commit = smoke
        .get("source_commit")
        .and_then(Value::as_str)
        .filter(|value| {
            value.len() == 40 && value.chars().all(|character| character.is_ascii_hexdigit())
        })
        .unwrap_or("unknown");
    Ok(json!({
        "schema_version": "harvis-ui-integrations-v1",
        "lark": {
            "transport": "lark-cli/OpenAPI",
            "profiles": profiles,
            "listener_health": if all_online { "online" } else { "needs_attention" },
            "last_card_action_age_seconds": last_card_action_age_seconds,
            "duplicate_guard": if duplicate_guard { "local_guard_active" } else { "local_guard_needs_attention" },
            "scope_status": if evidence_fresh { scope_status } else { "unknown" },
            "membership_status": if evidence_fresh { membership_status } else { "unknown" },
            "scope_membership_gaps": if live_complete { Vec::<&str>::new() } else { vec!["live_test_group_not_confirmed"] },
            "smoke": {
                "evidence_mode": evidence_mode,
                "status": if evidence_fresh { evidence_status } else { "stale" },
                "observed_at": observed_at,
                "evidence_age_seconds": evidence_age_seconds,
                "source_commit": source_commit,
                "checks_passed": smoke.get("checks_passed").and_then(Value::as_u64),
                "checks_total": smoke.get("checks_total").and_then(Value::as_u64),
                "live_complete": live_complete,
                "href": "/ui/t317-smoke.json"
            }
        }
    }))
}

fn safe_ui_label(value: &Value, key: &str, fallback: &str) -> String {
    let label = value.get(key).and_then(Value::as_str).unwrap_or(fallback);
    if label.len() <= 96
        && label
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._:-".contains(character))
    {
        label.to_string()
    } else {
        fallback.to_string()
    }
}

async fn launch_label_online(label: &str) -> &'static str {
    if label.is_empty() {
        return "unknown";
    }
    #[cfg(target_os = "macos")]
    {
        let Ok(uid) = Command::new("id").arg("-u").output().await else {
            return "unknown";
        };
        if !uid.status.success() {
            return "unknown";
        }
        let uid = String::from_utf8_lossy(&uid.stdout).trim().to_string();
        let target = format!("gui/{uid}/{label}");
        return match Command::new("launchctl")
            .arg("print")
            .arg(target)
            .output()
            .await
        {
            Ok(output) if output.status.success() => {
                let rendered = format!(
                    "{}{}",
                    String::from_utf8_lossy(&output.stdout),
                    String::from_utf8_lossy(&output.stderr)
                );
                if launchctl_output_is_running(&rendered) {
                    "online"
                } else {
                    "offline"
                }
            }
            Ok(_) => "offline",
            Err(_) => "unknown",
        };
    }
    #[cfg(not(target_os = "macos"))]
    {
        "unknown"
    }
}

fn launchctl_output_is_running(rendered: &str) -> bool {
    let state_running = rendered
        .lines()
        .any(|line| line.trim() == "state = running");
    let has_pid = rendered.lines().any(|line| {
        line.trim()
            .strip_prefix("pid =")
            .and_then(|value| value.trim().parse::<u32>().ok())
            .is_some_and(|pid| pid > 0)
    });
    state_running && has_pid
}

async fn bar_status(Query(query): Query<HashMap<String, String>>) -> Response {
    let data = query_to_value(query);
    let raw_root = match require_str(&data, "root", None) {
        Ok(root) => root,
        Err(error) => return fail("/bar/status", map_error(error)),
    };
    if !optional_bool(&data, "full", false).unwrap_or(false) {
        return match lightweight_bar_status(
            Path::new(&raw_root),
            "bar status returned lightweight data; pass full=true for filesystem-backed status",
        ) {
            Ok((data, warnings)) => ok_with_warnings("/bar/status", data, warnings).into_response(),
            Err(error) => fail("/bar/status", map_error(error)),
        };
    }
    let profile_root = optional_path(&data, "profile_root", "~/.harvis");
    match timeout(
        Duration::from_millis(5000),
        tokio::task::spawn_blocking(move || {
            let root = resolve_root(raw_root)?;
            if root.parent().is_none() || !root.join(".harvis").exists() {
                return lightweight_bar_status(
                    &root,
                    "workspace .harvis directory not found; bar status skipped filesystem reads",
                );
            }
            build_bar_status(&root, Some(&profile_root))
        }),
    )
    .await
    {
        Ok(Ok(Ok((data, warnings)))) => {
            ok_with_warnings("/bar/status", data, warnings).into_response()
        }
        Ok(Ok(Err(error))) => fail("/bar/status", map_error(error)),
        Ok(Err(error)) => fail(
            "/bar/status",
            HttpApiError::new(
                "runtime_error",
                format!("bar status worker failed: {error}"),
            )
            .status(StatusCode::INTERNAL_SERVER_ERROR),
        ),
        Err(_) => match lightweight_bar_status(
            Path::new("workspace"),
            "bar status root or filesystem read timed out; returned lightweight status",
        ) {
            Ok((data, warnings)) => ok_with_warnings("/bar/status", data, warnings).into_response(),
            Err(error) => fail("/bar/status", map_error(error)),
        },
    }
}

async fn task_progress_get(Query(query): Query<HashMap<String, String>>) -> Response {
    let data = query_to_value(query);
    let raw_root = match require_str(&data, "root", None) {
        Ok(root) => root,
        Err(error) => return fail("/task-progress", map_error(error)),
    };
    let limit = match optional_int(&data, "limit", 20, 1, 200) {
        Ok(limit) => limit,
        Err(error) => return fail("/task-progress", map_error(error)),
    };
    let include_inactive = match optional_bool(&data, "include_inactive", true) {
        Ok(include_inactive) => include_inactive,
        Err(error) => return fail("/task-progress", map_error(error)),
    };
    match optional_bool(&data, "include_local", false) {
        Ok(false) => {}
        Ok(true) => {
            return fail(
                "/task-progress",
                HttpApiError::new(
                    "invalid_request",
                    "include_local is disabled for the public-safe task progress endpoint",
                ),
            )
        }
        Err(error) => return fail("/task-progress", map_error(error)),
    }
    let cancelled = Arc::new(AtomicBool::new(false));
    let worker_cancelled = Arc::clone(&cancelled);
    match timeout(
        Duration::from_millis(5000),
        tokio::task::spawn_blocking(move || {
            let root = resolve_root(raw_root)?;
            task_progress_status_with_cancel(
                &root,
                limit,
                include_inactive,
                Some(worker_cancelled.as_ref()),
            )
        }),
    )
    .await
    {
        Ok(Ok(result)) => task_progress_get_response(result),
        Ok(Err(_)) => fail("/task-progress", task_progress_worker_error("read")),
        Err(_) => {
            cancelled.store(true, Ordering::Relaxed);
            task_progress_get_response(
                task_progress_snapshot(
                    "skipped",
                    "Task progress is unavailable.",
                    0,
                    vec![],
                    Value::Null,
                )
                .map(|status| (status, vec![TASK_PROGRESS_UNAVAILABLE_WARNING.to_string()])),
            )
        }
    }
}

fn lightweight_bar_status(root: &Path, warning: &str) -> Result<(Value, Vec<String>)> {
    let workspace = public_workspace_label(root);
    let task_progress = task_progress_snapshot(
        "skipped",
        "Task progress was not read in lightweight mode.",
        0,
        vec![],
        Value::Null,
    )?;
    Ok((
        json!({
            "schemaVersion": "harvis.bar-status.v0",
            "safeForHarvisBar": true,
            "generatedAt": harvis_core::time::now_rfc3339()?,
            "runtime": {
                "name": "H.A.R.V.I.S.",
                "state": "idle",
                "mode": "not-initialized",
                "autonomyLevel": 1,
                "version": BAR_STATUS_VERSION,
                "sourceRuntimeVersion": null,
                "summary": warning
            },
            "workspace": {
                "label": workspace,
                "rootDisplay": workspace,
                "configured": false,
                "statusPresent": false,
                "allowlistCount": 0,
                "stateStore": "none"
            },
            "serviceHealth": {
                "http": "running",
                "tickRunner": "not-probed",
                "mcp": "available"
            },
            "work": {
                "packets": 0,
                "packetStatusCounts": {},
                "blocked": 0,
                "pendingApprovals": 0,
                "runtimeErrors": 0,
                "runtimeWarnings": 1,
                "runs": 0,
                "activeRun": null,
                "lastTickAt": null,
                "lastEvent": null
            },
            "knowledge": {
                "hub": "not-probed",
                "wiki": "not-probed",
                "activeSources": [],
                "allowlistedSources": 0,
                "lastLookupAt": null,
                "policy": "redacted-rust-runtime",
                "redacted": true,
                "includesLocalAbsolutePaths": false
            },
            "agentHarnesses": agent_harness_status(false),
            "ports": local_ports_status(),
            "taskProgress": task_progress,
            "safety": {
                "redacted": true,
                "includesSecrets": false,
                "includesRawMemory": false,
                "includesCredentialPaths": false,
                "includesLocalAbsolutePaths": false,
                "networkExposure": "localhost-only"
            }
        }),
        vec![warning.to_string()],
    ))
}

async fn task_progress_post(Json(body): Json<Value>) -> Response {
    let data = if body.is_object() { body } else { json!({}) };
    match tokio::task::spawn_blocking(move || {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        upsert_task_progress(&root, &data)
    })
    .await
    {
        Ok(result) => task_progress_post_response(result),
        Err(_) => fail("/task-progress", task_progress_worker_error("update")),
    }
}

fn task_progress_get_response(result: Result<(Value, Vec<String>)>) -> Response {
    match result {
        Ok((data, warnings)) => ok_with_warnings("/task-progress", data, warnings).into_response(),
        Err(error) => fail("/task-progress", map_error(error)),
    }
}

fn task_progress_post_response(result: Result<Value>) -> Response {
    match result {
        Ok(data) => ok("/task-progress", data).into_response(),
        Err(error) => fail("/task-progress", map_error(error)),
    }
}

fn task_progress_worker_error(operation: &str) -> HttpApiError {
    HttpApiError::new(
        "runtime_error",
        format!("task progress {operation} worker failed"),
    )
    .status(StatusCode::INTERNAL_SERVER_ERROR)
}

async fn status(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/status", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let profile_root = optional_path(&data, "profile_root", "~/.harvis");
        let (status, status_path, state_store) =
            read_runtime_json_object(&root, "status.json", &profile_root);
        if !status.is_object() || status.as_object().is_some_and(Map::is_empty) {
            bail!("status file not found for workspace: {}", root.display());
        }
        Ok(json!({
            "workspace_root": root.display().to_string(),
            "status_path": status_path.map(|path| path.display().to_string()),
            "state_store": state_store,
            "status": status
        }))
    })
}

async fn permission_probe_get(Query(query): Query<HashMap<String, String>>) -> Response {
    let data = query_to_value(query);
    let raw_root = match require_str(&data, "root", None) {
        Ok(root) => root,
        Err(error) => return fail("/permission-probe", map_error(error)),
    };
    if !optional_bool(&data, "full", false).unwrap_or(false) {
        return ok("/permission-probe", lightweight_permission_probe(&raw_root)).into_response();
    }
    let profile_root = optional_path(&data, "profile_root", "~/.harvis");
    match timeout(
        Duration::from_millis(5000),
        tokio::task::spawn_blocking(move || {
            let root = resolve_root(raw_root)?;
            Ok(permission_probe(&root, &profile_root))
        }),
    )
    .await
    {
        Ok(Ok(Ok(data))) => ok("/permission-probe", data).into_response(),
        Ok(Ok(Err(error))) => fail("/permission-probe", map_error(error)),
        Ok(Err(error)) => fail(
            "/permission-probe",
            HttpApiError::new(
                "runtime_error",
                format!("permission probe worker failed: {error}"),
            ),
        ),
        Err(_) => ok(
            "/permission-probe",
            timeout_permission_probe("timeout: permission probe skipped filesystem writes"),
        )
        .into_response(),
    }
}

async fn events(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/events", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let profile_root = optional_path(&data, "profile_root", "~/.harvis");
        read_events(
            &root,
            &profile_root,
            optional_int(&data, "limit", 50, 1, 1000)?,
        )
    })
}

async fn packets(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/packets", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_packets(
            &root,
            optional_int(&data, "limit", 50, 1, 500)?,
            optional_bool(&data, "include_preview", false)?,
            optional_int(&data, "max_preview_chars", 800, 0, 8000)?,
        )
    })
}

async fn runs(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/runs", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok(serde_json::to_value(list_runs(
            &root,
            optional_int(&data, "limit", 50, 1, 500)?,
        )?)?)
    })
}

async fn run_timeline_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/run-timeline", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let profile_root = optional_path(&data, "profile_root", "~/.harvis");
        read_run_timeline(
            &root,
            &profile_root,
            optional_string(&data, "run_id").as_deref(),
            optional_string(&data, "codex_thread_id").as_deref(),
            optional_int(&data, "limit", 80, 1, 500)?,
        )
    })
}

async fn codex_thread_bindings_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/codex-thread-bindings", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let profile_root = optional_path(&data, "profile_root", "~/.harvis");
        list_codex_thread_bindings(
            &root,
            &profile_root,
            optional_int(&data, "limit", 50, 1, 500)?,
            optional_bool(&data, "include_legacy", false)?,
        )
    })
}

async fn codex_thread_pins_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/codex-thread-pins", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let profile_root = optional_path(&data, "profile_root", "~/.harvis");
        list_codex_thread_pins(
            &root,
            &profile_root,
            optional_int(&data, "limit", 50, 1, 500)?,
        )
    })
}

async fn lark_card_actions_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/lark/card-actions", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let profile_root = optional_path(&data, "profile_root", "~/.harvis");
        list_lark_card_actions(
            &root,
            &profile_root,
            optional_int(&data, "limit", 50, 1, 500)?,
        )
    })
}

async fn memory_candidates(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/memory-candidates", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_memory_candidates(&root, optional_int(&data, "limit", 50, 1, 500)?)
    })
}

async fn profile(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/profile", query, |data| {
        let profile_root = optional_path(&data, "profile_root", "~/.harvis");
        Ok(profile_metadata(&profile_root))
    })
}

async fn knowledge_graph(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/knowledge-graph", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let graph = scan_knowledge_graph(KnowledgeGraphOptions {
            root,
            config_path: optional_string(&data, "config").map(PathBuf::from),
            vault_override: optional_string(&data, "vault").map(PathBuf::from),
            include_paths_override: has_key(&data, "include_paths")
                .then(|| optional_bool(&data, "include_paths", false))
                .transpose()?,
            max_files_override: has_key(&data, "max_files")
                .then(|| optional_int(&data, "max_files", 1000, 1, 20000))
                .transpose()?,
            max_nodes_override: has_key(&data, "max_nodes")
                .then(|| optional_int(&data, "max_nodes", 1500, 1, 20000))
                .transpose()?,
        })?;
        Ok(serde_json::to_value(graph)?)
    })
}

async fn agent_harnesses_status() -> Response {
    ok("/agent-harnesses/status", agent_harness_status(false)).into_response()
}

async fn hub_status_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/hub/status", query, |_data| Ok(integration_hub_status()))
}

async fn hub_path_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/hub/path", query, |data| {
        hub_path_lookup(
            &require_str(&data, "query", None)?,
            optional_int(&data, "limit", 10, 1, 50)?,
        )
    })
}

async fn hub_search_get(Query(query): Query<HashMap<String, String>>) -> Response {
    let data = query_to_value(query);
    let query_text = match require_str(&data, "query", None) {
        Ok(query) => query,
        Err(error) => return fail("/hub/search", map_error(error)),
    };
    let limit = match optional_int(&data, "limit", 10, 1, 50) {
        Ok(limit) => limit,
        Err(error) => return fail("/hub/search", map_error(error)),
    };
    let max_excerpt_chars = match optional_int(&data, "max_excerpt_chars", 360, 80, 2000) {
        Ok(max_excerpt_chars) => max_excerpt_chars,
        Err(error) => return fail("/hub/search", map_error(error)),
    };
    let query_for_timeout = query_text.clone();
    match timeout(
        Duration::from_millis(3000),
        tokio::task::spawn_blocking(move || wiki_search(&query_text, limit, max_excerpt_chars)),
    )
    .await
    {
        Ok(Ok(Ok(data))) => ok("/hub/search", data).into_response(),
        Ok(Ok(Err(error))) => fail("/hub/search", map_error(error)),
        Ok(Err(error)) => fail(
            "/hub/search",
            HttpApiError::new(
                "runtime_error",
                format!("hub search worker failed: {error}"),
            ),
        ),
        Err(_) => ok_with_warnings(
            "/hub/search",
            json!({
                "query": query_for_timeout,
                "count": 0,
                "items": [],
                "wiki": "timeout",
                "redacted": true,
                "includesLocalAbsolutePaths": false
            }),
            vec!["hub search timed out; returned empty redacted result".to_string()],
        )
        .into_response(),
    }
}

async fn hub_wiki_page_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/hub/wiki/page", query, |data| {
        wiki_page(
            &require_str(&data, "page", None)?,
            optional_int(&data, "max_chars", 3000, 200, 8000)?,
        )
    })
}

async fn hub_llmwiki_status_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/hub/llmwiki/status", query, |_data| Ok(llmwiki_status()))
}

async fn webview_status_get(Query(query): Query<HashMap<String, String>>) -> Response {
    let data = query_to_value(query);
    let base_url = optional_string(&data, "url")
        .or_else(|| std::env::var("HARVIS_WEBVIEW_URL").ok())
        .unwrap_or_else(|| "http://127.0.0.1:7861/".to_string());
    let sample_limit = match optional_int(&data, "sample_limit", 5, 0, 20) {
        Ok(limit) => limit,
        Err(error) => return fail("/webview/status", map_error(error)),
    };
    match harvis_webview_status(&base_url, sample_limit).await {
        Ok(data) => ok("/webview/status", data).into_response(),
        Err(error) => fail("/webview/status", map_error(error)),
    }
}

async fn repoatlas_status_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/repoatlas/status", query, |data| {
        Ok(integration_repoatlas_status(
            optional_string(&data, "map_path").as_deref(),
            optional_bool(&data, "include_paths", false)?,
        ))
    })
}

async fn harvis_webview_status(base_url: &str, sample_limit: usize) -> Result<Value> {
    let base = reqwest::Url::parse(base_url).context("webview url is invalid")?;
    let host = base
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("webview url host is required"))?;
    if !matches!(host, "127.0.0.1" | "localhost" | "::1") {
        bail!("webview url must point to localhost");
    }
    let projects_url = base.join("/api/projects")?;
    let response = reqwest::Client::builder()
        .timeout(Duration::from_millis(1500))
        .build()?
        .get(projects_url)
        .send()
        .await
        .context("webview projects request failed")?;
    let status = response.status();
    let payload: Value = response
        .json()
        .await
        .context("webview projects response was not json")?;
    if !status.is_success() {
        bail!("webview projects request returned HTTP {status}");
    }
    let projects = payload
        .get("projects")
        .and_then(Value::as_array)
        .or_else(|| payload.as_array());
    let project_count = projects.map(Vec::len).unwrap_or(0);
    let sample = projects
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_object)
                .take(sample_limit)
                .map(|project| {
                    json!({
                        "id": sanitize_webview_text(project.get("id").and_then(Value::as_str)),
                        "name": sanitize_webview_text(project.get("name").and_then(Value::as_str)),
                        "kind": sanitize_webview_text(project.get("kind").and_then(Value::as_str)),
                        "root_exists": project.get("root_exists").and_then(Value::as_bool).unwrap_or(false),
                        "tags": project.get("tags").and_then(Value::as_array)
                            .map(|tags| tags.iter()
                                .filter_map(Value::as_str)
                                .take(5)
                                .map(|tag| sanitize_webview_text(Some(tag)))
                                .collect::<Vec<_>>())
                            .unwrap_or_default()
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(json!({
        "gateway": "harvis",
        "webview": "available",
        "primary_url": base.as_str(),
        "generated_at": payload.get("generated_at").cloned().unwrap_or(Value::Null),
        "project_count": project_count,
        "sample": sample,
        "redacted": true,
        "includesLocalAbsolutePaths": false
    }))
}

fn sanitize_webview_text(value: Option<&str>) -> Value {
    let text = value.unwrap_or_default();
    if text.starts_with("/Users/") || text.starts_with("/Volumes/") || text.starts_with("/private/")
    {
        return Value::String("[local-path]".to_string());
    }
    Value::String(text.chars().take(160).collect())
}

async fn repoatlas_find_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/repoatlas/find", query, |data| {
        repoatlas_find_repo(
            &require_str(&data, "query", None)?,
            optional_int(&data, "limit", 10, 1, 50)?,
            optional_string(&data, "map_path").as_deref(),
            optional_bool(&data, "include_paths", false)?,
        )
    })
}

async fn repoatlas_missing_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/repoatlas/missing", query, |data| {
        Ok(repoatlas_missing_local_copies(
            optional_int(&data, "limit", 50, 1, 200)?,
            optional_string(&data, "map_path").as_deref(),
        ))
    })
}

async fn repoatlas_attention_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/repoatlas/attention", query, |data| {
        Ok(repoatlas_needs_attention(
            optional_int(&data, "limit", 50, 1, 200)?,
            optional_string(&data, "map_path").as_deref(),
            optional_bool(&data, "include_paths", false)?,
        ))
    })
}

async fn agent_mail_status_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-mail/status", query, |_data| {
        Ok(integration_agent_mail_status())
    })
}

async fn ports_status_get(Query(query): Query<HashMap<String, String>>) -> Response {
    let _ = query;
    ok("/ports/status", local_ports_status()).into_response()
}

async fn agent_mail_unread_summary_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-mail/unread-summary", body, |data| {
        let limit = optional_int(&data, "limit", 8, 1, 20)? as usize;
        Ok((agent_mail_unread_summary(limit)?, Vec::new()))
    })
}

async fn init_workspace_post(Json(body): Json<Value>) -> Response {
    handle_post("/init-workspace", body, |data| {
        let root = body_path(&data, "root", ".")?;
        let messages = init_workspace(&root, optional_bool(&data, "force", false)?)?;
        let root = root.canonicalize().unwrap_or(root);
        Ok((
            json!({"workspace_root": root.display().to_string(), "messages": messages}),
            Vec::new(),
        ))
    })
}

async fn init_profile_post(Json(body): Json<Value>) -> Response {
    handle_post("/init-profile", body, |data| {
        let profile_root = body_path(&data, "profile_root", "~/.harvis")?;
        let messages = init_profile(&profile_root, optional_bool(&data, "force", false)?)?;
        let profile_root = expanduser(&profile_root)
            .canonicalize()
            .unwrap_or_else(|_| expanduser(&profile_root));
        Ok((
            json!({"profile_root": profile_root.display().to_string(), "messages": messages}),
            Vec::new(),
        ))
    })
}

async fn scan_inbox_post(Json(body): Json<Value>) -> Response {
    handle_post("/scan-inbox", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let raw_inboxes = data
            .get("inboxes")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_else(|| vec![json!(".harvis/inbox.md")]);
        let mut inboxes = Vec::new();
        for item in raw_inboxes {
            let Some(raw) = item.as_str() else {
                bail!("inboxes must be an array of strings");
            };
            inboxes.push(resolve_workspace_path(&root, raw)?);
        }
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
        Ok((
            json!({
                "workspace_root": root.display().to_string(),
                "inboxes": inboxes.iter().map(|path| path.display().to_string()).collect::<Vec<_>>(),
                "packets_written": packets.iter().map(|path| path.display().to_string()).collect::<Vec<_>>(),
                "runs_written": runs.get("runs").cloned().unwrap_or_else(|| json!([]))
            }),
            Vec::new(),
        ))
    })
}

async fn run_tick_post(Json(body): Json<Value>) -> Response {
    handle_post("/run-tick", body, |data| {
        let root = body_path(&data, "root", ".")?;
        let profile_root = body_path(&data, "profile_root", "~/.harvis")?;
        let interval = Some(optional_int(&data, "interval", 1200, 1, 86400)? as u64);
        let (status, side_effects) = run_tick(TickOptions {
            root: root.clone(),
            interval_override: interval,
            profile_root,
        })?;
        let warnings = status
            .errors
            .iter()
            .cloned()
            .chain(status.warnings.iter().cloned())
            .collect();
        Ok((
            json!({
                "workspace_root": root.canonicalize().unwrap_or(root).display().to_string(),
                "status": status,
                "captured_output": [
                    format!("wrote status: {}", side_effects.status_path.display()),
                    format!("wrote report: {}", side_effects.report_path.display())
                ]
            }),
            warnings,
        ))
    })
}

async fn permission_probe_post(Json(body): Json<Value>) -> Response {
    let data = if body.is_object() { body } else { json!({}) };
    let raw_root = match require_str(&data, "root", None) {
        Ok(root) => root,
        Err(error) => return fail("/permission-probe", map_error(error)),
    };
    if !optional_bool(&data, "full", false).unwrap_or(false) {
        return ok_with_warnings(
            "/permission-probe",
            lightweight_permission_probe(&raw_root),
            vec![
                "permission probe is lightweight by default; pass full=true to write probe files"
                    .to_string(),
            ],
        )
        .into_response();
    }
    let profile_root = match body_path(&data, "profile_root", "~/.harvis") {
        Ok(path) => path,
        Err(error) => return fail("/permission-probe", map_error(error)),
    };
    match timeout(
        Duration::from_millis(5000),
        tokio::task::spawn_blocking(move || {
            let root = resolve_root(raw_root)?;
            Ok(permission_probe(&root, &profile_root))
        }),
    )
    .await
    {
        Ok(Ok(Ok(data))) => ok("/permission-probe", data).into_response(),
        Ok(Ok(Err(error))) => fail("/permission-probe", map_error(error)),
        Ok(Err(error)) => fail(
            "/permission-probe",
            HttpApiError::new(
                "runtime_error",
                format!("permission probe worker failed: {error}"),
            ),
        ),
        Err(_) => ok_with_warnings(
            "/permission-probe",
            timeout_permission_probe("timeout: permission probe skipped filesystem writes"),
            vec!["permission probe filesystem write timed out".to_string()],
        )
        .into_response(),
    }
}

async fn memory_snapshot_post(Json(body): Json<Value>) -> Response {
    handle_post("/memory-snapshot", body, |data| {
        let root = body_path(&data, "root", ".")?;
        let profile_root = body_path(&data, "profile_root", "~/.harvis")?;
        let result = generate_snapshot(MemorySnapshotOptions {
            root,
            profile_root,
            max_events: optional_int(&data, "max_events", 50, 0, 500)?,
            max_packets: optional_int(&data, "max_packets", 50, 0, 500)?,
            max_reports: optional_int(&data, "max_reports", 10, 0, 100)?,
            max_excerpt_chars: optional_int(&data, "max_excerpt_chars", 1200, 0, 8000)?,
        })?;
        let warnings = result.warnings.clone();
        Ok((serde_json::to_value(result)?, warnings))
    })
}

async fn sync_runs_post(Json(body): Json<Value>) -> Response {
    handle_post("/sync-runs", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let result = sync_packet_runs(&root, None, optional_int(&data, "limit", 500, 1, 5000)?)?;
        Ok((serde_json::to_value(result)?, Vec::new()))
    })
}

async fn prepare_workbench_post(Json(body): Json<Value>) -> Response {
    handle_post("/prepare-workbench", body, |data| {
        let packet = optional_string(&data, "packet");
        Ok((
            prepare_workbench(WorkbenchOptions {
                root: body_path(&data, "root", ".")?,
                profile_root: body_path(&data, "profile_root", "~/.harvis")?,
                packet,
                limit: optional_int(&data, "limit", 5, 1, 100)?,
            })?,
            Vec::new(),
        ))
    })
}

async fn approvals(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/approvals", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_approvals(
            &root,
            optional_string(&data, "status").as_deref(),
            optional_int(&data, "limit", 50, 1, 500)?,
        )
    })
}

async fn notifications(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/notifications", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_notifications(
            &root,
            optional_string(&data, "kind").as_deref(),
            optional_int(&data, "limit", 50, 1, 500)?,
        )
    })
}

async fn agent_room(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-room", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_agent_room(&root, optional_int(&data, "limit", 50, 1, 500)?)
    })
}

async fn agent_roster_get(Query(query): Query<HashMap<String, String>>) -> Response {
    let data = query_to_value(query);
    let raw_root = match require_str(&data, "root", None) {
        Ok(root) => root,
        Err(error) => return fail("/agent-roster", map_error(error)),
    };
    let roster_path = optional_string(&data, "roster").map(PathBuf::from);
    let provider_registry = optional_string(&data, "provider_registry").map(PathBuf::from);
    let agent_pools = optional_string(&data, "agent_pools").map(PathBuf::from);
    let lark_config = optional_string(&data, "lark_config").map(PathBuf::from);
    match timeout(
        Duration::from_millis(1500),
        tokio::task::spawn_blocking(move || {
            let root = resolve_root(raw_root)?;
            agent_roster_status(
                &root,
                roster_path.as_deref(),
                RosterValidationOptions {
                    provider_registry,
                    agent_pools,
                    root: Some(root.clone()),
                    lark_config,
                },
            )
        }),
    )
    .await
    {
        Ok(Ok(Ok(data))) => ok("/agent-roster", data).into_response(),
        Ok(Ok(Err(error))) => fail("/agent-roster", map_error(error)),
        Ok(Err(error)) => fail(
            "/agent-roster",
            HttpApiError::new("runtime_error", format!("agent roster worker failed: {error}")),
        ),
        Err(_) => fail(
            "/agent-roster",
            HttpApiError::new(
                "timeout",
                "agent roster filesystem read timed out; use harvis agent-roster or harvis_agent_roster MCP for local validation",
            )
            .status(StatusCode::GATEWAY_TIMEOUT),
        ),
    }
}

async fn agent_room_live(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-room/live", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let registry_path = optional_string(&data, "provider_registry").map(PathBuf::from);
        let agent_pools = optional_string(&data, "agent_pools").map(PathBuf::from);
        let roster_path = optional_string(&data, "roster").map(PathBuf::from);
        let lark_config = optional_string(&data, "lark_config").map(PathBuf::from);
        Ok(json!({
            "room": list_agent_room(&root, optional_int(&data, "limit", 50, 1, 500)?)?,
            "workspace_state": workspace_state(
                &root,
                optional_string(&data, "topic_id").as_deref(),
                optional_int(&data, "limit", 50, 1, 500)?,
            )?,
            "providers": provider_registry_status(registry_path.as_deref()),
            "agent_roster": agent_roster_status(
                &root,
                roster_path.as_deref(),
                RosterValidationOptions {
                    provider_registry: registry_path.clone(),
                    agent_pools,
                    root: Some(root.clone()),
                    lark_config
                },
            ).ok(),
            "roundtable": {
                "send": "POST /agent-room/send",
                "autochat": "POST /agent-room/autochat",
                "writes": ".harvis/agent-room/messages.jsonl"
            }
        }))
    })
}

async fn agent_room_participants_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-room/participants", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_participants(&root, optional_string(&data, "topic_id").as_deref())
    })
}

async fn agent_room_participant_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/participant", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        object_or_null(&data, "permissions")?;
        Ok((
            upsert_participant(
                &root,
                ParticipantInput {
                    slot_id: require_str(&data, "slot_id", None)?,
                    role: require_str(&data, "role", None)?,
                    display_name: require_str(&data, "display_name", None)?,
                    provider_ref: optional_string(&data, "provider_ref")
                        .or_else(|| optional_string(&data, "provider")),
                    model_ref: optional_string(&data, "model_ref")
                        .or_else(|| optional_string(&data, "model")),
                    harness_ref: optional_string(&data, "harness_ref")
                        .or_else(|| optional_string(&data, "harness")),
                    route_ref: optional_string(&data, "route_ref")
                        .or_else(|| optional_string(&data, "route")),
                    execution_mode: optional_string(&data, "execution_mode"),
                    status: optional_string(&data, "status"),
                    permissions: data
                        .get("permissions")
                        .filter(|value| value.is_object())
                        .cloned(),
                },
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_participant_status_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/participant/status", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            update_participant_status(
                &root,
                &require_str(&data, "slot_id", None)?,
                &require_str(&data, "status", None)?,
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_mailbox_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-room/mailbox", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_mailbox(
            &root,
            optional_string(&data, "topic_id").as_deref(),
            optional_string(&data, "status").as_deref(),
            optional_int(&data, "limit", 50, 1, 500)?,
        )
    })
}

async fn agent_room_mailbox_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/mailbox", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            create_mailbox_item(
                &root,
                MailboxInput {
                    topic_id: optional_string(&data, "topic_id"),
                    from_slot_id: require_str(&data, "from_slot_id", None)?,
                    to_slot_id: require_str(&data, "to_slot_id", None)?,
                    kind: require_str(&data, "kind", Some("request"))?,
                    subject: optional_string(&data, "subject").unwrap_or_default(),
                    content: optional_string(&data, "content").unwrap_or_default(),
                    source_event_id: optional_string(&data, "source_event_id"),
                    task_id: optional_string(&data, "task_id"),
                },
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_mailbox_mark_read_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/mailbox/mark-read", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            mark_mailbox_read(
                &root,
                &require_str(&data, "mail_id", None)?,
                &require_str(&data, "read_by", Some("human"))?,
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_mailbox_wake_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/mailbox/wake", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            wake_mailbox_item(
                &root,
                &require_str(&data, "mail_id", None)?,
                &require_str(&data, "consumer_slot_id", Some("harvis-chair"))?,
                &require_str(&data, "reason", Some("manual_wake"))?,
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_mailbox_consume_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/mailbox/consume", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            consume_mailbox_loop(
                &root,
                &require_str(&data, "consumer_slot_id", Some("harvis-chair"))?,
                optional_string(&data, "topic_id").as_deref(),
                optional_int(&data, "limit", 10, 1, 100)?,
                optional_int(&data, "max_batches", 1, 1, 100)?,
                optional_bool(&data, "dry_run", false)?,
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_tasks_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-room/tasks", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_tasks(
            &root,
            optional_string(&data, "topic_id").as_deref(),
            optional_string(&data, "status").as_deref(),
            optional_int(&data, "limit", 50, 1, 500)?,
        )
    })
}

async fn agent_room_task_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/task", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            create_task(
                &root,
                TaskInput {
                    topic_id: optional_string(&data, "topic_id"),
                    title: require_str(&data, "title", None)?,
                    owner_slot_id: require_str(&data, "owner_slot_id", Some("harvis-chair"))?,
                    status: optional_string(&data, "status"),
                    source_event_id: optional_string(&data, "source_event_id"),
                    approval_id: optional_string(&data, "approval_id"),
                    handoff_id: optional_string(&data, "handoff_id"),
                    run_id: optional_string(&data, "run_id"),
                    packet_id: optional_string(&data, "packet_id"),
                    description: optional_string(&data, "description"),
                    metadata: data
                        .get("metadata")
                        .filter(|value| value.is_object())
                        .cloned(),
                },
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_task_status_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/task/status", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            update_task_status(
                &root,
                &require_str(&data, "task_id", None)?,
                &require_str(&data, "status", None)?,
                optional_string(&data, "note").as_deref().unwrap_or(""),
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_task_link_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/task/link", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            link_task(
                &root,
                TaskLinkInput {
                    task_id: require_str(&data, "task_id", None)?,
                    approval_id: optional_string(&data, "approval_id"),
                    handoff_id: optional_string(&data, "handoff_id"),
                    run_id: optional_string(&data, "run_id"),
                    packet_id: optional_string(&data, "packet_id"),
                    status: optional_string(&data, "status"),
                    note: optional_string(&data, "note"),
                },
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_conversations_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-room/conversations", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_conversations(
            &root,
            optional_string(&data, "transport").as_deref(),
            optional_string(&data, "chat_id").as_deref(),
            optional_string(&data, "sender").as_deref(),
            optional_int(&data, "limit", 50, 1, 500)?,
        )
    })
}

async fn agent_room_conversation_bindings_get(
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    handle_get("/agent-room/conversation-bindings", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_conversation_bindings(&root, optional_int(&data, "limit", 50, 1, 500)?)
    })
}

async fn agent_room_team_harness_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-room/team-harness", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        read_team_harness_state(&root, optional_int(&data, "limit", 50, 1, 500)?)
    })
}

async fn agent_room_workspace_state_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/agent-room/workspace-state", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        workspace_state(
            &root,
            optional_string(&data, "topic_id").as_deref(),
            optional_int(&data, "limit", 50, 1, 500)?,
        )
    })
}

async fn chair_step_post(Json(body): Json<Value>) -> Response {
    handle_post("/chair/step", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            chair_step(ChairStepOptions {
                root,
                topic_id: optional_string(&data, "topic_id"),
                dry_run: optional_bool(&data, "dry_run", true)?,
            })?,
            Vec::new(),
        ))
    })
}

async fn handoffs(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/handoffs", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_handoffs(&root, optional_int(&data, "limit", 50, 1, 500)?)
    })
}

async fn persona(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/persona", query, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        list_persona_state(&root, optional_int(&data, "limit", 100, 1, 500)?)
    })
}

async fn agent_room_init_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/init", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((init_agent_room(&root)?, Vec::new()))
    })
}

async fn agent_room_topic_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/topic", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let created_by =
            optional_string(&data, "created_by").unwrap_or_else(|| "harvis".to_string());
        Ok((
            create_topic(
                &root,
                &require_str(&data, "title", None)?,
                optional_string(&data, "goal").as_deref().unwrap_or(""),
                &created_by,
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_event_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/event", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let agent_id = optional_string(&data, "agent_id").unwrap_or_else(|| "harvis".to_string());
        let role = optional_string(&data, "role").unwrap_or_else(|| "coordinator".to_string());
        let event_type = optional_string(&data, "event_type").unwrap_or_else(|| "note".to_string());
        let content = optional_string(&data, "content").unwrap_or_default();
        let sensitivity =
            optional_string(&data, "sensitivity").unwrap_or_else(|| "internal".to_string());
        Ok((
            add_event(
                &root,
                &require_str(&data, "topic_id", None)?,
                &agent_id,
                &role,
                &event_type,
                &content,
                string_array(&data, "source_refs")?,
                &sensitivity,
                optional_string(&data, "model").as_deref(),
            )?,
            Vec::new(),
        ))
    })
}

async fn agent_room_message_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/message", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let agent_id = optional_string(&data, "agent_id").unwrap_or_else(|| "harvis".to_string());
        let role = optional_string(&data, "role").unwrap_or_else(|| "coordinator".to_string());
        let sensitivity =
            optional_string(&data, "sensitivity").unwrap_or_else(|| "internal".to_string());
        Ok((
            add_message(
                &root,
                &require_str(&data, "topic_id", None)?,
                &agent_id,
                &role,
                &require_str(&data, "content", None)?,
                string_array(&data, "source_refs")?,
                &sensitivity,
                optional_string(&data, "model").as_deref(),
            )?,
            Vec::new(),
        ))
    })
}

#[derive(Debug, Deserialize)]
struct AgentRoomSendRequest {
    root: String,
    prompt: String,
    #[serde(default = "default_model_alias")]
    model_alias: String,
    #[serde(default)]
    raw_prompt: Option<String>,
    #[serde(default)]
    topic_id: Option<String>,
    #[serde(default)]
    provider_registry: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AgentRoomAutochatRequest {
    root: String,
    seed: String,
    #[serde(default)]
    topic_id: Option<String>,
    #[serde(default)]
    provider_registry: Option<String>,
    #[serde(default = "default_rounds")]
    rounds: usize,
}

#[derive(Debug, Deserialize)]
struct AgentRoomStepRequest {
    root: String,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    raw_prompt: Option<String>,
    #[serde(default = "default_model_alias")]
    model_alias: String,
    #[serde(default)]
    topic_id: Option<String>,
    #[serde(default)]
    provider_registry: Option<String>,
    #[serde(default)]
    dry_run: bool,
    #[serde(default)]
    reply_to_event_id: Option<String>,
    #[serde(default)]
    reply_to_agent_id: Option<String>,
    #[serde(default)]
    reply_to_question_id: Option<String>,
    #[serde(default)]
    question_id: Option<String>,
}

#[derive(Debug, Serialize)]
struct RoundtableMessageView {
    id: String,
    event_id: String,
    agent: String,
    agent_id: String,
    alias: String,
    role: String,
    event_kind: String,
    initial: String,
    color: String,
    time: String,
    topic: String,
    question_id: String,
    reply_to_event_id: String,
    reply_to_agent_id: String,
    reply_to_question_id: String,
    route_reason: String,
    tags: Vec<String>,
    note: String,
    content: String,
}

#[derive(Debug)]
struct ModelReply {
    content: String,
    usage: Value,
    stop_reason: Option<String>,
    thinking_blocks: usize,
}

#[derive(Debug, Deserialize)]
struct A2aJsonRpcRequest {
    #[serde(default)]
    id: Value,
    #[serde(default)]
    method: String,
    #[serde(default)]
    params: Value,
}

fn default_model_alias() -> String {
    "d4f".to_string()
}

fn default_rounds() -> usize {
    2
}

async fn agent_room_send_post(Json(body): Json<AgentRoomSendRequest>) -> Response {
    match handle_agent_room_send(body).await {
        Ok(value) => ok("/agent-room/send", value).into_response(),
        Err(error) => fail("/agent-room/send", map_error(error)),
    }
}

async fn agent_room_autochat_post(Json(body): Json<AgentRoomAutochatRequest>) -> Response {
    match handle_agent_room_autochat(body).await {
        Ok(value) => ok("/agent-room/autochat", value).into_response(),
        Err(error) => fail("/agent-room/autochat", map_error(error)),
    }
}

async fn agent_room_step_post(Json(body): Json<AgentRoomStepRequest>) -> Response {
    match handle_agent_room_step(body).await {
        Ok(value) => ok("/agent-room/step", value).into_response(),
        Err(error) => fail("/agent-room/step", map_error(error)),
    }
}

async fn handle_agent_room_send(body: AgentRoomSendRequest) -> Result<Value> {
    let root = resolve_root(body.root.clone())?;
    let prompt = body.prompt.trim();
    if prompt.is_empty() {
        bail!("prompt must be a non-empty string");
    }
    let registry_path = body.provider_registry.as_deref().map(Path::new);
    let routing_text = body.raw_prompt.as_deref().unwrap_or(prompt);
    let route_decision = select_host_route(&body.model_alias, routing_text, registry_path);
    let selected_alias = route_decision["selected_alias"]
        .as_str()
        .unwrap_or(body.model_alias.as_str());
    let route = resolve_model_route(selected_alias, registry_path)?;
    let topic_id = ensure_roundtable_topic(
        &root,
        body.topic_id.as_deref(),
        "H.A.R.V.I.S. live roundtable",
        prompt,
    )?;
    let user_message = add_message(
        &root,
        &topic_id,
        "human",
        "user",
        prompt,
        Vec::new(),
        "internal",
        None,
    )?;
    let route_event = add_event_with_metadata(
        &root,
        &topic_id,
        "harvis",
        "host",
        "status_change",
        &format!("Host routed next turn to {}.", route.alias),
        Vec::new(),
        "internal",
        None,
        route_decision.clone(),
    )?;
    let reply = call_provider(
        &route,
        &format!(
            "You are {} in a H.A.R.V.I.S. Agent Room. Reply in concise Chinese, 1-3 sentences. Do not reveal hidden reasoning.\n\nUser message: {}",
            route.agent, prompt
        ),
        520,
    )
    .await?;
    let agent_message = add_message(
        &root,
        &topic_id,
        &route.alias,
        &route.role,
        &reply.content,
        Vec::new(),
        "internal",
        Some(&route.model),
    )?;
    let view = roundtable_message_view(&route, &topic_id, &agent_message, &reply, "live_reply");
    Ok(json!({
        "topic_id": topic_id,
        "user_message": user_message,
        "agent_message": agent_message,
        "message": view,
        "usage": reply.usage,
        "stop_reason": reply.stop_reason,
        "thinking_blocks": reply.thinking_blocks,
        "route": route_decision,
        "route_event": route_event,
        "provider_registry": {
            "includesSecrets": false
        }
    }))
}

async fn handle_agent_room_step(body: AgentRoomStepRequest) -> Result<Value> {
    let root = resolve_root(body.root.clone())?;
    // T308: the step now consumes the three-tier speaker selector
    // (round_robin default / llm via provider registry / custom_function)
    // implemented in harvis-runtime::speaker. The runtime is synchronous, so
    // the whole step runs on the blocking pool; provider calls inside the
    // step go through call_provider_sync, the blocking twin of call_provider
    // that shares the same provider-registry routes and response parsing.
    let options = SpeakerStepOptions {
        root,
        topic_id: body.topic_id.clone(),
        prompt: body.prompt.clone(),
        raw_prompt: body.raw_prompt.clone(),
        question_id: body.question_id.clone(),
        dry_run: body.dry_run,
        provider_registry: body.provider_registry.as_deref().map(PathBuf::from),
        selector_override: None,
        model_alias: Some(body.model_alias.clone()),
        reply_to_event_id: body.reply_to_event_id.clone(),
        reply_to_agent_id: body.reply_to_agent_id.clone(),
        reply_to_question_id: body.reply_to_question_id.clone(),
    };
    tokio::task::spawn_blocking(move || {
        let mut llm = |request: &LlmCallRequest| call_provider_sync(request);
        agent_room_speaker_step(&options, &mut llm)
    })
    .await
    .context("speaker step blocking task failed to join")?
}

fn call_provider_sync(request: &LlmCallRequest) -> Result<LlmCallResponse> {
    let route = &request.route;
    match route.provider_kind.as_str() {
        "anthropic-compatible" => {
            call_anthropic_compatible_sync(route, &request.prompt, request.max_tokens)
        }
        "openai-compatible" => {
            call_openai_compatible_sync(route, &request.prompt, request.max_tokens)
        }
        "openai-responses" => {
            call_openai_responses_sync(route, &request.prompt, request.max_tokens)
        }
        other => bail!("provider kind is not supported for speaker step yet: {other}"),
    }
}

fn call_anthropic_compatible_sync(
    route: &ResolvedModelRoute,
    prompt: &str,
    max_tokens: usize,
) -> Result<LlmCallResponse> {
    let endpoint = format!("{}/v1/messages", route.base_url.trim_end_matches('/'));
    let response = reqwest::blocking::Client::new()
        .post(endpoint)
        .header("content-type", "application/json")
        .header("anthropic-version", "2023-06-01")
        .header("x-api-key", &route.auth_token)
        .json(&json!({
            "model": route.model,
            "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt}]
        }))
        .send()
        .with_context(|| format!("provider request failed for {}", route.alias))?;
    let status = response.status();
    let payload: Value = response
        .json()
        .with_context(|| format!("provider returned invalid json for {}", route.alias))?;
    let content = text_from_provider_content(payload.get("content")).unwrap_or_default();
    if !status.is_success() || content.trim().is_empty() {
        let message = payload
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .or_else(|| payload.get("message").and_then(Value::as_str))
            .unwrap_or("provider returned no visible text");
        bail!("{}: {}", route.alias, message);
    }
    Ok(LlmCallResponse {
        text: content,
        usage: payload.get("usage").cloned().unwrap_or_else(|| json!({})),
        stop_reason: payload
            .get("stop_reason")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    })
}

fn call_openai_compatible_sync(
    route: &ResolvedModelRoute,
    prompt: &str,
    max_tokens: usize,
) -> Result<LlmCallResponse> {
    let endpoint = format!("{}/chat/completions", route.base_url.trim_end_matches('/'));
    let response = reqwest::blocking::Client::new()
        .post(endpoint)
        .bearer_auth(&route.auth_token)
        .json(&json!({
            "model": route.model,
            "max_tokens": max_tokens,
            "messages": [
                {"role": "system", "content": "You are a participant in a H.A.R.V.I.S. Agent Room. Reply with visible, concise Chinese only. Do not reveal hidden reasoning."},
                {"role": "user", "content": prompt}
            ]
        }))
        .send()
        .with_context(|| format!("provider request failed for {}", route.alias))?;
    let status = response.status();
    let payload: Value = response
        .json()
        .with_context(|| format!("provider returned invalid json for {}", route.alias))?;
    let content = text_from_openai_content(&payload).unwrap_or_default();
    if !status.is_success() || content.trim().is_empty() {
        let message = payload
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .or_else(|| payload.get("message").and_then(Value::as_str))
            .unwrap_or("provider returned no visible text");
        bail!("{}: {}", route.alias, message);
    }
    Ok(LlmCallResponse {
        text: content,
        usage: payload.get("usage").cloned().unwrap_or_else(|| json!({})),
        stop_reason: payload
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first())
            .and_then(|choice| choice.get("finish_reason"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    })
}

fn call_openai_responses_sync(
    route: &ResolvedModelRoute,
    prompt: &str,
    max_tokens: usize,
) -> Result<LlmCallResponse> {
    let endpoint = format!("{}/responses", normalize_openai_base_url(&route.base_url));
    let response = reqwest::blocking::Client::new()
        .post(endpoint)
        .bearer_auth(&route.auth_token)
        .json(&json!({
            "model": route.model,
            "input": prompt,
            "max_output_tokens": max_tokens
        }))
        .send()
        .with_context(|| format!("provider request failed for {}", route.alias))?;
    let status = response.status();
    let payload: Value = response
        .json()
        .with_context(|| format!("provider returned invalid json for {}", route.alias))?;
    let content = text_from_openai_responses_content(&payload).unwrap_or_default();
    if !status.is_success() || content.trim().is_empty() {
        let message = payload
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .or_else(|| payload.get("message").and_then(Value::as_str))
            .unwrap_or("provider returned no visible text");
        bail!("{}: {}", route.alias, message);
    }
    Ok(LlmCallResponse {
        text: content,
        usage: payload.get("usage").cloned().unwrap_or_else(|| json!({})),
        stop_reason: payload
            .get("status")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    })
}

async fn handle_agent_room_autochat(body: AgentRoomAutochatRequest) -> Result<Value> {
    let root = resolve_root(body.root)?;
    let seed = body.seed.trim();
    if seed.is_empty() {
        bail!("seed must be a non-empty string");
    }
    let rounds = body.rounds.clamp(1, 3);
    let registry_path = body.provider_registry.as_deref().map(Path::new);
    let first = resolve_model_route("d4f", registry_path)?;
    let second = resolve_model_route("d4p", registry_path)?;
    let topic_id = ensure_roundtable_topic(
        &root,
        body.topic_id.as_deref(),
        "H.A.R.V.I.S. autonomous roundtable",
        seed,
    )?;
    add_message(
        &root,
        &topic_id,
        "harvis",
        "coordinator",
        seed,
        Vec::new(),
        "internal",
        None,
    )?;

    let mut visible_turns: Vec<(String, String)> = Vec::new();
    let mut views = Vec::new();
    let mut errors = Vec::new();
    let order = [&first, &second];
    for index in 0..(rounds * order.len()) {
        let route = order[index % order.len()];
        let other = order[(index + 1) % order.len()];
        let route_decision = json!({
            "policy": "harvis.host.v0.50",
            "selected_alias": route.alias,
            "selected_agent": route.agent,
            "reason": if index == 0 {
                "start with planner route for initial proposal"
            } else if route.role.contains("review") {
                "reviewer route follows a proposal and checks risk"
            } else {
                "planner route follows review and sharpens next step"
            },
            "signals": {
                "explicit_mention": Value::Null,
                "role_fit": route.role,
                "turn_index": index + 1,
                "requires_approval_for_mutation": true
            }
        });
        add_event_with_metadata(
            &root,
            &topic_id,
            "harvis",
            "host",
            "status_change",
            &format!("Host routed auto turn {} to {}.", index + 1, route.alias),
            Vec::new(),
            "internal",
            None,
            route_decision.clone(),
        )?;
        let prior = visible_turns
            .iter()
            .map(|(alias, content)| format!("{alias}: {content}"))
            .collect::<Vec<_>>()
            .join("\n");
        let prompt = format!(
            "You are {} ({}) in an autonomous H.A.R.V.I.S. roundtable with {}.\nSpeak in concise Chinese. Use one complete chat-style message under 70 Chinese characters. Do not reveal hidden reasoning.\n{}\n\nRoundtable seed:\n{}\n{}\n",
            route.agent,
            route.role,
            other.agent,
            if route.alias == "d4f" {
                "Your job: propose the next useful step and ask the reviewer a concrete question."
            } else {
                "Your job: review the last proposal, name the main risk, and hand back one sharper next step."
            },
            seed,
            if prior.is_empty() {
                String::new()
            } else {
                format!("Autonomous turns so far:\n{prior}")
            }
        );
        let reply = match call_provider(route, &prompt, 520).await {
            Ok(reply) => reply,
            Err(error) => {
                let blocked_content = format!(
                    "Auto roundtable paused at turn {} for {}: {}",
                    index + 1,
                    route.alias,
                    error
                );
                let blocked_message = add_message(
                    &root,
                    &topic_id,
                    "harvis",
                    "coordinator",
                    &blocked_content,
                    Vec::new(),
                    "internal",
                    None,
                )?;
                views.push(system_roundtable_message_view(
                    &topic_id,
                    &blocked_message,
                    "auto_roundtable_partial",
                ));
                errors.push(json!({
                    "turn": index + 1,
                    "alias": route.alias,
                    "message": error.to_string()
                }));
                break;
            }
        };
        let message = add_message(
            &root,
            &topic_id,
            &route.alias,
            &route.role,
            &reply.content,
            Vec::new(),
            "internal",
            Some(&route.model),
        )?;
        visible_turns.push((route.alias.clone(), reply.content.clone()));
        let mut view = roundtable_message_view(
            route,
            &topic_id,
            &message,
            &reply,
            &format!("auto_turn_{}", index + 1),
        );
        view.note = format!(
            "{} Host route: {}",
            view.note,
            route_decision["reason"]
                .as_str()
                .unwrap_or("selected by host policy")
        );
        views.push(view);
    }
    let mut decision_record = Value::Null;
    if errors.is_empty() {
        decision_record = add_event_with_metadata(
            &root,
            &topic_id,
            "harvis",
            "host",
            "decision_record",
            "Auto roundtable completed its planned turns and preserved the transcript for human review.",
            Vec::new(),
            "internal",
            None,
            json!({
                "policy": "harvis.host.v0.50",
                "turns": views.len(),
                "requires_human_review_before_execution": true
            }),
        )?;
    }
    Ok(json!({
        "topic_id": topic_id,
        "seed": seed,
        "turns": views.len(),
        "status": if errors.is_empty() { "complete" } else { "partial" },
        "errors": errors,
        "messages": views,
        "decision_record": decision_record,
        "provider_registry": {
            "includesSecrets": false
        }
    }))
}

fn ensure_roundtable_topic(
    root: &Path,
    topic_id: Option<&str>,
    title: &str,
    goal: &str,
) -> Result<String> {
    if let Some(topic_id) = topic_id.map(str::trim).filter(|value| !value.is_empty()) {
        return Ok(topic_id.to_string());
    }
    let topic = create_topic(root, title, goal, "harvis")?;
    Ok(topic["topic_id"].as_str().unwrap_or_default().to_string())
}

fn select_host_route(
    requested_alias: &str,
    routing_text: &str,
    registry_path: Option<&Path>,
) -> Value {
    let requested_alias = requested_alias.trim();
    let requested_alias = if requested_alias.is_empty() {
        "d4f"
    } else {
        requested_alias
    };
    let lower = routing_text.to_lowercase();
    let mut selected_alias = requested_alias.to_string();
    let mut explicit_mention = Value::Null;
    let mut reason = "selected from composer model_alias".to_string();

    if let Ok(registry) = load_provider_registry(registry_path) {
        for (alias, route) in registry.models {
            let agent = route.agent.unwrap_or_else(|| route.model.clone());
            let alias_mention = format!("@{}", alias.to_lowercase());
            let agent_mention = format!("@{}", agent.to_lowercase());
            if lower.contains(&alias_mention) || lower.contains(&agent_mention) {
                selected_alias = alias.clone();
                explicit_mention = json!({
                    "alias": alias,
                    "agent": agent
                });
                reason = "explicit @agent mention in room message".to_string();
                break;
            }
        }
    }

    json!({
        "policy": "harvis.host.v0.50",
        "selected_alias": selected_alias,
        "reason": reason,
        "signals": {
            "explicit_mention": explicit_mention,
            "requested_alias": requested_alias,
            "role_fit": "composer-selected provider route",
            "unanswered_question": lower.contains("?") || lower.contains("？"),
            "requires_approval_for_mutation": true
        },
        "authority": {
            "executes_files": false,
            "executes_commands": false,
            "requires_handoff_for_mutation": true
        }
    })
}

async fn a2a_agent_card(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    let base_url = query
        .get("base_url")
        .cloned()
        .unwrap_or(state.public_base_url);
    Json(build_a2a_agent_card(&base_url))
}

async fn a2a_jsonrpc_post(Json(body): Json<A2aJsonRpcRequest>) -> Json<Value> {
    let id = body.id.clone();
    let method = body.method.as_str();
    // LF A2A 1.0.0 §5.3: PascalCase JSON-RPC method names are canonical.
    // Legacy slash/camelCase aliases are kept as documented local extensions.
    let result = match method {
        "SendMessage" | "message/send" | "sendMessage" => handle_a2a_send(&body.params).await,
        "SendStreamingMessage" | "message/stream" | "sendMessageStream" => {
            Err(A2aError::unsupported_operation(
                "streaming is not supported by this agent (AgentCard capabilities.streaming = false)",
            ))
        }
        "GetTask" | "tasks/get" | "getTask" => handle_a2a_get_task(&body.params).await,
        "CancelTask" | "tasks/cancel" | "cancelTask" => {
            handle_a2a_cancel_task(&body.params).await
        }
        "SubscribeToTask" | "tasks/resubscribe" => Err(A2aError::unsupported_operation(
            "streaming is not supported by this agent (AgentCard capabilities.streaming = false)",
        )),
        "CreateTaskPushNotificationConfig"
        | "GetTaskPushNotificationConfig"
        | "ListTaskPushNotificationConfigs"
        | "DeleteTaskPushNotificationConfig"
        | "tasks/pushNotificationConfig/set"
        | "tasks/pushNotificationConfig/get" => {
            Err(A2aError::push_notification_not_supported(
                "push notifications are not supported by this agent (AgentCard capabilities.pushNotifications = false)",
            ))
        }
        "GetExtendedAgentCard" | "agent/getAuthenticatedExtendedCard" => {
            Err(A2aError::unsupported_operation(
                "extended agent card is not supported by this agent",
            ))
        }
        _ => Err(A2aError::method_not_found(format!(
            "method not found: {method}"
        ))),
    };
    match result {
        Ok(value) => Json(json!({"jsonrpc": "2.0", "id": id, "result": value})),
        Err(error) => Json(error.jsonrpc_body(&id)),
    }
}

async fn a2a_message_send_post(Json(body): Json<Value>) -> Response {
    match handle_a2a_send(&body).await {
        Ok(task) => a2a_rest_response(StatusCode::OK, json!({"task": task})),
        Err(error) => error.rest_response(),
    }
}

async fn a2a_message_stream_post(Json(_body): Json<Value>) -> Response {
    // LF A2A 1.0.0 §3.3.4: capabilities.streaming is false, so streaming
    // requests MUST fail with UnsupportedOperationError.
    A2aError::unsupported_operation(
        "streaming is not supported by this agent (AgentCard capabilities.streaming = false)",
    )
    .rest_response()
}

async fn a2a_task_cancel_post(
    AxumPath(task_id): AxumPath<String>,
    Query(query): Query<HashMap<String, String>>,
    Json(body): Json<Value>,
) -> Response {
    let task_id = task_id
        .strip_suffix(":cancel")
        .unwrap_or(task_id.as_str())
        .to_string();
    let mut params = body.as_object().cloned().unwrap_or_default();
    params.insert("id".to_string(), json!(task_id));
    if !params.contains_key("root") {
        params.insert(
            "root".to_string(),
            json!(query.get("root").cloned().unwrap_or_default()),
        );
    }
    match handle_a2a_cancel_task(&Value::Object(params)).await {
        Ok(task) => a2a_rest_response(StatusCode::OK, task),
        Err(error) => error.rest_response(),
    }
}

/// LF A2A 1.0.0 AgentCard (§4.4.1 + §8). `supportedInterfaces` is the canonical
/// protocol declaration (first entry = preferred). The top-level
/// `url`/`preferredTransport`/`protocolVersion` fields are pre-1.0 legacy
/// aliases kept for older local clients (documented extension, T312).
fn build_a2a_agent_card(base_url: &str) -> Value {
    let root = base_url.trim_end_matches('/');
    json!({
        "name": "H.A.R.V.I.S.",
        "description": "Local-first Agent Room, Roundtable, host routing, and audited handoff runtime.",
        "version": API_VERSION,
        "supportedInterfaces": [
            {
                "url": format!("{root}/a2a/jsonrpc"),
                "protocolBinding": "JSONRPC",
                "protocolVersion": A2A_PROTOCOL_VERSION
            },
            {
                "url": format!("{root}/a2a"),
                "protocolBinding": "HTTP+JSON",
                "protocolVersion": A2A_PROTOCOL_VERSION
            }
        ],
        "capabilities": {
            "streaming": false,
            "pushNotifications": false,
            "stateTransitionHistory": true
        },
        "defaultInputModes": ["text"],
        "defaultOutputModes": ["text"],
        "skills": [
            {
                "id": "harvis.agent-room.delegate",
                "name": "Delegate to H.A.R.V.I.S. Agent Room",
                "description": "Create a local Agent Room topic, route it through H.A.R.V.I.S. host policy, and expose transcript-backed task state.",
                "tags": ["agent-room", "roundtable", "local-first", "handoff"],
                "inputModes": ["text"],
                "outputModes": ["text"]
            }
        ],
        "securitySchemes": {},
        "securityRequirements": [],
        "url": format!("{root}/a2a/jsonrpc"),
        "preferredTransport": "JSONRPC",
        "protocolVersion": A2A_PROTOCOL_VERSION
    })
}

/// A2A protocol version declared on every supported interface (LF A2A §3.6:
/// Major.Minor only, no patch component).
const A2A_PROTOCOL_VERSION: &str = "1.0";
/// LF A2A 1.0.0 §11.6: ErrorInfo domain for A2A-specific errors.
const A2A_ERROR_DOMAIN: &str = "a2a-protocol.org";

/// A2A error carrying the canonical cross-binding mapping (LF A2A 1.0.0
/// §3.3.2 error model, §5.4 code mappings, §9.5 JSON-RPC shape, §11.6
/// HTTP+JSON google.rpc.Status shape).
#[derive(Debug)]
struct A2aError {
    /// JSON-RPC error code (§5.4).
    code: i64,
    /// HTTP status for the REST binding (§5.4).
    http: StatusCode,
    /// gRPC-style status name used in REST error bodies (§11.6).
    grpc_status: &'static str,
    /// UPPER_SNAKE ErrorInfo reason for A2A-specific errors (§11.6).
    reason: Option<&'static str>,
    message: String,
}

impl A2aError {
    fn a2a_specific(
        code: i64,
        http: StatusCode,
        grpc_status: &'static str,
        reason: &'static str,
        message: impl Into<String>,
    ) -> Self {
        Self {
            code,
            http,
            grpc_status,
            reason: Some(reason),
            message: message.into(),
        }
    }

    fn standard(
        code: i64,
        http: StatusCode,
        grpc_status: &'static str,
        message: impl Into<String>,
    ) -> Self {
        Self {
            code,
            http,
            grpc_status,
            reason: None,
            message: message.into(),
        }
    }

    fn task_not_found(message: impl Into<String>) -> Self {
        Self::a2a_specific(
            -32001,
            StatusCode::NOT_FOUND,
            "NOT_FOUND",
            "TASK_NOT_FOUND",
            message,
        )
    }

    fn task_not_cancelable(message: impl Into<String>) -> Self {
        Self::a2a_specific(
            -32002,
            StatusCode::BAD_REQUEST,
            "FAILED_PRECONDITION",
            "TASK_NOT_CANCELABLE",
            message,
        )
    }

    fn push_notification_not_supported(message: impl Into<String>) -> Self {
        Self::a2a_specific(
            -32003,
            StatusCode::BAD_REQUEST,
            "FAILED_PRECONDITION",
            "PUSH_NOTIFICATION_NOT_SUPPORTED",
            message,
        )
    }

    fn unsupported_operation(message: impl Into<String>) -> Self {
        Self::a2a_specific(
            -32004,
            StatusCode::BAD_REQUEST,
            "FAILED_PRECONDITION",
            "UNSUPPORTED_OPERATION",
            message,
        )
    }

    fn content_type_not_supported(message: impl Into<String>) -> Self {
        Self::a2a_specific(
            -32005,
            StatusCode::BAD_REQUEST,
            "INVALID_ARGUMENT",
            "CONTENT_TYPE_NOT_SUPPORTED",
            message,
        )
    }

    fn invalid_params(message: impl Into<String>) -> Self {
        Self::standard(-32602, StatusCode::BAD_REQUEST, "INVALID_ARGUMENT", message)
    }

    fn method_not_found(message: impl Into<String>) -> Self {
        Self::standard(-32601, StatusCode::BAD_REQUEST, "INVALID_ARGUMENT", message)
    }

    fn internal(message: impl Into<String>) -> Self {
        Self::standard(
            -32603,
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            message,
        )
    }

    fn error_info(&self) -> Option<Value> {
        self.reason.map(|reason| {
            json!({
                "@type": "type.googleapis.com/google.rpc.ErrorInfo",
                "reason": reason,
                "domain": A2A_ERROR_DOMAIN
            })
        })
    }

    /// JSON-RPC binding error response body (§9.5).
    fn jsonrpc_body(&self, id: &Value) -> Value {
        let mut error = json!({"code": self.code, "message": self.message});
        if let Some(info) = self.error_info() {
            error["data"] = json!([info]);
        }
        json!({"jsonrpc": "2.0", "id": id, "error": error})
    }

    /// HTTP+JSON binding error response (§11.6 google.rpc.Status JSON).
    fn rest_response(&self) -> Response {
        let details = self.error_info().into_iter().collect::<Vec<_>>();
        a2a_rest_response(
            self.http,
            json!({
                "error": {
                    "code": i64::from(self.http.as_u16()),
                    "status": self.grpc_status,
                    "message": self.message,
                    "details": details
                }
            }),
        )
    }
}

impl From<anyhow::Error> for A2aError {
    fn from(error: anyhow::Error) -> Self {
        Self::internal(error.to_string())
    }
}

/// HTTP+JSON binding responses SHOULD use application/a2a+json (§11.1).
fn a2a_rest_response(status: StatusCode, body: Value) -> Response {
    (
        status,
        [(
            axum::http::header::CONTENT_TYPE,
            "application/a2a+json; charset=utf-8",
        )],
        body.to_string(),
    )
        .into_response()
}

/// A2A §5.6: timestamps are ISO 8601 UTC with a 'Z' suffix.
fn a2a_timestamp(raw: &Value) -> Value {
    raw.as_str()
        .map(|value| value.replace("+00:00", "Z"))
        .map(Value::from)
        .unwrap_or(Value::Null)
}

async fn handle_a2a_send(params: &Value) -> std::result::Result<Value, A2aError> {
    let root = extract_a2a_root(params)
        .and_then(|raw| resolve_root(raw))
        .map_err(|error| A2aError::invalid_params(error.to_string()))?;
    reject_unsupported_parts(params)?;
    let text = extract_a2a_text(params);
    if text.trim().is_empty() {
        return Err(A2aError::invalid_params("A2A message text is required"));
    }
    // LF A2A 1.0.0 §3.4.2: a client-provided taskId MUST reference an existing
    // task; §3.4.3: mismatching contextId/taskId pairs MUST be rejected.
    let requested_task_id = find_nested_str(
        params,
        &[
            &["message", "taskId"],
            &["message", "task_id"],
            &["taskId"],
            &["task_id"],
        ],
    )
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .map(ToOwned::to_owned);
    if let Some(task_id) = requested_task_id {
        if let Some(context_id) = extract_a2a_context_id(params)
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            if context_id != task_id {
                return Err(A2aError::invalid_params(format!(
                    "contextId {context_id} does not match taskId {task_id}"
                )));
            }
        }
        let existing = a2a_task_from_room(&root, &task_id)?;
        let state = existing["status"]["state"].as_str().unwrap_or_default();
        if matches!(
            state,
            "TASK_STATE_COMPLETED"
                | "TASK_STATE_FAILED"
                | "TASK_STATE_CANCELED"
                | "TASK_STATE_REJECTED"
        ) {
            return Err(A2aError::unsupported_operation(format!(
                "task {task_id} is in terminal state {state} and cannot accept further messages"
            )));
        }
        add_message(
            &root,
            &task_id,
            "a2a_client",
            "external_agent",
            &text,
            Vec::new(),
            "internal",
            None,
        )?;
        add_event_with_metadata(
            &root,
            &task_id,
            "harvis",
            "host",
            "status_change",
            "Follow-up A2A message recorded on existing task.",
            Vec::new(),
            "internal",
            None,
            json!({
                "a2a_status": "submitted",
                "message_id": extract_a2a_message_id(params),
                "context_id": extract_a2a_context_id(params),
                "actor": "a2a_client",
                "multi_turn": true,
                "approval_policy": "mutation requires explicit handoff or approval"
            }),
        )?;
        return a2a_task_from_room(&root, &task_id);
    }
    let title = format!("A2A: {}", short_text(&text, 70));
    let topic = create_topic(&root, &title, &text, "a2a_client")?;
    let topic_id = topic["topic_id"]
        .as_str()
        .context("created topic missing topic_id")?
        .to_string();
    add_message(
        &root,
        &topic_id,
        "a2a_client",
        "external_agent",
        &text,
        Vec::new(),
        "internal",
        None,
    )?;
    add_event_with_metadata(
        &root,
        &topic_id,
        "harvis",
        "host",
        "status_change",
        "Inbound A2A task accepted and mapped into H.A.R.V.I.S. Agent Room.",
        Vec::new(),
        "internal",
        None,
        json!({
            "a2a_status": "submitted",
            "message_id": extract_a2a_message_id(params),
            "context_id": extract_a2a_context_id(params),
            "actor": "a2a_client",
            "approval_policy": "mutation requires explicit handoff or approval"
        }),
    )?;
    a2a_task_from_room(&root, &topic_id)
}

/// LF A2A 1.0.0 §3.1.1: media types outside the agent's declared input modes
/// (text only) MUST fail with ContentTypeNotSupportedError.
fn reject_unsupported_parts(params: &Value) -> std::result::Result<(), A2aError> {
    for path in [&["message", "parts"][..], &["parts"][..]] {
        if let Some(parts) = get_nested(params, path).and_then(Value::as_array) {
            for part in parts {
                if part.is_string() {
                    continue;
                }
                if let Some(object) = part.as_object() {
                    if object.contains_key("text") {
                        continue;
                    }
                    return Err(A2aError::content_type_not_supported(
                        "only text parts are supported (defaultInputModes: [\"text\"])",
                    ));
                }
            }
        }
    }
    Ok(())
}

async fn handle_a2a_get_task(params: &Value) -> std::result::Result<Value, A2aError> {
    let root = extract_a2a_root(params)
        .and_then(|raw| resolve_root(raw))
        .map_err(|error| A2aError::invalid_params(error.to_string()))?;
    let task_id =
        extract_a2a_task_id(params).map_err(|error| A2aError::invalid_params(error.to_string()))?;
    a2a_task_from_room(&root, &task_id)
}

async fn handle_a2a_cancel_task(params: &Value) -> std::result::Result<Value, A2aError> {
    let root = extract_a2a_root(params)
        .and_then(|raw| resolve_root(raw))
        .map_err(|error| A2aError::invalid_params(error.to_string()))?;
    let task_id =
        extract_a2a_task_id(params).map_err(|error| A2aError::invalid_params(error.to_string()))?;
    let task = a2a_task_from_room(&root, &task_id)?;
    let state = task["status"]["state"].as_str().unwrap_or_default();
    // LF A2A 1.0.0 §3.1.5: tasks in a terminal state are not cancelable.
    if matches!(
        state,
        "TASK_STATE_COMPLETED" | "TASK_STATE_FAILED" | "TASK_STATE_REJECTED"
    ) {
        return Err(A2aError::task_not_cancelable(format!(
            "task {task_id} is in terminal state {state}"
        )));
    }
    // §3.3.1: cancellation is idempotent; an already-canceled task returns its
    // current state without writing duplicate events.
    if state == "TASK_STATE_CANCELED" {
        return Ok(task);
    }
    add_event_with_metadata(
        &root,
        &task_id,
        "a2a_adapter",
        "gateway",
        "status_change",
        "A2A task canceled by external caller.",
        Vec::new(),
        "internal",
        None,
        json!({
            "a2a_status": "canceled",
            "approval_policy": "record-only cancel; no file mutation"
        }),
    )?;
    a2a_task_from_room(&root, &task_id)
}

fn a2a_task_from_room(root: &Path, topic_id: &str) -> std::result::Result<Value, A2aError> {
    let room = list_agent_room(root, 500)?;
    let topic = room
        .get("topics")
        .and_then(Value::as_array)
        .and_then(|topics| {
            topics
                .iter()
                .find(|topic| topic.get("topic_id").and_then(Value::as_str) == Some(topic_id))
        })
        .cloned()
        .ok_or_else(|| A2aError::task_not_found(format!("task not found: {topic_id}")))?;
    let events = room
        .get("events")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|event| event.get("topic_id").and_then(Value::as_str) == Some(topic_id))
        .collect::<Vec<_>>();
    let messages = room
        .get("messages")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|message| message.get("topic_id").and_then(Value::as_str) == Some(topic_id))
        .collect::<Vec<_>>();
    let state = a2a_state_for_topic(&topic, &events, &messages);
    let history = messages.iter().map(a2a_history_message).collect::<Vec<_>>();
    let status_timestamp = events
        .last()
        .and_then(|event| event.get("created_at").cloned())
        .map(|raw| a2a_timestamp(&raw))
        .unwrap_or(Value::Null);
    Ok(json!({
        "kind": "task",
        "id": topic_id,
        "contextId": topic_id,
        "status": {
            "state": state,
            "message": {
                "kind": "message",
                "role": "ROLE_AGENT",
                "parts": [{"text": format!("H.A.R.V.I.S. Agent Room state: {state}")}]
            },
            "timestamp": status_timestamp
        },
        "history": history,
        "artifacts": latest_a2a_artifacts(&events),
        "metadata": {
            "source": "harvis",
            "agent_room_protocol": AGENT_ROOM_PROTOCOL_ID,
            "topic": topic,
            "event_count": events.len(),
            "message_count": messages.len(),
            "approval_policy": "mutations require explicit H.A.R.V.I.S. approval or handoff"
        }
    }))
}

fn latest_a2a_artifacts(events: &[Value]) -> Vec<Value> {
    events
        .iter()
        .rev()
        .filter(|event| {
            matches!(
                event.get("event_kind").and_then(Value::as_str),
                Some("final_report" | "decision_record" | "handoff_note")
            )
        })
        .take(3)
        .map(|event| {
            json!({
                "artifactId": event.get("event_id").cloned().unwrap_or(Value::Null),
                "name": event.get("event_kind").cloned().unwrap_or_else(|| json!("agent_room_event")),
                "parts": [{"text": event.get("content").and_then(Value::as_str).unwrap_or(""), "mediaType": "text/plain"}],
                "metadata": {
                    "source": "harvis",
                    "event_type": event.get("event_type").cloned().unwrap_or(Value::Null)
                }
            })
        })
        .collect()
}

/// LF A2A 1.0.0 §4.1.3 TaskState (ProtoJSON SCREAMING_SNAKE form, §5.5) mapped
/// onto local Agent Room signals. The authoritative mapping table lives in the
/// digital_me spec appendix (T312):
///
/// | A2A state                 | local signal                                             |
/// |---------------------------|----------------------------------------------------------|
/// | TASK_STATE_SUBMITTED      | task accepted (send) with no room execution yet          |
/// | TASK_STATE_WORKING        | latest a2a_status=working, or agent-side room messages   |
/// | TASK_STATE_INPUT_REQUIRED | topic status "blocked"                                   |
/// | TASK_STATE_COMPLETED      | topic status "done" or any final_report event            |
/// | TASK_STATE_FAILED         | topic status "failed" (reserved; no current writer)      |
/// | TASK_STATE_CANCELED       | any event with metadata a2a_status="canceled"            |
fn a2a_state_for_topic(topic: &Value, events: &[Value], messages: &[Value]) -> &'static str {
    if events.iter().any(|event| {
        event
            .get("metadata")
            .and_then(|metadata| metadata.get("a2a_status"))
            .and_then(Value::as_str)
            == Some("canceled")
    }) {
        return "TASK_STATE_CANCELED";
    }
    if topic.get("status").and_then(Value::as_str) == Some("done")
        || events
            .iter()
            .any(|event| event.get("event_kind").and_then(Value::as_str) == Some("final_report"))
    {
        return "TASK_STATE_COMPLETED";
    }
    if topic.get("status").and_then(Value::as_str) == Some("blocked") {
        return "TASK_STATE_INPUT_REQUIRED";
    }
    if topic.get("status").and_then(Value::as_str) == Some("failed") {
        return "TASK_STATE_FAILED";
    }
    let latest_a2a_status = events.iter().rev().find_map(|event| {
        event
            .get("metadata")
            .and_then(|metadata| metadata.get("a2a_status"))
            .and_then(Value::as_str)
    });
    let room_produced_agent_output = messages
        .iter()
        .any(|message| message.get("agent_id").and_then(Value::as_str) != Some("a2a_client"));
    if latest_a2a_status == Some("working") || room_produced_agent_output {
        return "TASK_STATE_WORKING";
    }
    "TASK_STATE_SUBMITTED"
}

fn a2a_history_message(message: &Value) -> Value {
    let role = if message.get("agent_id").and_then(Value::as_str) == Some("a2a_client")
        || message.get("role").and_then(Value::as_str) == Some("user")
    {
        "ROLE_USER"
    } else {
        "ROLE_AGENT"
    };
    json!({
        "kind": "message",
        "messageId": message.get("message_id").cloned().unwrap_or(Value::Null),
        "role": role,
        "parts": [{
            "text": message.get("content").and_then(Value::as_str).unwrap_or(""),
            "mediaType": "text/plain"
        }],
        "metadata": {
            "source": "harvis",
            "agent_id": message.get("agent_id").cloned().unwrap_or(Value::Null),
            "role": message.get("role").cloned().unwrap_or(Value::Null),
            "timestamp": message.get("created_at").cloned().unwrap_or(Value::Null)
        }
    })
}

fn extract_a2a_root(params: &Value) -> Result<String> {
    find_nested_str(
        params,
        &[
            &["root"],
            &["metadata", "root"],
            &["message", "metadata", "root"],
            &["params", "root"],
        ],
    )
    .map(ToOwned::to_owned)
    .filter(|value| !value.trim().is_empty())
    .context("A2A request requires root in params.root or metadata.root")
}

fn extract_a2a_task_id(params: &Value) -> Result<String> {
    find_nested_str(
        params,
        &[
            &["id"],
            &["taskId"],
            &["task_id"],
            &["task", "id"],
            &["task", "task_id"],
        ],
    )
    .map(ToOwned::to_owned)
    .filter(|value| !value.trim().is_empty())
    .context("A2A task id is required")
}

fn extract_a2a_message_id(params: &Value) -> Value {
    find_nested_str(
        params,
        &[
            &["messageId"],
            &["message_id"],
            &["message", "messageId"],
            &["message", "message_id"],
        ],
    )
    .map(|value| json!(value))
    .unwrap_or(Value::Null)
}

fn extract_a2a_context_id(params: &Value) -> Value {
    find_nested_str(
        params,
        &[
            &["contextId"],
            &["context_id"],
            &["message", "contextId"],
            &["message", "context_id"],
        ],
    )
    .map(|value| json!(value))
    .unwrap_or(Value::Null)
}

fn extract_a2a_text(params: &Value) -> String {
    if let Some(value) = find_nested_str(
        params,
        &[
            &["text"],
            &["content"],
            &["message", "text"],
            &["message", "content"],
        ],
    ) {
        return value.trim().to_string();
    }
    for path in [&["parts"][..], &["message", "parts"][..], &["content"][..]] {
        if let Some(parts) = get_nested(params, path).and_then(Value::as_array) {
            let text = parts
                .iter()
                .filter_map(|part| {
                    part.as_str()
                        .or_else(|| part.get("text").and_then(Value::as_str))
                        .or_else(|| part.get("value").and_then(Value::as_str))
                })
                .collect::<Vec<_>>()
                .join("\n");
            if !text.trim().is_empty() {
                return text.trim().to_string();
            }
        }
    }
    String::new()
}

fn find_nested_str<'a>(value: &'a Value, paths: &[&[&str]]) -> Option<&'a str> {
    paths
        .iter()
        .find_map(|path| get_nested(value, path).and_then(Value::as_str))
}

fn get_nested<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut current = value;
    for key in path {
        current = current.get(*key)?;
    }
    Some(current)
}

fn short_text(value: &str, max_chars: usize) -> String {
    let normalized = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.chars().count() <= max_chars {
        return normalized;
    }
    let mut output = normalized
        .chars()
        .take(max_chars.saturating_sub(3))
        .collect::<String>();
    output.push_str("...");
    output
}

async fn call_provider(
    route: &ResolvedModelRoute,
    prompt: &str,
    max_tokens: usize,
) -> Result<ModelReply> {
    match route.provider_kind.as_str() {
        "anthropic-compatible" => call_anthropic_compatible(route, prompt, max_tokens).await,
        "openai-compatible" => call_openai_compatible(route, prompt, max_tokens).await,
        "openai-responses" => call_openai_responses(route, prompt, max_tokens).await,
        other => bail!("provider kind is not supported for live roundtable yet: {other}"),
    }
}

async fn call_anthropic_compatible(
    route: &ResolvedModelRoute,
    prompt: &str,
    max_tokens: usize,
) -> Result<ModelReply> {
    let endpoint = format!("{}/v1/messages", route.base_url.trim_end_matches('/'));
    let response = reqwest::Client::new()
        .post(endpoint)
        .header("content-type", "application/json")
        .header("anthropic-version", "2023-06-01")
        .header("x-api-key", &route.auth_token)
        .json(&json!({
            "model": route.model,
            "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt}]
        }))
        .send()
        .await
        .with_context(|| format!("provider request failed for {}", route.alias))?;
    let status = response.status();
    let payload: Value = response
        .json()
        .await
        .with_context(|| format!("provider returned invalid json for {}", route.alias))?;
    let content = text_from_provider_content(payload.get("content")).unwrap_or_default();
    if !status.is_success() || content.trim().is_empty() {
        let message = payload
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .or_else(|| payload.get("message").and_then(Value::as_str))
            .unwrap_or("provider returned no visible text");
        bail!("{}: {}", route.alias, message);
    }
    let thinking_blocks = payload
        .get("content")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|item| item.get("type").and_then(Value::as_str) == Some("thinking"))
                .count()
        })
        .unwrap_or(0);
    Ok(ModelReply {
        content,
        usage: payload.get("usage").cloned().unwrap_or_else(|| json!({})),
        stop_reason: payload
            .get("stop_reason")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        thinking_blocks,
    })
}

async fn call_openai_compatible(
    route: &ResolvedModelRoute,
    prompt: &str,
    max_tokens: usize,
) -> Result<ModelReply> {
    let endpoint = format!("{}/chat/completions", route.base_url.trim_end_matches('/'));
    let response = reqwest::Client::new()
        .post(endpoint)
        .bearer_auth(&route.auth_token)
        .json(&json!({
            "model": route.model,
            "max_tokens": max_tokens,
            "messages": [
                {"role": "system", "content": "You are a participant in a H.A.R.V.I.S. Agent Room. Reply with visible, concise Chinese only. Do not reveal hidden reasoning."},
                {"role": "user", "content": prompt}
            ]
        }))
        .send()
        .await
        .with_context(|| format!("provider request failed for {}", route.alias))?;
    let status = response.status();
    let payload: Value = response
        .json()
        .await
        .with_context(|| format!("provider returned invalid json for {}", route.alias))?;
    let content = text_from_openai_content(&payload).unwrap_or_default();
    if !status.is_success() || content.trim().is_empty() {
        let message = payload
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .or_else(|| payload.get("message").and_then(Value::as_str))
            .unwrap_or("provider returned no visible text");
        bail!("{}: {}", route.alias, message);
    }
    Ok(ModelReply {
        content,
        usage: payload.get("usage").cloned().unwrap_or_else(|| json!({})),
        stop_reason: payload
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first())
            .and_then(|choice| choice.get("finish_reason"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        thinking_blocks: 0,
    })
}

async fn call_openai_responses(
    route: &ResolvedModelRoute,
    prompt: &str,
    max_tokens: usize,
) -> Result<ModelReply> {
    let endpoint = format!("{}/responses", normalize_openai_base_url(&route.base_url));
    let response = reqwest::Client::new()
        .post(endpoint)
        .bearer_auth(&route.auth_token)
        .json(&json!({
            "model": route.model,
            "input": prompt,
            "max_output_tokens": max_tokens
        }))
        .send()
        .await
        .with_context(|| format!("provider request failed for {}", route.alias))?;
    let status = response.status();
    let payload: Value = response
        .json()
        .await
        .with_context(|| format!("provider returned invalid json for {}", route.alias))?;
    let content = text_from_openai_responses_content(&payload).unwrap_or_default();
    if !status.is_success() || content.trim().is_empty() {
        let message = payload
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
            .or_else(|| payload.get("message").and_then(Value::as_str))
            .unwrap_or("provider returned no visible text");
        bail!("{}: {}", route.alias, message);
    }
    Ok(ModelReply {
        content,
        usage: payload.get("usage").cloned().unwrap_or_else(|| json!({})),
        stop_reason: payload
            .get("status")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        thinking_blocks: 0,
    })
}

fn text_from_provider_content(content: Option<&Value>) -> Option<String> {
    let text = content?
        .as_array()?
        .iter()
        .filter(|item| item.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    (!text.is_empty()).then_some(text)
}

fn normalize_openai_base_url(base_url: &str) -> String {
    let base = base_url.trim_end_matches('/');
    if base.ends_with("/v1") {
        base.to_string()
    } else {
        format!("{base}/v1")
    }
}

fn text_from_openai_content(payload: &Value) -> Option<String> {
    let text = payload
        .get("choices")?
        .as_array()?
        .iter()
        .filter_map(|choice| {
            choice
                .get("message")
                .and_then(|message| message.get("content"))
                .and_then(Value::as_str)
                .or_else(|| choice.get("text").and_then(Value::as_str))
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    (!text.is_empty()).then_some(text)
}

fn text_from_openai_responses_content(payload: &Value) -> Option<String> {
    if let Some(text) = payload
        .get("output_text")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    {
        return Some(text.to_string());
    }

    let text = payload
        .get("output")?
        .as_array()?
        .iter()
        .flat_map(|item| {
            item.get("content")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter_map(|content| {
            content
                .get("text")
                .and_then(Value::as_str)
                .or_else(|| content.get("value").and_then(Value::as_str))
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    (!text.is_empty()).then_some(text)
}

fn roundtable_message_view(
    route: &ResolvedModelRoute,
    topic_id: &str,
    message: &Value,
    reply: &ModelReply,
    tag_prefix: &str,
) -> RoundtableMessageView {
    let message_id = message
        .get("message_id")
        .and_then(Value::as_str)
        .unwrap_or("msg_unknown")
        .to_string();
    RoundtableMessageView {
        id: message_id.clone(),
        event_id: message
            .get("event_id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        agent: route.agent.clone(),
        agent_id: route.alias.clone(),
        alias: route.alias.clone(),
        role: route.role.clone(),
        event_kind: "agent_message".to_string(),
        initial: route.initial.clone(),
        color: route.color.clone(),
        time: message
            .get("created_at")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        topic: topic_id.to_string(),
        question_id: message
            .get("metadata")
            .and_then(|metadata| metadata.get("question_id"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        reply_to_event_id: message
            .get("metadata")
            .and_then(|metadata| metadata.get("reply_to_event_id"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        reply_to_agent_id: message
            .get("metadata")
            .and_then(|metadata| metadata.get("reply_to_agent_id"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        reply_to_question_id: message
            .get("metadata")
            .and_then(|metadata| metadata.get("reply_to_question_id"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        route_reason: String::new(),
        tags: vec![
            format!("evt_{}_{}", route.alias, tag_prefix),
            message_id,
            format!(
                "usage_out_{}",
                reply
                    .usage
                    .get("output_tokens")
                    .and_then(Value::as_i64)
                    .unwrap_or(0)
            ),
        ],
        note: format!(
            "H.A.R.V.I.S. provider registry -> {}; thinking blocks filtered: {}",
            route.alias, reply.thinking_blocks
        ),
        content: reply.content.clone(),
    }
}

fn system_roundtable_message_view(
    topic_id: &str,
    message: &Value,
    tag_prefix: &str,
) -> RoundtableMessageView {
    RoundtableMessageView {
        id: message
            .get("message_id")
            .and_then(Value::as_str)
            .unwrap_or("msg_unknown")
            .to_string(),
        event_id: message
            .get("event_id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        agent: "H.A.R.V.I.S.".to_string(),
        agent_id: "harvis".to_string(),
        alias: "harvis".to_string(),
        role: "coordinator".to_string(),
        event_kind: "status_change".to_string(),
        initial: "H".to_string(),
        color: "#111827".to_string(),
        time: message
            .get("created_at")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        topic: topic_id.to_string(),
        question_id: String::new(),
        reply_to_event_id: String::new(),
        reply_to_agent_id: String::new(),
        reply_to_question_id: String::new(),
        route_reason: String::new(),
        tags: vec![tag_prefix.to_string(), "needs_review".to_string()],
        note: "Partial result is preserved in Agent Room JSONL.".to_string(),
        content: message
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or("Auto roundtable paused.")
            .to_string(),
    }
}

async fn request_handoff_post(Json(body): Json<Value>) -> Response {
    handle_post("/request-handoff", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let requested_by =
            optional_string(&data, "requested_by").unwrap_or_else(|| "harvis".to_string());
        Ok((
            request_handoff(
                &root,
                &require_str(&data, "run_id", None)?,
                &require_str(&data, "harness", None)?,
                optional_string(&data, "instruction")
                    .as_deref()
                    .unwrap_or(""),
                optional_string(&data, "topic_id").as_deref(),
                &requested_by,
            )?,
            Vec::new(),
        ))
    })
}

async fn handoff_status_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-room/handoff/status", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        // T306 contract blocks: optional; when an adapter reports them they
        // must match the typed contract (unknown inner values stay null).
        let cost = match data.get("cost") {
            Some(value) => Some(
                serde_json::from_value::<HandoffCost>(value.clone())
                    .with_context(|| "invalid cost block".to_string())?,
            ),
            None => None,
        };
        let usage = match data.get("usage") {
            Some(value) => Some(
                serde_json::from_value::<HandoffUsage>(value.clone())
                    .with_context(|| "invalid usage block".to_string())?,
            ),
            None => None,
        };
        let verification = match data.get("verification") {
            Some(value) => Some(
                serde_json::from_value::<HandoffVerification>(value.clone())
                    .with_context(|| "invalid verification block".to_string())?,
            ),
            None => None,
        };
        Ok((
            update_handoff_status(
                &root,
                HandoffStatusInput {
                    handoff_id: require_str(&data, "handoff_id", None)?,
                    state: require_str(&data, "state", None)?,
                    summary: optional_string(&data, "summary"),
                    updated_by: optional_string(&data, "updated_by")
                        .or_else(|| Some("harvis-http".to_string())),
                    result_path: optional_string(&data, "result_path"),
                    exit_code: data.get("exit_code").and_then(Value::as_i64),
                    cost,
                    usage,
                    verification,
                },
            )?,
            Vec::new(),
        ))
    })
}

async fn request_approval_post(Json(body): Json<Value>) -> Response {
    handle_post("/request-approval", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            create_approval(
                &root,
                &require_str(&data, "run_id", None)?,
                &require_str(&data, "action_type", None)?,
                &require_str(&data, "target", None)?,
                &require_str(&data, "reason", None)?,
                &require_str(&data, "risk", Some("medium"))?,
                &require_str(&data, "scope", Some("one_time"))?,
            )?,
            Vec::new(),
        ))
    })
}

async fn decide_approval_post(Json(body): Json<Value>) -> Response {
    handle_post("/decide-approval", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            decide_approval(
                &root,
                &require_str(&data, "approval_id", None)?,
                &require_str(&data, "decision", None)?,
                &require_str(&data, "decided_by", Some("human"))?,
                optional_string(&data, "notes").as_deref().unwrap_or(""),
            )?,
            Vec::new(),
        ))
    })
}

async fn check_notifications_post(Json(body): Json<Value>) -> Response {
    handle_post("/check-notifications", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            check_notifications(&root, optional_bool(&data, "write", true)?)?,
            Vec::new(),
        ))
    })
}

async fn agent_harnesses_test_post(Json(body): Json<Value>) -> Response {
    handle_post("/agent-harnesses/test", body, |data| {
        let _ = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            build_agent_harness_status(true, optional_int(&data, "timeout_seconds", 120, 1, 600)?),
            Vec::new(),
        ))
    })
}

fn summarize_router_event(event: &Value) -> Value {
    let repo_lookup = event.get("repo_lookup").map(|repo_lookup| {
        let items = repo_lookup
            .get("items")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .map(|item| {
                        json!({
                            "nameWithOwner": item.get("nameWithOwner").and_then(Value::as_str),
                            "localExists": item.get("localExists").and_then(Value::as_bool),
                            "localStatus": item.get("localStatus").and_then(Value::as_str),
                            "dirty": item.get("dirty").and_then(Value::as_bool),
                            "ahead": item.get("ahead").and_then(Value::as_i64),
                            "behind": item.get("behind").and_then(Value::as_i64)
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        json!({
            "count": repo_lookup.get("count").and_then(Value::as_i64),
            "mode": repo_lookup.get("mode").and_then(Value::as_str),
            "queries": repo_lookup.get("queries").cloned().unwrap_or_else(|| json!([])),
            "items": items,
            "includesLocalAbsolutePaths": false
        })
    });
    let task_enqueue = event.get("task_enqueue").map(|task_enqueue| {
        json!({
            "packet_count": task_enqueue
                .get("packets")
                .and_then(Value::as_array)
                .map(|packets| packets.len())
                .unwrap_or(0),
            "selected_preset": task_enqueue.get("selected_preset").and_then(Value::as_str)
        })
    });
    json!({
        "recorded_at": event.get("recorded_at").and_then(Value::as_str),
        "router_version": event.get("router_version").and_then(Value::as_str),
        "transport": event.get("transport").and_then(Value::as_str),
        "intent": event.get("intent").and_then(Value::as_str),
        "route_state": event.get("route_state").and_then(Value::as_str),
        "selected_preset": event.get("selected_preset"),
        "agent_pools": event.get("agent_pools"),
        "repo_lookup": repo_lookup,
        "task_enqueue": task_enqueue,
        "safeForWebView": true,
        "includesLocalAbsolutePaths": false
    })
}

async fn router_events_get(Query(query): Query<HashMap<String, String>>) -> Response {
    handle_get("/router/events", query, |data| {
        let root = resolve_root(require_str(&data, "root", Some("."))?)?;
        let limit = optional_int(&data, "limit", 50, 1, 200)?;
        let full = optional_bool(&data, "full", false)?;
        let path = root.join(".harvis/router/events.jsonl");
        let mut events = Vec::new();
        if path.exists() {
            let text = fs::read_to_string(&path)?;
            for line in text.lines().rev().take(limit) {
                if let Ok(value) = serde_json::from_str::<Value>(line) {
                    events.push(value);
                }
            }
            events.reverse();
        }
        if !full {
            events = events.iter().map(summarize_router_event).collect();
        }
        Ok(json!({
            "router_version": harvis_integrations::router::ROUTER_VERSION,
            "events_path": ".harvis/router/events.jsonl",
            "event_count": events.len(),
            "events": events,
            "safeForWebView": !full,
            "includesLocalAbsolutePaths": full,
            "warnings": if full {
                json!(["full=true returns raw local router events and may include absolute local paths"])
            } else {
                json!([])
            }
        }))
    })
}

async fn router_message_post(Json(body): Json<Value>) -> Response {
    handle_post("/router/message", body, |data| {
        let root = resolve_root(require_str(&data, "root", Some("."))?)?;
        let context = if let Some(items) = data.get("context").and_then(Value::as_array) {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        } else {
            optional_string(&data, "context")
                .into_iter()
                .collect::<Vec<_>>()
        };
        Ok((
            route_message(RouteMessageOptions {
                root,
                transport: require_str(&data, "transport", Some("manual"))?,
                sender: require_str(&data, "sender", Some("local"))?,
                text: require_str(&data, "text", None)?,
                chat_id: optional_string(&data, "chat_id"),
                message_id: optional_string(&data, "message_id"),
                context,
                include_paths: optional_bool(&data, "include_paths", true)?,
                map_path: optional_string(&data, "map_path").map(PathBuf::from),
                agent_pools_path: optional_string(&data, "agent_pools").map(PathBuf::from),
            })?,
            Vec::new(),
        ))
    })
}

async fn projects_get(Query(query): Query<HashMap<String, String>>) -> Response {
    let data = query_to_value(query);
    let raw_root = match require_str(&data, "root", Some(".")) {
        Ok(root) => root,
        Err(error) => return fail("/projects", map_error(error)),
    };
    let query = optional_string(&data, "query");
    match timeout(
        Duration::from_millis(5000),
        tokio::task::spawn_blocking(move || {
            let root = resolve_root(raw_root)?;
            list_projects(ProjectListOptions { root, query })
        }),
    )
    .await
    {
        Ok(Ok(Ok(data))) => ok("/projects", data).into_response(),
        Ok(Ok(Err(error))) => fail("/projects", map_error(error)),
        Ok(Err(error)) => fail(
            "/projects",
            HttpApiError::new("join_error", error.to_string())
                .status(StatusCode::INTERNAL_SERVER_ERROR),
        ),
        Err(_) => fail(
            "/projects",
            HttpApiError::new("timeout", "projects read timed out after 5s")
                .status(StatusCode::GATEWAY_TIMEOUT),
        ),
    }
}

async fn agent_pools_get(Query(query): Query<HashMap<String, String>>) -> Response {
    let data = query_to_value(query);
    let raw_root = match require_str(&data, "root", Some(".")) {
        Ok(root) => root,
        Err(error) => return fail("/agent-pools", map_error(error)),
    };
    let path = optional_string(&data, "agent_pools").map(PathBuf::from);
    let query = optional_string(&data, "query");
    match timeout(
        Duration::from_millis(5000),
        tokio::task::spawn_blocking(move || {
            let root = resolve_root(raw_root)?;
            agent_pools_status(AgentPoolsOptions { root, path, query })
        }),
    )
    .await
    {
        Ok(Ok(Ok(data))) => ok("/agent-pools", data).into_response(),
        Ok(Ok(Err(error))) => fail("/agent-pools", map_error(error)),
        Ok(Err(error)) => fail(
            "/agent-pools",
            HttpApiError::new("join_error", error.to_string())
                .status(StatusCode::INTERNAL_SERVER_ERROR),
        ),
        Err(_) => fail(
            "/agent-pools",
            HttpApiError::new("timeout", "agent pools read timed out after 5s")
                .status(StatusCode::GATEWAY_TIMEOUT),
        ),
    }
}

async fn agent_step_post(Json(body): Json<Value>) -> Response {
    let data = if body.is_object() { body } else { json!({}) };
    let options = match parse_agent_step_options(data) {
        Ok(options) => options,
        Err(error) => return fail("/agent/step", map_error(error)),
    };
    match timeout(Duration::from_millis(10000), agent_step_via_cli(options)).await {
        Ok(Ok(data)) => ok("/agent/step", data).into_response(),
        Ok(Err(error)) => fail("/agent/step", map_error(error)),
        Err(_) => fail(
            "/agent/step",
            HttpApiError::new("timeout", "agent step timed out after 10s")
                .status(StatusCode::GATEWAY_TIMEOUT),
        ),
    }
}

async fn agent_step_via_cli(options: AgentStepOptions) -> Result<Value> {
    let exe = std::env::current_exe().context("resolve current harvis executable")?;
    let mut command = Command::new(exe);
    command
        .kill_on_drop(true)
        .arg("agent")
        .arg("--root")
        .arg(options.root.as_os_str())
        .arg("step")
        .arg("--channel")
        .arg(&options.channel)
        .arg("--sender")
        .arg(&options.sender)
        .arg("--message")
        .arg(&options.message);
    if let Some(chat_id) = &options.chat_id {
        command.arg("--chat-id").arg(chat_id);
    }
    if let Some(message_id) = &options.message_id {
        command.arg("--message-id").arg(message_id);
    }
    for item in &options.context {
        command.arg("--context").arg(item);
    }
    if let Some(map_path) = &options.map_path {
        command.arg("--map-path").arg(map_path.as_os_str());
    }
    if let Some(agent_pools_path) = &options.agent_pools_path {
        command
            .arg("--agent-pools")
            .arg(agent_pools_path.as_os_str());
    }
    if let Some(topic_id) = &options.topic_id {
        command.arg("--topic-id").arg(topic_id);
    }
    let output = command
        .output()
        .await
        .context("run harvis agent step worker")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        bail!(
            "agent step worker exited with {}: {}",
            output.status,
            detail
        );
    }
    serde_json::from_slice::<Value>(&output.stdout).context("parse harvis agent step worker JSON")
}

fn parse_agent_step_options(data: Value) -> Result<AgentStepOptions> {
    let root = resolve_root(require_str(&data, "root", Some("."))?)?;
    let context = if let Some(items) = data.get("context").and_then(Value::as_array) {
        items
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>()
    } else {
        optional_string(&data, "context")
            .into_iter()
            .collect::<Vec<_>>()
    };
    Ok(AgentStepOptions {
        root,
        channel: require_str(&data, "channel", Some("webview"))?,
        sender: require_str(&data, "sender", Some("local"))?,
        message: require_str(&data, "message", None)?,
        chat_id: optional_string(&data, "chat_id"),
        message_id: optional_string(&data, "message_id"),
        context,
        include_paths: optional_bool(&data, "include_paths", true)?,
        map_path: optional_string(&data, "map_path").map(PathBuf::from),
        agent_pools_path: optional_string(&data, "agent_pools").map(PathBuf::from),
        topic_id: optional_string(&data, "topic_id"),
        chair_dry_run: optional_bool(&data, "chair_dry_run", true)?,
    })
}

async fn persona_init_post(Json(body): Json<Value>) -> Response {
    handle_post("/persona/init", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((init_persona_registry(&root)?, Vec::new()))
    })
}

async fn persona_create_vault_post(Json(body): Json<Value>) -> Response {
    handle_post("/persona/create-vault", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let owner = optional_string(&data, "owner").unwrap_or_else(|| "harzva".to_string());
        Ok((
            create_memory_vault(
                &root,
                &require_str(&data, "display_name", None)?,
                optional_string(&data, "vault_id").as_deref(),
                &owner,
            )?,
            Vec::new(),
        ))
    })
}

async fn persona_create_card_post(Json(body): Json<Value>) -> Response {
    handle_post("/persona/create-card", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            create_persona_card(
                &root,
                &require_str(&data, "display_name", None)?,
                optional_string(&data, "persona_id").as_deref(),
                optional_string(&data, "visual_asset_id")
                    .as_deref()
                    .unwrap_or(""),
            )?,
            Vec::new(),
        ))
    })
}

async fn persona_update_card_post(Json(body): Json<Value>) -> Response {
    handle_post("/persona/update-card", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        object_or_null(&data, "tone")?;
        object_or_null(&data, "decision_style")?;
        string_array_or_null(&data, "behavior_rules")?;
        Ok((
            update_persona_card(
                &root,
                &require_str(&data, "persona_id", None)?,
                optional_string(&data, "display_name").as_deref(),
                optional_string(&data, "visual_asset_id").as_deref(),
                optional_string(&data, "base_template").as_deref(),
                optional_string(&data, "status").as_deref(),
                data.get("tone"),
                data.get("decision_style"),
                data.get("behavior_rules"),
            )?,
            Vec::new(),
        ))
    })
}

async fn persona_create_twin_post(Json(body): Json<Value>) -> Response {
    handle_post("/persona/create-twin", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        object_or_null(&data, "permissions")?;
        Ok((
            create_twin_instance(
                &root,
                &require_str(&data, "display_name", None)?,
                &require_str(&data, "memory_vault_id", None)?,
                &require_str(&data, "persona_card_id", None)?,
                optional_string(&data, "instance_id").as_deref(),
                optional_string(&data, "overlay_memory_id").as_deref(),
                data.get("permissions"),
            )?,
            Vec::new(),
        ))
    })
}

async fn personality_candidate_post(Json(body): Json<Value>) -> Response {
    handle_post("/personality-candidate", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        let confidence = optional_int(&data, "confidence_percent", 50, 0, 100)? as f64 / 100.0;
        Ok((
            create_personality_candidate(
                &root,
                &require_str(&data, "trait", None)?,
                &require_str(&data, "target_persona_id", None)?,
                &require_str(&data, "source_type", Some("manual"))?,
                string_array(&data, "source_refs")?,
                &require_str(&data, "trait_type", Some("decision_style"))?,
                confidence,
            )?,
            Vec::new(),
        ))
    })
}

async fn personality_candidate_decide_post(Json(body): Json<Value>) -> Response {
    handle_post("/personality-candidate/decide", body, |data| {
        let root = resolve_root(require_str(&data, "root", None)?)?;
        Ok((
            decide_personality_candidate(
                &root,
                &require_str(&data, "candidate_id", None)?,
                &require_str(&data, "decision", None)?,
                &require_str(&data, "decided_by", Some("human"))?,
                optional_string(&data, "notes").as_deref().unwrap_or(""),
                optional_string(&data, "edited_trait")
                    .as_deref()
                    .unwrap_or(""),
            )?,
            Vec::new(),
        ))
    })
}

async fn fallback(method: Method, uri: Uri, body: Bytes) -> Response {
    let endpoint = uri.path();
    if method == Method::POST
        && matches!(
            endpoint,
            "/a2a/message:send" | "/message:send" | "/a2a/message:stream" | "/message:stream"
        )
    {
        if endpoint.ends_with(":stream") {
            // capabilities.streaming = false -> UnsupportedOperationError (§3.3.4).
            return A2aError::unsupported_operation(
                "streaming is not supported by this agent (AgentCard capabilities.streaming = false)",
            )
            .rest_response();
        }
        let payload = serde_json::from_slice::<Value>(&body).unwrap_or_else(|_| json!({}));
        return match handle_a2a_send(&payload).await {
            Ok(task) => a2a_rest_response(StatusCode::OK, json!({"task": task})),
            Err(error) => error.rest_response(),
        };
    }
    if method == Method::POST && (endpoint.ends_with(":cancel") || endpoint.ends_with("ancel")) {
        if let Some(task_id) = endpoint
            .strip_prefix("/a2a/tasks/")
            .or_else(|| endpoint.strip_prefix("/tasks/"))
            .and_then(|rest| {
                rest.strip_suffix(":cancel")
                    .or_else(|| rest.strip_suffix("ancel"))
            })
            .filter(|value| !value.is_empty())
        {
            let mut params = serde_json::from_slice::<Value>(&body)
                .ok()
                .and_then(|value| value.as_object().cloned())
                .unwrap_or_default();
            params.insert("id".to_string(), json!(task_id));
            if !params.contains_key("root") {
                if let Some(root) = uri_query_param(&uri, "root") {
                    params.insert("root".to_string(), json!(root));
                }
            }
            return match handle_a2a_cancel_task(&Value::Object(params)).await {
                Ok(task) => a2a_rest_response(StatusCode::OK, task),
                Err(error) => error.rest_response(),
            };
        }
    }
    if method == Method::GET {
        if let Some(task_id) = endpoint
            .strip_prefix("/a2a/tasks/")
            .or_else(|| endpoint.strip_prefix("/tasks/"))
            .filter(|value| !value.is_empty())
            .filter(|value| !value.contains('/'))
        {
            let params = json!({
                "id": task_id,
                "root": uri_query_param(&uri, "root").unwrap_or_default()
            });
            return match handle_a2a_get_task(&params).await {
                Ok(task) => a2a_rest_response(StatusCode::OK, task),
                Err(error) => error.rest_response(),
            };
        }
    }
    fail(
        endpoint,
        HttpApiError::new("not_found", format!("unknown endpoint: {endpoint}"))
            .status(StatusCode::NOT_FOUND),
    )
}

fn uri_query_param(uri: &Uri, name: &str) -> Option<String> {
    uri.query()?.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == name).then(|| value.replace("%2F", "/").replace("%20", " "))
    })
}

fn handle_get(
    endpoint: &'static str,
    query: HashMap<String, String>,
    handler: impl FnOnce(Value) -> Result<Value>,
) -> Response {
    let data = query_to_value(query);
    match handler(data) {
        Ok(data) => ok(endpoint, data).into_response(),
        Err(error) => fail(endpoint, map_error(error)),
    }
}

fn handle_post(
    endpoint: &'static str,
    body: Value,
    handler: impl FnOnce(Value) -> Result<(Value, Vec<String>)>,
) -> Response {
    let data = if body.is_object() { body } else { json!({}) };
    match handler(data) {
        Ok((data, warnings)) => ok_with_warnings(endpoint, data, warnings).into_response(),
        Err(error) => fail(endpoint, map_error(error)),
    }
}

fn map_error(error: anyhow::Error) -> HttpApiError {
    if let Some(kind) = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<io::Error>().map(std::io::Error::kind))
    {
        return match kind {
            io::ErrorKind::PermissionDenied => {
                HttpApiError::new("permission_denied", "filesystem permission denied")
                    .status(StatusCode::FORBIDDEN)
            }
            io::ErrorKind::NotFound => {
                HttpApiError::new("not_found", "requested filesystem resource not found")
                    .status(StatusCode::NOT_FOUND)
            }
            _ => HttpApiError::new("runtime_error", "filesystem operation failed")
                .status(StatusCode::INTERNAL_SERVER_ERROR),
        };
    }
    let message = error.to_string();
    if message.contains("not found") {
        HttpApiError::new("not_found", message).status(StatusCode::NOT_FOUND)
    } else if message.contains("outside workspace") || message.contains("outside root") {
        HttpApiError::new("invalid_path", message)
    } else if message.contains("workspace root") {
        HttpApiError::new("invalid_root", message)
    } else {
        HttpApiError::new("invalid_request", message)
    }
}

fn query_to_value(query: HashMap<String, String>) -> Value {
    Value::Object(
        query
            .into_iter()
            .map(|(key, value)| (key, Value::String(value)))
            .collect(),
    )
}

fn require_str(data: &Value, name: &str, default: Option<&str>) -> Result<String> {
    let value = data.get(name).and_then(Value::as_str).or(default);
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        bail!("{name} must be a non-empty string");
    };
    Ok(value.to_string())
}

fn optional_string(data: &Value, name: &str) -> Option<String> {
    data.get(name)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn string_array(data: &Value, name: &str) -> Result<Vec<String>> {
    let Some(value) = data.get(name) else {
        return Ok(Vec::new());
    };
    let Some(items) = value.as_array() else {
        bail!("{name} must be an array of strings");
    };
    items
        .iter()
        .map(|item| {
            item.as_str()
                .map(str::trim)
                .map(ToOwned::to_owned)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| anyhow::anyhow!("{name} must be an array of strings"))
        })
        .collect()
}

fn string_array_or_null(data: &Value, name: &str) -> Result<()> {
    if data.get(name).is_none() || data.get(name).is_some_and(Value::is_null) {
        return Ok(());
    }
    let _ = string_array(data, name)?;
    Ok(())
}

fn object_or_null(data: &Value, name: &str) -> Result<()> {
    if data.get(name).is_none() || data.get(name).is_some_and(Value::is_null) {
        return Ok(());
    }
    if data.get(name).is_some_and(Value::is_object) {
        return Ok(());
    }
    bail!("{name} must be an object")
}

fn has_key(data: &Value, name: &str) -> bool {
    data.as_object()
        .is_some_and(|object| object.contains_key(name))
}

fn optional_bool(data: &Value, name: &str, default: bool) -> Result<bool> {
    let Some(value) = data.get(name) else {
        return Ok(default);
    };
    if let Some(value) = value.as_bool() {
        return Ok(value);
    }
    if let Some(value) = value.as_str() {
        return match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Ok(true),
            "0" | "false" | "no" | "off" => Ok(false),
            _ => bail!("{name} must be a boolean"),
        };
    }
    bail!("{name} must be a boolean")
}

fn optional_int(
    data: &Value,
    name: &str,
    default: usize,
    minimum: usize,
    maximum: usize,
) -> Result<usize> {
    let Some(value) = data.get(name) else {
        return Ok(default);
    };
    let parsed = if let Some(value) = value.as_u64() {
        value as usize
    } else if let Some(value) = value.as_str() {
        value.trim().parse::<usize>()?
    } else {
        bail!("{name} must be an integer");
    };
    if parsed < minimum || parsed > maximum {
        bail!("{name} must be between {minimum} and {maximum}");
    }
    Ok(parsed)
}

fn optional_path(data: &Value, name: &str, default: &str) -> PathBuf {
    optional_string(data, name)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(default))
}

fn body_path(data: &Value, name: &str, default: &str) -> Result<PathBuf> {
    Ok(PathBuf::from(require_str(data, name, Some(default))?))
}

fn resolve_root(raw: String) -> Result<PathBuf> {
    let root = expanduser(Path::new(&raw));
    if root.as_os_str().is_empty() {
        bail!("workspace root must be a non-empty path");
    }
    if root.is_absolute() {
        Ok(root)
    } else {
        Ok(std::env::current_dir()?.join(root))
    }
}

fn resolve_workspace_path(root: &Path, raw: &str) -> Result<PathBuf> {
    let mut path = expanduser(Path::new(raw));
    if !path.is_absolute() {
        path = root.join(path);
    }
    let path = path.canonicalize()?;
    if !path.starts_with(root) {
        bail!("path is outside workspace root: {}", path.display());
    }
    Ok(path)
}

fn list_packets(
    root: &Path,
    limit: usize,
    include_preview: bool,
    max_preview_chars: usize,
) -> Result<Value> {
    let outbox = root.join(".harvis/outbox");
    if !outbox.exists() {
        bail!("outbox not found: {}", outbox.display());
    }
    let mut paths = md_paths_by_mtime_desc(&outbox)?;
    paths.truncate(limit);
    let mut packets = Vec::new();
    for path in paths {
        let mut item = json!({
            "path": path.display().to_string(),
            "workspace_path": rel(&path, root),
            "status": parse_packet_status(&path),
            "bytes": path.metadata()?.len(),
            "modified_at": modified_secs(&path)
        });
        if include_preview {
            let preview = fs::read_to_string(&path)
                .unwrap_or_default()
                .chars()
                .take(max_preview_chars)
                .collect::<String>();
            item["preview"] = json!(preview);
        }
        packets.push(item);
    }
    Ok(json!({"workspace_root": root.display().to_string(), "packets": packets}))
}

fn read_events(root: &Path, profile_root: &Path, limit: usize) -> Result<Value> {
    let (path, state_store) = existing_runtime_path(root, "events.jsonl", profile_root);
    let Some(path) = path else {
        bail!(
            "event log not found: {}",
            root.join(".harvis/events.jsonl").display()
        );
    };
    let mut events = Vec::new();
    for line in fs::read_to_string(&path)
        .unwrap_or_default()
        .lines()
        .rev()
        .take(limit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        if let Ok(value) = serde_json::from_str::<Value>(line) {
            if value.is_object() {
                events.push(value);
            }
        }
    }
    Ok(
        json!({"workspace_root": root.display().to_string(), "state_store": state_store, "events": events}),
    )
}

fn list_codex_thread_bindings(
    root: &Path,
    profile_root: &Path,
    limit: usize,
    include_legacy: bool,
) -> Result<Value> {
    let (mut bindings, bindings_path, state_store) = read_runtime_jsonl_objects_result(
        root,
        "codex-threads/bindings.jsonl",
        profile_root,
        None,
    )?;
    let mut seen = BTreeMap::new();
    for item in &bindings {
        let run_id = item
            .get("run_id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let thread_id = item
            .get("codex_thread_id")
            .or_else(|| item.get("codex_session_id"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !run_id.is_empty() || !thread_id.is_empty() {
            seen.insert(format!("{run_id}:{thread_id}"), true);
        }
    }
    if include_legacy {
        for path in
            recent_child_file_paths(&root.join(".harvis/executions"), "codex-thread.json", 120)?
        {
            let Some(mut item) = read_json_object(&path) else {
                continue;
            };
            let run_id = item
                .get("run_id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let thread_id = item
                .get("codex_thread_id")
                .or_else(|| item.get("codex_session_id"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let key = format!("{run_id}:{thread_id}");
            if run_id.is_empty() || seen.contains_key(&key) {
                continue;
            }
            item.as_object_mut()
                .expect("checked object")
                .entry("codex_thread_binding".to_string())
                .or_insert_with(|| Value::String(path.display().to_string()));
            bindings.push(item);
            seen.insert(key, true);
        }
    }
    let mut enriched: Vec<Value> = bindings
        .into_iter()
        .map(enrich_with_codex_event_state)
        .collect();
    enriched.sort_by(|left, right| {
        value_time_key(right)
            .cmp(&value_time_key(left))
            .then_with(|| value_id_key(left).cmp(&value_id_key(right)))
    });
    enriched.truncate(limit);
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "bindings_path": ".harvis/codex-threads/bindings.jsonl",
        "state_store": state_store,
        "resolved_bindings_path": bindings_path.display().to_string(),
        "include_legacy": include_legacy,
        "bindings": enriched
    }))
}

fn list_codex_thread_pins(root: &Path, profile_root: &Path, limit: usize) -> Result<Value> {
    let mut active: BTreeMap<String, Value> = BTreeMap::new();
    let (events, pins_path, state_store) =
        read_runtime_jsonl_objects_result(root, "codex-threads/pins.jsonl", profile_root, None)?;
    for event in events {
        let thread_id = event
            .get("codex_thread_id")
            .or_else(|| event.get("codex_session_id"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if thread_id.is_empty() {
            continue;
        }
        if event.get("action").and_then(Value::as_str) == Some("unpin") {
            active.remove(&thread_id);
        } else {
            active.insert(thread_id, enrich_with_codex_event_state(event));
        }
    }
    let mut pins: Vec<Value> = active.into_values().collect();
    pins.sort_by(|left, right| {
        value_time_key(right)
            .cmp(&value_time_key(left))
            .then_with(|| value_id_key(left).cmp(&value_id_key(right)))
    });
    pins.truncate(limit);
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "pins_path": ".harvis/codex-threads/pins.jsonl",
        "state_store": state_store,
        "resolved_pins_path": pins_path.display().to_string(),
        "pins": pins
    }))
}

fn list_lark_card_actions(root: &Path, profile_root: &Path, limit: usize) -> Result<Value> {
    let relative_path = Path::new("lark/card-actions.jsonl");
    let fallback = runtime_fallback_path(root, relative_path, profile_root);
    let primary = root.join(".harvis").join(relative_path);
    let (mut actions, resolved_path, state_store) = if fallback.exists() {
        (
            read_jsonl_objects_result(&fallback, Some(limit))?,
            fallback,
            "profile-fallback",
        )
    } else if primary.exists() {
        (
            read_jsonl_objects_result(&primary, Some(limit))?,
            primary,
            "workspace",
        )
    } else {
        (Vec::new(), primary, "missing")
    };
    actions.reverse();
    let real_clicks = actions
        .iter()
        .filter(|item| item.get("dry_run").and_then(Value::as_bool) == Some(false))
        .count();
    let synthetic_clicks = actions.len().saturating_sub(real_clicks);
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "actions_path": ".harvis/lark/card-actions.jsonl",
        "resolved_actions_path": resolved_path.display().to_string(),
        "state_store": state_store,
        "count": actions.len(),
        "real_clicks": real_clicks,
        "synthetic_clicks": synthetic_clicks,
        "actions": actions
    }))
}

fn list_conversation_bindings(root: &Path, limit: usize) -> Result<Value> {
    let mut bindings = read_jsonl_objects_result(
        &root.join(".harvis/agent-room/conversation_binding.jsonl"),
        Some(limit),
    )?;
    bindings.reverse();
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "bindings_path": ".harvis/agent-room/conversation_binding.jsonl",
        "bindings": bindings
    }))
}

fn read_team_harness_state(root: &Path, limit: usize) -> Result<Value> {
    let base = root.join(".harvis/agent-room");
    let mut decisions =
        read_jsonl_objects_result(&base.join("chair_decisions.jsonl"), Some(limit))?;
    let mut tools = read_jsonl_objects_result(&base.join("team_tool_calls.jsonl"), Some(limit))?;
    let mut gates =
        read_jsonl_objects_result(&base.join("approval_gate_checks.jsonl"), Some(limit))?;
    decisions.reverse();
    tools.reverse();
    gates.reverse();
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "team_harness_version": "harvis.team-harness.v0",
        "leader_principle": "selected backend + leader prompt + Harvis tools + mailbox/taskboard/wake + hard approval gate",
        "paths": {
            "chair_decisions": ".harvis/agent-room/chair_decisions.jsonl",
            "team_tool_calls": ".harvis/agent-room/team_tool_calls.jsonl",
            "approval_gate_checks": ".harvis/agent-room/approval_gate_checks.jsonl"
        },
        "decisions": decisions,
        "tool_calls": tools,
        "approval_gate_checks": gates
    }))
}

fn read_run_timeline(
    root: &Path,
    profile_root: &Path,
    run_id: Option<&str>,
    codex_thread_id: Option<&str>,
    limit: usize,
) -> Result<Value> {
    let mut event_paths = Vec::new();
    if let Some(run_id) = run_id.filter(|value| !value.is_empty()) {
        event_paths.push(root.join(".harvis/runs").join(run_id).join("events.jsonl"));
    }
    if let Some(thread_id) = codex_thread_id.filter(|value| !value.is_empty()) {
        let bindings = list_codex_thread_bindings(root, profile_root, 500, false)?;
        for binding in bindings
            .get("bindings")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let matches_thread = binding
                .get("codex_thread_id")
                .or_else(|| binding.get("codex_session_id"))
                .and_then(Value::as_str)
                == Some(thread_id);
            if matches_thread {
                if let Some(path) = binding.get("events_jsonl").and_then(Value::as_str) {
                    event_paths.push(PathBuf::from(path));
                }
            }
        }
    }
    if event_paths.is_empty() && run_id.is_none() && codex_thread_id.is_none() {
        let bindings = list_codex_thread_bindings(root, profile_root, 1, false)?;
        if let Some(binding) = bindings
            .get("bindings")
            .and_then(Value::as_array)
            .and_then(|items| items.first())
        {
            if let Some(path) = binding.get("events_jsonl").and_then(Value::as_str) {
                event_paths.push(PathBuf::from(path));
            }
        }
    }
    event_paths.sort();
    event_paths.dedup();
    let mut events = Vec::new();
    for path in &event_paths {
        let (path_events, resolved_path, state_store) =
            read_jsonl_objects_with_runtime_fallback(root, path, profile_root, None)?;
        for mut event in path_events {
            if let Some(object) = event.as_object_mut() {
                object.insert(
                    "source_path".to_string(),
                    Value::String(path.display().to_string()),
                );
                object.insert(
                    "resolved_source_path".to_string(),
                    Value::String(resolved_path.display().to_string()),
                );
                object.insert(
                    "state_store".to_string(),
                    Value::String(state_store.to_string()),
                );
            }
            events.push(event);
        }
    }
    events.sort_by(|left, right| value_time_key(left).cmp(&value_time_key(right)));
    if events.len() > limit {
        events = events.split_off(events.len() - limit);
    }
    Ok(json!({
        "workspace_root": root.display().to_string(),
        "run_id": run_id,
        "codex_thread_id": codex_thread_id,
        "event_paths": event_paths.iter().map(|path| path.display().to_string()).collect::<Vec<_>>(),
        "events": events
    }))
}

const TASK_PROGRESS_UNAVAILABLE_WARNING: &str =
    "task progress skipped because its optional store is not readable";
const TASK_PROGRESS_SCAN_ENTRY_LIMIT: usize = 512;
const TASK_PROGRESS_RECORD_SIZE_LIMIT: u64 = 256 * 1024;

fn task_progress_dir(root: &Path) -> PathBuf {
    root.join(".harvis").join("task-progress")
}

fn sanitize_task_progress_id(raw: &str) -> Result<String> {
    let id = raw.trim();
    if id.is_empty() || id.len() > 120 {
        bail!("task_id must be non-empty and at most 120 characters");
    }
    if !id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | ':'))
    {
        bail!("task_id may contain only ASCII letters, digits, dash, underscore, dot, or colon");
    }
    Ok(id.to_string())
}

fn task_progress_id(data: &Value) -> Result<String> {
    let raw = data
        .get("taskId")
        .or_else(|| data.get("task_id"))
        .and_then(Value::as_str)
        .context("taskId or task_id is required")?;
    sanitize_task_progress_id(raw)
}

fn upsert_task_progress(root: &Path, data: &Value) -> Result<Value> {
    let task_id = task_progress_id(data)?;
    let root = root
        .canonicalize()
        .context("resolve task progress workspace root")?;
    if !root.is_dir() {
        bail!("task progress workspace root must be a directory");
    }
    let store = ensure_task_progress_store(&root)?;
    let path = store.join(format!("{}.json", sanitize_task_progress_id(&task_id)?));
    let now = harvis_core::time::now_rfc3339()?;
    let mut record = match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                bail!("task progress record must be a regular non-symlink file");
            }
            if metadata.len() > TASK_PROGRESS_RECORD_SIZE_LIMIT {
                bail!("task progress record exceeds the size limit");
            }
            let text = fs::read_to_string(&path).context("read existing task progress record")?;
            let value: Value =
                serde_json::from_str(&text).context("parse existing task progress record")?;
            if !value.is_object() {
                bail!("existing task progress record must be an object");
            }
            value
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => json!({}),
        Err(error) => return Err(error).context("inspect existing task progress record"),
    };
    {
        let object = record
            .as_object_mut()
            .context("task progress record must be an object")?;
        if !object.contains_key("startedAt") {
            object.insert("startedAt".to_string(), Value::String(now.clone()));
        }
        if let Some(incoming) = data.as_object() {
            for (key, value) in incoming {
                if key == "root" {
                    continue;
                }
                object.insert(key.clone(), value.clone());
            }
        }
        object.insert(
            "schemaVersion".to_string(),
            Value::String("harvis.task-progress.item.v0".to_string()),
        );
        object.insert("safeForHarvisBar".to_string(), Value::Bool(true));
        object.insert("taskId".to_string(), Value::String(task_id));
        object.insert("updatedAt".to_string(), Value::String(now));
        if !object.contains_key("status") {
            object.insert("status".to_string(), Value::String("running".to_string()));
        }
    }

    write_task_progress_record(&path, &record)?;
    Ok(json!({
        "schemaVersion": "harvis.task-progress.v0",
        "safeForHarvisBar": true,
        "workspace": public_workspace_label(&root),
        "task": normalize_task_progress_item(&record),
        "stored": true,
        "safety": {
            "redacted": true,
            "includesSecrets": false,
            "includesLocalAbsolutePaths": false
        }
    }))
}

fn ensure_task_progress_store(root: &Path) -> Result<PathBuf> {
    let harvis_dir = root.join(".harvis");
    ensure_real_directory(&harvis_dir, "task progress state directory")?;
    let store = harvis_dir.join("task-progress");
    ensure_real_directory(&store, "task progress store")?;
    Ok(store)
}

fn ensure_real_directory(path: &Path, label: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                bail!("{label} must be a real directory");
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir(path).with_context(|| format!("create {label}"))?;
            let metadata = fs::symlink_metadata(path)?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                bail!("{label} must be a real directory");
            }
        }
        Err(error) => return Err(error).with_context(|| format!("inspect {label}")),
    }
    Ok(())
}

fn write_task_progress_record(path: &Path, record: &Value) -> Result<()> {
    let parent = path.parent().context("task progress parent missing")?;
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .context("task progress record name is invalid")?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = parent.join(format!(".{name}.{}.{}.tmp", std::process::id(), nonce));
    let mut rendered = serde_json::to_vec_pretty(record)?;
    rendered.push(b'\n');
    if rendered.len() as u64 > TASK_PROGRESS_RECORD_SIZE_LIMIT {
        bail!("task progress record exceeds the size limit");
    }

    let result = (|| -> Result<()> {
        let mut output = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .context("create task progress temporary record")?;
        output
            .write_all(&rendered)
            .context("write task progress temporary record")?;
        output
            .sync_all()
            .context("sync task progress temporary record")?;
        drop(output);
        fs::rename(&temporary, path).context("publish task progress record")?;
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            bail!("published task progress record is not a regular file");
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn task_progress_status(
    root: &Path,
    limit: usize,
    include_inactive: bool,
) -> Result<(Value, Vec<String>)> {
    task_progress_status_with_cancel(root, limit, include_inactive, None)
}

fn task_progress_status_with_cancel(
    root: &Path,
    limit: usize,
    include_inactive: bool,
    cancelled: Option<&AtomicBool>,
) -> Result<(Value, Vec<String>)> {
    let store = task_progress_dir(root);
    let entries = match fs::symlink_metadata(&store) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
            fs::read_dir(store)
        }
        Ok(_) => Err(io::Error::other(
            "task progress store is not a real directory",
        )),
        Err(error) => Err(error),
    };
    task_progress_status_from_read_dir_with_cancel(entries, limit, include_inactive, cancelled)
}

#[cfg(test)]
fn task_progress_status_from_read_dir(
    entries: io::Result<fs::ReadDir>,
    limit: usize,
    include_inactive: bool,
) -> Result<(Value, Vec<String>)> {
    task_progress_status_from_read_dir_with_cancel(entries, limit, include_inactive, None)
}

fn task_progress_status_from_read_dir_with_cancel(
    entries: io::Result<fs::ReadDir>,
    limit: usize,
    include_inactive: bool,
    cancelled: Option<&AtomicBool>,
) -> Result<(Value, Vec<String>)> {
    let entries = match entries {
        Ok(entries) => Some(entries),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(_) => {
            return Ok((
                task_progress_snapshot(
                    "skipped",
                    "Task progress is unavailable.",
                    0,
                    vec![],
                    Value::Null,
                )?,
                vec![TASK_PROGRESS_UNAVAILABLE_WARNING.to_string()],
            ));
        }
    };

    let mut rows = Vec::new();
    let mut unreadable_entry = false;
    let mut scanned_entries = 0_usize;
    if let Some(entries) = entries {
        for entry in entries {
            if cancelled.is_some_and(|flag| flag.load(Ordering::Relaxed)) {
                unreadable_entry = true;
                break;
            }
            scanned_entries += 1;
            if scanned_entries > TASK_PROGRESS_SCAN_ENTRY_LIMIT {
                unreadable_entry = true;
                break;
            }
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => {
                    unreadable_entry = true;
                    continue;
                }
            };
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let metadata = match entry.file_type().and_then(|file_type| {
                if file_type.is_symlink() || !file_type.is_file() {
                    return Err(io::Error::other(
                        "task progress record is not a regular file",
                    ));
                }
                entry.metadata()
            }) {
                Ok(metadata) if metadata.len() <= TASK_PROGRESS_RECORD_SIZE_LIMIT => metadata,
                Ok(_) | Err(_) => {
                    unreadable_entry = true;
                    continue;
                }
            };
            debug_assert!(metadata.is_file());
            let Some(value) = read_json_object(&path) else {
                unreadable_entry = true;
                continue;
            };
            let status = value
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            if include_inactive
                || task_progress_is_active(status)
                || task_progress_has_failure_status(status)
            {
                rows.push(value);
            }
        }
    }

    if unreadable_entry {
        return Ok((
            task_progress_snapshot(
                "skipped",
                "Task progress is unavailable.",
                0,
                vec![],
                Value::Null,
            )?,
            vec![TASK_PROGRESS_UNAVAILABLE_WARNING.to_string()],
        ));
    }

    rows.sort_by(|left, right| {
        let left_status = left
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let right_status = right
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        task_progress_priority(left_status)
            .cmp(&task_progress_priority(right_status))
            .then_with(|| task_progress_updated_at(right).cmp(&task_progress_updated_at(left)))
    });
    let active_count = rows
        .iter()
        .filter(|row| {
            task_progress_is_active(
                row.get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown"),
            )
        })
        .count();
    let items: Vec<Value> = rows
        .iter()
        .take(limit)
        .map(normalize_task_progress_item)
        .collect();
    let current = items
        .iter()
        .find(|item| {
            task_progress_has_failure_status(
                item.get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown"),
            )
        })
        .or_else(|| {
            items.iter().find(|item| {
                task_progress_is_active(
                    item.get("status")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown"),
                )
            })
        })
        .cloned()
        .or_else(|| items.first().cloned())
        .unwrap_or(Value::Null);
    let summary = if active_count > 0 {
        format!("{active_count} active task progress item(s).")
    } else if items.is_empty() {
        "No task progress items.".to_string()
    } else {
        "No active task progress items.".to_string()
    };
    let status = if active_count > 0 { "active" } else { "idle" };
    Ok((
        task_progress_snapshot(status, &summary, active_count, items, current)?,
        Vec::new(),
    ))
}

fn task_progress_snapshot(
    status: &str,
    summary: &str,
    active_count: usize,
    items: Vec<Value>,
    current: Value,
) -> Result<Value> {
    Ok(json!({
        "schemaVersion": "harvis.task-progress.v0",
        "safeForHarvisBar": true,
        "generatedAt": harvis_core::time::now_rfc3339()?,
        "status": status,
        "summary": summary,
        "activeCount": active_count,
        "items": items,
        "current": current,
        "safety": {
            "redacted": true,
            "includesSecrets": false,
            "includesLocalAbsolutePaths": false
        }
    }))
}

fn task_progress_updated_at(value: &Value) -> String {
    value
        .get("updatedAt")
        .or_else(|| value.get("updated_at"))
        .or_else(|| value.get("time"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn task_progress_is_active(status: &str) -> bool {
    matches!(
        status.trim().to_ascii_lowercase().as_str(),
        "active" | "running" | "in_progress" | "pending" | "downloading" | "installing" | "queued"
    )
}

fn task_progress_has_failure_status(status: &str) -> bool {
    matches!(
        status
            .trim()
            .to_ascii_lowercase()
            .replace('_', "-")
            .as_str(),
        "aborted"
            | "blocked"
            | "canceled"
            | "cancelled"
            | "error"
            | "failed"
            | "interrupted"
            | "stalled"
            | "timed-out"
            | "timeout"
            | "unavailable"
    )
}

fn task_progress_priority(status: &str) -> u8 {
    if task_progress_has_failure_status(status) {
        0
    } else if task_progress_is_active(status) {
        1
    } else {
        2
    }
}

fn normalize_task_progress_item(value: &Value) -> Value {
    let progress = value.get("progress").and_then(Value::as_object);
    let percent = progress
        .and_then(|object| object.get("percent"))
        .or_else(|| value.get("percent"))
        .and_then(Value::as_f64)
        .map(|value| value.clamp(0.0, 100.0));
    let current = progress
        .and_then(|object| object.get("current"))
        .or_else(|| value.get("current"))
        .and_then(Value::as_i64);
    let total = progress
        .and_then(|object| object.get("total"))
        .or_else(|| value.get("total"))
        .and_then(Value::as_i64);
    let unit = progress
        .and_then(|object| object.get("unit"))
        .or_else(|| value.get("unit"))
        .and_then(Value::as_str)
        .unwrap_or("items");
    let metrics = value.get("metrics").and_then(Value::as_object);
    let mut item = json!({
        "taskId": safe_task_progress_text(value.get("taskId").or_else(|| value.get("task_id")).and_then(Value::as_str).unwrap_or("unknown"), 120),
        "title": safe_task_progress_text(value.get("title").and_then(Value::as_str).unwrap_or("Task"), 80),
        "kind": safe_task_progress_text(value.get("kind").and_then(Value::as_str).unwrap_or("task"), 40),
        "status": safe_task_progress_text(value.get("status").and_then(Value::as_str).unwrap_or("unknown"), 32),
        "summary": safe_task_progress_text(value.get("summary").and_then(Value::as_str).unwrap_or(""), 180),
        "detail": safe_task_progress_text(value.get("detail").and_then(Value::as_str).unwrap_or(""), 180),
        "progress": {
            "percent": percent,
            "current": current,
            "total": total,
            "unit": safe_task_progress_text(unit, 32)
        },
        "metrics": {
            "elapsed": safe_task_progress_text(metrics.and_then(|object| object.get("elapsed")).and_then(Value::as_str).unwrap_or(""), 32),
            "eta": safe_task_progress_text(metrics.and_then(|object| object.get("eta")).and_then(Value::as_str).unwrap_or(""), 32),
            "speed": safe_task_progress_text(metrics.and_then(|object| object.get("speed")).and_then(Value::as_str).unwrap_or(""), 48),
            "itemsPerSecond": metrics.and_then(|object| object.get("itemsPerSecond")).and_then(Value::as_f64)
        },
        "startedAt": safe_optional_task_progress_text(value.get("startedAt").or_else(|| value.get("started_at")), 64),
        "updatedAt": safe_optional_task_progress_text(value.get("updatedAt").or_else(|| value.get("updated_at")), 64),
        "safeForHarvisBar": true
    });
    if let Some(source) = value.get("source").and_then(Value::as_object) {
        item["source"] = json!({
            "kind": safe_task_progress_text(source.get("kind").and_then(Value::as_str).unwrap_or("unknown"), 40),
            "id": safe_task_progress_text(source.get("id").and_then(Value::as_str).unwrap_or(""), 120)
        });
    }
    item
}

fn safe_task_progress_text(raw: &str, max_chars: usize) -> String {
    let trimmed = raw.trim();
    let redacted =
        if contains_absolute_path(trimmed) || contains_sensitive_task_progress_text(trimmed) {
            "[local-detail]"
        } else {
            trimmed
        };
    redacted.chars().take(max_chars).collect()
}

fn contains_sensitive_task_progress_text(raw: &str) -> bool {
    let lowered = raw.to_ascii_lowercase();
    let has_marker = [
        ".env",
        "api_key",
        "api-key",
        "apikey",
        "access_key",
        "access-key",
        "authorization",
        "bearer",
        "client_secret",
        "cookie",
        "credential",
        "password",
        "private key",
        "private_key",
        "secret",
        "token",
    ]
    .iter()
    .any(|marker| lowered.contains(marker));
    if has_marker {
        return true;
    }

    lowered
        .split(|ch: char| {
            ch.is_whitespace()
                || matches!(
                    ch,
                    '=' | ':' | ',' | ';' | '(' | ')' | '[' | ']' | '{' | '}' | '\'' | '"' | '`'
                )
        })
        .any(|candidate| {
            (candidate.starts_with("sk-") && candidate.len() >= 16)
                || candidate.starts_with("ghp_")
                || candidate.starts_with("github_pat_")
                || candidate.starts_with("glpat-")
                || candidate.starts_with("glpat_")
                || candidate.starts_with("npm_")
                || candidate.starts_with("pk_live_")
                || candidate.starts_with("rk_live_")
                || candidate.starts_with("xoxb-")
                || candidate.starts_with("xoxp-")
                || (candidate.starts_with("akia") && candidate.len() >= 16)
                || (candidate.starts_with("eyj")
                    && candidate.len() >= 32
                    && candidate.matches('.').count() == 2)
                || (candidate.len() >= 32
                    && candidate
                        .chars()
                        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_'))
                    && candidate.chars().any(|ch| ch.is_ascii_alphabetic())
                    && candidate.chars().any(|ch| ch.is_ascii_digit()))
        })
}

fn safe_optional_task_progress_text(value: Option<&Value>, max_chars: usize) -> Value {
    value
        .and_then(Value::as_str)
        .map(|text| Value::String(safe_task_progress_text(text, max_chars)))
        .unwrap_or(Value::Null)
}

fn contains_absolute_path(raw: &str) -> bool {
    let normalized = raw.replace("\\/", "/");
    if normalized.contains("file:///") {
        return true;
    }

    let chars = normalized.chars().collect::<Vec<_>>();
    let has_posix_absolute = chars.iter().enumerate().any(|(index, ch)| {
        if *ch != '/' || chars.get(index + 1) == Some(&'/') {
            return false;
        }
        index == 0
            || chars[index - 1].is_whitespace()
            || matches!(
                chars[index - 1],
                '=' | ':' | '(' | '[' | '{' | ',' | ';' | '\'' | '"' | '`'
            )
    });
    has_posix_absolute
        || normalized
            .as_bytes()
            .windows(3)
            .enumerate()
            .any(|(index, window)| {
                let boundary = index == 0
                    || normalized.as_bytes()[index - 1].is_ascii_whitespace()
                    || matches!(
                        normalized.as_bytes()[index - 1],
                        b'=' | b':' | b'(' | b'[' | b'{' | b',' | b';' | b'\'' | b'"' | b'`'
                    );
                boundary
                    && window[0].is_ascii_alphabetic()
                    && window[1] == b':'
                    && matches!(window[2], b'/' | b'\\')
            })
}

fn build_bar_status(root: &Path, profile_root: Option<&Path>) -> Result<(Value, Vec<String>)> {
    let profile_root = profile_root
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("~/.harvis"));
    let harvis_dir = root.join(".harvis");
    let (status, _, status_source) = read_runtime_json_object(root, "status.json", &profile_root);
    let (event_path, _) = existing_runtime_path(root, "events.jsonl", &profile_root);
    let counts = packet_counts(&harvis_dir.join("outbox"));
    let packets: usize = counts.values().sum();
    let blocked = *counts.get("blocked").unwrap_or(&0);
    let pending_approvals = pending_approval_count(&harvis_dir.join("approvals"));
    let (run_count, active_run) = run_summary(&harvis_dir.join("runs"));
    let errors = count_status_list(&status, "errors");
    let runtime_warnings = count_status_list(&status, "warnings");
    let state = if pending_approvals > 0 {
        "waiting_approval"
    } else if errors > 0 || blocked > 0 {
        "blocked"
    } else if status.get("last_tick_at").and_then(Value::as_str).is_some() {
        "verified"
    } else {
        "idle"
    };
    let last_tick_at = status.get("last_tick_at").and_then(Value::as_str);
    let allowlist_count = status
        .get("allowlist")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);
    let configured =
        harvis_dir.exists() || runtime_fallback_path(root, "status.json", &profile_root).exists();
    let (task_progress, task_progress_warnings) = task_progress_status(root, 5, false)?;
    Ok((
        json!({
            "schemaVersion": "harvis.bar-status.v0",
            "safeForHarvisBar": true,
            "generatedAt": harvis_core::time::now_rfc3339()?,
            "runtime": {
                "name": "H.A.R.V.I.S.",
                "state": state,
                "mode": status.get("mode").and_then(Value::as_str).unwrap_or("not-initialized"),
                "autonomyLevel": status.get("autonomy_level").and_then(Value::as_i64).unwrap_or(1).clamp(0, 4),
                "version": BAR_STATUS_VERSION,
                "sourceRuntimeVersion": status.get("runtime_version").cloned().unwrap_or(Value::Null),
                "summary": derive_summary(state, packets, blocked, pending_approvals, errors + runtime_warnings)
            },
            "workspace": {
                "label": public_workspace_label(root),
                "rootDisplay": public_workspace_label(root),
                "configured": configured,
                "statusPresent": status.is_object() && !status.as_object().is_some_and(Map::is_empty),
                "allowlistCount": allowlist_count,
                "stateStore": status_source
            },
            "serviceHealth": {
                "http": "running",
                "tickRunner": if status.is_object() && !status.as_object().is_some_and(Map::is_empty) {
                    if errors > 0 || blocked > 0 { "warning" } else { "idle" }
                } else {
                    "not-initialized"
                },
                "mcp": "available"
            },
            "work": {
                "packets": packets,
                "packetStatusCounts": counts,
                "blocked": blocked,
                "pendingApprovals": pending_approvals,
                "runtimeErrors": errors,
                "runtimeWarnings": runtime_warnings,
                "runs": run_count,
                "activeRun": active_run,
                "lastTickAt": last_tick_at,
                "lastEvent": event_path.and_then(|path| read_last_event(&path))
            },
            "knowledge": {
                "hub": "available",
                "wiki": "available",
                "activeSources": [],
                "allowlistedSources": 0,
                "lastLookupAt": null,
                "policy": "redacted-rust-runtime",
                "redacted": true,
                "includesLocalAbsolutePaths": false
            },
            "agentMail": integration_agent_mail_status(),
            "agentHarnesses": agent_harness_status(false),
            "ports": local_ports_status(),
            "taskProgress": task_progress,
            "safety": {
                "redacted": true,
                "includesSecrets": false,
                "includesRawMemory": false,
                "includesCredentialPaths": false,
                "includesLocalAbsolutePaths": false,
                "networkExposure": "localhost-only"
            }
        }),
        task_progress_warnings,
    ))
}

fn agent_harness_status(run_tests: bool) -> Value {
    build_agent_harness_status(run_tests, 120)
}

fn profile_metadata(profile_root: &Path) -> Value {
    let root = expanduser(profile_root);
    let resolved = root.canonicalize().unwrap_or(root);
    let mut files = Vec::new();
    let mut missing = Vec::new();
    for relative_path in PROFILE_FILES {
        let path = resolved.join(relative_path);
        if path.exists() {
            files.push(json!({
                "path": relative_path,
                "bytes": path.metadata().map(|metadata| metadata.len()).unwrap_or(0),
                "modified_at": modified_secs(&path)
            }));
        } else {
            missing.push((*relative_path).to_string());
        }
    }
    json!({"root": resolved.display().to_string(), "exists": resolved.exists(), "files": files, "missing": missing})
}

fn permission_probe(root: &Path, profile_root: &Path) -> Value {
    let harvis_dir = root.join(".harvis");
    let profile_root = expanduser(profile_root);
    let mut checks = Vec::new();
    checks.push(probe_dir("workspace-root", root));
    checks.push(probe_dir("workspace-harvis", &harvis_dir));
    checks.push(probe_dir("profile-root", &profile_root));
    let ok = checks
        .iter()
        .all(|check| check.get("ok").and_then(Value::as_bool).unwrap_or(false));
    json!({
        "permission_probe_version": "v0.36-rust-alpha",
        "ok": ok,
        "context": "rust-http-api",
        "checks": checks,
        "redacted": true,
        "includesLocalAbsolutePaths": false
    })
}

fn lightweight_permission_probe(root: &str) -> Value {
    json!({
        "permission_probe_version": "v0.40-rust-alpha",
        "ok": true,
        "context": "rust-http-api-lightweight",
        "root": root,
        "checks": [],
        "redacted": true,
        "includesLocalAbsolutePaths": false,
        "writesSkipped": true
    })
}

fn timeout_permission_probe(root: &str) -> Value {
    json!({
        "permission_probe_version": "v0.40-rust-alpha",
        "ok": false,
        "context": "rust-http-api-permission-timeout",
        "root": root,
        "checks": [],
        "redacted": true,
        "includesLocalAbsolutePaths": false,
        "writesSkipped": true,
        "permission_timeout": true
    })
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

fn read_runtime_json_object(
    root: &Path,
    relative_path: &str,
    profile_root: &Path,
) -> (Value, Option<PathBuf>, &'static str) {
    let primary = root.join(".harvis").join(relative_path);
    if let Some(value) = read_json_object(&primary) {
        return (value, Some(primary), "workspace");
    }
    let fallback = runtime_fallback_path(root, relative_path, profile_root);
    if let Some(value) = read_json_object(&fallback) {
        return (value, Some(fallback), "profile-fallback");
    }
    (json!({}), None, "missing")
}

fn existing_runtime_path(
    root: &Path,
    relative_path: &str,
    profile_root: &Path,
) -> (Option<PathBuf>, &'static str) {
    let primary = root.join(".harvis").join(relative_path);
    if primary.exists() {
        return (Some(primary), "workspace");
    }
    let fallback = runtime_fallback_path(root, relative_path, profile_root);
    if fallback.exists() {
        return (Some(fallback), "profile-fallback");
    }
    (None, "missing")
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
    expanduser(profile_root)
        .join("state/workspaces")
        .join(workspace_state_id(root))
        .join(rel_path)
}

fn workspace_state_id(root: &Path) -> String {
    use sha2::{Digest, Sha256};
    let resolved = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let digest = Sha256::digest(resolved.display().to_string().as_bytes());
    let digest = digest
        .iter()
        .take(6)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let label = public_workspace_label(&resolved);
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

fn packet_counts(outbox_dir: &Path) -> BTreeMap<String, usize> {
    let mut counts = BTreeMap::new();
    let Ok(entries) = fs::read_dir(outbox_dir) else {
        return counts;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) == Some("md") && path.is_file() {
            let status = parse_packet_status(&path);
            *counts.entry(status).or_insert(0) += 1;
        }
    }
    counts
}

fn pending_approval_count(approvals_dir: &Path) -> usize {
    let Ok(entries) = fs::read_dir(approvals_dir) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|entry| entry.path().extension().and_then(|value| value.to_str()) == Some("json"))
        .filter(|entry| approval_is_pending(&entry.path()))
        .count()
}

fn approval_is_pending(path: &Path) -> bool {
    let Some(value) = read_json_object(path) else {
        return false;
    };
    let state = value
        .get("status")
        .or_else(|| value.get("state"))
        .or_else(|| value.get("decision"))
        .and_then(Value::as_str)
        .unwrap_or("pending")
        .to_ascii_lowercase();
    matches!(
        state.as_str(),
        "pending"
            | "requested"
            | "waiting"
            | "waiting_approval"
            | "needs_review"
            | "needs-approval"
    )
}

fn run_summary(runs_dir: &Path) -> (usize, Value) {
    let mut paths = json_paths_by_mtime_desc(runs_dir).unwrap_or_default();
    let count = paths.len();
    let latest = paths
        .drain(..)
        .filter_map(|path| read_json_object(&path))
        .map(|run| {
            json!({
                "runId": run.get("run_id").cloned().unwrap_or(Value::Null),
                "state": run.get("state").cloned().unwrap_or(Value::Null),
                "mode": run.get("mode").cloned().unwrap_or(Value::Null),
                "packetId": run.get("packet_id").cloned().unwrap_or(Value::Null),
                "updatedAt": run.get("updated_at").cloned().unwrap_or(Value::Null)
            })
        })
        .next()
        .unwrap_or(Value::Null);
    (count, latest)
}

fn read_last_event(path: &Path) -> Option<Value> {
    let text = fs::read_to_string(path).ok()?;
    text.lines().rev().find_map(|line| {
        let loaded = serde_json::from_str::<Value>(line).ok()?;
        loaded.is_object().then(|| {
            json!({
                "type": loaded.get("type").and_then(Value::as_str).unwrap_or("unknown"),
                "status": loaded.get("status").and_then(Value::as_str).unwrap_or("unknown"),
                "at": loaded.get("at").cloned().unwrap_or(Value::Null)
            })
        })
    })
}

fn derive_summary(
    state: &str,
    packets: usize,
    blocked: usize,
    pending_approvals: usize,
    runtime_issues: usize,
) -> String {
    match state {
        "waiting_approval" => format!("{pending_approvals} approval item(s) need review."),
        "blocked" => {
            format!("{blocked} blocked packet(s), {runtime_issues} runtime issue(s) need review.")
        }
        "verified" => format!("Runtime synchronized with {packets} packet(s)."),
        _ => "Runtime is idle or not initialized.".to_string(),
    }
}

fn count_status_list(status: &Value, key: &str) -> usize {
    status
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0)
}

fn read_json_object(path: &Path) -> Option<Value> {
    let text = fs::read_to_string(path).ok()?;
    let value = serde_json::from_str::<Value>(&text).ok()?;
    value.is_object().then_some(value)
}

fn read_jsonl_objects_result(path: &Path, limit: Option<usize>) -> Result<Vec<Value>> {
    let text = read_to_string_with_timeout(path, Duration::from_secs(2))?;
    let mut lines: Vec<&str> = text.lines().collect();
    if let Some(limit) = limit {
        if lines.len() > limit {
            lines = lines.split_off(lines.len() - limit);
        }
    }
    Ok(lines
        .into_iter()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .collect())
}

fn read_runtime_jsonl_objects_result(
    root: &Path,
    relative_path: impl AsRef<Path>,
    profile_root: &Path,
    limit: Option<usize>,
) -> Result<(Vec<Value>, PathBuf, &'static str)> {
    let relative_path = relative_path.as_ref();
    let fallback = runtime_fallback_path(root, relative_path, profile_root);
    if fallback.exists() {
        if let Ok(items) = read_jsonl_objects_result(&fallback, limit) {
            return Ok((items, fallback, "profile-fallback"));
        }
    }

    let primary = root.join(".harvis").join(relative_path);
    match read_jsonl_objects_result(&primary, limit) {
        Ok(items) => Ok((items, primary, "workspace")),
        Err(primary_error) => {
            if fallback.exists() {
                let items = read_jsonl_objects_result(&fallback, limit).with_context(|| {
                    format!("workspace read failed and fallback read failed: {primary_error}")
                })?;
                Ok((items, fallback, "profile-fallback"))
            } else {
                Err(primary_error)
            }
        }
    }
}

fn read_jsonl_objects_with_runtime_fallback(
    root: &Path,
    path: &Path,
    profile_root: &Path,
    limit: Option<usize>,
) -> Result<(Vec<Value>, PathBuf, &'static str)> {
    if let Some(relative_path) = runtime_relative_path(root, path) {
        return read_runtime_jsonl_objects_result(root, relative_path, profile_root, limit);
    }
    let items = read_jsonl_objects_result(path, limit)?;
    Ok((items, path.to_path_buf(), "direct"))
}

fn runtime_relative_path(root: &Path, path: &Path) -> Option<PathBuf> {
    let harvis_root = root.join(".harvis");
    if path.is_absolute() {
        path.strip_prefix(&harvis_root).ok().map(PathBuf::from)
    } else if path
        .components()
        .next()
        .map(|component| component.as_os_str())
        == Some(std::ffi::OsStr::new(".harvis"))
    {
        Some(path.components().skip(1).collect())
    } else {
        None
    }
}

fn read_to_string_with_timeout(path: &Path, duration: Duration) -> Result<String> {
    let path = path.to_path_buf();
    let display = path.display().to_string();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(fs::read_to_string(path));
    });
    match rx.recv_timeout(duration) {
        Ok(Ok(text)) => Ok(text),
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Ok(Err(error)) => Err(error).with_context(|| format!("failed to read JSONL file: {display}")),
        Err(mpsc::RecvTimeoutError::Timeout) => bail!(
            "timed out reading JSONL file after {}ms: {display}. If this path is on /Volumes, grant Full Disk Access to the H.A.R.V.I.S. runtime or run the HTTP service in the foreground user session.",
            duration.as_millis()
        ),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            bail!("JSONL reader disconnected before reading file: {display}")
        }
    }
}

fn recent_child_file_paths(root: &Path, file_name: &str, max_dirs: usize) -> Result<Vec<PathBuf>> {
    Ok(recent_child_dirs(root, max_dirs)?
        .into_iter()
        .map(|dir| dir.join(file_name))
        .filter(|path| path.is_file())
        .collect())
}

fn recent_child_dirs(root: &Path, max_dirs: usize) -> Result<Vec<PathBuf>> {
    let mut dirs = read_child_dirs_with_timeout(root, Duration::from_secs(2))?;
    dirs.sort_by(|left, right| right.cmp(left));
    dirs.truncate(max_dirs);
    Ok(dirs)
}

fn read_child_dirs_with_timeout(root: &Path, duration: Duration) -> Result<Vec<PathBuf>> {
    let root = root.to_path_buf();
    let display = root.display().to_string();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || -> () {
        let result = (|| -> std::io::Result<Vec<PathBuf>> {
            let mut dirs = Vec::new();
            let entries = match fs::read_dir(&root) {
                Ok(entries) => entries,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(dirs),
                Err(error) => return Err(error),
            };
            for entry in entries {
                let entry = entry?;
                if entry.file_type()?.is_dir() {
                    dirs.push(entry.path());
                }
            }
            Ok(dirs)
        })();
        let _ = tx.send(result);
    });
    match rx.recv_timeout(duration) {
        Ok(Ok(dirs)) => Ok(dirs),
        Ok(Err(error)) => Err(error).with_context(|| format!("failed to read directory: {display}")),
        Err(mpsc::RecvTimeoutError::Timeout) => bail!(
            "timed out reading directory after {}ms: {display}. If this path is on /Volumes, grant Full Disk Access to the H.A.R.V.I.S. runtime or run the HTTP service in the foreground user session.",
            duration.as_millis()
        ),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            bail!("directory reader disconnected before reading path: {display}")
        }
    }
}

fn enrich_with_codex_event_state(mut item: Value) -> Value {
    let event = item
        .get("events_jsonl")
        .and_then(Value::as_str)
        .and_then(|path| read_last_jsonl_object(Path::new(path)));
    if let (Some(object), Some(event)) = (item.as_object_mut(), event) {
        let event_type = event
            .get("codex_event_type")
            .or_else(|| event.get("type"))
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        object
            .entry("last_event_type".to_string())
            .or_insert_with(|| Value::String(event_type.clone()));
        if let Some(at) = event
            .get("observed_at")
            .or_else(|| event.get("created_at"))
            .or_else(|| event.get("at"))
            .cloned()
        {
            object.entry("last_event_at".to_string()).or_insert(at);
        }
        object
            .entry("status".to_string())
            .or_insert_with(|| Value::String(codex_status_from_event(&event_type)));
        if let Some(summary) = event.get("summary").and_then(Value::as_str) {
            object
                .entry("last_event_summary".to_string())
                .or_insert_with(|| Value::String(summary.chars().take(500).collect()));
        }
    }
    item
}

fn read_last_jsonl_object(path: &Path) -> Option<Value> {
    let text = read_to_string_with_timeout(path, Duration::from_secs(2)).ok()?;
    text.lines()
        .rev()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(Value::is_object)
}

fn codex_status_from_event(event_type: &str) -> String {
    match event_type {
        "turn.completed" | "adapter.completed" => "completed",
        "turn.failed" | "adapter.failed" => "failed",
        "adapter.started" | "thread.started" | "item.started" => "in_progress",
        "item.completed" | "agent_message" => "running",
        _ => "unknown",
    }
    .to_string()
}

fn value_time_key(value: &Value) -> String {
    [
        "updated_at",
        "last_event_at",
        "created_at",
        "observed_at",
        "timestamp",
        "at",
    ]
    .iter()
    .find_map(|key| value.get(*key).and_then(Value::as_str))
    .unwrap_or_default()
    .to_string()
}

fn value_id_key(value: &Value) -> String {
    [
        "codex_thread_id",
        "codex_session_id",
        "run_id",
        "task_id",
        "handoff_id",
        "packet_id",
        "conversation_key",
    ]
    .iter()
    .find_map(|key| value.get(*key).and_then(Value::as_str))
    .unwrap_or_default()
    .to_string()
}

fn parse_packet_status(path: &Path) -> String {
    let Ok(text) = fs::read_to_string(path) else {
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

fn md_paths_by_mtime_desc(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) == Some("md") && path.is_file() {
            paths.push(path);
        }
    }
    paths.sort_by(|left, right| {
        modified_secs(right)
            .cmp(&modified_secs(left))
            .then_with(|| left.cmp(right))
    });
    Ok(paths)
}

fn json_paths_by_mtime_desc(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    if !dir.exists() {
        return Ok(paths);
    }
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().and_then(|value| value.to_str()) == Some("json") && path.is_file() {
            paths.push(path);
        }
    }
    paths.sort_by(|left, right| {
        modified_secs(right)
            .cmp(&modified_secs(left))
            .then_with(|| left.cmp(right))
    });
    Ok(paths)
}

fn modified_secs(path: &Path) -> u64 {
    path.metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn public_workspace_label(root: &Path) -> String {
    root.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("workspace")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use harvis_runtime::init::init_workspace;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    fn spawn_webview_fixture(body: Value) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind fixture");
        let addr = listener.local_addr().expect("fixture addr");
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept fixture");
            let mut buffer = [0_u8; 1024];
            let _ = stream.read(&mut buffer);
            let body = body.to_string();
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            stream
                .write_all(response.as_bytes())
                .expect("write fixture response");
        });
        format!("http://{addr}/")
    }

    async fn response_json(response: Response) -> Value {
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("response body");
        serde_json::from_slice(&body).expect("response JSON")
    }

    #[test]
    fn task_progress_missing_store_is_idle() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-missing-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("fixture root");

        let (status, warnings) =
            task_progress_status(&root, 20, true).expect("missing store is optional");
        assert_eq!(status["status"], "idle");
        assert_eq!(status["activeCount"], 0);
        assert_eq!(status["items"], json!([]));
        assert_eq!(status["current"], Value::Null);
        assert!(warnings.is_empty());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_progress_permission_denied_is_skipped_without_local_details() {
        let denied = io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Operation not permitted: /sensitive/task-progress",
        );
        let (status, warnings) = task_progress_status_from_read_dir(Err(denied), 20, true)
            .expect("permission denial is a local optional-store degradation");
        let rendered = serde_json::to_string(&(status.clone(), warnings.clone())).expect("JSON");

        assert_eq!(status["status"], "skipped");
        assert_eq!(status["activeCount"], 0);
        assert_eq!(status["items"], json!([]));
        assert_eq!(status["current"], Value::Null);
        assert_eq!(warnings, vec![TASK_PROGRESS_UNAVAILABLE_WARNING]);
        assert!(!rendered.contains("/sensitive/"));
        assert!(!rendered.contains("Operation not permitted"));
    }

    #[test]
    fn task_progress_other_open_error_is_also_locally_skipped() {
        let failure = io::Error::other("device failed at /sensitive/task-progress");
        let (status, warnings) = task_progress_status_from_read_dir(Err(failure), 20, true)
            .expect("all optional-store open failures are locally degraded");
        let rendered = serde_json::to_string(&(status.clone(), warnings.clone())).expect("JSON");

        assert_eq!(status["status"], "skipped");
        assert_eq!(status["items"], json!([]));
        assert_eq!(warnings, vec![TASK_PROGRESS_UNAVAILABLE_WARNING]);
        assert!(!rendered.contains("/sensitive/"));
        assert!(!rendered.contains("device failed"));
    }

    #[test]
    fn task_progress_invalid_json_is_skipped_with_warning() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-invalid-json-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let store = task_progress_dir(&root);
        fs::create_dir_all(&store).expect("create task progress store");
        fs::write(store.join("broken.json"), "not-json").expect("write invalid record");

        let (status, warnings) =
            task_progress_status(&root, 20, true).expect("invalid optional store is degraded");

        assert_eq!(status["status"], "skipped");
        assert_eq!(status["activeCount"], 0);
        assert_eq!(status["items"], json!([]));
        assert_eq!(status["current"], Value::Null);
        assert_eq!(warnings, vec![TASK_PROGRESS_UNAVAILABLE_WARNING]);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_progress_cancelled_scan_degrades_without_returning_partial_rows() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-cancelled-scan-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let store = task_progress_dir(&root);
        fs::create_dir_all(&store).expect("create task progress store");
        fs::write(
            store.join("active.json"),
            r#"{"taskId":"active","status":"running"}"#,
        )
        .expect("write task progress record");
        let cancelled = AtomicBool::new(true);

        let (status, warnings) =
            task_progress_status_with_cancel(&root, 20, true, Some(&cancelled))
                .expect("cancelled optional store is degraded");

        assert_eq!(status["status"], "skipped");
        assert_eq!(status["items"], json!([]));
        assert_eq!(warnings, vec![TASK_PROGRESS_UNAVAILABLE_WARNING]);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_progress_scan_budget_degrades_instead_of_returning_partial_rows() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-scan-budget-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let store = task_progress_dir(&root);
        fs::create_dir_all(&store).expect("create task progress store");
        for index in 0..=TASK_PROGRESS_SCAN_ENTRY_LIMIT {
            fs::write(
                store.join(format!("record-{index:04}.json")),
                format!(r#"{{"taskId":"record-{index:04}","status":"running"}}"#),
            )
            .expect("write bounded scan fixture");
        }

        let (status, warnings) =
            task_progress_status(&root, 20, true).expect("oversized store is degraded");

        assert_eq!(status["status"], "skipped");
        assert_eq!(status["items"], json!([]));
        assert_eq!(warnings, vec![TASK_PROGRESS_UNAVAILABLE_WARNING]);

        let _ = fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn task_progress_symlink_record_is_skipped_without_reading_target() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-read-symlink-{}",
            std::process::id()
        ));
        let outside = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-read-target-{}.json",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_file(&outside);
        let store = task_progress_dir(&root);
        fs::create_dir_all(&store).expect("create task progress store");
        fs::write(
            &outside,
            r#"{"taskId":"outside","status":"running","summary":"do not read"}"#,
        )
        .expect("write outside target");
        symlink(&outside, store.join("linked.json")).expect("create record symlink");

        let (status, warnings) =
            task_progress_status(&root, 20, true).expect("symlink record is degraded");

        assert_eq!(status["status"], "skipped");
        assert_eq!(status["items"], json!([]));
        assert_eq!(warnings, vec![TASK_PROGRESS_UNAVAILABLE_WARNING]);

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_file(outside);
    }

    #[cfg(unix)]
    #[test]
    fn task_progress_post_rejects_record_symlink_without_overwriting_target() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-write-symlink-{}",
            std::process::id()
        ));
        let outside = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-write-target-{}.json",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_file(&outside);
        let store = task_progress_dir(&root);
        fs::create_dir_all(&store).expect("create task progress store");
        fs::write(&outside, "preserve-me").expect("write outside target");
        symlink(&outside, store.join("linked.json")).expect("create record symlink");

        let error = upsert_task_progress(
            &root,
            &json!({
                "taskId": "linked",
                "title": "Safe title",
                "status": "running"
            }),
        )
        .expect_err("record symlink must be rejected");

        assert!(error.to_string().contains("regular non-symlink file"));
        assert_eq!(fs::read_to_string(&outside).unwrap(), "preserve-me");

        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_file(outside);
    }

    #[test]
    fn task_progress_post_rejects_corrupt_existing_record_without_overwriting_it() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-write-corrupt-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let store = task_progress_dir(&root);
        fs::create_dir_all(&store).expect("create task progress store");
        let record = store.join("existing.json");
        fs::write(&record, "preserve-invalid-content").expect("write corrupt record");

        let error = upsert_task_progress(
            &root,
            &json!({
                "taskId": "existing",
                "title": "Safe title",
                "status": "running"
            }),
        )
        .expect_err("corrupt existing record must fail closed");

        assert!(error
            .to_string()
            .contains("parse existing task progress record"));
        assert_eq!(
            fs::read_to_string(&record).unwrap(),
            "preserve-invalid-content"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_progress_post_rejects_oversize_create_and_update_without_persisting_them() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-write-oversize-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create fixture root");
        let oversized = "x".repeat(TASK_PROGRESS_RECORD_SIZE_LIMIT as usize);

        let create_error = upsert_task_progress(
            &root,
            &json!({
                "taskId": "oversize-create",
                "title": "Oversize create",
                "status": "running",
                "detail": oversized
            }),
        )
        .expect_err("oversize create must fail closed");
        assert!(create_error.to_string().contains("exceeds the size limit"));
        assert!(!task_progress_dir(&root)
            .join("oversize-create.json")
            .exists());

        upsert_task_progress(
            &root,
            &json!({
                "taskId": "oversize-update",
                "title": "Preserved record",
                "status": "running"
            }),
        )
        .expect("write baseline record");
        let record = task_progress_dir(&root).join("oversize-update.json");
        let before = fs::read(&record).expect("read baseline record");

        let update_error = upsert_task_progress(
            &root,
            &json!({
                "taskId": "oversize-update",
                "detail": "y".repeat(TASK_PROGRESS_RECORD_SIZE_LIMIT as usize)
            }),
        )
        .expect_err("oversize update must fail closed");
        assert!(update_error.to_string().contains("exceeds the size limit"));
        assert_eq!(fs::read(&record).expect("read preserved record"), before);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn task_progress_text_redacts_secret_patterns_and_embedded_local_paths() {
        for sensitive in [
            "OPENAI_API_KEY=sk-example12345678901234567890",
            "ghp_123456789012345678901234567890123456", // gitleaks:allow -- synthetic redaction regression input
            "glpat-example12345678901234567890", // gitleaks:allow -- synthetic redaction regression input
            "npm_example123456789012345678901234567890",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature",
            "opaqueABCDEF1234567890abcdef1234567890",
            "file:///Users/example/private.txt",
            r#"{"path":"/Users/example/private.txt"}"#,
            r#"{"path":"\/Volumes\/External\/private.txt"}"#,
        ] {
            assert_eq!(safe_task_progress_text(sensitive, 180), "[local-detail]");
        }
        assert_eq!(
            safe_task_progress_text("task-progress at https://example.com/docs", 180),
            "task-progress at https://example.com/docs"
        );
        assert_eq!(
            safe_task_progress_text("https://example.com/Users/profile", 180),
            "https://example.com/Users/profile"
        );
    }

    #[test]
    fn map_error_classifies_wrapped_io_errors_without_leaking_paths() {
        let denied = anyhow::Error::new(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "denied /sensitive/task-progress.json",
        ))
        .context("write task progress record");
        let denied = map_error(denied);
        assert_eq!(denied.code, "permission_denied");
        assert_eq!(denied.status, StatusCode::FORBIDDEN);
        assert_eq!(denied.message, "filesystem permission denied");
        assert!(!denied.message.contains("/sensitive/"));

        let missing = map_error(anyhow::Error::new(io::Error::new(
            io::ErrorKind::NotFound,
            "missing /sensitive/item",
        )));
        assert_eq!(missing.code, "not_found");
        assert_eq!(missing.status, StatusCode::NOT_FOUND);
        assert_eq!(missing.message, "requested filesystem resource not found");
    }

    #[tokio::test]
    async fn task_progress_get_missing_store_returns_200_idle_envelope() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-get-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("fixture root");
        let query = HashMap::from([("root".to_string(), root.display().to_string())]);

        let response = task_progress_get(Query(query)).await;
        assert_eq!(response.status(), StatusCode::OK);
        let payload = response_json(response).await;
        assert_eq!(payload["ok"], true);
        assert_eq!(payload["endpoint"], "/task-progress");
        assert_eq!(payload["data"]["status"], "idle");
        assert_eq!(payload["data"]["items"], json!([]));
        assert_eq!(payload["data"]["current"], Value::Null);
        assert_eq!(payload["warnings"], json!([]));

        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn task_progress_get_rejects_include_local() {
        let query = HashMap::from([
            (
                "root".to_string(),
                std::env::temp_dir().display().to_string(),
            ),
            ("include_local".to_string(), "true".to_string()),
        ]);

        let response = task_progress_get(Query(query)).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let payload = response_json(response).await;
        assert_eq!(payload["ok"], false);
        assert_eq!(payload["error"]["code"], "invalid_request");
        assert_eq!(payload["data"], Value::Null);
    }

    #[tokio::test]
    async fn task_progress_get_permission_degradation_returns_200_warning_envelope() {
        let denied = io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Operation not permitted: /sensitive/task-progress",
        );
        let result = task_progress_status_from_read_dir(Err(denied), 20, true);
        let response = task_progress_get_response(result);

        assert_eq!(response.status(), StatusCode::OK);
        let payload = response_json(response).await;
        assert_eq!(payload["ok"], true);
        assert_eq!(payload["data"]["status"], "skipped");
        assert_eq!(payload["data"]["items"], json!([]));
        assert_eq!(payload["data"]["current"], Value::Null);
        assert_eq!(
            payload["warnings"],
            json!([TASK_PROGRESS_UNAVAILABLE_WARNING])
        );
        let rendered = serde_json::to_string(&payload).expect("JSON");
        assert!(!rendered.contains("/sensitive/"));
        assert!(!rendered.contains("Operation not permitted"));
    }

    #[tokio::test]
    async fn task_progress_post_then_get_round_trip_is_redacted() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-task-progress-round-trip-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("fixture root");

        let response = task_progress_post(Json(json!({
            "root": root.display().to_string(),
            "taskId": "release-check",
            "title": "Release check",
            "status": "running",
            "summary": "safe summary",
            "detail": "/sensitive/detail",
            "progress": {"current": 1, "total": 4, "unit": "checks"}
        })))
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let post_payload = response_json(response).await;
        assert_eq!(post_payload["data"]["stored"], true);
        assert_eq!(post_payload["data"]["task"]["detail"], "[local-detail]");

        let query = HashMap::from([("root".to_string(), root.display().to_string())]);
        let response = task_progress_get(Query(query)).await;
        assert_eq!(response.status(), StatusCode::OK);
        let get_payload = response_json(response).await;
        assert_eq!(get_payload["data"]["status"], "active");
        assert_eq!(get_payload["data"]["activeCount"], 1);
        assert_eq!(get_payload["data"]["current"]["taskId"], "release-check");
        assert_eq!(get_payload["data"]["current"]["detail"], "[local-detail]");
        assert_eq!(
            get_payload["data"]["safety"]["includesLocalAbsolutePaths"],
            false
        );

        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn task_progress_post_permission_denied_returns_403_redacted_envelope() {
        let error = anyhow::Error::new(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "denied /sensitive/task-progress.json",
        ))
        .context("write task progress record");
        let response = task_progress_post_response(Err(error));

        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        let payload = response_json(response).await;
        assert_eq!(payload["ok"], false);
        assert_eq!(payload["error"]["code"], "permission_denied");
        assert_eq!(payload["error"]["message"], "filesystem permission denied");
        let rendered = serde_json::to_string(&payload).expect("JSON");
        assert!(!rendered.contains("/sensitive/"));
        assert!(!rendered.contains("denied /"));
    }

    #[test]
    fn bar_status_keeps_full_contract_when_task_progress_store_is_invalid() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-bar-task-progress-degraded-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        fs::write(root.join(".harvis/task-progress"), "not a directory")
            .expect("invalid optional store fixture");

        let (status, warnings) =
            build_bar_status(&root.canonicalize().unwrap(), None).expect("bar status");
        let rendered = serde_json::to_string(&(status.clone(), warnings.clone())).expect("JSON");

        assert_eq!(status["safeForHarvisBar"], true);
        assert_eq!(status["taskProgress"]["status"], "skipped");
        assert_eq!(status["taskProgress"]["items"], json!([]));
        assert_eq!(status["taskProgress"]["current"], Value::Null);
        assert_eq!(warnings, vec![TASK_PROGRESS_UNAVAILABLE_WARNING]);
        assert!(!rendered.contains(root.to_string_lossy().as_ref()));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn bar_status_keeps_recent_failure_visible_when_no_task_is_active() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-bar-task-progress-failure-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        upsert_task_progress(
            &root,
            &json!({
                "taskId": "failed-release-check",
                "title": "Release check",
                "status": "failed",
                "summary": "[failure] Release validation stopped"
            }),
        )
        .expect("write failed task progress fixture");

        let (status, warnings) =
            build_bar_status(&root.canonicalize().unwrap(), None).expect("bar status");

        assert!(warnings.is_empty());
        assert_eq!(status["taskProgress"]["activeCount"], 0);
        assert_eq!(status["taskProgress"]["current"]["status"], "failed");
        assert_eq!(status["taskProgress"]["items"][0]["status"], "failed");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn map_error_maps_other_io_to_redacted_runtime_error() {
        let mapped = map_error(anyhow::Error::new(io::Error::other(
            "device failed at /sensitive/task-progress",
        )));
        assert_eq!(mapped.code, "runtime_error");
        assert_eq!(mapped.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(mapped.message, "filesystem operation failed");
        assert!(!mapped.message.contains("/sensitive/"));
    }

    #[test]
    fn task_progress_worker_failures_are_internal_errors() {
        for operation in ["read", "update"] {
            let error = task_progress_worker_error(operation);
            assert_eq!(error.code, "runtime_error");
            assert_eq!(error.status, StatusCode::INTERNAL_SERVER_ERROR);
        }
    }

    #[test]
    fn bar_status_is_redacted_for_local_ui() {
        let root =
            std::env::temp_dir().join(format!("harvis-http-bar-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        fs::write(
            root.join(".harvis/status.json"),
            json!({
                "agent": "H.A.R.V.I.S.",
                "runtime_version": "v0.3-alpha",
                "autonomy_level": 1,
                "mode": "read-only",
                "last_tick_at": "2026-06-24T00:00:00+00:00",
                "allowlist": [".harvis/inbox.md"],
                "errors": []
            })
            .to_string(),
        )
        .expect("write status");
        let (status, warnings) =
            build_bar_status(&root.canonicalize().unwrap(), None).expect("bar status");
        let rendered = serde_json::to_string(&status).expect("json");
        let schema_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join("schemas/bar-status.schema.json");
        let schema: Value =
            serde_json::from_slice(&fs::read(schema_path).expect("read bar status schema"))
                .expect("parse bar status schema");
        let required = schema["required"]
            .as_array()
            .expect("bar status required fields");
        assert!(warnings.is_empty());
        assert_eq!(status["safeForHarvisBar"], true);
        assert_eq!(status["taskProgress"]["status"], "idle");
        assert_eq!(status["taskProgress"]["items"], json!([]));
        assert_eq!(status["safety"]["includesLocalAbsolutePaths"], false);
        assert!(status["ports"]["items"]
            .as_array()
            .expect("port registry items")
            .iter()
            .any(|item| item["id"] == "h5magic-office-workbench"));
        assert!(!rendered.contains(root.to_string_lossy().as_ref()));

        let (lightweight, lightweight_warnings) =
            lightweight_bar_status(&root, "fixture warning").expect("lightweight status");
        let lightweight_rendered = serde_json::to_string(&lightweight).expect("json");
        assert_eq!(lightweight["schemaVersion"], "harvis.bar-status.v0");
        assert_eq!(lightweight["safeForHarvisBar"], true);
        assert_eq!(
            lightweight["workspace"]["label"],
            public_workspace_label(&root)
        );
        assert_eq!(lightweight["taskProgress"]["status"], "skipped");
        assert_eq!(lightweight["safety"]["includesLocalAbsolutePaths"], false);
        assert_eq!(lightweight_warnings, vec!["fixture warning"]);
        assert!(!lightweight_rendered.contains(root.to_string_lossy().as_ref()));
        for field in required.iter().filter_map(Value::as_str) {
            assert!(status.get(field).is_some(), "full status missing {field}");
            assert!(
                lightweight.get(field).is_some(),
                "lightweight status missing {field}"
            );
        }
        assert!(lightweight["ports"]["items"]
            .as_array()
            .expect("lightweight port registry items")
            .iter()
            .any(|item| {
                item["id"] == "h5magic-agent-bridge"
                    && item["showInHarvisBar"] == true
                    && item["lifecycle"] == "on-demand"
            }));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn launchctl_listener_health_requires_running_state_and_numeric_pid() {
        assert!(launchctl_output_is_running(
            "service = local.harvis.lark\nstate = running\npid = 4242\n"
        ));
        assert!(!launchctl_output_is_running(
            "service = local.harvis.lark\nstate = exited\npid = 4242\n"
        ));
        assert!(!launchctl_output_is_running(
            "service = local.harvis.lark\nstate = running\nlast exit code = 1\n"
        ));
        assert!(!launchctl_output_is_running(
            "service = local.harvis.lark\nstate = running\npid = not-a-number\n"
        ));
    }

    #[tokio::test]
    async fn ui_integrations_rejects_sensitive_labels_and_defaults_live_evidence_unknown() {
        let root = std::env::temp_dir().join(format!(
            "harvis-http-ui-integrations-test-{}",
            std::process::id()
        ));
        let plugin_root = root.join("plugin");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("digital_me/registry")).expect("registry dir");
        fs::create_dir_all(plugin_root.join("ui")).expect("plugin ui dir");
        fs::write(
            root.join("digital_me/registry/harvis_lark_bridge.json"),
            json!({
                "consumer_chains": [{
                    "profile_role": "../../private/operator",
                    "source_role": "message_listener",
                    "event_type": "im.message.receive_v1",
                    "launch_label": ""
                }]
            })
            .to_string(),
        )
        .expect("registry fixture");
        fs::write(
            plugin_root.join("ui/t317-smoke.json"),
            json!({
                "mode": "live",
                "status": "verified",
                "observed_at": "2020-01-01T00:00:00Z",
                "live_complete": true,
                "scope_status": "verified",
                "membership_status": "verified",
                "source_commit": "0123456789abcdef0123456789abcdef01234567"
            })
            .to_string(),
        )
        .expect("stale smoke fixture");

        let output = build_ui_integrations(&root, &plugin_root)
            .await
            .expect("safe integration output");
        let rendered = serde_json::to_string(&output).expect("json");
        assert_eq!(
            output["lark"]["profiles"][0]["profile_role"],
            "unregistered"
        );
        assert_eq!(output["lark"]["scope_status"], "unknown");
        assert_eq!(output["lark"]["membership_status"], "unknown");
        assert_eq!(output["lark"]["smoke"]["live_complete"], false);
        assert_eq!(output["lark"]["smoke"]["status"], "stale");
        assert_eq!(
            output["lark"]["scope_membership_gaps"][0],
            "live_test_group_not_confirmed"
        );
        assert!(!rendered.contains("../../private"));
        assert!(!rendered.contains("chat_id"));
        assert!(!rendered.contains("message_id"));
        assert!(!rendered.contains("open_id"));
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn a2a_send_get_cancel_uses_agent_room_protocol() {
        let root =
            std::env::temp_dir().join(format!("harvis-http-a2a-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let root = root.canonicalize().expect("canonical root");
        let sent = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {
                "messageId": "msg-test",
                "parts": [{"text": "请 H.A.R.V.I.S. 建立一个可审计圆桌任务。"}]
            }
        }))
        .await
        .expect("send");
        let task_id = sent["id"].as_str().expect("task id").to_string();
        assert_eq!(sent["kind"], "task");
        assert_eq!(sent["contextId"], task_id);
        // LF A2A 1.0.0 §4.1.3: a freshly accepted task is SUBMITTED until the
        // room produces agent-side output.
        assert_eq!(sent["status"]["state"], "TASK_STATE_SUBMITTED");
        assert_eq!(sent["status"]["message"]["role"], "ROLE_AGENT");
        assert_eq!(
            sent["metadata"]["agent_room_protocol"],
            AGENT_ROOM_PROTOCOL_ID
        );
        let fetched = handle_a2a_get_task(&json!({
            "root": root.display().to_string(),
            "id": task_id
        }))
        .await
        .expect("get");
        assert_eq!(fetched["status"]["state"], "TASK_STATE_SUBMITTED");
        assert_eq!(fetched["history"].as_array().unwrap().len(), 1);
        assert_eq!(fetched["history"][0]["role"], "ROLE_USER");
        let canceled = handle_a2a_cancel_task(&json!({
            "root": root.display().to_string(),
            "id": fetched["id"].as_str().unwrap()
        }))
        .await
        .expect("cancel");
        assert_eq!(canceled["status"]["state"], "TASK_STATE_CANCELED");
        // §3.3.1: cancel is idempotent; a repeat cancel returns the same state.
        let recanceled = handle_a2a_cancel_task(&json!({
            "root": root.display().to_string(),
            "id": fetched["id"].as_str().unwrap()
        }))
        .await
        .expect("idempotent cancel");
        assert_eq!(recanceled["status"]["state"], "TASK_STATE_CANCELED");
        let room = list_agent_room(&root, 50).expect("room");
        assert!(room["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|event| event["event_kind"] == "status_change"));
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn a2a_task_states_follow_lf_mapping_table() {
        // Pure mapping-table checks for the §4.1.3 TaskState projection.
        let topic = |status: &str| json!({"topic_id": "t", "status": status});
        let a2a_event = |a2a_status: &str| json!({"metadata": {"a2a_status": a2a_status}});
        let client_msg = json!({"agent_id": "a2a_client"});
        let agent_msg = json!({"agent_id": "d4f"});
        // Fresh send: only the client seed -> SUBMITTED.
        assert_eq!(
            a2a_state_for_topic(
                &topic("open"),
                &[a2a_event("submitted")],
                &[client_msg.clone()]
            ),
            "TASK_STATE_SUBMITTED"
        );
        // Agent-side room output -> WORKING.
        assert_eq!(
            a2a_state_for_topic(
                &topic("open"),
                &[a2a_event("submitted")],
                &[client_msg.clone(), agent_msg.clone()]
            ),
            "TASK_STATE_WORKING"
        );
        // Explicit working status marker -> WORKING.
        assert_eq!(
            a2a_state_for_topic(
                &topic("open"),
                &[a2a_event("working")],
                &[client_msg.clone()]
            ),
            "TASK_STATE_WORKING"
        );
        // Blocked topic -> INPUT_REQUIRED.
        assert_eq!(
            a2a_state_for_topic(&topic("blocked"), &[], &[client_msg.clone()]),
            "TASK_STATE_INPUT_REQUIRED"
        );
        // Done topic or final_report event -> COMPLETED.
        assert_eq!(
            a2a_state_for_topic(&topic("done"), &[], &[agent_msg.clone()]),
            "TASK_STATE_COMPLETED"
        );
        assert_eq!(
            a2a_state_for_topic(
                &topic("open"),
                &[json!({"event_kind": "final_report"})],
                &[agent_msg.clone()]
            ),
            "TASK_STATE_COMPLETED"
        );
        // Failed topic (reserved) -> FAILED.
        assert_eq!(
            a2a_state_for_topic(&topic("failed"), &[], &[client_msg.clone()]),
            "TASK_STATE_FAILED"
        );
        // Cancel marker wins over every other signal -> CANCELED.
        assert_eq!(
            a2a_state_for_topic(
                &topic("blocked"),
                &[a2a_event("working"), a2a_event("canceled")],
                &[agent_msg.clone()]
            ),
            "TASK_STATE_CANCELED"
        );
    }

    #[tokio::test]
    async fn a2a_agent_card_declares_lf_required_fields() {
        let card = build_a2a_agent_card("http://127.0.0.1:9999/");
        // LF A2A 1.0.0 §4.4.1 required AgentCard fields.
        for field in [
            "name",
            "description",
            "version",
            "supportedInterfaces",
            "capabilities",
            "defaultInputModes",
            "defaultOutputModes",
            "skills",
        ] {
            assert!(!card[field].is_null(), "missing required field: {field}");
        }
        let interfaces = card["supportedInterfaces"].as_array().expect("interfaces");
        assert!(!interfaces.is_empty(), "at least one interface required");
        for interface in interfaces {
            assert!(interface["url"].is_string(), "interface url required");
            assert!(
                interface["protocolBinding"].is_string(),
                "interface protocolBinding required"
            );
            assert_eq!(interface["protocolVersion"], "1.0");
        }
        assert_eq!(interfaces[0]["protocolBinding"], "JSONRPC");
        // Honest capability declaration: no SSE streaming, no push.
        assert_eq!(card["capabilities"]["streaming"], false);
        assert_eq!(card["capabilities"]["pushNotifications"], false);
        // Skills carry the §4.4.5 required members.
        let skill = &card["skills"][0];
        for field in ["id", "name", "description", "tags"] {
            assert!(!skill[field].is_null(), "missing skill field: {field}");
        }
    }

    #[tokio::test]
    async fn a2a_agent_card_defaults_to_the_actual_http_origin() {
        let state = AppState {
            auth_token: None,
            plugin_root: PathBuf::from("fixture-plugin-root"),
            public_base_url: "http://127.0.0.1:8765".to_string(),
            workspace_root: PathBuf::from("fixture-workspace"),
            loopback_only: true,
        };
        let Json(card) = a2a_agent_card(State(state), Query(HashMap::new())).await;
        assert_eq!(card["url"], "http://127.0.0.1:8765/a2a/jsonrpc");
        assert_eq!(
            card["supportedInterfaces"][0]["url"],
            "http://127.0.0.1:8765/a2a/jsonrpc"
        );
        assert_eq!(
            card["supportedInterfaces"][1]["url"],
            "http://127.0.0.1:8765/a2a"
        );
    }

    #[tokio::test]
    async fn ui_bootstrap_returns_workspace_without_credentials_on_loopback() {
        let state = AppState {
            auth_token: Some("fixture-secret-never-returned".to_string()),
            plugin_root: PathBuf::from("fixture-plugin-root"),
            public_base_url: "http://127.0.0.1:8765".to_string(),
            workspace_root: PathBuf::from("/tmp/fixture-workspace"),
            loopback_only: true,
        };
        let response = ui_bootstrap(State(state)).await.into_response();
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("bootstrap body");
        let payload: Value = serde_json::from_slice(&body).expect("bootstrap JSON");
        assert_eq!(payload["data"]["workspace_label"], "fixture-workspace");
        assert_eq!(payload["data"]["token_included"], false);
        assert!(!String::from_utf8_lossy(&body).contains("fixture-secret"));
    }

    #[tokio::test]
    async fn ui_bootstrap_refuses_non_loopback_runtime() {
        let state = AppState {
            auth_token: None,
            plugin_root: PathBuf::from("fixture-plugin-root"),
            public_base_url: "http://0.0.0.0:8765".to_string(),
            workspace_root: PathBuf::from("/tmp/fixture-workspace"),
            loopback_only: false,
        };
        let response = ui_bootstrap(State(state)).await.into_response();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn a2a_errors_use_canonical_codes() {
        let root =
            std::env::temp_dir().join(format!("harvis-http-a2a-err-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let root = root.canonicalize().expect("canonical root");
        // Unknown task -> TaskNotFoundError (-32001, TASK_NOT_FOUND).
        let error = handle_a2a_get_task(&json!({
            "root": root.display().to_string(),
            "id": "topic_missing"
        }))
        .await
        .expect_err("not found");
        assert_eq!(error.code, -32001);
        assert_eq!(error.reason, Some("TASK_NOT_FOUND"));
        let body = error.jsonrpc_body(&json!(7));
        assert_eq!(body["error"]["code"], -32001);
        assert_eq!(
            body["error"]["data"][0]["@type"],
            "type.googleapis.com/google.rpc.ErrorInfo"
        );
        assert_eq!(body["error"]["data"][0]["reason"], "TASK_NOT_FOUND");
        assert_eq!(body["error"]["data"][0]["domain"], "a2a-protocol.org");
        // Client-provided taskId for an unknown task -> TaskNotFoundError.
        let error = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {"taskId": "topic_missing", "parts": [{"text": "继续"}]}
        }))
        .await
        .expect_err("send to missing task");
        assert_eq!(error.code, -32001);
        // contextId/taskId mismatch -> InvalidParams (-32602).
        let error = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {"taskId": "a", "contextId": "b", "parts": [{"text": "继续"}]}
        }))
        .await
        .expect_err("mismatched context");
        assert_eq!(error.code, -32602);
        // Non-text part -> ContentTypeNotSupportedError (-32005).
        let error = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {"parts": [{"url": "https://example.com/file.pdf", "mediaType": "application/pdf"}]}
        }))
        .await
        .expect_err("unsupported part");
        assert_eq!(error.code, -32005);
        assert_eq!(error.reason, Some("CONTENT_TYPE_NOT_SUPPORTED"));
        // Empty text -> InvalidParams (-32602).
        let error = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {"parts": [{"text": "   "}]}
        }))
        .await
        .expect_err("empty text");
        assert_eq!(error.code, -32602);
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn a2a_multi_turn_and_terminal_guards() {
        let root =
            std::env::temp_dir().join(format!("harvis-http-a2a-mt-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let root = root.canonicalize().expect("canonical root");
        let sent = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {"messageId": "m1", "parts": [{"text": "建立圆桌任务"}]}
        }))
        .await
        .expect("send");
        let task_id = sent["id"].as_str().expect("task id").to_string();
        // §3.4.3: follow-up with the same taskId appends to the same task.
        let followed = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {"taskId": task_id, "parts": [{"text": "补充约束"}]}
        }))
        .await
        .expect("follow-up");
        assert_eq!(followed["id"], task_id);
        assert_eq!(followed["history"].as_array().unwrap().len(), 2);
        // §3.1.1: messages to terminal tasks are rejected.
        let canceled = handle_a2a_cancel_task(&json!({
            "root": root.display().to_string(),
            "id": task_id
        }))
        .await
        .expect("cancel");
        assert_eq!(canceled["status"]["state"], "TASK_STATE_CANCELED");
        let error = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {"taskId": task_id, "parts": [{"text": "再补充"}]}
        }))
        .await
        .expect_err("terminal send");
        assert_eq!(error.code, -32004);
        assert_eq!(error.reason, Some("UNSUPPORTED_OPERATION"));
        // §3.1.5: canceling a completed task -> TaskNotCancelableError.
        let second = handle_a2a_send(&json!({
            "root": root.display().to_string(),
            "message": {"parts": [{"text": "第二个任务"}]}
        }))
        .await
        .expect("second send");
        let second_id = second["id"].as_str().expect("second id").to_string();
        add_event_with_metadata(
            &root,
            &second_id,
            "d4f",
            "agent",
            "final_report",
            "final report",
            Vec::new(),
            "internal",
            None,
            json!({}),
        )
        .expect("final report");
        let error = handle_a2a_cancel_task(&json!({
            "root": root.display().to_string(),
            "id": second_id
        }))
        .await
        .expect_err("cancel completed");
        assert_eq!(error.code, -32002);
        assert_eq!(error.reason, Some("TASK_NOT_CANCELABLE"));
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn a2a_jsonrpc_dispatch_and_capability_errors() {
        let root =
            std::env::temp_dir().join(format!("harvis-http-a2a-rpc-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let root = root.canonicalize().expect("canonical root");
        async fn rpc(method: &str, params: Value) -> Value {
            a2a_jsonrpc_post(Json(A2aJsonRpcRequest {
                id: json!(1),
                method: method.to_string(),
                params,
            }))
            .await
            .0
        }
        // Canonical PascalCase send works.
        let response = rpc(
            "SendMessage",
            json!({
                "root": root.display().to_string(),
                "message": {"messageId": "m1", "parts": [{"text": "圆桌任务"}]}
            }),
        )
        .await;
        assert_eq!(response["jsonrpc"], "2.0");
        let task_id = response["result"]["id"]
            .as_str()
            .expect("task id")
            .to_string();
        assert_eq!(
            response["result"]["status"]["state"],
            "TASK_STATE_SUBMITTED"
        );
        // Unknown method -> -32601 MethodNotFound.
        let response = rpc("NoSuchMethod", json!({})).await;
        assert_eq!(response["error"]["code"], -32601);
        // Streaming declared unsupported -> -32004 UnsupportedOperationError.
        let response = rpc(
            "SendStreamingMessage",
            json!({"root": root.display().to_string()}),
        )
        .await;
        assert_eq!(response["error"]["code"], -32004);
        assert_eq!(
            response["error"]["data"][0]["reason"],
            "UNSUPPORTED_OPERATION"
        );
        // Push notifications declared unsupported -> -32003.
        let response = rpc(
            "CreateTaskPushNotificationConfig",
            json!({"root": root.display().to_string(), "taskId": task_id}),
        )
        .await;
        assert_eq!(response["error"]["code"], -32003);
        assert_eq!(
            response["error"]["data"][0]["reason"],
            "PUSH_NOTIFICATION_NOT_SUPPORTED"
        );
        // GetTask on a missing task -> -32001 TaskNotFoundError.
        let response = rpc(
            "GetTask",
            json!({"root": root.display().to_string(), "id": "topic_missing"}),
        )
        .await;
        assert_eq!(response["error"]["code"], -32001);
        assert_eq!(response["error"]["data"][0]["reason"], "TASK_NOT_FOUND");
        // CancelTask through the canonical name still reaches the task.
        let response = rpc(
            "CancelTask",
            json!({"root": root.display().to_string(), "id": task_id}),
        )
        .await;
        assert_eq!(response["result"]["status"]["state"], "TASK_STATE_CANCELED");
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn agent_room_step_dry_run_records_lineage() {
        let root =
            std::env::temp_dir().join(format!("harvis-http-step-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let root = root.canonicalize().expect("canonical root");
        let step = handle_agent_room_step(AgentRoomStepRequest {
            root: root.display().to_string(),
            prompt: Some("@d4p 追问当前方案的最大风险".to_string()),
            raw_prompt: Some("@d4p 追问当前方案的最大风险".to_string()),
            model_alias: "d4f".to_string(),
            topic_id: None,
            provider_registry: None,
            dry_run: true,
            reply_to_event_id: Some("evt_previous".to_string()),
            reply_to_agent_id: Some("d4f".to_string()),
            reply_to_question_id: Some("question_previous".to_string()),
            question_id: None,
        })
        .await
        .expect("step");
        assert_eq!(step["version"], "v0.53-cognitive-host-stepper");
        assert_eq!(step["dry_run"], true);
        assert!(step["question_id"]
            .as_str()
            .is_some_and(|value| value.starts_with("question_")));
        assert_eq!(step["reply_target"]["reply_to_event_id"], "evt_previous");
        assert_eq!(step["reply_target"]["reply_to_agent_id"], "d4f");
        assert_eq!(
            step["reply_target"]["reply_to_question_id"],
            "question_previous"
        );
        assert_eq!(step["host_event"]["event_kind"], "question");
        assert_eq!(
            step["host_event"]["metadata"]["authority"]["requires_handoff_for_mutation"],
            true
        );
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn agent_room_step_uses_round_robin_selector_by_default() {
        let root =
            std::env::temp_dir().join(format!("harvis-http-step-rr-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let root = root.canonicalize().expect("canonical root");
        let step = handle_agent_room_step(AgentRoomStepRequest {
            root: root.display().to_string(),
            prompt: Some("推进圆桌一步".to_string()),
            raw_prompt: None,
            model_alias: "d4f".to_string(),
            topic_id: Some("gwt-workbench".to_string()),
            provider_registry: None,
            dry_run: true,
            reply_to_event_id: None,
            reply_to_agent_id: None,
            reply_to_question_id: None,
            question_id: None,
        })
        .await
        .expect("step");
        assert_eq!(step["version"], "v0.53-cognitive-host-stepper");
        assert_eq!(step["selector"]["selector_kind"], "round_robin");
        assert_eq!(step["selector"]["fallback"], false);
        assert_eq!(step["status"], "planned");
        assert_eq!(step["speaker"]["slot_id"], "harvis-chair");
        assert_eq!(step["decision_record"]["selector_kind"], "round_robin");
        assert!(step["decision_record"]["route_reason"]
            .as_str()
            .is_some_and(|reason| !reason.is_empty()));
        assert!(step["decision_record"]["ts"].as_str().is_some());
        let decisions =
            harvis_runtime::agent_room::read_chair_decisions(&root, 10).expect("chair decisions");
        assert!(decisions
            .iter()
            .any(|record| record["selector_kind"] == "round_robin"));
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn agent_room_step_llm_selector_routes_mention_via_fixture_provider() {
        let root =
            std::env::temp_dir().join(format!("harvis-http-step-llm-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let root = root.canonicalize().expect("canonical root");
        // roster gains a DeepSeek participant (record_only: recorded, not executed)
        upsert_participant(
            &root,
            ParticipantInput {
                slot_id: "deepseek".to_string(),
                role: "reviewer".to_string(),
                display_name: "DeepSeek".to_string(),
                provider_ref: Some("deepseek".to_string()),
                model_ref: Some("deepseek-chat".to_string()),
                execution_mode: Some("record_only".to_string()),
                ..ParticipantInput::default()
            },
        )
        .expect("upsert deepseek");
        // llm selector tier, routed through the provider registry at a local
        // fixture provider (same code path as a real provider)
        fs::write(
            root.join(".harvis/harvis.toml"),
            "[agent_room_speaker]\nselector = \"llm\"\nmodel_alias = \"fixture\"\n",
        )
        .expect("write config");
        let fixture_url = spawn_webview_fixture(json!({
            "choices": [{
                "message": {"content": "{\"agent_id\": \"deepseek\", \"route_reason\": \"explicit @DeepSeek mention routes to the DeepSeek participant\"}"},
                "finish_reason": "stop"
            }],
            "usage": {"output_tokens": 18}
        }));
        let token_file = root.join("fixture-token");
        fs::write(&token_file, "token: sk-fixturetoken123456").expect("token");
        let registry = root.join("providers.toml");
        fs::write(
            &registry,
            format!(
                "[providers.fixture]\nkind = \"openai-compatible\"\nbase_url = \"{}\"\naccess_file = \"{}\"\n\n[models.fixture]\nprovider = \"fixture\"\nmodel = \"fixture-model\"\nagent = \"Fixture Selector\"\nrole = \"selector\"\n",
                fixture_url.trim_end_matches('/'),
                token_file.display()
            ),
        )
        .expect("registry");
        let step = handle_agent_room_step(AgentRoomStepRequest {
            root: root.display().to_string(),
            prompt: Some("@DeepSeek 请评审当前方案的最大风险".to_string()),
            raw_prompt: Some("@DeepSeek 请评审当前方案的最大风险".to_string()),
            model_alias: "fixture".to_string(),
            topic_id: Some("gwt-workbench".to_string()),
            provider_registry: Some(registry.display().to_string()),
            dry_run: false,
            reply_to_event_id: None,
            reply_to_agent_id: None,
            reply_to_question_id: None,
            question_id: None,
        })
        .await
        .expect("step");
        assert_eq!(step["selector"]["selector_kind"], "llm");
        assert_eq!(step["selector"]["effective_selector"], "llm");
        assert_eq!(step["selector"]["fallback"], false);
        assert_eq!(step["speaker"]["slot_id"], "deepseek");
        assert!(step["route_reason"]
            .as_str()
            .is_some_and(|reason| reason.contains("@DeepSeek")));
        // the mention signal resolves to the first roster candidate whose
        // slot or display name matches; "DeepSeek Chair" (harvis-chair)
        // precedes the deepseek slot, while the llm selector itself still
        // routed to the literal deepseek participant above
        assert_eq!(
            step["selector"]["signals"]["explicit_mention"]["slot_id"],
            "harvis-chair"
        );
        // deepseek is record_only: selection recorded, nothing executed
        assert_eq!(step["status"], "recorded");
        assert_eq!(step["agent_message"], Value::Null);
        assert_eq!(step["decision_record"]["selector_kind"], "llm");
        assert!(step["decision_record"]["route_reason"]
            .as_str()
            .is_some_and(|reason| reason.contains("@DeepSeek")));
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn webview_status_counts_projects_and_redacts_paths() {
        let url = spawn_webview_fixture(json!({
            "generated_at": "2026-06-27T08:00:00Z",
            "projects": [
                {
                    "id": "demo",
                    "name": "Demo",
                    "kind": "generic_repo",
                    "root": "/workspace/private/demo",
                    "root_exists": true,
                    "tags": ["demo", "/Users/secret/tag"]
                },
                {
                    "id": "second",
                    "name": "Second",
                    "kind": "tool",
                    "root_exists": false
                }
            ]
        }));

        let status = harvis_webview_status(&url, 1).await.expect("status");
        assert_eq!(status["gateway"], "harvis");
        assert_eq!(status["project_count"], 2);
        assert_eq!(status["sample"].as_array().expect("sample").len(), 1);
        assert_eq!(status["includesLocalAbsolutePaths"], false);
        let rendered = serde_json::to_string(&status).expect("json");
        assert!(!rendered.contains("/workspace/private/demo"));
        assert!(!rendered.contains("/Users/secret/tag"));
    }

    #[tokio::test]
    async fn webview_status_rejects_non_localhost_urls() {
        let error = harvis_webview_status("https://example.com/", 1)
            .await
            .expect_err("reject remote webview");
        assert!(error.to_string().contains("must point to localhost"));
    }
}
