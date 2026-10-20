import Darwin
import Foundation
import HarvisVersionCore
import XCTest
@testable import HarvisBar

final class ProjectGitMetadataTests: XCTestCase {
    func testInspectorDistinguishesPlainDirectoriesAndGitStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-git-\(UUID().uuidString)")
        let plain = root.appendingPathComponent("plain")
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(ProjectGitInspector.inspect(path: plain.path).isRepository)

        try runGit(["init", "-b", "main"], at: repository)
        let readme = repository.appendingPathComponent("README.md")
        try "initial\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], at: repository)
        try runGit(
            [
                "-c", "user.name=Harvis Test",
                "-c", "user.email=harvis@example.invalid",
                "commit", "-m", "initial"
            ],
            at: repository
        )

        let clean = ProjectGitInspector.inspect(path: repository.path)
        XCTAssertTrue(clean.isRepository)
        XCTAssertEqual(clean.branch, "main")
        XCTAssertEqual(clean.localBranches, ["main"])
        XCTAssertEqual(clean.worktreeCount, 1)
        XCTAssertFalse(clean.isDirty)

        try "changed\n".write(to: readme, atomically: true, encoding: .utf8)
        let dirty = ProjectGitInspector.inspect(path: repository.path)
        XCTAssertTrue(dirty.isDirty)
        XCTAssertEqual(dirty.changedFileCount, 1)

        let core = HarvisGenericGitInspector().inspect(path: repository.path)
        XCTAssertEqual(core.repositoryRoot, dirty.repositoryRoot)
        XCTAssertEqual(core.branch, dirty.branch)
        XCTAssertEqual(core.isDetached, dirty.isDetached)
        XCTAssertEqual(core.changedFileCount, dirty.changedFileCount)
        XCTAssertEqual(core.localBranches, dirty.localBranches)
        XCTAssertEqual(core.remoteBranches, dirty.remoteBranches)
        XCTAssertEqual(core.remotes, dirty.remotes)
        XCTAssertEqual(core.worktreeCount, dirty.worktreeCount)
    }

    func testInspectorBoundsHungGitAndProjectsUnavailableSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-hung-git-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        let pidFile = root.appendingPathComponent("git.pid")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let program = """
        import os, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(sys.argv[1], "w") as stream:
            stream.write(str(os.getpid()))
            stream.flush()
        time.sleep(60)
        """

        let startedAt = ProcessInfo.processInfo.systemUptime
        let summary = ProjectGitInspector.inspect(
            path: project.path,
            timeout: 0.2,
            gitExecutable: "/usr/bin/python3",
            gitArgumentPrefix: ["-c", program, pidFile.path]
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertFalse(summary.isRepository)
        XCTAssertNil(summary.repositoryRoot)
        XCTAssertLessThan(elapsed, 2, "Git metadata refresh must not block the GUI indefinitely")

        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(rawPID))
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let result = try BoundedProcessRunner.runSynchronously(
            executable: "/usr/bin/git",
            arguments: ["-C", directory.path] + arguments,
            timeout: 5
        )
        XCTAssertEqual(result.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
