import AppKit
import SwiftUI
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedChatDisplayScopeTests: XCTestCase {
    func testAllCodexHomesAndDshShareOneProjectGroupByCanonicalPath() throws {
        let suiteName = "ManagedChatDisplayScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-unified-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: project) }

        let homeA = codexHome(id: "home-a", email: "a@example.test")
        let homeB = codexHome(id: "home-b", email: "b@example.test")
        let model = HarvisRuntimeModel(defaults: defaults)
        model.codexHomes = [homeA, homeB]
        model.selectedCodexHomeID = homeA.id
        model.acceptCodexThreads(
            [codexThread(id: "same-native-id", cwd: project.path, title: "A")],
            sourceHomeID: homeA.id
        )
        model.acceptCodexThreads(
            [codexThread(id: "same-native-id", cwd: project.path, title: "B")],
            sourceHomeID: homeB.id
        )

        let dsh = ManagedChatThread(
            provider: .dsh,
            sourceScope: "dsh::home::web",
            sourceID: "dsh-session",
            title: "DSH",
            titleSource: "fixture",
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: -1,
            model: nil,
            cwd: project.path + "/.",
            archived: false,
            running: false,
            sourceStatus: "idle",
            threadSource: "dsh",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: "dsh-root",
            isSubagent: false,
            isSidechat: false,
            activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(
                state: .idle,
                reason: "fixture"
            )
        )
        model.dshThreads = [dsh]
        XCTAssertFalse(dsh.capabilities.supportsCodexDispatch)
        let mixedScope = ManagedChatDisplayScope(providers: ["codex", "dsh"], codexHomeIDs: [homeB.id])
        XCTAssertTrue(mixedScope.includes(dsh))
        XCTAssertEqual(model.managedChatThreads.filter(mixedScope.includes).count, 2)

        let threads = model.managedChatThreads
        XCTAssertEqual(threads.filter(\.isCodex).count, 2)
        XCTAssertEqual(threads.filter(\.isDsh).count, 1)
        XCTAssertEqual(
            Set(threads.map { ManagedChatProjectResolver.resolve(thread: $0).id }).count,
            1
        )
        XCTAssertEqual(
            Set(threads.map(model.managedChatStorageKey)).count,
            3
        )
        XCTAssertEqual(model.codexHome(for: threads[0])?.id, homeA.id)
        XCTAssertTrue(threads.contains { $0.title == "B" && $0.sourceScope == homeB.id })
    }

    func testDisplayScopeSupportsSingleMultipleEmptyAndSavedDefaultSelections() throws {
        let a = ManagedChatThread(codex: codexThread(id: "same", cwd: "/tmp/project", title: "A"), sourceScope: "a")
        let b = ManagedChatThread(codex: codexThread(id: "same", cwd: "/tmp/project", title: "B"), sourceScope: "b")
        var scope = ManagedChatDisplayScope.all
        XCTAssertTrue(scope.includes(a))
        XCTAssertTrue(scope.includes(b))
        scope.toggleHome("a", availableIDs: ["a", "b"])
        XCTAssertFalse(scope.includes(a))
        XCTAssertTrue(scope.includes(b))
        scope.toggleHome("b", availableIDs: ["a", "b"])
        XCTAssertFalse(scope.includes(a))
        XCTAssertFalse(scope.includes(b))
        XCTAssertEqual(ManagedChatDisplayScope.decode(scope.encoded), scope)
        scope.toggleProvider(.codex)
        scope.codexHomeIDs = nil
        XCTAssertFalse(scope.includes(a))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DisplayScope.\(UUID().uuidString)"))
        let saved = ManagedChatDisplayScope(providers: ["codex", "dsh"], codexHomeIDs: ["b"])
        defaults.set(saved.encoded, forKey: ManagedChatDisplayScope.defaultKey)
        XCTAssertEqual(ManagedChatDisplayScope.decode(defaults.string(forKey: ManagedChatDisplayScope.defaultKey)!), saved)
        defaults.removeObject(forKey: ManagedChatDisplayScope.defaultKey)
        XCTAssertEqual(ManagedChatDisplayScope.decode("corrupt"), .all)
        // A removed account must not cause an explicit selection to widen.
        XCTAssertFalse(ManagedChatDisplayScope(providers: ["codex"], codexHomeIDs: ["removed"]).includes(a))
    }

    func testCardOriginLookupRejectsHiddenUnknownAndMissingThreads() throws {
        let suite = "DisplayScope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let a = codexHome(id: "a", email: "a@example.test")
        let b = codexHome(id: "b", email: "b@example.test")
        model.codexHomes = [a, b]
        model.selectedCodexHomeID = a.id
        let nativeA = codexThread(id: "same", cwd: "/tmp/project", title: "A")
        let nativeB = codexThread(id: "same", cwd: "/tmp/project", title: "B")
        model.acceptCodexThreads([nativeA], sourceHomeID: a.id)
        model.acceptCodexThreads([nativeB], sourceHomeID: b.id)
        let cardB = try XCTUnwrap(model.managedChatThreads.first { $0.sourceScope == b.id })
        XCTAssertEqual(model.codexThread(for: cardB)?.title, "B")
        XCTAssertEqual(model.codexHome(for: cardB)?.path, b.path)
        XCTAssertEqual(model.selectedCodexHomeID, a.id)
        model.hiddenCodexHomeIDs = [b.id]
        XCTAssertNil(model.codexHome(for: cardB))
        XCTAssertNil(model.codexThread(for: cardB))
        XCTAssertFalse(model.managedChatThreads.contains { $0.sourceScope == b.id })
        model.hiddenCodexHomeIDs = []
        XCTAssertEqual(model.codexHome(for: cardB)?.id, b.id)
        model.acceptCodexThreads([], sourceHomeID: b.id)
        XCTAssertNil(model.codexHome(for: cardB))
    }

    func testAccountSelectionIsIsolatedByProviderAndSurvivesProviderToggles() {
        let codex = ManagedChatThread(codex: codexThread(id: "same", cwd: "/tmp/project", title: "Codex"), sourceScope: "local")
        let dsh = sourceThread(provider: .dsh, scope: "local")
        let workBuddy = sourceThread(provider: .workBuddy, scope: "local")
        var scope = ManagedChatDisplayScope.all
        scope.toggleAccount("local", provider: .dsh, availableIDs: ["local", "other"])
        XCTAssertTrue(scope.includes(codex))
        XCTAssertFalse(scope.includes(dsh))
        XCTAssertTrue(scope.includes(workBuddy))
        scope.toggleProvider(.dsh)
        scope.toggleProvider(.dsh)
        XCTAssertFalse(scope.includes(dsh), "Re-selecting an agent must preserve its account choices")
        XCTAssertEqual(ManagedChatDisplayScope.decode(scope.encoded), scope)
        scope.clearAccounts(provider: .workBuddy)
        XCTAssertFalse(scope.includes(workBuddy))
        XCTAssertTrue(scope.includes(codex))
        scope.setAllAccounts(provider: .dsh)
        XCTAssertTrue(scope.includes(dsh))
        XCTAssertFalse(scope.includes(workBuddy), "All accounts only affects the requested agent")
        scope.setAllAccounts(provider: .workBuddy)
        XCTAssertEqual(scope, .all)
    }

    func testLegacySavedScopeAndNewSourcesKeepExplicitSelection() {
        let oldJSON = #"{"providers":["codex","dsh"],"codexHomeIDs":["a"]}"#
        var scope = ManagedChatDisplayScope.decode(oldJSON)
        XCTAssertEqual(scope.providers, ["codex", "dsh"])
        XCTAssertTrue(scope.includesHome("a"))
        XCTAssertFalse(scope.includesHome("b"))
        XCTAssertTrue(scope.includes(sourceThread(provider: .dsh, scope: "web")))
        scope.toggleAccount("web", provider: .dsh, availableIDs: ["web", "research"])
        XCTAssertFalse(scope.includes(sourceThread(provider: .dsh, scope: "new-profile")))
        scope.clearAccounts(provider: .dsh)
        let restored = ManagedChatDisplayScope.decode(scope.encoded)
        XCTAssertFalse(restored.includes(sourceThread(provider: .dsh, scope: "research")))
        XCTAssertTrue(restored.includesHome("a"))
    }

    func testAccountCatalogIncludesEmptyHomesAndEndpointsWithoutDuplicateSources() {
        let home = codexHome(id: "empty-home", email: "empty@example.test")
        let endpoint = DshRuntimeEndpoint(homeID: "local", profile: "web", port: 1234)
        let anotherPort = DshRuntimeEndpoint(homeID: "local", profile: "web", port: 5678)
        let emptyEndpoint = DshRuntimeEndpoint(homeID: "local", profile: "research", port: 5679)
        let dsh = sourceThread(provider: .dsh, scope: endpoint.sourceScope)
        let buddy = sourceThread(provider: .workBuddy, scope: "local")
        let accounts = ManagedChatDisplayAccount.catalog(
            homes: [home], dshEndpoints: [endpoint, anotherPort, emptyEndpoint], threads: [dsh, buddy]
        )
        XCTAssertEqual(accounts.count, 4)
        XCTAssertEqual(Set(accounts.map(\.id)).count, 4)
        XCTAssertEqual(accounts.first?.provider, .codex)
        XCTAssertEqual(accounts.first?.threadCount, 0)
        XCTAssertEqual(accounts.first { $0.sourceScope == endpoint.sourceScope }?.threadCount, 1)
        XCTAssertEqual(accounts.first { $0.sourceScope == emptyEndpoint.sourceScope }?.threadCount, 0)
        XCTAssertEqual(accounts.last?.label, "本地会话")
        let disconnected = ManagedChatDisplayAccount.catalog(homes: [], dshEndpoints: [], threads: [dsh])
        XCTAssertEqual(disconnected.first?.id, "dsh::\(endpoint.sourceScope)")
        XCTAssertEqual(disconnected.first?.label, "local / web")
    }

    func testRenderSyntheticMixedAccountPreviewWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["HARVIS_DISPLAY_SCOPE_PREVIEW"] else { return }
        let suite = "DisplayScopePreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("matrix", forKey: "harvis.codex.chatManager.layout")
        let model = HarvisRuntimeModel(defaults: defaults)
        let a = codexHome(id: "research", email: "account6266@example.test", note: "6266")
        let b = codexHome(id: "design", email: "18700000001@example.test")
        let c = codexHome(id: "personal", email: "pengxxx@example.test")
        model.codexHomes = [a, b, c]
        model.selectedCodexHomeID = a.id
        model.acceptCodexThreads([codexThread(id: "same-id", cwd: "/tmp/shared-project", title: "研究需求与项目规划")], sourceHomeID: a.id)
        model.acceptCodexThreads([codexThread(id: "same-id", cwd: "/tmp/shared-project", title: "设计实现与界面检查")], sourceHomeID: b.id)
        model.acceptCodexThreads([codexThread(id: "personal-id", cwd: "/tmp/shared-project", title: "个人账号会话")], sourceHomeID: c.id)
        let nativeDsh = ManagedChatThread(
            provider: .dsh, sourceScope: "dsh::默认::web", sourceID: "dsh-session",
            title: "DSH 项目资料整理", titleSource: "fixture", hasMeaningfulTitle: true,
            createdAt: 1_700_000_000, updatedAt: 1_700_000_100, tokensUsed: -1,
            model: nil, cwd: "/tmp/shared-project", archived: false, running: false,
            sourceStatus: "idle", threadSource: "dsh", agentNickname: nil,
            agentRole: nil, agentPath: nil, parentThreadID: nil, rootThreadId: "dsh-root",
            isSubagent: false, isSidechat: false,
            activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(state: .idle, reason: "fixture")
        )
        model.dshThreads = [nativeDsh]
        model.dshRunningEndpoints = [DshRuntimeEndpoint(homeID: "默认", profile: "web", port: 1234)]
        model.workBuddyThreads = [WorkBuddyThreadSummary(
            id: "buddy-local", title: "本地项目资料", createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100, tokensUsed: 0, model: nil,
            cwd: "/tmp/shared-project", archived: false, running: false, sourceStatus: "idle"
        )]
        let variants: [(String, CGFloat, ManagedChatDisplayScope, HarvisTheme)] = [
            ("-paper", 960, .all, .paper),
            ("-ink", 960, .all, .ink),
            ("-forest", 960, .all, .forest),
            ("-narrow", 640, .all, .paper),
            ("-minimum", 480, .all, .paper),
            ("-font-small", 1440, .all, .paper),
            ("-font-medium", 1440, .all, .paper),
            ("-font-large", 1440, .all, .paper),
            ("-large-full-cards", 1440, .all, .paper),
            ("-large-narrow", 640, .all, .paper),
            ("-large-minimum", 480, .all, .paper),
            ("-layout-bottom", 1200, .all, .paper),
            ("-layout-right", 1560, .all, .paper),
            ("-selected", 960, ManagedChatDisplayScope(providers: ["codex"], codexHomeIDs: [a.id]), .paper),
            ("-empty", 640, ManagedChatDisplayScope(providers: []), .ink),
            ("-many", 960, .all, .paper),
            ("-collapsed", 640, .all, .paper),
            ("-sidechat", 640, ManagedChatDisplayScope(providers: ["codex"], codexHomeIDs: [a.id]), .paper),
            ("-graph", 1200, .all, .paper),
            ("-graph-narrow", 640, .all, .ink)
        ]
        for (suffix, width, scope, theme) in variants {
            model.themeID = theme.rawValue
            defaults.set(suffix.contains("large") ? "large" : (suffix.contains("small") ? "small" : "medium"), forKey: "harvis.codex.chatManager.textSize")
            defaults.set(suffix == "-layout-bottom" ? "bottom" : (suffix == "-layout-right" ? "right" : "automatic"), forKey: "harvis.codex.chatManager.workbenchPlacement")
            defaults.set(suffix.hasPrefix("-layout"), forKey: "harvis.codex.chatManager.workbenchExpanded")
            let previewProject = ManagedChatProjectResolver.resolve(thread: nativeDsh)
            defaults.set(suffix.hasPrefix("-layout") ? previewProject.id : "", forKey: "harvis.codex.chatManager.selectedProjectID")
            var researchThreads = [codexThread(id: "same-id", cwd: "/tmp/shared-project", title: "研究需求与项目规划")]
            if suffix == "-sidechat" || suffix.hasPrefix("-graph") {
                researchThreads += [
                    codexThread(id: "review-child", cwd: "/tmp/shared-project", title: "检查实现与验证证据",
                                source: "subagent", parent: "same-id", nickname: "Reviewer"),
                    codexThread(id: "sidechat-notes", cwd: "/tmp/shared-project", title: "补充讨论与待办事项",
                                source: "sidechat", parent: "same-id"),
                    codexThread(id: "missing-parent-child", cwd: "/tmp/shared-project", title: "父会话暂未载入的任务",
                                source: "subagent", parent: "not-loaded", nickname: "Researcher")
                ]
            }
            model.acceptCodexThreads(researchThreads, sourceHomeID: a.id)
            model.codexHomes = [a, b, c] + (suffix == "-many" ? (1...8).map {
                codexHome(id: "account-with-long-name-\($0)", email: "account-\($0)@example.test")
            } : [])
            defaults.set(scope.encoded, forKey: ManagedChatDisplayScope.selectionKey)
            defaults.set(suffix != "-collapsed", forKey: CodexComposerVisibilityPolicy.isVisibleDefaultsKey)
            defaults.set(suffix.hasPrefix("-graph") ? "relationships" : "structure",
                         forKey: "harvis.codex.chatManager.projectDisplayMode")
            let view = NSHostingView(rootView: HarvisCodexChatManagerView()
                .environmentObject(model).defaultAppStorage(defaults))
            let rect = NSRect(x: 0, y: 0, width: width, height: suffix == "-large-full-cards" ? 1700 : 1040)
            let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderOut(nil)
            view.frame = rect
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let base = URL(fileURLWithPath: output).deletingPathExtension().path
            try data.write(to: URL(fileURLWithPath: base + suffix + ".png"))
            window.contentView = nil
            window.close()
        }
        XCTAssertEqual(model.selectedCodexHomeID, a.id)
    }

    func testCompactLabelsPreferAccountIdentityAndPreserveFullDetails() {
        let homes = [
            codexHome(id: "research", email: "account6266@example.test", note: "6266"),
            codexHome(id: "design", email: "18700006266@example.test"),
            codexHome(id: "poom", email: "pengxxx@example.test", note: "poom"),
            codexHome(id: "offline", email: "", note: "本地")
        ]
        let accounts = ManagedChatDisplayAccount.catalog(homes: homes, dshEndpoints: [], threads: [])
        let labels = Dictionary(uniqueKeysWithValues: accounts.map { ($0.sourceScope, $0.label) })
        XCTAssertEqual(labels["research"], "6266")
        XCTAssertEqual(labels["design"], "187…6266")
        XCTAssertEqual(labels["poom"], "pengxxx")
        XCTAssertEqual(labels["offline"], "本地")
        XCTAssertTrue(accounts.first { $0.sourceScope == "design" }!.detail.contains("18700006266@example.test"))
    }

    func testCompactLabelCollisionsKeepDistinctStableAccountChoices() {
        let a = codexHome(id: "a", email: "shared@example.test")
        let b = codexHome(id: "b", email: "shared@example.test")
        let forward = ManagedChatDisplayAccount.catalog(homes: [a, b], dshEndpoints: [], threads: [])
        let reversed = ManagedChatDisplayAccount.catalog(homes: [b, a], dshEndpoints: [], threads: [])
        XCTAssertEqual(forward.map(\.label), ["shared · 1", "shared · 2"])
        XCTAssertEqual(forward.map(\.label), reversed.map(\.label))
        XCTAssertEqual(Set(forward.map(\.id)).count, 2)
        XCTAssertTrue(forward[0].detail.contains("来源：a"))
        let scope = ManagedChatDisplayScope(providers: ["codex"], codexHomeIDs: [a.id])
        XCTAssertTrue(scope.includesAccount(forward[0].sourceScope, provider: .codex))
        XCTAssertFalse(scope.includesAccount(forward[1].sourceScope, provider: .codex))
    }

    func testDisplayCatalogCacheRefreshesOnAccountsThreadsAndEndpoints() throws {
        let suite = "DisplayCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let home = codexHome(id: "home", email: "one@example.test")
        model.codexHomes = [home]
        XCTAssertEqual(model.managedChatDisplayAccounts.first?.threadCount, 0)
        model.acceptCodexThreads([codexThread(id: "chat", cwd: "/tmp/project", title: "A")], sourceHomeID: home.id)
        XCTAssertEqual(model.managedChatDisplayAccounts.first?.threadCount, 1)
        XCTAssertEqual(model.managedChatThreads.first?.title, "A")
        model.acceptCodexThreads([codexThread(id: "chat", cwd: "/tmp/project", title: "B")], sourceHomeID: home.id)
        XCTAssertEqual(model.managedChatThreads.first?.title, "B")
        model.codexHomes = [codexHome(id: "home", email: "one@example.test", note: "6266")]
        XCTAssertEqual(model.managedChatDisplayAccounts.first?.label, "6266")
        model.hiddenCodexHomeIDs = [home.id]
        XCTAssertTrue(model.managedChatDisplayAccounts.isEmpty)
        XCTAssertTrue(model.managedChatThreads.isEmpty)
        model.hiddenCodexHomeIDs = []
        let endpoint = DshRuntimeEndpoint(homeID: "fixture", profile: "web", port: 1234)
        model.dshRunningEndpoints = [endpoint]
        XCTAssertEqual(model.managedChatDisplayAccounts.count, 2)
        model.dshThreads = [sourceThread(provider: .dsh, scope: endpoint.sourceScope)]
        XCTAssertEqual(model.managedChatDisplayAccounts.last?.threadCount, 1)
        model.dshThreads = []
        model.dshRunningEndpoints = []
        XCTAssertEqual(model.managedChatDisplayAccounts.count, 1)
    }

    private func codexHome(id: String, email: String, note: String? = nil) -> CodexHome {
        CodexHome(
            id: id,
            label: id,
            accountNote: note,
            path: "/tmp/\(id)",
            source: "default",
            model: nil,
            provider: "openai",
            endpointHost: nil,
            hasAuth: true,
            accountEmail: email,
            authStatus: "valid",
            authExpiresAt: nil,
            authNote: nil,
            hasConfig: true,
            skillCount: 0,
            quotaMode: "subscription",
            quotaNote: nil
        )
    }

    private func sourceThread(provider: ManagedChatProvider, scope: String) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider, sourceScope: scope, sourceID: "same-session",
            title: provider.label, titleSource: "fixture", hasMeaningfulTitle: true,
            createdAt: 1_700_000_000, updatedAt: 1_700_000_100, tokensUsed: -1,
            model: nil, cwd: "/tmp/project", archived: false, running: false,
            sourceStatus: "idle", threadSource: provider.rawValue, agentNickname: nil,
            agentRole: nil, agentPath: nil, parentThreadID: nil, rootThreadId: "root",
            isSubagent: false, isSidechat: false,
            activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(state: .idle, reason: "fixture")
        )
    }

    private func codexThread(
        id: String, cwd: String, title: String,
        source: String? = nil, parent: String? = nil, nickname: String? = nil
    ) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            title: title,
            titleSource: "fixture",
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: 0,
            model: "fixture-model",
            cwd: cwd,
            archived: false,
            running: false,
            threadSource: source,
            agentNickname: nickname,
            agentRole: nil,
            agentPath: nil,
            parentThreadId: parent,
            agentDepth: nil,
            rootThreadId: parent ?? id,
            familyActivity: nil
        )
    }
}
