import AppKit
import XCTest
@testable import HarvisBar

final class CodexDockGeometryTests: XCTestCase {
    func testLockedRightAttachmentPreservesWidthAndOverlapWhileCodexMoves() {
        let initial = CodexDockGeometry.lockedFrame(
            beside: NSRect(x: 100, y: 120, width: 1_200, height: 800),
            side: .right,
            visibleWidth: 480,
            overlap: 14,
            gap: 0
        )
        let moved = CodexDockGeometry.lockedFrame(
            beside: NSRect(x: 260, y: 220, width: 1_200, height: 800),
            side: .right,
            visibleWidth: 480,
            overlap: 14,
            gap: 0
        )

        XCTAssertEqual(initial.width, 494)
        XCTAssertEqual(moved.width, initial.width)
        XCTAssertEqual(moved.minX, 260 + 1_200 - 14)
        XCTAssertEqual(moved.minY, 220)
        XCTAssertEqual(moved.height, 800)
    }

    func testLockedAttachmentTracksCodexHeightWithoutChangingWidth() {
        let resized = CodexDockGeometry.lockedFrame(
            beside: NSRect(x: 640, y: 80, width: 1_000, height: 960),
            side: .left,
            visibleWidth: 620,
            overlap: 14,
            gap: 0
        )

        XCTAssertEqual(resized.width, 634)
        XCTAssertEqual(resized.height, 960)
        XCTAssertEqual(resized.maxX, 640 + 14)
        XCTAssertEqual(resized.minY, 80)
    }

    func testAccessibilityCoordinatesMatchAppKitCoordinates() {
        let frame = CodexDockGeometry.appKitFrame(
            quartzOrigin: CGPoint(x: 1_984, y: 936),
            size: CGSize(width: 768, height: 912),
            mainDisplayTop: 2_160
        )

        XCTAssertEqual(frame, NSRect(x: 1_984, y: 312, width: 768, height: 912))
    }
}
