import AppKit
import Foundation

struct FinderContextMenuAction: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let placement: String
    let systemImage: String
    let description: String
}

struct FinderContextMenuScope: Codable, Sendable {
    let title: String?
    let summary: String?
    let roots: [String]?
    let limitations: [String]?
}

struct FinderContextMenuManifest: Codable, Sendable {
    let schemaVersion: Int
    let scope: FinderContextMenuScope?
    let actions: [FinderContextMenuAction]

    static let fallback = FinderContextMenuManifest(
        schemaVersion: 1,
        scope: FinderContextMenuScope(
            title: "所有真实文件系统路径",
            summary: "监听根目录与全部挂载卷，并在卷变化时自动刷新。",
            roots: ["/", "mounted-volumes"],
            limitations: ["Finder 的“最近使用”等虚拟视图不保证提供真实文件路径。"]
        ),
        actions: [
            FinderContextMenuAction(
                id: "toolbar-copy-current-path",
                title: "复制当前路径",
                placement: "toolbar",
                systemImage: "doc.on.clipboard",
                description: "从 Finder 工具栏复制当前文件夹的完整路径。"
            ),
            FinderContextMenuAction(
                id: "cut-selected-items",
                title: "剪切",
                placement: "selected-items",
                systemImage: "scissors",
                description: "标记选中的文件或文件夹，随后移动到目标目录。"
            ),
            FinderContextMenuAction(
                id: "copy-selected-paths",
                title: "复制文件路径",
                placement: "selected-items",
                systemImage: "doc.on.clipboard",
                description: "复制一个或多个选中项目的完整路径。"
            ),
            FinderContextMenuAction(
                id: "create-text-file",
                title: "新建 TXT 文件",
                placement: "container",
                systemImage: "doc.badge.plus",
                description: "在当前文件夹中创建不覆盖已有内容的文本文件。"
            ),
            FinderContextMenuAction(
                id: "copy-current-folder-path",
                title: "复制当前文件夹路径",
                placement: "container",
                systemImage: "doc.on.clipboard",
                description: "从文件夹空白区域复制当前目录路径。"
            ),
            FinderContextMenuAction(
                id: "paste-cut-items",
                title: "粘贴剪切项到此处",
                placement: "container",
                systemImage: "arrow.right.doc.on.clipboard",
                description: "把已剪切项目安全移动到当前目录。"
            ),
            FinderContextMenuAction(
                id: "open-terminal",
                title: "在此处打开终端",
                placement: "container",
                systemImage: "apple.terminal",
                description: "让终端直接进入当前文件夹。"
            ),
        ]
    )
}

enum FinderContextExtensionState: Equatable, Sendable {
    case checking
    case enabled
    case disabled
    case missing
    case failed

    var title: String {
        switch self {
        case .checking: return "正在检查"
        case .enabled: return "扩展已启用"
        case .disabled: return "扩展未启用"
        case .missing: return "尚未安装"
        case .failed: return "检查失败"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: return "arrow.triangle.2.circlepath"
        case .enabled: return "checkmark.seal.fill"
        case .disabled: return "exclamationmark.triangle.fill"
        case .missing: return "shippingbox"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

private struct FinderContextMenuSnapshot: Sendable {
    let state: FinderContextExtensionState
    let installedVersion: String?
    let extensionRecord: String?
    let manifest: FinderContextMenuManifest
    let mountedVolumeCount: Int
    let sourceRoot: String?
    let error: String?
}

struct FinderContextCommandResult: Sendable {
    let status: Int32
    let output: String
}

@MainActor
final class FinderContextMenuManagerModel: ObservableObject {
    static let shared = FinderContextMenuManagerModel()

    nonisolated static let extensionID = "dev.harzva.FinderContextTools.Extension"
    nonisolated static let installedAppPath = "/Applications/FinderContextTools.app"
    nonisolated static let shortCommandTimeout: TimeInterval = 8
    nonisolated static let sourceVerificationTimeout: TimeInterval = 120

    @Published private(set) var state: FinderContextExtensionState = .checking
    @Published private(set) var installedVersion: String?
    @Published private(set) var extensionRecord: String?
    @Published private(set) var manifest = FinderContextMenuManifest.fallback
    @Published private(set) var mountedVolumeCount = 0
    @Published private(set) var sourceRoot: String?
    @Published private(set) var lastMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false

    private init() {}

    func refresh() {
        guard !isBusy else { return }
        state = .checking
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.loadSnapshot()
            }.value
            state = snapshot.state
            installedVersion = snapshot.installedVersion
            extensionRecord = snapshot.extensionRecord
            manifest = snapshot.manifest
            mountedVolumeCount = snapshot.mountedVolumeCount
            sourceRoot = snapshot.sourceRoot
            lastError = snapshot.error
        }
    }

    func enableAndReload() {
        let extensionPath = Self.installedAppPath
            + "/Contents/PlugIns/FinderContextToolsExtension.appex"
        performOperation(successMessage: "Finder 增强菜单已启用并重新加载。") {
            guard FileManager.default.fileExists(atPath: extensionPath) else {
                throw FinderContextMenuManagerError.message("找不到已安装的 Finder 扩展。")
            }
            try Self.requireSuccess("/usr/bin/pluginkit", ["-a", extensionPath])
            try Self.requireSuccess("/usr/bin/pluginkit", ["-e", "use", "-i", Self.extensionID])
            try Self.requireSuccess("/usr/bin/killall", ["Finder"])
        }
    }

    func installOrUpdateFromSource() {
        guard let sourceRoot else {
            lastError = "尚未定位 FinderContextTools 源码目录。"
            return
        }
        let script = URL(fileURLWithPath: sourceRoot)
            .appendingPathComponent("script/build_and_run.sh")
            .path
        performOperation(successMessage: "Finder 增强菜单已从源码更新。") {
            guard FileManager.default.isExecutableFile(atPath: script) else {
                throw FinderContextMenuManagerError.message("源码目录缺少可执行的安装脚本。")
            }
            try Self.requireSuccess(
                script,
                ["--verify"],
                timeout: Self.sourceVerificationTimeout
            )
        }
    }

    func revealInstalledApplication() {
        let url = URL(fileURLWithPath: Self.installedAppPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "FinderContextTools 尚未安装。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        lastError = nil
    }

    func revealSourceRoot() {
        guard let sourceRoot else {
            lastError = "尚未定位 FinderContextTools 源码目录。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sourceRoot)])
        lastError = nil
    }

    func chooseSourceRoot() {
        let panel = NSOpenPanel()
        panel.title = "选择 FinderContextTools 源码目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let sourceRoot {
            panel.directoryURL = URL(fileURLWithPath: sourceRoot)
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard Self.isSourceRoot(selected.path) else {
            lastError = "所选目录不是有效的 FinderContextTools 源码目录。"
            return
        }
        UserDefaults.standard.set(selected.path, forKey: "harvisBar.finderContextToolsRoot")
        sourceRoot = selected.standardizedFileURL.path
        lastError = nil
        lastMessage = "已保存 FinderContextTools 源码目录。"
    }

    func openFinderExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.FinderSync",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        ]
        for rawURL in candidates {
            if let url = URL(string: rawURL), NSWorkspace.shared.open(url) {
                lastError = nil
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func performOperation(
        successMessage: String,
        operation: @escaping @Sendable () throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        lastMessage = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    try operation()
                    return (message: successMessage, error: Optional<String>.none)
                } catch {
                    return (message: "", error: error.localizedDescription)
                }
            }.value
            isBusy = false
            lastMessage = outcome.error == nil ? outcome.message : nil
            lastError = outcome.error
            refresh()
        }
    }

    nonisolated private static func loadSnapshot() -> FinderContextMenuSnapshot {
        let fileManager = FileManager.default
        let appURL = URL(fileURLWithPath: installedAppPath, isDirectory: true)
        let appExists = fileManager.fileExists(atPath: appURL.path)
        let version = Bundle(url: appURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let manifestURL = appURL
            .appendingPathComponent("Contents/Resources/context-menu-actions.json")
        let manifest: FinderContextMenuManifest
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(FinderContextMenuManifest.self, from: data) {
            manifest = decoded
        } else {
            manifest = .fallback
        }

        let pluginResult = runCommand(
            "/usr/bin/pluginkit",
            ["-m", "-A", "-D", "-p", "com.apple.FinderSync"]
        )
        let record = pluginResult.output
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains(extensionID) }
        let trimmedRecord = record?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedState: FinderContextExtensionState
        let error: String?
        if pluginResult.status != 0 {
            resolvedState = appExists ? .failed : .missing
            error = pluginResult.output.isEmpty ? "无法读取 Finder 扩展注册状态。" : pluginResult.output
        } else if trimmedRecord?.hasPrefix("+") == true {
            resolvedState = .enabled
            error = nil
        } else if record != nil || appExists {
            resolvedState = .disabled
            error = nil
        } else {
            resolvedState = .missing
            error = nil
        }

        let mountedVolumeCount = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        )?.count ?? 0

        return FinderContextMenuSnapshot(
            state: resolvedState,
            installedVersion: version,
            extensionRecord: trimmedRecord,
            manifest: manifest,
            mountedVolumeCount: mountedVolumeCount,
            sourceRoot: detectSourceRoot(),
            error: error
        )
    }

    nonisolated private static func detectSourceRoot() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let configured = UserDefaults.standard.string(forKey: "harvisBar.finderContextToolsRoot")
        let candidates = [environment["FINDER_CONTEXT_TOOLS_ROOT"], configured]
            .compactMap { $0 }

        for rawPath in candidates {
            let path = (rawPath as NSString).expandingTildeInPath
            if isSourceRoot(path) {
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
        }
        return nil
    }

    nonisolated private static func isSourceRoot(_ path: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: path + "/build.sh")
            && fileManager.fileExists(atPath: path + "/Sources/Extension/FinderSync.swift")
    }

    nonisolated private static func requireSuccess(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = shortCommandTimeout
    ) throws {
        let result = runCommand(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            throw FinderContextMenuManagerError.message(
                result.output.isEmpty ? "命令执行失败：\(executable)" : result.output
            )
        }
    }

    nonisolated static func runCommand(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = shortCommandTimeout
    ) -> FinderContextCommandResult {
        do {
            let result = try BoundedProcessRunner.runSynchronously(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
            let output = [result.standardOutput, result.standardError]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return FinderContextCommandResult(
                status: result.terminationStatus,
                output: output
            )
        } catch {
            return FinderContextCommandResult(status: -1, output: error.localizedDescription)
        }
    }
}

private enum FinderContextMenuManagerError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}
