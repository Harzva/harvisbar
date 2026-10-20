import Darwin
import Foundation
import XCTest
@testable import HarvisBar

final class HarvisTaskProgressTransportTests: XCTestCase {
    func testRequestUsesExactReadOnlyLoopbackContractAndEncoding() throws {
        let client = HarvisTaskProgressClient(
            transport: HarvisTaskProgressRecordingTransport(body: Self.activeEnvelope),
            tokenProvider: { path in
                XCTAssertEqual(path, "/fixture/http.token")
                return String(repeating: "a", count: 64)
            }
        )

        let request = try client.makeURLRequest(
            HarvisTaskProgressLoadRequest(
                port: 8_765,
                workspaceRoot: "/Volumes/Test Disk/研发&a",
                tokenFilePath: "/fixture/http.token"
            )
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "http")
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.url?.port, 8_765)
        XCTAssertEqual(request.url?.path, "/task-progress")
        XCTAssertEqual(
            request.url?.query,
            "root=%2FVolumes%2FTest%20Disk%2F%E7%A0%94%E5%8F%91%26a"
                + "&limit=20&include_inactive=true&include_local=false"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(String(repeating: "a", count: 64))"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.httpBody)
    }

    func testDedicatedSessionDisablesProxyCookieCacheAndCredentialSources() {
        let configuration = HarvisTaskProgressURLSessionTransport.makeEphemeralConfiguration()
        let proxy = configuration.connectionProxyDictionary ?? [:]

        for key in [
            "HTTPEnable", "HTTPSEnable", "SOCKSEnable",
            "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable",
        ] {
            XCTAssertEqual(proxy[key] as? Int, 0, "proxy key \(key) must be disabled")
        }
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 2)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
        XCTAssertEqual(HarvisTaskProgressURLSessionTransport.responseByteLimit, 1_048_576)
    }

    func testTokenAuthorityAcceptsCurrentAndLegacyFormatsOnly() throws {
        let current = Array(String(repeating: "A", count: 41).utf8) + [0x2D, 0x5F, 0x0A]
        XCTAssertEqual(
            try HarvisTaskProgressTokenAuthority.validate(current),
            String(repeating: "A", count: 41) + "-_"
        )
        XCTAssertEqual(
            try HarvisTaskProgressTokenAuthority.validate(
                Array(String(repeating: "a", count: 64).utf8)
            ),
            String(repeating: "a", count: 64)
        )

        for rejected in [
            Array(String(repeating: "A", count: 42).utf8),
            Array((String(repeating: "A", count: 43) + "\r\n").utf8),
            Array(String(repeating: "F", count: 64).utf8),
            Array((String(repeating: "a", count: 64) + "\n\n").utf8),
        ] {
            XCTAssertThrowsError(try HarvisTaskProgressTokenAuthority.validate(rejected)) {
                XCTAssertEqual($0 as? HarvisTaskProgressClientError, .invalidToken)
            }
        }
    }

    func testStrictEnvelopeDecodesSafeSnapshot() async throws {
        let transport = HarvisTaskProgressRecordingTransport(body: Self.activeEnvelope)
        let client = HarvisTaskProgressClient(
            transport: transport,
            tokenProvider: { _ in String(repeating: "a", count: 64) }
        )

        let snapshot = try await client.load(Self.loadRequest)

        XCTAssertEqual(snapshot.status, "active")
        XCTAssertEqual(snapshot.current?.taskId, "candidate-build")
        XCTAssertEqual(snapshot.current?.progress?.percent, 75)
        let request = await transport.lastRequest()
        XCTAssertEqual(request?.url?.host, "127.0.0.1")
        XCTAssertEqual(request?.url?.path, "/task-progress")
    }

    func testHTTP400AndFinalURLMismatchFailClosedWithoutRetainingBody() async {
        let rejectedTransport = HarvisTaskProgressRecordingTransport(
            body: Data(#"{"secret":"/Users/private/token"}"#.utf8),
            statusCode: 400
        )
        let rejected = HarvisTaskProgressClient(
            transport: rejectedTransport,
            tokenProvider: { _ in String(repeating: "a", count: 64) }
        )

        do {
            _ = try await rejected.load(Self.loadRequest)
            XCTFail("HTTP 400 must fail")
        } catch {
            XCTAssertEqual(error as? HarvisTaskProgressClientError, .httpStatus(400))
            XCTAssertFalse(String(reflecting: error).contains("/Users/private"))
        }

        let redirectedTransport = HarvisTaskProgressRecordingTransport(
            body: Self.activeEnvelope,
            finalURL: URL(string: "https://example.invalid/task-progress")
        )
        let redirected = HarvisTaskProgressClient(
            transport: redirectedTransport,
            tokenProvider: { _ in String(repeating: "a", count: 64) }
        )
        do {
            _ = try await redirected.load(Self.loadRequest)
            XCTFail("a different response URL must fail")
        } catch {
            XCTAssertEqual(error as? HarvisTaskProgressClientError, .responseURLMismatch)
        }
    }

    func testMalformedOrSkippedSnapshotDoesNotBecomeSuccess() async {
        let extraEnvelopeKey = Self.activeEnvelopeString
            .replacingOccurrences(of: #"{"ok":true"#, with: #"{"extra":1,"ok":true"#)
        let malformed = HarvisTaskProgressClient(
            transport: HarvisTaskProgressRecordingTransport(body: Data(extraEnvelopeKey.utf8)),
            tokenProvider: { _ in String(repeating: "a", count: 64) }
        )
        do {
            _ = try await malformed.load(Self.loadRequest)
            XCTFail("unknown envelope fields must fail closed")
        } catch {
            XCTAssertEqual(error as? HarvisTaskProgressClientError, .invalidEnvelope)
        }

        let skippedBody = Data(
            Self.activeEnvelopeString.replacingOccurrences(
                of: #""status":"active""#,
                with: #""status":"skipped""#
            ).utf8
        )
        let skipped = HarvisTaskProgressClient(
            transport: HarvisTaskProgressRecordingTransport(body: skippedBody),
            tokenProvider: { _ in String(repeating: "a", count: 64) }
        )
        do {
            _ = try await skipped.load(Self.loadRequest)
            XCTFail("skipped is a local degradation, not a replacement snapshot")
        } catch {
            XCTAssertEqual(error as? HarvisTaskProgressClientError, .unavailableSnapshot)
        }

        for invalidCount in ["true", "9223372036854775808", "1.5"] {
            let invalidBody = Data(
                Self.activeEnvelopeString.replacingOccurrences(
                    of: #""activeCount":1"#,
                    with: #""activeCount":\#(invalidCount)"#
                ).utf8
            )
            let invalid = HarvisTaskProgressClient(
                transport: HarvisTaskProgressRecordingTransport(body: invalidBody),
                tokenProvider: { _ in String(repeating: "a", count: 64) }
            )
            do {
                _ = try await invalid.load(Self.loadRequest)
                XCTFail("invalid activeCount \(invalidCount) must fail")
            } catch {
                XCTAssertEqual(error as? HarvisTaskProgressClientError, .invalidEnvelope)
            }
        }
    }

    func testStreamingTransportAcceptsExactCapAndRejectsFirstExtraByte() async throws {
        let cap = HarvisTaskProgressURLSessionTransport.responseByteLimit
        let exactServer = try HarvisTaskProgressLocalHTTPServer { descriptor in
            Self.writeHTTPResponse(descriptor: descriptor, status: 200, bodyCount: cap)
        }
        defer { exactServer.stop() }
        let exactRequest = URLRequest(
            url: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(exactServer.port)/task-progress?root=%2Ffixture")
            )
        )
        let exact = try await HarvisTaskProgressURLSessionTransport(
            totalTimeout: 3
        ).send(exactRequest)
        XCTAssertEqual(exact.data.count, cap)
        XCTAssertEqual(exact.statusCode, 200)
        XCTAssertTrue(exactServer.waitForCompletion())

        let overflowServer = try HarvisTaskProgressLocalHTTPServer { descriptor in
            Self.writeHTTPResponse(descriptor: descriptor, status: 200, bodyCount: cap + 1)
        }
        defer { overflowServer.stop() }
        let overflowRequest = URLRequest(
            url: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(overflowServer.port)/task-progress?root=%2Ffixture")
            )
        )
        do {
            _ = try await HarvisTaskProgressURLSessionTransport(
                totalTimeout: 3
            ).send(overflowRequest)
            XCTFail("1 MiB + 1 byte must be rejected while streaming")
        } catch {
            XCTAssertEqual(error as? HarvisTaskProgressClientError, .responseTooLarge)
        }
        XCTAssertTrue(overflowServer.waitForCompletion())
        XCTAssertEqual(overflowServer.acceptedConnectionCount, 1)
    }

    func testStreamingTransportReturns302WithoutFollowingExternalLocation() async throws {
        let server = try HarvisTaskProgressLocalHTTPServer { descriptor in
            let response = Data(
                "HTTP/1.1 302 Found\r\n"
                    .appending("Location: https://example.invalid/task-progress\r\n")
                    .appending("Content-Length: 0\r\nConnection: close\r\n\r\n")
                    .utf8
            )
            Self.writeAll(descriptor: descriptor, data: response)
        }
        defer { server.stop() }
        let request = URLRequest(
            url: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(server.port)/task-progress?root=%2Ffixture")
            )
        )

        let response = try await HarvisTaskProgressURLSessionTransport(
            totalTimeout: 3
        ).send(request)

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.finalURL, request.url)
        XCTAssertEqual(server.acceptedConnectionCount, 1)
        XCTAssertTrue(server.waitForCompletion())
    }

    func testStreamingTransportUsesTotalDeadlineAndRejectsHostnameAlias() async throws {
        let server = try HarvisTaskProgressLocalHTTPServer { descriptor in
            let header = Data(
                "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n".utf8
            )
            Self.writeAll(descriptor: descriptor, data: header)
            usleep(200_000)
            Self.writeAll(descriptor: descriptor, data: Data([0x78]))
        }
        defer { server.stop() }
        let request = URLRequest(
            url: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(server.port)/task-progress?root=%2Ffixture")
            )
        )

        do {
            _ = try await HarvisTaskProgressURLSessionTransport(
                totalTimeout: 0.05
            ).send(request)
            XCTFail("the monotonic total budget must cancel a slow body")
        } catch {
            XCTAssertEqual(error as? HarvisTaskProgressClientError, .timeout)
        }
        XCTAssertTrue(server.waitForCompletion())
        XCTAssertEqual(server.acceptedConnectionCount, 1)

        let hostnameAlias = URLRequest(
            url: try XCTUnwrap(
                URL(string: "http://localhost:\(server.port)/task-progress?root=%2Ffixture")
            )
        )
        do {
            _ = try await HarvisTaskProgressURLSessionTransport().send(hostnameAlias)
            XCTFail("only numeric loopback is allowed")
        } catch {
            XCTAssertEqual(error as? HarvisTaskProgressClientError, .invalidEndpoint)
        }
        XCTAssertEqual(server.acceptedConnectionCount, 1)
    }

    private static func writeHTTPResponse(
        descriptor: Int32,
        status: Int,
        bodyCount: Int
    ) {
        let header = Data(
            "HTTP/1.1 \(status) OK\r\n"
                .appending("Content-Length: \(bodyCount)\r\n")
                .appending("Content-Type: application/json\r\n")
                .appending("Connection: close\r\n\r\n")
                .utf8
        )
        writeAll(descriptor: descriptor, data: header)
        let chunk = Data(repeating: 0x78, count: 16_384)
        var remaining = bodyCount
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            writeAll(descriptor: descriptor, data: chunk.prefix(count))
            remaining -= count
        }
    }

    private static func writeAll(descriptor: Int32, data: Data) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private static let loadRequest = HarvisTaskProgressLoadRequest(
        port: 8_765,
        workspaceRoot: "/fixture/workspace",
        tokenFilePath: "/fixture/http.token"
    )

    private static let activeEnvelope = Data(activeEnvelopeString.utf8)

    private static let activeEnvelopeString = #"{"ok":true,"endpoint":"/task-progress","data":{"schemaVersion":"harvis.task-progress.v0","safeForHarvisBar":true,"generatedAt":"2026-08-30T00:00:00Z","status":"active","summary":"1 active task","activeCount":1,"items":[{"taskId":"candidate-build","title":"Build candidate","kind":"build","status":"active","summary":"Compiling","detail":"Release","progress":{"percent":75.0,"current":3,"total":4,"unit":"steps"},"metrics":{"elapsed":"3m","eta":"1m","speed":"1 step/m","itemsPerSecond":0.016},"startedAt":"2026-08-30T00:00:00Z","updatedAt":"2026-08-30T00:03:00Z","safeForHarvisBar":true}],"current":{"taskId":"candidate-build","title":"Build candidate","kind":"build","status":"active","summary":"Compiling","detail":"Release","progress":{"percent":75.0,"current":3,"total":4,"unit":"steps"},"metrics":{"elapsed":"3m","eta":"1m","speed":"1 step/m","itemsPerSecond":0.016},"startedAt":"2026-08-30T00:00:00Z","updatedAt":"2026-08-30T00:03:00Z","safeForHarvisBar":true},"safety":{"redacted":true,"includesSecrets":false,"includesLocalAbsolutePaths":false}},"warnings":[],"error":null}"#
}

private final class HarvisTaskProgressLocalHTTPServer: @unchecked Sendable {
    let port: Int

    private let descriptor: Int32
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private var connectionCount = 0

    var acceptedConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectionCount
    }

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        self.descriptor = descriptor

        var reuse: Int32 = 1
        _ = Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.serve(handler: handler)
        }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let shouldClose = !stopped
        stopped = true
        lock.unlock()
        if shouldClose {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
    }

    func waitForCompletion() -> Bool {
        completion.wait(timeout: .now() + 2) == .success
    }

    private func serve(handler: @escaping @Sendable (Int32) -> Void) {
        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let client = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(descriptor, $0, &peerLength)
            }
        }
        guard client >= 0 else {
            completion.signal()
            return
        }
        lock.lock()
        connectionCount += 1
        lock.unlock()
        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while request.count < 65_536 {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            request.append(contentsOf: buffer.prefix(count))
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        handler(client)
        _ = Darwin.shutdown(client, SHUT_RDWR)
        _ = Darwin.close(client)
        completion.signal()
    }
}

private actor HarvisTaskProgressRecordingTransport: HarvisTaskProgressTransport {
    private let body: Data
    private let statusCode: Int
    private let finalURL: URL?
    private var request: URLRequest?

    init(body: Data, statusCode: Int = 200, finalURL: URL? = nil) {
        self.body = body
        self.statusCode = statusCode
        self.finalURL = finalURL
    }

    func send(_ request: URLRequest) async throws -> HarvisTaskProgressTransportResponse {
        self.request = request
        return HarvisTaskProgressTransportResponse(
            data: body,
            statusCode: statusCode,
            finalURL: finalURL ?? request.url
        )
    }

    func lastRequest() -> URLRequest? { request }
}
