import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisGroupControlAPITests: XCTestCase {
    private func request(_ api: HarvisGroupControlAPI, _ method: String, _ params: [String: CodexJSONValue] = [:]) async throws -> CodexJSONValue {
        let data = try CodexJSONValue.object(["jsonrpc": .string("2.0"), "id": .string("test"), "method": .string(method), "params": .object(params)]).encodedData()
        return try JSONDecoder().decode(CodexJSONValue.self, from: await api.handle(data))
    }
    func testBackgroundGateParameterRejectionAndDurableRecordOnlyIdempotency() async throws {
        let directory = URL(fileURLWithPath: "/tmp/hga-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delivery = CodexTaskDeliveryCoordinator(store: CodexTaskQueueStore(queueURL: directory.appendingPathComponent("queue.json")),
            handoffStore: CodexConversationHandoffStore(storeURL: directory.appendingPathComponent("handoffs.json")))
        let coordinator = HarvisGroupCoordinator(delivery: delivery, store: HarvisGroupStore(url: directory.appendingPathComponent("groups.json")))
        let api = HarvisGroupControlAPI(coordinator: coordinator)
        let notReady = try await request(api, "groups.list")
        XCTAssertEqual(notReady["error"]?["code"], .number(-32001))
        await coordinator.activate(); await delivery.activate(probeExecutablePath: "/fixture/no-executable")
        // No binding, recipients, native RPC or model is needed for a record-only receipt.
        let created = await coordinator.createGroup(projectPath: directory.path)
        let groupID = try XCTUnwrap(created)
        let disabled = try await request(api, "groups.status", ["groupID": .string(groupID.uuidString)])
        XCTAssertEqual(disabled["error"]?["code"], .number(-32003))
        let enabled = await coordinator.setBackgroundEnabled(groupID: groupID, enabled: true)
        XCTAssertTrue(enabled)
        let override = try await request(api, "groups.send", ["groupID": .string(groupID.uuidString), "homePath": .string("/private/profile")])
        XCTAssertEqual(override["error"]?["code"], .number(-32602))
        let params: [String: CodexJSONValue] = ["groupID": .string(groupID.uuidString), "text": .string("Record @A without any execution"), "requestID": .string("durable-1"), "mode": .string("recordOnly")]
        let first = try await request(api, "groups.send", params)
        let repeated = try await request(api, "groups.send", params)
        XCTAssertNotNil(first["result"]?["messageID"])
        XCTAssertEqual(first["result"], repeated["result"])
        XCTAssertEqual(coordinator.group(groupID)?.messages.count, 1)
        XCTAssertTrue(delivery.queueItems.isEmpty)
        var conflict = params; conflict["text"] = .string("Changed payload")
        let rejected = try await request(api, "groups.send", conflict)
        XCTAssertEqual(rejected["error"]?["code"], .number(-32009))
        let status = try await request(api, "groups.status", ["groupID": .string(groupID.uuidString)])
        XCTAssertEqual(status["result"]?["service"]?["ownerConfigured"], .bool(false))
        let output = status.encodedString() ?? ""
        XCTAssertFalse(output.contains("homePath")); XCTAssertFalse(output.contains("accountIdentity")); XCTAssertFalse(output.contains("projectPath"))
        let results = try await request(api, "groups.results", ["groupID": .string(groupID.uuidString)])
        XCTAssertEqual(results["result"]?["messages"]?.arrayValue?.count, 1)
        coordinator.deactivate(); await delivery.deactivate()
    }
    private func serviceGroup(state: HarvisGroupRunState = .completed, verifiedOwner: Bool = true, coordinated: Bool = true) -> HarvisGroupConversation {
        let owner = HarvisGroupMember(name: "Owner", role: "Coordinate delivery", homePath: "/private/hidden-owner-home")
        let worker = HarvisGroupMember(name: "Maker", role: "Implementation", homePath: "/private/hidden-worker-home")
        let root = HarvisGroupMessage(sequence: 1, speaker: "你", text: "Deliver the verified change", recipientMemberIDs: [owner.id], origin: .user)
        var memberDispatch = HarvisGroupDispatch(messageID: root.id, memberID: worker.id, permission: .discussion, state: .completed)
        memberDispatch.nativeReplyVerified = true
        let memberReply = HarvisGroupMessage(sequence: 2, memberID: worker.id, speaker: worker.name, text: "Member evidence", dispatchID: memberDispatch.id)
        memberDispatch.responseMessageID = memberReply.id
        var run = HarvisGroupRun(rootMessageID: root.id, ownerMemberID: coordinated ? owner.id : nil, permission: .discussion, state: state)
        run.ownerRound = 2; run.summary = "Owner verified the change and its evidence."
        run.steps = [.init(id: "implementation", memberID: worker.id, task: "Implement and verify", dispatchID: memberDispatch.id, state: .finished)]
        let review = HarvisGroupMessage(sequence: 3, memberID: owner.id, speaker: "Review", text: "Verify member evidence", recipientMemberIDs: [owner.id], origin: .ownerReview(runID: run.id))
        var ownerDispatch = HarvisGroupDispatch(messageID: review.id, memberID: owner.id, permission: .discussion, state: .completed)
        ownerDispatch.nativeReplyVerified = verifiedOwner
        let ownerReply = HarvisGroupMessage(sequence: 4, memberID: owner.id, speaker: owner.name, text: "Final owner evidence", dispatchID: ownerDispatch.id)
        ownerDispatch.responseMessageID = ownerReply.id
        run.ownerDispatchID = coordinated ? ownerDispatch.id : nil
        var group = HarvisGroupConversation(title: "Change delivery", projectPath: "/private/hidden-project")
        group.members = [owner, worker]; group.messages = [root, memberReply, review, ownerReply]
        group.dispatches = [memberDispatch, ownerDispatch]; group.lastSequence = 4
        group.orchestration = .init(ownerMemberID: owner.id, backgroundEnabled: true, runs: [run])
        return group
    }
    private func seededAPI(_ groups: [HarvisGroupConversation]) async throws -> (URL, HarvisGroupCoordinator, CodexTaskDeliveryCoordinator, HarvisGroupControlAPI) {
        let directory = URL(fileURLWithPath: "/tmp/hga-service-" + UUID().uuidString)
        let store = HarvisGroupStore(url: directory.appendingPathComponent("groups.json"))
        try await store.save(groups)
        let delivery = CodexTaskDeliveryCoordinator(store: CodexTaskQueueStore(queueURL: directory.appendingPathComponent("queue.json")),
            handoffStore: CodexConversationHandoffStore(storeURL: directory.appendingPathComponent("handoffs.json")))
        let coordinator = HarvisGroupCoordinator(delivery: delivery, store: store)
        await coordinator.activate(); await delivery.activate(probeExecutablePath: "/fixture/no-executable")
        return (directory, coordinator, delivery, HarvisGroupControlAPI(coordinator: coordinator))
    }
    func testServiceDiscoveryAndMemberRunProgressDoNotRequireSessionManagement() async throws {
        let group = serviceGroup()
        var disabled = serviceGroup(); disabled.orchestration?.backgroundEnabled = false
        let (directory, coordinator, delivery, api) = try await seededAPI([group, disabled])
        defer { coordinator.deactivate(); try? FileManager.default.removeItem(at: directory) }
        let discovered = try await request(api, "groups.list")
        let descriptor = try XCTUnwrap(discovered["result"]?["groups"]?.arrayValue?.first?["service"])
        XCTAssertEqual(discovered["result"]?["groups"]?.arrayValue?.count, 1)
        XCTAssertEqual(descriptor["schemaVersion"], .string("harvis.agent-service.v1"))
        XCTAssertEqual(descriptor["serviceID"], .string("harvis-group:" + group.id.uuidString))
        XCTAssertEqual(descriptor["name"], .string(group.title))
        let responsibilities = try XCTUnwrap(descriptor["responsibilities"]?.arrayValue)
        XCTAssertEqual(responsibilities.count, 2)
        XCTAssertEqual(responsibilities[0]["memberID"], .string(group.members[0].id.uuidString))
        XCTAssertEqual(responsibilities[0]["name"], .string("Owner"))
        XCTAssertEqual(responsibilities[0]["role"], .string("Coordinate delivery"))
        XCTAssertEqual(responsibilities[0]["isOwner"], .bool(true))
        XCTAssertEqual(responsibilities[1]["role"], .string("Implementation"))
        XCTAssertEqual(responsibilities[1]["isOwner"], .bool(false))
        XCTAssertEqual(descriptor["capabilities"], .array(["task.submit", "task.status", "task.results", "task.cancel"].map(CodexJSONValue.string)))
        XCTAssertEqual(descriptor["defaultMode"], .string("coordinated"))
        XCTAssertEqual(descriptor["transports"], .array([.string("mcp"), .string("http")]))
        XCTAssertEqual(descriptor["requiresRunningApp"], .bool(true)); XCTAssertEqual(descriptor["ownerConfigured"], .bool(true))
        let status = try await request(api, "groups.status", ["groupID": .string(group.id.uuidString)])
        let members = try XCTUnwrap(status["result"]?["members"]?.arrayValue)
        let worker = try XCTUnwrap(members.first { $0["id"] == .string(group.members[1].id.uuidString) })
        XCTAssertEqual(worker["role"], .string("Implementation")); XCTAssertEqual(worker["isOwner"], .bool(false))
        XCTAssertEqual(members.first { $0["id"] == .string(group.members[0].id.uuidString) }?["isOwner"], .bool(true))
        XCTAssertEqual(worker["completedTaskCount"], .number(1)); XCTAssertEqual(worker["queuedTaskCount"], .number(0))
        XCTAssertEqual(worker["state"], .string("completed")); XCTAssertEqual(worker["currentTask"], .string("Implement and verify"))
        XCTAssertEqual(worker["awaitingHumanApproval"], .bool(false))
        let run = try XCTUnwrap(status["result"]?["runs"]?.arrayValue?.first)
        XCTAssertEqual(run["rootMessageID"], .string(group.messages[0].id.uuidString))
        XCTAssertEqual(run["messageID"], run["rootMessageID"])
        XCTAssertEqual(run["summary"], .string(group.runs[0].summary))
        XCTAssertEqual(run["ownerRound"], .number(2)); XCTAssertEqual(run["taskCount"], .number(1)); XCTAssertEqual(run["finishedTaskCount"], .number(1))
        let output = status.encodedString() ?? ""
        XCTAssertFalse(output.contains("hidden-owner-home")); XCTAssertFalse(output.contains("hidden-worker-home")); XCTAssertFalse(output.contains("hidden-project"))
        await delivery.deactivate()
    }
    func testOnlyCompletedRunWithVerifiedFinalOwnerReplyProducesDeliveryAndItFollowsMessagePages() async throws {
        let accepted = serviceGroup()
        let incomplete = serviceGroup(state: .needsInput)
        let unverified = serviceGroup(verifiedOwner: false)
        let direct = serviceGroup(coordinated: false)
        let (directory, coordinator, delivery, api) = try await seededAPI([accepted, incomplete, unverified, direct])
        defer { coordinator.deactivate(); try? FileManager.default.removeItem(at: directory) }
        for group in [incomplete, unverified, direct] {
            let result = try await request(api, "groups.results", ["groupID": .string(group.id.uuidString)])
            XCTAssertEqual(result["result"]?["deliveries"], .array([]), "Member completion or unverified owner output must not become a service delivery.")
            XCTAssertEqual(result["result"]?["messages"]?.arrayValue?.count, 4)
        }
        let first = try await request(api, "groups.results", ["groupID": .string(accepted.id.uuidString), "limit": .number(3)])
        XCTAssertEqual(first["result"]?["deliveries"], .array([])); XCTAssertEqual(first["result"]?["hasMore"], .bool(true))
        let last = try await request(api, "groups.results", ["groupID": .string(accepted.id.uuidString), "afterSequence": .number(3), "limit": .number(1)])
        let delivered = try XCTUnwrap(last["result"]?["deliveries"]?.arrayValue?.first)
        XCTAssertEqual(delivered["runID"], .string(accepted.runs[0].id.uuidString))
        XCTAssertEqual(delivered["rootMessageID"], .string(accepted.messages[0].id.uuidString))
        XCTAssertEqual(delivered["summary"], .string(accepted.runs[0].summary))
        XCTAssertEqual(delivered["finalSequence"], .number(4)); XCTAssertEqual(last["result"]?["nextSequence"], .number(4))
        let after = try await request(api, "groups.results", ["groupID": .string(accepted.id.uuidString), "afterSequence": .number(4)])
        XCTAssertEqual(after["result"]?["deliveries"], .array([]))
        await delivery.deactivate()
    }
    func testMalformedRPCIDsAndMethodsNeverTrapOrExecute() async throws {
        let api = HarvisGroupControlAPI(coordinator: HarvisGroupCoordinator(delivery: CodexTaskDeliveryCoordinator()))
        let oversizedID = Data("{\"jsonrpc\":\"2.0\",\"id\":9223372036854775808,\"method\":\"groups.list\"}".utf8)
        let result = try JSONDecoder().decode(CodexJSONValue.self, from: await api.handle(oversizedID))
        XCTAssertEqual(result["error"]?["code"], .number(-32600))
        let unknown = try await request(api, "groups.setOwner")
        XCTAssertEqual(unknown["error"]?["code"], .number(-32601))
    }
}
