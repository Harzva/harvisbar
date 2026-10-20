import Foundation
import XCTest
@testable import HarvisBar

final class DshManagedChatAdapterTests: XCTestCase {
    func testDedicatedMetaManagerSessionIsExcludedFromManagedThreads() throws {
        let endpoint = DshRuntimeEndpoint(
            homeID: DshMetaAgentPolicy.dedicatedHomeID,
            profile: DshMetaAgentPolicy.dedicatedProfile,
            port: 3080
        )
        let discovery = try makeDiscovery(
            endpoint: endpoint,
            sessions: [
                session(
                    id: "internal-analysis",
                    scope: endpoint.sourceScope,
                    title: "Internal analysis",
                    updatedAt: 100,
                    running: true,
                    agentPreset: DshMetaAgentPolicy.requiredPresetID
                ),
                session(
                    id: "visible-session",
                    scope: endpoint.sourceScope,
                    title: "Visible session",
                    updatedAt: 200,
                    running: false,
                    agentPreset: "other-preset"
                ),
            ]
        )

        let threads = DshManagedChatAdapter.threads(from: discovery)

        XCTAssertEqual(threads.map(\.sourceID), ["visible-session"])
    }

    func testSamePresetOutsideDedicatedEndpointRemainsVisible() throws {
        let endpoints = [
            DshRuntimeEndpoint(homeID: "other-home", profile: "web", port: 3081),
            DshRuntimeEndpoint(homeID: DshMetaAgentPolicy.dedicatedHomeID, profile: "other-profile", port: 3082),
        ]

        for endpoint in endpoints {
            let sessionID = ["same-preset", String(endpoint.port)].joined(separator: "-")
            let discovery = try makeDiscovery(
                endpoint: endpoint,
                sessions: [session(
                    id: sessionID,
                    scope: endpoint.sourceScope,
                    title: "Preserved",
                    updatedAt: 100,
                    running: false,
                    agentPreset: DshMetaAgentPolicy.requiredPresetID
                )]
            )

            let threads = DshManagedChatAdapter.threads(from: discovery)

            XCTAssertEqual(threads.map(\.sourceID), [sessionID])
        }
    }

    func testAdapterPreservesScopeArchiveParentAndSubagentMetadata() throws {
        let endpoint = DshRuntimeEndpoint(homeID: "home-a", profile: "web", port: 3080)
        let discovery = try makeDiscovery(
            endpoint: endpoint,
            sessions: [
                session(
                    id: "root-session",
                    scope: endpoint.sourceScope,
                    title: "Root",
                    updatedAt: 1_700_000_100,
                    running: false,
                    agentPreset: "main-preset"
                ),
                session(
                    id: "child-session",
                    scope: endpoint.sourceScope,
                    title: "Child",
                    updatedAt: 1_700_000_200,
                    running: true,
                    parentSessionID: "root-session",
                    origin: "subagent",
                    agentPreset: "worker-preset"
                ),
            ],
            workspaces: [
                DshWorkspace(
                    workspaceID: "workspace-a",
                    path: "/tmp/project-a",
                    title: "Project A",
                    sessionIDs: ["root-session"],
                    createdAt: nil,
                    updatedAt: nil
                ),
            ],
            archivedSessionIDs: ["root-session"]
        )

        let threads = DshManagedChatAdapter.threads(from: discovery)
        let root = try XCTUnwrap(threads.first { $0.sourceID == "root-session" })
        let child = try XCTUnwrap(threads.first { $0.sourceID == "child-session" })

        XCTAssertEqual(root.provider, .dsh)
        XCTAssertEqual(root.sourceScope, "dsh::home-a::web")
        XCTAssertEqual(root.tokensUsed, -1)
        XCTAssertEqual(root.cwd, "/tmp/project-a")
        XCTAssertTrue(root.archived)
        XCTAssertFalse(root.isSubagent)
        XCTAssertEqual(root.rootThreadId, "dsh::home-a::web::root-session")
        XCTAssertEqual(root.cardActivity.subagent, 1)
        XCTAssertEqual(root.trustProjection.state, .archived)

        XCTAssertEqual(child.parentThreadID, "root-session")
        XCTAssertEqual(child.rootThreadId, root.rootThreadId)
        XCTAssertEqual(child.cwd, "/tmp/project-a")
        XCTAssertTrue(child.isSubagent)
        XCTAssertFalse(child.isSidechat)
        XCTAssertEqual(child.agentNickname, "worker-preset")
        XCTAssertEqual(child.cardActivity.subagent, 1)
        XCTAssertEqual(child.trustProjection.state, .running)
    }

    func testSameNativeSessionIDAcrossScopesDoesNotCollide() throws {
        let firstEndpoint = DshRuntimeEndpoint(homeID: "home-a", profile: "web", port: 3080)
        let secondEndpoint = DshRuntimeEndpoint(homeID: "home-b", profile: "web", port: 3090)
        let first = try makeDiscovery(
            endpoint: firstEndpoint,
            sessions: [session(
                id: "shared-session",
                scope: firstEndpoint.sourceScope,
                title: "First",
                updatedAt: 100,
                running: false,
                cwd: "/tmp/first"
            )]
        )
        let second = try makeDiscovery(
            endpoint: secondEndpoint,
            sessions: [session(
                id: "shared-session",
                scope: secondEndpoint.sourceScope,
                title: "Second",
                updatedAt: 200,
                running: false,
                cwd: "/tmp/second"
            )]
        )

        let firstThread = try XCTUnwrap(DshManagedChatAdapter.threads(from: first).first)
        let secondThread = try XCTUnwrap(DshManagedChatAdapter.threads(from: second).first)

        XCTAssertEqual(firstThread.sourceID, secondThread.sourceID)
        XCTAssertNotEqual(firstThread.sourceScope, secondThread.sourceScope)
        XCTAssertNotEqual(firstThread.id, secondThread.id)
    }

    func testFallbackTitledDshSubagentUsesSharedUnnamedVisibilityPolicy() throws {
        let endpoint = DshRuntimeEndpoint(
            homeID: "home-a",
            profile: "web",
            port: 3080
        )
        let discovery = try makeDiscovery(
            endpoint: endpoint,
            sessions: [
                session(
                    id: "root-session",
                    scope: endpoint.sourceScope,
                    title: "Root",
                    updatedAt: 100,
                    running: false
                ),
                session(
                    id: "child-session",
                    scope: endpoint.sourceScope,
                    title: "DSH Session child",
                    titleSource: "fallback",
                    hasMeaningfulTitle: false,
                    updatedAt: 200,
                    running: false,
                    parentSessionID: "root-session",
                    origin: "subagent"
                ),
            ]
        )

        let child = try XCTUnwrap(
            DshManagedChatAdapter.threads(from: discovery).first {
                $0.sourceID == "child-session"
            }
        )
        XCTAssertTrue(child.isUnnamedSubagent)
        XCTAssertFalse(ManagedUnnamedSubagentVisibilityPolicy.shouldShow(
            isUnnamedSubagent: child.isUnnamedSubagent,
            hasExplicitShowOverride: false
        ))
    }

    func testEndpointFailureKeepsItsLastSuccessAndDoesNotBlockAnotherScope() throws {
        let firstEndpoint = DshRuntimeEndpoint(homeID: "home-a", profile: "web", port: 3080)
        let secondEndpoint = DshRuntimeEndpoint(homeID: "home-b", profile: "web", port: 3090)
        let staleEndpoint = DshRuntimeEndpoint(homeID: "home-c", profile: "web", port: 3100)
        let previousFirst = try makeDiscovery(
            endpoint: firstEndpoint,
            sessions: [session(
                id: "shared-session",
                scope: firstEndpoint.sourceScope,
                title: "Cached A",
                updatedAt: 100,
                running: false
            )]
        )
        let previousStale = try makeDiscovery(
            endpoint: staleEndpoint,
            sessions: [session(
                id: "stale-session",
                scope: staleEndpoint.sourceScope,
                title: "Stale",
                updatedAt: 50,
                running: false
            )]
        )
        let freshSecond = try makeDiscovery(
            endpoint: secondEndpoint,
            sessions: [session(
                id: "shared-session",
                scope: secondEndpoint.sourceScope,
                title: "Fresh B",
                updatedAt: 200,
                running: true
            )]
        )
        let previous = [
            firstEndpoint.sourceScope: DshManagedChatAdapter.threads(from: previousFirst),
            staleEndpoint.sourceScope: DshManagedChatAdapter.threads(from: previousStale),
        ]

        let state = DshManagedChatAdapter.refreshState(
            activeEndpoints: [firstEndpoint, secondEndpoint],
            previousThreadsByScope: previous,
            outcomes: [
                .failure(endpoint: firstEndpoint, message: "offline"),
                .success(freshSecond),
            ]
        )

        XCTAssertEqual(Set(state.threadsByScope.keys), [
            firstEndpoint.sourceScope,
            secondEndpoint.sourceScope,
        ])
        XCTAssertNil(state.threadsByScope[staleEndpoint.sourceScope])
        XCTAssertEqual(state.threadsByScope[firstEndpoint.sourceScope]?.first?.title, "Cached A")
        XCTAssertEqual(state.threadsByScope[secondEndpoint.sourceScope]?.first?.title, "Fresh B")
        XCTAssertEqual(state.threads.count, 2)
        XCTAssertEqual(Set(state.threads.map(\.id)).count, 2)
        XCTAssertEqual(
            state.errorsByEndpoint[DshManagedChatAdapter.endpointCacheKey(firstEndpoint)],
            "offline"
        )
    }

    func testCatalogProducesOnlyUniqueValidRunningEndpoints() throws {
        let catalog = try JSONDecoder().decode(
            DshRuntimeCatalog.self,
            from: Data(
                #"""
                {
                  "ok": true,
                  "schemaVersion": "harvis.dsh-catalog.v1",
                  "homeCount": 1,
                  "runtimeCount": 0,
                  "homes": [{
                    "id": "home-a",
                    "label": "A",
                    "path": "/tmp/.dsh-a",
                    "version": "0.1.0-rc.8",
                    "runtimePath": null,
                    "executable": null,
                    "status": "ready",
                    "defaultProfile": "web",
                    "profileCount": 0,
                    "pluginCount": 0,
                    "customPluginCount": 0,
                    "profiles": [],
                    "runningProfiles": [
                      {"profile":"web","pid":1,"ports":[3080,3080,0,65536]},
                      {"profile":"zhitro","pid":2,"ports":[3090]}
                    ]
                  }],
                  "runtimes": [],
                  "warnings": [],
                  "includesSecrets": false
                }
                """#.utf8
            )
        )

        XCTAssertEqual(
            DshManagedChatAdapter.runningEndpoints(from: catalog),
            [
                DshRuntimeEndpoint(homeID: "home-a", profile: "web", port: 3080),
                DshRuntimeEndpoint(homeID: "home-a", profile: "zhitro", port: 3090),
            ]
        )
    }

    @MainActor
    func testRuntimeMergesDshAndUsesCurrentCodexHomeScope() throws {
        let suiteName = "DshManagedChatAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let home = try JSONDecoder().decode(
            CodexHome.self,
            from: Data(
                #"""
                {
                  "id":"current-home",
                  "label":"Current",
                  "path":"/tmp/codex-home",
                  "source":"default",
                  "model":null,
                  "provider":"openai",
                  "endpointHost":null,
                  "hasAuth":true,
                  "accountEmail":"test@example.com",
                  "authStatus":"valid",
                  "authExpiresAt":null,
                  "authNote":null,
                  "hasConfig":true,
                  "skillCount":0,
                  "quotaMode":"official",
                  "quotaNote":null
                }
                """#.utf8
            )
        )
        model.codexHomes = [home]
        model.selectedCodexHomeID = home.id
        model.acceptCodexThreads(
            [fixtureThread(id: "codex-session")],
            sourceHomeID: home.id
        )

        let dshEndpoint = DshRuntimeEndpoint(homeID: "dsh-home", profile: "web", port: 3080)
        let dshDiscovery = try makeDiscovery(
            endpoint: dshEndpoint,
            sessions: [session(
                id: "dsh-session",
                scope: dshEndpoint.sourceScope,
                title: "DSH",
                updatedAt: 200,
                running: false
            )]
        )
        model.dshThreads = DshManagedChatAdapter.threads(from: dshDiscovery)

        let threads = model.managedChatThreads
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads.first { $0.provider == .codex }?.sourceScope, home.id)
        XCTAssertEqual(
            threads.first { $0.provider == .dsh }?.sourceScope,
            dshEndpoint.sourceScope
        )
    }

    @MainActor
    func testDshStorageKeyIncludesRuntimeScopeAndUnknownTokensStayUnknown() throws {
        let suiteName = "DshManagedChatAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let firstEndpoint = DshRuntimeEndpoint(homeID: "home-a", profile: "web", port: 3080)
        let secondEndpoint = DshRuntimeEndpoint(homeID: "home-b", profile: "web", port: 3090)
        let first = try XCTUnwrap(DshManagedChatAdapter.threads(from: makeDiscovery(
            endpoint: firstEndpoint,
            sessions: [session(
                id: "shared-session",
                scope: firstEndpoint.sourceScope,
                title: "First",
                updatedAt: 100,
                running: false
            )]
        )).first)
        let second = try XCTUnwrap(DshManagedChatAdapter.threads(from: makeDiscovery(
            endpoint: secondEndpoint,
            sessions: [session(
                id: "shared-session",
                scope: secondEndpoint.sourceScope,
                title: "Second",
                updatedAt: 200,
                running: false
            )]
        )).first)

        XCTAssertEqual(first.tokenLabel, "—")
        XCTAssertEqual(model.managedChatStorageKey(first), first.id)
        XCTAssertEqual(model.managedChatStorageKey(second), second.id)
        XCTAssertNotEqual(
            model.managedChatStorageKey(first),
            model.managedChatStorageKey(second)
        )
    }

    private func makeDiscovery(
        endpoint: DshRuntimeEndpoint,
        sessions: [DshChatSession],
        workspaces: [DshWorkspace] = [],
        archivedSessionIDs: [String] = []
    ) throws -> DshChatDiscovery {
        let host = try JSONDecoder().decode(
            DshHostDescription.self,
            from: Data(#"{"app":{"name":"DSH","version":"test"}}"#.utf8)
        )
        return DshChatDiscovery(
            endpoint: endpoint,
            sourceScope: endpoint.sourceScope,
            host: host,
            workspaces: workspaces,
            archivedSessionIDs: archivedSessionIDs,
            sessions: sessions
        )
    }

    private func session(
        id: String,
        scope: String,
        title: String,
        titleSource: String? = "projection",
        hasMeaningfulTitle: Bool = true,
        updatedAt: Int64,
        running: Bool,
        cwd: String? = nil,
        parentSessionID: String? = nil,
        origin: String? = nil,
        agentPreset: String? = nil
    ) -> DshChatSession {
        DshChatSession(
            sourceID: id,
            sourceScope: scope,
            title: title,
            titleSource: titleSource,
            hasMeaningfulTitle: hasMeaningfulTitle,
            updatedAt: updatedAt,
            running: running,
            cwd: cwd,
            parentSessionID: parentSessionID,
            origin: origin,
            agentPreset: agentPreset
        )
    }
}
