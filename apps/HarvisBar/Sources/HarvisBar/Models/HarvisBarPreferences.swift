import Combine
import Foundation

/// Personal presentation only. This never changes the app's bundle or runtime identity.
@MainActor
final class HarvisBarPreferences: ObservableObject {
    static let shared = HarvisBarPreferences()
    static let defaultDisplayName = "HarvisBar"
    private static let displayNameKey = "harvisBar.displayName"

    enum ValidationError: LocalizedError, Equatable {
        case empty
        case tooLong
        case invalidCharacters

        var errorDescription: String? {
            switch self {
            case .empty: return "名称不能为空。"
            case .tooLong: return "名称最多 40 个字符。"
            case .invalidCharacters: return "名称不能包含换行或控制字符。"
            }
        }
    }

    @Published private(set) var displayName: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.displayNameKey) as? String,
           let validated = try? Self.validate(stored) {
            displayName = validated
        } else {
            displayName = Self.defaultDisplayName
        }
    }

    func setDisplayName(_ value: String) throws {
        let validated = try Self.validate(value)
        defaults.set(validated, forKey: Self.displayNameKey)
        if displayName != validated { displayName = validated }
    }

    func resetDisplayName() {
        defaults.removeObject(forKey: Self.displayNameKey)
        if displayName != Self.defaultDisplayName { displayName = Self.defaultDisplayName }
    }

    private static func validate(_ value: String) throws -> String {
        // Check before trimming so a pasted newline/tab is rejected rather than silently removed.
        // Foundation includes the emoji zero-width joiner in controlCharacters; retain it so
        // names such as 👩🏽‍💻 remain valid single grapheme clusters.
        if value.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0)
                || (CharacterSet.controlCharacters.contains($0) && $0.value != 0x200D)
        }) {
            throw ValidationError.invalidCharacters
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard trimmed.count <= 40 else { throw ValidationError.tooLong }
        return trimmed
    }
}
