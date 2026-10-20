import AppKit
import Combine
import HarvisVersionCore
import SwiftUI

struct UnifiedVersionInstallation: Codable, Sendable {
    let profile: String
    let version: String?
    let packagePresent: Bool
}

struct UnifiedVersionItem: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let sourceVersion: String?
    let installedVersion: String?
    let runningVersion: String?
    let publishedVersion: String?
    let repositoryURL: String?
    let paths: [String]
    let installations: [UnifiedVersionInstallation]
    let branch: String?
    let commit: String?
    let dirty: Bool?
    let note: String
    let observedAt: String?

    var icon: String {
        switch kind {
        case "application": return "macwindow"
        case "runtime": return "terminal"
        case "plugin": return "puzzlepiece.extension"
        default: return "arrow.triangle.branch"
        }
    }
    var summary: String { installedVersion ?? sourceVersion ?? "版本待核验" }
    var searchText: String { ([name, repositoryURL ?? ""] + paths).joined(separator: " ") }
}

struct UnifiedVersionSnapshot: Codable, Sendable {
    let schemaVersion: String
    let generatedAt: String
    let githubSnapshotAt: String?
    let warnings: [String]
    let items: [UnifiedVersionItem]
}

@MainActor
final class UnifiedVersionCatalogModel: ObservableObject {
    @Published var snapshot: UnifiedVersionSnapshot?
    private(set) var snapshotData: Data?
    @Published var loading = false
    @Published var error: String?
    let script: String
    let schemaPath: String

    init() {
        let root = Bundle.main.resourceURL?.appendingPathComponent("HarvisPlugin")
        script = root?.appendingPathComponent("scripts/harvis_version_catalog.py").path ?? ""
        schemaPath = root?.appendingPathComponent("schemas/version-catalog-v1.schema.json").path ?? ""
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let result = try await HarvisVersionProcessRunner().run(.init(
                executable: "/usr/bin/python3", arguments: ["-I", script, "list"],
                environment: ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1"],
                timeout: 20, standardOutputLimit: 8_388_608, aggregateLimit: 9_437_184
            ))
            guard result.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
            let fresh = try JSONDecoder().decode(UnifiedVersionSnapshot.self, from: result.standardOutput)
            guard fresh.schemaVersion == "harvis.version-catalog.v1" else { throw CocoaError(.fileReadCorruptFile) }
            snapshotData = result.standardOutput
            snapshot = fresh
        } catch {
            self.error = "读取失败，已保留上次清单。请确认本机配置与数据源可访问后重试。"
        }
    }

    func itemData(id: String) -> Data? {
        guard let snapshotData,
              let root = try? JSONSerialization.jsonObject(with: snapshotData) as? [String: Any],
              let items = root["items"] as? [[String: Any]],
              let item = items.first(where: { $0["id"] as? String == id }) else { return nil }
        return try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])
    }

    var agentCommand: String {
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "/usr/bin/python3 -I \(quoted) list"
    }
}

@MainActor
struct UnifiedVersionCatalogView: View {
    @StateObject private var catalog = UnifiedVersionCatalogModel()
    @ObservedObject var runtime: HarvisRuntimeModel
    @State private var kind = "all"
    @State private var query = ""
    @State private var selectedID: String?
    @State private var notice: String?

    private let kinds = [("all", "全部"), ("application", "Harvis"), ("runtime", "DSH"), ("plugin", "插件"), ("repository", "仓库")]
    private var filtered: [UnifiedVersionItem] {
        (catalog.snapshot?.items ?? []).filter {
            (kind == "all" || $0.kind == kind) && (query.isEmpty || $0.searchText.localizedCaseInsensitiveContains(query))
        }
    }
    private var selected: UnifiedVersionItem? { filtered.first { $0.id == selectedID } ?? filtered.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 12) {
                Picker("类别", selection: $kind) {
                    ForEach(kinds, id: \.0) { key, title in
                        Text("\(title) \(count(key))").tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 590)
                TextField("搜索名称、仓库或本地地址", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("harvis-versions-search")
            }.padding(16)
            if let error = catalog.error { banner(error, isError: true) }
            if let warnings = catalog.snapshot?.warnings, !warnings.isEmpty {
                banner(warnings.joined(separator: " · "), isError: true)
            }
            HSplitView {
                list.frame(minWidth: 270, idealWidth: 320, maxWidth: 400)
                ScrollView {
                    if let item = selected { detail(item).padding(24) }
                    else {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                            Text(catalog.loading ? "正在读取本机版本…" : "没有匹配的项目")
                            if !query.isEmpty { Button("清除搜索") { query = "" } }
                        }.frame(maxWidth: .infinity).padding(60)
                    }
                }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(notice ?? "已安装 ≠ 正在运行 · 未知版本保留为空 · 本页读取本机信息")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制 Agent 命令") { copy(catalog.agentCommand, "已复制 Agent 读取命令") }
                Button("Schema") { NSWorkspace.shared.open(URL(fileURLWithPath: catalog.schemaPath)) }
                Button("导出 JSON") { exportSnapshot() }.disabled(catalog.snapshot == nil)
            }.padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await catalog.refresh(); selectedID = filtered.first?.id }
        .onChange(of: kind) { _ in selectedID = filtered.first?.id }
        .onChange(of: query) { _ in
            if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 30)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("统一版本管理").font(.title2.bold())
                Text("Harvis · DSH · 插件 · GitHub 仓库").foregroundStyle(.secondary)
                if let time = catalog.snapshot?.githubSnapshotAt {
                    Text("仓库 / 插件快照：\(time)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Harvis 构建详情") { runtime.openHarvisVersionCatalog() }
            Button("DSH 运行目录") { runtime.openDshRuntimeCatalog() }
            Button { Task { await catalog.refresh() } } label: {
                Label(catalog.loading ? "读取中" : "刷新清单", systemImage: "arrow.clockwise")
            }.disabled(catalog.loading).accessibilityIdentifier("harvis-versions-refresh")
        }.padding(20)
    }

    private var list: some View {
        List(selection: $selectedID) {
            ForEach(filtered) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.icon).foregroundStyle(Color.accentColor).frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(item.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 7).tag(item.id)
            }
        }.listStyle(.sidebar)
    }

    private func detail(_ item: UnifiedVersionItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(item.name, systemImage: item.icon).font(.title2.bold()).textSelection(.enabled)
            HStack(alignment: .top, spacing: 12) {
                versionCard("源码", item.sourceVersion)
                versionCard("已安装", item.installedVersion)
                versionCard("运行中", item.runningVersion)
                versionCard("已发布", item.publishedVersion)
            }
            Text(item.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let url = item.repositoryURL, let target = URL(string: url), target.scheme == "https" {
                GroupBox("仓库地址") {
                    HStack {
                        Text(url).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Link("打开", destination: target)
                        Button("复制") { copy(url, "已复制仓库地址") }
                    }.padding(8)
                }
            }
            if !item.paths.isEmpty {
                GroupBox("本机位置") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(item.paths, id: \.self) { path in
                            HStack {
                                Text(path).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                Button("复制") { copy(path, "已复制本机地址") }
                            }
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let branch = item.branch { Text("分支：\(branch)").textSelection(.enabled) }
            if let commit = item.commit { Text("构建 / 源码提交：\(commit)").font(.caption.monospaced()).textSelection(.enabled) }
            if let dirty = item.dirty { Text(dirty ? "源码存在未提交修改" : "采集时源码工作树干净").foregroundStyle(.secondary) }
            if !item.installations.isEmpty {
                GroupBox("Profile 安装记录") {
                    VStack(spacing: 10) {
                        ForEach(Array(item.installations.enumerated()), id: \.offset) { _, install in
                            HStack {
                                Text(install.profile)
                                Spacer()
                                Text(install.packagePresent ? (install.version ?? "版本未知") : "仅声明 · 未找到包")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(8)
                }
            }
            if let time = item.observedAt { Text("信息时间：\(time)").font(.caption2).foregroundStyle(.secondary) }
            Button("复制此项目 JSON") {
                if let data = catalog.itemData(id: item.id), let text = String(data: data, encoding: .utf8) { copy(text, "已复制项目 JSON") }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func versionCard(_ label: String, _ version: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(version ?? "未核验").font(.system(size: 13, weight: .semibold, design: .monospaced)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading).padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }
    private func banner(_ text: String, isError: Bool) -> some View {
        Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 10)
    }
    private func count(_ key: String) -> Int { catalog.snapshot?.items.filter { key == "all" || $0.kind == key }.count ?? 0 }
    private func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notice = message
    }
    private func exportSnapshot() {
        guard let snapshotData = catalog.snapshotData else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "harvis-versions.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try snapshotData.write(to: url, options: .atomic); notice = "已导出版本清单"
        } catch { notice = "导出失败，请选择可写入的位置" }
    }
}

@MainActor
final class UnifiedVersionCatalogWindowController {
    static let shared = UnifiedVersionCatalogWindowController()
    private var window: NSWindow?
    func show(runtime: HarvisRuntimeModel) {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "统一版本管理"
            created.isReleasedWhenClosed = false
            created.contentViewController = NSHostingController(rootView: UnifiedVersionCatalogView(runtime: runtime))
            created.contentMinSize = NSSize(width: 960, height: 600)
            created.setContentSize(NSSize(width: 1160, height: 760))
            created.setAccessibilityIdentifier("harvis-unified-version-catalog")
            created.center(); window = created
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
