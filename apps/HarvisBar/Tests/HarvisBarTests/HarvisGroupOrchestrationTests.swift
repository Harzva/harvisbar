import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisGroupOrchestrationTests: XCTestCase {
    func testOwnerPlanMembersReviewAndMemoryUseOneOwnerThreadAndSerialProjectWriters() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groupID = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let owner = try await unwrap(f.group.addMember(groupID: groupID, name: "zy", role: "coordinate", homePath: f.root.path))
        let a = try await unwrap(f.group.addMember(groupID: groupID, name: "A", role: "implement", homePath: f.root.path))
        let b = try await unwrap(f.group.addMember(groupID: groupID, name: "B", role: "review", homePath: f.root.path))
        let granted = await f.group.setProjectPermission(groupID: groupID, permission: .workspaceWrite)
        let selected = await f.group.setOwner(groupID: groupID, memberID: owner)
        XCTAssertTrue(granted); XCTAssertTrue(selected)
        let receipt = try await f.group.submitCoordinated(groupID: groupID, text: "Implement and verify the project", requestID: "owner-run-1")
        let runID = try XCTUnwrap(receipt.runID)
        let planning = await eventually { f.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(planning)
        let ownerThread = try XCTUnwrap(f.group.group(groupID)?.members.first { $0.id == owner }?.binding?.threadID)
        let plan = HarvisGroupOwnerDecision(action: .assign, summary: "Two tasks", assignments: [
            .init(id: "implement", memberID: a, task: "Write the implementation", dependencies: []),
            .init(id: "review", memberID: b, task: "Verify the implementation", dependencies: ["implement"])
        ], memory: .init(summary: "Plan accepted", keyDecisions: ["One writer at a time"], openItems: ["Implementation and review"]))
        try await complete(f, memberID: owner, groupID: groupID, text: encode(plan))
        let firstWorker = await eventually { f.group.group(groupID)?.runs.first { $0.id == runID }?.steps.first?.state == .submitted && f.delivery.durableQueueItems.last?.state == .running }
        XCTAssertTrue(firstWorker)
        XCTAssertEqual(f.delivery.durableQueueItems.count, 2)
        XCTAssertEqual(f.group.group(groupID)?.runs.first?.steps.last?.state, .planned)
        // Polling/history replay cannot turn one owner decision into duplicate tasks.
        await f.group.recover(); await f.group.advanceOrchestration()
        XCTAssertEqual(f.group.group(groupID)?.runs.first?.steps.count, 2)
        try await complete(f, memberID: a, groupID: groupID, text: "Implementation evidence")
        let secondWorker = await eventually { f.delivery.durableQueueItems.count == 3 && f.delivery.durableQueueItems.last?.state == .running }
        XCTAssertTrue(secondWorker)
        try await complete(f, memberID: b, groupID: groupID, text: "Review evidence")
        let reviewing = await eventually { f.group.group(groupID)?.runs.first?.state == .reviewing && f.delivery.durableQueueItems.count == 4 && f.delivery.durableQueueItems.last?.state == .running }
        XCTAssertTrue(reviewing)
        XCTAssertEqual(f.delivery.durableQueueItems.last?.command.threadID, ownerThread)
        XCTAssertTrue(f.delivery.durableQueueItems.last?.command.text.contains("Implementation evidence") == true)
        XCTAssertTrue(f.delivery.durableQueueItems.last?.command.text.contains("Review evidence") == true)
        try await complete(f, memberID: owner, groupID: groupID, text: encode(.init(action: .complete, summary: "Verified and complete", assignments: [], memory: .init(summary: "Project verified", keyDecisions: ["Review passed"], openItems: []))))
        let finished = await eventually { f.group.group(groupID)?.runs.first?.state == .completed }
        XCTAssertTrue(finished)
        XCTAssertEqual(f.group.group(groupID)?.memory.summary, "Project verified")
        XCTAssertEqual(f.group.group(groupID)?.members.first { $0.id == owner }?.binding?.threadID, ownerThread)
        await f.group.recover(); await f.group.advanceOrchestration()
        XCTAssertEqual(f.delivery.durableQueueItems.count, 4)
        let starts = try rpcStarts(f.root)
        XCTAssertNotNil(starts[0]["params"]?["outputSchema"])
        XCTAssertNil(starts[1]["params"]?["outputSchema"])
        XCTAssertNil(starts[2]["params"]?["outputSchema"])
        XCTAssertNotNil(starts[3]["params"]?["outputSchema"])
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testSubmissionReceiptsAreDurableIdempotentAndBackgroundFlagOnlyControlsExternalAcceptance() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let a = try await unwrap(f.group.addMember(groupID: id, name: "A", role: "review", homePath: f.root.path))
        do { _ = try await f.group.submitDirect(groupID: id, text: "External", memberIDs: [a], permission: .discussion, requestID: "external", requireBackgroundEnabled: true); XCTFail("Disabled endpoint accepted work") } catch {}
        XCTAssertTrue(f.group.group(id)?.messages.isEmpty == true)
        let first = try await f.group.submitDirect(groupID: id, text: "UI request", memberIDs: [a], permission: .discussion, requestID: "stable-1")
        let duplicate = try await f.group.submitDirect(groupID: id, text: "UI request", memberIDs: [a], permission: .discussion, requestID: "stable-1")
        XCTAssertEqual(first, duplicate)
        do { _ = try await f.group.submitDirect(groupID: id, text: "Different", memberIDs: [a], permission: .discussion, requestID: "stable-1"); XCTFail("Conflicting idempotency key accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("Request ID conflict")) }
        XCTAssertEqual(f.group.group(id)?.messages.filter { $0.origin == .user }.count, 1)
        let running = await eventually { f.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(running)
        XCTAssertFalse(f.group.group(id)?.backgroundEnabled ?? true)
        try await complete(f, memberID: a, groupID: id, text: "UI work continues with endpoint disabled")
        let finished = await eventually { f.group.group(id)?.runs.first?.state == .completed }
        XCTAssertTrue(finished)
        let saved = try await HarvisGroupStore(url: f.root.appendingPathComponent("groups.json")).load()
        XCTAssertEqual(saved.first?.orchestration?.requests.first?.receipt, first)
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testPlannedOutboxSurvivesRestartButEnqueueAttemptWithoutQueueEvidenceIsNeverReplayed() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let member = try await unwrap(f.group.addMember(groupID: id, name: "A", role: "review", homePath: f.root.path))
        let receipt = try await f.group.submitDirect(groupID: id, text: "Durable pending request", memberIDs: [member], permission: .discussion)
        f.group.deactivate() // No model RPC has been attempted by a planned outbox item.
        let store = HarvisGroupStore(url: f.root.appendingPathComponent("groups.json"))
        let planned = try await store.load()
        XCTAssertEqual(planned.first?.dispatches.first?.state, .queued)
        await f.group.activate()
        let started = await eventually { f.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(started)
        XCTAssertEqual(f.delivery.durableQueueItems.first?.id, receipt.dispatchIDs.first)
        f.group.deactivate()
        var snapshot = try await store.load()
        // A second outbox command was marked attempted, but its queue commit is absent.
        snapshot[0].lastSequence += 1
        let message = HarvisGroupMessage(sequence: snapshot[0].lastSequence, speaker: "你", text: "Uncertain enqueue", recipientMemberIDs: [member], origin: .user)
        snapshot[0].messages.append(message)
        let dispatch = HarvisGroupDispatch(messageID: message.id, memberID: member, permission: .discussion)
        snapshot[0].dispatches.append(dispatch)
        var run = HarvisGroupRun(rootMessageID: message.id, permission: .discussion, state: .working)
        run.steps = [.init(id: "unknown", memberID: member, task: message.text, dispatchID: dispatch.id, state: .enqueueStarted)]
        snapshot[0].orchestration?.runs.append(run)
        try await store.save(snapshot)
        await f.group.activate(); await f.group.advanceOrchestration()
        XCTAssertEqual(f.group.group(id)?.runs.last?.state, .deliveryUnknown)
        XCTAssertFalse(f.delivery.durableQueueItems.contains { $0.id == dispatch.id })
        let refused = await f.group.resumeRun(groupID: id, runID: run.id)
        XCTAssertFalse(refused)
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testInvalidOwnerPlanAndCyclesCannotDispatchAndStoppedRunCannotRestartItself() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let owner = try await unwrap(f.group.addMember(groupID: id, name: "zy", role: "coordinate", homePath: f.root.path))
        let worker = try await unwrap(f.group.addMember(groupID: id, name: "A", role: "review", homePath: f.root.path))
        _ = await f.group.setOwner(groupID: id, memberID: owner)
        let receipt = try await f.group.submitCoordinated(groupID: id, text: "Review the project")
        let runID = try XCTUnwrap(receipt.runID)
        let running = await eventually { f.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(running)
        let cyclic = HarvisGroupOwnerDecision(action: .assign, summary: "bad plan", assignments: [
            .init(id: "a", memberID: worker, task: "A", dependencies: ["b"]), .init(id: "b", memberID: worker, task: "B", dependencies: ["a"])
        ], memory: .init())
        try await complete(f, memberID: owner, groupID: id, text: encode(cyclic))
        let rejected = await eventually { f.group.group(id)?.runs.first?.state == .needsInput }
        XCTAssertTrue(rejected)
        XCTAssertEqual(f.delivery.durableQueueItems.count, 1)
        XCTAssertTrue(f.group.group(id)?.runs.first?.steps.isEmpty == true)
        let cancelled = await f.group.cancelRun(groupID: id, runID: runID)
        XCTAssertTrue(cancelled)
        f.group.deactivate(); await f.group.activate(); await f.group.advanceOrchestration()
        let refused = await f.group.resumeRun(groupID: id, runID: runID)
        XCTAssertFalse(refused)
        XCTAssertEqual(f.delivery.durableQueueItems.count, 1)
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testPermissionChangePreservesNativeThreadAndStructuredDecisionUsesFinalMessageOnly() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let member = try await unwrap(f.group.addMember(groupID: id, name: "zy", role: "coordinate", homePath: f.root.path))
        await f.group.send(groupID: id, text: "Prepare", mentionedMemberIDs: [member])
        let running = await eventually { f.delivery.durableQueueItems.first?.state == .running }
        XCTAssertTrue(running)
        let thread = try XCTUnwrap(f.group.group(id)?.members[0].binding?.threadID)
        try await complete(f, memberID: member, groupID: id, text: "prepared")
        let completed = await eventually { f.group.group(id)?.runs.first?.state == .completed }
        XCTAssertTrue(completed)
        let updated = await f.group.setProjectPermission(groupID: id, permission: .workspaceWrite)
        XCTAssertTrue(updated, f.group.lastError ?? "")
        XCTAssertEqual(f.group.group(id)?.members[0].binding?.threadID, thread)
        XCTAssertEqual(f.group.group(id)?.members[0].binding?.permission, .workspaceWrite)
        let turn: CodexJSONValue = .object(["items": .array([
            .object(["type": .string("agentMessage"), "phase": .string("commentary"), "text": .string("Thinking")]),
            .object(["type": .string("agentMessage"), "phase": .string("final_answer"), "text": .string("{\"action\":\"complete\"}")])
        ])])
        XCTAssertEqual(CodexGroupAdapter.finalText(in: turn), "{\"action\":\"complete\"}")
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testCancelOneRunDoesNotCancelAnotherRunOnTheSameMember() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ScriptedCodexActivityProbe([true]); f.delivery.setActivityProbeForTesting(gate)
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let member = try await unwrap(f.group.addMember(groupID: id, name: "A", role: "review", homePath: f.root.path))
        let first = try await f.group.submitDirect(groupID: id, text: "First request", memberIDs: [member], permission: .discussion)
        let second = try await f.group.submitDirect(groupID: id, text: "Second request", memberIDs: [member], permission: .discussion)
        let queued = await eventually { f.delivery.durableQueueItems.count == 2 }
        XCTAssertTrue(queued)
        let cancelled = await f.group.cancelRun(groupID: id, runID: try XCTUnwrap(first.runID))
        XCTAssertTrue(cancelled)
        XCTAssertEqual(f.delivery.durableQueueItems.first { $0.id == first.dispatchIDs[0] }?.state, .cancelled)
        XCTAssertFalse(f.delivery.durableQueueItems.first { $0.id == second.dispatchIDs[0] }?.state.isTerminal ?? true)
        await gate.replaceValues([false])
        let running = await eventually { f.delivery.durableQueueItems.first { $0.id == second.dispatchIDs[0] }?.state == .running }
        XCTAssertTrue(running)
        XCTAssertEqual(try rpcStarts(f.root).count, 1)
        XCTAssertTrue(try rpcStarts(f.root)[0]["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue?.hasSuffix("Second request") == true)
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testProjectPermissionGateRejectsConcurrentSubmissionAndPreservesThread() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let member = try await unwrap(f.group.addMember(groupID: id, name: "A", role: "review", homePath: f.root.path))
        await f.group.send(groupID: id, text: "Prepare", mentionedMemberIDs: [member])
        let started = await eventually { f.delivery.durableQueueItems.first?.state == .running }; XCTAssertTrue(started)
        try await complete(f, memberID: member, groupID: id, text: "Ready")
        let finished = await eventually { f.group.group(id)?.runs.first?.state == .completed }; XCTAssertTrue(finished)
        let binding = try XCTUnwrap(f.group.group(id)?.members[0].binding)
        let connection = await f.delivery.pool.connection(for: binding.homePath)
        _ = try await connection.request(method: "test/blockNextIdentity", params: .object([:]))
        let update = Task { await f.group.setProjectPermission(groupID: id, permission: .workspaceWrite) }
        let blocked = await eventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("identity-blocked").path) }; XCTAssertTrue(blocked)
        do { _ = try await f.group.submitDirect(groupID: id, text: "Must not race configuration", memberIDs: [member], permission: .discussion); XCTFail("Submission crossed config gate") } catch {}
        let ownerChanged = await f.group.setOwner(groupID: id, memberID: member); XCTAssertFalse(ownerChanged)
        let secondUpdate = await f.group.setProjectPermission(groupID: id, permission: .discussion); XCTAssertFalse(secondUpdate)
        try Data().write(to: f.root.appendingPathComponent("identity-release"))
        let updated = await update.value; XCTAssertTrue(updated, f.group.lastError ?? "")
        XCTAssertEqual(f.group.group(id)?.members[0].binding?.threadID, binding.threadID)
        XCTAssertEqual(f.group.group(id)?.projectPermission, .workspaceWrite)
        XCTAssertEqual(f.group.group(id)?.runs.count, 1)
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testCoordinatedRetryUsesOriginalReceiptAfterOwnerConfigurationChanges() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let owner = try await unwrap(f.group.addMember(groupID: id, name: "zy", role: "coordinate", homePath: f.root.path))
        _ = await f.group.setOwner(groupID: id, memberID: owner)
        let first = try await f.group.submitCoordinated(groupID: id, text: "Answer directly", requestID: "retry-after-config")
        let started = await eventually { f.delivery.durableQueueItems.first?.state == .running }; XCTAssertTrue(started)
        try await complete(f, memberID: owner, groupID: id, text: encode(.init(action: .complete, summary: "done", assignments: [], memory: .init())))
        let finished = await eventually { f.group.group(id)?.runs.first?.state == .completed }; XCTAssertTrue(finished)
        let cleared = await f.group.setOwner(groupID: id, memberID: nil); XCTAssertTrue(cleared)
        let granted = await f.group.setProjectPermission(groupID: id, permission: .workspaceWrite); XCTAssertTrue(granted)
        let retry = try await f.group.submitCoordinated(groupID: id, text: "Answer directly", requestID: "retry-after-config")
        XCTAssertEqual(retry, first)
        XCTAssertEqual(f.delivery.durableQueueItems.count, 1)
        XCTAssertEqual(f.group.group(id)?.runs.count, 1)
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testLoadedResumeIgnoresPermissionOverridesButExplicitSettingsUpdateChangesSameThread() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let member = try await unwrap(f.group.addMember(groupID: id, name: "zy", role: "coordinate", homePath: f.root.path))
        await f.group.send(groupID: id, text: "Warm the native thread", mentionedMemberIDs: [member])
        let running = await eventually { f.delivery.durableQueueItems.first?.state == .running }; XCTAssertTrue(running)
        try await complete(f, memberID: member, groupID: id, text: "Native context exists")
        let finished = await eventually { f.group.group(id)?.runs.first?.state == .completed }; XCTAssertTrue(finished)
        let original = try XCTUnwrap(f.group.group(id)?.members[0].binding)
        let connection = await f.delivery.pool.connection(for: original.homePath)
        let ignored = try await connection.request(method: "thread/resume", params: .object([
            "threadId": .string(original.threadID), "excludeTurns": .bool(true),
            "sandbox": .string("workspace-write"), "approvalPolicy": .string("on-request")]))
        XCTAssertEqual(ignored["sandbox"]?["type"]?.stringValue, "readOnly", "Loaded native resume is not a settings mutation")
        let adapter = CodexGroupAdapter(pool: f.delivery.pool)
        let updated = try await adapter.reconfigure(original, projectPath: f.root.path, permission: .workspaceWrite)
        XCTAssertEqual(updated.threadID, original.threadID)
        XCTAssertEqual(updated.permission, .workspaceWrite)
        let verified = try await adapter.prepare(updated, projectPath: f.root.path, connection: connection)
        XCTAssertEqual(verified["sandbox"]?["type"]?.stringValue, "workspaceWrite")
        XCTAssertEqual(verified["approvalPolicy"]?.stringValue, "on-request")
        let log = try String(contentsOf: f.root.appendingPathComponent("rpc-log.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(CodexJSONValue.self, from: Data($0.utf8)) }
        let settings = try XCTUnwrap(log.first { $0["method"]?.stringValue == "thread/settings/update" })
        XCTAssertEqual(settings["params"]?["threadId"]?.stringValue, original.threadID)
        XCTAssertEqual(settings["params"]?["sandboxPolicy"]?["type"]?.stringValue, "workspaceWrite")
        XCTAssertEqual(settings["params"]?["sandboxPolicy"]?["writableRoots"]?.arrayValue?.first?.stringValue, f.root.path)
        XCTAssertEqual(log.filter { $0["method"]?.stringValue == "thread/start" }.count, 1)
        XCTAssertEqual(log.filter { $0["method"]?.stringValue == "turn/start" }.count, 1)
        let restored = try await adapter.reconfigure(updated, projectPath: f.root.path, permission: .discussion)
        XCTAssertEqual(restored.threadID, original.threadID)
        XCTAssertEqual(restored.permission, .discussion)
        f.group.deactivate(); await f.delivery.deactivate()
    }

    func testSettingsAcknowledgmentWithoutEffectivePermissionChangeIsRejected() async throws {
        let f = try await HarvisGroupOrchestrationTestSupport.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await unwrap(f.group.createGroup(projectPath: f.root.path))
        let member = try await unwrap(f.group.addMember(groupID: id, name: "zy", role: "coordinate", homePath: f.root.path))
        await f.group.send(groupID: id, text: "Warm thread", mentionedMemberIDs: [member])
        let running = await eventually { f.delivery.durableQueueItems.first?.state == .running }; XCTAssertTrue(running)
        try await complete(f, memberID: member, groupID: id, text: "Ready")
        let finished = await eventually { f.group.group(id)?.runs.first?.state == .completed }; XCTAssertTrue(finished)
        let original = try XCTUnwrap(f.group.group(id)?.members[0].binding)
        let connection = await f.delivery.pool.connection(for: original.homePath)
        _ = try await connection.request(method: "test/ignoreSettingsUpdates", params: .object([:]))
        do {
            _ = try await CodexGroupAdapter(pool: f.delivery.pool).reconfigure(original, projectPath: f.root.path, permission: .workspaceWrite)
            XCTFail("An empty acknowledgment cannot prove the effective sandbox changed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sandbox=readOnly"))
            XCTAssertTrue(error.localizedDescription.contains("approval=never"))
            XCTAssertTrue(error.localizedDescription.contains("cwdMatch=true"))
            XCTAssertTrue(error.localizedDescription.contains("threadMatch=true"))
            XCTAssertFalse(error.localizedDescription.contains(original.homePath))
        }
        XCTAssertEqual(f.group.group(id)?.members[0].binding, original)
        XCTAssertEqual(try rpcStarts(f.root).count, 1)
        f.group.deactivate(); await f.delivery.deactivate()
    }

    private func unwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
    private func encode(_ decision: HarvisGroupOwnerDecision) throws -> String { String(decoding: try JSONEncoder().encode(decision), as: UTF8.self) }
    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < end { if predicate() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return predicate()
    }
    private func complete(_ f: (root: URL, group: HarvisGroupCoordinator, delivery: CodexTaskDeliveryCoordinator), memberID: UUID, groupID: UUID, text: String) async throws {
        let binding = try XCTUnwrap(f.group.group(groupID)?.members.first { $0.id == memberID }?.binding)
        let connection = await f.delivery.pool.connection(for: binding.homePath)
        _ = try await connection.request(method: "test/emitCompletion", params: .object(["threadId": .string(binding.threadID), "message": .string(text)]))
    }
    private func rpcStarts(_ root: URL) throws -> [CodexJSONValue] {
        try String(contentsOf: root.appendingPathComponent("rpc-log.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(CodexJSONValue.self, from: Data($0.utf8)) }.filter { $0["method"]?.stringValue == "turn/start" }
    }
}
