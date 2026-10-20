import XCTest
@testable import HarvisBar

final class ManagedConversationPlanPresentationTests: XCTestCase {
    func testMatrixCardKindsReserveIdenticalCardAndComposerHeights() {
        let cardHeights = CodexMatrixCardKind.allCases.map {
            CodexMatrixCardLayoutMetrics.cardHeight(for: $0)
        }
        let composerHeights = CodexMatrixCardKind.allCases.map {
            CodexMatrixCardLayoutMetrics.composerSlotHeight(for: $0)
        }

        XCTAssertEqual(Set(cardHeights).count, 1)
        XCTAssertEqual(Set(composerHeights).count, 1)
        XCTAssertGreaterThan(cardHeights[0], composerHeights[0])
    }

    func testPlanStripeStartsBelowCompactionRiskBar() {
        let inset = CodexMatrixCardLayoutMetrics.planStripeTopInset(
            preservingRiskBar: true
        )

        XCTAssertGreaterThan(
            inset,
            CodexMatrixCardLayoutMetrics.compactionRiskBarHeight
        )
        XCTAssertEqual(
            CodexMatrixCardLayoutMetrics.planStripeTopInset(
                preservingRiskBar: false
            ),
            1
        )
    }

    func testAlignmentUsesDistinctDerivedTones() {
        let expected: [(ConversationPlanAlignmentV1, ManagedConversationPlanTone)] = [
            (.onPlan, .positive),
            (.exempt, .informational),
            (.outOfPlan, .warning),
            (.unknown, .neutral),
            (.conflict, .critical),
        ]

        for (alignment, tone) in expected {
            let presentation = ManagedConversationPlanPresentation(
                alignment: alignment,
                workKind: .task,
                taskIDs: ["TASK-1"]
            )
            XCTAssertEqual(presentation.tone, tone)
        }
    }

    func testUnavailableMetadataIsExplicitAndFailClosed() {
        let presentation = ManagedConversationPlanPresentation.unavailable

        XCTAssertEqual(presentation.alignment, .unknown)
        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertEqual(presentation.workKindLabel, "管理数据未接入")
        XCTAssertEqual(presentation.bindingLabel, "未验证任务绑定")
    }

    func testTaskBindingIsNotRenderedAsOrdinaryTag() {
        let presentation = ManagedConversationPlanPresentation(
            alignment: .onPlan,
            workKind: .task,
            taskIDs: ["PLAN-7", "PLAN-9"]
        )

        XCTAssertEqual(presentation.bindingLabel, "任务 · PLAN-7 +1")
        XCTAssertFalse(presentation.bindingLabel.contains("#"))
        XCTAssertTrue(presentation.helpText.contains("PLAN-7, PLAN-9"))
    }

    func testExemptWorkKindNamesTheExplicitCategory() {
        let presentation = ManagedConversationPlanPresentation(
            alignment: .exempt,
            workKind: .exploration,
            taskIDs: []
        )

        XCTAssertEqual(presentation.title, "计划豁免")
        XCTAssertEqual(presentation.bindingLabel, "探索")
    }

    func testPolicyPreservesExactBindingOrderAndDuplicatesForConflictVisibility() {
        let target = ConversationManagementTargetV1(
            provider: "codex",
            sourceScope: "home-a",
            sourceID: "thread-a"
        )
        let extensionValue = ConversationManagementExtensionV1(
            target: target,
            workKind: .task,
            taskBindings: [
                ConversationTaskBindingV1(
                    taskID: "TASK-2",
                    projectID: "project-a",
                    target: target
                ),
                ConversationTaskBindingV1(
                    taskID: "TASK-2",
                    projectID: "project-a",
                    target: target
                ),
            ]
        )

        let presentation = ManagedConversationPlanPresentationPolicy.make(
            alignment: .conflict,
            managementExtension: extensionValue
        )

        XCTAssertEqual(presentation.taskIDs, ["TASK-2", "TASK-2"])
        XCTAssertEqual(presentation.tone, .critical)
    }

    func testEditorOffersOnlyOpenTasksFromAuthoritativePlan() {
        let plan = ConversationProjectTaskPlanProjectionV1(
            sourceRevision: "sha256:" + String(repeating: "a", count: 64),
            freshness: .fresh,
            isValid: true,
            observedAt: Date(),
            tasks: [
                task("OPEN", status: .inProgress),
                task("DONE", status: .done),
            ]
        )

        XCTAssertEqual(
            ConversationPlanEditorPolicy.openTasks(from: plan).map(\.taskID),
            ["OPEN"]
        )
        XCTAssertTrue(
            ConversationPlanEditorPolicy.canSave(
                brainEnabled: true,
                taskPlan: plan,
                workKind: .task,
                selectedTaskID: "OPEN"
            )
        )
        XCTAssertFalse(
            ConversationPlanEditorPolicy.canSave(
                brainEnabled: true,
                taskPlan: plan,
                workKind: .task,
                selectedTaskID: "DONE"
            )
        )
    }

    func testEditorFailsClosedWhenBrainOrTaskAuthorityIsUnavailable() {
        XCTAssertFalse(
            ConversationPlanEditorPolicy.canSave(
                brainEnabled: false,
                taskPlan: .unavailable,
                workKind: .exploration,
                selectedTaskID: ""
            )
        )
        XCTAssertFalse(
            ConversationPlanEditorPolicy.canSave(
                brainEnabled: true,
                taskPlan: .unavailable,
                workKind: .task,
                selectedTaskID: "TASK-1"
            )
        )
        XCTAssertNil(
            ConversationPlanEditorPolicy.taskIDForPersistence(
                workKind: .knowledge,
                selectedTaskID: "TASK-1"
            )
        )
    }

    func testEditorExplicitlyEnrollsEveryClassifiedSaveForApprovalOnly() {
        let classifiedKinds: [ConversationWorkKindV1] = [
            .task,
            .exploration,
            .operations,
            .knowledge,
            .management,
        ]

        for workKind in classifiedKinds {
            XCTAssertTrue(
                ConversationPlanEditorPolicy.includeForDispatch(
                    workKind: workKind
                )
            )
        }
        XCTAssertFalse(
            ConversationPlanEditorPolicy.includeForDispatch(
                workKind: .unclassified
            )
        )
    }

    func testBrainPreviewGenerationRequiresExactReadyInputs() {
        XCTAssertTrue(
            ManagedProjectBrainPreviewPolicy.canGenerate(
                brainEnabled: true,
                endpointAvailable: true,
                objective: "  inspect explicit plan  ",
                isGenerating: false,
                hasPreview: false,
                generatorAvailable: true
            )
        )
        XCTAssertFalse(
            ManagedProjectBrainPreviewPolicy.canGenerate(
                brainEnabled: false,
                endpointAvailable: true,
                objective: "inspect",
                isGenerating: false,
                hasPreview: false,
                generatorAvailable: true
            )
        )
        XCTAssertFalse(
            ManagedProjectBrainPreviewPolicy.canGenerate(
                brainEnabled: true,
                endpointAvailable: false,
                objective: "inspect",
                isGenerating: false,
                hasPreview: false,
                generatorAvailable: true
            )
        )
        XCTAssertFalse(
            ManagedProjectBrainPreviewPolicy.canGenerate(
                brainEnabled: true,
                endpointAvailable: true,
                objective: String(
                    repeating: "x",
                    count: ConversationManagementSchemaV1.maxPromptCharacters + 1
                ),
                isGenerating: false,
                hasPreview: false,
                generatorAvailable: true
            )
        )
    }

    func testBrainApprovalRequiresCompleteExactDispatchDecision() {
        let target = ConversationManagementTargetV1(
            provider: "codex",
            sourceScope: "home-a",
            sourceID: "thread-a"
        )
        let exact = ConversationManagementDecisionV1(
            kind: .dispatch,
            target: target,
            taskID: "TASK-1",
            prompt: "Implement the exact scoped task.",
            reason: "The task is open and explicitly linked.",
            expectedEvidence: "A targeted test passes."
        )
        XCTAssertEqual(
            ManagedProjectBrainPreviewPolicy.approval(for: exact),
            .approvable
        )

        let missingTask = ConversationManagementDecisionV1(
            kind: .dispatch,
            target: target,
            taskID: nil,
            prompt: "Implement the exact scoped task.",
            reason: "Missing task authority.",
            expectedEvidence: "A targeted test passes."
        )
        guard case .readOnly = ManagedProjectBrainPreviewPolicy.approval(
            for: missingTask
        ) else {
            return XCTFail("Incomplete dispatch must be read-only")
        }

        let completion = ConversationManagementDecisionV1(
            kind: .complete,
            reason: "All authoritative tasks are complete."
        )
        guard case .readOnly = ManagedProjectBrainPreviewPolicy.approval(
            for: completion
        ) else {
            return XCTFail("Non-dispatch decisions have no dispatch approval")
        }
    }

    func testBrainDeliveryPresentationNeverShowsFailureAsSuccess() {
        XCTAssertEqual(
            ManagedProjectBrainPreviewPolicy.deliveryPresentation(.completed).tone,
            .positive
        )
        XCTAssertEqual(
            ManagedProjectBrainPreviewPolicy.deliveryPresentation(.running).tone,
            .neutral
        )
        XCTAssertEqual(
            ManagedProjectBrainPreviewPolicy.deliveryPresentation(
                .waitingApproval
            ).tone,
            .warning
        )
        XCTAssertEqual(
            ManagedProjectBrainPreviewPolicy.deliveryPresentation(.failed).tone,
            .critical
        )
        XCTAssertEqual(
            ManagedProjectBrainPreviewPolicy.deliveryPresentation(
                .deliveryUnknown
            ).tone,
            .critical
        )
        XCTAssertEqual(
            ManagedProjectBrainPreviewPolicy.deliveryPresentation(.cancelled).tone,
            .warning
        )
    }

    private func task(
        _ id: String,
        status: ConversationProjectTaskStatusV1
    ) -> ConversationProjectTaskV1 {
        ConversationProjectTaskV1(
            taskID: id,
            title: id,
            owner: "owner",
            status: status,
            updatedAt: Date()
        )
    }
}
