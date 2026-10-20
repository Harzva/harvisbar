use axum::body::Body;
use axum::extract::State;
use axum::http::{header, Request, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::routes::error_envelope;
use crate::AppState;

pub async fn require_auth(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let endpoint = request.uri().path().to_string();
    if endpoint_is_public(&endpoint) || state.auth_token.is_none() {
        return next.run(request).await;
    }
    let Some(expected) = state.auth_token.as_deref() else {
        return next.run(request).await;
    };
    let authorized = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .is_some_and(|supplied| constant_time_eq(supplied.as_bytes(), expected.as_bytes()));
    if authorized {
        return next.run(request).await;
    }
    let mut response = (
        StatusCode::UNAUTHORIZED,
        error_envelope(
            &endpoint,
            "unauthorized",
            "Authorization bearer token is required.",
        ),
    )
        .into_response();
    response.headers_mut().insert(
        header::WWW_AUTHENTICATE,
        header::HeaderValue::from_static("Bearer realm=\"harvis\""),
    );
    response
}

fn endpoint_is_public(endpoint: &str) -> bool {
    endpoint == "/health"
        || endpoint == "/ui/bootstrap"
        || endpoint == "/ui/tokens.css"
        || endpoint == "/ui/runtime.js"
        || endpoint == "/ui/operator.css"
        || endpoint == "/ui/operator.js"
        || endpoint == "/ui/t317-smoke.json"
        || endpoint.starts_with("/schemas/")
        || endpoint == "/panel"
        || endpoint.starts_with("/panel/")
        || endpoint == "/presence"
        || endpoint.starts_with("/presence/")
        || endpoint == "/pet"
        || endpoint.starts_with("/pet/")
        || endpoint == "/studio"
        || endpoint.starts_with("/studio/")
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0u8, |acc, (left, right)| acc | (left ^ right))
        == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_endpoint_matches_python_exemptions() {
        for endpoint in [
            "/health",
            "/ui/bootstrap",
            "/ui/runtime.js",
            "/ui/operator.css",
            "/ui/operator.js",
            "/ui/t317-smoke.json",
            "/panel/",
            "/presence/presence.js",
            "/studio/studio.js",
            "/schemas/status.schema.json",
        ] {
            assert!(endpoint_is_public(endpoint));
        }
        assert!(!endpoint_is_public("/bar/status"));
        assert!(!endpoint_is_public("/ui/integrations"));
        assert!(!endpoint_is_public("/memory-candidates"));
    }
}
