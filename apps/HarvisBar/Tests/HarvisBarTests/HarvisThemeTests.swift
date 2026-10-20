import AppKit
import SwiftUI
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisThemeTests: XCTestCase {
    private let newThemes: [HarvisTheme] = [.paper, .ink, .forest]

    func testNewThemeIDsRoundTripAndUseCentralizedAppearance() {
        XCTAssertEqual(
            newThemes.map(\.rawValue),
            ["paper", "ink", "forest"]
        )
        XCTAssertTrue(HarvisTheme.paper.preferredColorScheme == .light)
        XCTAssertTrue(HarvisTheme.ink.preferredColorScheme == .dark)
        XCTAssertTrue(HarvisTheme.forest.preferredColorScheme == .dark)

        for theme in HarvisTheme.allCases {
            XCTAssertEqual(HarvisTheme(rawValue: theme.rawValue), theme)
        }
        XCTAssertEqual(HarvisTheme(rawValue: "removed-theme") ?? .glass, .glass)
    }

    func testNewThemeSemanticColorsMeetContrastAgainstTheirActualSurfaces() throws {
        for theme in newThemes {
            let backgrounds = [
                ("background", try rgb(theme.background)),
                ("surface", try rgb(theme.surface)),
                ("surfaceAlt", try rgb(theme.surfaceAlt))
            ]

            for (surfaceName, surface) in backgrounds {
                XCTAssertGreaterThanOrEqual(
                    contrast(try rgb(theme.text), surface),
                    4.5,
                    "\(theme.rawValue) normal text on \(surfaceName)"
                )
                XCTAssertGreaterThanOrEqual(
                    contrast(try rgb(theme.muted), surface),
                    4.5,
                    "\(theme.rawValue) muted text on \(surfaceName)"
                )
                XCTAssertGreaterThanOrEqual(
                    contrast(try rgb(theme.accent), surface),
                    4.5,
                    "\(theme.rawValue) accent on \(surfaceName)"
                )
            }
            XCTAssertGreaterThanOrEqual(contrast(try rgb(theme.positiveText), try rgb(theme.positive)), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(try rgb(theme.selectionText), try rgb(theme.selectionFill)), 4.5)
        }
    }

    func testThemeSelectionPersistsAndUnknownSavedIDsFallBackToGlass() throws {
        let suiteName = "HarvisThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(HarvisTheme.paper.rawValue, forKey: HarvisRuntimeModel.Keys.themeID)
        let model = HarvisRuntimeModel(defaults: defaults)
        XCTAssertEqual(model.themeID, HarvisTheme.paper.rawValue)
        XCTAssertEqual(model.theme, .paper)

        model.themeID = HarvisTheme.forest.rawValue
        XCTAssertEqual(defaults.string(forKey: HarvisRuntimeModel.Keys.themeID), "forest")
        XCTAssertEqual(model.theme, .forest)

        defaults.set("removed-theme", forKey: HarvisRuntimeModel.Keys.themeID)
        let fallbackModel = HarvisRuntimeModel(defaults: defaults)
        XCTAssertEqual(fallbackModel.theme, .glass)
    }

    private func rgb(_ color: Color) throws -> (Double, Double, Double) {
        let color = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return (
            Double(color.redComponent),
            Double(color.greenComponent),
            Double(color.blueComponent)
        )
    }

    private func contrast(
        _ lhs: (Double, Double, Double),
        _ rhs: (Double, Double, Double)
    ) -> Double {
        let first = relativeLuminance(lhs)
        let second = relativeLuminance(rhs)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(
        _ rgb: (Double, Double, Double)
    ) -> Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(rgb.0)
            + 0.7152 * linearize(rgb.1)
            + 0.0722 * linearize(rgb.2)
    }
}
