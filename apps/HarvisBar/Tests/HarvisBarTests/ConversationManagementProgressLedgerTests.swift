import Foundation
import XCTest
@testable import HarvisBar

final class ConversationManagementProgressLedgerTests: XCTestCase {
    func testPlanningAndDeliveryUseExactCASAndPreallocatedCommandID() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-1",
            expectedRevision: 0,
            at: date(1)
        )
        XCTAssertEqual(ledger.revision, 1)
        XCTAssertEqual(ledger.currentState.management, .planning)
        XCTAssertThrowsError(
            try ledger.startPlanning(
                metaSessionID: "meta-session",
                planningRPCID: "rpc-stale",
                expectedRevision: 0
            )
        )

        let snapshot = makeSnapshot()
        let decision = dispatchDecision()
        let proposal = makeProposal(
            ledger: ledger,
            snapshot: snapshot,
            decision: decision
        )
        try ledger.accept(
            proposal: proposal,
            snapshot: snapshot,
            policy: policy(),
            expectedRevision: 1,
            at: date(2)
        )
        XCTAssertEqual(ledger.cycle, 1)
        XCTAssertEqual(ledger.currentState.management, .awaitingPreview)

        let commandID = UUID()
        try ledger.recordDelivery(
            decisionID: decision.id,
            target: target,
            commandID: commandID,
            delivery: .dispatching,
            evidence: snapshot.conversations[0].base.evidence,
            expectedRevision: 2,
            at: date(3)
        )

        XCTAssertEqual(ledger.currentState.delivery, .dispatching)
        XCTAssertEqual(ledger.currentState.management, .dispatching)
        XCTAssertEqual(ledger.dispatchMemory.count, 1)
        XCTAssertEqual(ledger.dispatchMemory[0].commandID, commandID)
        XCTAssertEqual(ledger.dispatchMemory[0].evidenceRevision, 1)
        XCTAssertEqual(ledger.entries.map(\.revision), [1, 2, 3])
    }

    func testPlanningResponseLossBecomesTerminalDeliveryUnknown() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-lost",
            expectedRevision: 0
        )
        try ledger.recordPlanningFailure(
            delivery: .deliveryUnknown,
            expectedRevision: 1,
            note: "session.prompt response was lost"
        )

        XCTAssertEqual(ledger.currentState.delivery, .deliveryUnknown)
        XCTAssertEqual(ledger.currentState.management, .deliveryUnknown)
        XCTAssertEqual(ledger.entries.last?.kind, .planningFailed)
        XCTAssertEqual(ledger.entries.last?.planningRPCID, "rpc-lost")
        XCTAssertThrowsError(
            try ledger.startPlanning(
                metaSessionID: "meta-session",
                planningRPCID: "rpc-retry",
                expectedRevision: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .terminalLedger
            )
        }
    }

    func testRestartRecoveryIsFailClosedAndIdempotent() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-1",
            expectedRevision: 0,
            at: date(1)
        )

        XCTAssertTrue(ledger.recoverAfterRestart(at: date(2)))
        XCTAssertEqual(ledger.currentState.delivery, .deliveryUnknown)
        XCTAssertEqual(ledger.currentState.management, .deliveryUnknown)
        XCTAssertEqual(ledger.entries.last?.kind, .recovered)
        XCTAssertTrue(ledger.entries.last?.note?.contains("not replayed") == true)
        XCTAssertFalse(ledger.recoverAfterRestart(at: date(3)))
        XCTAssertEqual(ledger.revision, 2)
    }

    func testRestartPreservesRecordedCodexCommandForExactReconciliation() throws {
        var ledger = makeLedger()
        let snapshot = makeSnapshot()
        let decision = dispatchDecision()
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-recorded",
            expectedRevision: 0,
            at: date(1)
        )
        try ledger.accept(
            proposal: makeProposal(
                ledger: ledger,
                snapshot: snapshot,
                decision: decision
            ),
            snapshot: snapshot,
            policy: policy(),
            expectedRevision: 1,
            at: date(2)
        )
        try ledger.recordDelivery(
            decisionID: decision.id,
            target: target,
            commandID: UUID(),
            delivery: .dispatching,
            evidence: snapshot.conversations[0].base.evidence,
            expectedRevision: 2,
            at: date(3)
        )

        XCTAssertFalse(ledger.recoverAfterRestart(at: date(4)))
        XCTAssertEqual(ledger.currentState.delivery, .dispatching)
        XCTAssertEqual(ledger.currentState.management, .dispatching)
        XCTAssertEqual(ledger.revision, 3)
    }

    func testDecisionIDCannotBeReusedAcrossCyclesEvenWithNewEvidence() throws {
        var ledger = makeLedger()
        let firstSnapshot = makeSnapshot()
        let decision = dispatchDecision()
        let commandID = UUID()

        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-cycle-1",
            expectedRevision: 0
        )
        try ledger.accept(
            proposal: makeProposal(
                ledger: ledger,
                snapshot: firstSnapshot,
                decision: decision
            ),
            snapshot: firstSnapshot,
            policy: policy(),
            expectedRevision: 1
        )
        try ledger.recordDelivery(
            decisionID: decision.id,
            target: target,
            commandID: commandID,
            delivery: .dispatching,
            evidence: firstSnapshot.conversations[0].base.evidence,
            expectedRevision: 2
        )
        try ledger.recordDelivery(
            decisionID: decision.id,
            target: target,
            commandID: commandID,
            delivery: .completed,
            evidence: firstSnapshot.conversations[0].base.evidence,
            expectedRevision: 3
        )
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-cycle-2",
            expectedRevision: 4
        )

        let newerSnapshot = makeSnapshot(evidenceRevision: 2)
        let reused = ConversationManagementProposalV1(
            runID: ledger.runID,
            projectID: ledger.projectID,
            expectedRevision: ledger.revision,
            projectionRevision: newerSnapshot.revision,
            cycle: 2,
            summary: "New evidence exists, but identifiers remain single-use",
            decisions: [decision]
        )
        XCTAssertThrowsError(
            try ledger.accept(
                proposal: reused,
                snapshot: newerSnapshot,
                policy: policy(),
                expectedRevision: 5
            )
        ) { error in
            guard case let .invalidDecision(id, reason) =
                error as? ConversationManagementSchemaErrorV1 else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, decision.id)
            XCTAssertTrue(reason.contains("unique across management cycles"))
        }
    }

    func testDeliveryCannotSkipDurableDispatchingState() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-1",
            expectedRevision: 0
        )
        let snapshot = makeSnapshot()
        let decision = dispatchDecision()
        try ledger.accept(
            proposal: makeProposal(
                ledger: ledger,
                snapshot: snapshot,
                decision: decision
            ),
            snapshot: snapshot,
            policy: policy(),
            expectedRevision: 1
        )

        XCTAssertThrowsError(
            try ledger.recordDelivery(
                decisionID: decision.id,
                target: target,
                commandID: UUID(),
                delivery: .running,
                expectedRevision: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .invalidTransition(from: "none", to: "running")
            )
        }
    }

    func testPauseResumeAndCancelPreservePreviewAndUseCAS() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-1",
            expectedRevision: 0
        )
        let snapshot = makeSnapshot()
        let decision = dispatchDecision()
        try ledger.accept(
            proposal: makeProposal(
                ledger: ledger,
                snapshot: snapshot,
                decision: decision
            ),
            snapshot: snapshot,
            policy: policy(),
            expectedRevision: 1
        )

        try ledger.pause(expectedRevision: 2, note: "User paused preview")
        XCTAssertEqual(ledger.currentState.management, .paused)
        XCTAssertEqual(ledger.entries.last?.kind, .paused)
        XCTAssertThrowsError(try ledger.resume(expectedRevision: 2))

        try ledger.resume(expectedRevision: 3, note: "User resumed")
        XCTAssertEqual(ledger.currentState.management, .awaitingPreview)
        XCTAssertEqual(ledger.entries.last?.kind, .resumed)

        try ledger.cancel(expectedRevision: 4, note: "User cancelled run")
        XCTAssertEqual(ledger.currentState.delivery, .cancelled)
        XCTAssertEqual(ledger.currentState.management, .cancelled)
        XCTAssertEqual(ledger.entries.last?.kind, .cancelled)
        XCTAssertThrowsError(try ledger.pause(expectedRevision: 5)) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .terminalLedger
            )
        }
    }

    private let target = ConversationManagementTargetV1(
        provider: "codex",
        sourceScope: "persistedSubagent",
        sourceID: "thread-1"
    )

    private func makeLedger() -> ConversationManagementProgressLedgerV1 {
        ConversationManagementProgressLedgerV1(
            runID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            projectID: "project-1",
            objective: "Finish the bounded task",
            createdAt: date(0)
        )
    }

    private func makeSnapshot(
        evidenceRevision: Int = 1
    ) -> ConversationManagementSnapshotV1 {
        let evidence = ConversationEvidenceProjectionV1(
            revision: evidenceRevision,
            status: .fresh,
            fingerprint: "evidence-\(evidenceRevision)",
            summary: "Current test status",
            observedAt: date(0)
        )
        return ConversationManagementSnapshotV1(
            projectID: "project-1",
            brainEnabled: true,
            projectDefaultEnrollmentEnabled: true,
            taskPlan: ConversationProjectTaskPlanProjectionV1(
                sourceRevision: "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                freshness: .fresh,
                isValid: true,
                observedAt: date(0),
                tasks: [
                    ConversationProjectTaskV1(
                        taskID: "task-1",
                        title: "Run focused test",
                        owner: "test-owner",
                        status: .inProgress,
                        updatedAt: date(0)
                    ),
                ]
            ),
            generatedAt: date(0),
            conversations: [
                ConversationManagementRecordV1(
                    base: ConversationManagementBaseProjectionV1(
                        target: target,
                        projectID: "project-1",
                        title: "Worker",
                        role: "persistedSubagent",
                        observedAt: date(0),
                        runtime: .idle,
                        progress: .unknown,
                        evidence: evidence
                    ),
                    managementExtension: ConversationManagementExtensionV1(
                        target: target,
                        enrollment: .inherit,
                        workKind: .task,
                        taskBindings: [
                            ConversationTaskBindingV1(
                                taskID: "task-1",
                                projectID: "project-1",
                                target: target,
                                boundAt: date(0)
                            ),
                        ],
                        management: .observing,
                        updatedAt: date(0)
                    )
                ),
            ]
        )
    }

    private func dispatchDecision() -> ConversationManagementDecisionV1 {
        ConversationManagementDecisionV1(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            kind: .dispatch,
            target: target,
            taskID: "task-1",
            prompt: "Run the focused test and report its evidence",
            reason: "The result determines the next bounded action",
            expectedEvidence: "Test command and result"
        )
    }

    private func makeProposal(
        ledger: ConversationManagementProgressLedgerV1,
        snapshot: ConversationManagementSnapshotV1,
        decision: ConversationManagementDecisionV1
    ) -> ConversationManagementProposalV1 {
        ConversationManagementProposalV1(
            runID: ledger.runID,
            projectID: ledger.projectID,
            expectedRevision: ledger.revision,
            projectionRevision: snapshot.revision,
            cycle: ledger.cycle + 1,
            summary: "Collect one new piece of evidence",
            decisions: [decision]
        )
    }

    private func policy() -> ConversationManagementValidationPolicyV1 {
        ConversationManagementValidationPolicyV1(allowedTargets: [target])
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
}
