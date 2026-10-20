import Foundation

enum CodexConversationHandoffState: String, Codable, CaseIterable, Sendable {
    case queuedSummary
    case summarizing
    case summaryWaitingApproval
    case creatingDestination
    case seedingDestination
    case destinationWaitingApproval
    case verified
    case failed
    case deliveryUnknown
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .verified, .failed, .deliveryUnknown, .cancelled:
            return true
        default:
            return false
        }
    }

    var statusLabel: String {
        switch self {
        case .queuedSummary: return "等待源任务安全空闲"
        case .summarizing: return "正在生成交接包"
        case .summaryWaitingApproval: return "源任务等待用户审批"
        case .creatingDestination: return "正在创建新任务"
        case .seedingDestination: return "正在验证新任务"
        case .destinationWaitingApproval: return "新任务等待用户审批"
        case .verified: return "交接完成"
        case .failed: return "交接失败"
        case .deliveryUnknown: return "交付状态未知，请检查"
        case .cancelled: return "已取消"
        }
    }
}

struct CodexConversationHandoff: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let homeID: String
    let homePath: String
    let sourceThreadID: String
    let sourceTitle: String
    let cardType: CodexTaskCardType
    let summaryCommandID: UUID
    let createdAt: Date
    var updatedAt: Date
    var state: CodexConversationHandoffState
    var sourceSummaryTurnID: String?
    var sourceUpdatedAt: Int64?
    var destinationThreadID: String?
    var destinationTurnID: String?
    var lastError: String?
    var warning: String?

    init(
        id: UUID = UUID(),
        homeID: String,
        homePath: String,
        sourceThreadID: String,
        sourceTitle: String,
        cardType: CodexTaskCardType,
        summaryCommandID: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.homeID = homeID
        self.homePath = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL.path
        self.sourceThreadID = sourceThreadID
        self.sourceTitle = sourceTitle
        self.cardType = cardType
        self.summaryCommandID = summaryCommandID
        self.createdAt = createdAt
        updatedAt = createdAt
        state = .queuedSummary
        sourceSummaryTurnID = nil
        sourceUpdatedAt = nil
        destinationThreadID = nil
        destinationTurnID = nil
        lastError = nil
        warning = nil
    }

    var sourceTarget: CodexTaskTarget {
        CodexTaskTarget(homePath: homePath, threadID: sourceThreadID)
    }

    var canMarkSourceDone: Bool {
        state == .verified
            && sourceSummaryTurnID?.isEmpty == false
            && sourceUpdatedAt != nil
            && destinationThreadID?.isEmpty == false
            && destinationTurnID?.isEmpty == false
    }

    var statusLabel: String { state.statusLabel }
}

struct CodexVerifiedHandoff: Equatable, Sendable {
    let transactionID: UUID
    let homeID: String
    let homePath: String
    let sourceThreadID: String
    let destinationThreadID: String
    let destinationTurnID: String
}

struct CodexConversationHandoffEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    var transactions: [CodexConversationHandoff]

    init(
        version: Int = schemaVersion,
        transactions: [CodexConversationHandoff]
    ) {
        self.version = version
        self.transactions = transactions
    }
}

enum CodexConversationHandoffPolicy {
    static func supports(_ cardType: CodexTaskCardType) -> Bool {
        cardType == .main || cardType == .persistedSubagent
    }

    static let summaryPrompt = """
    Prepare a bounded, self-contained handoff packet for a fresh Codex task.
    Do not run commands, call tools, edit files, or ask questions. Return only the packet, no preamble.
    Limit the packet to 1,800 words and include: objective, current state, completed work, remaining work, exact relevant files/symbols, constraints and permissions, verification already run, failures/risks, and the safest next action. Do not include secrets, credentials, cookies, raw logs, or a transcript.
    """

    static func destinationPrompt(packet: String) -> String {
        """
        This is a clean task handoff. Read the packet below and acknowledge takeover with a concise statement of the objective and safest next action. Do not run commands, call tools, edit files, or ask questions in this first turn. Use only this packet as prior task context.

        --- HANDOFF PACKET ---
        \(packet)
        --- END HANDOFF PACKET ---
        """
    }
}
