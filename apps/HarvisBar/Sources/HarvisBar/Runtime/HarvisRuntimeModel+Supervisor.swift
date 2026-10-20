import Foundation

@MainActor
extension HarvisRuntimeModel {
    func supervisorEndpoint(for thread: ManagedChatThread) -> DshBridgeEndpointState? {
        guard ManagedSupervisorCompatibility.resolve(thread) == .dsh,
              !thread.sourceID.isEmpty else { return nil }
        let matches = dshRunningEndpoints.filter { $0.sourceScope == thread.sourceScope }
        guard Set(matches.map(\.port)).count == 1, let endpoint = matches.first,
              let bridge = dshBridgeStatesByScope[thread.sourceScope],
              bridge.endpoint == endpoint,
              bridge.supports("supervisor.session", operation: "state") else { return nil }
        return bridge
    }

    func supervisorSnapshot(for thread: ManagedChatThread) -> ManagedSupervisorSnapshot? {
        guard let saved = supervisorSnapshots[thread.id],
              let bridge = supervisorEndpoint(for: thread),
              saved.endpoint == bridge.endpoint, saved.authority == bridge.authority,
              saved.state.sessionID == thread.sourceID else { return nil }
        return saved
    }

    func refreshSupervisor(for thread: ManagedChatThread, discover: Bool = false) async {
        guard !Task.isCancelled, ManagedSupervisorCompatibility.resolve(thread) == .dsh,
              !supervisorBusyThreadIDs.contains(thread.id) else { return }
        supervisorBusyThreadIDs.insert(thread.id)
        defer { supervisorBusyThreadIDs.remove(thread.id) }
        if discover {
            await refreshDshCapabilities(endpoints: dshRunningEndpoints)
        }
        guard !Task.isCancelled else { return }
        guard let bridge = supervisorEndpoint(for: thread), let authority = bridge.authority else {
            supervisorSnapshots.removeValue(forKey: thread.id)
            supervisorErrors[thread.id] = "此 DSH 实例的 Supervisor 桥接尚未就绪。请确认实例运行且已加载新版 Harvis bridge 与 Supervisor。"
            supervisorIssueKinds[thread.id] = .unavailable
            return
        }
        do {
            let result = try await makeDshBridgeClient(bridge.endpoint).supervisorState(
                sessionID: thread.sourceID, expectedRuntimeID: authority.runtimeID
            )
            guard !Task.isCancelled, supervisorEndpoint(for: thread) == bridge else { return }
            supervisorSnapshots[thread.id] = ManagedSupervisorSnapshot(
                endpoint: bridge.endpoint, authority: result.authority, state: result.value, readAt: Date()
            )
            supervisorErrors.removeValue(forKey: thread.id)
            supervisorIssueKinds.removeValue(forKey: thread.id)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, supervisorEndpoint(for: thread) == bridge else { return }
            supervisorErrors[thread.id] = supervisorErrorMessage(error)
            supervisorIssueKinds[thread.id] = supervisorReadIssueKind(error)
        }
    }

    /// Refresh only eligible cards, with one capability discovery and at most
    /// four in-flight reads. Cancellation stops new work and cannot replay a
    /// control action. The caller owns the task and its progress presentation.
    func refreshSupervisorOverview(
        for threads: [ManagedChatThread],
        progress: @escaping @MainActor (ManagedSupervisorRefreshProgress) -> Void = { _ in }
    ) async {
        var seen: Set<String> = []
        let cards = threads.filter {
            ManagedSupervisorCompatibility.resolve($0) == .dsh
                && !$0.sourceID.isEmpty && seen.insert($0.id).inserted
        }
        progress(.init(completed: 0, total: cards.count))
        guard !Task.isCancelled, !cards.isEmpty else { return }
        await refreshDshCapabilities(endpoints: dshRunningEndpoints)
        guard !Task.isCancelled else { return }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            var completed = 0
            for card in cards.prefix(4) {
                group.addTask { await self.refreshSupervisor(for: card) }
                next += 1
            }
            for await _ in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                completed += 1
                progress(.init(completed: completed, total: cards.count))
                if next < cards.count {
                    let card = cards[next]
                    next += 1
                    group.addTask { await self.refreshSupervisor(for: card) }
                }
            }
        }
    }

    func supervisorOverviewStatus(
        for thread: ManagedChatThread, now: Date = Date()
    ) -> ManagedSupervisorOverviewStatus {
        guard ManagedSupervisorCompatibility.resolve(thread) == .dsh else { return .observation }
        if let issue = supervisorIssueKinds[thread.id], supervisorErrors[thread.id] != nil {
            switch issue {
            case .sessionUnloaded, .unavailable: return .unavailable
            case .connection, .requiresReview: return .attention
            }
        }
        if supervisorErrors[thread.id] != nil { return .attention }
        guard supervisorEndpoint(for: thread) != nil else { return .unavailable }
        guard let snapshot = supervisorSnapshot(for: thread),
              now.timeIntervalSince(snapshot.readAt) < 30 else { return .unread }
        let state = snapshot.state
        if !state.recoveryRequired.isEmpty { return .attention }
        if state.mode == "off" { return .off }
        if !state.suggestError.isEmpty || state.done || state.remaining == 0 { return .attention }
        return state.canAdopt ? .attention : .active
    }

    /// One explicit card action, bound to the last reviewed Host state. A failed
    /// delivery is never automatically replayed; refresh is always a read.
    @discardableResult
    func updateSupervisor(
        for thread: ManagedChatThread,
        operation: DshSupervisorOperation,
        patch: DshSupervisorPatch? = nil,
        expectedRevision: String? = nil
    ) async -> Bool {
        guard !supervisorBusyThreadIDs.contains(thread.id),
              let snapshot = supervisorSnapshot(for: thread),
              let bridge = supervisorEndpoint(for: thread),
              supervisorErrors[thread.id] == nil else { return false }
        guard expectedRevision == nil || expectedRevision == snapshot.state.revision else {
            supervisorErrors[thread.id] = "监督状态在点击操作后已变化。请刷新核对后重新提交；本次操作未发送。"
            supervisorIssueKinds[thread.id] = .requiresReview
            return false
        }
        guard bridge.supports("supervisor.session", operation: operation.rawValue) else {
            supervisorErrors[thread.id] = "此 DSH Supervisor 尚未提供所选操作，请刷新能力或更新对应插件。"
            supervisorIssueKinds[thread.id] = .unavailable
            return false
        }
        supervisorBusyThreadIDs.insert(thread.id)
        defer { supervisorBusyThreadIDs.remove(thread.id) }
        do {
            let result = try await makeDshBridgeClient(snapshot.endpoint).updateSupervisor(
                sessionID: thread.sourceID, expectedRuntimeID: snapshot.authority.runtimeID,
                expectedRevision: snapshot.state.revision, actionID: UUID().uuidString,
                operation: operation, patch: patch
            )
            guard supervisorEndpoint(for: thread) == bridge else {
                supervisorErrors[thread.id] = "监督实例在操作期间已变化。请刷新核对，操作不会自动重发。"
                supervisorIssueKinds[thread.id] = .requiresReview
                return false
            }
            supervisorSnapshots[thread.id] = ManagedSupervisorSnapshot(
                endpoint: snapshot.endpoint, authority: result.authority, state: result.value, readAt: Date()
            )
            supervisorErrors.removeValue(forKey: thread.id)
            supervisorIssueKinds.removeValue(forKey: thread.id)
            return true
        } catch {
            supervisorErrors[thread.id] = supervisorErrorMessage(error)
                + " 请刷新核对实际状态；本次操作不会自动重发。"
            supervisorIssueKinds[thread.id] = .requiresReview
            return false
        }
    }

    func supervisorCardLabel(for thread: ManagedChatThread) -> String {
        switch ManagedSupervisorCompatibility.resolve(thread) {
        case .codexProject: return "项目管理"
        case .observation: return "观察"
        case .dsh:
            if supervisorErrors[thread.id] != nil {
                switch supervisorIssueKinds[thread.id] {
                case .sessionUnloaded: return "需打开会话"
                case .unavailable: return "监督不可用"
                default: return "监督待核对"
                }
            }
            guard let snapshot = supervisorSnapshot(for: thread) else { return "监督" }
            guard Date().timeIntervalSince(snapshot.readAt) < 30 else { return "监督待刷新" }
            return snapshot.state.modeLabel
        }
    }

    private func supervisorReadIssueKind(_ error: Error) -> ManagedSupervisorIssueKind {
        if case let DshCapabilityBridgeError.remoteFailure(code) = error {
            switch code {
            case "session-unavailable", "session-not-found": return .sessionUnloaded
            case "unsupported-session", "capability-unavailable": return .unavailable
            default: break
            }
        }
        return .connection
    }

    private func supervisorErrorMessage(_ error: Error) -> String {
        if case let DshCapabilityBridgeError.remoteFailure(code) = error {
            switch code {
            case "runtime-mismatch", "stale-runtime": return "DSH 实例已经重启或切换。"
            case "stale-revision", "state-changed": return "监督状态已变化，本次操作未按旧状态执行。"
            case "session-unavailable", "session-not-found": return "该会话尚未加载执行器，请先在 DSH 中打开会话。"
            case "unsupported-session": return "Supervisor 只支持此实例中已加载的顶层会话。"
            case "action-conflict": return "此监督操作与先前请求冲突。"
            case "delivery-unknown", "action-unknown": return "暂时无法确定监督操作是否完成。"
            case "action-unavailable", "invalid-state": return "当前会话状态不允许执行此监督操作。"
            default: break
            }
        }
        return (error as? DshCapabilityBridgeError)?.localizedDescription ?? "无法连接监督服务。"
    }
}
