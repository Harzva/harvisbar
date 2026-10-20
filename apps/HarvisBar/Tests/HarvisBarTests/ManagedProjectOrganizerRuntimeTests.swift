import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedProjectOrganizerRuntimeTests: XCTestCase {
    private let draftKey = "harvisBar.projectOrganizerDraft.v1"
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testPreparingAndSavingReviewDraftNeverChangesProjectState() throws {
        try withModel { model, defaults in
            let source = thread("one")
            model.dshThreads = [source]
            model.prepareProjectOrganizer(threads: [source, source])
            XCTAssertEqual(model.projectOrganizerScopeConversationIDs, [source.id])
            XCTAssertFalse(model.projectOrganizerIsAnalyzing)
            XCTAssertNil(model.projectOrganizerTask)
            XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))

            let proposal = emptyChildProposal(model)
            model.projectOrganizerProposal = proposal
            model.persistProjectOrganizerDraft()
            XCTAssertEqual(model.managedProjectOrganization, .init())
            XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))
            XCTAssertNotNil(defaults.data(forKey: draftKey))

            let restored = HarvisRuntimeModel(defaults: defaults)
            restored.restoreProjectOrganizerDraft()
            XCTAssertEqual(restored.projectOrganizerProposal, proposal)
            XCTAssertEqual(restored.managedProjectOrganization, .init())
        }
    }

    func testReviewedEmptyChildAppliesPersistsAndUndoesWithoutFilesystemCreation() async throws {
        try await withAsyncModel { model, defaults in
            model.dshThreads = [thread("source")]
            let proposal = emptyChildProposal(model)
            let suggestion = try XCTUnwrap(proposal.suggestions.first)
            let child = try XCTUnwrap(suggestion.proposedProject)
            model.projectOrganizerProposal = proposal
            model.persistProjectOrganizerDraft()
            model.applyProjectOrganizerSelection([suggestion.id])
            await model.projectOrganizerTask?.value

            XCTAssertNil(model.projectOrganizerError)
            XCTAssertFalse(model.projectOrganizerIsApplying)
            XCTAssertEqual(model.managedProjectOrganization.projects[child.id]?.name, child.name)
            XCTAssertNil(model.managedProjectOrganization.projects[child.id]?.path)
            XCTAssertTrue(model.managedProjectOrganization.assignments.isEmpty)
            XCTAssertEqual(model.lastProjectOrganizationReceipt?.createdProjectCount, 1)
            XCTAssertNil(defaults.data(forKey: draftKey))
            let restored = try ManagedProjectOrganizationStore(defaults: defaults).load()
            XCTAssertNotNil(restored.projects[child.id])
            XCTAssertEqual(restored.history.first?.id, proposal.id)

            model.undoLastProjectOrganization()
            XCTAssertTrue(model.managedProjectOrganization.projects.isEmpty)
            XCTAssertTrue(model.managedProjectOrganization.assignments.isEmpty)
            XCTAssertTrue(try XCTUnwrap(model.managedProjectOrganization.history.first).isUndone)
            XCTAssertNil(model.lastProjectOrganizationReceipt)
            XCTAssertTrue(try ManagedProjectOrganizationStore(defaults: defaults).load().projects.isEmpty)
            XCTAssertEqual(model.managedChatThreads.first?.cwd, thread("source").cwd)
        }
    }

    func testCancellingBeforeApplyTaskStartsPreventsLateCommit() async throws {
        try await withAsyncModel { model, defaults in
            model.dshThreads = [thread("source")]
            let proposal = emptyChildProposal(model)
            model.projectOrganizerProposal = proposal
            model.applyProjectOrganizerSelection(proposal.suggestions.map(\.id))
            let pending = model.projectOrganizerTask
            model.cancelProjectOrganizerAnalysis()
            await pending?.value

            XCTAssertEqual(model.managedProjectOrganization, .init())
            XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))
            XCTAssertNil(model.projectOrganizerGeneration)
            XCTAssertFalse(model.projectOrganizerIsApplying)
            XCTAssertFalse(model.projectOrganizerIsAnalyzing)
            XCTAssertNotNil(model.projectOrganizerProposal)
        }
    }

    func testChangedCatalogRejectsWholeReviewedBatch() async throws {
        try await withAsyncModel { model, defaults in
            model.dshThreads = [thread("source")]
            let proposal = emptyChildProposal(model)
            model.projectOrganizerProposal = proposal
            model.dshThreads.append(thread("new-project", cwd: "/synthetic/harvis-organizer-runtime/elsewhere"))
            model.applyProjectOrganizerSelection(proposal.suggestions.map(\.id))
            await model.projectOrganizerTask?.value

            XCTAssertNotNil(model.projectOrganizerError)
            XCTAssertEqual(model.managedProjectOrganization, .init())
            XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))
            XCTAssertNotNil(model.projectOrganizerProposal)
        }
    }

    func testKeepCannotBePromotedToAnActionBySelectionIDs() async throws {
        try await withAsyncModel { model, defaults in
            let source = thread("one")
            model.dshThreads = [source]
            let keep = ManagedProjectOrganizerSuggestion(
                action: .keep, conversationIDs: [source.id], reason: "Cross-project coordination"
            )
            let proposal = reviewedProposal(model, snapshots: [model.projectOrganizationSnapshot(source, inputRevision: nil)],
                                            suggestions: [keep])
            model.projectOrganizerProposal = proposal
            model.applyProjectOrganizerSelection([keep.id])
            await model.projectOrganizerTask?.value

            XCTAssertNotNil(model.projectOrganizerError)
            XCTAssertEqual(model.managedProjectOrganization, .init())
            XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))
        }
    }

    func testUninspectedProviderCannotBeAppliedEvenWithAHandEditedSuggestion() async throws {
        try await withAsyncModel { model, defaults in
            let source = thread("one")
            model.dshThreads = [source]
            let assignment = ManagedProjectOrganizerSuggestion(
                action: .assign, conversationIDs: [source.id],
                targetProjectID: ManagedChatProjectResolver.resolveSource(thread: source).id,
                reason: "Edited review item"
            )
            model.projectOrganizerProposal = reviewedProposal(
                model, snapshots: [model.projectOrganizationSnapshot(source, inputRevision: nil)], suggestions: [assignment]
            )
            model.applyProjectOrganizerSelection([assignment.id])
            await model.projectOrganizerTask?.value

            XCTAssertNotNil(model.projectOrganizerError)
            XCTAssertTrue(model.managedProjectOrganization.assignments.isEmpty)
            XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))
        }
    }

    func testAlreadyLoadingInputCannotReuseOldAuthorityStampOrRetainRawRows() async throws {
        try await withAsyncModel { model, defaults in
            let source = try installCodexFixture(on: model)
            let key = model.managedChatStorageKey(source)
            model.managedConversationInputStates[key] = inputState(for: source, key: key, isLoading: true)
            model.managedConversationInputLoadGenerations[key] = 9
            let assignment = ManagedProjectOrganizerSuggestion(
                action: .assign, conversationIDs: [source.id],
                targetProjectID: ManagedChatProjectResolver.resolveSource(thread: source).id,
                reason: "Confirmed existing goal"
            )
            model.projectOrganizerProposal = reviewedProposal(
                model, snapshots: [model.projectOrganizationSnapshot(source, inputRevision: "fixture-input-revision")],
                suggestions: [assignment]
            )
            model.applyProjectOrganizerSelection([assignment.id])
            await model.projectOrganizerTask?.value

            // refreshConversationInputs returns early for this synthetic pending
            // load, so this test never launches a real provider process.
            XCTAssertNotNil(model.projectOrganizerError)
            XCTAssertTrue(model.managedProjectOrganization.assignments.isEmpty)
            XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))
            XCTAssertTrue(model.conversationInputState(for: source).items.isEmpty)
            XCTAssertFalse(model.conversationInputState(for: source).isLoading)
            XCTAssertEqual(model.conversationInputState(for: source).sourceRevision, "fixture-input-revision")
        }
    }

    func testReadCompletionRequiresNewTimestampExactGenerationAndSameSourceKey() throws {
        try withModel { model, _ in
            let source = thread("one")
            let key = model.managedChatStorageKey(source)
            model.managedConversationInputStates[key] = inputState(for: source, key: key)
            model.managedConversationInputLoadGenerations[key] = 9
            let stamp = model.projectOrganizerInputReadStamp(for: source)
            XCTAssertFalse(model.projectOrganizerInputReadCompleted(for: source, after: stamp))

            model.managedConversationInputLoadGenerations[key] = 10
            XCTAssertFalse(model.projectOrganizerInputReadCompleted(for: source, after: stamp))
            model.managedConversationInputStates[key]?.loadedAt = fixedDate.addingTimeInterval(1)
            XCTAssertTrue(model.projectOrganizerInputReadCompleted(for: source, after: stamp))
            model.managedConversationInputStates[key]?.isLoading = true
            XCTAssertFalse(model.projectOrganizerInputReadCompleted(for: source, after: stamp))
            model.managedConversationInputStates[key]?.isLoading = false
            model.managedConversationInputLoadGenerations[key] = 11
            XCTAssertFalse(model.projectOrganizerInputReadCompleted(for: source, after: stamp))
            XCTAssertFalse(model.projectOrganizerInputReadCompleted(for: thread("one", scope: "different-account"), after: stamp))
        }
    }

    func testSnapshotFingerprintBindsInputAccountHomeAndQuotaIdentity() throws {
        try withModel { model, _ in
            let source = try installCodexFixture(on: model)
            let original = model.projectOrganizationSnapshot(source, inputRevision: "input-a")
            XCTAssertNotEqual(original.sourceRevision, model.projectOrganizationSnapshot(source, inputRevision: "input-b").sourceRevision)

            model.codexHomes = [try home(path: "/synthetic/harvis-organizer-runtime/other-home")]
            let relocated = model.projectOrganizationSnapshot(source, inputRevision: "input-a")
            XCTAssertEqual(original.id, relocated.id)
            XCTAssertEqual(original.storageKey, relocated.storageKey)
            XCTAssertNotEqual(original.sourceRevision, relocated.sourceRevision)

            model.codexHomes = [try home(email: "different@example.invalid")]
            XCTAssertNotEqual(original.sourceRevision, model.projectOrganizationSnapshot(source, inputRevision: "input-a").sourceRevision)
            model.codexHomes = [try home(quotaMode: "subscription-b")]
            XCTAssertNotEqual(original.sourceRevision, model.projectOrganizationSnapshot(source, inputRevision: "input-a").sourceRevision)

            let otherScope = thread("same-id", scope: "other-scope")
            let firstScope = thread("same-id")
            XCTAssertNotEqual(model.projectOrganizationSnapshot(firstScope, inputRevision: nil).storageKey,
                              model.projectOrganizationSnapshot(otherScope, inputRevision: nil).storageKey)
        }
    }

    func testUndoPreservesUnrelatedLaterAssignmentAndRestoresSourceGrouping() throws {
        try withModel { model, defaults in
            let source = thread("one")
            let unrelated = thread("unrelated")
            let destination = thread("destination", cwd: "/synthetic/harvis-organizer-runtime/destination")
            model.dshThreads = [source, unrelated, destination]
            let target = ManagedChatProjectResolver.resolveSource(thread: destination)
            let snapshot = model.projectOrganizationSnapshot(source, inputRevision: "fixture")
            let suggestion = ManagedProjectOrganizerSuggestion(
                action: .assign, conversationIDs: [source.id], targetProjectID: target.id,
                reason: "Reviewed fixture", isSelected: true
            )
            let proposal = reviewedProposal(model, snapshots: [snapshot], suggestions: [suggestion])
            let applied = try ManagedProjectOrganizationEngine.apply(
                state: model.managedProjectOrganization, proposal: proposal, currentSnapshots: [snapshot],
                currentCatalog: model.managedChatProjectCatalog, now: fixedDate
            )
            XCTAssertTrue(model.persistProjectOrganization(applied.state))
            XCTAssertTrue(model.assignConversation(unrelated, to: target, source: .manual, at: fixedDate.addingTimeInterval(1)))
            model.undoLastProjectOrganization()

            XCTAssertNil(model.projectOrganizerError)
            XCTAssertNil(model.projectAssignment(for: source))
            XCTAssertEqual(model.projectAssignment(for: unrelated)?.project.id, target.id)
            XCTAssertEqual(model.managedChatThreads.first { $0.id == source.id }?.cwd, source.cwd)
            let stored = try ManagedProjectOrganizationStore(defaults: defaults).load()
            XCTAssertNil(stored.assignments[model.managedChatStorageKey(source)])
            XCTAssertNotNil(stored.assignments[model.managedChatStorageKey(unrelated)])
        }
    }

    func testUndoConflictDoesNotOverwriteLaterManualReview() throws {
        try withModel { model, defaults in
            let source = thread("one")
            let destination = thread("destination", cwd: "/synthetic/harvis-organizer-runtime/destination")
            model.dshThreads = [source, destination]
            let snapshot = model.projectOrganizationSnapshot(source, inputRevision: "fixture")
            let target = ManagedChatProjectResolver.resolveSource(thread: destination)
            let suggestion = ManagedProjectOrganizerSuggestion(
                action: .assign, conversationIDs: [source.id], targetProjectID: target.id,
                reason: "Reviewed fixture", isSelected: true
            )
            let applied = try ManagedProjectOrganizationEngine.apply(
                state: model.managedProjectOrganization,
                proposal: reviewedProposal(model, snapshots: [snapshot], suggestions: [suggestion]),
                currentSnapshots: [snapshot], currentCatalog: model.managedChatProjectCatalog, now: fixedDate
            )
            XCTAssertTrue(model.persistProjectOrganization(applied.state))
            XCTAssertTrue(model.assignConversation(source, to: target, source: .manual, at: fixedDate.addingTimeInterval(1)))
            let before = model.managedProjectOrganization
            let storedBefore = defaults.data(forKey: ManagedProjectOrganizationStore.storageKey)
            model.undoLastProjectOrganization()

            XCTAssertNotNil(model.projectOrganizerError)
            XCTAssertEqual(model.managedProjectOrganization, before)
            XCTAssertEqual(defaults.data(forKey: ManagedProjectOrganizationStore.storageKey), storedBefore)
        }
    }

    func testCorruptStateDisablesWritesAndPreservesStoredBytes() throws {
        try withModel { _, defaults in
            let corrupt = Data("invalid-project-envelope".utf8)
            defaults.set(corrupt, forKey: ManagedProjectOrganizationStore.storageKey)
            let restored = HarvisRuntimeModel(defaults: defaults)
            XCTAssertNotNil(restored.projectOrganizationLoadError)
            XCTAssertFalse(restored.persistProjectOrganization(.init()))
            XCTAssertEqual(defaults.data(forKey: ManagedProjectOrganizationStore.storageKey), corrupt)
            XCTAssertEqual(restored.managedProjectOrganization, .init())
        }
    }

    private func emptyChildProposal(_ model: HarvisRuntimeModel) -> ManagedProjectOrganizerProposal {
        let parent = model.managedChatProjectCatalog[0]
        let child = ManagedProjectRecord(
            name: "Reviewed empty child", purpose: "A separate planned deliverable",
            parentID: parent.id, createdAt: fixedDate
        )
        return reviewedProposal(model, snapshots: [], suggestions: [
            ManagedProjectOrganizerSuggestion(action: .createSubproject, conversationIDs: [], proposedProject: child,
                                              reason: "Human can create the project before choosing its conversations"),
        ])
    }

    private func reviewedProposal(
        _ model: HarvisRuntimeModel,
        snapshots: [ManagedProjectOrganizationConversation],
        suggestions: [ManagedProjectOrganizerSuggestion]
    ) -> ManagedProjectOrganizerProposal {
        ManagedProjectOrganizerProposal(
            createdAt: fixedDate, baseStateRevision: model.managedProjectOrganization.revision,
            catalogFingerprint: ManagedProjectOrganizationEngine.catalogFingerprint(model.managedChatProjectCatalog),
            snapshots: snapshots, suggestions: suggestions
        )
    }

    private func inputState(
        for thread: ManagedChatThread, key: String, isLoading: Bool = false
    ) -> ManagedConversationUserInputState {
        ManagedConversationUserInputState(
            targetKey: key, provider: thread.provider, sourceAvailable: true, sourceRevision: "fixture-input-revision",
            items: [ManagedConversationUserInput(id: "fixture-input", sequence: 1, turnID: nil, timestamp: nil,
                                                 text: "Synthetic user input", originalCharacterCount: 20,
                                                 truncated: false, source: .human)],
            totalCount: 1, isLoading: isLoading, loadedAt: fixedDate, threadUpdatedAtAtLoad: thread.updatedAt
        )
    }

    private func installCodexFixture(on model: HarvisRuntimeModel) throws -> ManagedChatThread {
        model.codexHomes = [try home()]
        let summary = try JSONDecoder().decode(CodexThreadSummary.self, from: JSONSerialization.data(withJSONObject: [
            "id": "fixture-thread", "title": "Fixture conversation", "hasMeaningfulTitle": true,
            "createdAt": 1_700_000_000, "updatedAt": 1_700_000_100, "tokensUsed": 0,
            "cwd": "/synthetic/harvis-organizer-runtime/source", "archived": false, "running": false,
        ]))
        model.acceptCodexThreads([summary], sourceHomeID: "fixture-home")
        return try XCTUnwrap(model.managedChatThreads.first)
    }

    private func home(
        path: String = "/synthetic/harvis-organizer-runtime/home",
        email: String = "fixture@example.invalid", quotaMode: String = "subscription-a"
    ) throws -> CodexHome {
        try JSONDecoder().decode(CodexHome.self, from: JSONSerialization.data(withJSONObject: [
            "id": "fixture-home", "label": "Fixture", "path": path, "source": "default",
            "hasAuth": true, "accountEmail": email, "hasConfig": false, "skillCount": 0,
            "quotaMode": quotaMode,
        ]))
    }

    private func thread(
        _ id: String, scope: String = "fixture-dsh-account",
        cwd: String = "/synthetic/harvis-organizer-runtime/source"
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: .dsh, sourceScope: scope, sourceID: id, title: id, titleSource: "fixture",
            hasMeaningfulTitle: true, createdAt: 1_700_000_000, updatedAt: 1_700_000_100,
            tokensUsed: 0, model: "fixture", cwd: cwd, archived: false, running: false,
            sourceStatus: "idle", threadSource: "fixture", agentNickname: nil, agentRole: nil,
            agentPath: nil, parentThreadID: nil, rootThreadId: "dsh::\(scope)::\(id)",
            isSubagent: false, isSidechat: false, activity: .init(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(state: .idle, reason: "Fixture")
        )
    }

    private func withModel(_ action: @MainActor (HarvisRuntimeModel, UserDefaults) throws -> Void) throws {
        let suite = "ManagedProjectOrganizerRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try action(HarvisRuntimeModel(defaults: defaults), defaults)
    }

    private func withAsyncModel(_ action: @MainActor (HarvisRuntimeModel, UserDefaults) async throws -> Void) async throws {
        let suite = "ManagedProjectOrganizerRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        defer { model.projectOrganizerTask?.cancel() }
        try await action(model, defaults)
    }
}
