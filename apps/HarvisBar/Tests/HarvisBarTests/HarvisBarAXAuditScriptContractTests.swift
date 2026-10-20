import Foundation
import XCTest

final class HarvisBarAXAuditScriptContractTests: XCTestCase {
    func testDefaultModeIsReadOnlyAndDoesNotScrollOrPress() throws {
        let source = try scriptSource()

        XCTAssertTrue(source.contains("var allSections = false"))
        XCTAssertTrue(source.contains("if !options.allSections"))
        XCTAssertTrue(source.contains("scrollAll: false"))
        XCTAssertTrue(source.contains("mode: \"read-only-current-page\""))
        XCTAssertEqual(source.occurrenceCount(of: "case \"--all-sections\":"), 1)
    }

    func testAllSectionsAllowlistIsExactlyTheTwelveNavigationIdentifiers() throws {
        let source = try scriptSource()
        let names = try sectionNames(from: source)
        let expected = [
            "overview", "codex", "agents", "system",
            "network", "dsh", "ports", "tools",
            "work", "review", "memory", "persona",
        ]

        XCTAssertEqual(names, expected)
        XCTAssertEqual(Set(names).count, 12)
        XCTAssertTrue(source.contains("sectionNames.map { \"harvis.section.\\($0)\" }"))
        XCTAssertTrue(source.contains("guard allowedSectionIdentifiers.contains(identifier)"))
    }

    func testAXPressHasNoPageOrGlobalActionPath() throws {
        let source = try scriptSource()

        XCTAssertEqual(source.occurrenceCount(of: "kAXPressAction as CFString"), 1)
        XCTAssertEqual(source.occurrenceCount(of: "driver.pressSection("), 2)
        XCTAssertTrue(source.contains("func pressSection("))
        XCTAssertTrue(source.contains("throw DriverError.unsafeIdentifier(identifier)"))
        XCTAssertFalse(source.contains("func pressGlobal"))
        XCTAssertFalse(source.contains("func pressPage"))
        XCTAssertFalse(source.contains("case \"--press\""))
        XCTAssertFalse(source.contains("harvis.global."))
    }

    func testAllSectionsModeRestoresOriginalSectionAndScroll() throws {
        let source = try scriptSource()

        XCTAssertTrue(source.contains("let originalSection = driver.selectedSection"))
        XCTAssertTrue(source.contains("let initialScroll = driver.mainScrollArea"))
        XCTAssertTrue(source.contains("restoredSection: restoredSection"))
        XCTAssertTrue(source.contains("restoredScroll: allScrollRestored"))
        XCTAssertTrue(source.contains("func restoreScrollValue("))
        XCTAssertTrue(source.contains("driver.restoreScrollValue("))
        XCTAssertTrue(source.contains("abs(observed - target) <= epsilon"))
    }

    private func scriptSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("harvis_bar_ax_audit.swift")
        return try String(contentsOf: scriptURL, encoding: .utf8)
    }

    private func sectionNames(from source: String) throws -> [String] {
        let marker = "private let sectionNames = ["
        let start = try XCTUnwrap(source.range(of: marker))
        let suffix = source[start.upperBound...]
        let end = try XCTUnwrap(suffix.range(of: "]"))
        let block = suffix[..<end.lowerBound]
        let components = block.components(separatedBy: "\"")
        return components.enumerated().compactMap { index, component in
            index.isMultiple(of: 2) ? nil : component
        }
    }
}

private extension String {
    func occurrenceCount(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return components(separatedBy: needle).count - 1
    }
}
