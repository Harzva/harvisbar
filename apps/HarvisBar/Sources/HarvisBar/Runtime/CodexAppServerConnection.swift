import Foundation

enum CodexExecutableLocator {
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        if let configured = environment["HARVIS_CODEX_EXECUTABLE"],
           fileManager.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixedCandidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for candidate in fixedCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("codex")
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

actor CodexAppServerConnection {
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<CodexJSONValue, Error>
        var timeoutTask: Task<Void, Never>?
        var wasWritten: Bool
    }

    let homePath: String
    private let explicitExecutableURL: URL?
    private let executableArgumentsPrefix: [String]
    private let requestTimeout: TimeInterval
    private let clientVersion: String
    private let environmentPolicy: CodexProfileEnvironmentPolicy
    private var profileFingerprint: String?

    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var outputReader: Task<Void, Never>?
    private var errorReader: Task<Void, Never>?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var activeConnectionID: UUID?
    private var initialized = false
    private var isConnecting = false
    private var connectWaiters: [CheckedContinuation<UUID, Error>] = []
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var eventContinuations: [
        UUID: AsyncStream<CodexAppServerEvent>.Continuation
    ] = [:]

    init(
        homePath: String,
        executableURL: URL? = nil,
        executableArgumentsPrefix: [String] = [],
        requestTimeout: TimeInterval = 30,
        clientVersion: String = CodexAppServerConnection.bundleClientVersion(),
        environmentPolicy: CodexProfileEnvironmentPolicy = .inherited
    ) {
        self.homePath = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL
            .path
        explicitExecutableURL = executableURL
        self.executableArgumentsPrefix = executableArgumentsPrefix
        self.requestTimeout = requestTimeout
        self.environmentPolicy = environmentPolicy
        let normalizedVersion = clientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientVersion = normalizedVersion.isEmpty ? "development" : normalizedVersion
    }

    nonisolated static func bundleClientVersion(
        bundle: Bundle = .main
    ) -> String {
        HarvisBuildInfo.bundleVersion(bundle: bundle)
    }

    func events() -> AsyncStream<CodexAppServerEvent> {
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            eventContinuations[subscriptionID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.removeEventContinuation(subscriptionID)
                }
            }
        }
    }

    func connectionID() -> UUID? {
        initialized ? activeConnectionID : nil
    }

    @discardableResult
    func connect() async throws -> UUID {
        if initialized,
           process?.isRunning == true,
           let activeConnectionID {
            if profileFingerprint != environmentPolicy.fingerprint(homePath: homePath) {
                invalidateConnection(activeConnectionID,
                    reason: "Selected account or profile configuration changed; the old connection was invalidated.",
                    terminateProcess: true)
                throw CodexAppServerError.connectionClosed("Profile changed. Inspect the previous turn before continuing; this request was not sent.")
            }
            return activeConnectionID
        }

        if isConnecting {
            return try await withCheckedThrowingContinuation { continuation in
                connectWaiters.append(continuation)
            }
        }

        isConnecting = true
        do {
            let connectionID = try await establishConnection()
            finishConnectWaiters(with: .success(connectionID))
            return connectionID
        } catch {
            finishConnectWaiters(with: .failure(error))
            throw error
        }
    }

    private func establishConnection() async throws -> UUID {
        if let staleConnectionID = activeConnectionID {
            invalidateConnection(
                staleConnectionID,
                reason: "Replacing stale app-server connection",
                terminateProcess: true
            )
        }

        guard let executableURL = explicitExecutableURL ?? CodexExecutableLocator.resolve() else {
            throw CodexAppServerError.executableUnavailable
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = executableArgumentsPrefix + ["app-server", "--stdio"]
        profileFingerprint = environmentPolicy.fingerprint(homePath: homePath)
        process.environment = environmentPolicy.environment(homePath: homePath, parent: ProcessInfo.processInfo.environment)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let connectionID = UUID()
        activeConnectionID = connectionID
        initialized = false
        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe.fileHandleForReading
        standardError = errorPipe.fileHandleForReading
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self?.processTerminated(
                    connectionID: connectionID,
                    status: status
                )
            }
        }

        do {
            try process.run()
            startReaders(
                output: outputPipe.fileHandleForReading,
                error: errorPipe.fileHandleForReading,
                connectionID: connectionID
            )
            let initializeParams: CodexJSONValue = .object([
                "clientInfo": .object([
                    "name": .string("harvisbar-codex-manager"),
                    "version": .string(clientVersion),
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true),
                ]),
            ])
            _ = try await sendRequest(
                method: "initialize",
                params: initializeParams,
                timeout: min(requestTimeout, 15)
            )
            try write(
                CodexJSONRPC.notification(method: "initialized"),
                expectedConnectionID: connectionID
            )
            initialized = true
            emit(.connected(connectionID: connectionID))
            return connectionID
        } catch {
            invalidateConnection(
                connectionID,
                reason: error.localizedDescription,
                terminateProcess: true
            )
            throw error
        }
    }

    private func finishConnectWaiters(with result: Result<UUID, Error>) {
        isConnecting = false
        let waiters = connectWaiters
        connectWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            switch result {
            case let .success(connectionID):
                waiter.resume(returning: connectionID)
            case let .failure(error):
                waiter.resume(throwing: error)
            }
        }
    }

    func request(
        method: String,
        params: CodexJSONValue,
        timeout: TimeInterval? = nil
    ) async throws -> CodexJSONValue {
        _ = try await connect()
        return try await sendRequest(
            method: method,
            params: params,
            timeout: timeout ?? requestTimeout
        )
    }

    func respond(
        to id: CodexRPCID,
        result: CodexJSONValue,
        expectedConnectionID: UUID
    ) throws {
        try write(
            CodexJSONRPC.response(id: id, result: result),
            expectedConnectionID: expectedConnectionID
        )
    }

    func respondError(
        to id: CodexRPCID,
        code: Int,
        message: String,
        expectedConnectionID: UUID
    ) throws {
        try write(
            CodexJSONRPC.errorResponse(id: id, code: code, message: message),
            expectedConnectionID: expectedConnectionID
        )
    }

    func stop() {
        guard let activeConnectionID else { return }
        invalidateConnection(
            activeConnectionID,
            reason: "Stopped by HarvisBar",
            terminateProcess: true
        )
    }

    private func sendRequest(
        method: String,
        params: CodexJSONValue,
        timeout: TimeInterval
    ) async throws -> CodexJSONValue {
        guard let connectionID = activeConnectionID,
              process?.isRunning == true else {
            throw CodexAppServerError.connectionClosed("process is not running")
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let payload = CodexJSONRPC.request(
            id: requestID,
            method: method,
            params: params
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = PendingRequest(
                method: method,
                continuation: continuation,
                timeoutTask: nil,
                wasWritten: false
            )
            do {
                try write(payload, expectedConnectionID: connectionID)
                pendingRequests[requestID]?.wasWritten = true
                let nanoseconds = UInt64(max(0.1, timeout) * 1_000_000_000)
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    await self?.expireRequest(
                        requestID,
                        connectionID: connectionID
                    )
                }
                pendingRequests[requestID]?.timeoutTask = timeoutTask
            } catch {
                let pending = pendingRequests.removeValue(forKey: requestID)
                pending?.continuation.resume(throwing: error)
            }
        }
    }

    private func write(
        _ value: CodexJSONValue,
        expectedConnectionID: UUID
    ) throws {
        guard activeConnectionID == expectedConnectionID,
              process?.isRunning == true,
              let standardInput else {
            throw CodexAppServerError.connectionClosed(
                "connection lifecycle changed"
            )
        }
        var data = try value.encodedData()
        data.append(0x0A)
        try standardInput.write(contentsOf: data)
    }

    private func startReaders(
        output: FileHandle,
        error: FileHandle,
        connectionID: UUID
    ) {
        // One consumer per pipe preserves byte order. A new unstructured Task
        // for every chunk can reach the actor out of order, corrupting large
        // JSON history responses and multibyte text split across reads.
        let stdout = AsyncStream<Data> { continuation in
            output.readabilityHandler = { handle in
                let data = handle.availableData
                continuation.yield(data)
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }
        let stderr = AsyncStream<Data> { continuation in
            error.readabilityHandler = { handle in
                let data = handle.availableData
                continuation.yield(data)
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }
        outputReader = Task { [weak self] in
            for await data in stdout {
                guard !Task.isCancelled else { return }
                await self?.receiveStandardOutputData(data, connectionID: connectionID)
            }
        }
        errorReader = Task { [weak self] in
            for await data in stderr {
                guard !Task.isCancelled else { return }
                await self?.receiveStandardErrorData(data, connectionID: connectionID)
            }
        }
    }

    private func receiveStandardOutputData(
        _ data: Data,
        connectionID: UUID
    ) {
        guard activeConnectionID == connectionID else { return }
        if data.isEmpty {
            flushOutputBuffer(connectionID: connectionID)
            readerEnded(
                connectionID: connectionID,
                reason: "standard output closed"
            )
            return
        }
        outputBuffer.append(data)
        for line in Self.takeCompleteLines(from: &outputBuffer) {
            receiveStandardOutputLine(line, connectionID: connectionID)
        }
    }

    private func receiveStandardErrorData(
        _ data: Data,
        connectionID: UUID
    ) {
        guard activeConnectionID == connectionID else { return }
        if data.isEmpty {
            flushErrorBuffer(connectionID: connectionID)
            return
        }
        errorBuffer.append(data)
        for line in Self.takeCompleteLines(from: &errorBuffer) {
            receiveStandardErrorLine(line, connectionID: connectionID)
        }
    }

    private func flushOutputBuffer(connectionID: UUID) {
        guard !outputBuffer.isEmpty else { return }
        if let line = String(data: outputBuffer, encoding: .utf8),
           !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            receiveStandardOutputLine(line, connectionID: connectionID)
        }
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func flushErrorBuffer(connectionID: UUID) {
        guard !errorBuffer.isEmpty else { return }
        if let line = String(data: errorBuffer, encoding: .utf8),
           !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            receiveStandardErrorLine(line, connectionID: connectionID)
        }
        errorBuffer.removeAll(keepingCapacity: false)
    }

    nonisolated private static func takeCompleteLines(
        from buffer: inout Data
    ) -> [String] {
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8),
               !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private func receiveStandardOutputLine(
        _ line: String,
        connectionID: UUID
    ) {
        guard activeConnectionID == connectionID else { return }
        if line.hasPrefix("HARVIS_READER_ERROR:") {
            emit(.standardError(message: line, connectionID: connectionID))
            return
        }
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                CodexJSONValue.self,
                from: data
              ),
              let object = value.objectValue else {
            emit(.standardError(
                message: "Unparseable app-server output: \(line.prefix(300))",
                connectionID: connectionID
            ))
            return
        }

        if let method = object["method"]?.stringValue {
            let params = object["params"] ?? .object([:])
            if let rawID = object["id"],
               let id = rpcID(from: rawID) {
                emit(.serverRequest(
                    request: CodexServerRequest(
                        id: id,
                        method: method,
                        params: params
                    ),
                    connectionID: connectionID
                ))
            } else {
                emit(.notification(
                    method: method,
                    params: params,
                    connectionID: connectionID
                ))
            }
            return
        }

        guard let requestID = object["id"]?.intValue,
              let pending = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        pending.timeoutTask?.cancel()
        if let error = object["error"]?.objectValue {
            pending.continuation.resume(throwing: CodexAppServerError.rpc(
                code: error["code"]?.intValue,
                message: error["message"]?.stringValue ?? "Unknown RPC error"
            ))
        } else {
            pending.continuation.resume(returning: object["result"] ?? .null)
        }
    }

    private func receiveStandardErrorLine(
        _ line: String,
        connectionID: UUID
    ) {
        guard activeConnectionID == connectionID,
              !line.isEmpty else {
            return
        }
        emit(.standardError(
            message: String(line.prefix(500)),
            connectionID: connectionID
        ))
    }

    private func rpcID(from value: CodexJSONValue) -> CodexRPCID? {
        if let intValue = value.intValue {
            return .integer(intValue)
        }
        if let stringValue = value.stringValue {
            return .string(stringValue)
        }
        return nil
    }

    private func expireRequest(
        _ requestID: Int,
        connectionID: UUID
    ) {
        guard activeConnectionID == connectionID,
              let pending = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        let error: CodexAppServerError = pending.wasWritten
            ? .deliveryUncertain(
                method: pending.method,
                reason: "response timed out"
            )
            : .requestTimedOut(method: pending.method)
        pending.continuation.resume(throwing: error)
    }

    private func processTerminated(
        connectionID: UUID,
        status: Int32
    ) {
        invalidateConnection(
            connectionID,
            reason: "process exited with status \(status)",
            terminateProcess: false
        )
    }

    private func readerEnded(
        connectionID: UUID,
        reason: String
    ) {
        guard activeConnectionID == connectionID,
              process?.isRunning != true else {
            return
        }
        invalidateConnection(
            connectionID,
            reason: reason,
            terminateProcess: false
        )
    }

    private func invalidateConnection(
        _ connectionID: UUID,
        reason: String,
        terminateProcess: Bool
    ) {
        guard activeConnectionID == connectionID else { return }
        initialized = false
        activeConnectionID = nil

        let requests = pendingRequests
        pendingRequests.removeAll()
        for (_, pending) in requests {
            pending.timeoutTask?.cancel()
            let error: CodexAppServerError = pending.wasWritten
                ? .deliveryUncertain(method: pending.method, reason: reason)
                : .connectionClosed(reason)
            pending.continuation.resume(throwing: error)
        }

        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        outputReader?.cancel()
        errorReader?.cancel()
        outputReader = nil
        errorReader = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
        try? standardInput?.close()
        try? standardOutput?.close()
        try? standardError?.close()
        standardInput = nil
        standardOutput = nil
        standardError = nil

        if terminateProcess, process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        emit(.disconnected(connectionID: connectionID, reason: reason))
    }

    private func emit(_ event: CodexAppServerEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
