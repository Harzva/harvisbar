import CryptoKit
import Foundation

extension HarvisRuntimeModel {
    private static let conversationInputPageLimit = 100
    private static let conversationInputMaximumItems = 1_000
    private static let conversationInputMaximumPages = 100

    func conversationInputState(
        for thread: ManagedChatThread
    ) -> ManagedConversationUserInputState {
        let key = managedChatStorageKey(thread)
        return managedConversationInputStates[key]
            ?? .empty(targetKey: key, provider: thread.provider)
    }

    /// Keeps raw user text only for the selected panel. Derived AI summaries
    /// have a separate private store; raw chat bodies never enter it.
    func prepareConversationInputPanel(for thread: ManagedChatThread) {
        let key = managedChatStorageKey(thread)
        for staleKey in Array(managedConversationInputStates.keys) where staleKey != key {
            managedConversationInputLoadGenerations[staleKey, default: 0] += 1
            scrubConversationInputText(forKey: staleKey)
        }
    }

    func clearConversationInputPanel(for thread: ManagedChatThread) {
        let key = managedChatStorageKey(thread)
        managedConversationInputLoadGenerations[key, default: 0] += 1
        scrubConversationInputText(forKey: key)
    }

    /// Retains only the privacy-safe authority stamp needed to mark a stored
    /// relevance result fresh or stale on an unselected card. Source text is
    /// removed immediately when the panel changes or closes.
    private func scrubConversationInputText(forKey key: String) {
        guard var state = managedConversationInputStates[key] else { return }
        state.items.removeAll(keepingCapacity: false)
        state.isLoading = false
        managedConversationInputStates[key] = state
    }

    func refreshConversationInputs(
        for thread: ManagedChatThread,
        force: Bool = false
    ) async {
        let key = managedChatStorageKey(thread)
        prepareConversationInputPanel(for: thread)
        if managedConversationInputStates[key]?.isLoading == true { return }
        if !force,
           let existing = managedConversationInputStates[key],
           existing.loadedAt != nil,
           existing.threadUpdatedAtAtLoad == thread.updatedAt {
            return
        }

        switch thread.provider {
        case .codex:
            await refreshCodexConversationInputs(for: thread, key: key)
        case .dsh:
            await refreshDshConversationInputs(for: thread, key: key)
        case .workBuddy:
            publishUnavailableConversationInputs(
                for: thread,
                key: key,
                reason: "WorkBuddy 尚未提供可信的只读用户输入接口。"
            )
        }
    }

    private func refreshDshConversationInputs(for thread: ManagedChatThread, key: String) async {
        guard let endpoint = dshUserInputEndpoint(for: thread) else {
            publishUnavailableConversationInputs(
                for: thread, key: key,
                reason: "此会话所属 DSH 实例尚未提供可用的用户输入读取能力。"
            )
            return
        }
        let generation = managedConversationInputLoadGenerations[key, default: 0] + 1
        managedConversationInputLoadGenerations[key] = generation
        var loading = ManagedConversationUserInputState.empty(targetKey: key, provider: .dsh)
        loading.isLoading = true
        managedConversationInputStates[key] = loading
        do {
            let snapshot = try await DshConversationUserInputReader(
                client: makeDshBridgeClient(endpoint)
            ).read(sessionID: thread.sourceID)
            try Task.checkCancellation()
            guard managedConversationInputLoadGenerations[key] == generation else { return }
            guard dshUserInputEndpoint(for: thread) == endpoint,
                  dshBridgeStatesByScope[thread.sourceScope]?.authority == snapshot.authority,
                  managedChatThreads.contains(where: {
                      managedChatStorageKey($0) == key && $0.updatedAt == thread.updatedAt
                  }) else { throw DshCapabilityBridgeError.authorityMismatch }
            managedConversationInputStates[key] = ManagedConversationUserInputState(
                targetKey: key, provider: .dsh, sourceAvailable: true,
                sourceRevision: snapshot.sourceRevision, items: snapshot.items,
                totalCount: snapshot.totalCount,
                excludedNonHumanCount: snapshot.excludedNonHumanCount,
                nextCursor: snapshot.nextCursor, isLoading: false,
                isTruncated: snapshot.isTruncated, loadedAt: Date(),
                threadUpdatedAtAtLoad: thread.updatedAt, error: nil
            )
        } catch is CancellationError {
            guard managedConversationInputLoadGenerations[key] == generation else { return }
            managedConversationInputStates[key] = .empty(targetKey: key, provider: .dsh)
        } catch {
            guard managedConversationInputLoadGenerations[key] == generation else { return }
            publishUnavailableConversationInputs(
                for: thread, key: key,
                reason: (error as? DshCapabilityBridgeError)?.localizedDescription
                    ?? "DSH 用户输入读取未完成，请检查实例连接。"
            )
        }
    }

    private func refreshCodexConversationInputs(
        for thread: ManagedChatThread,
        key: String
    ) async {
        guard let home = codexHome(for: thread) else {
            publishUnavailableConversationInputs(
                for: thread,
                key: key,
                reason: "Codex Home 与当前任务来源不匹配。"
            )
            return
        }

        let generation = managedConversationInputLoadGenerations[key, default: 0] + 1
        managedConversationInputLoadGenerations[key] = generation
        var loading = managedConversationInputStates[key]
            ?? .empty(targetKey: key, provider: thread.provider)
        loading.isLoading = true
        loading.error = nil
        managedConversationInputStates[key] = loading

        do {
            var cursor: String?
            var sourceRevision: String?
            var sourceAvailable = false
            var totalCount = 0
            var excludedNonHumanCount = 0
            var projected: [ManagedConversationUserInput] = []
            var originHashesByItemID: [String: String] = [:]
            var seenWireIDs: Set<String> = []
            var filteredManagerItems: Set<String> = []
            var filteredUnsupportedSourceItems: Set<String> = []
            var seenCursors: Set<String> = []
            var pageCount = 0
            let managerOriginHashes = managerOriginMessageIDHashes(
                homeID: home.id,
                threadID: thread.sourceID
            )
            repeat {
                try Task.checkCancellation()
                guard pageCount < Self.conversationInputMaximumPages else {
                    throw HarvisBarError.api(
                        "用户输入分页超过最大页数，请重新读取。"
                    )
                }
                var arguments = [
                    "codex", "user-inputs",
                    "--home", home.path,
                    "--thread", thread.sourceID,
                    "--limit", String(Self.conversationInputPageLimit),
                ]
                if let cursor {
                    guard seenCursors.insert(cursor).inserted else {
                        throw HarvisBarError.api(
                            "用户输入分页游标重复，读取已停止。"
                        )
                    }
                    arguments += ["--cursor", cursor]
                }
                let output = try await runProcess(
                    serviceManagerPath,
                    arguments,
                    timeout: 8
                )
                let page = try JSONDecoder().decode(
                    CodexUserInputPage.self,
                    from: Data(output.utf8)
                )
                try ManagedConversationInputProjection.validate(
                    page,
                    expectedThreadID: thread.sourceID
                )
                pageCount += 1
                if let sourceRevision, sourceRevision != page.sourceRevision {
                    throw HarvisBarError.api(
                        "用户输入在分页读取期间发生变化，请重新读取。"
                    )
                }
                sourceRevision = page.sourceRevision
                sourceAvailable = page.sourceAvailable
                totalCount = page.totalItems
                excludedNonHumanCount = page.excludedNonHumanItems
                for wireItem in page.items {
                    guard seenWireIDs.insert(wireItem.id).inserted else {
                        throw ManagedConversationInputProjectionError
                            .duplicateItem(wireItem.id)
                    }
                    if let originHash = wireItem.originMessageIDHash {
                        originHashesByItemID[wireItem.id] = originHash
                    }
                    if let originHash = wireItem.originMessageIDHash,
                       managerOriginHashes.contains(originHash) {
                        filteredManagerItems.insert(wireItem.id)
                        continue
                    }
                    guard wireItem.source == .human
                            || wireItem.source == .unknown else {
                        // Defense in depth for a future or drifting producer:
                        // Manager/system rows are never rendered or analyzed,
                        // even if they unexpectedly cross the Rust boundary.
                        filteredUnsupportedSourceItems.insert(wireItem.id)
                        continue
                    }
                    let item = wireItem.projected
                    projected.append(item)
                }
                cursor = page.nextCursor
            } while cursor != nil
                && projected.count < Self.conversationInputMaximumItems

            guard managedConversationInputLoadGenerations[key] == generation,
                  codexHome(for: thread)?.id == home.id,
                  managedChatThreads.contains(where: {
                      managedChatStorageKey($0) == key
                  }) else { return }
            // Re-read the durable Manager projection at the final, synchronous
            // MainActor publication boundary. A command may have been
            // persisted while the CLI pagination was awaiting; it must not be
            // published as an unverified user-role message.
            let finalManagerOriginHashes = managerOriginMessageIDHashes(
                homeID: home.id,
                threadID: thread.sourceID
            )
            let lateManagerItemIDs: Set<String> = Set(projected.compactMap { item in
                guard let hash = originHashesByItemID[item.id],
                      finalManagerOriginHashes.contains(hash) else { return nil }
                return item.id
            })
            if !lateManagerItemIDs.isEmpty {
                projected.removeAll { lateManagerItemIDs.contains($0.id) }
                filteredManagerItems.formUnion(lateManagerItemIDs)
            }
            let locallyExcludedCount = filteredManagerItems.count
                + filteredUnsupportedSourceItems.count
            let visibleTotalCount = max(0, totalCount - locallyExcludedCount)
            managedConversationInputStates[key] = ManagedConversationUserInputState(
                targetKey: key,
                provider: .codex,
                sourceAvailable: sourceAvailable,
                sourceRevision: sourceRevision,
                items: projected,
                totalCount: visibleTotalCount,
                excludedNonHumanCount:
                    excludedNonHumanCount + locallyExcludedCount,
                nextCursor: cursor,
                isLoading: false,
                isTruncated: cursor != nil || projected.count < visibleTotalCount,
                loadedAt: Date(),
                threadUpdatedAtAtLoad: thread.updatedAt,
                error: nil
            )
        } catch is CancellationError {
            guard managedConversationInputLoadGenerations[key] == generation else { return }
            var state = managedConversationInputStates[key]
                ?? .empty(targetKey: key, provider: thread.provider)
            state.isLoading = false
            managedConversationInputStates[key] = state
        } catch {
            guard managedConversationInputLoadGenerations[key] == generation else { return }
            // A failed authority read must not leave a previously successful
            // revision eligible for AI analysis or project reassignment. Drop
            // the raw rows as well: the selected panel may explain the failure,
            // but it cannot present or act on an old partial snapshot.
            managedConversationInputStates[key] = ManagedConversationUserInputState(
                targetKey: key,
                provider: thread.provider,
                sourceAvailable: false,
                sourceRevision: nil,
                items: [],
                totalCount: 0,
                excludedNonHumanCount: 0,
                nextCursor: nil,
                isLoading: false,
                isTruncated: false,
                loadedAt: Date(),
                threadUpdatedAtAtLoad: nil,
                error: clean(error.localizedDescription)
            )
        }
    }

    private func publishUnavailableConversationInputs(
        for thread: ManagedChatThread,
        key: String,
        reason: String
    ) {
        managedConversationInputStates[key] = ManagedConversationUserInputState(
            targetKey: key,
            provider: thread.provider,
            sourceAvailable: false,
            sourceRevision: nil,
            items: [],
            totalCount: 0,
            excludedNonHumanCount: 0,
            nextCursor: nil,
            isLoading: false,
            isTruncated: false,
            loadedAt: Date(),
            threadUpdatedAtAtLoad: thread.updatedAt,
            error: reason
        )
    }

    private func managerOriginMessageIDHashes(
        homeID: String,
        threadID: String
    ) -> Set<String> {
        Set(
            codexTaskDelivery.durableQueueItems.lazy
                .filter {
                    $0.command.homeID == homeID
                        && $0.command.threadID == threadID
                }
                .map { commandItem in
                    let canonical = commandItem.command.id.uuidString.lowercased()
                    let digest = SHA256.hash(data: Data(canonical.utf8))
                        .map { String(format: "%02x", $0) }
                        .joined()
                    return "sha256:\(digest)"
                }
        )
    }
}
