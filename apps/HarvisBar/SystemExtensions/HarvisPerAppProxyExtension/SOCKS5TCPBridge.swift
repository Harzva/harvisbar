import Foundation
import HarvisProxyCore
import Network
@preconcurrency import NetworkExtension

@available(macOS 15.0, *)
final class SOCKS5TCPBridge: @unchecked Sendable {
    private let flow: NEAppProxyTCPFlow
    private let connection: NWConnection
    private let targetAddress: SOCKS5Address
    private let targetPort: UInt16
    private let queue: DispatchQueue
    private let onFinished: @Sendable () -> Void
    private var state = TCPBridgeStateMachine()
    private var replyBuffer = Data()
    private var finished = false

    init?(
        flow: NEAppProxyTCPFlow,
        endpoint: ProxyEndpoint,
        queue: DispatchQueue,
        onFinished: @escaping @Sendable () -> Void
    ) {
        guard let target = Self.target(for: flow) else { return nil }
        self.flow = flow
        self.targetAddress = target.address
        self.targetPort = target.port
        self.queue = queue
        self.onFinished = onFinished
        guard let proxyPort = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return nil }
        self.connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: proxyPort,
            using: .tcp
        )
    }

    func start() {
        do {
            try state.handle(.start)
        } catch {
            finish(error)
            return
        }
        connection.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            switch connectionState {
            case .ready:
                self.connection.stateUpdateHandler = nil
                self.proxyConnected()
            case let .failed(error): self.finish(error)
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func proxyConnected() {
        do { try state.handle(.proxyConnected) } catch { return finish(error) }
        send(SOCKS5Protocol.noAuthenticationGreeting) { [weak self] error in
            guard let self else { return }
            if let error { return self.finish(error) }
            self.receiveMethodSelection()
        }
    }

    private func receiveMethodSelection() {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { return self.finish(error) }
            do {
                _ = try SOCKS5Protocol.validateMethodSelection(data ?? Data())
                try self.state.handle(.methodAccepted)
                let request = try SOCKS5Protocol.connectRequest(
                    to: self.targetAddress,
                    port: self.targetPort
                )
                self.send(request) { [weak self] error in
                    guard let self else { return }
                    if let error { return self.finish(error) }
                    self.receiveConnectReply()
                }
            } catch {
                self.finish(error)
            }
        }
    }

    private func receiveConnectReply() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { return self.finish(error) }
            if let data { self.replyBuffer.append(data) }
            do {
                let reply = try SOCKS5Protocol.parseConnectReply(self.replyBuffer)
                let trailing = self.replyBuffer.dropFirst(reply.consumedByteCount)
                try self.state.handle(.connectionAccepted)
                self.openApplicationFlow(initialProxyPayload: Data(trailing))
            } catch SOCKS5Error.incompleteFrame {
                self.receiveConnectReply()
            } catch {
                self.finish(error)
            }
        }
    }

    private func openApplicationFlow(initialProxyPayload: Data) {
        flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self else { return }
            if let error { return self.finish(error) }
            do { try self.state.handle(.applicationFlowOpened) } catch { return self.finish(error) }
            if initialProxyPayload.isEmpty {
                self.beginCopying()
            } else {
                self.flow.write(initialProxyPayload) { [weak self] error in
                    guard let self else { return }
                    if let error { return self.finish(error) }
                    self.beginCopying()
                }
            }
        }
    }

    private func beginCopying() {
        readFromApplication()
        readFromProxy()
    }

    private func readFromApplication() {
        flow.readData { [weak self] data, error in
            guard let self else { return }
            if let error { return self.finish(error) }
            guard let data, !data.isEmpty else {
                self.reachedEOF(.application)
                self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return
            }
            self.send(data) { [weak self] error in
                guard let self else { return }
                if let error { return self.finish(error) }
                self.readFromApplication()
            }
        }
    }

    private func readFromProxy() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { return self.finish(error) }
            if let data, !data.isEmpty {
                self.flow.write(data) { [weak self] error in
                    guard let self else { return }
                    if let error { return self.finish(error) }
                    if isComplete {
                        self.flow.closeWriteWithError(nil)
                        self.reachedEOF(.proxy)
                    } else {
                        self.readFromProxy()
                    }
                }
            } else if isComplete {
                self.flow.closeWriteWithError(nil)
                self.reachedEOF(.proxy)
            } else {
                self.readFromProxy()
            }
        }
    }

    private func reachedEOF(_ side: TCPBridgeSide) {
        do {
            let stage = try state.handle(.reachedEOF(side))
            if stage == .closed { finish(nil) }
        } catch {
            finish(error)
        }
    }

    private func send(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        connection.send(
            content: data,
            completion: .contentProcessed(completion)
        )
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        _ = try? state.handle(.failed)
        connection.cancel()
        let flowError = error.map {
            NSError(
                domain: NEAppProxyErrorDomain,
                code: NEAppProxyFlowError.internal.rawValue,
                userInfo: [NSUnderlyingErrorKey: $0]
            )
        }
        flow.closeReadWithError(flowError)
        flow.closeWriteWithError(flowError)
        onFinished()
    }

    static func target(for flow: NEAppProxyTCPFlow) -> (address: SOCKS5Address, port: UInt16)? {
        guard case let .hostPort(host, port) = flow.remoteFlowEndpoint else { return nil }
        let targetPort = port.rawValue
        switch host {
        case let .ipv4(address): return (.ipv4(Array(address.rawValue)), targetPort)
        case let .ipv6(address): return (.ipv6(Array(address.rawValue)), targetPort)
        case let .name(name, _): return (.domain(name), targetPort)
        @unknown default: return nil
        }
    }
}
