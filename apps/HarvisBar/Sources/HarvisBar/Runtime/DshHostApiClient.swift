import Foundation

struct DshHostTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol DshHostTransport: Sendable {
    func send(_ request: URLRequest) async throws -> DshHostTransportResponse
}

struct DshURLSessionTransport: DshHostTransport {
    private let session: URLSession

    // RPC envelopes contain per-request IDs and current session authority.
    // Never share the application's persistent HTTP cache or cookie storage.
    private static let rpcSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    init(session: URLSession? = nil) {
        self.session = session ?? Self.rpcSession
    }

    func send(_ request: URLRequest) async throws -> DshHostTransportResponse {
        guard request.url?.host == "127.0.0.1" else {
            throw DshHostApiError.invalidEndpoint
        }
        let (data, response) = try await session.data(
            for: request,
            delegate: DshNoRedirectDelegate()
        )
        guard let response = response as? HTTPURLResponse else {
            throw DshHostApiError.invalidHTTPResponse
        }
        return DshHostTransportResponse(
            data: data,
            statusCode: response.statusCode
        )
    }
}

private final class DshNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum DshHostApiError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidRPCID
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidEnvelope
    case unexpectedResponseType(String)
    case rpcIDMismatch(expected: String, actual: String)
    case remoteFailure(code: String, message: String)
    case missingResultValue

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The DSH runtime endpoint is invalid."
        case .invalidRPCID:
            return "The DSH Host request rpcId is invalid."
        case .invalidHTTPResponse:
            return "The DSH Host returned a non-HTTP response."
        case let .httpStatus(status):
            return "The DSH Host returned HTTP \(status)."
        case .invalidEnvelope:
            return "The DSH Host returned an invalid response envelope."
        case let .unexpectedResponseType(type):
            return "The DSH Host returned response type \(type)."
        case let .rpcIDMismatch(expected, actual):
            return "The DSH Host returned rpcId \(actual), expected \(expected)."
        case let .remoteFailure(code, message):
            return "The DSH Host request failed (\(code)): \(message)"
        case .missingResultValue:
            return "The DSH Host response did not include a result value."
        }
    }
}

struct DshHostApiClient: Sendable {
    static let requestTimeout: TimeInterval = 5

    let endpoint: DshRuntimeEndpoint
    private let transport: any DshHostTransport

    init(
        endpoint: DshRuntimeEndpoint,
        transport: any DshHostTransport = DshURLSessionTransport()
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func hostDescribe(
        rpcID: String = UUID().uuidString
    ) async throws -> DshHostDescription {
        try await request(
            method: "host.describe",
            payload: EmptyPayload(),
            rpcID: rpcID,
            as: DshHostDescription.self
        )
    }

    func workspaceList(
        rpcID: String = UUID().uuidString
    ) async throws -> DshWorkspaceList {
        try await request(
            method: "workspace.list",
            payload: EmptyPayload(),
            rpcID: rpcID,
            as: DshWorkspaceList.self
        )
    }

    func sessionList(
        rpcID: String = UUID().uuidString
    ) async throws -> [DshChatSession] {
        let response = try await request(
            method: "session.list",
            payload: EmptyPayload(),
            rpcID: rpcID,
            as: DshSessionListValue.self
        )
        return response.items
            .filter { !$0.blank }
            .map { $0.chatSession(sourceScope: endpoint.sourceScope) }
    }

    func agentPresetList(
        rpcID: String = UUID().uuidString
    ) async throws -> DshAgentPresetListValue {
        try await request(
            method: "agentPreset.list",
            payload: EmptyPayload(),
            rpcID: rpcID,
            as: DshAgentPresetListValue.self
        )
    }

    func agentPresetRead(
        _ payload: DshAgentPresetReadPayload,
        rpcID: String = UUID().uuidString
    ) async throws -> DshAgentPresetReadValue {
        try await request(
            method: "agentPreset.read",
            payload: payload,
            rpcID: rpcID,
            as: DshAgentPresetReadValue.self
        )
    }

    func sessionCreate(
        _ payload: DshSessionCreatePayload,
        rpcID: String = UUID().uuidString
    ) async throws -> DshSessionCreateValue {
        try await request(
            method: "session.create",
            payload: payload,
            rpcID: rpcID,
            as: DshSessionCreateValue.self
        )
    }

    func sessionRename(
        _ payload: DshSessionRenamePayload,
        rpcID: String = UUID().uuidString
    ) async throws -> DshSessionRenameValue {
        try await request(
            method: "session.rename",
            payload: payload,
            rpcID: rpcID,
            as: DshSessionRenameValue.self
        )
    }

    func sessionPrompt(
        _ payload: DshSessionPromptPayload,
        rpcID: String = UUID().uuidString
    ) async throws -> DshSessionPromptValue {
        try await request(
            method: "session.prompt",
            payload: payload,
            rpcID: rpcID,
            as: DshSessionPromptValue.self
        )
    }

    func sessionHistory(
        _ payload: DshSessionHistoryPayload,
        rpcID: String = UUID().uuidString
    ) async throws -> DshSessionHistoryValue {
        try await request(
            method: "session.history",
            payload: payload,
            rpcID: rpcID,
            as: DshSessionHistoryValue.self
        )
    }

    func sessionCancel(
        _ payload: DshSessionCancelPayload,
        rpcID: String = UUID().uuidString
    ) async throws -> DshSessionCancelValue {
        try await request(
            method: "session.cancel",
            payload: payload,
            rpcID: rpcID,
            as: DshSessionCancelValue.self
        )
    }

    func discover() async throws -> DshChatDiscovery {
        let host = try await hostDescribe()
        let workspaceList = try await workspaceList()
        let sessions = try await sessionList()
        return DshChatDiscovery(
            endpoint: endpoint,
            sourceScope: endpoint.sourceScope,
            host: host,
            workspaces: workspaceList.items,
            archivedSessionIDs: workspaceList.archivedSessionIDs,
            sessions: sessions
        )
    }

    private func request<Payload: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String,
        payload: Payload,
        rpcID: String,
        as type: Value.Type
    ) async throws -> Value {
        guard (1...65_535).contains(endpoint.port),
              !endpoint.homeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !endpoint.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DshHostApiError.invalidEndpoint
        }
        guard !rpcID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DshHostApiError.invalidRPCID
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = endpoint.port
        components.path = "/api/\(method)"
        guard let url = components.url else {
            throw DshHostApiError.invalidEndpoint
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        urlRequest.timeoutInterval = Self.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.httpBody = try JSONEncoder().encode(
            RequestEnvelope(
                type: "client-request",
                rpcID: rpcID,
                method: method,
                payload: payload
            )
        )

        let response = try await transport.send(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw DshHostApiError.httpStatus(response.statusCode)
        }

        let envelope: ResponseEnvelope<Value>
        do {
            envelope = try JSONDecoder().decode(
                ResponseEnvelope<Value>.self,
                from: response.data
            )
        } catch {
            throw DshHostApiError.invalidEnvelope
        }
        guard envelope.type == "server-response" else {
            throw DshHostApiError.unexpectedResponseType(envelope.type)
        }
        guard envelope.rpcID == rpcID else {
            throw DshHostApiError.rpcIDMismatch(
                expected: rpcID,
                actual: envelope.rpcID
            )
        }
        guard envelope.result.ok else {
            guard let error = envelope.result.error else {
                throw DshHostApiError.invalidEnvelope
            }
            throw DshHostApiError.remoteFailure(
                code: error.code,
                message: error.message
            )
        }
        guard let value = envelope.result.value else {
            throw DshHostApiError.missingResultValue
        }
        return value
    }
}

private struct EmptyPayload: Encodable, Sendable {}

private struct RequestEnvelope<Payload: Encodable & Sendable>: Encodable, Sendable {
    let type: String
    let rpcID: String
    let method: String
    let payload: Payload

    private enum CodingKeys: String, CodingKey {
        case type
        case rpcID = "rpcId"
        case method
        case payload
    }
}

private struct ResponseEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let type: String
    let rpcID: String
    let result: ResponseResult<Value>

    private enum CodingKeys: String, CodingKey {
        case type
        case rpcID = "rpcId"
        case result
    }
}

private struct ResponseResult<Value: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let value: Value?
    let error: RemoteError?
}

private struct RemoteError: Decodable, Sendable {
    let code: String
    let message: String
}
