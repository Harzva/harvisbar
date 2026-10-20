import Foundation
import XCTest
@testable import HarvisBar

final class ConversationPlanAlignmentTests: XCTestCase {
    func testTaskWithExactOpenBindingIsOnPlan() {
        let record = makeRecord(
            workKind: .task,
            bindings: [binding()]
        )

        XCTAssertEqual(
            record.planAlignment(taskPlan: taskPlan(), now: date(hours: 48)),
            .onPlan
        )
    }

    func testVisibleNonTaskCategoriesAreExplicitlyExempt() {
        let categories: [ConversationWorkKindV1] = [
            .exploration,
            .operations,
            .knowledge,
            .management,
        ]
        XCTAssertEqual(
            categories.map(\.rawValue),
            ["exploration", "operations", "knowledge", "management"]
        )
        for category in categories {
            XCTAssertEqual(
                makeRecord(workKind: category).planAlignment(
                    taskPlan: taskPlan(),
                    now: date(hours: 48)
                ),
                .exempt
            )
        }
    }

    func testUnclassifiedConversationUsesStableTwentyFourHourGrace() {
        let record = makeRecord(
            workKind: .unclassified,
            startedAt: date(hours: 0),
            observedAt: date(hours: 47),
            runtime: .running
        )

        XCTAssertEqual(
            record.planAlignment(taskPlan: taskPlan(), now: date(hours: 23)),
            .unknown
        )
        XCTAssertEqual(
            record.planAlignment(taskPlan: taskPlan(), now: date(hours: 25)),
            .outOfPlan,
            "new provider activity must not reset the stable start-time grace"
        )
    }

    func testStaleUnavailableOrInvalidAuthorityAlwaysReturnsUnknown() {
        let oldUnclassified = makeRecord(
            workKind: .unclassified,
            startedAt: date(hours: 0),
            observedAt: date(hours: 48),
            runtime: .running
        )
        let stale = ConversationProjectTaskPlanProjectionV1(
            sourceRevision: "sha256:one",
            freshness: .stale,
            isValid: true,
            observedAt: date(hours: 1),
            tasks: [task()]
        )
        let invalid = ConversationProjectTaskPlanProjectionV1(
            sourceRevision: "sha256:two",
            freshness: .fresh,
            isValid: false,
            observedAt: date(hours: 48),
            tasks: []
        )

        for plan in [
            ConversationProjectTaskPlanProjectionV1.unavailable,
            stale,
            invalid,
        ] {
            XCTAssertEqual(
                oldUnclassified.planAlignment(
                    taskPlan: plan,
                    now: date(hours: 48),
                    graceInterval: 1
                ),
                .unknown
            )
        }
    }

    func testConflictingExplicitFactsNeverUseSemanticInference() {
        let nonTaskWithBinding = makeRecord(
            workKind: .knowledge,
            bindings: [binding()]
        )
        XCTAssertEqual(
            nonTaskWithBinding.planAlignment(
                taskPlan: taskPlan(),
                now: date(hours: 48)
            ),
            .conflict
        )

        let missingTaskPlan = ConversationProjectTaskPlanProjectionV1(
            sourceRevision: "sha256:missing",
            freshness: .fresh,
            isValid: true,
            observedAt: date(hours: 48),
            tasks: []
        )
        XCTAssertEqual(
            makeRecord(workKind: .task, bindings: [binding()])
                .planAlignment(
                    taskPlan: missingTaskPlan,
                    now: date(hours: 48)
                ),
            .conflict
        )
        let crossProjectBinding = ConversationTaskBindingV1(
            taskID: "task-1",
            projectID: "project-other",
            target: target,
            boundAt: date(hours: 1)
        )
        XCTAssertEqual(
            makeRecord(workKind: .task, bindings: [crossProjectBinding])
                .planAlignment(
                    taskPlan: taskPlan(),
                    now: date(hours: 48)
                ),
            .conflict
        )

        let matchingTitleWithoutBinding = makeRecord(
            workKind: .unclassified,
            startedAt: date(hours: 0),
            observedAt: date(hours: 48),
            title: task().title
        )
        XCTAssertEqual(
            matchingTitleWithoutBinding.planAlignment(
                taskPlan: taskPlan(),
                now: date(hours: 48),
                graceInterval: 1
            ),
            .outOfPlan,
            "matching display text must never synthesize a task binding"
        )

        let activeAfterClosed = makeRecord(
            workKind: .task,
            bindings: [binding()],
            startedAt: date(hours: 0),
            observedAt: date(hours: 48),
            runtime: .running
        )
        XCTAssertEqual(
            activeAfterClosed.planAlignment(
                taskPlan: taskPlan(
                    status: .done,
                    updatedAt: date(hours: 24)
                ),
                now: date(hours: 48)
            ),
            .outOfPlan
        )

        let idleAtClosure = makeRecord(
            workKind: .task,
            bindings: [binding()],
            startedAt: date(hours: 0),
            observedAt: date(hours: 24),
            runtime: .idle
        )
        XCTAssertEqual(
            idleAtClosure.planAlignment(
                taskPlan: taskPlan(
                    status: .done,
                    updatedAt: date(hours: 24)
                ),
                now: date(hours: 48)
            ),
            .onPlan
        )

        XCTAssertEqual(
            idleAtClosure.planAlignment(
                taskPlan: taskPlan(status: .done, updatedAt: nil),
                now: date(hours: 48)
            ),
            .unknown
        )
    }

    private let target = ConversationManagementTargetV1(
        provider: "codex",
        sourceScope: "main",
        sourceID: "thread-1"
    )

    private func makeRecord(
        workKind: ConversationWorkKindV1,
        bindings: [ConversationTaskBindingV1] = [],
        startedAt: Date? = nil,
        observedAt: Date? = nil,
        runtime: ConversationRuntimeStateV1 = .idle,
        title: String = "Conversation"
    ) -> ConversationManagementRecordV1 {
        let startedAt = startedAt ?? date(hours: 0)
        return ConversationManagementRecordV1(
            base: ConversationManagementBaseProjectionV1(
                target: target,
                projectID: "project-1",
                title: title,
                role: "main",
                startedAt: startedAt,
                observedAt: observedAt ?? startedAt,
                runtime: runtime,
                progress: .unknown,
                evidence: .none
            ),
            managementExtension: ConversationManagementExtensionV1(
                target: target,
                enrollment: .enabled,
                workKind: workKind,
                taskBindings: bindings,
                management: .observing,
                updatedAt: observedAt ?? startedAt
            )
        )
    }

    private func binding() -> ConversationTaskBindingV1 {
        ConversationTaskBindingV1(
            taskID: "task-1",
            projectID: "project-1",
            target: target,
            boundAt: date(hours: 1)
        )
    }

    private func taskPlan(
        status: ConversationProjectTaskStatusV1 = .inProgress,
        updatedAt: Date? = nil
    ) -> ConversationProjectTaskPlanProjectionV1 {
        ConversationProjectTaskPlanProjectionV1(
            sourceRevision: "sha256:one",
            freshness: .fresh,
            isValid: true,
            observedAt: date(hours: 48),
            tasks: [task(status: status, updatedAt: updatedAt)]
        )
    }

    private func task(
        status: ConversationProjectTaskStatusV1 = .inProgress,
        updatedAt: Date? = nil
    ) -> ConversationProjectTaskV1 {
        ConversationProjectTaskV1(
            taskID: "task-1",
            title: "Same words as the conversation",
            owner: "executor",
            status: status,
            updatedAt: updatedAt
        )
    }

    private func date(hours: Double) -> Date {
        Date(timeIntervalSince1970: hours * 60 * 60)
    }
}
