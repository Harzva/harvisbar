import Foundation
import XCTest
@testable import HarvisBar

final class ManagedWorkspaceLayoutTests: XCTestCase {
    func testWorkspacePreferenceKeysAndDefaultsAreStable() {
        XCTAssertEqual(
            ManagedWorkspaceLayout.railWidthKey,
            "harvis.codex.chatManager.railWidth"
        )
        XCTAssertEqual(
            ManagedWorkspaceLayout.workbenchWidthKey,
            "harvis.codex.chatManager.workbenchWidth"
        )
        XCTAssertEqual(
            ManagedWorkspaceLayout.workbenchHeightKey,
            "harvis.codex.chatManager.workbenchHeight"
        )
        XCTAssertEqual(
            ManagedWorkspaceLayout.workbenchPlacementKey,
            "harvis.codex.chatManager.workbenchPlacement"
        )
        XCTAssertEqual(ManagedWorkspaceLayout.defaultRailWidth, 224)
        XCTAssertEqual(ManagedWorkspaceLayout.defaultWorkbenchWidth, 460)
        XCTAssertEqual(ManagedWorkspaceLayout.defaultWorkbenchHeight, 300)
        XCTAssertEqual(ManagedWorkspaceLayout.defaultWorkbenchPlacement, .automatic)
    }

    func testPlacementRoundTripsAndUsesReadableTitles() {
        XCTAssertEqual(
            ManagedWorkbenchPlacement.allCases.map(\.rawValue),
            ["automatic", "right", "bottom"]
        )
        XCTAssertEqual(
            ManagedWorkbenchPlacement.allCases.map(\.title),
            ["自动", "右侧", "底部"]
        )
        for placement in ManagedWorkbenchPlacement.allCases {
            XCTAssertEqual(ManagedWorkbenchPlacement(rawValue: placement.rawValue), placement)
        }
    }

    func testClampsLeadingAndTrailingPanesToBothMinimums() {
        let leadingMinimum: CGFloat = 180
        let trailingMinimum: CGFloat = 220
        let available: CGFloat = 600

        XCTAssertEqual(
            ManagedSplitGeometry.clampedLength(
                requestedLength: 50,
                availableExtent: available,
                minimumLeading: leadingMinimum,
                minimumTrailing: trailingMinimum,
                fixedPane: .leading
            ),
            180
        )
        XCTAssertEqual(
            ManagedSplitGeometry.clampedLength(
                requestedLength: 500,
                availableExtent: available,
                minimumLeading: leadingMinimum,
                minimumTrailing: trailingMinimum,
                fixedPane: .leading
            ),
            368
        )
        XCTAssertEqual(
            ManagedSplitGeometry.clampedLength(
                requestedLength: 50,
                availableExtent: available,
                minimumLeading: leadingMinimum,
                minimumTrailing: trailingMinimum,
                fixedPane: .trailing
            ),
            220
        )
        XCTAssertEqual(
            ManagedSplitGeometry.clampedLength(
                requestedLength: 500,
                availableExtent: available,
                minimumLeading: leadingMinimum,
                minimumTrailing: trailingMinimum,
                fixedPane: .trailing
            ),
            408
        )
    }

    func testInvalidValuesUseFiniteFallbackAndNeverProduceInvalidGeometry() {
        let invalid: [Double] = [.nan, .infinity, -.infinity]
        for value in invalid {
            let length = ManagedSplitGeometry.clampedLength(
                requestedLength: value,
                defaultLength: 300,
                availableExtent: 640,
                minimumLeading: 120,
                minimumTrailing: 120,
                fixedPane: .leading
            )
            XCTAssertEqual(length, 300)
            XCTAssertTrue(length.isFinite)
            XCTAssertGreaterThanOrEqual(length, 0)
        }

        let narrow = ManagedSplitGeometry.paneLengths(
            requestedLength: .nan,
            defaultLength: .infinity,
            availableExtent: 100,
            minimumLeading: 120,
            minimumTrailing: 120,
            fixedPane: .leading
        )
        XCTAssertEqual(narrow.leading, 44)
        XCTAssertEqual(narrow.trailing, 44)
        XCTAssertTrue(narrow.leading.isFinite)
        XCTAssertTrue(narrow.trailing.isFinite)
        XCTAssertEqual(narrow.leading + narrow.trailing, 88)
    }

    func testNonPositiveAndNonFiniteWindowExtentsCollapseSafely() {
        for available in [CGFloat.zero, -20, .infinity, -.infinity, .nan] {
            XCTAssertEqual(
                ManagedSplitGeometry.paneExtent(availableExtent: available),
                0
            )
            let panes = ManagedSplitGeometry.paneLengths(
                requestedLength: 240,
                availableExtent: available,
                minimumLeading: 100,
                minimumTrailing: 100,
                fixedPane: .leading
            )
            XCTAssertEqual(panes.leading, 0)
            XCTAssertEqual(panes.trailing, 0)
        }
    }

    func testVerticalAndHorizontalPaneCalculationsShareTheSameContract() {
        XCTAssertEqual(
            ManagedSplitGeometry.availableExtent(
                for: .horizontal,
                in: CGSize(width: 700, height: 280)
            ),
            700
        )
        XCTAssertEqual(
            ManagedSplitGeometry.availableExtent(
                for: .vertical,
                in: CGSize(width: 700, height: 280)
            ),
            280
        )

        let horizontal = ManagedSplitGeometry.paneLengths(
            requestedLength: 260,
            availableExtent: 700,
            minimumLeading: 160,
            minimumTrailing: 180,
            fixedPane: .leading
        )
        let vertical = ManagedSplitGeometry.paneLengths(
            requestedLength: 260,
            availableExtent: 700,
            minimumLeading: 160,
            minimumTrailing: 180,
            fixedPane: .leading
        )
        XCTAssertEqual(horizontal.leading, vertical.leading)
        XCTAssertEqual(horizontal.trailing, vertical.trailing)
        XCTAssertEqual(horizontal.leading + horizontal.trailing, 688)
    }

    func testNarrowDisplayDoesNotRewriteStoredPreference() {
        let suiteName = "ManagedWorkspaceLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(460.0, forKey: ManagedWorkspaceLayout.workbenchWidthKey)
        _ = ManagedSplitGeometry.paneLengths(
            requestedLength: defaults.double(forKey: ManagedWorkspaceLayout.workbenchWidthKey),
            availableExtent: 220,
            minimumLeading: 100,
            minimumTrailing: 100,
            fixedPane: .trailing
        )

        XCTAssertEqual(
            defaults.double(forKey: ManagedWorkspaceLayout.workbenchWidthKey),
            460
        )
    }
}
