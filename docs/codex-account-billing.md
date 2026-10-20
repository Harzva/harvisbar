# Codex account models, Credits, and billing

HarvisBar 0.44 separates three questions in each Home's account details:

1. Which models and service connections are configured locally?
2. How is each connection accessed and billed?
3. What quota or balance did the corresponding service actually return, and
   when was it read?

One Home may describe multiple API connections and model options. That does not
create additional Homes, merge their account identities, authenticate a model,
or install a gateway. A connection's metadata describes its routing and billing
context; it does not implement model routing.

## Configured model options

Home discovery projects `configuredModels` from the current default `model`,
inline `profiles` tables in `config.toml`, and `model_catalog_json`. A catalog
path may be relative to the Home. Its supported JSON shape is a `models` array
or a top-level array, with `slug` and optional `display_name` fields. Entries are
deduplicated by model ID. Explicit connection `modelIds` can associate these
options with a declared provider.

Each projected model has `id`, `displayName`, optional `providerId`, and
`source: "configured"`. These are local configuration facts. They do not prove
that the key is valid, a subscription includes that model, the gateway routes
it, or a model invocation will succeed. Discovery does not send model requests
to test access. Separately stored Codex profile files are not exhaustively
enumerated by this projection.

The Home list schema is `harvis.codex-home-list.v3`. Existing default model and
provider fields remain available alongside `configuredModels` and `connections`.

## Local account metadata

An optional `.harvis-account.json` in the selected Home supplies descriptive
connection and billing metadata. Its schema is `harvis.codex-account.v1`.
Keep the real file and all credential files outside this public source tree.

The following example is entirely synthetic. The credential filename is a
documentation placeholder, not a ready-to-use balance-query configuration.

```json
{
  "schemaVersion": "harvis.codex-account.v1",
  "label": "Example model workspace",
  "connections": [
    {
      "id": "example-usage",
      "name": "Example usage account",
      "providerId": "example-api",
      "endpointHost": "models.example.test",
      "modelIds": ["example-chat"],
      "accessMode": "api",
      "billingMode": "usage",
      "balances": [],
      "allowances": [],
      "usage": {
        "kind": "deepseek-balance",
        "credentialFile": "credentials/example-balance-key"
      }
    },
    {
      "id": "example-monthly",
      "name": "Example monthly account",
      "providerId": "example-plan",
      "endpointHost": "plan.example.test",
      "modelIds": ["example-flash"],
      "accessMode": "api",
      "billingMode": "subscription",
      "billingPeriod": "monthly",
      "planName": "Example monthly plan",
      "allowances": [
        {
          "id": "example-requests",
          "label": "Example request allowance",
          "remaining": null,
          "used": null,
          "limit": 1000,
          "unit": "requests",
          "resetsAt": null,
          "updatedAt": null
        }
      ],
      "balances": [],
      "usage": {
        "kind": "aliyun-token-plan"
      }
    }
  ]
}
```

The example allowance is illustrative, not a provider plan specification. Do
not copy its limit or imply that it is a live reading. For the DeepSeek adapter,
`usage.credentialFile` must be expanded to a real absolute path in your private
local metadata before refresh can read it. A relative path is treated as not
configured. The credential file contains the existing DeepSeek API key; the key
itself is never a metadata field or a public example. The adapter uses a fixed
official balance destination, not `endpointHost` from this example.

### Connection fields

| Field | Meaning |
| --- | --- |
| `id` | Stable connection identity within this Home; used to match refresh results. |
| `name` | Display name, independent of a secret or credential filename. |
| `providerId` | Optional local provider association. |
| `endpointHost` | Optional hostname only; no URL credentials, path, or query. |
| `modelIds` | Configured model IDs associated with this connection. |
| `accessMode` | `api`, `chatgpt`, or `unknown`. |
| `billingMode` | `usage`, `subscription`, or `unknown`. |
| `planName` | Optional descriptive plan name; not proof of entitlement. |
| `billingPeriod` | Optional period; `monthly` displays a monthly subscription, and `annual` an annual subscription. |
| `allowances` | Optional declared limits, consumption, remaining amounts, units, and reset/read times. |
| `balances` | Optional declared decimal currency balances. |
| `usage` | Private adapter configuration; it is not included in the discovery projection. |

Access and billing are independent. In particular, an API can be part of a
monthly subscription. `accessMode: "api"` must not automatically imply
`billingMode: "usage"`. Missing or unrecognized modes remain `unknown`.
`billingPeriod: "monthly"` is descriptive; it does not calculate a reset date or
create a subscription.

Allowances have an `id`, label, `unit`, optional `remaining`, `used`, `limit`,
`resetsAt`, and `updatedAt`. Timestamps are Unix seconds. Unknown quantities and
times should be omitted or `null`, never represented by an invented zero. A
supplied zero is meaningful; a negative remaining value may represent an
overage. Monetary balances use a decimal string such as `"12.3400"`, plus a
currency code and optional `updatedAt`, so display does not depend on a binary
floating-point conversion. Legitimate negative currency balances are retained.

Declared allowances and balances are projected with `source: "configured"`.
HarvisBar does not trust a caller-supplied `source` value to turn configuration
into a provider reading. Discovery bounds the metadata size and counts and
projects only supported display fields. It does not return adapter credential
filenames or arbitrary metadata payloads.

## Official ChatGPT quota and Credits

Official quota is read for one exact Home through Codex App Server's
`account/rateLimits/read`. The `harvis.codex-home-quota.v1` result includes its
`homeId` and the returned quota buckets. Each bucket may contain primary and
secondary rate-limit windows and a separate `credits` object with optional
`hasCredits`, `unlimited`, and decimal-string `balance` values.

These Credits are the selected official account's service-reported Credits.
They are not an API currency balance, a token count, or a monthly provider
allowance. HarvisBar does not convert between these units or combine them into
one total. A bucket's `resetsAt` belongs to its quota window; it must not be
invented for a Credits balance that has no supplied reset field.

Missing Credits remain unprovided. A failed or unavailable official query does
not become `0 Credits`, and another selected account's successful reading is
not substituted. Custom/API Homes do not expose official ChatGPT quota merely
because a stale official login file happens to exist in the same directory.

## Explicit provider billing refresh

Discovery and hover summaries use local or cached information. They do not
query billing endpoints, execute a custom Codex CLI, or send a prompt to a model.
Opening an account's details can request that Home's supported quota and billing
reads, with repeat attempts throttled for 60 seconds. The **refresh usage**
action explicitly requests a new read for that account. It is not a background
scan of all discovered Homes.

The CLI operations are separate as well. These examples use a synthetic local
Home directory:

```sh
./scripts/harvis codex homes
./scripts/harvis codex quota --home ./example-home
./scripts/harvis codex billing --home ./example-home
```

`codex homes` is configuration discovery. `codex quota` reads eligible official
quota; `codex billing` explicitly queries only adapters configured in that
Home's metadata. None of these billing operations invokes a model inference
request. The directory must already be configured; these commands do not create
or authenticate it.

### Supported adapters

| `usage.kind` | Current behavior |
| --- | --- |
| `deepseek-balance` | Uses the explicitly referenced existing DeepSeek key to read the fixed official balance API; projects supported CNY/USD `total_balance` values as `source: "provider"`. |
| `aliyun-token-plan` | Returns `requires-authorization`; model API keys cannot query Token Plan usage. |
| Missing or unsupported kind | No provider query; reports an unconfigured or unsupported adapter. |

DeepSeek's `serviceAvailable` is distinct from a successful balance read. A
balance can be retrieved successfully while the service reports insufficient
funds for inference. Queries are bounded, do not follow redirects, and return
safe error messages rather than raw provider responses or credentials. A
failure in one connection does not fall back to another connection's key.

Alibaba Cloud Token Plan usage needs separate read-only Alibaba Cloud RAM
authorization and request signing. The model API key is not that authorization.
This release does not implement a signed RAM usage adapter; a declared monthly
plan remains local configuration, and remaining allowance and reset time stay
unknown until a trusted reading is available. Do not put RAM secrets in public
examples or treat `requires-authorization` as an empty or exhausted plan.

The billing result schema is `harvis.codex-home-billing.v1`. Each result names
its `homeId` and has per-connection `id`, `available`, `status`, optional
`serviceAvailable`, `balances`, `allowances`, read timestamp `updatedAt`, and a
safe optional error. `available` means a supported billing reading was obtained;
it does not guarantee successful model access or sufficient funds. Current
DeepSeek reads supply balances, not reset-based allowances.

## Source, freshness, and isolation

The details view distinguishes local configuration from provider-returned
amounts and displays read/reset times when supplied. Successful provider
snapshots are treated as recent for five minutes; that is a UI freshness
threshold, not a provider guarantee. After a failed refresh, previous values may
remain visible with a failure or cached-data notice and their original read
time. An older balance does not become current merely because a retry occurred.

Official Credits and quota windows have their own read time. A passed reset
boundary can make a cached quota window stale before the five-minute threshold.
Neither case silently invents a refreshed amount. Configured metadata remains
configured even if it contains an `updatedAt` field.

Refresh responses are accepted only for the matching Home and connection IDs.
Account or connection identity changes invalidate the associated snapshots and
in-flight generations; a late response from the former account cannot replace
the current account's display. Monetary currencies, reset-based plan allowances,
and official Credits remain separately labeled throughout.

Real account labels, configured hosts, balance amounts, timestamps, and private
metadata can themselves be sensitive. Keep personal subscription details and
acceptance evidence outside this source tree, and use synthetic fixtures for
tests and screenshots.
