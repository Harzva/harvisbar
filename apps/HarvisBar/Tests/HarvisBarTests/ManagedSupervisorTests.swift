import AppKit
import SwiftUI
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedSupervisorTests: XCTestCase {
    func testInstalledSupervisorWireProjectionWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["HARVIS_SUPERVISOR_WIRE_OUTPUT"] else {
            throw XCTSkip("Set HARVIS_SUPERVISOR_WIRE_OUTPUT to the isolated real-plugin fixture result")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["schemaVersion"] as? String, DshCapabilityBridgeClient.schemaVersion)
        let authorityObject = try XCTUnwrap(envelope["authority"] as? [String: Any])
        let authority = try JSONDecoder().decode(DshBridgeAuthority.self, from: JSONSerialization.data(withJSONObject: authorityObject))
        try authority.validate(for: .init(homeID: "fixture-home", profile: "fixture-profile", port: 1))
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let value = try XCTUnwrap(result["value"] as? [String: Any])
        let projection = try JSONDecoder().decode(DshSupervisorState.self, from: JSONSerialization.data(withJSONObject: value))
        try projection.validate(expectedSessionID: "fixture-supervisor-session")
        XCTAssertFalse(projection.runID.isEmpty)
    }

    func testCardCompatibilityNeverPromotesOtherProviderOrChildToDshControl() {
        XCTAssertEqual(ManagedSupervisorCompatibility.resolve(thread()), .dsh)
        XCTAssertEqual(ManagedSupervisorCompatibility.resolve(thread(provider: .codex)), .codexProject)
        for card in [thread(provider: .workBuddy), thread(child: true), thread(archived: true)] {
            guard case .observation = ManagedSupervisorCompatibility.resolve(card) else {
                return XCTFail("Unsupported card acquired a control route")
            }
        }
    }

    func testSameSessionIDInOtherScopeAndHostRestartInvalidateCachedControl() throws {
        let suite = "ManagedSupervisorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let endpoint = DshRuntimeEndpoint(homeID: "fixture", profile: "web", port: 8123)
        let card = thread(scope: endpoint.sourceScope)
        let authority = DshBridgeAuthority(homeID: endpoint.homeID, profile: endpoint.profile, runtimeID: "runtime-a")
        let catalog = DshCapabilityCatalog(
            schemaVersion: DshCapabilityCatalog.supportedSchemaVersion, bridgeVersion: "0.2.0",
            capabilities: [.init(id: "supervisor.session", version: 1, title: "Supervisor", scope: "session",
                                 operations: ["state", "set", "regenerate", "adopt", "recover"],
                                 availability: .available, reason: nil, requiresApproval: false, supportsCancel: true)]
        )
        model.dshThreads = [card]
        model.dshRunningEndpoints = [endpoint]
        model.dshBridgeStatesByScope[endpoint.sourceScope] = .init(endpoint: endpoint, authority: authority, catalog: catalog, error: nil)
        model.supervisorSnapshots[card.id] = .init(endpoint: endpoint, authority: authority, state: try state(), readAt: Date())
        XCTAssertNotNil(model.supervisorEndpoint(for: card))
        XCTAssertNotNil(model.supervisorSnapshot(for: card))
        XCTAssertNil(model.supervisorEndpoint(for: thread(scope: "dsh::another-account::web")))
        XCTAssertNil(model.supervisorEndpoint(for: thread(provider: .codex, scope: endpoint.sourceScope)))
        model.dshBridgeStatesByScope[endpoint.sourceScope] = .init(
            endpoint: endpoint,
            authority: .init(homeID: endpoint.homeID, profile: endpoint.profile, runtimeID: "runtime-b"),
            catalog: catalog, error: nil
        )
        XCTAssertNil(model.supervisorSnapshot(for: card), "Old runtime must not supply action authority")
        model.dshRunningEndpoints.append(.init(homeID: "fixture", profile: "web", port: 8124))
        XCTAssertNil(model.supervisorEndpoint(for: card), "Same-scope ports cannot be guessed")
    }

    func testSuggestionActionsRequireReadyNativeSessionAndRemainingBudget() throws {
        XCTAssertTrue(try state().canAdopt)
        XCTAssertTrue(try state().canRegenerate)
        for changes: [String: Any] in [
            ["mode": "off"], ["done": true], ["remaining": 0],
            ["status": "working"], ["status": "thinking"],
            ["agentStatus": "waitingApproval"], ["agentStatus": "pendingApproval"],
            ["agentStatus": "pending-approval"], ["recoveryRequired": "delivery requires reconciliation"],
        ] {
            let projection = try state(changes)
            XCTAssertFalse(projection.canAdopt)
            XCTAssertFalse(projection.canRegenerate)
        }
        XCTAssertFalse(try state(["suggestionId": ""]).canAdopt)
    }

    func testRenderSupervisorStatesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["HARVIS_SUPERVISOR_PREVIEW"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, ManagedSupervisorCompatibility, DshSupervisorState?, String?)] = [
            ("dsh-advice", .dsh, try state(), nil),
            ("dsh-off-three", .dsh, try state(["mode": "off", "rounds": 3, "used": 0, "remaining": 3, "status": "off"]), nil),
            ("dsh-off-three-large", .dsh, try state(["mode": "off", "rounds": 3, "used": 0, "remaining": 3, "status": "off"]), nil),
            ("dsh-recovery", .dsh, try state(["status": "recovery", "recoveryRequired": "上次建议的送达结果需要核对。"]), nil),
            ("dsh-unavailable", .dsh, nil, "此 DSH 实例的 Supervisor 桥接尚未就绪。"),
            ("codex-project", .codexProject, nil, nil),
            ("codex-project-large", .codexProject, nil, nil),
            ("workbuddy-observation", .observation("WorkBuddy 目前提供会话状态观察，尚未提供 Supervisor 控制接口。"), nil, nil),
        ]
        for (name, compatibility, projection, error) in cases {
            let panel = ManagedSupervisorPanel(
                title: "Example · 验证项目交付与会话进展", source: "DSH · fixture/web",
                sessionID: "synthetic-session", compatibility: compatibility, state: projection,
                readAt: Date(timeIntervalSince1970: 1_800_000_000), error: error, busy: false,
                readReady: projection != nil && error == nil,
                availableOperations: Set(DshSupervisorOperation.allCases.map(\.rawValue)), theme: .paper,
                onRefresh: {}, onAction: { _, _ in }, onOpenSession: {}, onOpenProject: {}, onClose: {}
            )
            let textSize: HarvisTextSize = name.hasSuffix("-large") ? .large : .medium
            let size = NSSize(width: textSize == .large ? 660 : 600, height: compatibility == .dsh ? 690 : 430)
            let hosting = NSHostingView(rootView: panel.environment(\.harvisTextSize, textSize))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderOut(nil)
            defer { window.contentView = nil; window.close() }
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private func state(_ changes: [String: Any] = [:]) throws -> DshSupervisorState {
        var object: [String: Any] = [
            "schemaVersion": "harvis.dsh-supervisor.v1", "sessionId": "synthetic-session",
            "revision": "sha256:" + String(repeating: "a", count: 64), "mode": "advice", "strategy": "plan",
            "rounds": 8, "used": 1, "remaining": 7, "intervalMs": 60_000, "status": "suggested",
            "suggestion": "先检查当前变更与验收目标。\n验证通过后记录交付结果。", "suggestionId": "suggestion-1",
            "runId": "run-1", "recoveryRequired": "", "done": false, "agentStatus": "idle",
            "mentorName": "项目导师", "suggestError": "",
        ]
        object.merge(changes) { _, new in new }
        return try JSONDecoder().decode(DshSupervisorState.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func thread(
        provider: ManagedChatProvider = .dsh, scope: String = "dsh::fixture::web",
        child: Bool = false, archived: Bool = false
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider, sourceScope: scope, sourceID: "synthetic-session", title: "Synthetic session",
            titleSource: "fixture", hasMeaningfulTitle: true, createdAt: 1, updatedAt: 2,
            tokensUsed: 0, model: "fixture", cwd: "/synthetic/supervisor", archived: archived, running: false,
            sourceStatus: "idle", threadSource: "fixture", agentNickname: nil, agentRole: nil, agentPath: nil,
            parentThreadID: child ? "parent" : nil, rootThreadId: "root", isSubagent: child, isSidechat: false,
            activity: .init(main: 0, subagent: 0, sidechat: nil),
            trustProjection: .init(state: .idle, reason: "Fixture")
        )
    }
}
