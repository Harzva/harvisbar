import Foundation

struct DshBridgeAuthority: Codable, Equatable, Sendable {
    let homeID: String
    let profile: String
    let runtimeID: String

    enum CodingKeys: String, CodingKey {
        case homeID, profile
        case runtimeID = "runtimeId"
    }

    func validate(for endpoint: DshRuntimeEndpoint) throws {
        guard homeID == endpoint.homeID, profile == endpoint.profile,
              !runtimeID.isEmpty, runtimeID.utf8.count <= 128,
              runtimeID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw DshCapabilityBridgeError.authorityMismatch
        }
    }
}

struct DshCapabilityDescriptor: Codable, Equatable, Identifiable, Sendable {
    enum Availability: String, Codable, Sendable {
        case available
        case unavailable
    }

    let id: String
    let version: Int
    let title: String
    let scope: String
    let operations: [String]
    let availability: Availability
    let reason: String?
    let requiresApproval: Bool
    let supportsCancel: Bool
}

struct DshCapabilityCatalog: Decodable, Equatable, Sendable {
    static let supportedSchemaVersion = "harvis.dsh-capabilities.v1"

    let schemaVersion: String
    let bridgeVersion: String
    let capabilities: [DshCapabilityDescriptor]

    func supports(_ capabilityID: String, operation: String) -> Bool {
        capabilities.contains {
            $0.id == capabilityID && $0.version == 1
                && $0.availability == .available && $0.operations.contains(operation)
        }
    }

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion,
              !bridgeVersion.isEmpty, bridgeVersion.count <= 64,
              capabilities.count <= 64 else {
            throw DshCapabilityBridgeError.incompatibleContract
        }
        var identifiers = Set<String>()
        for capability in capabilities {
            guard !capability.id.isEmpty, capability.id.count <= 128,
                  identifiers.insert(capability.id).inserted,
                  capability.version >= 1,
                  !capability.title.isEmpty, capability.title.count <= 120,
                  ["session", "host", "project"].contains(capability.scope),
                  capability.operations.count <= 20,
                  Set(capability.operations).count == capability.operations.count,
                  capability.operations.allSatisfy({ !$0.isEmpty && $0.count <= 80 }),
                  capability.reason.map({ $0.count <= 500 }) != false else {
                throw DshCapabilityBridgeError.invalidResponse
            }
        }
    }
}

struct DshBridgeValue<Value: Sendable>: Sendable {
    let authority: DshBridgeAuthority
    let value: Value
}

struct DshBridgeEndpointState: Equatable, Sendable {
    let endpoint: DshRuntimeEndpoint
    let authority: DshBridgeAuthority?
    let catalog: DshCapabilityCatalog?
    let error: String?

    func supports(_ id: String, operation: String) -> Bool {
        error == nil && authority != nil && catalog?.supports(id, operation: operation) == true
    }
}

struct DshUserInputPage: Decodable, Equatable, Sendable {
    static let supportedSchemaVersion = "harvis.dsh-user-inputs.v1"

    let schemaVersion: String
    let sessionID: String
    let sourceAvailable: Bool
    let sourceRevision: String?
    let items: [ManagedConversationUserInputWireItem]
    let nextCursor: String?
    let excludedNonHumanItems: Int
    let totalItems: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion, sourceAvailable, sourceRevision, items, nextCursor
        case excludedNonHumanItems, totalItems
        case sessionID = "sessionId"
    }

    func validate(expectedSessionID: String, limit: Int) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw DshCapabilityBridgeError.incompatibleContract
        }
        guard sessionID == expectedSessionID else {
            throw DshCapabilityBridgeError.authorityMismatch
        }
        guard (0...1_000_000).contains(totalItems),
              (0...10_000_000).contains(excludedNonHumanItems),
              items.count <= limit, items.count <= totalItems,
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 2_048 }) != false else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        if sourceAvailable {
            guard let sourceRevision, Self.isRevision(sourceRevision) else {
                throw DshCapabilityBridgeError.invalidResponse
            }
        } else {
            guard sourceRevision == nil, items.isEmpty, nextCursor == nil, totalItems == 0 else {
                throw DshCapabilityBridgeError.invalidResponse
            }
        }
        var identifiers = Set<String>()
        var previousSequence: Int64?
        for item in items {
            guard !item.id.isEmpty, item.id.utf8.count <= 256,
                  identifiers.insert(item.id).inserted,
                  item.sequence >= 0,
                  previousSequence.map({ item.sequence > $0 }) != false,
                  !item.text.isEmpty, item.text.count <= 12_000,
                  item.originalCharacterCount >= item.text.count,
                  item.source == .human || item.source == .unknown,
                  item.originMessageIDHash.map(Self.isRevision) != false else {
                throw DshCapabilityBridgeError.invalidResponse
            }
            previousSequence = item.sequence
        }
    }

    static func isRevision(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && value.utf8.count == 71
            && value.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
    }
}

enum DshCapabilityBridgeError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case invalidEndpoint
    case incompatibleContract
    case authorityMismatch
    case invalidResponse
    case sourceChanged
    case remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "此 DSH 实例尚未提供 Harvis 能力桥接。"
        case .invalidEndpoint:
            return "DSH 实例连接信息无效。"
        case .incompatibleContract:
            return "DSH 能力接口版本不兼容，请更新对应桥接插件。"
        case .authorityMismatch:
            return "DSH 实例或目标会话已变化，请刷新后重试。"
        case .invalidResponse:
            return "DSH 返回的数据未通过完整性检查。"
        case .sourceChanged:
            return "DSH 用户输入在读取期间发生变化，请重新读取。"
        case let .remoteFailure(code):
            switch code {
            case "source-unavailable", "session-not-found":
                return "DSH 会话源暂不可用。"
            case "internal-session":
                return "内部管理或分析会话不参与项目整理。"
            case "stale-cursor", "source-changed":
                return "DSH 用户输入版本已变化，请重新读取。"
            case "capability-unavailable":
                return "对应 DSH 插件能力尚未就绪。"
            default:
                return "DSH 能力请求未完成，请检查实例状态。"
            }
        }
    }
}
