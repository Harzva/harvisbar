import Foundation
import XCTest
@testable import HarvisBar

final class DiskSamplingIsolationTests: XCTestCase {
    private final class BlockingDiskProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var attempts = 0
        private var readerMainThread: Bool?

        var attemptCount: Int { lock.withLock { attempts } }
        var readWasOnMainThread: Bool? { lock.withLock { readerMainThread } }

        func load() -> [DiskInfo] {
            lock.withLock {
                attempts += 1
                readerMainThread = Thread.isMainThread
            }
            release.wait()
            return [
                DiskInfo(
                    name: "Fixture",
                    volumeURL: URL(fileURLWithPath: "/fixture"),
                    totalBytes: 100,
                    availableBytes: 40,
                    usedBytes: 60,
                    isInternal: false,
                    isRemovable: true
                )
            ]
        }

        func unblock() {
            release.signal()
        }
    }

    @MainActor
    func testBlockedDiskScanNeverBlocksMainActorOrStartsDuplicates() async throws {
        let suiteName = "DiskSamplingIsolationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let probe = BlockingDiskProbe()

        model.sampleSystemInfo(diskLoader: probe.load)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while probe.attemptCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(probe.attemptCount, 1)
        XCTAssertEqual(probe.readWasOnMainThread, false)
        XCTAssertNotNil(model.diskRefreshTask)

        for _ in 0..<20 {
            model.sampleSystemInfo(diskLoader: probe.load)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.attemptCount, 1)

        probe.unblock()
        let completionDeadline = clock.now.advanced(by: .seconds(2))
        while model.disks.isEmpty, clock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.disks.map(\.name), ["Fixture"])
        XCTAssertNil(model.diskRefreshTask)
        XCTAssertEqual(probe.attemptCount, 1)
    }
}
