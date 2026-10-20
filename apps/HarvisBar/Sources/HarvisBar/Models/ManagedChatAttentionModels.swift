import Foundation

typealias ManagedAttentionLevel = ManagedConversationAttentionLevel
typealias ManagedAttentionPreference = ManagedConversationAttentionPreference
typealias ManagedAttentionWindowState = ManagedConversationAttentionWindowState
typealias ManagedProjectTaskSummary = ManagedConversationProjectTaskSummary
typealias ManagedGovernanceFreshness = ManagedConversationGovernanceFreshness

extension ManagedConversationAttentionLevel {
    var label: String {
        switch self {
        case .low: return "P4 低"
        case .normal: return "P3 普通"
        case .high: return "P2 重要"
        case .critical: return "P1 关键"
        }
    }

    var compactLabel: String { "P\(5 - rawValue)" }
}

struct CodexConversationMetrics: Decodable, Equatable, Sendable {
    let ok: Bool
    let schemaVersion: String?
    let threadId: String
    let sourceAvailable: Bool
    let userInputCount: Int?
    let turnCount: Int?
    let compactionCount: Int?
    let compactionEvidenceAvailable: Bool
    let reason: String?

    var attention: CodexConversationAttention {
        CodexConversationAttention(
            userInputCount: userInputCount,
            turnCount: turnCount,
            compactionCount: compactionCount,
            compactionEvidenceAvailable: compactionEvidenceAvailable
        )
    }

    var userFacingEvidenceNote: String? {
        if !sourceAvailable {
            return "当前记录源不可用，交互与压缩次数保持未知。"
        }
        if !compactionEvidenceAvailable {
            return "当前记录无法验证压缩次数；未知不会被当作 0。"
        }
        return nil
    }
}

extension ManagedConversationGovernanceFreshness {
    func currentConversationRisk(
        metrics: CodexConversationMetrics?
    ) -> CodexConversationRisk {
        guard isFresh else { return .unknown }
        return metrics?.attention.risk ?? .unknown
    }
}

struct ManagedChatGovernanceSnapshot: Equatable, Sendable {
    let project: ManagedChatProjectIdentity
    let projectAttention: ManagedAttentionPreference
    let projectTasks: ManagedProjectTaskSummary
    let projectTasksFreshness: ManagedGovernanceFreshness
    let conversationAttention: ManagedAttentionPreference
    let conversationMetrics: CodexConversationMetrics?
    let conversationMetricsFreshness: ManagedGovernanceFreshness
}

enum CodexConversationRisk: Int, Comparable, Sendable {
    case unknown = -1
    case healthy = 0
    case watch = 1
    case handoffRecommended = 2

    static func < (left: CodexConversationRisk, right: CodexConversationRisk) -> Bool {
        left.rawValue < right.rawValue
    }
}

enum ManagedUnnamedSubagentVisibilityPolicy {
    static func shouldShow(
        isUnnamedSubagent: Bool,
        hasExplicitShowOverride: Bool
    ) -> Bool {
        ManagedConversationVisibilityRules.shouldShowUnnamedSubagent(
            isUnnamedSubagent: isUnnamedSubagent,
            hasExplicitShowOverride: hasExplicitShowOverride
        )
    }
}

struct CodexConversationAttention: Equatable, Sendable {
    static let compactionWarningThreshold = 2
    static let compactionHandoffThreshold = 3

    let userInputCount: Int?
    let turnCount: Int?
    let compactionCount: Int?
    let compactionEvidenceAvailable: Bool

    var risk: CodexConversationRisk {
        guard compactionEvidenceAvailable, let compactionCount else {
            return .unknown
        }
        if compactionCount >= Self.compactionHandoffThreshold {
            return .handoffRecommended
        }
        if compactionCount >= Self.compactionWarningThreshold {
            return .watch
        }
        return .healthy
    }

    var interactionLabel: String {
        userInputCount.map { "交互 \($0)" } ?? "交互未知"
    }

    var compactionLabel: String {
        guard compactionEvidenceAvailable, let compactionCount else {
            return "压缩未知"
        }
        return "压缩 \(compactionCount)×"
    }
}

extension ManagedChatThread {
    var hasUntitledFallback: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Untitled chat") == .orderedSame
    }

    var isUnnamedSubagent: Bool {
        isSubagent && !hasMeaningfulTitle
    }
}
