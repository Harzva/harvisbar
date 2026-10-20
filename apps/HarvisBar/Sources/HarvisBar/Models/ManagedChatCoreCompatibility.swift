import Foundation

extension ConversationTrustProjection {
    init(legacy: CodexThreadTrustProjection) {
        switch legacy.state {
        case .running:
            self.init(state: .running, reason: legacy.reason)
        case .completed:
            self.init(state: .completed, reason: legacy.reason)
        case .failed:
            self.init(state: .failed, reason: legacy.reason)
        case .incomplete:
            self.init(
                state: .unknown,
                qualifier: .incomplete,
                reason: legacy.reason
            )
        case .recentlyActive:
            self.init(
                state: .idle,
                qualifier: .recentlyActive,
                reason: legacy.reason
            )
        case .idle:
            self.init(state: .idle, reason: legacy.reason)
        case .stale:
            self.init(
                state: .idle,
                qualifier: .stale,
                reason: legacy.reason
            )
        case .archived:
            self.init(state: .archived, reason: legacy.reason)
        }
    }

    var legacyProjection: CodexThreadTrustProjection {
        let legacyState: CodexThreadTrustState
        switch qualifier {
        case .incomplete:
            legacyState = .incomplete
        case .recentlyActive:
            legacyState = .recentlyActive
        case .stale:
            legacyState = .stale
        case nil:
            switch state {
            case .unknown:
                // The legacy model has no unknown state. Preserve a warning
                // presentation instead of silently treating uncertainty as idle.
                legacyState = .incomplete
            case .running:
                legacyState = .running
            case .idle:
                legacyState = .idle
            case .completed:
                legacyState = .completed
            case .failed:
                legacyState = .failed
            case .archived:
                legacyState = .archived
            }
        }
        return CodexThreadTrustProjection(state: legacyState, reason: reason)
    }
}

extension ManagedChatThread {
    /// Produces a pure Core snapshot without changing the legacy Runtime/UI
    /// authority. The caller must supply an opaque authority revision; this
    /// bridge never fabricates one from scope, timestamps, or source IDs.
    func coreProjection(
        generation: UInt64,
        authorityRevision: ConversationAuthorityRevision
    ) -> ManagedConversation {
        let address = ManagedConversationAddress(
            providerID: AgentProviderID(rawValue: provider.rawValue),
            scope: sourceScope,
            sourceID: sourceID
        )
        var coreCapabilities = ConversationCapabilities.denied(
            for: address,
            generation: generation
        )
        for action in [
            ConversationCapabilityAction.observe,
            .openProviderSurface,
        ] {
            coreCapabilities = coreCapabilities.setting(
                .allowedDirect(authorityRevision: authorityRevision),
                for: action
            )
        }

        if provider == .codex {
            // These exact/read decisions describe the Phase 0 compatibility
            // fact. They do not grant Insight/Plan or establish a future port.
            for action in [
                ConversationCapabilityAction.openExact,
                .readInputs,
                .inspect,
            ] {
                coreCapabilities = coreCapabilities.setting(
                    .allowedDirect(authorityRevision: authorityRevision),
                    for: action
                )
            }

            let sendDecision: ConversationCapabilityDecision
            if isSidechat {
                if let parentAddress = coreParentAddress(subject: address) {
                    sendDecision = .allowedParent(
                        target: parentAddress,
                        authorityRevision: authorityRevision
                    )
                } else {
                    sendDecision = .denied(
                        reason: "Transient Sidechat has no reliable parent target."
                    )
                }
            } else {
                sendDecision = .allowedDirect(
                    authorityRevision: authorityRevision
                )
            }
            coreCapabilities = coreCapabilities.setting(sendDecision, for: .send)
        }

        return ManagedConversation(
            address: address,
            title: title,
            titleSource: titleSource,
            hasMeaningfulTitle: hasMeaningfulTitle,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tokenUsage: tokensUsed >= 0 ? tokensUsed : nil,
            model: model,
            sourceWorkingDirectory: cwd,
            archived: archived,
            running: running,
            sourceStatus: sourceStatus,
            sourceKind: threadSource,
            agentIdentity: coreAgentIdentity,
            lineage: ManagedConversationLineage(
                rootAddress: coreRootAddress(subject: address),
                parentAddress: coreParentAddress(subject: address),
                isSubagent: isSubagent,
                isSidechat: isSidechat
            ),
            activity: ManagedConversationActivity(
                main: activity.main,
                subagent: activity.subagent,
                sidechat: activity.sidechat
            ),
            trust: ConversationTrustProjection(legacy: trustProjection),
            capabilities: coreCapabilities,
            projectAssignment: managementProjectAssignment
        )
    }

    /// Restores the legacy compatibility shape. The root string is required
    /// explicitly because legacy IDs are not a canonical, parseable encoding.
    init?(
        coreProjection core: ManagedConversation,
        legacyRootThreadID: String
    ) {
        guard
            let provider = ManagedChatProvider(
                rawValue: core.address.providerID.rawValue
            ),
            core.capabilities.subject == core.address
        else {
            return nil
        }
        if let parent = core.lineage.parentAddress {
            guard
                parent.providerID == core.address.providerID,
                parent.scope == core.address.scope
            else {
                return nil
            }
        }

        self.init(
            provider: provider,
            sourceScope: core.address.scope,
            sourceID: core.address.sourceID,
            title: core.title,
            titleSource: core.titleSource,
            hasMeaningfulTitle: core.hasMeaningfulTitle,
            createdAt: core.createdAt,
            updatedAt: core.updatedAt,
            tokensUsed: core.tokenUsage ?? -1,
            model: core.model,
            cwd: core.sourceWorkingDirectory,
            archived: core.archived,
            running: core.running,
            sourceStatus: core.sourceStatus,
            threadSource: core.sourceKind,
            agentNickname: core.agentIdentity?.displayName,
            agentRole: core.agentIdentity?.role,
            agentPath: core.agentIdentity?.sourcePath,
            parentThreadID: core.lineage.parentAddress?.sourceID,
            rootThreadId: legacyRootThreadID,
            isSubagent: core.lineage.isSubagent,
            isSidechat: core.lineage.isSidechat,
            activity: ManagedChatActivity(
                main: core.activity.main,
                subagent: core.activity.subagent,
                sidechat: core.activity.sidechat
            ),
            trustProjection: core.trust.legacyProjection,
            managementProjectAssignment: core.projectAssignment
        )
    }

    private var coreAgentIdentity: AgentIdentity? {
        guard
            agentNickname != nil || agentRole != nil || agentPath != nil
        else {
            return nil
        }
        return AgentIdentity(
            displayName: agentNickname,
            role: agentRole,
            sourcePath: agentPath
        )
    }

    private func coreParentAddress(
        subject: ManagedConversationAddress
    ) -> ManagedConversationAddress? {
        guard let parentThreadID, !parentThreadID.isEmpty else { return nil }
        return ManagedConversationAddress(
            providerID: subject.providerID,
            scope: subject.scope,
            sourceID: parentThreadID
        )
    }

    private func coreRootAddress(
        subject: ManagedConversationAddress
    ) -> ManagedConversationAddress? {
        let prefix: String
        switch provider {
        case .codex:
            prefix = "codex::"
        case .dsh:
            prefix = "\(sourceScope)::"
        case .workBuddy:
            prefix = "workbuddy::"
        }
        guard rootThreadId.hasPrefix(prefix) else { return nil }
        let rootSourceID = String(rootThreadId.dropFirst(prefix.count))
        guard !rootSourceID.isEmpty else { return nil }
        return ManagedConversationAddress(
            providerID: subject.providerID,
            scope: subject.scope,
            sourceID: rootSourceID
        )
    }
}
