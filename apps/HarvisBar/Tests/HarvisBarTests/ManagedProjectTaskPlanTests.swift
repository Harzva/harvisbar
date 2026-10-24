import XCTest
@testable import HarvisBar

@MainActor
final class ManagedProjectTaskPlanTests: XCTestCase {
    func testDecodesVersionedTaskPlanAndSafeEvidenceReferences() throws {
        let payload = #"""
        {
          "schemaVersion": "harvis.agent-room-task-plan.v1",
          "sourceAvailable": true,
          "sourceRevision": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "isValid": true,
          "invalidRecordCount": 0,
          "tasks": [
            {
              "taskId": "task-1",
              "title": "Ship the task projection",
              "description": "Keep the client read-only.",
              "owner": "executor",
              "status": "in_progress",
              "updatedAt": "2026-08-24T09:30:00Z",
              "evidence": [
                {"kind": "source_event_id", "id": "event-1"},
                {"kind": "approval_id", "id": "approval-1"}
              ]
            }
          ]
        }
        """#

        let plan = try JSONDecoder().decode(
            ManagedProjectTaskPlan.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(plan.schemaVersion, ManagedProjectTaskPlan.supportedSchemaVersion)
        XCTAssertEqual(
            plan.sourceRevision,
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        XCTAssertEqual(plan.tasks.count, 1)
        XCTAssertEqual(plan.tasks[0].owner, "executor")
        XCTAssertEqual(
            plan.tasks[0].evidence,
            [
                ManagedProjectTaskEvidenceReference(kind: "source_event_id", id: "event-1"),
                ManagedProjectTaskEvidenceReference(kind: "approval_id", id: "approval-1"),
            ]
        )
    }

    func testValidPlanProjectsExistingTaskSummarySemantics() throws {
        let plan = makePlan(statuses: [
            "pending",
            "in_progress",
            "waiting_approval",
            "blocked",
            "reviewing",
            "done",
            "closed",
        ])

        let summary = try ManagedProjectTaskPlanProjector.summary(from: plan)

        XCTAssertTrue(summary.sourceAvailable)
        XCTAssertEqual(summary.total, 7)
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(summary.open, 5)
        XCTAssertEqual(summary.blocked, 1)
        XCTAssertEqual(summary.waitingApproval, 1)
        XCTAssertEqual(summary.reviewing, 1)
        XCTAssertEqual(summary.closedWithoutCompletion, 1)
        XCTAssertFalse(summary.sourceTruncated)
    }

    func testProjectorRejectsInvalidEnvelopeAndUnsupportedSchema() {
        let invalid = makePlan(
            isValid: false,
            invalidRecordCount: 2,
            statuses: ["done"]
        )
        XCTAssertThrowsError(
            try ManagedProjectTaskPlanProjector.summary(from: invalid)
        ) { error in
            XCTAssertEqual(
                error as? ManagedProjectTaskPlanValidationError,
                .invalidEnvelope(invalidRecordCount: 2)
            )
        }

        let unsupported = makePlan(
            schemaVersion: "harvis.agent-room-task-plan.v2",
            statuses: ["done"]
        )
        XCTAssertThrowsError(
            try ManagedProjectTaskPlanProjector.summary(from: unsupported)
        ) { error in
            XCTAssertEqual(
                error as? ManagedProjectTaskPlanValidationError,
                .unsupportedSchema("harvis.agent-room-task-plan.v2")
            )
        }
    }

    func testProjectorRejectsUnsafeEvidenceReferences() {
        let plan = makePlan(
            statuses: ["pending"],
            evidence: [
                ManagedProjectTaskEvidenceReference(
                    kind: "run_id",
                    id: "/private/unsafe"
                ),
            ]
        )

        XCTAssertThrowsError(
            try ManagedProjectTaskPlanProjector.summary(from: plan)
        ) { error in
            XCTAssertEqual(
                error as? ManagedProjectTaskPlanValidationError,
                .invalidEvidence(taskID: "task-0")
            )
        }
    }

    func testProjectorRejectsBadRevisionTimestampAndEvidenceKind() {
        XCTAssertThrowsError(
            try ManagedProjectTaskPlanProjector.summary(
                from: makePlan(
                    sourceRevision: "sha256:short",
                    statuses: ["pending"]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedProjectTaskPlanValidationError,
                .invalidSourceRevision
            )
        }

        XCTAssertThrowsError(
            try ManagedProjectTaskPlanProjector.summary(
                from: makePlan(statuses: ["pending"], updatedAt: "not-a-date")
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedProjectTaskPlanValidationError,
                .invalidTimestamp(taskID: "task-0")
            )
        }

        XCTAssertThrowsError(
            try ManagedProjectTaskPlanProjector.summary(
                from: makePlan(
                    statuses: ["pending"],
                    evidence: [
                        ManagedProjectTaskEvidenceReference(
                            kind: "raw_log",
                            id: "event-1"
                        ),
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedProjectTaskPlanValidationError,
                .invalidEvidence(taskID: "task-0")
            )
        }
    }

    func testUnavailableRefreshPreservesLastKnownPlanAsStale() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let project = makeProject()
        let successfulAt = Date(timeIntervalSince1970: 1_000)
        let valid = makePlan(statuses: ["done", "blocked"])

        XCTAssertTrue(model.acceptManagedProjectTaskPlan(
            valid,
            for: project,
            at: successfulAt
        ))
        let acceptedSummary = try XCTUnwrap(model.managedProjectTaskSummaries[project.id])

        let unavailable = makePlan(
            sourceAvailable: false,
            sourceRevision: nil,
            statuses: []
        )
        XCTAssertFalse(model.acceptManagedProjectTaskPlan(
            unavailable,
            for: project,
            at: Date(timeIntervalSince1970: 2_000)
        ))

        XCTAssertEqual(model.projectTaskPlan(for: project), valid)
        XCTAssertEqual(model.managedProjectTaskSummaries[project.id], acceptedSummary)
        XCTAssertEqual(
            model.projectTaskPlanFreshness(for: project),
            .stale(
                lastSuccessfulAt: successfulAt,
                error: "Project task source is unavailable."
            )
        )
        XCTAssertEqual(
            model.projectTaskSummaryFreshness(for: project),
            model.projectTaskPlanFreshness(for: project)
        )
    }

    func testFirstInvalidPlanFailsClosedAsUnavailable() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let project = makeProject()
        let invalid = makePlan(
            isValid: false,
            invalidRecordCount: 1,
            statuses: ["done"]
        )

        XCTAssertFalse(model.acceptManagedProjectTaskPlan(invalid, for: project))

        XCTAssertNil(model.projectTaskPlan(for: project))
        XCTAssertEqual(model.managedProjectTaskSummaries[project.id], .unavailable)
        guard case let .unavailable(error) = model.projectTaskPlanFreshness(for: project) else {
            return XCTFail("Expected unavailable freshness")
        }
        XCTAssertEqual(error, "Project task plan is invalid (1 invalid record).")
    }

    func testForceRefreshAwaitsSameProjectInFlightLoad() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let project = makeProject()
        let plan = makePlan(statuses: ["in_progress"])
        let loader = SuspendingTaskPlanLoader(plan: plan)
        model.projectTaskPlanAuthorityLoader = { project in
            try await loader.load(for: project)
        }

        let firstRefresh = Task { @MainActor in
            await model.refreshProjectTaskPlan(project, force: true)
        }
        try await waitForCallCount(1, loader: loader)

        let completion = TaskPlanRefreshCompletion()
        let forceRefresh = Task { @MainActor in
            await model.refreshProjectTaskPlan(project, force: true)
            await completion.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(25))
        let callCountWhileLoading = await loader.currentCallCount()
        XCTAssertEqual(callCountWhileLoading, 1)
        let completedWhileLoading = await completion.isCompleted()
        XCTAssertFalse(completedWhileLoading)

        await loader.release()
        await firstRefresh.value
        await forceRefresh.value
        let completedAfterLoad = await completion.isCompleted()
        XCTAssertTrue(completedAfterLoad)
        XCTAssertEqual(model.projectTaskPlan(for: project), plan)

        await model.refreshProjectTaskPlan(project, force: true)
        let callCountAfterCompletion = await loader.currentCallCount()
        XCTAssertEqual(callCountAfterCompletion, 2)
    }

    func testCancelledRefreshClearsGuardWithoutReplacingBusinessEvidence() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let project = makeProject()
        let businessError = "Task source failed validation."
        model.recordManagedProjectTaskPlanFailure(businessError, for: project)
        let freshnessBeforeCancellation = model.projectTaskPlanFreshness(for: project)

        let plan = makePlan(statuses: ["done"])
        let loader = SuspendingTaskPlanLoader(plan: plan)
        model.projectTaskPlanAuthorityLoader = { project in
            try await loader.load(for: project)
        }

        let refresh = Task { @MainActor in
            await model.refreshProjectTaskPlan(project, force: true)
        }
        try await waitForCallCount(1, loader: loader)
        refresh.cancel()
        await refresh.value

        XCTAssertEqual(model.managedGovernanceErrors[project.id], businessError)
        XCTAssertEqual(
            model.projectTaskPlanFreshness(for: project),
            freshnessBeforeCancellation
        )

        await loader.release()
        await model.refreshProjectTaskPlan(project, force: true)
        let callCountAfterCancellation = await loader.currentCallCount()
        XCTAssertEqual(callCountAfterCancellation, 2)
        XCTAssertEqual(model.projectTaskPlan(for: project), plan)
        XCTAssertNil(model.managedGovernanceErrors[project.id])
    }

    func testFailedRefreshClearsSingleFlightForLaterRetry() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let project = makeProject()
        let plan = makePlan(statuses: ["done"])
        let loader = FailingOnceTaskPlanLoader(plan: plan)
        model.projectTaskPlanAuthorityLoader = { project in
            try await loader.load(for: project)
        }

        await model.refreshProjectTaskPlan(project, force: true)
        XCTAssertEqual(
            model.managedGovernanceErrors[project.id],
            "Authoritative task-plan read failed."
        )

        await model.refreshProjectTaskPlan(project, force: true)
        let callCount = await loader.currentCallCount()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(model.projectTaskPlan(for: project), plan)
        XCTAssertNil(model.managedGovernanceErrors[project.id])
    }

    private var suiteName: String {
        "ManagedProjectTaskPlanTests.\(name)"
    }

    func testHistoricalBackgroundGatePrecedesProjectResolutionAndExplicitSingleProjectStillWorks() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let project = makeProject()
        let path = "/fixture/permission-gated-history"
        model.workBuddyThreads = [WorkBuddyThreadSummary(id: "fixture-history", title: "History", createdAt: 1,
            updatedAt: 1, tokensUsed: 0, model: nil, cwd: path, archived: false, running: false, sourceStatus: "idle")]
        var count = 0
        let plan = makePlan(statuses: ["pending"])
        model.projectTaskPlanAuthorityLoader = { _ in count += 1; return plan }
        ManagedProjectPathCache.shared.removeAll()
        await model.refreshManagedChatGovernance(threads: [], projects: [project])
        await model.refreshProjectTaskPlan(project)
        XCTAssertEqual(count, 0)
        XCTAssertNil(ManagedProjectPathCache.shared.value(for: path), "Disabled background work must not even stat/canonicalize historical cwd")
        await model.refreshProjectTaskPlan(project, force: true)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.projectTaskPlan(for: project), plan)
        model.accessPreferences.historicalProjectAccessEnabled = true
        await model.refreshProjectTaskPlan(project, force: true)
        XCTAssertEqual(count, 2)
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func waitForCallCount(
        _ expected: Int,
        loader: SuspendingTaskPlanLoader
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await loader.currentCallCount() < expected {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for task-plan loader call \(expected)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeProject() -> ManagedChatProjectIdentity {
        ManagedChatProjectIdentity(
            id: "path::/tmp/task-plan-project",
            canonicalPath: "/tmp/task-plan-project",
            displayPath: "/tmp/task-plan-project",
            label: "task-plan-project",
            resolution: .resolved
        )
    }

    private func makePlan(
        schemaVersion: String = ManagedProjectTaskPlan.supportedSchemaVersion,
        sourceAvailable: Bool = true,
        sourceRevision: String? = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        isValid: Bool = true,
        invalidRecordCount: Int = 0,
        statuses: [String],
        evidence: [ManagedProjectTaskEvidenceReference] = [],
        updatedAt: String? = nil
    ) -> ManagedProjectTaskPlan {
        ManagedProjectTaskPlan(
            schemaVersion: schemaVersion,
            sourceAvailable: sourceAvailable,
            sourceRevision: sourceRevision,
            isValid: isValid,
            invalidRecordCount: invalidRecordCount,
            tasks: statuses.enumerated().map { index, status in
                ManagedProjectTaskPlanItem(
                    taskId: "task-\(index)",
                    title: "Task \(index)",
                    description: nil,
                    owner: "executor",
                    status: status,
                    updatedAt: updatedAt,
                    evidence: evidence
                )
            }
        )
    }
}

private actor SuspendingTaskPlanLoader {
    private let plan: ManagedProjectTaskPlan
    private var isReleased = false
    private var callCount = 0

    init(plan: ManagedProjectTaskPlan) {
        self.plan = plan
    }

    func load(
        for _: ManagedChatProjectIdentity
    ) async throws -> ManagedProjectTaskPlan {
        callCount += 1
        while !isReleased {
            try await Task.sleep(for: .milliseconds(5))
        }
        return plan
    }

    func release() {
        isReleased = true
    }

    func currentCallCount() -> Int {
        callCount
    }
}

private actor TaskPlanRefreshCompletion {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor FailingOnceTaskPlanLoader {
    private let plan: ManagedProjectTaskPlan
    private var callCount = 0

    init(plan: ManagedProjectTaskPlan) {
        self.plan = plan
    }

    func load(
        for _: ManagedChatProjectIdentity
    ) throws -> ManagedProjectTaskPlan {
        callCount += 1
        if callCount == 1 {
            throw TaskPlanLoaderTestError.authorityReadFailed
        }
        return plan
    }

    func currentCallCount() -> Int {
        callCount
    }
}

private enum TaskPlanLoaderTestError: LocalizedError {
    case authorityReadFailed

    var errorDescription: String? {
        "Authoritative task-plan read failed."
    }
}
