import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

/// Uses public, non-prompting preflight APIs for observable permission state.
/// Full Disk Access and per-target Automation remain system-managed; probing
/// unrelated private files to guess their state would itself request access.
@MainActor
final class HarvisPermissionCenter: ObservableObject {
    enum Permission: CaseIterable {
        case accessibility, screenRecording, fullDiskAccess, automation

        fileprivate var settingsPane: String {
            switch self {
            case .accessibility: "Privacy_Accessibility"
            case .screenRecording: "Privacy_ScreenCapture"
            case .fullDiskAccess: "Privacy_AllFiles"
            case .automation: "Privacy_Automation"
            }
        }
    }

    struct Environment {
        var accessibilityGranted: () -> Bool
        var screenRecordingGranted: () -> Bool
        var requestAccessibility: () -> Void
        var requestScreenRecording: () -> Bool
        var openURL: (URL) -> Bool
        var revealApp: (URL) -> Void

        static var live: Self {
            Self(
                accessibilityGranted: { AXIsProcessTrusted() },
                screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
                requestAccessibility: {
                    // The C SDK declares the constant as shared mutable state;
                    // use the same documented key as the existing window tools.
                    let options = ["AXTrustedCheckOptionPrompt": true]
                    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                },
                requestScreenRecording: { CGRequestScreenCaptureAccess() },
                openURL: { NSWorkspace.shared.open($0) },
                revealApp: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
            )
        }

#if DEBUG
        static var fixture: Self {
            Self(accessibilityGranted: { false }, screenRecordingGranted: { false },
                 requestAccessibility: {}, requestScreenRecording: { false },
                 openURL: { _ in true }, revealApp: { _ in })
        }
#endif
    }

    let appURL: URL
    private let environment: Environment
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var actionError: String?

    var appIcon: NSImage { NSWorkspace.shared.icon(forFile: appURL.path) }

    init(appURL: URL = Bundle.main.bundleURL, environment: Environment = .live) {
        self.appURL = appURL
        self.environment = environment
        refreshStatus()
    }

    func refreshStatus() {
        accessibilityGranted = environment.accessibilityGranted()
        screenRecordingGranted = environment.screenRecordingGranted()
    }

    func requestAccessibility() {
        actionError = nil
        environment.requestAccessibility()
        refreshStatus()
        if !accessibilityGranted { openSettings(.accessibility) }
    }

    func requestScreenRecording() {
        actionError = nil
        let granted = environment.requestScreenRecording()
        refreshStatus()
        if !granted { openSettings(.screenRecording) }
    }

    func openSettings(_ permission: Permission) {
        actionError = nil
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(permission.settingsPane)",
            "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsPane)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), environment.openURL(url) { return }
        }
        actionError = "未能打开系统设置，请手动进入「系统设置 → 隐私与安全性」。"
    }

    func revealAppInFinder() {
        environment.revealApp(appURL)
    }
}
