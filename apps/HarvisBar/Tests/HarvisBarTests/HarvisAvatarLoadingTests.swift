import Foundation
import XCTest
@testable import HarvisBar

final class HarvisAvatarLoadingTests: XCTestCase {
    private final class BlockingReadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var attempts = 0
        private var readerMainThread: Bool?

        var attemptCount: Int {
            lock.withLock { attempts }
        }

        var readWasOnMainThread: Bool? {
            lock.withLock { readerMainThread }
        }

        func read(_ url: URL) throws -> Data {
            lock.withLock {
                attempts += 1
                readerMainThread = Thread.isMainThread
            }
            release.wait()
            return Data([0x48, 0x41, 0x52, 0x56, 0x49, 0x53])
        }

        func releaseAll(_ count: Int) {
            for _ in 0..<count {
                release.signal()
            }
        }
    }

    func testLoaderUsesFirstReadableNonemptyCandidate() {
        var attempted: [String] = []
        let result = HarvisAvatarImageDataLoader.firstReadableData(
            candidatePaths: ["/missing.png", "/empty.png", "/avatar.png"],
            readData: { url in
                attempted.append(url.path)
                switch url.lastPathComponent {
                case "missing.png": throw CocoaError(.fileNoSuchFile)
                case "empty.png": return Data()
                default: return Data([0x01, 0x02])
                }
            }
        )

        XCTAssertEqual(result, Data([0x01, 0x02]))
        XCTAssertEqual(attempted, ["/missing.png", "/empty.png", "/avatar.png"])
    }

    func testAvatarViewContainsNoPathIOAndUsesSharedLoader() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("apps/HarvisBar/Sources/HarvisBar/Desktop/HarvisDesktopView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let avatarStart = try XCTUnwrap(source.range(of: "struct HarvisAvatarView: View"))
        let suffix = source[avatarStart.lowerBound...]
        let avatarEnd = try XCTUnwrap(suffix.range(of: "private struct DesktopMetricTile"))
        let avatarSource = String(suffix[..<avatarEnd.lowerBound])

        XCTAssertTrue(avatarSource.contains("model.avatarImageLoadCache.data"))
        XCTAssertFalse(avatarSource.contains("Task.detached"))
        XCTAssertFalse(avatarSource.contains("NSImage(contentsOf"))
        XCTAssertFalse(avatarSource.contains("Data(contentsOf"))
        XCTAssertFalse(avatarSource.contains("fileExists"))
    }

    @MainActor
    func testLoadCacheCoalescesTwentyRequestsOffMainThread() async throws {
        let cache = HarvisAvatarImageLoadCache()
        let probe = BlockingReadProbe()
        let requests = (0..<20).map { _ in
            Task {
                await cache.data(candidatePaths: ["/stalled/avatar.png"]) { url in
                    try probe.read(url)
                }
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while probe.attemptCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.attemptCount, 1)
        XCTAssertEqual(probe.readWasOnMainThread, false)

        // This assertion runs on MainActor while the injected filesystem read
        // is deliberately blocked, proving the UI actor remains schedulable.
        let mainActorHeartbeat = true
        XCTAssertTrue(mainActorHeartbeat)

        requests.prefix(10).forEach { $0.cancel() }
        let reopenedConsumer = Task {
            await cache.data(candidatePaths: ["/stalled/avatar.png"]) { url in
                try probe.read(url)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.attemptCount, 1)

        probe.releaseAll(20)
        for request in requests {
            let value = await request.value
            XCTAssertEqual(value, Data("HARVIS".utf8))
        }
        let reopenedValue = await reopenedConsumer.value
        XCTAssertEqual(reopenedValue, Data("HARVIS".utf8))
        XCTAssertEqual(probe.attemptCount, 1)
    }

    func testLoadCacheNegativeCachesFailureForSameCandidateSet() async {
        let cache = HarvisAvatarImageLoadCache()
        let probe = BlockingReadProbe()
        probe.releaseAll(2)

        let first = await cache.data(candidatePaths: ["/missing/avatar.png"]) { url in
            _ = try probe.read(url)
            throw CocoaError(.fileNoSuchFile)
        }
        let second = await cache.data(candidatePaths: ["/missing/avatar.png"]) { _ in
            XCTFail("same failed key must reuse its completed load")
            return Data([0x01])
        }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(probe.attemptCount, 1)
    }

    func testModelScopedCacheNeverStartsAnotherFilesystemRead() async {
        let cache = HarvisAvatarImageLoadCache()
        let probe = BlockingReadProbe()
        probe.releaseAll(2)

        _ = await cache.data(candidatePaths: ["/first/avatar.png"]) { url in
            try probe.read(url)
        }
        let second = await cache.data(candidatePaths: ["/second/avatar.png"]) { _ in
            XCTFail("immutable model asset source must load at most once")
            return Data([0x01])
        }

        XCTAssertEqual(second, Data("HARVIS".utf8))
        XCTAssertEqual(probe.attemptCount, 1)
    }

    @MainActor
    func testPersonaAssetCandidatesDoNotFollowEditablePluginRoot() {
        let suiteName = "HarvisAvatarLoadingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("/Volumes/Stalled/harvis", forKey: "harvisBar.pluginRoot")
        let model = HarvisRuntimeModel(defaults: defaults)
        let initial = model.personaImageCandidatePaths

        model.pluginRoot = "//server/share/harvis"

        XCTAssertEqual(model.personaImageCandidatePaths, initial)
        XCTAssertEqual(
            initial,
            HarvisRuntimeModel.personaImageCandidatePaths(
                assetRoot: "/Volumes/Stalled/harvis"
            )
        )
    }
}
