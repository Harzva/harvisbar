import AppKit
import Combine
import SwiftUI

enum HarvisVersionPopoverEntryContract {
    static let title = "版本与源码"
    static let accessibilityIdentifier = "harvis-version-manager-entry"

    /// The catalog is a read-only inspector and remains available while a
    /// service mutation is running. Keep this separate from the restart row's
    /// `.disabled(model.isBusy)` scope.
    static func isEnabled(runtimeIsBusy _: Bool) -> Bool { true }
}

@MainActor
enum HarvisVersionCatalogWindowConfiguration {
    static let title = "Harvis 版本管理"
    static let accessibilityIdentifier = "harvis-version-catalog-window"
    static let initialContentSize = NSSize(width: 1_060, height: 700)
    static let minimumContentSize = NSSize(width: 860, height: 560)
    static let styleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
    ]

    static func make(contentViewController: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentMinSize = minimumContentSize
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = contentViewController
        // Assigning a hosting controller can adopt its minimum fitting size.
        // Reassert the documented initial *content* size afterwards.
        window.setContentSize(initialContentSize)
        window.setAccessibilityIdentifier(accessibilityIdentifier)
        window.center()
        return window
    }

    static func makeProductionWindow(
        apiVersionProvider: @escaping @MainActor () -> String?,
        apiVersionUpdates: AnyPublisher<String?, Never>?
    ) -> NSWindow {
        let catalogModel = HarvisVersionCatalogModel.production(
            apiVersionProvider: apiVersionProvider,
            apiVersionUpdates: apiVersionUpdates
        )
        let windowBox = HarvisVersionCatalogWindowReference()
        let root = HarvisVersionCatalogView(
            model: catalogModel,
            effects: .live,
            closeAction: {
                windowBox.performClose()
            }
        )
        let hosting = NSHostingController(rootView: root)
        let window = make(contentViewController: hosting)
        windowBox.window = window
        return window
    }

#if HARVIS_VERSION_UI_TESTING
    static func makeFixtureWindow(
        provider: HarvisVersionFixtureProvider
    ) -> NSWindow {
        let windowReference = HarvisVersionCatalogWindowReference()
        let fixtureState = HarvisVersionFixtureViewState(provider: provider)
        let root = HarvisVersionFixtureCatalogRoot(
            model: provider.makeCatalogModel(),
            state: fixtureState,
            closeAction: {
                windowReference.performClose()
            }
        )
        let hosting = NSHostingController(rootView: root)
        let window = make(contentViewController: hosting)
        windowReference.window = window
        return window
    }
#endif
}

@MainActor
final class HarvisVersionCatalogWindowReference {
    weak var window: NSWindow?

    func performClose() {
        window?.performClose(nil)
    }
}

@MainActor
final class HarvisVersionCatalogWindowController {
    typealias APIVersionProvider = @MainActor () -> String?
    typealias APIVersionUpdates = AnyPublisher<String?, Never>
    typealias WindowFactory = @MainActor (
        @escaping APIVersionProvider,
        APIVersionUpdates?
    ) -> NSWindow
    typealias ApplicationActivator = @MainActor () -> Void

    static let shared = HarvisVersionCatalogWindowController()

    private var windowFactory: WindowFactory
    private let applicationActivator: ApplicationActivator
    private(set) var window: NSWindow?
    private(set) var creationCount = 0

    init(
        windowFactory: @escaping WindowFactory = { provider, updates in
            HarvisVersionCatalogWindowConfiguration.makeProductionWindow(
                apiVersionProvider: provider,
                apiVersionUpdates: updates
            )
        },
        applicationActivator: @escaping ApplicationActivator = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    ) {
        self.windowFactory = windowFactory
        self.applicationActivator = applicationActivator
    }

    /// Shows the process-owned inspector window. Closing never discards the
    /// instance, so a later invocation restores the same model and selection.
    func showWindow(
        apiVersionProvider: @escaping APIVersionProvider,
        apiVersionUpdates: APIVersionUpdates? = nil
    ) {
        let managedWindow: NSWindow
        if let window {
            managedWindow = window
        } else {
            let created = windowFactory(apiVersionProvider, apiVersionUpdates)
            created.isReleasedWhenClosed = false
            window = created
            creationCount += 1
            managedWindow = created
        }

        if managedWindow.isMiniaturized {
            managedWindow.deminiaturize(nil)
        }
        managedWindow.makeKeyAndOrderFront(nil)
        applicationActivator()
    }

#if HARVIS_VERSION_UI_TESTING
    static func installFixtureProvider(_ provider: HarvisVersionFixtureProvider) {
        precondition(
            shared.window == nil,
            "Fixture window factory must be installed before the first catalog window"
        )
        shared.windowFactory = { _, _ in
            HarvisVersionCatalogWindowConfiguration.makeFixtureWindow(
                provider: provider
            )
        }
    }
#endif
}

#if HARVIS_VERSION_UI_TESTING
@MainActor
final class HarvisTaskProgressFixtureWindowController {
    static let shared = HarvisTaskProgressFixtureWindowController()

    private var window: NSWindow?

    func show(
        model: HarvisRuntimeModel,
        provider: HarvisVersionFixtureProvider
    ) {
        let managedWindow: NSWindow
        if let window {
            managedWindow = window
        } else {
            let root = HarvisTaskProgressFixtureRoot(
                model: model,
                state: HarvisVersionFixtureViewState(provider: provider)
            )
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 338, height: 668),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.title = "Harvis task-progress 闭环"
            created.isReleasedWhenClosed = false
            created.contentViewController = NSHostingController(rootView: root)
            created.setAccessibilityIdentifier("harvis-task-progress-fixture-window")
            created.center()
            window = created
            managedWindow = created
        }
        managedWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#endif

extension HarvisRuntimeModel {
    func openHarvisVersionCatalog() {
        HarvisVersionCatalogWindowController.shared.showWindow(
            apiVersionProvider: { [weak self] in
                self?.health?.apiVersion
            },
            apiVersionUpdates: $health
                .map { $0?.apiVersion }
                .eraseToAnyPublisher()
        )
    }
}
