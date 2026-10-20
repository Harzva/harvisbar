import AppKit
import SwiftUI
import XCTest
@testable import HarvisBar

@MainActor
final class CodexAccountDetailsTests: XCTestCase {
    func testAccountDetailsNeverBorrowTheSelectedAccountsQuota() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = home("a", email: "a@example.test")
        let b = home("b", email: "b@example.test")
        model.codexHomes = [a, b]
        model.selectedCodexHomeID = a.id
        model.codexHomeQuotas[a.id] = quota(a.id, used: 12)
        let details = try XCTUnwrap(model.managedCodexAccountDetails[b.id])
        XCTAssertNil(details.quota)
        XCTAssertTrue(details.quotaLines.isEmpty)
        XCTAssertFalse(details.hoverSummary.contains("88%"))
        XCTAssertTrue(details.hoverSummary.contains("b@example.test"))
        XCTAssertEqual(model.selectedCodexHomeID, a.id)

        model.codexHomeQuotas[b.id] = quota(a.id, used: 12)
        let mismatched = try XCTUnwrap(model.managedCodexAccountDetails[b.id])
        XCTAssertNil(mismatched.quota)
        XCTAssertTrue(mismatched.quotaNotice?.contains("不匹配") == true)
    }

    func testQuotaAcceptanceRejectsWrongHomeAndLateResponsesAfterIdentityChanges() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = home("a", email: "first@example.test")
        model.codexHomes = [original]
        XCTAssertThrowsError(try model.acceptCodexAccountQuota(quota("b"), for: original))
        XCTAssertTrue(model.codexHomeQuotas.isEmpty)
        model.codexHomes = [home("a", email: "replacement@example.test")]
        XCTAssertFalse(try model.acceptCodexAccountQuota(quota("a"), for: original))
        XCTAssertTrue(model.codexHomeQuotas.isEmpty)
    }

    func testIdentityChangesClearQuotaButRenamingPreservesIt() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = home("a", email: "a@example.test")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        model.codexHomes = [a]
        XCTAssertTrue(try model.acceptCodexAccountQuota(quota(a.id), for: a, at: date))
        model.codexHomeQuotaAttemptedAt[a.id] = date
        model.codexHomeActionFeedback[a.id] = .init(message: "Opened", isError: false)
        model.codexHomes = [home("a", email: "a@example.test", note: "6266")]
        XCTAssertNotNil(model.codexHomeQuotas[a.id])
        XCTAssertEqual(model.codexHomeQuotaUpdatedAt[a.id], date)
        model.codexHomes = [home("a", email: "other@example.test")]
        XCTAssertNil(model.codexHomeQuotas[a.id])
        XCTAssertNil(model.codexHomeQuotaUpdatedAt[a.id])
        XCTAssertNil(model.codexHomeQuotaAttemptedAt[a.id])
        XCTAssertNil(model.codexHomeActionFeedback[a.id])
    }

    func testCachedQuotaShowsBothWindowsAndDoesNotInventAReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = details(quota: quota("a", used: 20, reset: Int64(now.timeIntervalSince1970 - 10)),
                            updatedAt: now.addingTimeInterval(-120), now: now)
        XCTAssertEqual(stale.quotaLines.map(\.window.remainingPercent), [80, 45])
        XCTAssertEqual(stale.quotaLines.map(\.title), ["Codex · 5小时", "Codex · 7天"])
        XCTAssertTrue(stale.quotaNeedsRefresh)
        XCTAssertTrue(stale.hoverSummary.contains("80%"))
        XCTAssertTrue(stale.hoverSummary.contains("建议刷新"))
        XCTAssertTrue(stale.quotaNotice?.contains("缓存") == true)
    }

    func testQuotaFailuresRetainCachedValuesAndMissingDataIsNotZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = details(quota: quota("a", used: 30), error: "请求超时", updatedAt: now, now: now)
        XCTAssertEqual(cached.quotaLines.first?.window.remainingPercent, 70)
        XCTAssertTrue(cached.quotaNotice?.contains("刷新失败") == true)
        let missing = details(quota: nil, now: now)
        XCTAssertTrue(missing.quotaLines.isEmpty)
        XCTAssertFalse(missing.hoverSummary.contains("0%"))
        XCTAssertTrue(missing.hoverSummary.contains("暂未返回"))
        let loading = details(quota: nil, loading: true, now: now)
        XCTAssertTrue(loading.quotaNotice?.contains("正在读取") == true)
    }

    func testOpeningRecentOrHiddenAccountDetailsDoesNotLaunchAQuotaRequest() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = home("a", email: "a@example.test")
        let now = Date()
        model.codexHomes = [a]
        model.codexHomeQuotaAttemptedAt[a.id] = now
        model.prepareCodexAccountDetails(a, now: now.addingTimeInterval(59))
        XCTAssertTrue(model.codexHomeQuotaLoadingIDs.isEmpty)
        XCTAssertEqual(model.codexHomeQuotaAttemptedAt[a.id], now)
        model.hiddenCodexHomeIDs = [a.id]
        model.prepareCodexAccountDetails(a, now: now.addingTimeInterval(120))
        model.performCodexAccountDetailAction(.openCLI, home: a)
        XCTAssertTrue(model.codexHomeActionIDs.isEmpty)
        XCTAssertTrue(model.codexHomeQuotaLoadingIDs.isEmpty)
        XCTAssertFalse(model.isCurrentCodexAccount(a))
    }

    func testUnauthorizedQuotaExplainsReloginWithoutShowingServerPayload() {
        let snapshot = details(quota: nil, error: "GET https://example.test/usage failed: 401 Unauthorized; body={error:invalid}", now: Date())
        XCTAssertEqual(snapshot.authenticationLabel, "需要重新登录")
        XCTAssertTrue(snapshot.requiresLogin)
        XCTAssertTrue(snapshot.quotaNotice?.contains("重新登录") == true)
        XCTAssertFalse(snapshot.hoverSummary.contains("https://"))
        XCTAssertFalse(snapshot.hoverSummary.contains("body="))
    }

    func testRenderAccountDetailStatesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["HARVIS_ACCOUNT_DETAILS_PREVIEW"] else { return }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let states: [(String, CodexAccountDetails)] = [
            ("", details(quota: quota("a", used: 20), updatedAt: now, now: now)),
            ("-loading", details(quota: nil, loading: true, now: now)),
            ("-error", details(quota: quota("a", used: 98), error: "额度请求超时，请稍后重试。", updatedAt: now.addingTimeInterval(-600), now: now)),
            ("-missing", details(quota: nil, now: now))
        ]
        for (suffix, snapshot) in states {
            let view = NSHostingView(rootView: CodexAccountDetailsPopover(
                details: snapshot, onAction: { _ in }, onClose: {}, theme: .glass
            ))
            let height = max(200, min(540, view.fittingSize.height))
            print("HARVIS_ACCOUNT_DETAILS_HEIGHT\(suffix)=\(height)")
            let rect = NSRect(x: 0, y: 0, width: 360, height: height)
            let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = rect
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let base = URL(fileURLWithPath: output).deletingPathExtension().path
            try data.write(to: URL(fileURLWithPath: base + suffix + ".png"))
            window.contentView = nil
        }
    }

    private func fixtureModel() throws -> (HarvisRuntimeModel, UserDefaults, String) {
        let suite = "CodexAccountDetailsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (HarvisRuntimeModel(defaults: defaults), defaults, suite)
    }

    private func home(_ id: String, email: String, note: String? = nil) -> CodexHome {
        CodexHome(id: id, label: "Default Codex", accountNote: note, path: "/tmp/codex-account-\(id)",
                  source: "default", model: "codex-model", provider: "openai", endpointHost: nil,
                  hasAuth: true, accountEmail: email, authStatus: "valid", authExpiresAt: nil,
                  authNote: nil, hasConfig: true, skillCount: 12, quotaMode: "subscription", quotaNote: nil)
    }

    private func quota(_ id: String, used: Int = 20, reset: Int64 = 1_800_014_400) -> CodexHomeQuota {
        CodexHomeQuota(ok: true, schemaVersion: nil, homeId: id, available: true, planType: "pro",
                      buckets: [CodexQuotaBucket(limitId: "codex", limitName: nil, planType: "pro",
                          primary: CodexQuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset),
                          secondary: CodexQuotaWindow(usedPercent: 55, windowDurationMins: 10080, resetsAt: 1_800_345_600))], error: nil)
    }

    private func details(quota: CodexHomeQuota?, error: String? = nil, updatedAt: Date? = nil,
                         loading: Bool = false, now: Date) -> CodexAccountDetails {
        CodexAccountDetails(home: home("a", email: "account6266@example.test", note: "6266"),
                            workspacePath: "/tmp/project-research", threadCount: 24,
                            quota: quota, quotaError: error, quotaUpdatedAt: updatedAt,
                            isQuotaLoading: loading, isActionRunning: false, observedAt: now)
    }
}
