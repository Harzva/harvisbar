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
    /// Resolve once to stable IDs before persistence. Scan left to right using
    /// the longest name at each position, so overlapping Chinese names cannot
    /// wake a shorter member merely because it is inside another member's name.
    static func resolve(_ text: String, members: [HarvisGroupMember]) -> [UUID] {
        let characters = Array(text)
        let candidates = members.enumerated().filter { !$0.element.name.isEmpty }
            .map { (order: $0.offset, id: $0.element.id, name: Array($0.element.name)) }
            .sorted { left, right in
                left.name.count == right.name.count ? left.order < right.order : left.name.count > right.name.count
            }
        var matched: Set<UUID> = []
        var position = 0
        while position < characters.count {
            let candidate = candidates.first { candidate in
                let end = position + candidate.name.count
                guard end <= characters.count,
                      characters[position ..< end].elementsEqual(candidate.name) else { return false }
                // Chinese names can occur inside natural sentences. ASCII name
                // edges need identifier boundaries: Ann must not match Annual,
                // joAnn, Ann2 or _Ann; Chinese text beside Ann remains natural.
                if let first = candidate.name.first, isWordCharacter(first),
                   position > 0, isWordCharacter(characters[position - 1]) { return false }
                if let last = candidate.name.last, isWordCharacter(last),
                   end < characters.count, isWordCharacter(characters[end]) { return false }
                return true
            }
            if let candidate {
                matched.insert(candidate.id)
                position += candidate.name.count
            } else {
                position += 1
            }
        }
        // Preserve group order and deduplicate repeated occurrences of a name.
        return members.filter { matched.contains($0.id) }.map(\.id)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (65 ... 90).contains(value) || (97 ... 122).contains(value)
            || (48 ... 57).contains(value) || value == 95
    }
}
