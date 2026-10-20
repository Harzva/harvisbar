import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisRuntimeSupervisorOverviewTests: XCTestCase {
    func testOverviewRefreshFiltersCardsDeduplicatesAndRoutesReadOnlyReadsByScope() async throws {
        let suite = "HarvisRuntimeSupervisorOverviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstEndpoint = DshRuntimeEndpoint(homeID: "overview-home-a", profile: "web", port: 8123)
        let secondEndpoint = DshRuntimeEndpoint(homeID: "overview-home-b", profile: "web", port: 8124)
        let transport = OverviewFixtureTransport(
            stateDataByPort: [
                firstEndpoint.port: try stateData(sessionID: "same-session", mode: "advice"),
                secondEndpoint.port: try stateData(sessionID: "same-session", mode: "takeover"),
            ],
            authorityByPort: [
                firstEndpoint.port: firstEndpoint.homeID,
                secondEndpoint.port: secondEndpoint.homeID,
            ]
        )
        let model = makeModel(
            defaults: defaults,
            endpoints: [firstEndpoint, secondEndpoint],
            transport: transport
        )
        let first = card(scope: firstEndpoint.sourceScope, sourceID: "same-session")
        let duplicate = card(scope: firstEndpoint.sourceScope, sourceID: "same-session")
        let second = card(scope: secondEndpoint.sourceScope, sourceID: "same-session")
        let ignored = [
            card(provider: .codex, scope: firstEndpoint.sourceScope, sourceID: "codex-session"),
            card(provider: .workBuddy, scope: firstEndpoint.sourceScope, sourceID: "workbuddy-session"),
            card(scope: firstEndpoint.sourceScope, sourceID: "child-session", child: true),
            card(scope: firstEndpoint.sourceScope, sourceID: "archived-session", archived: true),
        ]
        var progress: [ManagedSupervisorRefreshProgress] = []

        await model.refreshSupervisorOverview(for: [first, duplicate, second] + ignored) {
            progress.append($0)
        }

        XCTAssertEqual(model.supervisorSnapshot(for: first)?.state.mode, "advice")
        XCTAssertEqual(model.supervisorSnapshot(for: second)?.state.mode, "takeover")
        for card in ignored {
            XCTAssertNil(model.supervisorSnapshot(for: card))
        }
        XCTAssertEqual(progress.first, .init(completed: 0, total: 2))
        XCTAssertEqual(progress.last, .init(completed: 2, total: 2))

        let requests = await transport.requests()
        XCTAssertTrue(requests.allSatisfy {
            $0.method == "capabilities.describe" || $0.method == "supervisor.session.state"
        })
        let stateRequests = requests.filter { $0.method == "supervisor.session.state" }
        XCTAssertEqual(stateRequests.count, 2, "Duplicate cards must not trigger another state read")
        XCTAssertEqual(Set(stateRequests.map(\.port)), Set([firstEndpoint.port, secondEndpoint.port]))
        XCTAssertEqual(Set(stateRequests.compactMap(\.sessionID)), Set(["same-session"]))
    }

    func testOverviewRefreshKeepsAtMostFourStateReadsInFlight() async throws {
        let suite = "HarvisRuntimeSupervisorOverviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let endpoints = (0..<7).map {
            DshRuntimeEndpoint(homeID: "overview-home-\($0)", profile: "web", port: 8200 + $0)
        }
        let transport = OverviewFixtureTransport(
            stateDataByPort: Dictionary(uniqueKeysWithValues: endpoints.enumerated().map { index, endpoint in
                (
                    endpoint.port,
                    try! stateData(sessionID: "session-\(index)", mode: "advice")
                )
            }),
            authorityByPort: Dictionary(uniqueKeysWithValues: endpoints.map { ($0.port, $0.homeID) }),
            stateDelay: 30_000_000
        )
        let model = makeModel(defaults: defaults, endpoints: endpoints, transport: transport)
        let cards = endpoints.enumerated().map { index, endpoint in
            card(scope: endpoint.sourceScope, sourceID: "session-\(index)")
        }
        var progress: [ManagedSupervisorRefreshProgress] = []

        await model.refreshSupervisorOverview(for: cards) { progress.append($0) }

        let maximumConcurrentStateReads = await transport.maxConcurrentStateReads()
        let requests = await transport.requests()
        XCTAssertEqual(maximumConcurrentStateReads, 4)
        XCTAssertEqual(requests.filter { $0.method == "supervisor.session.state" }.count, cards.count)
        XCTAssertEqual(progress.last, .init(completed: cards.count, total: cards.count))
        XCTAssertTrue(model.supervisorBusyThreadIDs.isEmpty)
    }

    func testCancellingOverviewStopsBeforeStartingRemainingCardsAndClearsBusyState() async throws {
        let suite = "HarvisRuntimeSupervisorOverviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let endpoints = (0..<6).map {
            DshRuntimeEndpoint(homeID: "cancel-home-\($0)", profile: "web", port: 8300 + $0)
        }
        let transport = OverviewFixtureTransport(
            stateDataByPort: Dictionary(uniqueKeysWithValues: endpoints.enumerated().map { index, endpoint in
                (
                    endpoint.port,
                    try! stateData(sessionID: "cancel-session-\(index)", mode: "advice")
                )
            }),
            authorityByPort: Dictionary(uniqueKeysWithValues: endpoints.map { ($0.port, $0.homeID) }),
            stateDelay: 1_000_000_000
        )
        let model = makeModel(defaults: defaults, endpoints: endpoints, transport: transport)
        let cards = endpoints.enumerated().map { index, endpoint in
            card(scope: endpoint.sourceScope, sourceID: "cancel-session-\(index)")
        }
        let refresh = Task { @MainActor in
            await model.refreshSupervisorOverview(for: cards)
        }

        for _ in 0..<200 {
            if await transport.stateStartedCount() == 4 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let startedBeforeCancellation = await transport.stateStartedCount()
        XCTAssertEqual(startedBeforeCancellation, 4)
        refresh.cancel()
        await refresh.value

        let startedAfterCancellation = await transport.stateStartedCount()
        XCTAssertEqual(startedAfterCancellation, 4)
        XCTAssertTrue(model.supervisorBusyThreadIDs.isEmpty)
        XCTAssertTrue(model.supervisorSnapshots.isEmpty)
        XCTAssertTrue(model.supervisorErrors.isEmpty, "Cancelled reads must not become error banners")
    }

    func testOverviewRefreshDoesNotPublishAResponseFromAnOldAuthority() async throws {
        let suite = "HarvisRuntimeSupervisorOverviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let endpoint = DshRuntimeEndpoint(homeID: "stale-home", profile: "web", port: 8400)
        let transport = OverviewFixtureTransport(
            stateDataByPort: [endpoint.port: try stateData(sessionID: "stale-session", mode: "advice")],
            authorityByPort: [endpoint.port: endpoint.homeID],
            stateDelay: 80_000_000
        )
        let model = makeModel(defaults: defaults, endpoints: [endpoint], transport: transport)
        let card = card(scope: endpoint.sourceScope, sourceID: "stale-session")
        let refresh = Task { @MainActor in
            await model.refreshSupervisorOverview(for: [card])
        }

        for _ in 0..<200 {
            if await transport.stateStartedCount() == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let startedBeforeAuthorityChange = await transport.stateStartedCount()
        XCTAssertEqual(startedBeforeAuthorityChange, 1)
        let old = try XCTUnwrap(model.dshBridgeStatesByScope[endpoint.sourceScope])
        model.dshBridgeStatesByScope[endpoint.sourceScope] = .init(
            endpoint: endpoint,
            authority: .init(homeID: endpoint.homeID, profile: endpoint.profile, runtimeID: "restarted-runtime"),
            catalog: old.catalog,
            error: nil
        )
        await refresh.value

        XCTAssertNil(model.supervisorSnapshot(for: card))
        XCTAssertTrue(model.supervisorBusyThreadIDs.isEmpty)
    }

    func testOverviewStatusClassifiesFreshStaleAndUnavailableStates() throws {
        let suite = "HarvisRuntimeSupervisorOverviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let endpoint = DshRuntimeEndpoint(homeID: "status-home", profile: "web", port: 8500)
        let model = makeModel(defaults: defaults, endpoints: [endpoint], transport: OverviewFixtureTransport())
        let card = card(scope: endpoint.sourceScope, sourceID: "status-session")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let authority = DshBridgeAuthority(
            homeID: endpoint.homeID,
            profile: endpoint.profile,
            runtimeID: "status-runtime"
        )
        let catalog = DshCapabilityCatalog(
            schemaVersion: DshCapabilityCatalog.supportedSchemaVersion,
            bridgeVersion: "fixture",
            capabilities: [
                .init(
                    id: "supervisor.session",
                    version: 1,
                    title: "Supervisor",
                    scope: "session",
                    operations: ["state", "set", "regenerate", "adopt", "recover"],
                    availability: .available,
                    reason: nil,
                    requiresApproval: false,
                    supportsCancel: true
                )
            ]
        )
        model.dshBridgeStatesByScope[endpoint.sourceScope] = .init(
            endpoint: endpoint,
            authority: authority,
            catalog: catalog,
            error: nil
        )

        model.supervisorSnapshots[card.id] = .init(
            endpoint: endpoint,
            authority: authority,
            state: try state(sessionID: card.sourceID, mode: "advice", status: "silent"),
            readAt: now
        )
        XCTAssertEqual(model.supervisorOverviewStatus(for: card, now: now), .active)

        model.supervisorSnapshots[card.id] = .init(
            endpoint: endpoint,
            authority: authority,
            state: try state(
                sessionID: card.sourceID,
                mode: "advice",
                status: "suggested",
                suggestion: "Review the latest result.",
                suggestionID: "suggestion-1"
            ),
            readAt: now
        )
        XCTAssertEqual(model.supervisorOverviewStatus(for: card, now: now), .attention)

        model.supervisorSnapshots[card.id] = .init(
            endpoint: endpoint,
            authority: authority,
            state: try state(sessionID: card.sourceID, mode: "off", status: "off"),
            readAt: now
        )
        XCTAssertEqual(model.supervisorOverviewStatus(for: card, now: now), .off)

        model.supervisorSnapshots[card.id] = .init(
            endpoint: endpoint,
            authority: authority,
            state: try state(sessionID: card.sourceID, mode: "advice", status: "silent"),
            readAt: now.addingTimeInterval(-31)
        )
        XCTAssertEqual(model.supervisorOverviewStatus(for: card, now: now), .unread)

        model.supervisorSnapshots.removeValue(forKey: card.id)
        model.supervisorErrors[card.id] = "session unavailable"
        model.supervisorIssueKinds[card.id] = .sessionUnloaded
        XCTAssertEqual(model.supervisorOverviewStatus(for: card, now: now), .unavailable)

        XCTAssertEqual(
            model.supervisorOverviewStatus(for: self.card(provider: .codex, scope: endpoint.sourceScope, sourceID: "codex-observed"), now: now),
            .observation
        )
    }

    private func makeModel(
        defaults: UserDefaults,
        endpoints: [DshRuntimeEndpoint],
        transport: OverviewFixtureTransport
    ) -> HarvisRuntimeModel {
        let model = HarvisRuntimeModel(defaults: defaults)
        model.dshRunningEndpoints = endpoints
        let wire = transport
        model.makeDshBridgeClient = { endpoint in
            DshCapabilityBridgeClient(endpoint: endpoint, transport: wire)
        }
        return model
    }

    private func card(
        provider: ManagedChatProvider = .dsh,
        scope: String,
        sourceID: String,
        child: Bool = false,
        archived: Bool = false
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider,
            sourceScope: scope,
            sourceID: sourceID,
            title: "Synthetic supervisor session",
            titleSource: "fixture",
            hasMeaningfulTitle: true,
            createdAt: 1,
            updatedAt: 2,
            tokensUsed: 0,
            model: "fixture",
            cwd: "/synthetic/supervisor",
            archived: archived,
            running: false,
            sourceStatus: "idle",
            threadSource: "fixture",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: child ? "parent" : nil,
            rootThreadId: "root",
            isSubagent: child,
            isSidechat: false,
            activity: .init(main: 0, subagent: 0, sidechat: nil),
            trustProjection: .init(state: .idle, reason: "Fixture")
        )
    }

    private func state(
        sessionID: String,
        mode: String,
        status: String,
        suggestion: String = "",
        suggestionID: String = ""
    ) throws -> DshSupervisorState {
        try JSONDecoder().decode(
            DshSupervisorState.self,
            from: stateData(
                sessionID: sessionID,
                mode: mode,
                status: status,
                suggestion: suggestion,
                suggestionID: suggestionID
            )
        )
    }

    private func stateData(
        sessionID: String,
        mode: String,
        status: String = "silent",
        suggestion: String = "",
        suggestionID: String = ""
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": DshSupervisorState.supportedSchemaVersion,
            "sessionId": sessionID,
            "revision": "sha256:" + String(repeating: "a", count: 64),
            "mode": mode,
            "strategy": "plan",
            "rounds": 8,
            "used": 1,
            "remaining": 7,
            "intervalMs": 60_000,
            "status": status,
            "suggestion": suggestion,
            "suggestionId": suggestionID,
            "runId": "fixture-run",
            "recoveryRequired": "",
            "done": false,
            "agentStatus": "idle",
            "mentorName": "Fixture",
            "suggestError": "",
        ])
    }
}

private struct OverviewRequest: Equatable, Sendable {
    let method: String
    let port: Int
    let sessionID: String?
}

private actor OverviewFixtureTransport: DshHostTransport {
    private let stateDataByPort: [Int: Data]
    private let authorityByPort: [Int: String]
    private let stateDelay: UInt64
    private var recordedRequests: [OverviewRequest] = []
    private var activeStateReads = 0
    private var maximumStateReads = 0
    private var startedStateReads = 0

    init(
        stateDataByPort: [Int: Data] = [:],
        authorityByPort: [Int: String] = [:],
        stateDelay: UInt64 = 0
    ) {
        self.stateDataByPort = stateDataByPort
        self.authorityByPort = authorityByPort
        self.stateDelay = stateDelay
    }

    func requests() -> [OverviewRequest] { recordedRequests }

    func maxConcurrentStateReads() -> Int { maximumStateReads }

    func stateStartedCount() -> Int { startedStateReads }

    func send(_ request: URLRequest) async throws -> DshHostTransportResponse {
        guard let port = request.url?.port,
              let body = request.httpBody,
              let rpc = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = rpc["method"] as? String,
              let requestID = rpc["requestId"] as? String else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        let params = rpc["params"] as? [String: Any]
        let sessionID = params?["sessionId"] as? String
        recordedRequests.append(.init(method: method, port: port, sessionID: sessionID))

        if method == "supervisor.session.state" {
            startedStateReads += 1
            activeStateReads += 1
            maximumStateReads = max(maximumStateReads, activeStateReads)
            defer { activeStateReads -= 1 }
            if stateDelay > 0 {
                try await Task.sleep(nanoseconds: stateDelay)
            }
            try Task.checkCancellation()
            guard let value = stateDataByPort[port] else {
                throw DshCapabilityBridgeError.remoteFailure("session-unavailable")
            }
            return try envelope(
                requestID: requestID,
                endpoint: port,
                result: ["ok": true, "value": try JSONSerialization.jsonObject(with: value)]
            )
        }

        guard method == "capabilities.describe" else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        let catalog: [String: Any] = [
            "schemaVersion": DshCapabilityCatalog.supportedSchemaVersion,
            "bridgeVersion": "fixture",
            "capabilities": [[
                "id": "supervisor.session",
                "version": 1,
                "title": "Supervisor",
                "scope": "session",
                "operations": ["state", "set", "regenerate", "adopt", "recover"],
                "availability": "available",
                "requiresApproval": false,
                "supportsCancel": true,
            ]],
        ]
        return try envelope(
            requestID: requestID,
            endpoint: port,
            result: ["ok": true, "value": catalog]
        )
    }

    private func envelope(
        requestID: String,
        endpoint port: Int,
        result: [String: Any]
    ) throws -> DshHostTransportResponse {
        let authority: [String: Any] = [
            "homeID": authorityByPort[port] ?? "overview-home-\(port)",
            "profile": "web",
            "runtimeId": "runtime-\(port)",
        ]
        let object: [String: Any] = [
            "schemaVersion": DshCapabilityBridgeClient.schemaVersion,
            "requestId": requestID,
            "authority": authority,
            "result": result,
        ]
        return .init(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
}
