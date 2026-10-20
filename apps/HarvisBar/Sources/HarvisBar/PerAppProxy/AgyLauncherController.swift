import Darwin
import Foundation
import HarvisProxyCore

enum AgyLauncherState: Equatable {
    case stopped
    case launching
    case running(pid: pid_t)
    case failed(String)
}

enum AgyLauncherError: Error, LocalizedError {
    case commandUnavailable
    case terminalLaunchFailed(String)
    case processIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            return "找不到 agy 命令"
        case let .terminalLaunchFailed(message):
            return "无法启动 agy：\(message)"
        case .processIdentityMismatch:
            return "已拒绝终止：记录的 PID 不属于 agy"
        }
    }
}

struct AgyLauncherCommandBuilder {
    static func proxyURL(for endpoint: ProxyEndpoint) -> String {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        return "socks5h://\(host):\(endpoint.port)"
    }

    static func terminalCommand(
        executableURL: URL,
        endpoint: ProxyEndpoint,
        pidFileURL: URL,
        workingDirectoryURL: URL
    ) -> String {
        let proxyURL = proxyURL(for: endpoint)
        let noProxy = "localhost,127.0.0.1,::1"
        let environment = [
            "ALL_PROXY=\(proxyURL)",
            "all_proxy=\(proxyURL)",
            "HTTPS_PROXY=\(proxyURL)",
            "https_proxy=\(proxyURL)",
            "HTTP_PROXY=\(proxyURL)",
            "http_proxy=\(proxyURL)",
            "NO_PROXY=\(noProxy)",
            "no_proxy=\(noProxy)",
            "HARVIS_LAUNCHER=1",
        ]

        return [
            "umask 077",
            "mkdir -p \(shellQuote(pidFileURL.deletingLastPathComponent().path))",
            "printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path))",
            "cd \(shellQuote(workingDirectoryURL.path))",
            "exec env \(environment.map(shellQuote).joined(separator: " ")) \(shellQuote(executableURL.path))",
        ].joined(separator: "; ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class AgyLauncherController {
    private static let terminalAppleScript = """
    on run argv
        set launchCommand to item 1 of argv
        tell application "Terminal"
            activate
            do script launchCommand
        end tell
    end run
    """

    private(set) var state: AgyLauncherState = .stopped
    let pidFileURL: URL

    init(pidFileURL: URL? = nil) {
        self.pidFileURL = pidFileURL ?? Self.defaultPIDFileURL()
    }

    @discardableResult
    func refresh(executableURL: URL?) -> AgyLauncherState {
        guard let executableURL, let pid = recordedPID() else {
            state = .stopped
            return state
        }
        guard processMatches(pid: pid, executableURL: executableURL) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            state = .stopped
            return state
        }
        state = .running(pid: pid)
        return state
    }

    func launch(executableURL: URL?, endpoint: ProxyEndpoint) throws {
        guard let executableURL else { throw AgyLauncherError.commandUnavailable }
        if case .running = refresh(executableURL: executableURL) { return }

        try FileManager.default.createDirectory(
            at: pidFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(at: pidFileURL)
        state = .launching

        let terminalCommand = AgyLauncherCommandBuilder.terminalCommand(
            executableURL: executableURL,
            endpoint: endpoint,
            pidFileURL: pidFileURL,
            workingDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.terminalAppleScript, terminalCommand]
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = message?.isEmpty == false ? message! : "Terminal 返回错误 \(process.terminationStatus)"
            state = .failed(detail)
            throw AgyLauncherError.terminalLaunchFailed(detail)
        }

        // Terminal writes the shell PID immediately before `exec agy`. Wait
        // until proc_pidpath observes the executable transition, otherwise a
        // fast refresh can mistake the short-lived zsh path for a stale PID.
        for _ in 0..<40 {
            if let pid = recordedPID(), processMatches(pid: pid, executableURL: executableURL) {
                state = .running(pid: pid)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        state = .failed("Terminal 已打开，但没有取得 agy PID")
        throw AgyLauncherError.terminalLaunchFailed("没有取得 agy PID")
    }

    func stop(executableURL: URL?) throws {
        guard let executableURL, let pid = recordedPID() else {
            state = .stopped
            return
        }
        if Darwin.kill(pid, 0) != 0, errno == ESRCH {
            try? FileManager.default.removeItem(at: pidFileURL)
            state = .stopped
            return
        }
        guard processMatches(pid: pid, executableURL: executableURL) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            state = .stopped
            throw AgyLauncherError.processIdentityMismatch
        }

        guard Darwin.kill(pid, SIGTERM) == 0 else {
            let message = String(cString: strerror(errno))
            state = .failed(message)
            throw AgyLauncherError.terminalLaunchFailed(message)
        }
        try? FileManager.default.removeItem(at: pidFileURL)
        state = .stopped
    }

    private func recordedPID() -> pid_t? {
        guard let value = try? String(contentsOf: pidFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(value),
              pid > 1
        else { return nil }
        return pid
    }

    private func processMatches(pid: pid_t, executableURL: URL) -> Bool {
        guard Darwin.kill(pid, 0) == 0 else { return false }
        // proc_pidpath documents a 4 * MAXPATHLEN buffer. The SDK macro is not
        // imported into Swift, so retain its stable 4096-byte ABI value here.
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let runningPath = URL(
            fileURLWithPath: String(decoding: bytes, as: UTF8.self)
        ).resolvingSymlinksInPath().path
        return runningPath == executableURL.resolvingSymlinksInPath().path
    }

    private static func defaultPIDFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("HarvisBar/Launcher", isDirectory: true)
            .appendingPathComponent("agy.pid", isDirectory: false)
    }
}
