import AppKit
import Foundation
import SwiftUI

extension HarvisPopoverView {
    var dshServiceSection: some View {
        let homes = dshShortcutHomes.filter { dshSelectedHomeID.isEmpty || $0.id == dshSelectedHomeID }
        let apps = DshPopoverCatalogProjection.apps(from: homes)
        let featuredApps = DshPopoverCatalogProjection.featuredApps(from: homes)
        let runningCount = apps.filter(\.isRunning).count

        return compactPanel("DSH 启动预览") {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .foregroundColor(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dshShortcutHomes.isEmpty
                         ? (dshShortcutLoading ? "正在扫描 DSH Apps" : dshShortcutError == nil ? "未读取到 DSH Apps" : "DSH 目录读取失败")
                         : "\(runningCount) 运行中 · \(apps.count) 个 Web Profile")
                        .font(.caption2.bold())
                    Text(dshShortcutHomes.isEmpty
                         ? "从 Runtime Catalog 读取 Profile 与功能"
                         : "先看基座、共用插件和独有能力")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 4)
                Button {
                    model.openDshRuntimeCatalog()
                } label: {
                    Image(systemName: "shippingbox")
                }
                .buttonStyle(.borderless)
                .help("查看全部本地 DSH 版本、路径、Profiles、插件与一键启动")
                Button {
                    refreshDshShortcuts()
                    if dshManagementLayer == .sessions { Task { await model.refreshDshThreads() } }
                } label: {
                    if dshShortcutLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(dshShortcutLoading)
                .help("重新扫描 DSH Home、Profile、插件与运行实例")
                .accessibilityIdentifier("harvis.refresh.dsh-catalog")
                .accessibilityValue(
                    trackedRefreshAccessibilityValue(
                        "dsh-catalog",
                        externallyRunning: dshShortcutLoading
                    )
                )
            }

            Button {
                model.openDshRuntimeCatalog(homeID: dshSelectedHomeID.isEmpty ? nil : dshSelectedHomeID)
            } label: {
                Label("打开 Profile 树与插件矩阵", systemImage: "square.grid.3x3")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("dsh-preview-platform")
            if let error = dshShortcutError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(dshShortcutHomes.isEmpty ? "请点击刷新重试，或打开环境管理查看详情。" : "以下为上次读取的清单，请刷新后再操作。")
                    .font(.caption2).foregroundStyle(theme.muted)
            }
            if dshShortcutLoading && dshShortcutHomes.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取应用与能力清单…")
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                    Spacer()
                }
            } else if !dshShortcutHomes.isEmpty {
                HStack(spacing: 4) {
                    inlineMetric("Homes", dshShortcutHomes.count)
                    inlineMetric("Profiles", apps.count)
                    inlineMetric("运行", runningCount)
                    inlineMetric(
                        "版本",
                        DshPopoverCatalogProjection.versionCount(in: dshShortcutHomes)
                    )
                }

                Picker("DSH 管理层级", selection: $dshManagementLayer) {
                    ForEach(DshManagementLayer.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).controlSize(.small)
                Picker("HOME", selection: $dshSelectedHomeID) {
                    Text("全部 HOME").tag("")
                    ForEach(dshShortcutHomes) { home in Text(home.label).tag(home.id) }
                }.controlSize(.small)
                switch dshManagementLayer {
                case .launch:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("选择 Profile")
                            .font(.caption2.bold())
                            .foregroundColor(theme.muted)
                        Spacer()
                        if apps.count > featuredApps.count {
                            dshAllAppsMenu(apps)
                        }
                    }
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 112), spacing: 5),
                            GridItem(.flexible(minimum: 112), spacing: 5),
                        ],
                        spacing: 5
                    ) {
                        ForEach(featuredApps) { app in
                            dshAppCard(app)
                        }
                    }
                }
                case .instances:
                    dshManagedInstances(homes)
                case .sessions:
                    dshManagedSessionShortcuts(homes)
                }
            } else if dshShortcutError == nil {
                Label(
                    "没有可展示的 Web Profile；请在 Catalog 中检查 Home 配置。",
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundColor(theme.muted)
            }

            Button {
                model.openDshRuntimeCatalog(layer: dshManagementLayer, homeID: dshSelectedHomeID.isEmpty ? nil : dshSelectedHomeID)
            } label: {
                Label(dshManagementLayer == .launch ? "管理 Profile 与插件来源" : dshManagementLayer == .instances ? "管理运行实例" : "管理 DSH 会话", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help("在 DSH 专属管理窗口继续操作")
            .onChange(of: dshManagementLayer) { layer in
                if layer == .sessions { Task { await model.refreshDshThreads() } }
            }
        }
    }

    func dshManagedInstances(_ homes: [DshHomeCatalogItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if homes.allSatisfy({ $0.runningProfiles.isEmpty }) {
                Text("暂无运行实例，请先选择 Profile 启动。").font(.caption2).foregroundStyle(theme.muted)
            }
            ForEach(homes) { home in
                ForEach(home.runningProfiles) { instance in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(instance.profile, systemImage: "circle.fill").font(.caption2.bold()).foregroundStyle(theme.positive)
                            Spacer()
                            Text("PID \(String(instance.pid))").font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.muted)
                        }
                        Text(home.label).font(.caption2).foregroundStyle(theme.muted)
                        HStack {
                            ForEach(instance.ports, id: \.self) { port in
                                Button(":\(String(port))") {
                                    if let url = URL(string: "http://127.0.0.1:\(port)/") { NSWorkspace.shared.open(url) }
                                }.help("打开此实例")
                            }
                            Spacer()
                            Button("会话") {
                                model.openDshRuntimeCatalog(layer: .sessions, homeID: home.id, profile: instance.profile)
                            }
                            Menu {
                                ForEach(instance.ports, id: \.self) { port in
                                    Button("重启 :\(String(port))（会中断任务）") { model.restartDshInstance(port: port) }
                                        .disabled(model.isBusy)
                                }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                        }.controlSize(.mini)
                    }.padding(8).background(theme.surfaceAlt.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    func dshManagedSessionShortcuts(_ homes: [DshHomeCatalogItem]) -> some View {
        let scopes = Set(homes.flatMap { home in home.profiles.map { "dsh::\(home.id)::\($0.name)" } })
        let sessions = model.dshThreads.filter { scopes.contains($0.sourceScope) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(sessions.count) 个会话").font(.caption2.bold())
                Spacer()
                Button { Task { await model.refreshDshThreads() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.isDshThreadRefreshing)
            }
            if sessions.isEmpty {
                Text(model.isDshThreadRefreshing ? "正在读取会话…" : "暂无会话，或实例尚未运行。")
                    .font(.caption2).foregroundStyle(theme.muted)
            }
            if model.dshThreadError != nil {
                Text("部分实例读取失败，详情页可查看；缓存不代表在线。").font(.caption2).foregroundStyle(theme.muted)
            }
            ForEach(Array(sessions.prefix(5))) { thread in
                Button {
                    if let home = homes.first(where: { home in home.profiles.contains { "dsh::\(home.id)::\($0.name)" == thread.sourceScope } }),
                       let profile = home.profiles.first(where: { "dsh::\(home.id)::\($0.name)" == thread.sourceScope }) {
                        model.openDshRuntimeCatalog(layer: .sessions, homeID: home.id, profile: profile.name)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(thread.title).font(.caption2.bold()).lineLimit(1)
                        Text("Preset：\(thread.agentNickname ?? "未提供") · \(thread.running ? "运行中" : "空闲")")
                            .font(.system(size: 9)).foregroundStyle(theme.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(theme.surfaceAlt.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }

    func refreshDshShortcuts() {
        guard !dshShortcutLoading else { return }
        Task { @MainActor in
            guard !dshShortcutLoading else { return }
            dshShortcutLoading = true
            dshShortcutError = nil
            defer {
                dshShortcutLoading = false
                refreshActionCompletions["dsh-catalog", default: 0] += 1
            }
            do {
                let output = try await model.runProcess(
                    model.serviceManagerPath,
                    ["dsh-web", "catalog"],
                    timeout: 20,
                    standardOutputLimit: 8_388_608
                )
                let catalog = try JSONDecoder().decode(
                    DshRuntimeCatalog.self,
                    from: Data(output.utf8)
                )
                guard catalog.isSafeForLocalDisplay else {
                    throw HarvisBarError.api("DSH Runtime Catalog returned an unsafe response")
                }
                dshShortcutHomes = catalog.homes
                if !dshSelectedHomeID.isEmpty && !catalog.homes.contains(where: { $0.id == dshSelectedHomeID }) {
                    dshSelectedHomeID = ""
                }
                model.lastError = nil
            } catch {
                dshShortcutError = model.clean(error.localizedDescription)
                model.lastError = dshShortcutError
            }
        }
    }

    func dshAppCard(_ app: DshPopoverApp) -> some View {
        let busy = dshShortcutLaunchingIDs.contains(app.profile.id)
        return VStack(spacing: 4) {
        Button {
            activateDshApp(app)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: app.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(app.isRunning ? theme.positive : theme.accent)
                    Spacer(minLength: 2)
                    Circle()
                        .fill(app.isRunning ? theme.positive : theme.muted.opacity(0.55))
                        .frame(width: 6, height: 6)
                    Text(app.isRunning ? "运行" : "可启动")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(app.isRunning ? theme.positive : theme.muted)
                }

                Text(app.profile.name)
                    .font(.caption2.bold())
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(app.capabilityLabels.prefix(3).joined(separator: " · "))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)

                HStack(spacing: 3) {
                    Text(app.home.shortcutLabel)
                    Text("· \(app.profile.pluginPackages.count) 插件")
                    Spacer(minLength: 2)
                    if busy {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                    }
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .padding(7)
            .background(
                app.isRunning
                    ? theme.positive.opacity(0.10)
                    : theme.surfaceAlt.opacity(0.76)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        app.isRunning ? theme.positive.opacity(0.58) : theme.line.opacity(0.68),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("预览 Profile \(app.profile.name) 的基座与插件组成")
        .contextMenu {
            if let port = app.runningPort {
                Button {
                    model.restartDshInstance(port: port)
                } label: {
                    Label("重新启动 \(app.displayName)", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
            }
            Button {
                model.openDshRuntimeCatalog(homeID: app.home.id, profile: app.profile.name)
            } label: {
                Label("查看 Profile 与插件", systemImage: "shippingbox")
            }
        }
        .accessibilityIdentifier("dsh-app-\(app.profile.id)")
        .accessibilityLabel("\(app.displayName)，\(app.isRunning ? "运行中" : "可启动")")
        .accessibilityHint("先打开此 Profile 的启动预览")
        Button {
            model.openDshRuntimeCatalog(homeID: app.home.id, profile: app.profile.name)
        } label: {
            Text(app.home.profiles.count > 1
                 ? "HOME 内共用 \(app.home.previewPlugins(for: app.profile, scope: .shared).count) · 独有 \(app.home.previewPlugins(for: app.profile, scope: .unique).count)"
                 : "单 Profile · 暂无共用对比")
                .font(.system(size: 8)).foregroundStyle(theme.accent)
                .lineLimit(1).minimumScaleFactor(0.6)
        }.buttonStyle(.plain)
            .help("查看 \(app.profile.name) 的插件来源、版本与配置关系；? 表示来源待确认")
            .accessibilityLabel("\(app.profile.name) 插件来源详情")
        }
    }

    func dshAllAppsMenu(_ apps: [DshPopoverApp]) -> some View {
        Menu {
            ForEach(apps) { app in
                Button {
                    activateDshApp(app)
                } label: {
                    Label(
                        "\(app.profile.name) · 预览",
                        systemImage: app.systemImage
                    )
                }
                .disabled(dshShortcutLaunchingIDs.contains(app.profile.id))
            }
        } label: {
            Label("全部 \(apps.count)", systemImage: "chevron.down")
                .font(.caption2.bold())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("显示全部可启动 DSH App/Profile")
    }

    func activateDshApp(_ app: DshPopoverApp) {
        model.openDshRuntimeCatalog(homeID: app.home.id, profile: app.profile.name)
    }

    func startDshShortcut(home: DshHomeCatalogItem, profile: DshProfileCatalogItem) {
        guard !dshShortcutLaunchingIDs.contains(profile.id) else { return }
        Task { @MainActor in
            guard !dshShortcutLaunchingIDs.contains(profile.id) else { return }
            dshShortcutLaunchingIDs.insert(profile.id)
            defer { dshShortcutLaunchingIDs.remove(profile.id) }
            do {
                let output = try await model.runProcess(
                    model.serviceManagerPath,
                    [
                        "dsh-web", "start",
                        "--home", home.path,
                        "--profile", profile.name,
                        "--port", "0"
                    ],
                    timeout: 120
                )
                let result = try JSONDecoder().decode(DshStartResult.self, from: Data(output.utf8))
                guard result.isSafeForLocalOpen else {
                    throw HarvisBarError.api("DSH Profile returned an unsafe launch response")
                }
                if let url = result.safeLoopbackURL {
                    NSWorkspace.shared.open(url)
                }
                model.lastActionOutput = "\(home.label) · \(profile.name) 已启动"
                model.lastError = nil
                try? await Task.sleep(for: .milliseconds(500))
                await model.refreshAll()
                refreshDshShortcuts()
            } catch {
                model.lastError = model.clean(error.localizedDescription)
            }
        }
    }

    var networkConsoleSection: some View {
        compactPanel("Network Console") {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundColor(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude → VVCloudhao")
                        .font(.caption2.bold())
                        .foregroundColor(theme.text)
                    Text(model.networkActionSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if model.isNetworkActionRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Button {
                model.openNetworkConsole()
            } label: {
                Label("Open Network Console", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)

            HStack(spacing: 6) {
                networkQuickButton("speedometer", help: "Speed test Clash", action: "speed-route", route: "codex")
                networkQuickButton("speedometer", help: "Speed test V2Ray", action: "speed-route", route: "huggingface")
                networkQuickButton("location", help: "Read Clash public IP", action: "ip-route", route: "codex")
                networkQuickButton("location.fill", help: "Read V2Ray public IP", action: "ip-route", route: "huggingface")
                Spacer(minLength: 0)
            }
        }
    }

    func networkQuickButton(_ systemImage: String, help: String, action: String, route: String) -> some View {
        Button {
            model.runNetworkQuickAction(action, route: route)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
        }
        .help(help)
        .disabled(model.isNetworkActionRunning)
    }

    var proxySection: some View {
        compactPanel("Proxy Routes") {
            HStack(spacing: 5) {
                proxyEndpointPill("clash")
                proxyEndpointPill("v2ray")
                Spacer(minLength: 4)
                Button {
                    model.refreshProxyRoutes()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh proxy status")
                .disabled(model.isProxyRefreshing)
            }

            Picker("System proxy", selection: proxySystemSelection) {
                Text("Clash").tag("clash")
                Text("V2Ray").tag("v2ray")
                Text("Off").tag("off")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(model.isProxyRefreshing)

            HStack(spacing: 6) {
                Text("Codex: \(proxyRouteLabel("codex"))")
                Text("HF: \(proxyRouteLabel("huggingface"))")
                Spacer(minLength: 4)
                if model.proxyStatus?.systemProxy.drift == true {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .help("System proxy differs from the configured Codex route.")
                }
            }
            .font(.caption2)
            .foregroundColor(theme.muted)
        }
    }

    var perAppProxySection: some View {
        compactPanel("Per-App Proxy") {
            PerAppProxyCard(model: model.perAppProxy, theme: theme)
        }
    }

    var proxySystemSelection: Binding<String> {
        Binding(
            get: { model.proxyStatus?.systemProxy.route ?? "unknown" },
            set: { model.switchSystemProxy($0) }
        )
    }

    func proxyEndpointPill(_ id: String) -> some View {
        let endpoint = model.proxyStatus?.endpoints[id]
        let available = endpoint?.available == true
        return HStack(spacing: 4) {
            Circle()
                .fill(available ? theme.positive : Color.red)
                .frame(width: 7, height: 7)
            Text("\(endpoint?.label ?? id) :\(endpoint?.port ?? 0)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(theme.text)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(theme.surfaceAlt.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.opacity(0.70)))
    }

    func proxyRouteLabel(_ route: String) -> String {
        let endpointID = model.proxyStatus?.routes[route] ?? "-"
        return model.proxyStatus?.endpoints[endpointID]?.label ?? endpointID
    }

    var portSection: some View {
        compactPanel("Ports") {
            HStack(spacing: 6) {
                Text(model.barStatus?.ports?.summary ?? "not loaded")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    model.openPorts()
                } label: {
                    Image(systemName: "network")
                }
                .help("Open port manager")
            }

            VStack(spacing: 3) {
                ForEach(model.importantPorts.prefix(8)) { item in
                    portRouteRow(item)
                }
                if model.importantPorts.count > 8 {
                    Button {
                        model.openPorts()
                    } label: {
                        Label("查看全部（\(model.importantPorts.count)）", systemImage: "ellipsis.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundColor(theme.accent)
                }
            }
        }
    }

    func portRouteRow(_ item: PortStatusItem) -> some View {
        Button {
            model.openPort(item)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(portColor(item))
                    .frame(width: 7, height: 7)
                Text(item.shortLabel)
                    .font(.caption2.bold())
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Text(":\(item.port ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                Spacer(minLength: 4)
                Text(item.autostartLabel)
                    .font(.caption2)
                    .foregroundColor(portColor(item))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(theme.surfaceAlt.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .help(item.detailSummary)
    }

    func portColor(_ item: PortStatusItem) -> Color {
        if item.listening != true {
            if item.availability == "on-demand" {
                return theme.muted
            }
            return Color(hex: 0xDC2626)
        }
        if item.important == true && item.autostart?.loaded == true {
            return Color(hex: 0x15803D)
        }
        return Color(hex: 0xB45309)
    }

}
