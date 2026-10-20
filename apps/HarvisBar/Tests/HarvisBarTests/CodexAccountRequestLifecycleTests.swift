import XCTest
@testable import HarvisBar

@MainActor
final class CodexAccountRequestLifecycleTests: XCTestCase {
    func testIdentityReplacementClearsOldActivityAndLateCompletionsKeepReplacementBusy() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = home("a", email: "first@example.test")
        let replacement = home("a", email: "second@example.test")
        model.codexHomes = [original]
        let oldQuotaRequest = try XCTUnwrap(model.beginCodexHomeQuotaRequest(original))
        let oldActionRequest = try XCTUnwrap(model.beginCodexHomeAction(for: original))
        XCTAssertTrue(model.codexHomeQuotaLoadingIDs.contains("a"))
        XCTAssertTrue(model.codexHomeActionIDs.contains("a"))

        model.codexHomes = [replacement]
        XCTAssertTrue(model.codexHomeQuotaLoadingIDs.isEmpty)
        XCTAssertTrue(model.codexHomeActionIDs.isEmpty)
        XCTAssertFalse(model.isCurrentCodexRequest(oldQuotaRequest))
        XCTAssertFalse(model.isCurrentCodexRequest(oldActionRequest))

        let newQuotaRequest = try XCTUnwrap(model.beginCodexHomeQuotaRequest(replacement))
        let newActionRequest = try XCTUnwrap(model.beginCodexHomeAction(for: replacement))
        model.endCodexHomeQuotaRequest(oldQuotaRequest)
        model.endCodexHomeAction(oldActionRequest)

        XCTAssertTrue(model.codexHomeQuotaLoadingIDs.contains("a"))
        XCTAssertTrue(model.codexHomeActionIDs.contains("a"))
        XCTAssertTrue(model.isCurrentCodexRequest(newQuotaRequest))
        XCTAssertTrue(model.isCurrentCodexRequest(newActionRequest))
    }

    func testOldRequestCannotOwnStateAfterAccountReturnsToItsFormerIdentity() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = home("a", email: "first@example.test")
        let replacement = home("a", email: "second@example.test")
        model.codexHomes = [original]
        let oldRequest = try XCTUnwrap(model.beginCodexHomeAction(for: original))

        model.codexHomes = [replacement]
        model.codexHomes = [original]
        let newRequest = try XCTUnwrap(model.beginCodexHomeAction(for: original))
        model.endCodexHomeAction(oldRequest)

        XCTAssertFalse(model.isCurrentCodexRequest(oldRequest))
        XCTAssertTrue(model.isCurrentCodexRequest(newRequest))
        XCTAssertEqual(model.codexHomeActionCounts[original.id], 1)
        XCTAssertTrue(model.codexHomeActionIDs.contains(original.id))
    }

    func testLateQuotaResponseCannotOverwriteReplacementAccount() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = home("a", email: "first@example.test")
        let replacement = home("a", email: "second@example.test")
        model.codexHomes = [original]
        let oldRequest = try XCTUnwrap(model.beginCodexHomeQuotaRequest(original))
        model.codexHomes = [replacement]
        let newRequest = try XCTUnwrap(model.beginCodexHomeQuotaRequest(replacement))

        XCTAssertFalse(try model.acceptCodexAccountQuota(quota("a", used: 12), for: original, request: oldRequest))
        XCTAssertTrue(try model.acceptCodexAccountQuota(quota("a", used: 34), for: replacement, request: newRequest))
        XCTAssertEqual(model.codexHomeQuotas[replacement.id]?.buckets.first?.primary?.usedPercent, 34)
    }

    func testHidingAccountDoesNotStrandRequestActivityWhenOldRequestFinishes() throws {
        let (model, defaults, suite) = try fixtureModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        let account = home("a", email: "account@example.test")
        model.codexHomes = [account]
        let quotaRequest = try XCTUnwrap(model.beginCodexHomeQuotaRequest(account))
        let actionRequest = try XCTUnwrap(model.beginCodexHomeAction(for: account))
        model.hiddenCodexHomeIDs = [account.id]

        XCTAssertFalse(model.isCurrentCodexRequest(quotaRequest))
        model.endCodexHomeQuotaRequest(quotaRequest)
        model.endCodexHomeAction(actionRequest)
        XCTAssertTrue(model.codexHomeQuotaLoadingIDs.isEmpty)
        XCTAssertTrue(model.codexHomeActionIDs.isEmpty)
        XCTAssertTrue(model.codexHomeActionCounts.isEmpty)

        model.hiddenCodexHomeIDs = []
        XCTAssertTrue(model.codexHomeQuotaLoadingIDs.isEmpty)
        XCTAssertTrue(model.codexHomeActionIDs.isEmpty)
    }

    private func fixtureModel() throws -> (HarvisRuntimeModel, UserDefaults, String) {
        let suite = "CodexAccountRequestLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (HarvisRuntimeModel(defaults: defaults), defaults, suite)
    }

    private func home(_ id: String, email: String) -> CodexHome {
        CodexHome(
            id: id, label: "Default Codex", accountNote: nil,
            path: "/tmp/codex-account-\(id)", source: "default",
            model: "codex-model", provider: "openai", endpointHost: nil,
            hasAuth: true, accountEmail: email, authStatus: "valid",
            authExpiresAt: nil, authNote: nil, hasConfig: true, skillCount: 12,
            quotaMode: "subscription", quotaNote: nil
        )
    }

    private func quota(_ id: String, used: Int) -> CodexHomeQuota {
        CodexHomeQuota(
            ok: true, schemaVersion: nil, homeId: id, available: true,
            planType: "pro",
            buckets: [CodexQuotaBucket(
                limitId: "codex", limitName: nil, planType: "pro",
                primary: CodexQuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: nil),
                secondary: nil
            )], error: nil
        )
    }
}
