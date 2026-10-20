import SwiftUI

/// Object colors for the project structure surface. The palette remains
/// stable across Harvis themes so a project, folder, or session keeps the
/// same visual meaning when the user changes chrome themes.
enum ManagedProjectPathMatrixPalette {
    static func project(for theme: HarvisTheme) -> Color {
        switch theme {
        case .glass: return Color(hex: 0x315CAA)
        case .ember: return Color(hex: 0x4E78C5)
        case .paper: return Color(hex: 0x315CAA)
        case .ink: return Color(hex: 0x8BADEB)
        case .forest: return Color(hex: 0x86A8DE)
        default: return Color(hex: 0x9ABBFF)
        }
    }

    static func folder(for theme: HarvisTheme) -> Color {
        switch theme {
        case .glass: return Color(hex: 0x586575)
        case .ember: return Color(hex: 0x7B6D5C)
        case .paper: return Color(hex: 0x586575)
        case .ink: return Color(hex: 0xB9BDC5)
        case .forest: return Color(hex: 0xB7C6BB)
        default: return Color(hex: 0xAAB5C4)
        }
    }

    static func session(for theme: HarvisTheme) -> Color {
        switch theme {
        case .glass: return Color(hex: 0x7958A4)
        case .ember: return Color(hex: 0x8D5E95)
        case .paper: return Color(hex: 0x7958A4)
        case .ink: return Color(hex: 0xC6A9E6)
        case .forest: return Color(hex: 0xBFA5DF)
        default: return Color(hex: 0xD1B4F4)
        }
    }

    static func activeSurface(for theme: HarvisTheme) -> Color {
        switch theme {
        case .glass: return Color(hex: 0xE2EAF8)
        case .paper: return Color(hex: 0xE2EAF8)
        case .ink: return Color(hex: 0x35445F)
        case .forest: return Color(hex: 0x364A43)
        default: return Color(hex: 0x34445F)
        }
    }

    static func projectSurface(for theme: HarvisTheme) -> Color {
        project(for: theme).opacity(theme == .glass || theme == .paper ? 0.10 : 0.18)
    }

    static func sessionSurface(for theme: HarvisTheme) -> Color {
        session(for: theme).opacity(theme == .glass || theme == .paper ? 0.10 : 0.15)
    }

    static func color(
        for kind: ManagedProjectPathMatrixNode.Kind?,
        theme: HarvisTheme
    ) -> Color {
        switch kind {
        case .folder, nil: return folder(for: theme)
        case .project, .leaf: return project(for: theme)
        case .unclassified: return theme.accent2
        }
    }
}
