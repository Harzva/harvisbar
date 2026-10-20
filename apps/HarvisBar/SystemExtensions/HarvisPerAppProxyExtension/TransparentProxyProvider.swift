import Foundation
import HarvisProxyCore
import Network
@preconcurrency import NetworkExtension

@available(macOS 15.0, *)
final class TransparentProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling, @unchecked Sendable {
    private static let configurationKey = "harvisConfiguration"
    private let queue = DispatchQueue(label: "com.harzva.harvisbar.per-app-proxy.flows")
    private var configuration: PerAppProxyConfiguration?
    private var bridges: [ObjectIdentifier: SOCKS5TCPBridge] = [:]
    private var protectedFlowCount: UInt64 = 0
    private var rejectedUDPCount: UInt64 = 0

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            configuration = try loadConfiguration()
            let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            settings.includedNetworkRules = [
                NENetworkRule(
                    __remoteNetwork: nil,
                    remotePrefix: 0,
                    localNetwork: nil,
                    localPrefix: 0,
                    protocol: .any,
                    direction: .outbound
                )
            ]
            setTunnelNetworkSettings(settings, completionHandler: completionHandler)
        } catch {
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.bridges.removeAll()
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let configuration, matches(flow, configuration: configuration) else { return false }

        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            guard let target = SOCKS5TCPBridge.target(for: tcpFlow),
                  !ProxyDestinationPolicy.shouldBypass(target.address)
            else { return false }
            let key = ObjectIdentifier(tcpFlow)
            guard let bridge = SOCKS5TCPBridge(
                flow: tcpFlow,
                endpoint: configuration.endpoint,
                queue: queue,
                onFinished: { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        self.bridges.removeValue(forKey: key)
                    }
                }
            ) else {
                return false
            }
            queue.async { [weak self] in
                guard let self else { return }
                self.protectedFlowCount &+= 1
                self.bridges[key] = bridge
                bridge.start()
            }
            return true
        }

        return rejectUDP(flow)
    }

    func handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint
    ) -> Bool {
        guard let configuration,
              matches(flow, configuration: configuration),
              let address = Self.socksAddress(for: remoteEndpoint),
              !ProxyDestinationPolicy.shouldBypass(address)
        else { return false }
        return rejectUDP(flow)
    }

    private func rejectUDP(_ flow: NEAppProxyFlow) -> Bool {
        rejectedUDPCount &+= 1
        let error = NSError(
            domain: NEAppProxyErrorDomain,
            code: NEAppProxyFlowError.refused.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Harvis v1 blocks matched UDP so it cannot bypass SOCKS5 TCP."]
        )
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        return true
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let snapshot: [String: UInt64] = [
            "protectedFlowCount": protectedFlowCount,
            "activeFlowCount": UInt64(bridges.count),
            "rejectedUDPCount": rejectedUDPCount
        ]
        completionHandler?(try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]))
    }

    private func loadConfiguration() throws -> PerAppProxyConfiguration {
        guard let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let values = providerProtocol.providerConfiguration,
              let data = values[Self.configurationKey] as? Data
        else {
            throw NSError(
                domain: "HarvisPerAppProxyExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing per-app proxy configuration."]
            )
        }
        return try JSONDecoder().decode(PerAppProxyConfiguration.self, from: data)
    }

    private func matches(
        _ flow: NEAppProxyFlow,
        configuration: PerAppProxyConfiguration
    ) -> Bool {
        guard configuration.isEnabled,
              let signingIdentifier = flow.metaData.sourceAppSigningIdentifier as String?,
              let uniqueIdentifier = flow.metaData.sourceAppUniqueIdentifier as Data?
        else { return false }
        return configuration.matchingRule(for: .init(
            signingIdentifier: signingIdentifier,
            codeDirectoryHash: Array(uniqueIdentifier)
        )) != nil
    }

    private static func socksAddress(for endpoint: Network.NWEndpoint) -> SOCKS5Address? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(address): return .ipv4(Array(address.rawValue))
        case let .ipv6(address): return .ipv6(Array(address.rawValue))
        case let .name(name, _): return .domain(name)
        @unknown default: return nil
        }
    }
}
