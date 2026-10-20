# Supervisor on conversation cards

Before this release, conversation cards exposed provider activity and Harvis
project management, but did not read or control the DSH Supervisor plugin.
Every list and matrix card now has an explicit supervision or management entry.
Relationship details reuse the same conversation card and retain the entry.

| Source | Available behavior |
| --- | --- |
| Loaded DSH root session | Read Supervisor state; configure advice or takeover; regenerate, adopt, recover, and turn supervision off |
| Unloaded or archived DSH session | Explain availability and offer the existing exact-session opening path; refresh after opening/restoring |
| DSH child or transient session | Observation with an explicit root-session limitation; never silently redirect to a parent |
| Codex main or persisted subagent | Open the existing project management brain, proposal review, and approved Codex dispatch workflow |
| Other Codex card types or WorkBuddy | Explain observation support and the unavailable control operations |

DSH Supervisor and Codex project management remain different execution paths.
This release does not route Codex or WorkBuddy native identifiers into DSH
Supervisor, introduce a Fabric control adapter, or bypass native approval.

## State and control

The optional `@harzva/dsh-harvis-bridge` 0.2.0 adapter discovers the registered
`supervise` command through the existing Host command and agent services. It
uses `commands.execute(agent, line, [], signal)` with a fixed operation mapping.
Only an exact live root agent with the requested session identity is eligible.
The Supervisor plugin retains ownership of settings, suggestions, execution
receipts, scheduling, and persistent recovery.

The `supervisor.session` capability exposes `state`, `set`, `regenerate`,
`adopt`, and `recover`. Every request binds to the advertised runtime ID.
Mutations additionally require the last observed state revision and a unique
action ID. The adapter serializes session operations, rejects stale state,
rechecks the live root before mutation, retains successful and ambiguous action
receipts for the bridge lifetime, and aborts pending command calls on disposal.
The bounded receipt table rejects new actions when full; it does not forget old
action IDs and permit replay. A new bridge instance has a different runtime ID.
Revision checks govern Harvis bridge requests. The existing native Supervisor
command API does not accept a transactional revision token; concurrent control
from other Supervisor clients is outside this release's validated scope.

The native client validates the runtime, source scope, session, response schema,
and bounded projection. A response from a replaced runtime cannot update a card.
Only an open Supervisor panel polls state. Cards display a timestamped snapshot;
old snapshots show a refresh label. Errors remain visible until explicit refresh,
and control requests are never automatically retried.

Advice is sent only when the user adopts it. Enabling takeover explicitly allows
Supervisor to submit later suggestions within the configured round budget.
Regenerate/adopt are unavailable while the native agent is busy, awaiting
approval, recovering an uncertain delivery, or out of rounds. Turning supervision
off stops future Supervisor work; it does not claim to interrupt an already
running native turn or resolve its approvals.

## Verification

The full Swift suite passed 715 tests with three conditional skips. Additional
focused verification consumes the actual isolated plugin's bridge response and
passed 20 tests, including native mixed-provider card rendering. Five Supervisor
panel states and eleven whole-card/layout variants were rendered. The Host suite
passed 27 tests. Runtime
tests cover exact card routing, state writeback, duplicate clicks, an ambiguous
response followed by read-only reconciliation, and a runtime replacement while a
read is pending. Host tests cover identity, revision, duplicate and unknown
actions, busy/approval ownership, agent replacement, strict settings, malformed
or oversized suggestions, and plugin disposal.

`scripts/test-dsh-supervisor-closed-loop.mjs` loads an installed Supervisor entry
specified by `DSH_SUPERVISOR_PLUGIN_PATH`. It uses a temporary store, synthetic
session and native delivery sink, a deterministic LLM, and a real loopback HTTP
server. The bridge loop exercises off → advice → regenerate → suggestion → adopt
exactly once → off, then checks persistent recovery through the bridge. An extra
plugin scenario verifies that a late generation cannot survive supervision being
turned off. The run produced two deterministic model calls and one durable
delivery; restart retained the used-round count, and no native turn was stopped.

These checks exercise the installed Supervisor implementation with an isolated
Host fixture. They do not represent a paid model evaluation, a complete live DSH
Host lifecycle test, or unattended supervision of existing business conversations.
The daily profile is checked through capability discovery after deployment;
existing conversations are not automatically enrolled in takeover.
