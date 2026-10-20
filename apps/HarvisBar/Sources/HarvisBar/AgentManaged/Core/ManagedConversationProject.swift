import Foundation

enum ManagedConversationProjectResolution: String, Codable, Equatable, Sendable {
    case resolved
    case unresolved
    case unassigned
}

struct ManagedConversationProjectIdentity:
    Identifiable,
    Codable,
    Equatable,
    Hashable,
    Sendable {
    let id: String
    let canonicalPath: String?
    let displayPath: String
    let label: String
    let resolution: ManagedConversationProjectResolution
}

enum ManagedConversationProjectAssignmentSource:
    String,
    Codable,
    Equatable,
    Sendable {
    case manual
    case aiRecommendation
}

struct ManagedConversationProjectAssignment: Codable, Equatable, Sendable {
    let project: ManagedConversationProjectIdentity
    let source: ManagedConversationProjectAssignmentSource
    let assignedAt: Date
}

enum ManagedConversationProjectRules {
    static func unassigned(fallbackID: String) -> ManagedConversationProjectIdentity {
        ManagedConversationProjectIdentity(
            id: "unassigned::\(fallbackID)",
            canonicalPath: nil,
            displayPath: "No working directory",
            label: "Unassigned",
            resolution: .unassigned
        )
    }

    static func effectiveProject(
        source: ManagedConversationProjectIdentity,
        assignment: ManagedConversationProjectAssignment?
    ) -> ManagedConversationProjectIdentity {
        assignment?.project ?? source
    }
}
