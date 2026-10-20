import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class CodexTaskDeliveryCoordinatorTests: XCTestCase {
    func testDurableQueueProjectionDoesNotPublishRejectedTerminalSave() async throws {
        let store = StateBlockingCodexTaskQueueStore()
        await store.setBlockedState(.cancelled)
        let fixture = try makeFixture(
            probeValues: [true],
            store: store
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "persist before observing"
        )
        let commandID = try XCTUnwrap(submittedID)
        let monitorSettled = await eventually {
            fixture.coordinator.durableQueueItems.first(where: {
                $0.id == commandID
            })?.lastError?.contains("Another client is running") == true
        }
        XCTAssertTrue(monitorSettled)
        let durableBeforeCancellation = try XCTUnwrap(
            fixture.coordinator.durableQueueItems.first(where: {
                $0.id == commandID
            })
        )
        XCTAssertEqual(durableBeforeCancellation.state, .waiting)
        let durableRevision = fixture.coordinator.durableQueueRevision

        await fixture.coordinator.cancelQueuedCommand(commandID)

        XCTAssertEqual(
            fixture.coordinator.queueItems.first(where: {
                $0.id == commandID
            })?.state,
            .cancelled,
            "The optimistic UI projection exposes the attempted mutation"
        )
        XCTAssertEqual(
            fixture.coordinator.durableQueueItems.first(where: {
                $0.id == commandID
            })?.state,
            .waiting,
            "A rejected save must not change durable delivery evidence"
        )
        XCTAssertEqual(
            fixture.coordinator.metaQueueItem(commandID: commandID)?.state,
            .waiting,
            "Meta management must query only the durable queue projection"
        )
        XCTAssertEqual(
            fixture.coordinator.durableQueueRevision,
            durableRevision
        )
        let persistedItems = await store.savedItems()
        let blockedAttemptCount = await store.blockedAttemptCount
        XCTAssertEqual(
            persistedItems.first(where: { $0.id == commandID })?.state,
            .waiting
        )
        XCTAssertEqual(blockedAttemptCount, 1)
        XCTAssertTrue(
            fixture.coordinator.lastError?.contains(
                "Queue persistence failed"
            ) == true
        )
        await fixture.coordinator.deactivate()
    }

    func testSubmissionDuringQueueRecoveryIsRejectedWithoutLosingPersistedCommands() async throws {
        let persistedCommand = CodexTaskCommand(
            homeID: "home-a",
            homePath: "/tmp/home-a",
            threadID: "completed-thread",
            sourceThreadID: "completed-thread",
            cardType: .main,
            text: "already persisted"
        )
        let persistedItem = CodexTaskQueueItem(
            command: persistedCommand,
            state: .completed
        )
        let store = BlockingLoadCodexTaskQueueStore(items: [persistedItem])
        let fixture = try makeFixture(probeValues: [false], store: store)
        defer {
            store.gate.release()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let activation = Task {
            await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        }
        let loadStarted = await Task.detached {
            store.gate.waitUntilLoadStarts()
        }.value
        XCTAssertTrue(loadStarted)
        XCTAssertFalse(fixture.coordinator.isReady)
        XCTAssertTrue(fixture.coordinator.durableQueueItems.isEmpty)
        XCTAssertEqual(fixture.coordinator.durableQueueRevision, 0)

        let submittedID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "new-thread",
            targetThreadID: "new-thread",
            cardType: .main,
            text: "must not race recovery"
        )
        let freshTurnID = await fixture.coordinator.submitFreshTurn(
            commandID: UUID(),
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "new-thread",
            targetThreadID: "new-thread",
            cardType: .main,
            text: "must not start a handoff turn"
        )
        let repeatedID = await fixture.coordinator.submitRepeated(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "new-thread",
            targetThreadID: "new-thread",
            cardType: .main,
            text: "continue",
            repeatCount: 20
        )
        XCTAssertNil(submittedID)
        XCTAssertNil(freshTurnID)
        XCTAssertNil(repeatedID)
        XCTAssertTrue(fixture.coordinator.queueItems.isEmpty)
        XCTAssertTrue(
            fixture.coordinator.lastError?.contains("still being restored") == true
        )
        let connectionCountBeforeRecovery = await fixture.pool.connectionCount()
        XCTAssertEqual(connectionCountBeforeRecovery, 0)
        XCTAssertTrue(try loggedRPCMessages(in: fixture.root).isEmpty)

        store.gate.release()
        await activation.value

        XCTAssertTrue(fixture.coordinator.isReady)
        XCTAssertEqual(fixture.coordinator.queueItems, [persistedItem])
        XCTAssertEqual(
            fixture.coordinator.durableQueueItems,
            [persistedItem]
        )
        XCTAssertEqual(fixture.coordinator.durableQueueRevision, 1)
        let savedItems = await store.savedItems()
        let saveCount = await store.saveCount
        let connectionCountAfterRecovery = await fixture.pool.connectionCount()
        XCTAssertEqual(savedItems, [persistedItem])
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(connectionCountAfterRecovery, 0)
        XCTAssertTrue(try loggedRPCMessages(in: fixture.root).isEmpty)
        await fixture.coordinator.deactivate()
    }

    func testIdleStartManagerSteerApprovalAndCompletion() async throws {
        let fixture = try makeFixture(probeValues: [false, false, false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedFirstID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "start"
        )
        let firstID = try XCTUnwrap(submittedFirstID)
        let firstBecameRunning = await eventually {
            fixture.coordinator.queueItems.first(where: { $0.id == firstID })?
                .state == .running
        }
        XCTAssertTrue(firstBecameRunning)
        let live = fixture.coordinator.liveState(
            homePath: fixture.home.path,
            threadID: "thread-a"
        )
        guard case let .manager(turnID, connectionID) = live.ownership else {
            await fixture.coordinator.deactivate()
            return XCTFail("Expected exact Manager ownership")
        }
        XCTAssertEqual(turnID, "turn-manager")
        XCTAssertEqual(connectionID, live.connectionID)

        let initialRPCs = try loggedRPCMessages(in: fixture.root)
        let resumeRPC = initialRPCs.first {
            $0["method"]?.stringValue == "thread/resume"
        }
        XCTAssertEqual(
            resumeRPC?["params"],
            .object([
                "threadId": .string("thread-a"),
                "approvalsReviewer": .string("user"),
            ])
        )
        let startRPC = initialRPCs.first {
            $0["method"]?.stringValue == "turn/start"
        }
        XCTAssertEqual(
            startRPC?["params"],
            .object([
                "threadId": .string("thread-a"),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("start"),
                    ]),
                ]),
                "clientUserMessageId": .string(firstID.uuidString),
                "approvalsReviewer": .string("user"),
            ])
        )

        let submittedSteerID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "steer"
        )
        let steerID = try XCTUnwrap(submittedSteerID)
        XCTAssertEqual(
            fixture.coordinator.queueItems.first(where: { $0.id == steerID })?
                .dispatchPhase,
            .steer
        )
        XCTAssertEqual(
            fixture.coordinator.queueItems.first(where: { $0.id == steerID })?
                .state,
            .running
        )

        let connection = await fixture.pool.connection(
            for: fixture.home.path
        )
        _ = try await connection.request(
            method: "test/emitApproval",
            params: .object([:])
        )
        let approvalArrived = await eventually {
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).pendingApproval != nil
        }
        XCTAssertTrue(approvalArrived)
        let approval = try XCTUnwrap(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).pendingApproval
        )
        await fixture.coordinator.resolveApproval(
            approval,
            homePath: fixture.home.path,
            decision: .decline
        )
        XCTAssertNil(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).pendingApproval
        )

        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([:])
        )
        let completed = await eventually {
            fixture.coordinator.queueItems
                .filter { $0.command.threadID == "thread-a" }
                .allSatisfy { $0.state == .completed }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).finalSummary,
            "finished"
        )
        await fixture.coordinator.deactivate()
    }

    func testExternalRunningQueuesThenDispatchesAfterIdleChecks() async throws {
        let fixture = try makeFixture(probeValues: [true, true, true])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedCommandID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "after external turn"
        )
        let commandID = try XCTUnwrap(submittedCommandID)
        let startedWaiting = await eventually {
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })?
                .state == .waiting
        }
        XCTAssertTrue(startedWaiting)
        let connectionCount = await fixture.pool.connectionCount()
        XCTAssertEqual(connectionCount, 0)

        await fixture.probe.replaceValues([false, false, false])
        let dispatched = await eventually(timeoutNanoseconds: 2_000_000_000) {
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })?
                .state == .running
        }
        XCTAssertTrue(dispatched)
        let probeCallCount = await fixture.probe.callCount
        XCTAssertGreaterThanOrEqual(probeCallCount, 4)
        await fixture.coordinator.deactivate()
    }

    func testDisconnectMovesDeliveredTurnToUnknownWithoutReplay() async throws {
        let fixture = try makeFixture(probeValues: [false, false, false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "disconnect after delivery"
        )
        let commandID = try XCTUnwrap(submittedID)
        let becameRunning = await eventually {
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })?
                .state == .running
        }
        XCTAssertTrue(becameRunning)

        let connection = await fixture.pool.connection(for: fixture.home.path)
        do {
            _ = try await connection.request(
                method: "test/disconnect",
                params: .object([:])
            )
            XCTFail("Expected the fake app-server to disconnect")
        } catch {
            // Expected: the request was in flight when the process closed.
        }

        let becameUnknown = await eventually {
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })?
                .state == .deliveryUnknown
        }
        XCTAssertTrue(becameUnknown)
        let recovered = try XCTUnwrap(
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })
        )
        XCTAssertNil(recovered.connectionID)
        XCTAssertEqual(recovered.ownership, .external(turnID: "turn-manager"))
        XCTAssertTrue(recovered.lastError?.contains("not resent") == true)
        let startCount = try loggedRPCMessages(in: fixture.root)
            .filter { $0["method"]?.stringValue == "turn/start" }
            .count
        XCTAssertEqual(startCount, 1)
        await fixture.coordinator.deactivate()
    }

    func testHighFrequencyDeltasDoNotRewriteUnchangedQueue() async throws {
        let store = CountingCodexTaskQueueStore()
        let fixture = try makeFixture(
            probeValues: [false, false, false],
            store: store
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        _ = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "stream without disk churn"
        )
        let becameRunning = await eventually {
            fixture.coordinator.queueItems.last?.state == .running
        }
        XCTAssertTrue(becameRunning)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let savesBeforeBurst = await store.saveCount

        let connection = await fixture.pool.connection(for: fixture.home.path)
        _ = try await connection.request(
            method: "test/emitDeltaBurst",
            params: .object([:])
        )
        let receivedBurst = await eventually {
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).finalSummary?.count == 100
        }
        XCTAssertTrue(receivedBurst)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let savesAfterBurst = await store.saveCount
        XCTAssertEqual(savesAfterBurst, savesBeforeBurst)
        await fixture.coordinator.deactivate()
    }

    func testApprovalFIFOFileEvidenceAndUserInputCancellation() async throws {
        let fixture = try makeFixture(probeValues: [false, false, false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        _ = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "start"
        )
        let turnStarted = await eventually {
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).activeTurnID == "turn-manager"
        }
        XCTAssertTrue(turnStarted)

        let connection = await fixture.pool.connection(for: fixture.home.path)
        _ = try await connection.request(
            method: "test/emitApprovalPair",
            params: .object([:])
        )
        let pairArrived = await eventually {
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).pendingApprovals.count == 2
        }
        XCTAssertTrue(pairArrived)

        var state = fixture.coordinator.liveState(
            homePath: fixture.home.path,
            threadID: "thread-a"
        )
        XCTAssertEqual(state.pendingApprovals.map(\.id), [
            .string("approval-first"),
            .string("approval-second"),
        ])
        XCTAssertEqual(
            state.pendingApprovals[0].availableDecisions,
            [.accept, .decline]
        )
        XCTAssertEqual(
            state.pendingApprovals[1].fileChanges.first?.path,
            "Sources/App.swift"
        )
        XCTAssertTrue(
            state.pendingApprovals[1].fileChanges.first?.diff.contains("+new")
                == true
        )

        await fixture.coordinator.resolveApproval(
            state.pendingApprovals[1],
            homePath: fixture.home.path,
            decision: .accept
        )
        XCTAssertEqual(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).pendingApproval?.id,
            .string("approval-first")
        )

        await fixture.coordinator.resolveApproval(
            state.pendingApprovals[0],
            homePath: fixture.home.path,
            decision: .decline
        )
        state = fixture.coordinator.liveState(
            homePath: fixture.home.path,
            threadID: "thread-a"
        )
        XCTAssertEqual(state.pendingApproval?.id, .string("approval-second"))
        await fixture.coordinator.resolveApproval(
            try XCTUnwrap(state.pendingApproval),
            homePath: fixture.home.path,
            decision: .accept
        )
        XCTAssertNil(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).pendingApproval
        )

        _ = try await connection.request(
            method: "test/emitUserInputApproval",
            params: .object([:])
        )
        let inputArrived = await eventually {
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).pendingApproval?.id == .string("approval-input")
        }
        XCTAssertTrue(inputArrived)
        let inputApproval = try XCTUnwrap(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).pendingApproval
        )
        await fixture.coordinator.resolveApproval(
            inputApproval,
            homePath: fixture.home.path,
            decision: .cancel
        )

        let responseLog = try await connection.request(
            method: "test/getApprovalResponses",
            params: .object([:])
        )
        let responses = try XCTUnwrap(responseLog["responses"]?.arrayValue)
        XCTAssertEqual(responses.map { $0["id"]?.stringValue }, [
            "approval-first",
            "approval-second",
            "approval-input",
        ])
        XCTAssertEqual(
            responses.last?["result"],
            .object(["answers": .object([:])])
        )
        await fixture.coordinator.deactivate()
    }

    func testResumeRPCIsBlockedWhenDispatchingCannotBePersisted() async throws {
        let store = PhaseBlockingCodexTaskQueueStore()
        await store.setBlockedPhase(.resume)
        let fixture = try makeFixture(
            probeValues: [false, false, false],
            store: store
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "blocked resume"
        )
        let commandID = try XCTUnwrap(submittedID)
        let failed = await eventually {
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })?
                .state == .failed
        }
        XCTAssertTrue(failed)
        let failedItem = try XCTUnwrap(
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })
        )
        XCTAssertTrue(failedItem.lastError?.contains("thread/resume was not sent") == true)
        let methods = try loggedRPCMessages(in: fixture.root)
            .compactMap { $0["method"]?.stringValue }
        XCTAssertFalse(methods.contains("thread/resume"))
        XCTAssertFalse(methods.contains("turn/start"))
        let resumeBlockedAttempts = await store.blockedAttemptCount
        XCTAssertEqual(resumeBlockedAttempts, 1)
        await fixture.coordinator.deactivate()
    }

    func testStartRPCIsBlockedWhenItsDispatchingPhaseCannotBePersisted() async throws {
        let store = PhaseBlockingCodexTaskQueueStore()
        await store.setBlockedPhase(.start)
        let fixture = try makeFixture(
            probeValues: [false, false, false],
            store: store
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "blocked start"
        )
        let commandID = try XCTUnwrap(submittedID)
        let failed = await eventually {
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })?
                .state == .failed
        }
        XCTAssertTrue(failed)
        let failedItem = try XCTUnwrap(
            fixture.coordinator.queueItems.first(where: { $0.id == commandID })
        )
        XCTAssertTrue(failedItem.lastError?.contains("turn/start was not sent") == true)
        let methods = try loggedRPCMessages(in: fixture.root)
            .compactMap { $0["method"]?.stringValue }
        XCTAssertTrue(methods.contains("thread/resume"))
        XCTAssertFalse(methods.contains("turn/start"))
        let startBlockedAttempts = await store.blockedAttemptCount
        XCTAssertEqual(startBlockedAttempts, 1)
        await fixture.coordinator.deactivate()
    }

    func testSteerRPCIsBlockedWhenDispatchingCannotBePersisted() async throws {
        let store = PhaseBlockingCodexTaskQueueStore()
        let fixture = try makeFixture(
            probeValues: [false, false, false],
            store: store
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedFirstID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "start"
        )
        let firstID = try XCTUnwrap(submittedFirstID)
        let running = await eventually {
            fixture.coordinator.queueItems.first(where: { $0.id == firstID })?
                .state == .running
        }
        XCTAssertTrue(running)

        await store.setBlockedPhase(.steer)
        let submittedSteerID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "blocked steer"
        )
        let steerID = try XCTUnwrap(submittedSteerID)
        let failedItem = try XCTUnwrap(
            fixture.coordinator.queueItems.first(where: { $0.id == steerID })
        )
        XCTAssertEqual(failedItem.state, .failed)
        XCTAssertTrue(failedItem.lastError?.contains("turn/steer was not sent") == true)
        let methods = try loggedRPCMessages(in: fixture.root)
            .compactMap { $0["method"]?.stringValue }
        XCTAssertFalse(methods.contains("turn/steer"))
        let steerBlockedAttempts = await store.blockedAttemptCount
        XCTAssertEqual(steerBlockedAttempts, 1)
        await fixture.coordinator.deactivate()
    }

    func testSerialBatchStartsOneFreshTurnOnlyAfterEachCompletion() async throws {
        let fixture = try makeFixture(probeValues: [false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let batchID = await fixture.coordinator.submitRepeated(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "  continue  ",
            repeatCount: 3
        )
        XCTAssertNotNil(batchID)

        let firstStarted = await eventually {
            fixture.coordinator.queueItems.contains {
                $0.command.batch?.ordinal == 0 && $0.state == .running
            }
        }
        XCTAssertTrue(firstStarted)
        var messages = try loggedRPCMessages(in: fixture.root)
        XCTAssertEqual(messages.filter { $0["method"]?.stringValue == "turn/start" }.count, 1)
        XCTAssertEqual(messages.filter { $0["method"]?.stringValue == "turn/steer" }.count, 0)

        let connection = await fixture.pool.connection(for: fixture.home.path)
        for completedOrdinal in 0 ..< 3 {
            let activeTurnID = try XCTUnwrap(
                fixture.coordinator.liveState(
                    homePath: fixture.home.path,
                    threadID: "thread-a"
                ).activeTurnID
            )
            _ = try await connection.request(
                method: "test/emitCompletion",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string(activeTurnID),
                ])
            )

            if completedOrdinal < 2 {
                let nextStarted = await eventually(
                    timeoutNanoseconds: 2_000_000_000
                ) {
                    fixture.coordinator.queueItems.contains {
                        $0.command.batch?.ordinal == completedOrdinal + 1
                            && $0.state == .running
                    }
                }
                XCTAssertTrue(nextStarted)
            }
        }

        let allCompleted = await eventually {
            fixture.coordinator.queueItems
                .filter { $0.command.batch?.batchID == batchID }
                .allSatisfy { $0.state == .completed }
        }
        XCTAssertTrue(allCompleted)
        messages = try loggedRPCMessages(in: fixture.root)
        let starts = messages.filter {
            $0["method"]?.stringValue == "turn/start"
        }
        XCTAssertEqual(starts.count, 3)
        XCTAssertEqual(
            starts.compactMap {
                $0["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue
            },
            ["continue", "continue", "continue"]
        )
        XCTAssertEqual(
            Set(starts.compactMap {
                $0["params"]?["clientUserMessageId"]?.stringValue
            }).count,
            3
        )
        XCTAssertFalse(messages.contains {
            $0["method"]?.stringValue == "turn/steer"
        })
        await fixture.coordinator.deactivate()
    }

    func testSerialBatchStopsRemainingStepsAfterFailure() async throws {
        let fixture = try makeFixture(probeValues: [false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let batchID = await fixture.coordinator.submitRepeated(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "continue",
            repeatCount: 3
        )
        let started = await eventually {
            fixture.coordinator.queueItems.contains {
                $0.command.batch?.batchID == batchID && $0.state == .running
            }
        }
        XCTAssertTrue(started)
        let turnID = try XCTUnwrap(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).activeTurnID
        )
        let connection = await fixture.pool.connection(for: fixture.home.path)
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string(turnID),
                "status": .string("failed"),
            ])
        )

        let stopped = await eventually {
            let states = fixture.coordinator.queueItems
                .filter { $0.command.batch?.batchID == batchID }
                .sorted { ($0.command.batch?.ordinal ?? -1) < ($1.command.batch?.ordinal ?? -1) }
                .map(\.state)
            return states == [.failed, .cancelled, .cancelled]
        }
        XCTAssertTrue(stopped)
        let starts = try loggedRPCMessages(in: fixture.root)
            .filter { $0["method"]?.stringValue == "turn/start" }
        XCTAssertEqual(starts.count, 1)
        await fixture.coordinator.deactivate()
    }

    func testSerialBatchFailsClosedWhenCompletionOmitsStatus() async throws {
        let fixture = try makeFixture(probeValues: [false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let batchID = await fixture.coordinator.submitRepeated(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "continue",
            repeatCount: 2
        )
        let started = await eventually {
            fixture.coordinator.queueItems.contains {
                $0.command.batch?.batchID == batchID && $0.state == .running
            }
        }
        XCTAssertTrue(started)
        let turnID = try XCTUnwrap(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).activeTurnID
        )
        let connection = await fixture.pool.connection(for: fixture.home.path)
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string(turnID),
                "omitStatus": .bool(true),
            ])
        )

        let stopped = await eventually {
            let states = fixture.coordinator.queueItems
                .filter { $0.command.batch?.batchID == batchID }
                .sorted { ($0.command.batch?.ordinal ?? -1) < ($1.command.batch?.ordinal ?? -1) }
                .map(\.state)
            return states == [.failed, .cancelled]
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(
            try loggedRPCMessages(in: fixture.root)
                .filter { $0["method"]?.stringValue == "turn/start" }
                .count,
            1
        )
        await fixture.coordinator.deactivate()
    }

    func testSerialBatchCancellationStopsFutureStepsWithoutInterruptingCurrentTurn() async throws {
        let fixture = try makeFixture(probeValues: [false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedBatchID = await fixture.coordinator.submitRepeated(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "continue",
            repeatCount: 3
        )
        let batchID = try XCTUnwrap(submittedBatchID)
        let started = await eventually {
            fixture.coordinator.queueItems.contains {
                $0.command.batch?.ordinal == 0 && $0.state == .running
            }
        }
        XCTAssertTrue(started)

        await fixture.coordinator.cancelPendingBatch(batchID)
        let futureStates = fixture.coordinator.queueItems
            .filter { ($0.command.batch?.ordinal ?? 0) > 0 }
            .map(\.state)
        XCTAssertEqual(futureStates, [.cancelled, .cancelled])
        XCTAssertEqual(
            fixture.coordinator.queueItems.first {
                $0.command.batch?.ordinal == 0
            }?.state,
            .running
        )
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(
            try loggedRPCMessages(in: fixture.root)
                .filter { $0["method"]?.stringValue == "turn/start" }
                .count,
            1
        )
        await fixture.coordinator.deactivate()
    }

    func testSerialBatchCancellationDuringIdleProbeBlocksThePendingRPC() async throws {
        let fixture = try makeFixture(probeValues: [false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let blockingProbe = BlockingCodexActivityProbe(blockedCall: 2)
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        fixture.coordinator.setActivityProbeForTesting(blockingProbe)

        let submittedBatchID = await fixture.coordinator.submitRepeated(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "continue",
            repeatCount: 3
        )
        let batchID = try XCTUnwrap(submittedBatchID)
        await blockingProbe.waitUntilBlocked()

        await fixture.coordinator.cancelPendingBatch(batchID)
        await blockingProbe.release()
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertTrue(
            fixture.coordinator.queueItems
                .filter { $0.command.batch?.batchID == batchID }
                .allSatisfy { $0.state == .cancelled }
        )
        let methods = try loggedRPCMessages(in: fixture.root)
            .compactMap { $0["method"]?.stringValue }
        XCTAssertFalse(methods.contains("thread/resume"))
        XCTAssertFalse(methods.contains("turn/start"))
        await fixture.coordinator.deactivate()
    }

    func testCoordinatorRejectsObservationOnlyCardsBeforePersistenceOrRPC() async throws {
        let fixture = try makeFixture(probeValues: [false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        for cardType in [
            CodexTaskCardType.transientSidechat,
            .dsh,
            .workBuddy,
        ] {
            let repeatedID = await fixture.coordinator.submitRepeated(
                homeID: "home-a",
                homePath: fixture.home.path,
                sourceThreadID: "source-a",
                targetThreadID: "target-a",
                cardType: cardType,
                text: "continue",
                repeatCount: 20
            )
            XCTAssertNil(repeatedID)
            let commandID = await fixture.coordinator.submit(
                homeID: "home-a",
                homePath: fixture.home.path,
                sourceThreadID: "source-a",
                targetThreadID: "target-a",
                cardType: cardType,
                text: "should not send"
            )
            XCTAssertNil(commandID)
        }
        XCTAssertTrue(fixture.coordinator.queueItems.isEmpty)
        let connectionCount = await fixture.pool.connectionCount()
        XCTAssertEqual(connectionCount, 0)
        XCTAssertTrue(try loggedRPCMessages(in: fixture.root).isEmpty)
        await fixture.coordinator.deactivate()
    }

    func testCompletionBeforeStartResponseIsReconciled() async throws {
        let fixture = try makeFixture(probeValues: [false])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        let submittedCommandID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "__complete_before_response__"
        )
        let commandID = try XCTUnwrap(submittedCommandID)
        let reconciled = await eventually {
            fixture.coordinator.queueItems.first { $0.id == commandID }?.state
                == .completed
        }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(
            fixture.coordinator.liveState(
                homePath: fixture.home.path,
                threadID: "thread-a"
            ).finalSummary,
            "early finished"
        )
        await fixture.coordinator.deactivate()
    }

    private func makeFixture(
        probeValues: [Bool],
        store: (any CodexTaskQueueStoring)? = nil
    ) throws -> (
        root: URL,
        home: URL,
        pool: CodexAppServerPool,
        probe: ScriptedCodexActivityProbe,
        coordinator: CodexTaskDeliveryCoordinator
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexTaskDeliveryCoordinatorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        let queueURL = root
            .appendingPathComponent("queue", isDirectory: true)
            .appendingPathComponent("queue-v1.json")
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
        let probe = ScriptedCodexActivityProbe(probeValues)
        let queueStore: any CodexTaskQueueStoring
        if let store {
            queueStore = store
        } else {
            queueStore = CodexTaskQueueStore(queueURL: queueURL)
        }
        let coordinator = CodexTaskDeliveryCoordinator(
            store: queueStore,
            pool: pool,
            activityProbe: probe,
            monitorIntervalNanoseconds: 20_000_000
        )
        return (root, home, pool, probe, coordinator)
    }

    private func loggedRPCMessages(in root: URL) throws -> [CodexJSONValue] {
        let logURL = root.appendingPathComponent("rpc-log.jsonl")
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }
        return try String(contentsOf: logURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { line in
                try JSONDecoder().decode(
                    CodexJSONValue.self,
                    from: Data(line.utf8)
                )
            }
    }

    private func eventually(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let started = ContinuousClock.now
        while started.duration(to: .now) < .nanoseconds(Int64(timeoutNanoseconds)) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
