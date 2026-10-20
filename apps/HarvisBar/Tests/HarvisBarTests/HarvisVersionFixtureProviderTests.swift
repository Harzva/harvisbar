#if HARVIS_VERSION_UI_TESTING
import CryptoKit
import Foundation
import XCTest
@testable import HarvisBar
@testable import HarvisVersionCore

@MainActor
final class HarvisVersionFixtureProviderTests: XCTestCase {
    func testClosedArgumentParserRejectsArbitraryPayloadsAndDuplicates() throws {
        XCTAssertEqual(
            try HarvisVersionFixtureProvider.parseFixtureID(
                arguments: ["--harvis-version-fixture", "baseline-unbound"]
            ),
            .baselineUnbound
        )
        for arguments in [
            [String](),
            ["--harvis-version-fixture"],
            ["--harvis-version-fixture", "unknown"],
            ["--harvis-version-fixture", "/tmp/fixture.json"],
            ["--harvis-version-fixture", #"{"source":"/tmp"}"#],
            ["--harvis-version-fixture", "ready-exact", "extra"],
            ["--other", "baseline-unbound"],
        ] {
            XCTAssertThrowsError(
                try HarvisVersionFixtureProvider.parseFixtureID(arguments: arguments),
                "Unexpectedly accepted \(arguments)"
            )
        }
    }

    func testBootClearsSeedsAndAcknowledgesBeforePublishingFixture() throws {
        let defaults = RecordingFixtureDefaults()
        let provider = try HarvisVersionFixtureProvider(
            fixtureID: .persistedSourceOffline,
            defaults: defaults
        )

        XCTAssertEqual(defaults.calls, ["clear", "sync", "replace", "sync"])
        XCTAssertEqual(
            defaults.values[HarvisVersionFixtureProvider.fixtureSourcePreferenceKey] as? String,
            "/fixture/offline/source"
        )
        XCTAssertEqual(
            provider.bootEvents,
            [.defaultsCleared, .defaultsSeeded, .receiptAcknowledged]
        )
        XCTAssertEqual(provider.fixtureReceipt, "persisted-source-offline:ready")
        XCTAssertEqual(provider.initialSnapshot.source.status, .offline)
        XCTAssertEqual(provider.bootPolicy, .isolated)
    }

    func testDefaultsSynchronizationFailureStopsBeforeAcknowledgement() {
        let clearFailure = RecordingFixtureDefaults(synchronizeResults: [false])
        XCTAssertThrowsError(try HarvisVersionFixtureProvider(
            fixtureID: .baselineUnbound,
            defaults: clearFailure
        )) { error in
            XCTAssertEqual(error as? HarvisVersionFixtureProviderError, .defaultsSynchronizationFailed)
        }
        XCTAssertEqual(clearFailure.calls, ["clear", "sync"])

        let seedFailure = RecordingFixtureDefaults(synchronizeResults: [true, false])
        XCTAssertThrowsError(try HarvisVersionFixtureProvider(
            fixtureID: .baselineUnbound,
            defaults: seedFailure
        )) { error in
            XCTAssertEqual(error as? HarvisVersionFixtureProviderError, .defaultsSynchronizationFailed)
        }
        XCTAssertEqual(seedFailure.calls, ["clear", "sync", "replace", "sync"])
    }

    func testBaselineAndReadyExactSnapshotsMatchDeterministicContract() async throws {
        let baseline = try HarvisVersionFixtureProvider(
            fixtureID: .baselineUnbound,
            defaults: RecordingFixtureDefaults()
        )
        XCTAssertEqual(baseline.initialSnapshot.appIdentity.bundleIdentifier, "local.harzva.harvisbar.version-ui-test")
        XCTAssertEqual(baseline.initialSnapshot.appIdentity.version, "0.36.0")
        XCTAssertEqual(baseline.initialSnapshot.apiVersion, "v0.40-rust-alpha")
        XCTAssertEqual(baseline.initialSnapshot.receipt.status, .valid)
        XCTAssertEqual(baseline.initialSnapshot.source.status, .unbound)
        XCTAssertEqual(baseline.initialSnapshot.helper.status, .matched)

        let selected = await baseline.inspectSelectedSource()
        XCTAssertEqual(selected.status, .ready)
        XCTAssertEqual(selected.canonicalRepositoryRoot, "/fixture/harvis/main")
        XCTAssertEqual(selected.git?.branch, "codex/fixture-main")
        XCTAssertEqual(selected.git?.changedFileCount, 2)
        XCTAssertEqual(selected.git?.aheadCount, 2)
        XCTAssertEqual(selected.git?.behindCount, 1)
        XCTAssertEqual(selected.git?.observedAt, Date(timeIntervalSince1970: 1_787_961_600))
        XCTAssertEqual(selected.git?.remotes.first?.githubBrowseURL, "https://github.com/octocat/harvis-fixture")
        XCTAssertEqual(selected.git?.worktrees.count, 2)
        XCTAssertEqual(selected.alignment, .exact)

        let ready = try HarvisVersionFixtureProvider(
            fixtureID: .readyExact,
            defaults: RecordingFixtureDefaults()
        )
        XCTAssertEqual(ready.initialSnapshot.source, selected)
    }

    func testOfflineAndHelperMismatchAreLocalDegradations() throws {
        let offline = try HarvisVersionFixtureProvider(
            fixtureID: .sourceOffline,
            defaults: RecordingFixtureDefaults()
        )
        XCTAssertEqual(offline.initialSnapshot.source.status, .offline)
        XCTAssertTrue(offline.initialSnapshot.apiIsReady)
        XCTAssertEqual(offline.initialSnapshot.helper.status, .matched)
        XCTAssertEqual(offline.initialSnapshot.receipt.status, .valid)

        let mismatch = try HarvisVersionFixtureProvider(
            fixtureID: .helperMismatch,
            defaults: RecordingFixtureDefaults()
        )
        XCTAssertEqual(mismatch.initialSnapshot.source.status, .ready)
        XCTAssertEqual(mismatch.initialSnapshot.helper.status, .hashMismatch)
        XCTAssertEqual(mismatch.initialSnapshot.helper.helperFileStatus, .valid)
        XCTAssertEqual(mismatch.initialSnapshot.helper.receiptMatchStatus, .hashMismatch)
        XCTAssertEqual(mismatch.initialSnapshot.receipt.status, .valid)
    }

    func testCatalogModelUsesOnlyClosedSyntheticDependencies() async throws {
        let defaults = RecordingFixtureDefaults()
        let provider = try HarvisVersionFixtureProvider(
            fixtureID: .readyExact,
            defaults: defaults
        )
        let model = provider.makeCatalogModel()

        XCTAssertEqual(model.appIdentity, provider.initialSnapshot.appIdentity)
        XCTAssertEqual(model.stableHelperPath, "/fixture/home/.harvis/bin/harvis")
        XCTAssertEqual(model.selection, "/fixture/harvis/main")
        XCTAssertEqual(model.source.status, .offline)
        XCTAssertEqual(provider.sourceSelectionCandidate, "/fixture/harvis/main")
        XCTAssertEqual(provider.bootPolicy, .isolated)

        model.refresh()
        for _ in 0..<1_000 where model.isRefreshing {
            await Task.yield()
        }
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.receipt.status, .valid)
        XCTAssertEqual(model.source, provider.initialSnapshot.source)
        XCTAssertEqual(model.helper, provider.initialSnapshot.helper)
        XCTAssertEqual(model.apiVersion, "v0.40-rust-alpha")
    }

    func testLatestWinsUsesObservableBarriersWithoutSleep() async throws {
        let provider = try HarvisVersionFixtureProvider(
            fixtureID: .latestWins,
            defaults: RecordingFixtureDefaults()
        )
        XCTAssertNil(provider.fixtureReceipt)

        let aPending = expectation(description: "A inspection pending")
        provider.onFixtureReceiptChange = { value in
            if value == "latest-wins:a-pending" { aPending.fulfill() }
        }
        let taskA = Task { @MainActor in
            await provider.inspectSelectedSource()
        }
        await fulfillment(of: [aPending], timeout: 1)
        XCTAssertEqual(provider.fixtureReceipt, "latest-wins:a-pending")

        let validatedB = await provider.inspectSelectedSource()
        XCTAssertEqual(validatedB.canonicalRepositoryRoot, "/fixture/harvis/b")
        XCTAssertEqual(provider.fixtureReceipt, "latest-wins:a-pending")

        let sourceB = await provider.inspectSelectedSource()
        XCTAssertEqual(sourceB.canonicalRepositoryRoot, "/fixture/harvis/b")
        XCTAssertEqual(provider.fixtureReceipt, "latest-wins:b-published")
        XCTAssertTrue(provider.releaseLatestWinsA())
        XCTAssertFalse(provider.releaseLatestWinsA())

        let sourceA = await taskA.value
        XCTAssertEqual(sourceA.canonicalRepositoryRoot, "/fixture/harvis/a")
        XCTAssertTrue(provider.markLatestWinsACompletedDiscarded())
        XCTAssertEqual(provider.fixtureReceipt, "latest-wins:a-completed-discarded")
    }

    func testEffectSinksOnlyEmitSanitizedHashBoundReceipts() throws {
        let provider = try HarvisVersionFixtureProvider(
            fixtureID: .readyExact,
            defaults: RecordingFixtureDefaults()
        )
        XCTAssertFalse(provider.effects.openGitHub("https://user:secret@github.com/octocat/harvis-fixture"))
        XCTAssertNil(provider.effects.openerReceipt)
        XCTAssertTrue(provider.effects.openGitHub("https://github.com/octocat/harvis-fixture.git"))
        XCTAssertEqual(
            provider.effects.openerReceipt,
            "count=1 url=https://github.com/octocat/harvis-fixture"
        )

        provider.effects.copy("/fixture/harvis/main", kind: .source)
        XCTAssertEqual(
            provider.effects.clipboardReceipt,
            "count=1 kind=source valueSha256=\(sha256("/fixture/harvis/main"))"
        )
        XCTAssertFalse(provider.effects.showInFinder(canonicalPath: "/"))
        XCTAssertFalse(provider.effects.showInFinder(canonicalPath: "/fixture/../private"))
        XCTAssertTrue(provider.effects.showInFinder(canonicalPath: "/fixture/harvis/main"))
        XCTAssertEqual(
            provider.effects.finderReceipt,
            "count=1 canonicalPathSha256=\(sha256("/fixture/harvis/main"))"
        )
    }

    func testTaskProgressFixturesUseClosedRetryAndRecoveryBarriers() async throws {
        for (fixtureID, expectedFailure) in [
            (HarvisVersionFixtureID.taskProgressHTTP400, HarvisTaskProgressFailure.httpRejected),
            (.taskProgressPermissionFailed, .permissionDenied),
        ] {
            let provider = try HarvisVersionFixtureProvider(
                fixtureID: fixtureID,
                defaults: RecordingFixtureDefaults()
            )
            let loader = try XCTUnwrap(provider.makeTaskProgressLoader())
            let initial = try XCTUnwrap(provider.taskProgressInitialSnapshot)
            XCTAssertEqual(initial.current?.taskId, "retained-task")
            XCTAssertEqual(provider.bootPolicy, .isolated)

            do {
                _ = try await loader.load(Self.taskProgressRequest)
                XCTFail("the first closed request must degrade")
            } catch {
                let failure = HarvisTaskProgressFailure.classify(error)
                XCTAssertEqual(failure, expectedFailure)
                provider.acceptTaskProgressPublication(.failure(try XCTUnwrap(failure)))
            }
            XCTAssertEqual(
                provider.fixtureReceipt,
                "\(fixtureID.rawValue):degraded:count=1"
            )

            let retrying = expectation(description: "retrying barrier \(fixtureID.rawValue)")
            provider.onFixtureReceiptChange = { value in
                if value == "\(fixtureID.rawValue):retrying:count=2" {
                    retrying.fulfill()
                }
            }
            let retry = Task { try await loader.load(Self.taskProgressRequest) }
            await fulfillment(of: [retrying], timeout: 1)
            XCTAssertTrue(provider.releaseTaskProgressSuccess())
            XCTAssertFalse(provider.releaseTaskProgressSuccess())
            let recovered = try await retry.value
            XCTAssertEqual(recovered.current?.taskId, "recovered-task")
            provider.acceptTaskProgressPublication(.success)
            XCTAssertEqual(
                provider.fixtureReceipt,
                "\(fixtureID.rawValue):recovered:count=2"
            )
        }
    }

    func testNonTaskFixtureCannotCreateTaskLoader() throws {
        let provider = try HarvisVersionFixtureProvider(
            fixtureID: .readyExact,
            defaults: RecordingFixtureDefaults()
        )
        XCTAssertFalse(provider.isTaskProgressFixture)
        XCTAssertNil(provider.taskProgressInitialSnapshot)
        XCTAssertNil(provider.makeTaskProgressLoader())
        XCTAssertFalse(provider.releaseTaskProgressSuccess())
    }

    private static let taskProgressRequest = HarvisTaskProgressLoadRequest(
        port: 8_765,
        workspaceRoot: "/fixture/workspace",
        tokenFilePath: "/fixture/http.token"
    )

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class RecordingFixtureDefaults: HarvisVersionFixtureDefaultsWriting {
    private var synchronizeResults: [Bool]
    private(set) var calls: [String] = []
    private(set) var values: [String: Any] = [:]

    init(synchronizeResults: [Bool] = [true, true]) {
        self.synchronizeResults = synchronizeResults
    }

    func clearPersistentDomain() {
        calls.append("clear")
        values = [:]
    }

    func replacePersistentDomain(with values: [String: Any]) {
        calls.append("replace")
        self.values = values
    }

    func synchronize() -> Bool {
        calls.append("sync")
        return synchronizeResults.isEmpty ? true : synchronizeResults.removeFirst()
    }

    func readSourceRoot() throws -> String? {
        calls.append("read")
        guard let value = values[HarvisVersionFixtureProvider.fixtureSourcePreferenceKey] else {
            return nil
        }
        guard let sourceRoot = value as? String else {
            throw HarvisSourcePreferenceError.invalidStoredValue
        }
        return sourceRoot
    }

    func writeSourceRoot(_ sourceRoot: String?) throws {
        calls.append("write")
        values[HarvisVersionFixtureProvider.fixtureSourcePreferenceKey] = sourceRoot
    }
}
#endif
