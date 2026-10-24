import Foundation

/// The only external mutation path delegates to the existing durable coordinator.
@MainActor
final class HarvisGroupControlAPI {
    private let coordinator: HarvisGroupCoordinator
    init(coordinator: HarvisGroupCoordinator) { self.coordinator = coordinator }

    func handle(_ data: Data) async -> Data {
        var id: CodexJSONValue = .null
        do {
            guard data.count <= HarvisGroupControlServer.maximumMessageBytes,
                  let request = try JSONDecoder().decode(CodexJSONValue.self, from: data).objectValue,
                  request["jsonrpc"] == .string("2.0"),
                  let requestID = request["id"], validRPCID(requestID),
                  let method = request["method"]?.stringValue else { throw Failure(-32600, "Invalid JSON-RPC request.") }
            id = requestID
            guard Set(request.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]) else { throw Failure(-32600, "Unknown request fields.") }
            let params: [String: CodexJSONValue]
            if let value = request["params"] {
                guard let object = value.objectValue else { throw Failure(-32602, "params must be an object.") }; params = object
            } else { params = [:] }
            let result = try await call(method, params)
            return encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        } catch let error as Failure {
            return encode(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(error.code)), "message": .string(error.message)])]))
        } catch let HarvisGroupError.invalid(message) where message.hasPrefix("Request ID conflict:") {
            return encode(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32009), "message": .string("requestID was already accepted with a different payload.")])]))
        } catch {
            // Native errors can contain private profile paths or account responses.
            return encode(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32010), "message": .string("Group request was rejected. Check HarvisBar for details; no automatic retry was performed.")])]))
        }
    }
    private func call(_ method: String, _ params: [String: CodexJSONValue]) async throws -> CodexJSONValue {
        let allowed: Set<String>
        switch method {
        case "groups.list": allowed = []
        case "groups.status", "groups.recover": allowed = ["groupID"]
        case "groups.send": allowed = ["groupID", "text", "requestID", "mode", "memberIDs"]
        case "groups.results": allowed = ["groupID", "afterSequence", "limit"]
        case "groups.cancel": allowed = ["groupID", "runID", "memberID"]
        default: throw Failure(-32601, "Unknown group method.")
        }
        guard Set(params.keys).isSubset(of: allowed) else { throw Failure(-32602, "Unknown parameters; account, path and permission overrides are not accepted.") }
        guard coordinator.isReady, coordinator.delivery.isReady else { throw Failure(-32001, "HarvisBar group runtime is not ready. Keep the app running.") }
        if method == "groups.list" {
            return .object(["groups": .array(coordinator.groups.filter(\.backgroundEnabled).map(summary))])
        }
        let groupID = try uuid(params, "groupID")
        guard let group = coordinator.group(groupID), group.backgroundEnabled else { throw Failure(-32003, "Group is unavailable or background access is disabled in HarvisBar.") }
        switch method {
        case "groups.status":
            var value = summary(group).objectValue!
            value["members"] = .array(group.members.map { member in
                .object(["id": .string(member.id.uuidString), "name": .string(member.name),
                    "threadID": optional(member.binding?.threadID),
                    "awaitingHumanApproval": .bool(coordinator.liveState(groupID: group.id, memberID: member.id)?.pendingApproval != nil)])
            })
            value["dispatches"] = .array(group.dispatches.suffix(100).map { dispatch in
                .object(["id": .string(dispatch.id.uuidString), "messageID": .string(dispatch.messageID.uuidString),
                    "memberID": .string(dispatch.memberID.uuidString), "state": .string(dispatch.state.rawValue),
                    "threadID": optional(dispatch.binding?.threadID), "turnID": optional(dispatch.turnID),
                    "hasError": .bool(dispatch.lastError != nil), "nativeReplyVerified": .bool(dispatch.nativeReplyVerified)])
            })
            value["runs"] = .array(group.runs.suffix(100).map { run in
                .object(["id": .string(run.id.uuidString), "state": .string(run.state.rawValue),
                    "messageID": .string(run.rootMessageID.uuidString), "hasError": .bool(run.lastError != nil)])
            })
            return .object(value)
        case "groups.send":
            guard let text = params["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 200_000,
                  let requestID = params["requestID"]?.stringValue, !requestID.isEmpty, requestID.utf8.count <= 128 else {
                throw Failure(-32602, "send requires nonempty text (at most 200000 bytes) and a stable requestID (at most128 bytes).")
            }
            if let value = params["mode"], value.stringValue == nil { throw Failure(-32602, "mode must be a string.") }
            let mode = params["mode"]?.stringValue ?? "coordinated"
            let receipt: HarvisGroupSubmissionReceipt
            switch mode {
            case "coordinated":
                guard params["memberIDs"] == nil else { throw Failure(-32602, "coordinated mode does not accept memberIDs.") }
                receipt = try await coordinator.submitCoordinated(groupID: groupID, text: text, requestID: requestID, requireBackgroundEnabled: true)
            case "direct", "recordOnly":
                if let value = params["memberIDs"], value.arrayValue == nil { throw Failure(-32602, "memberIDs must be an array.") }
                guard let values = params["memberIDs"]?.arrayValue ?? (mode == "recordOnly" ? [] : nil),
                      values.count <= 64 else { throw Failure(-32602, "direct mode requires explicit memberIDs.") }
                let ids = try values.map { value -> UUID in
                    guard let raw = value.stringValue, let id = UUID(uuidString: raw) else { throw Failure(-32602, "Invalid memberID.") }; return id
                }
                guard mode != "direct" || !ids.isEmpty, mode != "recordOnly" || ids.isEmpty else { throw Failure(-32602, "direct requires recipients; recordOnly accepts none.") }
                receipt = try await coordinator.submitDirect(groupID: groupID, text: text, memberIDs: ids,
                    permission: group.projectPermission, requestID: requestID, requireBackgroundEnabled: true)
            default: throw Failure(-32602, "mode must be coordinated, direct or recordOnly.")
            }
            return try JSONDecoder().decode(CodexJSONValue.self, from: JSONEncoder().encode(receipt))
        case "groups.results":
            let after = try integer(params, "afterSequence", fallback: 0, range: 0 ... Int.max)
            let limit = try integer(params, "limit", fallback: 20, range: 1 ... 100)
            var messages: [CodexJSONValue] = []; var count = 0; var last = after
            for message in group.messages where message.sequence > after {
                let value = CodexJSONValue.object(["id": .string(message.id.uuidString), "sequence": .number(Double(message.sequence)),
                    "speaker": .string(message.speaker), "text": .string(message.text), "memberID": optional(message.memberID?.uuidString),
                    "dispatchID": optional(message.dispatchID?.uuidString), "threadID": optional(message.source?.threadID)])
                let bytes = try value.encodedData().count
                if count + bytes > 900_000 { break }
                messages.append(value); count += bytes; last = message.sequence
                if messages.count >= limit { break }
            }
            guard !messages.isEmpty || !group.messages.contains(where: { $0.sequence > after }) else { throw Failure(-32011, "Next message exceeds the control response limit; inspect it in HarvisBar native history.") }
            return .object(["messages": .array(messages), "nextSequence": .number(Double(last)), "hasMore": .bool(group.messages.contains { $0.sequence > last })])
        case "groups.cancel":
            if params["runID"] != nil {
                guard params["memberID"] == nil else { throw Failure(-32602, "Choose runID or memberID.") }
                let cancelled = await coordinator.cancelRun(groupID: groupID, runID: try uuid(params, "runID"))
                return .object(["cancelled": .bool(cancelled)])
            }
            let memberID = try uuid(params, "memberID")
            guard group.members.contains(where: { $0.id == memberID }) else { throw Failure(-32602, "Unknown memberID.") }
            await coordinator.stop(groupID: groupID, memberID: memberID)
            return .object(["stopRequested": .bool(true)])
        case "groups.recover":
            // History RPC can be slow. This operation never replays unknown commands.
            Task { await coordinator.recover(groupID: groupID) }
            return .object(["recoveryScheduled": .bool(true)])
        default: throw Failure(-32601, "Unknown group method.")
        }
    }
    private func summary(_ group: HarvisGroupConversation) -> CodexJSONValue {
        .object(["id": .string(group.id.uuidString), "title": .string(group.title), "backgroundEnabled": .bool(true),
            "ownerMemberID": optional(group.ownerMemberID?.uuidString), "projectPermission": .string(group.projectPermission.rawValue),
            "lastSequence": .number(Double(group.lastSequence))])
    }
    private func validRPCID(_ value: CodexJSONValue) -> Bool {
        if let string = value.stringValue { return string.utf8.count <= 256 }
        if case let .number(number) = value { return number.isFinite && number.rounded() == number && abs(number) < 9_007_199_254_740_992 }
        return false
    }
    private func uuid(_ params: [String: CodexJSONValue], _ key: String) throws -> UUID {
        guard let raw = params[key]?.stringValue, let id = UUID(uuidString: raw) else { throw Failure(-32602, "Invalid or missing \(key).") }; return id
    }
    private func integer(_ params: [String: CodexJSONValue], _ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = params[key] else { return fallback }
        // Avoid Double-to-Int upper-bound overflow in untrusted JSON.
        guard case let .number(number) = raw, number.isFinite, number.rounded() == number,
              number >= Double(range.lowerBound), number < Double(Int.max), number <= Double(range.upperBound) else { throw Failure(-32602, "Invalid \(key).") }
        return Int(number)
    }
    private func optional(_ value: String?) -> CodexJSONValue { value.map(CodexJSONValue.string) ?? .null }
    private func encode(_ value: CodexJSONValue) -> Data { (try? value.encodedData()) ?? Data("{}".utf8) }
    private struct Failure: Error { let code: Int; let message: String; init(_ code: Int, _ message: String) { self.code = code; self.message = message } }
}
