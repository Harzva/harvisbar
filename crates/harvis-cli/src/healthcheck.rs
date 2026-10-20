use anyhow::{bail, Result};
use harvis_integrations::agent_harnesses::build_agent_harness_status;
use harvis_integrations::hub::{hub_status, llmwiki_status, wiki_search};
use harvis_integrations::repoatlas::{
    repoatlas_find_repo, repoatlas_missing_local_copies, repoatlas_needs_attention,
    repoatlas_status,
};
use harvis_macos::service_manager::{self, LaunchAgentConfig, Service};
use harvis_runtime::agent_room::{create_topic, init_agent_room};
use harvis_runtime::init::init_workspace;
use harvis_runtime::notifications::check_notifications;
use harvis_runtime::persona::init_persona_registry;
use harvis_runtime::workbench::{prepare_workbench, WorkbenchOptions};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

const REQUIRED_FILES: &[&str] = &[
    ".codex-plugin/plugin.json",
    ".mcp.json",
    "scripts/harvis",
    "scripts/harvis_rust_shim.py",
    "mcp/harvis_mcp_server.py",
    "crates/harvis-core/src/lib.rs",
    "crates/harvis-runtime/src/init.rs",
    "crates/harvis-runtime/src/inbox.rs",
    "crates/harvis-runtime/src/tick.rs",
    "crates/harvis-runtime/src/runs.rs",
    "crates/harvis-runtime/src/approvals.rs",
    "crates/harvis-runtime/src/agent_room.rs",
    "crates/harvis-runtime/src/persona.rs",
    "crates/harvis-runtime/src/notifications.rs",
    "crates/harvis-runtime/src/memory.rs",
    "crates/harvis-runtime/src/memory_provider.rs",
    "crates/harvis-runtime/src/knowledge_graph.rs",
    "crates/harvis-runtime/src/workbench.rs",
    "crates/harvis-integrations/src/hub.rs",
    "crates/harvis-integrations/src/repoatlas.rs",
    "crates/harvis-integrations/src/agent_harnesses.rs",
    "crates/harvis-http/src/routes.rs",
    "crates/harvis-macos/src/service_manager.rs",
    "crates/harvis-mcp/src/lib.rs",
    "crates/harvis-cli/src/main.rs",
    "crates/harvis-cli/src/ui_healthcheck.rs",
    "schemas/ui-contract.schema.json",
    "schemas/memory-provider-v1.schema.json",
    "schemas/portable-memory-bundle-v1.schema.json",
];

const HOT_PYTHON_SHIMS: &[&str] = &[
    "mcp/harvis_mcp_server.py",
    "scripts/harvis_agent_harnesses.py",
    "scripts/harvis_agent_room.py",
    "scripts/harvis_approval_item.py",
    "scripts/harvis_http_api.py",
    "scripts/harvis_hub_adapter.py",
    "scripts/harvis_init_profile.py",
    "scripts/harvis_init_workspace.py",
    "scripts/harvis_inbox_scan.py",
    "scripts/harvis_knowledge_graph.py",
    "scripts/harvis_memory_snapshot.py",
    "scripts/harvis_notification_policy.py",
    "scripts/harvis_permission_probe.py",
    "scripts/harvis_persona_registry.py",
    "scripts/harvis_repoatlas_adapter.py",
    "scripts/harvis_run_ledger.py",
    "scripts/harvis_runtime_tick.py",
    "scripts/harvis_service_manager.py",
    "scripts/harvis_workbench.py",
];

const RETAINED_PYTHON_TOOLS: &[&str] = &[
    "scripts/harvis_bar_status.py",
    "scripts/harvis_generate_app_icon.py",
    "scripts/harvis_bar_release_manifest.py",
    "scripts/harvis_healthcheck.py",
    "scripts/harvis_task_packet.py",
];

pub fn run(plugin_root: PathBuf) -> Result<()> {
    let plugin_root = plugin_root
        .canonicalize()
        .unwrap_or_else(|_| plugin_root.clone());
    let mut checks = Vec::new();
    let mut errors = Vec::new();

    push_check(
        &mut checks,
        &mut errors,
        "required_files",
        required_files(&plugin_root),
    );
    push_check(
        &mut checks,
        &mut errors,
        "mcp_config_rust_entrypoint",
        mcp_config(&plugin_root),
    );
    push_check(
        &mut checks,
        &mut errors,
        "launch_agent_rust_http",
        launch_agent(&plugin_root, Service::Http),
    );
    push_check(
        &mut checks,
        &mut errors,
        "launch_agent_rust_tick",
        launch_agent(&plugin_root, Service::Tick),
    );
    push_check(&mut checks, &mut errors, "mcp_stdio_smoke", mcp_smoke());
    push_check(
        &mut checks,
        &mut errors,
        "runtime_store_smoke",
        runtime_store_smoke(),
    );
    push_check(
        &mut checks,
        &mut errors,
        "workbench_smoke",
        workbench_smoke(),
    );
    push_check(
        &mut checks,
        &mut errors,
        "integrations_redaction_smoke",
        integrations_redaction_smoke(),
    );
    push_check(
        &mut checks,
        &mut errors,
        "mcp_native_tool_calls",
        mcp_native_tool_calls(),
    );
    push_check(
        &mut checks,
        &mut errors,
        "python_hot_entrypoint_shims",
        python_hot_entrypoint_shims(&plugin_root),
    );

    let ok = errors.is_empty();
    let payload = json!({
        "ok": ok,
        "runtime": "rust",
        "healthcheck_version": "v0.44-rust-alpha",
        "http_api_version": harvis_http::routes::API_VERSION,
        "checks": checks,
        "errors": errors
    });
    println!("{}", serde_json::to_string_pretty(&payload)?);
    if !ok {
        bail!("Rust H.A.R.V.I.S. healthcheck failed");
    }
    Ok(())
}

fn push_check(
    checks: &mut Vec<Value>,
    errors: &mut Vec<String>,
    name: &str,
    result: std::result::Result<Value, String>,
) {
    match result {
        Ok(data) => checks.push(json!({"name": name, "ok": true, "data": data})),
        Err(error) => {
            checks.push(json!({"name": name, "ok": false, "error": error}));
            errors.push(format!("{name}: {error}"));
        }
    }
}

fn required_files(plugin_root: &Path) -> std::result::Result<Value, String> {
    let missing = REQUIRED_FILES
        .iter()
        .filter(|path| !plugin_root.join(path).exists())
        .copied()
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return Err(format!("missing files: {}", missing.join(", ")));
    }
    Ok(json!({"required_count": REQUIRED_FILES.len()}))
}

fn python_hot_entrypoint_shims(plugin_root: &Path) -> std::result::Result<Value, String> {
    let mut missing = Vec::new();
    let mut not_shimmed = Vec::new();
    for relative in HOT_PYTHON_SHIMS {
        let path = plugin_root.join(relative);
        let Ok(text) = fs::read_to_string(&path) else {
            missing.push(*relative);
            continue;
        };
        let rust_shimmed = text.contains("harvis_rust_shim")
            || (relative.starts_with("mcp/") && text.contains("[str(runtime), \"mcp\"]"));
        if !rust_shimmed {
            not_shimmed.push(*relative);
        }
    }
    if !missing.is_empty() {
        return Err(format!(
            "missing hot Python shim files: {}",
            missing.join(", ")
        ));
    }
    if !not_shimmed.is_empty() {
        return Err(format!(
            "hot Python entrypoints not routed to Rust: {}",
            not_shimmed.join(", ")
        ));
    }

    let retained_existing = RETAINED_PYTHON_TOOLS
        .iter()
        .filter(|relative| plugin_root.join(relative).exists())
        .count();
    Ok(json!({
        "hot_shim_count": HOT_PYTHON_SHIMS.len(),
        "retained_low_frequency_count": retained_existing,
        "retained_low_frequency_tools": RETAINED_PYTHON_TOOLS
    }))
}

fn mcp_config(plugin_root: &Path) -> std::result::Result<Value, String> {
    let path = plugin_root.join(".mcp.json");
    let value = read_json(&path)?;
    let harvis = value
        .get("mcpServers")
        .and_then(|servers| servers.get("harvis"))
        .ok_or_else(|| "missing mcpServers.harvis".to_string())?;
    let command = harvis.get("command").and_then(Value::as_str);
    let args = harvis.get("args").and_then(Value::as_array);
    if command != Some("./scripts/harvis") {
        return Err("H.A.R.V.I.S. MCP command must be ./scripts/harvis".to_string());
    }
    let expected_args = [Value::String("mcp".to_string())];
    if args.is_none_or(|items| items.as_slice() != expected_args) {
        return Err("H.A.R.V.I.S. MCP args must be [\"mcp\"]".to_string());
    }
    Ok(json!({"command": command, "args": ["mcp"]}))
}

fn launch_agent(plugin_root: &Path, service: Service) -> std::result::Result<Value, String> {
    let temp = temp_path(&format!("harvis-rust-healthcheck-{}", service.as_str()));
    let mut config = LaunchAgentConfig::new(service, plugin_root);
    config.home = temp.join("home");
    config.root = temp.join("workspace");
    config.profile_root = temp.join("profile");
    config.auth_token_file =
        (service == Service::Http).then(|| temp.join("home/.harvis/auth/http.token"));
    let plist = service_manager::render_launch_agent(&config);
    if plist.contains("/usr/bin/python3")
        || plist.contains("harvis_http_api.py")
        || plist.contains("harvis_runtime_tick.py")
    {
        return Err("LaunchAgent plist still references Python runtime".to_string());
    }
    let args = service_manager::program_arguments(&config);
    let expected_subcommand = if service == Service::Http {
        "http"
    } else {
        "run-tick"
    };
    if !args.iter().any(|arg| arg == expected_subcommand) {
        return Err(format!("LaunchAgent args missing {expected_subcommand}"));
    }
    Ok(
        json!({"label": service.label(), "program": args.first(), "subcommand": expected_subcommand}),
    )
}

fn mcp_smoke() -> std::result::Result<Value, String> {
    let response =
        harvis_mcp::handle_raw_request(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            .map_err(|error| format!("MCP request failed: {error:?}"))?
            .ok_or_else(|| "MCP tools/list returned no response".to_string())?;
    let tools = response
        .get("result")
        .and_then(|result| result.get("tools"))
        .and_then(Value::as_array)
        .ok_or_else(|| "MCP tools/list response missing tools".to_string())?;
    let names = tools
        .iter()
        .filter_map(|tool| tool.get("name").and_then(Value::as_str))
        .collect::<Vec<_>>();
    for required in [
        "harvis_init_workspace",
        "harvis_persona_init",
        "harvis_repoatlas_find_repo",
    ] {
        if !names.contains(&required) {
            return Err(format!("MCP tools/list missing {required}"));
        }
    }
    Ok(json!({"tool_count": names.len()}))
}

fn runtime_store_smoke() -> std::result::Result<Value, String> {
    let root = temp_path("harvis-rust-runtime-store-smoke");
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).map_err(|error| error.to_string())?;
    init_workspace(&root, false).map_err(|error| error.to_string())?;
    let persona = init_persona_registry(&root).map_err(|error| error.to_string())?;
    init_agent_room(&root).map_err(|error| error.to_string())?;
    let topic = create_topic(
        &root,
        "Rust healthcheck",
        "Verify runtime stores",
        "healthcheck",
    )
    .map_err(|error| error.to_string())?;
    fs::write(
        root.join(".harvis/status.json"),
        json!({
            "last_tick_at": "2026-06-24T00:00:00+00:00",
            "packet_status_counts": {},
            "errors": []
        })
        .to_string(),
    )
    .map_err(|error| error.to_string())?;
    let notifications = check_notifications(&root, true).map_err(|error| error.to_string())?;
    let _ = fs::remove_dir_all(&root);
    Ok(json!({
        "persona_cards": persona.get("persona_cards").and_then(Value::as_array).map(Vec::len).unwrap_or(0),
        "topic_id": topic.get("topic_id").cloned().unwrap_or(Value::Null),
        "notifications_written": notifications.get("written_count").cloned().unwrap_or(Value::Null)
    }))
}

fn workbench_smoke() -> std::result::Result<Value, String> {
    let root = temp_path("harvis-rust-workbench-smoke");
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).map_err(|error| error.to_string())?;
    init_workspace(&root, false).map_err(|error| error.to_string())?;
    let packet_path = root.join(".harvis/outbox/workbench-smoke.md");
    fs::write(
        &packet_path,
        [
            "# H.A.R.V.I.S. Work Packet workbench-smoke",
            "",
            "Status: new",
            "Source: .harvis/inbox.md:1",
            "Safety: no sensitive marker detected",
            "",
            "## Request",
            "",
            "```text",
            "@harvis Prepare Rust workbench smoke.",
            "```",
            "",
        ]
        .join("\n"),
    )
    .map_err(|error| error.to_string())?;
    let profile_root = root.join("profile");
    let result = prepare_workbench(WorkbenchOptions {
        root: root.clone(),
        profile_root,
        packet: Some("workbench-smoke".to_string()),
        limit: 5,
    })
    .map_err(|error| error.to_string())?;
    let prepared = result
        .get("prepared")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .ok_or_else(|| "workbench did not prepare a packet".to_string())?;
    for relative in [
        "planner.md",
        "executor.md",
        "reviewer.md",
        "harvis-summary.md",
        "index.json",
    ] {
        let path = root
            .join(".harvis/workbench/workbench-smoke")
            .join(relative);
        if !path.exists() {
            return Err(format!("workbench missing output: {}", path.display()));
        }
    }
    let _ = fs::remove_dir_all(&root);
    Ok(json!({
        "packet_id": prepared.get("packet_id").cloned().unwrap_or(Value::Null),
        "packet_count": result.get("packet_count").cloned().unwrap_or(Value::Null)
    }))
}

fn integrations_redaction_smoke() -> std::result::Result<Value, String> {
    let root = temp_path("harvis-rust-integrations-smoke");
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).map_err(|error| error.to_string())?;
    let map_path = root.join("repoatlas-local-address-map.json");
    let local_root = root.join("local/repos");
    fs::create_dir_all(&local_root).map_err(|error| error.to_string())?;
    write_repoatlas_fixture(&map_path, &local_root)?;

    let hub = hub_status();
    validate_no_local_paths("hub_status", &hub)?;
    let llmwiki = llmwiki_status();
    validate_no_local_paths("llmwiki_status", &llmwiki)?;
    let wiki = wiki_search("llmwiki", 1, 120).map_err(|error| error.to_string())?;
    validate_no_local_paths("wiki_search", &wiki)?;

    let map = map_path.display().to_string();
    let repo_status = repoatlas_status(Some(&map), false);
    let repo_find = repoatlas_find_repo("Harzva/mobilecode", 10, Some(&map), false)
        .map_err(|error| error.to_string())?;
    let repo_missing = repoatlas_missing_local_copies(50, Some(&map));
    let repo_attention = repoatlas_needs_attention(50, Some(&map), false);
    for (label, payload) in [
        ("repoatlas_status", &repo_status),
        ("repoatlas_find", &repo_find),
        ("repoatlas_missing", &repo_missing),
        ("repoatlas_attention", &repo_attention),
    ] {
        validate_no_local_paths(label, payload)?;
    }
    if repo_find.get("count").and_then(Value::as_u64) != Some(1) {
        return Err("RepoAtlas Rust find should return one fixture match".to_string());
    }
    let harnesses = build_agent_harness_status(false, 120);
    if harnesses.get("schemaVersion").and_then(Value::as_str) != Some("harvis.agent-harnesses.v0") {
        return Err("agent harness schema version mismatch".to_string());
    }
    if harnesses.get("includesModelCalls").and_then(Value::as_bool) != Some(false) {
        return Err("agent harness status smoke must not run model calls".to_string());
    }
    let _ = fs::remove_dir_all(&root);
    Ok(json!({
        "repoatlas_find_count": repo_find.get("count").cloned().unwrap_or(Value::Null),
        "harness_status": harnesses.get("status").cloned().unwrap_or(Value::Null)
    }))
}

fn mcp_native_tool_calls() -> std::result::Result<Value, String> {
    let root = temp_path("harvis-rust-mcp-native-smoke");
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).map_err(|error| error.to_string())?;
    init_workspace(&root, false).map_err(|error| error.to_string())?;
    fs::write(
        root.join(".harvis/outbox/mcp-workbench-smoke.md"),
        [
            "# H.A.R.V.I.S. Work Packet mcp-workbench-smoke",
            "",
            "Status: new",
            "Source: .harvis/inbox.md:1",
            "Safety: no sensitive marker detected",
            "",
            "## Request",
            "",
            "```text",
            "@harvis MCP workbench smoke.",
            "```",
            "",
        ]
        .join("\n"),
    )
    .map_err(|error| error.to_string())?;
    let map_path = root.join("repoatlas-local-address-map.json");
    write_repoatlas_fixture(&map_path, &root.join("repos"))?;

    let workbench = call_mcp_tool(
        "harvis_prepare_workbench",
        json!({"root": root.display().to_string(), "packet": "mcp-workbench-smoke"}),
    )?;
    if workbench.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err("MCP workbench call did not return ok".to_string());
    }
    let repo = call_mcp_tool(
        "harvis_repoatlas_find_repo",
        json!({"query": "Harzva/mobilecode", "map_path": map_path.display().to_string()}),
    )?;
    if repo.pointer("/data/count").and_then(Value::as_u64) != Some(1) {
        return Err("MCP RepoAtlas find did not return fixture match".to_string());
    }
    let hub = call_mcp_tool("harvis_hub_status", json!({}))?;
    if hub.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err("MCP hub status did not return ok".to_string());
    }
    let _ = fs::remove_dir_all(&root);
    Ok(json!({
        "workbench_ok": true,
        "repoatlas_count": 1,
        "hub_tool": hub.get("tool").cloned().unwrap_or(Value::Null)
    }))
}

fn call_mcp_tool(name: &str, arguments: Value) -> std::result::Result<Value, String> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": name,
            "arguments": arguments
        }
    });
    let response = harvis_mcp::handle_raw_request(&request.to_string())
        .map_err(|error| format!("MCP tool call failed: {error:?}"))?
        .ok_or_else(|| "MCP tool call returned no response".to_string())?;
    if let Some(error) = response.get("error") {
        return Err(format!("MCP error: {error}"));
    }
    let text = response
        .pointer("/result/content/0/text")
        .and_then(Value::as_str)
        .ok_or_else(|| "MCP tool response missing text content".to_string())?;
    serde_json::from_str(text).map_err(|error| error.to_string())
}

fn write_repoatlas_fixture(path: &Path, local_root: &Path) -> std::result::Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    fs::create_dir_all(local_root).map_err(|error| error.to_string())?;
    fs::write(
        path,
        serde_json::to_string_pretty(&json!({
            "generatedAt": "2026-06-24T00:00:00+00:00",
            "summary": {
                "remoteCount": 2,
                "localRepoCount": 1,
                "matchedRemoteCount": 1,
                "missingLocalCount": 1,
                "attentionCount": 1
            },
            "repositories": [
                {
                    "repoKey": "harzva/mobilecode",
                    "nameWithOwner": "Harzva/mobilecode",
                    "url": "https://github.com/Harzva/mobilecode",
                    "accountAlias": "Harzva",
                    "accountLogin": "Harzva",
                    "localExists": true,
                    "localPaths": [local_root.join("MobileCode").display().to_string()],
                    "localStatus": "dirty",
                    "dirty": true,
                    "ahead": 0,
                    "behind": 0
                },
                {
                    "repoKey": "harzva/missing",
                    "nameWithOwner": "Harzva/missing",
                    "url": "https://github.com/Harzva/missing",
                    "accountAlias": "Harzva",
                    "accountLogin": "Harzva",
                    "localExists": false,
                    "localPaths": [],
                    "localStatus": "no-local-copy",
                    "dirty": false,
                    "ahead": 0,
                    "behind": 0
                }
            ]
        }))
        .map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())
}

fn validate_no_local_paths(label: &str, payload: &Value) -> std::result::Result<(), String> {
    let rendered = serde_json::to_string(payload).map_err(|error| error.to_string())?;
    for marker in ["/Users/", "/Volumes/"] {
        if rendered.contains(marker) {
            return Err(format!(
                "{label} leaked local absolute path marker: {marker}"
            ));
        }
    }
    if payload.get("includesLocalAbsolutePaths").is_some()
        && payload
            .get("includesLocalAbsolutePaths")
            .and_then(Value::as_bool)
            != Some(false)
    {
        return Err(format!("{label} includesLocalAbsolutePaths must be false"));
    }
    Ok(())
}

fn read_json(path: &Path) -> std::result::Result<Value, String> {
    let text = fs::read_to_string(path).map_err(|error| error.to_string())?;
    serde_json::from_str(&text).map_err(|error| error.to_string())
}

fn temp_path(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("{name}-{}", std::process::id()))
}
