# Version tool: discovery and operation contract

The native HarvisBar 0.36.9 catalog is retained. A separate, stdlib-only local adapter reuses the same collector and machine configuration. Existing `harvis-versions list/schema` remain compatible; structured agent operations use `harvis-versions agent`, or MCP server `harvis-versions`. The agent adapter has its own release identity and does not rewrite the signed application payload.

## Discovery

Skill: `skills/harvis-versions/SKILL.md`. Automatic discovery is enabled. MCP exposes five tools: `versions_list`, `versions_get`, `versions_plan`, `versions_validate_plan`, `versions_capabilities`. All have input/output schemas and read-only, non-destructive annotations. Fixed MCP schema resources are `harvis-versions://schema/agent-v1` and `harvis-versions://schema/catalog-v1`. `--help` describes CLI routing. New MCP configuration may require the client to reload connections or start a new task before tool discovery; configuration alone is not proof of a loaded tool in an existing task.

## Contract

`agent` and MCP share `harvis.version-agent.v1`: `ok`, `data`, `error`, `meta`. The response schema validates every operation's payload. Version fields remain nullable. CLI agent failures emit a JSON envelope to stdout and exit nonzero; human `--help` is text. MCP execution errors set `isError=true`; protocol failures use JSON-RPC error responses. Protocol stdout contains only newline-delimited JSON-RPC. Requests over 1 MiB are rejected. Reads execute the existing bounded DSH version probe and never invoke install commands.

| Operation | Input | Result |
| --- | --- | --- |
| list | optional kind/query/offset/limit/expectedSnapshot | items, total, offset, nextOffset; default 30, maximum 100 |
| get | exact itemId from list | item, evidence, observed stateHash |
| plan | itemId, operation upgrade/switch/rollback, targetVersion | non-executable preview, before/requestedAfter, blockers, rollback requirements, 15-minute expiry, state/content hashes |
| validate-plan | full plan object | unchanged and executable=false, or state/expiry/content error |
| capabilities | none | supported operations, disabled mutations, error exit codes |

| Error | CLI exit | Meaning |
| --- | --- | --- |
| INVALID_ARGUMENT | 2 | invalid/unknown parameters |
| CONFIG_INVALID | 3 | invalid machine configuration |
| SOURCE_UNAVAILABLE | 4 | cannot determine the requested item from failed sources |
| NOT_FOUND | 5 | item not found in the available source |
| SNAPSHOT_CHANGED | 6 | page sequence or observed target state changed |
| PLAN_CHANGED / PLAN_EXPIRED | 7 | preview edited or expired |
| INTERNAL_ERROR | 8 | unexpected failure, with private diagnostics omitted |
| EXECUTOR_UNAVAILABLE | 9 | actual mutation is not implemented |

## Evidence and consistency

Every response has a request ID, generation time, snapshot revision, partial flag, warnings and sources. Sources identify snapshot versus local read, location, observation time, age, stale/unknown state and a revision when available. Future clocks are unknown/clock_skew rather than fresh. Pagination should echo the previous snapshot revision. Missing data is not evidence of absence. The MCP process retains its last repository/plugin records during a later source failure and labels the source unavailable/retained; a fresh CLI invocation does not invent cached records. A local refresh does not fetch GitHub or refresh RepoAtlas. No separate feedback or repository truth store is created.

## Modification boundaries

Planning and validation are implemented; actual upgrade, switch and rollback executors are not. A preview is not a simulated successful installation. Target artifacts are unverified, backups are not created, and every plan explicitly contains blockers and `executable=false`. The content hash detects accidental edits, not malicious forgery; it is not a signature, lease for execution or authorization token. The target state hash covers catalog fields and selected path metadata, not every file or running process. Passing validation does not establish that a backup can restore a deployment.

A future executor must supply product-specific artifact verification, real candidate diffs, concurrency control, exact preconditions, authorization for the concrete change, idempotency/retry behavior, backup validation, health checks and tested rollback before enabling mutation. None of those should be inferred from the existence of a schema.

## Validation

Collector/contract tests cover error envelopes, stale and unavailable sources, retained snapshots, pagination changes, null versions, plan tampering/expiry/state changes and the absence of writes during planning. A separate integration test uses the official MCP Python client SDK for initialization, tool/resource discovery, real local reads, invalid argument errors, preview generation and validation. Test dependencies are isolated; production uses Python's standard library. Runtime adapter installs use immutable releases plus an atomic current pointer, preserve the previous release, and keep all machine paths/configuration out of source commits.

Protocol references: [MCP tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools) and [lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle).
