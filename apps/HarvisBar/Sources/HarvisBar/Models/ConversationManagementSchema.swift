import Foundation

enum ConversationManagementSchemaV1 {
    static let version = 1
    static let maxDecisionsPerProposal = 5
    static let maxPromptCharacters = 8_000
}

/// Provider-neutral, exact address for one managed conversation.
///
/// Provider-specific eligibility is deliberately not encoded here. The caller
/// supplies an allowlist after resolving its current provider/card contracts.
struct ConversationManagementTargetV1: Codable, Equatable, Hashable, Sendable {
    let provider: String
    let sourceScope: String
    let sourceID: String

    var stableID: String {
        "\(provider)::\(sourceScope)::\(sourceID)"
    }
}

enum ConversationManagementEnrollmentV1: String, Codable, CaseIterable, Sendable {
    /// Follow the project-level enrollment default.
    case inherit
    /// Explicitly include this conversation in management.
    case enabled
    /// Explicitly exclude this conversation even when the project is enabled.
    case excluded

    func resolves(projectDefaultEnabled: Bool) -> Bool {
        switch self {
        case .inherit: return projectDefaultEnabled
        case .enabled: return true
        case .excluded: return false
        }
    }
}

enum ConversationDeliveryStateV1: String, Codable, CaseIterable, Sendable {
    case none
    case queued
    case dispatching
    case accepted
    case running
    case waitingApproval
    case completed
    case failed
    case deliveryUnknown
    case cancelled

    var isRestartAmbiguous: Bool {
        switch self {
        case .dispatching, .accepted, .running, .waitingApproval:
            return true
        case .none, .queued, .completed, .failed,
             .deliveryUnknown, .cancelled:
            return false
        }
    }
}

enum ConversationRuntimeStateV1: String, Codable, CaseIterable, Sendable {
    case unknown
    case disconnected
    case idle
    case running
    case waitingApproval
    case waitingUserInput
    case completed
    case failed
}

enum ConversationManagementStateV1: String, Codable, CaseIterable, Sendable {
    case unmanaged
    case observing
    case planning
    case awaitingPreview
    case dispatching
    case monitoring
    case waitingApproval
    case waitingUserInput
    case paused
    case completed
    case failed
    case deliveryUnknown
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .deliveryUnknown, .cancelled:
            return true
        default:
            return false
        }
    }

    var isRestartAmbiguous: Bool {
        switch self {
        case .planning, .dispatching, .monitoring,
             .waitingApproval, .waitingUserInput:
            return true
        case .unmanaged, .observing, .awaitingPreview, .paused,
             .completed, .failed, .deliveryUnknown, .cancelled:
            return false
        }
    }
}

enum ConversationProgressPhaseV1: String, Codable, CaseIterable, Sendable {
    case unknown
    case notStarted
    case active
    case waiting
    case blocked
    case completed
    case failed
}

struct ConversationProgressProjectionV1: Codable, Equatable, Sendable {
    let phase: ConversationProgressPhaseV1
    let completedUnitCount: Int?
    let totalUnitCount: Int?
    let summary: String?
    let updatedAt: Date?

    static let unknown = ConversationProgressProjectionV1(
        phase: .unknown,
        completedUnitCount: nil,
        totalUnitCount: nil,
        summary: nil,
        updatedAt: nil
    )
}

enum ConversationEvidenceStatusV1: String, Codable, CaseIterable, Sendable {
    case none
    case stale
    case partial
    case fresh
    case verified
    case conflicting
}

/// Small, structured evidence projection. It intentionally excludes raw chat
/// history and credentials.
struct ConversationEvidenceProjectionV1: Codable, Equatable, Sendable {
    let revision: Int
    let status: ConversationEvidenceStatusV1
    let fingerprint: String?
    let summary: String?
    let observedAt: Date?

    static let none = ConversationEvidenceProjectionV1(
        revision: 0,
        status: .none,
        fingerprint: nil,
        summary: nil,
        observedAt: nil
    )
}

enum ConversationProjectTaskFreshnessV1: String, Codable, CaseIterable, Sendable {
    case unavailable
    case stale
    case fresh
}

enum ConversationProjectTaskStatusV1: String, Codable, CaseIterable, Sendable {
    case pending
    case inProgress = "in_progress"
    case waitingApproval = "waiting_approval"
    case blocked
    case reviewing
    case done
    case cancelled
    case archived
    case closed

    var isOpen: Bool {
        switch self {
        case .pending, .inProgress, .waitingApproval, .blocked, .reviewing:
            return true
        case .done, .cancelled, .archived, .closed:
            return false
        }
    }
}

/// One task from the project-owned task plan. The fields intentionally mirror
/// the safe `harvis agent-room task-plan` projection; no chat text or local
/// source paths are admitted here.
struct ConversationProjectTaskEvidenceReferenceV1: Codable, Equatable, Sendable {
    let kind: String
    let id: String
}

struct ConversationProjectTaskV1: Codable, Equatable, Sendable {
    let taskID: String
    let title: String
    let description: String?
    let owner: String
    let status: ConversationProjectTaskStatusV1
    let updatedAt: Date?
    let evidence: [ConversationProjectTaskEvidenceReferenceV1]

    init(
        taskID: String,
        title: String,
        description: String? = nil,
        owner: String,
        status: ConversationProjectTaskStatusV1,
        updatedAt: Date? = nil,
        evidence: [ConversationProjectTaskEvidenceReferenceV1] = []
    ) {
        self.taskID = taskID
        self.title = title
        self.description = description
        self.owner = owner
        self.status = status
        self.updatedAt = updatedAt
        self.evidence = evidence
    }
}

/// Authoritative, bounded projection of the project task plan.
///
/// A projection grants dispatch authority only when it is fresh, valid, and
/// tied to a nonempty source revision. Stale data may still be displayed but
/// never authorizes a dispatch.
struct ConversationProjectTaskPlanProjectionV1: Codable, Equatable, Sendable {
    let sourceRevision: String?
    let freshness: ConversationProjectTaskFreshnessV1
    let isValid: Bool
    let observedAt: Date?
    let tasks: [ConversationProjectTaskV1]

    static let unavailable = ConversationProjectTaskPlanProjectionV1(
        sourceRevision: nil,
        freshness: .unavailable,
        isValid: false,
        observedAt: nil,
        tasks: []
    )

    var isAuthoritative: Bool {
        freshness == .fresh
            && isValid
            && sourceRevision?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
            && observedAt != nil
    }

    var openTasks: [ConversationProjectTaskV1] {
        tasks.filter(\.status.isOpen)
    }

    func task(id: String) -> ConversationProjectTaskV1? {
        tasks.first { $0.taskID == id }
    }
}

/// Project-level authority used to validate a Meta Agent `complete` decision.
struct ConversationProjectCompletionEvidenceV1: Codable, Equatable, Sendable {
    let taskFreshness: ConversationProjectTaskFreshnessV1
    let openTaskCount: Int?
    let observedAt: Date?
    let userConfirmedAt: Date?

    static let unavailable = ConversationProjectCompletionEvidenceV1(
        taskFreshness: .unavailable,
        openTaskCount: nil,
        observedAt: nil,
        userConfirmedAt: nil
    )

    /// Aggregate task counts are retained for v1 migration and display only.
    /// They are not task authority; only an explicit user confirmation can be
    /// decided from this legacy projection alone.
    var supportsCompletion: Bool { userConfirmedAt != nil }
}

/// Facts projected from a provider/runtime. Management enrollment, delivery,
/// and orchestration state do not belong in this base projection.
struct ConversationManagementBaseProjectionV1: Codable, Equatable, Sendable {
    let target: ConversationManagementTargetV1
    let projectID: String
    let title: String
    let role: String
    /// Stable conversation creation/first-observation time. Unlike observedAt,
    /// this must not advance when the provider reports new activity.
    let startedAt: Date
    let observedAt: Date
    let runtime: ConversationRuntimeStateV1
    let progress: ConversationProgressProjectionV1
    let evidence: ConversationEvidenceProjectionV1

    init(
        target: ConversationManagementTargetV1,
        projectID: String,
        title: String,
        role: String,
        startedAt: Date? = nil,
        observedAt: Date,
        runtime: ConversationRuntimeStateV1,
        progress: ConversationProgressProjectionV1,
        evidence: ConversationEvidenceProjectionV1
    ) {
        self.target = target
        self.projectID = projectID
        self.title = title
        self.role = role
        self.startedAt = startedAt ?? observedAt
        self.observedAt = observedAt
        self.runtime = runtime
        self.progress = progress
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case projectID
        case title
        case role
        case startedAt
        case observedAt
        case runtime
        case progress
        case evidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(
            ConversationManagementTargetV1.self,
            forKey: .target
        )
        projectID = try container.decode(String.self, forKey: .projectID)
        title = try container.decode(String.self, forKey: .title)
        role = try container.decode(String.self, forKey: .role)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        startedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .startedAt
        ) ?? observedAt
        runtime = try container.decode(
            ConversationRuntimeStateV1.self,
            forKey: .runtime
        )
        progress = try container.decode(
            ConversationProgressProjectionV1.self,
            forKey: .progress
        )
        evidence = try container.decode(
            ConversationEvidenceProjectionV1.self,
            forKey: .evidence
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(title, forKey: .title)
        try container.encode(role, forKey: .role)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(progress, forKey: .progress)
        try container.encode(evidence, forKey: .evidence)
    }
}

/// Harvis-owned extension. It joins a base projection by exact target but can
/// evolve independently of provider facts.
enum ConversationWorkKindV1: String, Codable, CaseIterable, Sendable {
    /// No explicit classification exists. Never infer one from title or role.
    case unclassified
    /// Work that must be backed by one or more explicit project-task bindings.
    case task
    case exploration
    case operations
    case knowledge
    case management

    var isPlanExempt: Bool {
        switch self {
        case .exploration, .operations, .knowledge, .management:
            return true
        case .unclassified, .task:
            return false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "unclassified", "unknown": self = .unclassified
        case "task", "planned": self = .task
        // The old generic exemption cannot identify a visible work category.
        // Migrate it fail-closed instead of inventing semantic classification.
        case "exempt": self = .unclassified
        case "exploration": self = .exploration
        case "operations": self = .operations
        case "knowledge": self = .knowledge
        case "management": self = .management
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported conversation work kind: \(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Explicit task-to-conversation join. Repeating the exact target makes a
/// misplaced binding detectable instead of silently inheriting array context.
struct ConversationTaskBindingV1: Codable, Equatable, Hashable, Sendable {
    let taskID: String
    let projectID: String
    let target: ConversationManagementTargetV1
    let boundAt: Date

    init(
        taskID: String,
        projectID: String,
        target: ConversationManagementTargetV1,
        boundAt: Date = Date()
    ) {
        self.taskID = taskID
        self.projectID = projectID
        self.target = target
        self.boundAt = boundAt
    }
}

struct ConversationManagementExtensionV1: Codable, Equatable, Sendable {
    let target: ConversationManagementTargetV1
    var revision: Int
    var enrollment: ConversationManagementEnrollmentV1
    var workKind: ConversationWorkKindV1
    var taskBindings: [ConversationTaskBindingV1]
    var delivery: ConversationDeliveryStateV1
    var management: ConversationManagementStateV1
    var lastDecisionID: UUID?
    var updatedAt: Date

    init(
        target: ConversationManagementTargetV1,
        revision: Int = 0,
        enrollment: ConversationManagementEnrollmentV1 = .inherit,
        workKind: ConversationWorkKindV1 = .unclassified,
        taskBindings: [ConversationTaskBindingV1] = [],
        delivery: ConversationDeliveryStateV1 = .none,
        management: ConversationManagementStateV1 = .unmanaged,
        lastDecisionID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.target = target
        self.revision = revision
        self.enrollment = enrollment
        self.workKind = workKind
        self.taskBindings = taskBindings
        self.delivery = delivery
        self.management = management
        self.lastDecisionID = lastDecisionID
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case revision
        case enrollment
        case workKind
        case taskBindings
        case delivery
        case management
        case lastDecisionID
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(
            ConversationManagementTargetV1.self,
            forKey: .target
        )
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        enrollment = try container.decodeIfPresent(
            ConversationManagementEnrollmentV1.self,
            forKey: .enrollment
        ) ?? .inherit
        workKind = try container.decodeIfPresent(
            ConversationWorkKindV1.self,
            forKey: .workKind
        ) ?? .unclassified
        taskBindings = try container.decodeIfPresent(
            [ConversationTaskBindingV1].self,
            forKey: .taskBindings
        ) ?? []
        delivery = try container.decodeIfPresent(
            ConversationDeliveryStateV1.self,
            forKey: .delivery
        ) ?? .none
        management = try container.decodeIfPresent(
            ConversationManagementStateV1.self,
            forKey: .management
        ) ?? .unmanaged
        lastDecisionID = try container.decodeIfPresent(
            UUID.self,
            forKey: .lastDecisionID
        )
        updatedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .updatedAt
        ) ?? Date(timeIntervalSince1970: 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(revision, forKey: .revision)
        try container.encode(enrollment, forKey: .enrollment)
        try container.encode(workKind, forKey: .workKind)
        try container.encode(taskBindings, forKey: .taskBindings)
        try container.encode(delivery, forKey: .delivery)
        try container.encode(management, forKey: .management)
        try container.encodeIfPresent(lastDecisionID, forKey: .lastDecisionID)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Resolved five-plane state consumed by the progress ledger and future UI.
struct ConversationManagementResolvedStateV1: Codable, Equatable, Sendable {
    let delivery: ConversationDeliveryStateV1
    let runtime: ConversationRuntimeStateV1
    let management: ConversationManagementStateV1
    let progress: ConversationProgressProjectionV1
    let evidence: ConversationEvidenceProjectionV1
}

struct ConversationManagementRecordV1: Codable, Equatable, Sendable {
    let base: ConversationManagementBaseProjectionV1
    var managementExtension: ConversationManagementExtensionV1?

    func isEnrolled(projectDefaultEnabled: Bool) -> Bool {
        (managementExtension?.enrollment ?? .inherit)
            .resolves(projectDefaultEnabled: projectDefaultEnabled)
    }

    var resolvedState: ConversationManagementResolvedStateV1 {
        ConversationManagementResolvedStateV1(
            delivery: managementExtension?.delivery ?? .none,
            runtime: base.runtime,
            management: managementExtension?.management ?? .unmanaged,
            progress: base.progress,
            evidence: base.evidence
        )
    }
}

struct ConversationManagementSnapshotV1: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let projectID: String
    var revision: Int
    var brainEnabled: Bool
    var projectDefaultEnrollmentEnabled: Bool
    var taskPlan: ConversationProjectTaskPlanProjectionV1
    var completionEvidence: ConversationProjectCompletionEvidenceV1
    var generatedAt: Date
    var conversations: [ConversationManagementRecordV1]

    init(
        schemaVersion: Int = ConversationManagementSchemaV1.version,
        projectID: String,
        revision: Int = 0,
        brainEnabled: Bool = false,
        projectDefaultEnrollmentEnabled: Bool = false,
        taskPlan: ConversationProjectTaskPlanProjectionV1 = .unavailable,
        completionEvidence: ConversationProjectCompletionEvidenceV1 = .unavailable,
        generatedAt: Date = Date(),
        conversations: [ConversationManagementRecordV1]
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.revision = revision
        self.brainEnabled = brainEnabled
        self.projectDefaultEnrollmentEnabled = projectDefaultEnrollmentEnabled
        self.taskPlan = taskPlan
        self.completionEvidence = completionEvidence
        self.generatedAt = generatedAt
        self.conversations = conversations
    }

    /// Completion is authoritative only from a fresh, valid task plan with no
    /// open tasks, or from an explicit user confirmation.
    var supportsCompletion: Bool {
        completionEvidence.userConfirmedAt != nil
            || (taskPlan.isAuthoritative && taskPlan.openTasks.isEmpty)
    }

    func record(
        for target: ConversationManagementTargetV1
    ) -> ConversationManagementRecordV1? {
        conversations.first { $0.base.target == target }
    }

    mutating func setEnrollment(
        _ enrollment: ConversationManagementEnrollmentV1,
        for target: ConversationManagementTargetV1,
        expectedRevision: Int,
        at now: Date = Date()
    ) throws {
        guard revision == expectedRevision else {
            throw ConversationManagementSchemaErrorV1.staleRevision(
                expected: expectedRevision,
                actual: revision
            )
        }
        guard let index = conversations.firstIndex(where: {
            $0.base.target == target
        }) else {
            throw ConversationManagementSchemaErrorV1.unknownTarget(
                target.stableID
            )
        }
        var extensionValue = conversations[index].managementExtension
            ?? ConversationManagementExtensionV1(target: target, updatedAt: now)
        extensionValue.revision += 1
        extensionValue.enrollment = enrollment
        extensionValue.updatedAt = now
        conversations[index].managementExtension = extensionValue
        revision += 1
        generatedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID
        case revision
        case brainEnabled
        case projectDefaultEnrollmentEnabled
        case taskPlan
        case completionEvidence
        case generatedAt
        case conversations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? ConversationManagementSchemaV1.version
        projectID = try container.decode(String.self, forKey: .projectID)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        // Additive v1 migration is deliberately fail-closed: persisted data
        // created before this field existed never enables the brain implicitly.
        brainEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .brainEnabled
        ) ?? false
        projectDefaultEnrollmentEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .projectDefaultEnrollmentEnabled
        ) ?? false
        taskPlan = try container.decodeIfPresent(
            ConversationProjectTaskPlanProjectionV1.self,
            forKey: .taskPlan
        ) ?? .unavailable
        completionEvidence = try container.decodeIfPresent(
            ConversationProjectCompletionEvidenceV1.self,
            forKey: .completionEvidence
        ) ?? .unavailable
        generatedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .generatedAt
        ) ?? Date(timeIntervalSince1970: 0)
        conversations = try container.decodeIfPresent(
            [ConversationManagementRecordV1].self,
            forKey: .conversations
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(revision, forKey: .revision)
        try container.encode(brainEnabled, forKey: .brainEnabled)
        try container.encode(
            projectDefaultEnrollmentEnabled,
            forKey: .projectDefaultEnrollmentEnabled
        )
        try container.encode(taskPlan, forKey: .taskPlan)
        try container.encode(completionEvidence, forKey: .completionEvidence)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(conversations, forKey: .conversations)
    }
}

enum ConversationManagementDecisionKindV1: String, Codable, CaseIterable, Sendable {
    case dispatch
    case complete
    case needsUser = "needs_user"
    case recommendHandoff = "recommend_handoff"
}

struct ConversationManagementDecisionV1: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: ConversationManagementDecisionKindV1
    let target: ConversationManagementTargetV1?
    let taskID: String?
    let prompt: String?
    let reason: String
    let expectedEvidence: String?

    init(
        id: UUID = UUID(),
        kind: ConversationManagementDecisionKindV1,
        target: ConversationManagementTargetV1? = nil,
        taskID: String? = nil,
        prompt: String? = nil,
        reason: String,
        expectedEvidence: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.taskID = taskID
        self.prompt = prompt
        self.reason = reason
        self.expectedEvidence = expectedEvidence
    }
}

/// Strict DSH Meta Agent output contract. `expectedRevision` protects the run
/// ledger while `projectionRevision` protects the observed project snapshot.
struct ConversationManagementProposalV1: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let projectID: String
    let expectedRevision: Int
    let projectionRevision: Int
    let cycle: Int
    let summary: String
    let decisions: [ConversationManagementDecisionV1]

    init(
        schemaVersion: Int = ConversationManagementSchemaV1.version,
        runID: UUID,
        projectID: String,
        expectedRevision: Int,
        projectionRevision: Int,
        cycle: Int,
        summary: String,
        decisions: [ConversationManagementDecisionV1]
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.projectionRevision = projectionRevision
        self.cycle = cycle
        self.summary = summary
        self.decisions = decisions
    }
}

enum ConversationManagementSchemaErrorV1: LocalizedError, Equatable {
    case unsupportedVersion(expected: Int, actual: Int)
    case invalidValue(field: String, reason: String)
    case staleRevision(expected: Int, actual: Int)
    case duplicateTarget(String)
    case targetMismatch(String)
    case unknownTarget(String)
    case targetNotAllowed(String)
    case targetExcluded(String)
    case duplicateDecision(UUID)
    case invalidDecision(UUID, String)
    case tooManyDecisions(Int)
    case mixedDecisionKinds
    case genericContinuation(UUID)
    case duplicateWithoutNewEvidence(UUID)
    case brainDisabled(String)
    case taskPlanUnavailable
    case taskPlanStale
    case taskPlanInvalid
    case unknownTask(String)
    case taskNotOpen(String)
    case taskNotLinked(taskID: String, target: String)
    case taskWorkKindRequired(String)
    case completionEvidenceRequired
    case invalidTransition(from: String, to: String)
    case terminalLedger
    case duplicateRun(UUID)
    case duplicateProject(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(expected, actual):
            return "Unsupported Conversation Management schema version \(actual); expected \(expected)."
        case let .invalidValue(field, reason):
            return "Invalid Conversation Management value for \(field): \(reason)"
        case let .staleRevision(expected, actual):
            return "Stale Conversation Management revision \(expected); current revision is \(actual)."
        case let .duplicateTarget(target):
            return "Duplicate Conversation Management target: \(target)"
        case let .targetMismatch(target):
            return "Conversation base and management extension targets differ: \(target)"
        case let .unknownTarget(target):
            return "Unknown Conversation Management target: \(target)"
        case let .targetNotAllowed(target):
            return "Conversation Management target is outside the caller allowlist: \(target)"
        case let .targetExcluded(target):
            return "Conversation Management target is explicitly excluded: \(target)"
        case let .duplicateDecision(id):
            return "Duplicate Conversation Management decision: \(id.uuidString)"
        case let .invalidDecision(id, reason):
            return "Invalid Conversation Management decision \(id.uuidString): \(reason)"
        case let .tooManyDecisions(count):
            return "Conversation Management proposal has too many decisions: \(count)."
        case .mixedDecisionKinds:
            return "Non-dispatch management decisions must be the proposal's only decision."
        case let .genericContinuation(id):
            return "Conversation Management decision \(id.uuidString) is only a generic continuation."
        case let .duplicateWithoutNewEvidence(id):
            return "Conversation Management decision \(id.uuidString) repeats an instruction without new evidence."
        case let .brainDisabled(projectID):
            return "Conversation Management brain is disabled for project \(projectID)."
        case .taskPlanUnavailable:
            return "Conversation Management dispatch requires an available project task plan."
        case .taskPlanStale:
            return "Conversation Management dispatch requires a fresh project task plan."
        case .taskPlanInvalid:
            return "Conversation Management dispatch requires a valid project task plan."
        case let .unknownTask(taskID):
            return "Unknown Conversation Management project task: \(taskID)"
        case let .taskNotOpen(taskID):
            return "Conversation Management project task is not open: \(taskID)"
        case let .taskNotLinked(taskID, target):
            return "Conversation Management task \(taskID) is not explicitly linked to target \(target)."
        case let .taskWorkKindRequired(target):
            return "Conversation Management target \(target) must be explicitly classified as task work."
        case .completionEvidenceRequired:
            return "Conversation completion requires a fresh valid zero-open-task plan or explicit user confirmation."
        case let .invalidTransition(from, to):
            return "Invalid Conversation Management transition from \(from) to \(to)."
        case .terminalLedger:
            return "A terminal Conversation Management ledger cannot accept another update."
        case let .duplicateRun(id):
            return "Duplicate Conversation Management run: \(id.uuidString)"
        case let .duplicateProject(id):
            return "Duplicate Conversation Management project snapshot: \(id)"
        }
    }
}
