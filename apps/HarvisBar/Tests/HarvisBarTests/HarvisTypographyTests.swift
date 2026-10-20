import XCTest
@testable import HarvisBar

@MainActor
final class HarvisTypographyTests: XCTestCase {
    func testTextSizePointMappingUsesMediumMacOSBasesAndReadabilityFloors() {
        XCTAssertEqual(HarvisTextSize.defaultsKey, "harvis.codex.chatManager.textSize")
        XCTAssertEqual(HarvisTextSize.defaultValue, .medium)
        XCTAssertEqual(HarvisTextSize.small.title, "小")
        XCTAssertEqual(HarvisTextSize.medium.title, "中")
        XCTAssertEqual(HarvisTextSize.large.title, "大")

        XCTAssertEqual(HarvisTextSize.small.layoutScale, 1)
        XCTAssertEqual(HarvisTextSize.medium.layoutScale, 1.16, accuracy: 0.0001)
        XCTAssertEqual(HarvisTextSize.large.layoutScale, 1.38, accuracy: 0.0001)

        XCTAssertEqual(HarvisTextSize.small.pointSize(for: 13), 13, accuracy: 0.0001)
        XCTAssertEqual(HarvisTextSize.medium.pointSize(for: 13), 15, accuracy: 0.0001)
        XCTAssertEqual(HarvisTextSize.large.pointSize(for: 13), 18, accuracy: 0.0001)
        XCTAssertEqual(HarvisTextSize.small.pointSize(for: 10), 11, accuracy: 0.0001)
        XCTAssertEqual(HarvisTextSize.medium.pointSize(for: 10), 13, accuracy: 0.0001)
        XCTAssertEqual(HarvisTextSize.large.pointSize(for: 10), 15, accuracy: 0.0001)
    }

    func testComposerSlotsScaleWithTheTextSizeEnvironmentHint() {
        XCTAssertEqual(
            CodexTaskComposerLayoutMetrics.inputHeight(compact: true, for: nil),
            CodexTaskComposerLayoutMetrics.compactInputHeight,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CodexTaskComposerLayoutMetrics.controlsHeight(for: nil),
            CodexTaskComposerLayoutMetrics.controlsHeight,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CodexTaskComposerLayoutMetrics.matrixComposerSlotHeight(for: .small),
            CodexTaskComposerLayoutMetrics.matrixComposerSlotHeight,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CodexTaskComposerLayoutMetrics.matrixComposerSlotHeight(for: .medium),
            CodexTaskComposerLayoutMetrics.matrixComposerSlotHeight * HarvisTextSize.medium.layoutScale,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CodexTaskComposerLayoutMetrics.inputHeight(compact: false, for: .large),
            CodexTaskComposerLayoutMetrics.matrixInputHeight * HarvisTextSize.large.layoutScale,
            accuracy: 0.0001
        )
    }
}
