import Combine
import Foundation
@testable import HarvisVersionCore
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisVersionCatalogTests: XCTestCase {
    func testLateRefreshCannotOverwriteNewSelection() async {
        let store = RecordingSourcePreferenceStore()
        let deferred = DeferredFirstSourceInspection()
        let model = makeModel(
            store: store,
            inspectSource: { selected, _ in
                await deferred.inspect(selected: selected)
            },
            validateSource: { _, _ in Self.readySource(root: "/fixture/b") }
        )

        model.refresh()
        await deferred.waitUntilStarted()
        let firstRequestID = model.refreshRequestID
        let firstGeneration = model.refreshGeneration

        await model.chooseSource(path: "/fixture/b/child")
        let secondRequestID = model.refreshRequestID
        XCTAssertNotEqual(firstRequestID, secondRequestID)
        XCTAssertGreaterThan(model.refreshGeneration, firstGeneration)
        XCTAssertEqual(model.selectionEpoch, 1)
        await waitForRefresh(model)
        XCTAssertEqual(model.source.canonicalRepositoryRoot, "/fixture/b")

        await deferred.release(Self.readySource(root: "/fixture/a"))
        await deferred.waitUntilCompleted()
        await Task.yield()

        XCTAssertEqual(model.selection, "/fixture/b")
        XCTAssertEqual(model.source.canonicalRepositoryRoot, "/fixture/b")
        XCTAssertEqual(model.alignment, .exact)
        XCTAssertEqual(store.writes, ["/fixture/b"])
    }

    func testInvalidAndCancelledSelectionsPerformZeroWritesAndKeepPriorSource() async {
        let store = RecordingSourcePreferenceStore(initial: "/fixture/a")
        let validation = DeferredValidation()
        let model = makeModel(
            store: store,
            inspectSource: { selected, _ in
                selected.map(Self.readySource(root:))
                    ?? HarvisSourceInspection(status: .unbound, selectedPath: nil)
            },
            validateSource: { path, _ in
                if path == "/fixture/invalid" {
                    return HarvisSourceInspection(status: .notHarvis, selectedPath: path)
                }
                return await validation.value()
            }
        )
        model.refresh()
        await waitForRefresh(model)
        let originalSource = model.source
        let originalEpoch = model.selectionEpoch

        await model.chooseSource(path: "/fixture/invalid")
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(model.selectionEpoch, originalEpoch)
        XCTAssertEqual(model.source, originalSource)
        XCTAssertEqual(model.error, "所选目录不是 Harvis 源码仓库。")

        let cancelled = Task { @MainActor in
            await model.chooseSource(path: "/fixture/cancelled")
        }
        await validation.waitUntilStarted()
        cancelled.cancel()
        await validation.release(Self.readySource(root: "/fixture/cancelled"))
        await cancelled.value

        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(model.selection, "/fixture/a")
        XCTAssertEqual(model.selectionEpoch, originalEpoch)
        XCTAssertEqual(model.source, originalSource)
    }

    func testSuccessfulSelectionWritesCanonicalTopLevelExactlyOnce() async {
        let store = RecordingSourcePreferenceStore()
        let model = makeModel(
            store: store,
            inspectSource: { selected, _ in
                selected.map(Self.readySource(root:))
                    ?? HarvisSourceInspection(status: .unbound, selectedPath: nil)
            },
            validateSource: { _, _ in Self.readySource(root: "/canonical/harvis") }
        )

        await model.chooseSource(path: "/canonical/harvis/nested")

        XCTAssertEqual(store.writes, ["/canonical/harvis"])
        XCTAssertEqual(model.selection, "/canonical/harvis")
        XCTAssertEqual(model.selectionEpoch, 1)
        await waitForRefresh(model)
        XCTAssertEqual(model.source.canonicalRepositoryRoot, "/canonical/harvis")
    }

    func testFixedScopeStoreSurvivesModelRecreationAndClearReturnsToUnbound() async throws {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        let store = HarvisSourcePreferenceStore(testApplicationID: suite)
        try store.writeSourceRoot(nil)
        defer { try? store.writeSourceRoot(nil) }

        var first: HarvisVersionCatalogModel? = makeModel(
            store: store,
            inspectSource: { selected, _ in
                selected.map(Self.readySource(root:))
                    ?? HarvisSourceInspection(status: .unbound, selectedPath: nil)
            },
            validateSource: { _, _ in Self.readySource(root: "/persisted/harvis") }
        )
        await first?.chooseSource(path: "/persisted/harvis/child")
        XCTAssertEqual(try store.readSourceRoot(), "/persisted/harvis")
        first?.cancelRefresh()
        first = nil

        let second = makeModel(store: store)
        XCTAssertEqual(second.selection, "/persisted/harvis")
        XCTAssertEqual(second.source.status, .offline)
        XCTAssertEqual(second.source.selectedPath, "/persisted/harvis")

        second.clearSource()
        XCTAssertNil(try store.readSourceRoot())
        second.cancelRefresh()

        let third = makeModel(store: store)
        XCTAssertNil(third.selection)
        XCTAssertEqual(third.source.status, .unbound)
    }

    func testInvalidStoredAuthorityIsPreservedWithoutFallback() async {
        let raw = "relative/source\n\u{202E}"
        let store = RecordingSourcePreferenceStore(initial: raw)
        let observed = SelectedDirectoryRecorder()
        let model = makeModel(
            store: store,
            inspectSource: { selected, _ in
                await observed.record(selected)
                return HarvisSourceInspection(status: .offline, selectedPath: selected)
            }
        )

        XCTAssertEqual(model.selection, raw)
        XCTAssertEqual(model.source.status, .offline)
        XCTAssertEqual(model.source.selectedPath, raw)
        model.refresh()
        await waitForRefresh(model)

        let observedValues = await observed.values()
        XCTAssertEqual(observedValues, [raw])
        XCTAssertEqual(model.source.status, .offline)
        XCTAssertEqual(model.source.selectedPath, raw)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testReceiptFailureDoesNotBlankIndependentSourceAndHelperCards() async {
        let source = Self.readySource(root: "/fixture/harvis")
        let helper = Self.matchedHelper()
        let dependencies = HarvisVersionCatalogDependencies(
            inspectReceipt: { throw SyntheticFailure.failed },
            inspectSource: { _, _ in source },
            inspectHelper: { _ in helper }
        )
        let model = HarvisVersionCatalogModel(
            appIdentity: Self.appIdentity,
            stableHelperPath: "/fixture/home/.harvis/bin/harvis",
            preferences: RecordingSourcePreferenceStore(initial: "/fixture/harvis"),
            dependencies: dependencies,
            apiVersionProvider: { "v0.40-rust-alpha" }
        )

        model.refresh()
        await waitForRefresh(model)

        XCTAssertEqual(model.receipt.status, .ioFailure)
        XCTAssertEqual(model.source, source)
        XCTAssertEqual(model.helper, helper)
        XCTAssertEqual(model.alignment, .exact)
        XCTAssertEqual(model.apiVersion, "v0.40-rust-alpha")
        XCTAssertNotNil(model.error)
    }

    func testAPIVersionUpdatesFromInitialNilToNormalizedReadyWithoutRefresh() async {
        let updates = PassthroughSubject<String?, Never>()
        let model = makeModel(
            apiVersionProvider: { nil },
            apiVersionUpdates: updates.eraseToAnyPublisher()
        )
        XCTAssertNil(model.apiVersion)

        let published = expectation(description: "normalized API version published")
        let cancellable = model.$apiVersion
            .dropFirst()
            .sink { value in
                if value == "v0.40-rust-alpha" {
                    published.fulfill()
                }
            }

        updates.send("  v0.40-rust-alpha\n")
        await fulfillment(of: [published], timeout: 2)

        XCTAssertEqual(model.apiVersion, "v0.40-rust-alpha")
        withExtendedLifetime(cancellable) {}
    }

    func testAPIVersionUpdatesSuppressNormalizedDuplicates() async {
        let updates = PassthroughSubject<String?, Never>()
        let model = makeModel(
            apiVersionProvider: { "v0.40-rust-alpha" },
            apiVersionUpdates: updates.eraseToAnyPublisher()
        )
        let noDuplicate = expectation(description: "no duplicate publication")
        noDuplicate.isInverted = true
        let cancellable = model.$apiVersion
            .dropFirst()
            .sink { _ in noDuplicate.fulfill() }

        updates.send(" v0.40-rust-alpha ")
        updates.send("v0.40-rust-alpha\n")
        await fulfillment(of: [noDuplicate], timeout: 0.2)

        XCTAssertEqual(model.apiVersion, "v0.40-rust-alpha")
        withExtendedLifetime(cancellable) {}
    }

    func testAPIVersionBurstPublishesOnlyLatestValueIncludingNilTransition() async {
        let updates = PassthroughSubject<String?, Never>()
        let model = makeModel(
            apiVersionProvider: { nil },
            apiVersionUpdates: updates.eraseToAnyPublisher()
        )
        let latest = expectation(description: "latest API version published")
        let stale = expectation(description: "no superseded API version published")
        stale.isInverted = true
        var observed: [String?] = []
        let cancellable = model.$apiVersion
            .dropFirst()
            .sink { value in
                observed.append(value)
                if value == "v-latest" {
                    latest.fulfill()
                } else {
                    stale.fulfill()
                }
            }

        updates.send("v-stale")
        updates.send(nil)
        updates.send("v-latest")
        await fulfillment(of: [latest, stale], timeout: 0.25)

        XCTAssertEqual(observed, ["v-latest"])
        XCTAssertEqual(model.apiVersion, "v-latest")
        withExtendedLifetime(cancellable) {}
    }

    func testManualRefreshInvalidatesQueuedPublisherValue() async {
        let updates = PassthroughSubject<String?, Never>()
        let provider = APIVersionProviderState(value: "v-initial")
        let model = makeModel(
            apiVersionProvider: { provider.value },
            apiVersionUpdates: updates.eraseToAnyPublisher()
        )
        let current = expectation(description: "manual snapshot published")
        let stale = expectation(description: "queued publisher value remains invalidated")
        stale.isInverted = true
        var observed: [String?] = []
        let cancellable = model.$apiVersion
            .dropFirst()
            .sink { value in
                observed.append(value)
                if value == "v-provider-current" {
                    current.fulfill()
                } else if value == "v-queued-stale" {
                    stale.fulfill()
                }
            }

        updates.send("v-queued-stale")
        provider.value = "v-provider-current"
        model.refresh()
        await fulfillment(of: [current, stale], timeout: 0.25)
        await waitForRefresh(model)

        XCTAssertEqual(observed, ["v-provider-current"])
        XCTAssertEqual(model.apiVersion, "v-provider-current")
        model.cancelRefresh()
        withExtendedLifetime(cancellable) {}
    }

    func testAPIVersionUpdateSubscriptionCancelsWhenModelIsReleased() {
        let updates = PassthroughSubject<String?, Never>()
        let lifetime = SubscriptionLifetimeRecorder()
        let publisher = updates
            .handleEvents(
                receiveSubscription: { _ in lifetime.recordSubscription() },
                receiveCancel: { lifetime.recordCancellation() }
            )
            .eraseToAnyPublisher()

        var model: HarvisVersionCatalogModel? = makeModel(
            apiVersionProvider: { nil },
            apiVersionUpdates: publisher
        )
        XCTAssertNotNil(model)
        XCTAssertEqual(lifetime.subscriptionCount, 1)

        model = nil

        XCTAssertEqual(lifetime.cancellationCount, 1)
        updates.send("v-after-release")
        XCTAssertEqual(lifetime.cancellationCount, 1)
    }

    private func makeModel(
        store: any HarvisSourcePreferenceStoring = RecordingSourcePreferenceStore(),
        inspectSource: HarvisVersionCatalogDependencies.SourceInspector? = nil,
        validateSource: HarvisVersionCatalogDependencies.SourceValidator? = nil,
        apiVersionProvider: @escaping @MainActor () -> String? = {
            "v0.40-rust-alpha"
        },
        apiVersionUpdates: AnyPublisher<String?, Never>? = nil
    ) -> HarvisVersionCatalogModel {
        let resolvedInspector: HarvisVersionCatalogDependencies.SourceInspector = inspectSource
            ?? { selected, _ in
                selected.map(HarvisVersionCatalogTests.readySource(root:))
                    ?? HarvisSourceInspection(status: .unbound, selectedPath: nil)
            }
        return HarvisVersionCatalogModel(
            appIdentity: Self.appIdentity,
            stableHelperPath: "/fixture/home/.harvis/bin/harvis",
            preferences: store,
            dependencies: HarvisVersionCatalogDependencies(
                inspectReceipt: { HarvisBundleReceiptInspection(status: .missing) },
                inspectSource: resolvedInspector,
                validateSource: validateSource,
                inspectHelper: { _ in Self.matchedHelper() }
            ),
            apiVersionProvider: apiVersionProvider,
            apiVersionUpdates: apiVersionUpdates
        )
    }

    private func waitForRefresh(
        _ model: HarvisVersionCatalogModel,
        timeout: TimeInterval = 2
    ) async {
        guard model.isRefreshing else { return }
        let finished = expectation(description: "catalog refresh completed")
        var cancellable: AnyCancellable?
        cancellable = model.$isRefreshing.sink { isRefreshing in
            if !isRefreshing { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: timeout)
        withExtendedLifetime(cancellable) {}
    }

    private static let appIdentity = HarvisAppIdentity(
        bundleIdentifier: "local.harzva.harvisbar",
        executable: "HarvisBar",
        version: "0.36.0"
    )

    fileprivate nonisolated static func readySource(root: String) -> HarvisSourceInspection {
        let commit = String(repeating: root.hasSuffix("b") ? "2" : "1", count: 40)
        let git = HarvisSourceGitSummary(
            repositoryRoot: root,
            headState: .attached,
            branch: "codex/test",
            headCommit: commit,
            changedFileCount: 0,
            upstream: nil,
            aheadCount: 0,
            behindCount: 0,
            isShallow: false,
            trackingSnapshotMayBeStale: true,
            trackingSnapshotIncomplete: false,
            observedAt: Date(timeIntervalSince1970: 1_787_961_600),
            remotes: [],
            worktrees: []
        )
        return HarvisSourceInspection(
            status: .ready,
            selectedPath: root,
            canonicalRepositoryRoot: root,
            git: git,
            alignmentEvidence: HarvisAlignmentEvidence(
                sourceCommit: commit,
                receiptCommit: commit,
                receiptObject: .positive,
                receiptIsAncestorOfSource: .positive,
                sourceIsAncestorOfReceipt: .positive,
                sourceIsShallow: false
            )
        )
    }

    private nonisolated static func matchedHelper() -> HarvisStableHelperSummary {
        HarvisStableHelperSummary(
            httpLaunchBindingStatus: .valid,
            tickLaunchBindingStatus: .valid,
            helperFileStatus: .valid,
            receiptMatchStatus: .matched,
            sizeBytes: 1_048_576,
            sha256: String(repeating: "a", count: 64)
        )
    }
}

@MainActor
private final class APIVersionProviderState {
    var value: String?

    init(value: String?) {
        self.value = value
    }
}

private enum SyntheticFailure: Error {
    case failed
}

private final class SubscriptionLifetimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions = 0
    private var cancellations = 0

    var subscriptionCount: Int {
        lock.withLock { subscriptions }
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    func recordSubscription() {
        lock.withLock { subscriptions += 1 }
    }

    func recordCancellation() {
        lock.withLock { cancellations += 1 }
    }
}

private final class RecordingSourcePreferenceStore: HarvisSourcePreferenceStoring {
    private(set) var value: String?
    private(set) var writes: [String?] = []

    init(initial: String? = nil) {
        value = initial
    }

    func readSourceRoot() throws -> String? {
        value
    }

    func writeSourceRoot(_ sourceRoot: String?) throws {
        writes.append(sourceRoot)
        value = sourceRoot
    }
}

private actor SelectedDirectoryRecorder {
    private var recorded: [String?] = []

    func record(_ value: String?) {
        recorded.append(value)
    }

    func values() -> [String?] {
        recorded
    }
}

private actor DeferredFirstSourceInspection {
    private var started = false
    private var completed = false
    private var continuation: CheckedContinuation<HarvisSourceInspection, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var completedWaiters: [CheckedContinuation<Void, Never>] = []

    func inspect(selected: String?) async -> HarvisSourceInspection {
        guard selected == nil else {
            return HarvisVersionCatalogTests.readySource(root: selected!)
        }
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        let value = await withCheckedContinuation { continuation = $0 }
        completed = true
        completedWaiters.forEach { $0.resume() }
        completedWaiters.removeAll()
        return value
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release(_ value: HarvisSourceInspection) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func waitUntilCompleted() async {
        guard !completed else { return }
        await withCheckedContinuation { completedWaiters.append($0) }
    }
}

private actor DeferredValidation {
    private var started = false
    private var continuation: CheckedContinuation<HarvisSourceInspection, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func value() async -> HarvisSourceInspection {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release(_ value: HarvisSourceInspection) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
