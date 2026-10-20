import Foundation
import XCTest
@testable import HarvisBar

final class DshSupervisorBridgeTests: XCTestCase {
    private let endpoint = DshRuntimeEndpoint(
        homeID: "fixture-home",
        profile: "web",
        port: 9876
    )
    private let sessionID = "root-session"
    private let runtimeID = "runtime-one"
    private let revision = "sha256:" + String(repeating: "a", count: 64)

    func testStateRecordsExactSessionAndRuntimeIdentity() async throws {
        let transport = SupervisorFixtureTransport(
            value: try stateData(sessionID: sessionID, revision: revision)
        )
        let client = makeClient(transport)

        let result = try await client.supervisorState(
            sessionID: sessionID,
            expectedRuntimeID: runtimeID,
            requestID: "state-request"
        )

        XCTAssertEqual(result.authority.runtimeID, runtimeID)
        XCTAssertEqual(result.value.sessionID, sessionID)
        XCTAssertEqual(result.value.revision, revision)
        let requestData = try await transport.singleRequest()
        let request = try requestObject(from: requestData)
        XCTAssertEqual(request["method"] as? String, "supervisor.session.state")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["sessionId"] as? String, sessionID)
        XCTAssertEqual(params["expectedRuntimeId"] as? String, runtimeID)
    }

    func testMutationMethodsAndPatchUseExactWireIdentity() async throws {
        let patch = DshSupervisorPatch(
            mode: "advice",
            strategy: "fixed",
            rounds: 3,
            intervalMs: 5_000
        )

        for operation in DshSupervisorOperation.allCases {
            let transport = SupervisorFixtureTransport(
                value: try stateData(sessionID: sessionID, revision: revision)
            )
            let client = makeClient(transport)
            _ = try await client.updateSupervisor(
                sessionID: sessionID,
                expectedRuntimeID: runtimeID,
                expectedRevision: revision,
                actionID: "action-\(operation.rawValue)",
                operation: operation,
                patch: operation == .set ? patch : nil,
                requestID: "request-\(operation.rawValue)"
            )

            let requestData = try await transport.singleRequest()
            let request = try requestObject(from: requestData)
            XCTAssertEqual(
                request["method"] as? String,
                "supervisor.session.\(operation.rawValue)"
            )
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["sessionId"] as? String, sessionID)
            XCTAssertEqual(params["expectedRuntimeId"] as? String, runtimeID)
            XCTAssertEqual(params["expectedRevision"] as? String, revision)
            XCTAssertEqual(
                params["actionId"] as? String,
                "action-\(operation.rawValue)"
            )
            if operation == .set {
                let wirePatch = try XCTUnwrap(params["patch"] as? [String: Any])
                XCTAssertEqual(wirePatch["mode"] as? String, "advice")
                XCTAssertEqual(wirePatch["strategy"] as? String, "fixed")
                XCTAssertEqual(wirePatch["rounds"] as? Int, 3)
                XCTAssertEqual(wirePatch["intervalMs"] as? Int, 5_000)
            } else {
                XCTAssertNil(params["patch"])
            }
        }
    }

    func testWrongRuntimeAuthorityIsRejectedAfterEnvelopeValidation() async throws {
        let transport = SupervisorFixtureTransport(
            value: try stateData(sessionID: sessionID, revision: revision),
            responseRuntimeID: "runtime-two"
        )

        do {
            _ = try await makeClient(transport).supervisorState(
                sessionID: sessionID,
                expectedRuntimeID: runtimeID
            )
            XCTFail("A restarted Supervisor runtime must not publish state")
        } catch {
            XCTAssertEqual(error as? DshCapabilityBridgeError, .authorityMismatch)
        }
    }

    func testWrongSessionIsRejectedForStateAndMutation() async throws {
        for mutation in [false, true] {
            let transport = SupervisorFixtureTransport(
                value: try stateData(sessionID: "another-session", revision: revision)
            )
            do {
                if mutation {
                    _ = try await makeClient(transport).updateSupervisor(
                        sessionID: sessionID,
                        expectedRuntimeID: runtimeID,
                        expectedRevision: revision,
                        actionID: "action",
                        operation: .recover
                    )
                } else {
                    _ = try await makeClient(transport).supervisorState(
                        sessionID: sessionID,
                        expectedRuntimeID: runtimeID
                    )
                }
                XCTFail("A response for another session must be rejected")
            } catch {
                XCTAssertEqual(error as? DshCapabilityBridgeError, .authorityMismatch)
            }
        }
    }

    func testMalformedRevisionAndStatusFailClosed() async throws {
        var malformedRevision = try stateValue(sessionID: sessionID, revision: "revision")
        malformedRevision["status"] = "idle"
        let revisionTransport = SupervisorFixtureTransport(value: try jsonData(malformedRevision))
        do {
            _ = try await makeClient(revisionTransport).supervisorState(
                sessionID: sessionID,
                expectedRuntimeID: runtimeID
            )
            XCTFail("A non-sha256 Supervisor revision must be rejected")
        } catch {
            XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
        }

        var malformedStatus = try stateValue(sessionID: sessionID, revision: revision)
        malformedStatus["status"] = 1
        let statusTransport = SupervisorFixtureTransport(value: try jsonData(malformedStatus))
        do {
            _ = try await makeClient(statusTransport).supervisorState(
                sessionID: sessionID,
                expectedRuntimeID: runtimeID
            )
            XCTFail("A non-string status must be rejected")
        } catch {
            XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
        }
    }

    func testInvalidPatchIsRejectedBeforeTransport() async throws {
        let transport = SupervisorFixtureTransport(
            value: try stateData(sessionID: sessionID, revision: revision)
        )
        do {
            _ = try await makeClient(transport).updateSupervisor(
                sessionID: sessionID,
                expectedRuntimeID: runtimeID,
                expectedRevision: revision,
                actionID: "action",
                operation: .set,
                patch: DshSupervisorPatch(mode: "unknown")
            )
            XCTFail("An unsupported patch mode must be rejected")
        } catch {
            XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testOperationPatchCombinationsFailClosedBeforeTransport() async throws {
        let validPatch = DshSupervisorPatch(mode: "advice")
        let cases: [(DshSupervisorOperation, DshSupervisorPatch?)] = [
            (.set, nil),
            (.set, DshSupervisorPatch()),
            (.regenerate, validPatch),
            (.adopt, validPatch),
            (.recover, validPatch),
        ]

        for (operation, patch) in cases {
            let transport = SupervisorFixtureTransport(
                value: try stateData(sessionID: sessionID, revision: revision)
            )
            do {
                _ = try await makeClient(transport).updateSupervisor(
                    sessionID: sessionID,
                    expectedRuntimeID: runtimeID,
                    expectedRevision: revision,
                    actionID: "action-\(operation.rawValue)",
                    operation: operation,
                    patch: patch
                )
                XCTFail("Expected invalid patch for \(operation.rawValue)")
            } catch {
                XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
            }
            let requestCount = await transport.requestCount()
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testRemoteStaleAndAmbiguousErrorsPropagate() async throws {
        for code in ["stale-revision", "ambiguous-session"] {
            let transport = SupervisorFixtureTransport(errorCode: code)
            do {
                _ = try await makeClient(transport).updateSupervisor(
                    sessionID: sessionID,
                    expectedRuntimeID: runtimeID,
                    expectedRevision: revision,
                    actionID: "action",
                    operation: .adopt
                )
                XCTFail("Expected remote \(code) failure")
            } catch {
                XCTAssertEqual(error as? DshCapabilityBridgeError, .remoteFailure(code))
            }
        }
    }

    func testStateValidatesBoundsAndAllowedModes() throws {
        var invalid = try stateValue(sessionID: sessionID, revision: revision)
        invalid["mode"] = "invalid"
        let state = try JSONDecoder().decode(DshSupervisorState.self, from: JSONSerialization.data(withJSONObject: invalid))
        XCTAssertThrowsError(try state.validate(expectedSessionID: sessionID)) { error in
            XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
        }

        invalid = try stateValue(sessionID: sessionID, revision: revision)
        invalid["intervalMs"] = 1_999
        let outOfBounds = try JSONDecoder().decode(DshSupervisorState.self, from: JSONSerialization.data(withJSONObject: invalid))
        XCTAssertThrowsError(try outOfBounds.validate(expectedSessionID: sessionID)) { error in
            XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
        }

        invalid = try stateValue(sessionID: sessionID, revision: revision)
        invalid["status"] = "idle"
        let invalidStatus = try JSONDecoder().decode(
            DshSupervisorState.self,
            from: JSONSerialization.data(withJSONObject: invalid)
        )
        XCTAssertThrowsError(try invalidStatus.validate(expectedSessionID: sessionID)) { error in
            XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
        }
    }

    func testStateAllowsOrdinarySuggestionWhitespace() throws {
        var valid = try stateValue(sessionID: sessionID, revision: revision)
        valid["suggestion"] = "第一行\n\t第二行\r\n"
        valid["recoveryRequired"] = "需要人工\n核对"
        let state = try JSONDecoder().decode(
            DshSupervisorState.self,
            from: JSONSerialization.data(withJSONObject: valid)
        )

        XCTAssertNoThrow(try state.validate(expectedSessionID: sessionID))
    }

    private func makeClient(_ transport: SupervisorFixtureTransport) -> DshCapabilityBridgeClient {
        DshCapabilityBridgeClient(endpoint: endpoint, transport: transport)
    }

    private func stateValue(
        sessionID: String,
        revision: String
    ) throws -> [String: Any] {
        [
            "schemaVersion": DshSupervisorState.supportedSchemaVersion,
            "sessionId": sessionID,
            "revision": revision,
            "mode": "advice",
            "strategy": "plan",
            "rounds": 1,
            "used": 0,
            "intervalMs": 2_000,
            "status": "silent",
            "suggestion": "",
            "suggestionId": "",
            "runId": "",
            "recoveryRequired": "",
            "done": false,
            "remaining": 0,
            "agentStatus": "",
            "mentorName": "",
            "suggestError": "",
        ]
    }

    private func stateData(
        sessionID: String,
        revision: String
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: stateValue(sessionID: sessionID, revision: revision)
        )
    }

    private func jsonData(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func requestObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor SupervisorFixtureTransport: DshHostTransport {
    private let value: Data?
    private let errorCode: String?
    private let responseRuntimeID: String
    private var requests: [Data] = []

    init(
        value: Data? = nil,
        errorCode: String? = nil,
        responseRuntimeID: String = "runtime-one"
    ) {
        self.value = value
        self.errorCode = errorCode
        self.responseRuntimeID = responseRuntimeID
    }

    func send(_ request: URLRequest) async throws -> DshHostTransportResponse {
        guard let body = request.httpBody else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        requests.append(body)
        let rpc = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let requestID = try XCTUnwrap(rpc["requestId"] as? String)
        let envelope: [String: Any]
        if let errorCode {
            envelope = [
                "schemaVersion": DshCapabilityBridgeClient.schemaVersion,
                "requestId": requestID,
                "authority": [
                    "homeID": "fixture-home",
                    "profile": "web",
                    "runtimeId": responseRuntimeID,
                ],
                "result": [
                    "ok": false,
                    "value": NSNull(),
                    "error": ["code": errorCode],
                ],
            ]
        } else {
            let jsonValue = try XCTUnwrap(value).jsonObject
            envelope = [
                "schemaVersion": DshCapabilityBridgeClient.schemaVersion,
                "requestId": requestID,
                "authority": [
                    "homeID": "fixture-home",
                    "profile": "web",
                    "runtimeId": responseRuntimeID,
                ],
                "result": ["ok": true, "value": jsonValue],
            ]
        }
        return DshHostTransportResponse(
            data: try JSONSerialization.data(withJSONObject: envelope),
            statusCode: 200
        )
    }

    func requestCount() -> Int { requests.count }

    func singleRequest() throws -> Data {
        guard requests.count == 1 else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        return requests[0]
    }
}

private extension Data {
    var jsonObject: Any {
        get throws {
            try JSONSerialization.jsonObject(with: self)
        }
    }
}
