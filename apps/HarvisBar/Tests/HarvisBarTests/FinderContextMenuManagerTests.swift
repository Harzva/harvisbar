import Foundation
import XCTest
@testable import HarvisBar

final class FinderContextMenuManagerTests: XCTestCase {
    func testCommandTimeoutIsBoundedAndReportedThroughExistingResult() {
        let startedAt = ProcessInfo.processInfo.systemUptime

        let result = FinderContextMenuManagerModel.runCommand(
            "/bin/sleep",
            ["60"],
            timeout: 0.1
        )

        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.output.contains("timed out"))
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            2,
            "Finder context-menu process execution must remain bounded"
        )
    }

    func testCommandTimeoutsMatchOperationClass() {
        XCTAssertEqual(FinderContextMenuManagerModel.shortCommandTimeout, 8)
        XCTAssertEqual(FinderContextMenuManagerModel.sourceVerificationTimeout, 120)
    }

    func testCommandPreservesStatusAndMapsBothOutputStreams() {
        let result = FinderContextMenuManagerModel.runCommand(
            "/bin/sh",
            ["-c", "printf stdout; printf stderr >&2; exit 7"]
        )

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "stdout\nstderr")
    }
}
