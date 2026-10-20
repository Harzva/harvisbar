import Foundation

enum DshEndpointDiscoveryOutcome {
    case success(DshChatDiscovery)
    case failure(endpoint: DshRuntimeEndpoint, message: String)

    var endpoint: DshRuntimeEndpoint {
        switch self {
        case let .success(discovery):
            return discovery.endpoint
        case let .failure(endpoint, _):
            return endpoint
        }
    }
}

struct DshManagedChatRefreshState {
    let threadsByScope: [String: [ManagedChatThread]]
    let threads: [ManagedChatThread]
    let errorsByEndpoint: [String: String]
}

enum DshManagedChatAdapter {
    static func threads(from discovery: DshChatDiscovery) -> [ManagedChatThread] {
        let sessions = discovery.sessions.filter { session in
            !isInternalAnalysisSession(session, endpoint: discovery.endpoint)
        }
        let archivedSessionIDs = Set(discovery.archivedSessionIDs)
        var sessionsByID: [String: DshChatSession] = [:]
        for session in sessions where sessionsByID[session.sourceID] == nil {
            sessionsByID[session.sourceID] = session
        }

        var workspacePathBySessionID: [String: String] = [:]
        for workspace in discovery.workspaces {
            for sessionID in workspace.sessionIDs where workspacePathBySessionID[sessionID] == nil {
                workspacePathBySessionID[sessionID] = workspace.path
            }
        }

        var lineageBySessionID: [String: SessionLineage] = [:]
        for session in sessions {
            lineageBySessionID[session.sourceID] = lineage(
                for: session,
                sessionsByID: sessionsByID,
                workspacePathBySessionID: workspacePathBySessionID
            )
        }

        var runningSubagentsByRootID: [String: Int] = [:]
        for session in sessions
        where isSubagent(session) && session.running {
            let rootID = lineageBySessionID[session.sourceID]?.rootID ?? session.sourceID
            runningSubagentsByRootID[rootID, default: 0] += 1
        }

        return sessions.map { session in
            let lineage = lineageBySessionID[session.sourceID]
                ?? SessionLineage(rootID: session.sourceID, cwd: "")
            let archived = archivedSessionIDs.contains(session.sourceID)
            let subagent = isSubagent(session)
            return ManagedChatThread(
                provider: .dsh,
                sourceScope: discovery.sourceScope,
                sourceID: session.sourceID,
                title: session.title,
                titleSource: session.titleSource,
                hasMeaningfulTitle: session.hasMeaningfulTitle,
                createdAt: session.updatedAt,
                updatedAt: session.updatedAt,
                tokensUsed: -1,
                model: nil,
                cwd: lineage.cwd,
                archived: archived,
                running: session.running,
                sourceStatus: archived ? "archived" : (session.running ? "running" : "idle"),
                threadSource: session.origin ?? "dsh",
                agentNickname: session.agentPreset,
                agentRole: nil,
                agentPath: nil,
                parentThreadID: session.parentSessionID,
                rootThreadId: "\(discovery.sourceScope)::\(lineage.rootID)",
                isSubagent: subagent,
                isSidechat: false,
                activity: ManagedChatActivity(
                    main: session.running && !subagent ? 1 : 0,
                    subagent: subagent
                        ? (session.running ? 1 : 0)
                        : runningSubagentsByRootID[lineage.rootID, default: 0],
                    sidechat: nil
                ),
                trustProjection: trustProjection(
                    archived: archived,
                    running: session.running
                )
            )
        }
    }

    private static func isInternalAnalysisSession(
        _ session: DshChatSession,
        endpoint: DshRuntimeEndpoint
    ) -> Bool {
        endpoint.homeID == DshMetaAgentPolicy.dedicatedHomeID
            && endpoint.profile == DshMetaAgentPolicy.dedicatedProfile
            && session.agentPreset == DshMetaAgentPolicy.requiredPresetID
    }

    static func runningEndpoints(from catalog: DshRuntimeCatalog) -> [DshRuntimeEndpoint] {
        var endpoints: [DshRuntimeEndpoint] = []
        for home in catalog.homes {
            for runningProfile in home.runningProfiles {
                for port in runningProfile.ports where (1...65_535).contains(port) {
                    let endpoint = DshRuntimeEndpoint(
                        homeID: home.id,
                        profile: runningProfile.profile,
                        port: port
                    )
                    if !endpoints.contains(endpoint) {
                        endpoints.append(endpoint)
                    }
                }
            }
        }
        return endpoints.sorted {
            if $0.homeID != $1.homeID { return $0.homeID < $1.homeID }
            if $0.profile != $1.profile { return $0.profile < $1.profile }
            return $0.port < $1.port
        }
    }

    static func refreshState(
        activeEndpoints: [DshRuntimeEndpoint],
        previousThreadsByScope: [String: [ManagedChatThread]],
        outcomes: [DshEndpointDiscoveryOutcome]
    ) -> DshManagedChatRefreshState {
        let activeScopes = Set(activeEndpoints.map(\.sourceScope))
        var threadsByScope = previousThreadsByScope.filter {
            activeScopes.contains($0.key)
        }
        var successfulScopes: Set<String> = []
        var errorsByEndpoint: [String: String] = [:]

        for outcome in outcomes where activeEndpoints.contains(outcome.endpoint) {
            switch outcome {
            case let .success(discovery):
                let scope = discovery.endpoint.sourceScope
                guard !successfulScopes.contains(scope) else { continue }
                threadsByScope[scope] = threads(from: discovery)
                successfulScopes.insert(scope)
            case let .failure(endpoint, message):
                errorsByEndpoint[endpointCacheKey(endpoint)] = message
            }
        }

        let threads = threadsByScope.keys.sorted().flatMap {
            threadsByScope[$0] ?? []
        }
        return DshManagedChatRefreshState(
            threadsByScope: threadsByScope,
            threads: threads,
            errorsByEndpoint: errorsByEndpoint
        )
    }

    static func endpointCacheKey(_ endpoint: DshRuntimeEndpoint) -> String {
        "\(endpoint.sourceScope)::port::\(endpoint.port)"
    }

    private static func lineage(
        for session: DshChatSession,
        sessionsByID: [String: DshChatSession],
        workspacePathBySessionID: [String: String]
    ) -> SessionLineage {
        var currentID = session.sourceID
        var rootID = session.sourceID
        var inheritedCWD: String?
        var visited: Set<String> = []

        while !currentID.isEmpty, !visited.contains(currentID) {
            visited.insert(currentID)
            rootID = currentID
            if inheritedCWD == nil {
                inheritedCWD = nonempty(sessionsByID[currentID]?.cwd)
                    ?? nonempty(workspacePathBySessionID[currentID])
            }
            guard let parentID = nonempty(sessionsByID[currentID]?.parentSessionID) else {
                break
            }
            currentID = parentID
        }
        return SessionLineage(rootID: rootID, cwd: inheritedCWD ?? "")
    }

    private static func isSubagent(_ session: DshChatSession) -> Bool {
        session.origin?.lowercased() == "subagent"
    }

    private static func trustProjection(
        archived: Bool,
        running: Bool
    ) -> CodexThreadTrustProjection {
        if archived {
            return CodexThreadTrustProjection(
                state: .archived,
                reason: "DSH reports this session as archived."
            )
        }
        if running {
            return CodexThreadTrustProjection(
                state: .running,
                reason: "DSH reports this session as running."
            )
        }
        return CodexThreadTrustProjection(
            state: .idle,
            reason: "DSH reports this session as idle."
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct SessionLineage {
        let rootID: String
        let cwd: String
    }
}
