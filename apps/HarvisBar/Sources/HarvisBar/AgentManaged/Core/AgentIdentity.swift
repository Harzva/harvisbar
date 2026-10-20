struct AgentIdentity: Equatable, Sendable {
    let stableID: String?
    let displayName: String?
    let role: String?
    let sourcePath: String?
    let skillIDs: [String]
    let presetIDs: [String]

    init(
        stableID: String? = nil,
        displayName: String? = nil,
        role: String? = nil,
        sourcePath: String? = nil,
        skillIDs: [String] = [],
        presetIDs: [String] = []
    ) {
        self.stableID = stableID
        self.displayName = displayName
        self.role = role
        self.sourcePath = sourcePath
        self.skillIDs = skillIDs
        self.presetIDs = presetIDs
    }
}
