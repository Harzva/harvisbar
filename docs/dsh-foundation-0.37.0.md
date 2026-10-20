# DSH capability foundation and project structure

## Release objective

HarvisBar 0.37.0 establishes a reusable Host capability boundary and makes
projects, paths and conversations visually distinct. The first complete flow is
source-scoped user-input extraction, suggestion generation, optional advisory
review, explicit user selection, revision-checked application and undo.

Project organization remains owned by the existing Harvis organization store.
DSH owns source sessions and plugin services. In the integration architecture,
Supervisor owns supervision information, GroupX owns advisory deliberation,
and Harness Fabric retains native-session control ownership. This release
implements user-input extraction, GroupX advisory jobs and the AgentRoom read
projection; Supervisor and Fabric command adapters remain future work.
A review result cannot approve a write or
change a thread's execution owner.

## Project structure

Object type, containment and execution status use separate visual channels:

- Projects use a stable layers symbol and blue type accents.
- Paths use neutral folder symbols and explicit path labels.
- Conversations use speech-bubble symbols and compact rows with purple accents.
- Unassigned conversations form an inbox-like queue.
- Status badges retain text and symbols; green indicates a known successful
  state, while uninspected content remains unknown.

A persistent tree and breadcrumbs navigate known containment. A separate
relationship view uses only relationships present in the current projection;
it never invents task, dependency or artifact edges. Source/account filters and
loaded-range counts apply consistently to all representations. Logical project
identity is independent from its associated filesystem path.

## Capability boundary

The Host bridge is a separately versioned, optional Host-only plugin. It does
not register model-facing tools or replace the DSH root UI. Each operation has
a JSON contract, explicit source identity, bounded input/output and a local
failure boundary. Missing or incompatible capabilities remain unavailable
without disabling project browsing or existing conversation sources.

The native client must validate the endpoint identity, contract version and
request identity. Session evidence is bound to a source revision. Pagination
must reject a revision change, duplicate items and stale publication. Unknown
user-role origins remain labeled unverified. Known manager, system, tool and
internal-analysis content cannot become organization evidence.

GroupX review reuses its existing role registry, model adapter and artifact
service where available. It produces advisory results for the existing Harvis
review surface. Cancellation is scoped to the bridge-owned review run; a late
result cannot alter a newer review. Supervision metadata remains a projection
of its owning service.

Future adapters will share discovery and result envelopes: session adapters
cover prompt/turn/cancel/recovery through Fabric; business adapters call their
WorkbenchService directly. Domain records, native transcripts and credentials
stay with their existing owners. Unknown command delivery is reconciled rather
than automatically retried. The current Fabric single-controller contract is
preserved.

## Task plan source

The existing AgentRoom task ledger remains authoritative. Its task-plan read
projection must satisfy the already deployed Swift schema, distinguish an
unavailable source from an empty valid ledger, and return stable revision and
evidence identifiers without copying raw evidence bodies or private paths.

## Acceptance and rollback

Validation covers meaningful boundaries: extraction and origin filtering,
identity/revision mismatch, pagination, absent plugins, bounded cancellation,
read-only task projection and organization apply/undo conflicts. A synthetic
live flow verifies the installed Host and native client together without
reassigning real conversations. Native acceptance exercises tree navigation,
relationship selection, properties, account scopes and review controls in
supported appearances and window sizes.

The Host package is first packed and tested in an isolated profile. Production
composition changes use the exact reviewed artifact, preserve existing plugin
rows and retain a rollback copy. The app is built from a clean committed source
through the existing provenance, package and bundle verification pipeline. The
previous app bundle remains available for rollback. Final acceptance records
installation versions and results separately from this public-safe source.
