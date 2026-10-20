import Darwin
import Foundation

protocol CodexThreadActivityProbing: Sendable {
    func isThreadRunning(
        homePath: String,
        threadID: String
    ) async throws -> Bool
}

enum CodexThreadActivityProbeError: LocalizedError, Sendable {
    case commandFailed(Int32, String)
    case invalidResponse
    case threadNotListed(String, Int)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(code, detail):
            return "Codex activity probe failed (\(code)): \(detail)"
        case .invalidResponse:
            return "Codex activity probe returned an invalid response."
        case let .threadNotListed(threadID, limit):
            return "Codex activity probe did not list task \(threadID) within the first \(limit) results; activity is unknown."
        case let .timedOut(seconds):
            return "Codex activity probe timed out after \(seconds.formatted()) seconds."
        }
    }
}

struct CodexCLIThreadActivityProbe: CodexThreadActivityProbing {
    static let resultLimit = 200
    static let defaultTimeoutSeconds: TimeInterval = 30

    private static let gracefulTerminationWait: TimeInterval = 0.2
    private static let forcedTerminationWait: TimeInterval = 1

    let executablePath: String
    let timeoutSeconds: TimeInterval

    init(
        executablePath: String,
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds
    ) {
        self.executablePath = executablePath
        self.timeoutSeconds = timeoutSeconds
    }

    func isThreadRunning(
        homePath: String,
        threadID: String
    ) async throws -> Bool {
        let executablePath = executablePath
        return try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let captureDirectory = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "harvis-codex-activity-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: captureDirectory,
                withIntermediateDirectories: true
            )
            defer { try? fileManager.removeItem(at: captureDirectory) }

            let outputURL = captureDirectory.appendingPathComponent("stdout.json")
            let errorURL = captureDirectory.appendingPathComponent("stderr.txt")
            fileManager.createFile(atPath: outputURL.path, contents: nil)
            fileManager.createFile(atPath: errorURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            defer {
                try? output.close()
                try? error.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = [
                "codex", "chats",
                "--home", homePath,
                "--limit", String(Self.resultLimit),
            ]
            process.standardOutput = output
            process.standardError = error
            let exitSignal = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSignal.signal()
            }
            try process.run()
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !process.isRunning else {
                Self.terminateAndReap(
                    process,
                    exitSignal: exitSignal
                )
                throw CodexThreadActivityProbeError.timedOut(timeoutSeconds)
            }
            try output.close()
            try error.close()

            let outputData = try Data(contentsOf: outputURL)
            let errorData = try Data(contentsOf: errorURL)
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw CodexThreadActivityProbeError.commandFailed(
                    process.terminationStatus,
                    String(errorText.prefix(500))
                )
            }

            struct Response: Decodable {
                struct Item: Decodable {
                    let id: String
                    let running: Bool
                }

                let ok: Bool
                let items: [Item]
            }

            let response = try JSONDecoder().decode(Response.self, from: outputData)
            guard response.ok else {
                throw CodexThreadActivityProbeError.invalidResponse
            }
            guard let item = response.items.first(where: { $0.id == threadID }) else {
                throw CodexThreadActivityProbeError.threadNotListed(
                    threadID,
                    Self.resultLimit
                )
            }
            return item.running
        }.value
    }

    /// Stops a timed-out child without introducing another unbounded wait.
    /// `Process` invokes its termination handler after it has observed/reaped
    /// the child, so the semaphore also gives us a bounded reap acknowledgement.
    @discardableResult
    static func terminateAndReap(
        _ process: Process,
        exitSignal: DispatchSemaphore
    ) -> Bool {
        guard process.isRunning else { return true }

        let processID = process.processIdentifier
        _ = Darwin.kill(processID, SIGTERM)
        if exitSignal.wait(
            timeout: .now() + gracefulTerminationWait
        ) == .success {
            return true
        }

        // Recheck Foundation's state before signalling again. This avoids
        // targeting a reused PID if the child exited while the handler was
        // waiting to run.
        guard process.isRunning else { return true }
        _ = Darwin.kill(processID, SIGKILL)
        if exitSignal.wait(
            timeout: .now() + forcedTerminationWait
        ) == .success {
            return true
        }
        return !process.isRunning
    }
}
