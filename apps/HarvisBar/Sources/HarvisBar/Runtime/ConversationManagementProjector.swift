import Foundation

/// Projects provider-owned chat facts into the shared management schema.
///
/// Every visible provider contributes a lightweight base projection. Only
/// exact, currently visible Codex main/persisted-subagent targets are eligible
/// for Meta Agent delivery in v1. Enrollment never widens that allowlist.
enum ConversationManagementProjectorV1 {
    /// Converts one exact read of the agent-room task-plan API into task
    /// authority. When the source disappears, the last projection is retained
    /// only as stale display data and cannot authorize dispatch.
    static func makeTaskPlanProjection(
        sourceAvailable: Bool,
        sourceRevision: String?,
        isValid: Bool,
        tasks: [ConversationProjectTaskV1],
        observedAt: Date,
        previous: ConversationProjectTaskPlanProjectionV1?
    ) -> ConversationProjectTaskPlanProjectionV1 {
        guard sourceAvailable,
              let sourceRevision,
              !sourceRevision.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            guard let previous,
                  previous.freshness != .unavailable,
                  previous.sourceRevision != nil else {
                return .unavailable
            }
            return ConversationProjectTaskPlanProjectionV1(
                sourceRevision: previous.sourceRevision,
                freshness: .stale,
                isValid: previous.isValid,
                observedAt: previous.observedAt,
                tasks: previous.isValid ? previous.tasks : []
            )
        }
        return ConversationProjectTaskPlanProjectionV1(
            sourceRevision: sourceRevision,
            freshness: .fresh,
            isValid: isValid,
            observedAt: observedAt,
            tasks: isValid ? tasks : []
        )
    }

    static func target(
        for thread: ManagedChatThread
    ) -> ConversationManagementTargetV1 {
        ConversationManagementTargetV1(
            provider: thread.provider.rawValue,
            sourceScope: thread.sourceScope,
            sourceID: thread.sourceID
        )
    }

    static func isDispatchEligible(_ thread: ManagedChatThread) -> Bool {
        guard thread.isCodex else { return false }
        switch thread.taskCardType {
        case .main, .persistedSubagent:
            return true
        case .sidechatParent, .transientSidechat, .dsh, .workBuddy:
            return false
        }
    }

    static func allowedTargets(
        project: ManagedChatProjectIdentity,
        threads: [ManagedChatThread]
    ) -> Set<ConversationManagementTargetV1> {
        Set(threads.compactMap { thread in
            guard belongs(thread, to: project),
                  isDispatchEligible(thread) else {
                return nil
            }
            return target(for: thread)
        })
    }

    static func makeSnapshot(
        project: ManagedChatProjectIdentity,
        threads: [ManagedChatThread],
        previous: ConversationManagementSnapshotV1?,
        projectDefaultEnrollmentEnabled: Bool,
        completionEvidence: ConversationProjectCompletionEvidenceV1,
        brainEnabled: Bool = false,
        taskPlan: ConversationProjectTaskPlanProjectionV1 = .unavailable,
        now: Date = Date()
    ) -> ConversationManagementSnapshotV1 {
        let previousForProject = previous?.projectID == project.id
            ? previous
            : nil
        let previousRecords = Dictionary(
            uniqueKeysWithValues: (previousForProject?.conversations ?? [])
                .map { ($0.base.target, $0) }
        )

        let visibleThreads = threads
            .filter { belongs($0, to: project) }
            .sorted { target(for: $0).stableID < target(for: $1).stableID }
        let visibleTargets = Set(visibleThreads.map(target(for:)))

        var records = visibleThreads.map { thread in
            let exactTarget = target(for: thread)
            var managementExtension = previousRecords[exactTarget]?
                .managementExtension
            // Brain enrollment starts by observing every visible provider
            // record. `.inherit` still resolves false while the project default
            // is false, and `allowedTargets` remains the separate dispatch
            // boundary, so observation cannot grant mutation authority.
            if managementExtension == nil,
               brainEnabled {
                managementExtension = ConversationManagementExtensionV1(
                    target: exactTarget,
                    enrollment: .inherit,
                    management: .observing,
                    updatedAt: now
                )
            }
            return ConversationManagementRecordV1(
                base: baseProjection(
                    thread: thread,
                    projectID: project.id,
                    previous: previousRecords[exactTarget]?.base
                ),
                managementExtension: managementExtension
            )
        }

        // Preserve enrollment and delivery evidence for managed conversations
        // that temporarily disappear from provider discovery. They are marked
        // disconnected/stale and are not returned by `allowedTargets`.
        let retainedMissingRecords = (previousForProject?.conversations ?? [])
            .filter {
                !visibleTargets.contains($0.base.target)
                    && $0.managementExtension != nil
            }
            .map { record in
                ConversationManagementRecordV1(
                    base: ConversationManagementBaseProjectionV1(
                        target: record.base.target,
                        projectID: record.base.projectID,
                        title: record.base.title,
                        role: record.base.role,
                        startedAt: record.base.startedAt,
                        observedAt: record.base.observedAt,
                        runtime: .disconnected,
                        progress: record.base.progress,
                        evidence: ConversationEvidenceProjectionV1(
                            revision: record.base.evidence.revision,
                            status: .stale,
                            fingerprint: record.base.evidence.fingerprint,
                            summary: record.base.evidence.summary,
                            observedAt: record.base.evidence.observedAt
                        )
                    ),
                    managementExtension: record.managementExtension
                )
            }
        records.append(contentsOf: retainedMissingRecords)
        records.sort { $0.base.target.stableID < $1.base.target.stableID }

        let contentChanged: Bool
        if let previousForProject {
            contentChanged = previousForProject
                .brainEnabled != brainEnabled
                || previousForProject.taskPlan != taskPlan
                || previousForProject
                .projectDefaultEnrollmentEnabled
                != projectDefaultEnrollmentEnabled
                || previousForProject.completionEvidence != completionEvidence
                || previousForProject.conversations != records
        } else {
            contentChanged = false
        }
        let revision = (previousForProject?.revision ?? 0)
            + (contentChanged ? 1 : 0)

        return ConversationManagementSnapshotV1(
            projectID: project.id,
            revision: revision,
            brainEnabled: brainEnabled,
            projectDefaultEnrollmentEnabled: projectDefaultEnrollmentEnabled,
            taskPlan: taskPlan,
            completionEvidence: completionEvidence,
            generatedAt: now,
            conversations: records
        )
    }

    private static func belongs(
        _ thread: ManagedChatThread,
        to project: ManagedChatProjectIdentity
    ) -> Bool {
        ManagedChatProjectResolver.resolve(thread: thread).id == project.id
    }

    private static func baseProjection(
        thread: ManagedChatThread,
        projectID: String,
        previous: ConversationManagementBaseProjectionV1?
    ) -> ConversationManagementBaseProjectionV1 {
        let sourceDate = thread.updatedAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(thread.updatedAt))
            : Date(timeIntervalSince1970: 0)
        let fingerprint = evidenceFingerprint(for: thread)
        let startedAt = previous?.startedAt ?? (thread.createdAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(thread.createdAt))
            : sourceDate)
        let sourceRevision = Int(clamping: max(Int64(0), thread.updatedAt))
        let evidenceRevision: Int
        if previous?.evidence.fingerprint == fingerprint {
            evidenceRevision = previous?.evidence.revision ?? sourceRevision
        } else if let previousEvidence = previous?.evidence {
            evidenceRevision = max(
                sourceRevision,
                previousEvidence.revision == Int.max
                    ? Int.max
                    : previousEvidence.revision + 1
            )
        } else {
            evidenceRevision = sourceRevision
        }
        let evidenceStatus: ConversationEvidenceStatusV1 = thread.updatedAt > 0
            ? .fresh
            : .partial

        return ConversationManagementBaseProjectionV1(
            target: target(for: thread),
            projectID: projectID,
            title: thread.title,
            role: role(for: thread),
            startedAt: startedAt,
            observedAt: sourceDate,
            runtime: runtimeState(for: thread),
            progress: progressProjection(for: thread, at: sourceDate),
            evidence: ConversationEvidenceProjectionV1(
                revision: evidenceRevision,
                status: evidenceStatus,
                fingerprint: fingerprint,
                summary: nil,
                observedAt: thread.updatedAt > 0 ? sourceDate : nil
            )
        )
    }

    private static func role(for thread: ManagedChatThread) -> String {
        switch thread.provider {
        case .codex:
            if thread.isSidechat { return "sidechat" }
            return thread.isSubagent ? "subagent" : "main"
        case .dsh:
            return thread.isSubagent ? "dsh_subagent" : "dsh_session"
        case .workBuddy:
            return "workbuddy"
        }
    }

    private static func runtimeState(
        for thread: ManagedChatThread
    ) -> ConversationRuntimeStateV1 {
        let status = (thread.sourceStatus ?? "")
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        if status.contains("waitingonapproval")
            || status.contains("waitingapproval") {
            return .waitingApproval
        }
        if status.contains("waitingonuserinput")
            || status.contains("waitinguserinput") {
            return .waitingUserInput
        }
        if status.contains("failed") || status.contains("error") {
            return .failed
        }
        if thread.running { return .running }
        if thread.archived { return .completed }
        return .idle
    }

    private static func progressProjection(
        for thread: ManagedChatThread,
        at sourceDate: Date
    ) -> ConversationProgressProjectionV1 {
        if thread.running {
            return ConversationProgressProjectionV1(
                phase: .active,
                completedUnitCount: nil,
                totalUnitCount: nil,
                summary: nil,
                updatedAt: thread.updatedAt > 0 ? sourceDate : nil
            )
        }
        if thread.archived {
            return ConversationProgressProjectionV1(
                // Provider archival closes a conversation surface; it is not
                // proof that the managed objective or project tasks finished.
                phase: .unknown,
                completedUnitCount: nil,
                totalUnitCount: nil,
                summary: "Provider archived this conversation; completion is unverified.",
                updatedAt: thread.updatedAt > 0 ? sourceDate : nil
            )
        }
        return .unknown
    }

    private static func evidenceFingerprint(
        for thread: ManagedChatThread
    ) -> String {
        let value = [
            thread.provider.rawValue,
            thread.sourceScope,
            thread.sourceID,
            String(thread.updatedAt),
            String(thread.tokensUsed),
            String(thread.running),
            thread.sourceStatus ?? "",
        ].joined(separator: "\u{1f}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
