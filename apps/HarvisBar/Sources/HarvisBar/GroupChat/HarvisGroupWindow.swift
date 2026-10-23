import AppKit
import SwiftUI

@MainActor
final class HarvisGroupWindowController: NSObject, NSWindowDelegate {
    static let shared = HarvisGroupWindowController()

    private var window: NSWindow?

    func show(runtime: HarvisRuntimeModel, coordinator: HarvisGroupCoordinator) {
        if window == nil {
            let root = HarvisGroupWindowView(
                runtime: runtime,
                coordinator: coordinator,
                composerState: runtime.groupComposerState
            )
                .preferredColorScheme(runtime.theme.preferredColorScheme)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Codex 成员群聊"
            window.minSize = NSSize(width: 800, height: 600)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: root)
            window.delegate = self
            window.center()
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}
