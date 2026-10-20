import Darwin
import Foundation

struct HarvisTaskProgressLoadRequest: Equatable, Sendable {
    static let endpointPath = "/task-progress"
    static let defaultLimit = 20

    let port: Int
    let workspaceRoot: String
    let tokenFilePath: String
    let limit: Int
    let includeInactive: Bool

    init(
        port: Int,
        workspaceRoot: String,
        tokenFilePath: String,
        limit: Int = Self.defaultLimit,
        includeInactive: Bool = true
    ) {
        self.port = port
        self.workspaceRoot = workspaceRoot
        self.tokenFilePath = tokenFilePath
        self.limit = limit
        self.includeInactive = includeInactive
    }
}

protocol HarvisTaskProgressLoading: Sendable {
    func load(_ request: HarvisTaskProgressLoadRequest) async throws -> TaskProgressStatus
}

enum HarvisTaskProgressPublishEvent: Equatable, Sendable {
    case success
    case failure(HarvisTaskProgressFailure)
    case cancelled
}

struct HarvisTaskProgressTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL?
}

protocol HarvisTaskProgressTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HarvisTaskProgressTransportResponse
}

enum HarvisTaskProgressClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case tokenUnavailable
    case invalidToken
    case invalidHTTPResponse
    case responseURLMismatch
    case responseTooLarge
    case httpStatus(Int)
    case invalidEnvelope
    case unavailableSnapshot
    case timeout
}

/// A dedicated local-only transport for the optional task lane.
///
/// It follows the existing DSH client no-redirect pattern, but intentionally
/// does not share URLSession.shared: task progress has a smaller response cap
/// and must ignore every system/environment proxy source.
final class HarvisTaskProgressURLSessionTransport: HarvisTaskProgressTransport,
    @unchecked Sendable
{
    static let responseByteLimit = 1_048_576
    static let requestTimeout: TimeInterval = 2
    static let resourceTimeout: TimeInterval = 10

    private let session: URLSession
    private let responseByteLimit: Int
    private let totalTimeoutNanoseconds: UInt64

    init(
        configuration: URLSessionConfiguration = HarvisTaskProgressURLSessionTransport
            .makeEphemeralConfiguration(),
        responseByteLimit: Int = HarvisTaskProgressURLSessionTransport.responseByteLimit,
        totalTimeout: TimeInterval = HarvisTaskProgressURLSessionTransport.resourceTimeout
    ) {
        self.session = URLSession(configuration: configuration)
        self.responseByteLimit = max(1, responseByteLimit)
        self.totalTimeoutNanoseconds = UInt64(max(totalTimeout, 0.001) * 1_000_000_000)
    }

    static func makeEphemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0,
            "ProxyAutoDiscoveryEnable": 0,
        ]
        return configuration
    }

    func send(_ request: URLRequest) async throws -> HarvisTaskProgressTransportResponse {
        guard Self.isExactNumericLoopback(request.url) else {
            throw HarvisTaskProgressClientError.invalidEndpoint
        }

        return try await withThrowingTaskGroup(
            of: HarvisTaskProgressTransportResponse.self
        ) { group in
            group.addTask { [session, responseByteLimit] in
                let (bytes, response) = try await session.bytes(
                    for: request,
                    delegate: HarvisTaskProgressNoRedirectDelegate()
                )
                guard let response = response as? HTTPURLResponse else {
                    throw HarvisTaskProgressClientError.invalidHTTPResponse
                }
                var data = Data()
                data.reserveCapacity(min(responseByteLimit, 16_384))
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < responseByteLimit else {
                        throw HarvisTaskProgressClientError.responseTooLarge
                    }
                    data.append(byte)
                }
                return HarvisTaskProgressTransportResponse(
                    data: data,
                    statusCode: response.statusCode,
                    finalURL: response.url
                )
            }
            group.addTask { [totalTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: totalTimeoutNanoseconds)
                throw HarvisTaskProgressClientError.timeout
            }

            guard let first = try await group.next() else {
                throw HarvisTaskProgressClientError.invalidHTTPResponse
            }
            group.cancelAll()
            return first
        }
    }

    private static func isExactNumericLoopback(_ url: URL?) -> Bool {
        guard let url,
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port != nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            return false
        }
        return true
    }
}

private final class HarvisTaskProgressNoRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
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

struct HarvisTaskProgressClient: HarvisTaskProgressLoading, Sendable {
    typealias TokenProvider = @Sendable (String) throws -> String

    private let transport: any HarvisTaskProgressTransport
    private let tokenProvider: TokenProvider

    init(
        transport: any HarvisTaskProgressTransport = HarvisTaskProgressURLSessionTransport(),
        tokenProvider: @escaping TokenProvider = HarvisTaskProgressTokenAuthority.read
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    func load(_ request: HarvisTaskProgressLoadRequest) async throws -> TaskProgressStatus {
        let urlRequest = try makeURLRequest(request)
        let response = try await transport.send(urlRequest)
        guard response.finalURL == urlRequest.url else {
            throw HarvisTaskProgressClientError.responseURLMismatch
        }
        guard response.statusCode == 200 else {
            throw HarvisTaskProgressClientError.httpStatus(response.statusCode)
        }
        let snapshot = try Self.decodeStrictSnapshot(
            response.data,
            maximumItems: request.limit
        )
        guard snapshot.status != "skipped" else {
            throw HarvisTaskProgressClientError.unavailableSnapshot
        }
        return snapshot
    }

    func makeURLRequest(_ request: HarvisTaskProgressLoadRequest) throws -> URLRequest {
        guard (1...65_535).contains(request.port),
              (1...200).contains(request.limit),
              request.workspaceRoot.hasPrefix("/"),
              !request.workspaceRoot.contains("\0") else {
            throw HarvisTaskProgressClientError.invalidEndpoint
        }
        let query = [
            "root=\(Self.percentEncode(request.workspaceRoot))",
            "limit=\(request.limit)",
            "include_inactive=\(request.includeInactive ? "true" : "false")",
            "include_local=false",
        ].joined(separator: "&")
        guard let url = URL(
            string: "http://127.0.0.1:\(request.port)"
                + HarvisTaskProgressLoadRequest.endpointPath
                + "?\(query)"
        ) else {
            throw HarvisTaskProgressClientError.invalidEndpoint
        }

        let token = try tokenProvider(request.tokenFilePath)
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: HarvisTaskProgressURLSessionTransport.requestTimeout
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    private static func percentEncode(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                output.unicodeScalars.append(UnicodeScalar(byte))
            default:
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    private static func decodeStrictSnapshot(
        _ data: Data,
        maximumItems: Int
    ) throws -> TaskProgressStatus {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(envelope.keys) == Set(["ok", "endpoint", "data", "warnings", "error"]),
              envelope["ok"] as? Bool == true,
              envelope["endpoint"] as? String == HarvisTaskProgressLoadRequest.endpointPath,
              envelope["error"] is NSNull,
              let warnings = envelope["warnings"] as? [Any],
              warnings.allSatisfy({ $0 is String }),
              let payload = envelope["data"] as? [String: Any] else {
            throw HarvisTaskProgressClientError.invalidEnvelope
        }
        try validatePayload(payload, maximumItems: maximumItems)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        do {
            return try JSONDecoder().decode(TaskProgressStatus.self, from: payloadData)
        } catch {
            throw HarvisTaskProgressClientError.invalidEnvelope
        }
    }

    private static func validatePayload(
        _ payload: [String: Any],
        maximumItems: Int
    ) throws {
        let required = Set([
            "schemaVersion", "safeForHarvisBar", "generatedAt", "status",
            "summary", "activeCount", "items", "current", "safety",
        ])
        guard required.isSubset(of: Set(payload.keys)),
              payload["schemaVersion"] as? String == "harvis.task-progress.v0",
              payload["safeForHarvisBar"] as? Bool == true,
              let generatedAt = payload["generatedAt"] as? String,
              generatedAt.count <= 64,
              Self.isISO8601(generatedAt),
              let status = payload["status"] as? String,
              ["active", "idle", "skipped"].contains(status),
              payload["summary"] is String,
              let activeCount = Self.strictInteger(payload["activeCount"]),
              activeCount >= 0,
              let items = payload["items"] as? [Any],
              items.count <= maximumItems,
              let safety = payload["safety"] as? [String: Any],
              safety["redacted"] as? Bool == true,
              safety["includesSecrets"] as? Bool == false,
              safety["includesLocalAbsolutePaths"] as? Bool == false else {
            throw HarvisTaskProgressClientError.invalidEnvelope
        }
        try items.forEach { try validateItem($0) }
        if !(payload["current"] is NSNull) {
            try validateItem(payload["current"] as Any)
        }
    }

    private static func validateItem(_ raw: Any) throws {
        guard let item = raw as? [String: Any],
              let taskID = item["taskId"] as? String,
              taskID.count <= 120,
              let title = item["title"] as? String,
              title.count <= 80,
              let kind = item["kind"] as? String,
              kind.count <= 40,
              let status = item["status"] as? String,
              status.count <= 32,
              let summary = item["summary"] as? String,
              summary.count <= 180,
              let detail = item["detail"] as? String,
              detail.count <= 180,
              item["progress"] is [String: Any],
              item["metrics"] is [String: Any],
              Self.isStringOrNull(item["startedAt"]),
              Self.isStringOrNull(item["updatedAt"]),
              item["safeForHarvisBar"] as? Bool == true else {
            throw HarvisTaskProgressClientError.invalidEnvelope
        }
    }

    private static func strictInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        // Parsing the canonical NSNumber spelling avoids a Double boundary
        // rounding trap at Int.max + 1 while still accepting the integer form
        // emitted by the local Rust API.
        return Int(number.stringValue)
    }

    private static func isStringOrNull(_ raw: Any?) -> Bool {
        raw is String || raw is NSNull
    }

    private static func isISO8601(_ raw: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: raw) != nil { return true }
        return ISO8601DateFormatter().date(from: raw) != nil
    }
}

enum HarvisTaskProgressTokenAuthority {
    static func read(_ path: String) throws -> String {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw HarvisTaskProgressClientError.tokenUnavailable
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= 65 else {
            throw HarvisTaskProgressClientError.invalidToken
        }

        var bytes = [UInt8](repeating: 0, count: 66)
        var count = 0
        while count < bytes.count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: count),
                    buffer.count - count
                )
            }
            if result == 0 { break }
            if result < 0 {
                if errno == EINTR { continue }
                throw HarvisTaskProgressClientError.tokenUnavailable
            }
            count += result
        }
        guard count <= 65 else {
            throw HarvisTaskProgressClientError.invalidToken
        }
        return try validate(Array(bytes.prefix(count)))
    }

    static func validate(_ bytes: [UInt8]) throws -> String {
        var tokenBytes = bytes
        if tokenBytes.last == 0x0A {
            tokenBytes.removeLast()
        }
        let isURLSafe43 = tokenBytes.count == 43 && tokenBytes.allSatisfy {
            (0x41...0x5A).contains($0)
                || (0x61...0x7A).contains($0)
                || (0x30...0x39).contains($0)
                || $0 == 0x2D
                || $0 == 0x5F
        }
        let isLowerHex64 = tokenBytes.count == 64 && tokenBytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
        guard isURLSafe43 || isLowerHex64,
              let token = String(bytes: tokenBytes, encoding: .ascii) else {
            throw HarvisTaskProgressClientError.invalidToken
        }
        return token
    }
}

extension HarvisTaskProgressFailure {
    static func classify(_ error: Error) -> Self? {
        if error is CancellationError { return nil }
        if let error = error as? HarvisTaskProgressClientError {
            switch error {
            case .httpStatus(let status):
                return status == 403 ? .permissionDenied : .httpRejected
            case .unavailableSnapshot:
                return .ioFailure
            case .timeout:
                return .timeout
            case .tokenUnavailable:
                return .offline
            case .invalidEndpoint, .invalidToken, .invalidHTTPResponse,
                 .responseURLMismatch, .responseTooLarge, .invalidEnvelope:
                return .invalidResponse
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut:
                return .timeout
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet:
                return .offline
            default:
                return .ioFailure
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
                return .permissionDenied
            }
            return .ioFailure
        }
        return .ioFailure
    }
}
