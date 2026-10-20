import SwiftUI

/// The readable text-size choices used by the Codex manager surfaces.
///
/// The environment value is optional on purpose. Views outside a text-size
/// aware manager window keep their existing SwiftUI font when no size has been
/// attached to the environment.
enum HarvisTextSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    static let defaultsKey = "harvis.codex.chatManager.textSize"
    static let defaultValue: Self = .medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    /// A layout hint for fixed-size controls and cards. Font rendering uses
    /// `pointSize(for:)` so controls can opt into a measured size instead of
    /// scaling an entire view tree.
    var layoutScale: CGFloat {
        switch self {
        case .small: return 1
        case .medium: return 1.16
        case .large: return 1.38
        }
    }

    /// Maps a normalised medium-size point value to this preference while
    /// keeping compact secondary text above its readability floor.
    func pointSize(for base: CGFloat) -> CGFloat {
        let scale: CGFloat
        let minimum: CGFloat
        switch self {
        case .small:
            scale = 1
            minimum = 11
        case .medium:
            scale = 15.0 / 13.0
            minimum = 13
        case .large:
            scale = 18.0 / 13.0
            minimum = 15
        }
        return max(base * scale, minimum)
    }
}

/// A semantic font descriptor that mirrors the Font members used by the
/// manager views. It keeps the original SwiftUI font when no text-size
/// preference is installed in the environment.
struct HarvisFontStyle {
    private enum Kind {
        case body
        case caption
        case caption2
        case subheadline
        case headline
        case title
        case title2
        case title3
        case system(CGFloat)
    }

    private let kind: Kind
    private let baseWeight: Font.Weight
    private let baseDesign: Font.Design
    private let weightOverride: Font.Weight?
    private let usesMonospaced: Bool
    private let usesMonospacedDigits: Bool

    private init(
        kind: Kind,
        weight: Font.Weight,
        design: Font.Design,
        weightOverride: Font.Weight? = nil,
        usesMonospaced: Bool = false,
        usesMonospacedDigits: Bool = false
    ) {
        self.kind = kind
        self.baseWeight = weight
        self.baseDesign = design
        self.weightOverride = weightOverride
        self.usesMonospaced = usesMonospaced
        self.usesMonospacedDigits = usesMonospacedDigits
    }

    static let body = Self(kind: .body, weight: .regular, design: .default)
    static let caption = Self(kind: .caption, weight: .regular, design: .default)
    static let caption2 = Self(kind: .caption2, weight: .regular, design: .default)
    static let subheadline = Self(kind: .subheadline, weight: .regular, design: .default)
    static let headline = Self(kind: .headline, weight: .semibold, design: .default)
    static let title = Self(kind: .title, weight: .regular, design: .default)
    static let title2 = Self(kind: .title2, weight: .regular, design: .default)
    static let title3 = Self(kind: .title3, weight: .regular, design: .default)

    static func system(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Self {
        Self(kind: .system(size), weight: weight, design: design)
    }

    func bold() -> Self {
        weight(.bold)
    }

    func weight(_ weight: Font.Weight) -> Self {
        Self(
            kind: kind,
            weight: baseWeight,
            design: baseDesign,
            weightOverride: weight,
            usesMonospaced: usesMonospaced,
            usesMonospacedDigits: usesMonospacedDigits
        )
    }

    func monospaced() -> Self {
        Self(
            kind: kind,
            weight: baseWeight,
            design: baseDesign,
            weightOverride: weightOverride,
            usesMonospaced: true,
            usesMonospacedDigits: usesMonospacedDigits
        )
    }

    func monospacedDigit() -> Self {
        Self(
            kind: kind,
            weight: baseWeight,
            design: baseDesign,
            weightOverride: weightOverride,
            usesMonospaced: usesMonospaced,
            usesMonospacedDigits: true
        )
    }

    fileprivate func font(for textSize: HarvisTextSize?) -> Font {
        guard let textSize else { return originalFont }
        var font = Font.system(
            size: textSize.pointSize(for: basePointSize),
            weight: weightOverride ?? baseWeight,
            design: usesMonospaced ? .monospaced : baseDesign
        )
        if usesMonospacedDigits {
            font = font.monospacedDigit()
        }
        return font
    }

    private var basePointSize: CGFloat {
        switch kind {
        case .body: return 13
        case .caption: return 11
        case .caption2: return 10
        case .subheadline: return 12
        case .headline: return 14
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case let .system(size): return max(size, 1)
        }
    }

    private var originalFont: Font {
        var font: Font
        switch kind {
        case .body: font = .body
        case .caption: font = .caption
        case .caption2: font = .caption2
        case .subheadline: font = .subheadline
        case .headline: font = .headline
        case .title: font = .title
        case .title2: font = .title2
        case .title3: font = .title3
        case let .system(size):
            font = .system(size: size, weight: baseWeight, design: baseDesign)
        }
        if let weightOverride {
            font = font.weight(weightOverride)
        }
        if usesMonospaced {
            font = font.monospaced()
        }
        if usesMonospacedDigits {
            font = font.monospacedDigit()
        }
        return font
    }
}

private struct HarvisTextSizeEnvironmentKey: EnvironmentKey {
    static let defaultValue: HarvisTextSize? = nil
}

extension EnvironmentValues {
    var harvisTextSize: HarvisTextSize? {
        get { self[HarvisTextSizeEnvironmentKey.self] }
        set { self[HarvisTextSizeEnvironmentKey.self] = newValue }
    }
}

private struct HarvisFontModifier: ViewModifier {
    @Environment(\.harvisTextSize) private var textSize

    let style: HarvisFontStyle

    func body(content: Content) -> some View {
        content.font(style.font(for: textSize))
    }
}

extension View {
    /// Applies a manager-aware font while preserving the original font when
    /// the optional `harvisTextSize` environment value is nil.
    func harvisFont(_ style: HarvisFontStyle) -> some View {
        modifier(HarvisFontModifier(style: style))
    }
}
