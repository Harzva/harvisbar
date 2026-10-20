import Darwin
import Foundation

public struct HarvisVersionProcessRequest: Sendable {
    public let executable: String
    public let arguments: [String]
    /// The complete child environment. The runner never merges inherited values.
    public let environment: [String: String]
    /// Borrowed for the duration of `posix_spawn`; ownership remains with the caller.
    public let workingDirectoryFileDescriptor: Int32?
    public let timeout: TimeInterval
    public let terminationGracePeriod: TimeInterval
    public let killGracePeriod: TimeInterval
    public let standardOutputLimit: Int
    public let standardErrorLimit: Int
    public let aggregateBytesBefore: Int
    public let aggregateLimit: Int

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectoryFileDescriptor: Int32? = nil,
        timeout: TimeInterval = 8,
        terminationGracePeriod: TimeInterval = 0.35,
        killGracePeriod: TimeInterval = 1,
        standardOutputLimit: Int = 1_048_576,
        standardErrorLimit: Int = 1_048_576,
        aggregateBytesBefore: Int = 0,
        aggregateLimit: Int = 4_194_304
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryFileDescriptor = workingDirectoryFileDescriptor
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.killGracePeriod = killGracePeriod
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
        self.aggregateBytesBefore = aggregateBytesBefore
        self.aggregateLimit = aggregateLimit
    }
}

public struct HarvisVersionProcessDataResult: Equatable, Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32
    public let capturedByteCount: Int

    public init(
        standardOutput: Data,
        standardError: Data,
        terminationStatus: Int32,
        capturedByteCount: Int
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
        self.capturedByteCount = capturedByteCount
    }
}

public enum HarvisVersionProcessRunnerError: LocalizedError, Sendable {
    case invalidTimeout(TimeInterval)
    case invalidGracePeriod(name: String, value: TimeInterval)
    case invalidCaptureLimit(Int)
    case invalidAggregateBudget(bytesBefore: Int, limit: Int)
    case invalidEnvironment
    case launchFailed(executable: String)
    case timedOut(executable: String, timeout: TimeInterval)
    case cancelled(executable: String)
    case outputLimitExceeded(executable: String)
    case terminationFailed(executable: String, processID: Int32)
    case ioFailure(executable: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidTimeout(timeout):
            return "Process timeout must be finite and greater than zero (received \(timeout))."
        case let .invalidGracePeriod(name, value):
            return "Process \(name) grace period must be finite and non-negative (received \(value))."
        case let .invalidCaptureLimit(limit):
            return "Process capture limit must be greater than zero (received \(limit))."
        case let .invalidAggregateBudget(bytesBefore, limit):
            return "Process aggregate budget is invalid (\(bytesBefore) of \(limit) bytes already used)."
        case .invalidEnvironment:
            return "Process arguments or environment contain an invalid value."
        case let .launchFailed(executable):
            return "Could not launch \(executable)."
        case let .timedOut(executable, timeout):
            return "Process timed out after \(Self.formatted(timeout)) seconds: \(executable)"
        case let .cancelled(executable):
            return "Process was cancelled: \(executable)"
        case let .outputLimitExceeded(executable):
            return "Process output exceeded its bounded capture limit: \(executable)"
        case let .terminationFailed(executable, processID):
            return "Process group led by \(processID) did not terminate: \(executable)"
        case let .ioFailure(executable):
            return "Process transport failed while capturing output: \(executable)"
        }
    }

    private static func formatted(_ value: TimeInterval) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}

public typealias HarvisVersionProcessError = HarvisVersionProcessRunnerError

/// Raw, bounded local process transport for the Harvis version inspector.
///
/// The implementation uses anonymous regular files rather than pipes, supplies
/// a complete environment, binds an optional open directory fd with
/// `posix_spawn_file_actions_addfchdir_np`, and owns a fresh process group for
/// bounded TERM -> KILL teardown. Capture reads are `pread` loops capped at
/// `limit + 1`; no unbounded read API is used.
public struct HarvisVersionProcessRunner: Sendable {
    private let captureUnlink: @Sendable (String) -> Int32

    public init() {
        captureUnlink = { path in
            path.withCString { Darwin.unlink($0) }
        }
    }

    /// Test seam for proving that a capture which cannot be unlinked fails
    /// before `posix_spawn`. Production callers always use `Darwin.unlink`.
    init(captureUnlink: @escaping @Sendable (String) -> Int32) {
        self.captureUnlink = captureUnlink
    }

    public func run(
        _ request: HarvisVersionProcessRequest
    ) async throws -> HarvisVersionProcessDataResult {
        let cancellation = HarvisProcessCancellationState()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Self.runSynchronously(
                    request,
                    cancellation: cancellation,
                    captureUnlink: captureUnlink
                )
            }.value
        } onCancel: {
            cancellation.requestCancellation()
        }
    }

    public func runSynchronously(
        _ request: HarvisVersionProcessRequest
    ) throws -> HarvisVersionProcessDataResult {
        try Self.runSynchronously(
            request,
            cancellation: nil,
            captureUnlink: captureUnlink
        )
    }

    public static func run(
        _ request: HarvisVersionProcessRequest
    ) async throws -> HarvisVersionProcessDataResult {
        try await HarvisVersionProcessRunner().run(request)
    }

    public static func runSynchronously(
        _ request: HarvisVersionProcessRequest
    ) throws -> HarvisVersionProcessDataResult {
        try HarvisVersionProcessRunner().runSynchronously(request)
    }

    private static func runSynchronously(
        _ request: HarvisVersionProcessRequest,
        cancellation: HarvisProcessCancellationState?,
        captureUnlink: @Sendable (String) -> Int32
    ) throws -> HarvisVersionProcessDataResult {
        try validate(request)
        if cancellation?.isCancellationRequested == true {
            throw HarvisVersionProcessRunnerError.cancelled(executable: request.executable)
        }

        let standardOutputFD = try makeAnonymousCapture(
            executable: request.executable,
            unlink: captureUnlink
        )
        var standardOutputOpen = true
        defer {
            if standardOutputOpen {
                closeDescriptor(standardOutputFD)
            }
        }

        let standardErrorFD: Int32
        do {
            standardErrorFD = try makeAnonymousCapture(
                executable: request.executable,
                unlink: captureUnlink
            )
        } catch {
            throw error
        }
        var standardErrorOpen = true
        defer {
            if standardErrorOpen {
                closeDescriptor(standardErrorFD)
            }
        }

        let processID = try spawn(
            request,
            standardOutputFD: standardOutputFD,
            standardErrorFD: standardErrorFD
        )
        var leaderReaped = false
        var rawWaitStatus: Int32 = 0
        let deadline = monotonicNow() + request.timeout
        var stopReason: HarvisProcessStopReason?

        while !leaderReaped {
            do {
                try validateCaptureSizes(
                    request,
                    standardOutputFD: standardOutputFD,
                    standardErrorFD: standardErrorFD
                )
            } catch let error as HarvisVersionProcessRunnerError {
                if case .outputLimitExceeded = error {
                    stopReason = .outputLimitExceeded
                    break
                }
                try? terminateAndReap(
                    processID: processID,
                    leaderReaped: &leaderReaped,
                    rawWaitStatus: &rawWaitStatus,
                    request: request
                )
                throw error
            }

            let waitResult = waitForLeader(
                processID,
                options: WNOHANG,
                rawWaitStatus: &rawWaitStatus
            )
            switch waitResult {
            case .reaped:
                leaderReaped = true
            case .running:
                break
            case .failed:
                try? terminateAndReap(
                    processID: processID,
                    leaderReaped: &leaderReaped,
                    rawWaitStatus: &rawWaitStatus,
                    request: request
                )
                throw HarvisVersionProcessRunnerError.ioFailure(executable: request.executable)
            }

            guard !leaderReaped else { break }
            if cancellation?.isCancellationRequested == true {
                stopReason = .cancelled
                break
            }
            if monotonicNow() >= deadline {
                stopReason = .timedOut
                break
            }
            sleepBriefly()
        }

        if let stopReason {
            try terminateAndReap(
                processID: processID,
                leaderReaped: &leaderReaped,
                rawWaitStatus: &rawWaitStatus,
                request: request
            )
            switch stopReason {
            case .timedOut:
                throw HarvisVersionProcessRunnerError.timedOut(
                    executable: request.executable,
                    timeout: request.timeout
                )
            case .cancelled:
                throw HarvisVersionProcessRunnerError.cancelled(
                    executable: request.executable
                )
            case .outputLimitExceeded:
                throw HarvisVersionProcessRunnerError.outputLimitExceeded(
                    executable: request.executable
                )
            }
        }

        // A successful leader must not leave a descendant holding the group or
        // capture descriptors. Treat that as a transport failure and clean it.
        if processGroupExists(processID) {
            try terminateAndReap(
                processID: processID,
                leaderReaped: &leaderReaped,
                rawWaitStatus: &rawWaitStatus,
                request: request
            )
            throw HarvisVersionProcessRunnerError.terminationFailed(
                executable: request.executable,
                processID: processID
            )
        }

        try validateCaptureSizes(
            request,
            standardOutputFD: standardOutputFD,
            standardErrorFD: standardErrorFD
        )
        let standardOutput = try boundedRead(
            fd: standardOutputFD,
            limit: request.standardOutputLimit,
            executable: request.executable
        )
        let standardError = try boundedRead(
            fd: standardErrorFD,
            limit: request.standardErrorLimit,
            executable: request.executable
        )
        try validateCaptureSizes(
            request,
            standardOutputFD: standardOutputFD,
            standardErrorFD: standardErrorFD
        )

        let capturedByteCount = try checkedSum(
            standardOutput.count,
            standardError.count,
            executable: request.executable
        )
        guard capturedByteCount <= request.aggregateLimit,
              request.aggregateBytesBefore <= request.aggregateLimit - capturedByteCount else {
            throw HarvisVersionProcessRunnerError.outputLimitExceeded(
                executable: request.executable
            )
        }

        closeDescriptor(standardOutputFD)
        standardOutputOpen = false
        closeDescriptor(standardErrorFD)
        standardErrorOpen = false
        return HarvisVersionProcessDataResult(
            standardOutput: standardOutput,
            standardError: standardError,
            terminationStatus: decodedTerminationStatus(rawWaitStatus),
            capturedByteCount: capturedByteCount
        )
    }

    private static func validate(_ request: HarvisVersionProcessRequest) throws {
        guard request.timeout.isFinite, request.timeout > 0 else {
            throw HarvisVersionProcessRunnerError.invalidTimeout(request.timeout)
        }
        guard request.terminationGracePeriod.isFinite,
              request.terminationGracePeriod >= 0 else {
            throw HarvisVersionProcessRunnerError.invalidGracePeriod(
                name: "termination",
                value: request.terminationGracePeriod
            )
        }
        guard request.killGracePeriod.isFinite,
              request.killGracePeriod >= 0 else {
            throw HarvisVersionProcessRunnerError.invalidGracePeriod(
                name: "kill",
                value: request.killGracePeriod
            )
        }
        guard request.standardOutputLimit > 0,
              request.standardOutputLimit < Int.max else {
            throw HarvisVersionProcessRunnerError.invalidCaptureLimit(
                request.standardOutputLimit
            )
        }
        guard request.standardErrorLimit > 0,
              request.standardErrorLimit < Int.max else {
            throw HarvisVersionProcessRunnerError.invalidCaptureLimit(
                request.standardErrorLimit
            )
        }
        guard request.aggregateBytesBefore >= 0,
              request.aggregateLimit >= 0,
              request.aggregateBytesBefore <= request.aggregateLimit else {
            throw HarvisVersionProcessRunnerError.invalidAggregateBudget(
                bytesBefore: request.aggregateBytesBefore,
                limit: request.aggregateLimit
            )
        }
        guard !request.executable.isEmpty,
              request.executable.utf8.first == UInt8(ascii: "/"),
              !request.executable.utf8.contains(0),
              request.arguments.allSatisfy({ !$0.utf8.contains(0) }),
              request.environment.allSatisfy({ key, value in
                  !key.isEmpty
                      && !key.contains("=")
                      && !key.utf8.contains(0)
                      && !value.utf8.contains(0)
              }) else {
            throw HarvisVersionProcessRunnerError.invalidEnvironment
        }
        if let cwdFD = request.workingDirectoryFileDescriptor {
            guard cwdFD >= 0, fcntl(cwdFD, F_GETFD) != -1 else {
                throw HarvisVersionProcessRunnerError.launchFailed(
                    executable: request.executable
                )
            }
        }
    }

    private static func spawn(
        _ request: HarvisVersionProcessRequest,
        standardOutputFD: Int32,
        standardErrorFD: Int32
    ) throws -> Int32 {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw HarvisVersionProcessRunnerError.launchFailed(
                executable: request.executable
            )
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        guard posix_spawn_file_actions_addopen(
            &fileActions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions,
            standardOutputFD,
            STDOUT_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions,
            standardErrorFD,
            STDERR_FILENO
        ) == 0 else {
            throw HarvisVersionProcessRunnerError.launchFailed(
                executable: request.executable
            )
        }
        if standardOutputFD != STDOUT_FILENO {
            guard posix_spawn_file_actions_addclose(&fileActions, standardOutputFD) == 0 else {
                throw HarvisVersionProcessRunnerError.launchFailed(
                    executable: request.executable
                )
            }
        }
        if standardErrorFD != STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(&fileActions, standardErrorFD) == 0 else {
                throw HarvisVersionProcessRunnerError.launchFailed(
                    executable: request.executable
                )
            }
        }
        if let cwdFD = request.workingDirectoryFileDescriptor {
            guard posix_spawn_file_actions_addfchdir_np(&fileActions, cwdFD) == 0 else {
                throw HarvisVersionProcessRunnerError.launchFailed(
                    executable: request.executable
                )
            }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw HarvisVersionProcessRunnerError.launchFailed(
                executable: request.executable
            )
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGHUP)
        sigaddset(&defaultSignals, SIGPIPE)
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 else {
            throw HarvisVersionProcessRunnerError.launchFailed(
                executable: request.executable
            )
        }

        let argv = [request.executable] + request.arguments
        let environment = request.environment
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let spawnStatus = withMutableCStringArray(argv) { argvPointer in
            withMutableCStringArray(environment) { environmentPointer in
                posix_spawn(
                    &processID,
                    request.executable,
                    &fileActions,
                    &attributes,
                    argvPointer,
                    environmentPointer
                )
            }
        }
        guard spawnStatus == 0 else {
            throw HarvisVersionProcessRunnerError.launchFailed(
                executable: request.executable
            )
        }
        return processID
    }

    private static func validateCaptureSizes(
        _ request: HarvisVersionProcessRequest,
        standardOutputFD: Int32,
        standardErrorFD: Int32
    ) throws {
        let standardOutputSize = try descriptorSize(
            standardOutputFD,
            executable: request.executable
        )
        let standardErrorSize = try descriptorSize(
            standardErrorFD,
            executable: request.executable
        )
        guard standardOutputSize <= request.standardOutputLimit,
              standardErrorSize <= request.standardErrorLimit else {
            throw HarvisVersionProcessRunnerError.outputLimitExceeded(
                executable: request.executable
            )
        }
        let processBytes = try checkedSum(
            standardOutputSize,
            standardErrorSize,
            executable: request.executable
        )
        guard processBytes <= request.aggregateLimit,
              request.aggregateBytesBefore <= request.aggregateLimit - processBytes else {
            throw HarvisVersionProcessRunnerError.outputLimitExceeded(
                executable: request.executable
            )
        }
    }

    private static func descriptorSize(_ fd: Int32, executable: String) throws -> Int {
        var metadata = stat()
        while Darwin.fstat(fd, &metadata) == -1 {
            if errno == EINTR { continue }
            throw HarvisVersionProcessRunnerError.ioFailure(executable: executable)
        }
        guard metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(Int.max) else {
            throw HarvisVersionProcessRunnerError.ioFailure(executable: executable)
        }
        return Int(metadata.st_size)
    }

    private static func boundedRead(
        fd: Int32,
        limit: Int,
        executable: String
    ) throws -> Data {
        var output = Data()
        output.reserveCapacity(min(limit, 64 * 1024))
        let maximumRead = limit + 1
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while output.count < maximumRead {
            let requested = min(buffer.count, maximumRead - output.count)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.pread(fd, rawBuffer.baseAddress, requested, offset)
            }
            if count > 0 {
                output.append(buffer, count: Int(count))
                offset += off_t(count)
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw HarvisVersionProcessRunnerError.ioFailure(executable: executable)
        }
        guard output.count <= limit else {
            throw HarvisVersionProcessRunnerError.outputLimitExceeded(executable: executable)
        }
        return output
    }

    private static func terminateAndReap(
        processID: Int32,
        leaderReaped: inout Bool,
        rawWaitStatus: inout Int32,
        request: HarvisVersionProcessRequest
    ) throws {
        signalProcessGroup(processID, signal: SIGTERM)
        let termDeadline = monotonicNow() + max(0, request.terminationGracePeriod)
        waitForLeaderAndGroup(
            processID: processID,
            leaderReaped: &leaderReaped,
            rawWaitStatus: &rawWaitStatus,
            deadline: termDeadline
        )

        if processGroupExists(processID) {
            signalProcessGroup(processID, signal: SIGKILL)
        }
        let killDeadline = monotonicNow() + max(0.01, request.killGracePeriod)
        waitForLeaderAndGroup(
            processID: processID,
            leaderReaped: &leaderReaped,
            rawWaitStatus: &rawWaitStatus,
            deadline: killDeadline
        )

        guard leaderReaped, !processGroupExists(processID) else {
            throw HarvisVersionProcessRunnerError.terminationFailed(
                executable: request.executable,
                processID: processID
            )
        }
    }

    private static func waitForLeaderAndGroup(
        processID: Int32,
        leaderReaped: inout Bool,
        rawWaitStatus: inout Int32,
        deadline: TimeInterval
    ) {
        repeat {
            if !leaderReaped {
                switch waitForLeader(
                    processID,
                    options: WNOHANG,
                    rawWaitStatus: &rawWaitStatus
                ) {
                case .reaped:
                    leaderReaped = true
                case .running, .failed:
                    break
                }
            }
            if leaderReaped, !processGroupExists(processID) {
                return
            }
            if monotonicNow() >= deadline { return }
            sleepBriefly()
        } while true
    }

    private static func waitForLeader(
        _ processID: Int32,
        options: Int32,
        rawWaitStatus: inout Int32
    ) -> HarvisWaitResult {
        while true {
            let result = Darwin.waitpid(processID, &rawWaitStatus, options)
            if result == processID { return .reaped }
            if result == 0 { return .running }
            if result == -1, errno == EINTR { continue }
            return .failed
        }
    }

    private static func processGroupExists(_ processID: Int32) -> Bool {
        errno = 0
        if Darwin.kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func signalProcessGroup(_ processID: Int32, signal: Int32) {
        while Darwin.kill(-processID, signal) == -1, errno == EINTR {}
    }

    private static func decodedTerminationStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return signal
    }

    private static func checkedSum(
        _ left: Int,
        _ right: Int,
        executable: String
    ) throws -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw HarvisVersionProcessRunnerError.ioFailure(executable: executable)
        }
        return sum
    }

    private static func makeAnonymousCapture(
        executable: String,
        unlink: @Sendable (String) -> Int32
    ) throws -> Int32 {
        var template = Array(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("harvis-version-capture-XXXXXX")
                .path
                .utf8CString
        )
        let fd = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.mkstemp(baseAddress)
        }
        guard fd >= 0 else {
            throw HarvisVersionProcessRunnerError.ioFailure(executable: executable)
        }
        guard let terminator = template.firstIndex(of: 0) else {
            closeDescriptor(fd)
            throw HarvisVersionProcessRunnerError.ioFailure(executable: executable)
        }
        let capturePath = String(
            decoding: template[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard unlink(capturePath) == 0 else {
            closeDescriptor(fd)
            throw HarvisVersionProcessRunnerError.ioFailure(executable: executable)
        }
        guard Darwin.fchmod(fd, 0o600) == 0,
              Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            closeDescriptor(fd)
            throw HarvisVersionProcessRunnerError.ioFailure(executable: executable)
        }
        return fd
    }

    private static func closeDescriptor(_ fd: Int32) {
        // On Darwin a close returning EINTR still has indeterminate ownership;
        // retrying could close a reused descriptor, so close is attempted once.
        _ = Darwin.close(fd)
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func sleepBriefly() {
        var duration = timespec(tv_sec: 0, tv_nsec: 10_000_000)
        while true {
            var remaining = timespec()
            if Darwin.nanosleep(&duration, &remaining) == 0 { return }
            guard errno == EINTR else { return }
            duration = remaining
        }
    }
}

private enum HarvisProcessStopReason {
    case timedOut
    case cancelled
    case outputLimitExceeded
}

private enum HarvisWaitResult {
    case running
    case reaped
    case failed
}

private final class HarvisProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }
}
