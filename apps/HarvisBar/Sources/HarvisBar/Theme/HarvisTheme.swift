import Foundation
import SwiftUI

enum HarvisTheme: String, CaseIterable, Identifiable {
    case glass
    case graphite
    case cyberMe
    case aurora
    case nightSignal
    case ember
    case paper
    case ink
    case forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: return "Glass"
        case .graphite: return "Graphite"
        case .cyberMe: return "CyberMe"
        case .aurora: return "Aurora"
        case .nightSignal: return "Night Signal"
        case .ember: return "Ember"
        case .paper: return "Paper · 纸白"
        case .ink: return "Ink · 墨黑"
        case .forest: return "Forest · 松林"
        }
    }

    var subtitle: String {
        switch self {
        case .glass: return "macOS light control deck"
        case .graphite: return "dark runtime cockpit"
        case .cyberMe: return "identity graph signal"
        case .aurora: return "cool companion glow"
        case .nightSignal: return "quiet verified mode"
        case .ember: return "warm review focus"
        case .paper: return "quiet light workspace"
        case .ink: return "neutral dark workspace"
        case .forest: return "muted green workspace"
        }
    }

    /// Whether native controls should use a dark system appearance alongside
    /// this semantic palette. Keeping this on the theme avoids independent
    /// appearance maps drifting as new themes are added.
    var isDark: Bool {
        switch self {
        case .glass, .ember, .paper: return false
        case .graphite, .cyberMe, .aurora, .nightSignal, .ink, .forest: return true
        }
    }

    var preferredColorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    var usesFlatSurfaces: Bool {
        switch self {
        case .paper, .ink, .forest: return true
        default: return false
        }
    }

    var background: Color {
        switch self {
        case .glass: return Color(hex: 0xF0F2F3)
        case .graphite: return Color(hex: 0x10141C)
        case .cyberMe: return Color(hex: 0x081A22)
        case .aurora: return Color(hex: 0x0D1B2A)
        case .nightSignal: return Color(hex: 0x10131A)
        case .ember: return Color(hex: 0xF4F0E7)
        case .paper: return Color(hex: 0xFAFAFA)
        case .ink: return Color(hex: 0x18181B)
        case .forest: return Color(hex: 0x17211E)
        }
    }

    var surface: Color {
        switch self {
        case .glass: return Color.white.opacity(0.88)
        case .graphite: return Color(hex: 0x171D27).opacity(0.96)
        case .cyberMe: return Color(hex: 0x0D2A34).opacity(0.94)
        case .aurora: return Color(hex: 0x102437).opacity(0.94)
        case .nightSignal: return Color(hex: 0x171923).opacity(0.96)
        case .ember: return Color(hex: 0xFFFCF4).opacity(0.93)
        case .paper: return Color(hex: 0xFFFFFF)
        case .ink: return Color(hex: 0x222225)
        case .forest: return Color(hex: 0x22302A)
        }
    }

    var surfaceAlt: Color {
        switch self {
        case .glass: return Color(hex: 0xE4E8E9)
        case .graphite: return Color(hex: 0x202835)
        case .cyberMe: return Color(hex: 0x123A42)
        case .aurora: return Color(hex: 0x16344A)
        case .nightSignal: return Color(hex: 0x222637)
        case .ember: return Color(hex: 0xF1E6D4)
        case .paper: return Color(hex: 0xF1F4F3)
        case .ink: return Color(hex: 0x2B2B30)
        case .forest: return Color(hex: 0x2B3A33)
        }
    }

    var text: Color {
        switch self {
        case .glass, .ember: return Color(hex: 0x111827)
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color(hex: 0xEEF4FF)
        case .paper: return Color(hex: 0x1F2933)
        case .ink: return Color(hex: 0xF4F4F5)
        case .forest: return Color(hex: 0xEFF4F0)
        }
    }

    var muted: Color {
        switch self {
        case .glass: return Color(hex: 0x4B5563)
        case .graphite: return Color(hex: 0x9CA8B8)
        case .cyberMe: return Color(hex: 0x8FD5D0)
        case .aurora: return Color(hex: 0x9CC7D6)
        case .nightSignal: return Color(hex: 0xAEB7C7)
        case .ember: return Color(hex: 0x7B6D5C)
        case .paper: return Color(hex: 0x52615F)
        case .ink: return Color(hex: 0xB7B7BE)
        case .forest: return Color(hex: 0xB6C5BD)
        }
    }

    var line: Color {
        switch self {
        case .glass: return Color(hex: 0xBFC7CA)
        case .graphite: return Color(hex: 0x344054)
        case .cyberMe: return Color(hex: 0x2A6670)
        case .aurora: return Color(hex: 0x28556B)
        case .nightSignal: return Color(hex: 0x343A4C)
        case .ember: return Color(hex: 0xDACBB4)
        case .paper: return Color(hex: 0xCBD5D2)
        case .ink: return Color(hex: 0x44444B)
        case .forest: return Color(hex: 0x41564A)
        }
    }

    var accent: Color {
        switch self {
        case .glass: return Color(hex: 0x145A4A)
        case .graphite: return Color(hex: 0x77A7FF)
        case .cyberMe: return Color(hex: 0x63E6D1)
        case .aurora: return Color(hex: 0x62D4C8)
        case .nightSignal: return Color(hex: 0x8FB4FF)
        case .ember: return Color(hex: 0xB76E24)
        case .paper: return Color(hex: 0x0F766E)
        case .ink: return Color(hex: 0x5FA89D)
        case .forest: return Color(hex: 0x9DBA9F)
        }
    }

    var accent2: Color {
        switch self {
        case .glass: return Color(hex: 0xA3472A)
        case .graphite: return Color(hex: 0x9AE66E)
        case .cyberMe: return Color(hex: 0xE8D06B)
        case .aurora: return Color(hex: 0xF0C35A)
        case .nightSignal: return Color(hex: 0x6EE7A8)
        case .ember: return Color(hex: 0x2F6F6B)
        case .paper: return Color(hex: 0x8B5E34)
        case .ink: return Color(hex: 0xC6A86D)
        case .forest: return Color(hex: 0xD7B77A)
        }
    }

    var positive: Color {
        switch self {
        case .glass, .ember: return Color(hex: 0x166534)
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color(hex: 0x86EFAC)
        case .paper: return Color(hex: 0x166534)
        case .ink: return Color(hex: 0x8FD3A3)
        case .forest: return Color(hex: 0xA7D7A8)
        }
    }

    var positiveText: Color {
        switch self {
        case .glass, .ember: return .white
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color(hex: 0x111827)
        case .paper: return .white
        case .ink: return Color(hex: 0x18211D)
        case .forest: return Color(hex: 0x18241D)
        }
    }

    var recentStatus: Color {
        switch self {
        case .glass, .ember: return Color(hex: 0x4B5563)
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color(hex: 0xCBD5E1)
        case .paper: return Color(hex: 0x52615F)
        case .ink: return Color(hex: 0xD0D0D6)
        case .forest: return Color(hex: 0xD0DED5)
        }
    }

    var selectionFill: Color {
        switch self {
        case .glass, .ember: return Color(hex: 0x111827)
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color(hex: 0xF8FAFC)
        case .paper: return Color(hex: 0x0F766E)
        case .ink: return Color(hex: 0xF4F4F5)
        case .forest: return Color(hex: 0xEFF4F0)
        }
    }

    var selectionText: Color {
        switch self {
        case .glass, .ember: return .white
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color(hex: 0x111827)
        case .paper: return .white
        case .ink: return Color(hex: 0x18181B)
        case .forest: return Color(hex: 0x1A2721)
        }
    }

    var remoteSurface: Color {
        switch self {
        case .glass, .ember: return Color(hex: 0xDCEEFF)
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color(hex: 0x163A5C)
        case .paper: return Color(hex: 0xE3F2F0)
        case .ink: return Color(hex: 0x1E3B3A)
        case .forest: return Color(hex: 0x24443B)
        }
    }

    var remoteLine: Color {
        switch self {
        case .glass, .ember: return Color(hex: 0x5B9BD5)
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color(hex: 0x70B7FF)
        case .paper: return Color(hex: 0x2D8A82)
        case .ink: return Color(hex: 0x75C4B8)
        case .forest: return Color(hex: 0xA0C7B5)
        }
    }

    var shadow: Color {
        switch self {
        case .glass: return Color.black.opacity(0.12)
        case .graphite, .cyberMe, .aurora, .nightSignal: return Color.black.opacity(0.34)
        case .ember: return Color.black.opacity(0.10)
        case .paper: return Color.black.opacity(0.10)
        case .ink: return Color.black.opacity(0.40)
        case .forest: return Color.black.opacity(0.38)
        }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct PulsingStatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let wave = reduceMotion
                ? 0.0
                : (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1.0) / 2.0
            ZStack {
                Circle()
                    .stroke(color, lineWidth: 1.4)
                    .frame(width: 10, height: 10)
                    .scaleEffect(1.0 + wave * 0.38)
                    .opacity(reduceMotion ? 0.45 : 0.72 - wave * 0.48)
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 14, height: 14)
        }
        .accessibilityLabel("Running")
    }
}

struct HarvisControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let theme: HarvisTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .harvisFont(.caption)
            .foregroundColor(theme.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? theme.accent.opacity(0.20) : theme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(configuration.isPressed ? theme.accent : theme.line, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.48)
    }
}
