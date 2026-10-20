import Foundation

protocol CodexTaskQueueStoring: Actor {
    func load() throws -> [CodexTaskQueueItem]
    func save(_ items: [CodexTaskQueueItem]) throws
}

enum CodexTaskQueueStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case duplicateCommand(UUID)
    case invalidBatch(UUID?, String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported Codex task queue version: \(version)"
        case let .duplicateCommand(id):
            return "Duplicate Codex task command: \(id.uuidString)"
        case let .invalidBatch(batchID, reason):
            let label = batchID?.uuidString ?? "missing-id"
            return "Invalid Codex automatic batch \(label): \(reason)"
        }
    }
}

actor CodexTaskQueueStore: CodexTaskQueueStoring {
    static func defaultQueueURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("HarvisBar", isDirectory: true)
            .appendingPathComponent("CodexTaskQueue", isDirectory: true)
            .appendingPathComponent("queue-v1.json")
    }

    let queueURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        queueURL: URL = CodexTaskQueueStore.defaultQueueURL(),
        fileManager: FileManager = .default
    ) {
        self.queueURL = queueURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func load() throws -> [CodexTaskQueueItem] {
        try ensureDirectory()
        guard fileManager.fileExists(atPath: queueURL.path) else {
            return []
        }
        let data = try Data(contentsOf: queueURL)
        let envelope = try decoder.decode(CodexTaskQueueEnvelope.self, from: data)
        guard envelope.version == CodexTaskQueueEnvelope.schemaVersion else {
            throw CodexTaskQueueStoreError.unsupportedVersion(envelope.version)
        }
        try validateUnique(envelope.items)

        var recovered = envelope.items
        var changed = false
        for index in recovered.indices {
            switch recovered[index].state {
            case .dispatching:
                recovered[index].state = .deliveryUnknown
                recovered[index].stateChangedAt = Date()
                recovered[index].lastError =
                    "HarvisBar restarted while an RPC delivery was in flight. The command was not resent."
                changed = true
            case .running:
                recovered[index].state = .deliveryUnknown
                recovered[index].stateChangedAt = Date()
                recovered[index].lastError =
                    "HarvisBar restarted after the turn was delivered but before its final status was recorded. The command was not resent; inspect the task before retrying."
                changed = true
            case .waitingApproval:
                recovered[index].state = .deliveryUnknown
                recovered[index].stateChangedAt = Date()
                recovered[index].lastError =
                    "HarvisBar restarted while a user decision was pending. That connection-bound request cannot be reconstructed, and the command was not resent."
                changed = true
            default:
                break
            }
            if case let .manager(turnID, _) = recovered[index].ownership {
                recovered[index].ownership = .external(turnID: turnID)
                changed = true
            }
            if recovered[index].connectionID != nil {
                recovered[index].connectionID = nil
                changed = true
            }
        }
        if changed {
            try save(recovered)
        } else {
            try secureExistingPaths()
        }
        return recovered
    }

    func save(_ items: [CodexTaskQueueItem]) throws {
        try validateUnique(items)
        try ensureDirectory()
        let envelope = CodexTaskQueueEnvelope(items: items)
        let data = try encoder.encode(envelope)
        let temporaryURL = queueURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".queue-v1.\(UUID().uuidString).tmp",
                isDirectory: false
            )
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )

        if fileManager.fileExists(atPath: queueURL.path) {
            _ = try fileManager.replaceItemAt(
                queueURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: queueURL)
        }
        try secureExistingPaths()
    }

    private func ensureDirectory() throws {
        let directoryURL = queueURL.deletingLastPathComponent()
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
        let directoryURL = queueURL.deletingLastPathComponent()
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        if fileManager.fileExists(atPath: queueURL.path) {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: queueURL.path
            )
        }
    }

    private func validateUnique(_ items: [CodexTaskQueueItem]) throws {
        var ids: Set<UUID> = []
        var batches: [UUID: [CodexTaskQueueItem]] = [:]
        for item in items {
            guard ids.insert(item.id).inserted else {
                throw CodexTaskQueueStoreError.duplicateCommand(item.id)
            }
            switch (item.command.strategy, item.command.batch) {
            case (.smart, nil), (.freshTurn, nil):
                break
            case let (.serialBatch, batch?):
                batches[batch.batchID, default: []].append(item)
            case (.smart, .some), (.freshTurn, .some):
                throw CodexTaskQueueStoreError.invalidBatch(
                    item.command.batch?.batchID,
                    "a non-batch command cannot carry batch metadata"
                )
            case (.serialBatch, nil):
                throw CodexTaskQueueStoreError.invalidBatch(
                    nil,
                    "a serial batch command is missing its position"
                )
            }
        }

        for (batchID, batchItems) in batches {
            guard let first = batchItems.first,
                  let position = first.command.batch else {
                continue
            }
            guard CodexSerialBatchPolicy.repeatCountRange.contains(
                position.count
            ), batchItems.count == position.count else {
                throw CodexTaskQueueStoreError.invalidBatch(
                    batchID,
                    "the persisted step count is incomplete or out of range"
                )
            }
            let ordinals = Set(batchItems.compactMap {
                $0.command.batch?.ordinal
            })
            guard ordinals == Set(0 ..< position.count) else {
                throw CodexTaskQueueStoreError.invalidBatch(
                    batchID,
                    "step ordinals must be unique and contiguous"
                )
            }
            guard batchItems.allSatisfy({ item in
                item.command.batch?.count == position.count
                    && item.command.homeID == first.command.homeID
                    && item.command.homePath == first.command.homePath
                    && item.command.threadID == first.command.threadID
                    && item.command.sourceThreadID == first.command.sourceThreadID
                    && item.command.cardType == first.command.cardType
                    && item.command.text == first.command.text
            }) else {
                throw CodexTaskQueueStoreError.invalidBatch(
                    batchID,
                    "all steps must share one target, prompt, and total"
                )
            }
        }
    }
}
