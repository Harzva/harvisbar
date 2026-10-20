import Foundation

enum HarvisBuildInfo {
    nonisolated static func bundleVersion(bundle: Bundle = .main) -> String {
        let value = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "development" : normalized
    }

    nonisolated static func footerLabel(
        appVersion: String,
        apiVersion: String?
    ) -> String {
        let normalizedAPI = apiVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let api = normalizedAPI.flatMap { $0.isEmpty ? nil : $0 } ?? "offline"
        return "App \(appVersion) · API \(api)"
    }
}
