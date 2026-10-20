import AppKit
import Foundation

extension HarvisRuntimeModel {
    func agentLaunchTargets(kind: AgentLaunchKind) -> [AgentLaunchTarget] {
        switch kind {
        case .cli:
            let searchPaths = AgentLauncherCatalog.executableSearchPaths(
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
            let targets = AgentLauncherCatalog.cliTargets(
                harnesses: displayedHarnesses?.items ?? [],
                searchPaths: searchPaths,
                isExecutable: FileManager.default.isExecutableFile(atPath:),
                isDirectory: { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(
                        atPath: path,
                        isDirectory: &isDirectory
                    ) && isDirectory.boolValue
                }
            )
            guard agentLauncherWorkspaceURL() == nil else { return targets }
            return targets.map { target in
                guard target.isLaunchable else { return target }
                return target.replacingAvailability(
                    .misconfigured,
                    reason: "Workspace root must name an existing folder."
                )
            }

        case .desktop:
            let workspace = NSWorkspace.shared
            let runningApplications = workspace.runningApplications
            return AgentLauncherCatalog.desktopTargets(
                bundleURLForIdentifier: { bundleIdentifier in
                    workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
                },
                applicationURLForName: { applicationName in
                    Self.standardApplicationURL(named: applicationName)
                },
                isRunning: { bundleIdentifier, applicationURL in
                    runningApplications.contains { application in
                        if application.bundleIdentifier == bundleIdentifier {
                            return true
                        }
                        guard let bundleURL = application.bundleURL else { return false }
                        return Self.sameApplicationURL(bundleURL, applicationURL)
                    }
                }
            )
        }
    }

    func openAgentLauncher(_ target: AgentLaunchTarget) {
        guard !agentLauncherOpeningIDs.contains(target.id) else { return }
        guard let current = agentLaunchTargets(kind: target.kind).first(where: {
            $0.id == target.id && $0.launcherID == target.launcherID
        }) else {
            lastError = "This launcher is no longer in the managed catalog."
            return
        }
        guard current.isLaunchable else {
            lastError = "\(current.label) could not open. \(current.availabilityReason)"
            return
        }

        agentLauncherOpeningIDs.insert(current.id)
        lastError = nil
        switch current.kind {
        case .cli:
            openCLIAgentLauncher(current)
        case .desktop:
            openDesktopAgentLauncher(current)
        }
    }

    private func openCLIAgentLauncher(_ target: AgentLaunchTarget) {
        guard target.launchMode == .newTerminalSession,
              target.workingDirectoryPolicy == .workspaceRoot,
              AgentLauncherCatalog.cliSpec(launcherID: target.launcherID) != nil,
              let executableURL = target.resolvedResourceURL,
              let workspaceURL = agentLauncherWorkspaceURL()
        else {
            agentLauncherOpeningIDs.remove(target.id)
            lastError = "\(target.label) could not open because its managed launch policy is unavailable."
            return
        }

        let command = AgentLauncherCommandBuilder.terminalCommand(
            executableURL: executableURL,
            workspaceURL: workspaceURL
        )
        let targetID = target.id
        let targetLabel = target.label
        Task { [weak self] in
            guard let self else { return }
            defer { agentLauncherOpeningIDs.remove(targetID) }
            do {
                _ = try await runProcess(
                    "/usr/bin/osascript",
                    ["-e", Self.agentLauncherTerminalAppleScript, command]
                )
                lastActionOutput = "Handed \(targetLabel) to Terminal."
                lastError = nil
            } catch {
                lastError = "Terminal could not open \(targetLabel). \(clean(error.localizedDescription))"
            }
        }
    }

    private func openDesktopAgentLauncher(_ target: AgentLaunchTarget) {
        guard target.launchMode == .activateOrOpen,
              let spec = AgentLauncherCatalog.desktopSpec(launcherID: target.launcherID),
              let applicationURL = desktopApplicationURL(for: spec)
        else {
            agentLauncherOpeningIDs.remove(target.id)
            lastError = "\(target.label) could not open because the managed application is unavailable."
            return
        }

        if let running = runningDesktopApplication(for: spec, applicationURL: applicationURL),
           running.activate(options: [.activateAllWindows]) {
            agentLauncherOpeningIDs.remove(target.id)
            lastActionOutput = "Activated \(target.label)."
            lastError = nil
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let targetID = target.id
        let targetLabel = target.label
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                agentLauncherOpeningIDs.remove(targetID)
                if let error {
                    lastError = "\(targetLabel) could not open. \(clean(error.localizedDescription))"
                } else {
                    lastActionOutput = "Opened \(targetLabel)."
                    lastError = nil
                }
            }
        }
    }

    private func agentLauncherWorkspaceURL() -> URL? {
        let configured = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return nil }
        let url = URL(
            fileURLWithPath: expanded(configured),
            isDirectory: true
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return url
    }

    private func desktopApplicationURL(for spec: ManagedDesktopLauncherSpec) -> URL? {
        let workspace = NSWorkspace.shared
        if let bundleURL = workspace.urlForApplication(
            withBundleIdentifier: spec.bundleIdentifier
        ) {
            return bundleURL.standardizedFileURL
        }
        for name in spec.applicationNames {
            if let url = Self.standardApplicationURL(named: name) {
                return url
            }
        }
        return nil
    }

    private func runningDesktopApplication(
        for spec: ManagedDesktopLauncherSpec,
        applicationURL: URL
    ) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { application in
            if application.bundleIdentifier == spec.bundleIdentifier {
                return true
            }
            guard let bundleURL = application.bundleURL else { return false }
            return Self.sameApplicationURL(bundleURL, applicationURL)
        }
    }

    private static func sameApplicationURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func standardApplicationURL(named name: String) -> URL? {
        let bundleName = name.hasSuffix(".app") ? name : "\(name).app"
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApplications,
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
        for root in roots {
            let candidate = root
                .appendingPathComponent(bundleName, isDirectory: true)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static let agentLauncherTerminalAppleScript = """
    on run argv
        set launchCommand to item 1 of argv
        tell application "Terminal"
            activate
            do script launchCommand
        end tell
    end run
    """
}
