import AppKit
import SwiftUI

struct DshRuntimeCatalogView: View {
    @StateObject private var model: DshRuntimeCatalogModel
    @State private var expandedHomes: Set<String> = []

    init(model: DshRuntimeCatalogModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 560)
        .task {
            if model.catalog == nil {
                await model.refresh()
            }
            if let home = model.selectedHome { expandedHomes.insert(home.id) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DSH 启动预览")
                        .font(.headline)
                    Text(catalogSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新扫描本机 DSH 版本、Home、Profile 和插件")
                .disabled(model.isRefreshing)
            }
            .padding(12)

            Divider()

            List(selection: $model.selectionID) {
                Section("数据与配置 · HOME") {
                    ForEach(model.catalog?.homes ?? []) { home in
                        DisclosureGroup(isExpanded: Binding(get: { expandedHomes.contains(home.id) }, set: { value in
                            if value { expandedHomes.insert(home.id) } else { expandedHomes.remove(home.id) }
                        })) {
                            ForEach(home.profiles) { profile in
                                Label(profile.name, systemImage: profile.launchable ? "square.stack.3d.up" : "terminal")
                                    .font(.caption).tag(home.previewSelectionID(for: profile))
                            }
                        } label: {
                            Button { model.selectHome(home.id); model.layer = .launch } label: {
                                DshHomeSidebarRow(home: home)
                            }.buttonStyle(.plain)
                        }.tag(home.selectionID)
                    }
                }

                Section("默认入口涉及的程序") {
                    ForEach(model.catalog?.runtimes ?? []) { runtime in
                        DshRuntimeSidebarRow(runtime: runtime)
                            .tag(runtime.selectionID)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: model.selectionID) { selection in
                if selection?.hasPrefix("profile:") == true { model.layer = .launch }
                if let home = model.selectedHome { expandedHomes.insert(home.id) }
            }

            if let error = model.error {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let message = model.message {
                Divider()
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let home = model.selectedHome, model.layer == .launch {
            DshLaunchPreviewView(home: home, model: model)
        } else if let home = model.selectedHome {
            DshHomeDetailView(home: home, model: model)
        } else if let runtime = model.selectedRuntime {
            DshRuntimeDetailView(runtime: runtime, catalog: model.catalog, model: model)
        } else if model.isRefreshing {
            ProgressView("正在扫描 DSH Runtime Catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                Text("未发现 DSH Runtime")
                    .font(.headline)
                Text("刷新后会显示本机 DSH 版本、路径、Profile 与插件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var catalogSummary: String {
        guard let catalog = model.catalog else { return "正在扫描…" }
        return "\(catalog.homeCount) 个 HOME · \(catalog.runtimeCount) 个程序副本"
    }
}

private struct DshHomeSidebarRow: View {
    let home: DshHomeCatalogItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: home.runningProfiles.isEmpty ? "server.rack" : "play.circle.fill")
                .foregroundColor(home.runningProfiles.isEmpty ? .secondary : .green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(home.label)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("入口 \(home.version ?? "未识别")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("\(home.profileCount) 个 Profile · \(home.runningProfiles.count) 个运行实例")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct DshRuntimeSidebarRow: View {
    let runtime: DshRuntimeCatalogItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.version)
                    .font(.body.weight(.medium).monospaced())
                Text(URL(fileURLWithPath: runtime.path).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct DshHomeDetailView: View {
    let home: DshHomeCatalogItem
    @ObservedObject var model: DshRuntimeCatalogModel
    @State private var profileQuery = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Picker("管理层级", selection: $model.layer) {
                    ForEach(DshManagementLayer.allCases) { layer in Text(layer.rawValue).tag(layer) }
                }.pickerStyle(.segmented)
                switch model.layer {
                case .launch:
                    paths
                    profiles
                case .instances:
                    runningProfiles
                case .sessions:
                    DshEnvironmentSessionsView(home: home, profileFilter: $model.profileFilter, runtime: model.runtimeModel)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(home.label)
                        .font(.title2.bold())
                    Text(home.version ?? "unknown")
                        .font(.caption.monospaced().bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                Text("\(home.profileCount) 个 Profile · 配置与数据共享此 HOME")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let profile = home.defaultLaunchProfile {
                Button {
                    Task { await model.start(home: home, profile: profile) }
                } label: {
                    Label("一键启动 \(profile.name)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.launchingProfileIDs.contains(profile.id))
                .help("以动态端口启动此 Home 的 \(profile.name) Profile，成功后自动打开")
            }
        }
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("位置")
                .font(.headline)
            DshPathRow(label: "DSH_HOME", path: home.path, model: model)
            if let runtimePath = home.runtimePath {
                DshPathRow(label: "Runtime", path: runtimePath, model: model)
            }
            if let executable = home.executable {
                DshPathRow(label: "Executable", path: executable, model: model)
            }
        }
    }

    private var runningProfiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("运行中的实例")
                .font(.headline)
            if home.runningProfiles.isEmpty {
                Text("此 HOME 暂无运行实例。请在启动环境中选择 Profile。").foregroundStyle(.secondary)
            }
            ForEach(home.runningProfiles) { item in
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(item.profile)
                        .font(.body.weight(.medium))
                    Text("Home · \(home.shortcutLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("PID \(item.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(item.ports, id: \.self) { port in
                        Button("打开 :\(String(port))") {
                            model.open(port: port)
                        }
                        .controlSize(.small)
                    }
                    Button("会话") {
                        model.profileFilter = item.profile
                        model.layer = .sessions
                    }
                    Menu {
                        ForEach(item.ports, id: \.self) { port in
                            Button("重启 :\(String(port))（会中断该实例任务）") {
                                Task { await model.restart(home: home, instance: item, port: port) }
                            }.disabled(model.launchingProfileIDs.contains("restart:\(item.id)"))
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile 工作环境")
                .font(.headline)
            TextField("搜索 Profile 或它包含的插件", text: $profileQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索 Profile")
            Text("选择一种插件组合进入工作。Profile 不是 Preset，也不等于独立的 DSH 版本。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(home.profiles.filter { profile in
                (model.profileFilter.isEmpty || profile.name == model.profileFilter) && (profileQuery.isEmpty || profile.name.localizedCaseInsensitiveContains(profileQuery)
                    || profile.plugins.contains { $0.matches(query: profileQuery) }
                )
            }) { profile in
                DshProfileCard(home: home, profile: profile, model: model)
            }
            if !model.profileFilter.isEmpty {
                Button("显示此 HOME 全部 Profile") { model.profileFilter = "" }
            }
        }
    }
}

private struct DshProfileCard: View {
    let home: DshHomeCatalogItem
    let profile: DshProfileCatalogItem
    @ObservedObject var model: DshRuntimeCatalogModel
    @State private var showsPlugins = false

    private var ports: [Int] {
        home.runningProfiles.filter { $0.profile == profile.name }.flatMap(\.ports)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: profile.launchable ? "globe" : "shippingbox")
                    .font(.title2).foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.headline).textSelection(.enabled)
                    Text("\(profile.mode.uppercased()) · \(profile.pluginPackages.count) 个插件 / 组合包")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !ports.isEmpty {
                    Label("运行中", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            HStack(spacing: 12) {
                DshInventoryBadge(text: "官方 \(profile.officialCount)", color: .blue)
                DshInventoryBadge(text: "第三方 \(profile.thirdPartyCount)", color: .purple)
                DshInventoryBadge(text: "待确认 \(profile.unknownCount)", color: .secondary)
                if profile.dependencyCount > 0 {
                    Text("另有 \(profile.dependencyCount) 个普通依赖").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !(profile.inventoryWarnings ?? []).isEmpty {
                Label("部分声明未展开，详情中可查看原因", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { showsPlugins = true } label: {
                    Label("查看插件与来源", systemImage: "list.bullet.rectangle")
                }
                .accessibilityLabel("查看 \(profile.name) 的插件与来源")
                Spacer()
                ForEach(Array(Set(ports)).sorted(), id: \.self) { port in
                    Button("打开 :\(String(port))") { model.open(port: port) }
                }
                if profile.launchable && ports.isEmpty {
                    Button {
                        Task { await model.start(home: home, profile: profile) }
                    } label: {
                        Label(model.launchingProfileIDs.contains(profile.id) ? "正在启动…" : "启动并打开", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.launchingProfileIDs.contains(profile.id))
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
        .sheet(isPresented: $showsPlugins) {
            DshProfileInventoryView(home: home, profile: profile, model: model)
        }
    }
}

private struct DshInventoryBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.09), in: Capsule())
    }
}

struct DshProfileInventoryView: View {
    let home: DshHomeCatalogItem
    let profile: DshProfileCatalogItem
    @ObservedObject var model: DshRuntimeCatalogModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var source = "all"

    private var filtered: [DshPluginCatalogItem] {
        profile.plugins.filter { plugin in
            plugin.matches(query: query) && (source == "all"
                || (source == "dependency" && plugin.packageType == "dependency")
                || (source == "unknown" && plugin.origin != "official" && plugin.origin != "third-party" && plugin.packageType != "dependency")
                || (plugin.origin == source && plugin.packageType != "dependency"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.title2.bold())
                    Text("\(home.label) / \(profile.mode.uppercased()) · 插件组成与来源")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            VStack(alignment: .leading, spacing: 10) {
                TextField("搜索插件名、用途、版本或来源组合", text: $query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("搜索插件")
                Picker("插件来源", selection: $source) {
                    Text("全部 \(profile.plugins.count)").tag("all")
                    Text("官方 \(profile.officialCount)").tag("official")
                    Text("第三方 \(profile.thirdPartyCount)").tag("third-party")
                    Text("待确认 \(profile.unknownCount)").tag("unknown")
                    Text("普通依赖 \(profile.dependencyCount)").tag("dependency")
                }.pickerStyle(.segmented)
                Text("清单读取 Profile、组合包和 HOME 补丁中的声明。已安装 ≠ 已加载；条件、覆盖补丁、Preset 和动态插件需运行时核对。来源分类依据包元数据，不代表安全认证。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let warnings = profile.inventoryWarnings, !warnings.isEmpty {
                        DisclosureGroup("\(warnings.count) 项读取范围说明") {
                            ForEach(warnings, id: \.self) { warning in
                                Text(warning).font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if filtered.isEmpty {
                        Text("没有符合条件的插件").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(36)
                    }
                    ForEach(filtered) { plugin in DshPluginInventoryRow(plugin: plugin) }
                }.padding(20)
            }
            Divider()
            HStack {
                Text("显示 \(filtered.count) / \(profile.plugins.count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制 Profile 路径") { model.copy(profile.path) }
                if let command = profile.launchCommand {
                    Button("复制启动命令") { model.copy(command) }
                }
            }.padding(14)
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 540, idealHeight: 720)
    }
}

private struct DshPluginInventoryRow: View {
    let plugin: DshPluginCatalogItem
    private var originColor: Color {
        plugin.origin == "official" ? .blue : plugin.origin == "third-party" ? .purple : .secondary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(plugin.name).font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                DshInventoryBadge(text: plugin.originLabel, color: originColor)
            }
            HStack(spacing: 10) {
                Text(plugin.typeLabel)
                Text(plugin.installation == "resolved" ? "已解析安装包" : "未解析到安装包")
                Text(plugin.installedVersion ?? "版本未知").textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
            if let description = plugin.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(plugin.declarationLabel).font(.caption)
            DisclosureGroup("来源依据与配置位置") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plugin.originEvidence ?? "旧版清单没有提供来源依据；请更新 Harvis CLI 后重新扫描。")
                    Text("安装声明：\(plugin.spec)").textSelection(.enabled)
                    if let repo = plugin.repository {
                        Text("仓库：\(repo)").textSelection(.enabled)
                    }
                    Text("引用位置：\((plugin.declaredIn ?? []).joined(separator: "、"))")
                        .textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }.font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DshRuntimeDetailView: View {
    let runtime: DshRuntimeCatalogItem
    let catalog: DshRuntimeCatalog?
    @ObservedObject var model: DshRuntimeCatalogModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DSH \(runtime.version)")
                            .font(.title2.bold().monospaced())
                        Text(runtime.linkedHomeIds.isEmpty
                             ? "Standalone runtime copy"
                             : "Linked to \(runtime.linkedHomeIds.count) DSH Home(s)")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("位置")
                        .font(.headline)
                    DshPathRow(label: "Package", path: runtime.path, model: model)
                    DshPathRow(label: "Executable", path: runtime.executable, model: model)
                }

                if !runtime.linkedHomeIds.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Managed Homes")
                            .font(.headline)
                        ForEach(runtime.linkedHomeIds, id: \.self) { homeID in
                            let home = catalog?.homes.first(where: { $0.id == homeID })
                            Button {
                                model.selectHome(homeID)
                            } label: {
                                Label(home?.label ?? homeID, systemImage: "server.rack")
                            }
                        }
                    }
                } else {
                    Label(
                        "此副本没有绑定 Profile Home；请从左侧 DSH Homes 启动可管理版本。",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(.background)
    }
}

private struct DshPathRow: View {
    let label: String
    let path: String
    @ObservedObject var model: DshRuntimeCatalogModel

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                model.copy(path)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制路径")
            Button {
                model.reveal(path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
        }
        .padding(9)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }
}
