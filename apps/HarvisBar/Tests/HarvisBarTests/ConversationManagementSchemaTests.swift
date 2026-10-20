import Foundation
import XCTest
@testable import HarvisBar

final class ConversationManagementSchemaTests: XCTestCase {
    func testEnrollmentResolvesThreeStatesWithoutPollutingBaseProjection() throws {
        XCTAssertFalse(
            ConversationManagementEnrollmentV1.inherit
                .resolves(projectDefaultEnabled: false)
        )
        XCTAssertTrue(
            ConversationManagementEnrollmentV1.inherit
                .resolves(projectDefaultEnabled: true)
        )
        XCTAssertTrue(
            ConversationManagementEnrollmentV1.enabled
                .resolves(projectDefaultEnabled: false)
        )
        XCTAssertFalse(
            ConversationManagementEnrollmentV1.excluded
                .resolves(projectDefaultEnabled: true)
        )

        let baseObject = try jsonObject(baseProjection())
        XCTAssertNil(baseObject["enrollment"])
        XCTAssertNil(baseObject["delivery"])
        XCTAssertNil(baseObject["management"])

        let extensionObject = try jsonObject(
            ConversationManagementExtensionV1(target: target())
        )
        XCTAssertNil(extensionObject["runtime"])
        XCTAssertNil(extensionObject["progress"])
        XCTAssertNil(extensionObject["evidence"])
    }

    func testEnrollmentMutationRequiresExactProjectionRevision() throws {
        var value = snapshot(projectDefaultEnabled: false)
        try value.setEnrollment(
            .enabled,
            for: target(),
            expectedRevision: 0,
            at: date(10)
        )

        XCTAssertEqual(value.revision, 1)
        XCTAssertTrue(
            value.record(for: target())?.isEnrolled(
                projectDefaultEnabled: value.projectDefaultEnrollmentEnabled
            ) == true
        )
        XCTAssertThrowsError(
            try value.setEnrollment(
                .excluded,
                for: target(),
                expectedRevision: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .staleRevision(expected: 0, actual: 1)
            )
        }
    }

    func testProposalRequiresExactLedgerProjectionAndCycleRevisions() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta-1",
            planningRPCID: "rpc-1",
            expectedRevision: 0,
            at: date(1)
        )
        let project = snapshot(revision: 4)
        let valid = proposal(
            ledger: ledger,
            snapshot: project,
            decision: dispatchDecision(prompt: "Run the focused tests")
        )
        let policy = allowlist(target())

        XCTAssertNoThrow(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: valid,
                snapshot: project,
                ledger: ledger,
                policy: policy
            )
        )

        let staleLedger = ConversationManagementProposalV1(
            runID: ledger.runID,
            projectID: project.projectID,
            expectedRevision: 0,
            projectionRevision: project.revision,
            cycle: 1,
            summary: "Plan",
            decisions: [dispatchDecision(prompt: "Run the focused tests")]
        )
        XCTAssertThrowsError(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: staleLedger,
                snapshot: project,
                ledger: ledger,
                policy: policy
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .staleRevision(expected: 0, actual: 1)
            )
        }

        let staleProjection = ConversationManagementProposalV1(
            runID: ledger.runID,
            projectID: project.projectID,
            expectedRevision: ledger.revision,
            projectionRevision: 3,
            cycle: 1,
            summary: "Plan",
            decisions: [dispatchDecision(prompt: "Run the focused tests")]
        )
        XCTAssertThrowsError(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: staleProjection,
                snapshot: project,
                ledger: ledger,
                policy: policy
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .staleRevision(expected: 3, actual: 4)
            )
        }
    }

    func testCallerAllowlistAndEnrollmentAreBothRequired() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta",
            planningRPCID: "rpc",
            expectedRevision: 0
        )
        let allowed = target(scope: "main")
        let denied = target(scope: "workbuddy")
        let project = snapshot(
            records: [
                record(target: allowed),
                record(target: denied),
            ]
        )
        let deniedDecision = dispatchDecision(
            target: denied,
            prompt: "Implement the approved change"
        )

        XCTAssertThrowsError(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: proposal(
                    ledger: ledger,
                    snapshot: project,
                    decision: deniedDecision
                ),
                snapshot: project,
                ledger: ledger,
                policy: allowlist(allowed)
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .targetNotAllowed(denied.stableID)
            )
        }

        let excludedProject = snapshot(
            records: [
                record(target: allowed, enrollment: .excluded),
            ]
        )
        XCTAssertThrowsError(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: proposal(
                    ledger: ledger,
                    snapshot: excludedProject,
                    decision: dispatchDecision(
                        target: allowed,
                        prompt: "Implement the approved change"
                    )
                ),
                snapshot: excludedProject,
                ledger: ledger,
                policy: allowlist(allowed)
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .targetExcluded(allowed.stableID)
            )
        }
    }

    func testGenericContinueBatchesAreRejected() throws {
        for prompt in ["continue", "continue 20 times", "继续20次", "go on"] {
            var ledger = makeLedger()
            try ledger.startPlanning(
                metaSessionID: "meta",
                planningRPCID: "rpc",
                expectedRevision: 0
            )
            let project = snapshot()
            let decision = dispatchDecision(prompt: prompt)

            XCTAssertThrowsError(
                try ConversationManagementSchemaValidatorV1.validate(
                    proposal: proposal(
                        ledger: ledger,
                        snapshot: project,
                        decision: decision
                    ),
                    snapshot: project,
                    ledger: ledger,
                    policy: allowlist(target())
                )
            ) { error in
                XCTAssertEqual(
                    error as? ConversationManagementSchemaErrorV1,
                    .genericContinuation(decision.id)
                )
            }
        }
    }

    func testDuplicateInstructionRequiresNewTargetEvidence() throws {
        let prompt = "Run tests and fix only the failing assertion"
        var ledger = makeLedger()
        var project = snapshot(evidenceRevision: 2)
        try ledger.startPlanning(
            metaSessionID: "meta",
            planningRPCID: "rpc-1",
            expectedRevision: 0
        )
        let first = proposal(
            ledger: ledger,
            snapshot: project,
            decision: dispatchDecision(prompt: prompt)
        )
        try ledger.accept(
            proposal: first,
            snapshot: project,
            policy: allowlist(target()),
            expectedRevision: ledger.revision
        )
        let firstDecision = try XCTUnwrap(first.decisions.first)
        try ledger.recordDelivery(
            decisionID: firstDecision.id,
            target: target(),
            commandID: UUID(),
            delivery: .dispatching,
            evidence: project.conversations[0].base.evidence,
            expectedRevision: ledger.revision
        )
        try ledger.recordDelivery(
            decisionID: firstDecision.id,
            target: target(),
            commandID: ledger.dispatchMemory[0].commandID,
            delivery: .completed,
            expectedRevision: ledger.revision
        )
        try ledger.startPlanning(
            metaSessionID: "meta",
            planningRPCID: "rpc-2",
            expectedRevision: ledger.revision
        )
        let duplicate = dispatchDecision(prompt: prompt)

        XCTAssertThrowsError(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: proposal(
                    ledger: ledger,
                    snapshot: project,
                    decision: duplicate
                ),
                snapshot: project,
                ledger: ledger,
                policy: allowlist(target())
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .duplicateWithoutNewEvidence(duplicate.id)
            )
        }

        project = snapshot(revision: 1, evidenceRevision: 3)
        XCTAssertNoThrow(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: proposal(
                    ledger: ledger,
                    snapshot: project,
                    decision: dispatchDecision(prompt: prompt)
                ),
                snapshot: project,
                ledger: ledger,
                policy: allowlist(target())
            )
        )
    }

    func testCompleteNeedsFreshZeroOpenTasksOrExplicitUserConfirmation() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta",
            planningRPCID: "rpc",
            expectedRevision: 0
        )
        let complete = ConversationManagementDecisionV1(
            kind: .complete,
            reason: "All acceptance criteria appear satisfied"
        )
        let unavailable = snapshot(taskPlan: .unavailable)
        XCTAssertThrowsError(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: proposal(
                    ledger: ledger,
                    snapshot: unavailable,
                    decision: complete
                ),
                snapshot: unavailable,
                ledger: ledger,
                policy: allowlist(target())
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .completionEvidenceRequired
            )
        }

        let fresh = snapshot(
            completion: ConversationProjectCompletionEvidenceV1(
                taskFreshness: .fresh,
                openTaskCount: 0,
                observedAt: date(20),
                userConfirmedAt: nil
            ),
            taskPlan: taskPlan(tasks: [])
        )
        XCTAssertNoThrow(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: proposal(
                    ledger: ledger,
                    snapshot: fresh,
                    decision: complete
                ),
                snapshot: fresh,
                ledger: ledger,
                policy: allowlist(target())
            )
        )

        let confirmed = snapshot(
            completion: ConversationProjectCompletionEvidenceV1(
                taskFreshness: .stale,
                openTaskCount: 4,
                observedAt: date(10),
                userConfirmedAt: date(30)
            ),
            taskPlan: .unavailable
        )
        XCTAssertNoThrow(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: proposal(
                    ledger: ledger,
                    snapshot: confirmed,
                    decision: complete
                ),
                snapshot: confirmed,
                ledger: ledger,
                policy: allowlist(target())
            )
        )
    }

    func testBrainDisabledIsAHardProposalGate() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta",
            planningRPCID: "rpc",
            expectedRevision: 0
        )
        var disabled = snapshot()
        disabled.brainEnabled = false
        let value = proposal(
            ledger: ledger,
            snapshot: disabled,
            decision: dispatchDecision(prompt: "Run the bounded task")
        )

        XCTAssertThrowsError(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: value,
                snapshot: disabled,
                ledger: ledger,
                policy: allowlist(target())
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .brainDisabled("project-1")
            )
        }
    }

    func testDispatchRequiresFreshValidOpenTaskBoundToExactTarget() throws {
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta",
            planningRPCID: "rpc",
            expectedRevision: 0
        )

        let stale = snapshot(taskPlan: taskPlan(freshness: .stale))
        assertDispatchError(
            .taskPlanStale,
            snapshot: stale,
            ledger: ledger,
            decision: dispatchDecision(prompt: "Run the bounded task")
        )

        let invalid = snapshot(taskPlan: taskPlan(isValid: false))
        assertDispatchError(
            .taskPlanInvalid,
            snapshot: invalid,
            ledger: ledger,
            decision: dispatchDecision(prompt: "Run the bounded task")
        )

        let closed = snapshot(taskPlan: taskPlan(tasks: [
            projectTask(status: .done),
        ]))
        assertDispatchError(
            .taskNotOpen("task-1"),
            snapshot: closed,
            ledger: ledger,
            decision: dispatchDecision(prompt: "Run the bounded task")
        )

        let unboundRecord = ConversationManagementRecordV1(
            base: baseProjection(),
            managementExtension: ConversationManagementExtensionV1(
                target: target(),
                enrollment: .enabled,
                workKind: .task,
                taskBindings: [],
                management: .observing,
                updatedAt: date(1)
            )
        )
        let unbound = snapshot(records: [unboundRecord])
        assertDispatchError(
            .taskNotLinked(taskID: "task-1", target: target().stableID),
            snapshot: unbound,
            ledger: ledger,
            decision: dispatchDecision(prompt: "Run the bounded task")
        )

        let wrongTask = dispatchDecision(
            taskID: "task-other",
            prompt: "Run the bounded task"
        )
        assertDispatchError(
            .unknownTask("task-other"),
            snapshot: snapshot(),
            ledger: ledger,
            decision: wrongTask
        )
    }

    func testAdditiveV1DecisionAndWorkKindDecodingIsBackwardCompatible() throws {
        let legacyDecision = #"""
        {
          "id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
          "kind": "dispatch",
          "target": {
            "provider": "codex",
            "sourceScope": "main",
            "sourceID": "thread-1"
          },
          "prompt": "Run the bounded task",
          "reason": "Legacy proposal fixture",
          "expectedEvidence": "Focused test result"
        }
        """#
        let decoded = try JSONDecoder().decode(
            ConversationManagementDecisionV1.self,
            from: Data(legacyDecision.utf8)
        )
        XCTAssertNil(decoded.taskID)

        XCTAssertEqual(
            try JSONDecoder().decode(
                ConversationWorkKindV1.self,
                from: Data(#""unknown""#.utf8)
            ),
            .unclassified
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ConversationWorkKindV1.self,
                from: Data(#""planned""#.utf8)
            ),
            .task
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ConversationWorkKindV1.self,
                from: Data(#""exempt""#.utf8)
            ),
            .unclassified,
            "generic legacy exemption cannot invent a visible work category"
        )
    }

    private func target(
        provider: String = "codex",
        scope: String = "main",
        id: String = "thread-1"
    ) -> ConversationManagementTargetV1 {
        ConversationManagementTargetV1(
            provider: provider,
            sourceScope: scope,
            sourceID: id
        )
    }

    private func baseProjection(
        target value: ConversationManagementTargetV1? = nil,
        evidenceRevision: Int = 0
    ) -> ConversationManagementBaseProjectionV1 {
        ConversationManagementBaseProjectionV1(
            target: value ?? target(),
            projectID: "project-1",
            title: "Task",
            role: "main",
            observedAt: date(1),
            runtime: .idle,
            progress: .unknown,
            evidence: ConversationEvidenceProjectionV1(
                revision: evidenceRevision,
                status: evidenceRevision == 0 ? .none : .fresh,
                fingerprint: evidenceRevision == 0 ? nil : "evidence-\(evidenceRevision)",
                summary: nil,
                observedAt: evidenceRevision == 0 ? nil : date(2)
            )
        )
    }

    private func record(
        target value: ConversationManagementTargetV1? = nil,
        enrollment: ConversationManagementEnrollmentV1 = .inherit,
        evidenceRevision: Int = 0
    ) -> ConversationManagementRecordV1 {
        let value = value ?? target()
        return ConversationManagementRecordV1(
            base: baseProjection(
                target: value,
                evidenceRevision: evidenceRevision
            ),
            managementExtension: ConversationManagementExtensionV1(
                target: value,
                enrollment: enrollment,
                workKind: .task,
                taskBindings: [ConversationTaskBindingV1(
                    taskID: "task-1",
                    projectID: "project-1",
                    target: value,
                    boundAt: date(1)
                )],
                management: .observing,
                updatedAt: date(1)
            )
        )
    }

    private func snapshot(
        revision: Int = 0,
        projectDefaultEnabled: Bool = true,
        completion: ConversationProjectCompletionEvidenceV1 = .unavailable,
        taskPlan value: ConversationProjectTaskPlanProjectionV1? = nil,
        evidenceRevision: Int = 0,
        records: [ConversationManagementRecordV1]? = nil
    ) -> ConversationManagementSnapshotV1 {
        ConversationManagementSnapshotV1(
            projectID: "project-1",
            revision: revision,
            brainEnabled: true,
            projectDefaultEnrollmentEnabled: projectDefaultEnabled,
            taskPlan: value ?? taskPlan(),
            completionEvidence: completion,
            generatedAt: date(1),
            conversations: records ?? [record(evidenceRevision: evidenceRevision)]
        )
    }

    private func makeLedger() -> ConversationManagementProgressLedgerV1 {
        ConversationManagementProgressLedgerV1(
            runID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            projectID: "project-1",
            objective: "Finish the project",
            createdAt: date(0)
        )
    }

    private func dispatchDecision(
        target value: ConversationManagementTargetV1? = nil,
        taskID: String = "task-1",
        prompt: String
    ) -> ConversationManagementDecisionV1 {
        ConversationManagementDecisionV1(
            kind: .dispatch,
            target: value ?? target(),
            taskID: taskID,
            prompt: prompt,
            reason: "This is the next evidence-producing step",
            expectedEvidence: "Focused test result"
        )
    }

    private func proposal(
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
            summary: "One bounded next action",
            decisions: [decision]
        )
    }

    private func allowlist(
        _ targets: ConversationManagementTargetV1...
    ) -> ConversationManagementValidationPolicyV1 {
        ConversationManagementValidationPolicyV1(
            allowedTargets: Set(targets)
        )
    }

    private func assertDispatchError(
        _ expected: ConversationManagementSchemaErrorV1,
        snapshot: ConversationManagementSnapshotV1,
        ledger: ConversationManagementProgressLedgerV1,
        decision: ConversationManagementDecisionV1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ConversationManagementSchemaValidatorV1.validate(
                proposal: proposal(
                    ledger: ledger,
                    snapshot: snapshot,
                    decision: decision
                ),
                snapshot: snapshot,
                ledger: ledger,
                policy: allowlist(target())
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func taskPlan(
        freshness: ConversationProjectTaskFreshnessV1 = .fresh,
        isValid: Bool = true,
        tasks: [ConversationProjectTaskV1]? = nil
    ) -> ConversationProjectTaskPlanProjectionV1 {
        ConversationProjectTaskPlanProjectionV1(
            sourceRevision: freshness == .unavailable ? nil : "sha256:task-plan-1",
            freshness: freshness,
            isValid: isValid,
            observedAt: freshness == .unavailable ? nil : date(3),
            tasks: isValid ? (tasks ?? [projectTask()]) : []
        )
    }

    private func projectTask(
        id: String = "task-1",
        status: ConversationProjectTaskStatusV1 = .pending
    ) -> ConversationProjectTaskV1 {
        ConversationProjectTaskV1(
            taskID: id,
            title: "Authoritative task",
            owner: "executor",
            status: status
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(value)
            ) as? [String: Any]
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
}
