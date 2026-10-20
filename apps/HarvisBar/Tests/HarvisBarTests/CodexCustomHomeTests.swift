import XCTest
@testable import HarvisBar

@MainActor
final class CodexCustomHomeTests: XCTestCase {
    func testConfiguredCustomHomesRemainSelectableWithoutChatGPTIdentity() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let deepSeek = home("deepseek", mode: "proxy")
        let apiKey = home("api-key", mode: "api-key")
        model.codexHomes = [deepSeek, apiKey]

        XCTAssertEqual(Set(model.visibleCodexHomes.map(\.id)), Set([deepSeek.id, apiKey.id]))
        for custom in [deepSeek, apiKey] {
            model.selectedCodexHomeID = custom.id
            XCTAssertEqual(model.selectedCodexHome?.id, custom.id)
            XCTAssertTrue(custom.isCodexAccountCandidate)
            XCTAssertTrue(custom.isCustomModelHome)
            XCTAssertFalse(custom.isSubscriptionHome)
            XCTAssertNotNil(custom.officialQuotaBlockedReason)
            XCTAssertFalse(custom.hasAuth)
            XCTAssertNil(custom.accountEmail)
        }
    }

    func testCustomCredentialsAreUnverifiedRegardlessOfCachedChatGPTAuth() {
        for mode in ["proxy", "api-key"] {
            for status in ["missing", "expired", "invalid", "valid", "configured"] {
                let custom = home("custom", mode: mode, email: "old@example.test", authStatus: status)
                XCTAssertEqual(custom.authStatusLabel, "API 凭据待验证")
                XCTAssertEqual(custom.authMenuSummary, "API 凭据待验证")
                XCTAssertEqual(custom.authSystemImage, "key.horizontal")
                XCTAssertFalse(custom.isAuthInvalid)
                XCTAssertNil(custom.authExpirationLabel)
                XCTAssertNil(custom.compactAuthExpirationLabel)

                let details = CodexAccountDetails(
                    home: custom, workspacePath: "/tmp", threadCount: 0,
                    quota: nil, quotaError: "401 Unauthorized", quotaUpdatedAt: nil,
                    isQuotaLoading: false, isActionRunning: false
                )
                XCTAssertFalse(details.requiresLogin)
                XCTAssertEqual(details.authenticationLabel, "API 凭据待验证")
                XCTAssertEqual(details.quotaNotice, custom.officialQuotaBlockedReason)
            }
        }
    }

    func testSubscriptionDuplicatesDoNotMergeOrHideCustomHomesWithSameEmail() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let email = "owner@example.test"
        let subscription = home("subscription", mode: "subscription", email: email, source: "default")
        let duplicate = home("duplicate", mode: "subscription", email: "OWNER@example.test", source: "managed-agent")
        let proxy = home("proxy", mode: "proxy", email: email)
        let apiKey = home("api-key", mode: "api-key", email: email)
        model.codexHomes = [duplicate, proxy, subscription, apiKey]
        model.selectedCodexHomeID = subscription.id

        XCTAssertEqual(Set(model.visibleCodexHomes.map(\.id)), Set([subscription.id, proxy.id, apiKey.id]))
        XCTAssertEqual(model.codexHomeIDs(forAccount: subscription), Set([subscription.id, duplicate.id]))
        XCTAssertEqual(model.codexHomeIDs(forAccount: proxy), Set([proxy.id]))
        XCTAssertEqual(model.codexHomeIDs(forAccount: apiKey), Set([apiKey.id]))

        model.hideCodexHome(proxy)
        XCTAssertEqual(Set(model.visibleCodexHomes.map(\.id)), Set([subscription.id, apiKey.id]))
        XCTAssertEqual(model.hiddenCodexHomeIDs, Set([proxy.id]))
        model.restoreCodexHome(proxy)
        XCTAssertEqual(Set(model.visibleCodexHomes.map(\.id)), Set([subscription.id, proxy.id, apiKey.id]))

        // Keep selection on an unaffected Home so this preference-only test
        // never starts quota or thread refresh work.
        model.selectedCodexHomeID = apiKey.id
        model.hideCodexHome(subscription)
        XCTAssertEqual(Set(model.visibleCodexHomes.map(\.id)), Set([proxy.id, apiKey.id]))
        XCTAssertEqual(model.hiddenCodexHomeIDs, Set([subscription.id, duplicate.id]))
    }

    func testBulkHideInvalidAccountsPreservesCustomHomesAndTheirWorkspaces() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let missing = home("missing", mode: "missing-auth", source: "managed-agent")
        let expired = home("expired", mode: "subscription", email: "expired@example.test", authStatus: "expired")
        let proxy = home("proxy", mode: "proxy")
        let apiKey = home("api-key", mode: "api-key", authStatus: "expired")
        model.codexHomes = [missing, expired, proxy, apiKey]
        model.selectedCodexHomeID = proxy.id
        model.codexHomeWorkspaces[proxy.id] = "/tmp/proxy-workspace"
        model.codexHomeWorkspaces[apiKey.id] = "/tmp/api-workspace"

        XCTAssertEqual(Set(model.invalidVisibleCodexHomes.map(\.id)), Set([missing.id, expired.id]))
        model.hideInvalidCodexHomes()

        XCTAssertEqual(Set(model.visibleCodexHomes.map(\.id)), Set([proxy.id, apiKey.id]))
        XCTAssertEqual(model.hiddenCodexHomeIDs, Set([missing.id, expired.id]))
        XCTAssertEqual(model.codexWorkspacePath(for: proxy), "/tmp/proxy-workspace")
        XCTAssertEqual(model.codexWorkspacePath(for: apiKey), "/tmp/api-workspace")
        XCTAssertEqual(model.selectedCodexHome?.id, proxy.id)
    }

    func testCustomDisplayUsesConfigurationIdentityInsteadOfResidualEmail() {
        let named = home("named", mode: "proxy", email: "old@example.test", note: "DeepSeek Flash")
        XCTAssertEqual(named.accountDisplayLabel, "DeepSeek Flash")
        let modelNamed = home("model", mode: "proxy", email: "old@example.test")
        XCTAssertEqual(modelNamed.accountDisplayLabel, "deepseek-flash")
        let providerNamed = home("provider", mode: "api-key", email: "old@example.test", modelName: nil)
        XCTAssertEqual(providerNamed.accountDisplayLabel, "Custom provider")
    }

    func testCustomHomeNeverProjectsCachedOfficialSubscriptionQuota() {
        let custom = home("custom", mode: "proxy")
        let quota = CodexHomeQuota(
            ok: true, schemaVersion: nil, homeId: custom.id, available: true,
            planType: "pro", buckets: [CodexQuotaBucket(
                limitId: "codex", limitName: nil, planType: "pro",
                primary: CodexQuotaWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: nil),
                secondary: nil
            )], error: nil
        )
        let details = CodexAccountDetails(
            home: custom, workspacePath: "/tmp", threadCount: 0,
            quota: quota, quotaError: nil, quotaUpdatedAt: Date(),
            isQuotaLoading: false, isActionRunning: false
        )

        XCTAssertNil(details.quota)
        XCTAssertTrue(details.quotaLines.isEmpty)
        XCTAssertEqual(details.quotaNotice, custom.officialQuotaBlockedReason)
        XCTAssertFalse(details.requiresLogin)
        XCTAssertEqual(details.authenticationLabel, "API 凭据待验证")
        XCTAssertFalse(details.hoverSummary.localizedCaseInsensitiveContains("pro"))
    }

    private func fixtureModel() throws -> (HarvisRuntimeModel, UserDefaults, String) {
        let suite = "CodexCustomHomeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (HarvisRuntimeModel(defaults: defaults), defaults, suite)
    }

    private func home(
        _ id: String, mode: String, email: String? = nil,
        authStatus: String = "missing", source: String = "harvis-configured",
        note: String? = nil, modelName: String? = "deepseek-flash"
    ) -> CodexHome {
        CodexHome(
            id: id, label: "Custom · \(id)", accountNote: note,
            path: "/tmp/harvis-test-home-\(id)", source: source,
            model: modelName, provider: "Custom provider", endpointHost: nil,
            hasAuth: authStatus == "valid", accountEmail: email,
            authStatus: authStatus, authExpiresAt: 1_900_000_000,
            authNote: nil, hasConfig: true, skillCount: 0,
            quotaMode: mode, quotaNote: "This CODEX_HOME has no configured ChatGPT account."
        )
    }
}
