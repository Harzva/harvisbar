import Foundation
import XCTest
@testable import HarvisBar

final class ManagedSupervisorSettingsDraftTests: XCTestCase {
    func testInitialDraftUsesReadBackSettingsIncludingClosedModeAndRoundCount() throws {
        let state = try state(mode: "off", rounds: 3, intervalMs: 60_000)
        let draft = ManagedSupervisorSettingsDraft(state: state, identity: "dsh::fixture::session")

        XCTAssertEqual(draft.identity, "dsh::fixture::session")
        XCTAssertEqual(draft.mode, "off")
        XCTAssertEqual(draft.strategy, "plan")
        XCTAssertEqual(draft.rounds, 3)
        XCTAssertEqual(draft.intervalMs, 60_000)
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.patch())
    }

    func testSameRevisionDifferentSessionResetsDraftAndIdentity() throws {
        let first = try state(sessionID: "first", rounds: 3, revisionCharacter: "a")
        let second = try state(sessionID: "second", rounds: 9, revisionCharacter: "a")
        var draft = ManagedSupervisorSettingsDraft(state: first, identity: "card-first")
        draft.setRounds(4)

        draft.observe(second, identity: "card-second")

        XCTAssertEqual(draft.identity, "card-second")
        XCTAssertEqual(draft.sessionID, "second")
        XCTAssertEqual(draft.rounds, 9)
        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.isConflicted)
    }

    func testDirtySettingsConflictOnlyWhenRemoteSettingChanges() throws {
        let initial = try state(rounds: 3, intervalMs: 2_500)
        var draft = ManagedSupervisorSettingsDraft(state: initial, identity: "card")
        draft.setMode("advice")

        var progressOnly = initial
        progressOnly = try state(rounds: 3, intervalMs: 2_500, used: 1, status: "working", revisionCharacter: "b")
        draft.observe(progressOnly, identity: "card")
        XCTAssertTrue(draft.isDirty)
        XCTAssertFalse(draft.isConflicted)
        XCTAssertEqual(draft.baseRevision, progressOnly.revision)

        let remoteSettingsChange = try state(rounds: 7, intervalMs: 2_500, used: 1, status: "working", revisionCharacter: "c")
        draft.observe(remoteSettingsChange, identity: "card")
        XCTAssertTrue(draft.isConflicted)
        XCTAssertTrue(draft.conflictFields.contains(.rounds))
        XCTAssertFalse(draft.canSubmit)
        XCTAssertNil(draft.patch())
    }

    func testMinimalPatchPreservesUneditedNonIntegralInterval() throws {
        let initial = try state(rounds: 3, intervalMs: 2_500)
        var draft = ManagedSupervisorSettingsDraft(state: initial, identity: "card")
        draft.setMode("advice")
        draft.setRounds(5)

        let patch = try XCTUnwrap(draft.patch())
        XCTAssertEqual(patch.mode, "advice")
        XCTAssertEqual(patch.rounds, 5)
        XCTAssertNil(patch.strategy)
        XCTAssertNil(patch.intervalMs)
    }

    func testSameSessionIDInAnotherSourceCannotInheritTheDraft() throws {
        let sourceState = try state(rounds: 3)
        var draft = ManagedSupervisorSettingsDraft(state: sourceState, identity: "dsh::home-a::session")
        draft.setRounds(7)
        draft.observe(sourceState, identity: "dsh::home-b::session")
        XCTAssertEqual(draft.identity, "dsh::home-b::session")
        XCTAssertEqual(draft.rounds, 3)
        XCTAssertFalse(draft.isDirty)
    }

    func testFailedSavePreservesDraftUntilReadbackMatchesTheRequestedSettings() throws {
        let initial = try state(rounds: 3)
        var draft = ManagedSupervisorSettingsDraft(state: initial, identity: "card")
        draft.setMode("advice")
        draft.observe(try state(rounds: 3, revisionCharacter: "b"), identity: "card")
        XCTAssertEqual(draft.patch()?.mode, "advice", "An unchanged provider must not erase a failed edit")

        draft.observe(try state(mode: "advice", rounds: 3, revisionCharacter: "c"), identity: "card")
        XCTAssertFalse(draft.isDirty, "Readback can reconcile an already applied edit without another write")
        XCTAssertFalse(draft.isConflicted)
        XCTAssertNil(draft.patch())
    }

    func testUseLatestClearsConflictAndSubmissionSuccessClearsDirtyState() throws {
        let initial = try state(rounds: 3)
        var draft = ManagedSupervisorSettingsDraft(state: initial, identity: "card")
        draft.setMode("advice")
        let changed = try state(mode: "takeover", rounds: 3, revisionCharacter: "b")
        draft.observe(changed, identity: "card")
        XCTAssertTrue(draft.isConflicted)

        draft.useLatestSettings(changed)
        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.isConflicted)
        XCTAssertEqual(draft.mode, "takeover")

        draft.setRounds(6)
        XCTAssertTrue(draft.isDirty)
        let saved = try state(mode: "takeover", rounds: 6, revisionCharacter: "c")
        draft.markSubmissionSucceeded(with: saved)
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.patch())
        XCTAssertEqual(draft.baseRevision, saved.revision)
    }

    private func state(
        sessionID: String = "session",
        mode: String = "off",
        strategy: String = "plan",
        rounds: Int = 3,
        intervalMs: Int = 60_000,
        used: Int = 0,
        status: String = "off",
        revisionCharacter: String = "a"
    ) throws -> DshSupervisorState {
        let object: [String: Any] = [
            "schemaVersion": "harvis.dsh-supervisor.v1",
            "sessionId": sessionID,
            "revision": "sha256:" + String(repeating: revisionCharacter, count: 64),
            "mode": mode,
            "strategy": strategy,
            "rounds": rounds,
            "used": used,
            "remaining": max(0, rounds - used),
            "intervalMs": intervalMs,
            "status": status,
            "suggestion": "",
            "suggestionId": "",
            "runId": "run",
            "recoveryRequired": "",
            "done": false,
            "agentStatus": "idle",
            "mentorName": "",
            "suggestError": "",
        ]
        return try JSONDecoder().decode(
            DshSupervisorState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
