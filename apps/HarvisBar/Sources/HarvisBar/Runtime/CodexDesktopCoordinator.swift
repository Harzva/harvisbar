import AppKit
import Carbon
import Foundation

struct CodexDesktopInstance: Equatable, Sendable {
    let pid: Int32
    let homePath: String?
}

@MainActor
protocol CodexDesktopHosting: AnyObject {
    func instances() -> [CodexDesktopInstance]
    func launch(homePath: String, homeID: String) async throws -> CodexDesktopInstance
    func activate(pid: Int32) -> Bool
    func openThread(_ url: URL, pid: Int32, newWindow: Bool) async throws
}

/// Normal opens reuse the exact account process. Different cards awaiting the
/// same account launch share one launch task; no global launchd state is changed.
@MainActor
final class CodexDesktopCoordinator {
    struct Receipt: Equatable {
        let pid: Int32
        let reused: Bool
        /// The caller's intent, not confirmation that navigation has completed.
        let requestedNewWindow: Bool
    }
    private struct OpenKey: Hashable {
        let home: String
        let threadID: String?
        let newWindow: Bool
    }
    private struct InstanceResolution {
        let instance: CodexDesktopInstance
        let initiatedLaunch: Bool
    }
    private let host: any CodexDesktopHosting
    private var launches: [String: Task<CodexDesktopInstance, Error>] = [:]
    private var opens: [OpenKey: Task<Receipt, Error>] = [:]

    init(host: (any CodexDesktopHosting)? = nil) {
        self.host = host ?? NativeCodexDesktopHost()
    }

    func open(homePath: String, homeID: String, threadID: String? = nil, newWindow: Bool = false) async throws -> Receipt {
        guard homePath.hasPrefix("/"), !homeID.isEmpty else { throw CodexDesktopOpenError.invalidTarget }
        let home = CodexDesktopIdentity.normalizedHomePath(homePath)
        let url = try threadID.map { try Self.threadURL($0) }
        let key = OpenKey(home: home, threadID: threadID, newWindow: newWindow)
        if let task = opens[key] { return try await task.value }
        let task = Task { @MainActor in
            let existing = self.matchingInstance(home: home)
            let resolution: InstanceResolution
            if let existing { resolution = .init(instance: existing, initiatedLaunch: false) }
            else { resolution = try await self.ensureInstance(home: home, homeID: homeID) }
            let instance = resolution.instance
            // Re-read identity after launch/await. Never route a global URL to a
            // default handler or to a PID whose account can no longer be proved.
            guard self.host.instances().contains(where: { $0.pid == instance.pid && $0.homePath == home }) else {
                throw CodexDesktopOpenError.identityChanged
            }
            // Only the request that initiated the application launch owns its
            // first window. An explicit new-window request that joined that
            // launch still needs its own additional window.
            if let url {
                try await self.host.openThread(url, pid: instance.pid, newWindow: newWindow && !resolution.initiatedLaunch)
            }
            guard self.host.activate(pid: instance.pid) else { throw CodexDesktopOpenError.activationFailed }
            return Receipt(pid: instance.pid, reused: !resolution.initiatedLaunch, requestedNewWindow: newWindow)
        }
        opens[key] = task
        defer { opens.removeValue(forKey: key) }
        return try await task.value
    }

    private func matchingInstance(home: String) -> CodexDesktopInstance? {
        host.instances().first { $0.homePath == home }
    }

    private func ensureInstance(home: String, homeID: String) async throws -> InstanceResolution {
        if let task = launches[home] {
            return .init(instance: try await task.value, initiatedLaunch: false)
        }
        let task = Task { @MainActor in try await self.host.launch(homePath: home, homeID: homeID) }
        launches[home] = task
        defer { launches.removeValue(forKey: home) }
        return .init(instance: try await task.value, initiatedLaunch: true)
    }

    static func threadURL(_ id: String) throws -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "codex://threads/\(encoded)") else { throw CodexDesktopOpenError.invalidTarget }
        return url
    }
}

private enum CodexDesktopOpenError: LocalizedError {
    case invalidTarget, applicationMissing, identityChanged, launchFailed, activationFailed
    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "无法确定目标 Codex 账号或会话。"
        case .applicationMissing: return "未找到 Codex 桌面应用。"
        case .identityChanged: return "Codex 实例的账号未通过核对，未打开会话。请刷新后重试。"
        case .launchFailed: return "Codex 账号窗口未能启动。"
        case .activationFailed: return "无法将目标 Codex 账号窗口切换到前台，请重试。"
        }
    }
}

@MainActor
private final class NativeCodexDesktopHost: CodexDesktopHosting {
    private let workspace = NSWorkspace.shared
    private let bundleID = "com.openai.codex"
    private var deliveries: [Int32: (id: UUID, task: Task<Void, Error>)] = [:]

    func instances() -> [CodexDesktopInstance] {
        let frontmostPID = workspace.frontmostApplication?.processIdentifier
        return workspace.runningApplications.filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
            .sorted { lhs, rhs in
                if lhs.processIdentifier == rhs.processIdentifier { return false }
                if lhs.processIdentifier == frontmostPID { return true }
                if rhs.processIdentifier == frontmostPID { return false }
                return lhs.processIdentifier < rhs.processIdentifier
            }
            .map { app in
                .init(pid: app.processIdentifier, homePath: CodexDesktopIdentity.read(pid: app.processIdentifier)?.homePath)
            }
    }

    func launch(homePath: String, homeID: String) async throws -> CodexDesktopInstance {
        guard let app = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            throw CodexDesktopOpenError.applicationMissing
        }
        // The hash is a path component, never a caller-provided directory.
        guard !homeID.isEmpty, homeID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw CodexDesktopOpenError.invalidTarget
        }
        let data = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HarvisBar/codex-home-desktops")
            .appendingPathComponent(homeID, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        configuration.environment = ["CODEX_HOME": homePath, "CODEX_ELECTRON_USER_DATA_PATH": data.path]
        configuration.arguments = ["--user-data-dir=\(data.path)"]
        let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            workspace.openApplication(at: app, configuration: configuration) { application, error in
                if let error { continuation.resume(throwing: error) }
                else if let application { continuation.resume(returning: application) }
                else { continuation.resume(throwing: CodexDesktopOpenError.launchFailed) }
            }
        }
        return .init(pid: application.processIdentifier, homePath: homePath)
    }

    func activate(pid: Int32) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else { return false }
        return application.activate(options: [.activateAllWindows])
    }

    func openThread(_ url: URL, pid: Int32, newWindow: Bool) async throws {
        guard let expectedHome = CodexDesktopIdentity.read(pid: pid)?.homePath else {
            throw CodexDesktopOpenError.identityChanged
        }
        let previous = deliveries[pid]?.task
        let deliveryID = UUID()
        let task = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            guard self.instances().contains(where: { $0.pid == pid && $0.homePath == expectedHome }) else {
                throw CodexDesktopOpenError.identityChanged
            }
            // A newly created window must belong to the foreground account.
            // Serialize creation/navigation so another card cannot steal focus.
            guard self.activate(pid: pid) else { throw CodexDesktopOpenError.activationFailed }
            try await Task.detached {
                let target = NSAppleEventDescriptor(processIdentifier: pid)
                if newWindow {
                    let create = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAECreateElement),
                        targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                    create.setParam(NSAppleEventDescriptor(typeCode: OSType(cWindow)), forKeyword: AEKeyword(keyAEObjectClass))
                    let properties = NSAppleEventDescriptor.record()
                    properties.setDescriptor(NSAppleEventDescriptor(int32: 1), forKeyword: AEKeyword(pIndex))
                    create.setParam(properties, forKeyword: AEKeyword(keyAEPropData))
                    let reply = try create.sendEvent(options: [.waitForReply, .canInteract], timeout: 5)
                    if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                        throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
                    }
                }
                let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                    targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
                // Electron exposes no completion acknowledgement for this URL
                // handler. Success here means the request was dispatched only.
                _ = try event.sendEvent(options: [.noReply, .canInteract], timeout: 5)
            }.value
        }
        deliveries[pid] = (deliveryID, task)
        defer {
            if deliveries[pid]?.id == deliveryID { deliveries.removeValue(forKey: pid) }
        }
        try await task.value
    }
}
