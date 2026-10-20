import Foundation

// MARK: - Read-only HTTP contracts

struct DigitalMeApprovalsResponse: Decodable, Equatable, Sendable {
    let approvalCount: Int?
    let approvals: [DigitalMeApproval]

    enum CodingKeys: String, CodingKey {
        case approvalCount = "approval_count"
        case approvals
    }
}

struct DigitalMeApproval: Decodable, Equatable, Sendable {
    let approvalID: String?
    let status: String?
    let risk: String?
    let actionType: String?
    let target: DigitalMeApprovalTarget?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case approvalID = "approval_id"
        case status
        case risk
        case actionType = "action_type"
        case target
        case updatedAt = "updated_at"
    }
}

struct DigitalMeApprovalTarget: Decodable, Equatable, Sendable {
    let kind: String?
    let display: String?
}

struct DigitalMeMemoryCandidatesResponse: Decodable, Equatable, Sendable {
    let memoryIndex: DigitalMeMemoryIndex?
    let candidateCount: Int?
    let candidates: [DigitalMeMemoryCandidate]

    enum CodingKeys: String, CodingKey {
        case memoryIndex = "memory_index"
        case candidateCount = "candidate_count"
        case candidates
    }
}

struct DigitalMeMemoryIndex: Decodable, Equatable, Sendable {
    let exists: Bool?
    let latestGeneratedAt: String?
    let candidateSignalCount: Int?
    let knowledgeSourceCount: Int?
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case exists
        case latestGeneratedAt = "latest_generated_at"
        case candidateSignalCount = "candidate_signal_count"
        case knowledgeSourceCount = "knowledge_source_count"
        case warnings
    }
}

struct DigitalMeMemoryCandidate: Decodable, Equatable, Sendable {
    let candidateID: String?
    let name: String?
    let status: String?
    let requiresReview: Bool?
    let adoption: DigitalMeMemoryCandidateAdoption?
    let review: DigitalMeMemoryCandidateReview?

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case name
        case status
        case requiresReview = "requires_review"
        case adoption
        case review
    }
}

struct DigitalMeMemoryCandidateAdoption: Decodable, Equatable, Sendable {
    let status: String?
    let requiresHumanReview: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case requiresHumanReview = "requires_human_review"
    }
}

struct DigitalMeMemoryCandidateReview: Decodable, Equatable, Sendable {
    let decision: String?
    let approvalDecision: String?

    enum CodingKeys: String, CodingKey {
        case decision
        case approvalDecision = "approval_decision"
    }
}

struct DigitalMePersonaResponse: Decodable, Equatable, Sendable {
    let personaRegistryVersion: String?
    let reviewQueueVersion: String?
    let memoryVaults: [DigitalMeMemoryVault]
    let personaCards: [DigitalMePersonaCard]
    let twinInstances: [DigitalMeTwinInstance]
    let personalityCandidates: [DigitalMePersonalityCandidate]
    let pendingPersonalityReview: [DigitalMePersonalityCandidate]

    enum CodingKeys: String, CodingKey {
        case personaRegistryVersion = "persona_registry_version"
        case reviewQueueVersion = "review_queue_version"
        case memoryVaults = "memory_vaults"
        case personaCards = "persona_cards"
        case twinInstances = "twin_instances"
        case personalityCandidates = "personality_candidates"
        case pendingPersonalityReview = "pending_personality_review"
    }
}

struct DigitalMeMemoryVault: Decodable, Equatable, Sendable {
    let vaultID: String?
    let displayName: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case vaultID = "vault_id"
        case displayName = "display_name"
        case status
    }
}

struct DigitalMePersonaCard: Decodable, Equatable, Sendable {
    let personaID: String?
    let displayName: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case personaID = "persona_id"
        case displayName = "display_name"
        case status
    }
}

struct DigitalMeTwinInstance: Decodable, Equatable, Sendable {
    let instanceID: String?
    let displayName: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case displayName = "display_name"
        case status
    }
}

struct DigitalMePersonalityCandidate: Decodable, Equatable, Sendable {
    let candidateID: String?
    let trait: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case trait
        case status
    }
}

// MARK: - Source loading state

enum DigitalMeNavigationSource: String, CaseIterable, Equatable, Hashable, Sendable {
    case approvals
    case memoryCandidates
    case persona
}

struct DigitalMeNavigationSourceState<Value: Equatable & Sendable>: Equatable, Sendable {
    var value: Value?
    var isLoading: Bool
    var errorMessage: String?
    var lastAttemptedAt: Date?
    var refreshedAt: Date?

    static var notRequested: Self {
        Self(
            value: nil,
            isLoading: false,
            errorMessage: nil,
            lastAttemptedAt: nil,
            refreshedAt: nil
        )
    }

    func needsRefresh(at now: Date, ttl: TimeInterval) -> Bool {
        guard !isLoading, let lastAttemptedAt else { return !isLoading }
        return now.timeIntervalSince(lastAttemptedAt) >= ttl
    }

    func hidingExpiredValue(at now: Date, ttl: TimeInterval) -> Self {
        guard value != nil else { return self }
        let maximumAge = max(ttl, 0)
        guard let refreshedAt,
              now.timeIntervalSince(refreshedAt) < maximumAge else {
            var expired = self
            expired.value = nil
            return expired
        }
        return self
    }
}

struct DigitalMeNavigationRemoteSources: Equatable, Sendable {
    var approvals: DigitalMeNavigationSourceState<DigitalMeApprovalsResponse>
    var memoryCandidates: DigitalMeNavigationSourceState<DigitalMeMemoryCandidatesResponse>
    var persona: DigitalMeNavigationSourceState<DigitalMePersonaResponse>

    static let notRequested = DigitalMeNavigationRemoteSources(
        approvals: .notRequested,
        memoryCandidates: .notRequested,
        persona: .notRequested
    )

    func hidingExpiredValues(at now: Date, ttl: TimeInterval) -> Self {
        Self(
            approvals: approvals.hidingExpiredValue(at: now, ttl: ttl),
            memoryCandidates: memoryCandidates.hidingExpiredValue(at: now, ttl: ttl),
            persona: persona.hidingExpiredValue(at: now, ttl: ttl)
        )
    }
}

enum DigitalMeNavigationContract {
    /// All three list endpoints accept at most 500 rows. A full page is a
    /// lower bound because the current API does not return a continuation.
    static let pageLimit = 500
}

// MARK: - Pure projection input

struct DigitalMeRuntimeWork: Equatable, Sendable {
    let packetCount: Int?
    let blockedCount: Int?
    let runCount: Int?
}

struct DigitalMeDurableWorkItem: Equatable, Sendable {
    let state: CodexDeliveryState
    let stateChangedAt: Date
    let threadID: String
}

enum DigitalMeWorkProvider: String, Equatable, Hashable, Sendable {
    case codex
    case dsh
    case workBuddy
}

struct DigitalMeRunningConversation: Equatable, Sendable {
    let provider: DigitalMeWorkProvider
    let sourceID: String
    let updatedAt: Date
}

struct DigitalMeWorkProjectionInput: Equatable, Sendable {
    let runtimeWork: DigitalMeRuntimeWork?
    let durableQueue: [DigitalMeDurableWorkItem]?
    let runningConversations: [DigitalMeRunningConversation]?
}

struct DigitalMeNavigationProjectionInput: Equatable, Sendable {
    let work: DigitalMeWorkProjectionInput
    let remote: DigitalMeNavigationRemoteSources
}

// MARK: - Read-only navigation snapshot

enum DigitalMeNavigationAvailability: Equatable, Sendable {
    case notLoaded
    case loading
    case available
    case partial
    case unavailable
}

struct DigitalMeNavigationSourceIssue: Equatable, Sendable {
    let source: DigitalMeNavigationSource
    let message: String
}

enum DigitalMeCountCompleteness: Equatable, Sendable {
    case exact
    case atLeast
}

enum DigitalMeWorkPrimaryKind: Equatable, Sendable {
    case blockedDelivery
    case activeConversation
    case activeDelivery
    case queuedDelivery
    case runtimeHistory
}

struct DigitalMeWorkPrimaryItem: Equatable, Sendable {
    let kind: DigitalMeWorkPrimaryKind
    /// A generic status label. Never a conversation title or queued command body.
    let title: String
}

struct DigitalMeWorkSummary: Equatable, Sendable {
    let availability: DigitalMeNavigationAvailability
    let activeCount: Int?
    let queuedCount: Int?
    let blockedCount: Int?
    let packetCount: Int?
    /// Total historical Harvis runs reported by bar status; not an active count.
    let runCount: Int?
    let runningConversationCount: Int?
    let primaryItem: DigitalMeWorkPrimaryItem?
}

struct DigitalMeReviewSummary: Equatable, Sendable {
    let availability: DigitalMeNavigationAvailability
    let approvalCount: Int?
    let approvalCountCompleteness: DigitalMeCountCompleteness?
    let memoryCandidateCount: Int?
    let memoryCandidateCountCompleteness: DigitalMeCountCompleteness?
    let personalityCandidateCount: Int?
    let personalityCandidateCountCompleteness: DigitalMeCountCompleteness?
    /// Nil when any source is unavailable, so an incomplete sum is never presented as complete.
    let totalAttentionCount: Int?
    let knownAttentionCount: Int
    let issues: [DigitalMeNavigationSourceIssue]
}

struct DigitalMeMemorySummary: Equatable, Sendable {
    let availability: DigitalMeNavigationAvailability
    let vaultCount: Int?
    let vaultCountCompleteness: DigitalMeCountCompleteness?
    let snapshotExists: Bool?
    let lastSnapshotAt: String?
    let candidateSignalCount: Int?
    let pendingCandidateCount: Int?
    let pendingCandidateCountCompleteness: DigitalMeCountCompleteness?
    let knowledgeSourceCount: Int?
    let issues: [DigitalMeNavigationSourceIssue]
}

struct DigitalMePersonaSummary: Equatable, Sendable {
    let availability: DigitalMeNavigationAvailability
    let activePersonaCount: Int?
    let activePersonaCountCompleteness: DigitalMeCountCompleteness?
    let runningTwinCount: Int?
    let runningTwinCountCompleteness: DigitalMeCountCompleteness?
    let activePersonaNames: [String]
    let runningTwinNames: [String]
    let registryVersion: String?
    let reviewQueueVersion: String?
    let issues: [DigitalMeNavigationSourceIssue]
}

struct DigitalMeNavigationSnapshot: Equatable, Sendable {
    let work: DigitalMeWorkSummary
    let review: DigitalMeReviewSummary
    let memory: DigitalMeMemorySummary
    let persona: DigitalMePersonaSummary
}
