import Foundation

extension HarvisRuntimeModel {
    private static let catopRefreshInterval: TimeInterval = 30

    func refreshCatop(force: Bool = false) {
        Task { await refreshCatopStatus(force: force) }
    }

    func refreshCatopStatus(force: Bool = false) async {
        guard !isCatopRefreshing else { return }
        if !force,
           let lastCatopRefreshAt,
           Date().timeIntervalSince(lastCatopRefreshAt) < Self.catopRefreshInterval {
            return
        }

        isCatopRefreshing = true
        lastCatopRefreshAt = Date()
        defer { isCatopRefreshing = false }

        guard let invocation = catopInvocation(once: true) else {
            catopStatus = nil
            catopError = "Enter a command name or an absolute path for catop."
            return
        }

        do {
            let output = try await runProcess(invocation.executable, invocation.arguments)
            catopStatus = try JSONDecoder().decode(CatopStatus.self, from: Data(output.utf8))
            catopError = nil
        } catch {
            catopStatus = nil
            catopError = "catop status is unavailable. Check the command above, then refresh."
        }
    }

    func openCatopTerminal() {
        guard let invocation = catopInvocation(once: false) else {
            catopError = "Enter a command name or an absolute path for catop."
            return
        }
        let command = ([invocation.executable] + invocation.arguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")
        let script = "tell application \"Terminal\"\nactivate\ndo script \(Self.appleScriptQuoted(command))\nend tell"
        Task {
            do {
                _ = try await runProcess("/usr/bin/osascript", ["-e", script])
                lastActionOutput = "Opened catop in Terminal."
                catopError = nil
            } catch {
                catopError = "Terminal could not open catop. Check the command above."
            }
        }
    }

    private func catopInvocation(once: Bool) -> (executable: String, arguments: [String])? {
        let command = catopCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.contains(where: \.isWhitespace) else { return nil }
        let arguments = ["--agent", "codex", "--offline-prices", "--window", "today"]
            + (once ? ["--once", "--status-json"] : [])
        if command.contains("/") {
            return (expanded(command), arguments)
        }
        return ("/usr/bin/env", [command] + arguments)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
