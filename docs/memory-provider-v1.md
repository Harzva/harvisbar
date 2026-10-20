# HARVIS Memory Provider V1

HARVIS owns the memory control plane: candidates, human review, canonical
identifiers, routing, commit reconciliation, visibility, and audit state.
Provider adapters only store and retrieve accepted records.

## M0 capability matrix

| Capability | Fake | Local SQLite | MVP required |
| --- | --- | --- | --- |
| `capabilities` | yes | yes | yes |
| `health` | yes | yes | yes |
| `recall` | yes | yes | yes |
| `context_pack` | yes | yes | yes |
| `commit_approved` | yes | yes | yes |
| `entity` | no | no | no |
| `reflect` | no | no | no |
| `forget_approved` | no | no | no |
| `export` | yes | yes | migration only |

The executable contract is `HarvisMemoryProviderV1` in
`crates/harvis-runtime/src/memory_provider.rs`. `propose` is deliberately not a
provider method.

## Persistence and state

Runtime files remain under ignored `.harvis/memory-v1/` state:

- `harvis-canonical.sqlite3` contains physically separate candidate and
  accepted tables plus the HARVIS commit journal.
- `providers/local-sqlite.sqlite3` is the offline provider implementation.
- `providers/gbrain-reconciliation.sqlite3` records reviewed commits and their
  portable records without adopting GBrain identifiers as HARVIS identity.

Approval moves a canonical record to `accepted_pending_commit`. The service
derives the stable key from `approval_id + memory_id + provider_id +
schema_version`, then moves through `committing` to `committed`,
`retryable_failure`, or `terminal_failure`. Only HARVIS records marked
`committed` and still `accepted` can be recalled.

The existing workbench candidate reconciler imports only reviews whose decision
is `approve`. It records the provider commit metadata on the candidate review;
missing commit metadata is retried on later ticks with the same key. Reject and
defer decisions never reach a provider.

## Safety boundary

Recall is filtered by project/user/session/agent/shared subject and sensitivity,
then cross-checked against the canonical commit journal. Context packs include
provenance, scores, and a total token estimate. Stored angle brackets are escaped
inside JSON data records so a memory cannot forge the outer context boundary.
Provider recall failures degrade to an empty context rather than blocking the
caller.

## Built-in profiles

- `minimal`: Local SQLite, no external service.
- `local-fast`: GBrain primary, Local SQLite fallback, and LLMWiki as a
  separate read-only project-knowledge lane. Production activation requires
  the exact `confirm_memory_profile:local-fast` confirmation.
- `learning-lab`, `temporal-lab`, and `shadow-benchmark`: experimental profiles
  that runtime validation refuses to use as production routes.

The GBrain adapter accepts exactly the seven MEMORY_VERBS v1 operations:
`recall`, `remember`, `entity`, `synthesize`, `forget`, `context_pack`, and
`delta`. It never runs persona bootstrap, writes only after HARVIS approval,
and filters recall through reviewed provenance and the canonical journal.

LLMWiki implements a distinct `HarvisKnowledgeProviderV1`. The adapter refuses
non-read calls and preserves immutable raw-source references. Personal memory
and project knowledge remain typed as separate result lanes, and failure in one
lane does not grant or contaminate the other.

## DSH and lifecycle

`@harzva/dsh-memory` provides one process-level Cordis Host service. Agent
Presets consume it, warm each session once, and do not create competing
provider/router instances. Unload closes the MCP child and clears session
caches; a reload receives a fresh Host. The JSON-only Client tool view displays
status, provider/profile, evidence-reference counts, token usage, and degraded
warnings.

The model-safe surface is recall, context, entity, and candidate proposal.
Status, candidate review, portable export, migration, and rollback stay on the
administrative MCP surface.

## Portable migration

Portable bundles contain uniquely sorted records and a canonical SHA-256 shared
by the Rust and Python implementations. A production switch requires a clean
dry run and its exact confirmation string. The target must pass health,
capability, count, hash, and sample-recall checks before a transaction updates
the canonical provider references and route. Rollback restores the source
route from the migration journal and disables target use without destructively
deleting target data.

The Digital-Me safe-core benchmark evaluates synthetic/public observations for
GBrain, Hindsight, Graphiti, and Mem0. Experimental adapters are never promoted
unless safety, deletion, migration, failure-resilience, temporal, and paired
statistical-improvement gates all pass. Eligibility is evidence only; it never
performs a production switch.

Run the M0 checks with:

```bash
cargo test -p harvis-runtime memory_provider
cargo test -p harvis-runtime memory::tests
cargo test -p harvis-runtime gbrain_memory
cargo test -p harvis-runtime knowledge_provider
cargo test -p harvis-mcp --lib
```
