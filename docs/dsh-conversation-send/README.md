# DSH conversation sending — 0.36.5

Built on the 0.36.1-based display-scope branch, retaining mixed-account/provider filters, project-path grouping, and the subsequent performance fixes.

## Implementation plan and behavior

1. Render a multiline input and Send button directly on every DSH card in both matrix and list layouts. Reuse the native composer keyboard behavior: Enter sends, Shift+Enter inserts a newline, and marked IME text is committed through the input system. The Codex composer visibility and tag controls do not hide DSH inputs. Offline, archived, ambiguous, or subagent targets keep a disabled input with an explanation.
2. Route card and detail sends through the same sender. A target includes provider scope, active endpoint port, and exact session ID. Recheck the live session and archive lists before posting. Subagents require the separate parent/child API and remain available in DSH itself in this release.
3. Keep card drafts in per-conversation observable objects keyed by full managed identity. Filtering or lazy card remounting preserves drafts during the app process lifetime; keystrokes do not publish changes through the parent grid. Clear a submitted draft only when it has not changed. Rejected or blocked sends keep the draft.
4. Reconcile pending sends from the shared runtime refresh, so card sends complete without opening a detail. Cards add no timers and perform no idle history polling. Verify only the original endpoint, no more frequently than three seconds, and stop automatic checks after 100 attempts. Manual reconciliation remains available without reposting.
5. Build and verify a versioned application, retain the previous bundle, install it, and complete a real native card click acceptance before reporting delivery.

## Delivery and performance contract

The sender uses the existing loopback DSH Host API and does not modify DSH packages or profiles. RPC transport uses a shared ephemeral session without HTTP cache, cookies, or credential storage; each request bypasses caches and requests no storage, ensuring live session authority and per-request envelopes are not replayed from the application cache. Preflight errors distinguish a connection timeout from changed targets and invalid responses, while retaining the draft. Delivery uses a caller-generated RPC ID and queue mode. An accepted response is distinct from a completed model turn. Completion requires the exact user RPC ID, matching turn boundaries, and a final assistant message. The card shows the matching reply preview; detail provides full bounded history. Explicit plugin and skill-catalog context messages are excluded from user history and attribution checks; other competing user messages remain ambiguous. A transport failure never triggers an automatic resend.

Card discovery uses the lean `dsh-web running` endpoint roster without reading runtime or profile package metadata. Full management catalog scans are separate. History is bounded to 100 messages and rendering to the latest 30 text messages, each capped at 24,000 characters. No transcripts or credentials are written by the sender. Drafts and delivery state are in memory and are not restored after quitting Harvis Bar.

## Validation and native acceptance

Unit coverage includes exact routing, account changes during preflight, archived/child targets, explicit rejection, ambiguous transport delivery, duplicate prevention, exact completed-turn attribution, card completion without detail, idle polling suppression, polling throttling, changed endpoints, and draft isolation. Run the full Swift suite, including existing scope, grouping, composer keyboard, and CLI integration tests.

Native acceptance must use a dedicated harmless session. Close the detail panel, enter a unique marker request in that card's input, click its Send button, and verify that the card shows the reply. Independently verify exactly one new user RPC, the correct session and completed turn, an exact assistant marker, and no tool execution. Also exercise draft retention through search filtering and verify DSH inputs remain visible with Codex composers hidden. API-only delivery or clicking Send inside the detail does not satisfy this gate. Keep runtime evidence outside the repository.

Retain a verified previous application bundle for rollback. Replace only HarvisBar.app; do not restart or modify the DSH Host, other Harvis applications, or account data.
