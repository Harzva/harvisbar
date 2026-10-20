import XCTest
@testable import HarvisBar

@MainActor
final class CodexPersistenceTests: XCTestCase {
    func testRetiredPluginTreeIsNeverAcceptedAsRuntimeRoot() {
        XCTAssertTrue(
            HarvisRuntimeModel.isLegacyPluginRoot(
                "\(NSHomeDirectory())/plugins/harvis"
            )
        )
        XCTAssertFalse(
            HarvisRuntimeModel.isLegacyPluginRoot(
                "\(NSHomeDirectory())/.codex/plugins/cache/personal/harvis/current"
            )
        )
    }

    func testRemoteTagDetectionIsCaseInsensitiveAndExact() {
        XCTAssertTrue(CodexThreadPreferences.hasRemoteTag(["remote"]))
        XCTAssertTrue(CodexThreadPreferences.hasRemoteTag(["Paper", "REMOTE"]))
        XCTAssertFalse(CodexThreadPreferences.hasRemoteTag(["remote-work"]))
        XCTAssertFalse(CodexThreadPreferences.hasRemoteTag([]))
        XCTAssertTrue(CodexThreadPreferences.hasDoneTag(["DONE"]))
        XCTAssertFalse(CodexThreadPreferences.hasDoneTag(["done-later"]))
    }

    func testPinAndTagsSurviveModelRecreation() {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let home = fixtureHome()
        let thread = fixtureThread()
        let first = HarvisRuntimeModel(defaults: defaults)
        first.codexHomes = [home]
        first.selectedCodexHomeID = home.id
        first.toggleThreadPin(thread)
        first.setTags(["paper", "paper", " benchmark "], for: thread)

        let restored = HarvisRuntimeModel(defaults: defaults)
        restored.codexHomes = [home]
        restored.selectedCodexHomeID = home.id

        XCTAssertTrue(restored.isThreadPinned(thread))
        XCTAssertEqual(restored.tags(for: thread), ["paper", "benchmark"])
    }

    func testGovernancePreferencesRoundTripWithoutSharingRuntimeState() {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = CodexThreadPreferences(defaults: defaults)
        let window = ManagedAttentionPreference(
            level: .critical,
            focusStartsAt: Date(timeIntervalSince1970: 1_700_000_000),
            focusEndsAt: Date(timeIntervalSince1970: 1_700_086_400)
        )
        preferences.saveVisibleUnnamedSubagents(["home-a::thread-1"])
        preferences.saveProjectAttention(["path::/tmp/project": window])
        preferences.saveConversationAttention(["home-a::thread-1": window])

        XCTAssertEqual(
            preferences.loadVisibleUnnamedSubagents(),
            ["home-a::thread-1"]
        )
        XCTAssertEqual(
            preferences.loadProjectAttention()["path::/tmp/project"],
            window
        )
        XCTAssertEqual(
            preferences.loadConversationAttention()["home-a::thread-1"],
            window
        )
    }

    func testVerifiedHandoffAddsDoneToStableHomeKeyEvenWhenTagSlotsAreFull() {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = HarvisRuntimeModel(defaults: defaults)
        let key = "home-a::source-thread"
        model.codexThreadTags[key] = (1 ... 8).map { "tag\($0)" }
        var transaction = CodexConversationHandoff(
            homeID: "home-a",
            homePath: "/tmp/codex-home-a",
            sourceThreadID: "source-thread",
            sourceTitle: "Source",
            cardType: .main
        )
        transaction.state = .verified
        transaction.sourceSummaryTurnID = "source-summary-turn"
        transaction.sourceUpdatedAt = 1_900_000_000
        transaction.destinationThreadID = "destination-thread"
        transaction.destinationTurnID = "destination-turn"

        model.syncVerifiedHandoffTags([transaction])

        XCTAssertEqual(model.codexThreadTags[key]?.count, 8)
        XCTAssertEqual(model.codexThreadTags[key]?.first, "done")
        XCTAssertTrue(CodexThreadPreferences.hasDoneTag(model.codexThreadTags[key] ?? []))
    }

    func testManagedCodexStorageKeyUsesCardSourceHomeAfterAccountSwitch() {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = HarvisRuntimeModel(defaults: defaults)
        let homeA = fixtureHome(id: "home-a", accountEmail: "a@example.test")
        let homeB = fixtureHome(id: "home-b", accountEmail: "b@example.test")
        model.codexHomes = [homeA, homeB]
        model.selectedCodexHomeID = homeB.id

        let card = ManagedChatThread(
            codex: fixtureThread(id: "shared-thread"),
            sourceScope: homeA.id
        )

        XCTAssertEqual(
            model.managedChatStorageKey(card),
            "home-a::shared-thread"
        )
    }

    func testAccountSwitchKeepsCardsWithoutRelabelingTheirOrigin() throws {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = HarvisRuntimeModel(defaults: defaults)
        let homeA = fixtureHome(id: "home-a", accountEmail: "a@example.test")
        let homeB = fixtureHome(id: "home-b", accountEmail: "b@example.test")
        let shared = fixtureThread(id: "shared-thread")
        model.codexHomes = [homeA, homeB]
        model.selectedCodexHomeID = homeA.id
        model.acceptCodexThreads([shared], sourceHomeID: homeA.id)

        let cardA = try XCTUnwrap(
            model.managedChatThreads.first { $0.provider == .codex }
        )
        model.setTags(["home-a-only"], for: cardA)
        XCTAssertEqual(cardA.sourceScope, homeA.id)
        XCTAssertEqual(model.selectedCodexHome(for: cardA)?.id, homeA.id)

        // Management selection changes the legacy popover, while the unified
        // catalog retains A and routes it by immutable origin.
        model.selectedCodexHomeID = homeB.id

        XCTAssertNil(model.codexThreadsSourceHomeID)
        XCTAssertTrue(model.codexThreads.isEmpty)
        XCTAssertTrue(model.managedChatThreads.contains { $0.sourceScope == homeA.id })
        XCTAssertNil(model.selectedCodexHome(for: cardA))
        XCTAssertEqual(model.tags(for: cardA), ["home-a-only"])

        XCTAssertEqual(model.codexHome(for: cardA)?.id, homeA.id)
        // A late response updates A only; an equal native ID in B has its own key.
        model.acceptCodexThreads([shared], sourceHomeID: homeA.id)
        XCTAssertTrue(model.managedChatThreads.contains { $0.sourceScope == homeA.id })
        model.acceptCodexThreads([shared], sourceHomeID: homeB.id)
        let cardB = try XCTUnwrap(
            model.managedChatThreads.first { $0.sourceScope == homeB.id }
        )
        XCTAssertEqual(cardB.sourceScope, homeB.id)
        XCTAssertEqual(model.selectedCodexHome(for: cardB)?.id, homeB.id)
        XCTAssertNotEqual(
            model.managedChatStorageKey(cardA),
            model.managedChatStorageKey(cardB)
        )
        XCTAssertTrue(model.tags(for: cardB).isEmpty)
    }

    func testPerAccountWorkspaceSurvivesAuthExpirationAndModelRecreation() {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let active = fixtureHome(authStatus: "valid")
        let first = HarvisRuntimeModel(defaults: defaults)
        first.codexHomes = [active]
        first.setCodexWorkspace("/tmp", for: active)

        let expired = fixtureHome(authStatus: "expired")
        let restored = HarvisRuntimeModel(defaults: defaults)
        restored.codexHomes = [expired]

        XCTAssertEqual(restored.codexWorkspacePath(for: expired), "/tmp")
        XCTAssertTrue(expired.isAuthInvalid)
        XCTAssertEqual(restored.visibleCodexHomes.map(\.id), [expired.id])
    }

    func testHidingAccountIsReversibleAndKeepsWorkspaceMapping() {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let home = fixtureHome(authStatus: "invalid")
        let model = HarvisRuntimeModel(defaults: defaults)
        model.codexHomes = [home]
        model.setCodexWorkspace("/tmp", for: home)
        model.hideCodexHome(home)

        XCTAssertTrue(model.visibleCodexHomes.isEmpty)
        XCTAssertEqual(model.hiddenCodexHomes.map(\.id), [home.id])
        XCTAssertEqual(model.codexWorkspacePath(for: home), "/tmp")

        model.restoreCodexHome(home)
        XCTAssertEqual(model.visibleCodexHomes.map(\.id), [home.id])
        XCTAssertEqual(model.codexWorkspacePath(for: home), "/tmp")
    }

    func testAccountListKeepsCustomHomesAndPrefersDefaultForSubscriptionDuplicates() {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let defaultHome = fixtureHome(
            id: "default-home",
            label: "Default Codex",
            source: "default",
            accountEmail: "owner@example.test",
            authStatus: "refresh-needed"
        )
        let managedDuplicate = fixtureHome(
            id: "managed-home",
            label: "Managed · codex-current",
            source: "managed-agent",
            accountEmail: "owner@example.test",
            authStatus: "valid"
        )
        let apiOnly = fixtureHome(
            id: "api-home",
            label: "Inroi Direct",
            source: "open-codex-launcher",
            accountEmail: nil,
            authStatus: "configured",
            quotaMode: "api-key"
        )
        let proxyEmail = fixtureHome(
            id: "proxy-home",
            label: "Legacy Proxy",
            source: "open-codex-launcher",
            accountEmail: "proxy@example.test",
            authStatus: "valid",
            quotaMode: "proxy"
        )

        model.codexHomes = [managedDuplicate, apiOnly, proxyEmail, defaultHome]

        XCTAssertEqual(
            Set(model.visibleCodexHomes.map(\.id)),
            Set([defaultHome.id, apiOnly.id, proxyEmail.id])
        )
        let subscription = model.visibleCodexHomes.first { $0.id == defaultHome.id }
        XCTAssertEqual(subscription?.accountDisplayLabel, "owner@example.test")
        XCTAssertEqual(subscription?.authStatusLabel, "Auth 待刷新")
        XCTAssertFalse(model.visibleCodexHomes.contains { $0.id == managedDuplicate.id })
    }

    func testRememberedAccountRemainsVisibleWhenAuthIdentityIsUnavailable() {
        let suite = "local.harzva.harvisbar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let remembered = fixtureHome(
            id: "remembered-home",
            label: "Research",
            accountNote: "Research",
            source: "managed-agent",
            accountEmail: nil,
            authStatus: "invalid"
        )

        model.codexHomes = [remembered]

        XCTAssertEqual(model.visibleCodexHomes.map(\.id), [remembered.id])
        XCTAssertEqual(model.visibleCodexHomes.first?.authStatusLabel, "Auth 无效")
    }

    func testAccountDisplayLabelCombinesNoteAndEmailWithoutDuplicatingIdentity() {
        let named = fixtureHome(
            label: "论文研究",
            accountNote: "论文研究",
            accountEmail: "research@example.test"
        )
        XCTAssertEqual(named.accountDisplayLabel, "论文研究 · research@example.test")

        let legacyRuntimeProjection = fixtureHome(
            label: "论文研究",
            source: "managed-agent",
            accountEmail: "research@example.test"
        )
        XCTAssertEqual(
            legacyRuntimeProjection.accountDisplayLabel,
            "论文研究 · research@example.test"
        )

        let emailOnly = fixtureHome(
            label: "Managed · account-1",
            source: "managed-agent",
            accountEmail: "research@example.test"
        )
        XCTAssertEqual(emailOnly.accountDisplayLabel, "research@example.test")

        let duplicate = fixtureHome(
            label: "research@example.test",
            accountNote: "research@example.test",
            accountEmail: "research@example.test"
        )
        XCTAssertEqual(duplicate.accountDisplayLabel, "research@example.test")

        let noteOnly = fixtureHome(
            label: "论文研究",
            accountNote: "论文研究",
            accountEmail: nil
        )
        XCTAssertEqual(noteOnly.accountDisplayLabel, "论文研究")
    }

    func testAccountNoteMetadataCanBeRenamedAndClearedWithoutChangingCreatedAt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-account-note-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataURL = root.appendingPathComponent(".harvis-account.json")
        try Data(#"{"schemaVersion":"harvis.codex-account.v1","label":"Old","createdAt":"2026-08-24T00:00:00Z"}"#.utf8)
            .write(to: metadataURL)

        try await HarvisRuntimeModel.updateCodexAccountNote(
            homePath: root.path,
            note: "论文研究"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        XCTAssertEqual(object["label"] as? String, "论文研究")
        XCTAssertEqual(object["createdAt"] as? String, "2026-08-24T00:00:00Z")
        XCTAssertNotNil(object["updatedAt"] as? String)

        try await HarvisRuntimeModel.updateCodexAccountNote(
            homePath: root.path,
            note: "   "
        )
        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        XCTAssertNil(object["label"])
        XCTAssertEqual(object["createdAt"] as? String, "2026-08-24T00:00:00Z")
    }

    func testCodexAuthChangeWatcherDetectsNewAuthFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-auth-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let baseline = HarvisRuntimeModel.codexAuthFileSnapshot(homePath: root.path)
        XCTAssertNil(baseline)
        let watcher = Task {
            await HarvisRuntimeModel.waitForCodexAuthChange(
                homePath: root.path,
                baseline: baseline,
                timeoutNanoseconds: 1_000_000_000,
                pollIntervalNanoseconds: 10_000_000
            )
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        try Data("{}".utf8).write(
            to: root.appendingPathComponent("auth.json"),
            options: .atomic
        )

        let detected = await watcher.value
        XCTAssertTrue(detected)
    }

    func testCodexAuthChangeWatcherDetectsReplacedAuthFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-auth-relogin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let authURL = root.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: authURL, options: .atomic)

        let baseline = try XCTUnwrap(
            HarvisRuntimeModel.codexAuthFileSnapshot(homePath: root.path)
        )
        let watcher = Task {
            await HarvisRuntimeModel.waitForCodexAuthChange(
                homePath: root.path,
                baseline: baseline,
                timeoutNanoseconds: 1_000_000_000,
                pollIntervalNanoseconds: 10_000_000
            )
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        try Data("{\"updated\":true}".utf8).write(to: authURL, options: .atomic)

        let detected = await watcher.value
        XCTAssertTrue(detected)
    }

    func testCodexHomeDiscoveryFingerprintChangesWhenExternalAuthAppears() throws {
        let userRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-home-discovery-\(UUID().uuidString)", isDirectory: true)
        let accountHome = userRoot
            .appendingPathComponent(".codex-managed-agent/accounts/account-a", isDirectory: true)
        try FileManager.default.createDirectory(
            at: accountHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: userRoot) }

        let before = HarvisRuntimeModel.codexHomeDiscoveryFingerprint(
            userRootPath: userRoot.path
        )
        try Data("{}".utf8).write(
            to: accountHome.appendingPathComponent("auth.json"),
            options: .atomic
        )
        let after = HarvisRuntimeModel.codexHomeDiscoveryFingerprint(
            userRootPath: userRoot.path
        )

        XCTAssertNotEqual(before, after)
    }

    private func fixtureHome(
        id: String = "home-1",
        label: String = "Test Home",
        accountNote: String? = nil,
        source: String = "test",
        accountEmail: String? = "research@example.test",
        authStatus: String = "missing",
        quotaMode: String = "missing-auth"
    ) -> CodexHome {
        CodexHome(
            id: id,
            label: label,
            accountNote: accountNote,
            path: "/tmp/test-codex-home",
            source: source,
            model: "gpt-5.6-sol",
            provider: "openai",
            endpointHost: nil,
            hasAuth: false,
            accountEmail: accountEmail,
            authStatus: authStatus,
            authExpiresAt: authStatus == "valid" ? 1_900_000_000 : 1,
            authNote: nil,
            hasConfig: true,
            skillCount: 2,
            quotaMode: quotaMode,
            quotaNote: "此 Home 尚未完成独立 ChatGPT 登录。"
        )
    }
}
