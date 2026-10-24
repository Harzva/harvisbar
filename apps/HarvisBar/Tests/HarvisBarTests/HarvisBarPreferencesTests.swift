import Combine
import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisBarPreferencesTests: XCTestCase {
    private let key = "harvisBar.displayName"

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "HarvisBarPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testMissingPreferenceUsesDefaultWithoutWritingDefaults() throws {
        try withDefaults { defaults in
            let preferences = HarvisBarPreferences(defaults: defaults)
            XCTAssertEqual(preferences.displayName, "HarvisBar")
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testTrimmedChineseAndEmojiNamePersistsAcrossInstances() throws {
        try withDefaults { defaults in
            let preferences = HarvisBarPreferences(defaults: defaults)
            try preferences.setDisplayName("  小舟 👩🏽‍💻  ")
            XCTAssertEqual(preferences.displayName, "小舟 👩🏽‍💻")
            XCTAssertEqual(defaults.string(forKey: key), "小舟 👩🏽‍💻")
            XCTAssertEqual(HarvisBarPreferences(defaults: defaults).displayName, "小舟 👩🏽‍💻")
        }
    }

    func testLengthCountsCharactersAndRejectsOverflowWithoutTruncating() throws {
        try withDefaults { defaults in
            let preferences = HarvisBarPreferences(defaults: defaults)
            let fortyCharacters = String(repeating: "👩🏽‍💻", count: 40)
            XCTAssertEqual(fortyCharacters.count, 40)
            try preferences.setDisplayName(fortyCharacters)
            XCTAssertEqual(preferences.displayName, fortyCharacters)
            XCTAssertThrowsError(try preferences.setDisplayName(fortyCharacters + "舟")) { error in
                XCTAssertEqual(error as? HarvisBarPreferences.ValidationError, .tooLong)
                XCTAssertEqual(error.localizedDescription, "名称最多 40 个字符。")
            }
            XCTAssertEqual(preferences.displayName, fortyCharacters)
            XCTAssertEqual(defaults.string(forKey: key), fortyCharacters)
        }
    }

    func testInvalidInputsPreserveStoredNameAndUnrelatedPreferences() throws {
        try withDefaults { defaults in
            defaults.set("existing-workspace", forKey: "harvisBar.workspaceRoot")
            defaults.set(["one", "two"], forKey: "unrelated-array")
            let preferences = HarvisBarPreferences(defaults: defaults)
            try preferences.setDisplayName("小舟")
            let before = defaults.dictionaryRepresentation() as NSDictionary
            for value in ["", "   ", "\n小舟", "小舟\n", "小\r舟", "小\t舟", "小\0舟", "小\u{2028}舟", "小\u{202E}舟"] {
                XCTAssertThrowsError(try preferences.setDisplayName(value), value)
                XCTAssertEqual(preferences.displayName, "小舟")
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            }
        }
    }

    func testInvalidStoredValuesFallBackWithoutRewritingOrTruncating() throws {
        try withDefaults { defaults in
            let invalidValues: [Any] = ["", "   ", "bad\nname", String(repeating: "名", count: 41), 42, true, ["unexpected": "object"]]
            for stored in invalidValues {
                defaults.set(stored, forKey: key)
                let before = defaults.dictionaryRepresentation() as NSDictionary
                XCTAssertEqual(HarvisBarPreferences(defaults: defaults).displayName, "HarvisBar")
                XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
            }
        }
    }

    func testResetRemovesOnlyNameAndRestoresDefaultForNextInstance() throws {
        try withDefaults { defaults in
            defaults.set("stable-theme", forKey: "harvisBar.themeID")
            let preferences = HarvisBarPreferences(defaults: defaults)
            try preferences.setDisplayName("个人 Bar")
            preferences.resetDisplayName()
            XCTAssertEqual(preferences.displayName, "HarvisBar")
            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertEqual(defaults.string(forKey: "harvisBar.themeID"), "stable-theme")
            XCTAssertEqual(HarvisBarPreferences(defaults: defaults).displayName, "HarvisBar")
        }
    }

    func testPublishesAcceptedChangesAndResetButNeverRejectedInput() throws {
        try withDefaults { defaults in
            let preferences = HarvisBarPreferences(defaults: defaults)
            var published: [String] = []
            let subscription = preferences.$displayName.sink { published.append($0) }
            defer { subscription.cancel() }
            try preferences.setDisplayName("小舟")
            XCTAssertThrowsError(try preferences.setDisplayName("invalid\nname"))
            try preferences.setDisplayName(" 小舟 ")
            preferences.resetDisplayName()
            XCTAssertEqual(published, ["HarvisBar", "小舟", "HarvisBar"])
        }
    }

    func testSeparateSuitesKeepPersonalNamesIsolated() throws {
        try withDefaults { first in
            try withDefaults { second in
                let one = HarvisBarPreferences(defaults: first)
                let two = HarvisBarPreferences(defaults: second)
                try one.setDisplayName("一个人")
                XCTAssertEqual(two.displayName, "HarvisBar")
                XCTAssertNil(second.object(forKey: key))
            }
        }
    }
}
