import CryptoKit
import Foundation

enum ManagedConversationInsightSchemaV1 {
    static let identifier = "harvis.managed-conversation-insight.v1"
    /// Store v2 adds per-target CAS generations and persisted cancel intent.
    /// It intentionally uses a new file instead of accepting unsafe v1 rows.
    static let storeVersion = 2
    static let maximumMainTasks = 3
    static let maximumConstraints = 3
    static let maximumOpenQuestions = 2
    static let maximumProjectCandidates = 100
    static let maximumPromptCharacters = 30_000
}

struct ManagedConversationInsightTarget: Codable, Equatable, Hashable, Sendable {
    let provider: String
    let sourceScope: String
    let sourceID: String

    init(provider: String, sourceScope: String, sourceID: String) {
        self.provider = provider
        self.sourceScope = sourceScope
        self.sourceID = sourceID
    }

    /// Stable across launches and safe to use as an in-memory dictionary key.
    /// The digest deliberately does not expose provider account or session ids.
    var storageKey: String {
        let material = "\(provider)\u{1f}\(sourceScope)\u{1f}\(sourceID)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct ManagedConversationProjectCandidate: Equatable, Sendable {
    let candidateID: String
    let label: String
    let taskTitles: [String]
    let conversationTitles: [String]

    init(
        candidateID: String,
        label: String,
        taskTitles: [String] = [],
        conversationTitles: [String] = []
    ) {
        self.candidateID = candidateID
        self.label = label
        self.taskTitles = taskTitles
        self.conversationTitles = conversationTitles
    }
}

/// Provider-neutral, ephemeral input for one explicit analysis request.
/// This type is intentionally not Codable: raw user messages must never enter
/// the durable conversation-insight store.
struct ManagedConversationInsightInput: Equatable, Sendable {
    let target: ManagedConversationInsightTarget
    let messages: [ManagedConversationUserInput]
    let inputFingerprint: String
    let totalUserMessageCount: Int
    let currentProjectCandidateID: String?
    let candidates: [ManagedConversationProjectCandidate]

    init(
        target: ManagedConversationInsightTarget,
        messages: [ManagedConversationUserInput],
        inputFingerprint: String,
        totalUserMessageCount: Int,
        currentProjectCandidateID: String?,
        candidates: [ManagedConversationProjectCandidate]
    ) {
        self.target = target
        self.messages = messages
        self.inputFingerprint = inputFingerprint
        self.totalUserMessageCount = totalUserMessageCount
        self.currentProjectCandidateID = currentProjectCandidateID
        self.candidates = candidates
    }
}

/// Raw-free request produced synchronously before any async security or DSH
/// operation. It is safe to retain across awaits: only opaque identities,
/// counts, and the irreversible local fact projection remain.
struct ManagedConversationPreparedInsightRequest: Equatable, Sendable {
    let target: ManagedConversationInsightTarget
    let inputFingerprint: String
    let totalInputCount: Int
    let analyzedInputCount: Int
    let omittedInputCount: Int
    let currentProjectCandidateID: String?
    let candidateIDs: [String]
    let factProjection: ManagedConversationInsightFactProjectionV1
}

struct ManagedConversationRequirementSummaryV1: Codable, Equatable, Sendable {
    let coreGoal: String
    let mainTasks: [String]
    let constraints: [String]
    let openQuestions: [String]
}

struct ManagedConversationProjectRelevanceV1: Codable, Equatable, Sendable {
    let currentScore: Int
    let reason: String
    let recommendedCandidateID: String?
    let recommendedScore: Int?
    let confidence: Double
}

/// Validated local result. Counts and timestamps are added by Harvis rather
/// than trusted to model output.
struct ManagedConversationInsightV1: Codable, Equatable, Sendable {
    let schema: String
    let requestID: String
    let inputFingerprint: String
    let currentProjectCandidateID: String?
    let summary: ManagedConversationRequirementSummaryV1
    let relevance: ManagedConversationProjectRelevanceV1
    let analyzedInputCount: Int
    let totalInputCount: Int
    let omittedInputCount: Int
    let generatedAt: Date

    var analyzedCurrentProjectCandidateID: String? {
        currentProjectCandidateID
    }
}

enum ManagedConversationInsightDeliveryState: String, Codable, Equatable, Sendable {
    case dispatching
    case running
    case cancelling
    case completed
    case failed
    case deliveryUnknown
    case cancelled

    var isInFlight: Bool {
        self == .dispatching || self == .running || self == .cancelling
    }
}

enum ManagedConversationInsightIntent: String, Codable, Equatable, Sendable {
    case analyze
    case cancel
}

struct ManagedConversationInsightCapabilityAttestation: Equatable, Sendable {
    let endpoint: DshRuntimeEndpoint
    let presetID: String
    let catalogRevision: String
    let toolIdentifiers: [String]
    let allowsCommandExecution: Bool
    let allowsFileMutation: Bool
    let allowsNetwork: Bool
    let allowsMCP: Bool

    var provesToolFreeNoSideEffects: Bool {
        !catalogRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && toolIdentifiers.isEmpty
            && !allowsCommandExecution
            && !allowsFileMutation
            && !allowsNetwork
            && !allowsMCP
    }
}

enum ManagedConversationInsightSecurityAvailability: Equatable, Sendable {
    case verified(ManagedConversationInsightCapabilityAttestation)
    case unavailable(String)

    var isAvailable: Bool {
        if case .verified = self { return true }
        return false
    }

    var unavailableReason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

struct ManagedConversationInsightFactSignalV1: Codable, Equatable, Sendable {
    let id: String
    let count: Int
}

struct ManagedConversationInsightProjectFactV1: Codable, Equatable, Sendable {
    let candidateID: String
    let localRelevanceScore: Int
    let lexicalOverlapPermille: Int
    let sharedSignals: [String]
    let taskFactCount: Int
    let conversationFactCount: Int
}

/// Privacy-preserving source projection sent to DSH. It contains only fixed
/// Harvis taxonomy ids, aggregate counts, opaque candidate ids, and locally
/// computed overlap values. No source string or reversible token is retained.
struct ManagedConversationInsightFactProjectionV1: Codable, Equatable, Sendable {
    let inputSignals: [ManagedConversationInsightFactSignalV1]
    let projectFacts: [ManagedConversationInsightProjectFactV1]
    let analyzedInputCount: Int
    let totalInputCount: Int
    let omittedInputCount: Int
    let truncatedInputCount: Int
    /// `.unknown` is eligible user-role evidence but is never represented as
    /// a verified natural-person message.
    let unverifiedSourceInputCount: Int
}

struct ManagedConversationInsightStatus: Equatable, Sendable {
    let target: ManagedConversationInsightTarget
    let state: ManagedConversationInsightDeliveryState
    let inputFingerprint: String
    let totalInputCount: Int
    let analyzedInputCount: Int
    let omittedInputCount: Int
    let sessionID: String
    let rpcID: String
    let latestInsight: ManagedConversationInsightV1?
    let summaryIsStale: Bool
    let relevanceIsStale: Bool
    let updatedAt: Date
    let lastError: String?

    var isStale: Bool {
        summaryIsStale || relevanceIsStale
    }

    /// A recommendation is safe to apply only when the durable result matches
    /// both the currently displayed evidence and the current project binding.
    var isApplicable: Bool {
        state == .completed
            && latestInsight != nil
            && !summaryIsStale
            && !relevanceIsStale
    }
}

enum ManagedConversationInsightValidationError: LocalizedError, Equatable {
    case invalidTarget(String)
    case invalidFingerprint
    case invalidCount
    case duplicateMessage(String)
    case invalidCandidate(String)
    case duplicateCandidate(String)
    case currentProjectNotInCandidates(String)
    case malformedJSON
    case unknownKeys(path: String, keys: [String])
    case missingKeys(path: String, keys: [String])
    case schemaMismatch(String)
    case requestMismatch(field: String)
    case invalidSummary(String)
    case invalidRelevance(String)
    case recommendationNotInCandidates(String)
    case promptTooLarge

    var errorDescription: String? {
        switch self {
        case let .invalidTarget(reason):
            return "Invalid managed-conversation target: \(reason)"
        case .invalidFingerprint:
            return "The conversation input fingerprint is invalid."
        case .invalidCount:
            return "The conversation input counts are invalid."
        case let .duplicateMessage(id):
            return "Duplicate user input id: \(id)"
        case let .invalidCandidate(id):
            return "Invalid project candidate: \(id)"
        case let .duplicateCandidate(id):
            return "Duplicate project candidate: \(id)"
        case let .currentProjectNotInCandidates(id):
            return "Current project candidate is not in the candidate set: \(id)"
        case .malformedJSON:
            return "The DSH conversation insight was not one JSON object."
        case let .unknownKeys(path, keys):
            return "Unknown JSON keys at \(path): \(keys.sorted().joined(separator: ", "))"
        case let .missingKeys(path, keys):
            return "Missing JSON keys at \(path): \(keys.sorted().joined(separator: ", "))"
        case let .schemaMismatch(actual):
            return "Unsupported conversation insight schema: \(actual)"
        case let .requestMismatch(field):
            return "The DSH conversation insight did not match \(field)."
        case let .invalidSummary(reason):
            return "Invalid conversation requirement summary: \(reason)"
        case let .invalidRelevance(reason):
            return "Invalid project relevance result: \(reason)"
        case let .recommendationNotInCandidates(id):
            return "Recommended project is outside the candidate set: \(id)"
        case .promptTooLarge:
            return "The redacted conversation analysis prompt exceeded its character budget."
        }
    }
}

enum ManagedConversationInsightValidatorV1 {
    static func validate(input: ManagedConversationInsightInput) throws {
        try validate(target: input.target)
        try requireOpaque(input.inputFingerprint, maximum: 256)
        guard input.totalUserMessageCount >= 0 else {
            throw ManagedConversationInsightValidationError.invalidCount
        }
        let eligibleInputs = input.messages.filter {
            $0.source == .human || $0.source == .unknown
        }
        guard eligibleInputs.count <= input.totalUserMessageCount else {
            throw ManagedConversationInsightValidationError.invalidCount
        }
        var messageIDs: Set<String> = []
        for message in eligibleInputs {
            guard !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  messageIDs.insert(message.id).inserted else {
                throw ManagedConversationInsightValidationError.duplicateMessage(
                    message.id
                )
            }
        }
        guard input.candidates.count
            <= ManagedConversationInsightSchemaV1.maximumProjectCandidates else {
            throw ManagedConversationInsightValidationError.invalidCandidate(
                "too-many"
            )
        }
        var candidateIDs: Set<String> = []
        for candidate in input.candidates {
            try requireOpaque(candidate.candidateID, maximum: 256)
            guard candidate.label.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false else {
                throw ManagedConversationInsightValidationError.invalidCandidate(
                    candidate.candidateID
                )
            }
            guard candidateIDs.insert(candidate.candidateID).inserted else {
                throw ManagedConversationInsightValidationError.duplicateCandidate(
                    candidate.candidateID
                )
            }
        }
        if let current = input.currentProjectCandidateID,
           !candidateIDs.contains(current) {
            throw ManagedConversationInsightValidationError
                .currentProjectNotInCandidates(current)
        }
    }

    static func validate(target: ManagedConversationInsightTarget) throws {
        for (name, value) in [
            ("provider", target.provider),
            ("sourceScope", target.sourceScope),
            ("sourceID", target.sourceID),
        ] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 512,
                  !trimmed.contains("\n"), !trimmed.contains("\r"),
                  ManagedConversationInsightRedactor.redact(trimmed)
                    == trimmed else {
                throw ManagedConversationInsightValidationError.invalidTarget(name)
            }
        }
    }

    static func validate(
        insight: ManagedConversationInsightV1,
        candidateIDs: Set<String>? = nil
    ) throws {
        guard insight.schema == ManagedConversationInsightSchemaV1.identifier else {
            throw ManagedConversationInsightValidationError.schemaMismatch(
                insight.schema
            )
        }
        try requireOpaque(insight.requestID, maximum: 256)
        try requireOpaque(insight.inputFingerprint, maximum: 256)
        try validate(summary: insight.summary)
        try validate(relevance: insight.relevance)
        guard insight.totalInputCount >= 0,
              insight.analyzedInputCount >= 0,
              insight.analyzedInputCount <= insight.totalInputCount,
              insight.omittedInputCount
                == insight.totalInputCount - insight.analyzedInputCount else {
            throw ManagedConversationInsightValidationError.invalidCount
        }
        if let current = insight.currentProjectCandidateID {
            try requireOpaque(current, maximum: 256)
            if let candidateIDs, !candidateIDs.contains(current) {
                throw ManagedConversationInsightValidationError
                    .currentProjectNotInCandidates(current)
            }
        }
        if let recommendation = insight.relevance.recommendedCandidateID,
           let candidateIDs, !candidateIDs.contains(recommendation) {
            throw ManagedConversationInsightValidationError
                .recommendationNotInCandidates(recommendation)
        }
        if insight.relevance.recommendedCandidateID
            == insight.currentProjectCandidateID,
           insight.relevance.recommendedCandidateID != nil {
            throw ManagedConversationInsightValidationError.invalidRelevance(
                "the recommendation must be a different project"
            )
        }
    }

    static func validate(
        summary: ManagedConversationRequirementSummaryV1
    ) throws {
        try requireText(summary.coreGoal, field: "coreGoal", maximum: 1_200)
        guard summary.mainTasks.count
            <= ManagedConversationInsightSchemaV1.maximumMainTasks,
              summary.constraints.count
                <= ManagedConversationInsightSchemaV1.maximumConstraints,
              summary.openQuestions.count
                <= ManagedConversationInsightSchemaV1.maximumOpenQuestions else {
            throw ManagedConversationInsightValidationError.invalidSummary(
                "one or more lists exceeded their item limit"
            )
        }
        for item in summary.mainTasks {
            try requireText(item, field: "mainTasks", maximum: 800)
        }
        for item in summary.constraints {
            try requireText(item, field: "constraints", maximum: 800)
        }
        for item in summary.openQuestions {
            try requireText(item, field: "openQuestions", maximum: 800)
        }
    }

    static func validate(
        relevance: ManagedConversationProjectRelevanceV1
    ) throws {
        guard (0...100).contains(relevance.currentScore),
              (0...1).contains(relevance.confidence),
              relevance.confidence.isFinite else {
            throw ManagedConversationInsightValidationError.invalidRelevance(
                "score or confidence is outside its allowed range"
            )
        }
        try requireText(relevance.reason, field: "reason", maximum: 1_200)
        let hasID = relevance.recommendedCandidateID != nil
        let hasScore = relevance.recommendedScore != nil
        guard hasID == hasScore else {
            throw ManagedConversationInsightValidationError.invalidRelevance(
                "recommendedCandidateID and recommendedScore must appear together"
            )
        }
        if let score = relevance.recommendedScore,
           !(0...100).contains(score) {
            throw ManagedConversationInsightValidationError.invalidRelevance(
                "recommendedScore is outside 0...100"
            )
        }
        if let id = relevance.recommendedCandidateID {
            try requireOpaque(id, maximum: 256)
        }
    }

    private static func requireOpaque(
        _ value: String,
        maximum: Int
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum,
              !trimmed.contains("\n"), !trimmed.contains("\r"),
              ManagedConversationInsightRedactor.redact(trimmed)
                == trimmed else {
            throw ManagedConversationInsightValidationError.invalidFingerprint
        }
    }

    private static func requireText(
        _ value: String,
        field: String,
        maximum: Int
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum else {
            throw ManagedConversationInsightValidationError.invalidSummary(
                "\(field) is blank or too long"
            )
        }
    }
}

enum ManagedConversationInsightFactProjectorV1 {
    private struct SignalDefinition {
        let id: String
        let needles: [String]
    }

    /// A deliberately small, versioned taxonomy. Only these fixed ids leave
    /// the process; matched source substrings never do.
    private static let taxonomy: [SignalDefinition] = [
        SignalDefinition(
            id: "conversation_management",
            needles: ["conversation", "chat", "对话", "会话", "聊天"]
        ),
        SignalDefinition(
            id: "project_classification",
            needles: ["project", "项目", "归属", "移动到", "分类"]
        ),
        SignalDefinition(
            id: "requirements_summary",
            needles: ["summary", "summarize", "requirement", "摘要", "总结", "要求"]
        ),
        SignalDefinition(
            id: "relevance_scoring",
            needles: ["relevance", "score", "相关", "分数", "匹配"]
        ),
        SignalDefinition(
            id: "task_planning",
            needles: ["task plan", "checklist", "任务计划", "任务清单", "待办"]
        ),
        SignalDefinition(
            id: "progress_tracking",
            needles: ["progress", "status", "进度", "状态", "完成"]
        ),
        SignalDefinition(
            id: "handoff",
            needles: ["handoff", "交接", "移交"]
        ),
        SignalDefinition(
            id: "ui_layout",
            needles: ["ui", "layout", "panel", "sidebar", "界面", "布局", "面板", "边栏", "输入框"]
        ),
        SignalDefinition(
            id: "automation",
            needles: ["automatic", "automation", "自动", "连续", "continue"]
        ),
        SignalDefinition(
            id: "privacy_security",
            needles: ["privacy", "security", "credential", "secret", "隐私", "安全", "凭据", "密钥"]
        ),
        SignalDefinition(
            id: "manual_confirmation",
            needles: ["manual", "confirm", "approve", "手动", "确认", "批准", "授权"]
        ),
        SignalDefinition(
            id: "non_destructive",
            needles: ["do not delete", "no delete", "non-destructive", "不要删除", "非删除", "不覆盖", "不移动"]
        ),
        SignalDefinition(
            id: "codex_provider",
            needles: ["codex"]
        ),
        SignalDefinition(
            id: "dsh_provider",
            needles: ["dsh", "deepseek"]
        ),
        SignalDefinition(
            id: "multimodal",
            needles: ["image", "screenshot", "visual", "图片", "截图", "视觉", "多模态"]
        ),
        SignalDefinition(
            id: "testing_verification",
            needles: ["test", "verify", "acceptance", "测试", "验证", "验收", "闭环"]
        ),
        SignalDefinition(
            id: "implementation_change",
            needles: ["implement", "build", "upgrade", "fix", "实现", "开发", "升级", "修复"]
        ),
        SignalDefinition(
            id: "documentation",
            needles: ["document", "readme", "docs", "文档", "说明"]
        ),
    ]

    private static var allowedSignalIDs: Set<String> {
        Set(taxonomy.map(\.id)).union(["general_request"])
    }

    static func project(
        input: ManagedConversationInsightInput,
        eligibleInputs: [ManagedConversationUserInput]
    ) -> ManagedConversationInsightFactProjectionV1 {
        let inputTexts = eligibleInputs.map(\.text)
        let inputSignalCounts = signalCounts(in: inputTexts)
        let inputSignalIDs = Set(inputSignalCounts.keys)
        let inputLexicalFacts = lexicalFacts(in: inputTexts)

        let inputSignals: [ManagedConversationInsightFactSignalV1]
        if inputSignalCounts.isEmpty {
            inputSignals = [
                ManagedConversationInsightFactSignalV1(
                    id: "general_request",
                    count: max(1, eligibleInputs.count)
                ),
            ]
        } else {
            inputSignals = inputSignalCounts.keys.sorted().map {
                ManagedConversationInsightFactSignalV1(
                    id: $0,
                    count: inputSignalCounts[$0] ?? 0
                )
            }
        }

        let projectFacts = input.candidates.map { candidate in
            let candidateTexts = [candidate.label]
                + candidate.taskTitles
                + candidate.conversationTitles
            let candidateSignals = Set(signalCounts(in: candidateTexts).keys)
            let sharedSignals = inputSignalIDs.intersection(candidateSignals)
                .sorted()
            let candidateLexicalFacts = lexicalFacts(in: candidateTexts)
            let lexicalIntersection = inputLexicalFacts.intersection(
                candidateLexicalFacts
            ).count
            let lexicalPermille = inputLexicalFacts.isEmpty
                ? 0
                : min(
                    1_000,
                    lexicalIntersection * 1_000 / inputLexicalFacts.count
                )
            let signalBase = inputSignalIDs.isEmpty
                ? 0
                : sharedSignals.count * 70 / inputSignalIDs.count
            let score = min(100, signalBase + lexicalPermille * 30 / 1_000)
            return ManagedConversationInsightProjectFactV1(
                candidateID: candidate.candidateID,
                localRelevanceScore: score,
                lexicalOverlapPermille: lexicalPermille,
                sharedSignals: sharedSignals,
                taskFactCount: candidate.taskTitles.count,
                conversationFactCount: candidate.conversationTitles.count
            )
        }

        return ManagedConversationInsightFactProjectionV1(
            inputSignals: inputSignals,
            projectFacts: projectFacts,
            analyzedInputCount: eligibleInputs.count,
            totalInputCount: input.totalUserMessageCount,
            omittedInputCount:
                input.totalUserMessageCount - eligibleInputs.count,
            truncatedInputCount: eligibleInputs.filter(\.truncated).count,
            unverifiedSourceInputCount: eligibleInputs.filter {
                $0.source == .unknown
            }.count
        )
    }

    /// Defense-in-depth for the async boundary. Even another module-internal
    /// caller cannot forge a prepared request that carries arbitrary strings
    /// in place of fixed taxonomy facts.
    static func validate(
        _ projection: ManagedConversationInsightFactProjectionV1,
        candidateIDs: Set<String>
    ) throws {
        guard projection.totalInputCount >= 0,
              projection.analyzedInputCount > 0,
              projection.analyzedInputCount <= projection.totalInputCount,
              projection.omittedInputCount
                == projection.totalInputCount - projection.analyzedInputCount,
              (0...projection.analyzedInputCount).contains(
                projection.truncatedInputCount
              ),
              (0...projection.analyzedInputCount).contains(
                projection.unverifiedSourceInputCount
              ) else {
            throw ManagedConversationInsightValidationError.invalidCount
        }
        var signalIDs: Set<String> = []
        for signal in projection.inputSignals {
            guard allowedSignalIDs.contains(signal.id),
                  (1...projection.analyzedInputCount).contains(signal.count),
                  signalIDs.insert(signal.id).inserted else {
                throw ManagedConversationInsightValidationError.invalidSummary(
                    "prepared fact projection contains a non-taxonomy signal"
                )
            }
        }
        guard !signalIDs.isEmpty else {
            throw ManagedConversationInsightValidationError.invalidSummary(
                "prepared fact projection has no signals"
            )
        }
        var projectedCandidates: Set<String> = []
        for fact in projection.projectFacts {
            guard candidateIDs.contains(fact.candidateID),
                  projectedCandidates.insert(fact.candidateID).inserted,
                  (0...100).contains(fact.localRelevanceScore),
                  (0...1_000).contains(fact.lexicalOverlapPermille),
                  fact.taskFactCount >= 0,
                  fact.conversationFactCount >= 0,
                  Set(fact.sharedSignals).count == fact.sharedSignals.count,
                  fact.sharedSignals.allSatisfy(allowedSignalIDs.contains) else {
                throw ManagedConversationInsightValidationError.invalidCandidate(
                    "prepared-project-fact"
                )
            }
        }
        guard projectedCandidates == candidateIDs else {
            throw ManagedConversationInsightValidationError.invalidCandidate(
                "prepared-candidate-set"
            )
        }
    }

    private static func signalCounts(in texts: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for text in texts {
            let normalized = text.lowercased()
            for definition in taxonomy where definition.needles.contains(where: {
                normalized.contains($0)
            }) {
                counts[definition.id, default: 0] += 1
            }
        }
        return counts
    }

    /// Local-only lexical facts. They are used to calculate an aggregate
    /// overlap integer and are discarded before the DSH request is built.
    private static func lexicalFacts(in texts: [String]) -> Set<String> {
        var facts: Set<String> = []
        for text in texts {
            var latin = ""
            var hanRun: [UnicodeScalar] = []

            func flushLatin() {
                if latin.count >= 3, !latinStopWords.contains(latin) {
                    facts.insert(latin)
                }
                latin.removeAll(keepingCapacity: true)
            }

            func flushHan() {
                guard hanRun.count >= 2 else {
                    hanRun.removeAll(keepingCapacity: true)
                    return
                }
                for index in 0..<(hanRun.count - 1) {
                    facts.insert(String(String.UnicodeScalarView([
                        hanRun[index], hanRun[index + 1],
                    ])))
                }
                hanRun.removeAll(keepingCapacity: true)
            }

            for scalar in text.lowercased().unicodeScalars {
                if isHan(scalar) {
                    flushLatin()
                    hanRun.append(scalar)
                } else if scalar.isASCII,
                          CharacterSet.alphanumerics.contains(scalar) {
                    flushHan()
                    latin.unicodeScalars.append(scalar)
                } else {
                    flushLatin()
                    flushHan()
                }
            }
            flushLatin()
            flushHan()
        }
        if facts.count <= 5_000 { return facts }
        return Set(facts.sorted().prefix(5_000))
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static let latinStopWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "into",
        "have", "has", "need", "want", "please", "can", "could",
    ]
}

/// Strict wire decoder. `Decodable` alone ignores unknown keys, which would
/// accidentally turn model-suggested actions into a permissive extension.
enum ManagedConversationInsightWireDecoderV1 {
    static func decode(
        _ data: Data,
        requestID: String,
        inputFingerprint: String,
        currentProjectCandidateID: String?,
        candidateIDs: Set<String>,
        analyzedInputCount: Int,
        totalInputCount: Int,
        generatedAt: Date
    ) throws -> ManagedConversationInsightV1 {
        let root: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw ManagedConversationInsightValidationError.malformedJSON
            }
            root = value
        } catch let error as ManagedConversationInsightValidationError {
            throw error
        } catch {
            throw ManagedConversationInsightValidationError.malformedJSON
        }
        try requireExactKeys(
            root,
            expected: [
                "schema", "requestID", "inputFingerprint",
                "currentProjectCandidateID", "summary", "relevance",
            ],
            path: "$"
        )
        guard let summaryObject = root["summary"] as? [String: Any],
              let relevanceObject = root["relevance"] as? [String: Any] else {
            throw ManagedConversationInsightValidationError.malformedJSON
        }
        try requireExactKeys(
            summaryObject,
            expected: ["coreGoal", "mainTasks", "constraints", "openQuestions"],
            path: "$.summary"
        )
        try requireExactKeys(
            relevanceObject,
            expected: [
                "currentScore", "reason", "recommendedCandidateID",
                "recommendedScore", "confidence",
            ],
            path: "$.relevance"
        )

        let wire: WireResponse
        do {
            wire = try JSONDecoder().decode(WireResponse.self, from: data)
        } catch {
            throw ManagedConversationInsightValidationError.malformedJSON
        }
        guard wire.schema == ManagedConversationInsightSchemaV1.identifier else {
            throw ManagedConversationInsightValidationError.schemaMismatch(
                wire.schema
            )
        }
        guard wire.requestID == requestID else {
            throw ManagedConversationInsightValidationError.requestMismatch(
                field: "requestID"
            )
        }
        guard wire.inputFingerprint == inputFingerprint else {
            throw ManagedConversationInsightValidationError.requestMismatch(
                field: "inputFingerprint"
            )
        }
        guard wire.currentProjectCandidateID == currentProjectCandidateID else {
            throw ManagedConversationInsightValidationError.requestMismatch(
                field: "currentProjectCandidateID"
            )
        }

        let scrubbedSummary = ManagedConversationRequirementSummaryV1(
            coreGoal: ManagedConversationInsightRedactor.redact(
                wire.summary.coreGoal
            ),
            mainTasks: wire.summary.mainTasks.map(
                ManagedConversationInsightRedactor.redact
            ),
            constraints: wire.summary.constraints.map(
                ManagedConversationInsightRedactor.redact
            ),
            openQuestions: wire.summary.openQuestions.map(
                ManagedConversationInsightRedactor.redact
            )
        )
        let scrubbedRelevance = ManagedConversationProjectRelevanceV1(
            currentScore: wire.relevance.currentScore,
            reason: ManagedConversationInsightRedactor.redact(
                wire.relevance.reason
            ),
            recommendedCandidateID: wire.relevance.recommendedCandidateID,
            recommendedScore: wire.relevance.recommendedScore,
            confidence: wire.relevance.confidence
        )
        let insight = ManagedConversationInsightV1(
            schema: wire.schema,
            requestID: wire.requestID,
            inputFingerprint: wire.inputFingerprint,
            currentProjectCandidateID: wire.currentProjectCandidateID,
            summary: scrubbedSummary,
            relevance: scrubbedRelevance,
            analyzedInputCount: analyzedInputCount,
            totalInputCount: totalInputCount,
            omittedInputCount: totalInputCount - analyzedInputCount,
            generatedAt: generatedAt
        )
        try ManagedConversationInsightValidatorV1.validate(
            insight: insight,
            candidateIDs: candidateIDs
        )
        return insight
    }

    private struct WireResponse: Decodable {
        let schema: String
        let requestID: String
        let inputFingerprint: String
        let currentProjectCandidateID: String?
        let summary: ManagedConversationRequirementSummaryV1
        let relevance: ManagedConversationProjectRelevanceV1
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        expected: Set<String>,
        path: String
    ) throws {
        let actual = Set(object.keys)
        let unknown = actual.subtracting(expected)
        if !unknown.isEmpty {
            throw ManagedConversationInsightValidationError.unknownKeys(
                path: path,
                keys: Array(unknown)
            )
        }
        let missing = expected.subtracting(actual)
        if !missing.isEmpty {
            throw ManagedConversationInsightValidationError.missingKeys(
                path: path,
                keys: Array(missing)
            )
        }
    }
}

/// Small deterministic local scrubber used before evidence enters a prompt and
/// again before derived text is persisted. It is deliberately conservative.
enum ManagedConversationInsightRedactor {
    static func redact(_ value: String) -> String {
        var result = value
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: rule.replacement
            )
        }
        return String(result.prefix(12_000))
    }

    private struct Rule {
        let expression: NSRegularExpression
        let replacement: String

        init(_ pattern: String, _ replacement: String, options: NSRegularExpression.Options = []) {
            expression = try! NSRegularExpression(
                pattern: pattern,
                options: options
            )
            self.replacement = replacement
        }
    }

    private static let rules: [Rule] = [
        Rule(
            #"-----BEGIN [^-\r\n]*PRIVATE KEY-----[\s\S]*?-----END [^-\r\n]*PRIVATE KEY-----"#,
            "[REDACTED_PRIVATE_KEY]",
            options: [.caseInsensitive]
        ),
        Rule(
            #"\bAuthorization\s*[:=]\s*[^\r\n,;]+"#,
            "Authorization: [REDACTED]",
            options: [.caseInsensitive]
        ),
        Rule(
            #"\b(?:Set-Cookie|Cookie)\s*[:=]\s*[^\r\n]+"#,
            "Cookie: [REDACTED]",
            options: [.caseInsensitive]
        ),
        Rule(
            #"\b(?:Bearer|token|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)\s*[:=]\s*[\"']?[^\s\"',;]+"#,
            "[REDACTED_SECRET]",
            options: [.caseInsensitive]
        ),
        Rule(
            #"(?m)^\s*[A-Z][A-Z0-9_]{1,}\s*=\s*[^\r\n]+$"#,
            "[REDACTED_ENV]"
        ),
        Rule(
            #"\bdata:[^\s;,]+;base64,[A-Za-z0-9+/=]+"#,
            "[REDACTED_BASE64]",
            options: [.caseInsensitive]
        ),
        Rule(
            #"(?<![A-Za-z0-9])[A-Za-z0-9+/]{80,}={0,2}(?![A-Za-z0-9])"#,
            "[REDACTED_BASE64]"
        ),
        Rule(
            #"\b(?:https?|ftp)://[^\s<>\"']+"#,
            "[REDACTED_URL]",
            options: [.caseInsensitive]
        ),
        Rule(
            #"(?<![A-Za-z0-9])(?:/(?:Users|Volumes|private|var|tmp|opt|etc|home)/[^\s<>\"']+|~/[^\s<>\"']+|[A-Za-z]:\\[^\r\n<>\"']+)"#,
            "[REDACTED_LOCAL_PATH]"
        ),
        Rule(
            #"(?<![A-Za-z0-9])/(?!/)[^\s<>\"']+"#,
            "[REDACTED_LOCAL_PATH]"
        ),
        Rule(
            #"(?m)^\s*[a-z_][A-Za-z0-9_]*=[^\r\n]+$"#,
            "[REDACTED_ENV]"
        ),
    ]
}
