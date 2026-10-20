import Foundation

enum ConversationManagementLedgerEventKindV1: String, Codable, Sendable {
    case planningStarted
    case planningFailed
    case proposalAccepted
    case deliveryChanged
    case evidenceObserved
    case paused
    case resumed
    case cancelled
    case recovered
}

struct ConversationManagementProgressEntryV1: Codable, Equatable, Sendable {
    let revision: Int
    let cycle: Int
    let kind: ConversationManagementLedgerEventKindV1
    let decisionID: UUID?
    let target: ConversationManagementTargetV1?
    let commandID: UUID?
    let planningRPCID: String?
    let state: ConversationManagementResolvedStateV1
    let instructionFingerprint: String?
    let note: String?
    let timestamp: Date
}

/// Records a prompt only when dispatch is durably marked in flight. A proposal
/// shown in preview is not delivery and therefore does not enter this memory.
struct ConversationManagementDispatchMemoryV1: Codable, Equatable, Sendable {
    let target: ConversationManagementTargetV1
    let decisionID: UUID
    let instructionFingerprint: String
    let evidenceRevision: Int
    let commandID: UUID
    let recordedAt: Date
}

struct ConversationManagementProgressLedgerV1: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let projectID: String
    let objective: String
    private(set) var revision: Int
    private(set) var cycle: Int
    private(set) var metaSessionID: String?
    private(set) var planningRPCID: String?
    private(set) var currentState: ConversationManagementResolvedStateV1
    private(set) var latestProposal: ConversationManagementProposalV1?
    private(set) var dispatchMemory: [ConversationManagementDispatchMemoryV1]
    private(set) var entries: [ConversationManagementProgressEntryV1]
    let createdAt: Date
    private(set) var updatedAt: Date

    init(
        schemaVersion: Int = ConversationManagementSchemaV1.version,
        runID: UUID = UUID(),
        projectID: String,
        objective: String,
        revision: Int = 0,
        cycle: Int = 0,
        metaSessionID: String? = nil,
        planningRPCID: String? = nil,
        currentState: ConversationManagementResolvedStateV1? = nil,
        latestProposal: ConversationManagementProposalV1? = nil,
        dispatchMemory: [ConversationManagementDispatchMemoryV1] = [],
        entries: [ConversationManagementProgressEntryV1] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.projectID = projectID
        self.objective = objective
        self.revision = revision
        self.cycle = cycle
        self.metaSessionID = metaSessionID
        self.planningRPCID = planningRPCID
        self.currentState = currentState
            ?? ConversationManagementResolvedStateV1(
                delivery: .none,
                runtime: .unknown,
                management: .observing,
                progress: .unknown,
                evidence: .none
            )
        self.latestProposal = latestProposal
        self.dispatchMemory = dispatchMemory
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    mutating func startPlanning(
        metaSessionID: String,
        planningRPCID: String,
        expectedRevision: Int,
        at now: Date = Date()
    ) throws {
        try requireRevision(expectedRevision)
        try requireMutable()
        guard !metaSessionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "metaSessionID",
                reason: "must be nonempty"
            )
        }
        guard !planningRPCID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "planningRPCID",
                reason: "must be nonempty"
            )
        }
        guard !currentState.delivery.isRestartAmbiguous else {
            throw ConversationManagementSchemaErrorV1.invalidTransition(
                from: currentState.delivery.rawValue,
                to: ConversationManagementStateV1.planning.rawValue
            )
        }
        guard currentState.management != .paused else {
            throw ConversationManagementSchemaErrorV1.invalidTransition(
                from: currentState.management.rawValue,
                to: ConversationManagementStateV1.planning.rawValue
            )
        }

        self.metaSessionID = metaSessionID
        self.planningRPCID = planningRPCID
        currentState = replacingState(management: .planning)
        append(
            kind: .planningStarted,
            planningRPCID: planningRPCID,
            note: nil,
            at: now
        )
    }

    mutating func accept(
        proposal: ConversationManagementProposalV1,
        snapshot: ConversationManagementSnapshotV1,
        policy: ConversationManagementValidationPolicyV1,
        expectedRevision: Int,
        at now: Date = Date()
    ) throws {
        try requireRevision(expectedRevision)
        try requireMutable()
        guard currentState.management == .planning else {
            throw ConversationManagementSchemaErrorV1.invalidTransition(
                from: currentState.management.rawValue,
                to: ConversationManagementStateV1.awaitingPreview.rawValue
            )
        }
        try ConversationManagementSchemaValidatorV1.validate(
            proposal: proposal,
            snapshot: snapshot,
            ledger: self,
            policy: policy
        )

        let decision = proposal.decisions[0]
        guard !entries.contains(where: { $0.decisionID == decision.id }) else {
            throw ConversationManagementSchemaErrorV1.invalidDecision(
                decision.id,
                "decision id must be unique across management cycles"
            )
        }

        cycle = proposal.cycle
        latestProposal = proposal
        switch decision.kind {
        case .dispatch, .recommendHandoff:
            currentState = replacingState(
                delivery: ConversationDeliveryStateV1.none,
                management: .awaitingPreview
            )
        case .needsUser:
            currentState = replacingState(
                delivery: ConversationDeliveryStateV1.none,
                management: .waitingUserInput
            )
        case .complete:
            currentState = ConversationManagementResolvedStateV1(
                delivery: currentState.delivery,
                runtime: currentState.runtime,
                management: .completed,
                progress: ConversationProgressProjectionV1(
                    phase: .completed,
                    completedUnitCount: currentState.progress.completedUnitCount,
                    totalUnitCount: currentState.progress.totalUnitCount,
                    summary: proposal.summary,
                    updatedAt: now
                ),
                evidence: currentState.evidence
            )
        }
        append(
            kind: .proposalAccepted,
            decisionID: decision.id,
            target: decision.target,
            planningRPCID: planningRPCID,
            note: proposal.summary,
            at: now
        )
    }

    /// Records a definitive planning rejection or an ambiguous prompt delivery.
    /// `deliveryUnknown` is terminal for this run and must never be replayed.
    mutating func recordPlanningFailure(
        delivery: ConversationDeliveryStateV1,
        expectedRevision: Int,
        note: String,
        at now: Date = Date()
    ) throws {
        try requireRevision(expectedRevision)
        try requireMutable()
        guard currentState.management == .planning,
              delivery == .failed || delivery == .deliveryUnknown else {
            throw ConversationManagementSchemaErrorV1.invalidTransition(
                from: currentState.management.rawValue,
                to: delivery.rawValue
            )
        }
        currentState = ConversationManagementResolvedStateV1(
            delivery: delivery,
            runtime: delivery == .failed ? .failed : .unknown,
            management: delivery == .failed ? .failed : .deliveryUnknown,
            progress: currentState.progress,
            evidence: currentState.evidence
        )
        append(
            kind: .planningFailed,
            planningRPCID: planningRPCID,
            note: note,
            at: now
        )
    }

    /// Persist this mutation before issuing the provider RPC. In particular,
    /// `.dispatching` pre-allocates and records `commandID`, making a response
    /// loss recover as `deliveryUnknown` instead of a blind resend.
    mutating func recordDelivery(
        decisionID: UUID,
        target: ConversationManagementTargetV1,
        commandID: UUID,
        delivery: ConversationDeliveryStateV1,
        runtime: ConversationRuntimeStateV1? = nil,
        progress: ConversationProgressProjectionV1? = nil,
        evidence: ConversationEvidenceProjectionV1? = nil,
        expectedRevision: Int,
        note: String? = nil,
        at now: Date = Date()
    ) throws {
        try requireRevision(expectedRevision)
        try requireMutable()
        guard let decision = latestProposal?.decisions.first(where: {
            $0.id == decisionID
        }), decision.kind == .dispatch,
              decision.target == target,
              let prompt = decision.prompt else {
            throw ConversationManagementSchemaErrorV1.invalidDecision(
                decisionID,
                "delivery must reference an accepted dispatch decision and exact target"
            )
        }
        try validateDeliveryTransition(
            from: currentState.delivery,
            to: delivery
        )

        let fingerprint = ConversationManagementSchemaValidatorV1
            .instructionFingerprint(prompt)
        if delivery == .dispatching,
           !dispatchMemory.contains(where: { $0.decisionID == decisionID }) {
            dispatchMemory.append(
                ConversationManagementDispatchMemoryV1(
                    target: target,
                    decisionID: decisionID,
                    instructionFingerprint: fingerprint,
                    evidenceRevision: evidence?.revision
                        ?? currentState.evidence.revision,
                    commandID: commandID,
                    recordedAt: now
                )
            )
        }

        currentState = ConversationManagementResolvedStateV1(
            delivery: delivery,
            runtime: runtime ?? runtimeState(for: delivery),
            management: managementState(for: delivery),
            progress: progress ?? currentState.progress,
            evidence: evidence ?? currentState.evidence
        )
        append(
            kind: .deliveryChanged,
            decisionID: decisionID,
            target: target,
            commandID: commandID,
            instructionFingerprint: fingerprint,
            note: note,
            at: now
        )
    }

    mutating func observe(
        runtime: ConversationRuntimeStateV1,
        progress: ConversationProgressProjectionV1,
        evidence: ConversationEvidenceProjectionV1,
        expectedRevision: Int,
        note: String? = nil,
        at now: Date = Date()
    ) throws {
        try requireRevision(expectedRevision)
        try requireMutable()
        guard evidence.revision >= currentState.evidence.revision else {
            throw ConversationManagementSchemaErrorV1.staleRevision(
                expected: evidence.revision,
                actual: currentState.evidence.revision
            )
        }
        currentState = ConversationManagementResolvedStateV1(
            delivery: currentState.delivery,
            runtime: runtime,
            management: currentState.management,
            progress: progress,
            evidence: evidence
        )
        append(kind: .evidenceObserved, note: note, at: now)
    }

    mutating func pause(
        expectedRevision: Int,
        note: String? = nil,
        at now: Date = Date()
    ) throws {
        try requireRevision(expectedRevision)
        try requireMutable()
        guard currentState.management == .observing
                || currentState.management == .awaitingPreview else {
            throw ConversationManagementSchemaErrorV1.invalidTransition(
                from: currentState.management.rawValue,
                to: ConversationManagementStateV1.paused.rawValue
            )
        }
        currentState = replacingState(management: .paused)
        append(kind: .paused, note: note, at: now)
    }

    mutating func resume(
        expectedRevision: Int,
        note: String? = nil,
        at now: Date = Date()
    ) throws {
        try requireRevision(expectedRevision)
        try requireMutable()
        guard currentState.management == .paused else {
            throw ConversationManagementSchemaErrorV1.invalidTransition(
                from: currentState.management.rawValue,
                to: ConversationManagementStateV1.observing.rawValue
            )
        }
        let hasUndeliveredPreview = currentState.delivery == .none
            && latestProposal?.decisions.first.map {
                $0.kind == .dispatch || $0.kind == .recommendHandoff
            } == true
        currentState = replacingState(
            management: hasUndeliveredPreview ? .awaitingPreview : .observing
        )
        append(kind: .resumed, note: note, at: now)
    }

    mutating func cancel(
        expectedRevision: Int,
        note: String? = nil,
        at now: Date = Date()
    ) throws {
        try requireRevision(expectedRevision)
        try requireMutable()
        currentState = ConversationManagementResolvedStateV1(
            delivery: .cancelled,
            runtime: currentState.runtime,
            management: .cancelled,
            progress: currentState.progress,
            evidence: currentState.evidence
        )
        append(kind: .cancelled, note: note, at: now)
    }

    /// Fail closed on restart. This method is intentionally idempotent.
    @discardableResult
    mutating func recoverAfterRestart(at now: Date = Date()) -> Bool {
        guard currentState.delivery.isRestartAmbiguous
                || currentState.management.isRestartAmbiguous else {
            return false
        }
        // A Codex dispatch with a preallocated, durable command ID is
        // reconcilable against the separately persisted Codex queue. Preserve
        // it as nonterminal until that exact lookup runs; never replay it.
        if !dispatchMemory.isEmpty,
           currentState.delivery == .dispatching
                || currentState.delivery == .accepted
                || currentState.delivery == .running
                || currentState.delivery == .waitingApproval {
            return false
        }
        currentState = ConversationManagementResolvedStateV1(
            delivery: .deliveryUnknown,
            runtime: .unknown,
            management: .deliveryUnknown,
            progress: currentState.progress,
            evidence: currentState.evidence
        )
        append(
            kind: .recovered,
            planningRPCID: planningRPCID,
            note: "HarvisBar restarted during an in-flight management step. Delivery was not replayed.",
            at: now
        )
        return true
    }

    private mutating func append(
        kind: ConversationManagementLedgerEventKindV1,
        decisionID: UUID? = nil,
        target: ConversationManagementTargetV1? = nil,
        commandID: UUID? = nil,
        planningRPCID: String? = nil,
        instructionFingerprint: String? = nil,
        note: String? = nil,
        at now: Date
    ) {
        revision += 1
        updatedAt = now
        entries.append(
            ConversationManagementProgressEntryV1(
                revision: revision,
                cycle: cycle,
                kind: kind,
                decisionID: decisionID,
                target: target,
                commandID: commandID,
                planningRPCID: planningRPCID,
                state: currentState,
                instructionFingerprint: instructionFingerprint,
                note: note,
                timestamp: now
            )
        )
    }

    private func replacingState(
        delivery: ConversationDeliveryStateV1? = nil,
        management: ConversationManagementStateV1? = nil
    ) -> ConversationManagementResolvedStateV1 {
        ConversationManagementResolvedStateV1(
            delivery: delivery ?? currentState.delivery,
            runtime: currentState.runtime,
            management: management ?? currentState.management,
            progress: currentState.progress,
            evidence: currentState.evidence
        )
    }

    private func requireRevision(_ expectedRevision: Int) throws {
        guard revision == expectedRevision else {
            throw ConversationManagementSchemaErrorV1.staleRevision(
                expected: expectedRevision,
                actual: revision
            )
        }
    }

    private func requireMutable() throws {
        guard !currentState.management.isTerminal else {
            throw ConversationManagementSchemaErrorV1.terminalLedger
        }
    }

    private func validateDeliveryTransition(
        from: ConversationDeliveryStateV1,
        to: ConversationDeliveryStateV1
    ) throws {
        if from == to { return }
        let allowed: Set<ConversationDeliveryStateV1>
        switch from {
        case .none:
            allowed = [.queued, .dispatching, .failed, .cancelled]
        case .queued:
            allowed = [.dispatching, .failed, .cancelled]
        case .dispatching:
            allowed = [
                .accepted, .running, .waitingApproval, .completed,
                .failed, .deliveryUnknown, .cancelled,
            ]
        case .accepted:
            allowed = [
                .running, .waitingApproval, .completed, .failed,
                .deliveryUnknown, .cancelled,
            ]
        case .running:
            allowed = [
                .waitingApproval, .completed, .failed,
                .deliveryUnknown, .cancelled,
            ]
        case .waitingApproval:
            allowed = [
                .running, .completed, .failed, .deliveryUnknown, .cancelled,
            ]
        case .completed, .failed, .deliveryUnknown, .cancelled:
            allowed = []
        }
        guard allowed.contains(to) else {
            throw ConversationManagementSchemaErrorV1.invalidTransition(
                from: from.rawValue,
                to: to.rawValue
            )
        }
    }

    private func managementState(
        for delivery: ConversationDeliveryStateV1
    ) -> ConversationManagementStateV1 {
        switch delivery {
        case .none: return currentState.management
        case .queued: return .awaitingPreview
        case .dispatching: return .dispatching
        case .accepted, .running: return .monitoring
        case .waitingApproval: return .waitingApproval
        case .completed: return .observing
        case .failed: return .failed
        case .deliveryUnknown: return .deliveryUnknown
        case .cancelled: return .cancelled
        }
    }

    private func runtimeState(
        for delivery: ConversationDeliveryStateV1
    ) -> ConversationRuntimeStateV1 {
        switch delivery {
        case .none, .queued: return currentState.runtime
        case .dispatching, .accepted, .running: return .running
        case .waitingApproval: return .waitingApproval
        case .completed: return .completed
        case .failed: return .failed
        case .deliveryUnknown, .cancelled: return .unknown
        }
    }
}
