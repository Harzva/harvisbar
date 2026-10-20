import Foundation

struct DshPresetPreview: Decodable, Identifiable {
    let id: String
    let name: String
    let source: String
    let plugins: [String]
    let conditionalPlugins: [String]
    let warnings: [String]
}

/// Comparisons describe package declarations in the selected profiles, never
/// physical installation sharing or the effective live Loader graph.
struct DshPluginComparisonRow: Identifiable {
    let name: String
    let profiles: [DshProfileCatalogItem]
    var id: String { name }
    func plugin(in profile: DshProfileCatalogItem) -> DshPluginCatalogItem? {
        profile.pluginPackages.first { $0.name == name }
    }
    var presentCount: Int { profiles.filter { plugin(in: $0) != nil }.count }
    var common: Bool { profiles.count > 1 && presentCount == profiles.count }
    var unique: Bool { profiles.count > 1 && presentCount == 1 }
    var versionsDiffer: Bool {
        let versions = profiles.compactMap { plugin(in: $0)?.installedVersion }
        return Set(versions).count > 1
    }
    var summary: String {
        if profiles.count < 2 { return "单列预览" }
        if common { return versionsDiffer ? "共同引用 · 版本不同" : "共同引用" }
        if unique { return "仅一个 Profile" }
        return "部分共用"
    }
    static func make(profiles: [DshProfileCatalogItem]) -> [Self] {
        Set(profiles.flatMap { $0.pluginPackages.map(\.name) }).sorted()
            .map { Self(name: $0, profiles: profiles) }
    }
}

enum DshPreviewScope: String, CaseIterable, Identifiable {
    case all = "全部组成"
    case home = "HOME 统一加入"
    case shared = "与其他 Profile 共用"
    case unique = "此 Profile 独有"
    case client = "UI 扩展声明"
    var id: String { rawValue }
}

extension DshHomeCatalogItem {
    func profilesReferencing(_ name: String) -> [DshProfileCatalogItem] {
        profiles.filter { $0.pluginPackages.contains { $0.name == name } }
    }
    func previewPlugins(for profile: DshProfileCatalogItem, scope: DshPreviewScope) -> [DshPluginCatalogItem] {
        profile.pluginPackages.filter { plugin in
            switch scope {
            case .all: return true
            case .home: return (plugin.declaredIn ?? []).contains("HOME 共享补丁")
            case .shared: return profilesReferencing(plugin.name).count > 1
            case .unique: return profiles.count > 1 && profilesReferencing(plugin.name).count == 1
            case .client: return plugin.clientContribution == true
            }
        }
    }
    var previewSelectionID: String { "home:\(id)" }
    func previewSelectionID(for profile: DshProfileCatalogItem) -> String {
        "profile:\(profile.id)"
    }
}
