import Combine
import CryptoKit
import Foundation

enum DshMetaAgentPolicy {
    static let requiredPresetID = "harvis-meta-manager"
    static let dedicatedHomeID = "dsh-harvis-meta"
    static let dedicatedProfile = "web"
    static let defaultDecisionTimeout: TimeInterval = 20 * 60

    static func isDedicatedEndpoint(_ endpoint: DshRuntimeEndpoint) -> Bool {
        endpoint.homeID == dedicatedHomeID
            && endpoint.profile == dedicatedProfile
    }

    /// Stable, opaque session identity for one project inside the dedicated
    /// DSH brain Home. No path or project label is exposed in the identifier.
    static func projectSessionID(projectID: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(
            "harvis-meta-manager-v1:\(projectID)".utf8
        )).prefix(16))
        // RFC 9562 custom UUID (version 8) and RFC variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12)),
        ].joined(separator: "-")
    }
}

struct DshMetaAgentSessionRequest: Equatable, Sendable {
    let endpoint: DshRuntimeEndpoint
    let sessionID: String
    let presetID: String
    /// Exact caller-supplied project cwd. It is never inferred from projectID.
    let projectPath: String
    let rpcID: String
}

struct DshMetaAgentPromptRequest: Equatable, Sendable {
    let endpoint: DshRuntimeEndpoint
    let sessionID: String
    let rpcID: String
    let mode: DshSessionPromptMode
    let text: String
}

enum DshMetaAgentDecisionResult: Equatable, Sendable {
    case proposalJSON(Data)
    case failed(String)
    case deliveryUnknown(String)
}

/// The Coordinator owns retry and persistence policy. Implementations must
/// issue each mutation exactly once and must never retry `session.prompt`.
protocol DshMetaAgentDecisionClient: Sendable {
    func prepareSession(
        _ request: DshMetaAgentSessionRequest
    ) async throws

    func queuePrompt(
        _ request: DshMetaAgentPromptRequest
    ) async throws -> Bool

    func waitForDecision(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        promptRPCID: String
    ) async throws -> DshMetaAgentDecisionResult

    /// Cancels the exact dedicated Meta session once. Callers never retry an
    /// ambiguous response.
    func cancelSession(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        rpcID: String
    ) async throws -> Bool
}

enum DshMetaAgentClientError: LocalizedError, Equatable, Sendable {
    case invalidPreset(String)
    case unavailablePreset(String)
    case brokenPreset(String, String)
    case invalidPresetTrust(id: String, actual: String)
    case sessionPresetMismatch(expected: String, actual: String?)
    case sessionMismatch(expected: String, actual: String)
    case nonQueuePrompt
    case decisionTimedOut

    var errorDescription: String? {
        switch self {
        case let .invalidPreset(id):
            return "DSH Meta Agent requires the exact preset \(id)."
        case let .unavailablePreset(id):
            return "DSH preset \(id) is not installed; no fallback preset was used."
        case let .brokenPreset(id, reason):
            return "DSH preset \(id) is broken: \(reason)"
        case let .invalidPresetTrust(id, actual):
            return "DSH preset \(id) must be a dedicated user preset, not \(actual)."
        case let .sessionPresetMismatch(expected, actual):
            let actualID = actual ?? "none"
            return "DSH session uses preset \(actualID), expected \(expected)."
        case let .sessionMismatch(expected, actual):
            return "DSH created session \(actual), expected \(expected)."
        case .nonQueuePrompt:
            return "DSH Meta Agent prompts must use queue mode."
        case .decisionTimedOut:
            return "DSH Meta Agent did not produce a decision before the deadline."
        }
    }
}

/// Production adapter around the narrow rc.8 Host API. It validates the
/// dedicated preset, uses a caller-supplied session id, queues one prompt, and
/// then performs read-only history reconciliation by the exact prompt rpcId.
struct DshHostMetaAgentDecisionClient: DshMetaAgentDecisionClient {
    let pollIntervalNanoseconds: UInt64
    let decisionTimeout: TimeInterval

    init(
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        decisionTimeout: TimeInterval = DshMetaAgentPolicy.defaultDecisionTimeout
    ) {
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.decisionTimeout = decisionTimeout
    }

    func prepareSession(
        _ request: DshMetaAgentSessionRequest
    ) async throws {
        try requireDedicatedEndpoint(request.endpoint)
        guard request.presetID == DshMetaAgentPolicy.requiredPresetID else {
            throw DshMetaAgentClientError.invalidPreset(
                DshMetaAgentPolicy.requiredPresetID
            )
        }
        let client = DshHostApiClient(endpoint: request.endpoint)
        let roster = try await client.agentPresetList(
            rpcID: "\(request.rpcID)-preset-list"
        )
        guard let preset = roster.presets.first(where: {
            $0.id == request.presetID
        }) else {
            throw DshMetaAgentClientError.unavailablePreset(request.presetID)
        }
        if let broken = preset.broken?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !broken.isEmpty {
            throw DshMetaAgentClientError.brokenPreset(
                request.presetID,
                broken
            )
        }
        guard preset.trust == .user else {
            throw DshMetaAgentClientError.invalidPresetTrust(
                id: request.presetID,
                actual: preset.trust.rawValue
            )
        }

        let created = try await client.sessionCreate(
            DshSessionCreatePayload(
                cwd: request.projectPath,
                sessionID: request.sessionID,
                agentPreset: request.presetID
            ),
            rpcID: request.rpcID
        )
        guard created.sessionID == request.sessionID else {
            throw DshMetaAgentClientError.sessionMismatch(
                expected: request.sessionID,
                actual: created.sessionID
            )
        }
        guard created.agentPreset == request.presetID else {
            throw DshMetaAgentClientError.sessionPresetMismatch(
                expected: request.presetID,
                actual: created.agentPreset
            )
        }
    }

    func queuePrompt(
        _ request: DshMetaAgentPromptRequest
    ) async throws -> Bool {
        try requireDedicatedEndpoint(request.endpoint)
        guard request.mode == .queue else {
            throw DshMetaAgentClientError.nonQueuePrompt
        }
        return try await DshHostApiClient(endpoint: request.endpoint)
            .sessionPrompt(
                DshSessionPromptPayload(
                    sessionID: request.sessionID,
                    mode: .queue,
                    content: [.text(request.text)],
                    clientTimeZone: TimeZone.current.identifier
                ),
                rpcID: request.rpcID
            ).accepted
    }

    func waitForDecision(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        promptRPCID: String
    ) async throws -> DshMetaAgentDecisionResult {
        try requireDedicatedEndpoint(endpoint)
        let client = DshHostApiClient(endpoint: endpoint)
        let deadline = Date().addingTimeInterval(decisionTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let history = try await client.sessionHistory(
                DshSessionHistoryPayload(
                    sessionID: sessionID,
                    maxMessages: 100
                ),
                rpcID: UUID().uuidString
            )
            switch DshMetaAgentHistoryScanner.scan(
                history.events,
                promptRPCID: promptRPCID
            ) {
            case .pending:
                try await Task.sleep(
                    nanoseconds: pollIntervalNanoseconds
                )
            case let .proposalJSON(data):
                return .proposalJSON(data)
            case let .failed(reason):
                return .failed(reason)
            case let .deliveryUnknown(reason):
                return .deliveryUnknown(reason)
            }
        }
        throw DshMetaAgentClientError.decisionTimedOut
    }

    func cancelSession(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        rpcID: String
    ) async throws -> Bool {
        try requireDedicatedEndpoint(endpoint)
        return try await DshHostApiClient(endpoint: endpoint).sessionCancel(
            DshSessionCancelPayload(sessionID: sessionID),
            rpcID: rpcID
        ).accepted
    }

    private func requireDedicatedEndpoint(
        _ endpoint: DshRuntimeEndpoint
    ) throws {
        guard DshMetaAgentPolicy.isDedicatedEndpoint(endpoint) else {
            throw DshMetaAgentCoordinatorError.brainEndpointUnavailable(
                homeID: DshMetaAgentPolicy.dedicatedHomeID,
                profile: DshMetaAgentPolicy.dedicatedProfile
            )
        }
    }
}

enum DshMetaAgentHistoryScanResult: Equatable, Sendable {
    case pending
    case proposalJSON(Data)
    case failed(String)
    case deliveryUnknown(String)
}

enum DshMetaAgentHistoryScanner {
    static func scan(
        _ entries: [DshSessionHistoryEntry],
        promptRPCID: String
    ) -> DshMetaAgentHistoryScanResult {
        let events = entries.map(\.event).sorted { $0.seq < $1.seq }
        let prompts = events.filter {
            $0.type == "user/message"
                && $0.data["source"]?["rpcId"]?.stringValue == promptRPCID
        }
        guard let prompt = prompts.first else {
            return .pending
        }
        guard prompts.count == 1 else {
            return .deliveryUnknown(
                "The Meta prompt rpcId appeared more than once; no output was attributed."
            )
        }
        guard let boundary = events.last(where: {
            $0.seq < prompt.seq
                && ($0.type == "turn/start" || $0.type == "turn/end")
        }), boundary.type == "turn/start",
              let turn = boundary.data["turn"]?.intValue else {
            return .deliveryUnknown(
                "The exact Meta prompt was not inside one identifiable DSH turn."
            )
        }

        var lastAssistantJSON: Data?
        for event in events where event.seq > boundary.seq {
            if event.type == "user/message", event.seq != prompt.seq {
                return .deliveryUnknown(
                    "Another user message shared the Meta prompt turn; no output was attributed."
                )
            }
            if event.type == "turn/start" {
                return .deliveryUnknown(
                    "A new DSH turn started before the Meta prompt turn closed."
                )
            }
            if event.type == "assistant/message" {
                guard event.data["turn"]?.intValue == turn else {
                    return .deliveryUnknown(
                        "An assistant message could not be matched to the exact Meta turn."
                    )
                }
                if event.data["interrupted"]?.boolValue == true {
                    return .deliveryUnknown(
                        "The Meta Agent assistant message was interrupted."
                    )
                }
                lastAssistantJSON = assistantText(in: event.data)
                    .map { Data($0.utf8) }
            }
            if event.type == "turn/error"
                || event.type == "agent/error"
                || event.type == "assistant/error" {
                return .failed(safeErrorDescription(
                    code: event.data["error"]?["code"]?.stringValue
                ))
            }
            if event.type == "turn/end" {
                guard event.data["turn"]?.intValue == turn else {
                    return .deliveryUnknown(
                        "The DSH turn boundary did not match the Meta prompt turn."
                    )
                }
                let reason = event.data["reason"]?["kind"]?.stringValue
                if reason == "completed", let lastAssistantJSON {
                    return .proposalJSON(lastAssistantJSON)
                }
                if reason == "interrupted" || reason == "aborted" {
                    return .deliveryUnknown(
                        "The DSH Meta Agent turn did not close normally."
                    )
                }
                if reason == "error" {
                    return .failed(safeErrorDescription(
                        code: event.data["reason"]?["error"]?["code"]?.stringValue
                    ))
                }
                return .failed(
                    "The DSH Meta Agent turn ended without one completed JSON decision."
                )
            }
        }
        return .pending
    }

    /// Backend messages may contain provider details or credentials. Only
    /// verified protocol codes map to fixed copy; neither code nor message is echoed.
    private static func safeErrorDescription(code: String?) -> String {
        switch code {
        case "MISSING_CREDENTIAL":
            return "分析服务缺少模型凭据，请配置专用分析服务的模型凭据后重试。"
        default:
            return "分析服务执行失败，请检查专用分析服务的配置后重试。"
        }
    }

    private static func assistantText(in data: DshJSONValue) -> String? {
        if let text = normalized(data["text"]?.stringValue) {
            return text
        }
        if let content = data["content"]?.arrayValue {
            let parts = content.compactMap { part -> String? in
                guard part["type"]?.stringValue == "text" else { return nil }
                return normalized(part["text"]?.stringValue)
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }
        if let message = data["message"] {
            return assistantText(in: message)
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct DshMetaCodexDestination: Equatable, Sendable {
    let target: ConversationManagementTargetV1
    let homeID: String
    let homePath: String
    let sourceThreadID: String
    let targetThreadID: String
    let cardType: CodexTaskCardType
}

@MainActor
protocol DshMetaCodexCommandDispatching: AnyObject {
    func enqueueMetaCommand(
        commandID: UUID,
        destination: DshMetaCodexDestination,
        text: String
    ) async -> UUID?

    func metaQueueItem(commandID: UUID) -> CodexTaskQueueItem?
}

extension CodexTaskDeliveryCoordinator: DshMetaCodexCommandDispatching {
    func enqueueMetaCommand(
        commandID: UUID,
        destination: DshMetaCodexDestination,
        text: String
    ) async -> UUID? {
        await submit(
            commandID: commandID,
            homeID: destination.homeID,
            homePath: destination.homePath,
            sourceThreadID: destination.sourceThreadID,
            targetThreadID: destination.targetThreadID,
            cardType: destination.cardType,
            text: text
        )
    }

    func metaQueueItem(commandID: UUID) -> CodexTaskQueueItem? {
        durableQueueItems.first { $0.id == commandID }
    }
}

enum DshMetaAgentExecutionMode: String, Codable, Equatable, Sendable {
    case previewOnly
    case automaticSerial
}

struct DshMetaAgentPreview: Equatable, Sendable {
    let runID: UUID
    let proposal: ConversationManagementProposalV1
    let ledgerRevision: Int
}

struct DshMetaAgentDispatchOutcome: Equatable, Sendable {
    let commandID: UUID
    let delivery: ConversationDeliveryStateV1

    var isPaused: Bool {
        delivery == .waitingApproval
            || delivery == .failed
            || delivery == .deliveryUnknown
    }
}

struct DshMetaAgentProjectStatus: Equatable, Sendable {
    let projectID: String
    let isConfigured: Bool
    let runID: UUID?
    let revision: Int?
    let state: ConversationManagementResolvedStateV1?
    let executionMode: DshMetaAgentExecutionMode
}

enum DshMetaAgentCoordinatorError: LocalizedError, Equatable {
    case notReady
    case unknownProject(String)
    case unknownRun(UUID)
    case projectAlreadyManaged(String)
    case invalidProjectPath
    case planningAlreadyInFlight(UUID)
    case metaSessionMismatch(expected: String, actual: String)
    case promptRejected
    case planningFailed(String)
    case deliveryUnknown(String)
    case invalidProposal(String)
    case missingDecision(UUID)
    case unsupportedTarget(String)
    case targetMismatch(String)
    case projectManagementDisabled(String)
    case brainEndpointUnavailable(homeID: String, profile: String)
    case dispatchUnavailable
    case dispatchRejected(UUID)
    case exactQueueItemMissing(UUID)
    case projectApprovalInFlight(String)
    case runCancelled(UUID)
    case runNotCancellable(UUID)
    case automaticDispatchRequiresExplicitDestination

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "DSH Meta Agent state is not loaded."
        case let .unknownProject(id):
            return "Unknown managed project: \(id)"
        case let .unknownRun(id):
            return "Unknown DSH Meta Agent run: \(id.uuidString)"
        case let .projectAlreadyManaged(id):
            return "Project \(id) already has an active Meta Agent run."
        case .invalidProjectPath:
            return "DSH Meta Agent requires an exact absolute project path."
        case let .planningAlreadyInFlight(id):
            return "DSH Meta Agent run \(id.uuidString) is already planning."
        case let .metaSessionMismatch(expected, actual):
            return "Meta Agent run is bound to session \(expected), not \(actual)."
        case .promptRejected:
            return "DSH rejected the queued Meta Agent prompt."
        case let .planningFailed(reason):
            return "DSH Meta Agent planning failed: \(reason)"
        case let .deliveryUnknown(reason):
            return "Delivery is unknown and was not replayed: \(reason)"
        case let .invalidProposal(reason):
            return "DSH Meta Agent returned an invalid proposal: \(reason)"
        case let .missingDecision(id):
            return "The accepted proposal has no decision \(id.uuidString)."
        case let .unsupportedTarget(target):
            return "Meta Agent target cannot be dispatched through Codex: \(target)"
        case let .targetMismatch(target):
            return "The approved destination does not match decision target \(target)."
        case let .projectManagementDisabled(projectID):
            return "Project \(projectID) has Meta Agent management disabled."
        case let .brainEndpointUnavailable(homeID, profile):
            return "Dedicated DSH brain endpoint \(homeID)/\(profile) is not running or is ambiguous."
        case .dispatchUnavailable:
            return "Codex task delivery is not active."
        case let .dispatchRejected(id):
            return "Codex command \(id.uuidString) was not durably queued."
        case let .exactQueueItemMissing(id):
            return "Codex queue item \(id.uuidString) could not be reconciled."
        case let .projectApprovalInFlight(projectID):
            return "Project \(projectID) is committing an approved command; management settings are temporarily locked."
        case let .runCancelled(runID):
            return "Management run \(runID.uuidString) was cancelled by the user."
        case let .runNotCancellable(runID):
            return "Management run \(runID.uuidString) already owns a Codex command; wait for its exact terminal state or cancel it in the task panel."
        case .automaticDispatchRequiresExplicitDestination:
            return "Automatic mode requires an explicit, validated target resolver."
        }
    }
}

/// Project-level Meta Agent orchestration. DSH may only propose work. The
/// default is preview-only; a Codex mutation happens only through
/// `approveProposal`, after an exact command id is durably recorded.
@MainActor
final class DshMetaAgentCoordinator: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var projectStatuses: [
        String: DshMetaAgentProjectStatus
    ] = [:]
    @Published private(set) var lastError: String?

    private let store: any ConversationManagementStoringV1
    private let dshClient: any DshMetaAgentDecisionClient
    private weak var codexDispatcher: (any DshMetaCodexCommandDispatching)?
    private let makeUUID: @Sendable () -> UUID
    private var envelope = ConversationManagementStoreEnvelopeV1()
    private var planningRuns: Set<UUID> = []
    private var startingProjects: [String: UUID] = [:]
    private var dispatchingProjects: Set<String> = []
    private var cancellingRuns: Set<UUID> = []
    private var planningContexts: [UUID: (
        endpoint: DshRuntimeEndpoint,
        sessionID: String
    )] = [:]
    private var executionModes: [String: DshMetaAgentExecutionMode] = [:]
    private var lifecycleGeneration: UInt64 = 0

    init(
        store: any ConversationManagementStoringV1 = ConversationManagementStoreV1(),
        dshClient: any DshMetaAgentDecisionClient = DshHostMetaAgentDecisionClient(),
        codexDispatcher: (any DshMetaCodexCommandDispatching)? = nil,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.store = store
        self.dshClient = dshClient
        self.codexDispatcher = codexDispatcher
        self.makeUUID = makeUUID
    }

    func activate() async {
        guard !isReady else { return }
        let generation = lifecycleGeneration
        do {
            let loaded = try await store.load()
            guard generation == lifecycleGeneration else { return }
            envelope = loaded
            isReady = true
            lastError = nil
            publishStatuses()
        } catch {
            guard generation == lifecycleGeneration else { return }
            lastError = error.localizedDescription
        }
    }

    func deactivate() {
        lifecycleGeneration &+= 1
        planningRuns.removeAll()
        startingProjects.removeAll()
        isReady = false
    }

    func snapshot(
        projectID: String
    ) -> ConversationManagementSnapshotV1? {
        envelope.snapshot(projectID: projectID)
    }

    func ledger(
        runID: UUID
    ) -> ConversationManagementProgressLedgerV1? {
        envelope.ledger(runID: runID)
    }

    func latestLedger(
        projectID: String
    ) -> ConversationManagementProgressLedgerV1? {
        envelope.ledgers
            .filter { $0.projectID == projectID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func latestLedgersByProject() -> [
        String: ConversationManagementProgressLedgerV1
    ] {
        var result: [String: ConversationManagementProgressLedgerV1] = [:]
        for ledger in envelope.ledgers {
            if let current = result[ledger.projectID],
               current.updatedAt >= ledger.updatedAt {
                continue
            }
            result[ledger.projectID] = ledger
        }
        return result
    }

    /// Read-only recovery inventory. A caller may reconcile these exact
    /// command IDs against the already-loaded Codex queue, but must never
    /// recreate a missing command.
    func ledgersWithRecordedDispatches() -> [
        ConversationManagementProgressLedgerV1
    ] {
        envelope.ledgers.filter { !$0.dispatchMemory.isEmpty }
    }

    /// Reconciles only already-recorded Codex commands against their exact
    /// queue items. This method never calls `enqueueMetaCommand`; a missing
    /// item is therefore terminal `deliveryUnknown`, never a replay request.
    func reconcileRecordedDispatches() async {
        guard isReady else { return }
        let candidates = envelope.ledgers.compactMap { ledger -> (
            runID: UUID,
            decisionID: UUID
        )? in
            guard !Self.isTerminalDelivery(ledger.currentState.delivery),
                  let proposal = ledger.latestProposal,
                  let memory = ledger.dispatchMemory.reversed().first(where: {
                      candidate in
                      proposal.decisions.contains(where: {
                          $0.id == candidate.decisionID
                      })
                  }) else {
                return nil
            }
            return (ledger.runID, memory.decisionID)
        }

        for candidate in candidates {
            guard !Task.isCancelled,
                  let current = envelope.ledger(runID: candidate.runID),
                  !Self.isTerminalDelivery(current.currentState.delivery),
                  current.latestProposal?.decisions.contains(where: {
                      $0.id == candidate.decisionID
                  }) == true else {
                continue
            }
            do {
                _ = try await reconcileProposal(
                    runID: candidate.runID,
                    decisionID: candidate.decisionID,
                    expectedRevision: current.revision
                )
            } catch DshMetaAgentCoordinatorError.exactQueueItemMissing {
                // `reconcileProposal` already persisted deliveryUnknown.
            } catch ConversationManagementSchemaErrorV1.staleRevision {
                // A newer exact state won the CAS while this pass was waiting.
                // The next queue publication will reconcile that revision.
            } catch {
                lastError = bounded(error.localizedDescription)
            }
        }
    }

    func status(projectID: String) -> DshMetaAgentProjectStatus? {
        projectStatuses[projectID]
    }

    func setExecutionMode(
        _ mode: DshMetaAgentExecutionMode,
        projectID: String
    ) throws {
        guard envelope.snapshot(projectID: projectID) != nil else {
            throw DshMetaAgentCoordinatorError.unknownProject(projectID)
        }
        guard mode == .previewOnly else {
            // The Coordinator deliberately does not infer a Codex destination
            // from provider display metadata. RuntimeModel must supply a
            // persistent, validated resolver before automatic serial mode can
            // be enabled.
            throw DshMetaAgentCoordinatorError
                .automaticDispatchRequiresExplicitDestination
        }
        executionModes[projectID] = mode
        publishStatuses()
    }

    func configureProjectSnapshot(
        _ snapshot: ConversationManagementSnapshotV1,
        expectedRevision: Int?
    ) async throws {
        try requireReady()
        guard !dispatchingProjects.contains(snapshot.projectID),
              !startingProjects.keys.contains(snapshot.projectID) else {
            throw DshMetaAgentCoordinatorError.projectApprovalInFlight(
                snapshot.projectID
            )
        }
        try await store.upsert(
            snapshot: snapshot,
            expectedRevision: expectedRevision
        )
        envelope = try await store.load()
        lastError = nil
        publishStatuses()
    }

    @discardableResult
    func startPreview(
        projectID: String,
        objective: String,
        projectPath: String,
        endpoint: DshRuntimeEndpoint,
        preset: String = DshMetaAgentPolicy.requiredPresetID,
        policy: ConversationManagementValidationPolicyV1
    ) async throws -> DshMetaAgentPreview {
        try requireReady()
        let lifecycle = lifecycleGeneration
        try requireDedicatedEndpoint(endpoint)
        guard preset == DshMetaAgentPolicy.requiredPresetID else {
            throw DshMetaAgentClientError.invalidPreset(
                DshMetaAgentPolicy.requiredPresetID
            )
        }
        guard projectPath.hasPrefix("/"),
              !projectPath.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw DshMetaAgentCoordinatorError.invalidProjectPath
        }
        guard let snapshot = envelope.snapshot(projectID: projectID) else {
            throw DshMetaAgentCoordinatorError.unknownProject(projectID)
        }
        guard snapshot.brainEnabled else {
            throw DshMetaAgentCoordinatorError.projectManagementDisabled(
                projectID
            )
        }
        guard startingProjects[projectID] == nil else {
            throw DshMetaAgentCoordinatorError.projectAlreadyManaged(projectID)
        }
        let reservationID = UUID()
        startingProjects[projectID] = reservationID
        defer {
            if startingProjects[projectID] == reservationID {
                startingProjects.removeValue(forKey: projectID)
            }
        }
        if envelope.ledgers.contains(where: {
            $0.projectID == projectID && Self.isBlockingRun($0)
        }) {
            throw DshMetaAgentCoordinatorError.projectAlreadyManaged(projectID)
        }

        let runID = makeUUID()
        let ledger = ConversationManagementProgressLedgerV1(
            runID: runID,
            projectID: projectID,
            objective: objective
        )
        try await persistNewLedger(ledger)
        try requireLifecycle(lifecycle)
        let proposal = try await requestDecision(
            runID: runID,
            metaSessionID: DshMetaAgentPolicy.projectSessionID(
                projectID: projectID
            ),
            projectPath: projectPath,
            endpoint: endpoint,
            preset: preset,
            policy: policy,
            expectedRevision: ledger.revision
        )
        guard let accepted = envelope.ledger(runID: runID) else {
            throw DshMetaAgentCoordinatorError.unknownRun(runID)
        }
        return DshMetaAgentPreview(
            runID: runID,
            proposal: proposal,
            ledgerRevision: accepted.revision
        )
    }

    @discardableResult
    func continuePreview(
        runID: UUID,
        projectPath: String,
        endpoint: DshRuntimeEndpoint,
        preset: String = DshMetaAgentPolicy.requiredPresetID,
        policy: ConversationManagementValidationPolicyV1,
        expectedRevision: Int
    ) async throws -> DshMetaAgentPreview {
        let current = try requireLedger(runID)
        let sessionID = current.metaSessionID ?? makeUUID().uuidString
        let proposal = try await requestDecision(
            runID: runID,
            metaSessionID: sessionID,
            projectPath: projectPath,
            endpoint: endpoint,
            preset: preset,
            policy: policy,
            expectedRevision: expectedRevision
        )
        guard let accepted = envelope.ledger(runID: runID) else {
            throw DshMetaAgentCoordinatorError.unknownRun(runID)
        }
        return DshMetaAgentPreview(
            runID: runID,
            proposal: proposal,
            ledgerRevision: accepted.revision
        )
    }

    @discardableResult
    func requestDecision(
        runID: UUID,
        metaSessionID: String,
        projectPath: String,
        endpoint: DshRuntimeEndpoint,
        preset: String,
        policy: ConversationManagementValidationPolicyV1,
        expectedRevision: Int,
        planningRPCID: String? = nil
    ) async throws -> ConversationManagementProposalV1 {
        try requireReady()
        let lifecycle = lifecycleGeneration
        try requireDedicatedEndpoint(endpoint)
        guard projectPath.hasPrefix("/"),
              !projectPath.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw DshMetaAgentCoordinatorError.invalidProjectPath
        }
        guard preset == DshMetaAgentPolicy.requiredPresetID else {
            throw DshMetaAgentClientError.invalidPreset(
                DshMetaAgentPolicy.requiredPresetID
            )
        }
        guard planningRuns.insert(runID).inserted else {
            throw DshMetaAgentCoordinatorError.planningAlreadyInFlight(runID)
        }
        defer { planningRuns.remove(runID) }

        var planning = try requireLedger(runID)
        guard planning.currentState.management == .observing else {
            if planning.currentState.management == .planning {
                throw DshMetaAgentCoordinatorError
                    .planningAlreadyInFlight(runID)
            }
            throw ConversationManagementSchemaErrorV1.invalidTransition(
                from: planning.currentState.management.rawValue,
                to: ConversationManagementStateV1.planning.rawValue
            )
        }
        if let bound = planning.metaSessionID, bound != metaSessionID {
            throw DshMetaAgentCoordinatorError.metaSessionMismatch(
                expected: bound,
                actual: metaSessionID
            )
        }
        guard let snapshot = envelope.snapshot(projectID: planning.projectID) else {
            throw DshMetaAgentCoordinatorError.unknownProject(
                planning.projectID
            )
        }
        guard snapshot.brainEnabled else {
            throw DshMetaAgentCoordinatorError.projectManagementDisabled(
                planning.projectID
            )
        }
        let singleDecisionPolicy = ConversationManagementValidationPolicyV1(
            allowedTargets: policy.allowedTargets,
            maxDecisions: 1
        )
        let rpcID = planningRPCID ?? makeUUID().uuidString
        try planning.startPlanning(
            metaSessionID: metaSessionID,
            planningRPCID: rpcID,
            expectedRevision: expectedRevision
        )
        try await persistLedger(
            planning,
            expectedRevision: expectedRevision
        )
        try requireLifecycle(lifecycle)
        planningContexts[runID] = (endpoint, metaSessionID)
        defer {
            planningContexts.removeValue(forKey: runID)
            cancellingRuns.remove(runID)
        }

        let prompt = try planningPrompt(
            snapshot: snapshot,
            ledger: planning,
            policy: singleDecisionPolicy
        )
        try requirePlanningActive(runID: runID, planningRPCID: rpcID)
        do {
            try await dshClient.prepareSession(
                DshMetaAgentSessionRequest(
                    endpoint: endpoint,
                    sessionID: metaSessionID,
                    presetID: preset,
                    projectPath: projectPath,
                    rpcID: "\(runID.uuidString)-session-create"
                )
            )
            try requireLifecycle(lifecycle)
            try requirePlanningActive(runID: runID, planningRPCID: rpcID)
        } catch DshMetaAgentCoordinatorError.notReady {
            throw DshMetaAgentCoordinatorError.notReady
        } catch DshMetaAgentCoordinatorError.runCancelled(_) {
            throw DshMetaAgentCoordinatorError.runCancelled(runID)
        } catch let error as DshMetaAgentClientError {
            try await finishPlanning(
                runID: runID,
                delivery: .failed,
                note: bounded(error.localizedDescription)
            )
            throw error
        } catch {
            try await finishPlanning(
                runID: runID,
                delivery: .deliveryUnknown,
                note: "DSH session preparation response was not reliable; the planning prompt was not replayed."
            )
            throw DshMetaAgentCoordinatorError.deliveryUnknown(
                bounded(error.localizedDescription)
            )
        }

        let accepted: Bool
        do {
            accepted = try await dshClient.queuePrompt(
                DshMetaAgentPromptRequest(
                    endpoint: endpoint,
                    sessionID: metaSessionID,
                    rpcID: rpcID,
                    mode: .queue,
                    text: prompt
                )
            )
            try requireLifecycle(lifecycle)
            try requirePlanningActive(runID: runID, planningRPCID: rpcID)
        } catch DshMetaAgentCoordinatorError.notReady {
            throw DshMetaAgentCoordinatorError.notReady
        } catch DshMetaAgentCoordinatorError.runCancelled(_) {
            throw DshMetaAgentCoordinatorError.runCancelled(runID)
        } catch {
            try await finishPlanning(
                runID: runID,
                delivery: .deliveryUnknown,
                note: "DSH session.prompt response was lost; rpcId was retained and the prompt was not replayed."
            )
            throw DshMetaAgentCoordinatorError.deliveryUnknown(
                bounded(error.localizedDescription)
            )
        }
        guard accepted else {
            try await finishPlanning(
                runID: runID,
                delivery: .failed,
                note: "DSH definitively rejected the queued planning prompt."
            )
            throw DshMetaAgentCoordinatorError.promptRejected
        }

        let result: DshMetaAgentDecisionResult
        do {
            result = try await dshClient.waitForDecision(
                endpoint: endpoint,
                sessionID: metaSessionID,
                promptRPCID: rpcID
            )
            try requireLifecycle(lifecycle)
            try requirePlanningActive(runID: runID, planningRPCID: rpcID)
        } catch DshMetaAgentCoordinatorError.notReady {
            throw DshMetaAgentCoordinatorError.notReady
        } catch DshMetaAgentCoordinatorError.runCancelled(_) {
            throw DshMetaAgentCoordinatorError.runCancelled(runID)
        } catch {
            try await finishPlanning(
                runID: runID,
                delivery: .deliveryUnknown,
                note: "DSH decision reconciliation stopped without a reliable terminal result; no prompt was replayed."
            )
            throw DshMetaAgentCoordinatorError.deliveryUnknown(
                bounded(error.localizedDescription)
            )
        }

        switch result {
        case let .failed(reason):
            try await finishPlanning(
                runID: runID,
                delivery: .failed,
                note: bounded(reason)
            )
            throw DshMetaAgentCoordinatorError.planningFailed(
                bounded(reason)
            )
        case let .deliveryUnknown(reason):
            try await finishPlanning(
                runID: runID,
                delivery: .deliveryUnknown,
                note: bounded(reason)
            )
            throw DshMetaAgentCoordinatorError.deliveryUnknown(
                bounded(reason)
            )
        case let .proposalJSON(data):
            return try await acceptProposalJSON(
                data,
                runID: runID,
                snapshot: snapshot,
                policy: singleDecisionPolicy
            )
        }
    }

    @discardableResult
    func approveProposal(
        runID: UUID,
        decisionID: UUID,
        destination: DshMetaCodexDestination,
        policy: ConversationManagementValidationPolicyV1,
        projectManagementEnabled: Bool,
        expectedRevision: Int
    ) async throws -> DshMetaAgentDispatchOutcome {
        try requireReady()
        let lifecycle = lifecycleGeneration
        // Re-read the actor-owned store at the approval boundary. A preview is
        // not authority after its project snapshot, enrollment, or allowlist
        // has changed.
        let loaded = try await store.load()
        try requireLifecycle(lifecycle)
        envelope = loaded
        publishStatuses()
        var ledger = try requireLedger(runID)
        try requireRevision(expectedRevision, ledger: ledger)
        guard projectManagementEnabled else {
            throw DshMetaAgentCoordinatorError.projectManagementDisabled(
                ledger.projectID
            )
        }
        guard let decision = ledger.latestProposal?.decisions.first(where: {
            $0.id == decisionID
        }), decision.kind == .dispatch,
              let target = decision.target,
              let prompt = decision.prompt else {
            throw DshMetaAgentCoordinatorError.missingDecision(decisionID)
        }
        guard let proposal = ledger.latestProposal else {
            throw DshMetaAgentCoordinatorError.missingDecision(decisionID)
        }
        let currentRecord = try requireCurrentDispatchRecord(
            projectID: ledger.projectID,
            proposalRevision: proposal.projectionRevision,
            target: target,
            policy: policy
        )
        guard target == destination.target,
              destination.homeID == target.sourceScope,
              destination.sourceThreadID == target.sourceID,
              destination.targetThreadID == target.sourceID else {
            throw DshMetaAgentCoordinatorError.targetMismatch(target.stableID)
        }
        guard target.provider.lowercased() == "codex",
              destination.cardType.canDispatchThroughCodex else {
            throw DshMetaAgentCoordinatorError.unsupportedTarget(
                target.stableID
            )
        }

        if let existing = ledger.dispatchMemory.first(where: {
            $0.decisionID == decisionID
        }) {
            return try await reconcileProposal(
                runID: runID,
                decisionID: decisionID,
                expectedRevision: expectedRevision,
                knownCommandID: existing.commandID
            )
        }
        guard let codexDispatcher else {
            throw DshMetaAgentCoordinatorError.dispatchUnavailable
        }
        guard dispatchingProjects.insert(ledger.projectID).inserted else {
            throw DshMetaAgentCoordinatorError.projectApprovalInFlight(
                ledger.projectID
            )
        }
        defer { dispatchingProjects.remove(ledger.projectID) }

        let commandID = makeUUID()
        try ledger.recordDelivery(
            decisionID: decisionID,
            target: target,
            commandID: commandID,
            delivery: .dispatching,
            evidence: currentRecord.base.evidence,
            expectedRevision: expectedRevision,
            note: "Approved after preview; preparing exact Codex command."
        )
        try await persistLedger(
            ledger,
            expectedRevision: expectedRevision
        )
        try requireLifecycle(lifecycle)

        do {
            let loaded = try await store.load()
            try requireLifecycle(lifecycle)
            envelope = loaded
            _ = try requireCurrentDispatchRecord(
                projectID: ledger.projectID,
                proposalRevision: proposal.projectionRevision,
                target: target,
                policy: policy
            )
        } catch {
            _ = try? await recordDispatchState(
                runID: runID,
                decisionID: decisionID,
                target: target,
                commandID: commandID,
                delivery: .failed,
                note: "Project authority changed before Codex delivery; no command was sent."
            )
            throw error
        }

        try requireLifecycle(lifecycle)
        guard await codexDispatcher.enqueueMetaCommand(
            commandID: commandID,
            destination: destination,
            text: prompt
        ) == commandID else {
            try await recordDispatchState(
                runID: runID,
                decisionID: decisionID,
                target: target,
                commandID: commandID,
                delivery: .failed,
                note: "Codex rejected the preallocated command before delivery."
            )
            throw DshMetaAgentCoordinatorError.dispatchRejected(commandID)
        }
        try requireLifecycle(lifecycle)

        return try await reconcileProposal(
            runID: runID,
            decisionID: decisionID,
            expectedRevision: try requireLedger(runID).revision,
            knownCommandID: commandID
        )
    }

    @discardableResult
    func reconcileProposal(
        runID: UUID,
        decisionID: UUID,
        expectedRevision: Int
    ) async throws -> DshMetaAgentDispatchOutcome {
        let ledger = try requireLedger(runID)
        try requireRevision(expectedRevision, ledger: ledger)
        guard let memory = ledger.dispatchMemory.first(where: {
            $0.decisionID == decisionID
        }) else {
            throw DshMetaAgentCoordinatorError.missingDecision(decisionID)
        }
        return try await reconcileProposal(
            runID: runID,
            decisionID: decisionID,
            expectedRevision: expectedRevision,
            knownCommandID: memory.commandID
        )
    }

    func pause(
        runID: UUID,
        expectedRevision: Int,
        note: String = "Paused by the user."
    ) async throws {
        var ledger = try requireLedger(runID)
        try requireProjectMutationUnlocked(ledger.projectID)
        try ledger.pause(
            expectedRevision: expectedRevision,
            note: note
        )
        try await persistLedger(ledger, expectedRevision: expectedRevision)
    }

    func resume(
        runID: UUID,
        expectedRevision: Int,
        note: String = "Resumed by the user."
    ) async throws {
        var ledger = try requireLedger(runID)
        try requireProjectMutationUnlocked(ledger.projectID)
        try ledger.resume(
            expectedRevision: expectedRevision,
            note: note
        )
        try await persistLedger(ledger, expectedRevision: expectedRevision)
    }

    func cancel(
        runID: UUID,
        expectedRevision: Int,
        note: String = "Cancelled by the user."
    ) async throws {
        var ledger = try requireLedger(runID)
        try requireProjectMutationUnlocked(ledger.projectID)
        guard ledger.dispatchMemory.isEmpty else {
            throw DshMetaAgentCoordinatorError.runNotCancellable(runID)
        }
        let context = planningContexts[runID]
        let cancellationReservationID = UUID()
        startingProjects[ledger.projectID] = cancellationReservationID
        cancellingRuns.insert(runID)
        do {
            try ledger.cancel(
                expectedRevision: expectedRevision,
                note: note
            )
            try await persistLedger(
                ledger,
                expectedRevision: expectedRevision
            )
        } catch {
            cancellingRuns.remove(runID)
            if startingProjects[ledger.projectID]
                == cancellationReservationID {
                startingProjects.removeValue(forKey: ledger.projectID)
            }
            throw error
        }

        guard let context else {
            if startingProjects[ledger.projectID]
                == cancellationReservationID {
                startingProjects.removeValue(forKey: ledger.projectID)
            }
            return
        }
        do {
            let accepted = try await dshClient.cancelSession(
                endpoint: context.endpoint,
                sessionID: context.sessionID,
                rpcID: "\(runID.uuidString)-session-cancel"
            )
            if accepted {
                if startingProjects[ledger.projectID]
                    == cancellationReservationID {
                    startingProjects.removeValue(forKey: ledger.projectID)
                }
            } else {
                lastError = "DSH did not accept cancellation for the exact Meta session; the cancelled proposal result will still be ignored."
            }
        } catch {
            lastError = "DSH cancellation response was unknown; the cancelled proposal result will not be accepted or replayed."
        }
    }

    private func reconcileProposal(
        runID: UUID,
        decisionID: UUID,
        expectedRevision: Int,
        knownCommandID: UUID
    ) async throws -> DshMetaAgentDispatchOutcome {
        let ledger = try requireLedger(runID)
        try requireRevision(expectedRevision, ledger: ledger)
        if ledger.currentState.delivery == .failed
            || ledger.currentState.delivery == .deliveryUnknown {
            return DshMetaAgentDispatchOutcome(
                commandID: knownCommandID,
                delivery: ledger.currentState.delivery
            )
        }
        guard let decision = ledger.latestProposal?.decisions.first(where: {
            $0.id == decisionID
        }), let target = decision.target else {
            throw DshMetaAgentCoordinatorError.missingDecision(decisionID)
        }
        guard let item = codexDispatcher?.metaQueueItem(
            commandID: knownCommandID
        ) else {
            try await recordDispatchState(
                runID: runID,
                decisionID: decisionID,
                target: target,
                commandID: knownCommandID,
                delivery: .deliveryUnknown,
                note: "The exact Codex queue item was missing; it was not recreated."
            )
            throw DshMetaAgentCoordinatorError.exactQueueItemMissing(
                knownCommandID
            )
        }

        let observed = conversationDelivery(for: item.state)
        let next = monotonicDelivery(
            current: ledger.currentState.delivery,
            observed: observed
        )
        let reconciled: ConversationDeliveryStateV1
        if next != ledger.currentState.delivery {
            reconciled = try await recordDispatchState(
                runID: runID,
                decisionID: decisionID,
                target: target,
                commandID: knownCommandID,
                delivery: next,
                note: item.lastError
            )
        } else {
            reconciled = next
        }
        return DshMetaAgentDispatchOutcome(
            commandID: knownCommandID,
            delivery: reconciled
        )
    }

    private func acceptProposalJSON(
        _ data: Data,
        runID: UUID,
        snapshot: ConversationManagementSnapshotV1,
        policy: ConversationManagementValidationPolicyV1
    ) async throws -> ConversationManagementProposalV1 {
        let proposal: ConversationManagementProposalV1
        var accepted = try requireLedger(runID)
        do {
            proposal = try JSONDecoder().decode(
                ConversationManagementProposalV1.self,
                from: data
            )
            try accepted.accept(
                proposal: proposal,
                snapshot: snapshot,
                policy: policy,
                expectedRevision: accepted.revision
            )
        } catch {
            try await finishPlanning(
                runID: runID,
                delivery: .failed,
                note: "DSH returned JSON that failed the v1 schema validator."
            )
            throw DshMetaAgentCoordinatorError.invalidProposal(
                bounded(error.localizedDescription)
            )
        }

        let previousRevision = accepted.revision - 1
        do {
            try await persistLedger(
                accepted,
                expectedRevision: previousRevision
            )
        } catch {
            try? await finishPlanning(
                runID: runID,
                delivery: .deliveryUnknown,
                note: "The validated proposal could not be durably committed; no planning prompt was replayed."
            )
            throw DshMetaAgentCoordinatorError.deliveryUnknown(
                bounded(error.localizedDescription)
            )
        }

        lastError = nil
        return proposal
    }

    private func finishPlanning(
        runID: UUID,
        delivery: ConversationDeliveryStateV1,
        note: String
    ) async throws {
        var ledger = try requireLedger(runID)
        let expectedRevision = ledger.revision
        try ledger.recordPlanningFailure(
            delivery: delivery,
            expectedRevision: expectedRevision,
            note: note
        )
        try await persistLedger(ledger, expectedRevision: expectedRevision)
    }

    @discardableResult
    private func recordDispatchState(
        runID: UUID,
        decisionID: UUID,
        target: ConversationManagementTargetV1,
        commandID: UUID,
        delivery: ConversationDeliveryStateV1,
        note: String?
    ) async throws -> ConversationDeliveryStateV1 {
        var lastStaleError: ConversationManagementSchemaErrorV1?
        for _ in 0..<3 {
            var ledger = try requireLedger(runID)
            guard ledger.dispatchMemory.contains(where: {
                $0.decisionID == decisionID && $0.commandID == commandID
            }) else {
                throw DshMetaAgentCoordinatorError.missingDecision(decisionID)
            }
            let next = monotonicDelivery(
                current: ledger.currentState.delivery,
                observed: delivery
            )
            if next == ledger.currentState.delivery {
                return next
            }
            let expectedRevision = ledger.revision
            try ledger.recordDelivery(
                decisionID: decisionID,
                target: target,
                commandID: commandID,
                delivery: next,
                expectedRevision: expectedRevision,
                note: note
            )
            do {
                try await persistLedger(
                    ledger,
                    expectedRevision: expectedRevision
                )
                return next
            } catch let error as ConversationManagementSchemaErrorV1 {
                guard case .staleRevision = error else { throw error }
                lastStaleError = error
                envelope = try await store.load()
                publishStatuses()
            }
        }
        if let lastStaleError { throw lastStaleError }
        throw DshMetaAgentCoordinatorError.deliveryUnknown(
            "Exact Codex state could not be reconciled after bounded CAS retries."
        )
    }

    private func persistNewLedger(
        _ ledger: ConversationManagementProgressLedgerV1
    ) async throws {
        try await store.upsert(ledger: ledger, expectedRevision: nil)
        envelope = try await store.load()
        lastError = nil
        publishStatuses()
    }

    private func persistLedger(
        _ ledger: ConversationManagementProgressLedgerV1,
        expectedRevision: Int
    ) async throws {
        try await store.upsert(
            ledger: ledger,
            expectedRevision: expectedRevision
        )
        envelope = try await store.load()
        lastError = nil
        publishStatuses()
    }

    private func planningPrompt(
        snapshot: ConversationManagementSnapshotV1,
        ledger: ConversationManagementProgressLedgerV1,
        policy: ConversationManagementValidationPolicyV1
    ) throws -> String {
        struct Context: Encodable {
            let snapshot: ConversationManagementSnapshotV1
            let ledger: ConversationManagementProgressLedgerV1
            let allowedTargets: [ConversationManagementTargetV1]
            let maxDecisions: Int
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Context(
            snapshot: snapshot,
            ledger: ledger,
            allowedTargets: policy.allowedTargets.sorted {
                $0.stableID < $1.stableID
            },
            maxDecisions: policy.maxDecisions
        ))
        guard let context = String(data: data, encoding: .utf8) else {
            throw DshMetaAgentCoordinatorError.invalidProposal(
                "planning context was not UTF-8"
            )
        }
        return """
        You are Harvis's project-level Meta Agent. Produce exactly one JSON document and no Markdown. It must decode as ConversationManagementProposalV1 and pass the v1 schema validator. Use the exact runID, projectID, expectedRevision, projectionRevision, and cycle required by the supplied ledger and snapshot. The supplied project task evidence is the sole plan authority; do not invent a shadow plan, LLMWiki, or semantic-similarity drift score. Never emit a generic continue/proceed instruction. Every dispatch must name one allowed target, a bounded semantic prompt, and expected evidence. If evidence is insufficient, choose needs_user or recommend_handoff. Do not execute the proposed task yourself.

        CONTEXT_JSON:
        \(context)
        """
    }

    private func publishStatuses() {
        var statuses: [String: DshMetaAgentProjectStatus] = [:]
        for snapshot in envelope.snapshots {
            let ledger = latestLedger(projectID: snapshot.projectID)
            statuses[snapshot.projectID] = DshMetaAgentProjectStatus(
                projectID: snapshot.projectID,
                isConfigured: true,
                runID: ledger?.runID,
                revision: ledger?.revision,
                state: ledger?.currentState,
                executionMode: executionModes[snapshot.projectID]
                    ?? .previewOnly
            )
        }
        projectStatuses = statuses
    }

    private func requireReady() throws {
        guard isReady else {
            throw DshMetaAgentCoordinatorError.notReady
        }
    }

    private func requireLedger(
        _ runID: UUID
    ) throws -> ConversationManagementProgressLedgerV1 {
        try requireReady()
        guard let ledger = envelope.ledger(runID: runID) else {
            throw DshMetaAgentCoordinatorError.unknownRun(runID)
        }
        return ledger
    }

    private func requireRevision(
        _ expectedRevision: Int,
        ledger: ConversationManagementProgressLedgerV1
    ) throws {
        guard ledger.revision == expectedRevision else {
            throw ConversationManagementSchemaErrorV1.staleRevision(
                expected: expectedRevision,
                actual: ledger.revision
            )
        }
    }

    private func requireDedicatedEndpoint(
        _ endpoint: DshRuntimeEndpoint
    ) throws {
        guard DshMetaAgentPolicy.isDedicatedEndpoint(endpoint) else {
            throw DshMetaAgentCoordinatorError.brainEndpointUnavailable(
                homeID: DshMetaAgentPolicy.dedicatedHomeID,
                profile: DshMetaAgentPolicy.dedicatedProfile
            )
        }
    }

    private func requireCurrentDispatchRecord(
        projectID: String,
        proposalRevision: Int,
        target: ConversationManagementTargetV1,
        policy: ConversationManagementValidationPolicyV1
    ) throws -> ConversationManagementRecordV1 {
        guard let snapshot = envelope.snapshot(projectID: projectID) else {
            throw DshMetaAgentCoordinatorError.unknownProject(projectID)
        }
        guard snapshot.brainEnabled else {
            throw DshMetaAgentCoordinatorError.projectManagementDisabled(
                projectID
            )
        }
        guard snapshot.revision == proposalRevision else {
            throw ConversationManagementSchemaErrorV1.staleRevision(
                expected: proposalRevision,
                actual: snapshot.revision
            )
        }
        guard let record = snapshot.record(for: target) else {
            throw ConversationManagementSchemaErrorV1.unknownTarget(
                target.stableID
            )
        }
        guard policy.allowedTargets.contains(target) else {
            throw ConversationManagementSchemaErrorV1.targetNotAllowed(
                target.stableID
            )
        }
        guard record.isEnrolled(
            projectDefaultEnabled: snapshot.projectDefaultEnrollmentEnabled
        ) else {
            throw ConversationManagementSchemaErrorV1.targetExcluded(
                target.stableID
            )
        }
        return record
    }

    private func conversationDelivery(
        for state: CodexDeliveryState
    ) -> ConversationDeliveryStateV1 {
        switch state {
        case .queued, .waiting, .dispatching: return .accepted
        case .running: return .running
        case .waitingApproval: return .waitingApproval
        case .completed: return .completed
        case .failed: return .failed
        case .deliveryUnknown: return .deliveryUnknown
        case .cancelled: return .cancelled
        }
    }

    private func monotonicDelivery(
        current: ConversationDeliveryStateV1,
        observed: ConversationDeliveryStateV1
    ) -> ConversationDeliveryStateV1 {
        if current == .completed || current == .failed
            || current == .deliveryUnknown || current == .cancelled {
            return current
        }
        if observed == .accepted,
           current == .running || current == .waitingApproval {
            return current
        }
        return observed
    }

    private static func isTerminalDelivery(
        _ delivery: ConversationDeliveryStateV1
    ) -> Bool {
        delivery == .completed || delivery == .failed
            || delivery == .deliveryUnknown || delivery == .cancelled
    }

    private static func isBlockingRun(
        _ ledger: ConversationManagementProgressLedgerV1
    ) -> Bool {
        if ledger.entries.isEmpty,
           ledger.latestProposal == nil,
           ledger.currentState.delivery == .none,
           ledger.currentState.management == .observing {
            return false
        }
        return !ledger.currentState.management.isTerminal
            && !isTerminalDelivery(ledger.currentState.delivery)
    }

    private func requireProjectMutationUnlocked(_ projectID: String) throws {
        guard !dispatchingProjects.contains(projectID) else {
            throw DshMetaAgentCoordinatorError.projectApprovalInFlight(
                projectID
            )
        }
    }

    private func requireLifecycle(_ generation: UInt64) throws {
        guard isReady, generation == lifecycleGeneration else {
            throw DshMetaAgentCoordinatorError.notReady
        }
    }

    private func requirePlanningActive(
        runID: UUID,
        planningRPCID: String
    ) throws {
        guard !cancellingRuns.contains(runID),
              let ledger = envelope.ledger(runID: runID),
              ledger.currentState.management == .planning,
              ledger.planningRPCID == planningRPCID else {
            throw DshMetaAgentCoordinatorError.runCancelled(runID)
        }
    }

    private func bounded(_ value: String) -> String {
        String(value.prefix(500))
    }
}
