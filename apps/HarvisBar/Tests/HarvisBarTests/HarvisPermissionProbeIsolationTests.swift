import Foundation
import XCTest
@testable import HarvisBar

final class HarvisPermissionProbeIsolationTests: XCTestCase {
    @MainActor
    func testOnlyExplicitFullProbeUsesExactQueryWhileBackgroundRefreshIsPassive() async throws {
        let loader = HarvisPermissionProbeSequenceLoader([
            .success(try Self.decode(Self.readyJSON)),
            .success(try Self.decode(Self.lightweightJSON)),
            .failure,
        ])
        let model = makeModel { query in
            try await loader.load(query)
        }
        model.lastError = "existing-global-message"
        let startedAt = Date(timeIntervalSince1970: 1_000)

        await model.refreshPermissionProbe(now: startedAt)
        let passiveRequestCount = await loader.requestCount()
        XCTAssertEqual(passiveRequestCount, 0)
        XCTAssertEqual(model.permissionVerificationState, .unverified)
        await model.refreshPermissionProbe(force: true, now: startedAt)

        XCTAssertEqual(model.permissionVerificationState, .verifiedReady)
        XCTAssertTrue(model.allowsAutomaticWorkspaceAccess)
        XCTAssertTrue(Self.fullDiskAccessStep(in: model).ok)
        XCTAssertEqual(model.permissionProbe?.checks?.count, 3)
        let initialRequestCount = await loader.requestCount()
        XCTAssertEqual(initialRequestCount, 1)
        let recordedQuery = await loader.query(at: 0)
        let firstQuery = try XCTUnwrap(recordedQuery)
        XCTAssertEqual(
            firstQuery.map { [$0.name, $0.value ?? ""] },
            [
                ["root", "/fixture/workspace"],
                ["profile_root", "/fixture/profile"],
                ["full", "true"],
            ]
        )

        await model.refreshPermissionProbe(now: startedAt.addingTimeInterval(1))
        let throttledRequestCount = await loader.requestCount()
        XCTAssertEqual(throttledRequestCount, 1, "the two-second lane must not repeat a full probe")

        await model.refreshPermissionProbe(
            force: true,
            now: startedAt.addingTimeInterval(2)
        )
        let explicitRequestCount = await loader.requestCount()
        XCTAssertEqual(explicitRequestCount, 2)
        XCTAssertEqual(model.permissionVerificationState, .verifiedReady)
        XCTAssertEqual(model.permissionProbe?.checks?.count, 3)
        XCTAssertEqual(model.lastError, "existing-global-message")

        await model.refreshPermissionProbe(
            now: startedAt.addingTimeInterval(
                HarvisRuntimeModel.fullPermissionProbeRefreshInterval + 2
            )
        )
        let expiredRequestCount = await loader.requestCount()
        XCTAssertEqual(expiredRequestCount, 2, "expiry must never schedule a write-backed probe")
        await model.refreshPermissionProbe(force: true, now: startedAt.addingTimeInterval(302))
        let finalExplicitCount = await loader.requestCount()
        XCTAssertEqual(finalExplicitCount, 3)
        XCTAssertEqual(model.permissionVerificationState, .stale)
        XCTAssertFalse(Self.fullDiskAccessStep(in: model).ok)
        XCTAssertEqual(model.permissionProbe?.checks?.count, 3, "the last complete projection stays available")
        XCTAssertEqual(model.lastError, "existing-global-message")
    }

    @MainActor
    func testOnlyExactFullThreeCheckResponseCanBecomeReady() async throws {
        let loader = HarvisPermissionProbeSequenceLoader([
            .success(try Self.decode(Self.lightweightJSON)),
            .success(try Self.decode(Self.wrongLabelsJSON)),
            .success(try Self.decode(Self.blockedJSON)),
            .success(try Self.decode(Self.readyJSON)),
        ])
        let model = makeModel { query in
            try await loader.load(query)
        }
        let startedAt = Date(timeIntervalSince1970: 2_000)

        await model.refreshPermissionProbe(force: true, now: startedAt)
        XCTAssertEqual(model.permissionVerificationState, .unverified)
        XCTAssertNil(model.permissionProbe)
        XCTAssertTrue(model.permissionProbeFailureMessage?.contains("未返回完整") == true)
        XCTAssertFalse(Self.fullDiskAccessStep(in: model).ok)

        await model.refreshPermissionProbe(
            force: true,
            now: startedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(model.permissionVerificationState, .unverified)
        XCTAssertNil(model.permissionProbe)

        await model.refreshPermissionProbe(
            force: true,
            now: startedAt.addingTimeInterval(2)
        )
        XCTAssertEqual(model.permissionVerificationState, .verifiedBlocked)
        XCTAssertNil(model.permissionProbeFailureMessage)
        XCTAssertEqual(model.permissionProbe?.checks?.count, 3)
        XCTAssertFalse(Self.fullDiskAccessStep(in: model).ok)

        await model.refreshPermissionProbe(
            force: true,
            now: startedAt.addingTimeInterval(3)
        )
        XCTAssertEqual(model.permissionVerificationState, .verifiedReady)
        XCTAssertNil(model.permissionProbeFailureMessage)
        XCTAssertTrue(Self.fullDiskAccessStep(in: model).ok)
    }

    @MainActor
    func testExplicitProbeFailuresUseDedicatedFeedbackAndSuccessOrScopeChangeClearsIt() async throws {
        let loader = HarvisPermissionProbeSequenceLoader([
            .failure,
            .timeout,
            .success(try Self.decode(Self.readyJSON)),
            .failure,
        ])
        let model = makeModel { try await loader.load($0) }
        model.lastError = "unrelated-global-message"

        await model.refreshPermissionProbe(force: true)
        XCTAssertTrue(model.permissionProbeFailureMessage?.contains("本地服务未连接") == true)
        XCTAssertEqual(model.lastError, "unrelated-global-message")
        XCTAssertNil(model.permissionProbe)
        XCTAssertEqual(model.permissionVerificationState, .unverified)

        await model.refreshPermissionProbe(force: true)
        XCTAssertTrue(model.permissionProbeFailureMessage?.contains("响应超时") == true)
        XCTAssertEqual(model.lastError, "unrelated-global-message")

        await model.refreshPermissionProbe(force: true)
        XCTAssertNil(model.permissionProbeFailureMessage)
        XCTAssertEqual(model.permissionVerificationState, .verifiedReady)
        XCTAssertEqual(model.lastError, "unrelated-global-message")

        await model.refreshPermissionProbe(force: true)
        XCTAssertNotNil(model.permissionProbeFailureMessage)
        model.profileRoot = "/fixture/other-profile"
        XCTAssertNil(model.permissionProbeFailureMessage)
        XCTAssertEqual(model.lastError, "unrelated-global-message")
    }

    @MainActor
    func testScopeChangeInvalidatesVerificationAndBypassesThrottle() async throws {
        let loader = HarvisPermissionProbeSequenceLoader([
            .success(try Self.decode(Self.readyJSON)),
            .success(try Self.decode(Self.readyJSON)),
        ])
        let model = makeModel { query in
            try await loader.load(query)
        }
        let startedAt = Date(timeIntervalSince1970: 2_500)

        await model.refreshPermissionProbe(force: true, now: startedAt)
        XCTAssertEqual(model.permissionVerificationState, .verifiedReady)

        model.workspaceRoot = "/fixture/other-workspace"
        XCTAssertEqual(model.permissionVerificationState, .unverified)
        XCTAssertNil(model.permissionProbe)
        XCTAssertNil(model.lastFullPermissionProbeAttemptAt)

        await model.refreshPermissionProbe(force: true, now: startedAt.addingTimeInterval(1))
        let requestCount = await loader.requestCount()
        XCTAssertEqual(requestCount, 2, "new authority scope must not inherit the old throttle")
        let secondQuery = await loader.query(at: 1)
        let recordedQuery = try XCTUnwrap(secondQuery)
        XCTAssertEqual(recordedQuery.first?.value, "/fixture/other-workspace")
        XCTAssertEqual(model.permissionVerificationState, .verifiedReady)

        model.portText = "9876"
        XCTAssertEqual(model.permissionVerificationState, .unverified)
        XCTAssertNil(model.permissionProbe)
    }

    @MainActor
    func testLatestFullProbeWinsWhenCancelledLoaderReturnsLate() async throws {
        let loader = HarvisPermissionProbeLatestWinsLoader(
            firstResult: try Self.decode(Self.blockedJSON),
            secondResult: try Self.decode(Self.readyJSON)
        )
        let model = makeModel { query in
            await loader.load(query)
        }
        let startedAt = Date(timeIntervalSince1970: 3_000)

        let first = Task {
            await model.refreshPermissionProbe(force: true, now: startedAt)
        }
        await loader.waitForRequestCount(1)
        let second = Task {
            await model.refreshPermissionProbe(
                force: true,
                now: startedAt.addingTimeInterval(1)
            )
        }
        await second.value

        XCTAssertEqual(model.permissionVerificationState, .verifiedReady)
        let firstWasCancelled = await loader.firstRequestWasCancelled()
        XCTAssertTrue(firstWasCancelled)

        await loader.releaseFirst()
        await first.value

        XCTAssertEqual(model.permissionVerificationState, .verifiedReady)
        XCTAssertTrue(Self.fullDiskAccessStep(in: model).ok)
        XCTAssertFalse(model.isPermissionProbeRefreshing)
    }

    @MainActor
    func testCallerCancellationDiscardsLateFullProbeAndLeavesGlobalStateUntouched() async throws {
        let loader = HarvisPermissionProbeCancellationIgnoringLoader(
            result: try Self.decode(Self.readyJSON)
        )
        let model = makeModel { query in
            await loader.load(query)
        }
        model.lastError = "unrelated-global-message"

        let refresh = Task {
            await model.refreshPermissionProbe(
                force: true,
                now: Date(timeIntervalSince1970: 4_000)
            )
        }
        await loader.waitUntilStarted()
        refresh.cancel()
        await loader.release()
        await refresh.value

        XCTAssertEqual(model.permissionVerificationState, .unverified)
        XCTAssertNil(model.permissionProbe)
        XCTAssertNil(model.lastFullPermissionProbeAttemptAt)
        XCTAssertFalse(model.isPermissionProbeRefreshing)
        XCTAssertEqual(model.lastError, "unrelated-global-message")
    }

    @MainActor
    private func makeModel(
        loader: @escaping HarvisRuntimeModel.PermissionProbeLoader
    ) -> HarvisRuntimeModel {
        let suite = "HarvisPermissionProbeIsolationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("/fixture/workspace", forKey: HarvisRuntimeModel.Keys.workspaceRoot)
        defaults.set("/fixture/profile", forKey: HarvisRuntimeModel.Keys.profileRoot)
        return HarvisRuntimeModel(
            defaults: defaults,
            permissionProbeLoader: loader
        )
    }

    @MainActor
    func testDeniedExplicitCheckNeverRetriesInBackgroundAndStartWaitsForGuide() async throws {
        let loader = HarvisPermissionProbeSequenceLoader([.success(try Self.decode(Self.blockedJSON))])
        let model = makeModel { try await loader.load($0) }
        model.start()
        XCTAssertNil(model.timer); XCTAssertNil(model.startupTasks)
        await model.refreshPermissionProbe(force: true, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(model.permissionVerificationState, .verifiedBlocked)
        XCTAssertFalse(model.allowsAutomaticWorkspaceAccess)
        for offset in [1.0, 301, 3_600, 86_400] {
            await model.refreshPermissionProbe(now: Date(timeIntervalSince1970: 100 + offset))
        }
        let count = await loader.requestCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.permissionVerificationState, .stale)
        XCTAssertFalse(Self.fullDiskAccessStep(in: model).ok)
    }

    @MainActor
    private static func fullDiskAccessStep(in model: HarvisRuntimeModel) -> FirstRunStep {
        model.firstRunSteps.first { $0.title == "Workspace Access" }!
    }

    private static func decode(_ json: String) throws -> HarvisFullPermissionProbePayload {
        try JSONDecoder().decode(
            HarvisFullPermissionProbePayload.self,
            from: Data(json.utf8)
        )
    }

    private static let readyJSON = #"""
    {
      "ok": true,
      "context": "rust-http-api",
      "redacted": true,
      "includesLocalAbsolutePaths": false,
      "checks": [
        {"label":"workspace-root","ok":true,"exists":true,"writable":true},
        {"label":"workspace-harvis","ok":true,"exists":true,"writable":true},
        {"label":"profile-root","ok":true,"exists":true,"writable":true}
      ]
    }
    """#

    private static let lightweightJSON = #"""
    {
      "ok": true,
      "context": "rust-http-api-lightweight",
      "redacted": true,
      "includesLocalAbsolutePaths": false,
      "writesSkipped": true,
      "checks": []
    }
    """#

    private static let wrongLabelsJSON = #"""
    {
      "ok": true,
      "context": "rust-http-api",
      "redacted": true,
      "includesLocalAbsolutePaths": false,
      "writesSkipped": false,
      "checks": [
        {"label":"workspace-root","ok":true,"exists":true,"writable":true},
        {"label":"workspace-root","ok":true,"exists":true,"writable":true},
        {"label":"profile-root","ok":true,"exists":true,"writable":true}
      ]
    }
    """#

    private static let blockedJSON = #"""
    {
      "ok": false,
      "context": "rust-http-api",
      "redacted": true,
      "includesLocalAbsolutePaths": false,
      "writesSkipped": false,
      "checks": [
        {"label":"workspace-root","ok":true,"exists":true,"writable":true},
        {"label":"workspace-harvis","ok":false,"exists":true,"writable":false},
        {"label":"profile-root","ok":true,"exists":true,"writable":true}
      ]
    }
    """#
}

private actor HarvisPermissionProbeSequenceLoader {
    enum Outcome: Sendable {
        case success(HarvisFullPermissionProbePayload)
        case failure
        case timeout
    }

    private var outcomes: [Outcome]
    private var queries: [[URLQueryItem]] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func load(_ query: [URLQueryItem]) throws -> HarvisFullPermissionProbePayload {
        queries.append(query)
        guard !outcomes.isEmpty else { throw URLError(.cannotConnectToHost) }
        switch outcomes.removeFirst() {
        case .success(let payload):
            return payload
        case .failure:
            throw URLError(.cannotConnectToHost)
        case .timeout:
            throw HarvisBarError.timeout("/permission-probe")
        }
    }

    func requestCount() -> Int { queries.count }

    func query(at index: Int) -> [URLQueryItem]? {
        queries.indices.contains(index) ? queries[index] : nil
    }
}

private actor HarvisPermissionProbeLatestWinsLoader {
    private let firstResult: HarvisFullPermissionProbePayload
    private let secondResult: HarvisFullPermissionProbePayload
    private var count = 0
    private var cancelled = false
    private var firstContinuation: CheckedContinuation<HarvisFullPermissionProbePayload, Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        firstResult: HarvisFullPermissionProbePayload,
        secondResult: HarvisFullPermissionProbePayload
    ) {
        self.firstResult = firstResult
        self.secondResult = secondResult
    }

    func load(_ query: [URLQueryItem]) async -> HarvisFullPermissionProbePayload {
        count += 1
        releaseCountWaiters()
        if count == 2 { return secondResult }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { firstContinuation = $0 }
        } onCancel: {
            Task { await self.recordCancellation() }
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

    func firstRequestWasCancelled() -> Bool { cancelled }

    private func recordCancellation() {
        cancelled = true
    }

    private func releaseCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, waiter) in countWaiters {
            if count >= target {
                waiter.resume()
            } else {
                remaining.append((target, waiter))
            }
        }
        countWaiters = remaining
    }
}

private actor HarvisPermissionProbeCancellationIgnoringLoader {
    private let result: HarvisFullPermissionProbePayload
    private var started = false
    private var continuation: CheckedContinuation<HarvisFullPermissionProbePayload, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: HarvisFullPermissionProbePayload) {
        self.result = result
    }

    func load(_ query: [URLQueryItem]) async -> HarvisFullPermissionProbePayload {
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
