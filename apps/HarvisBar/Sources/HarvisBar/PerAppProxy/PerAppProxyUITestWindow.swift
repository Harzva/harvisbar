import AppKit
import SwiftUI

@MainActor
final class PerAppProxyUITestWindowController: NSObject, NSWindowDelegate {
    static let shared = PerAppProxyUITestWindowController()
    private var window: NSWindow?

    func show(model: HarvisRuntimeModel) {
        let content = HarvisPopoverView()
            .environmentObject(model)
            .frame(width: 318, height: 620)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 318, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "HarvisBar UI Test"
        window.contentViewController = hostingController
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
