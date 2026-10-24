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

    func testBareChineseNamesMatchNaturalSentencesMultipleMembersAndStableOrder() {
        let architect = HarvisGroupMember(name: "架构师", role: "design", homePath: "/a")
        let implementer = HarvisGroupMember(name: "实现者", role: "code", homePath: "/b")
        let reviewer = HarvisGroupMember(name: "审查员", role: "review", homePath: "/c")
        XCTAssertEqual(HarvisGroupMentions.resolve("请实现者先动手，架构师看看设计，再由实现者确认。", members: [architect, implementer, reviewer]), [architect.id, implementer.id])
        XCTAssertEqual(HarvisGroupMentions.resolve("@架构师，请实现者一起讨论。", members: [architect, implementer]), [architect.id, implementer.id])
    }

    func testEnglishAndNumericNamesRequireIdentifierBoundaries() {
        let ann = HarvisGroupMember(name: "Ann", role: "review", homePath: "/a")
        let bob = HarvisGroupMember(name: "Bob", role: "code", homePath: "/b")
        let number = HarvisGroupMember(name: "007", role: "check", homePath: "/c")
        let developer = HarvisGroupMember(name: "dev_2", role: "code", homePath: "/d")
        let members = [ann, bob, number, developer]
        XCTAssertEqual(HarvisGroupMentions.resolve("planner Annual Ann2 joAnn _Ann Ann_Bob 1007 007x x007 dev_20", members: members), [])
        XCTAssertEqual(HarvisGroupMentions.resolve("请Ann复核，Bob/007一起看；@dev_2确认。", members: members), members.map(\.id))
    }

    func testLongestOverlappingNameWinsWithoutWakingPrefixOrInteriorMembers() {
        let short = HarvisGroupMember(name: "小王", role: "review", homePath: "/a")
        let long = HarvisGroupMember(name: "小王同学", role: "code", homePath: "/b")
        let interior = HarvisGroupMember(name: "王同学", role: "check", homePath: "/c")
        let members = [short, long, interior]
        XCTAssertEqual(HarvisGroupMentions.resolve("请小王同学先看方案。", members: members), [long.id])
        XCTAssertEqual(HarvisGroupMentions.resolve("@小王同学看完后，请小王补充。", members: members), [short.id, long.id])
    }

    func testCoordinatorDispatchesBareNameToOnlyItsStableMemberID() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        fixture.delivery.setActivityProbeForTesting(ScriptedCodexActivityProbe([true]))
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let reviewer = try await unwrap(fixture.group.addMember(groupID: groupID, name: "审查员", role: "review", homePath: fixture.root.path))
        let writer = try await unwrap(fixture.group.addMember(groupID: groupID, name: "实现者", role: "code", homePath: fixture.root.path))
        let persisted = await fixture.group.send(groupID: groupID, text: "请审查员看看这份方案。")
        XCTAssertTrue(persisted)
        XCTAssertEqual(fixture.group.group(groupID)?.messages.first?.recipientMemberIDs, [reviewer])
        XCTAssertEqual(fixture.group.group(groupID)?.dispatches.map(\.memberID), [reviewer])
        XCTAssertEqual(fixture.delivery.durableQueueItems.count, 1)
        XCTAssertNil(fixture.group.group(groupID)?.members.first { $0.id == writer }?.binding)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
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
        _ = await fixture.group.setProjectPermission(groupID: groupID, permission: .workspaceWrite)
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
        XCTAssertEqual(writable.threadID, fork.threadID)
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

    func testSharedProjectAcceptsMultipleWritersButSerializesTheirOutbox() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        fixture.delivery.setActivityProbeForTesting(ScriptedCodexActivityProbe([true]))
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        _ = await fixture.group.setProjectPermission(groupID: groupID, permission: .workspaceWrite)
        _ = await fixture.group.addMember(groupID: groupID, name: "A", role: "write", homePath: fixture.root.path)
        _ = await fixture.group.addMember(groupID: groupID, name: "B", role: "write", homePath: fixture.root.path)
        let accepted = await fixture.group.send(groupID: groupID, text: "@A @B work", permission: .workspaceWrite)
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.group.group(groupID)?.dispatches.count, 2)
        XCTAssertEqual(fixture.delivery.durableQueueItems.count, 1)
        XCTAssertEqual(fixture.group.group(groupID)?.runs.first?.steps.filter { $0.state == .planned }.count, 1)
        let other = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        _ = await fixture.group.setProjectPermission(groupID: other, permission: .workspaceWrite)
        let c = try await unwrap(fixture.group.addMember(groupID: other, name: "C", role: "write", homePath: fixture.root.path))
        let waiting = try await fixture.group.submitDirect(groupID: other, text: "same project", memberIDs: [c], permission: .workspaceWrite)
        XCTAssertNotNil(waiting.runID)
        await fixture.group.advanceOrchestration()
        XCTAssertEqual(fixture.delivery.durableQueueItems.count, 1)
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

    func testMemberEditingPersistsOnlyNameAndRoleAndUsesThemOnFutureDispatch() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "旧审查员", role: "旧职责", homePath: fixture.root.path))
        _ = await fixture.group.addMember(groupID: groupID, name: "实现者", role: "code", homePath: fixture.root.path)
        await fixture.group.send(groupID: groupID, text: "请旧审查员检查原方案。")
        let started = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(started)
        let originalBinding = try XCTUnwrap(fixture.group.group(groupID)?.members.first { $0.id == memberID }?.binding)
        let connection = await fixture.delivery.pool.connection(for: originalBinding.homePath)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(originalBinding.threadID), "message": .string("原审查结论")]))
        let completed = await eventually { fixture.group.group(groupID)?.dispatches.first?.nativeReplyVerified == true }
        XCTAssertTrue(completed)
        await fixture.group.forkMember(groupID: groupID, memberID: memberID)
        let before = try XCTUnwrap(fixture.group.group(groupID))
        let memberIndex = try XCTUnwrap(before.members.firstIndex { $0.id == memberID })
        XCTAssertFalse(before.members[memberIndex].previousBindings.isEmpty)
        XCTAssertGreaterThan(before.members[memberIndex].lastConsumedSequence, 0)
        XCTAssertTrue(before.messages.contains { $0.memberID == memberID && $0.speaker == "旧审查员" })
        let queueBefore = fixture.delivery.durableQueueItems
        let requestsBefore = try Data(contentsOf: fixture.root.appendingPathComponent("request-log.txt"))
        let duplicate = await fixture.group.updateMember(groupID: groupID, memberID: memberID, name: "实现者", role: "不能保存")
        XCTAssertFalse(duplicate)
        XCTAssertNotNil(fixture.group.lastError)
        let renamed = await fixture.group.updateMember(groupID: groupID, memberID: memberID, name: "  新审查员\n", role: "核对证据并检查回归")
        XCTAssertTrue(renamed)
        XCTAssertNil(fixture.group.lastError)
        var expected = before
        expected.members[memberIndex].name = "新审查员"
        expected.members[memberIndex].role = "核对证据并检查回归"
        XCTAssertEqual(fixture.group.group(groupID), expected, "Editing must preserve the entire group except the selected member's name and role")
        let persisted = try await HarvisGroupStore(url: fixture.root.appendingPathComponent("groups.json")).load()
        XCTAssertEqual(persisted, [expected])
        XCTAssertEqual(fixture.delivery.durableQueueItems, queueBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("request-log.txt")), requestsBefore, "Editing must not issue native RPCs")
        XCTAssertEqual(HarvisGroupMentions.resolve("请新审查员检查。", members: expected.members), [memberID])
        XCTAssertEqual(HarvisGroupMentions.resolve("请旧审查员检查。", members: expected.members), [])
        fixture.delivery.setActivityProbeForTesting(ScriptedCodexActivityProbe([true]))
        let sent = await fixture.group.send(groupID: groupID, text: "请新审查员复核更新。")
        XCTAssertTrue(sent)
        let command = try XCTUnwrap(fixture.delivery.durableQueueItems.last?.command)
        XCTAssertEqual(command.threadID, expected.members[memberIndex].binding?.threadID)
        XCTAssertTrue(command.text.contains("name: 新审查员"))
        XCTAssertTrue(command.text.contains("Role/instructions: 核对证据并检查回归"))
        XCTAssertEqual(fixture.group.group(groupID)?.dispatches.last?.memberID, memberID)
        XCTAssertEqual(fixture.delivery.durableQueueItems.first, queueBefore.first)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testInvalidMemberEditsRejectDuplicatesAndMissingTargetsWithoutSaving() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "审查员", role: "review", homePath: fixture.root.path))
        _ = await fixture.group.addMember(groupID: groupID, name: "实现者", role: "code", homePath: fixture.root.path)
        let before = fixture.group.groups
        let dataBefore = try Data(contentsOf: fixture.root.appendingPathComponent("groups.json"))
        for name in [" 实现者 ", " \t\n", "名字 空格", "@名字", "名\n字"] {
            let result = await fixture.group.updateMember(groupID: groupID, memberID: memberID, name: name, role: "不能保存")
            XCTAssertFalse(result, name)
            XCTAssertNotNil(fixture.group.lastError)
        }
        let missingMember = await fixture.group.updateMember(groupID: groupID, memberID: UUID(), name: "新名称", role: "不能保存")
        let missingGroup = await fixture.group.updateMember(groupID: UUID(), memberID: memberID, name: "新名称", role: "不能保存")
        XCTAssertFalse(missingMember)
        XCTAssertFalse(missingGroup)
        XCTAssertEqual(fixture.group.groups, before)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("groups.json")), dataBefore)
        XCTAssertTrue(fixture.delivery.durableQueueItems.isEmpty)
        let connectionCount = await fixture.delivery.pool.connectionCount()
        XCTAssertEqual(connectionCount, 0)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testCurrentRequestIsOutsideReferenceHistoryAndConsecutiveDispatchesKeepTheirOwnMessage() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "审查员", role: "旧验收职责：只回复 UX_ROLE_READY", homePath: fixture.root.path))
        await fixture.group.send(groupID: groupID, text: "请审查员确认旧验收口令。")
        let initialStarted = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(initialStarted)
        let binding = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        let connection = await fixture.delivery.pool.connection(for: binding.homePath)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(binding.threadID), "message": .string("UX_ROLE_READY")]))
        let initialCompleted = await eventually { fixture.group.group(groupID)?.dispatches.first?.nativeReplyVerified == true }
        XCTAssertTrue(initialCompleted)
        await fixture.group.send(groupID: groupID, text: "UNREAD_REFERENCE_ONLY：此前讨论的依据。", resolveTextMentions: false)
        let firstRequest = "CURRENT_TASK_ONE：请生成40条具体检查项，不要只给旧验收口令。"
        let secondRequest = "CURRENT_TASK_TWO：仅总结下一阶段的三个决定。"
        await fixture.group.send(groupID: groupID, text: firstRequest, mentionedMemberIDs: [memberID], resolveTextMentions: false)
        await fixture.group.send(groupID: groupID, text: secondRequest, mentionedMemberIDs: [memberID], resolveTextMentions: false)
        await fixture.group.send(groupID: groupID, text: "FUTURE_REFERENCE_MUST_NOT_LEAK", resolveTextMentions: false)
        let commands = fixture.delivery.durableQueueItems.map(\.command)
        XCTAssertEqual(commands.count, 3)
        let first = commands[1], second = commands[2]
        let history = try referenceHistory(in: first.text)
        XCTAssertTrue(history.contains("审查员: UX_ROLE_READY"))
        XCTAssertTrue(history.contains("UNREAD_REFERENCE_ONLY"))
        XCTAssertFalse(history.contains(firstRequest))
        XCTAssertTrue(first.text.hasSuffix(firstRequest))
        XCTAssertFalse(first.text.contains(secondRequest))
        XCTAssertFalse(first.text.contains("FUTURE_REFERENCE_MUST_NOT_LEAK"))
        XCTAssertTrue(second.text.hasSuffix(secondRequest))
        XCTAssertFalse(second.text.contains("FUTURE_REFERENCE_MUST_NOT_LEAK"))
        XCTAssertTrue(first.text.contains("Role/instructions: 旧验收职责：只回复 UX_ROLE_READY"))
        let dispatches = try XCTUnwrap(fixture.group.group(groupID)?.dispatches)
        XCTAssertTrue(first.text.contains("message ID: \(dispatches[1].messageID.uuidString)"))
        XCTAssertTrue(second.text.contains("message ID: \(dispatches[2].messageID.uuidString)"))
        let firstStarted = await eventually { fixture.delivery.durableQueueItems.first { $0.id == first.id }?.state == .running }
        XCTAssertTrue(firstStarted)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(binding.threadID)]))
        let secondStarted = await eventually { fixture.delivery.durableQueueItems.first { $0.id == second.id }?.state == .running }
        XCTAssertTrue(secondStarted)
        let starts = try recordedTurnStarts(in: fixture.root)
        XCTAssertEqual(starts.first { $0["params"]?["clientUserMessageId"]?.stringValue == first.id.uuidString }?["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue, first.text)
        XCTAssertEqual(starts.first { $0["params"]?["clientUserMessageId"]?.stringValue == second.id.uuidString }?["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue, second.text)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testOversizedHistoryTruncationNeverTruncatesTheCompleteCurrentRequest() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "审查员", role: "review", homePath: fixture.root.path))
        let history = "HISTORY_PREFIX_TO_TRUNCATE" + String(repeating: "h", count: 100_100) + "HISTORY_TAIL_TO_KEEP"
        await fixture.group.send(groupID: groupID, text: history, resolveTextMentions: false)
        let request = "CURRENT_PREFIX_MUST_SURVIVE\n" + String(repeating: "u", count: 100_100) + "\nCURRENT_SUFFIX_MUST_SURVIVE"
        await fixture.group.send(groupID: groupID, text: request, mentionedMemberIDs: [memberID], resolveTextMentions: false)
        let started = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(started)
        let command = try XCTUnwrap(fixture.delivery.durableQueueItems.first?.command)
        let reference = try referenceHistory(in: command.text)
        XCTAssertLessThanOrEqual(reference.count, 100_000)
        XCTAssertFalse(reference.contains("HISTORY_PREFIX_TO_TRUNCATE"))
        XCTAssertTrue(reference.contains("HISTORY_TAIL_TO_KEEP"))
        XCTAssertFalse(reference.contains("CURRENT_PREFIX_MUST_SURVIVE"))
        XCTAssertTrue(command.text.hasSuffix(request))
        let start = try XCTUnwrap(recordedTurnStarts(in: fixture.root).last)
        XCTAssertEqual(start["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue, command.text)
        fixture.group.deactivate(); await fixture.delivery.deactivate()
    }

    func testCurrentRequestSurvivesRestoredConsumedMarkerAtItsSequenceBoundary() async throws {
        let fixture = try await makeFixture(); defer { cleanFixture(fixture.root) }
        let groupID = try await unwrap(fixture.group.createGroup(projectPath: fixture.root.path))
        let memberID = try await unwrap(fixture.group.addMember(groupID: groupID, name: "审查员", role: "review", homePath: fixture.root.path))
        await fixture.group.send(groupID: groupID, text: "请审查员准备。")
        let initialStarted = await eventually { fixture.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(initialStarted)
        let binding = try XCTUnwrap(fixture.group.group(groupID)?.members[0].binding)
        let connection = await fixture.delivery.pool.connection(for: binding.homePath)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(binding.threadID)]))
        let initialCompleted = await eventually { fixture.group.group(groupID)?.dispatches.first?.nativeReplyVerified == true }
        XCTAssertTrue(initialCompleted)
        fixture.group.deactivate()
        let store = HarvisGroupStore(url: fixture.root.appendingPathComponent("groups.json"))
        var saved = try await store.load()
        saved[0].members[0].lastConsumedSequence = saved[0].lastSequence + 1
        let boundary = saved[0].members[0].lastConsumedSequence
        try await store.save(saved)
        let restored = HarvisGroupCoordinator(delivery: fixture.delivery, store: store)
        await restored.activate()
        let request = "CURRENT_BOUNDARY_TASK：请执行本次完整新任务。"
        await restored.send(groupID: groupID, text: request, mentionedMemberIDs: [memberID], resolveTextMentions: false)
        let message = try XCTUnwrap(restored.group(groupID)?.messages.last { $0.text == request })
        XCTAssertEqual(message.sequence, boundary)
        let command = try XCTUnwrap(fixture.delivery.durableQueueItems.last?.command)
        XCTAssertTrue(command.text.hasSuffix(request))
        XCTAssertEqual(try referenceHistory(in: command.text), "")
        let started = await eventually { fixture.delivery.durableQueueItems.last?.state == .running }
        XCTAssertTrue(started)
        XCTAssertEqual(try recordedTurnStarts(in: fixture.root).last?["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue, command.text)
        restored.deactivate(); await fixture.delivery.deactivate()
    }

    private func referenceHistory(in packet: String) throws -> String {
        let start = try XCTUnwrap(packet.range(of: "\n<group-context>\n"))
        let end = try XCTUnwrap(packet.range(of: "\n</group-context>", range: start.upperBound ..< packet.endIndex))
        return String(packet[start.upperBound ..< end.lowerBound])
    }

    private func recordedTurnStarts(in root: URL) throws -> [CodexJSONValue] {
        try String(contentsOf: root.appendingPathComponent("rpc-log.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(CodexJSONValue.self, from: Data($0.utf8)) }
            .filter { $0["method"]?.stringValue == "turn/start" }
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
        try await HarvisGroupOrchestrationTestSupport.make()
    }
    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 150 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}
