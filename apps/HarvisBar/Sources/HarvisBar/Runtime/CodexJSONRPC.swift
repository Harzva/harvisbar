import Foundation

enum CodexJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CodexJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var objectValue: [String: CodexJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [CodexJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case let .number(value) = self,
              value.rounded() == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    subscript(key: String) -> CodexJSONValue? {
        objectValue?[key]
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func encodedString() -> String? {
        guard let data = try? encodedData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum CodexRPCID: Codable, Equatable, Hashable, Sendable {
    case integer(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }

    var jsonValue: CodexJSONValue {
        switch self {
        case let .integer(value): return .number(Double(value))
        case let .string(value): return .string(value)
        }
    }

    var displayValue: String {
        switch self {
        case let .integer(value): return String(value)
        case let .string(value): return value
        }
    }
}

struct CodexServerRequest: Equatable, Sendable {
    let id: CodexRPCID
    let method: String
    let params: CodexJSONValue
}

enum CodexAppServerEvent: Equatable, Sendable {
    case connected(connectionID: UUID)
    case notification(
        method: String,
        params: CodexJSONValue,
        connectionID: UUID
    )
    case serverRequest(
        request: CodexServerRequest,
        connectionID: UUID
    )
    case standardError(message: String, connectionID: UUID)
    case disconnected(connectionID: UUID, reason: String)
}

enum CodexAppServerError: LocalizedError, Equatable, Sendable {
    case executableUnavailable
    case connectionClosed(String)
    case requestTimedOut(method: String)
    case rpc(code: Int?, message: String)
    case malformedMessage(String)
    case deliveryUncertain(method: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "Codex executable is unavailable."
        case let .connectionClosed(reason):
            return "Codex app-server connection closed: \(reason)"
        case let .requestTimedOut(method):
            return "Codex app-server request timed out: \(method)"
        case let .rpc(code, message):
            if let code {
                return "Codex app-server error \(code): \(message)"
            }
            return "Codex app-server error: \(message)"
        case let .malformedMessage(message):
            return "Malformed Codex app-server message: \(message)"
        case let .deliveryUncertain(method, reason):
            return "Delivery is unknown for \(method): \(reason)"
        }
    }
}

enum CodexJSONRPC {
    static func request(
        id: Int,
        method: String,
        params: CodexJSONValue
    ) -> CodexJSONValue {
        .object([
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
    }

    static func notification(
        method: String,
        params: CodexJSONValue? = nil
    ) -> CodexJSONValue {
        var object: [String: CodexJSONValue] = ["method": .string(method)]
        if let params {
            object["params"] = params
        }
        return .object(object)
    }

    static func response(
        id: CodexRPCID,
        result: CodexJSONValue
    ) -> CodexJSONValue {
        .object([
            "id": id.jsonValue,
            "result": result,
        ])
    }

    static func errorResponse(
        id: CodexRPCID,
        code: Int,
        message: String
    ) -> CodexJSONValue {
        .object([
            "id": id.jsonValue,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
    }
}
