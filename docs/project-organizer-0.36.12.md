# Project paths and reviewed AI organization

HarvisBar 0.36.12 replaces vertical project headers in Matrix mode with a
folder/project grid. Entering a path shows its immediate children and its
directly assigned conversations. Breadcrumbs return to parent paths. List mode
retains its existing presentation.

Properties distinguish direct conversations from the deduplicated descendant
total, show the complete associated path and purpose, and count participating
sources. A source count does not establish project ownership. Statistics cover
loaded conversations within the active account, search and status filters;
they do not imply complete history or a filesystem inventory. Known unavailable
paths are marked for inspection. Unanalyzed content remains explicitly unknown;
folder count and hierarchy depth are not a health score.

## AI review workflow

1. Open **AI 整理** at the catalog root or within a path. This captures the
   selected scope and does not analyze or change project assignments.
2. **开始分析** reads necessary user-input excerpts from eligible Codex sources
   and sends a bounded, redacted request to the dedicated analysis service.
   Up to 100 conversations and 100 candidate projects are compared per batch;
   current project identities take priority when the catalog is larger.
3. Review each suggested assignment, new child project, or retained/uncertain
   conversation. Evidence references are resolved to the actual excerpts sent,
   not quotations supplied by the model. All changes initially remain unchecked.
   Names, purposes and existing associated paths can be edited before approval.
4. **应用所选** rereads selected conversations and checks account identity,
   source revision, current assignment, catalog and state revision. All checks
   finish before one catalog/assignment/history envelope is saved.
5. **撤销上次整理** restores the batch if affected values have not been changed
   since application. Unrelated later edits are preserved; conflicts stop undo.

Creating a project creates an independent logical identity. Associating a path
does not create a directory, move files, rewrite conversation logs, or change a
running session's cwd. A child can exist without conversations. Moving a
conversation into a proposed child requires selecting its creation and the
individual conversation assignment.

## Evidence and failure boundaries

Codex is the first supported user-input adapter. DSH and WorkBuddy remain
uninspected until their adapters can provide trustworthy user-only data. Unknown
user roles are explicitly labeled as unverified; manager and system messages are
excluded. Unavailable, omitted and excess conversations remain visible as
unconfirmed instead of receiving fabricated AI results.

The original single-conversation insight contract is unchanged. This separate
opt-in semantic analysis contract verifies the dedicated endpoint's exact
tool-free preset before creating a fresh analysis session and again before
submission. Failure never substitutes an unaudited endpoint or retries an
unknown delivery. The planner cannot write project state. Evidence and review
drafts remain in the existing private app preferences, outside public source.

The dedicated DSH profile can be started from the existing Runtime Catalog.
Its persistent server uses a separate process group so completing the launch
command does not trigger the bounded command runner's descendant cleanup.
The shared runner continues to clean up ordinary command descendants.

Legacy assignment preferences are read without writing during startup. The
versioned organization envelope becomes authoritative only after a user action.
Unknown or corrupt storage is preserved and blocks mutations. Closing review or
cancelling analysis does not apply assignments.

## References and verification

Reference checkouts are held separately from the application repository:
[BattleLab](https://github.com/teriansilva/agent-sessions) (AGPL-3.0-or-later),
[agentsview](https://github.com/kenn-io/agentsview) (MIT), and
[AgentHub](https://github.com/jamesrochabrun/AgentHub) (MIT). No source from these
repositories is embedded and no new runtime dependency is introduced.

Deterministic tests cover hierarchy, explicit identities, migration, stale
preconditions, batch atomicity, idempotency, undo conflicts, scope cancellation,
redaction, budgets, schema validation, evidence matching and tool-free service
attestation. An opt-in live gateway smoke uses synthetic conversations only.
Native acceptance exercises navigation, properties, review and cancellation;
real user conversation assignments are not changed by acceptance tests.
