import Foundation
import XCTest
@testable import HarvisBar

final class HarvisBuildInfoTests: XCTestCase {
    func testFooterDistinguishesBundleAndRuntimeAPIVersions() {
        XCTAssertEqual(
            HarvisBuildInfo.footerLabel(
                appVersion: "0.35.0",
                apiVersion: "v0.40-rust-alpha"
            ),
            "App 0.35.0 · API v0.40-rust-alpha"
        )
    }

    func testFooterShowsOfflineWithoutHidingAppVersion() {
        XCTAssertEqual(
            HarvisBuildInfo.footerLabel(appVersion: "0.35.0", apiVersion: nil),
            "App 0.35.0 · API offline"
        )
        XCTAssertEqual(
            HarvisBuildInfo.footerLabel(appVersion: "0.35.0", apiVersion: "  "),
            "App 0.35.0 · API offline"
        )
    }
}
