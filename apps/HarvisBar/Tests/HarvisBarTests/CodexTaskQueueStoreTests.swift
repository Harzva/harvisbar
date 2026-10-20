import Foundation
import XCTest
@testable import HarvisBar

final class CodexTaskQueueStoreTests: XCTestCase {
    func testAtomicQueueUsesPrivatePermissionsAndRoundTrips() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let item = makeItem()

        try await fixture.store.save([item])
        let loaded = try await fixture.store.load()

        XCTAssertEqual(loaded, [item])
        let directoryPermissions = try permissions(
            at: fixture.queueURL.deletingLastPathComponent()
        )
        let filePermissions = try permissions(at: fixture.queueURL)
        XCTAssertEqual(directoryPermissions & 0o777, 0o700)
        XCTAssertEqual(filePermissions & 0o777, 0o600)
    }

    func testRestartMovesDispatchingToDeliveryUnknownWithoutResend() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connectionID = UUID()
        var item = makeItem()
        item.state = .dispatching
        item.dispatchPhase = .start
        item.connectionID = connectionID
        item.ownership = .manager(
            turnID: "turn-1",
            connectionID: connectionID
        )
        try await fixture.store.save([item])

        let recovered = try await fixture.store.load()

        XCTAssertEqual(recovered.first?.state, .deliveryUnknown)
        XCTAssertEqual(
            recovered.first?.ownership,
            .external(turnID: "turn-1")
        )
        XCTAssertNil(recovered.first?.connectionID)
        XCTAssertTrue(
            recovered.first?.lastError?.contains("not resent") == true
        )
    }

    func testRestartTerminatesRunningAndApprovalStatesWithoutReplay() async throws {
        for interruptedState in [
            CodexDeliveryState.running,
            CodexDeliveryState.waitingApproval,
        ] {
            let fixture = try makeFixture()
            let connectionID = UUID()
            var item = makeItem()
            item.state = interruptedState
            item.connectionID = connectionID
            item.ownership = .manager(
                turnID: "turn-1",
                connectionID: connectionID
            )
            try await fixture.store.save([item])

            let recovered = try await fixture.store.load()

            XCTAssertEqual(recovered.first?.state, .deliveryUnknown)
            XCTAssertEqual(recovered.first?.ownership, .external(turnID: "turn-1"))
            XCTAssertNil(recovered.first?.connectionID)
            XCTAssertTrue(recovered.first?.lastError?.contains("not resent") == true)
            try? FileManager.default.removeItem(at: fixture.root)
        }
    }

    func testDuplicateCommandIDsAreRejected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let item = makeItem()

        do {
            try await fixture.store.save([item, item])
            XCTFail("Expected duplicate queue id to fail")
        } catch let error as CodexTaskQueueStoreError {
            XCTAssertEqual(error, .duplicateCommand(item.id))
        }
    }

    func testSerialBatchRoundTripsAsOneCompleteAtomicEnvelope() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let items = makeBatchItems(count: 3)

        try await fixture.store.save(items)
        let loaded = try await fixture.store.load()

        XCTAssertEqual(loaded, items)
        XCTAssertEqual(
            Set(loaded.compactMap { $0.command.batch?.ordinal }),
            Set(0 ..< 3)
        )
        XCTAssertEqual(
            Set(loaded.compactMap { $0.command.id }).count,
            3
        )
    }

    func testIncompleteSerialBatchIsRejectedBeforeWriting() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let incomplete = Array(makeBatchItems(count: 3).prefix(2))

        do {
            try await fixture.store.save(incomplete)
            XCTFail("Expected an incomplete automatic batch to fail")
        } catch let error as CodexTaskQueueStoreError {
            guard case .invalidBatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.queueURL.path)
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        queueURL: URL,
        store: CodexTaskQueueStore
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexTaskQueueStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let queueURL = root
            .appendingPathComponent("CodexTaskQueue", isDirectory: true)
            .appendingPathComponent("queue-v1.json")
        return (
            root,
            queueURL,
            CodexTaskQueueStore(queueURL: queueURL)
        )
    }

    private func makeItem() -> CodexTaskQueueItem {
        CodexTaskQueueItem(
            command: CodexTaskCommand(
            id: UUID(),
            homeID: "home-a",
            homePath: "/tmp/home-a",
            threadID: "thread-a",
            sourceThreadID: "thread-a",
            cardType: .main,
            text: "test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            stateChangedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    private func makeBatchItems(count: Int) -> [CodexTaskQueueItem] {
        let batchID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        return (0 ..< count).map { ordinal in
            CodexTaskQueueItem(
                command: CodexTaskCommand(
                    id: UUID(),
                    homeID: "home-a",
                    homePath: "/tmp/home-a",
                    threadID: "thread-a",
                    sourceThreadID: "thread-a",
                    cardType: .main,
                    text: "continue",
                    strategy: .serialBatch,
                    batch: CodexTaskBatchPosition(
                        batchID: batchID,
                        ordinal: ordinal,
                        count: count
                    ),
                    createdAt: createdAt
                ),
                state: .waiting,
                stateChangedAt: createdAt
            )
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
