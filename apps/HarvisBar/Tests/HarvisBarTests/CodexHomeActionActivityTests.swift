import XCTest
@testable import HarvisBar

@MainActor
final class CodexHomeActionActivityTests: XCTestCase {
    func testOverlappingAccountActionsStayBusyUntilEveryOwnerFinishes() throws {
        let suite = "harvis-tests.action-activity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(defaults: defaults)
        // Login, a desktop card, and another account overlap.
        model.beginCodexHomeAction("account-a")
        model.beginCodexHomeAction("account-a")
        model.beginCodexHomeAction("account-b")
        model.endCodexHomeAction("account-a")
        XCTAssertEqual(model.codexHomeActionIDs, ["account-a", "account-b"])
        model.endCodexHomeAction("account-b")
        XCTAssertEqual(model.codexHomeActionIDs, ["account-a"])
        model.endCodexHomeAction("account-a")
        XCTAssertTrue(model.codexHomeActionIDs.isEmpty)
        XCTAssertTrue(model.codexHomeActionCounts.isEmpty)
        model.endCodexHomeAction("account-a")
        model.beginCodexHomeAction("account-a")
        XCTAssertEqual(model.codexHomeActionIDs, ["account-a"])
    }
}
