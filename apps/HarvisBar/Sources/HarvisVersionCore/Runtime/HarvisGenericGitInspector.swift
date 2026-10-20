import Foundation

/// Target-neutral Git facts used by legacy HarvisBar project cards and future
/// version surfaces. Command execution remains in HarvisVersionCore so clients
/// cannot accidentally grow a second `Process`/`posix_spawn` implementation.
public struct HarvisGenericGitSummary: Equatable, Sendable {
    public let inspectedPath: String
    public let repositoryRoot: String?
    public let branch: String?
    public let isDetached: Bool
    public let changedFileCount: Int
    public let localBranches: [String]
    public let remoteBranches: [String]
    public let remotes: [String]
    public let worktreeCount: Int

    public init(
        inspectedPath: String,
        repositoryRoot: String?,
        branch: String?,
        isDetached: Bool,
        changedFileCount: Int,
        localBranches: [String],
        remoteBranches: [String],
        remotes: [String],
        worktreeCount: Int
    ) {
        self.inspectedPath = inspectedPath
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.isDetached = isDetached
        self.changedFileCount = changedFileCount
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.remotes = remotes
        self.worktreeCount = worktreeCount
    }

    public var isRepository: Bool { repositoryRoot != nil }
    public var isDirty: Bool { changedFileCount > 0 }

    fileprivate static func unavailable(path: String) -> Self {
        Self(
            inspectedPath: path,
            repositoryRoot: nil,
            branch: nil,
            isDetached: false,
            changedFileCount: 0,
            localBranches: [],
            remoteBranches: [],
            remotes: [],
            worktreeCount: 0
        )
    }
}

/// Read-only, deadline-bounded generic Git inspector.
///
/// It intentionally exposes the command executable/prefix for deterministic
/// timeout tests, while every command still runs through
/// `HarvisVersionProcessRunner`. The inspector performs no fetch, checkout,
/// config write, index write, or remote request.
public struct HarvisGenericGitInspector: Sendable {
    public static let defaultInspectionTimeout: TimeInterval = 5

    private let runner: HarvisVersionProcessRunner

    public init(runner: HarvisVersionProcessRunner = HarvisVersionProcessRunner()) {
        self.runner = runner
    }

    public func inspect(
        path: String,
        timeout: TimeInterval = Self.defaultInspectionTimeout,
        gitExecutable: String = "/usr/bin/git",
        gitArgumentPrefix: [String] = []
    ) -> HarvisGenericGitSummary {
        guard timeout.isFinite, timeout > 0, !path.isEmpty else {
            return .unavailable(path: path)
        }

        var budget = InspectionBudget(timeout: timeout)
        let rootResult = runGit(
            ["rev-parse", "--show-toplevel"],
            at: path,
            executable: gitExecutable,
            callerPrefix: gitArgumentPrefix,
            budget: &budget
        )
        guard rootResult.succeeded, !rootResult.output.isEmpty else {
            return .unavailable(path: path)
        }

        let root = rootResult.output
        let symbolicBranch = runGit(
            ["symbolic-ref", "--short", "-q", "HEAD"],
            at: root,
            executable: gitExecutable,
            callerPrefix: gitArgumentPrefix,
            budget: &budget
        )
        let isDetached = !symbolicBranch.succeeded || symbolicBranch.output.isEmpty
        let branch = isDetached
            ? runGit(
                ["rev-parse", "--short", "HEAD"],
                at: root,
                executable: gitExecutable,
                callerPrefix: gitArgumentPrefix,
                budget: &budget
            ).output
            : symbolicBranch.output
        let status = runGit(
            ["status", "--porcelain=v1", "--untracked-files=normal"],
            at: root,
            executable: gitExecutable,
            callerPrefix: gitArgumentPrefix,
            budget: &budget
        ).output
        let localBranches = Self.lines(runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            at: root,
            executable: gitExecutable,
            callerPrefix: gitArgumentPrefix,
            budget: &budget
        ).output)
        let remoteBranches = Self.lines(runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes"],
            at: root,
            executable: gitExecutable,
            callerPrefix: gitArgumentPrefix,
            budget: &budget
        ).output)
        .filter { !$0.hasSuffix("/HEAD") }
        let remotes = Self.lines(runGit(
            ["remote"],
            at: root,
            executable: gitExecutable,
            callerPrefix: gitArgumentPrefix,
            budget: &budget
        ).output)
        let worktrees = Self.lines(runGit(
            ["worktree", "list", "--porcelain"],
            at: root,
            executable: gitExecutable,
            callerPrefix: gitArgumentPrefix,
            budget: &budget
        ).output)
        .filter { $0.hasPrefix("worktree ") }

        return HarvisGenericGitSummary(
            inspectedPath: path,
            repositoryRoot: root,
            branch: branch.isEmpty ? nil : branch,
            isDetached: isDetached,
            changedFileCount: Self.lines(status).count,
            localBranches: localBranches,
            remoteBranches: remoteBranches,
            remotes: remotes,
            worktreeCount: worktrees.count
        )
    }

    private func runGit(
        _ arguments: [String],
        at path: String,
        executable: String,
        callerPrefix: [String],
        budget: inout InspectionBudget
    ) -> CommandResult {
        guard let remaining = budget.remaining else { return .failed }
        do {
            let result = try runner.runSynchronously(HarvisVersionProcessRequest(
                executable: executable,
                arguments: callerPrefix + Self.safePrefix + ["-C", path] + arguments,
                environment: Self.gitEnvironment,
                timeout: remaining,
                standardOutputLimit: 1_048_576,
                standardErrorLimit: 1_048_576,
                aggregateBytesBefore: budget.capturedBytes,
                aggregateLimit: 4_194_304
            ))
            budget.capturedBytes += result.capturedByteCount
            guard let output = String(data: result.standardOutput, encoding: .utf8) else {
                return .failed
            }
            return CommandResult(
                status: result.terminationStatus,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return .failed
        }
    }

    private static func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static let safePrefix = [
        "--no-pager",
        "--no-replace-objects",
        "--no-optional-locks",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "protocol.allow=never",
    ]

    private static let gitEnvironment = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/var/empty",
        "XDG_CONFIG_HOME": "/var/empty",
        "LC_ALL": "C",
        "LANG": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
    ]
}

private struct InspectionBudget {
    let deadline: TimeInterval
    var capturedBytes = 0

    init(timeout: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }

    var remaining: TimeInterval? {
        let value = deadline - ProcessInfo.processInfo.systemUptime
        return value.isFinite && value > 0 ? value : nil
    }
}

private struct CommandResult {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }

    static let failed = Self(status: -1, output: "")
}
