import XCTest
@testable import HarvisBar

@MainActor
final class ManagedChatResponsivenessTests: XCTestCase {
    func testLargeCatalogCardPass() throws {
        let suite = "Responsiveness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        // DSH fixtures avoid discovery, real accounts, and task dispatch.
        model.dshThreads = (0..<200).map { index in
            var thread = ManagedChatThread(codex: fixtureThread(id: "card-\(index)", cwd: "/tmp/harvis-benchmark/project-\(index % 20)"), sourceScope: "fixture")
            thread = ManagedChatThread(provider: .dsh, sourceScope: "fixture", sourceID: thread.sourceID,
                title: thread.title, titleSource: "fixture", hasMeaningfulTitle: true,
                createdAt: thread.createdAt, updatedAt: thread.updatedAt, tokensUsed: 0, model: nil,
                cwd: thread.cwd, archived: false, running: false, sourceStatus: "idle", threadSource: "dsh",
                agentNickname: nil, agentRole: nil, agentPath: nil, parentThreadID: nil,
                rootThreadId: thread.sourceID, isSubagent: false, isSidechat: false,
                activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
                trustProjection: CodexThreadTrustProjection(state: .idle, reason: "fixture"))
            return thread
        }
        let cards = model.managedChatThreads
        let start = Date()
        for card in cards {
            XCTAssertEqual(model.managedConversationInsightContext(for: card).projectCatalog.count, 20)
        }
        print("HARVIS_CARD_PASS_200_MS=\(Date().timeIntervalSince(start) * 1000)")
        _ = model.managedChatDisplayAccounts
        let warmStart = Date()
        for _ in 0..<200 {
            XCTAssertEqual(model.managedChatThreads.count, 200)
            XCTAssertEqual(model.managedChatDisplayAccounts.first?.threadCount, 200)
        }
        print("HARVIS_WARM_CATALOG_READS_200_MS=\(Date().timeIntervalSince(warmStart) * 1000)")
    }
    func testPathCacheExpiresAndRemainsBounded() {
        let cache = ManagedProjectPathCache(capacity: 2, lifetime: 5)
        let identity = ManagedChatProjectResolver.resolve(cwd: "", fallbackID: "fixture")
        cache.insert(identity, for: "a", now: 0)
        cache.insert(identity, for: "b", now: 1)
        XCTAssertEqual(cache.value(for: "a", now: 2), identity)
        cache.insert(identity, for: "c", now: 2)
        XCTAssertNil(cache.value(for: "a", now: 2))
        XCTAssertEqual(cache.value(for: "b", now: 2), identity)
        XCTAssertNil(cache.value(for: "b", now: 6))
        cache.removeAll()
        XCTAssertNil(cache.value(for: "c", now: 3))
    }

    func testCatalogRefreshesAfterConversationAndAccountChanges() throws {
        let suite = "Responsiveness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let home = CodexHome(id: "fixture-home", label: "fixture", accountNote: nil,
            path: "/tmp/fixture-home", source: "default", model: nil, provider: "openai",
            endpointHost: nil, hasAuth: false, accountEmail: nil, authStatus: "missing",
            authExpiresAt: nil, authNote: nil, hasConfig: false, skillCount: 0,
            quotaMode: "subscription", quotaNote: nil)
        model.codexHomes = [home]
        model.acceptCodexThreads([fixtureThread(title: "Before", cwd: "/tmp/first-project")], sourceHomeID: home.id)
        XCTAssertEqual(model.cachedManagedInsightCatalog.candidates.first?.conversationTitles, ["Before"])
        model.acceptCodexThreads([fixtureThread(title: "After", cwd: "/tmp/second-project")], sourceHomeID: home.id)
        XCTAssertEqual(model.cachedManagedInsightCatalog.candidates.first?.conversationTitles, ["After"])
        XCTAssertEqual(model.cachedManagedInsightCatalog.projects.first?.label, "second-project")
        model.hiddenCodexHomeIDs = [home.id]
        XCTAssertTrue(model.cachedManagedInsightCatalog.projects.isEmpty)
        model.hiddenCodexHomeIDs = []
        XCTAssertEqual(model.cachedManagedInsightCatalog.projects.count, 1)
        model.acceptCodexThreads([], sourceHomeID: home.id)
        XCTAssertTrue(model.cachedManagedInsightCatalog.projects.isEmpty)
    }

}
