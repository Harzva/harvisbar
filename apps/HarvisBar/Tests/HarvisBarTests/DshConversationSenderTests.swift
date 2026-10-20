import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class DshConversationSenderTests: XCTestCase {
    let endpoint = DshRuntimeEndpoint(homeID: "test-home", profile: "web", port: 3080)

    func testLeanCatalogRejectsUnsafeEndpointsAndPreservesSameScopePorts() throws {
        let data = Data(#"{"ok":true,"includesSecrets":false,"endpoints":[{"homeID":"a","profile":"web","port":3080},{"homeID":"a","profile":"web","port":3080},{"homeID":"a","profile":"web","port":3081}]}"#.utf8)
        let catalog = try JSONDecoder().decode(DshRunningEndpointCatalog.self, from: data)
        XCTAssertEqual(try catalog.validatedEndpoints().map(\.port), [3080, 3081])
        for invalid in [
            #"{"ok":true,"includesSecrets":true,"endpoints":[]}"#,
            #"{"ok":false,"includesSecrets":false,"endpoints":[]}"#,
            #"{"ok":true,"includesSecrets":false,"endpoints":[{"homeID":"a","profile":"web","port":0}]}"#,
            #"{"ok":true,"includesSecrets":false,"endpoints":[{"homeID":" ","profile":"web","port":3080}]}"#
        ] {
            let value = try JSONDecoder().decode(DshRunningEndpointCatalog.self, from: Data(invalid.utf8))
            XCTAssertThrowsError(try value.validatedEndpoints())
        }
    }

    func testRejectsAmbiguousOfflineArchivedAndChildTargets() async throws {
        let thread = try await fixture()
        XCTAssertEqual(DshConversationSender.endpoint(for: thread, endpoints: [endpoint]), endpoint)
        XCTAssertNil(DshConversationSender.endpoint(for: thread, endpoints: []))
        XCTAssertNil(DshConversationSender.endpoint(for: thread, endpoints: [endpoint,
            .init(homeID: endpoint.homeID, profile: endpoint.profile, port: 3081)]))
        let archived = try await fixture(archived: true)
        XCTAssertNil(DshConversationSender.endpoint(for: archived, endpoints: [endpoint]))
        let child = try await fixture(child: true)
        XCTAssertNil(DshConversationSender.endpoint(for: child, endpoints: [endpoint]))
    }

    func testTimeoutPreservesExactRequestAndPreventsDuplicatePost() async throws {
        let transport = SenderTransport(timeout: true)
        let thread = try await fixture()
        let sender = DshConversationSender { DshHostApiClient(endpoint: $0, transport: transport) }
        let submitted = await sender.send("hello", thread: thread, endpoint: endpoint, isCurrent: { true })
        XCTAssertTrue(submitted, "An uncertain delivery must preserve its request and must not be resent")
        XCTAssertNotNil(sender.states[thread.id]?.pendingRPCID)
        let duplicate = await sender.send("hello again", thread: thread, endpoint: endpoint, isCurrent: { true })
        XCTAssertFalse(duplicate, "A blocked send must not consume a new draft")
        let posts = await transport.posts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.sessionID, thread.sourceID)
        XCTAssertEqual(posts.first?.port, endpoint.port)
    }

    func testOnlyExactCompletedTurnUnlocksNextSend() async throws {
        let transport = SenderTransport()
        let thread = try await fixture()
        let sender = DshConversationSender { DshHostApiClient(endpoint: $0, transport: transport) }
        await sender.send("hello", thread: thread, endpoint: endpoint, isCurrent: { true })
        XCTAssertNotNil(sender.states[thread.id]?.pendingRPCID)
        await transport.complete(useExactID: false)
        await sender.refresh(thread: thread, endpoint: endpoint)
        XCTAssertNotNil(sender.states[thread.id]?.pendingRPCID)
        await transport.complete(useExactID: true)
        await sender.refresh(thread: thread, endpoint: endpoint)
        XCTAssertNil(sender.states[thread.id]?.pendingRPCID)
        XCTAssertTrue(sender.states[thread.id]?.status.contains("已完成") == true)
        XCTAssertEqual(sender.states[thread.id]?.messages.last?.text, "marker")
        XCTAssertEqual(sender.states[thread.id]?.messages.count, 2)
    }

    func testAccountChangeDuringPreflightNeverPosts() async throws {
        let transport = SenderTransport()
        let thread = try await fixture()
        let sender = DshConversationSender { DshHostApiClient(endpoint: $0, transport: transport) }
        var checks = 0
        await sender.send("hello", thread: thread, endpoint: endpoint, isCurrent: {
            checks += 1
            return checks == 1
        })
        let posts = await transport.posts
        XCTAssertTrue(posts.isEmpty)
        XCTAssertNil(sender.states[thread.id]?.pendingRPCID)
    }

    func testSharedRefreshCompletesCardSendWithoutDetailAndStopsIdleReads() async throws {
        let transport = SenderTransport()
        let thread = try await fixture()
        let sender = DshConversationSender { DshHostApiClient(endpoint: $0, transport: transport) }
        await sender.refreshPending(threads: [thread], endpoints: [endpoint])
        let idleReads = await transport.historyReads
        XCTAssertEqual(idleReads, 0)
        await sender.send("hello", thread: thread, endpoint: endpoint, isCurrent: { true })
        let firstReads = await transport.historyReads
        let tick = Date().addingTimeInterval(4)
        await sender.refreshPending(threads: [thread, thread], endpoints: [endpoint], now: tick)
        await sender.refreshPending(threads: [thread], endpoints: [endpoint], now: tick.addingTimeInterval(1))
        let throttledReads = await transport.historyReads
        XCTAssertEqual(throttledReads, firstReads + 1)
        await transport.complete(useExactID: true)
        await sender.refreshPending(threads: [thread], endpoints: [endpoint], now: tick.addingTimeInterval(4))
        XCTAssertNil(sender.states[thread.id]?.pendingRPCID)
        XCTAssertEqual(sender.states[thread.id]?.lastReply, "marker")
        let completedReads = await transport.historyReads
        await sender.refreshPending(threads: [thread], endpoints: [endpoint], now: tick.addingTimeInterval(10))
        let finalReads = await transport.historyReads
        XCTAssertEqual(finalReads, completedReads)
    }

    func testSharedRefreshNeverFollowsPendingRequestToAnotherPort() async throws {
        let transport = SenderTransport()
        let thread = try await fixture()
        let sender = DshConversationSender { DshHostApiClient(endpoint: $0, transport: transport) }
        await sender.send("hello", thread: thread, endpoint: endpoint, isCurrent: { true })
        let before = await transport.historyReads
        await sender.refreshPending(threads: [thread], endpoints: [
            .init(homeID: endpoint.homeID, profile: endpoint.profile, port: 3081)
        ], now: Date().addingTimeInterval(5))
        let after = await transport.historyReads
        XCTAssertEqual(after, before)
        XCTAssertNotNil(sender.states[thread.id]?.pendingRPCID)
    }

    func testDraftSurvivesCardRemountAndIsIsolatedBySourceScope() async throws {
        let first = try await fixture()
        let secondEndpoint = DshRuntimeEndpoint(homeID: "another-home", profile: endpoint.profile, port: 3081)
        let discovery = try await DshHostApiClient(endpoint: secondEndpoint, transport: SenderTransport()).discover()
        let second = try XCTUnwrap(DshManagedChatAdapter.threads(from: discovery).first)
        XCTAssertEqual(first.sourceID, second.sourceID)
        let sender = DshConversationSender()
        let draft = sender.draft(for: first)
        draft.text = "尚未发送的草稿"
        XCTAssertTrue(sender.draft(for: first) === draft)
        XCTAssertEqual(sender.draft(for: first).text, "尚未发送的草稿")
        XCTAssertFalse(sender.draft(for: second) === draft)
        XCTAssertEqual(sender.draft(for: second).text, "")
    }

    func testExplicitRejectionAllowsCorrectionAndEmptyInputNeverPosts() async throws {
        let transport = SenderTransport(reject: true)
        let thread = try await fixture()
        let sender = DshConversationSender { DshHostApiClient(endpoint: $0, transport: transport) }
        let empty = await sender.send("  ", thread: thread, endpoint: endpoint, isCurrent: { true })
        let rejected = await sender.send("hello", thread: thread, endpoint: endpoint, isCurrent: { true })
        XCTAssertFalse(empty)
        XCTAssertFalse(rejected)
        XCTAssertNil(sender.states[thread.id]?.pendingRPCID)
        XCTAssertTrue(sender.states[thread.id]?.status.contains("拒绝") == true)
        let posts = await transport.posts
        XCTAssertEqual(posts.count, 1)
    }

    func testPreflightTimeoutKeepsDraftAndDoesNotPostOrStartPolling() async throws {
        let transport = SenderTransport(preflightTimeout: true)
        let thread = try await fixture()
        let sender = DshConversationSender { DshHostApiClient(endpoint: $0, transport: transport) }
        sender.draft(for: thread).text = "retry after connection recovers"
        let submitted = await sender.send(sender.draft(for: thread).text, thread: thread, endpoint: endpoint, isCurrent: { true })
        XCTAssertFalse(submitted)
        XCTAssertEqual(sender.draft(for: thread).text, "retry after connection recovers")
        XCTAssertTrue(sender.states[thread.id]?.status.contains("连接 DSH 超时") == true)
        await sender.refreshPending(threads: [thread], endpoints: [endpoint], now: Date().addingTimeInterval(10))
        let posts = await transport.posts
        let reads = await transport.historyReads
        XCTAssertTrue(posts.isEmpty)
        XCTAssertEqual(reads, 0)
    }

    private func fixture(archived: Bool = false, child: Bool = false) async throws -> ManagedChatThread {
        let transport = SenderTransport(archived: archived, child: child)
        let discovery = try await DshHostApiClient(endpoint: endpoint, transport: transport).discover()
        return try XCTUnwrap(DshManagedChatAdapter.threads(from: discovery).first)
    }
}

private actor SenderTransport: DshHostTransport {
    struct Post: Sendable { let rpcID: String; let sessionID: String; let port: Int? }
    var posts: [Post] = []
    var historyReads = 0
    let timeout: Bool
    let reject: Bool
    let archived: Bool
    let child: Bool
    let preflightTimeout: Bool
    var completedID: String?
    init(timeout: Bool = false, reject: Bool = false, archived: Bool = false, child: Bool = false, preflightTimeout: Bool = false) {
        self.timeout = timeout; self.reject = reject; self.archived = archived; self.child = child
        self.preflightTimeout = preflightTimeout
    }
    func complete(useExactID: Bool) { completedID = useExactID ? posts.last?.rpcID : "another-request" }
    func send(_ request: URLRequest) async throws -> DshHostTransportResponse {
        let envelope = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let method = envelope["method"] as! String
        let rpcID = envelope["rpcId"] as! String
        let payload = envelope["payload"] as! [String: Any]
        var value: [String: Any] = [:]
        switch method {
        case "host.describe":
            if preflightTimeout { throw URLError(.timedOut) }
            value = ["app": ["name": "DSH", "version": "test"]]
        case "workspace.list": value = ["items": [], "archivedSessionIds": archived ? ["session-test"] : []]
        case "session.list":
            var session: [String: Any] = ["sessionId": "session-test", "running": false, "blank": false, "updatedAt": 0, "cwd": "/tmp/dsh-test"]
            if child { session["parentSessionId"] = "parent"; session["origin"] = "subagent" }
            value = ["items": [session]]
        case "session.prompt":
            posts.append(.init(rpcID: rpcID, sessionID: payload["sessionId"] as! String, port: request.url?.port))
            if timeout { throw URLError(.timedOut) }
            if reject {
                return try response(rpcID, result: ["ok": false, "error": ["code": "agent-busy", "message": "Unavailable"]])
            }
            value = ["accepted": true]
        case "session.history":
            historyReads += 1
            var events: [[String: Any]] = []
            if let completedID {
                let raw: [(String, [String: Any])] = [
                    ("turn/start", ["turn": 1]),
                    ("user/message", ["source": ["rpcId": completedID], "content": [["type": "text", "text": "hello"]]]),
                    ("user/message", ["source": ["kind": "plugin"], "content": [["type": "text", "text": "internal context"]]]),
                    ("user/message", ["source": ["kind": "skill-catalog", "form": "catalog"], "content": [["type": "text", "text": "internal skills"]]]),
                    ("assistant/message", ["turn": 1, "message": ["content": [["type": "text", "text": "marker"]]]]),
                    ("turn/end", ["turn": 1, "reason": ["kind": "completed"]])]
                events = raw.enumerated().map { index, item in
                    ["event": ["type": item.0, "seq": index + 1, "time": 0, "data": item.1]]
                }
            }
            value = ["events": events, "hasMore": false]
        default: throw URLError(.unsupportedURL)
        }
        return try response(rpcID, result: ["ok": true, "value": value])
    }
    private func response(_ rpcID: String, result: [String: Any]) throws -> DshHostTransportResponse {
        .init(data: try JSONSerialization.data(withJSONObject: ["type": "server-response", "rpcId": rpcID, "result": result]), statusCode: 200)
    }
}
