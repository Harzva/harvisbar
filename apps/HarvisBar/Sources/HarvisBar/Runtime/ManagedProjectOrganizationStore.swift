import Foundation

enum ManagedProjectOrganizationStoreError: Error, Equatable, LocalizedError {
    case invalidStoredType
    case unsupportedVersion(Int)
    case corruptData(String)

    var errorDescription: String? {
        switch self {
        case .invalidStoredType: return "项目整理存储格式异常；保留原数据，暂停修改。"
        case .unsupportedVersion(let version): return "不支持项目整理存储版本 \(version)；保留原数据。"
        case .corruptData(let detail): return "项目整理存储无法读取；保留原数据。\(detail)"
        }
    }
}

/// Synchronous, whole-envelope persistence. The owner serializes mutations and
/// publishes a returned state only after save succeeds. Reading never writes.
final class ManagedProjectOrganizationStore {
    static let storageKey = "harvisBar.projectOrganization.v1"
    private let defaults: UserDefaults

    private struct VersionHeader: Decodable { let schemaVersion: Int }
    private struct Envelope: Codable {
        var schemaVersion: Int
        var state: ManagedProjectOrganizationState
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(
        legacyAssignments: [String: ManagedChatProjectAssignment] = [:]
    ) throws -> ManagedProjectOrganizationState {
        guard let stored = defaults.object(forKey: Self.storageKey) else {
            let migrated = ManagedProjectOrganizationState(assignments: legacyAssignments)
            try ManagedProjectOrganizationEngine.validateState(migrated)
            return migrated
        }
        guard let data = stored as? Data else {
            throw ManagedProjectOrganizationStoreError.invalidStoredType
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let header: VersionHeader
        do { header = try decoder.decode(VersionHeader.self, from: data) }
        catch { throw ManagedProjectOrganizationStoreError.corruptData(error.localizedDescription) }
        guard header.schemaVersion == 1 else {
            throw ManagedProjectOrganizationStoreError.unsupportedVersion(header.schemaVersion)
        }
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            try ManagedProjectOrganizationEngine.validateState(envelope.state)
            return envelope.state
        } catch {
            throw ManagedProjectOrganizationStoreError.corruptData(error.localizedDescription)
        }
    }

    func save(_ state: ManagedProjectOrganizationState) throws {
        try ManagedProjectOrganizationEngine.validateState(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(Envelope(schemaVersion: 1, state: state))
        defaults.set(data, forKey: Self.storageKey)
    }
}
