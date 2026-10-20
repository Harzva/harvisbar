//! Explicit, read-only provider billing queries for one exact Codex Home.
//!
//! Discovery does not call this module. Credentials are used only by the
//! supported adapter and are never part of its serialized projection.

use crate::codex_homes::{
    bounded_decimal, is_safe_connection_id, stable_id, CodexConfiguredAllowance,
};
use anyhow::{anyhow, Result};
use reqwest::blocking::Client;
use reqwest::header::{HeaderValue, AUTHORIZATION};
use reqwest::redirect::Policy;
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeSet;
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_METADATA_BYTES: u64 = 64 * 1024;
const MAX_RESPONSE_BYTES: u64 = 256 * 1024;
const MAX_CREDENTIAL_BYTES: u64 = 4096;
const MAX_CONNECTIONS: usize = 64;
const QUERY_BUDGET: Duration = Duration::from_secs(10);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const DEEPSEEK_BALANCE_URL: &str = "https://api.deepseek.com/user/balance";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexHomeBillingResult {
    pub ok: bool,
    pub schema_version: &'static str,
    pub home_id: String,
    pub connections: Vec<CodexConnectionBilling>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexConnectionBilling {
    pub id: String,
    /// Whether supported balance details were retrieved, not whether the
    /// account has sufficient funds to make an inference request.
    pub available: bool,
    pub status: &'static str,
    pub service_available: Option<bool>,
    pub balances: Vec<CodexProviderBalance>,
    pub allowances: Vec<CodexConfiguredAllowance>,
    pub updated_at: i64,
    pub error: Option<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexProviderBalance {
    pub currency: String,
    pub amount: String,
    pub updated_at: i64,
    pub source: &'static str,
}

#[derive(Debug)]
struct DeepSeekBalance {
    service_available: Option<bool>,
    balances: Vec<CodexProviderBalance>,
}

/// Query only adapters explicitly configured in this Home's account metadata.
/// The account metadata is intentionally not returned by this operation.
pub fn read_codex_home_billing(home: &Path) -> Result<CodexHomeBillingResult> {
    read_billing_with_query(home, |credential_file, timeout, updated_at| {
        let credential = read_credential(credential_file)?;
        let mut authorization = HeaderValue::from_str(&format!("Bearer {credential}"))
            .map_err(|_| "The balance-query credential is invalid.")?;
        authorization.set_sensitive(true);
        let client = Client::builder()
            .redirect(Policy::none())
            .no_proxy()
            .connect_timeout(timeout.min(Duration::from_secs(2)))
            .timeout(timeout)
            .build()
            .map_err(|_| "The provider balance query could not be initialized.")?;
        let response = client
            .get(DEEPSEEK_BALANCE_URL)
            .header(AUTHORIZATION, authorization)
            .send()
            .map_err(|_| "The provider balance query could not be completed.")?;
        if !response.status().is_success() {
            return Err(match response.status().as_u16() {
                401 | 403 => "The provider did not authorize this balance query.",
                429 => "The provider balance query is temporarily rate limited.",
                _ => "The provider balance service is temporarily unavailable.",
            });
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_RESPONSE_BYTES)
        {
            return Err("The provider returned an oversized balance response.");
        }
        let mut bytes = Vec::new();
        response
            .take(MAX_RESPONSE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "The provider balance response could not be read.")?;
        if bytes.len() as u64 > MAX_RESPONSE_BYTES {
            return Err("The provider returned an oversized balance response.");
        }
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|_| "The provider returned an invalid balance response.")?;
        project_deepseek_balance(&value, updated_at)
    })
}

fn read_billing_with_query<F>(home: &Path, mut query: F) -> Result<CodexHomeBillingResult>
where
    F: FnMut(&Path, Duration, i64) -> std::result::Result<DeepSeekBalance, &'static str>,
{
    let deadline = Instant::now() + QUERY_BUDGET;
    read_billing_before_deadline(home, &mut query, deadline)
}

fn read_billing_before_deadline<F>(
    home: &Path,
    mut query: F,
    deadline: Instant,
) -> Result<CodexHomeBillingResult>
where
    F: FnMut(&Path, Duration, i64) -> std::result::Result<DeepSeekBalance, &'static str>,
{
    let home = home
        .canonicalize()
        .map_err(|_| anyhow!("The requested CODEX_HOME is unavailable."))?;
    if !home.is_dir() {
        return Err(anyhow!("The requested CODEX_HOME is not a directory."));
    }
    let path = home.join(".harvis-account.json");
    match path.metadata() {
        Ok(metadata) if !metadata.is_file() => {
            return Err(anyhow!("Account billing metadata is not a regular file."));
        }
        Ok(metadata) if metadata.len() > MAX_METADATA_BYTES => {
            return Err(anyhow!("Account billing metadata is too large."));
        }
        _ => {}
    }
    let metadata = match File::open(&path) {
        Ok(file) => {
            if !file
                .metadata()
                .map_err(|_| anyhow!("Account billing metadata could not be read."))?
                .is_file()
            {
                return Err(anyhow!("Account billing metadata is not a regular file."));
            }
            let mut bytes = Vec::new();
            file.take(MAX_METADATA_BYTES + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| anyhow!("Account billing metadata could not be read."))?;
            if bytes.len() as u64 > MAX_METADATA_BYTES {
                return Err(anyhow!("Account billing metadata is too large."));
            }
            serde_json::from_slice::<Value>(&bytes)
                .map_err(|_| anyhow!("Account billing metadata is not valid JSON."))?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Value::Null,
        Err(_) => return Err(anyhow!("Account billing metadata could not be read.")),
    };
    if metadata
        .get("schemaVersion")
        .is_some_and(|value| value.as_str() != Some("harvis.codex-account.v1"))
    {
        return Err(anyhow!(
            "The account billing metadata version is not supported."
        ));
    }
    let mut seen = BTreeSet::new();
    let mut connections = Vec::new();
    for entry in metadata
        .get("connections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(MAX_CONNECTIONS)
    {
        let Some(id) = entry
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| is_safe_connection_id(id))
        else {
            continue;
        };
        if !seen.insert(id.to_owned()) {
            continue;
        }
        let updated_at = now_seconds();
        let mut result = empty_connection(id, updated_at);
        match entry.pointer("/usage/kind").and_then(Value::as_str) {
            Some("deepseek-balance") => {
                let credential_file = entry
                    .pointer("/usage/credentialFile")
                    .and_then(Value::as_str)
                    .map(Path::new)
                    .filter(|path| path.is_absolute());
                if let Some(credential_file) = credential_file {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        result.status = "unavailable";
                        result.error =
                            Some("The billing refresh deadline was reached. Refresh again later.");
                    } else {
                        match query(credential_file, remaining.min(REQUEST_TIMEOUT), updated_at) {
                            Ok(balance) => {
                                result.available = true;
                                result.status = "available";
                                result.service_available = balance.service_available;
                                result.balances = balance.balances;
                            }
                            Err(error) => {
                                result.status = "unavailable";
                                result.error = Some(error);
                            }
                        }
                    }
                } else {
                    result.error = Some("A balance-query credential file has not been configured.");
                }
            }
            Some("aliyun-token-plan") => {
                result.status = "requires-authorization";
                result.error = Some("Token Plan usage requires separate Alibaba Cloud read-only authorization; a model API key cannot query it.");
            }
            Some(_) => {
                result.error = Some("This service does not have a supported billing adapter.");
            }
            None => {}
        }
        connections.push(result);
    }
    Ok(CodexHomeBillingResult {
        ok: true,
        schema_version: "harvis.codex-home-billing.v1",
        home_id: stable_id(&home),
        connections,
    })
}

fn empty_connection(id: &str, updated_at: i64) -> CodexConnectionBilling {
    CodexConnectionBilling {
        id: id.to_owned(),
        available: false,
        status: "not-configured",
        service_available: None,
        balances: Vec::new(),
        allowances: Vec::new(),
        updated_at,
        error: None,
    }
}

fn read_credential(path: &Path) -> std::result::Result<String, &'static str> {
    let metadata = path
        .metadata()
        .map_err(|_| "The balance-query credential is unavailable.")?;
    if !metadata.is_file() || metadata.len() > MAX_CREDENTIAL_BYTES {
        return Err("The balance-query credential must be a bounded regular file.");
    }
    let file = File::open(path).map_err(|_| "The balance-query credential is unavailable.")?;
    if !file
        .metadata()
        .map_err(|_| "The balance-query credential is unavailable.")?
        .is_file()
    {
        return Err("The balance-query credential must be a regular file.");
    }
    let mut bytes = Vec::new();
    file.take(MAX_CREDENTIAL_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "The balance-query credential could not be read.")?;
    if bytes.len() as u64 > MAX_CREDENTIAL_BYTES {
        return Err("The balance-query credential is invalid.");
    }
    let key = std::str::from_utf8(&bytes)
        .map_err(|_| "The balance-query credential is invalid.")?
        .trim();
    if key.len() < 12 || !key.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err("The balance-query credential is invalid.");
    }
    Ok(key.to_owned())
}

fn project_deepseek_balance(
    value: &Value,
    updated_at: i64,
) -> std::result::Result<DeepSeekBalance, &'static str> {
    let entries = value
        .get("balance_infos")
        .and_then(Value::as_array)
        .ok_or("The provider did not return supported balance details.")?;
    let mut currencies = BTreeSet::new();
    let balances: Vec<_> = entries
        .iter()
        .take(16)
        .filter_map(|entry| {
            let currency = entry.get("currency")?.as_str()?;
            if !matches!(currency, "CNY" | "USD") || currencies.contains(currency) {
                return None;
            }
            let amount = bounded_decimal(entry.get("total_balance")?.as_str()?)?;
            currencies.insert(currency.to_owned());
            Some(CodexProviderBalance {
                currency: currency.to_owned(),
                amount,
                updated_at,
                source: "provider",
            })
        })
        .collect();
    if balances.is_empty() {
        return Err("The provider did not return supported balance details.");
    }
    Ok(DeepSeekBalance {
        service_available: value.get("is_available").and_then(Value::as_bool),
        balances,
    })
}

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_HOME: AtomicU64 = AtomicU64::new(0);

    struct TestHome(PathBuf);

    impl TestHome {
        fn new(metadata: Value) -> Self {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let serial = NEXT_HOME.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "harvis-billing-{}-{unique}-{serial}",
                std::process::id()
            ));
            fs::create_dir(&path).unwrap();
            fs::write(
                path.join(".harvis-account.json"),
                serde_json::to_vec(&metadata).unwrap(),
            )
            .unwrap();
            Self(path)
        }
    }

    impl Drop for TestHome {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn projects_decimal_balances_without_conflating_insufficient_funds_with_auth() {
        let response = json!({
            "is_available": false,
            "balance_infos": [
                {"currency":"CNY", "total_balance":"-0.00120", "granted_balance":"999.0", "topped_up_balance":"0"},
                {"currency":"USD", "total_balance":"0.00"}
            ],
            "credential": "MUST_NOT_BE_PROJECTED"
        });
        let result = project_deepseek_balance(&response, 123).unwrap();
        assert_eq!(result.service_available, Some(false));
        assert_eq!(result.balances[0].amount, "-0.00120");
        assert_eq!(result.balances[1].amount, "0.00");
        let encoded = serde_json::to_string(&result.balances).unwrap();
        assert!(!encoded.contains("MUST_NOT_BE_PROJECTED"));
        assert!(!encoded.contains("granted_balance"));
        assert!(encoded.contains("\"source\":\"provider\""));
    }

    #[test]
    fn malformed_missing_and_unsupported_balances_remain_unknown() {
        for response in [
            json!({}),
            json!({"balance_infos":[]}),
            json!({"balance_infos":[{"currency":"EUR","total_balance":"8"}]}),
        ] {
            assert!(project_deepseek_balance(&response, 123).is_err());
        }
        for amount in [
            json!(0),
            json!(null),
            json!(""),
            json!("NaN"),
            json!("1e2"),
            json!("Bearer private-value"),
            json!(" 1.0"),
            json!("1\n"),
        ] {
            assert!(project_deepseek_balance(
                &json!({"balance_infos":[{"currency":"CNY","total_balance":amount}]}),
                123
            )
            .is_err());
        }
    }

    #[test]
    fn home_projection_uses_only_each_explicit_adapter_and_never_returns_credential_paths() {
        let home = TestHome::new(json!({"connections":[
            {"id":"deepseek", "usage":{"kind":"deepseek-balance","credentialFile":"/private/fixture-credential"}},
            {"id":"qwen-token-plan", "usage":{"kind":"aliyun-token-plan","credentialFile":"/private/never-read"}},
            {"id":"other"},
            {"id":"deepseek", "usage":{"kind":"deepseek-balance","credentialFile":"/private/duplicate"}},
            {"id":"https://invalid.invalid/private"}
        ]}));
        let mut calls = 0;
        let result = read_billing_with_query(&home.0, |path, timeout, updated_at| {
            calls += 1;
            assert_eq!(path, Path::new("/private/fixture-credential"));
            assert!(timeout <= REQUEST_TIMEOUT);
            project_deepseek_balance(
                &json!({"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0"}]}),
                updated_at,
            )
        })
        .unwrap();
        assert_eq!(calls, 1);
        assert_eq!(result.home_id, stable_id(&home.0.canonicalize().unwrap()));
        assert_eq!(result.connections.len(), 3);
        assert!(result.connections[0].available);
        assert_eq!(result.connections[0].service_available, Some(false));
        assert_eq!(result.connections[1].status, "requires-authorization");
        assert_eq!(result.connections[2].status, "not-configured");
        let encoded = serde_json::to_string(&result).unwrap();
        for private in [
            "credentialFile",
            "fixture-credential",
            "never-read",
            "duplicate",
            "invalid.invalid",
        ] {
            assert!(!encoded.contains(private));
        }
    }

    #[test]
    fn missing_credentials_are_isolated_without_another_connection_fallback() {
        let home = TestHome::new(json!({"connections":[
            {"id":"missing", "usage":{"kind":"deepseek-balance","credentialFile":"relative-key"}},
            {"id":"failed", "usage":{"kind":"deepseek-balance","credentialFile":"/private/missing"}},
            {"id":"qwen", "usage":{"kind":"aliyun-token-plan"}}
        ]}));
        let mut calls = 0;
        let result = read_billing_with_query(&home.0, |_, _, _| {
            calls += 1;
            Err("The balance-query credential is unavailable.")
        })
        .unwrap();
        assert_eq!(calls, 1);
        assert_eq!(result.connections[0].status, "not-configured");
        assert_eq!(result.connections[1].status, "unavailable");
        assert_eq!(result.connections[2].status, "requires-authorization");
        assert!(result
            .connections
            .iter()
            .all(|item| !item.available && item.balances.is_empty()));
    }

    #[test]
    fn oversized_metadata_and_credentials_fail_with_safe_messages() {
        let home = TestHome::new(json!({}));
        let credential = home.0.join("test-key");
        fs::write(&credential, b"fixture-key\nsecond-line").unwrap();
        assert_eq!(
            read_credential(&credential).unwrap_err(),
            "The balance-query credential is invalid."
        );
        fs::write(
            home.0.join(".harvis-account.json"),
            vec![b' '; (MAX_METADATA_BYTES + 1) as usize],
        )
        .unwrap();
        let error = read_billing_with_query(&home.0, |_, _, _| panic!("no network should run"))
            .unwrap_err()
            .to_string();
        assert_eq!(error, "Account billing metadata is too large.");
        assert!(!error.contains(home.0.to_str().unwrap()));
    }

    #[test]
    fn exhausted_budget_never_starts_another_provider_request() {
        let home = TestHome::new(json!({"connections":[
            {"id":"first", "usage":{"kind":"deepseek-balance","credentialFile":"/private/first"}},
            {"id":"second", "usage":{"kind":"deepseek-balance","credentialFile":"/private/second"}},
            {"id":"qwen", "usage":{"kind":"aliyun-token-plan"}}
        ]}));
        let result = read_billing_before_deadline(
            &home.0,
            |_, _, _| panic!("deadline must prevent network"),
            Instant::now(),
        )
        .unwrap();
        assert!(result.connections[..2]
            .iter()
            .all(|item| item.status == "unavailable" && item.balances.is_empty()));
        assert_eq!(result.connections[2].status, "requires-authorization");
    }
}
