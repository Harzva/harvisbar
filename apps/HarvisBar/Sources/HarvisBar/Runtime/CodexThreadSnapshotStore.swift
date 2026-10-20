import Foundation

protocol CodexThreadSnapshotStoring: Actor {
    func load(now: Date) throws -> [String: CodexThreadSnapshot]
    func save(
        _ threads: [CodexThreadSummary],
        for homeID: String,
        now: Date
    ) throws
}

struct CodexThreadSnapshot: Codable, Sendable {
    let updatedAt: Date
    let threads: [CodexThreadSummary]
}

enum CodexThreadSnapshotStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case oversizedFile(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported Codex thread snapshot version: \(version)"
        case let .oversizedFile(size):
            return "Codex thread snapshot file is too large: \(size) bytes"
        }
    }
}

private struct CodexThreadSnapshotEnvelope: Codable {
    static let schemaVersion = 1

    let version: Int
    var homes: [String: CodexThreadSnapshot]

    init(homes: [String: CodexThreadSnapshot]) {
        version = Self.schemaVersion
        self.homes = homes
    }
}

/// Private, bounded stale-while-revalidate cache for the thread-card projection.
///
/// This contains only the same metadata already rendered by HarvisBar. It never
/// stores auth material, message bodies, tool output, or native session files.
actor CodexThreadSnapshotStore: CodexThreadSnapshotStoring {
    static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60
    static let defaultMaximumHomeCount = 16
    static let defaultMaximumThreadsPerHome = 100
    static let defaultMaximumFileBytes = 4 * 1024 * 1024

    static func defaultSnapshotURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("HarvisBar", isDirectory: true)
            .appendingPathComponent("CodexThreadSnapshots", isDirectory: true)
            .appendingPathComponent("snapshots-v1.json")
    }

    let snapshotURL: URL
    private let fileManager: FileManager
    private let retention: TimeInterval
    private let maximumHomeCount: Int
    private let maximumThreadsPerHome: Int
    private let maximumFileBytes: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        snapshotURL: URL = CodexThreadSnapshotStore.defaultSnapshotURL(),
        fileManager: FileManager = .default,
        retention: TimeInterval = CodexThreadSnapshotStore.defaultRetention,
        maximumHomeCount: Int = CodexThreadSnapshotStore.defaultMaximumHomeCount,
        maximumThreadsPerHome: Int = CodexThreadSnapshotStore.defaultMaximumThreadsPerHome,
        maximumFileBytes: Int = CodexThreadSnapshotStore.defaultMaximumFileBytes
    ) {
        self.snapshotURL = snapshotURL
        self.fileManager = fileManager
        self.retention = retention
        self.maximumHomeCount = max(1, maximumHomeCount)
        self.maximumThreadsPerHome = max(1, maximumThreadsPerHome)
        self.maximumFileBytes = max(1, maximumFileBytes)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func load(now: Date = Date()) throws -> [String: CodexThreadSnapshot] {
        try ensureDirectory()
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return [:]
        }
        let attributes = try fileManager.attributesOfItem(atPath: snapshotURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumFileBytes else {
            throw CodexThreadSnapshotStoreError.oversizedFile(size)
        }
        let data = try Data(contentsOf: snapshotURL)
        let envelope = try decoder.decode(CodexThreadSnapshotEnvelope.self, from: data)
        guard envelope.version == CodexThreadSnapshotEnvelope.schemaVersion else {
            throw CodexThreadSnapshotStoreError.unsupportedVersion(envelope.version)
        }
        try secureExistingPaths()
        return bounded(envelope.homes, now: now)
    }

    func save(
        _ threads: [CodexThreadSummary],
        for homeID: String,
        now: Date = Date()
    ) throws {
        guard !homeID.isEmpty else { return }
        var homes: [String: CodexThreadSnapshot]
        do {
            homes = try load(now: now)
        } catch CodexThreadSnapshotStoreError.unsupportedVersion,
                CodexThreadSnapshotStoreError.oversizedFile {
            homes = [:]
        } catch is DecodingError {
            homes = [:]
        }
        homes[homeID] = CodexThreadSnapshot(
            updatedAt: now,
            threads: Array(threads.prefix(maximumThreadsPerHome))
        )
        homes = bounded(homes, now: now)
        try write(CodexThreadSnapshotEnvelope(homes: homes))
    }

    private func bounded(
        _ homes: [String: CodexThreadSnapshot],
        now: Date
    ) -> [String: CodexThreadSnapshot] {
        let cutoff = now.addingTimeInterval(-retention)
        return Dictionary(
            uniqueKeysWithValues: homes
                .filter { $0.value.updatedAt >= cutoff && !$0.key.isEmpty }
                .sorted { left, right in
                    if left.value.updatedAt != right.value.updatedAt {
                        return left.value.updatedAt > right.value.updatedAt
                    }
                    return left.key < right.key
                }
                .prefix(maximumHomeCount)
                .map { key, snapshot in
                    (
                        key,
                        CodexThreadSnapshot(
                            updatedAt: snapshot.updatedAt,
                            threads: Array(snapshot.threads.prefix(maximumThreadsPerHome))
                        )
                    )
                }
        )
    }

    private func write(_ envelope: CodexThreadSnapshotEnvelope) throws {
        try ensureDirectory()
        let data = try encoder.encode(envelope)
        guard data.count <= maximumFileBytes else {
            throw CodexThreadSnapshotStoreError.oversizedFile(data.count)
        }
        let temporaryURL = snapshotURL
            .deletingLastPathComponent()
            .appendingPathComponent(".snapshots-v1.\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )
        if fileManager.fileExists(atPath: snapshotURL.path) {
            _ = try fileManager.replaceItemAt(
                snapshotURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
        }
        try secureExistingPaths()
    }

    private func ensureDirectory() throws {
        let directoryURL = snapshotURL.deletingLastPathComponent()
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
        let directoryURL = snapshotURL.deletingLastPathComponent()
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: snapshotURL.path
            )
        }
    }
}
