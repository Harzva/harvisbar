import Foundation
import XCTest
@testable import HarvisBar

final class HarvisPermissionCenterTests: XCTestCase {
    @MainActor
    func testPreflightAndRefreshNeverRequestOrOpenPermissions() {
        var accessibility = false
        var requests = 0
        var opened: [URL] = []
        let center = HarvisPermissionCenter(environment: .init(
            accessibilityGranted: { accessibility }, screenRecordingGranted: { false },
            requestAccessibility: { requests += 1 },
            requestScreenRecording: { requests += 1; return false },
            openURL: { opened.append($0); return true }, revealApp: { _ in requests += 1 }
        ))
        XCTAssertFalse(center.accessibilityGranted)
        accessibility = true
        center.refreshStatus()
        XCTAssertTrue(center.accessibilityGranted)
        XCTAssertFalse(center.screenRecordingGranted)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(opened.isEmpty)
    }

    @MainActor
    func testExplicitRequestsRemainIndependentAndSettingsDoNotImplyGrant() {
        var accessibilityRequests = 0
        var screenRequests = 0
        var opened: [URL] = []
        let center = HarvisPermissionCenter(environment: .init(
            accessibilityGranted: { false }, screenRecordingGranted: { false },
            requestAccessibility: { accessibilityRequests += 1 },
            requestScreenRecording: { screenRequests += 1; return false },
            openURL: { opened.append($0); return true }, revealApp: { _ in }
        ))
        center.openSettings(.fullDiskAccess)
        XCTAssertEqual(accessibilityRequests, 0)
        XCTAssertEqual(screenRequests, 0)
        center.requestAccessibility()
        XCTAssertEqual(accessibilityRequests, 1)
        XCTAssertEqual(screenRequests, 0)
        center.requestScreenRecording()
        XCTAssertEqual(screenRequests, 1)
        XCTAssertEqual(opened.count, 3)
        XCTAssertFalse(center.accessibilityGranted)
        XCTAssertFalse(center.screenRecordingGranted)
    }

    @MainActor
    func testSettingsFallbackReportsFailureWithoutChangingPermissionState() {
        var attempts = 0
        let center = HarvisPermissionCenter(environment: .init(
            accessibilityGranted: { true }, screenRecordingGranted: { false },
            requestAccessibility: {}, requestScreenRecording: { false },
            openURL: { _ in attempts += 1; return false }, revealApp: { _ in }
        ))
        center.openSettings(.automation)
        XCTAssertEqual(attempts, 3)
        XCTAssertNotNil(center.actionError)
        XCTAssertTrue(center.accessibilityGranted)
        XCTAssertFalse(center.screenRecordingGranted)
    }

    @MainActor
    func testGuideAcknowledgementDoesNotEnableOptionalScanning() throws {
        let suite = "harvis-access-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HarvisAccessPreferences(defaults: defaults)
        XCTAssertFalse(preferences.hasSeenPermissionGuide)
        XCTAssertFalse(preferences.externalHomeDiscoveryEnabled)
        XCTAssertFalse(preferences.historicalProjectAccessEnabled)
        XCTAssertFalse(preferences.allowsWorkspaceAccess(workspaceRoot: "/fixture/work", profileRoot: "/fixture/profile"))
        preferences.markPermissionGuideSeen()
        let restored = HarvisAccessPreferences(defaults: defaults)
        XCTAssertTrue(restored.hasSeenPermissionGuide)
        XCTAssertFalse(restored.externalHomeDiscoveryEnabled)
        XCTAssertFalse(restored.historicalProjectAccessEnabled)
        XCTAssertNil(restored.workspaceAccessScope)
        restored.externalHomeDiscoveryEnabled = true
        XCTAssertTrue(HarvisAccessPreferences(defaults: defaults).externalHomeDiscoveryEnabled)
        XCTAssertFalse(HarvisAccessPreferences(defaults: defaults).historicalProjectAccessEnabled)
        restored.externalHomeDiscoveryEnabled = false
        XCTAssertFalse(HarvisAccessPreferences(defaults: defaults).externalHomeDiscoveryEnabled)
    }

    @MainActor
    func testWorkspaceConsentIsBoundToBothPathsAndCanBeRevokedAcrossRestarts() throws {
        let suite = "harvis-access-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HarvisAccessPreferences(defaults: defaults)
        preferences.allowWorkspaceAccess(workspaceRoot: "/fixture/work/", profileRoot: "/fixture/profile")
        let restored = HarvisAccessPreferences(defaults: defaults)
        XCTAssertTrue(restored.allowsWorkspaceAccess(workspaceRoot: "/fixture/work", profileRoot: "/fixture/profile"))
        XCTAssertFalse(restored.allowsWorkspaceAccess(workspaceRoot: "/fixture/other", profileRoot: "/fixture/profile"))
        XCTAssertFalse(restored.allowsWorkspaceAccess(workspaceRoot: "/fixture/work", profileRoot: "/fixture/other"))
        XCTAssertFalse(restored.hasSeenPermissionGuide)
        restored.revokeWorkspaceAccess()
        XCTAssertNil(HarvisAccessPreferences(defaults: defaults).workspaceAccessScope)
    }
}
