import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class CodexBillingTests: XCTestCase {
    func testCreditsPreserveZeroPrecisionNegativeAndUnlimitedWithoutInventingMissingBalances() {
        XCTAssertEqual(CodexCreditsSnapshot(hasCredits: true, unlimited: false, balance: "120.001230").valueLabel, "120.001230 Credits")
        let zero = CodexCreditsSnapshot(hasCredits: false, unlimited: false, balance: "0.00")
        XCTAssertEqual(zero.valueLabel, "0.00 Credits")
        XCTAssertTrue(zero.isDepleted)
        XCTAssertEqual(CodexCreditsSnapshot(hasCredits: true, unlimited: false, balance: "-0.25").valueLabel, "-0.25 Credits")
        let unlimited = CodexCreditsSnapshot(hasCredits: true, unlimited: true, balance: nil)
        XCTAssertEqual(unlimited.valueLabel, "不限量 Credits")
        XCTAssertFalse(unlimited.isDepleted)
        XCTAssertEqual(CodexCreditsSnapshot(hasCredits: nil, unlimited: nil, balance: nil).valueLabel, "Credits 未提供")
        XCTAssertNil(CodexBillingAmount.decimal("secret-nonnumeric-value"))
        XCTAssertNil(CodexBillingAmount.decimal("1e9"))
    }

    func testCreditsStayBoundToTheirHomeAndCustomAPIsNeverBorrowOfficialCredits() throws {
        let a = try home("a")
        let b = try home("b")
        let quota = quota("a", balance: "127.50")
        XCTAssertEqual(details(a, quota: quota).creditLines.first?.valueLabel, "127.50 Credits")
        XCTAssertTrue(details(b, quota: quota).creditLines.isEmpty)
        let api = try home("a", custom: true)
        XCTAssertTrue(details(api, quota: quota).creditLines.isEmpty)
        XCTAssertNil(details(api, quota: quota).creditsSummary)
        XCTAssertFalse(details(b, quota: nil).creditsSummary?.contains("0") == true)
    }

    func testCreditOnlySnapshotsExpireAndDuplicateBucketBalancesAreNotAddedTogether() throws {
        let h = try home("a")
        let credits = CodexCreditsSnapshot(hasCredits: true, unlimited: false, balance: "15.00")
        let bucket = CodexQuotaBucket(limitId: "codex", limitName: nil, planType: "pro", primary: nil, secondary: nil, credits: credits)
        let duplicate = CodexQuotaBucket(limitId: "codex_other", limitName: nil, planType: "pro", primary: nil, secondary: nil, credits: credits)
        let value = CodexHomeQuota(ok: true, schemaVersion: nil, homeId: h.id, available: true, planType: "pro", buckets: [bucket, duplicate], error: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let d = details(h, quota: value, at: now.addingTimeInterval(-400), now: now)
        XCTAssertTrue(d.quotaLines.isEmpty)
        XCTAssertEqual(d.creditLines.count, 1)
        XCTAssertTrue(d.quotaNeedsRefresh)
        XCTAssertTrue(d.creditsNotice?.contains("缓存") == true)
    }

    func testAPITransportAndMonthlyBillingAreIndependentAndMissingQuotaIsUnknown() throws {
        let h = try home("api", custom: true)
        let d = details(h, quota: nil)
        XCTAssertEqual(d.configuredModels.map(\.id), ["deepseek-flash", "qwen-example"])
        XCTAssertEqual(d.billingConnections.map(\.modeLabel), ["API · 按量计费", "API · 包月订阅"])
        XCTAssertEqual(d.billingConnections[1].modelNames, ["Qwen example"])
        XCTAssertTrue(d.billingConnections.allSatisfy { $0.balances.isEmpty && $0.allowances.isEmpty })
        XCTAssertTrue(d.canRefreshUsage)
        XCTAssertTrue(d.connectionSummary.contains("2 个服务"))
    }

    func testAPIUsageRejectsWrongHomeFiltersUnconfiguredConnectionsAndPreservesCachedBalanceOnFailure() throws {
        let suite = "CodexBillingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        let h = try home("api", custom: true)
        model.codexHomes = [h]
        XCTAssertThrowsError(try model.acceptCodexAccountBilling(billing("other"), for: h))
        let valid = CodexHomeBilling(ok: true, schemaVersion: nil, homeId: h.id, connections: [entry("deepseek", amount: "0.00000123"), entry("unconfigured", amount: "999")])
        XCTAssertTrue(try model.acceptCodexAccountBilling(valid, for: h))
        XCTAssertEqual(model.codexHomeBilling[h.id]?.connections.map(\.id), ["deepseek"])
        let failed = CodexHomeBilling(ok: true, schemaVersion: nil, homeId: h.id, connections: [entry("deepseek", amount: nil, available: false)])
        XCTAssertTrue(try model.acceptCodexAccountBilling(failed, for: h))
        let d = model.codexAccountDetails(for: h)
        XCTAssertEqual(d.billingConnections.first?.balances.first?.amount, "0.00000123")
        XCTAssertTrue(d.billingConnections.first?.notice?.contains("缓存") == true)
        model.codexHomes = [try home("api", custom: true, email: "replacement@example.test")]
        XCTAssertNil(model.codexHomeBilling[h.id])
        XCTAssertFalse(try model.acceptCodexAccountBilling(valid, for: h))
    }

    func testProviderInsufficientBalanceDoesNotBecomeAnAuthenticationFailure() throws {
        let h = try home("api", custom: true)
        let snapshot = CodexConnectionUsageSnapshot(id: "deepseek", available: true, status: "available", serviceAvailable: false, balances: [.init(currency: "CNY", amount: "-0.01", updatedAt: 1_800_000_000, source: "provider")], allowances: [], updatedAt: 1_800_000_000, error: nil)
        let result = CodexHomeBilling(ok: true, schemaVersion: nil, homeId: h.id, connections: [snapshot])
        let d = details(h, quota: nil, billing: result)
        XCTAssertEqual(d.billingConnections.first?.balances.first?.summaryLabel, "-0.01 CNY")
        XCTAssertTrue(d.billingConnections.first?.notice?.contains("余额不足") == true)
        XCTAssertFalse(d.requiresLogin)
    }

    private func home(_ id: String, custom: Bool = false, email: String = "account@example.test") throws -> CodexHome {
        var json: [String: Any] = ["id": id, "label": "Example", "path": "/tmp/harvis-billing-\(id)", "source": "explicit", "model": "deepseek-flash", "provider": custom ? "Router" : "openai", "providerId": custom ? "custom-router" : "openai", "hasAuth": true, "accountEmail": email, "authStatus": "valid", "hasConfig": true, "skillCount": 0, "quotaMode": custom ? "proxy" : "subscription"]
        if custom {
            json["configuredModels"] = [["id": "deepseek-flash", "displayName": "DeepSeek Flash", "providerId": "deepseek", "source": "configured"], ["id": "qwen-example", "displayName": "Qwen example", "providerId": "qwen", "source": "configured"]]
            json["connections"] = [connection("deepseek", model: "deepseek-flash", mode: "usage"), connection("qwen", model: "qwen-example", mode: "subscription")]
        }
        return try JSONDecoder().decode(CodexHome.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func connection(_ id: String, model: String, mode: String) -> [String: Any] {
        ["id": id, "name": id, "providerId": id, "modelIds": [model], "accessMode": "api", "billingMode": mode, "billingPeriod": "monthly", "allowances": [], "balances": []]
    }

    private func quota(_ id: String, balance: String) -> CodexHomeQuota {
        CodexHomeQuota(ok: true, schemaVersion: nil, homeId: id, available: true, planType: "pro", buckets: [.init(limitId: "codex", limitName: nil, planType: "pro", primary: nil, secondary: nil, credits: .init(hasCredits: true, unlimited: false, balance: balance))], error: nil)
    }

    private func entry(_ id: String, amount: String?, available: Bool = true) -> CodexConnectionUsageSnapshot {
        CodexConnectionUsageSnapshot(id: id, available: available, status: available ? "available" : "unavailable", serviceAvailable: nil, balances: amount.map { [.init(currency: "CNY", amount: $0, updatedAt: 1_800_000_000, source: "provider")] } ?? [], allowances: [], updatedAt: 1_800_000_000, error: nil)
    }

    private func billing(_ id: String) -> CodexHomeBilling {
        CodexHomeBilling(ok: true, schemaVersion: nil, homeId: id, connections: [])
    }

    private func details(_ home: CodexHome, quota: CodexHomeQuota?, at: Date? = nil, now: Date = Date(timeIntervalSince1970: 1_800_000_000), billing: CodexHomeBilling? = nil) -> CodexAccountDetails {
        CodexAccountDetails(home: home, workspacePath: "/tmp/example", threadCount: 0, quota: quota, quotaError: nil, quotaUpdatedAt: at, isQuotaLoading: false, isActionRunning: false, billing: billing, observedAt: now)
    }
}
