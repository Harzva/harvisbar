import AppKit
import Combine
import Foundation
import HarvisProxyCore

@MainActor
final class PerAppProxyModel: ObservableObject {
    @Published private(set) var configuration: PerAppProxyConfiguration
    @Published private(set) var launcherState: AgyLauncherState = .stopped
    @Published private(set) var lastError: String?
    @Published private(set) var refreshRevision = 0

    private let store: PerAppProxyStore
    private let inspector: CodeIdentityInspector
    private let launcher: AgyLauncherController
    private var agyExecutableURL: URL?

    init(
        store: PerAppProxyStore = PerAppProxyStore(),
        inspector: CodeIdentityInspector = CodeIdentityInspector(),
        launcher: AgyLauncherController = AgyLauncherController()
    ) {
        self.store = store
        self.inspector = inspector
        self.launcher = launcher
        self.agyExecutableURL = inspector.locateCommand(named: "agy")
        do {
            self.configuration = try store.load() ?? Self.defaultConfiguration()
        } catch {
            self.configuration = Self.fallbackConfiguration()
            self.lastError = error.localizedDescription
        }
        addAgyPresetIfAvailable()
        refreshLauncherState()
    }

    var canEnable: Bool { agyExecutableURL != nil }

    var isLauncherRunning: Bool {
        if case .running = launcherState { return true }
        return false
    }

    var primaryRule: PerAppProxyRule? {
        configuration.rules.first(where: { $0.isEnabled }) ?? configuration.rules.first
    }

    var statusLabel: String {
        if let lastError, !lastError.isEmpty { return lastError }
        switch launcherState {
        case .stopped: return canEnable ? "就绪 · 仅 agy 使用代理，不启用 TUN" : "找不到 agy 命令"
        case .launching: return "正在通过 Terminal 启动 agy…"
        case let .running(pid): return "agy 运行中 · PID \(pid) · 无 TUN"
        case let .failed(message): return message
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try launcher.launch(
                    executableURL: agyExecutableURL,
                    endpoint: configuration.endpoint
                )
            } else {
                try launcher.stop(executableURL: agyExecutableURL)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        syncLauncherState()
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择需要单独代理的应用或命令"
        panel.prompt = "加入规则"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addApplication(at: url)
    }

    func addApplication(at url: URL) {
        do {
            let identity = try inspector.inspect(url)
            configuration.rules.removeAll {
                $0.application.signingIdentifier == identity.signingIdentifier
                    && $0.application.codeDirectoryHash == identity.codeDirectoryHash
            }
            configuration.rules.insert(.init(application: identity), at: 0)
            lastError = nil
            persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeRule(id: UUID) {
        configuration.rules.removeAll { $0.id == id }
        persist()
    }

    func refreshLauncherState() {
        defer { refreshRevision &+= 1 }
        agyExecutableURL = inspector.locateCommand(named: "agy")
        launcherState = launcher.refresh(executableURL: agyExecutableURL)
        if canEnable {
            if case .failed = launcherState {
                // Preserve the actionable launcher error.
            } else {
                lastError = nil
            }
        }
        if configuration.isEnabled != isLauncherRunning {
            configuration.isEnabled = isLauncherRunning
            persist()
        }
    }

    private func addAgyPresetIfAvailable() {
        guard configuration.rules.isEmpty,
              let agyURL = inspector.locateCommand(named: "agy")
        else { return }
        addApplication(at: agyURL)
    }

    private func persist() {
        do {
            try store.save(configuration)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func syncLauncherState() {
        launcherState = launcher.state
        configuration.isEnabled = isLauncherRunning
        persist()
    }

    private static func defaultConfiguration() throws -> PerAppProxyConfiguration {
        try PerAppProxyConfiguration(
            isEnabled: false,
            endpoint: ProxyEndpoint(host: "127.0.0.1", port: 7890)
        )
    }

    private static func fallbackConfiguration() -> PerAppProxyConfiguration {
        // Literal values are compile-time valid; retain a non-throwing recovery path for corrupt local state.
        try! defaultConfiguration()
    }
}
