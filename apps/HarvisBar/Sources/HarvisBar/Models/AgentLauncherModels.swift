import Foundation

enum AgentLaunchKind: String, CaseIterable, Hashable {
    case cli
    case desktop
}

enum AgentLaunchAvailability: String, Equatable {
    case available
    case running
    case missing
    case misconfigured
    case unsupported
    case unknown
}

enum AgentLaunchMode: String, Equatable {
    case newTerminalSession = "new-terminal-session"
    case activateOrOpen = "activate-or-open"
}

enum AgentWorkingDirectoryPolicy: String, Equatable {
    case workspaceRoot = "workspace-root"
    case none
}

struct AgentLaunchTarget: Identifiable, Equatable {
    let id: String
    let productID: String
    let launcherID: String
    let kind: AgentLaunchKind
    let label: String
    let subtitle: String
    let availability: AgentLaunchAvailability
    let availabilityReason: String
    let launchMode: AgentLaunchMode
    let workingDirectoryPolicy: AgentWorkingDirectoryPolicy
    let sourceStatusCode: String?
    let sourceSummary: String?

    /// A process-local resolution result. This value is never persisted or
    /// rendered; launch actions resolve the managed ID again before opening.
    let resolvedResourceURL: URL?

    var statusCode: String {
        switch availability {
        case .available:
            guard kind == .cli else { return availability.rawValue }
            let source = sourceStatusCode?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return source?.isEmpty == false ? source! : availability.rawValue
        default:
            return availability.rawValue
        }
    }

    var isLaunchable: Bool {
        availability == .available || availability == .running
    }

    var buttonLabel: String {
        switch kind {
        case .cli:
            return "Open CLI"
        case .desktop where availability == .running:
            return "Go to"
        case .desktop:
            return "Open"
        }
    }

    var buttonSystemImage: String {
        switch kind {
        case .cli:
            return "terminal"
        case .desktop where availability == .running:
            return "arrow.up.forward.app"
        case .desktop:
            return "play.fill"
        }
    }

    var accessibilityLabel: String {
        switch kind {
        case .cli:
            return "Open \(label) CLI"
        case .desktop where availability == .running:
            return "Go to \(label)"
        case .desktop:
            return "Open \(label)"
        }
    }

    var detailSummary: String {
        [sourceSummary, availabilityReason]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")
    }

    func replacingAvailability(
        _ availability: AgentLaunchAvailability,
        reason: String
    ) -> AgentLaunchTarget {
        AgentLaunchTarget(
            id: id,
            productID: productID,
            launcherID: launcherID,
            kind: kind,
            label: label,
            subtitle: subtitle,
            availability: availability,
            availabilityReason: reason,
            launchMode: launchMode,
            workingDirectoryPolicy: workingDirectoryPolicy,
            sourceStatusCode: sourceStatusCode,
            sourceSummary: sourceSummary,
            resolvedResourceURL: resolvedResourceURL
        )
    }
}

struct ManagedCLILauncherSpec: Equatable {
    let launcherID: String
    let productID: String
    let label: String
    let executableNames: [String]
}

struct ManagedDesktopLauncherSpec: Equatable {
    let launcherID: String
    let productID: String
    let label: String
    let bundleIdentifier: String
    let applicationNames: [String]
}

enum AgentLauncherCatalog {
    static let managedCLILaunchers: [ManagedCLILauncherSpec] = [
        ManagedCLILauncherSpec(
            launcherID: "harvis.cli.codex",
            productID: "codex",
            label: "Codex CLI",
            executableNames: ["codex"]
        ),
        ManagedCLILauncherSpec(
            launcherID: "harvis.cli.dsh",
            productID: "dsh",
            label: "DSH",
            executableNames: ["dsh"]
        ),
        ManagedCLILauncherSpec(
            launcherID: "harvis.cli.kimicode",
            productID: "kimicode",
            label: "Kimi Code",
            executableNames: ["kimicode", "kimi"]
        ),
        ManagedCLILauncherSpec(
            launcherID: "harvis.cli.mimocode",
            productID: "mimocode",
            label: "MiMoCode",
            executableNames: ["mimocode", "mimo"]
        ),
        ManagedCLILauncherSpec(
            launcherID: "harvis.cli.claude-code",
            productID: "claude-code",
            label: "Claude Code",
            executableNames: ["claude"]
        ),
        ManagedCLILauncherSpec(
            launcherID: "harvis.cli.likecode",
            productID: "likecode",
            label: "LikeCode",
            executableNames: ["likecode"]
        ),
    ]

    static let managedDesktopLaunchers: [ManagedDesktopLauncherSpec] = [
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.codex",
            productID: "codex",
            label: "Codex Desktop",
            bundleIdentifier: "com.openai.codex",
            applicationNames: ["ChatGPT", "Codex"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.claude",
            productID: "claude",
            label: "Claude",
            bundleIdentifier: "com.anthropic.claudefordesktop",
            applicationNames: ["Claude"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.kimi",
            productID: "kimi",
            label: "Kimi",
            bundleIdentifier: "com.moonshot.kimichat",
            applicationNames: ["Kimi"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.dsh",
            productID: "dsh",
            label: "DSH Desktop",
            bundleIdentifier: "ai.deepseek.dsh.desktop",
            applicationNames: ["DSH Desktop", "DSH"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.workbuddy",
            productID: "workbuddy",
            label: "WorkBuddy",
            bundleIdentifier: "com.workbuddy.workbuddy",
            applicationNames: ["WorkBuddy"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.zcode",
            productID: "zcode",
            label: "ZCode",
            bundleIdentifier: "dev.zcode.app",
            applicationNames: ["ZCode"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.doubaowork",
            productID: "doubaowork",
            label: "DoubaoWork",
            bundleIdentifier: "com.work.pc.doubao",
            applicationNames: ["DoubaoWork"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.qoder",
            productID: "qoder",
            label: "Qoder",
            bundleIdentifier: "com.qoder.ide",
            applicationNames: ["Qoder"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.aionui",
            productID: "aionui",
            label: "AionUi",
            bundleIdentifier: "com.aionui.app",
            applicationNames: ["AionUi", "AionUI"]
        ),
        ManagedDesktopLauncherSpec(
            launcherID: "harvis.desktop.codex-managed-agent",
            productID: "codex-managed-agent",
            label: "Codex Managed Agent Desktop",
            bundleIdentifier: "dev.harzva.codex-managed-agent.desktop",
            applicationNames: ["Codex Managed Agent Desktop", "Codex Managed Agent"]
        ),
    ]

    static func cliSpec(launcherID: String) -> ManagedCLILauncherSpec? {
        managedCLILaunchers.first { $0.launcherID == launcherID }
    }

    static func desktopSpec(launcherID: String) -> ManagedDesktopLauncherSpec? {
        managedDesktopLaunchers.first { $0.launcherID == launcherID }
    }

    static func executableSearchPaths(
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        let home = (homeDirectory as NSString).standardizingPath
        let managedFallbacks = [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]

        var seen: Set<String> = []
        return (pathDirectories + managedFallbacks).compactMap { path in
            let standardized = (path as NSString).standardizingPath
            guard standardized.hasPrefix("/"), seen.insert(standardized).inserted else {
                return nil
            }
            return standardized
        }
    }

    static func cliTargets(
        harnesses: [AgentHarnessItem],
        searchPaths: [String],
        isExecutable: (String) -> Bool,
        isDirectory: (String) -> Bool = { _ in false }
    ) -> [AgentLaunchTarget] {
        harnesses.compactMap { item in
            // cxspark is a reviewed runtime preset, not an interactive CLI.
            guard item.id.lowercased() != "cxspark", let descriptor = item.launch else {
                return nil
            }

            let launcherID = trimmed(descriptor.launcherID)
            let productID = trimmed(descriptor.productID)
            let targetID = "cli:\(item.id):\(launcherID ?? "invalid")"
            let subtitle = item.routeLabel

            guard let launcherID, let productID else {
                return AgentLaunchTarget(
                    id: targetID,
                    productID: productID ?? item.id,
                    launcherID: launcherID ?? "invalid:\(item.id)",
                    kind: .cli,
                    label: item.label ?? item.id,
                    subtitle: subtitle,
                    availability: .misconfigured,
                    availabilityReason: "The runtime declared an incomplete CLI launcher.",
                    launchMode: .newTerminalSession,
                    workingDirectoryPolicy: .workspaceRoot,
                    sourceStatusCode: item.effectiveStatus,
                    sourceSummary: item.detailSummary,
                    resolvedResourceURL: nil
                )
            }

            guard descriptor.kind == AgentLaunchKind.cli.rawValue,
                  descriptor.mode == AgentLaunchMode.newTerminalSession.rawValue,
                  descriptor.workingDirectoryPolicy == AgentWorkingDirectoryPolicy.workspaceRoot.rawValue
            else {
                return AgentLaunchTarget(
                    id: targetID,
                    productID: productID,
                    launcherID: launcherID,
                    kind: .cli,
                    label: item.label ?? item.id,
                    subtitle: subtitle,
                    availability: .misconfigured,
                    availabilityReason: "The runtime declared an unsupported CLI launch policy.",
                    launchMode: .newTerminalSession,
                    workingDirectoryPolicy: .workspaceRoot,
                    sourceStatusCode: item.effectiveStatus,
                    sourceSummary: item.detailSummary,
                    resolvedResourceURL: nil
                )
            }

            guard let spec = cliSpec(launcherID: launcherID) else {
                return AgentLaunchTarget(
                    id: targetID,
                    productID: productID,
                    launcherID: launcherID,
                    kind: .cli,
                    label: item.label ?? item.id,
                    subtitle: subtitle,
                    availability: .unsupported,
                    availabilityReason: "This CLI launcher is not in the local managed catalog.",
                    launchMode: .newTerminalSession,
                    workingDirectoryPolicy: .workspaceRoot,
                    sourceStatusCode: item.effectiveStatus,
                    sourceSummary: item.detailSummary,
                    resolvedResourceURL: nil
                )
            }

            guard productID == spec.productID, item.id == spec.productID else {
                return AgentLaunchTarget(
                    id: targetID,
                    productID: productID,
                    launcherID: launcherID,
                    kind: .cli,
                    label: item.label ?? spec.label,
                    subtitle: subtitle,
                    availability: .misconfigured,
                    availabilityReason: "The CLI launcher does not match its declared product.",
                    launchMode: .newTerminalSession,
                    workingDirectoryPolicy: .workspaceRoot,
                    sourceStatusCode: item.effectiveStatus,
                    sourceSummary: item.detailSummary,
                    resolvedResourceURL: nil
                )
            }

            let executableURL = executableURL(
                for: spec,
                searchPaths: searchPaths,
                isExecutable: isExecutable,
                isDirectory: isDirectory
            )
            let availability: AgentLaunchAvailability = executableURL == nil ? .missing : .available
            let reason = executableURL == nil
                ? "The managed \(spec.label) executable was not found."
                : "The managed \(spec.label) executable is available."
            return AgentLaunchTarget(
                id: targetID,
                productID: productID,
                launcherID: launcherID,
                kind: .cli,
                label: item.label ?? spec.label,
                subtitle: subtitle,
                availability: availability,
                availabilityReason: reason,
                launchMode: .newTerminalSession,
                workingDirectoryPolicy: .workspaceRoot,
                sourceStatusCode: item.effectiveStatus,
                sourceSummary: item.detailSummary,
                resolvedResourceURL: executableURL
            )
        }
    }

    static func executableURL(
        for spec: ManagedCLILauncherSpec,
        searchPaths: [String],
        isExecutable: (String) -> Bool,
        isDirectory: (String) -> Bool = { _ in false }
    ) -> URL? {
        for directory in searchPaths where directory.hasPrefix("/") {
            for name in spec.executableNames {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
                    .standardizedFileURL
                if isExecutable(candidate.path), !isDirectory(candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    static func desktopTargets(
        specs: [ManagedDesktopLauncherSpec] = managedDesktopLaunchers,
        bundleURLForIdentifier: (String) -> URL?,
        applicationURLForName: (String) -> URL?,
        isRunning: (String, URL) -> Bool
    ) -> [AgentLaunchTarget] {
        specs.map { spec in
            let bundleURL = bundleURLForIdentifier(spec.bundleIdentifier)
            let fallbackURL = bundleURL == nil
                ? firstApplicationURL(names: spec.applicationNames, resolver: applicationURLForName)
                : nil
            let applicationURL = bundleURL ?? fallbackURL
            let running = applicationURL.map { isRunning(spec.bundleIdentifier, $0) } ?? false
            let availability: AgentLaunchAvailability
            let reason: String
            if applicationURL == nil {
                availability = .missing
                reason = "\(spec.label) is not installed."
            } else if running {
                availability = .running
                reason = "\(spec.label) is installed and running."
            } else {
                availability = .available
                reason = "\(spec.label) is installed."
            }

            return AgentLaunchTarget(
                id: "desktop:\(spec.launcherID)",
                productID: spec.productID,
                launcherID: spec.launcherID,
                kind: .desktop,
                label: spec.label,
                subtitle: spec.bundleIdentifier,
                availability: availability,
                availabilityReason: reason,
                launchMode: .activateOrOpen,
                workingDirectoryPolicy: .none,
                sourceStatusCode: nil,
                sourceSummary: nil,
                resolvedResourceURL: applicationURL
            )
        }
    }

    private static func firstApplicationURL(
        names: [String],
        resolver: (String) -> URL?
    ) -> URL? {
        for name in names {
            if let url = resolver(name) {
                return url
            }
        }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AgentLauncherCommandBuilder {
    static func terminalCommand(executableURL: URL, workspaceURL: URL) -> String {
        "cd \(shellQuote(workspaceURL.standardizedFileURL.path)) && "
            + "exec \(shellQuote(executableURL.standardizedFileURL.path))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
