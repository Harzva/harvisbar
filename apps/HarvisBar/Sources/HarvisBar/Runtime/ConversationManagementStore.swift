import Foundation

struct ConversationManagementStoreEnvelopeV1: Codable, Equatable, Sendable {
    static let schemaVersion = ConversationManagementSchemaV1.version

    let version: Int
    var savedAt: Date
    var snapshots: [ConversationManagementSnapshotV1]
    var ledgers: [ConversationManagementProgressLedgerV1]

    init(
        version: Int = schemaVersion,
        savedAt: Date = Date(),
        snapshots: [ConversationManagementSnapshotV1] = [],
        ledgers: [ConversationManagementProgressLedgerV1] = []
    ) {
        self.version = version
        self.savedAt = savedAt
        self.snapshots = snapshots
        self.ledgers = ledgers
    }

    func snapshot(projectID: String) -> ConversationManagementSnapshotV1? {
        snapshots.first { $0.projectID == projectID }
    }

    func ledger(runID: UUID) -> ConversationManagementProgressLedgerV1? {
        ledgers.first { $0.runID == runID }
    }

    mutating func upsert(
        snapshot: ConversationManagementSnapshotV1,
        expectedRevision: Int?
    ) throws {
        try ConversationManagementSchemaValidatorV1.validate(snapshot: snapshot)
        if let index = snapshots.firstIndex(where: {
            $0.projectID == snapshot.projectID
        }) {
            let currentRevision = snapshots[index].revision
            guard expectedRevision == currentRevision else {
                throw ConversationManagementSchemaErrorV1.staleRevision(
                    expected: expectedRevision ?? -1,
                    actual: currentRevision
                )
            }
            snapshots[index] = snapshot
        } else {
            guard expectedRevision == nil else {
                throw ConversationManagementSchemaErrorV1.staleRevision(
                    expected: expectedRevision ?? -1,
                    actual: -1
                )
            }
            snapshots.append(snapshot)
        }
    }

    mutating func upsert(
        ledger: ConversationManagementProgressLedgerV1,
        expectedRevision: Int?
    ) throws {
        try ConversationManagementSchemaValidatorV1.validate(ledger: ledger)
        if let index = ledgers.firstIndex(where: { $0.runID == ledger.runID }) {
            let currentRevision = ledgers[index].revision
            guard expectedRevision == currentRevision else {
                throw ConversationManagementSchemaErrorV1.staleRevision(
                    expected: expectedRevision ?? -1,
                    actual: currentRevision
                )
            }
            ledgers[index] = ledger
        } else {
            guard expectedRevision == nil else {
                throw ConversationManagementSchemaErrorV1.staleRevision(
                    expected: expectedRevision ?? -1,
                    actual: -1
                )
            }
            ledgers.append(ledger)
        }
    }
}

protocol ConversationManagementStoringV1: Actor {
    func load() throws -> ConversationManagementStoreEnvelopeV1
    func save(_ envelope: ConversationManagementStoreEnvelopeV1) throws
    func snapshot(projectID: String) throws -> ConversationManagementSnapshotV1?
    func ledger(runID: UUID) throws -> ConversationManagementProgressLedgerV1?
    func upsert(
        snapshot: ConversationManagementSnapshotV1,
        expectedRevision: Int?
    ) throws
    func upsert(
        ledger: ConversationManagementProgressLedgerV1,
        expectedRevision: Int?
    ) throws
}

enum ConversationManagementStoreErrorV1: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case orphanLedger(runID: UUID, projectID: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported Conversation Management store version: \(version)"
        case let .orphanLedger(runID, projectID):
            return "Conversation Management run \(runID.uuidString) references missing project \(projectID)."
        }
    }
}

actor ConversationManagementStoreV1: ConversationManagementStoringV1 {
    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return base
            .appendingPathComponent("HarvisBar", isDirectory: true)
            .appendingPathComponent(
                "ConversationManagement",
                isDirectory: true
            )
            .appendingPathComponent("management-v1.json")
    }

    let storeURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// One actor instance represents one app-process lifecycle. Recovery must
    /// run only on the first disk read, never on an ordinary in-process CAS.
    private var cachedEnvelope: ConversationManagementStoreEnvelopeV1?

    init(
        storeURL: URL = ConversationManagementStoreV1.defaultURL(),
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        cachedEnvelope = nil
    }

    func load() throws -> ConversationManagementStoreEnvelopeV1 {
        if let cachedEnvelope {
            return cachedEnvelope
        }
        try ensureDirectory()
        guard fileManager.fileExists(atPath: storeURL.path) else {
            let empty = ConversationManagementStoreEnvelopeV1()
            cachedEnvelope = empty
            return empty
        }
        let storedData = try Data(contentsOf: storeURL)
        let requiresMigration = Self.requiresAdditiveV1Migration(storedData)
        var envelope = try decoder.decode(
            ConversationManagementStoreEnvelopeV1.self,
            from: storedData
        )
        guard envelope.version == ConversationManagementStoreEnvelopeV1
            .schemaVersion else {
            throw ConversationManagementStoreErrorV1.unsupportedVersion(
                envelope.version
            )
        }
        try validate(envelope)

        let now = Date()
        var changed = false
        for ledgerIndex in envelope.ledgers.indices {
            if envelope.ledgers[ledgerIndex].recoverAfterRestart(at: now) {
                changed = true
            }
        }
        for snapshotIndex in envelope.snapshots.indices {
            var snapshotChanged = false
            for recordIndex in envelope.snapshots[snapshotIndex]
                .conversations.indices {
                guard var extensionValue = envelope.snapshots[snapshotIndex]
                    .conversations[recordIndex].managementExtension,
                      extensionValue.delivery.isRestartAmbiguous
                        || extensionValue.management.isRestartAmbiguous else {
                    continue
                }
                extensionValue.delivery = .deliveryUnknown
                extensionValue.management = .deliveryUnknown
                extensionValue.revision += 1
                extensionValue.updatedAt = now
                envelope.snapshots[snapshotIndex]
                    .conversations[recordIndex].managementExtension
                    = extensionValue
                snapshotChanged = true
            }
            if snapshotChanged {
                envelope.snapshots[snapshotIndex].revision += 1
                envelope.snapshots[snapshotIndex].generatedAt = now
                changed = true
            }
        }

        if changed || requiresMigration {
            envelope.savedAt = now
            try save(envelope)
        } else {
            try secureExistingPaths()
            cachedEnvelope = envelope
        }
        return envelope
    }

    func save(_ envelope: ConversationManagementStoreEnvelopeV1) throws {
        try validate(envelope)
        try ensureDirectory()
        let data = try encoder.encode(envelope)
        let temporaryURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".management-v1.\(UUID().uuidString).tmp",
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
        cachedEnvelope = envelope
    }

    func snapshot(
        projectID: String
    ) throws -> ConversationManagementSnapshotV1? {
        try load().snapshot(projectID: projectID)
    }

    func ledger(
        runID: UUID
    ) throws -> ConversationManagementProgressLedgerV1? {
        try load().ledger(runID: runID)
    }

    /// Actor-isolated read/CAS/write transaction. Callers should prefer this
    /// over a separate load and save when replacing one record.
    func upsert(
        snapshot: ConversationManagementSnapshotV1,
        expectedRevision: Int?
    ) throws {
        var envelope = try load()
        try envelope.upsert(
            snapshot: snapshot,
            expectedRevision: expectedRevision
        )
        envelope.savedAt = Date()
        try save(envelope)
    }

    /// Actor-isolated read/CAS/write transaction. `expectedRevision == nil`
    /// means create-only; a concrete value means replace-only.
    func upsert(
        ledger: ConversationManagementProgressLedgerV1,
        expectedRevision: Int?
    ) throws {
        var envelope = try load()
        try envelope.upsert(
            ledger: ledger,
            expectedRevision: expectedRevision
        )
        envelope.savedAt = Date()
        try save(envelope)
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

    private func validate(
        _ envelope: ConversationManagementStoreEnvelopeV1
    ) throws {
        guard envelope.version == ConversationManagementStoreEnvelopeV1
            .schemaVersion else {
            throw ConversationManagementStoreErrorV1.unsupportedVersion(
                envelope.version
            )
        }
        var projectIDs: Set<String> = []
        for snapshot in envelope.snapshots {
            guard projectIDs.insert(snapshot.projectID).inserted else {
                throw ConversationManagementSchemaErrorV1.duplicateProject(
                    snapshot.projectID
                )
            }
            try ConversationManagementSchemaValidatorV1.validate(
                snapshot: snapshot
            )
        }

        var runIDs: Set<UUID> = []
        for ledger in envelope.ledgers {
            guard runIDs.insert(ledger.runID).inserted else {
                throw ConversationManagementSchemaErrorV1.duplicateRun(
                    ledger.runID
                )
            }
            guard projectIDs.contains(ledger.projectID) else {
                throw ConversationManagementStoreErrorV1.orphanLedger(
                    runID: ledger.runID,
                    projectID: ledger.projectID
                )
            }
            try ConversationManagementSchemaValidatorV1.validate(
                ledger: ledger
            )
        }
    }

    /// Detect additive fields introduced while the store remains schema v1.
    /// Decoders provide fail-closed defaults; a one-time canonical rewrite
    /// makes that migration durable and independently inspectable.
    private static func requiresAdditiveV1Migration(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let snapshots = root["snapshots"] as? [[String: Any]] else {
            return false
        }
        for snapshot in snapshots {
            if snapshot["brainEnabled"] == nil || snapshot["taskPlan"] == nil {
                return true
            }
            guard let conversations = snapshot["conversations"]
                as? [[String: Any]] else {
                continue
            }
            for conversation in conversations {
                if let base = conversation["base"] as? [String: Any],
                   base["startedAt"] == nil {
                    return true
                }
                if let extensionValue = conversation["managementExtension"]
                    as? [String: Any],
                   (extensionValue["workKind"] == nil
                    || extensionValue["taskBindings"] == nil) {
                    return true
                }
            }
        }
        return false
    }
}
