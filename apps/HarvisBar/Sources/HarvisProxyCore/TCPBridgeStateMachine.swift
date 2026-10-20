public enum TCPBridgeSide: Equatable, Sendable {
    case application
    case proxy
}

public enum TCPBridgeStage: Equatable, Sendable {
    case idle
    case connectingToProxy
    case negotiatingMethod
    case requestingConnection
    case openingApplicationFlow
    case copying
    case halfClosed(TCPBridgeSide)
    case closed
}

public enum TCPBridgeEvent: Equatable, Sendable {
    case start
    case proxyConnected
    case methodAccepted
    case connectionAccepted
    case applicationFlowOpened
    case reachedEOF(TCPBridgeSide)
    case failed
}

public enum TCPBridgeStateError: Error, Equatable, Sendable {
    case invalidTransition(stage: TCPBridgeStage, event: TCPBridgeEvent)
}

public struct TCPBridgeStateMachine: Equatable, Sendable {
    public private(set) var stage: TCPBridgeStage = .idle

    public init() {}

    @discardableResult
    public mutating func handle(_ event: TCPBridgeEvent) throws -> TCPBridgeStage {
        let nextStage: TCPBridgeStage
        switch (stage, event) {
        case (.idle, .start):
            nextStage = .connectingToProxy
        case (.connectingToProxy, .proxyConnected):
            nextStage = .negotiatingMethod
        case (.negotiatingMethod, .methodAccepted):
            nextStage = .requestingConnection
        case (.requestingConnection, .connectionAccepted):
            nextStage = .openingApplicationFlow
        case (.openingApplicationFlow, .applicationFlowOpened):
            nextStage = .copying
        case (.copying, let .reachedEOF(side)):
            nextStage = .halfClosed(side)
        case let (.halfClosed(firstSide), .reachedEOF(secondSide)) where firstSide != secondSide:
            nextStage = .closed
        case (_, .failed) where stage != .closed:
            nextStage = .closed
        default:
            throw TCPBridgeStateError.invalidTransition(stage: stage, event: event)
        }

        stage = nextStage
        return nextStage
    }
}
