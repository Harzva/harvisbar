use axum::extract::{Path, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Redirect, Response};
use std::path::{Path as FsPath, PathBuf};

use crate::routes::error_envelope;
use crate::AppState;

const STUDIO_ASSETS: &[&str] = &[
    "harvis-persona-system.png",
    "harvis-core-male.png",
    "harvis-core-female.png",
    "harvis-app-icon.png",
];

const SCHEMAS: &[&str] = &[
    "approval.schema.json",
    "agent-pools.schema.json",
    "agent-roster.schema.json",
    "agent-room.schema.json",
    "agent-room-mailbox.schema.json",
    "agent-room-participant.schema.json",
    "agent-room-task.schema.json",
    "agent-room-workspace-state.schema.json",
    "bar-status.schema.json",
    "handoff.schema.json",
    "hub-source.schema.json",
    "memory-vault.schema.json",
    "run.schema.json",
    "persona-card.schema.json",
    "personality-candidate.schema.json",
    "task.schema.json",
    "task-progress.schema.json",
    "status.schema.json",
    "twin-instance.schema.json",
    "ui-contract.schema.json",
    "event.schema.json",
    "notification.schema.json",
    "ports-status.schema.json",
    "result.schema.json",
];

pub async fn panel_index(State(state): State<AppState>) -> Response {
    serve_file("/panel/", state.plugin_root.join("panel/index.html")).await
}

pub async fn ui_tokens_css(State(state): State<AppState>) -> Response {
    serve_file("/ui/tokens.css", state.plugin_root.join("ui/tokens.css")).await
}

pub async fn ui_runtime_js(State(state): State<AppState>) -> Response {
    serve_file("/ui/runtime.js", state.plugin_root.join("ui/runtime.js")).await
}

pub async fn ui_operator_css(State(state): State<AppState>) -> Response {
    serve_file(
        "/ui/operator.css",
        state.plugin_root.join("ui/operator.css"),
    )
    .await
}

pub async fn ui_operator_js(State(state): State<AppState>) -> Response {
    serve_file("/ui/operator.js", state.plugin_root.join("ui/operator.js")).await
}

pub async fn ui_t317_smoke(State(state): State<AppState>) -> Response {
    serve_file(
        "/ui/t317-smoke.json",
        state.plugin_root.join("ui/t317-smoke.json"),
    )
    .await
}

pub async fn panel_css(State(state): State<AppState>) -> Response {
    serve_file(
        "/panel/styles.css",
        state.plugin_root.join("panel/styles.css"),
    )
    .await
}

pub async fn panel_js(State(state): State<AppState>) -> Response {
    serve_file("/panel/panel.js", state.plugin_root.join("panel/panel.js")).await
}

pub async fn presence_index(State(state): State<AppState>) -> Response {
    serve_file("/presence/", state.plugin_root.join("presence/index.html")).await
}

pub async fn presence_css(State(state): State<AppState>) -> Response {
    serve_file(
        "/presence/styles.css",
        state.plugin_root.join("presence/styles.css"),
    )
    .await
}

pub async fn presence_js(State(state): State<AppState>) -> Response {
    serve_file(
        "/presence/presence.js",
        state.plugin_root.join("presence/presence.js"),
    )
    .await
}

pub async fn pet_index() -> Redirect {
    Redirect::permanent("/presence/")
}

pub async fn pet_css() -> Redirect {
    Redirect::permanent("/presence/styles.css")
}

pub async fn pet_js() -> Redirect {
    Redirect::permanent("/presence/presence.js")
}

pub async fn studio_index(State(state): State<AppState>) -> Response {
    serve_file("/studio/", state.plugin_root.join("studio/index.html")).await
}

pub async fn studio_css(State(state): State<AppState>) -> Response {
    serve_file(
        "/studio/styles.css",
        state.plugin_root.join("studio/styles.css"),
    )
    .await
}

pub async fn studio_js(State(state): State<AppState>) -> Response {
    serve_file(
        "/studio/studio.js",
        state.plugin_root.join("studio/studio.js"),
    )
    .await
}

pub async fn studio_roundtable(State(state): State<AppState>) -> Response {
    serve_file(
        "/studio/roundtable/",
        state.plugin_root.join("studio/roundtable.html"),
    )
    .await
}

pub async fn studio_mobile(State(state): State<AppState>) -> Response {
    serve_file(
        "/studio/mobile/",
        state.plugin_root.join("studio/mobile.html"),
    )
    .await
}

pub async fn studio_mobile_css(State(state): State<AppState>) -> Response {
    serve_file(
        "/studio/mobile.css",
        state.plugin_root.join("studio/mobile.css"),
    )
    .await
}

pub async fn studio_mobile_js(State(state): State<AppState>) -> Response {
    serve_file(
        "/studio/mobile.js",
        state.plugin_root.join("studio/mobile.js"),
    )
    .await
}

pub async fn studio_asset(State(state): State<AppState>, Path(name): Path<String>) -> Response {
    if !STUDIO_ASSETS.contains(&name.as_str()) {
        return (
            StatusCode::NOT_FOUND,
            error_envelope(
                "/studio/assets",
                "not_found",
                &format!("unknown studio asset: {name}"),
            ),
        )
            .into_response();
    }
    serve_file(
        &format!("/studio/assets/{name}"),
        state.plugin_root.join("studio/assets").join(name),
    )
    .await
}

pub async fn schema(State(state): State<AppState>, Path(name): Path<String>) -> Response {
    if !SCHEMAS.contains(&name.as_str()) {
        return (
            StatusCode::NOT_FOUND,
            error_envelope("/schemas", "not_found", &format!("unknown schema: {name}")),
        )
            .into_response();
    }
    serve_file(
        &format!("/schemas/{name}"),
        state.plugin_root.join("schemas").join(name),
    )
    .await
}

async fn serve_file(endpoint: &str, path: PathBuf) -> Response {
    let Ok(body) = tokio::fs::read(&path).await else {
        return (
            StatusCode::NOT_FOUND,
            error_envelope(
                endpoint,
                "not_found",
                &format!("asset not found: {endpoint}"),
            ),
        )
            .into_response();
    };
    let content_type = content_type(&path);
    let mut response = (StatusCode::OK, body).into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    response
}

fn content_type(path: &FsPath) -> &'static str {
    match path.extension().and_then(|value| value.to_str()) {
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "application/javascript; charset=utf-8",
        Some("json") => "application/schema+json; charset=utf-8",
        Some("png") => "image/png",
        _ => "text/html; charset=utf-8",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn agent_room_schema_covers_cognitive_trace_kinds() {
        let schema_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join("schemas/agent-room.schema.json");
        let schema: Value =
            serde_json::from_slice(&std::fs::read(&schema_path).expect("read agent-room schema"))
                .expect("parse agent-room schema");
        let kinds = schema["properties"]["event_kind"]["enum"]
            .as_array()
            .expect("event kind enum");
        for required in ["hypothesis", "verification_target"] {
            assert!(
                kinds.iter().any(|kind| kind.as_str() == Some(required)),
                "agent-room schema missing T311 kind: {required}"
            );
        }
    }

    #[test]
    fn task_progress_schema_is_served_and_bar_status_references_it() {
        assert!(SCHEMAS.contains(&"task-progress.schema.json"));
        let schema_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join("schemas");
        let task_progress: Value = serde_json::from_slice(
            &std::fs::read(schema_root.join("task-progress.schema.json"))
                .expect("read task-progress schema"),
        )
        .expect("parse task-progress schema");
        let bar_status: Value = serde_json::from_slice(
            &std::fs::read(schema_root.join("bar-status.schema.json"))
                .expect("read bar-status schema"),
        )
        .expect("parse bar-status schema");

        assert_eq!(
            task_progress["$id"],
            "https://harzva.local/harvis/schemas/task-progress.schema.json"
        );
        assert_eq!(
            bar_status["properties"]["taskProgress"]["$ref"],
            "task-progress.schema.json#/$defs/status"
        );
    }
}
