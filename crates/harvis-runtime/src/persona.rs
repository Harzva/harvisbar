use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use harvis_core::time::now_rfc3339;

pub const PERSONA_REGISTRY_VERSION: &str = "v0.18-alpha";
pub const REVIEW_QUEUE_VERSION: &str = "v0.19-alpha";

const VALID_CANDIDATE_DECISIONS: &[&str] = &[
    "accepted",
    "edited",
    "rejected",
    "reject_forever",
    "deferred",
];
const VALID_RUN_TOOL_PERMISSIONS: &[&str] = &["disabled", "approval_required", "read_only"];

pub fn init_persona_registry(root: &Path) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    registry_dir(&root)?;
    for store in Store::all() {
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(store_path(&root, *store)?)?;
    }
    if list_store(&root, Store::MemoryVault, 1, None)?.is_empty() {
        create_memory_vault(
            &root,
            "Default Memory Vault",
            Some("vault_default_me"),
            "harzva",
        )?;
    }
    if list_store(&root, Store::PersonaCard, 1, None)?.is_empty() {
        create_persona_card_with_tone(
            &root,
            "Core Male Assistant",
            Some("persona_core_male_assistant"),
            "Default Me",
            "core_male_default",
            7,
            7,
            3,
            8,
        )?;
        create_persona_card_with_tone(
            &root,
            "Core Female Assistant",
            Some("persona_core_female_assistant"),
            "Default Me",
            "core_female_default",
            8,
            6,
            3,
            8,
        )?;
    }
    if list_store(&root, Store::TwinInstance, 1, None)?.is_empty() {
        create_twin_instance(
            &root,
            "H.A.R.V.I.S. Default",
            "vault_default_me",
            "persona_core_male_assistant",
            Some("copyme_default_harvis"),
            None,
            None,
        )?;
    }
    list_persona_state(&root, 100)
}

pub fn list_persona_state(root: &Path, limit: usize) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    Ok(json!({
        "persona_registry_version": PERSONA_REGISTRY_VERSION,
        "review_queue_version": REVIEW_QUEUE_VERSION,
        "workspace": {"label": workspace_label(&root)},
        "memory_vaults": list_store(&root, Store::MemoryVault, limit, None)?,
        "persona_cards": list_store(&root, Store::PersonaCard, limit, None)?,
        "twin_instances": list_store(&root, Store::TwinInstance, limit, None)?,
        "personality_candidates": list_store(&root, Store::PersonalityCandidate, limit, None)?,
        "pending_personality_review": list_store(&root, Store::PersonalityCandidate, limit, Some("pending_review"))?
    }))
}

pub fn create_memory_vault(
    root: &Path,
    display_name: &str,
    vault_id: Option<&str>,
    owner: &str,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let vault_id = vault_id
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| stable_id("vault", display_name));
    append_record(
        &root,
        Store::MemoryVault,
        json!({
            "vault_id": vault_id,
            "display_name": display_name,
            "owner": owner,
            "status": "active",
            "visibility": "private",
            "sources": ["project", "conversation", "manual_input", "local_engineering"],
            "memory_items": 0,
            "last_synced_at": null
        }),
    )
}

pub fn create_persona_card(
    root: &Path,
    display_name: &str,
    persona_id: Option<&str>,
    visual_asset_id: &str,
) -> Result<Value> {
    create_persona_card_with_tone(
        root,
        display_name,
        persona_id,
        "Default Me",
        if visual_asset_id.is_empty() {
            persona_id.unwrap_or("")
        } else {
            visual_asset_id
        },
        7,
        7,
        3,
        8,
    )
}

pub fn update_persona_card(
    root: &Path,
    persona_id: &str,
    display_name: Option<&str>,
    visual_asset_id: Option<&str>,
    base_template: Option<&str>,
    status: Option<&str>,
    tone: Option<&Value>,
    decision_style: Option<&Value>,
    behavior_rules: Option<&Value>,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let current = find_by_id(&root, Store::PersonaCard, "persona_id", persona_id)?;
    let mut updated = current.as_object().cloned().unwrap_or_default();
    if let Some(value) = display_name
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        updated.insert("display_name".to_string(), json!(value));
    }
    if let Some(value) = visual_asset_id {
        updated.insert("visual_asset_id".to_string(), json!(value.trim()));
    }
    if let Some(value) = base_template
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        updated.insert("base_template".to_string(), json!(value));
    }
    if let Some(value) = status.map(str::trim).filter(|value| !value.is_empty()) {
        let value = value.to_ascii_lowercase();
        if !["active", "draft", "archived", "disabled"].contains(&value.as_str()) {
            bail!("status must be one of: active, draft, archived, disabled");
        }
        updated.insert("status".to_string(), json!(value));
    }
    if let Some(tone) = tone.and_then(Value::as_object) {
        let mut merged = updated
            .get("tone")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        for key in [
            "warmth",
            "directness",
            "humor",
            "detail",
            "encouragement",
            "criticism",
        ] {
            if let Some(value) = tone.get(key) {
                merged.insert(key.to_string(), json!(clamp_tone(value, 7)));
            }
        }
        updated.insert("tone".to_string(), Value::Object(merged));
    }
    if let Some(style) = decision_style.and_then(Value::as_object) {
        let mut merged = updated
            .get("decision_style")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        for (key, value) in style {
            if !key.trim().is_empty()
                && (value.is_boolean() || value.is_number() || value.is_string() || value.is_null())
            {
                merged.insert(key.trim().to_string(), value.clone());
            }
        }
        updated.insert("decision_style".to_string(), Value::Object(merged));
    }
    if let Some(items) = behavior_rules.and_then(Value::as_array) {
        let rules = items
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .take(12)
            .collect::<Vec<_>>();
        updated.insert("behavior_rules".to_string(), json!(rules));
    }
    updated.insert("new_traits_require_human_review".to_string(), json!(true));
    append_record(&root, Store::PersonaCard, Value::Object(updated))
}

pub fn create_twin_instance(
    root: &Path,
    display_name: &str,
    memory_vault_id: &str,
    persona_card_id: &str,
    instance_id: Option<&str>,
    overlay_memory_id: Option<&str>,
    permissions: Option<&Value>,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let instance_id = instance_id
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| stable_id("copyme", display_name));
    append_record(
        &root,
        Store::TwinInstance,
        json!({
            "instance_id": instance_id,
            "display_name": display_name,
            "memory_vault_id": memory_vault_id,
            "persona_card_id": persona_card_id,
            "overlay_memory_id": overlay_memory_id,
            "status": "running",
            "permissions": normalize_twin_permissions(permissions)
        }),
    )
}

pub fn create_personality_candidate(
    root: &Path,
    trait_text: &str,
    target_persona_id: &str,
    source_type: &str,
    source_refs: Vec<String>,
    trait_type: &str,
    confidence: f64,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    if trait_text.trim().is_empty() {
        bail!("trait is required");
    }
    append_record(
        &root,
        Store::PersonalityCandidate,
        json!({
            "review_queue_version": REVIEW_QUEUE_VERSION,
            "candidate_id": event_id("pc", &[target_persona_id, trait_text])?,
            "target_persona_id": target_persona_id,
            "source_type": source_type,
            "source_refs": source_refs,
            "trait": trait_text.trim(),
            "trait_type": trait_type,
            "confidence": confidence.clamp(0.0, 1.0),
            "stability": "observed_once",
            "risk": "low",
            "suggested_action": "review",
            "status": "pending_review"
        }),
    )
}

pub fn decide_personality_candidate(
    root: &Path,
    candidate_id: &str,
    decision: &str,
    decided_by: &str,
    notes: &str,
    edited_trait: &str,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let decision = decision.trim().to_ascii_lowercase();
    if !VALID_CANDIDATE_DECISIONS.contains(&decision.as_str()) {
        bail!(
            "decision must be one of: {}",
            VALID_CANDIDATE_DECISIONS.join(", ")
        );
    }
    let candidate = find_by_id(
        &root,
        Store::PersonalityCandidate,
        "candidate_id",
        candidate_id,
    )?;
    let status = if decision == "deferred" {
        "pending_review"
    } else {
        decision.as_str()
    };
    let mut updated = candidate.as_object().cloned().unwrap_or_default();
    updated.insert("status".to_string(), json!(status));
    if !edited_trait.trim().is_empty() {
        updated.insert("trait".to_string(), json!(edited_trait.trim()));
        updated.insert("edited".to_string(), json!(true));
    }
    let candidate = append_record(&root, Store::PersonalityCandidate, Value::Object(updated))?;
    let decision_record = append_record(
        &root,
        Store::ReviewDecision,
        json!({
            "review_queue_version": REVIEW_QUEUE_VERSION,
            "decision_id": event_id("pdec", &[candidate_id, &decision])?,
            "candidate_id": candidate_id,
            "decision": decision,
            "decided_by": decided_by,
            "notes": notes.trim(),
            "status_after": status
        }),
    )?;
    Ok(json!({"candidate": candidate, "decision": decision_record}))
}

fn create_persona_card_with_tone(
    root: &Path,
    display_name: &str,
    persona_id: Option<&str>,
    base_template: &str,
    visual_asset_id: &str,
    warmth: i64,
    directness: i64,
    humor: i64,
    detail: i64,
) -> Result<Value> {
    let root = resolve_workspace_root(root)?;
    let persona_id = persona_id
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| stable_id("persona", display_name));
    append_record(
        &root,
        Store::PersonaCard,
        json!({
            "persona_id": persona_id,
            "display_name": display_name,
            "base_template": base_template,
            "visual_asset_id": if visual_asset_id.is_empty() { persona_id.as_str() } else { visual_asset_id },
            "status": "active",
            "tone": {
                "warmth": warmth.clamp(0, 10),
                "directness": directness.clamp(0, 10),
                "humor": humor.clamp(0, 10),
                "detail": detail.clamp(0, 10)
            },
            "decision_style": {
                "evidence_first": true,
                "risk_tolerance": "medium",
                "challenge_user": true,
                "prefer_verification": true
            },
            "behavior_rules": [
                "Inspect context before acting.",
                "Mark uncertainty when evidence is incomplete.",
                "Prefer executable next steps over broad narration."
            ],
            "new_traits_require_human_review": true
        }),
    )
}

fn append_record(root: &Path, store: Store, record: Value) -> Result<Value> {
    let mut object = record.as_object().cloned().unwrap_or_default();
    object
        .entry("registry_version".to_string())
        .or_insert_with(|| json!(PERSONA_REGISTRY_VERSION));
    object
        .entry("created_at".to_string())
        .or_insert_with(|| json!(now_rfc3339().unwrap_or_default()));
    object.insert("updated_at".to_string(), json!(now_rfc3339()?));
    let record = Value::Object(object);
    append_jsonl(&store_path(root, store)?, &record)?;
    Ok(record)
}

fn list_store(root: &Path, store: Store, limit: usize, status: Option<&str>) -> Result<Vec<Value>> {
    let rows = read_jsonl(&store_path(root, store)?)?;
    let mut latest: BTreeMap<String, Value> = BTreeMap::new();
    for row in rows {
        if let Some(id) = row.get(store.key()).and_then(Value::as_str) {
            latest.insert(id.to_string(), row);
        }
    }
    let mut values = latest
        .into_values()
        .filter(|row| {
            status.is_none_or(|status| row.get("status").and_then(Value::as_str) == Some(status))
        })
        .collect::<Vec<_>>();
    values.sort_by(|left, right| {
        row_time(right)
            .cmp(&row_time(left))
            .then_with(|| row_id(left, store).cmp(&row_id(right, store)))
    });
    values.truncate(limit);
    Ok(values)
}

fn find_by_id(root: &Path, store: Store, key: &str, id: &str) -> Result<Value> {
    list_store(root, store, 1000, None)?
        .into_iter()
        .find(|row| row.get(key).and_then(Value::as_str) == Some(id))
        .with_context(|| format!("{key} not found: {id}"))
}

fn normalize_twin_permissions(value: Option<&Value>) -> Value {
    let mut permissions = json!({
        "read_memory": true,
        "write_candidate_memory": true,
        "write_accepted_memory": false,
        "run_tools": "approval_required"
    });
    let Some(object) = value.and_then(Value::as_object) else {
        return permissions;
    };
    for key in [
        "read_memory",
        "write_candidate_memory",
        "write_accepted_memory",
    ] {
        if let Some(value) = object.get(key).and_then(Value::as_bool) {
            permissions[key] = json!(value);
        }
    }
    if let Some(run_tools) = object.get("run_tools").and_then(Value::as_str) {
        if VALID_RUN_TOOL_PERMISSIONS.contains(&run_tools) {
            permissions["run_tools"] = json!(run_tools);
        }
    }
    permissions
}

fn clamp_tone(value: &Value, fallback: i64) -> i64 {
    if let Some(value) = value.as_i64() {
        value.clamp(0, 10)
    } else if let Some(value) = value.as_str() {
        value
            .parse::<i64>()
            .map(|value| value.clamp(0, 10))
            .unwrap_or(fallback)
    } else {
        fallback
    }
}

fn stable_id(prefix: &str, value: &str) -> String {
    let clean = sanitize_id(value, prefix, 42);
    let digest = Sha256::digest(value.as_bytes())
        .iter()
        .take(4)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("{prefix}_{clean}_{digest}")
}

fn event_id(prefix: &str, parts: &[&str]) -> Result<String> {
    let timestamp = timestamp_slug(&now_rfc3339()?);
    let digest = Sha256::digest(parts.join("|").as_bytes())
        .iter()
        .take(5)
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(format!("{prefix}_{timestamp}_{digest}"))
}

fn sanitize_id(value: &str, fallback: &str, max_chars: usize) -> String {
    let clean = value
        .chars()
        .map(|character| {
            if character.is_alphanumeric() {
                character.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .split('-')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("-")
        .chars()
        .take(max_chars)
        .collect::<String>();
    if clean.is_empty() {
        fallback.to_string()
    } else {
        clean
    }
}

fn append_jsonl(path: &Path, item: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all((serde_json::to_string(item)? + "\n").as_bytes())?;
    Ok(())
}

fn read_jsonl(path: &Path) -> Result<Vec<Value>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    Ok(fs::read_to_string(path)?
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .collect())
}

fn row_time(row: &Value) -> String {
    row.get("updated_at")
        .or_else(|| row.get("created_at"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn row_id(row: &Value, store: Store) -> String {
    row.get(store.key())
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn registry_dir(root: &Path) -> Result<PathBuf> {
    let path = root.join(".harvis/persona");
    fs::create_dir_all(&path)?;
    Ok(path)
}

fn store_path(root: &Path, store: Store) -> Result<PathBuf> {
    Ok(registry_dir(root)?.join(store.filename()))
}

fn timestamp_slug(moment: &str) -> String {
    let digits = moment
        .chars()
        .filter(|character| character.is_ascii_digit())
        .take(14)
        .collect::<String>();
    let (date, time) = digits.split_at(8);
    format!("{date}T{time}Z")
}

fn resolve_workspace_root(value: &Path) -> Result<PathBuf> {
    let root = expanduser(value).canonicalize().with_context(|| {
        format!(
            "workspace root must be an existing directory: {}",
            value.display()
        )
    })?;
    if !root.is_dir() {
        bail!(
            "workspace root must be an existing directory: {}",
            root.display()
        );
    }
    Ok(root)
}

fn expanduser(path: &Path) -> PathBuf {
    let Some(value) = path.to_str() else {
        return path.to_path_buf();
    };
    if value == "~" {
        return std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| path.to_path_buf());
    }
    if let Some(rest) = value.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    path.to_path_buf()
}

fn workspace_label(root: &Path) -> String {
    root.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("workspace")
        .to_string()
}

#[derive(Debug, Clone, Copy)]
enum Store {
    MemoryVault,
    PersonaCard,
    TwinInstance,
    PersonalityCandidate,
    ReviewDecision,
}

impl Store {
    fn all() -> &'static [Store] {
        &[
            Store::MemoryVault,
            Store::PersonaCard,
            Store::TwinInstance,
            Store::PersonalityCandidate,
            Store::ReviewDecision,
        ]
    }

    fn filename(self) -> &'static str {
        match self {
            Store::MemoryVault => "memory-vaults.jsonl",
            Store::PersonaCard => "persona-cards.jsonl",
            Store::TwinInstance => "twin-instances.jsonl",
            Store::PersonalityCandidate => "personality-candidates.jsonl",
            Store::ReviewDecision => "review-decisions.jsonl",
        }
    }

    fn key(self) -> &'static str {
        match self {
            Store::MemoryVault => "vault_id",
            Store::PersonaCard => "persona_id",
            Store::TwinInstance => "instance_id",
            Store::PersonalityCandidate => "candidate_id",
            Store::ReviewDecision => "decision_id",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::init::init_workspace;

    #[test]
    fn initializes_and_updates_persona_registry() {
        let root =
            std::env::temp_dir().join(format!("harvis-persona-rust-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        init_workspace(&root, false).expect("init");
        let state = init_persona_registry(&root).expect("persona init");
        assert!(state["memory_vaults"].as_array().unwrap().len() >= 1);
        assert!(state["persona_cards"].as_array().unwrap().len() >= 2);
        let persona = create_persona_card(&root, "Specialist", None, "harvis-persona-system")
            .expect("persona");
        let persona_id = persona["persona_id"].as_str().unwrap();
        let mut tone = serde_json::Map::new();
        tone.insert("warmth".to_string(), json!(9));
        let updated = update_persona_card(
            &root,
            persona_id,
            Some("Specialist Updated"),
            None,
            None,
            None,
            Some(&Value::Object(tone)),
            None,
            None,
        )
        .expect("update");
        assert_eq!(updated["tone"]["warmth"], 9);
        let candidate = create_personality_candidate(
            &root,
            "Prefers concise next actions.",
            persona_id,
            "test",
            Vec::new(),
            "behavior_rule",
            0.7,
        )
        .expect("candidate");
        let decided = decide_personality_candidate(
            &root,
            candidate["candidate_id"].as_str().unwrap(),
            "accepted",
            "human",
            "ok",
            "",
        )
        .expect("decide");
        assert_eq!(decided["candidate"]["status"], "accepted");
        let _ = fs::remove_dir_all(root);
    }
}
