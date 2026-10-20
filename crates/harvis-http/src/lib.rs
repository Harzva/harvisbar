pub mod auth;
pub mod routes;
pub mod static_assets;

use anyhow::Result;
use axum::Router;
use std::net::SocketAddr;
use std::path::PathBuf;
use tokio::net::TcpListener;
use tower_http::cors::{Any, CorsLayer};

#[derive(Debug, Clone)]
pub struct HttpConfig {
    pub auth_token: Option<String>,
    pub auth_token_file: Option<PathBuf>,
    pub host: String,
    pub plugin_root: PathBuf,
    pub port: u16,
    /// Trusted workspace selected by the CLI/service manager. UI surfaces use
    /// this value through the loopback-only bootstrap route instead of taking
    /// a private absolute path from the browser URL or persistent storage.
    pub workspace_root: PathBuf,
}

impl HttpConfig {
    pub fn resolved_auth_token(&self) -> Option<String> {
        if let Some(token) = self
            .auth_token
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return Some(token.to_string());
        }
        let path = self.auth_token_file.as_ref()?;
        std::fs::read_to_string(path)
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }
}

#[derive(Debug, Clone)]
pub struct AppState {
    pub auth_token: Option<String>,
    pub plugin_root: PathBuf,
    /// Canonical origin advertised by discovery documents such as the A2A
    /// Agent Card. It is derived from the actual listen configuration so a
    /// non-default local test port cannot silently advertise another service.
    pub public_base_url: String,
    pub workspace_root: PathBuf,
    pub loopback_only: bool,
}

pub fn serve_blocking(config: HttpConfig) -> Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(serve(config))
}

pub async fn serve(config: HttpConfig) -> Result<()> {
    let addr: SocketAddr = format!("{}:{}", config.host, config.port).parse()?;
    let public_base_url = format!("http://{addr}");
    let state = AppState {
        auth_token: config.resolved_auth_token(),
        plugin_root: config.plugin_root,
        public_base_url,
        workspace_root: config
            .workspace_root
            .canonicalize()
            .unwrap_or(config.workspace_root),
        loopback_only: addr.ip().is_loopback(),
    };
    let app = app(state);
    eprintln!("H.A.R.V.I.S. Rust HTTP API listening on http://{addr}");
    let listener = TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

pub fn app(state: AppState) -> Router {
    routes::router(state).layer(
        CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any),
    )
}

pub fn http_label() -> &'static str {
    "harvis-http"
}
