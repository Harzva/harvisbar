import AppKit
import SwiftUI
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisVersionCatalogWindowTests: XCTestCase {
    func testVisibleEscapeIsSingleLineAndPreservesUnsafeScalarsReversibly() {
        let raw = "folder\\name\nline\rreturn\ttab\u{007F}\u{202E}end"
        let visible = HarvisVersionVisibleEscape.encode(raw)

        XCTAssertEqual(
            visible,
            "folder\\\\name\\nline\\rreturn\\ttab\\u{007F}\\u{202E}end"
        )
        XCTAssertFalse(visible.contains("\n"))
        XCTAssertFalse(visible.contains("\r"))
        XCTAssertFalse(visible.unicodeScalars.contains("\u{202E}"))
    }

    func testWindowUsesContentSizingAndStableAccessibilityIdentity() {
        let controller = NSHostingController(rootView: Color.clear)
        let window = HarvisVersionCatalogWindowConfiguration.make(
            contentViewController: controller
        )
        defer { window.close() }

        XCTAssertEqual(window.title, "Harvis 版本管理")
        XCTAssertEqual(
            window.accessibilityIdentifier(),
            "harvis-version-catalog-window"
        )
        XCTAssertEqual(window.contentMinSize, NSSize(width: 860, height: 560))
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 1_060, height: 700))
        XCTAssertEqual(window.contentLayoutRect.width, 1_060)
        XCTAssertLessThanOrEqual(window.contentLayoutRect.height, 700)
        XCTAssertGreaterThan(window.contentLayoutRect.height, 0)
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    func testShowShowCloseShowRetainsOneWindowAndCallsFactoryOnce() {
        var factoryCount = 0
        let expected = HarvisVersionCatalogWindowConfiguration.make(
            contentViewController: NSHostingController(rootView: Color.clear)
        )
        let controller = HarvisVersionCatalogWindowController(
            windowFactory: { _, _ in
                factoryCount += 1
                return expected
            },
            applicationActivator: {}
        )

        controller.showWindow(apiVersionProvider: { "v-test" })
        let first = controller.window
        controller.showWindow(apiVersionProvider: { "v-test" })
        XCTAssertTrue(first === controller.window)

        controller.window?.close()
        controller.showWindow(apiVersionProvider: { "v-test" })

        XCTAssertTrue(first === controller.window)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(controller.creationCount, 1)
        controller.window?.close()
    }

    func testRetainedCloseReferenceClosesTheAssignedWindow() {
        let reference = HarvisVersionCatalogWindowReference()
        let window = HarvisVersionCatalogWindowConfiguration.make(
            contentViewController: NSHostingController(rootView: Color.clear)
        )
        reference.window = window
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)

        reference.performClose()

        XCTAssertFalse(window.isVisible)
        XCTAssertNotNil(reference.window)
    }

#if HARVIS_VERSION_UI_TESTING
    func testFixtureWindowAndEffectsUseOnlyInjectedProvider() throws {
        let provider = try HarvisVersionFixtureProvider(
            fixtureID: .baselineUnbound,
            defaults: WindowFixtureDefaults()
        )
        let state = HarvisVersionFixtureViewState(provider: provider)

        XCTAssertEqual(
            state.effects.chooseSourceDirectory(),
            "/fixture/harvis/main"
        )
        state.effects.copy("/fixture/harvis/main", .source)
        XCTAssertEqual(
            state.clipboardReceipt,
            "count=1 kind=source valueSha256=2b5c887df036f9e299d2443033483de1a59142f699c34aa3e9763017bf5ccca9"
        )
        state.effects.reveal(URL(fileURLWithPath: "/fixture/harvis/main"))
        XCTAssertTrue(state.finderReceipt?.hasPrefix("count=1 canonicalPathSha256=") == true)
        state.effects.openGitHub(
            try XCTUnwrap(URL(string: "https://github.com/octocat/harvis-fixture"))
        )
        XCTAssertEqual(
            state.openerReceipt,
            "count=1 url=https://github.com/octocat/harvis-fixture"
        )

        let window = HarvisVersionCatalogWindowConfiguration.makeFixtureWindow(
            provider: provider
        )
        defer { window.close() }
        XCTAssertEqual(window.title, "Harvis 版本管理")
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 1_060, height: 700))
        XCTAssertTrue(
            window.contentViewController
                is NSHostingController<HarvisVersionFixtureCatalogRoot>
        )
        XCTAssertEqual(provider.bootPolicy, .isolated)
    }
#endif
}

#if HARVIS_VERSION_UI_TESTING
private final class WindowFixtureDefaults: HarvisVersionFixtureDefaultsWriting {
    private var values: [String: Any] = [:]

    func clearPersistentDomain() {
        values.removeAll()
    }

    func replacePersistentDomain(with values: [String: Any]) {
        self.values = values
    }

    func synchronize() -> Bool { true }

    func readSourceRoot() throws -> String? {
        values[HarvisVersionFixtureProvider.fixtureSourcePreferenceKey] as? String
    }

    func writeSourceRoot(_ canonicalRoot: String?) throws {
        values[HarvisVersionFixtureProvider.fixtureSourcePreferenceKey] = canonicalRoot
    }
}
#endif
