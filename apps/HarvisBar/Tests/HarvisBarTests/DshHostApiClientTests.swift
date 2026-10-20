import CryptoKit
import Foundation
import XCTest
@testable import HarvisBar

final class DshHostApiClientTests: XCTestCase {
    func testDiscoveryUsesLoopbackReadOnlyRPCsAndReturnsSafeMetadata() async throws {
        let transport = RecordingDshHostTransport { request in
            let rpc = try RecordedDshRequest(request)
            let value: Any
            switch rpc.method {
            case "host.describe":
                value = [
                    "app": ["name": "DeepSeek Harness", "version": "0.0.1"],
                    "futureField": ["ignored": true],
                ]
            case "workspace.list":
                value = [
                    "items": [[
                        "workspaceId": "workspace-1",
                        "path": "/tmp/project",
                        "title": "Project",
                        "sessionIds": ["session-title", "session-fallback"],
                        "createdAt": "2026-08-23T00:00:00Z",
                        "updatedAt": "2026-08-23T01:00:00Z",
                        "futureField": 42,
                    ]],
                    "archivedSessionIds": ["archived-1"],
                    "futureField": true,
                ]
            case "session.list":
                value = [
                    "items": [
                        [
                            "sessionId": "session-title",
                            "updatedAt": 1_700_000_123_456,
                            "running": true,
                            "blank": false,
                            "cwd": "/tmp/project",
                            "projections": [
                                "asOfSeq": 9,
                                "values": ["title": "  Project planning  ", "future": true],
                            ],
                            "futureField": ["ignored": true],
                        ],
                        [
                            "sessionId": "session-blank",
                            "updatedAt": 1_700_000_000_000,
                            "running": false,
                            "blank": true,
                        ],
                        [
                            "sessionId": "fallback-123456",
                            "updatedAt": 1_700_000_999_999,
                            "running": false,
                            "blank": false,
                            "title": "must not be used",
                            "projections": ["values": ["title": 42]],
                        ],
                    ],
                    "futureField": "ignored",
                ]
            default:
                throw TestFailure.unexpectedMethod(rpc.method)
            }
            return try serverResponse(rpcID: rpc.rpcID, value: value)
        }
        let endpoint = DshRuntimeEndpoint(
            homeID: "dsh-dev",
            profile: "web",
            port: 30_80
        )
        let discovery = try await DshHostApiClient(
            endpoint: endpoint,
            transport: transport
        ).discover()

        XCTAssertEqual(discovery.sourceScope, "dsh::dsh-dev::web")
        XCTAssertEqual(discovery.host.applicationName, "DeepSeek Harness")
        XCTAssertEqual(discovery.host.applicationVersion, "0.0.1")
        XCTAssertEqual(discovery.workspaces.map(\.workspaceID), ["workspace-1"])
        XCTAssertEqual(discovery.archivedSessionIDs, ["archived-1"])
        XCTAssertEqual(discovery.sessions.count, 2)
        XCTAssertEqual(discovery.sessions[0].sourceID, "session-title")
        XCTAssertEqual(discovery.sessions[0].sourceScope, "dsh::dsh-dev::web")
        XCTAssertEqual(discovery.sessions[0].title, "Project planning")
        XCTAssertEqual(discovery.sessions[0].titleSource, "projection")
        XCTAssertTrue(discovery.sessions[0].hasMeaningfulTitle)
        XCTAssertEqual(discovery.sessions[0].updatedAt, 1_700_000_123)
        XCTAssertTrue(discovery.sessions[0].running)
        XCTAssertEqual(discovery.sessions[1].title, "DSH Session fallback")
        XCTAssertEqual(discovery.sessions[1].titleSource, "fallback")
        XCTAssertFalse(discovery.sessions[1].hasMeaningfulTitle)
        XCTAssertEqual(discovery.sessions[1].updatedAt, 1_700_000_999)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.compactMap { $0.url?.path },
            ["/api/host.describe", "/api/workspace.list", "/api/session.list"]
        )
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "http")
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.port, 30_80)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.timeoutInterval, 5, accuracy: 0.001)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            let body = try RecordedDshRequest(request)
            XCTAssertEqual(body.type, "client-request")
            XCTAssertEqual(request.url?.lastPathComponent, body.method)
            XCTAssertEqual(body.payload, .object([:]))
            XCTAssertEqual(
                body.envelopeKeys,
                Set(["type", "rpcId", "method", "payload"])
            )
        }
    }

    func testManagementRPCsPreserveExactEnvelopePayloadAndCallerRPCID() async throws {
        let transport = RecordingDshHostTransport { request in
            let rpc = try RecordedDshRequest(request)
            let value: Any
            switch rpc.method {
            case "agentPreset.list":
                value = [
                    "presets": [[
                        "id": "harvis-meta-manager",
                        "trust": "user",
                        "isDefault": false,
                        "name": "Harvis Meta Manager",
                        "description": "Plans project-level work",
                    ]],
                    "authorable": true,
                    "hasDocument": true,
                ]
            case "agentPreset.read":
                value = [
                    "agentPreset": "harvis-meta-manager",
                    "trust": "user",
                    "content": "- id: persona\n  name: '@deepseek-ai/dsh-persona'\n",
                    "name": "Harvis Project Brain",
                    "description": "Proposal only",
                ]
            case "session.create":
                value = [
                    "sessionId": "meta-session",
                    "agentPreset": "harvis-meta-manager",
                ]
            case "session.rename":
                value = ["title": "Meta control", "seq": 4]
            case "session.prompt":
                value = ["accepted": true]
            case "session.history":
                value = [
                    "events": [[
                        "event": [
                            "type": "user/message",
                            "seq": 7,
                            "time": 1_777_777_777_777,
                            "data": [
                                "source": [
                                    "kind": "user",
                                    "rpcId": "rpc-prompt",
                                ],
                                "content": [["type": "text", "text": "Plan next work"]],
                            ],
                        ],
                        "view": ["for": "user/message", "kind": "message"],
                    ]],
                    "hasMore": false,
                    "projections": [
                        "asOfSeq": 7,
                        "values": ["title": "Meta control"],
                    ],
                ]
            case "session.cancel":
                value = ["accepted": true]
            default:
                throw TestFailure.unexpectedMethod(rpc.method)
            }
            return try serverResponse(rpcID: rpc.rpcID, value: value)
        }
        let client = makeClient(transport: transport)

        let presets = try await client.agentPresetList(rpcID: "rpc-presets")
        let preset = try await client.agentPresetRead(
            DshAgentPresetReadPayload(agentPreset: "harvis-meta-manager"),
            rpcID: "rpc-preset-read"
        )
        let created = try await client.sessionCreate(
            DshSessionCreatePayload(
                workspaceID: "workspace-1",
                sessionID: "meta-session",
                agentPreset: "harvis-meta-manager"
            ),
            rpcID: "rpc-create"
        )
        let renamed = try await client.sessionRename(
            DshSessionRenamePayload(
                sessionID: "meta-session",
                title: "Meta control"
            ),
            rpcID: "rpc-rename"
        )
        let prompted = try await client.sessionPrompt(
            DshSessionPromptPayload(
                sessionID: "meta-session",
                mode: .queue,
                content: [
                    .text("Plan next work"),
                    .image(
                        mediaType: "image/png",
                        data: "aW1hZ2U=",
                        name: "evidence.png"
                    ),
                ],
                clientTimeZone: "Asia/Shanghai"
            ),
            rpcID: "rpc-prompt"
        )
        let history = try await client.sessionHistory(
            DshSessionHistoryPayload(
                sessionID: "meta-session",
                beforeSeq: 100,
                maxMessages: 25
            ),
            rpcID: "rpc-history"
        )
        let cancelled = try await client.sessionCancel(
            DshSessionCancelPayload(sessionID: "meta-session"),
            rpcID: "rpc-cancel"
        )

        XCTAssertEqual(presets.presets.map(\.id), ["harvis-meta-manager"])
        XCTAssertEqual(presets.presets.first?.trust, .user)
        XCTAssertTrue(presets.authorable)
        XCTAssertTrue(presets.hasDocument)
        XCTAssertEqual(preset.agentPreset, "harvis-meta-manager")
        XCTAssertEqual(preset.trust, .user)
        XCTAssertTrue(preset.content.contains("@deepseek-ai/dsh-persona"))
        XCTAssertEqual(created.sessionID, "meta-session")
        XCTAssertEqual(created.agentPreset, "harvis-meta-manager")
        XCTAssertEqual(renamed, DshSessionRenameValue(title: "Meta control", seq: 4))
        XCTAssertTrue(prompted.accepted)
        XCTAssertNil(prompted.command)
        XCTAssertEqual(history.events.first?.event.type, "user/message")
        XCTAssertEqual(history.events.first?.event.seq, 7)
        XCTAssertEqual(history.events.first?.event.time, 1_777_777_777_777)
        XCTAssertEqual(
            history.events.first?.event.data["source"]?["rpcId"]?.stringValue,
            "rpc-prompt"
        )
        XCTAssertEqual(
            history.events.first?.view?["for"]?.stringValue,
            "user/message"
        )
        XCTAssertEqual(history.projections?.asOfSeq, 7)
        XCTAssertEqual(
            history.projections?.values["title"]?.stringValue,
            "Meta control"
        )
        XCTAssertFalse(history.hasMore)
        XCTAssertTrue(cancelled.accepted)

        let requests = await transport.recordedRequests()
        let recorded = try requests.map(RecordedDshRequest.init)
        XCTAssertEqual(
            recorded.map(\.method),
            [
                "agentPreset.list",
                "agentPreset.read",
                "session.create",
                "session.rename",
                "session.prompt",
                "session.history",
                "session.cancel",
            ]
        )
        XCTAssertEqual(
            recorded.map(\.rpcID),
            [
                "rpc-presets",
                "rpc-preset-read",
                "rpc-create",
                "rpc-rename",
                "rpc-prompt",
                "rpc-history",
                "rpc-cancel",
            ]
        )
        XCTAssertEqual(
            requests.compactMap { $0.url?.path },
            [
                "/api/agentPreset.list",
                "/api/agentPreset.read",
                "/api/session.create",
                "/api/session.rename",
                "/api/session.prompt",
                "/api/session.history",
                "/api/session.cancel",
            ]
        )
        XCTAssertTrue(recorded.allSatisfy {
            $0.type == "client-request"
                && $0.envelopeKeys == Set(["type", "rpcId", "method", "payload"])
        })
        XCTAssertTrue(requests.allSatisfy {
            $0.url?.scheme == "http"
                && $0.url?.host == "127.0.0.1"
                && $0.url?.port == 3_080
                && $0.httpMethod == "POST"
                && abs($0.timeoutInterval - 5) < 0.001
                && $0.value(forHTTPHeaderField: "Content-Type") == "application/json"
        })
        XCTAssertEqual(recorded[0].payload, .object([:]))
        XCTAssertEqual(
            recorded[1].payload,
            .object(["agentPreset": .string("harvis-meta-manager")])
        )
        XCTAssertEqual(
            recorded[2].payload,
            .object([
                "workspaceId": .string("workspace-1"),
                "sessionId": .string("meta-session"),
                "agentPreset": .string("harvis-meta-manager"),
            ])
        )
        XCTAssertEqual(
            recorded[3].payload,
            .object([
                "sessionId": .string("meta-session"),
                "title": .string("Meta control"),
            ])
        )
        XCTAssertEqual(
            recorded[4].payload,
            .object([
                "sessionId": .string("meta-session"),
                "mode": .string("queue"),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Plan next work"),
                    ]),
                    .object([
                        "type": .string("image"),
                        "mediaType": .string("image/png"),
                        "data": .string("aW1hZ2U="),
                        "name": .string("evidence.png"),
                    ]),
                ]),
                "clientTimeZone": .string("Asia/Shanghai"),
            ])
        )
        XCTAssertEqual(
            recorded[5].payload,
            .object([
                "sessionId": .string("meta-session"),
                "beforeSeq": .number(100),
                "maxMessages": .number(25),
            ])
        )
        XCTAssertEqual(
            recorded[6].payload,
            .object(["sessionId": .string("meta-session")])
        )
    }

    func testMismatchedRPCIDIsRejected() async throws {
        let transport = RecordingDshHostTransport { _ in
            try serverResponse(rpcID: "wrong-id", value: ["items": []])
        }
        let client = makeClient(transport: transport)

        do {
            _ = try await client.sessionList(rpcID: "rpc-list")
            XCTFail("A mismatched rpcId must be rejected")
        } catch let error as DshHostApiError {
            guard case let .rpcIDMismatch(expected, actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, "rpc-list")
            XCTAssertEqual(actual, "wrong-id")
        }
    }

    func testInsightCapabilityVerifierRequiresExactToolFreeComposition() async throws {
        let safeContent = "- id: persona\n  name: '@deepseek-ai/dsh-persona'\n"
        let digest = SHA256.hash(data: Data(safeContent.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let transport = RecordingDshHostTransport { request in
            let rpc = try RecordedDshRequest(request)
            let value: Any
            switch rpc.method {
            case "agentPreset.list":
                value = [
                    "presets": [[
                        "id": "harvis-meta-manager",
                        "trust": "user",
                        "isDefault": false,
                    ]],
                    "authorable": true,
                    "hasDocument": true,
                ]
            case "agentPreset.read":
                value = [
                    "agentPreset": "harvis-meta-manager",
                    "trust": "user",
                    "content": safeContent,
                ]
            default:
                throw TestFailure.unexpectedMethod(rpc.method)
            }
            return try serverResponse(rpcID: rpc.rpcID, value: value)
        }
        let endpoint = DshRuntimeEndpoint(
            homeID: DshMetaAgentPolicy.dedicatedHomeID,
            profile: DshMetaAgentPolicy.dedicatedProfile,
            port: 3_080
        )
        let verifier = DshHostManagedConversationInsightCapabilityVerifier(
            makeClient: { endpoint in
                DshHostApiClient(endpoint: endpoint, transport: transport)
            },
            acceptedCompositionSHA256: digest,
            attestReviewedRuntime: {
                "sha256:" + String(repeating: "1", count: 64)
            }
        )

        let available = await verifier.verify(
            endpoint: endpoint,
            presetID: DshMetaAgentPolicy.requiredPresetID
        )
        guard case let .verified(attestation) = available else {
            return XCTFail("The exact composition should be attested")
        }
        XCTAssertTrue(attestation.provesToolFreeNoSideEffects)
        XCTAssertTrue(attestation.catalogRevision.hasPrefix("sha256:"))
        XCTAssertEqual(attestation.catalogRevision.count, 71)

        let rejected = DshHostManagedConversationInsightCapabilityVerifier(
            makeClient: { endpoint in
                DshHostApiClient(endpoint: endpoint, transport: transport)
            },
            acceptedCompositionSHA256: String(repeating: "0", count: 64),
            attestReviewedRuntime: {
                "sha256:" + String(repeating: "1", count: 64)
            }
        )
        let unavailable = await rejected.verify(
            endpoint: endpoint,
            presetID: DshMetaAgentPolicy.requiredPresetID
        )
        XCTAssertFalse(unavailable.isAvailable)
    }

    func testReviewedInsightRuntimeMatchesWhenDedicatedHomeExists() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh-harvis-meta", isDirectory: true)
        guard FileManager.default.fileExists(atPath: home.path) else {
            throw XCTSkip("Dedicated local DSH insight Home is not installed")
        }
        let revision = try DshHostManagedConversationInsightCapabilityVerifier
            .reviewedRuntimeRevision()
        XCTAssertTrue(revision.hasPrefix("sha256:"))
        XCTAssertEqual(revision.count, 71)
    }

    func testWrongResponseTypeAndMissingResultAreRejected() async throws {
        let wrongType = RecordingDshHostTransport { request in
            let rpc = try RecordedDshRequest(request)
            return try serverResponse(
                rpcID: rpc.rpcID,
                type: "client-response",
                value: ["items": []]
            )
        }
        do {
            _ = try await makeClient(transport: wrongType).workspaceList()
            XCTFail("A non-server response must be rejected")
        } catch let error as DshHostApiError {
            XCTAssertEqual(error, .unexpectedResponseType("client-response"))
        }

        let missingResult = RecordingDshHostTransport { request in
            let rpc = try RecordedDshRequest(request)
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "server-response",
                "rpcId": rpc.rpcID,
            ])
            return DshHostTransportResponse(data: data, statusCode: 200)
        }
        do {
            _ = try await makeClient(transport: missingResult).workspaceList()
            XCTFail("A missing result must be rejected")
        } catch let error as DshHostApiError {
            XCTAssertEqual(error, .invalidEnvelope)
        }
    }

    func testRemoteFailureIsPreservedWithoutReadingDetails() async throws {
        let transport = RecordingDshHostTransport { request in
            let rpc = try RecordedDshRequest(request)
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "server-response",
                "rpcId": rpc.rpcID,
                "result": [
                    "ok": false,
                    "error": [
                        "code": "session-store-unavailable",
                        "message": "Session metadata is unavailable",
                        "details": ["private": "ignored"],
                    ],
                ],
            ])
            return DshHostTransportResponse(data: data, statusCode: 200)
        }

        do {
            _ = try await makeClient(transport: transport).sessionList()
            XCTFail("A failed result must be rejected")
        } catch let error as DshHostApiError {
            XCTAssertEqual(
                error,
                .remoteFailure(
                    code: "session-store-unavailable",
                    message: "Session metadata is unavailable"
                )
            )
        }
    }

    func testMutationTransportFailureIsNotRetried() async throws {
        let transport = RecordingDshHostTransport { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await makeClient(transport: transport).sessionPrompt(
                DshSessionPromptPayload(
                    sessionID: "meta-session",
                    mode: .queue,
                    content: [.text("Plan next work")]
                ),
                rpcID: "rpc-no-retry"
            )
            XCTFail("The transport failure should surface")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testInvalidCallerRPCIDFailsBeforeTransport() async throws {
        let transport = RecordingDshHostTransport { _ in
            throw TestFailure.transportShouldNotRun
        }

        do {
            _ = try await makeClient(transport: transport).agentPresetList(
                rpcID: " \n "
            )
            XCTFail("A blank caller rpcId must fail closed")
        } catch let error as DshHostApiError {
            XCTAssertEqual(error, .invalidRPCID)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testInvalidEndpointFailsBeforeTransport() async throws {
        let transport = RecordingDshHostTransport { _ in
            throw TestFailure.transportShouldNotRun
        }
        let client = DshHostApiClient(
            endpoint: DshRuntimeEndpoint(homeID: "dsh", profile: "web", port: 0),
            transport: transport
        )

        do {
            _ = try await client.hostDescribe()
            XCTFail("An invalid port must fail closed")
        } catch let error as DshHostApiError {
            XCTAssertEqual(error, .invalidEndpoint)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    private func makeClient(
        transport: RecordingDshHostTransport
    ) -> DshHostApiClient {
        DshHostApiClient(
            endpoint: DshRuntimeEndpoint(homeID: "dsh", profile: "web", port: 3080),
            transport: transport
        )
    }
}

private actor RecordingDshHostTransport: DshHostTransport {
    typealias Handler = @Sendable (URLRequest) throws -> DshHostTransportResponse

    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> DshHostTransportResponse {
        requests.append(request)
        return try handler(request)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }
}

private struct RecordedDshRequest {
    let type: String
    let rpcID: String
    let method: String
    let payload: DshJSONValue
    let envelopeKeys: Set<String>

    private struct Wire: Decodable {
        let type: String
        let rpcID: String
        let method: String
        let payload: DshJSONValue

        private enum CodingKeys: String, CodingKey {
            case type
            case rpcID = "rpcId"
            case method
            case payload
        }
    }

    init(_ request: URLRequest) throws {
        guard let body = request.httpBody else {
            throw TestFailure.missingBody
        }
        let wire = try JSONDecoder().decode(Wire.self, from: body)
        guard let object = try JSONSerialization.jsonObject(with: body)
            as? [String: Any] else {
            throw TestFailure.invalidBody
        }
        type = wire.type
        rpcID = wire.rpcID
        method = wire.method
        payload = wire.payload
        envelopeKeys = Set(object.keys)
    }
}

private enum TestFailure: Error {
    case missingBody
    case invalidBody
    case transportShouldNotRun
    case unexpectedMethod(String)
}

private func serverResponse(
    rpcID: String,
    type: String = "server-response",
    value: Any
) throws -> DshHostTransportResponse {
    let data = try JSONSerialization.data(withJSONObject: [
        "type": type,
        "rpcId": rpcID,
        "result": ["ok": true, "value": value],
        "futureField": true,
    ])
    return DshHostTransportResponse(data: data, statusCode: 200)
}
