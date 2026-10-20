import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisRuntimeSupervisorTests: XCTestCase {
    func testActionDoesNotSubstituteANewerSnapshotForTheRevisionTheUserReviewed() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.model.refreshSupervisor(for: fixture.card)
        let reviewed = try XCTUnwrap(fixture.model.supervisorSnapshot(for: fixture.card)?.state.revision)
        await fixture.model.updateSupervisor(for: fixture.card, operation: .set, patch: .init(mode: "advice"))

        let accepted = await fixture.model.updateSupervisor(
            for: fixture.card, operation: .set, patch: .init(mode: "takeover"), expectedRevision: reviewed
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.model.supervisorSnapshot(for: fixture.card)?.state.mode, "advice")
        XCTAssertEqual(fixture.model.supervisorIssueKinds[fixture.card.id], .requiresReview)
        let methods = await fixture.transport.methods()
        XCTAssertEqual(methods.filter { $0 == "supervisor.session.set" }.count, 1)
    }

    func testCardActionRoundTripUsesItsOwnEndpointAndDoesNotAlterProviderActivity() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.model.refreshSupervisor(for: fixture.card)
        XCTAssertEqual(fixture.model.supervisorSnapshot(for: fixture.card)?.state.mode, "off")
        await fixture.model.updateSupervisor(for: fixture.card, operation: .set, patch: .init(mode: "advice"))
        XCTAssertEqual(fixture.model.supervisorSnapshot(for: fixture.card)?.state.mode, "advice")
        XCTAssertNil(fixture.model.supervisorErrors[fixture.card.id])
        XCTAssertFalse(fixture.model.dshThreads[0].running)
        XCTAssertTrue(fixture.model.supervisorBusyThreadIDs.isEmpty)
        let methods = await fixture.transport.methods()
        XCTAssertEqual(methods, ["supervisor.session.state", "supervisor.session.set"])
    }

    func testAmbiguousMutationIsNotAutomaticallyRepeatedAndNeedsExplicitRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.model.refreshSupervisor(for: fixture.card)
        await fixture.transport.failNextMutation()
        await fixture.model.updateSupervisor(for: fixture.card, operation: .set, patch: .init(mode: "advice"))
        XCTAssertNotNil(fixture.model.supervisorErrors[fixture.card.id])
        await fixture.model.updateSupervisor(for: fixture.card, operation: .set, patch: .init(mode: "advice"))
        let before = await fixture.transport.methods()
        XCTAssertEqual(before.filter { $0 == "supervisor.session.set" }.count, 1)
        await fixture.model.refreshSupervisor(for: fixture.card)
        XCTAssertNil(fixture.model.supervisorErrors[fixture.card.id])
        XCTAssertEqual(fixture.model.supervisorSnapshot(for: fixture.card)?.state.mode, "advice",
                       "Refresh must reconcile the server's completed mutation after a lost response")
        let after = await fixture.transport.methods()
        XCTAssertEqual(after.last, "supervisor.session.state")
    }

    func testRepeatedClickWhileRequestIsPendingDispatchesOnlyOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.model.refreshSupervisor(for: fixture.card)
        await fixture.transport.setDelay(80_000_000)
        let first = Task { await fixture.model.updateSupervisor(for: fixture.card, operation: .set, patch: .init(mode: "advice")) }
        await Task.yield()
        XCTAssertTrue(fixture.model.supervisorBusyThreadIDs.contains(fixture.card.id))
        await fixture.model.updateSupervisor(for: fixture.card, operation: .set, patch: .init(mode: "takeover"))
        await first.value
        let methods = await fixture.transport.methods()
        XCTAssertEqual(methods.filter { $0 == "supervisor.session.set" }.count, 1)
        XCTAssertEqual(fixture.model.supervisorSnapshot(for: fixture.card)?.state.mode, "advice")
    }

    func testRuntimeReplacementWhileReadingCannotPublishOldState() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.transport.setDelay(80_000_000)
        let read = Task { await fixture.model.refreshSupervisor(for: fixture.card) }
        await Task.yield()
        let old = try XCTUnwrap(fixture.model.dshBridgeStatesByScope[fixture.endpoint.sourceScope])
        fixture.model.dshBridgeStatesByScope[fixture.endpoint.sourceScope] = .init(
            endpoint: old.endpoint,
            authority: .init(homeID: old.endpoint.homeID, profile: old.endpoint.profile, runtimeID: "restarted-runtime"),
            catalog: old.catalog, error: nil
        )
        await read.value
        XCTAssertNil(fixture.model.supervisorSnapshot(for: fixture.card))
        XCTAssertTrue(fixture.model.supervisorBusyThreadIDs.isEmpty)
    }

    @MainActor
    private struct Fixture {
        let suite = "HarvisRuntimeSupervisorTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let model: HarvisRuntimeModel
        let endpoint = DshRuntimeEndpoint(homeID: "fixture-home", profile: "web", port: 8123)
        let card: ManagedChatThread
        let transport = SupervisorRuntimeTransport()

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            model = HarvisRuntimeModel(defaults: defaults)
            card = ManagedChatThread(
                provider: .dsh, sourceScope: endpoint.sourceScope, sourceID: "fixture-session",
                title: "Synthetic card", titleSource: "fixture", hasMeaningfulTitle: true,
                createdAt: 1, updatedAt: 2, tokensUsed: 0, model: "fixture", cwd: "/synthetic/supervisor",
                archived: false, running: false, sourceStatus: "idle", threadSource: "fixture",
                agentNickname: nil, agentRole: nil, agentPath: nil, parentThreadID: nil,
                rootThreadId: "fixture-session", isSubagent: false, isSidechat: false,
                activity: .init(main: 0, subagent: 0, sidechat: nil), trustProjection: .init(state: .idle, reason: "Fixture")
            )
            model.dshThreads = [card]
            model.dshRunningEndpoints = [endpoint]
            model.dshBridgeStatesByScope[endpoint.sourceScope] = .init(
                endpoint: endpoint,
                authority: .init(homeID: endpoint.homeID, profile: endpoint.profile, runtimeID: "fixture-runtime"),
                catalog: .init(schemaVersion: "harvis.dsh-capabilities.v1", bridgeVersion: "0.2.0", capabilities: [
                    .init(id: "supervisor.session", version: 1, title: "Supervisor", scope: "session",
                          operations: ["state", "set", "adopt", "regenerate", "recover"], availability: .available,
                          reason: nil, requiresApproval: false, supportsCancel: true)
                ]), error: nil
            )
            let wire = transport
            model.makeDshBridgeClient = { DshCapabilityBridgeClient(endpoint: $0, transport: wire) }
        }

        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}

private actor SupervisorRuntimeTransport: DshHostTransport {
    private var recordedMethods: [String] = []
    private var mode = "off"
    private var revisionCharacter = "a"
    private var shouldFailMutation = false
    private var delay: UInt64 = 0

    func methods() -> [String] { recordedMethods }
    func setDelay(_ value: UInt64) { delay = value }
    func failNextMutation() { shouldFailMutation = true }

    func send(_ request: URLRequest) async throws -> DshHostTransportResponse {
        let body = try XCTUnwrap(request.httpBody)
        let rpc = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let method = try XCTUnwrap(rpc["method"] as? String)
        let requestID = try XCTUnwrap(rpc["requestId"] as? String)
        let params = try XCTUnwrap(rpc["params"] as? [String: Any])
        XCTAssertEqual(request.url?.port, 8123)
        XCTAssertEqual(params["sessionId"] as? String, "fixture-session")
        XCTAssertEqual(params["expectedRuntimeId"] as? String, "fixture-runtime")
        recordedMethods.append(method)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if method == "supervisor.session.set" {
            XCTAssertEqual(params["expectedRevision"] as? String, "sha256:" + String(repeating: revisionCharacter, count: 64))
            let patch = try XCTUnwrap(params["patch"] as? [String: Any])
            mode = try XCTUnwrap(patch["mode"] as? String)
            revisionCharacter = "b"
            if shouldFailMutation {
                shouldFailMutation = false
                throw URLError(.timedOut)
            }
        }
        let value: [String: Any] = [
            "schemaVersion": "harvis.dsh-supervisor.v1", "sessionId": "fixture-session",
            "revision": "sha256:" + String(repeating: revisionCharacter, count: 64),
            "mode": mode, "strategy": "plan", "rounds": 3, "used": 0, "remaining": 3,
            "intervalMs": 60_000, "status": mode == "off" ? "off" : "silent", "suggestion": "",
            "suggestionId": "", "runId": "fixture-run", "recoveryRequired": "", "done": false,
            "agentStatus": "idle", "mentorName": "Fixture", "suggestError": "",
        ]
        let envelope: [String: Any] = [
            "schemaVersion": "harvis.dsh-bridge.v1", "requestId": requestID,
            "authority": ["homeID": "fixture-home", "profile": "web", "runtimeId": "fixture-runtime"],
            "result": ["ok": true, "value": value],
        ]
        return .init(data: try JSONSerialization.data(withJSONObject: envelope), statusCode: 200)
    }
}
