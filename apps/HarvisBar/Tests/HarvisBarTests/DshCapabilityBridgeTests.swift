import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class DshCapabilityBridgeTests: XCTestCase {
    func testLiveIsolatedUserInputBridgeWithSyntheticSessionOnly() async throws {
        guard let value = ProcessInfo.processInfo.environment["HARVIS_DSH_INPUT_BRIDGE_SMOKE_PORT"],
              let port = Int(value) else {
            throw XCTSkip("Requires the isolated synthetic DSH Host fixture")
        }
        let endpoint = DshRuntimeEndpoint(homeID: "synthetic", profile: "bridge-smoke", port: port)
        let reader = DshConversationUserInputReader(client: DshCapabilityBridgeClient(endpoint: endpoint))
        let first = try await reader.read(sessionID: "synthetic-session")
        let second = try await reader.read(sessionID: "synthetic-session")
        XCTAssertEqual(first.authority, second.authority)
        XCTAssertEqual(first.sourceRevision, second.sourceRevision)
        XCTAssertEqual(first.totalCount, 1)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.items.first?.source, .human)
        XCTAssertFalse(first.isTruncated)
    }

    func testUserOnlyReaderUsesBoundedHostProjectionAndPreservesOriginLabels() async throws {
        let transport = BridgeFixtureTransport(replies: try [
            bridgeReply(bridgeCatalog()),
            bridgeReply(bridgePage(items: [bridgeItem(1, source: "human")], total: 2, cursor: "next")),
            bridgeReply(bridgePage(items: [bridgeItem(3, source: "unknown")], total: 2)),
        ])
        let result = try await bridgeReader(transport).read(sessionID: "session-one")
        XCTAssertEqual(result.items.map(\.id), ["user-1", "user-3"])
        XCTAssertEqual(result.items.map(\.source), [.human, .unknown])
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertFalse(result.isTruncated)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["capabilities.describe", "session.userInputs", "session.userInputs"])
        XCTAssertTrue(requests.allSatisfy { $0.path == "/harvis-bridge/v1" && $0.host == "127.0.0.1" })
        XCTAssertTrue(requests.allSatisfy { $0.noStore && !$0.handlesCookies })
        XCTAssertEqual(requests[1].limit, 100)
        XCTAssertNil(requests[1].cursor)
        XCTAssertEqual(requests[2].cursor, "next")
    }

    func testMissingCapabilityNeverFallsBackToFullHistory() async throws {
        let transport = BridgeFixtureTransport(replies: try [bridgeReply(bridgeCatalog(available: false))])
        do {
            _ = try await bridgeReader(transport).read(sessionID: "session-one")
            XCTFail("Unavailable extraction capability must stop before a source read")
        } catch {
            XCTAssertEqual(error as? DshCapabilityBridgeError, .unavailable)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["capabilities.describe"])
    }

    func testWrongSourceAuthorityAndRequestIdentityAreRejected() async throws {
        for change in ["home", "profile", "request", "schema"] {
            var reply = try bridgeReply(bridgeCatalog())
            if change == "home" { reply.homeID = "another-home" }
            if change == "profile" { reply.profile = "another-profile" }
            if change == "request" { reply.requestID = "another-request" }
            if change == "schema" { reply.schemaVersion = "harvis.dsh-bridge.v2" }
            let transport = BridgeFixtureTransport(replies: [reply])
            do {
                _ = try await DshCapabilityBridgeClient(endpoint: bridgeEndpoint, transport: transport).describe()
                XCTFail("Accepted mismatched \(change)")
            } catch {
                XCTAssertTrue(error is DshCapabilityBridgeError)
            }
        }
    }

    func testRestartOrRevisionChangeBetweenPagesCannotPublishMixedSnapshot() async throws {
        for change in ["runtime", "revision", "session", "duplicate", "cursor"] {
            var second = bridgePage(items: [bridgeItem(2)], total: 2)
            if change == "revision" { second["sourceRevision"] = "sha256:" + String(repeating: "b", count: 64) }
            if change == "session" { second["sessionId"] = "another-session" }
            if change == "duplicate" { second["items"] = [bridgeItem(1)] }
            if change == "cursor" { second["nextCursor"] = "next" }
            var secondReply = try bridgeReply(second)
            if change == "runtime" { secondReply.runtimeID = "restarted-runtime" }
            let transport = BridgeFixtureTransport(replies: try [
                bridgeReply(bridgeCatalog()),
                bridgeReply(bridgePage(items: [bridgeItem(1)], total: 2, cursor: "next")),
                secondReply,
            ])
            do {
                _ = try await bridgeReader(transport).read(sessionID: "session-one")
                XCTFail("Published a mixed \(change) snapshot")
            } catch {
                XCTAssertTrue(error is DshCapabilityBridgeError)
            }
        }
    }

    func testKnownNonHumanRowsAndOversizedTextFailClosed() async throws {
        for source in ["manager", "system", "tool", "oversized"] {
            var item = bridgeItem(1, source: source == "oversized" ? "human" : source)
            if source == "oversized" {
                item["text"] = String(repeating: "x", count: 12_001)
                item["originalCharacterCount"] = 12_001
            }
            let transport = BridgeFixtureTransport(replies: try [
                bridgeReply(bridgeCatalog()), bridgeReply(bridgePage(items: [item], total: 1)),
            ])
            do {
                _ = try await bridgeReader(transport).read(sessionID: "session-one")
                XCTFail("Accepted unsupported \(source) evidence")
            } catch {
                XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
            }
        }
    }

    func testReaderStopsAtOneThousandAndKeepsCoverageExplicit() async throws {
        var replies = try [bridgeReply(bridgeCatalog())]
        for page in 0..<10 {
            replies.append(try bridgeReply(bridgePage(
                items: ((page * 100 + 1)...(page * 100 + 100)).map { bridgeItem($0) },
                total: 1_100, cursor: "page-\(page + 1)"
            )))
        }
        let transport = BridgeFixtureTransport(replies: replies)
        let result = try await bridgeReader(transport).read(sessionID: "session-one")
        XCTAssertEqual(result.items.count, 1_000)
        XCTAssertEqual(result.totalCount, 1_100)
        XCTAssertEqual(result.nextCursor, "page-10")
        XCTAssertTrue(result.isTruncated)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 11)
    }

    func testUnavailableAndOversizedResponseNeverExposeRemoteBodiesAsErrors() async throws {
        let oversized = Data(repeating: 0x20, count: DshCapabilityBridgeClient.maximumResponseBytes + 1)
        for status in [404, 200] {
            let transport = BridgeFixtureTransport(replies: [BridgeFixtureReply(value: oversized, status: status)])
            do {
                _ = try await DshCapabilityBridgeClient(endpoint: bridgeEndpoint, transport: transport).describe()
                XCTFail("Accepted unavailable or oversized response")
            } catch {
                XCTAssertEqual(error as? DshCapabilityBridgeError, status == 404 ? .unavailable : .invalidResponse)
            }
        }
    }

    func testDuplicateCapabilitiesCannotAmbiguouslyEnableAnOperation() async throws {
        var catalog = bridgeCatalog()
        let entries = try XCTUnwrap(catalog["capabilities"] as? [[String: Any]])
        catalog["capabilities"] = entries + entries
        let transport = BridgeFixtureTransport(replies: try [bridgeReply(catalog)])
        do {
            _ = try await DshCapabilityBridgeClient(endpoint: bridgeEndpoint, transport: transport).describe()
            XCTFail("Accepted duplicate capability identity")
        } catch {
            XCTAssertEqual(error as? DshCapabilityBridgeError, .invalidResponse)
        }
    }
}

private let bridgeEndpoint = DshRuntimeEndpoint(homeID: "fixture-dsh", profile: "web", port: 9876)

private func bridgeReader(_ transport: BridgeFixtureTransport) -> DshConversationUserInputReader {
    DshConversationUserInputReader(client: DshCapabilityBridgeClient(endpoint: bridgeEndpoint, transport: transport))
}

private func bridgeCatalog(available: Bool = true) -> [String: Any] {
    [
        "schemaVersion": DshCapabilityCatalog.supportedSchemaVersion, "bridgeVersion": "0.1.0",
        "capabilities": [[
            "id": "session.userInputs", "version": 1, "title": "用户输入", "scope": "session",
            "operations": ["read"], "availability": available ? "available" : "unavailable",
            "requiresApproval": false, "supportsCancel": false,
        ]],
    ]
}

private func bridgeItem(_ sequence: Int, source: String = "unknown") -> [String: Any] {
    [
        "id": "user-\(sequence)", "sequence": sequence, "text": "Synthetic user evidence",
        "originalCharacterCount": 23, "truncated": false, "source": source,
    ]
}

private func bridgePage(items: [[String: Any]], total: Int, cursor: String? = nil) -> [String: Any] {
    var page: [String: Any] = [
        "schemaVersion": DshUserInputPage.supportedSchemaVersion, "sessionId": "session-one",
        "sourceAvailable": true, "sourceRevision": "sha256:" + String(repeating: "a", count: 64),
        "items": items, "totalItems": total, "excludedNonHumanItems": 4,
    ]
    if let cursor { page["nextCursor"] = cursor }
    return page
}

private func bridgeReply(_ value: [String: Any]) throws -> BridgeFixtureReply {
    BridgeFixtureReply(value: try JSONSerialization.data(withJSONObject: value))
}

private struct BridgeFixtureReply: Sendable {
    let value: Data
    var status = 200
    var homeID = "fixture-dsh"
    var profile = "web"
    var runtimeID = "fixture-runtime"
    var requestID: String?
    var schemaVersion = DshCapabilityBridgeClient.schemaVersion
}

private actor BridgeFixtureTransport: DshHostTransport {
    struct Request: Sendable {
        let method: String
        let path: String?
        let host: String?
        let noStore: Bool
        let handlesCookies: Bool
        let cursor: String?
        let limit: Int?
    }

    private var replies: [BridgeFixtureReply]
    private(set) var requests: [Request] = []

    init(replies: [BridgeFixtureReply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> DshHostTransportResponse {
        guard !replies.isEmpty, let data = request.httpBody,
              let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = rpc["requestId"] as? String,
              let method = rpc["method"] as? String else { throw DshCapabilityBridgeError.invalidResponse }
        let params = rpc["params"] as? [String: Any] ?? [:]
        requests.append(Request(
            method: method, path: request.url?.path, host: request.url?.host,
            noStore: request.value(forHTTPHeaderField: "Cache-Control") == "no-store",
            handlesCookies: request.httpShouldHandleCookies,
            cursor: params["cursor"] as? String, limit: params["limit"] as? Int
        ))
        let reply = replies.removeFirst()
        if reply.status != 200 || reply.value.count > DshCapabilityBridgeClient.maximumResponseBytes {
            return DshHostTransportResponse(data: reply.value, statusCode: reply.status)
        }
        let value = try JSONSerialization.jsonObject(with: reply.value)
        let envelope: [String: Any] = [
            "schemaVersion": reply.schemaVersion, "requestId": reply.requestID ?? requestID,
            "authority": ["homeID": reply.homeID, "profile": reply.profile, "runtimeId": reply.runtimeID],
            "result": ["ok": true, "value": value],
        ]
        return DshHostTransportResponse(
            data: try JSONSerialization.data(withJSONObject: envelope), statusCode: reply.status
        )
    }
}
