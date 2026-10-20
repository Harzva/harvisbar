import Foundation

struct DshRuntimeCatalog: Decodable {
    let ok: Bool
    let schemaVersion: String
    let homeCount: Int
    let runtimeCount: Int
    let homes: [DshHomeCatalogItem]
    let runtimes: [DshRuntimeCatalogItem]
    let warnings: [String]
    let includesSecrets: Bool

    var isSafeForLocalDisplay: Bool {
        ok
            && schemaVersion == "harvis.dsh-catalog.v1"
            && !includesSecrets
    }
}

struct DshHomeCatalogItem: Decodable, Identifiable {
    let id: String
    let label: String
    let path: String
    let version: String?
    let runtimePath: String?
    let executable: String?
    let status: String
    let defaultProfile: String?
    let profileCount: Int
    let pluginCount: Int
    let customPluginCount: Int
    let profiles: [DshProfileCatalogItem]
    let runningProfiles: [DshRunningProfileCatalogItem]
    var presetPreviews: [DshPresetPreview]? = nil

    var selectionID: String { "home:\(id)" }

    var runningPortCount: Int {
        runningProfiles.reduce(0) { $0 + $1.ports.count }
    }

    var defaultLaunchProfile: DshProfileCatalogItem? {
        if let defaultProfile,
           let profile = profiles.first(where: { $0.name == defaultProfile && $0.launchable }) {
            return profile
        }
        return profiles.first(where: \.launchable)
    }

    var shortcutLabel: String {
        switch id {
        case "dsh": return "默认"
        case "dsh-rc8-home": return "RC8"
        case "dsh-next": return "Next"
        case "dsh-dev": return "Dev"
        case "dsh-brandos": return "BrandOS"
        default: return label
        }
    }

    func ownsRunningInstance(profile: String, pid: Int?, port: Int?) -> Bool {
        runningProfiles.contains { running in
            guard running.profile == profile else { return false }
            if let pid, running.pid == pid {
                return true
            }
            if let port, running.ports.contains(port) {
                return true
            }
            return false
        }
    }
}

struct DshProfileCatalogItem: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String
    let mode: String
    let launchable: Bool
    let launchCommand: String?
    let pluginCount: Int
    let customPluginCount: Int
    let plugins: [DshPluginCatalogItem]
    var inventoryWarnings: [String]? = nil

    var pluginPackages: [DshPluginCatalogItem] { plugins.filter { $0.packageType != "dependency" } }
    var officialCount: Int { pluginPackages.filter { $0.origin == "official" }.count }
    var thirdPartyCount: Int { pluginPackages.filter { $0.origin == "third-party" }.count }
    var unknownCount: Int { pluginPackages.count - officialCount - thirdPartyCount }
    var dependencyCount: Int { plugins.count - pluginPackages.count }
}

struct DshPluginCatalogItem: Decodable, Identifiable {
    let name: String
    let spec: String
    let kind: String
    var origin: String? = nil
    var originEvidence: String? = nil
    var installedVersion: String? = nil
    var installation: String? = nil
    var packageType: String? = nil
    var description: String? = nil
    var repository: String? = nil
    var declaredIn: [String]? = nil
    var declarations: [String]? = nil
    var clientContribution: Bool? = nil

    var id: String { name }

    var originLabel: String {
        switch origin {
        case "official": return "官方"
        case "third-party": return "第三方"
        default: return "来源待确认"
        }
    }
    var typeLabel: String {
        switch packageType {
        case "bundle": return "组合包"
        case "plugin": return "插件"
        case "dependency": return "普通依赖"
        default: return "类型待确认"
        }
    }
    var declarationLabel: String {
        let values = declarations ?? []
        if values.contains("disabled-declaration") { return "含停用声明 · 最终状态未验" }
        if values.contains("conditional-declaration") { return "条件加载 · 未求值" }
        if values.contains("bundle") { return "已列入 Profile 组合" }
        if values.contains("reference") { return "配置引用 · 运行状态未验" }
        return "仅声明依赖 · 加载状态未验"
    }
    func matches(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || ([name, description ?? "", installedVersion ?? "", repository ?? ""] + (declaredIn ?? []))
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct DshRunningProfileCatalogItem: Decodable, Identifiable {
    let profile: String
    let pid: Int
    let ports: [Int]

    var id: String { "\(pid):\(profile)" }
}

struct DshRuntimeCatalogItem: Decodable, Identifiable {
    let id: String
    let version: String
    let path: String
    let executable: String
    let source: String
    let launchable: Bool
    let linkedHomeIds: [String]

    var selectionID: String { "runtime:\(id)" }
}

struct DshStartResult: Decodable {
    let ok: Bool
    let action: String
    let homeId: String
    let home: String
    let version: String?
    let profile: String
    let pid: Int
    let port: Int?
    let url: String?
    let tmuxSession: String
    let runtime: String
    let includesSecrets: Bool

    var isSafeForLocalOpen: Bool {
        guard ok, !includesSecrets else { return false }
        return url == nil || safeLoopbackURL != nil
    }

    var safeLoopbackURL: URL? {
        guard let url,
              let parsed = URL(string: url),
              parsed.scheme?.lowercased() == "http",
              ["127.0.0.1", "localhost"].contains(parsed.host?.lowercased() ?? ""),
              parsed.user == nil,
              parsed.password == nil,
              parsed.query == nil,
              let port = parsed.port,
              (1...65_535).contains(port)
        else {
            return nil
        }
        return parsed
    }
}

/// A compact, read-only projection of one launchable DSH Web Profile for the
/// menu bar. The Catalog remains the source of truth; this type only derives
/// presentation metadata and never invents runtime state.
struct DshPopoverApp: Identifiable {
    let home: DshHomeCatalogItem
    let profile: DshProfileCatalogItem
    let runningProfile: DshRunningProfileCatalogItem?

    var id: String { profile.id }

    var isRunning: Bool { runningPort != nil }

    var runningPort: Int? {
        runningProfile?.ports.first { (1...65_535).contains($0) }
    }

    var displayName: String {
        switch profile.name {
        case "web":
            return home.id == "dsh" ? "DSH Web" : "\(home.shortcutLabel) Web"
        case "digital-me": return "Digital Me"
        case "digital-me-im": return "Digital Me IM"
        case "zhitro": return "Zhitro"
        case "cima-check": return "CIMA Check"
        case "devflow-lab": return "DevFlow Lab"
        case "modebar-lab": return "ModeBar Lab"
        case "qwen-image-lab": return "Image Lab"
        case "sidechat-lab": return "SideChat Lab"
        case "ui-test-studio-dev": return "UI Test Studio"
        case "voice-lab": return "Voice Lab"
        default:
            return profile.name
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    var systemImage: String {
        switch profile.name {
        case "digital-me", "digital-me-im": return "person.crop.circle"
        case "zhitro": return "sparkles"
        case "voice-lab": return "waveform"
        case "qwen-image-lab": return "photo"
        case "sidechat-lab": return "bubble.left.and.bubble.right"
        case "ui-test-studio-dev": return "hammer"
        case "modebar-lab": return "slider.horizontal.3"
        case "devflow-lab": return "arrow.triangle.branch"
        case "cima-check": return "checkmark.shield"
        case "web": return "globe"
        default: return "square.grid.2x2"
        }
    }

    /// Labels are derived from the Profile's declared plugin names. Every Web
    /// bundle exposes chat/workspace/agent/settings; custom labels are added
    /// only when their backing plugin is present in the Catalog response.
    var capabilityLabels: [String] {
        let names = profile.plugins.map { $0.name.lowercased() }
        var labels = ["对话"]

        func includes(_ fragments: String...) -> Bool {
            names.contains { name in fragments.contains { name.contains($0) } }
        }

        func includesPackage(_ package: String) -> Bool {
            names.contains { $0 == package || $0.hasSuffix("/\(package)") }
        }

        func append(_ label: String, when condition: Bool) {
            guard condition, !labels.contains(label) else { return }
            labels.append(label)
        }

        append("记忆", when: includes("dsh-memory"))
        append("预设", when: includes("preset-matrix", "preset-workbench"))
        append("多 Agent", when: includes("agent-teams", "groupx"))
        append("GenUI", when: includes("dsh-genui"))
        append("IM", when: includesPackage("dsh-im"))
        append("语音", when: includes("dsh-voice"))
        append("图像", when: includes("qwen-image", "image-mcp"))
        append("侧聊", when: includes("side-chat"))
        append("仪表盘", when: includes("zhitro-dashboard"))
        append("艺术指导", when: includes("art-director"))
        append("UI 测试", when: includes("ui-test"))
        append("工作流", when: includes("dsh-devflow"))
        append("自检", when: includes("self-verifier", "context-integrity"))
        append("网络", when: includes("dsh-clash"))
        append("Codex", when: includes("codex-connect"))
        append("插件", when: includes("dshmarket", "find-plugin"))

        for baseline in ["工作区", "Agent", "设置"] where labels.count < 4 {
            labels.append(baseline)
        }
        return Array(labels.prefix(4))
    }
}

enum DshPopoverCatalogProjection {
    private static let preferredProfileOrder = [
        "digital-me",
        "digital-me-im",
        "voice-lab",
        "qwen-image-lab",
        "ui-test-studio-dev",
        "sidechat-lab",
        "zhitro",
        "modebar-lab",
        "devflow-lab",
        "cima-check",
        "web",
    ]

    static func apps(from homes: [DshHomeCatalogItem]) -> [DshPopoverApp] {
        homes
            .flatMap { home in
                home.profiles
                    .filter(\.launchable)
                    .map { profile in
                        DshPopoverApp(
                            home: home,
                            profile: profile,
                            runningProfile: home.runningProfiles.first {
                                $0.profile == profile.name
                            }
                        )
                    }
            }
            .sorted(by: appComesBefore)
    }

    static func featuredApps(
        from homes: [DshHomeCatalogItem],
        limit: Int = 6
    ) -> [DshPopoverApp] {
        Array(apps(from: homes).prefix(max(0, limit)))
    }

    static func versionCount(in homes: [DshHomeCatalogItem]) -> Int {
        Set(homes.compactMap(\.version)).count
    }

    private static func appComesBefore(_ lhs: DshPopoverApp, _ rhs: DshPopoverApp) -> Bool {
        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning
        }

        let leftRank = preferenceRank(for: lhs)
        let rightRank = preferenceRank(for: rhs)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        if lhs.home.id != rhs.home.id {
            return lhs.home.id < rhs.home.id
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func preferenceRank(for app: DshPopoverApp) -> Int {
        if app.profile.name == "web", app.home.id != "dsh" {
            return preferredProfileOrder.count + 10
        }
        return preferredProfileOrder.firstIndex(of: app.profile.name)
            ?? preferredProfileOrder.count
    }
}
