import AppKit
import SwiftUI
import XCTest
@testable import HarvisBar

/// Opt-in native render fixture for the overview's range and width states.
/// Set HARVIS_SUPERVISOR_OVERVIEW_PREVIEW to a writable directory when
/// packaging a visual candidate; ordinary test runs skip the bitmap output.
@MainActor
final class ManagedSupervisorOverviewRenderTests: XCTestCase {
    func testRenderOverviewNarrowWideEmptyAndMixedSourcesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["HARVIS_SUPERVISOR_OVERVIEW_PREVIEW"] else {
            return
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let suite = "ManagedSupervisorOverviewRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let mixed = try configureMixedModel(model)
        let cases: [(String, NSSize, [ManagedChatThread])] = [
            ("overview-narrow", NSSize(width: 520, height: 560), mixed),
            ("overview-wide", NSSize(width: 940, height: 680), mixed),
            ("overview-empty", NSSize(width: 520, height: 560), []),
            ("overview-mixed", NSSize(width: 760, height: 640), mixed),
        ]

        for (name, size, threads) in cases {
            let view = ManagedSupervisorOverviewView(
                threads: threads,
                theme: .paper,
                onOpenCard: { _ in },
                onBack: {}
            )
            let hosting = NSHostingView(rootView: view.environmentObject(model))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderOut(nil)
            defer {
                window.contentView = nil
                window.close()
            }

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

    private func configureMixedModel(_ model: HarvisRuntimeModel) throws -> [ManagedChatThread] {
        let codex = fixtureThread(
            provider: .codex, scope: "fixture-codex", id: "codex-session",
            title: "Codex 项目整理", cwd: "/tmp/fixture-project"
        )
        let dsh = fixtureThread(
            provider: .dsh, scope: "dsh::fixture::web", id: "dsh-session",
            title: "DSH 监督会话", cwd: "/tmp/fixture-project"
        )
        let staleDsh = fixtureThread(
            provider: .dsh, scope: "dsh::fixture::cli", id: "stale-session",
            title: "待刷新 DSH 会话", cwd: "/tmp/fixture-project-cli"
        )
        let workBuddy = fixtureThread(
            provider: .workBuddy, scope: ManagedChatSourceScope.workBuddyLocal,
            id: "workbuddy-session", title: "WorkBuddy 观察会话", cwd: "/tmp/fixture-project"
        )
        let workBuddySummary = WorkBuddyThreadSummary(
            id: workBuddy.sourceID, title: workBuddy.title,
            createdAt: workBuddy.createdAt, updatedAt: workBuddy.updatedAt,
            tokensUsed: workBuddy.tokensUsed, model: workBuddy.model,
            cwd: workBuddy.cwd, archived: workBuddy.archived,
            running: workBuddy.running, sourceStatus: workBuddy.sourceStatus ?? "idle"
        )

        model.codexHomes = [fixtureHome()]
        model.dshThreads = [dsh, staleDsh]
        model.workBuddyThreads = [workBuddySummary]
        let endpoint = DshRuntimeEndpoint(homeID: "fixture", profile: "web", port: 8123)
        let staleEndpoint = DshRuntimeEndpoint(homeID: "fixture", profile: "cli", port: 8124)
        model.dshRunningEndpoints = [endpoint, staleEndpoint]
        let authority = DshBridgeAuthority(homeID: endpoint.homeID, profile: endpoint.profile, runtimeID: "fixture-runtime")
        let staleAuthority = DshBridgeAuthority(homeID: staleEndpoint.homeID, profile: staleEndpoint.profile, runtimeID: "fixture-runtime-cli")
        let catalog = DshCapabilityCatalog(
            schemaVersion: DshCapabilityCatalog.supportedSchemaVersion,
            bridgeVersion: "fixture",
            capabilities: [
                .init(id: "supervisor.session", version: 1, title: "Supervisor", scope: "session",
                      operations: ["state", "set"], availability: .available,
                      reason: nil, requiresApproval: false, supportsCancel: true)
            ]
        )
        model.dshBridgeStatesByScope[endpoint.sourceScope] = .init(
            endpoint: endpoint, authority: authority, catalog: catalog, error: nil
        )
        model.dshBridgeStatesByScope[staleEndpoint.sourceScope] = .init(
            endpoint: staleEndpoint, authority: staleAuthority, catalog: catalog, error: nil
        )
        model.supervisorSnapshots[dsh.id] = .init(
            endpoint: endpoint, authority: authority, state: try fixtureState(sessionID: dsh.sourceID),
            readAt: Date()
        )
        model.supervisorSnapshots[staleDsh.id] = .init(
            endpoint: staleEndpoint, authority: staleAuthority,
            state: try fixtureState(sessionID: staleDsh.sourceID),
            readAt: Date(timeIntervalSinceNow: -120)
        )
        model.supervisorErrors[staleDsh.id] = "示例连接错误；需要刷新核对。"

        // Keep the mixed-source render independent from adapter decoding while
        // still giving the view the same source catalog it uses in production.
        return [codex, dsh, staleDsh, workBuddy]
    }

    private func fixtureHome() -> CodexHome {
        CodexHome(
            id: "fixture-codex", label: "Codex Fixture", accountNote: "主账号",
            path: "/tmp/fixture-codex", source: "default", model: "fixture",
            provider: "openai", endpointHost: nil, hasAuth: true,
            accountEmail: "fixture@example.com", authStatus: "valid",
            authExpiresAt: nil, authNote: nil, hasConfig: true, skillCount: 0,
            quotaMode: "subscription", quotaNote: nil
        )
    }

    private func fixtureThread(
        provider: ManagedChatProvider,
        scope: String,
        id: String,
        title: String,
        cwd: String
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider, sourceScope: scope, sourceID: id, title: title,
            titleSource: "fixture", hasMeaningfulTitle: true, createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100, tokensUsed: 120, model: "fixture", cwd: cwd,
            archived: false, running: false, sourceStatus: "idle", threadSource: "fixture",
            agentNickname: nil, agentRole: nil, agentPath: nil, parentThreadID: nil,
            rootThreadId: id, isSubagent: false, isSidechat: false,
            activity: .init(main: 0, subagent: 0, sidechat: nil),
            trustProjection: .init(state: .idle, reason: "render fixture")
        )
    }

    private func fixtureState(sessionID: String) throws -> DshSupervisorState {
        let object: [String: Any] = [
            "schemaVersion": DshSupervisorState.supportedSchemaVersion,
            "sessionId": sessionID,
            "revision": "sha256:" + String(repeating: "a", count: 64),
            "mode": "advice", "strategy": "plan", "rounds": 8, "used": 1,
            "intervalMs": 60_000, "status": "silent", "suggestion": "",
            "suggestionId": "", "runId": "fixture-run", "recoveryRequired": "",
            "done": false, "remaining": 7, "agentStatus": "idle",
            "mentorName": "项目导师", "suggestError": ""
        ]
        return try JSONDecoder().decode(
            DshSupervisorState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
