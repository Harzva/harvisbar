import SwiftUI

struct DshLaunchPreviewView: View {
    let home: DshHomeCatalogItem
    @ObservedObject var model: DshRuntimeCatalogModel
    @State private var layout = "profiles"
    @State private var query = ""
    @State private var comparisonIDs: Set<String> = []
    @State private var matrixFilter = "differences"

    private var selectedProfiles: [DshProfileCatalogItem] {
        home.profiles.filter { comparisonIDs.contains($0.id) }
    }
    private var rows: [DshPluginComparisonRow] {
        DshPluginComparisonRow.make(profiles: selectedProfiles).filter { row in
            (query.isEmpty || row.name.localizedCaseInsensitiveContains(query))
                && (matrixFilter == "all" || matrixFilter == "common" && row.common
                    || matrixFilter == "differences" && (!row.common || row.versionsDiffer))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(home.label).font(.title2.bold())
                    Text("启动前看清组合，再进入工作环境").foregroundStyle(.secondary)
                }
                Spacer()
                Button("运行实例") { model.layer = .instances }
                Button("会话") { model.profileFilter = model.previewProfile?.name ?? ""; model.layer = .sessions }
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    base
                    if let profile = model.previewProfile {
                        Button("返回此 HOME 的全部 Profile") { model.selectHome(home.id) }
                        DshSelectedProfilePreview(home: home, profile: profile, model: model)
                            .id(profile.id)
                    } else {
                        Picker("预览视图", selection: $layout) {
                            Text("Profile 卡片").tag("profiles")
                            Text("插件对比矩阵").tag("matrix")
                        }.pickerStyle(.segmented)
                        if layout == "profiles" { cards } else { matrix }
                    }
                }.padding(22)
            }
        }
        .onAppear { seedComparison() }
        .onChange(of: home.id) { _ in query = ""; seedComparison() }
    }
    private var base: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("共同基座", systemImage: "square.stack.3d.down.right.fill").font(.headline)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前启动器默认程序").font(.caption).foregroundStyle(.secondary)
                    Text(home.version ?? "版本未识别").font(.headline.monospaced())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("HOME 共享配置与数据").font(.caption).foregroundStyle(.secondary)
                    Text("\(home.profiles.count) 个 Profile · \(home.runningProfiles.count) 个运行实例")
                }
            }
            Text("HOME 是数据与配置空间，程序版本由启动入口决定。下列 Profile 使用本管理器为此 HOME 解析的默认入口；这不是 HOME 只能安装一个版本的限制。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("基座路径与共享边界") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("HOME：\(home.path)")
                    Text("默认程序：\(home.runtimePath ?? "未解析")")
                    Text("Profile 自身组合 → Profile 补丁 → HOME 共享补丁；启动参数、条件表达式和动态插件仍可能改变最终结果。")
                    Text("多个 Profile 引用同名包表示声明共用，不保证同一物理安装、相同版本或相同最终 UI。")
                }.font(.caption).textSelection(.enabled).padding(.top, 6)
            }.font(.caption)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("查找 Profile 或插件", text: $query).textFieldStyle(.roundedBorder)
            Text("选择卡片预览；点击“启动并打开”时才启动实例。")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(home.profiles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.plugins.contains { $0.matches(query: query) } }) { profile in
                    Button { model.selectionID = home.previewSelectionID(for: profile) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: profile.launchable ? "square.stack.3d.up.fill" : "terminal")
                                Text(profile.name).font(.headline).lineLimit(2)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            Text("\(profile.mode.uppercased()) · \(profile.pluginPackages.count) 项插件声明")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text("共用 \(home.previewPlugins(for: profile, scope: .shared).count)")
                                Text(home.profiles.count > 1 ? "独有 \(home.previewPlugins(for: profile, scope: .unique).count)" : "暂无可比较 Profile")
                            }.font(.caption).foregroundStyle(.tint)
                            Text("官方 \(profile.officialCount) · 第三方 \(profile.thirdPartyCount) · 待确认 \(profile.unknownCount)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.padding(16).frame(maxWidth: .infinity, minHeight: 115, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel("预览 \(profile.name)")
                }
            }
        }
    }
    private var matrix: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择 2–4 个 Profile，对比声明共用与差异").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], alignment: .leading) {
                ForEach(home.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(get: { comparisonIDs.contains(profile.id) }, set: { value in
                        if value { comparisonIDs.insert(profile.id) } else { comparisonIDs.remove(profile.id) }
                    })).font(.caption).disabled(!comparisonIDs.contains(profile.id) && comparisonIDs.count >= 4)
                }
            }
            Text("统计仅针对所选 Profile；同名插件的版本、条件或来源仍可能不同。未展开的声明不参与完整性判断。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("矩阵筛选", selection: $matrixFilter) {
                Text("差异").tag("differences")
                Text("共同引用").tag("common")
                Text("全部").tag("all")
            }.pickerStyle(.segmented)
            TextField("搜索矩阵中的插件", text: $query).textFieldStyle(.roundedBorder)
            if selectedProfiles.count < 2 {
                Text("请至少选择两个 Profile。").foregroundStyle(.secondary)
            } else {
                Text("显示 \(rows.count) 项 · 版本不同会保留在差异中").font(.caption)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            Text("插件 / 共用关系").frame(width: 260, alignment: .leading)
                            ForEach(selectedProfiles) { profile in
                                Button(profile.name) { model.selectionID = home.previewSelectionID(for: profile) }
                                    .frame(width: 160)
                            }
                        }.font(.caption.bold()).padding(10).background(.quaternary.opacity(0.7))
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                HStack(alignment: .top, spacing: 0) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.name).font(.caption.monospaced()).textSelection(.enabled)
                                        Text(row.summary).font(.caption2).foregroundStyle(row.versionsDiffer ? .orange : .secondary)
                                    }.frame(width: 260, alignment: .leading)
                                    ForEach(selectedProfiles) { profile in
                                        matrixCell(row.plugin(in: profile)).frame(width: 160)
                                    }
                                }.padding(10)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
    private func matrixCell(_ plugin: DshPluginCatalogItem?) -> some View {
        VStack(spacing: 4) {
            if let plugin {
                Text(plugin.installedVersion ?? "版本未解析").font(.caption.monospaced())
                Text(plugin.originLabel).font(.caption2).foregroundStyle(.secondary)
                Text((plugin.declaredIn ?? []).contains("HOME 共享补丁") ? "HOME 加入" : "组合 / Profile 引用")
                    .font(.caption2).foregroundStyle(.secondary)
                if (plugin.declarations ?? []).contains(where: { $0.contains("disabled") || $0.contains("conditional") }) {
                    Text("含条件或停用声明").font(.caption2).foregroundStyle(.orange)
                }
            } else { Text("—").foregroundStyle(.tertiary) }
        }
    }
    private func seedComparison() {
        let preferred = home.profiles.filter { ["web", "digital-me", "digital-me-im"].contains($0.name) }
        comparisonIDs = Set((preferred.count >= 2 ? Array(preferred.prefix(3)) : Array(home.profiles.prefix(3))).map(\.id))
    }
}

private struct DshSelectedProfilePreview: View {
    let home: DshHomeCatalogItem
    let profile: DshProfileCatalogItem
    @ObservedObject var model: DshRuntimeCatalogModel
    @State private var scope: DshPreviewScope = .all
    @State private var query = ""
    @State private var presetID = ""
    @State private var showInventory = false
    private var plugins: [DshPluginCatalogItem] {
        home.previewPlugins(for: profile, scope: scope).filter { $0.matches(query: query) }
    }
    private var ports: [Int] { Array(Set(home.runningProfiles.filter { $0.profile == profile.name }.flatMap(\.ports))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.title.bold())
                    Text("\(profile.mode.uppercased()) · \(profile.pluginPackages.count) 项插件 / 组合包声明")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !ports.isEmpty {
                    ForEach(ports, id: \.self) { port in Button("进入 :\(String(port))") { model.open(port: port) }.buttonStyle(.borderedProminent) }
                } else if profile.launchable {
                    Button(model.launchingProfileIDs.contains(profile.id) ? "正在启动…" : "启动并打开") {
                        Task { await model.start(home: home, profile: profile) }
                    }.buttonStyle(.borderedProminent).disabled(model.launchingProfileIDs.contains(profile.id))
                } else {
                    Text("此入口不提供 Web 启动").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("官方 \(profile.officialCount) · 第三方 \(profile.thirdPartyCount) · 来源待确认 \(profile.unknownCount)").font(.caption)
                Spacer()
                Button("完整来源明细") { showInventory = true }
            }
            Text("共用 / 独有按此 HOME 的 \(home.profiles.count) 个 Profile 的插件声明比较；HOME 统一加入依据共享补丁。两者可以重叠，不代表运行时已加载。")
                .font(.caption).foregroundStyle(.secondary)
            if !(profile.inventoryWarnings ?? []).isEmpty {
                Label("部分配置未展开，以下比较是已读取范围内的结果。", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            Picker("查看组成", selection: $scope) {
                ForEach(DshPreviewScope.allCases) { scope in Text("\(scope.rawValue) · \(home.previewPlugins(for: profile, scope: scope).count)").tag(scope) }
            }.pickerStyle(.menu)
            if scope == .client {
                Text("依据包内 dsh.client 声明识别 UI 扩展；主题、设置、Preset、条件加载及会话状态也会影响实际界面。").font(.caption).foregroundStyle(.secondary)
            }
            TextField("搜索当前组成", text: $query).textFieldStyle(.roundedBorder)
            DisclosureGroup("Preset / 模式追加预览") { presetPreview }
            LazyVStack(alignment: .leading, spacing: 8) {
                if plugins.isEmpty { Text("此分类暂无匹配声明。").foregroundStyle(.secondary) }
                ForEach(plugins) { plugin in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(plugin.name).font(.caption.monospaced().bold()).textSelection(.enabled)
                            Spacer()
                            Text(plugin.originLabel).font(.caption2).foregroundStyle(.secondary)
                            Text(plugin.installedVersion ?? "版本未解析").font(.caption.monospaced())
                        }
                        Text(plugin.description ?? "未提供用途说明").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        let peers = home.profilesReferencing(plugin.name)
                        Text("\(peers.count) / \(home.profiles.count) 个 Profile 引用 · \(plugin.declarationLabel)").font(.caption2).foregroundStyle(.secondary)
                        DisclosureGroup("引用位置与共用对象") {
                            Text((plugin.declaredIn ?? []).joined(separator: " · ")).font(.caption)
                            Text(peers.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }.font(.caption)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.sheet(isPresented: $showInventory) { DshProfileInventoryView(home: home, profile: profile, model: model) }
    }
    private var presetPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这是程序自带和 HOME 本地目录的静态声明预览，不是当前 Profile 的有效 Preset 名单。自定义 roots、动态模式和条件表达式未求值；需进入 DSH 核对实际可选项。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("选择 Preset 预览", selection: $presetID) {
                Text("选择一个 Preset").tag("")
                ForEach(home.presetPreviews ?? []) { preset in Text("\(preset.name) · \(preset.source)").tag(preset.id) }
            }
            if (home.presetPreviews ?? []).isEmpty {
                Text("没有读取到可预览的 Preset 文件；不代表运行时没有 Preset。").font(.caption).foregroundStyle(.secondary)
            }
            if let preset = home.presetPreviews?.first(where: { $0.id == presetID }) {
                let baseNames = Set(profile.pluginPackages.map(\.name))
                let additions = preset.plugins.filter { !baseNames.contains($0) }
                Text("\(additions.count) 项仅出现在此 Preset 声明 · \(preset.plugins.count - additions.count) 项与 Profile 同名")
                    .font(.caption.bold())
                Text("这里只预览差异；启动按钮仅启动 Profile，不会为会话选择这个 Preset。").font(.caption).foregroundStyle(.secondary)
                ForEach(preset.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                ForEach(preset.plugins, id: \.self) { name in
                    HStack {
                        Text(name).font(.caption.monospaced())
                        Spacer()
                        Text(baseNames.contains(name) ? "Profile 也声明" : "Preset 追加声明").font(.caption2).foregroundStyle(.secondary)
                        if preset.conditionalPlugins.contains(name) { Text("条件 / 停用").font(.caption2).foregroundStyle(.orange) }
                    }
                }
            }
        }.padding(.vertical, 10)
    }
}
