#if DEBUG
import Foundation

/// Opens the real group window against explicitly supplied acceptance data.
/// The production runtime, discovery and service timers never start in this mode.
@MainActor
enum HarvisGroupUIFixture {
    nonisolated static let argument = "--harvis-group-ui-fixture-root"

    nonisolated static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(argument)
            || Bundle.main.object(forInfoDictionaryKey: "HarvisGroupFixtureRoot") != nil
    }

    private struct Configuration: Decodable {
        struct Home: Decodable {
            let label: String
            let path: String
        }
        let homes: [Home]
    }

    static func makeRuntime(arguments: [String]) throws -> HarvisRuntimeModel {
        let path: String
        if let index = arguments.firstIndex(of: argument) {
            guard arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            path = arguments[index + 1]
        } else if let configured = Bundle.main.object(forInfoDictionaryKey: "HarvisGroupFixtureRoot") as? String {
            path = configured
        } else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let configuration = try JSONDecoder().decode(Configuration.self,
            from: Data(contentsOf: root.appendingPathComponent("fixture-config.json")))
        let suite = "local.harzva.harvisbar.group-ui-fixture"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CocoaError(.fileReadUnknown)
        }
        let runtime = HarvisRuntimeModel(defaults: defaults,
            groupDataDirectory: root.appendingPathComponent("data", isDirectory: true))
        runtime.codexHomes = configuration.homes.enumerated().map { index, home in
            CodexHome(id: "group-fixture-\(index)", label: home.label, accountNote: home.label,
                path: home.path, source: "managed-agent", model: nil, provider: "openai",
                endpointHost: nil, hasAuth: true, accountEmail: nil, authStatus: "ready",
                authExpiresAt: nil, authNote: nil, hasConfig: true, skillCount: 0,
                quotaMode: nil, quotaNote: nil)
        }
        return runtime
    }
}
#endif
