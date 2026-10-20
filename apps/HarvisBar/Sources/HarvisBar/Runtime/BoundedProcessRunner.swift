import Foundation
import HarvisVersionCore

struct BoundedProcessResult: Sendable {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32
}

enum BoundedProcessRunnerError: LocalizedError, Sendable {
    case invalidTimeout(TimeInterval)
    case launchFailed(executable: String, message: String)
    case timedOut(executable: String, timeout: TimeInterval)
    case cancelled(executable: String)
    case terminationFailed(executable: String, processID: Int32)

    var errorDescription: String? {
        switch self {
        case let .invalidTimeout(timeout):
            return "Process timeout must be finite and greater than zero (received \(timeout))."
        case let .launchFailed(executable, message):
            return "Could not launch \(executable): \(message)"
        case let .timedOut(executable, timeout):
            return "Process timed out after \(Self.formatted(timeout)) seconds: \(executable)"
        case let .cancelled(executable):
            return "Process was cancelled: \(executable)"
        case let .terminationFailed(executable, processID):
            return "Process \(processID) did not exit after SIGTERM and SIGKILL: \(executable)"
        }
    }

    private static func formatted(_ value: TimeInterval) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}

/// Source-compatible String facade over HarvisVersionCore's raw bounded runner.
enum BoundedProcessRunner {
    static let defaultTimeout: TimeInterval = 8
    static let defaultTerminationGracePeriod: TimeInterval = 0.35
    static let defaultKillGracePeriod: TimeInterval = 1

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        terminationGracePeriod: TimeInterval = defaultTerminationGracePeriod,
        killGracePeriod: TimeInterval = defaultKillGracePeriod,
        standardOutputLimit: Int = 1_048_576
    ) async throws -> BoundedProcessResult {
        do {
            let result = try await HarvisVersionProcessRunner.run(
                request(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    terminationGracePeriod: terminationGracePeriod,
                    killGracePeriod: killGracePeriod,
                    standardOutputLimit: standardOutputLimit
                )
            )
            return stringResult(result)
        } catch {
            throw map(error, executable: executable)
        }
    }

    static func runSynchronously(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        terminationGracePeriod: TimeInterval = defaultTerminationGracePeriod,
        killGracePeriod: TimeInterval = defaultKillGracePeriod
    ) throws -> BoundedProcessResult {
        do {
            let result = try HarvisVersionProcessRunner.runSynchronously(
                request(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    terminationGracePeriod: terminationGracePeriod,
                    killGracePeriod: killGracePeriod
                )
            )
            return stringResult(result)
        } catch {
            throw map(error, executable: executable)
        }
    }

    /// Kept internal for the pre-existing crash-residue regression test.
    static func makeAnonymousCapture(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw BoundedProcessRunnerError.launchFailed(
                executable: url.path,
                message: "Could not create anonymous capture file"
            )
        }
        do {
            let handle = try FileHandle(forUpdating: url)
            try FileManager.default.removeItem(at: url)
            return handle
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func request(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval,
        killGracePeriod: TimeInterval,
        standardOutputLimit: Int = 1_048_576
    ) -> HarvisVersionProcessRequest {
        HarvisVersionProcessRequest(
            executable: executable,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            killGracePeriod: killGracePeriod,
            standardOutputLimit: min(max(standardOutputLimit, 1), 8_388_608),
            standardErrorLimit: 1_048_576,
            aggregateBytesBefore: 0,
            aggregateLimit: min(max(standardOutputLimit, 1), 8_388_608) + 1_048_576
        )
    }

    private static func stringResult(
        _ result: HarvisVersionProcessDataResult
    ) -> BoundedProcessResult {
        BoundedProcessResult(
            standardOutput: String(data: result.standardOutput, encoding: .utf8) ?? "",
            standardError: String(data: result.standardError, encoding: .utf8) ?? "",
            terminationStatus: result.terminationStatus
        )
    }

    private static func map(_ error: Error, executable: String) -> Error {
        guard let error = error as? HarvisVersionProcessRunnerError else { return error }
        switch error {
        case let .invalidTimeout(timeout):
            return BoundedProcessRunnerError.invalidTimeout(timeout)
        case let .timedOut(_, timeout):
            return BoundedProcessRunnerError.timedOut(
                executable: executable,
                timeout: timeout
            )
        case .cancelled:
            return BoundedProcessRunnerError.cancelled(executable: executable)
        case let .terminationFailed(_, processID):
            return BoundedProcessRunnerError.terminationFailed(
                executable: executable,
                processID: processID
            )
        case .invalidGracePeriod,
             .invalidCaptureLimit,
             .invalidAggregateBudget,
             .invalidEnvironment,
             .launchFailed,
             .outputLimitExceeded,
             .ioFailure:
            return BoundedProcessRunnerError.launchFailed(
                executable: executable,
                message: error.localizedDescription
            )
        }
    }
}
