# Supervisor overview and editable settings

Conversation cards now share a supervision overview inside the management
window. The overview uses the window's current provider, account, and search
filters, including explicit project queries. Matrix folder navigation is kept
separately and does not narrow this range. It groups timestamped snapshots into active, attention, off,
unread, unavailable, and project-management/observation states. Opening a row
retains its complete provider, source scope, and session identity.

Refreshing the overview is an explicit read-only operation. It discovers the
running bridge capabilities once, deduplicates eligible DSH root cards, and
performs at most four concurrent session reads. Progress is visible and the
operation can be cancelled. Unsupported providers, child sessions, and archived
sessions never receive Supervisor control requests. The overview does not enroll
sessions, adopt suggestions, or poll all conversations in the background.

Unavailable executors are distinguished from control results that need review.
Snapshots older than thirty seconds are shown as needing refresh rather than
counted as current active supervision. Existing source/runtime checks reject a
response from a replaced endpoint before it can update the displayed card.

## Settings and action feedback

The detail panel initializes its settings from the provider's state, including
the off mode and existing round budget. Controls wait for the initial read to
complete. Drafts are bound to the full card identity and retain their edit
baseline. Changes to execution progress do not discard an edit; changes to the
provider's settings require reconciliation before applying it. Settings requests
contain only modified fields, preserving untouched provider-owned values.

Failed requests retain the user's draft. A control result requiring review stays
visible when the panel is reopened and is reconciled by an explicit refresh.
Successful actions show a receipt appropriate to the operation: requesting a new
suggestion is not reported as completed generation, and adopting a suggestion is
not reported as completion of the native session's work.

The DSH bridge and installed Supervisor plugin are unchanged in this release.
Codex cards continue to use their existing project-management and approved
dispatch path; WorkBuddy and unsupported card types expose observation support.

## Verification scope

The isolated real-plugin fixture additionally changes only the round budget,
then restores it, and verifies that the off mode, strategy, inspection interval,
model call count, and native delivery count remain unchanged. It then exercises
generation, one-time adoption, shutdown, and persisted recovery as before.

This fixture uses the real installed Supervisor implementation with a synthetic
Host, deterministic model responses, and a real loopback HTTP bridge. It is not a
production-model or multi-client concurrency evaluation.

Validation completed with 730 Swift tests (four opt-in fixtures skipped, zero
failures), 33 focused Supervisor tests with the real-plugin wire fixture, and
27 bridge tests. Native render fixtures cover the overview at wide and narrow
sizes, empty and mixed-provider ranges, and a provider state with supervision
off and three rounds. The complete management-window fixture also includes a
480-point width to check the new overview entry alongside the existing controls.
