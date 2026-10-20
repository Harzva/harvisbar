import Foundation

/// A separate, explicitly requested text analysis contract. The existing
/// single-conversation irreversible-facts contract is intentionally unchanged.
/// Inputs are ephemeral and not Codable; callers retain identity maps locally.
struct ManagedProjectOrganizerAnalysisRequest: Equatable, Sendable {
    let projects: [ManagedProjectOrganizerAnalysisProject]
    let conversations: [ManagedProjectOrganizerAnalysisConversation]
    let uninspectedConversationCount: Int

    init(
        projects: [ManagedProjectOrganizerAnalysisProject],
        conversations: [ManagedProjectOrganizerAnalysisConversation],
        uninspectedConversationCount: Int = 0
    ) {
        self.projects = projects
        self.conversations = conversations
        self.uninspectedConversationCount = uninspectedConversationCount
    }
}

struct ManagedProjectOrganizerAnalysisProject: Equatable, Sendable {
    let ref: String
    let name: String
    let purpose: String
    let parentRef: String?

    init(ref: String, name: String, purpose: String = "", parentRef: String? = nil) {
        self.ref = ref
        self.name = name
        self.purpose = purpose
        self.parentRef = parentRef
    }
}

struct ManagedProjectOrganizerAnalysisConversation: Equatable, Sendable {
    let ref: String
    let title: String
    let currentProjectRef: String?
    let messages: [ManagedProjectOrganizerAnalysisMessage]
    let totalUserMessageCount: Int
}

struct ManagedProjectOrganizerAnalysisMessage: Equatable, Sendable {
    let ref: String
    let text: String
    let truncated: Bool
    let source: ManagedConversationUserInputSource

    init(
        ref: String,
        text: String,
        truncated: Bool = false,
        source: ManagedConversationUserInputSource = .human
    ) {
        self.ref = ref
        self.text = text
        self.truncated = truncated
        self.source = source
    }
}

enum ManagedProjectOrganizerAnalysisAction: String, Codable, Equatable, Sendable {
    case move
    case newChild = "new_child"
    case keep
}

enum ManagedProjectOrganizerAnalysisSource: String, Codable, Equatable, Sendable {
    case human
    case unverifiedUserRole = "unverified_user_role"
}

struct ManagedProjectOrganizerAnalysisEvidence: Equatable, Sendable {
    let messageRef: String
    /// Always copied from the actual locally prepared snippet, never model text.
    let excerpt: String
    let source: ManagedProjectOrganizerAnalysisSource
    let truncated: Bool
}

struct ManagedProjectOrganizerAnalysisSuggestion: Equatable, Sendable {
    let conversationRef: String
    let action: ManagedProjectOrganizerAnalysisAction
    let targetProjectRef: String?
    let targetChildRef: String?
    let reason: String
    let confidence: Double
    let evidence: [ManagedProjectOrganizerAnalysisEvidence]
    /// True means the model omitted this conversation; Harvis added a keep row.
    let modelOmitted: Bool
}

struct ManagedProjectOrganizerAnalysisChild: Equatable, Sendable {
    /// Temporary n-prefixed reference, never a persistent project identity.
    let ref: String
    let name: String
    let purpose: String
    let parentProjectRef: String
    /// An existing project reference, never a model-selected filesystem path.
    let pathProjectRef: String?
}

struct ManagedProjectOrganizerAnalysisCoverage: Equatable, Sendable {
    let selectedConversationCount: Int
    let conversationsWithEvidenceCount: Int
    let totalUserMessageCount: Int
    let sentUserMessageCount: Int
    let unverifiedUserMessageCount: Int
    let truncatedMessageCount: Int
    let uninspectedConversationCount: Int
    let modelOmittedConversationCount: Int
    let promptUTF8ByteCount: Int
    /// UTF-8 byte count is a deliberately conservative bound, not a tokenizer
    /// estimate. Provider tokenization is not available at this boundary.
    let conservativeTokenUpperBound: Int

    var omittedUserMessageCount: Int {
        max(0, totalUserMessageCount - sentUserMessageCount)
    }
}

struct ManagedProjectOrganizerAnalysisResponse: Equatable, Sendable {
    let requestID: String
    let generatedAt: Date
    let children: [ManagedProjectOrganizerAnalysisChild]
    let suggestions: [ManagedProjectOrganizerAnalysisSuggestion]
    let coverage: ManagedProjectOrganizerAnalysisCoverage
}

enum ManagedProjectOrganizerAnalysisLimits {
    static let schema = "harvis.managed-project-organizer.v1"
    static let maximumConversations = 100
    static let maximumProjects = 100
    static let maximumChildren = 20
    static let maximumMessagesPerConversation = 3
    static let maximumSnippetCharacters = 600
    static let maximumSnippetUTF8Bytes = 24_000
    static let maximumPromptUTF8Bytes = 64_000
    static let maximumResponseUTF8Bytes = 128_000
}

enum ManagedProjectOrganizerAnalysisError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case budgetExceeded
    case endpointUnavailable
    case securityUnavailable(String)
    case invalidBrainWorkingDirectory
    case promptRejected
    case analysisFailed(String)
    case deliveryUnknown
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(reason):
            return "AI 整理输入无效：\(reason)"
        case .budgetExceeded:
            return "AI 整理超过单批输入预算，请缩小会话或项目范围。"
        case .endpointUnavailable:
            return "专用 DSH 分析端点不可用；未改用其他端点或本地规则。"
        case let .securityUnavailable(reason):
            return "AI 整理需要经过验证的零工具分析能力：\(reason)"
        case .invalidBrainWorkingDirectory:
            return "AI 整理需要明确的专用分析工作目录。"
        case .promptRejected:
            return "DSH 拒绝了 AI 整理请求。"
        case let .analysisFailed(reason):
            return "AI 整理失败：\(reason)"
        case .deliveryUnknown:
            return "AI 整理请求的送达或结果状态不明；没有自动重发。"
        case let .invalidResponse(reason):
            return "AI 整理建议未通过本地校验：\(reason)"
        }
    }
}
