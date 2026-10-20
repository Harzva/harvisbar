import Darwin
import Foundation
import XCTest
@testable import HarvisBar

final class HarvisTaskProgressIsolationTests: XCTestCase {
    func testLegacyBarStatusIgnoresMalformedEmbeddedTaskProgressLane() throws {
        let status = try JSONDecoder().decode(
            BarStatus.self,
            from: Data(
                #"{"runtime":{"state":"verified","summary":"healthy"},"taskProgress":{"items":"malformed"}}"#.utf8
            )
        )

        XCTAssertEqual(status.runtime?.state, "verified")
        XCTAssertEqual(status.runtime?.summary, "healthy")
    }

    @MainActor
    func testHTTP400IsLocalAndPreservesLastSuccessAndGlobalState() async throws {
        let previous = try Self.snapshot(taskID: "last-success", percent: 40)
        let loader = HarvisTaskProgressOutcomeLoader([
            .failure(.httpStatus(400)),
        ])
        let model = makeModel(loader: loader, initial: previous)
        model.health = try JSONDecoder().decode(
            HealthData.self,
            from: Data(#"{"api_version":"v0.40-rust-alpha","auth_required":true}"#.utf8)
        )
        model.barStatus = try JSONDecoder().decode(
            BarStatus.self,
            from: Data(#"{"runtime":{"state":"verified","summary":"healthy"}}"#.utf8)
        )

        let successAt = model.taskProgressLastSuccessAt
        await model.refreshTaskProgress()

        XCTAssertEqual(model.taskProgressFailure, .httpRejected)
        XCTAssertEqual(model.taskProgressLastSuccess, previous)
        XCTAssertEqual(model.taskProgressLastSuccessAt, successAt)
        XCTAssertFalse(model.isTaskProgressRefreshing)
        XCTAssertEqual(model.health?.apiVersion, "v0.40-rust-alpha")
        XCTAssertEqual(model.barStatus?.runtime?.summary, "healthy")
        XCTAssertNil(model.lastError, "task-only failure must not create global Attention")
    }

    @MainActor
    func testPermissionFailureThenSuccessRecoversOnlyTaskLane() async throws {
        let old = try Self.snapshot(taskID: "old", percent: 20)
        let fresh = try Self.snapshot(taskID: "fresh", percent: 90)
        let loader = HarvisTaskProgressOutcomeLoader([
            .posixPermission,
            .success(fresh),
        ])
        let model = makeModel(loader: loader, initial: old)

        await model.refreshTaskProgress()
        XCTAssertEqual(model.taskProgressFailure, .permissionDenied)
        XCTAssertEqual(model.taskProgressLastSuccess?.current?.taskId, "old")
        XCTAssertNil(model.lastError)

        await model.refreshTaskProgress()
        XCTAssertNil(model.taskProgressFailure)
        XCTAssertEqual(model.taskProgressLastSuccess?.current?.taskId, "fresh")
        XCTAssertEqual(model.taskProgressLastSuccess?.current?.progress?.percent, 90)
        XCTAssertNil(model.lastError)
        let requestCount = await loader.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testLatestRequestWinsEvenWhenCancelledLoaderReturnsLate() async throws {
        let late = try Self.snapshot(taskID: "late-a", percent: 10)
        let winner = try Self.snapshot(taskID: "winner-b", percent: 80)
        let loader = HarvisTaskProgressLatestWinsLoader(firstResult: late, secondResult: winner)
        let model = makeModel(loader: loader)

        let first = Task { await model.refreshTaskProgress() }
        await loader.waitForRequestCount(1)
        let second = Task { await model.refreshTaskProgress() }
        await second.value

        XCTAssertEqual(model.taskProgressLastSuccess?.current?.taskId, "winner-b")
        let firstWasCancelled = await loader.firstRequestWasCancelled
        XCTAssertTrue(firstWasCancelled)
        await loader.releaseFirst()
        await first.value

        XCTAssertEqual(model.taskProgressLastSuccess?.current?.taskId, "winner-b")
        XCTAssertNil(model.taskProgressFailure)
        XCTAssertFalse(model.isTaskProgressRefreshing)
    }

    @MainActor
    func testCallerCancellationDoesNotPublishFailureOrEraseSnapshot() async throws {
        let previous = try Self.snapshot(taskID: "retained", percent: 55)
        let loader = HarvisTaskProgressCancellationLoader()
        let model = makeModel(loader: loader, initial: previous)

        let refresh = Task { await model.refreshTaskProgress() }
        await loader.waitUntilStarted()
        refresh.cancel()
        await refresh.value

        XCTAssertEqual(model.taskProgressLastSuccess, previous)
        XCTAssertNil(model.taskProgressFailure)
        XCTAssertFalse(model.isTaskProgressRefreshing)
        let observedCancellation = await loader.observedCancellation()
        XCTAssertTrue(observedCancellation)
    }

    @MainActor
    func testCallerCancellationDiscardsLateSuccessFromIgnoringLoader() async throws {
        let previous = try Self.snapshot(taskID: "retained", percent: 55)
        let late = try Self.snapshot(taskID: "late-success", percent: 99)
        let loader = HarvisTaskProgressCancellationIgnoringLoader(result: late)
        let model = makeModel(loader: loader, initial: previous)

        let refresh = Task { await model.refreshTaskProgress() }
        await loader.waitUntilStarted()
        refresh.cancel()
        await loader.release()
        await refresh.value

        XCTAssertEqual(model.taskProgressLastSuccess, previous)
        XCTAssertNil(model.taskProgressFailure)
        XCTAssertFalse(model.isTaskProgressRefreshing)
    }

    @MainActor
    private func makeModel(
        loader: any HarvisTaskProgressLoading,
        initial: TaskProgressStatus? = nil
    ) -> HarvisRuntimeModel {
        let suite = "HarvisTaskProgressIsolationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("/fixture/workspace", forKey: HarvisRuntimeModel.Keys.workspaceRoot)
        return HarvisRuntimeModel(
            defaults: defaults,
            taskProgressLoader: loader,
            taskProgressInitialSnapshot: initial
        )
    }

    private static func snapshot(taskID: String, percent: Double) throws -> TaskProgressStatus {
        try JSONDecoder().decode(
            TaskProgressStatus.self,
            from: Data(
                """
                {
                  "status":"active",
                  "summary":"one task",
                  "activeCount":1,
                  "current":{
                    "taskId":"\(taskID)",
                    "title":"Candidate",
                    "kind":"build",
                    "status":"active",
                    "summary":"Working",
                    "detail":"Local",
                    "progress":{"percent":\(percent),"current":1,"total":2,"unit":"steps"},
                    "metrics":{"elapsed":"1m","eta":"1m","speed":"1 step/m"},
                    "startedAt":"2026-08-30T00:00:00Z",
                    "updatedAt":"2026-08-30T00:01:00Z"
                  },
                  "items":[]
                }
                """.utf8
            )
        )
    }
}

private actor HarvisTaskProgressOutcomeLoader: HarvisTaskProgressLoading {
    enum Outcome: Sendable {
        case success(TaskProgressStatus)
        case failure(HarvisTaskProgressClientError)
        case posixPermission
    }

    private var outcomes: [Outcome]
    private var count = 0

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func load(_ request: HarvisTaskProgressLoadRequest) async throws -> TaskProgressStatus {
        count += 1
        guard !outcomes.isEmpty else { throw HarvisTaskProgressClientError.invalidEnvelope }
        switch outcomes.removeFirst() {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        case .posixPermission:
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
    }

    func requestCount() -> Int { count }
}

private actor HarvisTaskProgressLatestWinsLoader: HarvisTaskProgressLoading {
    private let firstResult: TaskProgressStatus
    private let secondResult: TaskProgressStatus
    private var count = 0
    private var firstContinuation: CheckedContinuation<TaskProgressStatus, Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var firstRequestWasCancelled = false

    init(firstResult: TaskProgressStatus, secondResult: TaskProgressStatus) {
        self.firstResult = firstResult
        self.secondResult = secondResult
    }

    func load(_ request: HarvisTaskProgressLoadRequest) async throws -> TaskProgressStatus {
        count += 1
        let requestNumber = count
        releaseCountWaiters()
        if requestNumber == 2 { return secondResult }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { firstContinuation = $0 }
        } onCancel: {
            Task { await self.recordFirstCancellation() }
        }
    }

    func waitForRequestCount(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { countWaiters.append((target, $0)) }
    }

    func releaseFirst() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(returning: firstResult)
    }

    private func recordFirstCancellation() {
        firstRequestWasCancelled = true
    }

    private func releaseCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, waiter) in countWaiters {
            if count >= target { waiter.resume() } else { remaining.append((target, waiter)) }
        }
        countWaiters = remaining
    }
}

private actor HarvisTaskProgressCancellationLoader: HarvisTaskProgressLoading {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load(_ request: HarvisTaskProgressLoadRequest) async throws -> TaskProgressStatus {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw HarvisTaskProgressClientError.invalidEnvelope
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func observedCancellation() -> Bool { cancelled }
}

private actor HarvisTaskProgressCancellationIgnoringLoader: HarvisTaskProgressLoading {
    private let result: TaskProgressStatus
    private var started = false
    private var continuation: CheckedContinuation<TaskProgressStatus, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: TaskProgressStatus) {
        self.result = result
    }

    func load(_ request: HarvisTaskProgressLoadRequest) async throws -> TaskProgressStatus {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}
