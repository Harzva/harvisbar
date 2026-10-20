import Foundation
import HarvisProxyCore

enum PerAppProxyStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "不支持的按应用代理配置版本：\(version)"
        }
    }
}

struct PerAppProxyStore {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let configuration: PerAppProxyConfiguration
    }

    static let currentSchemaVersion = 1
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.fileURL = base
            .appendingPathComponent("HarvisBar", isDirectory: true)
            .appendingPathComponent("per-app-proxy.json", isDirectory: false)
    }

    func load() throws -> PerAppProxyConfiguration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.schemaVersion == Self.currentSchemaVersion else {
            throw PerAppProxyStoreError.unsupportedSchema(envelope.schemaVersion)
        }
        return envelope.configuration
    }

    func save(_ configuration: PerAppProxyConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let envelope = Envelope(
            schemaVersion: Self.currentSchemaVersion,
            configuration: configuration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(envelope).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
