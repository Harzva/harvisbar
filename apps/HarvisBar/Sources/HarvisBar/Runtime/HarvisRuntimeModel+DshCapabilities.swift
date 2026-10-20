import Foundation

@MainActor
extension HarvisRuntimeModel {
    /// Optional capability failures never discard the ordinary DSH catalog.
    /// Discovery is shared by the runtime refresh, not repeated by every card.
    func refreshDshCapabilities(endpoints: [DshRuntimeEndpoint]) async {
        let makeClient = makeDshBridgeClient
        let grouped = Dictionary(grouping: endpoints, by: \.sourceScope)
        let unique = grouped.values.compactMap { values -> DshRuntimeEndpoint? in
            guard Set(values.map(\.port)).count == 1 else { return nil }
            return values.first
        }
        let states = await withTaskGroup(of: DshBridgeEndpointState.self) { group in
            for endpoint in unique {
                group.addTask {
                    do {
                        let result = try await makeClient(endpoint).describe()
                        return DshBridgeEndpointState(
                            endpoint: endpoint, authority: result.authority,
                            catalog: result.value, error: nil
                        )
                    } catch {
                        return DshBridgeEndpointState(
                            endpoint: endpoint, authority: nil, catalog: nil,
                            error: (error as? DshCapabilityBridgeError)?.localizedDescription
                                ?? "无法连接 DSH 能力桥接。"
                        )
                    }
                }
            }
            var result: [String: DshBridgeEndpointState] = [:]
            for await state in group { result[state.endpoint.sourceScope] = state }
            return result
        }
        guard !Task.isCancelled, dshRunningEndpoints == endpoints else { return }
        if dshBridgeStatesByScope != states { dshBridgeStatesByScope = states }
    }

    func dshUserInputEndpoint(for thread: ManagedChatThread) -> DshRuntimeEndpoint? {
        guard thread.provider == .dsh, !thread.sourceID.isEmpty else { return nil }
        let matches = dshRunningEndpoints.filter { $0.sourceScope == thread.sourceScope }
        guard Set(matches.map(\.port)).count == 1, let endpoint = matches.first,
              let bridge = dshBridgeStatesByScope[thread.sourceScope],
              bridge.endpoint == endpoint,
              bridge.supports("session.userInputs", operation: "read") else { return nil }
        return endpoint
    }

    func hasProjectOrganizerInputCapability(_ thread: ManagedChatThread) -> Bool {
        switch thread.provider {
        case .codex: return codexHome(for: thread) != nil
        case .dsh: return dshUserInputEndpoint(for: thread) != nil
        case .workBuddy: return false
        }
    }
}
