import Foundation

enum ManagedConversationUserInputSource: String, Decodable, Equatable, Sendable {
    /// The producer exposed an explicit, supported natural-person marker.
    case human
    case manager
    case system
    /// A provider `user`-role message whose natural-person origin cannot be
    /// proven by the provider's wire protocol. Harvis displays this as
    /// unverified user-role evidence and excludes known Manager commands
    /// before analysis.
    case unknown
}

struct ManagedConversationUserInput: Identifiable, Equatable, Sendable {
    let id: String
    let sequence: Int64
    let turnID: String?
    let timestamp: String?
    let text: String
    let originalCharacterCount: Int
    let truncated: Bool
    let source: ManagedConversationUserInputSource
}

struct ManagedConversationUserInputState: Equatable, Sendable {
    var targetKey: String
    var provider: ManagedChatProvider
    var sourceAvailable = false
    var sourceRevision: String?
    var items: [ManagedConversationUserInput] = []
    var totalCount = 0
    var excludedNonHumanCount = 0
    var nextCursor: String?
    var isLoading = false
    var isTruncated = false
    var loadedAt: Date?
    var threadUpdatedAtAtLoad: Int64?
    var error: String?

    static func empty(
        targetKey: String,
        provider: ManagedChatProvider
    ) -> ManagedConversationUserInputState {
        ManagedConversationUserInputState(
            targetKey: targetKey,
            provider: provider
        )
    }
}

struct CodexUserInputPage: Decodable, Equatable, Sendable {
    static let supportedSchemaVersion = "harvis.codex-user-inputs.v1"

    let ok: Bool
    let schemaVersion: String
    let threadId: String
    let source: String
    let sourceAvailable: Bool
    let sourceRevision: String?
    let items: [CodexUserInputWireItem]
    let nextCursor: String?
    let excludedNonHumanItems: Int
    let totalItems: Int
}

typealias CodexUserInputWireItem = ManagedConversationUserInputWireItem

struct ManagedConversationUserInputWireItem: Decodable, Equatable, Sendable {
    let id: String
    let sequence: Int64
    let timestamp: String?
    let turnId: String?
    let text: String
    let truncated: Bool
    let originalCharacterCount: Int
    let source: ManagedConversationUserInputSource
    let originMessageIDHash: String?

    var projected: ManagedConversationUserInput {
        ManagedConversationUserInput(
            id: id,
            sequence: sequence,
            turnID: turnId,
            timestamp: timestamp,
            text: text,
            originalCharacterCount: originalCharacterCount,
            truncated: truncated,
            source: source
        )
    }
}

enum ManagedConversationInputProjectionError: LocalizedError, Equatable {
    case unsupportedSchema(String)
    case targetMismatch(expected: String, actual: String)
    case failedResponse
    case invalidRevision
    case invalidCount
    case duplicateItem(String)
    case invalidOriginHash(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "不支持的用户输入数据格式：\(version)"
        case let .targetMismatch(expected, actual):
            return "用户输入属于任务 \(actual)，当前任务是 \(expected)。"
        case .failedResponse:
            return "用户输入读取失败。"
        case .invalidRevision:
            return "用户输入缺少可信的版本指纹。"
        case .invalidCount:
            return "用户输入数量无效。"
        case let .duplicateItem(id):
            return "用户输入包含重复项目：\(id)"
        case let .invalidOriginHash(id):
            return "用户输入 \(id) 的来源指纹无效。"
        }
    }
}

enum ManagedConversationInputProjection {
    static func validate(
        _ page: CodexUserInputPage,
        expectedThreadID: String
    ) throws {
        guard page.ok else {
            throw ManagedConversationInputProjectionError.failedResponse
        }
        guard page.schemaVersion == CodexUserInputPage.supportedSchemaVersion else {
            throw ManagedConversationInputProjectionError.unsupportedSchema(
                page.schemaVersion
            )
        }
        guard page.threadId == expectedThreadID else {
            throw ManagedConversationInputProjectionError.targetMismatch(
                expected: expectedThreadID,
                actual: page.threadId
            )
        }
        guard page.totalItems >= 0,
              page.excludedNonHumanItems >= 0,
              page.items.count <= page.totalItems else {
            throw ManagedConversationInputProjectionError.invalidCount
        }
        if page.sourceAvailable {
            guard let revision = page.sourceRevision,
                  revision.hasPrefix("sha256:"),
                  revision.dropFirst("sha256:".count).count == 64 else {
                throw ManagedConversationInputProjectionError.invalidRevision
            }
        }
        var ids: Set<String> = []
        for item in page.items {
            guard ids.insert(item.id).inserted else {
                throw ManagedConversationInputProjectionError.duplicateItem(item.id)
            }
            if let hash = item.originMessageIDHash {
                guard hash.hasPrefix("sha256:"),
                      hash.dropFirst("sha256:".count).count == 64,
                      hash.dropFirst("sha256:".count).allSatisfy({
                          $0.isHexDigit
                      }) else {
                    throw ManagedConversationInputProjectionError
                        .invalidOriginHash(item.id)
                }
            }
        }
    }
}
