import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

struct CodexAuthFileSnapshot: Equatable, Sendable {
    let modificationDate: Date?
    let fileSize: UInt64?
    let fileSystemNumber: UInt64?
}

struct CodexHomeDiscoveryFingerprint: Equatable, Sendable {
    let entries: [String]
}

extension HarvisRuntimeModel {
    func startServices() {
        Task { await runServiceCommand("start", service: "both", ensureToken: true) }
    }

    func stopServices() {
        Task { await runServiceCommand("stop", service: "both", ensureToken: false) }
    }

    func restartServices() {
        Task { await runServiceCommand("restart", service: "both", ensureToken: true) }
    }

    func restartDshInstance(port: Int) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                lastActionOutput = try await runProcess(
                    serviceManagerPath,
                    ["dsh-web", "restart", "--port", String(port)],
                    timeout: 120
                )
                lastError = nil
                try? await Task.sleep(for: .milliseconds(700))
                await refreshAll()
            } catch {
                lastError = clean(error.localizedDescription)
            }
        }
    }

    func refreshDshInstances() {
        Task { await refreshAll() }
    }

    func refreshProxyRoutes() {
        Task { await refreshProxyStatus(force: true) }
    }

    func switchSystemProxy(_ profile: String) {
        guard ["clash", "v2ray", "off"].contains(profile) else { return }
        Task { await runProxyCommand("switch", profile: profile) }
    }

    func archiveScheduledCodexThreads() {
        Task { await runCodexArchive() }
    }

    func refreshCodexHomeList() {
        Task { await refreshCodexHomes() }
    }

    func selectCodexHome(_ home: CodexHome) {
        selectedCodexHomeID = home.id
        codexEvidenceStates = [:]
        codexEvidenceErrors = [:]
        codexEvidenceLoadingKeys = []
        Task {
            async let quotaRefresh: Void = refreshCodexHomeQuota(home)
            async let threadRefresh: Void = refreshCodexThreads(home)
            _ = await (quotaRefresh, threadRefresh)
        }
    }

    func refreshSelectedCodexThreads(userInitiated: Bool = false) {
        guard let home = selectedCodexHome else { return }
        Task { await refreshCodexThreads(home, userInitiated: userInitiated) }
    }

    func refreshManagedChatList() {
        Task { await refreshManagedChatProviders() }
    }

    func launchCodexCLI(_ home: CodexHome) {
        Task { _ = await runCodexHomeAction("launch-cli", home: home) }
    }

    /// Resume the card's exact Codex session in Terminal using its owning
    /// CODEX_HOME and recorded working directory.
    @discardableResult
    func openManagedThreadInCLI(_ thread: ManagedChatThread) -> Task<Bool, Never>? {
        guard thread.isCodex,
              let home = codexHome(for: thread),
              let codexThread = codexThread(for: thread),
              codexThread.id == thread.sourceID else {
            lastError = "此 Codex 会话的来源账号或会话记录不可用。"
            return nil
        }
        let workingDirectory = codexThread.cwd
        guard !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "此 Codex 会话没有可用的工作目录。"
            return nil
        }
        return Task {
            await runCodexThreadAction(
                "resume-cli",
                home: home,
                threadID: codexThread.id,
                workingDirectory: workingDirectory
            )
        }
    }

    func launchCodexDesktop(_ home: CodexHome) {
        Task { _ = await runCodexHomeAction("launch-desktop", home: home) }
    }

    func loginCodexHome(_ home: CodexHome) {
        guard !home.isCustomModelHome else {
            openCodexConfig(home)
            return
        }
        Task { _ = await runCodexHomeAction("login", home: home) }
    }

    func openCodexThread(_ thread: CodexThreadSummary) {
        guard let home = selectedCodexHome else { return }
        Task {
            _ = await performCodexDesktopOpen(home: home, threadID: thread.id)
        }
    }

    func openManagedThread(_ thread: ManagedChatThread) {
        switch thread.provider {
        case .workBuddy:
            let application = URL(fileURLWithPath: "/Applications/WorkBuddy.app")
            guard FileManager.default.fileExists(atPath: application.path) else {
                lastError = "WorkBuddy is not installed in /Applications."
                return
            }
            NSWorkspace.shared.openApplication(
                at: application,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                Task { @MainActor in
                    if let error {
                        self.lastError = "WorkBuddy could not open. \(self.clean(error.localizedDescription))"
                    } else {
                        self.lastActionOutput = "Opened WorkBuddy for \(thread.title)"
                        self.lastError = nil
                    }
                }
            }
        case .dsh:
            guard let url = ManagedChatOpenTarget.dshSessionURL(
                sessionID: thread.sourceID, sourceScope: thread.sourceScope, endpoints: dshRunningEndpoints
            ) else {
                lastError = "This DSH runtime is not currently available. Open the DSH Runtime Catalog to inspect or start it."
                openDshRuntimeCatalog()
                return
            }
            guard NSWorkspace.shared.open(url) else {
                lastError = "DSH 会话页面未能打开。"
                return
            }
            lastActionOutput = "已请求在 DSH 中打开 \(thread.title)"
            lastError = nil
        case .codex:
            guard let home = codexHome(for: thread),
                  let codexThread = codexThread(for: thread) else { return }
            Task {
                _ = await performCodexDesktopOpen(home: home, threadID: codexThread.id)
            }
        }
    }

    func codexThread(for thread: ManagedChatThread) -> CodexThreadSummary? {
        guard let home = codexHome(for: thread) else { return nil }
        let threads = codexThreadSnapshotsByHomeID[home.id]?.threads
            ?? (codexThreadsSourceHomeID == home.id ? codexThreads : [])
        return threads.first { $0.id == thread.sourceID }
    }

    func openManagedThreadInNewWindow(_ thread: ManagedChatThread) {
        guard let home = codexHome(for: thread),
              let nativeThread = codexThread(for: thread) else { return }
        openCodexThreadInNewWindow(nativeThread, home: home)
    }

    func openCodexThreadInNewWindow(_ thread: CodexThreadSummary) {
        guard let home = selectedCodexHome else { return }
        openCodexThreadInNewWindow(thread, home: home)
    }

    private func openCodexThreadInNewWindow(_ thread: CodexThreadSummary, home: CodexHome) {
        Task {
            _ = await performCodexDesktopOpen(home: home, threadID: thread.id, newWindow: true)
        }
    }

    func openCodexThreadID(_ threadID: String, home: CodexHome) {
        guard visibleCodexHomes.contains(where: { $0.id == home.id && $0.path == home.path }) else { return }
        Task {
            _ = await performCodexDesktopOpen(home: home, threadID: threadID)
        }
    }

    func performCodexDesktopOpen(home: CodexHome, threadID: String? = nil, newWindow: Bool = false) async -> Bool {
        guard let request = beginCodexHomeAction(for: home) else { return false }
        defer { endCodexHomeAction(request) }
        do {
            _ = try await codexDesktopCoordinator.open(
                homePath: home.path, homeID: home.id, threadID: threadID, newWindow: newWindow
            )
            guard isCurrentCodexRequest(request) else { return true }
            lastActionOutput = newWindow
                ? "已请求在 \(home.accountDisplayLabel) 的新 Codex 窗口打开会话"
                : "已请求在 \(home.accountDisplayLabel) 的 Codex 窗口打开"
            lastError = nil
            codexHomeActionFeedback[home.id] = .init(message: "已请求打开此账号的 Codex Desktop。", isError: false)
            return true
        } catch {
            guard isCurrentCodexRequest(request) else { return false }
            lastError = clean(error.localizedDescription)
            codexHomeActionFeedback[home.id] = .init(message: clean(error.localizedDescription), isError: true)
            return false
        }
    }

    func revealCodexHome(_ home: CodexHome) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: home.path)])
    }

    func openCodexConfig(_ home: CodexHome) {
        let configURL = URL(fileURLWithPath: home.path, isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        guard FileManager.default.isReadableFile(atPath: configURL.path) else {
            lastError = "This CODEX_HOME does not contain a readable config.toml."
            return
        }
        guard let textEditURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.TextEdit"
        ) else {
            lastError = "macOS TextEdit is unavailable."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [configURL],
            withApplicationAt: textEditURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastError = error.map { self.clean($0.localizedDescription) }
            }
        }
    }

    func revealCodexWorkspace(_ home: CodexHome) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: codexWorkspacePath(for: home), isDirectory: true)
        ])
    }

    func chooseCodexWorkspace(_ home: CodexHome) {
        let panel = NSOpenPanel()
        panel.title = "选择 \(home.accountDisplayLabel) 的工作区"
        panel.prompt = "设为工作区"
        panel.message = "此路径只绑定到当前账户；Auth 失效或重新登录不会删除它。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: codexWorkspacePath(for: home), isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCodexWorkspace(url.path, for: home)
    }

    func setCodexWorkspace(_ path: String, for home: CodexHome) {
        let normalized = URL(fileURLWithPath: expanded(path), isDirectory: true)
            .standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            lastError = "选择的 Codex 工作区不存在。"
            return
        }
        codexHomeWorkspaces[home.id] = normalized
        lastActionOutput = "已为 \(home.accountDisplayLabel) 保存独立工作区。"
        lastError = nil
    }

    func hideCodexHome(_ home: CodexHome) {
        hiddenCodexHomeIDs.formUnion(codexHomeIDs(forAccount: home))
        moveSelectionAfterHidingHomes()
        lastActionOutput = "已将 \(home.accountDisplayLabel) 移出账户列表；CODEX_HOME、工作区和会话均已保留。"
        lastError = nil
    }

    func hideInvalidCodexHomes() {
        let invalidHomes = invalidVisibleCodexHomes
        guard !invalidHomes.isEmpty else { return }
        hiddenCodexHomeIDs.formUnion(
            invalidHomes.flatMap { codexHomeIDs(forAccount: $0) }
        )
        moveSelectionAfterHidingHomes()
        lastActionOutput = "已移出 \(invalidHomes.count) 个失效账户；所有工作区和本地会话均已保留。"
        lastError = nil
    }

    func restoreCodexHome(_ home: CodexHome) {
        hiddenCodexHomeIDs.subtract(codexHomeIDs(forAccount: home))
        if selectedCodexHomeID == nil {
            selectCodexHome(home)
        }
        lastActionOutput = "已恢复 \(home.accountDisplayLabel)；原工作区仍然可用。"
        lastError = nil
    }

    func restoreAllCodexHomes() {
        guard !hiddenCodexHomeIDs.isEmpty else { return }
        hiddenCodexHomeIDs.removeAll()
        if selectedCodexHomeID == nil, let home = visibleCodexHomes.first {
            selectCodexHome(home)
        }
        lastActionOutput = "已恢复全部账户。"
        lastError = nil
    }

    func renameCodexAccountNote(_ home: CodexHome, note: String) {
        Task {
            do {
                let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedNote.count <= 60,
                      !trimmedNote.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else {
                    throw HarvisBarError.api("账户备注应为不超过 60 个字符的可见文字。")
                }
                try await Self.updateCodexAccountNote(
                    homePath: home.path,
                    note: trimmedNote
                )
                await refreshCodexHomes()
                if trimmedNote.isEmpty {
                    lastActionOutput = "已清除账户备注；登录邮箱和 CODEX_HOME 均未改变。"
                } else {
                    lastActionOutput = "账户备注已更新为“\(trimmedNote)”；登录邮箱和 CODEX_HOME 均未改变。"
                }
                lastError = nil
            } catch {
                lastError = clean(error.localizedDescription)
            }
        }
    }

    func addManagedCodexAccount(label: String, workspacePath: String) {
        Task {
            do {
                let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLabel.isEmpty,
                      trimmedLabel.count <= 60,
                      !trimmedLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else {
                    throw HarvisBarError.api("账户备注应为 1–60 个可见字符。")
                }
                let normalizedWorkspace = URL(
                    fileURLWithPath: expanded(workspacePath),
                    isDirectory: true
                ).standardizedFileURL.path
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: normalizedWorkspace,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw HarvisBarError.api("请先选择一个存在的工作区目录。")
                }

                let homePath = try await Self.createManagedCodexHome(label: trimmedLabel)
                await refreshCodexHomes()
                guard let home = codexHomes.first(where: {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path == homePath
                }) else {
                    throw HarvisBarError.api("账户目录已创建，但 Harvis 尚未发现它；请点击刷新。")
                }
                hiddenCodexHomeIDs.remove(home.id)
                setCodexWorkspace(normalizedWorkspace, for: home)
                selectCodexHome(home)
                _ = await runCodexHomeAction("login", home: home)
            } catch {
                lastError = clean(error.localizedDescription)
            }
        }
    }

    nonisolated static func codexAuthFileSnapshot(homePath: String) -> CodexAuthFileSnapshot? {
        let authPath = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
            .path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: authPath) else {
            return nil
        }
        return CodexAuthFileSnapshot(
            modificationDate: attributes[.modificationDate] as? Date,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value,
            fileSystemNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    nonisolated static func codexHomeDiscoveryFingerprint(
        userRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        additionalHomePaths: [String] = []
    ) -> CodexHomeDiscoveryFingerprint {
        let fileManager = FileManager.default
        let userRoot = URL(fileURLWithPath: userRootPath, isDirectory: true)
            .standardizedFileURL
        var homeURLs = [userRoot.appendingPathComponent(".codex", isDirectory: true)]
        let groupedRoots = [
            userRoot.appendingPathComponent(".codex-managed-agent/accounts", isDirectory: true),
            userRoot.appendingPathComponent(
                "Library/Application Support/open-codex-launcher/profile-homes",
                isDirectory: true
            ),
            userRoot.appendingPathComponent(
                "Library/Application Support/codexuse-desktop/profile-homes",
                isDirectory: true
            )
        ]
        for root in groupedRoots {
            let children = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            )) ?? []
            homeURLs.append(contentsOf: children.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            })
        }
        homeURLs.append(contentsOf: additionalHomePaths.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        })

        let uniqueHomes = Dictionary(
            grouping: homeURLs,
            by: { $0.standardizedFileURL.path }
        ).compactMap { $0.value.first }
        let observedNames = ["auth.json", ".harvis-account.json", "config.toml"]
        var entries: [String] = []
        for home in uniqueHomes {
            entries.append(fileMetadataFingerprint(home, fileManager: fileManager))
            for name in observedNames {
                entries.append(
                    fileMetadataFingerprint(
                        home.appendingPathComponent(name, isDirectory: false),
                        fileManager: fileManager
                    )
                )
            }
        }
        return CodexHomeDiscoveryFingerprint(entries: entries.sorted())
    }

    private nonisolated static func fileMetadataFingerprint(
        _ url: URL,
        fileManager: FileManager
    ) -> String {
        let path = url.standardizedFileURL.path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return "\(path)|missing"
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileSystemNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(path)|\(modified)|\(size)|\(fileSystemNumber)"
    }

    nonisolated static func waitForCodexAuthChange(
        homePath: String,
        baseline: CodexAuthFileSnapshot?,
        timeoutNanoseconds: UInt64 = 180_000_000_000,
        pollIntervalNanoseconds: UInt64 = 500_000_000
    ) async -> Bool {
        let startedAt = ContinuousClock.now
        let timeout = Duration.nanoseconds(Int64(clamping: timeoutNanoseconds))
        repeat {
            if Task.isCancelled { return false }
            if let current = codexAuthFileSnapshot(homePath: homePath), current != baseline {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return false
            }
        } while ContinuousClock.now - startedAt < timeout
        return false
    }

    func refreshCodexHomeAfterLogin(
        home: CodexHome,
        baseline: CodexAuthFileSnapshot?
    ) async {
        let authChanged = await Self.waitForCodexAuthChange(
            homePath: home.path,
            baseline: baseline
        )
        guard !Task.isCancelled else { return }

        // Refresh once even after timeout: a filesystem may preserve coarse
        // metadata while Codex atomically replaces auth.json.
        await refreshCodexHomes()
        guard authChanged,
              let refreshedHome = codexHomes.first(where: {
                  URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path
                      == URL(fileURLWithPath: home.path, isDirectory: true).standardizedFileURL.path
              }),
              refreshedHome.isCodexAccountCandidate
        else { return }

        hiddenCodexHomeIDs.remove(refreshedHome.id)
        if selectedCodexHomeID == home.id || !home.isCodexAccountCandidate {
            selectCodexHome(refreshedHome)
        }
        lastActionOutput = "登录完成，已刷新账户列表：\(refreshedHome.accountDisplayLabel)"
        lastError = nil
    }

    private func moveSelectionAfterHidingHomes() {
        guard let selectedCodexHomeID,
              hiddenCodexHomeIDs.contains(selectedCodexHomeID) else { return }
        if let next = visibleCodexHomes.first {
            selectCodexHome(next)
        } else {
            self.selectedCodexHomeID = nil
            codexThreads = []
            codexThreadError = nil
        }
    }

    private static func createManagedCodexHome(label: String) async throws -> String {
        let slug = label
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .map { character in
                character.isASCII && (character.isLetter || character.isNumber)
                    ? character
                    : "-"
            }
            .reduce(into: "") { partial, character in
                if character != "-" || partial.last != "-" {
                    partial.append(character)
                }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeSlug = String((slug.isEmpty ? "account" : slug).prefix(32))
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-managed-agent/accounts", isDirectory: true)
        let home = root.appendingPathComponent("\(safeSlug)-\(suffix)", isDirectory: true)
        let createdAt = ISO8601DateFormatter().string(from: Date())

        return try await Task.detached {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.createDirectory(
                at: home,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            do {
                let config = Data("# Managed by HarvisBar.\n".utf8)
                try config.write(to: home.appendingPathComponent("config.toml"), options: .atomic)
                let metadata = try JSONSerialization.data(
                    withJSONObject: [
                        "schemaVersion": "harvis.codex-account.v1",
                        "label": label,
                        "createdAt": createdAt
                    ],
                    options: [.prettyPrinted, .sortedKeys]
                )
                let metadataURL = home.appendingPathComponent(".harvis-account.json")
                try metadata.write(to: metadataURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: metadataURL.path
                )
                return home.standardizedFileURL.path
            } catch {
                try? fileManager.removeItem(at: home)
                throw error
            }
        }.value
    }

    static func updateCodexAccountNote(homePath: String, note: String) async throws {
        let normalizedHome = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.detached {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: normalizedHome.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw HarvisBarError.api("CODEX_HOME 不存在，无法更新账户备注。")
            }

            let metadataURL = normalizedHome.appendingPathComponent(".harvis-account.json")
            var createdAt: String?
            if fileManager.fileExists(atPath: metadataURL.path) {
                let existing = try Data(contentsOf: metadataURL)
                guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any]
                else {
                    throw HarvisBarError.api("账户备注文件格式无效，未进行覆盖。")
                }
                createdAt = object["createdAt"] as? String
            }

            var metadata: [String: Any] = [
                "schemaVersion": "harvis.codex-account.v1",
                "updatedAt": ISO8601DateFormatter().string(from: Date())
            ]
            if let createdAt, !createdAt.isEmpty {
                metadata["createdAt"] = createdAt
            }
            if !trimmedNote.isEmpty {
                metadata["label"] = trimmedNote
            }
            let data = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: metadataURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: metadataURL.path
            )
        }.value
    }

    func testHarnesses() {
        Task { await runHarnessPreflightTests() }
    }

    func refreshAgentMailSummary() {
        Task { await runAgentMailSummary() }
    }

    func initializeFirstRun() {
        Task { await runFirstRunInitialization() }
    }

    func openPanel() {
        openLocalPath("/panel/")
    }

    func openStudio() {
        openLocalPath("/studio/")
    }

    func openCredentialBank() {
        openLocalPath(
            "/studio/",
            extraQueryItems: [
                URLQueryItem(name: "view", value: "settings"),
                URLQueryItem(name: "focus", value: "credential-vault")
            ]
        )
    }

    func openPresence() {
        openLocalPath("/presence/")
    }

    func openPorts() {
        openLocalPath("/studio/", extraQueryItems: [URLQueryItem(name: "view", value: "ports")])
    }

    func openNetworkConsole() {
        HarvisNetworkWindowController.shared.show(model: self)
    }

    func openH5MagicWorkbench() {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let launcher = try h5MagicWorkbenchLauncherPath()
                lastActionOutput = try await runProcess(launcher, ["open"])
                lastError = nil
            } catch {
                lastError = clean(error.localizedDescription)
            }
        }
    }

    private func h5MagicWorkbenchLauncherPath() throws -> String {
        let fileManager = FileManager.default
        let environmentRoot = ProcessInfo.processInfo.environment["H5MAGIC_WORKBENCH_ROOT"]
        let configuredRoot = try? String(
            contentsOfFile: expanded("~/.harvis/launchers/h5magic-root"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [environmentRoot, configuredRoot, workspaceRoot]
            .compactMap { $0 }
            .map(expanded)

        for root in candidates where !root.isEmpty {
            let launcher = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("app/scripts/h5magic-workbench-service.sh")
                .path
            if fileManager.isExecutableFile(atPath: launcher) {
                return launcher
            }
        }
        throw HarvisBarError.process(
            "H5Magic launcher was not found. Configure ~/.harvis/launchers/h5magic-root."
        )
    }

    func openCodexChatManager() {
        HarvisCodexChatWindowController.shared.show(model: self)
    }

    func openCodexGroupChat() {
        HarvisGroupWindowController.shared.show(runtime: self, coordinator: groupChat)
        Task { await activateGroupChat() }
    }

    func toggleCodexChatWindowPin() {
        isCodexChatWindowPinned.toggle()
    }

    func toggleCodexChatWindowDocking() {
        if isCodexChatWindowDockingEnabled {
            isCodexChatWindowAttachmentLocked = false
            isCodexChatWindowDockingEnabled = false
        } else {
            isCodexChatWindowDockingEnabled = true
        }
    }

    func toggleCodexChatWindowAttachmentLock() {
        if isCodexChatWindowAttachmentLocked {
            isCodexChatWindowAttachmentLocked = false
        } else {
            HarvisCodexChatWindowController.shared
                .requestStrongAttachmentPermissionIfNeeded()
            isCodexChatWindowDockingEnabled = true
            isCodexChatWindowAttachmentLocked = true
        }
    }

    func updateCodexChatWindowDocked(_ docked: Bool, side: String? = nil) {
        if isCodexChatWindowDocked != docked {
            isCodexChatWindowDocked = docked
        }
        let nextSide = docked ? side : nil
        if codexChatWindowDockSide != nextSide {
            codexChatWindowDockSide = nextSide
        }
    }

    func tags(for thread: CodexThreadSummary) -> [String] {
        codexThreadTags[codexThreadStorageKey(thread)] ?? []
    }

    func tags(for thread: ManagedChatThread) -> [String] {
        codexThreadTags[managedChatStorageKey(thread)] ?? []
    }

    func setTags(_ tags: [String], for thread: CodexThreadSummary) {
        let normalized = CodexThreadPreferences.normalizedTags(tags)
        let key = codexThreadStorageKey(thread)
        if normalized.isEmpty {
            codexThreadTags.removeValue(forKey: key)
        } else {
            codexThreadTags[key] = normalized
        }
        codexPreferences.saveTags(codexThreadTags)
    }

    func setTags(_ tags: [String], for thread: ManagedChatThread) {
        let normalized = CodexThreadPreferences.normalizedTags(tags)
        let key = managedChatStorageKey(thread)
        if normalized.isEmpty {
            codexThreadTags.removeValue(forKey: key)
        } else {
            codexThreadTags[key] = normalized
        }
        codexPreferences.saveTags(codexThreadTags)
    }

    func removeTag(_ tag: String, from thread: CodexThreadSummary) {
        setTags(tags(for: thread).filter { $0.caseInsensitiveCompare(tag) != .orderedSame }, for: thread)
    }

    func removeTag(_ tag: String, from thread: ManagedChatThread) {
        setTags(tags(for: thread).filter { $0.caseInsensitiveCompare(tag) != .orderedSame }, for: thread)
    }

    func appendTag(_ tag: String, toStorageKey key: String) {
        let existing = codexThreadTags[key] ?? []
        guard !existing.contains(where: {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }) else { return }
        // System-derived tags such as `done` must not be dropped merely
        // because all eight user tag slots are occupied.
        let normalized = CodexThreadPreferences.normalizedTags([tag] + existing)
        guard normalized != existing else { return }
        codexThreadTags[key] = normalized
        codexPreferences.saveTags(codexThreadTags)
    }

    func syncVerifiedHandoffTags(
        _ transactions: [CodexConversationHandoff]
    ) {
        for transaction in transactions where transaction.canMarkSourceDone {
            appendTag(
                "done",
                toStorageKey: "\(transaction.homeID)::\(transaction.sourceThreadID)"
            )
        }
    }

    func isThreadPinned(_ thread: CodexThreadSummary) -> Bool {
        pinnedCodexThreadKeys.contains(codexThreadStorageKey(thread))
    }

    func isThreadPinned(_ thread: ManagedChatThread) -> Bool {
        pinnedCodexThreadKeys.contains(managedChatStorageKey(thread))
    }

    func toggleThreadPin(_ thread: CodexThreadSummary) {
        let key = codexThreadStorageKey(thread)
        if pinnedCodexThreadKeys.contains(key) {
            pinnedCodexThreadKeys.remove(key)
        } else {
            pinnedCodexThreadKeys.insert(key)
        }
        codexPreferences.savePins(pinnedCodexThreadKeys)
    }

    func toggleThreadPin(_ thread: ManagedChatThread) {
        let key = managedChatStorageKey(thread)
        if pinnedCodexThreadKeys.contains(key) {
            pinnedCodexThreadKeys.remove(key)
        } else {
            pinnedCodexThreadKeys.insert(key)
        }
        codexPreferences.savePins(pinnedCodexThreadKeys)
    }

    func isUnnamedSubagentVisible(_ thread: ManagedChatThread) -> Bool {
        visibleUnnamedSubagentKeys.contains(managedChatStorageKey(thread))
    }

    func setUnnamedSubagentVisible(
        _ visible: Bool,
        thread: ManagedChatThread
    ) {
        let key = managedChatStorageKey(thread)
        if visible {
            visibleUnnamedSubagentKeys.insert(key)
        } else {
            visibleUnnamedSubagentKeys.remove(key)
        }
        codexPreferences.saveVisibleUnnamedSubagents(visibleUnnamedSubagentKeys)
    }

    func attention(for project: ManagedChatProjectIdentity) -> ManagedAttentionPreference {
        managedProjectAttention[project.id] ?? ManagedAttentionPreference()
    }

    func sourceProject(for thread: ManagedChatThread) -> ManagedChatProjectIdentity {
        ManagedChatProjectResolver.resolveSource(thread: thread)
    }

    func projectAssignment(
        for thread: ManagedChatThread
    ) -> ManagedChatProjectAssignment? {
        managedConversationProjectAssignments[managedChatStorageKey(thread)]
    }

    @discardableResult
    func assignConversation(
        _ thread: ManagedChatThread,
        to project: ManagedChatProjectIdentity,
        source: ManagedChatProjectAssignmentSource,
        at assignedAt: Date = Date()
    ) -> Bool {
        guard projectOrganizationLoadError == nil,
              managedChatThreads.contains(where: { $0.id == thread.id }) else { return false }
        let knownProject = managedChatProjectCatalog.first { $0.id == project.id }
        guard let knownProject, knownProject == project else { return false }
        let key = managedChatStorageKey(thread)
        let sourceProject = ManagedChatProjectResolver.resolveSource(thread: thread)
        var next = managedProjectOrganization
        if sourceProject.id == project.id {
            next.assignments.removeValue(forKey: key)
        } else {
            next.assignments[key] = ManagedChatProjectAssignment(
                project: project,
                source: source,
                assignedAt: assignedAt
            )
        }
        guard next.assignments != managedProjectOrganization.assignments else { return true }
        next.revision += 1
        return persistProjectOrganization(next)
    }

    func clearConversationProjectAssignment(_ thread: ManagedChatThread) {
        guard projectOrganizationLoadError == nil else { return }
        let key = managedChatStorageKey(thread)
        var next = managedProjectOrganization
        guard next.assignments.removeValue(forKey: key) != nil else {
            return
        }
        next.revision += 1
        _ = persistProjectOrganization(next)
    }

    func setAttention(
        _ preference: ManagedAttentionPreference,
        for project: ManagedChatProjectIdentity
    ) {
        if preference.isEmpty {
            managedProjectAttention.removeValue(forKey: project.id)
        } else {
            managedProjectAttention[project.id] = preference
        }
        codexPreferences.saveProjectAttention(managedProjectAttention)
    }

    func attention(for thread: ManagedChatThread) -> ManagedAttentionPreference {
        managedConversationAttention[managedChatStorageKey(thread)]
            ?? ManagedAttentionPreference()
    }

    func setAttention(
        _ preference: ManagedAttentionPreference,
        for thread: ManagedChatThread
    ) {
        let key = managedChatStorageKey(thread)
        if preference.isEmpty {
            managedConversationAttention.removeValue(forKey: key)
        } else {
            managedConversationAttention[key] = preference
        }
        codexPreferences.saveConversationAttention(managedConversationAttention)
    }

    func runNetworkQuickAction(_ action: String, route: String) {
        Task {
            _ = await performNetworkConsoleAction(["action": action, "route": route])
        }
    }

    func openPort(_ item: PortStatusItem) {
        guard let raw = item.url, let url = URL(string: raw), !raw.isEmpty else {
            openPorts()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openDesktopApp() {
        HarvisDesktopWindowController.shared.show(model: self)
    }

    func openAgentMailWeb() {
        if let url = URL(string: "https://agent.qq.com") {
            NSWorkspace.shared.open(url)
        }
    }

    func studioURL() -> URL? {
        localURL(path: "/studio/")
    }

    func networkURL() -> URL? {
        localURL(path: "/network/")
    }

    func openLocalPath(_ path: String, extraQueryItems: [URLQueryItem] = []) {
        if let url = localURL(path: path, extraQueryItems: extraQueryItems) {
            NSWorkspace.shared.open(url)
        }
    }

    func codexThreadStorageKey(_ thread: CodexThreadSummary) -> String {
        "\(codexThreadsSourceHomeID ?? "unscoped")::\(thread.id)"
    }

    func managedChatStorageKey(_ thread: ManagedChatThread) -> String {
        if thread.isCodex {
            // A managed card already carries the CODEX_HOME scope it was
            // projected from. Never rebuild this key from the account that is
            // selected now: account switches can overlap async UI callbacks,
            // and identical thread IDs may legitimately exist in two homes.
            return "\(thread.sourceScope)::\(thread.sourceID)"
        }
        return thread.id
    }

    func localURL(path: String, extraQueryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "root", value: expanded(workspaceRoot)),
            URLQueryItem(name: "profile_root", value: profileRoot)
        ] + extraQueryItems
        return components.url
    }

    func revealLogs() {
        let logs = URL(fileURLWithPath: expanded("~/.harvis/logs"))
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([logs])
    }

    func revealWorkspaceVolume() {
        guard let disk = workspaceDiskInfo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([disk.volumeURL])
    }

    func revealVolume(_ disk: DiskInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([disk.volumeURL])
    }

}
