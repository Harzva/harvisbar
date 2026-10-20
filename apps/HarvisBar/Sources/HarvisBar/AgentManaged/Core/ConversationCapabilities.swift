enum ConversationCapabilityAction: String, Codable, CaseIterable, Hashable, Sendable {
    case observe
    case openProviderSurface
    case openExact
    case readInputs
    case send
    case steer
    case interrupt
    case approve
    case archive
    case fork
    case handoff
    case inspect
    case analyzeInsight
    case plan
}

enum ConversationAuthorityConfidence: String, Codable, Hashable, Sendable {
    case compatibility
    case verified
}

struct ConversationAuthorityRevision: Codable, Hashable, Sendable {
    let rawValue: String
    let confidence: ConversationAuthorityConfidence

    init(
        rawValue: String,
        confidence: ConversationAuthorityConfidence
    ) {
        self.rawValue = rawValue
        self.confidence = confidence
    }

    static func compatibility(_ rawValue: String) -> ConversationAuthorityRevision {
        ConversationAuthorityRevision(
            rawValue: rawValue,
            confidence: .compatibility
        )
    }

    static func verified(_ rawValue: String) -> ConversationAuthorityRevision {
        ConversationAuthorityRevision(
            rawValue: rawValue,
            confidence: .verified
        )
    }
}

enum ConversationCapabilityDecision: Equatable, Sendable {
    case allowedDirect(authorityRevision: ConversationAuthorityRevision)
    case allowedParent(
        target: ManagedConversationAddress,
        authorityRevision: ConversationAuthorityRevision
    )
    case allowedExplicit(
        target: ManagedConversationAddress,
        authorityRevision: ConversationAuthorityRevision
    )
    case denied(reason: String)

    var isAllowed: Bool {
        switch self {
        case .allowedDirect, .allowedParent, .allowedExplicit:
            return true
        case .denied:
            return false
        }
    }

    var authorityRevision: ConversationAuthorityRevision? {
        switch self {
        case let .allowedDirect(authorityRevision),
             let .allowedParent(_, authorityRevision),
             let .allowedExplicit(_, authorityRevision):
            return authorityRevision
        case .denied:
            return nil
        }
    }

}

enum ConversationCapabilityRoute: Equatable, Sendable {
    case direct(ManagedConversationAddress)
    case parent(ManagedConversationAddress)
    case explicit(ManagedConversationAddress)
}

struct ConversationCapabilities: Equatable, Sendable {
    let subject: ManagedConversationAddress
    let generation: UInt64
    private let decisions: [ConversationCapabilityAction: ConversationCapabilityDecision]
    private let defaultDenialReason: String

    init(
        subject: ManagedConversationAddress,
        generation: UInt64 = 0,
        decisions: [ConversationCapabilityAction: ConversationCapabilityDecision] = [:],
        defaultDenialReason: String = "Capability was not declared."
    ) {
        self.subject = subject
        self.generation = generation
        self.decisions = decisions
        self.defaultDenialReason = defaultDenialReason
    }

    static func denied(
        for subject: ManagedConversationAddress,
        generation: UInt64 = 0,
        reason: String = "Capability was not declared."
    ) -> ConversationCapabilities {
        ConversationCapabilities(
            subject: subject,
            generation: generation,
            defaultDenialReason: reason
        )
    }

    func decision(
        for action: ConversationCapabilityAction
    ) -> ConversationCapabilityDecision {
        decisions[action] ?? .denied(reason: defaultDenialReason)
    }

    func setting(
        _ decision: ConversationCapabilityDecision,
        for action: ConversationCapabilityAction
    ) -> ConversationCapabilities {
        var updated = decisions
        updated[action] = decision
        return ConversationCapabilities(
            subject: subject,
            generation: generation,
            decisions: updated,
            defaultDenialReason: defaultDenialReason
        )
    }

    func route(
        for action: ConversationCapabilityAction
    ) -> ConversationCapabilityRoute? {
        switch decision(for: action) {
        case .allowedDirect:
            return .direct(subject)
        case let .allowedParent(target, _):
            return .parent(target)
        case let .allowedExplicit(target, _):
            return .explicit(target)
        case .denied:
            return nil
        }
    }
}
