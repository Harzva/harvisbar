import Combine
import Foundation

struct DigitalMeNavigationTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol DigitalMeNavigationTransport: Sendable {
    func send(_ request: URLRequest) async throws -> DigitalMeNavigationTransportResponse
}

struct DigitalMeNavigationURLSessionTransport: DigitalMeNavigationTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> DigitalMeNavigationTransportResponse {
        guard request.url?.host == "127.0.0.1" else {
            throw DigitalMeNavigationAPIError.invalidEndpoint
        }
        let (data, response) = try await session.data(
            for: request,
            delegate: DigitalMeNavigationNoRedirectDelegate()
        )
        guard let response = response as? HTTPURLResponse else {
            throw DigitalMeNavigationAPIError.invalidResponse
        }
        return DigitalMeNavigationTransportResponse(
            data: data,
            statusCode: response.statusCode
        )
    }
}

private final class DigitalMeNavigationNoRedirectDelegate: NSObject,
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

enum DigitalMeNavigationAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case invalidEnvelope
    case remoteFailure

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The local Digital-Me API endpoint is invalid."
        case .invalidResponse:
            return "The local Digital-Me API returned an invalid response."
        case .unauthorized:
            return "The local Digital-Me API rejected the bearer token."
        case let .httpStatus(status):
            return "The local Digital-Me API returned HTTP \(status)."
        case .invalidEnvelope:
            return "The local Digital-Me API returned an invalid envelope."
        case .remoteFailure:
            return "The local Digital-Me API reported a request failure."
        }
    }
}

@MainActor
final class DigitalMeNavigationStore: ObservableObject {
    static let defaultTTL: TimeInterval = 15

    @Published private(set) var sources: DigitalMeNavigationRemoteSources = .notRequested

    private let transport: any DigitalMeNavigationTransport
    private let ttl: TimeInterval
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID: UUID?
    private var scope: DigitalMeNavigationScope?
    private var generation: UInt64 = 0

    init(
        transport: any DigitalMeNavigationTransport = DigitalMeNavigationURLSessionTransport(),
        ttl: TimeInterval = DigitalMeNavigationStore.defaultTTL
    ) {
        self.transport = transport
        self.ttl = max(ttl, 0)
    }

    /// Returns cached sources only when they belong to the caller's current
    /// runtime context. This synchronous gate lets SwiftUI hide old workspace
    /// data before its asynchronous refresh task begins.
    func sources(
        matchingPort port: Int,
        workspaceRoot: String,
        now: Date = Date()
    ) -> DigitalMeNavigationRemoteSources {
        let requestedScope = Self.normalizedScope(
            port: port,
            workspaceRoot: workspaceRoot
        )
        guard scope == requestedScope else { return .notRequested }
        return sources.hidingExpiredValues(at: now, ttl: ttl)
    }

    func refreshIfNeeded(
        sources requestedSources: Set<DigitalMeNavigationSource> = Set(
            DigitalMeNavigationSource.allCases
        ),
        port: Int,
        workspaceRoot: String,
        authToken: String?,
        now: Date = Date()
    ) async {
        await refresh(
            port: port,
            workspaceRoot: workspaceRoot,
            authToken: authToken,
            requestedSources: requestedSources,
            force: false,
            now: now
        )
    }

    func forceRefresh(
        sources requestedSources: Set<DigitalMeNavigationSource> = Set(
            DigitalMeNavigationSource.allCases
        ),
        port: Int,
        workspaceRoot: String,
        authToken: String?,
        now: Date = Date()
    ) async {
        await refresh(
            port: port,
            workspaceRoot: workspaceRoot,
            authToken: authToken,
            requestedSources: requestedSources,
            force: true,
            now: now
        )
    }

    func cancelRefresh() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        clearCancelledLoadingState(&sources.approvals)
        clearCancelledLoadingState(&sources.memoryCandidates)
        clearCancelledLoadingState(&sources.persona)
    }

    private func refresh(
        port: Int,
        workspaceRoot: String,
        authToken: String?,
        requestedSources: Set<DigitalMeNavigationSource>,
        force: Bool,
        now: Date
    ) async {
        let requestedScope = Self.normalizedScope(
            port: port,
            workspaceRoot: workspaceRoot
        )
        let callGeneration = activateScope(requestedScope)

        while let activeTask = refreshTask {
            let activeTaskID = refreshTaskID
            await activeTask.value
            if refreshTaskID == activeTaskID {
                refreshTask = nil
                refreshTaskID = nil
            }
            guard scope == requestedScope, generation == callGeneration else {
                return
            }
        }

        let loadApprovals = requestedSources.contains(.approvals)
            && (force || sources.approvals.needsRefresh(at: now, ttl: ttl))
        let loadMemory = requestedSources.contains(.memoryCandidates)
            && (force || sources.memoryCandidates.needsRefresh(at: now, ttl: ttl))
        let loadPersona = requestedSources.contains(.persona)
            && (force || sources.persona.needsRefresh(at: now, ttl: ttl))
        guard loadApprovals || loadMemory || loadPersona else { return }

        markLoading(
            approvals: loadApprovals,
            memoryCandidates: loadMemory,
            persona: loadPersona,
            at: now
        )

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(
                authToken: authToken,
                loadApprovals: loadApprovals,
                loadMemory: loadMemory,
                loadPersona: loadPersona,
                now: now,
                scope: requestedScope,
                generation: callGeneration,
                taskID: taskID
            )
        }
        refreshTask = task
        refreshTaskID = taskID
        await task.value
        if refreshTaskID == taskID {
            refreshTask = nil
            refreshTaskID = nil
        }
    }

    private func performRefresh(
        authToken: String?,
        loadApprovals: Bool,
        loadMemory: Bool,
        loadPersona: Bool,
        now: Date,
        scope expectedScope: DigitalMeNavigationScope,
        generation expectedGeneration: UInt64,
        taskID: UUID
    ) async {
        let transport = transport
        async let approvals = Self.load(
            enabled: loadApprovals,
            path: "/approvals",
            limit: DigitalMeNavigationContract.pageLimit,
            port: expectedScope.port,
            workspaceRoot: expectedScope.workspaceRoot,
            authToken: authToken,
            transport: transport,
            as: DigitalMeApprovalsResponse.self
        )
        async let memory = Self.load(
            enabled: loadMemory,
            path: "/memory-candidates",
            limit: DigitalMeNavigationContract.pageLimit,
            port: expectedScope.port,
            workspaceRoot: expectedScope.workspaceRoot,
            authToken: authToken,
            transport: transport,
            as: DigitalMeMemoryCandidatesResponse.self
        )
        async let persona = Self.load(
            enabled: loadPersona,
            path: "/persona",
            limit: DigitalMeNavigationContract.pageLimit,
            port: expectedScope.port,
            workspaceRoot: expectedScope.workspaceRoot,
            authToken: authToken,
            transport: transport,
            as: DigitalMePersonaResponse.self
        )

        let results = await (approvals, memory, persona)
        guard generation == expectedGeneration,
              self.scope == expectedScope,
              refreshTaskID == taskID else {
            return
        }
        apply(
            results.0,
            to: &sources.approvals,
            at: now,
            workspaceRoot: expectedScope.workspaceRoot
        )
        apply(
            results.1,
            to: &sources.memoryCandidates,
            at: now,
            workspaceRoot: expectedScope.workspaceRoot
        )
        apply(
            results.2,
            to: &sources.persona,
            at: now,
            workspaceRoot: expectedScope.workspaceRoot
        )
    }

    private func activateScope(
        _ requestedScope: DigitalMeNavigationScope
    ) -> UInt64 {
        guard scope != requestedScope else { return generation }
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        scope = requestedScope
        sources = .notRequested
        return generation
    }

    private func clearCancelledLoadingState<Value>(
        _ state: inout DigitalMeNavigationSourceState<Value>
    ) {
        guard state.isLoading else { return }
        state.isLoading = false
        state.errorMessage = nil
        state.lastAttemptedAt = nil
    }

    private func markLoading(
        approvals: Bool,
        memoryCandidates: Bool,
        persona: Bool,
        at now: Date
    ) {
        if approvals {
            sources.approvals.isLoading = true
            sources.approvals.errorMessage = nil
            sources.approvals.lastAttemptedAt = now
        }
        if memoryCandidates {
            sources.memoryCandidates.isLoading = true
            sources.memoryCandidates.errorMessage = nil
            sources.memoryCandidates.lastAttemptedAt = now
        }
        if persona {
            sources.persona.isLoading = true
            sources.persona.errorMessage = nil
            sources.persona.lastAttemptedAt = now
        }
    }

    private func apply<Value>(
        _ outcome: LoadOutcome<Value>,
        to state: inout DigitalMeNavigationSourceState<Value>,
        at now: Date,
        workspaceRoot: String
    ) {
        switch outcome {
        case .skipped:
            break
        case let .success(value):
            state.value = value
            state.isLoading = false
            state.errorMessage = nil
            state.lastAttemptedAt = now
            state.refreshedAt = now
        case let .failure(message):
            state.isLoading = false
            state.errorMessage = Self.safeErrorMessage(
                message,
                workspaceRoot: workspaceRoot
            )
            state.lastAttemptedAt = now
        }
    }

    private nonisolated static func load<Value: Decodable & Equatable & Sendable>(
        enabled: Bool,
        path: String,
        limit: Int,
        port: Int,
        workspaceRoot: String,
        authToken: String?,
        transport: any DigitalMeNavigationTransport,
        as type: Value.Type
    ) async -> LoadOutcome<Value> {
        guard enabled else { return .skipped }
        do {
            let request = try makeRequest(
                path: path,
                limit: limit,
                port: port,
                workspaceRoot: workspaceRoot,
                authToken: authToken
            )
            let response = try await transport.send(request)
            if response.statusCode == 401 {
                throw DigitalMeNavigationAPIError.unauthorized
            }
            guard (200..<300).contains(response.statusCode) else {
                throw DigitalMeNavigationAPIError.httpStatus(response.statusCode)
            }
            let envelope = try JSONDecoder().decode(
                DigitalMeNavigationEnvelope<Value>.self,
                from: response.data
            )
            guard envelope.ok else {
                throw DigitalMeNavigationAPIError.remoteFailure
            }
            guard let value = envelope.data else {
                throw DigitalMeNavigationAPIError.invalidEnvelope
            }
            return .success(value)
        } catch is CancellationError {
            return .failure("Digital-Me refresh was cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private nonisolated static func makeRequest(
        path: String,
        limit: Int,
        port: Int,
        workspaceRoot: String,
        authToken: String?
    ) throws -> URLRequest {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...65_535).contains(port), !root.isEmpty else {
            throw DigitalMeNavigationAPIError.invalidEndpoint
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "root", value: root),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else {
            throw DigitalMeNavigationAPIError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        let token = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private nonisolated static func normalizedScope(
        port: Int,
        workspaceRoot: String
    ) -> DigitalMeNavigationScope {
        let trimmed = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = expanded.isEmpty
            ? ""
            : (expanded as NSString).standardizingPath
        return DigitalMeNavigationScope(
            // Keep the caller-provided port in the cache scope. makeRequest
            // rejects values outside 1...65535 before any bearer token or
            // workspace root can reach a different loopback service.
            port: port,
            workspaceRoot: standardized
        )
    }

    private nonisolated static func safeErrorMessage(
        _ message: String,
        workspaceRoot: String
    ) -> String {
        var safe = message
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !root.isEmpty {
            safe = safe.replacingOccurrences(of: root, with: "[workspace]")
        }
        let home = NSHomeDirectory()
        if !home.isEmpty {
            safe = safe.replacingOccurrences(of: home, with: "~")
        }
        return String(safe.prefix(240))
    }
}

private enum LoadOutcome<Value: Equatable & Sendable>: Sendable {
    case skipped
    case success(Value)
    case failure(String)
}

private struct DigitalMeNavigationEnvelope<Value: Decodable>: Decodable {
    let ok: Bool
    let data: Value?
}

private struct DigitalMeNavigationScope: Equatable, Sendable {
    let port: Int
    let workspaceRoot: String
}
