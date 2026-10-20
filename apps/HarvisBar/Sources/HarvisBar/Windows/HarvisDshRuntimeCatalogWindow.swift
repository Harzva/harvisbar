import AppKit
import SwiftUI

@MainActor
final class HarvisDshQuickWindowController: NSObject, NSWindowDelegate {
    static let shared = HarvisDshQuickWindowController()
    private var window: NSWindow?

    func show(model: HarvisRuntimeModel) {
        if window == nil {
            let content = HarvisPopoverView(selectedSection: .dsh)
                .environmentObject(model)
                .frame(width: 318, height: 620)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 318, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "DSH 快捷管理"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: content)
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

@MainActor
final class HarvisDshRuntimeCatalogWindowController: NSObject, NSWindowDelegate {
    static let shared = HarvisDshRuntimeCatalogWindowController()

    private var window: NSWindow?
    private var catalogModel: DshRuntimeCatalogModel?

    func show(model: HarvisRuntimeModel, layer: DshManagementLayer = .launch, homeID: String? = nil, profile: String = "") {
        let navigation = catalogModel ?? DshRuntimeCatalogModel(runtimeModel: model)
        catalogModel = navigation
        navigation.layer = layer
        navigation.profileFilter = profile
        if let homeID { navigation.selectHome(homeID) }
        if layer == .launch, let homeID, !profile.isEmpty {
            navigation.selectionID = "profile:\(homeID).\(profile)"
        }
        if window == nil {
            let hosting = NSHostingController(
                rootView: DshRuntimeCatalogView(model: navigation)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "DSH 启动预览"
            window.minSize = NSSize(width: 860, height: 560)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.delegate = self
            window.center()
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}

extension HarvisRuntimeModel {
    func openDshRuntimeCatalog(layer: DshManagementLayer = .launch, homeID: String? = nil, profile: String = "") {
        HarvisDshRuntimeCatalogWindowController.shared.show(model: self, layer: layer, homeID: homeID, profile: profile)
    }
}
