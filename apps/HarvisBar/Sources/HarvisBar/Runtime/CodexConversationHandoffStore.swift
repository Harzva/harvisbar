import Foundation

protocol CodexConversationHandoffStoring: Actor {
    func load() throws -> [CodexConversationHandoff]
    func save(_ transactions: [CodexConversationHandoff]) throws
}

enum CodexConversationHandoffStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case duplicateTransaction(UUID)
    case duplicateActiveSource(String)
    case incompleteVerifiedTransaction(UUID)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported Codex handoff store version: \(version)"
        case let .duplicateTransaction(id):
            return "Duplicate Codex handoff transaction: \(id.uuidString)"
        case let .duplicateActiveSource(key):
            return "Multiple active Codex handoffs target the same source: \(key)"
        case let .incompleteVerifiedTransaction(id):
            return "Verified Codex handoff is missing exact source or destination evidence: \(id.uuidString)"
        }
    }
}

actor CodexConversationHandoffStore: CodexConversationHandoffStoring {
    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("HarvisBar", isDirectory: true)
            .appendingPathComponent("CodexHandoffs", isDirectory: true)
            .appendingPathComponent("handoffs-v1.json")
    }

    let storeURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        storeURL: URL = CodexConversationHandoffStore.defaultURL(),
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func load() throws -> [CodexConversationHandoff] {
        try ensureDirectory()
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let envelope = try decoder.decode(
            CodexConversationHandoffEnvelope.self,
            from: Data(contentsOf: storeURL)
        )
        guard envelope.version == CodexConversationHandoffEnvelope.schemaVersion else {
            throw CodexConversationHandoffStoreError.unsupportedVersion(envelope.version)
        }
        var recovered = envelope.transactions
        var changed = false
        // `sourceUpdatedAt` was added to the v1 evidence envelope after the
        // first local builds. A legacy `verified` record must never acquire a
        // `done` tag merely because its optional field decoded as nil.
        for index in recovered.indices
            where recovered[index].state == .verified
                && !recovered[index].canMarkSourceDone {
            recovered[index].state = .deliveryUnknown
            recovered[index].updatedAt = Date()
            recovered[index].lastError =
                "This legacy handoff was marked verified without complete source evidence. It was not trusted or replayed."
            changed = true
        }
        try validate(recovered)

        for index in recovered.indices where !recovered[index].state.isTerminal {
            recovered[index].state = .deliveryUnknown
            recovered[index].updatedAt = Date()
            recovered[index].lastError =
                "HarvisBar restarted while this handoff was active. It was not replayed; inspect the source and any recorded destination before retrying."
            changed = true
        }
        if changed {
            try save(recovered)
        } else {
            try secureExistingPaths()
        }
        return recovered
    }

    func save(_ transactions: [CodexConversationHandoff]) throws {
        try validate(transactions)
        try ensureDirectory()
        let data = try encoder.encode(
            CodexConversationHandoffEnvelope(transactions: transactions)
        )
        let temporaryURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".handoffs-v1.\(UUID().uuidString).tmp",
                isDirectory: false
            )
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )
        if fileManager.fileExists(atPath: storeURL.path) {
            _ = try fileManager.replaceItemAt(
                storeURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: storeURL)
        }
        try secureExistingPaths()
    }

    private func ensureDirectory() throws {
        let directoryURL = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func secureExistingPaths() throws {
        let directoryURL = storeURL.deletingLastPathComponent()
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        if fileManager.fileExists(atPath: storeURL.path) {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
        }
    }

    private func validate(_ transactions: [CodexConversationHandoff]) throws {
        var ids: Set<UUID> = []
        var activeSources: Set<String> = []
        for transaction in transactions {
            guard ids.insert(transaction.id).inserted else {
                throw CodexConversationHandoffStoreError.duplicateTransaction(
                    transaction.id
                )
            }
            if transaction.state == .verified,
               !transaction.canMarkSourceDone {
                throw CodexConversationHandoffStoreError
                    .incompleteVerifiedTransaction(transaction.id)
            }
            guard !transaction.state.isTerminal else { continue }
            let key = "\(transaction.homePath)::\(transaction.sourceThreadID)"
            guard activeSources.insert(key).inserted else {
                throw CodexConversationHandoffStoreError.duplicateActiveSource(key)
            }
        }
    }
}
