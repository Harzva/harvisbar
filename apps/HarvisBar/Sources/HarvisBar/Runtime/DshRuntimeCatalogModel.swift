import AppKit
import Combine
import Foundation

enum DshManagementLayer: String, CaseIterable, Identifiable {
    case launch = "启动预览"
    case instances = "运行实例"
    case sessions = "会话"
    var id: String { rawValue }
}

@MainActor
final class DshRuntimeCatalogModel: ObservableObject {
    @Published private(set) var catalog: DshRuntimeCatalog?
    @Published var selectionID: String?
    @Published private(set) var launchingProfileIDs: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published var message: String?
    @Published var error: String?
    @Published var layer: DshManagementLayer = .launch
    @Published var profileFilter: String = ""

    let runtimeModel: HarvisRuntimeModel

    init(runtimeModel: HarvisRuntimeModel) {
        self.runtimeModel = runtimeModel
    }

    var selectedHome: DshHomeCatalogItem? {
        guard let selectionID else { return nil }
        if selectionID.hasPrefix("profile:") {
            return catalog?.homes.first { home in home.profiles.contains { "profile:\($0.id)" == selectionID } }
        }
        return catalog?.homes.first(where: { $0.selectionID == selectionID })
    }

    var previewProfile: DshProfileCatalogItem? {
        selectedHome?.profiles.first { "profile:\($0.id)" == selectionID }
    }

    var selectedRuntime: DshRuntimeCatalogItem? {
        guard let selectionID, selectionID.hasPrefix("runtime:") else { return nil }
        return catalog?.runtimes.first(where: { $0.selectionID == selectionID })
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let output = try await runtimeModel.runProcess(
                runtimeModel.serviceManagerPath,
                ["dsh-web", "catalog"],
                timeout: 20,
                standardOutputLimit: 8_388_608
            )
            let decoded = try JSONDecoder().decode(
                DshRuntimeCatalog.self,
                from: Data(output.utf8)
            )
            guard decoded.isSafeForLocalDisplay else {
                throw HarvisBarError.api("DSH Runtime Catalog returned an unsafe response")
            }
            catalog = decoded
            if selectionID == nil || !containsSelection(selectionID, catalog: decoded) {
                selectionID = decoded.homes.first?.selectionID
                    ?? decoded.runtimes.first?.selectionID
            }
            error = nil
        } catch {
            self.error = runtimeModel.clean(error.localizedDescription)
        }
    }

    func start(home: DshHomeCatalogItem, profile: DshProfileCatalogItem) async {
        guard profile.launchable, !launchingProfileIDs.contains(profile.id) else { return }
        launchingProfileIDs.insert(profile.id)
        defer { launchingProfileIDs.remove(profile.id) }
        do {
            let output = try await runtimeModel.runProcess(
                runtimeModel.serviceManagerPath,
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
            message = result.port.map {
                "\(home.label) · \(profile.name) 已在端口 \($0) 启动"
            } ?? "\(home.label) · \(profile.name) 已启动"
            error = nil
            await refresh()
            await runtimeModel.refreshAll()
        } catch {
            self.error = runtimeModel.clean(error.localizedDescription)
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: expanded(path), isDirectory: true)
        ])
    }

    func restart(home: DshHomeCatalogItem, instance: DshRunningProfileCatalogItem, port: Int) async {
        let key = "restart:\(instance.id)"
        guard !launchingProfileIDs.contains(key) else { return }
        launchingProfileIDs.insert(key)
        defer { launchingProfileIDs.remove(key) }
        await refresh()
        guard error == nil, catalog?.homes.first(where: { $0.id == home.id })?
            .runningProfiles.contains(where: { $0.pid == instance.pid && $0.profile == instance.profile && $0.ports.contains(port) }) == true else {
            error = "实例已变化，未执行重启。请查看刷新后的实例。"
            return
        }
        do {
            _ = try await runtimeModel.runProcess(runtimeModel.serviceManagerPath,
                ["dsh-web", "restart", "--port", String(port)], timeout: 120)
            message = "\(home.label) · \(instance.profile) 已重启"
            await refresh()
        } catch { self.error = runtimeModel.clean(error.localizedDescription) }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        message = "已复制"
    }

    func open(port: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        NSWorkspace.shared.open(url)
    }

    func selectHome(_ id: String) {
        selectionID = "home:\(id)"
    }

    private func expanded(_ value: String) -> String {
        (value as NSString).expandingTildeInPath
    }

    private func containsSelection(_ selectionID: String?, catalog: DshRuntimeCatalog) -> Bool {
        guard let selectionID else { return false }
        return catalog.homes.contains(where: { $0.selectionID == selectionID })
            || catalog.homes.flatMap(\.profiles).contains(where: { "profile:\($0.id)" == selectionID })
            || catalog.runtimes.contains(where: { $0.selectionID == selectionID })
    }
}
