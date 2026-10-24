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
        let output = status.encodedString() ?? ""
        XCTAssertFalse(output.contains("homePath")); XCTAssertFalse(output.contains("accountIdentity")); XCTAssertFalse(output.contains("projectPath"))
        let results = try await request(api, "groups.results", ["groupID": .string(groupID.uuidString)])
        XCTAssertEqual(results["result"]?["messages"]?.arrayValue?.count, 1)
        coordinator.deactivate(); await delivery.deactivate()
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
