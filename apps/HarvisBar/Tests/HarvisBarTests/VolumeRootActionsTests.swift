import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class VolumeRootActionsTests: XCTestCase {
    func testCopyUsesMountedVolumeRootPathVerbatim() {
        var copiedPath: String?
        let actions = VolumeRootActions(
            pathWriter: { path in
                copiedPath = path
                return true
            },
            urlOpener: { _ in
                XCTFail("Copying a path must not open Finder")
                return false
            },
            urlRevealer: { _ in
                XCTFail("Copying a path must not reveal Finder")
                return false
            }
        )
        let disk = makeDisk(path: "/Volumes/Example Disk")

        XCTAssertTrue(actions.copyRootPath(for: disk))
        XCTAssertEqual(copiedPath, "/Volumes/Example Disk")
    }

    func testOpenUsesMountedVolumeRootURLVerbatim() {
        var openedURL: URL?
        let actions = VolumeRootActions(
            pathWriter: { _ in
                XCTFail("Opening a root must not write to the clipboard")
                return false
            },
            urlOpener: { url in
                openedURL = url
                return true
            },
            urlRevealer: { _ in
                XCTFail("Opening a root must not reveal Finder")
                return false
            }
        )
        let disk = makeDisk(path: "/")

        XCTAssertTrue(actions.openRoot(for: disk))
        XCTAssertEqual(openedURL?.path, "/")
    }

    func testSystemActionFailuresAreReturnedToTheCaller() {
        let actions = VolumeRootActions(
            pathWriter: { _ in false },
            urlOpener: { _ in false },
            urlRevealer: { _ in false }
        )
        let disk = makeDisk(path: "/Volumes/Example Disk")

        XCTAssertFalse(actions.copyRootPath(for: disk))
        XCTAssertFalse(actions.openRoot(for: disk))
        XCTAssertFalse(actions.revealRoot(for: disk))
    }

    func testRevealUsesMountedVolumeRootURLVerbatim() {
        var revealedURL: URL?
        let actions = VolumeRootActions(
            pathWriter: { _ in false },
            urlOpener: { _ in false },
            urlRevealer: { url in
                revealedURL = url
                return true
            }
        )
        let disk = makeDisk(path: "/Volumes/Example Disk")

        XCTAssertTrue(actions.revealRoot(for: disk))
        XCTAssertEqual(revealedURL?.path, "/Volumes/Example Disk")
    }

    func testAccessibilityIdentifierIsStableSafeAndDoesNotExposePath() {
        let disk = makeDisk(path: "/Volumes/Example Disk")
        let first = VolumeRootActions.accessibilityIdentifierComponent(for: disk)
        let second = VolumeRootActions.accessibilityIdentifierComponent(for: disk)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("external-"))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains(" "))
        XCTAssertFalse(first.contains("Example"))
    }

    private func makeDisk(path: String) -> DiskInfo {
        DiskInfo(
            name: path == "/" ? "Macintosh HD" : "External",
            volumeURL: URL(fileURLWithPath: path, isDirectory: true),
            totalBytes: 1_000,
            availableBytes: 500,
            usedBytes: 500,
            isInternal: path == "/",
            isRemovable: false
        )
    }
}
