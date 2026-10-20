import XCTest
@testable import HarvisBar

final class HarvisPopoverInteractionContractTests: XCTestCase {
    func testTrackedRefreshIdentifiersAreUniqueAndStable() {
        let identifiers = [
            "harvis.refresh.remote-studio",
            "harvis.refresh.codex-alignment",
            "harvis.refresh.agent-catop",
            "harvis.refresh.dsh-catalog",
            "harvis.refresh.agy-launcher",
            "harvis.refresh.task-progress",
        ]
        XCTAssertEqual(Set(identifiers).count, 6)
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("harvis.refresh.") })
    }

    func testTaskProgressDegradationUsesOneLocalRetryAndOneGlobalAttentionID() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HarvisBar/MenuBar/HarvisTaskProgressSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(
            source.components(separatedBy: "harvis-task-progress-degraded").count,
            2
        )
        XCTAssertEqual(
            source.components(separatedBy: "harvis-task-progress-retry").count,
            2
        )
        XCTAssertFalse(source.contains("model.barStatus?.taskProgress"))
        XCTAssertTrue(source.contains("model.taskProgressLastSuccess"))
        XCTAssertTrue(source.contains("model.refreshTaskProgress()"))

        let popoverURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("HarvisPopoverView.swift")
        let popover = try String(contentsOf: popoverURL, encoding: .utf8)
        XCTAssertEqual(
            popover.components(separatedBy: "harvis-global-attention").count,
            2
        )
    }

    func testGlobalActionsHaveUniqueSemanticLabelsAndStableIdentifiers() {
        let actions = HarvisGlobalAction.allCases
        let labels = actions.map(\.accessibilityLabel)
        let identifiers = actions.map(\.accessibilityIdentifier)

        XCTAssertEqual(actions.count, 10)
        XCTAssertEqual(Set(labels).count, actions.count)
        XCTAssertEqual(Set(identifiers).count, actions.count)
        XCTAssertTrue(labels.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("harvis.global.") })
    }

    func testTopCodexMenuSwitchesAccountsWithoutPerAccountSubmenus() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HarvisBar/MenuBar/HarvisPopoverOverview.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("model.selectCodexHome(home)"))
        XCTAssertFalse(source.contains("Menu(home.accountDisplayLabel)"))
        XCTAssertTrue(source.contains("model.launchCodexCLI(selected)"))
        XCTAssertTrue(source.contains("model.launchCodexDesktop(selected)"))
        XCTAssertTrue(source.contains("model.revealCodexHome(selected)"))
    }

    func testCodexAccountSwitchStartsQuotaAndThreadRefreshConcurrently() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HarvisBar/Runtime/HarvisRuntimeModel+Actions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("async let quotaRefresh: Void = refreshCodexHomeQuota(home)"))
        XCTAssertTrue(source.contains("async let threadRefresh: Void = refreshCodexThreads(home)"))
        XCTAssertTrue(source.contains("_ = await (quotaRefresh, threadRefresh)"))
    }

    func testVersionManagerEntryIsStableAndIndependentOfRuntimeBusyState() {
        XCTAssertEqual(HarvisVersionPopoverEntryContract.title, "版本与源码")
        XCTAssertEqual(
            HarvisVersionPopoverEntryContract.accessibilityIdentifier,
            "harvis-version-manager-entry"
        )
        XCTAssertTrue(HarvisVersionPopoverEntryContract.isEnabled(runtimeIsBusy: false))
        XCTAssertTrue(HarvisVersionPopoverEntryContract.isEnabled(runtimeIsBusy: true))

        // The version inspector is a contextual service action, not an 11th
        // global action. This freezes the existing top-level action contract.
        XCTAssertEqual(HarvisGlobalAction.allCases.count, 10)
        XCTAssertFalse(
            HarvisGlobalAction.allCases.map(\.accessibilityIdentifier).contains(
                HarvisVersionPopoverEntryContract.accessibilityIdentifier
            )
        )

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/HarvisBar/MenuBar/HarvisSystemPopoverSection.swift")
        let source = try? String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(
            source?.components(
                separatedBy: "HarvisVersionPopoverEntryContract.accessibilityIdentifier"
            ).count,
            2,
            "The service section must contain exactly one version-manager entry"
        )
        XCTAssertEqual(
            source?.components(separatedBy: "model.openHarvisVersionCatalog()").count,
            2,
            "The service section must have one entry action"
        )
    }

    func testVersionManagerColdStartArgumentContract() {
        XCTAssertTrue(
            HarvisAppLaunchArguments.shouldOpenHarvisVersionManager([
                "HarvisBar",
                "--open-harvis-version-manager",
            ])
        )
        XCTAssertFalse(
            HarvisAppLaunchArguments.shouldOpenHarvisVersionManager([
                "HarvisBar",
                "--open-dsh-manager",
            ])
        )

        let production = HarvisAppBootRoute.resolve(
            legacyInteractionTest: false,
            isolatedVersionTest: false
        )
        XCTAssertTrue(production.startsRuntime)
        XCTAssertFalse(production.performsLegacyRefresh)

        let versionFixture = HarvisAppBootRoute.resolve(
            legacyInteractionTest: false,
            isolatedVersionTest: true
        )
        XCTAssertFalse(versionFixture.startsRuntime)
        XCTAssertFalse(versionFixture.performsLegacyRefresh)
        XCTAssertFalse(versionFixture.showsLegacyProxyWindow)
    }

    func testReleaseVersionNeverRegressesBelowLastLegacyBundle() throws {
        let cargoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Cargo.toml")
        let cargo = try String(contentsOf: cargoURL, encoding: .utf8)
        let match = cargo.firstMatch(of: /version\s*=\s*"(\d+)\.(\d+)\.(\d+)"/)
        let components = try XCTUnwrap(match).output
        let version = [
            Int(components.1),
            Int(components.2),
            Int(components.3),
        ].compactMap { $0 }

        XCTAssertEqual(version.count, 3)
        XCTAssertGreaterThanOrEqual(version.lexicographicCompare([0, 35, 0]), 0)
    }
}

private extension Array where Element == Int {
    func lexicographicCompare(_ other: [Int]) -> Int {
        for (left, right) in zip(self, other) where left != right {
            return left < right ? -1 : 1
        }
        if count == other.count { return 0 }
        return count < other.count ? -1 : 1
    }
}
