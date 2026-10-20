import Combine
import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class CodexConversationHandoffCoordinatorTests: XCTestCase {
    func testVerifiedHandoffCreatesCleanDurableThreadBeforeCallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        var verified: CodexVerifiedHandoff?
        let startedTransactionID = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Important task",
            cardType: .main
        ) { result in
            verified = result
        }
        let transactionID = try XCTUnwrap(startedTransactionID)
        let summaryRunning = await eventually {
            fixture.coordinator.queueItems.first {
                $0.id == fixture.coordinator.handoffs
                    .latestHandoff(
                        homePath: fixture.home.path,
                        sourceThreadID: "thread-a"
                    )?.summaryCommandID
            }?.state == .running
        }
        XCTAssertTrue(summaryRunning)
        XCTAssertNil(verified, "done callback must not run during summary")

        let connection = await fixture.pool.connection(for: fixture.home.path)
        let summaryItem = try XCTUnwrap(
            fixture.coordinator.queueItems.first {
                $0.id == fixture.coordinator.handoffs
                    .latestHandoff(
                        homePath: fixture.home.path,
                        sourceThreadID: "thread-a"
                    )?.summaryCommandID
            }
        )
        let summaryTurnID = try XCTUnwrap(summaryItem.ownership?.turnID)
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string(summaryTurnID),
                "message": .string("Objective: ship safely. Next: run focused tests."),
            ])
        )

        let destinationStarted = await eventually {
            let handoff = fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
            return handoff?.destinationThreadID != nil
                && handoff?.destinationTurnID != nil
        }
        XCTAssertTrue(destinationStarted)
        XCTAssertNil(verified, "done callback must wait for exact target completion")
        let inFlight = try XCTUnwrap(
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
        )
        XCTAssertFalse(inFlight.canMarkSourceDone)
        let destinationThreadID = try XCTUnwrap(inFlight.destinationThreadID)
        let destinationTurnID = try XCTUnwrap(inFlight.destinationTurnID)

        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string(destinationThreadID),
                "turnId": .string(destinationTurnID),
                "message": .string("Accepted handoff."),
            ])
        )
        let completed = await eventually {
            verified?.transactionID == transactionID
                && fixture.coordinator.handoffs.latestHandoff(
                    homePath: fixture.home.path,
                    sourceThreadID: "thread-a"
                )?.state == .verified
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(verified?.destinationThreadID, destinationThreadID)
        XCTAssertTrue(
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.canMarkSourceDone == true
        )

        let messages = try loggedRPCMessages(in: fixture.root)
        XCTAssertFalse(messages.contains {
            $0["method"]?.stringValue == "thread/fork"
        })
        let nameSet = try XCTUnwrap(messages.first {
            $0["method"]?.stringValue == "thread/name/set"
        })
        XCTAssertEqual(
            nameSet["params"]?["threadId"],
            .string(destinationThreadID)
        )
        XCTAssertEqual(
            nameSet["params"]?["name"],
            .string("Important task · 接手")
        )
        let threadStart = try XCTUnwrap(messages.first {
            $0["method"]?.stringValue == "thread/start"
        })
        let startParams = try XCTUnwrap(threadStart["params"])
        XCTAssertEqual(startParams["ephemeral"], .bool(false))
        XCTAssertEqual(startParams["model"], .string("gpt-test"))
        XCTAssertEqual(startParams["permissions"], .string(":danger-full-access"))
        XCTAssertNil(startParams["sandbox"], "permissions and sandbox are mutually exclusive")
        XCTAssertEqual(startParams["approvalsReviewer"], .string("user"))
        let targetTurn = try XCTUnwrap(messages.first {
            $0["method"]?.stringValue == "turn/start"
                && $0["params"]?["threadId"]?.stringValue == destinationThreadID
        })
        let targetText = targetTurn["params"]?["input"]?.arrayValue?
            .first?["text"]?.stringValue ?? ""
        XCTAssertTrue(targetText.contains("Objective: ship safely"))
        XCTAssertTrue(targetText.contains("Use only this packet"))
        let exactSourceChecks = messages.filter {
            $0["method"]?.stringValue == "thread/turns/list"
        }
        XCTAssertEqual(exactSourceChecks.count, 2)
        XCTAssertEqual(
            exactSourceChecks.last?["params"]?["threadId"],
            .string("thread-a")
        )
        XCTAssertEqual(
            exactSourceChecks.last?["params"]?["sortDirection"],
            .string("desc")
        )
        XCTAssertEqual(exactSourceChecks.last?["params"]?["limit"], .number(1))
        XCTAssertEqual(
            exactSourceChecks.last?["params"]?["itemsView"],
            .string("notLoaded")
        )
        await fixture.coordinator.deactivate()
    }

    func testSummaryFailureDoesNotCreateDestinationOrCallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        var callbackCount = 0
        _ = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .persistedSubagent
        ) { _ in callbackCount += 1 }
        let summaryStarted = await eventually {
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.state == .summarizing
        }
        XCTAssertTrue(summaryStarted)
        let connection = await fixture.pool.connection(for: fixture.home.path)
        let turnID = try XCTUnwrap(
            fixture.coordinator.queueItems.last?.ownership?.turnID
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string(turnID),
                "status": .string("failed"),
                "message": .string("could not summarize"),
            ])
        )
        let failed = await eventually {
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.state == .failed
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(callbackCount, 0)
        XCTAssertFalse(try loggedRPCMessages(in: fixture.root).contains {
            $0["method"]?.stringValue == "thread/start"
        })
        await fixture.coordinator.deactivate()
    }

    func testSourceAdvanceAfterPacketPreventsVerifiedAndDoneCallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        var callbackCount = 0
        _ = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in callbackCount += 1 }
        let connection = await fixture.pool.connection(for: fixture.home.path)
        let summaryReady = await eventually {
            fixture.coordinator.queueItems.first {
                $0.command.strategy == .freshTurn
            }?.ownership?.turnID != nil
        }
        XCTAssertTrue(summaryReady)
        let summaryTurnID = try XCTUnwrap(
            fixture.coordinator.queueItems.first {
                $0.command.strategy == .freshTurn
            }?.ownership?.turnID
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string(summaryTurnID),
                "message": .string("Safe packet"),
            ])
        )
        let destinationReady = await eventually {
            let handoff = fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
            return handoff?.destinationThreadID != nil
                && handoff?.destinationTurnID != nil
        }
        XCTAssertTrue(destinationReady)
        let handoff = try XCTUnwrap(
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
        )
        _ = try await connection.request(
            method: "test/advanceThreadSilently",
            params: .object(["threadId": .string("thread-a")])
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string(try XCTUnwrap(handoff.destinationThreadID)),
                "turnId": .string(try XCTUnwrap(handoff.destinationTurnID)),
                "message": .string("Accepted"),
            ])
        )

        let rejected = await eventually {
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.state == .failed
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(callbackCount, 0)
        XCTAssertFalse(
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.canMarkSourceDone == true
        )
        await fixture.coordinator.deactivate()
    }

    func testSameSecondSourceAdvanceIsRejectedByExactLatestTurn() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        var callbackCount = 0
        _ = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in callbackCount += 1 }
        let connection = await fixture.pool.connection(for: fixture.home.path)
        let summaryReady = await eventually {
            fixture.coordinator.queueItems.first {
                $0.command.strategy == .freshTurn
            }?.ownership?.turnID != nil
        }
        XCTAssertTrue(summaryReady)
        let summaryTurnID = try XCTUnwrap(
            fixture.coordinator.queueItems.first {
                $0.command.strategy == .freshTurn
            }?.ownership?.turnID
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string(summaryTurnID),
                "message": .string("Safe packet"),
            ])
        )
        let destinationReady = await eventually {
            let handoff = fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
            return handoff?.destinationThreadID != nil
                && handoff?.destinationTurnID != nil
        }
        XCTAssertTrue(destinationReady)
        let handoff = try XCTUnwrap(
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
        )
        _ = try await connection.request(
            method: "test/advanceThreadSilently",
            params: .object([
                "threadId": .string("thread-a"),
                "preserveUpdatedAt": .bool(true),
            ])
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string(try XCTUnwrap(handoff.destinationThreadID)),
                "turnId": .string(try XCTUnwrap(handoff.destinationTurnID)),
                "message": .string("Accepted"),
            ])
        )

        let rejected = await eventually {
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.state == .failed
        }
        XCTAssertTrue(rejected)
        XCTAssertEqual(callbackCount, 0)
        XCTAssertFalse(
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.canMarkSourceDone == true
        )
        await fixture.coordinator.deactivate()
    }

    func testVerifiedStateIsNotPublishedBeforeItsStoreSaveSucceeds() async throws {
        let handoffStore = InMemoryCodexConversationHandoffStore(
            failWhenVerified: true
        )
        let fixture = try makeFixture(handoffStore: handoffStore)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        var callbackCount = 0
        var emittedVerified = false
        let publisher = fixture.coordinator.handoffs.$transactions.sink {
            if $0.contains(where: { $0.state == .verified }) {
                emittedVerified = true
            }
        }
        defer { publisher.cancel() }
        _ = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in callbackCount += 1 }
        let connection = await fixture.pool.connection(for: fixture.home.path)
        let summaryReady = await eventually {
            fixture.coordinator.queueItems.first {
                $0.command.strategy == .freshTurn
            }?.ownership?.turnID != nil
        }
        XCTAssertTrue(summaryReady)
        let summaryTurnID = try XCTUnwrap(
            fixture.coordinator.queueItems.first {
                $0.command.strategy == .freshTurn
            }?.ownership?.turnID
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string(summaryTurnID),
                "message": .string("Safe packet"),
            ])
        )
        let destinationReady = await eventually {
            let handoff = fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
            return handoff?.destinationThreadID != nil
                && handoff?.destinationTurnID != nil
        }
        XCTAssertTrue(destinationReady)
        let handoff = try XCTUnwrap(
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string(try XCTUnwrap(handoff.destinationThreadID)),
                "turnId": .string(try XCTUnwrap(handoff.destinationTurnID)),
                "message": .string("Accepted"),
            ])
        )

        let becameUnknown = await eventually {
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.state == .deliveryUnknown
        }
        XCTAssertTrue(becameUnknown)
        XCTAssertFalse(emittedVerified)
        XCTAssertEqual(callbackCount, 0)
        await fixture.coordinator.deactivate()
    }

    func testDestinationApprovalWaitsForExplicitUserDecision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        var callbackCount = 0
        _ = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in callbackCount += 1 }
        let summaryRunning = await eventually {
            fixture.coordinator.queueItems.first {
                $0.command.strategy == .freshTurn
            }?.state == .running
        }
        XCTAssertTrue(summaryRunning)
        let connection = await fixture.pool.connection(for: fixture.home.path)
        let summaryTurnID = try XCTUnwrap(
            fixture.coordinator.queueItems.first {
                $0.command.strategy == .freshTurn
            }?.ownership?.turnID
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string(summaryTurnID),
                "message": .string("Safe handoff packet."),
            ])
        )
        let destinationReady = await eventually {
            let handoff = fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
            return handoff?.destinationThreadID != nil
                && handoff?.destinationTurnID != nil
        }
        XCTAssertTrue(destinationReady)
        let handoff = try XCTUnwrap(
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )
        )
        let destinationThreadID = try XCTUnwrap(handoff.destinationThreadID)
        let destinationTurnID = try XCTUnwrap(handoff.destinationTurnID)
        _ = try await connection.request(
            method: "test/emitApprovalFor",
            params: .object([
                "threadId": .string(destinationThreadID),
                "turnId": .string(destinationTurnID),
            ])
        )
        let waiting = await eventually {
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.state == .destinationWaitingApproval
        }
        XCTAssertTrue(waiting)
        XCTAssertEqual(callbackCount, 0)
        let beforeDecision = try await connection.request(
            method: "test/getApprovalResponses",
            params: .object([:])
        )
        XCTAssertTrue(beforeDecision["responses"]?.arrayValue?.isEmpty == true)

        let approval = try XCTUnwrap(fixture.coordinator.liveState(
            homePath: fixture.home.path,
            threadID: destinationThreadID
        ).pendingApproval)
        await fixture.coordinator.resolveApproval(
            approval,
            homePath: fixture.home.path,
            decision: .decline
        )
        _ = try await connection.request(
            method: "test/emitCompletion",
            params: .object([
                "threadId": .string(destinationThreadID),
                "turnId": .string(destinationTurnID),
                "message": .string("Accepted without running the command."),
            ])
        )
        let verified = await eventually { callbackCount == 1 }
        XCTAssertTrue(verified)
        await fixture.coordinator.deactivate()
    }

    func testDisconnectBecomesUnknownWithoutReplayOrCallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        var callbackCount = 0
        _ = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in callbackCount += 1 }
        let summaryStarted = await eventually {
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.state == .summarizing
        }
        XCTAssertTrue(summaryStarted)
        let connection = await fixture.pool.connection(for: fixture.home.path)
        do {
            _ = try await connection.request(
                method: "test/disconnect",
                params: .object([:])
            )
        } catch {
            // Expected: the fake server exits after reading this request.
        }
        let becameUnknown = await eventually {
            fixture.coordinator.handoffs.latestHandoff(
                homePath: fixture.home.path,
                sourceThreadID: "thread-a"
            )?.state == .deliveryUnknown
        }
        XCTAssertTrue(becameUnknown)
        XCTAssertEqual(callbackCount, 0)
        let startCount = try loggedRPCMessages(in: fixture.root).filter {
            $0["method"]?.stringValue == "turn/start"
        }.count
        XCTAssertEqual(startCount, 1)
        await fixture.coordinator.deactivate()
    }

    func testDuplicateClickReturnsSameActiveTransaction() async throws {
        let fixture = try makeFixture(probeValues: [true])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        let first = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in }
        let second = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in XCTFail("duplicate callback must not replace the owner") }
        XCTAssertEqual(first, second)
        XCTAssertEqual(fixture.coordinator.handoffs.transactions.count, 1)
        XCTAssertEqual(
            fixture.coordinator.queueItems.filter {
                $0.command.threadID == "thread-a"
                    && $0.command.strategy == .freshTurn
            }.count,
            1
        )
        await fixture.coordinator.deactivate()
    }

    func testConcurrentDuplicateClickReturnsSameActiveTransaction() async throws {
        let handoffStore = InMemoryCodexConversationHandoffStore(
            saveDelay: 0.04
        )
        let fixture = try makeFixture(
            probeValues: Array(repeating: true, count: 16),
            handoffStore: handoffStore
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        async let first = fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in }
        async let second = fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in XCTFail("duplicate callback must not replace the owner") }

        let results = await [first, second]
        XCTAssertNotNil(results[0])
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(fixture.coordinator.handoffs.transactions.count, 1)
        XCTAssertEqual(
            fixture.coordinator.queueItems.filter {
                $0.command.threadID == "thread-a"
                    && $0.command.strategy == .freshTurn
            }.count,
            1
        )
        let savedTransactions = await handoffStore.savedTransactions()
        XCTAssertEqual(savedTransactions.count, 1)
        await fixture.coordinator.deactivate()
    }

    func testConcurrentBeginsPreserveBothDurableTransactions() async throws {
        let handoffStore = InMemoryCodexConversationHandoffStore(
            saveDelay: 0.04
        )
        let fixture = try makeFixture(
            probeValues: Array(repeating: true, count: 16),
            handoffStore: handoffStore
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")

        async let first = fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "First",
            cardType: .main
        ) { _ in }
        async let second = fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-b",
            sourceTitle: "Second",
            cardType: .main
        ) { _ in }

        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 2)
        XCTAssertEqual(
            Set(fixture.coordinator.handoffs.transactions.map(\.sourceThreadID)),
            ["thread-a", "thread-b"]
        )
        let savedTransactions = await handoffStore.savedTransactions()
        XCTAssertEqual(savedTransactions.count, 2)
        await fixture.coordinator.deactivate()
    }

    func testRejectsDshWorkBuddyAndEverySidechatType() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        for cardType in [
            CodexTaskCardType.dsh,
            .workBuddy,
            .sidechatParent,
            .transientSidechat,
        ] {
            let result = await fixture.coordinator.handoffs.begin(
                homeID: "home-a",
                homePath: fixture.home.path,
                sourceThreadID: "thread-a-\(cardType.rawValue)",
                sourceTitle: "Unsupported",
                cardType: cardType
            ) { _ in XCTFail("unsupported cards cannot verify") }
            XCTAssertNil(result, "\(cardType) should be rejected")
        }
        XCTAssertTrue(fixture.coordinator.handoffs.transactions.isEmpty)
        XCTAssertTrue(fixture.coordinator.queueItems.isEmpty)
        await fixture.coordinator.deactivate()
    }

    func testFreshSummaryNeverSteersAnExistingManagerTurn() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.coordinator.activate(probeExecutablePath: "/bin/false")
        let submittedBusyID = await fixture.coordinator.submit(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            targetThreadID: "thread-a",
            cardType: .main,
            text: "busy"
        )
        let busyID = try XCTUnwrap(submittedBusyID)
        let busyStarted = await eventually {
            fixture.coordinator.queueItems.first { $0.id == busyID }?.state
                == .running
        }
        XCTAssertTrue(busyStarted)
        _ = await fixture.coordinator.handoffs.begin(
            homeID: "home-a",
            homePath: fixture.home.path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        ) { _ in }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let messages = try loggedRPCMessages(in: fixture.root)
        XCTAssertFalse(messages.contains {
            $0["method"]?.stringValue == "turn/steer"
        })
        let fresh = try XCTUnwrap(fixture.coordinator.queueItems.first {
            $0.command.strategy == .freshTurn
        })
        XCTAssertEqual(fresh.state, .waiting)
        XCTAssertTrue(fresh.lastError?.contains("fresh turn") == true)
        await fixture.coordinator.deactivate()
    }

    func testRestartCancelsStillWaitingSummaryInsteadOfReplayingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexConversationHandoffRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let queueStore = CodexTaskQueueStore(
            queueURL: root.appendingPathComponent("queue/queue-v1.json")
        )
        let handoffStore = CodexConversationHandoffStore(
            storeURL: root.appendingPathComponent("handoffs/handoffs-v1.json")
        )
        let transaction = CodexConversationHandoff(
            homeID: "home-a",
            homePath: root.appendingPathComponent("home").path,
            sourceThreadID: "thread-a",
            sourceTitle: "Task",
            cardType: .main
        )
        let command = CodexTaskCommand(
            id: transaction.summaryCommandID,
            homeID: transaction.homeID,
            homePath: transaction.homePath,
            threadID: transaction.sourceThreadID,
            sourceThreadID: transaction.sourceThreadID,
            cardType: .main,
            text: CodexConversationHandoffPolicy.summaryPrompt,
            strategy: .freshTurn
        )
        try await handoffStore.save([transaction])
        try await queueStore.save([
            CodexTaskQueueItem(command: command, state: .waiting),
        ])
        let pool = CodexAppServerPool()
        let coordinator = CodexTaskDeliveryCoordinator(
            store: queueStore,
            pool: pool,
            handoffStore: handoffStore,
            activityProbe: ScriptedCodexActivityProbe([false, false, false]),
            monitorIntervalNanoseconds: 10_000_000
        )
        await coordinator.activate(probeExecutablePath: "/bin/false")
        XCTAssertEqual(
            coordinator.handoffs.transactions.first?.state,
            .deliveryUnknown
        )
        XCTAssertEqual(coordinator.queueItems.first?.state, .cancelled)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let connectionCount = await pool.connectionCount()
        XCTAssertEqual(connectionCount, 0)
        await coordinator.deactivate()
    }

    private func makeFixture(
        probeValues: [Bool] = Array(repeating: false, count: 32),
        handoffStore: any CodexConversationHandoffStoring =
            InMemoryCodexConversationHandoffStore()
    ) throws -> (
        root: URL,
        home: URL,
        pool: CodexAppServerPool,
        coordinator: CodexTaskDeliveryCoordinator
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexConversationHandoffTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
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
            store: CodexTaskQueueStore(
                queueURL: root.appendingPathComponent("queue/queue-v1.json")
            ),
            pool: pool,
            handoffStore: handoffStore,
            handoffPollIntervalNanoseconds: 10_000_000,
            handoffPhaseTimeout: 2,
            activityProbe: ScriptedCodexActivityProbe(probeValues),
            monitorIntervalNanoseconds: 20_000_000
        )
        return (root, home, pool, coordinator)
    }

    private func loggedRPCMessages(in root: URL) throws -> [CodexJSONValue] {
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

    private func eventually(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while start.duration(to: .now)
            < .nanoseconds(Int64(timeoutNanoseconds)) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

final class CodexConversationHandoffStoreTests: XCTestCase {
    func testStoreRejectsVerifiedTransactionWithoutSourceUpdateEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexConversationHandoffStoreValidationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexConversationHandoffStore(
            storeURL: root.appendingPathComponent("handoffs-v1.json")
        )
        var transaction = CodexConversationHandoff(
            homeID: "home-a",
            homePath: "/tmp/home-a",
            sourceThreadID: "source-a",
            sourceTitle: "Task",
            cardType: .main
        )
        transaction.state = .verified
        transaction.sourceSummaryTurnID = "summary-a"
        transaction.destinationThreadID = "destination-a"
        transaction.destinationTurnID = "destination-turn-a"
        XCTAssertNil(transaction.sourceUpdatedAt)

        do {
            try await store.save([transaction])
            XCTFail("Incomplete verified evidence must not be persisted")
        } catch let error as CodexConversationHandoffStoreError {
            XCTAssertEqual(
                error,
                .incompleteVerifiedTransaction(transaction.id)
            )
        }
    }

    func testLoadMigratesLegacyVerifiedTransactionWithoutSourceUpdateEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexConversationHandoffStoreMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("handoffs/handoffs-v1.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var transaction = CodexConversationHandoff(
            homeID: "home-a",
            homePath: "/tmp/home-a",
            sourceThreadID: "source-a",
            sourceTitle: "Legacy task",
            cardType: .main
        )
        transaction.state = .verified
        transaction.sourceSummaryTurnID = "summary-a"
        transaction.destinationThreadID = "destination-a"
        transaction.destinationTurnID = "destination-turn-a"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(
            CodexConversationHandoffEnvelope(transactions: [transaction])
        ).write(to: url, options: .atomic)

        let store = CodexConversationHandoffStore(storeURL: url)
        let recovered = try await store.load()
        XCTAssertEqual(recovered.first?.state, .deliveryUnknown)
        XCTAssertFalse(recovered.first?.canMarkSourceDone == true)
        XCTAssertTrue(
            recovered.first?.lastError?.contains("complete source evidence")
                == true
        )

        let persisted = try await store.load()
        XCTAssertEqual(persisted.first?.state, .deliveryUnknown)
        XCTAssertFalse(persisted.first?.canMarkSourceDone == true)
    }

    func testCrashReloadCannotMarkDurablePreVerificationSnapshotDone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexConversationHandoffPreVerificationCrashTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("handoffs/handoffs-v1.json")
        var transaction = CodexConversationHandoff(
            homeID: "home-a",
            homePath: "/tmp/home-a",
            sourceThreadID: "source-a",
            sourceTitle: "Task",
            cardType: .main
        )
        transaction.state = .seedingDestination
        transaction.sourceSummaryTurnID = "summary-a"
        transaction.sourceUpdatedAt = 1_900_000_000
        transaction.destinationThreadID = "destination-a"
        transaction.destinationTurnID = "destination-turn-a"
        let writer = CodexConversationHandoffStore(storeURL: url)
        try await writer.save([transaction])
        XCTAssertFalse(transaction.canMarkSourceDone)

        let readerAfterCrash = CodexConversationHandoffStore(storeURL: url)
        let recovered = try await readerAfterCrash.load()
        XCTAssertEqual(recovered.first?.state, .deliveryUnknown)
        XCTAssertFalse(recovered.first?.canMarkSourceDone == true)
    }

    func testRestartMarksActiveTransactionUnknownAndSecuresFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexConversationHandoffStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("handoffs/handoffs-v1.json")
        let store = CodexConversationHandoffStore(storeURL: url)
        var transaction = CodexConversationHandoff(
            homeID: "home-a",
            homePath: "/tmp/home-a",
            sourceThreadID: "source-a",
            sourceTitle: "Task",
            cardType: .main
        )
        transaction.state = .seedingDestination
        transaction.destinationThreadID = "destination-a"
        try await store.save([transaction])

        let recovered = try await store.load()
        XCTAssertEqual(recovered.first?.state, .deliveryUnknown)
        XCTAssertEqual(recovered.first?.destinationThreadID, "destination-a")
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: url.deletingLastPathComponent().path
            )[.posixPermissions] as? NSNumber
        )
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }
}
