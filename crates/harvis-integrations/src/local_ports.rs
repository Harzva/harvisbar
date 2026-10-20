use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::process::Command;

#[derive(Debug, Clone)]
struct KnownPort {
    id: &'static str,
    label: &'static str,
    port: u16,
    function: &'static str,
    url: &'static str,
    launch_label: Option<&'static str>,
    important: bool,
    show_in_harvis_bar: bool,
    lifecycle: &'static str,
}

#[derive(Debug, Clone)]
struct Listener {
    pid: u32,
    command: String,
    address: String,
    port: u16,
}

const KNOWN_PORTS: &[KnownPort] = &[
    KnownPort {
        id: "harvis-http",
        label: "H.A.R.V.I.S. Runtime API",
        port: 8765,
        function: "H.A.R.V.I.S. Studio, Presence, Bar API, and runtime control",
        url: "http://127.0.0.1:8765/studio/",
        launch_label: Some("local.harzva.harvis.http"),
        important: true,
        show_in_harvis_bar: true,
        lifecycle: "managed",
    },
    KnownPort {
        id: "local-knowledge-hub",
        label: "H.A.R.V.I.S. Knowledge Base",
        port: 6666,
        function: "H.A.R.V.I.S. local knowledge dashboard and repo index",
        url: "http://127.0.0.1:6666/",
        launch_label: Some("com.harzva.local-knowledge-hub"),
        important: true,
        show_in_harvis_bar: true,
        lifecycle: "managed",
    },
    KnownPort {
        id: "digital-me-project-console",
        label: "H.A.R.V.I.S. Console",
        port: 7861,
        function: "H.A.R.V.I.S. project console and WebView gateway",
        url: "http://127.0.0.1:7861/",
        launch_label: Some("com.harzva.digital-me.project-console"),
        important: true,
        show_in_harvis_bar: true,
        lifecycle: "managed",
    },
    KnownPort {
        id: "h5magic-office-workbench",
        label: "H5Magic Office Workbench",
        port: 8766,
        function: "H5Magic Office local file center and editor workbench",
        url: "http://127.0.0.1:8766/console.html",
        launch_label: Some("local.harzva.h5magic.workbench.8766"),
        important: false,
        show_in_harvis_bar: true,
        lifecycle: "on-demand",
    },
    KnownPort {
        id: "h5magic-agent-bridge",
        label: "H5Magic Agent Bridge",
        port: 8776,
        function: "H5Magic Agent tool and MCP bridge",
        url: "http://127.0.0.1:8776/",
        launch_label: None,
        important: false,
        show_in_harvis_bar: true,
        lifecycle: "on-demand",
    },
    KnownPort {
        id: "codex-image-canvas",
        label: "Codex Image Canvas",
        port: 7788,
        function: "Local image canvas asset bridge",
        url: "http://127.0.0.1:7788/",
        launch_label: Some("com.harzva.codex-image-canvas"),
        important: false,
        show_in_harvis_bar: false,
        lifecycle: "managed",
    },
    KnownPort {
        id: "open-codex-launcher",
        label: "Open Codex Launcher",
        port: 4188,
        function: "Local launcher bridge",
        url: "http://127.0.0.1:4188/",
        launch_label: Some("com.open-codex-launcher"),
        important: false,
        show_in_harvis_bar: false,
        lifecycle: "managed",
    },
    KnownPort {
        id: "esp32-codex-status",
        label: "ESP32 Codex Status",
        port: 8787,
        function: "ESP32 Codex status bridge",
        url: "http://127.0.0.1:8787/",
        launch_label: Some("com.harzva.esp32-codex-status-bridge"),
        important: false,
        show_in_harvis_bar: false,
        lifecycle: "managed",
    },
    KnownPort {
        id: "esp32-config-panel",
        label: "ESP32 Config Panel",
        port: 8790,
        function: "ESP32 local configuration panel",
        url: "http://127.0.0.1:8790/",
        launch_label: Some("com.harzva.esp32-config-panel"),
        important: false,
        show_in_harvis_bar: false,
        lifecycle: "managed",
    },
    KnownPort {
        id: "codex-web-bridge",
        label: "Codex Web Bridge",
        port: 3838,
        function: "Codex web bridge",
        url: "http://127.0.0.1:3838/",
        launch_label: Some("com.codexweb.bridge"),
        important: false,
        show_in_harvis_bar: false,
        lifecycle: "managed",
    },
    KnownPort {
        id: "ngrok-console",
        label: "ngrok Console",
        port: 4040,
        function: "Local ngrok inspection console",
        url: "http://127.0.0.1:4040/",
        launch_label: Some("com.harzva.codexbridge.ngrok"),
        important: false,
        show_in_harvis_bar: false,
        lifecycle: "managed",
    },
    KnownPort {
        id: "ngrok-harvis-workbench",
        label: "Harvis Workbench Tunnel",
        port: 4041,
        function: "Local ngrok inspection console for Harvis workbench tunnel",
        url: "http://127.0.0.1:4041/",
        launch_label: Some("local.harzva.ngrok-harvis-workbench"),
        important: false,
        show_in_harvis_bar: false,
        lifecycle: "managed",
    },
];

pub fn local_ports_status() -> Value {
    let listeners = lsof_listeners();
    let launchctl = launchctl_rows();
    let mut by_port: BTreeMap<u16, Vec<Listener>> = BTreeMap::new();
    for listener in listeners {
        by_port.entry(listener.port).or_default().push(listener);
    }

    let mut seen_ports = BTreeSet::new();
    let mut items = Vec::new();
    for known in KNOWN_PORTS {
        seen_ports.insert(known.port);
        items.push(port_item(
            known.port,
            Some(known),
            by_port.get(&known.port).cloned().unwrap_or_default(),
            &launchctl,
        ));
    }
    for (port, listeners) in by_port {
        if seen_ports.contains(&port) {
            continue;
        }
        items.push(port_item(port, None, listeners, &launchctl));
    }

    let running = items
        .iter()
        .filter(|item| item.get("listening").and_then(Value::as_bool) == Some(true))
        .count();
    let important = items
        .iter()
        .filter(|item| item.get("important").and_then(Value::as_bool) == Some(true))
        .count();
    let important_running = items
        .iter()
        .filter(|item| {
            item.get("important").and_then(Value::as_bool) == Some(true)
                && item.get("listening").and_then(Value::as_bool) == Some(true)
        })
        .count();
    let autostart_ready = items
        .iter()
        .filter(|item| {
            item.get("important").and_then(Value::as_bool) == Some(true)
                && item
                    .get("autostart")
                    .and_then(|value| value.get("loaded"))
                    .and_then(Value::as_bool)
                    == Some(true)
        })
        .count();

    json!({
        "schemaVersion": "harvis.ports-status.v0",
        "safeForHarvisBar": true,
        "generatedAt": harvis_core::time::now_rfc3339().unwrap_or_else(|_| String::new()),
        "status": if important == important_running && important == autostart_ready { "ready" } else { "needs_review" },
        "summary": format!("{running} listener(s), {important_running}/{important} important running, {autostart_ready}/{important} important autostart-ready."),
        "counts": {
            "listeners": running,
            "known": KNOWN_PORTS.len(),
            "important": important,
            "importantRunning": important_running,
            "importantAutostartReady": autostart_ready
        },
        "items": items,
        "management": {
            "autostartPolicy": "known-launchagent-only",
            "harvisServiceManager": "scripts/harvis service-manager",
            "canManageUnknownPorts": false
        },
        "safety": {
            "redacted": true,
            "includesSecrets": false,
            "includesLocalAbsolutePaths": false,
            "networkExposure": "localhost-observed"
        }
    })
}

fn port_item(
    port: u16,
    known: Option<&KnownPort>,
    listeners: Vec<Listener>,
    launchctl: &BTreeMap<String, Value>,
) -> Value {
    let primary = listeners.first();
    let label = known
        .map(|known| known.label.to_string())
        .or_else(|| primary.map(|listener| listener.command.clone()))
        .unwrap_or_else(|| format!("Port {port}"));
    let launch_label = known.and_then(|known| known.launch_label);
    let autostart = launch_label
        .map(|label| {
            launchctl.get(label).cloned().unwrap_or_else(|| {
                json!({
                    "label": label,
                    "loaded": false,
                    "running": false,
                    "plistPresent": launch_agent_exists(label)
                })
            })
        })
        .unwrap_or_else(
            || json!({"label": null, "loaded": false, "running": false, "plistPresent": false}),
        );
    let pids = listeners
        .iter()
        .map(|listener| listener.pid)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let uptime = pids.first().and_then(|pid| process_etime(*pid));
    json!({
        "id": known.map(|known| known.id.to_string()).unwrap_or_else(|| format!("port-{port}")),
        "label": label,
        "port": port,
        "host": primary.map(|listener| listener.address.clone()).unwrap_or_else(|| "127.0.0.1".to_string()),
        "url": known.map(|known| known.url).unwrap_or(""),
        "function": known.map(|known| known.function).unwrap_or("Unregistered local listener"),
        "known": known.is_some(),
        "important": known.map(|known| known.important).unwrap_or(false),
        "showInHarvisBar": known.map(|known| known.show_in_harvis_bar).unwrap_or(false),
        "lifecycle": known.map(|known| known.lifecycle).unwrap_or("external"),
        "listening": !listeners.is_empty(),
        "process": primary.map(|listener| listener.command.clone()).unwrap_or_else(|| "-".to_string()),
        "pid": primary.map(|listener| json!(listener.pid)).unwrap_or(Value::Null),
        "pids": pids,
        "uptime": uptime,
        "listeners": listeners.into_iter().map(|listener| json!({
            "pid": listener.pid,
            "process": listener.command,
            "address": listener.address,
            "port": listener.port
        })).collect::<Vec<_>>(),
        "autostart": autostart,
        "safeForHarvisBar": true
    })
}

fn lsof_listeners() -> Vec<Listener> {
    let Ok(output) = Command::new("lsof")
        .args(["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcPn"])
        .output()
    else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    parse_lsof(&String::from_utf8_lossy(&output.stdout))
}

fn parse_lsof(text: &str) -> Vec<Listener> {
    let mut pid: Option<u32> = None;
    let mut command = String::new();
    let mut listeners = Vec::new();
    for line in text.lines() {
        let mut chars = line.chars();
        let Some(kind) = chars.next() else {
            continue;
        };
        let value = chars.as_str();
        match kind {
            'p' => {
                pid = value.parse::<u32>().ok();
                command.clear();
            }
            'c' => command = value.to_string(),
            'n' => {
                let Some(pid) = pid else {
                    continue;
                };
                if let Some((address, port)) = parse_name(value) {
                    listeners.push(Listener {
                        pid,
                        command: command.clone(),
                        address,
                        port,
                    });
                }
            }
            _ => {}
        }
    }
    listeners
}

fn parse_name(value: &str) -> Option<(String, u16)> {
    let index = value.rfind(':')?;
    let (address, port) = value.split_at(index);
    let port = port.trim_start_matches(':').parse::<u16>().ok()?;
    Some((address.to_string(), port))
}

fn launchctl_rows() -> BTreeMap<String, Value> {
    let Ok(output) = Command::new("/bin/launchctl").arg("list").output() else {
        return BTreeMap::new();
    };
    if !output.status.success() {
        return BTreeMap::new();
    }
    let mut rows = BTreeMap::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let parts = line.split_whitespace().collect::<Vec<_>>();
        if parts.len() < 3 {
            continue;
        }
        let label = parts[2].to_string();
        if !label.contains("harvis")
            && !label.contains("harzva")
            && !label.contains("codex")
            && !label.contains("open-codex")
        {
            continue;
        }
        let pid = parts[0].parse::<u32>().ok();
        rows.insert(
            label.clone(),
            json!({
                "label": label,
                "loaded": true,
                "running": pid.is_some(),
                "pid": pid,
                "plistPresent": launch_agent_exists(&label)
            }),
        );
    }
    rows
}

fn launch_agent_exists(label: &str) -> bool {
    let Some(home) = std::env::var_os("HOME") else {
        return false;
    };
    std::path::PathBuf::from(home)
        .join("Library/LaunchAgents")
        .join(format!("{label}.plist"))
        .is_file()
}

fn process_etime(pid: u32) -> Option<String> {
    let output = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "etime="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!value.is_empty()).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_lsof_field_output() {
        let parsed = parse_lsof("p123\ncnode\nf12\nPTCP\nn127.0.0.1:7788\n");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].pid, 123);
        assert_eq!(parsed[0].command, "node");
        assert_eq!(parsed[0].address, "127.0.0.1");
        assert_eq!(parsed[0].port, 7788);
    }

    #[test]
    fn registers_h5magic_ports_as_visible_on_demand_services() {
        let workbench = KNOWN_PORTS
            .iter()
            .find(|item| item.id == "h5magic-office-workbench")
            .expect("H5Magic Office Workbench should be registered");
        assert_eq!(workbench.port, 8766);
        assert!(workbench.show_in_harvis_bar);
        assert!(!workbench.important);
        assert_eq!(workbench.lifecycle, "on-demand");

        let bridge = KNOWN_PORTS
            .iter()
            .find(|item| item.id == "h5magic-agent-bridge")
            .expect("H5Magic Agent Bridge should be registered");
        assert_eq!(bridge.port, 8776);
        assert!(bridge.show_in_harvis_bar);
        assert!(!bridge.important);
        assert_eq!(bridge.lifecycle, "on-demand");
        assert!(bridge.launch_label.is_none());
    }
}
