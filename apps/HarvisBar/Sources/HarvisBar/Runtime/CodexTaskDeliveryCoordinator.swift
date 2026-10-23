import Combine
import Foundation

@MainActor
final class CodexTaskDeliveryCoordinator: ObservableObject {
    @Published private(set) var queueItems: [CodexTaskQueueItem] = []
    /// Last queue snapshot that the store confirmed as durable. Runtime UI may
    /// continue to render `queueItems` optimistically, but safety-sensitive
    /// consumers must use this projection so an in-memory state published
    /// before `save` cannot be mistaken for committed delivery evidence.
    @Published private(set) var durableQueueItems: [CodexTaskQueueItem] = []
    /// Monotonic in-process commit token for `durableQueueItems`. It advances
    /// after a successful load/recovery or save, including an empty snapshot.
    @Published private(set) var durableQueueRevision: UInt64 = 0
    @Published private(set) var liveStates: [
        CodexTaskTarget: CodexThreadLiveState
    ] = [:]
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?

    /// Optional owner-specific validation after native resume, immediately
    /// before sending a new turn. Group delivery uses this to revalidate the
    /// pinned account, project, permissions and durable dispatch identity.
    var submissionValidator: (@MainActor (CodexTaskCommand, CodexJSONValue) async throws -> Void)?
    /// Final synchronous cancellation/binding check after every preflight and
    /// persistence await, at the point where a turn is about to be submitted.
    var submissionFence: (@MainActor (CodexTaskCommand) throws -> Void)?
    /// A newly started native thread can be live before it has a rollout to
    /// resume. The owner may supply its generation-bound, validated start
    /// response; persisted threads still use native thread/resume.
    var threadPreparation: (@MainActor (CodexTaskCommand, CodexAppServerConnection) async throws -> CodexJSONValue)?

    private let store: any CodexTaskQueueStoring
    let pool: CodexAppServerPool
    private let handoffStore: any CodexConversationHandoffStoring
    private let handoffPollIntervalNanoseconds: UInt64
    private let handoffPhaseTimeout: TimeInterval
    private let monitorIntervalNanoseconds: UInt64
    private var activityProbe: (any CodexThreadActivityProbing)?
    private var monitorTask: Task<Void, Never>?
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var idleGates: [CodexTaskTarget: CodexIdleDispatchGate] = [:]
    private var processingTargets: Set<CodexTaskTarget> = []
    lazy var handoffs = CodexConversationHandoffCoordinator(
        delivery: self,
        pool: pool,
        store: handoffStore,
        pollIntervalNanoseconds: handoffPollIntervalNanoseconds,
        phaseTimeout: handoffPhaseTimeout
    )

    init(
        store: any CodexTaskQueueStoring = CodexTaskQueueStore(),
        pool: CodexAppServerPool = CodexAppServerPool(),
        handoffStore: any CodexConversationHandoffStoring = CodexConversationHandoffStore(),
        handoffPollIntervalNanoseconds: UInt64 = 100_000_000,
        handoffPhaseTimeout: TimeInterval = 20 * 60,
        activityProbe: (any CodexThreadActivityProbing)? = nil,
        monitorIntervalNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.store = store
        self.pool = pool
        self.handoffStore = handoffStore
        self.handoffPollIntervalNanoseconds = handoffPollIntervalNanoseconds
        self.handoffPhaseTimeout = handoffPhaseTimeout
        self.activityProbe = activityProbe
        self.monitorIntervalNanoseconds = monitorIntervalNanoseconds
    }

    func activate(probeExecutablePath: String) async {
        if activityProbe == nil {
            activityProbe = CodexCLIThreadActivityProbe(
                executablePath: probeExecutablePath
            )
        }
        guard !isReady else { return }
        do {
            let recovered = try await store.load()
            queueItems = recovered
            publishDurableQueue(recovered)
            isReady = true
            lastError = nil
            await handoffs.activate()
            startMonitor()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setActivityProbeForTesting(
        _ probe: any CodexThreadActivityProbing
    ) {
        activityProbe = probe
    }

    func deactivate() async {
        await handoffs.deactivate()
        monitorTask?.cancel()
        monitorTask = nil
        for task in eventTasks.values {
            task.cancel()
        }
        eventTasks.removeAll()
        await pool.stopAll()
        isReady = false
    }

    @discardableResult
    func submit(
        commandID: UUID = UUID(),
        homeID: String,
        homePath: String,
        sourceThreadID: String,
        targetThreadID: String,
        cardType: CodexTaskCardType,
        text: String
    ) async -> UUID? {
        guard requireReadyForSubmission() else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              cardType.canDispatchThroughCodex,
              !queueItems.contains(where: { $0.id == commandID }) else {
            return nil
        }

        let command = CodexTaskCommand(
            id: commandID,
            homeID: homeID,
            homePath: homePath,
            threadID: targetThreadID,
            sourceThreadID: sourceThreadID,
            cardType: cardType,
            text: trimmed
        )
        let item = CodexTaskQueueItem(command: command)
        queueItems.append(item)
        do {
            try await saveQueueSnapshot()
            lastError = nil
        } catch {
            queueItems.removeAll { $0.id == commandID }
            lastError =
                "Command was not queued because persistence failed: \(error.localizedDescription)"
            return nil
        }

        let target = CodexTaskTarget(
            homePath: homePath,
            threadID: targetThreadID
        )
        if let liveState = liveStates[target],
           let turnID = liveState.ownership?.managerTurnID(
               on: liveState.connectionID
           ),
           turnID == liveState.activeTurnID {
            await dispatchSteer(itemID: command.id, turnID: turnID)
        } else {
            await setState(
                itemID: command.id,
                state: .waiting,
                phase: .queued,
                error: nil
            )
        }
        return command.id
    }

    /// Enqueues an exact, separately owned turn. Unlike smart delivery, this
    /// path never steers an active Manager turn.
    @discardableResult
    func submitFreshTurn(
        commandID: UUID,
        homeID: String,
        homePath: String,
        sourceThreadID: String,
        targetThreadID: String,
        cardType: CodexTaskCardType,
        text: String
    ) async -> UUID? {
        guard requireReadyForSubmission() else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              cardType.canDispatchThroughCodex,
              !queueItems.contains(where: { $0.id == commandID }) else {
            return nil
        }
        let command = CodexTaskCommand(
            id: commandID,
            homeID: homeID,
            homePath: homePath,
            threadID: targetThreadID,
            sourceThreadID: sourceThreadID,
            cardType: cardType,
            text: trimmed,
            strategy: .freshTurn
        )
        queueItems.append(CodexTaskQueueItem(
            command: command,
            state: .waiting,
            lastError: "Waiting for a safe idle start."
        ))
        do {
            try await saveQueueSnapshot()
            lastError = nil
            return commandID
        } catch {
            queueItems.removeAll { $0.id == commandID }
            lastError =
                "Fresh-turn command was not queued because persistence failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Persists the entire automatic batch before any RPC can be sent.
    /// Every step has its own command ID and is always delivered as a fresh
    /// turn after the exact previous step reports successful completion.
    @discardableResult
    func submitRepeated(
        homeID: String,
        homePath: String,
        sourceThreadID: String,
        targetThreadID: String,
        cardType: CodexTaskCardType,
        text: String,
        repeatCount: Int
    ) async -> UUID? {
        guard requireReadyForSubmission() else { return nil }
        guard cardType.canDispatchThroughCodex,
              let prompt = CodexSerialBatchPolicy.normalizedPrompt(
                text,
                repeatCount: repeatCount
              ) else {
            return nil
        }

        let batchID = UUID()
        let createdAt = Date()
        let items = (0 ..< repeatCount).map { ordinal in
            let command = CodexTaskCommand(
                homeID: homeID,
                homePath: homePath,
                threadID: targetThreadID,
                sourceThreadID: sourceThreadID,
                cardType: cardType,
                text: prompt,
                strategy: .serialBatch,
                batch: CodexTaskBatchPosition(
                    batchID: batchID,
                    ordinal: ordinal,
                    count: repeatCount
                ),
                createdAt: createdAt
            )
            return CodexTaskQueueItem(
                command: command,
                state: .waiting,
                stateChangedAt: createdAt,
                lastError: ordinal == 0
                    ? "Waiting for a safe idle start."
                    : "Waiting for automatic step \(ordinal)/\(repeatCount) to complete."
            )
        }

        queueItems.append(contentsOf: items)
        do {
            try await saveQueueSnapshot()
            lastError = nil
            return batchID
        } catch {
            queueItems.removeAll {
                $0.command.batch?.batchID == batchID
            }
            lastError =
                "Automatic batch was not queued because persistence failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func requireReadyForSubmission() -> Bool {
        guard isReady else {
            lastError =
                "Codex task queue is still being restored; no command was accepted or sent."
            return false
        }
        return true
    }

    func cancelQueuedCommand(_ id: UUID) async {
        guard let index = queueItems.firstIndex(where: { $0.id == id }),
              [.queued, .waiting].contains(queueItems[index].state) else {
            return
        }
        queueItems[index].state = .cancelled
        queueItems[index].stateChangedAt = Date()
        queueItems[index].lastError = "Cancelled before delivery."
        await persistQueue()
    }

    /// Stops every not-yet-delivered step. An already running turn is left
    /// untouched; when it finishes, no further automatic step will start.
    func cancelPendingBatch(_ batchID: UUID) async {
        var changed = false
        for index in queueItems.indices
            where queueItems[index].command.batch?.batchID == batchID
                && [.queued, .waiting].contains(queueItems[index].state) {
            queueItems[index].state = .cancelled
            queueItems[index].stateChangedAt = Date()
            queueItems[index].lastError =
                "Remaining automatic steps were cancelled by the user."
            changed = true
        }
        if changed { await persistQueue() }
    }

    func liveState(
        homePath: String,
        threadID: String
    ) -> CodexThreadLiveState {
        let target = CodexTaskTarget(
            homePath: homePath,
            threadID: threadID
        )
        return liveStates[target] ?? CodexThreadLiveState(target: target)
    }

    func latestQueueItem(
        homePath: String,
        threadID: String
    ) -> CodexTaskQueueItem? {
        queueItems
            .filter {
                $0.command.homePath == homePath
                    && $0.command.threadID == threadID
            }
            .max { $0.command.createdAt < $1.command.createdAt }
    }

    func resolveApproval(
        _ approval: CodexPendingApproval,
        homePath: String,
        decision: CodexApprovalDecision,
        answers: [String: [String]] = [:],
        mcpContent: CodexJSONValue? = nil
    ) async {
        let target = CodexTaskTarget(
            homePath: homePath,
            threadID: approval.threadID
        )
        guard liveStates[target]?.pendingApproval?.matches(approval) == true else {
            lastError = "Approvals must be resolved in the order they arrived."
            return
        }
        let connection = await pool.connection(for: homePath)
        guard await connection.connectionID() == approval.connectionID else {
            lastError =
                "This approval belongs to an expired app-server connection and was not sent."
            return
        }
        do {
            let result = try CodexApprovalResponseBuilder.result(
                for: approval,
                decision: decision,
                answers: answers,
                mcpContent: mcpContent
            )
            try await connection.respond(
                to: approval.id,
                result: result,
                expectedConnectionID: approval.connectionID
            )
            clearApproval(
                approval,
                homePath: homePath,
                summary: decision == .decline || decision == .cancel
                    ? "Request declined by user"
                    : "Request approved by user"
            )
            await persistQueue()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rejectUnsupportedApproval(
        _ approval: CodexPendingApproval,
        homePath: String
    ) async {
        let target = CodexTaskTarget(
            homePath: homePath,
            threadID: approval.threadID
        )
        guard liveStates[target]?.pendingApproval?.matches(approval) == true else {
            lastError = "Approvals must be rejected in the order they arrived."
            return
        }
        let connection = await pool.connection(for: homePath)
        guard await connection.connectionID() == approval.connectionID else {
            lastError = "The approval connection expired."
            return
        }
        do {
            try await connection.respondError(
                to: approval.id,
                code: -32601,
                message: "HarvisBar does not support this request type.",
                expectedConnectionID: approval.connectionID
            )
            clearApproval(
                approval,
                homePath: homePath,
                summary: "Unsupported request rejected"
            )
            await persistQueue()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task {
            while !Task.isCancelled {
                await processWaitingCommands()
                do {
                    try await Task.sleep(
                        nanoseconds: monitorIntervalNanoseconds
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func processWaitingCommands() async {
        guard let activityProbe else { return }
        let candidates = queueItems
            .filter { [.queued, .waiting].contains($0.state) }
            .sorted { lhs, rhs in
                if lhs.command.createdAt != rhs.command.createdAt {
                    return lhs.command.createdAt < rhs.command.createdAt
                }
                let lhsOrdinal = lhs.command.batch?.ordinal ?? -1
                let rhsOrdinal = rhs.command.batch?.ordinal ?? -1
                if lhsOrdinal != rhsOrdinal {
                    return lhsOrdinal < rhsOrdinal
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var seenTargets: Set<CodexTaskTarget> = []

        for candidate in candidates {
            switch CodexSerialBatchPolicy.predecessorDecision(
                for: candidate,
                in: queueItems
            ) {
            case .ready:
                break
            case let .waiting(reason):
                await setState(
                    itemID: candidate.id,
                    state: .waiting,
                    phase: .queued,
                    error: reason
                )
                continue
            case let .stop(reason):
                await setState(
                    itemID: candidate.id,
                    state: .cancelled,
                    phase: .queued,
                    error: reason
                )
                continue
            }

            let target = CodexTaskTarget(
                homePath: candidate.command.homePath,
                threadID: candidate.command.threadID
            )
            guard seenTargets.insert(target).inserted,
                  !processingTargets.contains(target) else {
                continue
            }

            if let state = liveStates[target],
               let turnID = state.ownership?.managerTurnID(
                   on: state.connectionID
               ),
               turnID == state.activeTurnID {
                if candidate.command.strategy == .smart {
                    await dispatchSteer(itemID: candidate.id, turnID: turnID)
                } else {
                    await setState(
                        itemID: candidate.id,
                        state: .waiting,
                        phase: .queued,
                        error: "This command requires a fresh turn and is waiting for the active turn to complete."
                    )
                }
                continue
            }

            do {
                let running = try await activityProbe.isThreadRunning(
                    homePath: target.homePath,
                    threadID: target.threadID
                )
                var gate = idleGates[target] ?? CodexIdleDispatchGate()
                gate.observe(successfulIdle: !running)
                idleGates[target] = gate
                if running {
                    await setState(
                        itemID: candidate.id,
                        state: .waiting,
                        phase: .queued,
                        error: "Another client is running this task. Delivery is queued."
                    )
                    continue
                }
                guard gate.consecutiveIdleObservations >= 2 else {
                    await setState(
                        itemID: candidate.id,
                        state: .waiting,
                        phase: .queued,
                        error: "Waiting for a second consecutive idle check."
                    )
                    continue
                }

                let finalRunning = try await activityProbe.isThreadRunning(
                    homePath: target.homePath,
                    threadID: target.threadID
                )
                guard gate.permitsDispatch(finalSuccessfulIdle: !finalRunning) else {
                    idleGates[target]?.reset()
                    await setState(
                        itemID: candidate.id,
                        state: .waiting,
                        phase: .queued,
                        error: "The task became active during the final delivery check."
                    )
                    continue
                }
                idleGates[target]?.reset()
                await dispatchStart(itemID: candidate.id)
            } catch {
                idleGates[target]?.reset()
                await setState(
                    itemID: candidate.id,
                    state: .waiting,
                    phase: .queued,
                    error: "Activity probe failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func dispatchStart(itemID: UUID) async {
        guard let item = queueItems.first(where: { $0.id == itemID }) else {
            return
        }
        let target = CodexTaskTarget(
            homePath: item.command.homePath,
            threadID: item.command.threadID
        )
        guard processingTargets.insert(target).inserted else { return }
        defer { processingTargets.remove(target) }

        let connection = await pool.connection(
            for: item.command.homePath
        )
        ensureEventSubscription(
            homePath: item.command.homePath,
            connection: connection
        )

        var turnRequestStarted = false
        do {
            let connectionID = try await connection.connect()
            guard await setDispatching(
                itemID: itemID,
                phase: .resume,
                connectionID: connectionID,
                rpcMethod: "thread/resume"
            ) else { return }

            let resumed: CodexJSONValue
            if let threadPreparation {
                resumed = try await threadPreparation(item.command, connection)
            } else {
                resumed = try await connection.request(
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(item.command.threadID),
                        "approvalsReviewer": .string("user"),
                    ])
                )
            }

            try await submissionValidator?(item.command, resumed)
            guard await connection.connectionID() == connectionID else {
                throw CodexAppServerError.connectionClosed("Connection changed before turn submission; no turn was sent.")
            }

            guard await setDispatching(
                itemID: itemID,
                phase: .start,
                connectionID: connectionID,
                rpcMethod: "turn/start"
            ) else { return }
            try submissionFence?(item.command)
            turnRequestStarted = true
            let result = try await connection.request(
                method: "turn/start",
                params: .object([
                    "threadId": .string(item.command.threadID),
                    "input": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(item.command.text),
                        ]),
                    ]),
                    "clientUserMessageId": .string(item.command.id.uuidString),
                    "approvalsReviewer": .string("user"),
                ])
            )
            guard await connection.connectionID() == connectionID else {
                throw CodexAppServerError.deliveryUncertain(
                    method: "turn/start",
                    reason: "connection lifecycle changed after response"
                )
            }
            guard let turnID = result["turn"]?["id"]?.stringValue else {
                throw CodexAppServerError.deliveryUncertain(
                    method: "turn/start",
                    reason: "response did not contain an exact turn id"
                )
            }

            let ownership = CodexTurnOwnership.manager(
                turnID: turnID,
                connectionID: connectionID
            )
            let earlyTurnStatus: String?
            if liveStates[target]?.lastCompletedTurnID == turnID {
                earlyTurnStatus = liveStates[target]?.lastCompletedTurnStatus
            } else {
                earlyTurnStatus = nil
            }
            if let index = queueItems.firstIndex(where: { $0.id == itemID }) {
                queueItems[index].state = earlyTurnStatus.map {
                    deliveryState(forTurnStatus: $0)
                } ?? .running
                queueItems[index].stateChangedAt = Date()
                queueItems[index].ownership = ownership
                queueItems[index].connectionID = connectionID
                queueItems[index].dispatchPhase = .start
                queueItems[index].lastError = earlyTurnStatus.flatMap {
                    $0 == "completed" ? nil : "Turn \($0)"
                }
            }
            var state = liveStates[target] ?? CodexThreadLiveState(target: target)
            state.connectionID = connectionID
            if let earlyTurnStatus {
                state.status = .idle
                state.activeTurnID = nil
                state.ownership = .external(turnID: nil)
                state.append(CodexLiveEvent(
                    kind: earlyTurnStatus == "completed" ? .turn : .error,
                    summary: "Manager reconciled an early \(earlyTurnStatus) notification",
                    turnID: turnID
                ))
            } else {
                state.status = .active
                if state.activeTurnID != turnID {
                    state.finalSummary = nil
                    state.currentToolSummary = nil
                }
                state.activeTurnID = turnID
                state.ownership = ownership
                state.append(CodexLiveEvent(
                    kind: .turn,
                    summary: "Manager started turn \(turnID)",
                    turnID: turnID
                ))
            }
            liveStates[target] = state
            await persistQueue()
        } catch is CancellationError {
            if !turnRequestStarted {
                await setState(itemID: itemID, state: .cancelled, phase: .start,
                    error: "Cancelled before turn submission.")
            } else {
                await handleDispatchFailure(itemID: itemID, method: "turn/start",
                    error: CodexAppServerError.deliveryUncertain(method: "turn/start",
                        reason: "submission was cancelled after entering the native request"))
            }
        } catch {
            await handleDispatchFailure(
                itemID: itemID,
                method: "turn/start",
                error: error
            )
        }
    }

    private func dispatchSteer(
        itemID: UUID,
        turnID: String
    ) async {
        guard let item = queueItems.first(where: { $0.id == itemID }) else {
            return
        }
        let target = CodexTaskTarget(
            homePath: item.command.homePath,
            threadID: item.command.threadID
        )
        guard processingTargets.insert(target).inserted else { return }
        defer { processingTargets.remove(target) }

        let connection = await pool.connection(for: item.command.homePath)
        ensureEventSubscription(
            homePath: item.command.homePath,
            connection: connection
        )
        guard let connectionID = await connection.connectionID(),
              liveStates[target]?.ownership?.managerTurnID(
                  on: connectionID
              ) == turnID else {
            if var state = liveStates[target] {
                state.ownership = .external(turnID: state.activeTurnID)
                liveStates[target] = state
            }
            await setState(
                itemID: itemID,
                state: .waiting,
                phase: .queued,
                error: "Manager ownership expired; waiting for a safe idle start."
            )
            return
        }

        guard await setDispatching(
            itemID: itemID,
            phase: .steer,
            connectionID: connectionID,
            rpcMethod: "turn/steer"
        ) else { return }
        do {
            let result = try await connection.request(
                method: "turn/steer",
                params: .object([
                    "threadId": .string(item.command.threadID),
                    "expectedTurnId": .string(turnID),
                    "input": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(item.command.text),
                        ]),
                    ]),
                    "clientUserMessageId": .string(item.command.id.uuidString),
                ])
            )
            guard await connection.connectionID() == connectionID,
                  result["turnId"]?.stringValue == turnID else {
                throw CodexAppServerError.deliveryUncertain(
                    method: "turn/steer",
                    reason: "turn id or connection lifecycle did not match"
                )
            }
            if let index = queueItems.firstIndex(where: { $0.id == itemID }) {
                queueItems[index].state = .running
                queueItems[index].stateChangedAt = Date()
                queueItems[index].ownership = .manager(
                    turnID: turnID,
                    connectionID: connectionID
                )
                queueItems[index].lastError = nil
            }
            var state = liveStates[target] ?? CodexThreadLiveState(target: target)
            state.append(CodexLiveEvent(
                kind: .turn,
                summary: "Manager steered the active turn",
                turnID: turnID
            ))
            liveStates[target] = state
            await persistQueue()
        } catch let error as CodexAppServerError {
            if case .rpc = error {
                if var state = liveStates[target] {
                    state.ownership = .external(turnID: state.activeTurnID)
                    liveStates[target] = state
                }
                await setState(
                    itemID: itemID,
                    state: .waiting,
                    phase: .queued,
                    error: "Steer precondition failed; queued for a safe idle start."
                )
            } else {
                await handleDispatchFailure(
                    itemID: itemID,
                    method: "turn/steer",
                    error: error
                )
            }
        } catch {
            await handleDispatchFailure(
                itemID: itemID,
                method: "turn/steer",
                error: error
            )
        }
    }

    private func setDispatching(
        itemID: UUID,
        phase: CodexDispatchPhase,
        connectionID: UUID,
        rpcMethod: String
    ) async -> Bool {
        guard let index = queueItems.firstIndex(where: { $0.id == itemID }) else {
            return false
        }
        let item = queueItems[index]
        switch phase {
        case .resume, .steer:
            guard [.queued, .waiting].contains(item.state) else {
                return false
            }
            if phase == .resume,
               item.command.strategy == .serialBatch,
               CodexSerialBatchPolicy.predecessorDecision(
                for: item,
                in: queueItems
               ) != .ready {
                return false
            }
        case .start:
            guard item.state == .dispatching,
                  item.dispatchPhase == .resume,
                  item.connectionID == connectionID else {
                return false
            }
        case .queued:
            return false
        }
        queueItems[index].state = .dispatching
        queueItems[index].stateChangedAt = Date()
        queueItems[index].connectionID = connectionID
        queueItems[index].dispatchPhase = phase
        queueItems[index].lastError = nil
        do {
            try await saveQueueSnapshot()
            lastError = nil
            return true
        } catch {
            let message =
                "Queue persistence failed before \(rpcMethod); \(rpcMethod) was not sent: \(error.localizedDescription)"
            queueItems[index].state = .failed
            queueItems[index].stateChangedAt = Date()
            queueItems[index].lastError = message
            lastError = message
            // A transient store failure may still allow the terminal failure
            // marker to be persisted. Either way, the RPC remains blocked.
            try? await saveQueueSnapshot()
            return false
        }
    }

    private func setState(
        itemID: UUID,
        state: CodexDeliveryState,
        phase: CodexDispatchPhase,
        error: String?
    ) async {
        guard let index = queueItems.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        // The monitor holds candidate snapshots across suspension points. A
        // cancellation or completion that lands meanwhile is authoritative;
        // a stale candidate must never resurrect a terminal queue item.
        guard !queueItems[index].state.isTerminal else { return }
        let changed = queueItems[index].state != state
            || queueItems[index].dispatchPhase != phase
            || queueItems[index].lastError != error
        guard changed else { return }
        queueItems[index].state = state
        queueItems[index].stateChangedAt = Date()
        queueItems[index].dispatchPhase = phase
        queueItems[index].lastError = error
        await persistQueue()
    }

    private func handleDispatchFailure(
        itemID: UUID,
        method: String,
        error: Error
    ) async {
        let state: CodexDeliveryState
        if case CodexAppServerError.deliveryUncertain = error {
            state = .deliveryUnknown
        } else {
            state = .failed
        }
        await setState(
            itemID: itemID,
            state: state,
            phase: method == "turn/steer" ? .steer : .start,
            error: error.localizedDescription
        )
    }

    private func ensureEventSubscription(
        homePath: String,
        connection: CodexAppServerConnection
    ) {
        guard eventTasks[homePath] == nil else { return }
        eventTasks[homePath] = Task {
            let stream = await connection.events()
            for await event in stream {
                if Task.isCancelled { return }
                await handle(event, homePath: homePath)
            }
        }
    }

    private func handle(
        _ event: CodexAppServerEvent,
        homePath: String
    ) async {
        switch event {
        case let .connected(connectionID):
            for target in Array(liveStates.keys) where target.homePath == homePath {
                liveStates[target]?.connectionID = connectionID
                liveStates[target]?.append(CodexLiveEvent(
                    kind: .connection,
                    summary: "Codex app-server connected"
                ))
            }

        case let .disconnected(connectionID, reason):
            for target in Array(liveStates.keys) where
                target.homePath == homePath
                    && liveStates[target]?.connectionID == connectionID {
                if case let .manager(turnID, _) = liveStates[target]?.ownership {
                    liveStates[target]?.ownership = .external(turnID: turnID)
                }
                liveStates[target]?.connectionID = nil
                liveStates[target]?.status = .disconnected
                liveStates[target]?.clearPendingApprovals()
                liveStates[target]?.append(CodexLiveEvent(
                    kind: .connection,
                    summary: "Disconnected: \(reason)"
                ))
            }
            var changed = false
            for index in queueItems.indices
                where queueItems[index].connectionID == connectionID {
                switch queueItems[index].state {
                case .dispatching:
                    queueItems[index].state = .deliveryUnknown
                    queueItems[index].lastError =
                        "Connection closed while delivery was in flight."
                    queueItems[index].stateChangedAt = Date()
                    changed = true
                case .running:
                    queueItems[index].state = .deliveryUnknown
                    queueItems[index].lastError =
                        "The app-server connection closed before the delivered turn reported a final result. The command was not resent."
                    queueItems[index].stateChangedAt = Date()
                    changed = true
                case .waitingApproval:
                    queueItems[index].state = .deliveryUnknown
                    queueItems[index].lastError =
                        "The app-server connection closed while a user decision was pending. The request cannot be safely replayed."
                    queueItems[index].stateChangedAt = Date()
                    changed = true
                default:
                    break
                }
                if case let .manager(turnID, _) = queueItems[index].ownership {
                    queueItems[index].ownership = .external(turnID: turnID)
                    changed = true
                }
                queueItems[index].connectionID = nil
            }
            if changed { await persistQueue() }

        case let .standardError(message, connectionID):
            lastError = "app-server \(connectionID.uuidString.prefix(8)): \(message)"

        case let .serverRequest(request, connectionID):
            let queueChanged = handleServerRequest(
                request,
                connectionID: connectionID,
                homePath: homePath
            )
            if queueChanged { await persistQueue() }

        case let .notification(method, params, connectionID):
            let queueChanged = handleNotification(
                method: method,
                params: params,
                connectionID: connectionID,
                homePath: homePath
            )
            if queueChanged { await persistQueue() }
        }
    }

    private func handleServerRequest(
        _ request: CodexServerRequest,
        connectionID: UUID,
        homePath: String
    ) -> Bool {
        let approval = CodexApprovalResponseBuilder.presentation(
            request: request,
            connectionID: connectionID
        )
        guard !approval.threadID.isEmpty else {
            lastError = "app-server approval omitted threadId"
            return false
        }
        let target = CodexTaskTarget(
            homePath: homePath,
            threadID: approval.threadID
        )
        var state = liveStates[target] ?? CodexThreadLiveState(target: target)
        state.connectionID = connectionID
        state.enqueueApproval(approval)
        state.status = state.pendingApproval?.method == "item/tool/requestUserInput"
            ? .waitingUserInput
            : .waitingApproval
        state.append(CodexLiveEvent(
            kind: .approval,
            summary: state.pendingApprovals.count > 1
                ? "Queued approval \(state.pendingApprovals.count): \(approval.title)"
                : approval.title,
            turnID: approval.turnID
        ))
        liveStates[target] = state

        var queueChanged = false
        for index in queueItems.indices
            where queueItems[index].command.homePath == homePath
                && queueItems[index].command.threadID == approval.threadID
                && queueItems[index].state == .running {
            queueItems[index].state = .waitingApproval
            queueItems[index].stateChangedAt = Date()
            queueChanged = true
        }
        return queueChanged
    }

    private func handleNotification(
        method: String,
        params: CodexJSONValue,
        connectionID: UUID,
        homePath: String
    ) -> Bool {
        guard let threadID = params["threadId"]?.stringValue else {
            if method == "error" {
                lastError = params["error"]?["message"]?.stringValue
                    ?? params["message"]?.stringValue
                    ?? "Codex app-server reported an error."
            }
            return false
        }
        var queueChanged = false
        let target = CodexTaskTarget(homePath: homePath, threadID: threadID)
        var state = liveStates[target] ?? CodexThreadLiveState(target: target)
        state.connectionID = connectionID

        switch method {
        case "thread/status/changed":
            let statusType = params["status"]?["type"]?.stringValue ?? "systemError"
            let activeFlags = params["status"]?["activeFlags"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            switch statusType {
            case "idle":
                state.status = .idle
            case "active":
                if activeFlags.contains("waitingOnUserInput") {
                    state.status = .waitingUserInput
                } else if activeFlags.contains("waitingOnApproval") {
                    state.status = .waitingApproval
                } else {
                    state.status = .active
                }
            case "notLoaded":
                state.status = .notLoaded
            default:
                state.status = .systemError
            }
            state.append(CodexLiveEvent(
                kind: .status,
                summary: "Thread status: \(state.status.rawValue)"
            ))

        case "turn/started":
            let turnID = params["turn"]?["id"]?.stringValue
            state.status = .active
            state.activeTurnID = turnID
            state.lastCompletedTurnID = nil
            state.lastCompletedTurnStatus = nil
            if state.ownership?.managerTurnID(on: connectionID) != turnID {
                state.ownership = .external(turnID: turnID)
            }
            state.finalSummary = nil
            state.append(CodexLiveEvent(
                kind: .turn,
                summary: "Turn started",
                turnID: turnID
            ))

        case "turn/completed":
            let turnID = params["turn"]?["id"]?.stringValue
            let turnStatus = params["turn"]?["status"]?.stringValue ?? "unknown"
            state.status = .idle
            state.activeTurnID = nil
            state.lastCompletedTurnID = turnID
            state.lastCompletedTurnStatus = turnStatus
            state.currentToolSummary = nil
            state.clearPendingApprovals()
            state.finalSummary = finalMessage(from: params["turn"]) ?? state.finalSummary
            state.append(CodexLiveEvent(
                kind: turnStatus == "completed" ? .turn : .error,
                summary: "Turn \(turnStatus)",
                turnID: turnID
            ))
            for index in queueItems.indices
                where queueItems[index].command.homePath == homePath
                    && queueItems[index].command.threadID == threadID
                    && queueItems[index].ownership?.managerTurnID(
                        on: connectionID
                    ) == turnID {
                let nextState = deliveryState(
                    forTurnStatus: turnStatus
                )
                let deliveryError = turnStatus == "completed"
                    ? nil
                    : "Turn \(turnStatus)"
                if queueItems[index].state != nextState
                    || queueItems[index].lastError != deliveryError {
                    queueItems[index].state = nextState
                    queueItems[index].stateChangedAt = Date()
                    queueItems[index].lastError = deliveryError
                    queueChanged = true
                }
            }
            state.ownership = .external(turnID: nil)

        case "item/started":
            let item = params["item"] ?? .object([:])
            let itemID = item["id"]?.stringValue
            let summary = itemSummary(item)
            if item["type"]?.stringValue == "fileChange",
               let itemID {
                state.rememberFileChanges(
                    itemID: itemID,
                    changes: CodexApprovalResponseBuilder.fileChanges(
                        from: item
                    )
                )
            }
            if isToolItem(item) {
                state.currentToolSummary = summary
            }
            state.append(CodexLiveEvent(
                kind: isToolItem(item) ? .tool : .message,
                summary: "Started: \(summary)",
                turnID: params["turnId"]?.stringValue,
                itemID: itemID
            ))

        case "item/completed":
            let item = params["item"] ?? .object([:])
            let itemID = item["id"]?.stringValue
            let summary = itemSummary(item)
            if item["type"]?.stringValue == "fileChange",
               let itemID {
                state.rememberFileChanges(
                    itemID: itemID,
                    changes: CodexApprovalResponseBuilder.fileChanges(
                        from: item
                    )
                )
            }
            if isToolItem(item) {
                state.currentToolSummary = nil
            }
            if item["type"]?.stringValue == "agentMessage",
               let text = item["text"]?.stringValue {
                state.finalSummary = String(text.suffix(8_000))
            }
            state.append(CodexLiveEvent(
                kind: isToolItem(item) ? .tool : .message,
                summary: "Completed: \(summary)",
                turnID: params["turnId"]?.stringValue,
                itemID: itemID
            ))

        case "item/agentMessage/delta":
            if let delta = params["delta"]?.stringValue {
                state.finalSummary = String(
                    ((state.finalSummary ?? "") + delta).suffix(8_000)
                )
            }

        case "error":
            let message = params["error"]?["message"]?.stringValue
                ?? params["message"]?.stringValue
                ?? "Unknown turn error"
            state.append(CodexLiveEvent(
                kind: .error,
                summary: message,
                turnID: params["turnId"]?.stringValue
            ))
            lastError = message

        default:
            if method.contains("outputDelta") || method.contains("progress") {
                let summary = params["delta"]?.stringValue
                    ?? params["message"]?.stringValue
                    ?? method
                state.currentToolSummary = String(summary.prefix(1_000))
            }
        }
        liveStates[target] = state
        return queueChanged
    }

    private func deliveryState(
        forTurnStatus status: String
    ) -> CodexDeliveryState {
        status == "completed" ? .completed : .failed
    }

    private func itemSummary(_ item: CodexJSONValue) -> String {
        let type = item["type"]?.stringValue ?? "item"
        let detail = item["command"]?.stringValue
            ?? item["path"]?.stringValue
            ?? item["server"]?.stringValue
            ?? item["tool"]?.stringValue
            ?? item["text"]?.stringValue
        guard let detail,
              !detail.isEmpty else {
            return type
        }
        return "\(type): \(detail.prefix(300))"
    }

    private func isToolItem(_ item: CodexJSONValue) -> Bool {
        guard let type = item["type"]?.stringValue else { return false }
        return [
            "commandExecution",
            "fileChange",
            "mcpToolCall",
            "dynamicToolCall",
            "collabAgentToolCall",
        ].contains(type)
    }

    private func finalMessage(
        from turn: CodexJSONValue?
    ) -> String? {
        let items = turn?["items"]?.arrayValue ?? []
        for item in items.reversed()
            where item["type"]?.stringValue == "agentMessage" {
            if let text = item["text"]?.stringValue, !text.isEmpty {
                return String(text.suffix(8_000))
            }
        }
        return nil
    }

    private func clearApproval(
        _ approval: CodexPendingApproval,
        homePath: String,
        summary: String
    ) {
        let target = CodexTaskTarget(
            homePath: homePath,
            threadID: approval.threadID
        )
        guard var state = liveStates[target],
              state.dequeueApproval(matching: approval) else {
            return
        }
        if let next = state.pendingApproval {
            state.status = next.method == "item/tool/requestUserInput"
                ? .waitingUserInput
                : .waitingApproval
        } else {
            state.status = .active
        }
        state.append(CodexLiveEvent(
            kind: .approval,
            summary: summary,
            turnID: approval.turnID
        ))
        liveStates[target] = state
        for index in queueItems.indices
            where queueItems[index].command.homePath == homePath
                && queueItems[index].command.threadID == approval.threadID
                && queueItems[index].state == .waitingApproval {
            queueItems[index].state = state.pendingApproval == nil
                ? .running
                : .waitingApproval
            queueItems[index].stateChangedAt = Date()
        }
    }

    private func persistQueue() async {
        do {
            try await saveQueueSnapshot()
            lastError = nil
        } catch {
            lastError = "Queue persistence failed: \(error.localizedDescription)"
        }
    }

    /// Captures the exact value sent to the actor store. Because the await can
    /// yield the MainActor, publishing `queueItems` after the call would risk
    /// exposing a newer, not-yet-persisted mutation as durable evidence.
    private func saveQueueSnapshot() async throws {
        let snapshot = queueItems
        try await store.save(snapshot)
        publishDurableQueue(snapshot)
    }

    private func publishDurableQueue(
        _ snapshot: [CodexTaskQueueItem]
    ) {
        durableQueueItems = snapshot
        durableQueueRevision &+= 1
    }
}
