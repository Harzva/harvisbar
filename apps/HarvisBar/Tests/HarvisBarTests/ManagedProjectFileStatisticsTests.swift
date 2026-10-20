import Foundation
import XCTest
@testable import HarvisBar

private func inProcessStatisticsResult(
    arguments: [String]
) throws -> BoundedProcessResult {
    guard let invocation = ManagedProjectFileStatisticsHelper.invokeIfRequested(
        arguments: ["HarvisBar"] + arguments
    ) else {
        throw ManagedProjectFileStatisticsError.invalidHelperResponse(
            "The helper mode was not selected."
        )
    }
    return BoundedProcessResult(
        standardOutput: String(decoding: invocation.standardOutput, as: UTF8.self),
        standardError: String(decoding: invocation.standardError, as: UTF8.self),
        terminationStatus: invocation.exitCode
    )
}

private actor ControlledStatisticsRunner {
    enum FirstBehavior: Sendable {
        case blocked
        case process
    }

    private let firstBehavior: FirstBehavior
    private var count = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(firstBehavior: FirstBehavior) {
        self.firstBehavior = firstBehavior
    }

    var invocationCount: Int { count }

    func run(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> BoundedProcessResult {
        count += 1
        if count == 1 {
            switch firstBehavior {
            case .blocked:
                await withCheckedContinuation { continuation in
                    blockedContinuation = continuation
                }
            case .process:
                return try await BoundedProcessRunner.run(
                    executable: "/bin/sleep",
                    arguments: ["5"],
                    timeout: timeout
                )
            }
        }
        return try inProcessStatisticsResult(arguments: arguments)
    }

    func releaseBlockedRun() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

final class ManagedProjectFileStatisticsTests: XCTestCase {
    func testInspectorCountsProjectContentAndSkipsGeneratedDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Nested"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules/pkg"),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 4).write(
            to: root.appendingPathComponent("README.md")
        )
        try Data(repeating: 2, count: 6).write(
            to: root.appendingPathComponent("Sources/main.swift")
        )
        try Data(repeating: 3, count: 100).write(
            to: root.appendingPathComponent("node_modules/pkg/cache.bin")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("sources-link"),
            withDestinationURL: root.appendingPathComponent("Sources")
        )

        let statistics = try ManagedProjectFileInspector.inspect(path: root.path)

        XCTAssertEqual(statistics.folderCount, 2)
        XCTAssertEqual(statistics.fileCount, 2)
        XCTAssertEqual(statistics.symbolicLinkCount, 1)
        XCTAssertEqual(statistics.totalBytes, 10)
        XCTAssertEqual(statistics.excludedDirectoryCount, 1)
        XCTAssertFalse(statistics.isTruncated)
    }

    func testInspectorStopsAtEntryLimitAndReportsTruncation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            try Data("\(index)".utf8).write(
                to: root.appendingPathComponent("file-\(index).txt")
            )
        }

        let statistics = try ManagedProjectFileInspector.inspect(
            path: root.path,
            maximumEntries: 2
        )

        XCTAssertEqual(statistics.scannedEntryCount, 2)
        XCTAssertEqual(statistics.fileCount, 2)
        XCTAssertTrue(statistics.isTruncated)
    }

    func testInspectorRejectsMissingProjectDirectory() {
        let missing = "/private/tmp/harvis-missing-project-\(UUID().uuidString)"
        XCTAssertThrowsError(
            try ManagedProjectFileInspector.inspect(path: missing)
        ) { error in
            guard let typed = error as? ManagedProjectFileStatisticsError,
                  case let .projectNotDirectory(path) = typed else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, missing)
        }
    }

    func testHiddenHelperRoundTripsRawProjectPathAsJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Harvis helper 路径 with spaces-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("hello.txt"))

        let invocation = try XCTUnwrap(
            ManagedProjectFileStatisticsHelper.invokeIfRequested(
                arguments: [
                    "/Applications/HarvisBar.app/Contents/MacOS/HarvisBar",
                    ManagedProjectFileStatisticsHelper.argument,
                    root.path,
                ]
            )
        )

        XCTAssertEqual(invocation.exitCode, 0)
        XCTAssertTrue(invocation.standardError.isEmpty)
        let decoded = try ManagedProjectFileStatisticsHelper.decodeStatistics(
            from: invocation.standardOutput
        )
        XCTAssertEqual(decoded.fileCount, 1)
        XCTAssertEqual(
            decoded.projectPath,
            root.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    @MainActor
    func testStoreCachesUntilForcedRefresh() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        let project = ManagedChatProjectResolver.resolve(
            cwd: root.path,
            fallbackID: "fixture"
        )
        let store = ManagedProjectFileStatisticsStore(
            cacheLifetime: 3_600,
            processRunner: { _, arguments, _ in
                try inProcessStatisticsResult(arguments: arguments)
            }
        )

        await store.refresh(project: project)
        XCTAssertEqual(store.statistics(for: project)?.fileCount, 1)

        try Data("two".utf8).write(to: root.appendingPathComponent("two.txt"))
        await store.refresh(project: project)
        XCTAssertEqual(store.statistics(for: project)?.fileCount, 1)

        await store.refresh(project: project, force: true)
        XCTAssertEqual(store.statistics(for: project)?.fileCount, 2)
    }

    @MainActor
    func testForcedRefreshRemainsSingleFlight() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        let project = ManagedChatProjectResolver.resolve(
            cwd: root.path,
            fallbackID: "fixture"
        )
        let runner = ControlledStatisticsRunner(firstBehavior: .blocked)
        let store = ManagedProjectFileStatisticsStore(
            helperTimeout: 2,
            processRunner: { _, arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let firstRefresh = Task {
            await store.refresh(project: project, force: true)
        }
        try await waitForInvocationCount(1, runner: runner)
        XCTAssertTrue(store.scanningProjectIDs.contains(project.id))

        await store.refresh(project: project, force: true)
        let singleFlightInvocationCount = await runner.invocationCount
        XCTAssertEqual(singleFlightInvocationCount, 1)

        await runner.releaseBlockedRun()
        await firstRefresh.value
        XCTAssertFalse(store.scanningProjectIDs.contains(project.id))
        XCTAssertEqual(store.statistics(for: project)?.fileCount, 1)
    }

    @MainActor
    func testTimeoutClearsScanningStateAndLaterForceCanRetry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        let project = ManagedChatProjectResolver.resolve(
            cwd: root.path,
            fallbackID: "fixture"
        )
        let runner = ControlledStatisticsRunner(firstBehavior: .process)
        let store = ManagedProjectFileStatisticsStore(
            helperTimeout: 0.05,
            processRunner: { _, arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        await store.refresh(project: project, force: true)

        XCTAssertFalse(store.scanningProjectIDs.contains(project.id))
        XCTAssertNil(store.statistics(for: project))
        XCTAssertTrue(store.errors[project.id]?.contains("超过 0.05 秒") == true)
        XCTAssertTrue(store.errors[project.id]?.contains("已停止并回收") == true)

        await store.refresh(project: project, force: true)
        let retryInvocationCount = await runner.invocationCount
        XCTAssertEqual(retryInvocationCount, 2)
        XCTAssertEqual(store.statistics(for: project)?.fileCount, 1)
        XCTAssertNil(store.errors[project.id])
    }

    @MainActor
    func testCancellationClearsScanningStateAndLaterForceCanRetry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        let project = ManagedChatProjectResolver.resolve(
            cwd: root.path,
            fallbackID: "fixture"
        )
        let runner = ControlledStatisticsRunner(firstBehavior: .process)
        let store = ManagedProjectFileStatisticsStore(
            helperTimeout: 2,
            processRunner: { _, arguments, timeout in
                try await runner.run(arguments: arguments, timeout: timeout)
            }
        )

        let refresh = Task {
            await store.refresh(project: project, force: true)
        }
        try await waitForInvocationCount(1, runner: runner)
        XCTAssertTrue(store.scanningProjectIDs.contains(project.id))
        refresh.cancel()
        await refresh.value

        XCTAssertFalse(store.scanningProjectIDs.contains(project.id))
        XCTAssertNil(store.statistics(for: project))

        await store.refresh(project: project, force: true)
        let retryInvocationCount = await runner.invocationCount
        XCTAssertEqual(retryInvocationCount, 2)
        XCTAssertEqual(store.statistics(for: project)?.fileCount, 1)
    }

    @MainActor
    private func waitForInvocationCount(
        _ expected: Int,
        runner: ControlledStatisticsRunner
    ) async throws {
        for _ in 0..<100 {
            if await runner.invocationCount >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for process runner invocation \(expected).")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ManagedProjectFileStatisticsTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
