import Foundation

enum HarvisGroupPermission: String, Codable, CaseIterable, Sendable {
    case discussion
    case workspaceWrite
    var sandbox: String { self == .discussion ? "read-only" : "workspace-write" }
}

struct HarvisGroupBinding: Codable, Equatable, Sendable {
    var providerID = "codex"
    var host = "localhost"
    var homePath: String
    var accountIdentity: String
    var threadID: String
    var permission: HarvisGroupPermission
    var model: String? = nil
    var reasoningEffort: String? = nil
    var predecessorThreadID: String?
    var predecessorHomePath: String?
    var lineage: String = "native-start"
}

struct HarvisGroupMember: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var role: String
    var homePath: String
    var binding: HarvisGroupBinding?
    var previousBindings: [HarvisGroupBinding] = []
    var lastConsumedSequence: Int = 0
}

struct HarvisGroupMessage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var sequence: Int
    var createdAt = Date()
    var memberID: UUID?
    var speaker: String
    var text: String
    var recipientMemberIDs: [UUID] = []
    var dispatchID: UUID?
    var source: HarvisGroupBinding?
}

struct HarvisGroupDispatch: Codable, Equatable, Identifiable, Sendable {
    // Also the durable delivery queue command ID. Never generate another ID on recovery.
    var id = UUID()
    var messageID: UUID
    var memberID: UUID
    var permission: HarvisGroupPermission
    var state: CodexDeliveryState = .queued
    var binding: HarvisGroupBinding?
    var turnID: String?
    var connectionID: UUID?
    var lastError: String?
    var responseMessageID: UUID?
    var nativeReplyVerified = false
}

struct HarvisGroupConversation: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var projectPath: String
    var createdAt = Date()
    var members: [HarvisGroupMember] = []
    var messages: [HarvisGroupMessage] = []
    var dispatches: [HarvisGroupDispatch] = []
    var lastSequence: Int = 0
}

enum HarvisGroupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(text) = self { return text }; return nil }
}

enum HarvisGroupMentions {
    /// Names are unique within a group. Resolve once to IDs before persistence.
    static func resolve(_ text: String, members: [HarvisGroupMember]) -> [UUID] {
        members.filter { member in
            let pattern = "@" + NSRegularExpression.escapedPattern(for: member.name) + "(?=$|[\\s，。！？,:;：；、])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }.map(\.id)
    }
}
