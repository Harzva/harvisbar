import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisGroupBackendTests: XCTestCase {
    func testMentionResolutionUsesExactStableMemberIdentity() {
        let architect = HarvisGroupMember(name: "架构师", role: "design", homePath: "/a")
        let alice = HarvisGroupMember(name: "alice", role: "review", homePath: "/b")
        XCTAssertEqual(HarvisGroupMentions.resolve("@架构师，检查 @alice2 @alice", members: [architect, alice]), [architect.id, alice.id])
        XCTAssertEqual(HarvisGroupMentions.resolve("@alice2", members: [alice]), [])
    }

    func testCrashRecoveryPreservesUnknownWithoutResubmitting() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HarvisGroupStore(url: root.appendingPathComponent("groups.json"))
        let member = HarvisGroupMember(name: "A", role: "review", homePath: root.path)
        var group = HarvisGroupConversation(title: "Crash", projectPath: root.path, members: [member])
        let message = HarvisGroupMessage(sequence: 1, speaker: "you", text: "@A run")
        group.messages = [message]; group.lastSequence = 1
        group.dispatches = [HarvisGroupDispatch(messageID: message.id, memberID: member.id, permission: .discussion, state: .dispatching)]
        try await store.save([group])
        let first = try await store.load()
        XCTAssertEqual(first[0].dispatches[0].state, .deliveryUnknown)
        XCTAssertEqual(first[0].dispatches[0].id, group.dispatches[0].id)
        let second = try await store.load()
        XCTAssertEqual(second, first)
        let delivery = CodexTaskDeliveryCoordinator(store: CodexTaskQueueStore(queueURL: root.appendingPathComponent("queue.json")))
        let coordinator = HarvisGroupCoordinator(delivery: delivery, store: store)
        await coordinator.activate(); await coordinator.recover()
        XCTAssertTrue(delivery.queueItems.isEmpty)
        XCTAssertEqual(coordinator.groups[0].dispatches[0].state, .deliveryUnknown)
        coordinator.deactivate()
    }

    func testTwoMembersSameHomeSeparateThreadsAndOtherHomeFailureIsIsolated() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let coordinator = fixture.group
        let groupID = try await unwrap(coordinator.createGroup(projectPath: fixture.root.path))
        let a = try await unwrap(coordinator.addMember(groupID: groupID, name: "A", role: "architect", homePath: fixture.root.path))
        let b = try await unwrap(coordinator.addMember(groupID: groupID, name: "B", role: "reviewer", homePath: fixture.root.path))
        let broken = try await unwrap(coordinator.addMember(groupID: groupID, name: "Bad", role: "unavailable", homePath: fixture.root.appendingPathComponent("bad-home").path))
        await coordinator.send(groupID: groupID, text: "@A @B @Bad discuss")
        let group = try XCTUnwrap(coordinator.group(groupID))
        let bindingA = try XCTUnwrap(group.members.first { $0.id == a }?.binding)
        let bindingB = try XCTUnwrap(group.members.first { $0.id == b }?.binding)
        XCTAssertNotEqual(bindingA.threadID, bindingB.threadID)
        XCTAssertEqual(bindingA.homePath, bindingB.homePath)
        XCTAssertEqual(bindingA.permission, .discussion)
        XCTAssertEqual(bindingA.model, "gpt-test")
        XCTAssertEqual(bindingA.reasoningEffort, "medium")
        XCTAssertEqual(group.dispatches.first { $0.memberID == broken }?.state, .failed)
        XCTAssertEqual(fixture.delivery.durableQueueItems.count, 2)
        XCTAssertTrue(fixture.delivery.durableQueueItems.allSatisfy { $0.command.text.contains("Shared project cwd: \(fixture.root.path)") })
        let running = await eventually { fixture.delivery.durableQueueItems.filter { $0.state == .running }.count == 2 }
        XCTAssertTrue(running)
        let connection = await fixture.delivery.pool.connection(for: fixture.root.path)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(bindingA.threadID), "message": .string("A evidence")]))
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(bindingB.threadID), "message": .string("B evidence")]))
        let completed = await eventually { coordinator.group(groupID)?.dispatches.filter { $0.state == .completed }.count == 2 }
        XCTAssertTrue(completed)
        XCTAssertTrue(coordinator.group(groupID)?.messages.contains { $0.memberID == a && $0.text == "A evidence" } == true)
        XCTAssertTrue(coordinator.group(groupID)?.messages.contains { $0.memberID == b && $0.text == "B evidence" } == true)
        coordinator.deactivate(); await fixture.delivery.deactivate()
    }

    func testHandoffCreatesFreshLineageAndIncludesGroupEvidenceOnNextExplicitMention() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path))
        await fixture.group.send(groupID: groupID, text: "@A first evidence")
        let running = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(running)
        let old = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        let connection = await fixture.delivery.pool.connection(for: old.homePath)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(old.threadID), "message": .string("verified decision")]))
        let completed = await eventually { fixture.group.group(groupID)?.dispatches.first?.state == .completed }
        XCTAssertTrue(completed)
        let target = fixture.root.appendingPathComponent("second-home").path
        await fixture.group.handoff(groupID: groupID, memberID: memberID, targetHomePath: target)
        let replacement = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        XCTAssertEqual(replacement.homePath, target)
        XCTAssertEqual(replacement.lineage, "context-handoff")
        XCTAssertEqual(replacement.predecessorThreadID, old.threadID)
        XCTAssertEqual(replacement.predecessorHomePath, old.homePath)
        XCTAssertEqual(fixture.delivery.durableQueueItems.count, 1, "Handoff itself must not start a paid model turn")
        await fixture.group.send(groupID: groupID, text: "@A continue")
        let command = try XCTUnwrap(fixture.delivery.durableQueueItems.last?.command)
        XCTAssertEqual(command.homePath, target)
        XCTAssertTrue(command.text.contains("verified decision"))
        XCTAssertTrue(command.text.contains("not a full native history migration"))
        let log = try String(contentsOf: fixture.root.appendingPathComponent("rpc-log.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("\"history\""))
        XCTAssertFalse(log.contains("\"path\""))
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testReadOnlyNativeProbeChecksExactThreadAndDetectsActiveTurn() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let probe = CodexGroupNativeActivityProbe(pool: fixture.delivery.pool)
        let idle = try await probe.isThreadRunning(homePath: fixture.root.path, threadID: "thread-a")
        XCTAssertFalse(idle)
        let connection = await fixture.delivery.pool.connection(for: fixture.root.path)
        _ = try await connection.request(method: "turn/start", params: .object(["threadId": .string("thread-a"), "input": .array([])]))
        let active = try await probe.isThreadRunning(homePath: fixture.root.path, threadID: "thread-a")
        XCTAssertTrue(active)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testNativeHistoryReconcilesKnownUnknownTurnWithoutReplayAndKeepsFullReply() async throws {
        let fixture = try await makeFixture()
        defer {
            if testRun?.failureCount == 0 { try? FileManager.default.removeItem(at: fixture.root) }
            else { print("Group recovery diagnostic fixture: \(fixture.root.path)") }
        }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path))
        await fixture.group.send(groupID: groupID, text: "@A check")
        let started = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(started, "\(fixture.group.group(groupID)?.dispatches.compactMap(\.lastError) ?? []); delivery: \(fixture.delivery.lastError ?? "nil")")
        // Wait for group ledger to capture exact turn ID before simulated UI/process restart.
        let projected = await eventually { fixture.group.group(groupID)?.dispatches.first?.turnID != nil }
        XCTAssertTrue(projected)
        let binding = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        fixture.group.deactivate()
        let connection = await fixture.delivery.pool.connection(for: fixture.root.path)
        let events = await connection.events()
        var readerDiagnostics: [String] = []
        let watcher = Task {
            for await event in events {
                if case let .standardError(message, _) = event { readerDiagnostics.append(message) }
            }
        }
        defer { watcher.cancel() }
        let fullReply = String(repeating: "evidence ", count: 2000)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(binding.threadID), "message": .string(fullReply)]))
        let emptyDelivery = CodexTaskDeliveryCoordinator(store: CodexTaskQueueStore(queueURL: fixture.root.appendingPathComponent("empty-queue.json")), pool: fixture.delivery.pool)
        let recovered = HarvisGroupCoordinator(delivery: emptyDelivery, store: HarvisGroupStore(url: fixture.root.appendingPathComponent("groups.json")))
        await recovered.activate()
        XCTAssertEqual(recovered.group(groupID)?.dispatches.first?.state, .completed, "\(recovered.lastError ?? "no error"); reader: \(readerDiagnostics)")
        XCTAssertEqual(recovered.group(groupID)?.messages.last?.text, fullReply)
        XCTAssertTrue(emptyDelivery.queueItems.isEmpty)
        XCTAssertEqual(recovered.group(groupID)?.members.first?.id, memberID)
        recovered.deactivate(); await fixture.delivery.deactivate()
    }

    func testNativeForkAndPermissionChangePreserveOriginalBinding() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path))
        await fixture.group.send(groupID: groupID, text: "@A discuss")
        let started = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(started, "\(fixture.group.group(groupID)?.dispatches.compactMap(\.lastError) ?? []); delivery: \(fixture.delivery.lastError ?? "nil")")
        let original = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        await fixture.group.forkMember(groupID: groupID, memberID: memberID)
        XCTAssertEqual(fixture.group.group(groupID)?.members[0].binding, original, "Active binding must not be replaced")
        let connection = await fixture.delivery.pool.connection(for: fixture.root.path)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(original.threadID)]))
        let completed = await eventually { fixture.group.group(groupID)?.dispatches.first?.state == .completed }
        XCTAssertTrue(completed)
        await fixture.group.forkMember(groupID: groupID, memberID: memberID)
        let fork = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        XCTAssertNotEqual(fork.threadID, original.threadID)
        XCTAssertEqual(fork.lineage, "native-fork")
        XCTAssertEqual(fork.predecessorThreadID, original.threadID)
        XCTAssertEqual(fixture.delivery.durableQueueItems.count, 1)
        await fixture.group.send(groupID: groupID, text: "@A implement explicitly", permission: .workspaceWrite)
        let writable = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        XCTAssertEqual(writable.permission, .workspaceWrite)
        XCTAssertNotEqual(writable.threadID, fork.threadID)
        XCTAssertTrue(fixture.group.group(groupID)?.members[0].previousBindings.contains(original) == true)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testAccountChangeAfterQueueingBlocksActualTurnStart() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let gate = ScriptedCodexActivityProbe([true])
        fixture.delivery.setActivityProbeForTesting(gate)
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        _ = await fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path)
        await fixture.group.send(groupID: groupID, text: "@A do not use a different account")
        let connection = await fixture.delivery.pool.connection(for: fixture.root.path)
        _ = try await connection.request(method: "test/setIdentity", params: .object(["value": .string("different-workspace-same-email")]))
        await gate.replaceValues([false])
        let rejected = await eventually { fixture.delivery.durableQueueItems.first?.state == .failed }
        XCTAssertTrue(rejected)
        let log = try String(contentsOf: fixture.root.appendingPathComponent("request-log.txt"), encoding: .utf8)
        XCTAssertFalse(log.split(separator: "\n").contains("turn/start"))
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testFailedHistoryReadsBackOffWithoutBlockingOtherMemberProjection() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let a = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path))
        let bHome = fixture.root.appendingPathComponent("second-home").path
        let b = try await unwrap(fixture.group.addMember(groupID: groupID, name: "B", role: "review", homePath: bHome))
        await fixture.group.send(groupID: groupID, text: "@A @B check")
        let started = await eventually { fixture.delivery.durableQueueItems.filter { $0.state == .running }.count == 2 }
        XCTAssertTrue(started, "\(fixture.group.group(groupID)?.dispatches.compactMap(\.lastError) ?? []); delivery: \(fixture.delivery.lastError ?? "nil")")
        let bindingA = try XCTUnwrap(fixture.group.group(groupID)?.members.first { $0.id == a }?.binding)
        let bindingB = try XCTUnwrap(fixture.group.group(groupID)?.members.first { $0.id == b }?.binding)
        let connectionA = await fixture.delivery.pool.connection(for: bindingA.homePath)
        let connectionB = await fixture.delivery.pool.connection(for: bindingB.homePath)
        _ = try await connectionA.request(method: "test/setHistoryFailure", params: .object([:]))
        _ = try await connectionA.request(method: "test/emitCompletion", params: .object(["threadId": .string(bindingA.threadID)]))
        _ = try await connectionB.request(method: "test/emitCompletion", params: .object(["threadId": .string(bindingB.threadID), "message": .string("B complete while A history unavailable")]))
        let verifiedB = await eventually { fixture.group.group(groupID)?.dispatches.first { $0.memberID == b }?.nativeReplyVerified == true }
        XCTAssertTrue(verifiedB)
        XCTAssertEqual(fixture.group.group(groupID)?.dispatches.first { $0.memberID == a }?.state, .completed)
        XCTAssertEqual(fixture.group.group(groupID)?.dispatches.first { $0.memberID == a }?.nativeReplyVerified, false)
        try await Task.sleep(nanoseconds: 600_000_000)
        let counters = try await connectionA.request(method: "test/historyCounters", params: .object([:]))
        XCTAssertEqual(counters["count"]?.intValue, 1, "200ms projection must not retry failed native reads until backoff elapses")
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testStopReportsCancelledWhileRealNativeFailureRemainsFailed() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path))
        await fixture.group.send(groupID: groupID, text: "@A work")
        let started = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(started, "\(fixture.group.group(groupID)?.dispatches.compactMap(\.lastError) ?? []); delivery: \(fixture.delivery.lastError ?? "nil")")
        await fixture.group.stop(groupID: groupID, memberID: memberID)
        let cancelled = await eventually { fixture.group.group(groupID)?.dispatches.first?.state == .cancelled }
        XCTAssertTrue(cancelled)
        XCTAssertNil(fixture.group.group(groupID)?.dispatches.first?.lastError)
        await fixture.group.send(groupID: groupID, text: "@A start another explicit task")
        let restarted = await eventually { fixture.delivery.durableQueueItems.last?.state == .running }
        XCTAssertTrue(restarted)
        let binding = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        let connection = await fixture.delivery.pool.connection(for: fixture.root.path)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(binding.threadID), "status": .string("failed")]))
        let failed = await eventually { fixture.group.group(groupID)?.dispatches.last?.state == .failed }
        XCTAssertTrue(failed)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testFreshThreadSkipsResumeUntilRolloutAndCacheExpiresWithConnection() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        _ = await fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path)
        await fixture.group.send(groupID: groupID, text: "@A first turn has no rollout yet")
        let started = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(started, "\(fixture.group.group(groupID)?.dispatches.compactMap(\.lastError) ?? []); delivery: \(fixture.delivery.lastError ?? "nil")")
        var log = try String(contentsOf: fixture.root.appendingPathComponent("request-log.txt"), encoding: .utf8)
        XCTAssertFalse(log.split(separator: "\n").contains("thread/resume"))
        let binding = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        let connection = await fixture.delivery.pool.connection(for: fixture.root.path)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(binding.threadID)]))
        let completed = await eventually { fixture.group.group(groupID)?.dispatches.first?.state == .completed }
        XCTAssertTrue(completed)
        await connection.stop()
        // Fake server deliberately loses history across process restart. A stale preparation
        // response must never cause a new turn on that missing native thread.
        await fixture.group.send(groupID: groupID, text: "@A must use native resume after restart")
        let rejected = await eventually { fixture.delivery.durableQueueItems.last?.state == .failed }
        XCTAssertTrue(rejected)
        log = try String(contentsOf: fixture.root.appendingPathComponent("request-log.txt"), encoding: .utf8)
        XCTAssertTrue(log.split(separator: "\n").contains("thread/resume"))
        XCTAssertEqual(log.split(separator: "\n").filter { $0 == "turn/start" }.count, 1)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testEmptyHandoffAfterServerRestartRecreatesOnlyBeforeFirstDispatchAndPreservesLineage() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path))
        await fixture.group.send(groupID: groupID, text: "@A source evidence")
        let started = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(started)
        let source = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        let sourceConnection = await fixture.delivery.pool.connection(for: source.homePath)
        _ = try await sourceConnection.request(method: "test/emitCompletion", params: .object(["threadId": .string(source.threadID), "message": .string("source shared decision")]))
        let completed = await eventually { fixture.group.group(groupID)?.dispatches.first?.nativeReplyVerified == true }
        XCTAssertTrue(completed)
        let targetHome = fixture.root.appendingPathComponent("second-home").path
        await fixture.group.handoff(groupID: groupID, memberID: memberID, targetHomePath: targetHome)
        let empty = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        XCTAssertEqual(empty.lineage, "context-handoff")
        XCTAssertFalse(fixture.group.group(groupID)?.dispatches.contains { $0.binding == empty } == true)
        fixture.group.deactivate()
        let targetConnection = await fixture.delivery.pool.connection(for: targetHome)
        await targetConnection.stop()
        let delivery = CodexTaskDeliveryCoordinator(store: CodexTaskQueueStore(queueURL: fixture.root.appendingPathComponent("restarted-queue.json")), pool: fixture.delivery.pool,
            handoffStore: CodexConversationHandoffStore(storeURL: fixture.root.appendingPathComponent("restarted-handoffs.json")),
            activityProbe: ScriptedCodexActivityProbe([false]), monitorIntervalNanoseconds: 20_000_000)
        let restored = HarvisGroupCoordinator(delivery: delivery, store: HarvisGroupStore(url: fixture.root.appendingPathComponent("groups.json")))
        await restored.activate(); await delivery.activate(probeExecutablePath: "/bin/false")
        let persisted = await restored.send(groupID: groupID, text: "@A explicitly continue after restart")
        XCTAssertTrue(persisted)
        let accepted = await eventually { delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(accepted, "\(restored.group(groupID)?.dispatches.compactMap(\.lastError) ?? [])")
        let replacement = try XCTUnwrap(restored.group(groupID)?.members[0].binding)
        XCTAssertNotEqual(replacement.threadID, empty.threadID)
        XCTAssertEqual(replacement.predecessorThreadID, source.threadID)
        XCTAssertEqual(replacement.predecessorHomePath, source.homePath)
        XCTAssertEqual(replacement.lineage, "context-handoff")
        XCTAssertTrue(restored.group(groupID)?.members[0].previousBindings.contains(empty) == true)
        XCTAssertEqual(delivery.durableQueueItems.count, 1, "No context seed/model turn may be replayed during empty binding repair")
        XCTAssertEqual(delivery.durableQueueItems.first?.command.threadID, replacement.threadID)
        XCTAssertTrue(delivery.durableQueueItems.first?.command.text.contains("source shared decision") == true)
        restored.deactivate(); await delivery.deactivate(); await fixture.delivery.deactivate()
    }

    func testSharedProjectAllowsOneWriterAndConcurrentReadOnlyReviewer() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        fixture.delivery.setActivityProbeForTesting(ScriptedCodexActivityProbe([true]))
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let a = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "writer", homePath: fixture.root.path))
        let b = try await unwrap(fixture.group.addMember(groupID: groupID, name: "B", role: "review", homePath: fixture.root.path))
        let multiple = await fixture.group.send(groupID: groupID, text: "@A @B write", permission: .workspaceWrite)
        XCTAssertFalse(multiple)
        XCTAssertTrue(fixture.group.group(groupID)?.messages.isEmpty == true)
        let first = await fixture.group.send(groupID: groupID, text: "@A write", permission: .workspaceWrite)
        XCTAssertTrue(first)
        let competing = await fixture.group.send(groupID: groupID, text: "@B also write", permission: .workspaceWrite)
        XCTAssertFalse(competing)
        XCTAssertEqual(fixture.group.group(groupID)?.dispatches.count, 1)
        XCTAssertEqual(fixture.group.group(groupID)?.dispatches.first?.memberID, a)
        let review = await fixture.group.send(groupID: groupID, text: "@B read and review")
        XCTAssertTrue(review)
        XCTAssertEqual(fixture.group.group(groupID)?.dispatches.count, 2)
        XCTAssertEqual(fixture.group.group(groupID)?.members.first { $0.id == b }?.binding?.permission, .discussion)
        XCTAssertEqual(fixture.delivery.durableQueueItems.count, 2)
        let otherGroupID = try await unwrap(fixture.group.createGroup(title: "Same cwd", projectPath: fixture.root.path))
        _ = await fixture.group.addMember(groupID: otherGroupID, name: "C", role: "other group", homePath: fixture.root.path)
        let crossGroupWriter = await fixture.group.send(groupID: otherGroupID, text: "@C write same cwd", permission: .workspaceWrite)
        XCTAssertFalse(crossGroupWriter)
        XCTAssertTrue(fixture.group.group(otherGroupID)?.messages.isEmpty == true)
        let crossGroupReview = await fixture.group.send(groupID: otherGroupID, text: "@C read same cwd")
        XCTAssertTrue(crossGroupReview)
        XCTAssertEqual(fixture.delivery.durableQueueItems.count, 3)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testStopWhileAccountValidationIsBlockedNeverStartsTurn() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path))
        let connection = await fixture.delivery.pool.connection(for: fixture.root.path)
        // New binding checks identity once; actual pre-turn validation checks it again.
        _ = try await connection.request(method: "test/blockIdentityAt", params: .object(["count": .number(2)]))
        await fixture.group.send(groupID: groupID, text: "@A stop while validation is awaiting account read")
        let blockedFile = fixture.root.appendingPathComponent("identity-blocked")
        let blocked = await eventually { FileManager.default.fileExists(atPath: blockedFile.path) }
        XCTAssertTrue(blocked)
        XCTAssertEqual(fixture.delivery.durableQueueItems.first?.state, .dispatching)
        await fixture.group.stop(groupID: groupID, memberID: memberID)
        try Data().write(to: fixture.root.appendingPathComponent("identity-release"))
        let cancelled = await eventually { fixture.delivery.durableQueueItems.first?.state == .cancelled }
        XCTAssertTrue(cancelled, "\(fixture.delivery.durableQueueItems.first?.lastError ?? "no queue error")")
        let log = try String(contentsOf: fixture.root.appendingPathComponent("request-log.txt"), encoding: .utf8)
        XCTAssertFalse(log.split(separator: "\n").contains("turn/start"))
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testRecordOnlyDoesNotDispatchTextMentions() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        _ = await fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path)
        let persisted = await fixture.group.send(groupID: groupID, text: "@A record this mention without waking anyone", mentionedMemberIDs: [], resolveTextMentions: false)
        XCTAssertTrue(persisted)
        XCTAssertEqual(fixture.group.group(groupID)?.messages.count, 1)
        XCTAssertTrue(fixture.group.group(groupID)?.messages.first?.recipientMemberIDs.isEmpty == true)
        XCTAssertTrue(fixture.group.group(groupID)?.dispatches.isEmpty == true)
        XCTAssertTrue(fixture.delivery.durableQueueItems.isEmpty)
        let connectionCount = await fixture.delivery.pool.connectionCount()
        XCTAssertEqual(connectionCount, 0, "Record-only messages must not even initialize an execution connection")
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testNeverDispatchedEmptyHandoffCanChangeAccountAfterServerRestartButCannotFakeFork() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "A", role: "review", homePath: fixture.root.path))
        await fixture.group.handoff(groupID: groupID, memberID: memberID, targetHomePath: fixture.root.path)
        let empty = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        XCTAssertEqual(empty.lineage, "context-handoff")
        XCTAssertTrue(fixture.group.group(groupID)?.dispatches.isEmpty == true)
        let connection = await fixture.delivery.pool.connection(for: empty.homePath)
        await connection.stop()
        await fixture.group.forkMember(groupID: groupID, memberID: memberID)
        XCTAssertEqual(fixture.group.group(groupID)?.members[0].binding, empty)
        XCTAssertTrue(fixture.group.lastError?.contains("thread not loaded") == true)
        let target = fixture.root.appendingPathComponent("second-home").path
        await fixture.group.handoff(groupID: groupID, memberID: memberID, targetHomePath: target)
        let replacement = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        XCTAssertNil(fixture.group.lastError)
        XCTAssertEqual(replacement.homePath, target)
        XCTAssertEqual(replacement.lineage, "context-handoff")
        XCTAssertEqual(replacement.predecessorThreadID, empty.threadID)
        XCTAssertTrue(fixture.group.group(groupID)?.members[0].previousBindings.contains(empty) == true)
        XCTAssertTrue(fixture.group.group(groupID)?.dispatches.isEmpty == true)
        XCTAssertTrue(fixture.delivery.durableQueueItems.isEmpty)
        let log = try String(contentsOf: fixture.root.appendingPathComponent("request-log.txt"), encoding: .utf8)
        XCTAssertFalse(log.split(separator: "\n").contains("turn/start"))
        XCTAssertFalse(log.split(separator: "\n").contains("thread/fork"))
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    private func unwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

    private func cleanFixture(_ root: URL) {
        if testRun?.failureCount == 0 { try? FileManager.default.removeItem(at: root) }
        else { print("Group backend diagnostic fixture: \(root.path)") }
    }

    private func makeRoot() throws -> URL {
        let base = ProcessInfo.processInfo.environment["HARVIS_GROUP_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("HarvisGroupBackendTests", isDirectory: true)
        let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func makeFixture() async throws -> (root: URL, group: HarvisGroupCoordinator, delivery: CodexTaskDeliveryCoordinator) {
        let root = try makeRoot()
        let executable = try CodexAppServerTestSupport.makeFakeExecutable(in: root)
        var script = try String(contentsOf: executable, encoding: .utf8)
        script = script.replacingOccurrences(of: "        elif method == \"thread/start\":", with: """
                elif method == "test/setIdentity":
                    test_identity = params["value"]
                    send({"id":request_id,"result":{}})
                elif method == "test/setHistoryFailure":
                    fail_history = True
                    send({"id":request_id,"result":{}})
                elif method == "test/historyCounters":
                    send({"id":request_id,"result":{"count":history_count}})
                elif method == "turn/interrupt":
                    thread_id = params["threadId"]
                    turn_id = params["turnId"]
                    turn = {"id":turn_id,"status":"interrupted","items":[]}
                    upsert_turn(thread_id, turn)
                    active_turns.pop(thread_id, None)
                    send({"method":"turn/completed","params":{"threadId":thread_id,"turn":turn}})
                    send({"id":request_id,"result":{}})
                elif method == "model/list":
                    send({"id":request_id,"result":{"data":[{"model":"gpt-test","isDefault":True,"hidden":False,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"medium"}]}],"nextCursor":None}})
                elif method == "test/blockIdentityAt":
                    identity_gate_at = params["count"]
                    send({"id":request_id,"result":{}})
                elif method == "account/read":
                    identity_reads += 1
                    if identity_reads == identity_gate_at:
                        open(os.path.join(SCRIPT_DIRECTORY, "identity-blocked"), "w").close()
                        while not os.path.exists(os.path.join(SCRIPT_DIRECTORY, "identity-release")):
                            time.sleep(0.01)
                    account = None if os.environ.get("CODEX_HOME", "").endswith("bad-home") else {"type":"chatgpt","email":os.environ.get("CODEX_HOME", "test") + "@example.invalid","planType":"plus"}
                    send({"id":request_id,"result":{"account":account,"requiresOpenaiAuth":True}})
                elif method == "account/rateLimits/read":
                    send({"id":request_id,"result":{"accountId":test_identity or os.environ.get("CODEX_HOME", "test")}})
                elif method == "thread/start" or method == "thread/fork":
        """)
        script = script.replacingOccurrences(of: "        elif method == \"thread/turns/list\":", with: "        elif method == \"thread/turns/list\":\n            history_count += 1\n            if fail_history:\n                send({\"id\":request_id,\"error\":{\"code\":-32000,\"message\":\"history unavailable\"}})\n                continue")
        script = script.replacingOccurrences(of: "        elif method == \"thread/read\":\n            thread_id = params[\"threadId\"]", with: "        elif method == \"thread/read\":\n            thread_id = params[\"threadId\"]\n            if thread_id not in thread_versions:\n                send({\"id\":request_id,\"error\":{\"code\":-32600,\"message\":\"thread not loaded: \" + thread_id}})\n                continue")
        script = script.replacingOccurrences(of: "thread_id = \"thread-handoff-\" + str(thread_counter)", with: "thread_id = \"thread-handoff-\" + str(os.getpid()) + \"-\" + str(thread_counter)")
        script = script.replacingOccurrences(of: "thread_counter = 0", with: "thread_counter = 0\nthread_sandboxes = {}\ntest_identity = None\nfail_history = False\nhistory_count = 0\nidentity_reads = 0\nidentity_gate_at = -1")
        script = script.replacingOccurrences(of: "        elif method == \"thread/resume\":", with: "        elif method == \"thread/resume\":\n            params[\"sandbox\"] = thread_sandboxes.get(params[\"threadId\"], \"read-only\")\n            if not thread_turns.get(params[\"threadId\"]):\n                send({\"id\":request_id,\"error\":{\"code\":-32600,\"message\":\"no rollout found for thread id\"}})\n                continue")
        script = script.replacingOccurrences(of: "            thread_versions[thread_id] = 1", with: "            thread_sandboxes[thread_id] = params.get(\"sandbox\", \"read-only\")\n            thread_versions[thread_id] = 1")
        script = script.replacingOccurrences(of: "\"sandbox\":{\"type\":\"dangerFullAccess\"}", with: "\"sandbox\":{\"type\":\"workspaceWrite\" if params.get(\"sandbox\") == \"workspace-write\" else \"readOnly\"}")
        script = script.replacingOccurrences(of: "\"approvalPolicy\":\"on-request\",", with: "\"approvalPolicy\":(\"on-request\" if params.get(\"sandbox\") == \"workspace-write\" else \"never\"),")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        // Match production RPC timing: fixture scripts and durable journals may live
        // on slow external storage. Timeout-specific tests must opt into a short bound.
        let pool = CodexAppServerPool(executableURL: executable, requestTimeout: 30)
        let delivery = CodexTaskDeliveryCoordinator(store: CodexTaskQueueStore(queueURL: root.appendingPathComponent("queue.json")), pool: pool,
            handoffStore: CodexConversationHandoffStore(storeURL: root.appendingPathComponent("handoffs.json")),
            activityProbe: ScriptedCodexActivityProbe([false]), monitorIntervalNanoseconds: 20_000_000)
        await delivery.activate(probeExecutablePath: "/bin/false")
        let group = HarvisGroupCoordinator(delivery: delivery, store: HarvisGroupStore(url: root.appendingPathComponent("groups.json")))
        await group.activate()
        return (root, group, delivery)
    }
    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 150 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}
