import Foundation

actor HarvisGroupStore {
    struct Envelope: Codable { var version = 1; var groups: [HarvisGroupConversation] }
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HarvisBar/GroupChat/groups-v1.json")) { self.url = url }

    func load() throws -> [HarvisGroupConversation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 1 else { throw HarvisGroupError.invalid("Unsupported group store version.") }
        try validate(envelope.groups)
        var groups = envelope.groups
        for g in groups.indices {
            for d in groups[g].dispatches.indices where !groups[g].dispatches[d].state.isTerminal {
                let id = groups[g].dispatches[d].id
                let planned = groups[g].runs.contains { run in
                    (run.ownerDispatchID == id && run.ownerDispatchState == .planned && !run.state.isTerminal)
                        || run.steps.contains { $0.dispatchID == id && $0.state == .planned }
                }
                if planned { continue }
                groups[g].dispatches[d].state = .deliveryUnknown
                groups[g].dispatches[d].lastError = "Execution interrupted by restart. Inspect native history; this dispatch was not resent."
            }
        }
        if groups != envelope.groups { try save(groups) }
        return groups
    }

    func save(_ groups: [HarvisGroupConversation]) throws {
        try validate(groups)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Envelope(groups: groups)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func validate(_ groups: [HarvisGroupConversation]) throws {
        guard Set(groups.map(\.id)).count == groups.count else { throw HarvisGroupError.invalid("Duplicate group identity in saved state.") }
        var dispatchIDs: Set<UUID> = []
        for group in groups {
            let memberIDs = Set(group.members.map(\.id))
            let messageIDs = Set(group.messages.map(\.id))
            guard memberIDs.count == group.members.count, messageIDs.count == group.messages.count,
                  Set(group.members.map(\.name)).count == group.members.count,
                  Set(group.messages.map(\.sequence)).count == group.messages.count,
                  group.messages.allSatisfy({ $0.sequence > 0 && $0.sequence <= group.lastSequence }) else {
                throw HarvisGroupError.invalid("Invalid member or message identities in group state.")
            }
            if let configuration = group.orchestration {
                guard configuration.ownerMemberID.map({ memberIDs.contains($0) }) ?? true,
                      Set(configuration.runs.map(\.id)).count == configuration.runs.count,
                      Set(configuration.requests.map(\.requestID)).count == configuration.requests.count else { throw HarvisGroupError.invalid("Invalid group owner/run identities.") }
                for run in configuration.runs {
                    guard messageIDs.contains(run.rootMessageID), Set(run.steps.map(\.id)).count == run.steps.count,
                          Set(run.steps.map(\.dispatchID)).count == run.steps.count,
                          run.steps.allSatisfy({ memberIDs.contains($0.memberID) }) else { throw HarvisGroupError.invalid("Invalid orchestration task ledger.") }
                }
            }
            var deliveryKeys: Set<String> = []
            for dispatch in group.dispatches {
                let key = dispatch.messageID.uuidString + "/" + dispatch.memberID.uuidString
                guard dispatchIDs.insert(dispatch.id).inserted, deliveryKeys.insert(key).inserted,
                      memberIDs.contains(dispatch.memberID), messageIDs.contains(dispatch.messageID),
                      dispatch.responseMessageID.map({ messageIDs.contains($0) }) ?? true else {
                    throw HarvisGroupError.invalid("Invalid or duplicate persisted group dispatch.")
                }
            }
        }
    }

}
