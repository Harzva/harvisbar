import XCTest
@testable import HarvisBar

@MainActor
final class SectionNavigationTests: XCTestCase {
    func testEveryDigitalMeButtonBuildsTheExactTypedStudioURL() throws {
        let suite = "SectionNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/tmp/harvis-workspace", forKey: HarvisRuntimeModel.Keys.workspaceRoot)
        defaults.set("/tmp/harvis-profile", forKey: HarvisRuntimeModel.Keys.profileRoot)
        defaults.set("43210", forKey: HarvisRuntimeModel.Keys.portText)
        let model = HarvisRuntimeModel(defaults: defaults)

        for destination in DigitalMeStudioDestination.allCases {
            let url = try XCTUnwrap(model.digitalMeStudioURL(destination))
            let components = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.scheme, "http")
            XCTAssertEqual(components.host, "127.0.0.1")
            XCTAssertEqual(components.port, 43210)
            XCTAssertEqual(components.path, "/studio/")
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                    item in item.value.map { (item.name, $0) }
                }
            )
            XCTAssertEqual(query["root"], "/tmp/harvis-workspace")
            XCTAssertEqual(query["profile_root"], "/tmp/harvis-profile")
            XCTAssertEqual(query["view"], destination.rawValue)
        }
    }

    func testNavigationUsesThreeOrderedRowsOfFourSections() {
        XCTAssertEqual(HarvisBarSection.primarySections, [.overview, .codex, .agents, .system])
        XCTAssertEqual(HarvisBarSection.utilitySections, [.network, .dsh, .ports, .tools])
        XCTAssertEqual(HarvisBarSection.digitalMeSections, [.work, .review, .memory, .persona])
        XCTAssertEqual(
            HarvisBarSection.navigationRows,
            [
                [.overview, .codex, .agents, .system],
                [.network, .dsh, .ports, .tools],
                [.work, .review, .memory, .persona],
            ]
        )
        XCTAssertEqual(HarvisBarSection.navigationRows.map(\.count), [4, 4, 4])
    }

    func testNavigationRowsCoverEverySectionExactlyOnce() {
        let flattenedSections = HarvisBarSection.navigationRows.flatMap { $0 }

        XCTAssertEqual(flattenedSections, HarvisBarSection.allCases)
        XCTAssertEqual(flattenedSections.count, 12)
        XCTAssertEqual(Set(flattenedSections).count, 12)
    }

    func testSectionLabelsAreNonemptyAndUnique() {
        let labels = HarvisBarSection.allCases.map { section in
            XCTAssertFalse(section.shortTitle.isEmpty)
            XCTAssertFalse(section.title.isEmpty)
            return "\(section.shortTitle)\u{00b7}\(section.title)"
        }

        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testOriginalSectionOrderAndLabelsRemainStable() {
        let originalSections = Array(HarvisBarSection.allCases.prefix(8))

        XCTAssertEqual(
            originalSections,
            [.overview, .codex, .agents, .system, .network, .dsh, .ports, .tools]
        )
        XCTAssertEqual(
            originalSections.map { "\($0.shortTitle)\u{00b7}\($0.title)" },
            [
                "\u{7532}\u{00b7}\u{603b}\u{89c8}",
                "\u{4e59}\u{00b7}Codex",
                "\u{4e19}\u{00b7}Agent",
                "\u{4e01}\u{00b7}Harvis",
                "A\u{00b7}Network",
                "B\u{00b7}DSH",
                "C\u{00b7}Ports",
                "D\u{00b7}Tools",
            ]
        )
    }

    func testDigitalMeSectionLabelsAreExact() {
        XCTAssertEqual(
            HarvisBarSection.digitalMeSections.map { "\($0.shortTitle)\u{00b7}\($0.title)" },
            ["1\u{00b7}Work", "2\u{00b7}Review", "3\u{00b7}Memory", "4\u{00b7}Persona"]
        )
    }

    func testPopoverDefaultsToOverview() {
        XCTAssertEqual(HarvisPopoverView().selectedSection, .overview)
    }

    func testDigitalMeStudioDestinationsAreTypedAndUnique() {
        let rawValues = DigitalMeStudioDestination.allCases.map(\.rawValue)

        XCTAssertEqual(rawValues, ["work", "review", "memory", "studio", "copy"])
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }
}
