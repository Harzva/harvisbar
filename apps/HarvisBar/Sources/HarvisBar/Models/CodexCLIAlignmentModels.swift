import Foundation

struct CodexCLIEndpointStatus: Codable, Equatable, Sendable {
    let label: String
    let host: String?
    let path: String?
    let version: String?
    let available: Bool
    let error: String?
}

struct CodexCLIAlignmentStatus: Codable, Equatable, Sendable {
    let schema: String
    let sampledAt: String?
    let local: CodexCLIEndpointStatus
    let remote: CodexCLIEndpointStatus
    let appBundled: CodexCLIEndpointStatus
    let aligned: Bool
    let actionMessage: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case sampledAt = "sampled_at"
        case local
        case remote
        case appBundled = "app_bundled"
        case aligned
        case actionMessage = "action_message"
    }

    var terminalVersionsAvailable: Bool {
        local.available && remote.available
    }

    var canAlignTerminals: Bool {
        remote.available
    }

    var stateLabel: String {
        if aligned { return "已对齐" }
        if terminalVersionsAvailable { return "版本不一致" }
        return "待检查"
    }
}
