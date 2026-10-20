# Card navigation and account window reuse — 0.36.8

Continues the 0.36.1-based branch and retains 0.36.5 DSH card inputs, shared sending, account/provider display scopes, project-path grouping, and performance changes.

## Implementation plan and behavior

1. Make card and list title clicks consistently open the provider application, independently of whether the Harvis workbench is expanded. Keep the separate Inspect action for Harvis details.
2. Resolve a Codex card to its source account. Find an existing desktop process with a verified canonical CODEX_HOME; activate and navigate that process. Never use the current management account as a substitute or dispatch account-specific links through the global URL handler.
3. Only launch when no matching account instance exists. Coalesce concurrent opens for the same account, pass account and Electron data directories in the new process configuration, and verify identity again before routing. Do not change global launchd environment variables. Normal opens do not request new windows; the explicit new-window action remains separate. Native deliveries are serialized per process, with account identity rechecked after queue waits. Explicit window creation activates the account and orders the new window first before dispatching the deep link; actual focus/navigation behavior still needs native acceptance.
4. DSH titles open the exact encoded session URL in the unique running runtime for the card scope. Offline or ambiguous scopes show the runtime catalog instead of guessing a different instance.
5. Verify unit coverage and the signed versioned bundle, back up the installed app, install the candidate, and save native acceptance evidence outside the repository.

## Account identification and performance

Only candidates identified by the desktop bundle ID are inspected. A bounded process-argument read retains PID, CODEX_HOME, and the Electron data directory, never raw environment or credentials. Unknown, malformed, conflicting, or helper process identities cannot be used as the default account. Path aliases and existing symlinks are normalized. A missing CODEX_HOME is recognized as the default account only when HOME and data directory checks agree.

The coordinator runs only on user actions, adds no card timers or background scans, and coalesces in-flight account launches and identical opens. Blocking AppleEvent delivery runs off the main actor. Deep links are addressed to a verified PID. This changes Harvis Bar GUI actions; the standalone CLI launch-desktop command is outside this change.

## Acceptance

Tests cover existing and wrong-account instances, explicit new windows, cold opens, launch coalescing, identity loss, safe URL encoding, DSH runtime ambiguity, and synthetic process argument parsing. Preserve existing send, draft, display scope and grouping regressions.

Native checks should show DSH card title navigation to the matching session with the card input retained. Codex checks require an already-open account window: click two cards from that account and verify the same process/window changes conversation; repeat with another already-open account and verify no cross-account routing. A cold account should launch once; explicit new-window should create only one additional window within the account process.

Current automation policy may block inspection or operation of the official Codex application. If blocked, record that limitation and leave Codex native window behavior unverified rather than substituting unit tests for UI acceptance. Keep screenshots and the installation verification report outside the repository. Retain the previous application bundle for rollback; do not restart DSH or unrelated applications.

## 0.36.7 closure

Opening a provider application is a request, not proof that the conversation has rendered. UI feedback now says that opening was requested; an unsuccessful native activation is reported as an error. The receipt records the caller's new-window intent without claiming confirmed window creation. No automatic retry is added.

All per-account GUI actions, including login, CLI launch, and desktop navigation, share activity reference counts. A completed action cannot clear another action's busy state. A cold-start owner uses the first application window; an overlapping distinct explicit new-window request joins the same launch and requests an additional window. Identical in-flight requests are still coalesced. Unit coverage includes these overlap and failure cases.

Native closure should additionally send a harmless unique marker from a dedicated DSH card with its detail closed, verify one matching user request and a completed assistant reply, then click the title and verify that exact reply in the original DSH page. Save unedited screenshots before sending, after the card reply, after external navigation, and at the internal Inspect action. Keep Codex native acceptance separate when official-application automation is prohibited.

## 0.36.8 cold-start discovery

An externally installed DSH runtime can use a known Home without mentioning that Home in its command line. Previously, the lightweight running catalog missed that process even though the full runtime catalog found it; after restarting Harvis, its conversation cards disappeared.

Running discovery now reads explicit `DSH_HOME` from candidate process metadata and binds it only to one canonical discovered Home. It rejects unknown, conflicting, unreadable, or changing process identities instead of guessing a Home. Existing deterministic command matching remains available when the process has no explicit `DSH_HOME`. Environment contents are never included in catalog output. The lightweight path still avoids profile manifests.

Cold-start acceptance must restart the installed Harvis application while leaving DSH running, confirm that the dedicated DSH card returns, then perform the card send, external title navigation, and independent Inspect checks above. Record the installed version and executable hashes alongside a fresh unique marker and read-only session baseline.
