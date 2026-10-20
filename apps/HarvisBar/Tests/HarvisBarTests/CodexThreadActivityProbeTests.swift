import Darwin
import Foundation
import XCTest
@testable import HarvisBar

final class CodexThreadActivityProbeTests: XCTestCase {
    func testDefaultTimeoutAllowsBoundedColdAppServerStartup() {
        let probe = CodexCLIThreadActivityProbe(executablePath: "/fixture/harvis")
        XCTAssertEqual(probe.timeoutSeconds, 30)
    }

    func testMissingThreadIsUnknownRatherThanIdle() async throws {
        let fixture = try makeExecutable(
            "#!/bin/sh\nprintf '%s\\n' '{\"ok\":true,\"items\":[{\"id\":\"other\",\"running\":false}]}'\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let probe = CodexCLIThreadActivityProbe(
            executablePath: fixture.executable.path,
            timeoutSeconds: 8
        )
        do {
            _ = try await probe.isThreadRunning(
                homePath: fixture.root.path,
                threadID: "target"
            )
            XCTFail("A thread omitted from a bounded result set must not be treated as idle")
        } catch let error as CodexThreadActivityProbeError {
            guard case let .threadNotListed(threadID, limit) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(threadID, "target")
            XCTAssertEqual(limit, CodexCLIThreadActivityProbe.resultLimit)
        }
    }

    func testHungProbeTimesOut() async throws {
        let fixture = try makeExecutable("#!/bin/sh\nexec /bin/sleep 2\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let probe = CodexCLIThreadActivityProbe(
            executablePath: fixture.executable.path,
            timeoutSeconds: 0.05
        )
        do {
            _ = try await probe.isThreadRunning(
                homePath: fixture.root.path,
                threadID: "target"
            )
            XCTFail("A hung activity probe must time out")
        } catch let error as CodexThreadActivityProbeError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTimeoutCleanupForceKillsAndReapsReadyChildIgnoringTermination() throws {
        let fixture = try makeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' "$$" > "${0%/*}/pid"
            trap '' TERM
            exec /bin/sleep 10
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let process = Process()
        process.executableURL = fixture.executable
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
        try process.run()
        defer {
            CodexCLIThreadActivityProbe.terminateAndReap(
                process,
                exitSignal: exitSignal
            )
        }

        let pidURL = fixture.root.appendingPathComponent("pid")
        XCTAssertTrue(
            waitForFile(at: pidURL, timeout: 5),
            "The fixture must be ready before exercising timeout cleanup"
        )
        guard FileManager.default.fileExists(atPath: pidURL.path) else { return }

        let startedAt = Date()
        XCTAssertTrue(
            CodexCLIThreadActivityProbe.terminateAndReap(
                process,
                exitSignal: exitSignal
            ),
            "The force-killed child should be reaped within the bounded wait"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            2,
            "Timeout cleanup must remain bounded even when SIGTERM is ignored"
        )

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let processID = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(
            Darwin.kill(processID, 0),
            -1,
            "The force-killed child must be reaped before the probe returns"
        )
        XCTAssertEqual(errno, ESRCH)
    }

    func testExplicitThreadStateIsReturned() async throws {
        let fixture = try makeExecutable(
            "#!/bin/sh\nprintf '%s\\n' '{\"ok\":true,\"items\":[{\"id\":\"target\",\"running\":false}]}'\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let probe = CodexCLIThreadActivityProbe(
            executablePath: fixture.executable.path,
            timeoutSeconds: 8
        )
        let running = try await probe.isThreadRunning(
            homePath: fixture.root.path,
            threadID: "target"
        )
        XCTAssertFalse(running)
    }

    private func makeExecutable(
        _ source: String
    ) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexThreadActivityProbeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let executable = root.appendingPathComponent("probe.sh")
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return (root, executable)
    }

    private func waitForFile(
        at url: URL,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
