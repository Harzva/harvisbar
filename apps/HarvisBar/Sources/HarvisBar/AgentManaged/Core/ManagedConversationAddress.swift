struct ManagedConversationAddress: Codable, Hashable, Sendable, Identifiable {
    let providerID: AgentProviderID
    let scope: String
    let sourceID: String

    var id: ManagedConversationAddress { self }

    /// Compatibility serialization only. Structural equality remains the
    /// authority so delimiter-like source values are never parsed or guessed.
    var serializedID: String {
        "\(providerID.rawValue)::\(scope)::\(sourceID)"
    }
}
