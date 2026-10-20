import Foundation
import HarvisProxyCore
@preconcurrency import NetworkExtension
import SystemExtensions

enum PerAppProxyInstallationState: String, Equatable, Sendable {
    case extensionMissing
    case approvalRequired
    case installed
    case running
    case failed

    var label: String {
        switch self {
        case .extensionMissing: return "开发构建缺少已签名扩展"
        case .approvalRequired: return "需要安装并授权系统扩展"
        case .installed: return "已安装 · 未启用"
        case .running: return "运行中"
        case .failed: return "启动失败"
        }
    }
}

enum PerAppProxyControllerError: Error, LocalizedError {
    case extensionNotBundled

    var errorDescription: String? {
        switch self {
        case .extensionNotBundled:
            return "当前 HarvisBar 未内嵌已签名的按应用代理系统扩展"
        }
    }
}

@MainActor
final class PerAppProxyController {
    static let extensionBundleIdentifier = "com.harzva.harvisbar.per-app-proxy"
    static let configurationKey = "harvisConfiguration"

    private let activator = PerAppProxySystemExtensionActivator()

    func installationState(in hostBundle: Bundle = .main) -> PerAppProxyInstallationState {
        guard bundledExtensionURL(in: hostBundle) != nil else { return .extensionMissing }
        return .approvalRequired
    }

    func requestInstallation(completion: @escaping (Result<PerAppProxyInstallationState, Error>) -> Void) {
        guard bundledExtensionURL(in: .main) != nil else {
            completion(.failure(PerAppProxyControllerError.extensionNotBundled))
            return
        }
        activator.activate { result in
            switch result {
            case .success: completion(.success(.installed))
            case let .failure(error): completion(.failure(error))
            }
        }
    }

    func setEnabled(
        _ enabled: Bool,
        configuration: PerAppProxyConfiguration,
        completion: @escaping (Result<PerAppProxyInstallationState, Error>) -> Void
    ) {
        loadManager { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(manager):
                do {
                    let providerProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol)
                        ?? NETunnelProviderProtocol()
                    providerProtocol.providerBundleIdentifier = Self.extensionBundleIdentifier
                    providerProtocol.serverAddress = "127.0.0.1"
                    providerProtocol.providerConfiguration = [
                        Self.configurationKey: try JSONEncoder().encode(configuration)
                    ]
                    manager.protocolConfiguration = providerProtocol
                    manager.localizedDescription = "Harvis Per-App Proxy"
                    manager.isEnabled = enabled
                    manager.saveToPreferences { error in
                        if let error {
                            completion(.failure(error))
                            return
                        }
                        manager.loadFromPreferences { error in
                            if let error {
                                completion(.failure(error))
                                return
                            }
                            do {
                                if enabled {
                                    try manager.connection.startVPNTunnel()
                                    completion(.success(.running))
                                } else {
                                    manager.connection.stopVPNTunnel()
                                    completion(.success(.installed))
                                }
                            } catch {
                                completion(.failure(error))
                            }
                        }
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func loadManager(
        completion: @escaping (Result<NETransparentProxyManager, Error>) -> Void
    ) {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let existing = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == Self.extensionBundleIdentifier
            }) {
                completion(.success(existing))
            } else {
                completion(.success(NETransparentProxyManager()))
            }
        }
    }

    private func bundledExtensionURL(in hostBundle: Bundle) -> URL? {
        let url = hostBundle.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("HarvisPerAppProxyExtension.systemextension", isDirectory: true)
        guard
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}

@MainActor
private final class PerAppProxySystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    private var completion: ((Result<Void, Error>) -> Void)?

    func activate(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: PerAppProxyController.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // macOS owns the approval UI; the model keeps showing approvalRequired.
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            completion?(.success(()))
            completion = nil
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            completion?(.failure(error))
            completion = nil
        }
    }
}
