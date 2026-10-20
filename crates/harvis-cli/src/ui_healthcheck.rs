use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

const UI_HEALTHCHECK_VERSION: &str = "v0.45-ui-contract";

#[derive(Debug, Clone)]
pub struct UiHealthcheckConfig {
    pub root: PathBuf,
    pub profile_root: PathBuf,
    pub host: String,
    pub port: u16,
    pub auth_token_file: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy)]
enum ExpectedKind {
    Array,
    Bool,
    BoolFalse,
    BoolTrue,
    ExactString(&'static str),
    Integer,
    NullOrObject,
    Object,
    String,
    TaskProgressStatus,
}

#[derive(Debug, Clone, Copy)]
struct FieldSpec {
    pointer: &'static str,
    kind: ExpectedKind,
}

#[derive(Debug, Clone)]
struct EndpointSpec {
    endpoint: &'static str,
    path_kind: PathKind,
    data_fields: Vec<FieldSpec>,
}

#[derive(Debug, Clone, Copy)]
enum PathKind {
    Plain,
    Root,
    RootProfile,
    RootLimit(usize),
}

pub fn run(config: UiHealthcheckConfig) -> Result<()> {
    let root = expanduser(&config.root);
    let profile_root = expanduser(&config.profile_root);
    let token = config
        .auth_token_file
        .as_ref()
        .map(|path| expanduser(path))
        .and_then(|path| fs::read_to_string(path).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    let mut checks = Vec::new();
    let mut errors = Vec::new();
    for spec in endpoint_specs() {
        let check = check_endpoint(&config, &root, &profile_root, token.as_deref(), &spec);
        if let Some(error) = check.get("error").and_then(Value::as_str) {
            errors.push(format!("{}: {error}", spec.endpoint));
        } else if !check.get("ok").and_then(Value::as_bool).unwrap_or(false) {
            let missing = check
                .get("missing_fields")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            let type_errors = check
                .get("type_errors")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            errors.push(format!(
                "{}: missing=[{}] type_errors=[{}]",
                spec.endpoint, missing, type_errors
            ));
        }
        checks.push(check);
    }

    let ok = errors.is_empty();
    let payload = json!({
        "ok": ok,
        "runtime": "rust",
        "ui_healthcheck_version": UI_HEALTHCHECK_VERSION,
        "http_api_version": harvis_http::routes::API_VERSION,
        "host": config.host,
        "port": config.port,
        "workspace": {
            "label": workspace_label(&root)
        },
        "auth": {
            "token_file_configured": config.auth_token_file.is_some(),
            "token_loaded": token.is_some(),
            "token_value_returned": false
        },
        "contract": {
            "mode": "additive",
            "envelope": ["ok", "endpoint", "data", "warnings", "error"],
            "endpoint_count": checks.len(),
            "autonomy_level": 1
        },
        "checks": checks,
        "errors": errors
    });
    println!("{}", serde_json::to_string_pretty(&payload)?);
    if !ok {
        bail!("H.A.R.V.I.S. UI healthcheck failed");
    }
    Ok(())
}

fn check_endpoint(
    config: &UiHealthcheckConfig,
    root: &Path,
    profile_root: &Path,
    token: Option<&str>,
    spec: &EndpointSpec,
) -> Value {
    let request_path = request_path(spec, root, profile_root);
    let response = match local_http_get(&config.host, config.port, &request_path, token) {
        Ok(response) => response,
        Err(error) => {
            return json!({
                "endpoint": spec.endpoint,
                "ok": false,
                "error": error.to_string()
            })
        }
    };
    let value = match serde_json::from_str::<Value>(&response.body) {
        Ok(value) => value,
        Err(error) => {
            return json!({
                "endpoint": spec.endpoint,
                "http_status": response.status,
                "ok": false,
                "error": format!("invalid JSON response: {error}")
            })
        }
    };

    let mut missing_fields = Vec::new();
    let mut type_errors = Vec::new();
    check_envelope(spec.endpoint, &value, &mut missing_fields, &mut type_errors);
    if let Some(data) = value.get("data") {
        for field in &spec.data_fields {
            match data.pointer(field.pointer) {
                Some(value) if kind_matches(value, field.kind) => {}
                Some(_) => type_errors.push(field.pointer.to_string()),
                None => missing_fields.push(field.pointer.to_string()),
            }
        }
    }

    let ok = (200..300).contains(&response.status)
        && missing_fields.is_empty()
        && type_errors.is_empty()
        && value.get("ok").and_then(Value::as_bool).unwrap_or(false);
    json!({
        "endpoint": spec.endpoint,
        "http_status": response.status,
        "ok": ok,
        "required_data_fields": spec.data_fields.iter().map(|field| field.pointer).collect::<Vec<_>>(),
        "missing_fields": missing_fields,
        "type_errors": type_errors,
        "data_keys": value.get("data").and_then(Value::as_object).map(|object| object.keys().cloned().collect::<Vec<_>>()).unwrap_or_default()
    })
}

fn check_envelope(
    endpoint: &str,
    value: &Value,
    missing_fields: &mut Vec<String>,
    type_errors: &mut Vec<String>,
) {
    for field in ["ok", "endpoint", "data", "warnings", "error"] {
        if value.get(field).is_none() {
            missing_fields.push(format!("/{field}"));
        }
    }
    if !value.get("ok").is_some_and(Value::is_boolean) {
        type_errors.push("/ok".to_string());
    }
    if value.get("endpoint").and_then(Value::as_str) != Some(endpoint) {
        type_errors.push("/endpoint".to_string());
    }
    if !value.get("warnings").is_some_and(Value::is_array) {
        type_errors.push("/warnings".to_string());
    }
    if value.get("data").is_none_or(Value::is_null) {
        missing_fields.push("/data".to_string());
    }
}

fn kind_matches(value: &Value, kind: ExpectedKind) -> bool {
    match kind {
        ExpectedKind::Array => value.is_array(),
        ExpectedKind::Bool => value.is_boolean(),
        ExpectedKind::BoolFalse => value.as_bool() == Some(false),
        ExpectedKind::BoolTrue => value.as_bool() == Some(true),
        ExpectedKind::ExactString(expected) => value.as_str() == Some(expected),
        ExpectedKind::Integer => value.as_i64().is_some() || value.as_u64().is_some(),
        ExpectedKind::NullOrObject => value.is_null() || value.is_object(),
        ExpectedKind::Object => value.is_object(),
        ExpectedKind::String => value.is_string(),
        ExpectedKind::TaskProgressStatus => value
            .as_str()
            .is_some_and(|status| matches!(status, "active" | "idle" | "skipped")),
    }
}

fn request_path(spec: &EndpointSpec, root: &Path, profile_root: &Path) -> String {
    match spec.path_kind {
        PathKind::Plain => spec.endpoint.to_string(),
        PathKind::Root => format!(
            "{}?root={}",
            spec.endpoint,
            url_encode(&root.display().to_string())
        ),
        PathKind::RootProfile => format!(
            "{}?root={}&profile_root={}{}",
            spec.endpoint,
            url_encode(&root.display().to_string()),
            url_encode(&profile_root.display().to_string()),
            if spec.endpoint == "/bar/status" {
                "&full=true"
            } else {
                ""
            }
        ),
        PathKind::RootLimit(limit) => format!(
            "{}?root={}&limit={}",
            spec.endpoint,
            url_encode(&root.display().to_string()),
            limit
        ),
    }
}

struct HttpResponse {
    status: u16,
    body: String,
}

fn local_http_get(host: &str, port: u16, path: &str, token: Option<&str>) -> Result<HttpResponse> {
    let mut stream = TcpStream::connect((host, port))
        .with_context(|| format!("connect to H.A.R.V.I.S. Runtime API on {host}:{port}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(15)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;

    let auth_header = token
        .map(|value| format!("Authorization: Bearer {value}\r\n"))
        .unwrap_or_default();
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nAccept: application/json\r\nConnection: close\r\n{auth_header}\r\n"
    );
    stream.write_all(request.as_bytes())?;

    let mut response_bytes = Vec::new();
    let mut buffer = [0_u8; 8192];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => response_bytes.extend_from_slice(&buffer[..count]),
            Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                if response_bytes.is_empty() {
                    return Err(error.into());
                }
                break;
            }
            Err(error) => return Err(error.into()),
        }
    }
    let response =
        String::from_utf8(response_bytes).context("non-UTF-8 H.A.R.V.I.S. API response")?;
    let (headers, body) = response
        .split_once("\r\n\r\n")
        .context("malformed HTTP response from H.A.R.V.I.S. API")?;
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .context("missing HTTP status from H.A.R.V.I.S. API")?;
    Ok(HttpResponse {
        status,
        body: body.to_string(),
    })
}

fn endpoint_specs() -> Vec<EndpointSpec> {
    vec![
        EndpointSpec {
            endpoint: "/health",
            path_kind: PathKind::Plain,
            data_fields: vec![
                field("/agent", ExpectedKind::String),
                field("/api_version", ExpectedKind::String),
                field("/mode", ExpectedKind::String),
                field("/autonomy_level", ExpectedKind::Integer),
                field("/auth_required", ExpectedKind::Bool),
                field("/runtime", ExpectedKind::String),
                field("/bar_status", ExpectedKind::String),
                field("/permission_probe", ExpectedKind::String),
                field("/persona_studio", ExpectedKind::String),
                field("/knowledge_graph", ExpectedKind::String),
            ],
        },
        EndpointSpec {
            endpoint: "/bar/status",
            path_kind: PathKind::RootProfile,
            data_fields: vec![
                field("/schemaVersion", ExpectedKind::String),
                field("/safeForHarvisBar", ExpectedKind::BoolTrue),
                field("/generatedAt", ExpectedKind::String),
                field("/runtime/name", ExpectedKind::String),
                field("/runtime/state", ExpectedKind::String),
                field("/runtime/mode", ExpectedKind::String),
                field("/runtime/autonomyLevel", ExpectedKind::Integer),
                field("/runtime/summary", ExpectedKind::String),
                field("/workspace/label", ExpectedKind::String),
                field("/workspace/rootDisplay", ExpectedKind::String),
                field("/workspace/configured", ExpectedKind::Bool),
                field("/workspace/statusPresent", ExpectedKind::Bool),
                field("/serviceHealth/http", ExpectedKind::String),
                field("/serviceHealth/tickRunner", ExpectedKind::String),
                field("/serviceHealth/mcp", ExpectedKind::String),
                field("/work/packets", ExpectedKind::Integer),
                field("/work/blocked", ExpectedKind::Integer),
                field("/work/pendingApprovals", ExpectedKind::Integer),
                field("/work/runtimeErrors", ExpectedKind::Integer),
                field("/work/runtimeWarnings", ExpectedKind::Integer),
                field("/work/runs", ExpectedKind::Integer),
                field("/knowledge/hub", ExpectedKind::String),
                field("/knowledge/wiki", ExpectedKind::String),
                field("/knowledge/activeSources", ExpectedKind::Array),
                field("/knowledge/allowlistedSources", ExpectedKind::Integer),
                field("/knowledge/redacted", ExpectedKind::BoolTrue),
                field(
                    "/knowledge/includesLocalAbsolutePaths",
                    ExpectedKind::BoolFalse,
                ),
                field("/agentHarnesses/status", ExpectedKind::String),
                field(
                    "/agentHarnesses/includesModelCalls",
                    ExpectedKind::BoolFalse,
                ),
                field("/ports/status", ExpectedKind::String),
                field("/ports/items", ExpectedKind::Array),
                field("/ports/counts/listeners", ExpectedKind::Integer),
                field(
                    "/ports/safety/includesLocalAbsolutePaths",
                    ExpectedKind::BoolFalse,
                ),
                field(
                    "/taskProgress/schemaVersion",
                    ExpectedKind::ExactString("harvis.task-progress.v0"),
                ),
                field("/taskProgress/safeForHarvisBar", ExpectedKind::BoolTrue),
                field("/taskProgress/status", ExpectedKind::TaskProgressStatus),
                field("/taskProgress/activeCount", ExpectedKind::Integer),
                field("/taskProgress/items", ExpectedKind::Array),
                field("/taskProgress/current", ExpectedKind::NullOrObject),
                field("/taskProgress/safety/redacted", ExpectedKind::BoolTrue),
                field(
                    "/taskProgress/safety/includesSecrets",
                    ExpectedKind::BoolFalse,
                ),
                field(
                    "/taskProgress/safety/includesLocalAbsolutePaths",
                    ExpectedKind::BoolFalse,
                ),
                field("/safety/redacted", ExpectedKind::BoolTrue),
                field("/safety/includesSecrets", ExpectedKind::BoolFalse),
                field("/safety/includesRawMemory", ExpectedKind::BoolFalse),
                field(
                    "/safety/includesLocalAbsolutePaths",
                    ExpectedKind::BoolFalse,
                ),
                field("/safety/networkExposure", ExpectedKind::String),
            ],
        },
        EndpointSpec {
            endpoint: "/task-progress",
            path_kind: PathKind::RootLimit(20),
            data_fields: vec![
                field(
                    "/schemaVersion",
                    ExpectedKind::ExactString("harvis.task-progress.v0"),
                ),
                field("/safeForHarvisBar", ExpectedKind::BoolTrue),
                field("/generatedAt", ExpectedKind::String),
                field("/status", ExpectedKind::TaskProgressStatus),
                field("/summary", ExpectedKind::String),
                field("/activeCount", ExpectedKind::Integer),
                field("/items", ExpectedKind::Array),
                field("/current", ExpectedKind::NullOrObject),
                field("/safety/redacted", ExpectedKind::BoolTrue),
                field("/safety/includesSecrets", ExpectedKind::BoolFalse),
                field(
                    "/safety/includesLocalAbsolutePaths",
                    ExpectedKind::BoolFalse,
                ),
            ],
        },
        EndpointSpec {
            endpoint: "/permission-probe",
            path_kind: PathKind::RootProfile,
            data_fields: vec![
                field("/permission_probe_version", ExpectedKind::String),
                field("/ok", ExpectedKind::Bool),
                field("/context", ExpectedKind::String),
                field("/checks", ExpectedKind::Array),
                field("/redacted", ExpectedKind::BoolTrue),
                field("/includesLocalAbsolutePaths", ExpectedKind::BoolFalse),
            ],
        },
        EndpointSpec {
            endpoint: "/knowledge-graph",
            path_kind: PathKind::Root,
            data_fields: vec![
                field("/graph_version", ExpectedKind::String),
                field("/nodes", ExpectedKind::Array),
                field("/edges", ExpectedKind::Array),
                field("/stats", ExpectedKind::Object),
                field("/stats/node_count", ExpectedKind::Integer),
                field("/stats/edge_count", ExpectedKind::Integer),
                field("/stats/tags", ExpectedKind::Array),
                field("/source", ExpectedKind::Object),
                field("/source/vaults", ExpectedKind::Array),
                field("/limits", ExpectedKind::Object),
                field("/read_only", ExpectedKind::BoolTrue),
                field("/redacted", ExpectedKind::BoolTrue),
                field("/includesLocalAbsolutePaths", ExpectedKind::BoolFalse),
                field("/warnings", ExpectedKind::Array),
                field("/errors", ExpectedKind::Array),
            ],
        },
        EndpointSpec {
            endpoint: "/persona",
            path_kind: PathKind::RootLimit(100),
            data_fields: vec![
                field("/persona_registry_version", ExpectedKind::String),
                field("/review_queue_version", ExpectedKind::String),
                field("/workspace", ExpectedKind::Object),
                field("/memory_vaults", ExpectedKind::Array),
                field("/persona_cards", ExpectedKind::Array),
                field("/twin_instances", ExpectedKind::Array),
                field("/personality_candidates", ExpectedKind::Array),
                field("/pending_personality_review", ExpectedKind::Array),
            ],
        },
        EndpointSpec {
            endpoint: "/runs",
            path_kind: PathKind::RootLimit(12),
            data_fields: vec![
                field("/workspace_root", ExpectedKind::String),
                field("/run_count", ExpectedKind::Integer),
                field("/runs", ExpectedKind::Array),
            ],
        },
        EndpointSpec {
            endpoint: "/events",
            path_kind: PathKind::RootLimit(12),
            data_fields: vec![
                field("/workspace_root", ExpectedKind::String),
                field("/state_store", ExpectedKind::String),
                field("/events", ExpectedKind::Array),
            ],
        },
        EndpointSpec {
            endpoint: "/approvals",
            path_kind: PathKind::RootLimit(50),
            data_fields: vec![
                field("/workspace_root", ExpectedKind::String),
                field("/approval_count", ExpectedKind::Integer),
                field("/approvals", ExpectedKind::Array),
            ],
        },
        EndpointSpec {
            endpoint: "/agent-room",
            path_kind: PathKind::RootLimit(80),
            data_fields: vec![
                field("/agent_room_version", ExpectedKind::String),
                field("/workspace", ExpectedKind::Object),
                field("/topics", ExpectedKind::Array),
                field("/events", ExpectedKind::Array),
                field("/messages", ExpectedKind::Array),
                field("/handoffs", ExpectedKind::Array),
            ],
        },
        EndpointSpec {
            endpoint: "/handoffs",
            path_kind: PathKind::RootLimit(40),
            data_fields: vec![
                field("/handoff_version", ExpectedKind::String),
                field("/workspace", ExpectedKind::Object),
                field("/handoffs", ExpectedKind::Array),
            ],
        },
        EndpointSpec {
            endpoint: "/memory-candidates",
            path_kind: PathKind::RootLimit(50),
            data_fields: vec![
                field("/workspace", ExpectedKind::Object),
                field("/candidate_count", ExpectedKind::Integer),
                field("/candidates", ExpectedKind::Array),
            ],
        },
    ]
}

const fn field(pointer: &'static str, kind: ExpectedKind) -> FieldSpec {
    FieldSpec { pointer, kind }
}

fn workspace_label(root: &Path) -> String {
    root.file_name()
        .and_then(|name| name.to_str())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| "workspace".to_string())
}

fn url_encode(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                vec![byte as char]
            }
            _ => format!("%{byte:02X}").chars().collect::<Vec<_>>(),
        })
        .collect()
}

fn expanduser(path: &Path) -> PathBuf {
    let Some(value) = path.to_str() else {
        return path.to_path_buf();
    };
    if value == "~" {
        return harvis_macos::service_manager::home_dir();
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return harvis_macos::service_manager::home_dir().join(rest);
    }
    path.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_contract_includes_dashboard_and_bar_surfaces() {
        let endpoints = endpoint_specs()
            .iter()
            .map(|spec| spec.endpoint)
            .collect::<Vec<_>>();
        for endpoint in [
            "/health",
            "/bar/status",
            "/task-progress",
            "/permission-probe",
            "/knowledge-graph",
            "/persona",
            "/runs",
            "/events",
            "/approvals",
            "/agent-room",
            "/handoffs",
            "/memory-candidates",
        ] {
            assert!(endpoints.contains(&endpoint));
        }
    }

    #[test]
    fn bar_status_contract_keeps_privacy_flags() {
        let specs = endpoint_specs();
        let bar = specs
            .iter()
            .find(|spec| spec.endpoint == "/bar/status")
            .expect("bar status spec");
        let fields = bar
            .data_fields
            .iter()
            .map(|field| field.pointer)
            .collect::<Vec<_>>();
        assert!(fields.contains(&"/safeForHarvisBar"));
        assert!(fields.contains(&"/taskProgress/status"));
        assert!(fields.contains(&"/taskProgress/safety/includesLocalAbsolutePaths"));
        assert!(fields.contains(&"/safety/includesSecrets"));
        assert!(fields.contains(&"/safety/includesLocalAbsolutePaths"));
    }
}
