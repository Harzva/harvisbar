# Account matrix — 0.36.10

Chat Agent Managed now gives Codex, DSH, and WorkBuddy separate rows. Selecting an agent reveals its account or source choices beside it; each row can select or clear its sources independently. Existing saved display scopes remain compatible, including deliberately empty selections. Display choices do not change the account used by management actions.

Buttons fit their text. Codex labels prefer short numeric notes or abbreviated email usernames, with full identity in help/accessibility text. Repeated short names receive stable source-order suffixes. Account rows retain native horizontal scroll indicators so overflow can be discovered and operated in narrow windows. DSH exposes known runtime profiles and WorkBuddy exposes the local conversation store; neither is represented as an authenticated multi-account catalog.

The model caches account catalogs until their inputs change, and conversation projections are invalidated immediately by source changes with a five-second maximum lifetime for time-derived trust labels. Search is parsed once per filtering pass, empty search avoids constructing per-card text, and display-only filters no longer restart complete-catalog governance refreshes. The All/Running/Recent control uses fixed-height SwiftUI buttons to avoid native segmented-control layout re-entry during live updates.

Validation: the complete Swift suite passes 566 tests. Synthetic previews cover wide/narrow windows, individual selection, no selection, and many accounts. Regression tests cover legacy preferences, provider isolation, abbreviated-name collisions, and cache invalidation. A 200-card workload includes repeated warm catalog reads.

Native candidate checks verified all three provider toggles, individual Codex and DSH source selection, row select/clear, empty-state recovery, status and search filters, card scrolling, and save/restore defaults against the local catalog. WorkBuddy had no local conversations, so its unavailable source actions were verified disabled. The candidate's idle main thread waited for events instead of repeatedly sizing a native segmented control.

Local release acceptance uses the existing provenance stage, bundle receipt and strict code-signature verifiers. Retain the prior application bundle, finish narrow-window scroll and relaunch checks, restore the chosen display scope, and recheck the installed version and idle CPU before declaring the upgrade complete. Keep local receipts, screenshots and performance samples outside the repository.
