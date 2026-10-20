import Combine
import Foundation

extension HarvisRuntimeModel {
    /// Loads the durable management store. Loading never enables a project:
    /// legacy and newly discovered snapshots both default to `brainEnabled == false`.
    func activateConversationManagement() async {
        observeConversationManagementState()
        await managedConversationInsights.activate()
        managedConversationInsightRevision &+= 1
        await dshMetaAgentCoordinator.activate()
        publishConversationManagementSnapshots()
        scheduleConversationManagementDeliveryReconcile()
    }

    /// Stops the in-process coordinator lifecycle without deleting its durable
    /// snapshots or ledgers. The next activation performs normal recovery.
    func deactivateConversationManagement() {
        conversationManagementStateObserver?.cancel()
        conversationManagementStateObserver = nil
        conversationManagementDeliveryObserver?.cancel()
        conversationManagementDeliveryObserver = nil
        conversationManagementReconcileGeneration &+= 1
        conversationManagementReconcileTask?.cancel()
        conversationManagementReconcileTask = nil
        conversationManagementReconcilePending = false
        dshMetaAgentCoordinator.deactivate()
        managedConversationInsights.deactivate()
        managedConversationInsightRevision &+= 1
    }

    func conversationManagementSnapshot(
        for project: ManagedChatProjectIdentity
    ) -> ConversationManagementSnapshotV1? {
        conversationManagementSnapshots[project.id]
            ?? dshMetaAgentCoordinator.snapshot(projectID: project.id)
    }

    func isConversationManagementBrainEnabled(
        for project: ManagedChatProjectIdentity
    ) -> Bool {
        conversationManagementSnapshot(for: project)?.brainEnabled ?? false
    }

    /// Reprojects every currently discovered provider conversation. The input
    /// is deliberately `managedChatThreads`, not a search/filter result from a
    /// view, so hidden cards cannot disappear from management authority.
    func refreshConversationManagementSnapshots(
        additionalProjects: [ManagedChatProjectIdentity] = [],
        at now: Date = Date()
    ) async {
        await dshMetaAgentCoordinator.activate()
        publishConversationManagementSnapshots()
        guard dshMetaAgentCoordinator.isReady else {
            let message = dshMetaAgentCoordinator.lastError
                ?? DshMetaAgentCoordinatorError.notReady.localizedDescription
            for project in additionalProjects {
                conversationManagementErrors[project.id] = message
            }
            return
        }

        let completeThreads = managedChatThreads
        let projects = conversationManagementProjects(
            threads: completeThreads,
            additionalProjects: additionalProjects
        )
        for project in projects {
            guard !Task.isCancelled else { return }
            do {
                let projectionWarning = try await configureConversationManagementSnapshot(
                    project: project,
                    threads: completeThreads,
                    brainEnabled: nil,
                    projectDefaultEnrollmentEnabled: nil,
                    at: now
                )
                if let projectionWarning {
                    conversationManagementErrors[project.id] = projectionWarning
                } else {
                    conversationManagementErrors.removeValue(forKey: project.id)
                }
            } catch {
                conversationManagementErrors[project.id] = clean(
                    error.localizedDescription
                )
            }
        }
    }

    /// Persists the per-project brain switch inside the management snapshot.
    /// A project with no prior snapshot starts disabled until this exact API is
    /// called with `true`.
    func setConversationManagementBrainEnabled(
        _ enabled: Bool,
        for project: ManagedChatProjectIdentity,
        at now: Date = Date()
    ) async throws {
        await dshMetaAgentCoordinator.activate()
        publishConversationManagementSnapshots()
        guard dshMetaAgentCoordinator.isReady else {
            throw DshMetaAgentCoordinatorError.notReady
        }
        let projectionWarning = try await configureConversationManagementSnapshot(
            project: project,
            threads: managedChatThreads,
            brainEnabled: enabled,
            projectDefaultEnrollmentEnabled: nil,
            at: now
        )
        if let projectionWarning {
            conversationManagementErrors[project.id] = projectionWarning
        } else {
            conversationManagementErrors.removeValue(forKey: project.id)
        }
    }

    /// Project-wide enrollment is separate from the brain switch. Keeping the
    /// two switches independent prevents enabling DSH planning from silently
    /// widening the set of dispatchable conversations.
    func setConversationManagementDefaultEnrollmentEnabled(
        _ enabled: Bool,
        for project: ManagedChatProjectIdentity,
        at now: Date = Date()
    ) async throws {
        await dshMetaAgentCoordinator.activate()
        publishConversationManagementSnapshots()
        guard dshMetaAgentCoordinator.isReady else {
            throw DshMetaAgentCoordinatorError.notReady
        }
        let projectionWarning = try await configureConversationManagementSnapshot(
            project: project,
            threads: managedChatThreads,
            brainEnabled: nil,
            projectDefaultEnrollmentEnabled: enabled,
            at: now
        )
        if let projectionWarning {
            conversationManagementErrors[project.id] = projectionWarning
        } else {
            conversationManagementErrors.removeValue(forKey: project.id)
        }
    }

    /// Starts one explicit preview cycle against the exact dedicated DSH
    /// preset. No automatic dispatch mode or preset fallback is exposed here.
    @discardableResult
    func startConversationManagementPreview(
        project: ManagedChatProjectIdentity,
        objective: String,
        endpoint: DshRuntimeEndpoint
    ) async throws -> DshMetaAgentPreview {
        guard endpoint == conversationManagementBrainEndpoint else {
            throw DshMetaAgentCoordinatorError.brainEndpointUnavailable(
                homeID: DshMetaAgentPolicy.dedicatedHomeID,
                profile: DshMetaAgentPolicy.dedicatedProfile
            )
        }
        defer { publishConversationManagementSnapshots() }
        await refreshConversationManagementSnapshots(
            additionalProjects: [project]
        )
        guard let snapshot = conversationManagementSnapshot(for: project) else {
            throw DshMetaAgentCoordinatorError.unknownProject(project.id)
        }
        guard snapshot.brainEnabled else {
            throw ConversationManagementSchemaErrorV1.brainDisabled(project.id)
        }
        guard let projectPath = project.canonicalPath else {
            throw DshMetaAgentCoordinatorError.invalidProjectPath
        }
        let allowedTargets = ConversationManagementProjectorV1.allowedTargets(
            project: project,
            threads: managedChatThreads
        )
        return try await dshMetaAgentCoordinator.startPreview(
            projectID: project.id,
            objective: objective,
            projectPath: projectPath,
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: ConversationManagementValidationPolicyV1(
                allowedTargets: allowedTargets,
                maxDecisions: 1
            )
        )
    }

    /// Resolves only the dedicated, currently running brain endpoint. An
    /// arbitrary DSH endpoint is never selected as a fallback, and ambiguity
    /// fails closed.
    var conversationManagementBrainEndpoint: DshRuntimeEndpoint? {
        let matches = dshRunningEndpoints.filter {
            $0.homeID == DshMetaAgentPolicy.dedicatedHomeID
                && $0.profile == DshMetaAgentPolicy.dedicatedProfile
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    var conversationManagementBrainEndpointError: String? {
        guard conversationManagementBrainEndpoint == nil else { return nil }
        return DshMetaAgentCoordinatorError.brainEndpointUnavailable(
            homeID: DshMetaAgentPolicy.dedicatedHomeID,
            profile: DshMetaAgentPolicy.dedicatedProfile
        ).localizedDescription
    }

    @discardableResult
    func startConversationManagementPreview(
        project: ManagedChatProjectIdentity,
        objective: String
    ) async throws -> DshMetaAgentPreview {
        guard let endpoint = conversationManagementBrainEndpoint else {
            throw DshMetaAgentCoordinatorError.brainEndpointUnavailable(
                homeID: DshMetaAgentPolicy.dedicatedHomeID,
                profile: DshMetaAgentPolicy.dedicatedProfile
            )
        }
        return try await startConversationManagementPreview(
            project: project,
            objective: objective,
            endpoint: endpoint
        )
    }

    /// Converts one approved Meta decision into an exact Codex destination.
    /// Provider display labels and another Home's same-named thread are never
    /// accepted as destination evidence.
    @discardableResult
    func approveConversationManagementProposal(
        project: ManagedChatProjectIdentity,
        runID: UUID,
        decisionID: UUID,
        expectedLedgerRevision: Int? = nil
    ) async throws -> DshMetaAgentDispatchOutcome {
        defer { publishConversationManagementSnapshots() }
        guard let previewSnapshot = conversationManagementSnapshot(for: project) else {
            throw DshMetaAgentCoordinatorError.unknownProject(project.id)
        }
        // The task plan is the sole dispatch authority. Approval bypasses the
        // ordinary refresh throttle and compares the exact raw-source hash that
        // the preview was based on. An unavailable, invalid, or changed source
        // revokes this approval instead of relying on a recently cached plan.
        await refreshProjectTaskPlan(project, force: true)
        let currentPlan = projectTaskPlan(for: project)
        let currentFreshness = projectTaskPlanFreshness(for: project)
        let taskAuthorityUnchanged: Bool
        if currentFreshness.isFresh, let currentPlan {
            taskAuthorityUnchanged = (try? ManagedProjectTaskPlanProjector
                .summary(from: currentPlan)) != nil
                && currentPlan.sourceRevision
                    == previewSnapshot.taskPlan.sourceRevision
        } else {
            taskAuthorityUnchanged = false
        }
        if !taskAuthorityUnchanged {
            await refreshConversationManagementSnapshots(
                additionalProjects: [project]
            )
            switch currentFreshness {
            case .unavailable:
                throw ConversationManagementSchemaErrorV1.taskPlanUnavailable
            case .stale:
                throw ConversationManagementSchemaErrorV1.taskPlanStale
            case .fresh:
                guard currentPlan?.isValid == true,
                      currentPlan?.invalidRecordCount == 0 else {
                    throw ConversationManagementSchemaErrorV1.taskPlanInvalid
                }
                let actual = conversationManagementSnapshot(for: project)?
                    .revision ?? previewSnapshot.revision
                throw ConversationManagementSchemaErrorV1.staleRevision(
                    expected: previewSnapshot.revision,
                    actual: actual
                )
            }
        }
        let snapshot = conversationManagementSnapshot(for: project)
            ?? previewSnapshot
        guard let ledger = dshMetaAgentCoordinator.ledger(runID: runID),
              ledger.projectID == project.id else {
            throw DshMetaAgentCoordinatorError.unknownRun(runID)
        }
        guard let decision = ledger.latestProposal?.decisions.first(where: {
            $0.id == decisionID
        }), decision.kind == .dispatch,
              let target = decision.target else {
            throw DshMetaAgentCoordinatorError.missingDecision(decisionID)
        }

        guard let thread = managedChatThreads.first(where: {
            ConversationManagementProjectorV1.target(for: $0) == target
                && ManagedChatProjectResolver.resolve(thread: $0).id
                    == project.id
        }) else {
            throw ConversationManagementSchemaErrorV1.unknownTarget(
                target.stableID
            )
        }
        guard ConversationManagementProjectorV1.isDispatchEligible(thread),
              let home = codexHome(for: thread),
              home.id == target.sourceScope else {
            throw DshMetaAgentCoordinatorError.unsupportedTarget(
                target.stableID
            )
        }
        let policy = ConversationManagementValidationPolicyV1(
            allowedTargets: ConversationManagementProjectorV1.allowedTargets(
                project: project,
                threads: managedChatThreads
            ),
            maxDecisions: 1
        )
        return try await dshMetaAgentCoordinator.approveProposal(
            runID: runID,
            decisionID: decisionID,
            destination: DshMetaCodexDestination(
                target: target,
                homeID: home.id,
                homePath: expanded(home.path),
                sourceThreadID: thread.sourceID,
                targetThreadID: thread.sourceID,
                cardType: thread.taskCardType
            ),
            policy: policy,
            projectManagementEnabled: snapshot.brainEnabled,
            expectedRevision: expectedLedgerRevision ?? ledger.revision
        )
    }

    /// Ends one exact durable run without guessing from the currently visible
    /// card. This remains available after the brain switch is turned off, so
    /// a user can always close a nonterminal preview explicitly.
    func cancelConversationManagementRun(
        project: ManagedChatProjectIdentity,
        runID: UUID,
        expectedLedgerRevision: Int
    ) async throws {
        await dshMetaAgentCoordinator.activate()
        defer { publishConversationManagementSnapshots() }
        guard let ledger = dshMetaAgentCoordinator.ledger(runID: runID),
              ledger.projectID == project.id else {
            throw DshMetaAgentCoordinatorError.unknownRun(runID)
        }
        try await dshMetaAgentCoordinator.cancel(
            runID: runID,
            expectedRevision: expectedLedgerRevision,
            note: "Ended explicitly from the project management page."
        )
    }

    /// Writes one exact project-task join for one provider conversation. This
    /// is the only runtime path that turns a card into `.task` work; it never
    /// infers a task from a title, tag, thread id, or another Home's card.
    func setConversationManagementPlanBinding(
        for thread: ManagedChatThread,
        project: ManagedChatProjectIdentity,
        workKind: ConversationWorkKindV1,
        taskID: String?,
        includeForDispatch: Bool,
        at now: Date = Date()
    ) async throws {
        await dshMetaAgentCoordinator.activate()
        publishConversationManagementSnapshots()
        guard dshMetaAgentCoordinator.isReady else {
            throw DshMetaAgentCoordinatorError.notReady
        }
        guard ManagedChatProjectResolver.resolve(thread: thread).id
                == project.id else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "projectID",
                reason: "the exact provider conversation belongs to another project"
            )
        }

        let target = ConversationManagementProjectorV1.target(for: thread)
        guard managedChatThreads.contains(where: {
            ConversationManagementProjectorV1.target(for: $0) == target
                && ManagedChatProjectResolver.resolve(thread: $0).id
                    == project.id
        }) else {
            throw ConversationManagementSchemaErrorV1.unknownTarget(
                target.stableID
            )
        }
        guard var snapshot = dshMetaAgentCoordinator.snapshot(
            projectID: project.id
        ) else {
            throw DshMetaAgentCoordinatorError.unknownProject(project.id)
        }
        guard snapshot.brainEnabled else {
            throw ConversationManagementSchemaErrorV1.brainDisabled(project.id)
        }
        if includeForDispatch {
            guard workKind != .unclassified else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "includeForDispatch",
                    reason: "unclassified work cannot be enrolled for dispatch"
                )
            }
            guard ConversationManagementProjectorV1.isDispatchEligible(
                thread
            ) else {
                throw DshMetaAgentCoordinatorError.unsupportedTarget(
                    target.stableID
                )
            }
        }
        guard let recordIndex = snapshot.conversations.firstIndex(where: {
            $0.base.target == target
        }) else {
            throw ConversationManagementSchemaErrorV1.unknownTarget(
                target.stableID
            )
        }

        let bindings: [ConversationTaskBindingV1]
        if workKind == .task {
            guard let taskID,
                  !taskID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskID",
                    reason: "task work requires one exact project task id"
                )
            }
            let taskPlan = snapshot.taskPlan
            switch taskPlan.freshness {
            case .unavailable:
                throw ConversationManagementSchemaErrorV1.taskPlanUnavailable
            case .stale:
                throw ConversationManagementSchemaErrorV1.taskPlanStale
            case .fresh:
                guard taskPlan.isValid, taskPlan.isAuthoritative else {
                    throw ConversationManagementSchemaErrorV1.taskPlanInvalid
                }
            }
            guard let task = taskPlan.task(id: taskID) else {
                throw ConversationManagementSchemaErrorV1.unknownTask(taskID)
            }
            guard task.status.isOpen else {
                throw ConversationManagementSchemaErrorV1.taskNotOpen(taskID)
            }
            bindings = [
                ConversationTaskBindingV1(
                    taskID: taskID,
                    projectID: project.id,
                    target: target,
                    boundAt: now
                ),
            ]
        } else {
            guard taskID == nil else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskID",
                    reason: "non-task work must clear all project task bindings"
                )
            }
            bindings = []
        }

        var managementExtension = snapshot.conversations[recordIndex]
            .managementExtension
            ?? ConversationManagementExtensionV1(
                target: target,
                enrollment: .inherit,
                management: .observing,
                updatedAt: now
            )
        managementExtension.revision += 1
        // Enrollment authority is an explicit caller decision. Merely
        // enabling the project brain never enrolls a conversation.
        managementExtension.enrollment = includeForDispatch
            ? .enabled
            : .inherit
        managementExtension.workKind = workKind
        managementExtension.taskBindings = bindings
        managementExtension.updatedAt = now
        snapshot.conversations[recordIndex].managementExtension
            = managementExtension
        let expectedRevision = snapshot.revision
        snapshot.revision += 1
        snapshot.generatedAt = now

        try ConversationManagementSchemaValidatorV1.validate(
            snapshot: snapshot
        )
        try await dshMetaAgentCoordinator.configureProjectSnapshot(
            snapshot,
            expectedRevision: expectedRevision
        )
        try dshMetaAgentCoordinator.setExecutionMode(
            .previewOnly,
            projectID: project.id
        )
        publishConversationManagementSnapshots()
        conversationManagementErrors.removeValue(forKey: project.id)
    }

    func clearConversationManagementPlanBinding(
        for thread: ManagedChatThread,
        project: ManagedChatProjectIdentity,
        at now: Date = Date()
    ) async throws {
        try await setConversationManagementPlanBinding(
            for: thread,
            project: project,
            workKind: .unclassified,
            taskID: nil,
            includeForDispatch: false,
            at: now
        )
    }

    private func configureConversationManagementSnapshot(
        project: ManagedChatProjectIdentity,
        threads: [ManagedChatThread],
        brainEnabled: Bool?,
        projectDefaultEnrollmentEnabled: Bool?,
        at now: Date
    ) async throws -> String? {
        let previous = dshMetaAgentCoordinator.snapshot(projectID: project.id)
        let planProjection: ConversationProjectTaskPlanProjectionV1
        let projectionWarning: String?
        do {
            planProjection = try ConversationManagementTaskPlanAdapterV1
                .projection(
                    plan: projectTaskPlan(for: project),
                    freshness: projectTaskPlanFreshness(for: project),
                    previous: previous?.taskPlan,
                    observedAt: projectTaskPlanFreshness(for: project)
                        .lastSuccessfulAt ?? now
                )
            projectionWarning = nil
        } catch {
            // Projection failures retain the previous plan as stale display
            // evidence, but immediately revoke task authority.
            planProjection = ConversationManagementProjectorV1
                .makeTaskPlanProjection(
                    sourceAvailable: false,
                    sourceRevision: nil,
                    isValid: false,
                    tasks: [],
                    observedAt: now,
                    previous: previous?.taskPlan
                )
            projectionWarning = clean(error.localizedDescription)
        }

        let completionEvidence = ConversationProjectCompletionEvidenceV1(
            taskFreshness: planProjection.freshness,
            openTaskCount: planProjection.isValid
                ? planProjection.openTasks.count
                : nil,
            observedAt: planProjection.isValid
                ? planProjection.observedAt
                : nil,
            userConfirmedAt: previous?.completionEvidence.userConfirmedAt
        )
        let snapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: project,
            threads: threads,
            previous: previous,
            projectDefaultEnrollmentEnabled:
                projectDefaultEnrollmentEnabled
                    ?? previous?.projectDefaultEnrollmentEnabled
                    ?? false,
            completionEvidence: completionEvidence,
            brainEnabled: brainEnabled ?? previous?.brainEnabled ?? false,
            taskPlan: planProjection,
            now: now
        )

        // `generatedAt` is observational. Do not rewrite the durable file when
        // no authoritative projection field changed.
        if let previous, snapshot.revision == previous.revision {
            return projectionWarning
        }
        try await dshMetaAgentCoordinator.configureProjectSnapshot(
            snapshot,
            expectedRevision: previous?.revision
        )
        // The only supported execution mode remains preview-only. The call is
        // explicit so a future persisted mode cannot be inherited silently.
        try dshMetaAgentCoordinator.setExecutionMode(
            .previewOnly,
            projectID: project.id
        )
        publishConversationManagementSnapshots()
        return projectionWarning
    }

    private func conversationManagementProjects(
        threads: [ManagedChatThread],
        additionalProjects: [ManagedChatProjectIdentity]
    ) -> [ManagedChatProjectIdentity] {
        var byID: [String: ManagedChatProjectIdentity] = [:]
        for project in additionalProjects {
            byID[project.id] = project
        }
        for thread in threads {
            let project = ManagedChatProjectResolver.resolve(thread: thread)
            byID[project.id] = project
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private func observeConversationManagementState() {
        if conversationManagementStateObserver == nil {
            conversationManagementStateObserver = dshMetaAgentCoordinator
                .$projectStatuses
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.publishConversationManagementSnapshots()
                    }
                }
        }
        if conversationManagementDeliveryObserver == nil {
            conversationManagementDeliveryObserver = Publishers.CombineLatest(
                codexTaskDelivery.$durableQueueRevision,
                codexTaskDelivery.$isReady
            )
            .sink { [weak self] _, isReady in
                guard isReady else { return }
                Task { @MainActor [weak self] in
                    self?.scheduleConversationManagementDeliveryReconcile()
                }
            }
        }
    }

    /// Coalesces committed Codex queue revisions into a read-only
    /// reconciliation pass. The pass only looks up command IDs that were
    /// already committed to the management ledger and only reads the queue's
    /// durable projection. It cannot enqueue, recreate, or replay a command.
    private func scheduleConversationManagementDeliveryReconcile() {
        guard codexTaskDelivery.isReady, dshMetaAgentCoordinator.isReady else {
            return
        }
        conversationManagementReconcilePending = true
        guard conversationManagementReconcileTask == nil else { return }
        let generation = conversationManagementReconcileGeneration
        conversationManagementReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while conversationManagementReconcilePending,
                  !Task.isCancelled,
                  generation == conversationManagementReconcileGeneration {
                conversationManagementReconcilePending = false
                await dshMetaAgentCoordinator.reconcileRecordedDispatches()
                guard generation == conversationManagementReconcileGeneration,
                      !Task.isCancelled else { return }
                publishConversationManagementSnapshots()
            }
            if generation == conversationManagementReconcileGeneration {
                conversationManagementReconcileTask = nil
            }
        }
    }

    private func publishConversationManagementSnapshots() {
        let statuses = dshMetaAgentCoordinator.projectStatuses
        replaceConversationManagementPublishedState(
            snapshots: Dictionary(
                uniqueKeysWithValues: statuses.keys
                .compactMap { projectID in
                    dshMetaAgentCoordinator.snapshot(projectID: projectID)
                        .map { (projectID, $0) }
                }
            ),
            statuses: statuses,
            latestLedgers: dshMetaAgentCoordinator.latestLedgersByProject()
        )
    }
}
