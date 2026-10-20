enum ConversationTrustState:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable {
    case unknown
    case running
    case idle
    case completed
    case failed
    case archived
}

enum ConversationTrustQualifier:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable {
    case incomplete
    case recentlyActive
    case stale
}

struct ConversationTrustProjection: Codable, Equatable, Sendable {
    let state: ConversationTrustState
    let qualifier: ConversationTrustQualifier?
    let reason: String

    init(
        state: ConversationTrustState,
        qualifier: ConversationTrustQualifier? = nil,
        reason: String
    ) {
        self.state = state
        self.qualifier = qualifier
        self.reason = reason
    }
}
