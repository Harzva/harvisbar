import Foundation

enum ManagedConversationAttentionLevel:
    Int,
    Codable,
    CaseIterable,
    Identifiable,
    Sendable {
    case low = 1
    case normal = 2
    case high = 3
    case critical = 4

    var id: Int { rawValue }
}

struct ManagedConversationAttentionPreference: Codable, Equatable, Sendable {
    var level: ManagedConversationAttentionLevel?
    var focusStartsAt: Date?
    var focusEndsAt: Date?

    init(
        level: ManagedConversationAttentionLevel? = nil,
        focusStartsAt: Date? = nil,
        focusEndsAt: Date? = nil
    ) {
        self.level = level
        self.focusStartsAt = focusStartsAt
        self.focusEndsAt = focusEndsAt
    }

    var isEmpty: Bool {
        level == nil && focusStartsAt == nil && focusEndsAt == nil
    }

    func focusState(
        at date: Date = Date()
    ) -> ManagedConversationAttentionWindowState {
        guard let start = focusStartsAt, let end = focusEndsAt, end > start else {
            return .unset
        }
        if date < start { return .scheduled }
        if date <= end { return .active }
        return .expired
    }
}

enum ManagedConversationAttentionWindowState: String, Equatable, Sendable {
    case unset
    case scheduled
    case active
    case expired
}

struct ManagedConversationProjectTaskSummary: Codable, Equatable, Sendable {
    let sourceAvailable: Bool
    let total: Int
    let done: Int
    let open: Int
    let blocked: Int
    let waitingApproval: Int
    let reviewing: Int
    let sourceTruncated: Bool

    static let unavailable = ManagedConversationProjectTaskSummary(
        sourceAvailable: false,
        total: 0,
        done: 0,
        open: 0,
        blocked: 0,
        waitingApproval: 0,
        reviewing: 0,
        sourceTruncated: false
    )

    var completionFraction: Double? {
        guard sourceAvailable, total > 0 else { return nil }
        return Double(done) / Double(total)
    }

    var closedWithoutCompletion: Int {
        max(total - done - open, 0)
    }

    var needsAttention: Bool {
        blocked > 0 || waitingApproval > 0
    }
}

enum ManagedConversationGovernanceFreshness: Equatable, Sendable {
    case unavailable(error: String?)
    case fresh(lastSuccessfulAt: Date)
    case stale(lastSuccessfulAt: Date, error: String)

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }

    var lastSuccessfulAt: Date? {
        switch self {
        case .unavailable:
            return nil
        case let .fresh(lastSuccessfulAt),
             let .stale(lastSuccessfulAt, _):
            return lastSuccessfulAt
        }
    }

    var error: String? {
        switch self {
        case let .unavailable(error): return error
        case .fresh: return nil
        case let .stale(_, error): return error
        }
    }

    func recordingFailure(
        _ error: String
    ) -> ManagedConversationGovernanceFreshness {
        guard let lastSuccessfulAt else {
            return .unavailable(error: error)
        }
        return .stale(lastSuccessfulAt: lastSuccessfulAt, error: error)
    }
}

struct ManagedConversationGovernanceSnapshot: Equatable, Sendable {
    let project: ManagedConversationProjectIdentity
    let projectAttention: ManagedConversationAttentionPreference
    let projectTasks: ManagedConversationProjectTaskSummary
    let projectTasksFreshness: ManagedConversationGovernanceFreshness
    let conversationAttention: ManagedConversationAttentionPreference
}

enum ManagedConversationVisibilityRules {
    static func shouldShowUnnamedSubagent(
        isUnnamedSubagent: Bool,
        hasExplicitShowOverride: Bool
    ) -> Bool {
        !isUnnamedSubagent || hasExplicitShowOverride
    }
}
