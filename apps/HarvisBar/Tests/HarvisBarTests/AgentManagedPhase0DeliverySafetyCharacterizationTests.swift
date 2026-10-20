import Foundation
import XCTest
@testable import HarvisBar

/// Phase 0 freezes only the fail-closed ordering at the first durable-write
/// boundary. These tests use synthetic stores and never launch a real Agent.
@MainActor
final class AgentManagedPhase0DeliverySafetyCharacterizationTests:
    XCTestCase {
    func testInitialQueueIntentPersistenceFailureRollsBackBeforeRPC() async throws {
        let queueStore = RejectingInitialQueueIntentStore()
        let fixture = try makeFixture(
            queueStore: queueStore,
            handoffStore: EmptyPhase0HandoffStore()
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        XCTAssertTrue(fixture.coordinator.isReady)
        let durableRevisionBeforeSubmit =
            fixture.coordinator.durableQueueRevision

        let submittedID = await fixture.coordinator.submit(
            commandID: UUID(),
            homeID: "synthetic-home",
            homePath: fixture.home.path,
            sourceThreadID: "synthetic-source",
            targetThreadID: "synthetic-target",
            cardType: .main,
            text: "synthetic command"
        )

        XCTAssertNil(submittedID)
        XCTAssertTrue(
            fixture.coordinator.queueItems.isEmpty,
            "A non-durable initial intent must be rolled back in memory."
        )
        XCTAssertTrue(fixture.coordinator.durableQueueItems.isEmpty)
        XCTAssertEqual(
            fixture.coordinator.durableQueueRevision,
            durableRevisionBeforeSubmit,
            "A rejected write must not advance the durable projection."
        )
        let attemptedSnapshots = await queueStore.attemptedSnapshots()
        XCTAssertEqual(attemptedSnapshots.count, 1)
        XCTAssertEqual(attemptedSnapshots.first?.count, 1)
        XCTAssertEqual(attemptedSnapshots.first?.first?.state, .queued)
        XCTAssertTrue(
            fixture.coordinator.lastError?.contains(
                "Command was not queued because persistence failed"
            ) == true
        )
        let connectionCount = await fixture.pool.connectionCount()
        XCTAssertEqual(connectionCount, 0)
        XCTAssertTrue(try loggedRPCMessages(in: fixture.root).isEmpty)

        await fixture.coordinator.deactivate()
    }

    func testInitialHandoffPersistenceFailureStopsBeforeQueueRPCOrCallback() async throws {
        let queueStore = RecordingEmptyPhase0QueueStore()
        let handoffStore = RejectingInitialHandoffIntentStore()
        let fixture = try makeFixture(
            queueStore: queueStore,
            handoffStore: handoffStore
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        XCTAssertTrue(fixture.coordinator.isReady)
        XCTAssertTrue(fixture.coordinator.handoffs.isReady)
        let durableRevisionBeforeBegin =
            fixture.coordinator.durableQueueRevision
        var callbackCount = 0

        let transactionID = await fixture.coordinator.handoffs.begin(
            homeID: "synthetic-home",
            homePath: fixture.home.path,
            sourceThreadID: "synthetic-source",
            sourceTitle: "Synthetic source",
            cardType: .main
        ) { _ in
            callbackCount += 1
        }

        XCTAssertNil(transactionID)
        XCTAssertTrue(
            fixture.coordinator.handoffs.transactions.isEmpty,
            "A rejected transaction must not become observable in memory."
        )
        let attemptedTransactions = await handoffStore.attemptedSnapshots()
        XCTAssertEqual(attemptedTransactions.count, 1)
        XCTAssertEqual(attemptedTransactions.first?.count, 1)
        XCTAssertEqual(
            attemptedTransactions.first?.first?.state,
            .queuedSummary
        )
        let queueSaveCount = await queueStore.saveCount()
        XCTAssertEqual(queueSaveCount, 0)
        XCTAssertTrue(fixture.coordinator.queueItems.isEmpty)
        XCTAssertTrue(fixture.coordinator.durableQueueItems.isEmpty)
        XCTAssertEqual(
            fixture.coordinator.durableQueueRevision,
            durableRevisionBeforeBegin
        )
        XCTAssertEqual(callbackCount, 0)
        XCTAssertTrue(
            fixture.coordinator.handoffs.lastError?.contains(
                "transaction could not be persisted"
            ) == true
        )
        let connectionCount = await fixture.pool.connectionCount()
        XCTAssertEqual(connectionCount, 0)
        XCTAssertTrue(try loggedRPCMessages(in: fixture.root).isEmpty)

        await fixture.coordinator.deactivate()
    }

    private func makeFixture(
        queueStore: any CodexTaskQueueStoring,
        handoffStore: any CodexConversationHandoffStoring
    ) throws -> (
        root: URL,
        home: URL,
        pool: CodexAppServerPool,
        coordinator: CodexTaskDeliveryCoordinator
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentManagedPhase0DeliverySafety-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent(
            "synthetic-codex-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        let executable = try CodexAppServerTestSupport.makeFakeExecutable(
            in: root
        )
        let pool = CodexAppServerPool(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [executable.path],
            requestTimeout: 2
        )
        let coordinator = CodexTaskDeliveryCoordinator(
            store: queueStore,
            pool: pool,
            handoffStore: handoffStore,
            activityProbe: ScriptedCodexActivityProbe([false]),
            monitorIntervalNanoseconds: 20_000_000
        )
        return (root, home, pool, coordinator)
    }

    private func loggedRPCMessages(
        in root: URL
    ) throws -> [CodexJSONValue] {
        let logURL = root.appendingPathComponent("rpc-log.jsonl")
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }
        return try String(contentsOf: logURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map {
                try JSONDecoder().decode(
                    CodexJSONValue.self,
                    from: Data($0.utf8)
                )
            }
    }
}

private enum Phase0SyntheticPersistenceError: LocalizedError {
    case queueIntentRejected
    case handoffIntentRejected

    var errorDescription: String? {
        switch self {
        case .queueIntentRejected:
            return "Synthetic initial queue persistence failure."
        case .handoffIntentRejected:
            return "Synthetic initial handoff persistence failure."
        }
    }
}

private actor RejectingInitialQueueIntentStore: CodexTaskQueueStoring {
    private var snapshots: [[CodexTaskQueueItem]] = []

    func load() throws -> [CodexTaskQueueItem] { [] }

    func save(_ items: [CodexTaskQueueItem]) throws {
        snapshots.append(items)
        throw Phase0SyntheticPersistenceError.queueIntentRejected
    }

    func attemptedSnapshots() -> [[CodexTaskQueueItem]] { snapshots }
}

private actor RecordingEmptyPhase0QueueStore: CodexTaskQueueStoring {
    private var saves = 0

    func load() throws -> [CodexTaskQueueItem] { [] }

    func save(_: [CodexTaskQueueItem]) throws {
        saves += 1
    }

    func saveCount() -> Int { saves }
}

private actor EmptyPhase0HandoffStore: CodexConversationHandoffStoring {
    func load() throws -> [CodexConversationHandoff] { [] }
    func save(_: [CodexConversationHandoff]) throws {}
}

private actor RejectingInitialHandoffIntentStore:
    CodexConversationHandoffStoring {
    private var snapshots: [[CodexConversationHandoff]] = []

    func load() throws -> [CodexConversationHandoff] { [] }

    func save(_ transactions: [CodexConversationHandoff]) throws {
        snapshots.append(transactions)
        throw Phase0SyntheticPersistenceError.handoffIntentRejected
    }

    func attemptedSnapshots() -> [[CodexConversationHandoff]] { snapshots }
}
