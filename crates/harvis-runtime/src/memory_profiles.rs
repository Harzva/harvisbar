//! Public-safe built-in HARVIS memory routing profiles.
//!
//! Profiles contain identifiers and capabilities only. Commands, credentials,
//! access files, and machine paths remain local runtime configuration.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct MemoryProfile {
    pub id: String,
    pub primary: String,
    pub knowledge: Option<String>,
    pub fallback: Option<String>,
    pub routing: BTreeMap<String, String>,
    pub write_policy: String,
    pub production: bool,
    pub experimental: bool,
    pub shadow_providers: Vec<String>,
}

impl MemoryProfile {
    pub fn required_confirmation(&self) -> Option<String> {
        self.production
            .then(|| format!("confirm_memory_profile:{}", self.id))
    }

    pub fn validate_runtime_enabled(&self) -> Result<()> {
        if self.experimental {
            bail!(
                "memory profile {} is benchmark-only and cannot be a production route",
                self.id
            );
        }
        if self.write_policy != "review_required" {
            bail!("memory profile must preserve review_required writes");
        }
        Ok(())
    }
}

pub fn built_in_memory_profiles() -> BTreeMap<String, MemoryProfile> {
    [
        MemoryProfile {
            id: "minimal".to_string(),
            primary: "local-sqlite".to_string(),
            knowledge: None,
            fallback: None,
            routing: BTreeMap::new(),
            write_policy: "review_required".to_string(),
            production: false,
            experimental: false,
            shadow_providers: Vec::new(),
        },
        MemoryProfile {
            id: "local-fast".to_string(),
            primary: "gbrain".to_string(),
            knowledge: Some("llmwiki".to_string()),
            fallback: Some("local-sqlite".to_string()),
            routing: [
                ("preference", "gbrain"),
                ("decision", "gbrain"),
                ("commitment", "gbrain"),
                ("experience", "gbrain"),
            ]
            .into_iter()
            .map(|(kind, provider)| (kind.to_string(), provider.to_string()))
            .collect(),
            write_policy: "review_required".to_string(),
            production: true,
            experimental: false,
            shadow_providers: Vec::new(),
        },
        MemoryProfile {
            id: "learning-lab".to_string(),
            primary: "hindsight".to_string(),
            knowledge: Some("llmwiki".to_string()),
            fallback: Some("local-sqlite".to_string()),
            routing: BTreeMap::new(),
            write_policy: "review_required".to_string(),
            production: false,
            experimental: true,
            shadow_providers: Vec::new(),
        },
        MemoryProfile {
            id: "temporal-lab".to_string(),
            primary: "graphiti".to_string(),
            knowledge: None,
            fallback: Some("local-sqlite".to_string()),
            routing: BTreeMap::new(),
            write_policy: "review_required".to_string(),
            production: false,
            experimental: true,
            shadow_providers: Vec::new(),
        },
        MemoryProfile {
            id: "shadow-benchmark".to_string(),
            primary: "gbrain".to_string(),
            knowledge: Some("llmwiki".to_string()),
            fallback: Some("local-sqlite".to_string()),
            routing: BTreeMap::new(),
            write_policy: "review_required".to_string(),
            production: false,
            experimental: true,
            shadow_providers: vec![
                "hindsight".to_string(),
                "graphiti".to_string(),
                "mem0".to_string(),
            ],
        },
    ]
    .into_iter()
    .map(|profile| (profile.id.clone(), profile))
    .collect()
}

pub fn memory_profile(id: &str) -> Result<MemoryProfile> {
    built_in_memory_profiles()
        .remove(id)
        .ok_or_else(|| anyhow::anyhow!("unknown HARVIS memory profile: {id}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn built_ins_cover_production_fallback_and_three_lab_adapters() {
        let profiles = built_in_memory_profiles();
        assert_eq!(profiles.len(), 5);
        assert_eq!(profiles["minimal"].primary, "local-sqlite");
        assert_eq!(profiles["local-fast"].knowledge.as_deref(), Some("llmwiki"));
        assert_eq!(
            profiles["local-fast"].required_confirmation().as_deref(),
            Some("confirm_memory_profile:local-fast")
        );
        assert!(profiles["learning-lab"].validate_runtime_enabled().is_err());
        assert_eq!(profiles["shadow-benchmark"].shadow_providers.len(), 3);
    }
}
