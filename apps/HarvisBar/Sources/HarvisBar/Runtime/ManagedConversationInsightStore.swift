import Foundation

struct ManagedConversationInsightStoreEnvelopeV1: Codable, Equatable, Sendable {
    let version: Int
    var savedAt: Date
    var records: [ManagedConversationInsightStoreRecordV1]

    init(
        version: Int = ManagedConversationInsightSchemaV1.storeVersion,
        savedAt: Date = Date(),
        records: [ManagedConversationInsightStoreRecordV1] = []
    ) {
        self.version = version
        self.savedAt = savedAt
        self.records = records
    }

    func record(for target: ManagedConversationInsightTarget)
        -> ManagedConversationInsightStoreRecordV1? {
        records.first { $0.target == target }
    }

    /// In-memory replacement only. Durable runtime writers use store CAS first.
    mutating func upsert(_ record: ManagedConversationInsightStoreRecordV1) {
        if let index = records.firstIndex(where: { $0.target == record.target }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }
}

struct ManagedConversationInsightStoreRecordV1: Codable, Equatable, Sendable {
    let target: ManagedConversationInsightTarget
    var generationID: UUID
    var revision: Int
    var intent: ManagedConversationInsightIntent
    var requestID: String
    var inputFingerprint: String
    var totalInputCount: Int
    var analyzedInputCount: Int
    var omittedInputCount: Int
    var state: ManagedConversationInsightDeliveryState
    var sessionID: String
    var rpcID: String
    var cancelRPCID: String?
    var analyzedCurrentProjectCandidateID: String?
    var latestInsight: ManagedConversationInsightV1?
    var updatedAt: Date
    var lastError: String?

    /// Explicit defaults keep external fixtures source-compatible while v2
    /// always encodes the generation, revision, intent, and request identity.
    init(
        target: ManagedConversationInsightTarget,
        generationID: UUID = UUID(),
        revision: Int = 1,
        intent: ManagedConversationInsightIntent = .analyze,
        requestID: String? = nil,
        inputFingerprint: String,
        totalInputCount: Int,
        analyzedInputCount: Int,
        omittedInputCount: Int,
        state: ManagedConversationInsightDeliveryState,
        sessionID: String,
        rpcID: String,
        cancelRPCID: String? = nil,
        analyzedCurrentProjectCandidateID: String?,
        latestInsight: ManagedConversationInsightV1?,
        updatedAt: Date,
        lastError: String?
    ) {
        self.target = target
        self.generationID = generationID
        self.revision = revision
        self.intent = intent
        self.requestID = requestID ?? rpcID
        self.inputFingerprint = inputFingerprint
        self.totalInputCount = totalInputCount
        self.analyzedInputCount = analyzedInputCount
        self.omittedInputCount = omittedInputCount
        self.state = state
        self.sessionID = sessionID
        self.rpcID = rpcID
        self.cancelRPCID = cancelRPCID
        self.analyzedCurrentProjectCandidateID = analyzedCurrentProjectCandidateID
        self.latestInsight = latestInsight
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}

protocol ManagedConversationInsightStoringV1: Actor {
    func load() throws -> ManagedConversationInsightStoreEnvelopeV1
    func save(_ envelope: ManagedConversationInsightStoreEnvelopeV1) throws
    func record(for target: ManagedConversationInsightTarget) throws
        -> ManagedConversationInsightStoreRecordV1?
    func upsert(_ record: ManagedConversationInsightStoreRecordV1) throws
    func upsert(
        _ record: ManagedConversationInsightStoreRecordV1,
        expectedRevision: Int?
    ) throws
}

extension ManagedConversationInsightStoringV1 {
    /// Actor isolation makes this compatibility implementation an atomic CAS
    /// for existing in-memory stores. The disk store also implements it.
    func upsert(
        _ record: ManagedConversationInsightStoreRecordV1,
        expectedRevision: Int?
    ) throws {
        let actual = try self.record(for: record.target)?.revision
        guard actual == expectedRevision else {
            throw ManagedConversationInsightStoreErrorV1.staleRevision(
                expected: expectedRevision,
                actual: actual
            )
        }
        let required = (actual ?? 0) + 1
        guard record.revision == required else {
            throw ManagedConversationInsightStoreErrorV1.invalidRevision(
                expected: required,
                actual: record.revision
            )
        }
        try upsert(record)
    }
}

enum ManagedConversationInsightStoreErrorV1: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case duplicateTarget(String)
    case invalidRecord(String)
    case invalidRevision(expected: Int, actual: Int)
    case staleRevision(expected: Int?, actual: Int?)
    case sensitiveMaterial(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported conversation insight store version: \(version)"
        case let .duplicateTarget(key):
            return "Duplicate conversation insight target: \(key)"
        case let .invalidRecord(reason):
            return "Invalid conversation insight record: \(reason)"
        case let .invalidRevision(expected, actual):
            return "Invalid conversation insight revision \(actual); expected \(expected)."
        case let .staleRevision(expected, actual):
            return "Conversation insight CAS failed; expected revision \(String(describing: expected)), actual \(String(describing: actual))."
        case let .sensitiveMaterial(field):
            return "Conversation insight persistence rejected sensitive material in \(field)."
        }
    }
}

actor ManagedConversationInsightStoreV1: ManagedConversationInsightStoringV1 {
    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("HarvisBar", isDirectory: true)
            .appendingPathComponent("ManagedConversationInsight", isDirectory: true)
            .appendingPathComponent("insight-v2.json", isDirectory: false)
    }

    let storeURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedEnvelope: ManagedConversationInsightStoreEnvelopeV1?

    init(
        storeURL: URL = ManagedConversationInsightStoreV1.defaultURL(),
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

    func load() throws -> ManagedConversationInsightStoreEnvelopeV1 {
        if let cachedEnvelope { return cachedEnvelope }
        try ensureDirectory()
        guard fileManager.fileExists(atPath: storeURL.path) else {
            let empty = ManagedConversationInsightStoreEnvelopeV1()
            cachedEnvelope = empty
            return empty
        }

        var envelope = try decoder.decode(
            ManagedConversationInsightStoreEnvelopeV1.self,
            from: Data(contentsOf: storeURL)
        )
        try validate(envelope)

        let recoveredAt = Date()
        var recovered = false
        for index in envelope.records.indices where envelope.records[index].state.isInFlight {
            envelope.records[index].revision += 1
            envelope.records[index].state = .deliveryUnknown
            envelope.records[index].updatedAt = recoveredAt
            envelope.records[index].lastError =
                "Harvis restarted while delivery was in flight; the request was not replayed."
            recovered = true
        }
        if recovered {
            envelope.savedAt = recoveredAt
            try write(envelope)
        } else {
            try secureExistingPaths()
            cachedEnvelope = envelope
        }
        return envelope
    }

    /// Bootstrap/test API. Coordinator runtime transitions always use CAS.
    func save(_ envelope: ManagedConversationInsightStoreEnvelopeV1) throws {
        try write(envelope)
    }

    func record(for target: ManagedConversationInsightTarget) throws
        -> ManagedConversationInsightStoreRecordV1? {
        try load().record(for: target)
    }

    /// Compatibility API retained for existing fixtures. Coordinator does not call it.
    func upsert(_ record: ManagedConversationInsightStoreRecordV1) throws {
        var envelope = try load()
        envelope.upsert(record)
        envelope.savedAt = record.updatedAt
        try write(envelope)
    }

    func upsert(
        _ record: ManagedConversationInsightStoreRecordV1,
        expectedRevision: Int?
    ) throws {
        var envelope = try load()
        let actual = envelope.record(for: record.target)?.revision
        guard actual == expectedRevision else {
            throw ManagedConversationInsightStoreErrorV1.staleRevision(
                expected: expectedRevision,
                actual: actual
            )
        }
        let required = (actual ?? 0) + 1
        guard record.revision == required else {
            throw ManagedConversationInsightStoreErrorV1.invalidRevision(
                expected: required,
                actual: record.revision
            )
        }
        envelope.upsert(record)
        envelope.savedAt = record.updatedAt
        try write(envelope)
    }

    private func write(_ envelope: ManagedConversationInsightStoreEnvelopeV1) throws {
        try validate(envelope)
        try ensureDirectory()
        let data = try encoder.encode(envelope)
        let temporaryURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(".insight-v2.\(UUID().uuidString).tmp")
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

    private func validate(_ envelope: ManagedConversationInsightStoreEnvelopeV1) throws {
        guard envelope.version == ManagedConversationInsightSchemaV1.storeVersion else {
            throw ManagedConversationInsightStoreErrorV1.unsupportedVersion(envelope.version)
        }
        var targets: Set<String> = []
        for record in envelope.records {
            try ManagedConversationInsightValidatorV1.validate(target: record.target)
            guard targets.insert(record.target.storageKey).inserted else {
                throw ManagedConversationInsightStoreErrorV1.duplicateTarget(
                    record.target.storageKey
                )
            }
            guard record.revision >= 1,
                  record.totalInputCount >= 0,
                  record.analyzedInputCount >= 0,
                  record.analyzedInputCount <= record.totalInputCount,
                  record.omittedInputCount == record.totalInputCount - record.analyzedInputCount,
                  UUID(uuidString: record.sessionID) != nil,
                  !record.rpcID.isEmpty,
                  !record.requestID.isEmpty,
                  !record.inputFingerprint.isEmpty else {
                throw ManagedConversationInsightStoreErrorV1.invalidRecord(
                    record.target.storageKey
                )
            }
            if record.state == .cancelling || record.state == .cancelled {
                guard record.intent == .cancel, record.cancelRPCID?.isEmpty == false else {
                    throw ManagedConversationInsightStoreErrorV1.invalidRecord(
                        "cancel state is missing its durable cancel intent"
                    )
                }
            }
            if record.intent == .analyze, record.cancelRPCID != nil {
                throw ManagedConversationInsightStoreErrorV1.invalidRecord(
                    "analyze intent unexpectedly contains a cancel rpc id"
                )
            }
            if record.state == .completed {
                guard record.intent == .analyze,
                      let latest = record.latestInsight,
                      latest.requestID == record.requestID,
                      latest.inputFingerprint == record.inputFingerprint,
                      latest.analyzedInputCount == record.analyzedInputCount,
                      latest.totalInputCount == record.totalInputCount,
                      latest.currentProjectCandidateID == record.analyzedCurrentProjectCandidateID else {
                    throw ManagedConversationInsightStoreErrorV1.invalidRecord(
                        "completed record does not match its exact insight"
                    )
                }
            }
            if let insight = record.latestInsight {
                try ManagedConversationInsightValidatorV1.validate(insight: insight)
                try requireSafe(insight.summary.coreGoal, field: "coreGoal")
                for value in insight.summary.mainTasks { try requireSafe(value, field: "mainTasks") }
                for value in insight.summary.constraints { try requireSafe(value, field: "constraints") }
                for value in insight.summary.openQuestions { try requireSafe(value, field: "openQuestions") }
                try requireSafe(insight.relevance.reason, field: "reason")
            }
            if let error = record.lastError { try requireSafe(error, field: "lastError") }
            for (value, field) in [
                (record.target.provider, "target.provider"),
                (record.target.sourceScope, "target.sourceScope"),
                (record.target.sourceID, "target.sourceID"),
                (record.inputFingerprint, "inputFingerprint"),
                (record.requestID, "requestID"),
                (record.rpcID, "rpcID"),
                (record.sessionID, "sessionID"),
            ] {
                try requireSafeIdentifier(value, field: field)
            }
            if let cancelRPCID = record.cancelRPCID {
                try requireSafeIdentifier(cancelRPCID, field: "cancelRPCID")
            }
        }
    }

    private func requireSafe(_ value: String, field: String) throws {
        guard ManagedConversationInsightRedactor.redact(value) == value else {
            throw ManagedConversationInsightStoreErrorV1.sensitiveMaterial(field)
        }
    }

    private func requireSafeIdentifier(_ value: String, field: String) throws {
        guard ManagedConversationInsightRedactor.redact(value) == value else {
            throw ManagedConversationInsightStoreErrorV1.sensitiveMaterial(field)
        }
    }
}
