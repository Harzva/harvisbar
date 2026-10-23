import Foundation
import XCTest
@testable import HarvisBar

final class CodexAppServerConnectionTests: XCTestCase {
    func testLargeNativeHistoryResponsePreservesChunkAndUnicodeOrder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connection = CodexAppServerConnection(homePath: fixture.home.path,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [fixture.executable.path], requestTimeout: 5)
        let expected = (0..<12_000).map { "第\($0)条证据 αβγ\n" }.joined()
        _ = try await connection.request(method: "test/emitCompletion", params: .object([
            "threadId": .string("thread-a"), "message": .string(expected)]))
        for _ in 0..<3 {
            let response = try await connection.request(method: "thread/turns/list", params: .object([
                "threadId": .string("thread-a"), "itemsView": .string("full")]))
            let actual = response["data"]?.arrayValue?.first?["items"]?.arrayValue?.first?["text"]?.stringValue
            XCTAssertTrue(actual == expected, "Large native history bytes must remain ordered and complete")
        }
        await connection.stop()
    }

    func testInitializeHandshakeUsesInjectedClientVersion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connection = CodexAppServerConnection(
            homePath: fixture.home.path,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [fixture.executable.path],
            requestTimeout: 2,
            clientVersion: "9.8.7-contract-test"
        )

        _ = try await connection.connect()
        let rpcLog = fixture.root.appendingPathComponent("rpc-log.jsonl")
        let records = try String(contentsOf: rpcLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            .compactMap { $0 as? [String: Any] }
        let initialize = try XCTUnwrap(
            records.first { $0["method"] as? String == "initialize" }
        )
        let params = try XCTUnwrap(initialize["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["version"] as? String, "9.8.7-contract-test")
        await connection.stop()
    }

    func testBundleClientVersionHasNoStaleSemanticFallback() {
        let expected = (Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedVersion = expected.flatMap { $0.isEmpty ? nil : $0 }
            ?? "development"
        XCTAssertEqual(
            CodexAppServerConnection.bundleClientVersion(),
            expectedVersion
        )
    }

    func testConcurrentConnectCallsShareOneInitializeLifecycle() async throws {
        let fixture = try makeFixture(initializeDelaySeconds: 0.15)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connection = CodexAppServerConnection(
            homePath: fixture.home.path,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [fixture.executable.path],
            requestTimeout: 2
        )

        let connectionIDs = try await withThrowingTaskGroup(
            of: UUID.self,
            returning: [UUID].self
        ) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await connection.connect()
                }
            }
            var values: [UUID] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(Set(connectionIDs).count, 1)
        let launchLog = fixture.root.appendingPathComponent("launch-log.txt")
        let launches = try String(contentsOf: launchLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(launches.count, 1)
        let requestLog = fixture.root.appendingPathComponent("request-log.txt")
        let initializeCount = try String(contentsOf: requestLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .filter { $0 == "initialize" }
            .count
        XCTAssertEqual(initializeCount, 1)
        await connection.stop()
    }

    func testHandshakeInterleavesNotificationsAndRoutesTurnRequests() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connection = CodexAppServerConnection(
            homePath: fixture.home.path,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [fixture.executable.path],
            requestTimeout: 2
        )
        let stream = await connection.events()
        let connectionID = try await connection.connect()
        var iterator = stream.makeAsyncIterator()
        var sawConnected = false
        var sawStatusNotification = false
        for _ in 0..<2 {
            guard let event = await iterator.next() else { break }
            switch event {
            case let .connected(id):
                sawConnected = id == connectionID
            case let .notification(method, _, id):
                sawStatusNotification =
                    method == "thread/status/changed" && id == connectionID
            default:
                break
            }
        }
        XCTAssertTrue(sawConnected)
        XCTAssertTrue(sawStatusNotification)

        _ = try await connection.request(
            method: "thread/resume",
            params: .object(["threadId": .string("thread-a")])
        )
        let start = try await connection.request(
            method: "turn/start",
            params: .object([
                "threadId": .string("thread-a"),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("hello"),
                    ]),
                ]),
            ])
        )
        XCTAssertEqual(start["turn"]?["id"]?.stringValue, "turn-manager")

        let steer = try await connection.request(
            method: "turn/steer",
            params: .object([
                "threadId": .string("thread-a"),
                "expectedTurnId": .string("turn-manager"),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("more"),
                    ]),
                ]),
            ])
        )
        XCTAssertEqual(steer["turnId"]?.stringValue, "turn-manager")
        await connection.stop()
    }

    func testServerRequestIsSurfacedAndNeverAutoApproved() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connection = CodexAppServerConnection(
            homePath: fixture.home.path,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [fixture.executable.path],
            requestTimeout: 2
        )
        let stream = await connection.events()
        let connectionID = try await connection.connect()
        _ = try await connection.request(
            method: "test/emitApproval",
            params: .object([:])
        )

        var iterator = stream.makeAsyncIterator()
        var request: CodexServerRequest?
        for _ in 0..<5 {
            guard let event = await iterator.next() else { break }
            if case let .serverRequest(candidate, id) = event,
               id == connectionID {
                request = candidate
                break
            }
        }
        XCTAssertEqual(
            request?.method,
            "item/commandExecution/requestApproval"
        )
        XCTAssertEqual(request?.id, .string("approval-1"))
        if let request {
            try await connection.respond(
                to: request.id,
                result: .object(["decision": .string("decline")]),
                expectedConnectionID: connectionID
            )
        }
        await connection.stop()
    }

    func testDisconnectAfterWriteReturnsDeliveryUnknown() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connection = CodexAppServerConnection(
            homePath: fixture.home.path,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [fixture.executable.path],
            requestTimeout: 1
        )
        _ = try await connection.connect()

        do {
            _ = try await connection.request(
                method: "test/disconnect",
                params: .object([:])
            )
            XCTFail("Expected disconnect")
        } catch let error as CodexAppServerError {
            guard case .deliveryUncertain(method: "test/disconnect", _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testReconnectCreatesANewOwnershipLifecycle() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let connection = CodexAppServerConnection(
            homePath: fixture.home.path,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [fixture.executable.path],
            requestTimeout: 1
        )
        let firstConnectionID = try await connection.connect()

        do {
            _ = try await connection.request(
                method: "test/disconnect",
                params: .object([:])
            )
            XCTFail("Expected disconnect")
        } catch let error as CodexAppServerError {
            guard case .deliveryUncertain = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let secondConnectionID = try await connection.connect()
        XCTAssertNotEqual(firstConnectionID, secondConnectionID)
        let activeConnectionID = await connection.connectionID()
        XCTAssertEqual(activeConnectionID, secondConnectionID)
        await connection.stop()
    }

    private func makeFixture(
        initializeDelaySeconds: Double = 0
    ) throws -> (
        root: URL,
        home: URL,
        executable: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexAppServerConnectionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        let executable = try CodexAppServerTestSupport.makeFakeExecutable(
            in: root,
            initializeDelaySeconds: initializeDelaySeconds
        )
        return (root, home, executable)
    }
}
