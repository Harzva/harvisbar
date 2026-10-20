import Foundation

struct DshRuntimeEndpoint: Equatable, Sendable {
    let homeID: String
    let profile: String
    let port: Int

    var sourceScope: String {
        "dsh::\(homeID)::\(profile)"
    }
}

struct DshHostDescription: Decodable, Equatable, Sendable {
    let applicationName: String?
    let applicationVersion: String?

    private enum CodingKeys: String, CodingKey {
        case app
        case application
        case name
        case version
    }

    private struct Application: Decodable {
        let name: String?
        let version: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let application = (try? container.decode(Application.self, forKey: .app))
            ?? (try? container.decode(Application.self, forKey: .application))
        applicationName = application?.name
            ?? (try? container.decode(String.self, forKey: .name))
        applicationVersion = application?.version
            ?? (try? container.decode(String.self, forKey: .version))
    }
}

struct DshWorkspace: Decodable, Equatable, Sendable {
    let workspaceID: String
    let path: String
    let title: String?
    let sessionIDs: [String]
    let createdAt: String?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case path
        case title
        case sessionIDs = "sessionIds"
        case createdAt
        case updatedAt
    }
}

struct DshWorkspaceList: Decodable, Equatable, Sendable {
    let items: [DshWorkspace]
    let archivedSessionIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case items
        case archivedSessionIDs = "archivedSessionIds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([DshWorkspace].self, forKey: .items)
        archivedSessionIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .archivedSessionIDs
        ) ?? []
    }
}

struct DshChatSession: Equatable, Sendable {
    let sourceID: String
    let sourceScope: String
    let title: String
    let titleSource: String?
    let hasMeaningfulTitle: Bool
    let updatedAt: Int64
    let running: Bool
    let cwd: String?
    let parentSessionID: String?
    let origin: String?
    let agentPreset: String?
}

struct DshChatDiscovery: Equatable, Sendable {
    let endpoint: DshRuntimeEndpoint
    let sourceScope: String
    let host: DshHostDescription
    let workspaces: [DshWorkspace]
    let archivedSessionIDs: [String]
    let sessions: [DshChatSession]
}

enum DshAgentPresetTrust: String, Decodable, Equatable, Sendable {
    case system
    case user
}

struct DshAgentPresetEntry: Decodable, Equatable, Sendable {
    let id: String
    let trust: DshAgentPresetTrust
    let isDefault: Bool
    let name: String?
    let description: String?
    let broken: String?
}

struct DshAgentPresetListValue: Decodable, Equatable, Sendable {
    let presets: [DshAgentPresetEntry]
    let authorable: Bool
    let hasDocument: Bool
}

struct DshAgentPresetReadPayload: Encodable, Equatable, Sendable {
    let agentPreset: String
}

struct DshAgentPresetReadValue: Decodable, Equatable, Sendable {
    let agentPreset: String
    let trust: DshAgentPresetTrust
    let content: String
    let name: String?
    let description: String?
}

struct DshSessionCreatePayload: Encodable, Equatable, Sendable {
    let workspaceID: String?
    let cwd: String?
    let sessionID: String?
    let agentPreset: String?

    init(
        workspaceID: String? = nil,
        cwd: String? = nil,
        sessionID: String? = nil,
        agentPreset: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.sessionID = sessionID
        self.agentPreset = agentPreset
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case cwd
        case sessionID = "sessionId"
        case agentPreset
    }
}

struct DshSessionCreateValue: Decodable, Equatable, Sendable {
    let sessionID: String
    let agentPreset: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case agentPreset
    }
}

struct DshSessionRenamePayload: Encodable, Equatable, Sendable {
    let sessionID: String
    let title: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case title
    }
}

struct DshSessionRenameValue: Decodable, Equatable, Sendable {
    let title: String
    let seq: Int
}

enum DshSessionPromptMode: String, Codable, Equatable, Sendable {
    case queue
    case steer
}

enum DshPromptContentPart: Codable, Equatable, Sendable {
    case text(String)
    case image(mediaType: String, data: String, name: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case mediaType
        case data
        case name
    }

    private enum Kind: String, Codable {
        case text
        case image
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(
                mediaType: try container.decode(String.self, forKey: .mediaType),
                data: try container.decode(String.self, forKey: .data),
                name: try container.decodeIfPresent(String.self, forKey: .name)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(mediaType, data, name):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(name, forKey: .name)
        }
    }
}

struct DshSessionPromptPayload: Encodable, Equatable, Sendable {
    let sessionID: String
    let mode: DshSessionPromptMode
    let content: [DshPromptContentPart]
    let clientTimeZone: String?

    init(
        sessionID: String,
        mode: DshSessionPromptMode,
        content: [DshPromptContentPart],
        clientTimeZone: String? = nil
    ) {
        self.sessionID = sessionID
        self.mode = mode
        self.content = content
        self.clientTimeZone = clientTimeZone
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case mode
        case content
        case clientTimeZone
    }
}

struct DshSessionPromptValue: Decodable, Equatable, Sendable {
    let accepted: Bool
    let command: DshSessionPromptCommand?
}

struct DshSessionPromptCommand: Decodable, Equatable, Sendable {
    let kind: String
    let text: String?
}

struct DshSessionHistoryPayload: Encodable, Equatable, Sendable {
    let sessionID: String
    let beforeSeq: Int?
    let maxMessages: Int?

    init(
        sessionID: String,
        beforeSeq: Int? = nil,
        maxMessages: Int? = nil
    ) {
        self.sessionID = sessionID
        self.beforeSeq = beforeSeq
        self.maxMessages = maxMessages
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case beforeSeq
        case maxMessages
    }
}

struct DshSessionHistoryValue: Decodable, Equatable, Sendable {
    let events: [DshSessionHistoryEntry]
    let hasMore: Bool
    let projections: DshSessionProjectionsBlock?
}

struct DshSessionHistoryEntry: Decodable, Equatable, Sendable {
    let event: DshSessionEvent
    let view: DshJSONValue?
}

struct DshSessionProjectionsBlock: Decodable, Equatable, Sendable {
    let asOfSeq: Int
    let values: [String: DshJSONValue]
}

struct DshSessionEvent: Decodable, Equatable, Sendable {
    let type: String
    let seq: Int
    let time: Int64
    let data: DshJSONValue
    let ignorable: Bool?
}

struct DshSessionCancelPayload: Encodable, Equatable, Sendable {
    let sessionID: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
    }
}

struct DshSessionCancelValue: Decodable, Equatable, Sendable {
    let accepted: Bool
}

enum DshJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DshJSONValue])
    case object([String: DshJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DshJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: DshJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var objectValue: [String: DshJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [DshJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case let .number(value) = self,
              value.rounded() == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    subscript(key: String) -> DshJSONValue? {
        objectValue?[key]
    }
}

struct DshSessionListValue: Decodable, Sendable {
    let items: [DshWireSession]
}

struct DshWireSession: Decodable, Sendable {
    let sessionID: String
    let updatedAtMilliseconds: Int64
    let running: Bool
    let blank: Bool
    let cwd: String?
    let parentSessionID: String?
    let origin: String?
    let agentPreset: String?
    let projectionTitle: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case updatedAtMilliseconds = "updatedAt"
        case running
        case blank
        case cwd
        case parentSessionID = "parentSessionId"
        case origin
        case agentPreset
        case projections
    }

    private struct Projections: Decodable {
        let title: String?

        private enum CodingKeys: String, CodingKey {
            case values
        }

        private struct Values: Decodable {
            let title: String?

            private enum CodingKeys: String, CodingKey {
                case title
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                title = try? container.decode(String.self, forKey: .title)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? container.decode(Values.self, forKey: .values))?.title
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        updatedAtMilliseconds = try container.decode(
            Int64.self,
            forKey: .updatedAtMilliseconds
        )
        running = try container.decode(Bool.self, forKey: .running)
        blank = try container.decode(Bool.self, forKey: .blank)
        cwd = try? container.decode(String.self, forKey: .cwd)
        parentSessionID = try? container.decode(String.self, forKey: .parentSessionID)
        origin = try? container.decode(String.self, forKey: .origin)
        agentPreset = try? container.decode(String.self, forKey: .agentPreset)
        projectionTitle = (try? container.decode(Projections.self, forKey: .projections))?.title
    }

    func chatSession(sourceScope: String) -> DshChatSession {
        let trimmedTitle = projectionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectedTitle = trimmedTitle.flatMap { $0.isEmpty ? nil : $0 }
        let title = projectedTitle ?? "DSH Session \(shortIdentifier)"
        return DshChatSession(
            sourceID: sessionID,
            sourceScope: sourceScope,
            title: title,
            titleSource: projectedTitle == nil ? "fallback" : "projection",
            hasMeaningfulTitle: projectedTitle != nil,
            updatedAt: updatedAtMilliseconds / 1_000,
            running: running,
            cwd: cwd,
            parentSessionID: parentSessionID,
            origin: origin,
            agentPreset: agentPreset
        )
    }

    private var shortIdentifier: String {
        sessionID.isEmpty ? "unknown" : String(sessionID.prefix(8))
    }
}

/// Hot-path discovery deliberately excludes profile/plugin metadata and private paths.
struct DshRunningEndpointCatalog: Decodable {
    let ok: Bool
    let includesSecrets: Bool
    let endpoints: [Endpoint]

    struct Endpoint: Decodable {
        let homeID: String
        let profile: String
        let port: Int
    }

    func validatedEndpoints() throws -> [DshRuntimeEndpoint] {
        guard ok, !includesSecrets else { throw DshHostApiError.invalidEndpoint }
        var result: [DshRuntimeEndpoint] = []
        for item in endpoints {
            guard !item.homeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65535).contains(item.port) else { throw DshHostApiError.invalidEndpoint }
            let endpoint = DshRuntimeEndpoint(homeID: item.homeID, profile: item.profile, port: item.port)
            if !result.contains(endpoint) { result.append(endpoint) }
        }
        return result
    }
}
