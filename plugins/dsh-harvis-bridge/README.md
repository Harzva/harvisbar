# DSH Harvis capability bridge

`@harzva/dsh-harvis-bridge` is a Host-only plain ESM plugin for the Harvis
conversation input reader and the optional DSH Supervisor session controls. It
registers one exact loopback route:

```text
POST /harvis-bridge/v1
```

The route is intentionally separate from DSH's fixed `/api` RPC map. The
plugin reads `ctx.sessionPersistence.inspect()` and never resumes an Agent,
publishes a Session, or returns raw `session.history` events. Supervisor
operations use the already registered `supervise` command from the installed
`dsh-supervisor` package through `ctx.get('commands').execute()`; this bridge
does not duplicate Supervisor state or prompt logic.

## Mounting

The package is dependency-free beyond Node's standard library. The native
source-pinned DSH runtime checked for this bridge is `@deepseek-ai/dsh` and
its `@deepseek-ai/dsh-host-webserver`, `@deepseek-ai/dsh-session-persistence`,
`@deepseek-ai/dsh-session`, and `@deepseek-ai/dsh-llm` contracts at
`0.1.1-rc.2` (Node `^22.19.0 || >=24.0.0`). The Host composition must mount
the web server and session persistence services before this plugin. Installing
the package alone does not modify a profile or expose a route.

The optional GroupX review path resolves the public mode package at
`@harness-flow/dsh-groupx@0.1.0-alpha.27`; the peer is marked optional so the
session input capability can run without GroupX.

The profile supplies immutable authority facts. `homeID` and `profile` are
required; `runtimeId` is minted once for this Host process and is never a
configuration field. In the native DSH deployment, `homeID` is the opaque
catalog label `dsh`, rather than the filesystem path. The bridge excludes the
known `harzva-meta` and `delivery-manager` agent presets and
`harvis-review-`/`harvis-organizer-` session prefixes by default. A deployment
can add known manager or analysis sessions in the policy:

```yaml
- id: dsh-harvis-bridge
  name: '@harzva/dsh-harvis-bridge'
  config:
    homeID: 'dsh'
    profile: 'digital-me'
    internalSessionPrefixes: ['manager:']
    internalAgentPresets: ['harvis-manager']
```

`homeID`, `profile`, and `runtimeId` are server response authority. A request
cannot override them. Missing authority is a configuration error, so the
plugin fails closed during activation.

The route accepts only `POST`, `Content-Type: application/json`, and a direct
loopback peer (`127.0.0.1` or `::1`). The HTTP `Host` header must also be the
same loopback literal, with an optional port; when `Origin` is present it must
be the matching `http://` loopback origin. `null`, remote, DNS, forwarded, or
cross-port origins are rejected. Requests and responses are bounded at 64 KiB
and 1 MiB respectively. No forwarded-host or forwarded-address header is
trusted.

A profile may mount the packed package's `src/index.js` from a separate,
immutable version directory. Its nearest profile `node_modules` must resolve
the optional GroupX peer when review is enabled. Install a changed artifact in
a new directory and update only the bridge loader row; removing that row
disposes its route and owned review jobs. Existing profile dependencies need
no version changes for this file-entry deployment.

## Envelope

Every valid request has this shape:

```json
{
  "schemaVersion": "harvis.dsh-bridge.v1",
  "requestId": "client-correlation-id",
  "method": "capabilities.describe",
  "params": {}
}
```

Responses echo `requestId` and carry the server-derived authority:

```json
{
  "schemaVersion": "harvis.dsh-bridge.v1",
  "requestId": "client-correlation-id",
  "authority": {
    "homeID": "dsh",
    "profile": "digital-me",
    "runtimeId": "process-local-id"
  },
  "result": { "ok": true, "value": {} }
}
```

`capabilities.describe` returns the `harvis.dsh-capabilities.v1` catalog. The
`session.userInputs` capability is advertised only when `ctx.get` finds a
Host persistence service with both `inspect` and `listSnapshots`. Other
capabilities are not advertised until a real Host service and its contract are
mounted. When the optional `groupx-review.mjs` service is present and accepts
the configured `reviewModels`, the same catalog includes `groupx.review` v1
with `start`, `status`, and `cancel` operations. The bridge never discovers
model credentials or model lists from a request.

The `supervisor.session` capability is available only when the Host agent
registry exposes `roots()`, `commands.execute()` exists, and a `supervise`
command is registered on a root agent. Missing services or a missing command
are reported as an explicit unavailable descriptor. Its operations are
`state`, `set`, `regenerate`, `adopt`, and `recover`.

Supervisor state reads require `sessionId` and the exact process-local
`expectedRuntimeId`. Mutations additionally require the last state
`expectedRevision` and a bounded `actionId`; `set` accepts only `mode`,
`strategy`, `rounds`, and `intervalMs` in their native ranges and requires a
nonempty patch. `regenerate`, `adopt`, and `recover` omit `patch`. The bridge
resolves the exact object returned by `ctx.agents.get(sessionId)`, requires
that same object in `ctx.agents.roots()`, and verifies `agent.session.id`.
Unknown or unloaded sessions return `session-unavailable`; child or non-root
sessions return `unsupported-session`.

Commands are serialized per session. A repeated action ID with the same
canonical payload is idempotent, while reuse with a different payload returns
`action-conflict`. An ambiguous command result returns `action-unknown` and is
never replayed. The fixed `harvis.dsh-supervisor.v1` projection contains only
bounded control and execution fields. Its `revision` is a SHA-256 digest of
the normalized projection with `revision` excluded. Polling state may append
the native command lifecycle events, but never enables supervision. `adopt`
requires a current suggestion, suggestion ID, remaining quota, and no recovery
flag. `regenerate` is rejected while supervision is off or while the native
agent is working or waiting for approval. Turning supervision off remains
available from a known state.

## User input projection

`session.userInputs` accepts:

```json
{
  "sessionId": "session-id",
  "cursor": null,
  "limit": 100
}
```

The response is `harvis.dsh-user-inputs.v1` and contains bounded items with
`id`, event `sequence`, optional `turnId` and ISO timestamp, visible text,
truncation metadata, and `source`. A source revision is an opaque
`sha256:<64 lowercase hex>` token. Cursors bind to both the session and that
revision; appending to the source makes a previous cursor return
`stale-cursor` or `source-changed`.

Only `user/message` events whose message source is `{ kind: 'user' }` are
eligible. The API's transport extension `{ kind: 'user', rpcId: ... }` is
returned as `source: "unknown"` because the persisted event cannot prove that
the caller was a natural person. Plain source records are returned as
`source: "human"`. Plugin context, tool results, image-only prompts, and
other user-role records are excluded and counted in
`excludedNonHumanItems`. Text is capped at 12,000 Unicode code points per
item; IDs are hashed only as an optional origin reference and source text is
included only in an opaque source-revision digest when a live inspection is
ahead of the durable checkpoint. No raw event bodies are returned.

The source is inspected as immutable data. Cold sessions remain cold, and the
plugin does not use the public Remote/Client aggregate or add a fixed `/api`
method. Harvis can therefore treat the bridge as an optional capability and
fall back to its ordinary DSH catalog when the route or capability is absent.

## Optional GroupX review

The GroupX capability is available only when the Host-side review service is
mounted. Its request methods are:

```text
groupx.review.start  { jobId, proposalRevision, task }
groupx.review.status { jobId, proposalRevision }
groupx.review.cancel { jobId, proposalRevision }
```

`jobId` is a canonical UUID, `proposalRevision` is the lowercase
`sha256:<64 hex>` digest of the submitted task, and `task` is bounded to
16,000 Unicode code points. The service returns only the fixed
`harvis.groupx-review-job.v1` projection: job identity and revision, lifecycle
state, timestamps, summary, participant/model-call counts, the model-call
bound, and an optional error code. Cancellation is idempotent at the service
boundary and the loader disposer calls the service's `dispose()` hook.

`reviewModels` is trusted deployment configuration. It is not read from
client params and is not exposed in the capability catalog.

## Checks

The package has no runtime dependencies beyond Node's standard library:

```sh
npm test
```
