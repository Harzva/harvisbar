use harvis_core::group_control::{self, ControlError};
use serde_json::{json, Value};
fn operation(name: &str) -> Option<&'static str> {
    match name { "harvis_group_list"=>Some("list"), "harvis_group_status"=>Some("status"), "harvis_group_send"=>Some("send"), "harvis_group_results"=>Some("results"), "harvis_group_cancel"=>Some("cancel"), "harvis_group_recover"=>Some("recover"), _=>None }
}
pub fn is_group_tool(name: &str) -> bool { operation(name).is_some() }
pub fn tool(name: &str) -> Option<Value> {
    let op = operation(name)?;
    let mut properties = serde_json::Map::new();
    let mut required = vec![];
    if op != "list" { properties.insert("groupID".into(),json!({"type":"string","format":"uuid"})); required.push("groupID"); }
    match op {
        "send"=> {
            properties.insert("text".into(),json!({"type":"string","minLength":1}));
            properties.insert("requestID".into(),json!({"type":"string","minLength":1,"maxLength":128,"description":"Caller-generated stable idempotency key. Reuse the same key and exact payload after a timeout."}));
            properties.insert("mode".into(),json!({"type":"string","enum":["coordinated","direct","recordOnly"],"default":"coordinated"}));
            properties.insert("memberIDs".into(),json!({"type":"array","items":{"type":"string","format":"uuid"},"maxItems":64}));
            required.extend(["text","requestID"]);
        }
        "results"=> { properties.insert("afterSequence".into(),json!({"type":"integer","minimum":0})); properties.insert("limit".into(),json!({"type":"integer","minimum":1,"maximum":100})); }
        "cancel"=> { properties.insert("runID".into(),json!({"type":"string","format":"uuid"})); properties.insert("memberID".into(),json!({"type":"string","format":"uuid","description":"Stops all pending/current work of this member, not a single dispatch."})); }
        _=>{}
    }
    Some(json!({"name":name,"description":format!("HarvisBar native group {op}. Requires the local app running and background access enabled for this group. Uses persistent Codex app-server threads. Never changes account, project grants or human approvals. Send returns a durable receipt; poll status/results for completion."),
        "inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},
        "annotations":{"readOnlyHint":matches!(op,"list"|"status"|"results"),"destructiveHint":op=="cancel","idempotentHint":true,"openWorldHint":op=="send"},
        "_meta":{"harvis/externalAvailability":"local-running-app-and-background-enabled-group","harvis/mutating":!matches!(op,"list"|"status"|"results")}}))
}
pub fn call(name: &str, args: &Value) -> Result<Value, ControlError> {
    let method = format!("groups.{}", operation(name).unwrap_or("unknown"));
    group_control::call(&method, args.clone())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn group_tools_declare_execution_and_external_availability() {
        let send=tool("harvis_group_send").unwrap();
        assert_eq!(send["inputSchema"]["additionalProperties"],false);
        assert_eq!(send["annotations"]["readOnlyHint"],false);
        assert_eq!(send["_meta"]["harvis/mutating"],true);
        assert_eq!(tool("harvis_group_results").unwrap()["annotations"]["readOnlyHint"],true);
        assert!(tool("harvis_agent_room_send").is_none());
    }
}
