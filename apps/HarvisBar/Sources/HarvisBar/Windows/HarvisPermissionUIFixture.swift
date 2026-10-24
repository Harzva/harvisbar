#if DEBUG
import CryptoKit
import Foundation

/// The acceptance app uses a private defaults suite and inert OS actions.
/// No real access requests, runtime services or discovery are started here.
@MainActor
enum HarvisPermissionUIFixture {
    nonisolated static let argument = "--harvis-permission-ui-fixture-root"

    struct Context {
        let runtime: HarvisRuntimeModel
        let preferences: HarvisBarPreferences
        let permissionCenter: HarvisPermissionCenter
    }

    nonisolated static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(argument)
            || Bundle.main.object(forInfoDictionaryKey: "HarvisPermissionFixtureRoot") != nil
    }

    static func makeContext(arguments: [String]) throws -> Context {
        let path: String
        if let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) {
            path = arguments[index + 1]
        } else if let configured = Bundle.main.object(
            forInfoDictionaryKey: "HarvisPermissionFixtureRoot"
        ) as? String {
            path = configured
        } else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let suite = "local.harzva.harvisbar.permission-fixture.\(digest)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        defaults.set(root.path, forKey: HarvisRuntimeModel.Keys.workspaceRoot)
        defaults.set(root.appendingPathComponent("profile").path, forKey: HarvisRuntimeModel.Keys.profileRoot)
        let runtime = HarvisRuntimeModel(
            defaults: defaults,
            groupDataDirectory: root.appendingPathComponent("groups"),
            codexThreadSnapshotStore: CodexThreadSnapshotStore(snapshotURL: root.appendingPathComponent("snapshots.json")),
            permissionProbeLoader: { _ in throw URLError(.notConnectedToInternet) }
        )
        let permissions = HarvisPermissionCenter(environment: .fixture)
        return Context(runtime: runtime, preferences: HarvisBarPreferences(defaults: defaults), permissionCenter: permissions)
    }
}
#endif
