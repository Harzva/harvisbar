struct ManagedConversationActivity: Equatable, Sendable {
    let main: Int
    let subagent: Int
    let sidechat: Int?

    var total: Int {
        main + subagent + (sidechat ?? 0)
    }
}

struct ManagedConversationLineage: Equatable, Sendable {
    let rootAddress: ManagedConversationAddress?
    let parentAddress: ManagedConversationAddress?
    let isSubagent: Bool
    let isSidechat: Bool
}

struct ManagedConversation: Identifiable, Equatable, Sendable {
    let address: ManagedConversationAddress
    let title: String
    let titleSource: String?
    let hasMeaningfulTitle: Bool
    let createdAt: Int64
    let updatedAt: Int64
    let tokenUsage: Int64?
    let model: String?
    let sourceWorkingDirectory: String
    let archived: Bool
    let running: Bool
    let sourceStatus: String?
    let sourceKind: String?
    let agentIdentity: AgentIdentity?
    let lineage: ManagedConversationLineage
    let activity: ManagedConversationActivity
    let trust: ConversationTrustProjection
    let capabilities: ConversationCapabilities
    var projectAssignment: ManagedConversationProjectAssignment?

    var id: ManagedConversationAddress { address }
}
