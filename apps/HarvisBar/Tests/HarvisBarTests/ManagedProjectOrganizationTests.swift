import Foundation
import XCTest
@testable import HarvisBar

final class ManagedProjectOrganizationTests: XCTestCase {
    private let parent = ManagedChatProjectIdentity(
        id: "path::/workspace", canonicalPath: "/workspace", displayPath: "/workspace",
        label: "Workspace", resolution: .resolved
    )
    private let existing = ManagedChatProjectIdentity(
        id: "path::/workspace/existing", canonicalPath: "/workspace/existing",
        displayPath: "/workspace/existing", label: "Existing", resolution: .resolved
    )
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLogicalProjectsCanSharePathAndKeepDistinctIdentity() throws {
        let first = project("First")
        let second = project("Second")
        XCTAssertNotEqual(first.identity.id, second.identity.id)
        XCTAssertEqual(first.identity.canonicalPath, second.identity.canonicalPath)
        let snapshots = [conversation("one"), conversation("two")]
        let suggestions = [create(first, ids: [snapshots[0].id]), create(second, ids: [snapshots[1].id])]
        let result = try apply(proposal(snapshots, suggestions))
        XCTAssertEqual(result.state.projects.count, 2)
        XCTAssertEqual(result.state.assignments[snapshots[0].storageKey]?.project.id, first.id)
        XCTAssertEqual(result.state.assignments[snapshots[1].storageKey]?.project.id, second.id)
        XCTAssertEqual(snapshots[0].sourceProject, parent)
        XCTAssertEqual(result.receipt.createdProjectCount, 2)
    }

    func testNoSelectionAndKeepOnlyNeverMutateState() throws {
        let state = ManagedProjectOrganizationState()
        let snapshot = conversation("one")
        var suggestion = assign(snapshot.id)
        suggestion.isSelected = false
        let unreviewed = proposal([snapshot], [suggestion])
        XCTAssertThrowsError(try apply(unreviewed, state: state)) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .nothingSelected)
        }
        suggestion.action = .keep
        suggestion.isSelected = true
        XCTAssertThrowsError(try apply(proposal([snapshot], [suggestion]), state: state)) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .nothingSelected)
        }
        XCTAssertEqual(state, ManagedProjectOrganizationState())
    }

    func testOnlyReviewedSelectionIsApplied() throws {
        let snapshots = [conversation("one"), conversation("two")]
        var notSelected = create(project("Unselected"), ids: [snapshots[1].id])
        notSelected.isSelected = false
        let result = try apply(proposal(snapshots, [assign(snapshots[0].id), notSelected]))
        XCTAssertEqual(result.state.assignments.count, 1)
        XCTAssertNil(result.state.assignments[snapshots[1].storageKey])
        XCTAssertTrue(result.state.projects.isEmpty)
    }

    func testNewProjectDependencyMustAlsoBeSelected() throws {
        let snapshots = [conversation("one"), conversation("two")]
        let child = project("Child")
        var creation = create(child, ids: [snapshots[0].id])
        creation.isSelected = false
        let dependent = assign(snapshots[1].id, target: child.id)
        XCTAssertThrowsError(try apply(proposal(snapshots, [creation, dependent]))) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .missingProject(child.id))
        }
        creation.isSelected = true
        let result = try apply(proposal(snapshots, [creation, dependent]))
        XCTAssertEqual(result.state.projects.count, 1)
        XCTAssertEqual(result.state.assignments.count, 2)
    }

    func testNestedCreationCanBeReviewedInAnyOrder() throws {
        let snapshots = [conversation("one"), conversation("two")]
        let child = project("Child")
        var grandchild = project("Grandchild")
        grandchild.parentID = child.id
        let result = try apply(proposal(snapshots, [
            create(grandchild, ids: [snapshots[0].id]), create(child, ids: [snapshots[1].id]),
        ]))
        XCTAssertEqual(result.state.projects[grandchild.id]?.parentID, child.id)
    }

    func testIndependentCreationAllowsPerConversationReviewAndEmptyProject() throws {
        let snapshots = [conversation("one"), conversation("two")]
        let child = project("Child")
        let creation = create(child, ids: [])
        var cancelled = assign(snapshots[1].id, target: child.id)
        cancelled.isSelected = false
        let result = try apply(proposal(snapshots, [
            creation, assign(snapshots[0].id, target: child.id), cancelled,
        ]))
        XCTAssertEqual(result.receipt.createdProjectCount, 1)
        XCTAssertEqual(result.receipt.appliedConversationCount, 1)
        XCTAssertNil(result.state.assignments[snapshots[1].storageKey])

        let empty = try apply(proposal([], [create(child, ids: [])]))
        XCTAssertEqual(empty.receipt.createdProjectCount, 1)
        XCTAssertEqual(empty.receipt.appliedConversationCount, 0)
        let undone = try ManagedProjectOrganizationEngine.undo(state: empty.state, receiptID: empty.receipt.id)
        XCTAssertTrue(undone.state.projects.isEmpty)

        var invalidAssignment = assign(snapshots[0].id)
        invalidAssignment.conversationIDs = []
        XCTAssertThrowsError(try apply(proposal(snapshots, [invalidAssignment])))
    }

    func testCrossAccountConversationIDsStayIsolated() throws {
        let first = conversation("same-source-id", scope: "account-a")
        let second = conversation("same-source-id", scope: "account-b")
        let result = try apply(proposal([first, second], [assign(first.id)]))
        XCTAssertEqual(result.state.assignments[first.storageKey]?.project, existing)
        XCTAssertNil(result.state.assignments[second.storageKey])
    }

    func testFreshSourceRevisionAndIdentityAreRequired() throws {
        let original = conversation("one")
        let reviewed = proposal([original], [assign(original.id)])
        var changed = original
        changed.sourceRevision = "new-input-page-fingerprint"
        XCTAssertThrowsError(try apply(reviewed, current: [changed])) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .staleConversation(original.id))
        }
        changed = original
        changed.storageKey = "codex::different-home::one"
        XCTAssertThrowsError(try apply(reviewed, current: [changed]))
        changed = original
        changed.sourceProject = existing
        XCTAssertThrowsError(try apply(reviewed, current: [changed]))
    }

    func testLaterAssignmentOrCatalogChangeRejectsProposal() throws {
        let snapshot = conversation("one")
        let reviewed = proposal([snapshot], [assign(snapshot.id)])
        let state = ManagedProjectOrganizationState(revision: 1)
        XCTAssertThrowsError(try apply(reviewed, state: state)) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .staleState)
        }
        let staleAssignment = ManagedChatProjectAssignment(project: existing, source: .manual, assignedAt: now)
        let inconsistent = ManagedProjectOrganizationState(assignments: [snapshot.storageKey: staleAssignment])
        XCTAssertThrowsError(try apply(reviewed, state: inconsistent)) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .staleConversation(snapshot.id))
        }
        let changedCatalog = [parent, ManagedChatProjectIdentity(
            id: existing.id, canonicalPath: existing.canonicalPath,
            displayPath: existing.displayPath, label: "Renamed", resolution: .resolved
        )]
        XCTAssertThrowsError(try ManagedProjectOrganizationEngine.apply(
            state: .init(), proposal: reviewed, currentSnapshots: [snapshot], currentCatalog: changedCatalog
        )) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .staleCatalog)
        }
    }

    func testFailureIsAtomicWhenLaterSuggestionIsInvalid() throws {
        let snapshots = [conversation("one"), conversation("two")]
        let state = ManagedProjectOrganizationState()
        let reviewed = proposal(snapshots, [
            create(project("Valid"), ids: [snapshots[0].id]),
            assign(snapshots[1].id, target: "path::/missing"),
        ])
        XCTAssertThrowsError(try apply(reviewed, state: state))
        XCTAssertTrue(state.projects.isEmpty)
        XCTAssertTrue(state.assignments.isEmpty)
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertEqual(state.revision, 0)
    }

    func testDuplicateConversationAndStorageAliasAreRejected() throws {
        let snapshot = conversation("one")
        XCTAssertThrowsError(try apply(proposal([snapshot], [assign(snapshot.id), assign(snapshot.id)]))) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .conflictingConversation(snapshot.id))
        }
        var alias = conversation("two")
        alias.storageKey = snapshot.storageKey
        XCTAssertThrowsError(try apply(proposal([snapshot, alias], [assign(snapshot.id)])))
    }

    func testInvalidParentCycleAndTraversalPathAreRejected() throws {
        let snapshots = [conversation("one"), conversation("two")]
        var bad = project("Missing parent")
        bad.parentID = "path::/missing"
        XCTAssertThrowsError(try apply(proposal(snapshots, [create(bad, ids: [snapshots[0].id])])))
        bad = project("Traversal")
        bad.path = "/workspace/../elsewhere"
        XCTAssertThrowsError(try apply(proposal(snapshots, [create(bad, ids: [snapshots[0].id])])))
        var first = project("First")
        var second = project("Second")
        first.parentID = second.id
        second.parentID = first.id
        XCTAssertThrowsError(try apply(proposal(snapshots, [
            create(first, ids: [snapshots[0].id]), create(second, ids: [snapshots[1].id]),
        ])))
    }

    func testPathlessChildDoesNotRequireFilesystemAndUndoRestoresOriginalAssignment() throws {
        let previous = ManagedChatProjectAssignment(project: parent, source: .manual, assignedAt: now)
        var snapshot = conversation("one")
        snapshot.assignment = previous
        let initial = ManagedProjectOrganizationState(assignments: [snapshot.storageKey: previous])
        var child = project("Logical only")
        child.path = nil
        let result = try apply(proposal([snapshot], [create(child, ids: [snapshot.id])]), state: initial)
        XCTAssertNil(result.state.projects[child.id]?.identity.canonicalPath)
        XCTAssertEqual(result.state.projects[child.id]?.identity.displayPath, "未关联路径")
        let undone = try ManagedProjectOrganizationEngine.undo(
            state: result.state, receiptID: result.receipt.id, now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(undone.state.assignments, initial.assignments)
        XCTAssertTrue(undone.state.projects.isEmpty)
        XCTAssertTrue(undone.receipt.isUndone)
        XCTAssertEqual(undone.state.revision, 2)
    }

    func testUndoAllowsUnrelatedLaterChanges() throws {
        let snapshot = conversation("one")
        let result = try apply(proposal([snapshot], [assign(snapshot.id)]))
        var later = result.state
        later.revision += 1
        later.assignments["unrelated"] = ManagedChatProjectAssignment(
            project: parent, source: .manual, assignedAt: now.addingTimeInterval(20)
        )
        let undone = try ManagedProjectOrganizationEngine.undo(state: later, receiptID: result.receipt.id)
        XCTAssertNil(undone.state.assignments[snapshot.storageKey])
        XCTAssertEqual(undone.state.assignments["unrelated"], later.assignments["unrelated"])
    }

    func testUndoRejectsLaterEditsAndNewReferencesToCreatedProjects() throws {
        let snapshot = conversation("one")
        let child = project("Child")
        let result = try apply(proposal([snapshot], [create(child, ids: [snapshot.id])]))
        var modified = result.state
        modified.assignments[snapshot.storageKey] = ManagedChatProjectAssignment(
            project: parent, source: .manual, assignedAt: now.addingTimeInterval(1)
        )
        XCTAssertThrowsError(try ManagedProjectOrganizationEngine.undo(
            state: modified, receiptID: result.receipt.id
        )) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .undoConflict(snapshot.id))
        }
        modified = result.state
        modified.assignments["later-session"] = ManagedChatProjectAssignment(
            project: child.identity, source: .manual, assignedAt: now
        )
        XCTAssertThrowsError(try ManagedProjectOrganizationEngine.undo(state: modified, receiptID: result.receipt.id))
        modified = result.state
        var laterChild = project("Later child")
        laterChild.parentID = child.id
        modified.projects[laterChild.id] = laterChild
        XCTAssertThrowsError(try ManagedProjectOrganizationEngine.undo(state: modified, receiptID: result.receipt.id))
        modified = result.state
        modified.projects[child.id]?.purpose = "Updated after apply"
        XCTAssertThrowsError(try ManagedProjectOrganizationEngine.undo(state: modified, receiptID: result.receipt.id))
    }

    func testApplyAndUndoAreIdempotentAndUndoneProposalCannotReplay() throws {
        let snapshot = conversation("one")
        let reviewed = proposal([snapshot], [assign(snapshot.id)])
        let result = try apply(reviewed)
        let duplicate = try apply(reviewed, state: result.state)
        XCTAssertEqual(duplicate, result)
        var edited = reviewed
        edited.suggestions[0].reason = "Changed reviewed operation"
        XCTAssertThrowsError(try apply(edited, state: result.state)) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .duplicateOperationMismatch)
        }
        let undone = try ManagedProjectOrganizationEngine.undo(state: result.state, receiptID: result.receipt.id)
        let twice = try ManagedProjectOrganizationEngine.undo(state: undone.state, receiptID: result.receipt.id)
        XCTAssertEqual(twice, undone)
        XCTAssertThrowsError(try apply(reviewed, state: undone.state)) {
            XCTAssertEqual($0 as? ManagedProjectOrganizationError, .proposalAlreadyUndone)
        }
    }

    func testCatalogFingerprintIsOrderIndependentAndIdentitySensitive() {
        let fingerprint = ManagedProjectOrganizationEngine.catalogFingerprint([parent, existing])
        XCTAssertEqual(fingerprint, ManagedProjectOrganizationEngine.catalogFingerprint([existing, parent]))
        XCTAssertNotEqual(fingerprint, ManagedProjectOrganizationEngine.catalogFingerprint([parent]))
    }

    func testLegacyMigrationIsReadOnlyAndNeverOverridesNewEnvelope() throws {
        try withStore { store, defaults in
            let legacy = ["legacy": ManagedChatProjectAssignment(project: parent, source: .manual, assignedAt: now)]
            let migrated = try store.load(legacyAssignments: legacy)
            XCTAssertEqual(migrated.assignments, legacy)
            XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))
            try store.save(.init())
            XCTAssertTrue(try store.load(legacyAssignments: legacy).assignments.isEmpty)
        }
    }

    func testStoreRoundTripsCatalogAssignmentsAndUndoJournalInOneEnvelope() throws {
        try withStore { store, defaults in
            let snapshot = conversation("one")
            let result = try apply(proposal([snapshot], [create(project("Child"), ids: [snapshot.id])]))
            try store.save(result.state)
            XCTAssertEqual(try store.load(), result.state)
            let data = try XCTUnwrap(defaults.data(forKey: ManagedProjectOrganizationStore.storageKey))
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(decoded["schemaVersion"] as? Int, 1)
            XCTAssertNotNil(decoded["state"])
        }
    }

    func testCorruptUnsupportedAndWrongTypeStoresFailClosed() throws {
        try withStore { store, defaults in
            let key = ManagedProjectOrganizationStore.storageKey
            let broken = Data("broken-json".utf8)
            defaults.set(broken, forKey: key)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(defaults.data(forKey: key), broken)
            let future = Data("{\"schemaVersion\":2,\"state\":{}}".utf8)
            defaults.set(future, forKey: key)
            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? ManagedProjectOrganizationStoreError, .unsupportedVersion(2))
            }
            XCTAssertEqual(defaults.data(forKey: key), future)
            defaults.set("incorrect type", forKey: key)
            XCTAssertThrowsError(try store.load()) {
                XCTAssertEqual($0 as? ManagedProjectOrganizationStoreError, .invalidStoredType)
            }
            XCTAssertEqual(defaults.string(forKey: key), "incorrect type")
        }
    }

    func testFailedSavePreservesLastGoodEnvelope() throws {
        try withStore { store, defaults in
            try store.save(.init())
            let before = defaults.data(forKey: ManagedProjectOrganizationStore.storageKey)
            var invalid = project("Invalid date")
            invalid.createdAt = Date(timeIntervalSince1970: .infinity)
            XCTAssertThrowsError(try store.save(.init(projects: [invalid.id: invalid])))
            XCTAssertEqual(defaults.data(forKey: ManagedProjectOrganizationStore.storageKey), before)
        }
    }

    private func conversation(_ id: String, scope: String = "account-a") -> ManagedProjectOrganizationConversation {
        ManagedProjectOrganizationConversation(
            id: "codex::\(scope)::\(id)", storageKey: "codex::\(scope)::\(id)",
            sourceRevision: "\(scope)::revision-1::inputs-hash", sourceProject: parent,
            effectiveProject: parent, title: "Conversation \(id)", provider: "codex"
        )
    }

    private func project(_ name: String) -> ManagedProjectRecord {
        ManagedProjectRecord(name: name, purpose: "Independent goal for \(name)", parentID: parent.id, path: "/workspace")
    }

    private func create(_ project: ManagedProjectRecord, ids: [String]) -> ManagedProjectOrganizerSuggestion {
        ManagedProjectOrganizerSuggestion(
            action: .createSubproject, conversationIDs: ids, proposedProject: project,
            reason: "Independent deliverable", evidence: ["message-1"], isSelected: true
        )
    }

    private func assign(_ id: String, target: String? = nil) -> ManagedProjectOrganizerSuggestion {
        ManagedProjectOrganizerSuggestion(
            action: .assign, conversationIDs: [id], targetProjectID: target ?? existing.id,
            reason: "Matches the existing goal", evidence: ["message-1"], isSelected: true
        )
    }

    private func proposal(
        _ snapshots: [ManagedProjectOrganizationConversation], _ suggestions: [ManagedProjectOrganizerSuggestion]
    ) -> ManagedProjectOrganizerProposal {
        ManagedProjectOrganizerProposal(
            createdAt: now, baseStateRevision: 0,
            catalogFingerprint: ManagedProjectOrganizationEngine.catalogFingerprint([parent, existing]),
            snapshots: snapshots, suggestions: suggestions
        )
    }

    private func apply(
        _ proposal: ManagedProjectOrganizerProposal,
        state: ManagedProjectOrganizationState = .init(),
        current: [ManagedProjectOrganizationConversation]? = nil
    ) throws -> ManagedProjectOrganizationApplication {
        try ManagedProjectOrganizationEngine.apply(
            state: state, proposal: proposal, currentSnapshots: current ?? proposal.snapshots,
            currentCatalog: [parent, existing], now: now
        )
    }

    private func withStore(_ operation: (ManagedProjectOrganizationStore, UserDefaults) throws -> Void) throws {
        let suite = "ManagedProjectOrganizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(ManagedProjectOrganizationStore(defaults: defaults), defaults)
    }
}
