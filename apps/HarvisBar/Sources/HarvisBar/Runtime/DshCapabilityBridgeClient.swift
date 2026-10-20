import Foundation

/// JSON-only access to the optional Host bridge. Source sessions and plugin
/// state remain owned by DSH; this client holds no organization write handle.
struct DshCapabilityBridgeClient: Sendable {
    static let schemaVersion = "harvis.dsh-bridge.v1"
    static let maximumResponseBytes = 1_048_576

    let endpoint: DshRuntimeEndpoint
    private let transport: any DshHostTransport

    init(endpoint: DshRuntimeEndpoint, transport: any DshHostTransport = DshURLSessionTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func describe(requestID: String = UUID().uuidString) async throws -> DshBridgeValue<DshCapabilityCatalog> {
        let response: DshBridgeValue<DshCapabilityCatalog> = try await request(
            method: "capabilities.describe", params: EmptyParams(), requestID: requestID
        )
        try response.value.validate()
        return response
    }

    func userInputs(
        sessionID: String,
        cursor: String? = nil,
        limit: Int = 100,
        requestID: String = UUID().uuidString
    ) async throws -> DshBridgeValue<DshUserInputPage> {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256,
              (1...100).contains(limit),
              cursor.map({ !$0.isEmpty && $0.utf8.count <= 2_048 }) != false else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        let response: DshBridgeValue<DshUserInputPage> = try await request(
            method: "session.userInputs",
            params: UserInputsParams(sessionID: sessionID, cursor: cursor, limit: limit),
            requestID: requestID
        )
        try response.value.validate(expectedSessionID: sessionID, limit: limit)
        return response
    }

    func startGroupxReview(_ params: DshGroupxReviewStart) async throws -> DshBridgeValue<DshGroupxReviewJob> {
        try params.validate()
        let response: DshBridgeValue<DshGroupxReviewJob> = try await request(
            method: "groupx.review.start", params: params, requestID: UUID().uuidString
        )
        try response.value.validate(jobID: params.jobID, revision: params.proposalRevision)
        return response
    }

    func groupxReviewStatus(_ identity: DshGroupxReviewIdentity, cancel: Bool = false) async throws -> DshBridgeValue<DshGroupxReviewJob> {
        let response: DshBridgeValue<DshGroupxReviewJob> = try await request(
            method: cancel ? "groupx.review.cancel" : "groupx.review.status",
            params: identity, requestID: UUID().uuidString
        )
        try response.value.validate(jobID: identity.jobID, revision: identity.proposalRevision)
        return response
    }

    func supervisorState(
        sessionID: String,
        expectedRuntimeID: String,
        requestID: String = UUID().uuidString
    ) async throws -> DshBridgeValue<DshSupervisorState> {
        try validateSupervisorIdentity(
            sessionID: sessionID,
            expectedRuntimeID: expectedRuntimeID
        )
        let response: DshBridgeValue<DshSupervisorState> = try await request(
            method: "supervisor.session.state",
            params: SupervisorStateParams(
                sessionID: sessionID,
                expectedRuntimeID: expectedRuntimeID
            ),
            requestID: requestID
        )
        try validateSupervisorAuthority(
            response.authority,
            expectedRuntimeID: expectedRuntimeID
        )
        try response.value.validate(expectedSessionID: sessionID)
        return response
    }

    func updateSupervisor(
        sessionID: String,
        expectedRuntimeID: String,
        expectedRevision: String,
        actionID: String,
        operation: DshSupervisorOperation,
        patch: DshSupervisorPatch? = nil,
        requestID: String = UUID().uuidString
    ) async throws -> DshBridgeValue<DshSupervisorState> {
        try validateSupervisorIdentity(
            sessionID: sessionID,
            expectedRuntimeID: expectedRuntimeID
        )
        guard DshUserInputPage.isRevision(expectedRevision),
              !actionID.isEmpty,
              actionID.utf8.count <= 128,
              actionID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        switch operation {
        case .set:
            guard let patch else { throw DshCapabilityBridgeError.invalidResponse }
            try patch.validate()
        case .regenerate, .adopt, .recover:
            guard patch == nil else { throw DshCapabilityBridgeError.invalidResponse }
        }
        let response: DshBridgeValue<DshSupervisorState> = try await request(
            method: "supervisor.session.\(operation.rawValue)",
            params: SupervisorMutationParams(
                sessionID: sessionID,
                expectedRuntimeID: expectedRuntimeID,
                expectedRevision: expectedRevision,
                actionID: actionID,
                patch: patch
            ),
            requestID: requestID
        )
        try validateSupervisorAuthority(
            response.authority,
            expectedRuntimeID: expectedRuntimeID
        )
        try response.value.validate(expectedSessionID: sessionID)
        return response
    }

    private func validateSupervisorIdentity(
        sessionID: String,
        expectedRuntimeID: String
    ) throws {
        guard !sessionID.isEmpty,
              sessionID.utf8.count <= 256,
              sessionID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !expectedRuntimeID.isEmpty,
              expectedRuntimeID.utf8.count <= 128,
              expectedRuntimeID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DshCapabilityBridgeError.invalidResponse
        }
    }

    private func validateSupervisorAuthority(
        _ authority: DshBridgeAuthority,
        expectedRuntimeID: String
    ) throws {
        guard authority.runtimeID == expectedRuntimeID else {
            throw DshCapabilityBridgeError.authorityMismatch
        }
    }

    private func request<Params: Encodable & Sendable, Value: Decodable & Sendable>(
        method: String, params: Params, requestID: String
    ) async throws -> DshBridgeValue<Value> {
        try Task.checkCancellation()
        guard (1...65_535).contains(endpoint.port),
              !endpoint.homeID.isEmpty, !endpoint.profile.isEmpty,
              !requestID.isEmpty, requestID.utf8.count <= 128 else {
            throw DshCapabilityBridgeError.invalidEndpoint
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = endpoint.port
        components.path = "/harvis-bridge/v1"
        guard let url = components.url else { throw DshCapabilityBridgeError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = DshHostApiClient.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(RequestEnvelope(
            schemaVersion: Self.schemaVersion, requestID: requestID, method: method, params: params
        ))
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.statusCode != 404 else { throw DshCapabilityBridgeError.unavailable }
        guard response.data.count <= Self.maximumResponseBytes,
              (200..<300).contains(response.statusCode) else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        let envelope: ResponseEnvelope<Value>
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope<Value>.self, from: response.data)
        } catch {
            throw DshCapabilityBridgeError.invalidResponse
        }
        guard envelope.schemaVersion == Self.schemaVersion else {
            throw DshCapabilityBridgeError.incompatibleContract
        }
        guard envelope.requestID == requestID else { throw DshCapabilityBridgeError.invalidResponse }
        try envelope.authority.validate(for: endpoint)
        guard envelope.result.ok else {
            guard envelope.result.value == nil, let error = envelope.result.error,
                  !error.code.isEmpty, error.code.utf8.count <= 128 else {
                throw DshCapabilityBridgeError.invalidResponse
            }
            throw DshCapabilityBridgeError.remoteFailure(error.code)
        }
        guard envelope.result.error == nil, let value = envelope.result.value else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        return DshBridgeValue(authority: envelope.authority, value: value)
    }
}

private struct EmptyParams: Encodable, Sendable {}

private struct UserInputsParams: Encodable, Sendable {
    let sessionID: String
    let cursor: String?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cursor, limit
    }
}

private struct SupervisorStateParams: Encodable, Sendable {
    let sessionID: String
    let expectedRuntimeID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case expectedRuntimeID = "expectedRuntimeId"
    }
}

private struct SupervisorMutationParams: Encodable, Sendable {
    let sessionID: String
    let expectedRuntimeID: String
    let expectedRevision: String
    let actionID: String
    let patch: DshSupervisorPatch?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case expectedRuntimeID = "expectedRuntimeId"
        case expectedRevision, actionID = "actionId", patch
    }
}

private struct RequestEnvelope<Params: Encodable & Sendable>: Encodable, Sendable {
    let schemaVersion: String
    let requestID: String
    let method: String
    let params: Params

    enum CodingKeys: String, CodingKey {
        case schemaVersion, method, params
        case requestID = "requestId"
    }
}

private struct ResponseEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let schemaVersion: String
    let requestID: String
    let authority: DshBridgeAuthority
    let result: ResultEnvelope<Value>

    enum CodingKeys: String, CodingKey {
        case schemaVersion, authority, result
        case requestID = "requestId"
    }
}

private struct ResultEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let code: String
    }

    let ok: Bool
    let value: Value?
    let error: Failure?
}
