//! Small synchronous MCP stdio client used by provider adapters.
//!
//! The client deliberately exposes only tool discovery and tool calls. It does
//! not forward prompts, resources, or roots, which keeps third-party adapters
//! on the narrow capability surface HARVIS selected for them.

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

pub trait McpToolTransport: Send + Sync {
    fn list_tools(&self) -> Result<Vec<String>>;
    fn call_tool(&self, name: &str, arguments: &Value) -> Result<Value>;
}

pub struct McpStdioTransport {
    session: Mutex<McpStdioSession>,
}

impl McpStdioTransport {
    pub fn spawn(command: &str, args: &[String], env: &BTreeMap<String, String>) -> Result<Self> {
        if command.trim().is_empty() {
            bail!("MCP command is required");
        }
        let mut process = Command::new(command);
        process
            .args(args)
            .envs(env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        let mut child = process
            .spawn()
            .with_context(|| format!("spawn MCP server command: {command}"))?;
        let stdin = child.stdin.take().context("MCP server has no stdin")?;
        let stdout = child.stdout.take().context("MCP server has no stdout")?;
        let mut session = McpStdioSession {
            child,
            stdin: BufWriter::new(stdin),
            stdout: BufReader::new(stdout),
            next_id: 1,
        };
        session.initialize()?;
        Ok(Self {
            session: Mutex::new(session),
        })
    }
}

impl McpToolTransport for McpStdioTransport {
    fn list_tools(&self) -> Result<Vec<String>> {
        self.session
            .lock()
            .map_err(|_| anyhow::anyhow!("MCP session lock poisoned"))?
            .list_tools()
    }

    fn call_tool(&self, name: &str, arguments: &Value) -> Result<Value> {
        self.session
            .lock()
            .map_err(|_| anyhow::anyhow!("MCP session lock poisoned"))?
            .call_tool(name, arguments)
    }
}

struct McpStdioSession {
    child: Child,
    stdin: BufWriter<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
}

impl McpStdioSession {
    fn initialize(&mut self) -> Result<()> {
        self.request(
            "initialize",
            json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "harvis-memory", "version": env!("CARGO_PKG_VERSION")}
            }),
        )?;
        self.notify("notifications/initialized", json!({}))
    }

    fn list_tools(&mut self) -> Result<Vec<String>> {
        let result = self.request("tools/list", json!({}))?;
        let tools = result
            .get("tools")
            .and_then(Value::as_array)
            .context("MCP tools/list response is missing tools[]")?;
        tools
            .iter()
            .map(|tool| {
                tool.get("name")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .context("MCP tool is missing name")
            })
            .collect()
    }

    fn call_tool(&mut self, name: &str, arguments: &Value) -> Result<Value> {
        if !arguments.is_object() {
            bail!("MCP tool arguments must be a JSON object");
        }
        let result = self.request("tools/call", json!({"name": name, "arguments": arguments}))?;
        if result.get("isError").and_then(Value::as_bool) == Some(true) {
            bail!(
                "MCP tool {name} failed: {}",
                tool_text(&result).unwrap_or_default()
            );
        }
        if let Some(structured) = result.get("structuredContent") {
            return Ok(structured.clone());
        }
        let text = tool_text(&result).context("MCP tool response has no JSON content")?;
        serde_json::from_str(&text)
            .with_context(|| format!("MCP tool {name} returned non-JSON text"))
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        self.write(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        }))?;
        loop {
            let message = self.read_message()?;
            if message.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if let Some(error) = message.get("error") {
                bail!("MCP {method} failed: {error}");
            }
            return message
                .get("result")
                .cloned()
                .context("MCP response is missing result");
        }
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<()> {
        self.write(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
    }

    fn write(&mut self, message: &Value) -> Result<()> {
        serde_json::to_writer(&mut self.stdin, message)?;
        self.stdin.write_all(b"\n")?;
        self.stdin.flush()?;
        Ok(())
    }

    fn read_message(&mut self) -> Result<Value> {
        let mut line = String::new();
        let bytes = self.stdout.read_line(&mut line)?;
        if bytes == 0 {
            let status = self.child.try_wait()?;
            bail!("MCP server closed stdout (status: {status:?})");
        }
        serde_json::from_str(&line).context("MCP server wrote non-JSON data to stdout")
    }
}

impl Drop for McpStdioSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn tool_text(result: &Value) -> Option<String> {
    result
        .get("content")?
        .as_array()?
        .iter()
        .find(|item| item.get("type").and_then(Value::as_str) == Some("text"))?
        .get("text")?
        .as_str()
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_first_text_content() {
        let result = json!({"content": [{"type": "text", "text": "{\"ok\":true}"}]});
        assert_eq!(tool_text(&result).as_deref(), Some("{\"ok\":true}"));
    }
}
