import Foundation
import XCTest
@testable import HarvisBar

final class ConversationManagementTaskPlanAdapterTests: XCTestCase {
    func testFreshValidatedPlanMapsExactAuthorityFields() throws {
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let plan = ManagedProjectTaskPlan(
            schemaVersion: ManagedProjectTaskPlan.supportedSchemaVersion,
            sourceAvailable: true,
            sourceRevision: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            isValid: true,
            invalidRecordCount: 0,
            tasks: [
                ManagedProjectTaskPlanItem(
                    taskId: "task-1",
                    title: "Implement project page",
                    description: "Display exact project facts.",
                    owner: "executor",
                    status: "in_progress",
                    updatedAt: "2026-08-24T00:30:00Z",
                    evidence: [
                        ManagedProjectTaskEvidenceReference(
                            kind: "run_id",
                            id: "run-1"
                        ),
                    ]
                ),
            ]
        )

        let projection = try ConversationManagementTaskPlanAdapterV1.projection(
            plan: plan,
            freshness: .fresh(lastSuccessfulAt: observedAt),
            previous: nil,
            observedAt: observedAt
        )

        XCTAssertTrue(projection.isAuthoritative)
        XCTAssertEqual(projection.sourceRevision, plan.sourceRevision)
        XCTAssertEqual(projection.tasks.map(\.taskID), ["task-1"])
        XCTAssertEqual(projection.tasks[0].status, .inProgress)
        XCTAssertEqual(projection.tasks[0].evidence[0].kind, "run_id")
        XCTAssertNotNil(projection.tasks[0].updatedAt)
    }

    func testStalePlanRetainsPreviousOnlyAsNonAuthoritative() throws {
        let previous = ConversationProjectTaskPlanProjectionV1(
            sourceRevision: "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            freshness: .fresh,
            isValid: true,
            observedAt: Date(timeIntervalSince1970: 1_000),
            tasks: [
                ConversationProjectTaskV1(
                    taskID: "task-1",
                    title: "Previous task",
                    owner: "executor",
                    status: .pending
                ),
            ]
        )

        let projection = try ConversationManagementTaskPlanAdapterV1.projection(
            plan: nil,
            freshness: .stale(
                lastSuccessfulAt: Date(timeIntervalSince1970: 1_000),
                error: "source unavailable"
            ),
            previous: previous
        )

        XCTAssertEqual(projection.freshness, .stale)
        XCTAssertEqual(projection.tasks.map(\.taskID), ["task-1"])
        XCTAssertFalse(projection.isAuthoritative)
    }
}
