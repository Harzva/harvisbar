import Combine
import Foundation

/// App-level choices are separate from macOS permissions. Acknowledging the
/// guide never implies that the operating system has granted access.
@MainActor
final class HarvisAccessPreferences: ObservableObject {
    static let guideVersion = 1
    private enum Keys {
        static let guide = "harvisBar.permissionGuideVersion"
        static let externalHomes = "harvisBar.externalHomeDiscoveryEnabled"
        static let historicalProjects = "harvisBar.historicalProjectAccessEnabled"
        static let workspaceScope = "harvisBar.workspaceAccessScope"
    }

    private let defaults: UserDefaults
    @Published private(set) var hasSeenPermissionGuide: Bool
    @Published private(set) var workspaceAccessScope: [String]?
    @Published var externalHomeDiscoveryEnabled: Bool {
        didSet { defaults.set(externalHomeDiscoveryEnabled, forKey: Keys.externalHomes) }
    }
    @Published var historicalProjectAccessEnabled: Bool {
        didSet { defaults.set(historicalProjectAccessEnabled, forKey: Keys.historicalProjects) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasSeenPermissionGuide = defaults.integer(forKey: Keys.guide) >= Self.guideVersion
        let scope = defaults.stringArray(forKey: Keys.workspaceScope)
        workspaceAccessScope = scope?.count == 2 ? scope : nil
        externalHomeDiscoveryEnabled = defaults.bool(forKey: Keys.externalHomes)
        historicalProjectAccessEnabled = defaults.bool(forKey: Keys.historicalProjects)
    }

    func markPermissionGuideSeen() {
        defaults.set(Self.guideVersion, forKey: Keys.guide)
        hasSeenPermissionGuide = true
    }

    func allowsWorkspaceAccess(workspaceRoot: String, profileRoot: String) -> Bool {
        workspaceAccessScope == Self.scope(workspaceRoot: workspaceRoot, profileRoot: profileRoot)
    }

    func allowWorkspaceAccess(workspaceRoot: String, profileRoot: String) {
        let scope = Self.scope(workspaceRoot: workspaceRoot, profileRoot: profileRoot)
        defaults.set(scope, forKey: Keys.workspaceScope)
        workspaceAccessScope = scope
    }

    func revokeWorkspaceAccess() {
        defaults.removeObject(forKey: Keys.workspaceScope)
        workspaceAccessScope = nil
    }

    private static func scope(workspaceRoot: String, profileRoot: String) -> [String] {
        [workspaceRoot, profileRoot].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
        }
    }
}
