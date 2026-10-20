import Foundation

private enum ManagedChatGovernanceRefreshError: LocalizedError {
    case mismatchedMetrics(String)

    var errorDescription: String? {
        switch self {
        case let .mismatchedMetrics(threadID):
            return "Conversation metrics did not match task \(threadID)."
        }
    }
}

extension HarvisRuntimeModel {
    private static var unavailableGovernanceRetryInterval: TimeInterval { 60 }

    /// Returns the last successfully validated task plan for a project.
    /// Consult `projectTaskPlanFreshness(for:)` before treating it as current.
    func projectTaskPlan(
        for project: ManagedChatProjectIdentity
    ) -> ManagedProjectTaskPlan? {
        managedProjectTaskPlans[project.id]
    }

    func projectTaskPlanFreshness(
        for project: ManagedChatProjectIdentity
    ) -> ManagedGovernanceFreshness {
        managedProjectTaskPlanFreshness[project.id]
            ?? managedProjectTaskSummaryFreshness[project.id]
            ?? .unavailable(error: nil)
    }

    func conversationMetrics(
        for thread: ManagedChatThread
    ) -> CodexConversationMetrics? {
        codexConversationMetrics[managedChatStorageKey(thread)]
    }

    func conversationMetricsFreshness(
        for thread: ManagedChatThread
    ) -> ManagedGovernanceFreshness {
        let key = managedChatStorageKey(thread)
        let freshness = codexConversationMetricsFreshness[key]
            ?? .unavailable(error: nil)
        guard codexConversationMetricsUpdatedAt[key] != thread.updatedAt,
              let lastSuccessfulAt = freshness.lastSuccessfulAt else {
            return freshness
        }
        return .stale(
            lastSuccessfulAt: lastSuccessfulAt,
            error: "Conversation changed; current metrics have not been refreshed."
        )
    }

    func projectTaskSummaryFreshness(
        for project: ManagedChatProjectIdentity
    ) -> ManagedGovernanceFreshness {
        projectTaskPlanFreshness(for: project)
    }

    func refreshManagedChatGovernance(
        threads _: [ManagedChatThread],
        projects: [ManagedChatProjectIdentity]
    ) async {
        // A view may pass a search-filtered card list. Governance must always
        // project the complete provider inventory so hidden conversations do
        // not silently fall out of the management snapshot or allowlist.
        let completeThreads = managedChatThreads
        var projectsByID: [String: ManagedChatProjectIdentity] = [:]
        for project in projects {
            projectsByID[project.id] = project
        }
        for thread in completeThreads {
            let project = ManagedChatProjectResolver.resolve(thread: thread)
            projectsByID[project.id] = project
        }
        let completeProjects = projectsByID.values.sorted { $0.id < $1.id }

        for project in completeProjects.prefix(80) {
            guard !Task.isCancelled else { return }
            await refreshProjectTaskPlan(project)
        }
        for thread in completeThreads.lazy.filter({ $0.isCodex }).prefix(100) {
            guard !Task.isCancelled else { return }
            await refreshConversationMetrics(thread)
        }
        await refreshConversationManagementSnapshots(
            additionalProjects: Array(completeProjects.prefix(80))
        )
    }

    func refreshProjectTaskPlan(
        _ project: ManagedChatProjectIdentity,
        force: Bool = false
    ) async {
        if let inFlight = managedProjectTaskPlanRefreshTasks[project.id] {
            await inFlight.value
            return
        }

        let now = Date()
        if !force,
           let attemptedAt = managedProjectTaskPlansUpdatedAt[project.id],
           now.timeIntervalSince(attemptedAt)
                < Self.unavailableGovernanceRetryInterval {
            return
        }

        let refresh = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadProjectTaskPlan(project, attemptedAt: now)
        }
        managedProjectTaskPlanRefreshTasks[project.id] = refresh
        defer { managedProjectTaskPlanRefreshTasks.removeValue(forKey: project.id) }
        await withTaskCancellationHandler {
            await refresh.value
        } onCancel: {
            refresh.cancel()
        }
    }

    private func loadProjectTaskPlan(
        _ project: ManagedChatProjectIdentity,
        attemptedAt now: Date
    ) async {
        guard !Task.isCancelled else { return }
        managedProjectTaskPlansUpdatedAt[project.id] = now
        guard let root = project.canonicalPath else {
            recordManagedProjectTaskPlanFailure(
                "Project task source is unavailable.",
                for: project
            )
            return
        }
        do {
            let plan: ManagedProjectTaskPlan
            if let projectTaskPlanAuthorityLoader {
                plan = try await projectTaskPlanAuthorityLoader(project)
            } else {
                let output = try await runProcess(serviceManagerPath, [
                    "agent-room", "--root", root, "task-plan",
                ])
                plan = try JSONDecoder().decode(
                    ManagedProjectTaskPlan.self,
                    from: Data(output.utf8)
                )
            }
            try Task.checkCancellation()
            acceptManagedProjectTaskPlan(plan, for: project, at: now)
        } catch is CancellationError {
            // Cancellation is lifecycle control, not new project evidence.
            // Preserve the last authoritative freshness and business error.
            return
        } catch {
            recordManagedProjectTaskPlanFailure(
                clean(error.localizedDescription),
                for: project
            )
        }
    }

    /// Applies a decoded plan without running the CLI. Keeping this transition
    /// separate makes the fail-closed cache behavior directly testable.
    @discardableResult
    func acceptManagedProjectTaskPlan(
        _ plan: ManagedProjectTaskPlan,
        for project: ManagedChatProjectIdentity,
        at now: Date = Date()
    ) -> Bool {
        managedProjectTaskPlansUpdatedAt[project.id] = now
        let summary: ManagedProjectTaskSummary
        do {
            summary = try ManagedProjectTaskPlanProjector.summary(from: plan)
        } catch {
            recordManagedProjectTaskPlanFailure(
                clean(error.localizedDescription),
                for: project
            )
            return false
        }

        if managedProjectTaskPlans[project.id] != plan {
            managedProjectTaskPlans[project.id] = plan
        }
        if managedProjectTaskSummaries[project.id] != summary {
            managedProjectTaskSummaries[project.id] = summary
        }
        let freshness = ManagedGovernanceFreshness.fresh(
            lastSuccessfulAt: now
        )
        managedProjectTaskPlanFreshness[project.id] = freshness
        managedProjectTaskSummaryFreshness[project.id] = freshness
        managedGovernanceErrors.removeValue(forKey: project.id)
        return true
    }

    func recordManagedProjectTaskPlanFailure(
        _ message: String,
        for project: ManagedChatProjectIdentity
    ) {
        if managedProjectTaskSummaries[project.id] == nil {
            managedProjectTaskSummaries[project.id] = .unavailable
        }
        let previous = managedProjectTaskPlanFreshness[project.id]
            ?? managedProjectTaskSummaryFreshness[project.id]
            ?? .unavailable(error: nil)
        let freshness = previous.recordingFailure(message)
        managedProjectTaskPlanFreshness[project.id] = freshness
        managedProjectTaskSummaryFreshness[project.id] = freshness
        managedGovernanceErrors[project.id] = message
    }

    private func refreshConversationMetrics(
        _ thread: ManagedChatThread
    ) async {
        guard thread.isCodex,
              let home = selectedCodexHome,
              thread.sourceScope == home.id else { return }
        let key = managedChatStorageKey(thread)
        let now = Date()
        if codexConversationMetricsUpdatedAt[key] == thread.updatedAt,
           let cached = codexConversationMetrics[key] {
            if cached.sourceAvailable,
               codexConversationMetricsFreshness[key]?.isFresh == true {
                return
            }
            if let attemptedAt = codexConversationMetricsAttemptedAt[key],
               now.timeIntervalSince(attemptedAt)
                    < Self.unavailableGovernanceRetryInterval {
                return
            }
        } else if codexConversationMetricsFreshness[key]?.isFresh == false,
                  let attemptedAt = codexConversationMetricsAttemptedAt[key],
                  now.timeIntervalSince(attemptedAt)
                    < Self.unavailableGovernanceRetryInterval {
            return
        }
        guard codexConversationMetricsLoadingKeys.insert(key).inserted else {
            return
        }
        codexConversationMetricsAttemptedAt[key] = now
        defer { codexConversationMetricsLoadingKeys.remove(key) }

        do {
            let output = try await runProcess(serviceManagerPath, [
                "codex", "metrics",
                "--home", expanded(home.path),
                "--thread", thread.sourceID,
            ])
            let metrics = try JSONDecoder().decode(
                CodexConversationMetrics.self,
                from: Data(output.utf8)
            )
            guard metrics.ok, metrics.threadId == thread.sourceID else {
                throw ManagedChatGovernanceRefreshError
                    .mismatchedMetrics(thread.sourceID)
            }
            guard selectedCodexHomeID == home.id else { return }
            if codexConversationMetrics[key] != metrics {
                codexConversationMetrics[key] = metrics
            }
            codexConversationMetricsUpdatedAt[key] = thread.updatedAt
            codexConversationMetricsFreshness[key] = .fresh(
                lastSuccessfulAt: now
            )
            managedGovernanceErrors.removeValue(forKey: key)
        } catch {
            guard selectedCodexHomeID == home.id else { return }
            let message = clean(error.localizedDescription)
            if codexConversationMetrics[key] == nil {
                codexConversationMetrics[key] = CodexConversationMetrics(
                    ok: true,
                    schemaVersion: nil,
                    threadId: thread.sourceID,
                    sourceAvailable: false,
                    userInputCount: nil,
                    turnCount: nil,
                    compactionCount: nil,
                    compactionEvidenceAvailable: false,
                    reason: nil
                )
                codexConversationMetricsUpdatedAt[key] = thread.updatedAt
            }
            let previous = codexConversationMetricsFreshness[key]
                ?? .unavailable(error: nil)
            codexConversationMetricsFreshness[key] = previous
                .recordingFailure(message)
            managedGovernanceErrors[key] = message
        }
    }
}
