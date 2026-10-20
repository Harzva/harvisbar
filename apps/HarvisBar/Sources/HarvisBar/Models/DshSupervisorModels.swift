import Foundation

/// Provider-owned state for one Supervisor session.
///
/// The bridge returns empty strings for optional textual fields. The source
/// runtime remains authoritative for the session; this value is only a
/// validated projection used by Harvis.
struct DshSupervisorState: Decodable, Equatable, Sendable {
    static let supportedSchemaVersion = "harvis.dsh-supervisor.v1"

    let schemaVersion: String
    let sessionID: String
    let revision: String
    let mode: String
    let strategy: String
    let rounds: Int
    let used: Int
    let intervalMs: Int
    let status: String
    let suggestion: String
    let suggestionID: String
    let runID: String
    let recoveryRequired: String
    let done: Bool
    let remaining: Int
    let agentStatus: String
    let mentorName: String
    let suggestError: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, mode, strategy, rounds, used, intervalMs
        case status, suggestion, recoveryRequired, done, remaining, agentStatus
        case mentorName, suggestError
        case sessionID = "sessionId"
        case suggestionID = "suggestionId"
        case runID = "runId"
    }

    /// Validates both the wire contract and that the projection belongs to the
    /// exact card/session that requested it.
    func validate(expectedSessionID: String) throws {
        guard !expectedSessionID.isEmpty,
              expectedSessionID.utf8.count <= 256,
              sessionID == expectedSessionID else {
            throw DshCapabilityBridgeError.authorityMismatch
        }
        guard schemaVersion == Self.supportedSchemaVersion,
              DshUserInputPage.isRevision(revision),
              ["off", "advice", "takeover"].contains(mode),
              ["plan", "insight", "fixed"].contains(strategy),
              (1...10_000).contains(rounds),
              (0...10_000).contains(used),
              (2_000...3_600_000).contains(intervalMs),
              (0...10_000).contains(remaining),
              ["off", "working", "thinking", "suggested", "silent", "recovery"].contains(status),
              Self.isText(schemaVersion),
              Self.isText(sessionID),
              Self.isText(mode),
              Self.isText(strategy),
              Self.isText(status),
              Self.isText(suggestion),
              Self.isText(suggestionID),
              Self.isText(runID),
              Self.isText(agentStatus),
              Self.isText(mentorName),
              Self.isText(suggestError) else {
            throw DshCapabilityBridgeError.invalidResponse
        }
    }

    private static func isText(_ value: String) -> Bool {
        value.unicodeScalars.count <= 12_000
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value == 9 || scalar.value == 10 || scalar.value == 13
                    || !CharacterSet.controlCharacters.contains(scalar)
            }
    }
}

/// Optional settings sent with a Supervisor mutation. Omitted fields retain
/// their provider-owned values.
struct DshSupervisorPatch: Encodable, Equatable, Sendable {
    let mode: String?
    let strategy: String?
    let rounds: Int?
    let intervalMs: Int?

    init(
        mode: String? = nil,
        strategy: String? = nil,
        rounds: Int? = nil,
        intervalMs: Int? = nil
    ) {
        self.mode = mode
        self.strategy = strategy
        self.rounds = rounds
        self.intervalMs = intervalMs
    }

    func validate() throws {
        guard mode != nil || strategy != nil || rounds != nil || intervalMs != nil,
              mode.map({ ["off", "advice", "takeover"].contains($0) }) != false,
              strategy.map({ ["plan", "insight", "fixed"].contains($0) }) != false,
              rounds.map({ (1...10_000).contains($0) }) != false,
              intervalMs.map({ (2_000...3_600_000).contains($0) }) != false,
              mode.map(Self.isText) != false,
              strategy.map(Self.isText) != false else {
            throw DshCapabilityBridgeError.invalidResponse
        }
    }

    private static func isText(_ value: String) -> Bool {
        value.unicodeScalars.count <= 12_000
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value == 9 || scalar.value == 10 || scalar.value == 13
                    || !CharacterSet.controlCharacters.contains(scalar)
            }
    }
}

enum DshSupervisorOperation: String, CaseIterable, Equatable, Sendable {
    case set
    case regenerate
    case adopt
    case recover
}
