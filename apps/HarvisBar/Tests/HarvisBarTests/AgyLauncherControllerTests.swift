import HarvisProxyCore
import XCTest
@testable import HarvisBar

final class AgyLauncherControllerTests: XCTestCase {
    func testCommandInjectsOnlyProcessScopedSOCKSProxyAndRecordsPID() throws {
        let endpoint = try ProxyEndpoint(host: "127.0.0.1", port: 7890)
        let command = AgyLauncherCommandBuilder.terminalCommand(
            executableURL: URL(fileURLWithPath: "/tmp/agy test"),
            endpoint: endpoint,
            pidFileURL: URL(fileURLWithPath: "/tmp/Harvis Launcher/agy.pid"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/Work Space")
        )

        XCTAssertTrue(command.contains("'ALL_PROXY=socks5h://127.0.0.1:7890'"))
        XCTAssertTrue(command.contains("'all_proxy=socks5h://127.0.0.1:7890'"))
        XCTAssertTrue(command.contains("'HTTPS_PROXY=socks5h://127.0.0.1:7890'"))
        XCTAssertTrue(command.contains("'https_proxy=socks5h://127.0.0.1:7890'"))
        XCTAssertTrue(command.contains("'HTTP_PROXY=socks5h://127.0.0.1:7890'"))
        XCTAssertTrue(command.contains("'http_proxy=socks5h://127.0.0.1:7890'"))
        XCTAssertTrue(command.contains("printf '%s\\n' \"$$\""))
        XCTAssertTrue(command.contains("exec env"))
        XCTAssertTrue(command.contains("'/tmp/agy test'"))
        XCTAssertFalse(command.contains("networksetup"))
    }

    func testIPv6ProxyURLUsesBrackets() throws {
        let endpoint = try ProxyEndpoint(host: "::1", port: 7890)
        XCTAssertEqual(AgyLauncherCommandBuilder.proxyURL(for: endpoint), "socks5h://[::1]:7890")
    }

    @MainActor
    func testStopTreatsAnExitedRecordedProcessAsStopped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFileURL = directory.appendingPathComponent("agy.pid")
        try "999999\n".write(to: pidFileURL, atomically: true, encoding: .utf8)
        let controller = AgyLauncherController(pidFileURL: pidFileURL)

        try controller.stop(executableURL: URL(fileURLWithPath: "/usr/bin/true"))

        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFileURL.path))
    }
}
