import Foundation

enum CodexTaskCardType: String, Codable, CaseIterable, Sendable {
    case main
    case persistedSubagent
    case sidechatParent
    case transientSidechat
    case dsh
    case workBuddy

    var canDispatchThroughCodex: Bool {
        switch self {
        case .main, .persistedSubagent, .sidechatParent:
            return true
        case .transientSidechat, .dsh, .workBuddy:
            return false
        }
    }
}

enum CodexTaskStrategy: String, Codable, Sendable {
    case smart
    /// A delivery that must begin as its own turn and must never steer an
    /// already-running Manager turn. Used by transactional workflows such as
    /// conversation handoff.
    case freshTurn
    case serialBatch
}

struct CodexTaskBatchPosition: Codable, Equatable, Sendable {
    let batchID: UUID
    let ordinal: Int
    let count: Int

    var displayIndex: Int { ordinal + 1 }
}

enum CodexDeliveryState: String, Codable, CaseIterable, Sendable {
    case queued
    case waiting
    case dispatching
    case running
    case waitingApproval
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
}

enum CodexTurnOwnership: Codable, Equatable, Sendable {
    case manager(turnID: String, connectionID: UUID)
    case external(turnID: String?)

    var turnID: String? {
        switch self {
        case let .manager(turnID, _):
            return turnID
        case let .external(turnID):
            return turnID
        }
    }

    func managerTurnID(on connectionID: UUID?) -> String? {
        guard let connectionID else { return nil }
        guard case let .manager(turnID, ownerConnectionID) = self,
              ownerConnectionID == connectionID else {
            return nil
        }
        return turnID
    }
}

struct CodexTaskCommand: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let homeID: String
    let homePath: String
    let threadID: String
    let sourceThreadID: String
    let cardType: CodexTaskCardType
    let text: String
    let strategy: CodexTaskStrategy
    let batch: CodexTaskBatchPosition?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        homeID: String,
        homePath: String,
        threadID: String,
        sourceThreadID: String,
        cardType: CodexTaskCardType,
        text: String,
        strategy: CodexTaskStrategy = .smart,
        batch: CodexTaskBatchPosition? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.homeID = homeID
        self.homePath = homePath
        self.threadID = threadID
        self.sourceThreadID = sourceThreadID
        self.cardType = cardType
        self.text = text
        self.strategy = strategy
        self.batch = batch
        self.createdAt = createdAt
    }
}

enum CodexDispatchPhase: String, Codable, Sendable {
    case queued
    case resume
    case start
    case steer
}

struct CodexTaskQueueItem: Codable, Equatable, Identifiable, Sendable {
    let command: CodexTaskCommand
    var state: CodexDeliveryState
    var stateChangedAt: Date
    var ownership: CodexTurnOwnership?
    var connectionID: UUID?
    var requestID: Int?
    var dispatchPhase: CodexDispatchPhase
    var lastError: String?

    var id: UUID { command.id }

    init(
        command: CodexTaskCommand,
        state: CodexDeliveryState = .queued,
        stateChangedAt: Date = Date(),
        ownership: CodexTurnOwnership? = nil,
        connectionID: UUID? = nil,
        requestID: Int? = nil,
        dispatchPhase: CodexDispatchPhase = .queued,
        lastError: String? = nil
    ) {
        self.command = command
        self.state = state
        self.stateChangedAt = stateChangedAt
        self.ownership = ownership
        self.connectionID = connectionID
        self.requestID = requestID
        self.dispatchPhase = dispatchPhase
        self.lastError = lastError
    }
}

enum CodexSerialBatchPredecessorDecision: Equatable, Sendable {
    case ready
    case waiting(String)
    case stop(String)
}

enum CodexSerialBatchPolicy {
    static let repeatCountDefaultsKey =
        "harvis.codex.chatManager.serialBatch.repeatCount"
    static let defaultRepeatCount = 20
    static let repeatCountRange = 2 ... 20

    static func normalizedRepeatCount(_ value: Int) -> Int {
        min(max(value, repeatCountRange.lowerBound), repeatCountRange.upperBound)
    }

    static func normalizedPrompt(
        _ text: String,
        repeatCount: Int
    ) -> String? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, repeatCountRange.contains(repeatCount) else {
            return nil
        }
        return prompt
    }

    static func predecessorDecision(
        for item: CodexTaskQueueItem,
        in items: [CodexTaskQueueItem]
    ) -> CodexSerialBatchPredecessorDecision {
        guard item.command.strategy == .serialBatch,
              let batch = item.command.batch else {
            return .ready
        }
        guard batch.count >= repeatCountRange.lowerBound,
              batch.count <= repeatCountRange.upperBound,
              batch.ordinal >= 0,
              batch.ordinal < batch.count else {
            return .stop("Automatic batch metadata is invalid.")
        }
        guard batch.ordinal > 0 else { return .ready }
        guard let predecessor = items.first(where: {
            $0.command.batch?.batchID == batch.batchID
                && $0.command.batch?.ordinal == batch.ordinal - 1
        }) else {
            return .stop("The previous automatic batch step is missing.")
        }
        switch predecessor.state {
        case .completed:
            return .ready
        case .failed:
            return .stop("The previous automatic step failed; remaining steps were stopped.")
        case .deliveryUnknown:
            return .stop("The previous automatic step has unknown delivery; remaining steps were stopped without replay.")
        case .cancelled:
            return .stop("The previous automatic step was cancelled; remaining steps were stopped.")
        case .queued, .waiting, .dispatching, .running, .waitingApproval:
            return .waiting(
                "Waiting for automatic step \(batch.ordinal)/\(batch.count) to complete."
            )
        }
    }
}

struct CodexTaskQueueEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    var items: [CodexTaskQueueItem]

    init(version: Int = schemaVersion, items: [CodexTaskQueueItem]) {
        self.version = version
        self.items = items
    }
}

struct CodexTaskTarget: Hashable, Sendable {
    let homePath: String
    let threadID: String
}

enum CodexSmartDispatchDecision: Equatable, Sendable {
    case start
    case steer(turnID: String)
    case queue
}

enum CodexSmartRouter {
    static func decide(
        externalRunning: Bool,
        ownership: CodexTurnOwnership?,
        activeTurnID: String?,
        connectionID: UUID?
    ) -> CodexSmartDispatchDecision {
        if let ownership,
           let managerTurnID = ownership.managerTurnID(on: connectionID),
           managerTurnID == activeTurnID {
            return .steer(turnID: managerTurnID)
        }
        return externalRunning ? .queue : .start
    }
}

struct CodexIdleDispatchGate: Equatable, Sendable {
    private(set) var consecutiveIdleObservations = 0

    mutating func observe(successfulIdle: Bool) {
        consecutiveIdleObservations = successfulIdle
            ? consecutiveIdleObservations + 1
            : 0
    }

    mutating func reset() {
        consecutiveIdleObservations = 0
    }

    func permitsDispatch(finalSuccessfulIdle: Bool) -> Bool {
        consecutiveIdleObservations >= 2 && finalSuccessfulIdle
    }
}

enum CodexLiveEventKind: String, Codable, Sendable {
    case connection
    case status
    case turn
    case tool
    case message
    case approval
    case error
}

struct CodexLiveEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: CodexLiveEventKind
    let summary: String
    let turnID: String?
    let itemID: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: CodexLiveEventKind,
        summary: String,
        turnID: String? = nil,
        itemID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
        self.turnID = turnID
        self.itemID = itemID
    }
}

enum CodexThreadRuntimeStatus: String, Codable, Sendable {
    case disconnected
    case idle
    case active
    case waitingApproval
    case waitingUserInput
    case notLoaded
    case systemError
}

struct CodexUserInputOption: Codable, Equatable, Identifiable, Sendable {
    let label: String
    let description: String?

    var id: String { label }
}

struct CodexUserInputQuestion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let header: String?
    let question: String
    let options: [CodexUserInputOption]
    let isOther: Bool
    let isSecret: Bool

    init(
        id: String,
        header: String?,
        question: String,
        options: [CodexUserInputOption],
        isOther: Bool = false,
        isSecret: Bool = false
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.isOther = isOther
        self.isSecret = isSecret
    }
}

enum CodexApprovalDecisionOption: String, Codable, Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

struct CodexFileApprovalChange: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let kind: String
    let diff: String

    var id: String { "\(kind)::\(path)" }
}

struct CodexPendingApproval: Equatable, Identifiable, Sendable {
    let id: CodexRPCID
    let connectionID: UUID
    let method: String
    let threadID: String
    let turnID: String?
    let title: String
    let detail: String
    let params: CodexJSONValue
    let questions: [CodexUserInputQuestion]
    let availableDecisions: [CodexApprovalDecisionOption]?
    var fileChanges: [CodexFileApprovalChange]

    init(
        id: CodexRPCID,
        connectionID: UUID,
        method: String,
        threadID: String,
        turnID: String?,
        title: String,
        detail: String,
        params: CodexJSONValue,
        questions: [CodexUserInputQuestion],
        availableDecisions: [CodexApprovalDecisionOption]? = nil,
        fileChanges: [CodexFileApprovalChange] = []
    ) {
        self.id = id
        self.connectionID = connectionID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.title = title
        self.detail = detail
        self.params = params
        self.questions = questions
        self.availableDecisions = availableDecisions
        self.fileChanges = fileChanges
    }

    func matches(_ other: CodexPendingApproval) -> Bool {
        id == other.id && connectionID == other.connectionID
    }
}

private struct CodexFileChangeEvidence: Equatable, Sendable {
    let itemID: String
    let changes: [CodexFileApprovalChange]
}

struct CodexThreadLiveState: Equatable, Sendable {
    let target: CodexTaskTarget
    var connectionID: UUID?
    var status: CodexThreadRuntimeStatus
    var activeTurnID: String?
    var ownership: CodexTurnOwnership?
    var lastCompletedTurnID: String?
    var lastCompletedTurnStatus: String?
    var events: [CodexLiveEvent]
    var currentToolSummary: String?
    var finalSummary: String?
    private(set) var pendingApprovals: [CodexPendingApproval]
    private var fileChangeEvidence: [CodexFileChangeEvidence]

    var pendingApproval: CodexPendingApproval? {
        pendingApprovals.first
    }

    init(target: CodexTaskTarget) {
        self.target = target
        connectionID = nil
        status = .disconnected
        activeTurnID = nil
        ownership = nil
        lastCompletedTurnID = nil
        lastCompletedTurnStatus = nil
        events = []
        currentToolSummary = nil
        finalSummary = nil
        pendingApprovals = []
        fileChangeEvidence = []
    }

    mutating func append(_ event: CodexLiveEvent, limit: Int = 120) {
        events.append(event)
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
    }

    mutating func enqueueApproval(_ approval: CodexPendingApproval) {
        guard !pendingApprovals.contains(where: { $0.matches(approval) }) else {
            return
        }
        var enriched = approval
        if let itemID = approval.params["itemId"]?.stringValue,
           let evidence = fileChangeEvidence.last(where: {
               $0.itemID == itemID
           }) {
            enriched.fileChanges = evidence.changes
        }
        pendingApprovals.append(enriched)
    }

    @discardableResult
    mutating func dequeueApproval(
        matching approval: CodexPendingApproval
    ) -> Bool {
        guard pendingApprovals.first?.matches(approval) == true else {
            return false
        }
        pendingApprovals.removeFirst()
        return true
    }

    mutating func clearPendingApprovals() {
        pendingApprovals.removeAll()
    }

    mutating func rememberFileChanges(
        itemID: String,
        changes: [CodexFileApprovalChange],
        limit: Int = 32
    ) {
        guard !itemID.isEmpty, !changes.isEmpty else { return }
        fileChangeEvidence.removeAll { $0.itemID == itemID }
        fileChangeEvidence.append(CodexFileChangeEvidence(
            itemID: itemID,
            changes: changes
        ))
        if fileChangeEvidence.count > limit {
            fileChangeEvidence.removeFirst(fileChangeEvidence.count - limit)
        }
        for index in pendingApprovals.indices
            where pendingApprovals[index].params["itemId"]?.stringValue == itemID {
            pendingApprovals[index].fileChanges = changes
        }
    }
}

enum CodexCardDispatchCapability: Equatable, Sendable {
    case direct(threadID: String)
    case parentOnly(threadID: String)
    case unavailable(reason: String)
}

enum CodexComposerVisibilityPolicy {
    static let isVisibleDefaultsKey =
        "harvis.codex.chatManager.composer.visible"
    static let selectedTagsDefaultsKey =
        "harvis.codex.chatManager.composer.selectedTagsJSON"

    static func selectedTags(from encoded: String) -> Set<String> {
        guard let data = encoded.data(using: .utf8),
              let values = try? JSONDecoder().decode(
                  [String].self,
                  from: data
              ) else {
            return []
        }
        return Set(values)
    }

    static func encodeSelectedTags(_ tags: Set<String>) -> String {
        let orderedTags = tags.sorted()
        guard let data = try? JSONEncoder().encode(orderedTags),
              let encoded = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return encoded
    }

    static func shouldShow(
        isEnabled: Bool,
        selectedTags: Set<String>,
        threadTags: [String],
        cardOverride: Bool? = nil
    ) -> Bool {
        // A local input action must still work when the bulk switch or its
        // tag filter hides other cards. The owner keys overrides by source.
        if let cardOverride { return cardOverride }
        guard isEnabled else { return false }
        guard !selectedTags.isEmpty else { return true }
        return selectedTags.contains { selectedTag in
            threadTags.contains { threadTag in
                threadTag.caseInsensitiveCompare(selectedTag) == .orderedSame
            }
        }
    }
}

enum CodexComposerKeyAction: Equatable, Sendable {
    case send
    case newline
    case forwardToInputSystem

    static func action(
        keyCode: UInt16,
        shiftPressed: Bool,
        hasMarkedText: Bool
    ) -> CodexComposerKeyAction {
        guard keyCode == 36 || keyCode == 76 else {
            return .forwardToInputSystem
        }
        if hasMarkedText {
            return .forwardToInputSystem
        }
        return shiftPressed ? .newline : .send
    }
}

enum CodexWorkbenchMode: String, Codable, Sendable {
    case compact
    case expanded
}

struct CodexWorkbenchWindowSize: Codable, Equatable, Sendable {
    static let compactDefault = CodexWorkbenchWindowSize(width: 920, height: 780)
    static let expandedDefault = CodexWorkbenchWindowSize(width: 1180, height: 820)

    let width: Double
    let height: Double

    func clamped(for mode: CodexWorkbenchMode) -> CodexWorkbenchWindowSize {
        let minimumWidth = mode == .expanded ? 980.0 : 480.0
        let minimumHeight = 560.0
        return CodexWorkbenchWindowSize(
            width: max(minimumWidth, width),
            height: max(minimumHeight, height)
        )
    }
}

extension ManagedChatThread {
    var taskCardType: CodexTaskCardType {
        switch provider {
        case .codex:
            if isSidechat {
                return parentThreadID == nil ? .transientSidechat : .sidechatParent
            }
            return isSubagent ? .persistedSubagent : .main
        case .dsh:
            return .dsh
        case .workBuddy:
            return .workBuddy
        }
    }

    var dispatchCapability: CodexCardDispatchCapability {
        switch provider {
        case .dsh:
            return .unavailable(reason: "DSH cards are observation-only.")
        case .workBuddy:
            return .unavailable(reason: "WorkBuddy cards are observation-only.")
        case .codex:
            if isSidechat {
                guard let parentThreadID, !parentThreadID.isEmpty else {
                    return .unavailable(reason: "Transient Sidechat has no reliable parent target.")
                }
                return .parentOnly(threadID: parentThreadID)
            }
            return .direct(threadID: sourceID)
        }
    }
}
