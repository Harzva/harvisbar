import Foundation

enum DigitalMeNavigationProjection {
    static func makeInput(
        runtimeWork: WorkInfo?,
        durableQueueItems: [CodexTaskQueueItem]?,
        managedChatThreads: [ManagedChatThread]?,
        remote: DigitalMeNavigationRemoteSources
    ) -> DigitalMeNavigationProjectionInput {
        DigitalMeNavigationProjectionInput(
            work: DigitalMeWorkProjectionInput(
                runtimeWork: runtimeWork.map {
                    DigitalMeRuntimeWork(
                        packetCount: nonnegative($0.packets),
                        blockedCount: nonnegative($0.blocked),
                        runCount: nonnegative($0.runs)
                    )
                },
                durableQueue: durableQueueItems?.map {
                    DigitalMeDurableWorkItem(
                        state: $0.state,
                        stateChangedAt: $0.stateChangedAt,
                        threadID: $0.command.threadID
                    )
                },
                runningConversations: managedChatThreads?.filter(\.running).map {
                    DigitalMeRunningConversation(
                        provider: workProvider($0.provider),
                        sourceID: $0.sourceID,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval($0.updatedAt))
                    )
                }
            ),
            remote: remote
        )
    }

    static func makeSnapshot(
        from input: DigitalMeNavigationProjectionInput
    ) -> DigitalMeNavigationSnapshot {
        DigitalMeNavigationSnapshot(
            work: makeWorkSummary(from: input.work),
            review: makeReviewSummary(from: input.remote),
            memory: makeMemorySummary(from: input.remote),
            persona: makePersonaSummary(from: input.remote)
        )
    }

    private static func makeWorkSummary(
        from input: DigitalMeWorkProjectionInput
    ) -> DigitalMeWorkSummary {
        let activeDeliveryThreadIDs = input.durableQueue.map { queue in
            Set(queue.compactMap { item -> String? in
                guard item.state == .dispatching || item.state == .running else {
                    return nil
                }
                return stableIdentity(item.threadID)
            })
        }
        let queuedDeliveryCount = input.durableQueue?.count {
            $0.state == .queued || $0.state == .waiting
        }
        let blockedDeliveryCount = input.durableQueue?.count {
            $0.state == .waitingApproval
                || $0.state == .failed
                || $0.state == .deliveryUnknown
        }
        let conversationIdentities = input.runningConversations.map { conversations in
            Set(conversations.compactMap(conversationIdentity))
        }
        let conversationCount = conversationIdentities?.count
        let managedActiveCount: Int?
        if input.durableQueue == nil && input.runningConversations == nil {
            managedActiveCount = nil
        } else {
            let codexConversationIDs = Set(
                input.runningConversations?.compactMap { conversation -> String? in
                    guard conversation.provider == .codex else { return nil }
                    return stableIdentity(conversation.sourceID)
                } ?? []
            )
            let nonCodexConversationIDs = Set(
                input.runningConversations?.compactMap { conversation -> String? in
                    guard conversation.provider != .codex else { return nil }
                    return conversationIdentity(conversation)
                } ?? []
            )
            managedActiveCount = (activeDeliveryThreadIDs ?? [])
                .union(codexConversationIDs)
                .count + nonCodexConversationIDs.count
        }
        let blockedCount = optionalSum(
            input.runtimeWork?.blockedCount,
            blockedDeliveryCount
        )

        return DigitalMeWorkSummary(
            availability: input.runtimeWork != nil
                || input.durableQueue != nil
                || input.runningConversations != nil
                ? .available
                : .notLoaded,
            activeCount: managedActiveCount,
            queuedCount: queuedDeliveryCount,
            blockedCount: blockedCount,
            packetCount: input.runtimeWork?.packetCount,
            runCount: input.runtimeWork?.runCount,
            runningConversationCount: conversationCount,
            primaryItem: primaryWorkItem(
                input: input,
                activeDeliveryCount: activeDeliveryThreadIDs?.count ?? 0,
                queuedDeliveryCount: queuedDeliveryCount ?? 0,
                blockedDeliveryCount: blockedDeliveryCount ?? 0
            )
        )
    }

    private static func primaryWorkItem(
        input: DigitalMeWorkProjectionInput,
        activeDeliveryCount: Int,
        queuedDeliveryCount: Int,
        blockedDeliveryCount: Int
    ) -> DigitalMeWorkPrimaryItem? {
        if blockedDeliveryCount > 0 || (input.runtimeWork?.blockedCount ?? 0) > 0 {
            return DigitalMeWorkPrimaryItem(
                kind: .blockedDelivery,
                title: "Work needs attention"
            )
        }
        let primaryConversation = (input.runningConversations ?? [])
            .filter { stableIdentity($0.sourceID) != nil }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
        if let conversation = primaryConversation {
            return DigitalMeWorkPrimaryItem(
                kind: .activeConversation,
                title: runningConversationLabel(conversation.provider)
            )
        }
        if activeDeliveryCount > 0 {
            return DigitalMeWorkPrimaryItem(
                kind: .activeDelivery,
                title: "Codex delivery is running"
            )
        }
        if queuedDeliveryCount > 0 {
            return DigitalMeWorkPrimaryItem(
                kind: .queuedDelivery,
                title: "Codex delivery is queued"
            )
        }
        if (input.runtimeWork?.runCount ?? 0) > 0
            || (input.runtimeWork?.packetCount ?? 0) > 0 {
            return DigitalMeWorkPrimaryItem(
                kind: .runtimeHistory,
                title: "Harvis work history is available"
            )
        }
        return nil
    }

    private static func makeReviewSummary(
        from remote: DigitalMeNavigationRemoteSources
    ) -> DigitalMeReviewSummary {
        let approvals = currentValue(remote.approvals)
        let memoryCandidates = currentValue(remote.memoryCandidates)
        let persona = currentValue(remote.persona)
        let approvalCount = approvals.map { response in
            response.approvals.count {
                isPendingApproval($0)
                    && normalized($0.target?.kind) != "memory_candidate"
            }
        }
        let memoryCandidateCount = memoryCandidates.map { response in
            response.candidates.count(where: isPendingMemoryCandidate)
        }
        let personalityCandidateCount = persona.map { response in
            response.pendingPersonalityReview.count(where: isPendingPersonalityCandidate)
        }
        let approvalCompleteness = approvals.map {
            completeness(pageCount: $0.approvals.count)
        }
        let memoryCompleteness = memoryCandidates.map {
            completeness(pageCount: $0.candidates.count)
        }
        let personalityCompleteness = persona.map {
            completeness(pageCount: $0.pendingPersonalityReview.count)
        }
        let counts = [approvalCount, memoryCandidateCount, personalityCandidateCount]
        let knownAttentionCount = counts.compactMap { $0 }.reduce(0, +)
        let reviewAvailability = availabilityAccountingForSaturation(
            availability([
                sourceDescriptor(remote.approvals),
                sourceDescriptor(remote.memoryCandidates),
                sourceDescriptor(remote.persona),
            ]),
            completeness: [
                approvalCompleteness,
                memoryCompleteness,
                personalityCompleteness,
            ]
        )

        return DigitalMeReviewSummary(
            availability: reviewAvailability,
            approvalCount: approvalCount,
            approvalCountCompleteness: approvalCompleteness,
            memoryCandidateCount: memoryCandidateCount,
            memoryCandidateCountCompleteness: memoryCompleteness,
            personalityCandidateCount: personalityCandidateCount,
            personalityCandidateCountCompleteness: personalityCompleteness,
            totalAttentionCount: reviewAvailability == .available
                && counts.allSatisfy { $0 != nil }
                ? knownAttentionCount
                : nil,
            knownAttentionCount: knownAttentionCount,
            issues: issues(from: remote)
        )
    }

    private static func makeMemorySummary(
        from remote: DigitalMeNavigationRemoteSources
    ) -> DigitalMeMemorySummary {
        let memory = currentValue(remote.memoryCandidates)
        let persona = currentValue(remote.persona)
        let vaultCompleteness = persona.map {
            completeness(pageCount: $0.memoryVaults.count)
        }
        let pendingCandidateCompleteness = memory.map {
            completeness(pageCount: $0.candidates.count)
        }
        let memoryAvailability = availabilityAccountingForSaturation(
            availability([
                sourceDescriptor(remote.memoryCandidates),
                sourceDescriptor(remote.persona),
            ]),
            completeness: [vaultCompleteness, pendingCandidateCompleteness]
        )

        return DigitalMeMemorySummary(
            availability: memoryAvailability,
            vaultCount: persona?.memoryVaults.count,
            vaultCountCompleteness: vaultCompleteness,
            snapshotExists: memory?.memoryIndex?.exists,
            lastSnapshotAt: nonempty(memory?.memoryIndex?.latestGeneratedAt),
            candidateSignalCount: memory?.memoryIndex?.candidateSignalCount,
            pendingCandidateCount: memory.map {
                $0.candidates.count(where: isPendingMemoryCandidate)
            },
            pendingCandidateCountCompleteness: pendingCandidateCompleteness,
            knowledgeSourceCount: memory?.memoryIndex?.knowledgeSourceCount,
            issues: issues(
                memoryCandidates: remote.memoryCandidates,
                persona: remote.persona
            )
        )
    }

    private static func makePersonaSummary(
        from remote: DigitalMeNavigationRemoteSources
    ) -> DigitalMePersonaSummary {
        let response = currentValue(remote.persona)
        let activePersonas = response?.personaCards.filter {
            normalized($0.status) == "active"
        }
        let runningTwins = response?.twinInstances.filter {
            normalized($0.status) == "running"
        }
        let activePersonaCompleteness = response.map {
            completeness(pageCount: $0.personaCards.count)
        }
        let runningTwinCompleteness = response.map {
            completeness(pageCount: $0.twinInstances.count)
        }
        let personaAvailability = availabilityAccountingForSaturation(
            availability([sourceDescriptor(remote.persona)]),
            completeness: [activePersonaCompleteness, runningTwinCompleteness]
        )

        return DigitalMePersonaSummary(
            availability: personaAvailability,
            activePersonaCount: activePersonas?.count,
            activePersonaCountCompleteness: activePersonaCompleteness,
            runningTwinCount: runningTwins?.count,
            runningTwinCountCompleteness: runningTwinCompleteness,
            activePersonaNames: Array(
                (activePersonas ?? [])
                    .compactMap { safePersonaName($0.displayName) }
                    .prefix(3)
            ),
            runningTwinNames: Array(
                (runningTwins ?? [])
                    .compactMap { safePersonaName($0.displayName) }
                    .prefix(3)
            ),
            registryVersion: nonempty(response?.personaRegistryVersion),
            reviewQueueVersion: nonempty(response?.reviewQueueVersion),
            issues: issue(
                source: .persona,
                message: remote.persona.errorMessage
            ).map { [$0] } ?? []
        )
    }

    private static func isPendingApproval(_ approval: DigitalMeApproval) -> Bool {
        let status = normalized(approval.status)
        return status.isEmpty || ["pending", "waiting", "requested"].contains(status)
    }

    private static func isPendingMemoryCandidate(
        _ candidate: DigitalMeMemoryCandidate
    ) -> Bool {
        let status = normalized(candidate.status, fallback: "candidate")
        let adoptionStatus = normalized(
            candidate.adoption?.status,
            fallback: "not_adopted"
        )
        let requiresReview = candidate.requiresReview == true
            || candidate.adoption?.requiresHumanReview == true
        let terminalStatuses: Set<String> = [
            "accepted", "adopted", "rejected", "dismissed", "obsolete",
        ]
        let terminalAdoptionStatuses: Set<String> = [
            "adopted", "rejected", "dismissed",
        ]
        return requiresReview
            && candidate.review == nil
            && !terminalStatuses.contains(status)
            && !terminalAdoptionStatuses.contains(adoptionStatus)
    }

    private static func isPendingPersonalityCandidate(
        _ candidate: DigitalMePersonalityCandidate
    ) -> Bool {
        let status = normalized(candidate.status, fallback: "pending_review")
        return ["pending_review", "pending", "waiting", "requested"].contains(status)
    }

    private struct SourceDescriptor {
        let hasValue: Bool
        let isLoading: Bool
        let hasError: Bool
    }

    private static func sourceDescriptor<Value>(
        _ state: DigitalMeNavigationSourceState<Value>
    ) -> SourceDescriptor {
        SourceDescriptor(
            hasValue: currentValue(state) != nil,
            isLoading: state.isLoading,
            hasError: state.errorMessage != nil
        )
    }

    private static func currentValue<Value>(
        _ state: DigitalMeNavigationSourceState<Value>
    ) -> Value? {
        guard !state.isLoading, state.errorMessage == nil else { return nil }
        return state.value
    }

    private static func availability(
        _ sources: [SourceDescriptor]
    ) -> DigitalMeNavigationAvailability {
        let valueCount = sources.count(where: \.hasValue)
        let hasLoading = sources.contains(where: \.isLoading)
        let hasError = sources.contains(where: \.hasError)

        if valueCount == sources.count && !hasLoading && !hasError {
            return .available
        }
        if valueCount > 0 {
            return .partial
        }
        if hasLoading {
            return .loading
        }
        if hasError {
            return .unavailable
        }
        return .notLoaded
    }

    private static func availabilityAccountingForSaturation(
        _ base: DigitalMeNavigationAvailability,
        completeness: [DigitalMeCountCompleteness?]
    ) -> DigitalMeNavigationAvailability {
        guard base == .available,
              completeness.contains(where: { $0 == .atLeast }) else {
            return base
        }
        return .partial
    }

    private static func completeness(
        pageCount: Int
    ) -> DigitalMeCountCompleteness {
        pageCount >= DigitalMeNavigationContract.pageLimit ? .atLeast : .exact
    }

    private static func issues(
        from remote: DigitalMeNavigationRemoteSources
    ) -> [DigitalMeNavigationSourceIssue] {
        [
            issue(source: .approvals, message: remote.approvals.errorMessage),
            issue(source: .memoryCandidates, message: remote.memoryCandidates.errorMessage),
            issue(source: .persona, message: remote.persona.errorMessage),
        ].compactMap { $0 }
    }

    private static func issues(
        memoryCandidates: DigitalMeNavigationSourceState<DigitalMeMemoryCandidatesResponse>,
        persona: DigitalMeNavigationSourceState<DigitalMePersonaResponse>
    ) -> [DigitalMeNavigationSourceIssue] {
        [
            issue(source: .memoryCandidates, message: memoryCandidates.errorMessage),
            issue(source: .persona, message: persona.errorMessage),
        ].compactMap { $0 }
    }

    private static func issue(
        source: DigitalMeNavigationSource,
        message: String?
    ) -> DigitalMeNavigationSourceIssue? {
        guard let message = nonempty(message) else { return nil }
        return DigitalMeNavigationSourceIssue(source: source, message: message)
    }

    private static func optionalSum(_ left: Int?, _ right: Int?) -> Int? {
        switch (left, right) {
        case let (left?, right?): return left + right
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        value.map { max($0, 0) }
    }

    private static func normalized(
        _ value: String?,
        fallback: String = ""
    ) -> String {
        nonempty(value)?.lowercased() ?? fallback
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableIdentity(_ value: String) -> String? {
        nonempty(value)
    }

    private static func conversationIdentity(
        _ conversation: DigitalMeRunningConversation
    ) -> String? {
        guard let sourceID = stableIdentity(conversation.sourceID) else { return nil }
        return "\(conversation.provider.rawValue)::\(sourceID)"
    }

    private static func workProvider(
        _ provider: ManagedChatProvider
    ) -> DigitalMeWorkProvider {
        switch provider {
        case .codex: return .codex
        case .dsh: return .dsh
        case .workBuddy: return .workBuddy
        }
    }

    private static func runningConversationLabel(
        _ provider: DigitalMeWorkProvider
    ) -> String {
        switch provider {
        case .codex: return "Codex conversation is running"
        case .dsh: return "DSH conversation is running"
        case .workBuddy: return "WorkBuddy conversation is running"
        }
    }

    private static func safePersonaName(_ value: String?) -> String? {
        guard let value,
              !value.contains("\n"),
              !value.contains("\r"),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("://"),
              !value.contains("=") else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return nil }

        let lowered = trimmed.lowercased()
        let forbiddenFragments = [
            "token", "secret", "password", "bearer", "credential",
            "api key", "apikey", "api_key", "api-key", "api.key",
        ]
        guard !forbiddenFragments.contains(where: lowered.contains) else {
            return nil
        }

        let allowedPunctuation = CharacterSet(charactersIn: "-_.·'()")
        let allowed = trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == " "
                || allowedPunctuation.contains(scalar)
        }
        return allowed ? trimmed : nil
    }
}
