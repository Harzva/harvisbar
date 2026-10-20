import Darwin
import Foundation
import XCTest
@testable import HarvisBar
@testable import HarvisVersionCore

final class ProcessTransportTests: XCTestCase {
    func testRawRunnerRejectsInvalidGracePeriodsBeforeSpawn() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-invalid-grace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let cases: [(String, TimeInterval, TimeInterval)] = [
            ("termination", -0.01, 1),
            ("termination", .infinity, 1),
            ("termination", .nan, 1),
            ("kill", 0.1, -0.01),
            ("kill", 0.1, -.infinity),
            ("kill", 0.1, .nan),
        ]
        for (expectedName, terminationGrace, killGrace) in cases {
            XCTAssertThrowsError(try HarvisVersionProcessRunner.runSynchronously(
                HarvisVersionProcessRequest(
                    executable: "/usr/bin/python3",
                    arguments: [
                        "-c",
                        "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('spawned')",
                        marker.path,
                    ],
                    environment: [:],
                    timeout: 2,
                    terminationGracePeriod: terminationGrace,
                    killGracePeriod: killGrace
                )
            )) { error in
                guard case let .invalidGracePeriod(name, _) = error as? HarvisVersionProcessError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(name, expectedName)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: marker.path),
                "Invalid grace input must be rejected before the child is spawned"
            )
        }

        let zeroGrace = try HarvisVersionProcessRunner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/usr/bin/true",
                arguments: [],
                environment: [:],
                timeout: 2,
                terminationGracePeriod: 0,
                killGracePeriod: 0
            )
        )
        XCTAssertEqual(zeroGrace.terminationStatus, 0)
    }

    func testAnonymousCaptureUnlinkFailureIsFailClosedBeforeSpawn() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-unlink-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = HarvisVersionProcessRunner(captureUnlink: { path in
            // Remove the synthetic named capture to avoid test residue, then
            // report failure to exercise the production fail-closed branch.
            _ = path.withCString { Darwin.unlink($0) }
            return -1
        })

        XCTAssertThrowsError(try runner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/usr/bin/python3",
                arguments: [
                    "-c",
                    "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('spawned')",
                    marker.path,
                ],
                environment: [:],
                timeout: 2
            )
        )) { error in
            guard case .ioFailure = error as? HarvisVersionProcessError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "A named capture must never be tolerated by launching the child"
        )
    }

    func testRawRunnerPreservesNonUTF8AndUsesExactEnvironment() throws {
        let program = """
        import os, sys
        sys.stdout.buffer.write(bytes([0xff, 0x00, 0x41]))
        sys.stderr.write(os.environ.get("ONLY_THIS", "missing"))
        sys.stderr.write("|" + os.environ.get("PATH", "absent"))
        """
        let result = try HarvisVersionProcessRunner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/usr/bin/python3",
                arguments: ["-c", program],
                environment: ["ONLY_THIS": "yes"],
                timeout: 2
            )
        )

        XCTAssertEqual(result.standardOutput, Data([0xff, 0x00, 0x41]))
        XCTAssertEqual(result.standardError, Data("yes|absent".utf8))
        XCTAssertEqual(result.capturedByteCount, 13)
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testLegacyStringFacadeKeepsInvalidUTF8AsEmptyString() throws {
        let result = try BoundedProcessRunner.runSynchronously(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import sys; sys.stdout.buffer.write(bytes([0xff]))"],
            timeout: 2
        )
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testRawRunnerSuppliesEOFAndBorrowedFDCWD() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-fd-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = Darwin.close(fd) }

        let program = """
        import os, sys
        payload = sys.stdin.buffer.read()
        sys.stdout.write(os.getcwd() + "|" + str(len(payload)))
        """
        let result = try HarvisVersionProcessRunner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/usr/bin/python3",
                arguments: ["-c", program],
                environment: [:],
                workingDirectoryFileDescriptor: fd,
                timeout: 2
            )
        )
        var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        XCTAssertNotNil(Darwin.realpath(directory.path, &canonicalBuffer))
        let canonicalEnd = canonicalBuffer.firstIndex(of: 0) ?? canonicalBuffer.endIndex
        let canonicalDirectory = String(
            decoding: canonicalBuffer[..<canonicalEnd].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        XCTAssertEqual(
            String(data: result.standardOutput, encoding: .utf8),
            canonicalDirectory + "|0"
        )
    }

    func testRawRunnerClosesUnlistedParentFDAndRestoresSignalDefaults() throws {
        let canary = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(canary, 2)
        defer { _ = Darwin.close(canary) }
        let program = """
        import fcntl, signal, sys
        try:
            fcntl.fcntl(int(sys.argv[1]), fcntl.F_GETFD)
            inherited = "yes"
        except OSError:
            inherited = "no"
        defaulted = signal.getsignal(signal.SIGTERM) == signal.SIG_DFL
        sys.stdout.write(inherited + "|" + str(defaulted).lower())
        """
        let result = try HarvisVersionProcessRunner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/usr/bin/python3",
                arguments: ["-c", program, String(canary)],
                environment: [:],
                timeout: 2
            )
        )
        XCTAssertEqual(result.standardOutput, Data("no|true".utf8))
    }

    func testRawRunnerEnforcesExactPerStreamAndAggregateCaps() throws {
        let exact = try HarvisVersionProcessRunner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/usr/bin/python3",
                arguments: ["-c", "import sys; sys.stdout.write('x' * 16); sys.stderr.write('y' * 8)"],
                environment: [:],
                timeout: 2,
                standardOutputLimit: 16,
                standardErrorLimit: 8,
                aggregateBytesBefore: 8,
                aggregateLimit: 32
            )
        )
        XCTAssertEqual(exact.capturedByteCount, 24)

        XCTAssertThrowsError(try HarvisVersionProcessRunner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/usr/bin/python3",
                arguments: ["-c", "import sys; sys.stdout.write('x' * 17)"],
                environment: [:],
                timeout: 2,
                standardOutputLimit: 16,
                standardErrorLimit: 8
            )
        )) { error in
            guard case .outputLimitExceeded = error as? HarvisVersionProcessError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try HarvisVersionProcessRunner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/usr/bin/python3",
                arguments: ["-c", "import sys; sys.stdout.write('x' * 16); sys.stderr.write('y' * 8)"],
                environment: [:],
                timeout: 2,
                standardOutputLimit: 16,
                standardErrorLimit: 8,
                aggregateBytesBefore: 9,
                aggregateLimit: 32
            )
        )) { error in
            guard case .outputLimitExceeded = error as? HarvisVersionProcessError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRawRunnerTimeoutTerminatesEntireChildProcessGroup() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-process-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let program = """
        /bin/sleep 60 &
        printf '%s %s' "$$" "$!" > "$1"
        wait
        """

        XCTAssertThrowsError(try HarvisVersionProcessRunner.runSynchronously(
            HarvisVersionProcessRequest(
                executable: "/bin/sh",
                arguments: ["-c", program, "harvis-process-group", pidFile.path],
                environment: [:],
                timeout: 0.25,
                terminationGracePeriod: 0.15,
                killGracePeriod: 1
            )
        )) { error in
            guard case .timedOut = error as? HarvisVersionProcessError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let values = try String(contentsOf: pidFile, encoding: .utf8)
            .split(separator: " ")
            .compactMap { Int32($0) }
        XCTAssertEqual(values.count, 2)
        for pid in values {
            errno = 0
            XCTAssertEqual(Darwin.kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH, "leader and descendant must both be absent")
        }
    }

    @MainActor
    func testRunProcessDrainsOutputLargerThanPipeBuffer() async throws {
        let defaults = UserDefaults(suiteName: "ProcessTransportTests")!
        defaults.removePersistentDomain(forName: "ProcessTransportTests")
        let model = HarvisRuntimeModel(defaults: defaults)

        let output = try await model.runProcess(
            "/usr/bin/python3",
            ["-c", "print('x' * 262144)"]
        )

        XCTAssertEqual(output.count, 262145)
    }

    func testCatalogCanOptIntoLargerBoundedOutputWithoutChangingDefault() async throws {
        let arguments = ["-c", "import sys; sys.stdout.write('x' * 1200000)"]
        let output = try await BoundedProcessRunner.run(
            executable: "/usr/bin/python3", arguments: arguments,
            standardOutputLimit: 8_388_608
        )
        XCTAssertEqual(output.standardOutput.count, 1_200_000)
        do {
            _ = try await BoundedProcessRunner.run(executable: "/usr/bin/python3", arguments: arguments)
            XCTFail("Default output cap must remain enforced")
        } catch { }
    }

    func testAnonymousCaptureHasNoNamedCrashResidue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-anonymous-capture-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureURL = directory.appendingPathComponent("stdout")

        let handle = try BoundedProcessRunner.makeAnonymousCapture(at: captureURL)
        defer { try? handle.close() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
        try handle.write(contentsOf: Data("private-output".utf8))
        try handle.seek(toOffset: 0)
        XCTAssertEqual(try handle.readToEnd(), Data("private-output".utf8))
    }

    @MainActor
    func testRunProcessTimesOutAndTerminatesChild() async throws {
        let model = makeModel(suite: #function)
        let startedAt = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await model.runProcess(
                "/bin/sleep",
                ["60"],
                timeout: 0.1
            )
            XCTFail("Expected the child to time out")
        } catch let error as BoundedProcessRunnerError {
            guard case let .timedOut(executable, timeout) = error else {
                return XCTFail("Unexpected process error: \(error)")
            }
            XCTAssertEqual(executable, "/bin/sleep")
            XCTAssertEqual(timeout, 0.1, accuracy: 0.001)
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }

        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            2,
            "Timeout handling must remain bounded"
        )
    }

    @MainActor
    func testRunProcessForceKillsTermIgnoringChildAndReapsIt() async throws {
        let model = makeModel(suite: #function)
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-process-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let program = """
        import os, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(sys.argv[1], "w") as stream:
            stream.write(str(os.getpid()))
            stream.flush()
        time.sleep(60)
        """

        do {
            _ = try await model.runProcess(
                "/usr/bin/python3",
                ["-c", program, pidFile.path],
                timeout: 0.2
            )
            XCTFail("Expected the child to time out")
        } catch let error as BoundedProcessRunnerError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected process error: \(error)")
            }
        }

        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(rawPID))
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "The timed-out child must not survive")
        XCTAssertEqual(errno, ESRCH, "The timed-out child must be reaped, not left as a zombie")
    }

    @MainActor
    func testCancellingRunProcessTerminatesChild() async throws {
        let model = makeModel(suite: #function)
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-cancelled-process-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let program = """
        import os, sys, time
        with open(sys.argv[1], "w") as stream:
            stream.write(str(os.getpid()))
            stream.flush()
        time.sleep(60)
        """
        let task = Task {
            try await model.runProcess(
                "/usr/bin/python3",
                ["-c", program, pidFile.path],
                timeout: 30
            )
        }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pidFile.path),
            "The child must launch before cancellation is tested"
        )
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to terminate the child")
        } catch let error as BoundedProcessRunnerError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected process error: \(error)")
            }
        }

        let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(rawPID))
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "The cancelled child must not survive")
        XCTAssertEqual(errno, ESRCH, "The cancelled child must be reaped")
    }

    @MainActor
    private func makeModel(suite: String) -> HarvisRuntimeModel {
        let suiteName = "ProcessTransportTests.\(suite)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HarvisRuntimeModel(defaults: defaults)
    }
}
