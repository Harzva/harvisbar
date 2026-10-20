# Workspace interactions

Hiding the bulk Codex input controls previously removed every local entry point
from a card. Each Codex card now keeps three explicit actions: Input, Desktop,
and CLI. Opening one input overrides the bulk visibility and tag filter for that
source-scoped conversation. Collapsing it preserves the draft and shows a clear
collapsed state. Desktop and CLI use the card's account and conversation identity.

Project navigation treats the card body as its primary action and keeps project
properties as a separate control. Navigating must update the path, conversation
scope, and inspector consistently. Project assignment comes from the hierarchy's
direct conversation membership; execution directories do not replace logical
project assignments in the presentation.

The relationship view exposes actual project membership and recorded conversation
lineage. Provider and account scope remain part of every node identity. Missing
or filtered parents are labelled; shared paths, similar titles, and task status
must never be presented as evidence of a parent-child relationship. Nodes retain
access to the existing conversation cards and their input, sending, and Inspect
actions.

Relationship types can be toggled separately. Project and conversation focus
reflows the visible graph; zoom controls and a textual relation list support
navigation. The graph initially fits its available width. Wide layouts keep
details beside the canvas; narrow layouts open the selected node in a detail
sheet. Projects and explanatory nodes share one lane so edges do not cross
through explanatory cards. Conversation batches remain reachable beyond the per-page drawing
limit, and a selected conversation keeps its full card when pagination hides
its node. A single immutable render snapshot supplies filtering, edges, layout,
and detail lookups so graph drawing does not rebuild the projection per node.

The existing Paper, Ink, Forest, and legacy themes remain available. This change
uses native SwiftUI controls and the existing theme tokens, without new runtime
UI dependencies. AionUi's explicit fork metadata is a semantic reference; it does
not supply a reusable graph component for this native application.

Acceptance covers source-scoped opening, local input recovery with the bulk
switch disabled, draft preservation, project body navigation and breadcrumbs,
relationship identity and missing-parent behavior, and actual native renders.
Visual checks use synthetic conversations and do not require sending messages.

Validation: the full Swift suite ran 697 tests with 3 conditional skips and no
failures. After the final responsive-layout changes, 49 related tests and 11
native SwiftUI renders passed. CLI verification covers exact account/session
arguments, working directories with quotes/spaces, invalid sources, and shell
escaping without launching a real conversation or sending a prompt.
