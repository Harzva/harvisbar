import Foundation

final class CodexThreadPreferences {
    private enum Keys {
        static let tags = "harvisBar.codexThreadTags"
        static let pins = "harvisBar.pinnedCodexThreads"
        static let visibleUnnamedSubagents =
            "harvisBar.visibleUnnamedCodexSubagents"
        static let projectAttention =
            "harvisBar.managedChatProjectAttention"
        static let conversationAttention =
            "harvisBar.managedChatConversationAttention"
        static let projectAssignments =
            "harvisBar.managedChatProjectAssignments"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadTags() -> [String: [String]] {
        guard let data = defaults.data(forKey: Keys.tags) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    func saveTags(_ tags: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        defaults.set(data, forKey: Keys.tags)
    }

    func loadPins() -> Set<String> {
        Set(defaults.stringArray(forKey: Keys.pins) ?? [])
    }

    func savePins(_ pins: Set<String>) {
        defaults.set(pins.sorted(), forKey: Keys.pins)
    }

    func loadVisibleUnnamedSubagents() -> Set<String> {
        Set(defaults.stringArray(forKey: Keys.visibleUnnamedSubagents) ?? [])
    }

    func saveVisibleUnnamedSubagents(_ keys: Set<String>) {
        defaults.set(keys.sorted(), forKey: Keys.visibleUnnamedSubagents)
    }

    func loadProjectAttention() -> [String: ManagedAttentionPreference] {
        loadCodable([String: ManagedAttentionPreference].self, key: Keys.projectAttention) ?? [:]
    }

    func saveProjectAttention(_ preferences: [String: ManagedAttentionPreference]) {
        saveCodable(preferences, key: Keys.projectAttention)
    }

    func loadConversationAttention() -> [String: ManagedAttentionPreference] {
        loadCodable([String: ManagedAttentionPreference].self, key: Keys.conversationAttention) ?? [:]
    }

    func saveConversationAttention(_ preferences: [String: ManagedAttentionPreference]) {
        saveCodable(preferences, key: Keys.conversationAttention)
    }

    func loadProjectAssignments() -> [String: ManagedChatProjectAssignment] {
        loadCodable(
            [String: ManagedChatProjectAssignment].self,
            key: Keys.projectAssignments
        ) ?? [:]
    }

    func saveProjectAssignments(
        _ assignments: [String: ManagedChatProjectAssignment]
    ) {
        saveCodable(assignments, key: Keys.projectAssignments)
    }

    private func loadCodable<Value: Decodable>(
        _ type: Value.Type,
        key: String
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func saveCodable<Value: Encodable>(_ value: Value, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawTag in tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            let clipped = String(tag.prefix(24))
            guard seen.insert(clipped.lowercased()).inserted else { continue }
            result.append(clipped)
            if result.count == 8 { break }
        }
        return result
    }

    static func hasRemoteTag(_ tags: [String]) -> Bool {
        tags.contains { $0.caseInsensitiveCompare("remote") == .orderedSame }
    }

    static func hasDoneTag(_ tags: [String]) -> Bool {
        tags.contains { $0.caseInsensitiveCompare("done") == .orderedSame }
    }
}
