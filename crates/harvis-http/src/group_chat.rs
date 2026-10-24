//! Authenticated HTTP projection of the Swift group's private control API.
use axum::{extract::{Path, State}, http::{header, HeaderMap, StatusCode}, response::{IntoResponse, Response}, routing::post, Json, Router};
use harvis_core::group_control;
use serde_json::{json, Value};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/group-chat/:operation", post(forward))
}
fn authorization(state: &AppState, headers: &HeaderMap) -> Result<(), (StatusCode, &'static str)> {
    let Some(expected) = state.auth_token.as_deref().filter(|s| s.len() >= 32) else {
        return Err((StatusCode::SERVICE_UNAVAILABLE, "Group HTTP access requires a configured bearer token of at least32 bytes."));
    };
    if !state.loopback_only { return Err((StatusCode::FORBIDDEN, "Group HTTP access requires a loopback-only listener.")); }
    // These tools are local agent APIs, not browser-origin mutation endpoints.
    if headers.contains_key(header::ORIGIN) { return Err((StatusCode::FORBIDDEN, "Browser-origin group control requests are not accepted.")); }
    let supplied = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()).and_then(|v| v.strip_prefix("Bearer ")).unwrap_or("");
    if supplied.len() != expected.len() || supplied.bytes().zip(expected.bytes()).fold(0u8, |acc, (a,b)| acc | (a ^ b)) != 0 {
        return Err((StatusCode::UNAUTHORIZED, "Group HTTP access requires its bearer token."));
    }
    Ok(())
}
async fn forward(State(state): State<AppState>, Path(operation): Path<String>, headers: HeaderMap, Json(params): Json<Value>) -> Response {
    if let Err((status, message)) = authorization(&state, &headers) {
        return (status, Json(json!({"ok":false,"error":{"code":"group_http_access_denied","message":message}}))).into_response();
    }
    let method = match operation.as_str() {
        "list" => "groups.list", "status" => "groups.status", "send" => "groups.send", "results" => "groups.results", "cancel" => "groups.cancel", "recover" => "groups.recover",
        _ => return (StatusCode::NOT_FOUND, Json(json!({"ok":false,"error":{"code":"unknown_method","message":"Unknown group operation."}}))).into_response(),
    };
    match tokio::task::spawn_blocking(move || group_control::call(method, params)).await {
        Ok(Ok(data)) => (if operation == "send" { StatusCode::ACCEPTED } else { StatusCode::OK }, Json(json!({"ok":true,"data":data}))).into_response(),
        Ok(Err(error)) => {
            let status = match error.code.as_str() { "-32602" | "invalid_request" => StatusCode::BAD_REQUEST, "-32003" => StatusCode::FORBIDDEN, "-32009" => StatusCode::CONFLICT, "-32010" => StatusCode::UNPROCESSABLE_ENTITY, _ => StatusCode::SERVICE_UNAVAILABLE };
            (status, Json(json!({"ok":false,"error":{"code":error.code,"message":error.message}}))).into_response()
        }
        Err(_) => (StatusCode::SERVICE_UNAVAILABLE, Json(json!({"ok":false,"error":{"code":"unavailable","message":"Group control task is unavailable."}}))).into_response(),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn state(token: Option<&str>) -> AppState {
        AppState { auth_token: token.map(str::to_string), plugin_root: ".".into(), public_base_url: "http://127.0.0.1:8765".into(), workspace_root: ".".into(), loopback_only: true }
    }
    #[tokio::test]
    async fn mutation_handler_never_forwards_when_auth_is_unconfigured() {
        let response = forward(State(state(None)), Path("send".into()), HeaderMap::new(), Json(json!({"text":"must never be sent"}))).await;
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body = axum::body::to_bytes(response.into_body(), 4096).await.unwrap();
        let value: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["error"]["code"], "group_http_access_denied");
    }
    #[test]
    fn group_http_fails_closed_without_strong_token_or_on_browser_origin() {
        let token = "test-token-with-at-least-32-bytes-long";
        let mut headers = HeaderMap::new();
        assert_eq!(authorization(&state(None), &headers).unwrap_err().0, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(authorization(&state(Some("short")), &headers).unwrap_err().0, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(authorization(&state(Some(token)), &headers).unwrap_err().0, StatusCode::UNAUTHORIZED);
        headers.insert(header::AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
        assert!(authorization(&state(Some(token)), &headers).is_ok());
        headers.insert(header::ORIGIN, "http://hostile.invalid".parse().unwrap());
        assert_eq!(authorization(&state(Some(token)), &headers).unwrap_err().0, StatusCode::FORBIDDEN);
    }
}
