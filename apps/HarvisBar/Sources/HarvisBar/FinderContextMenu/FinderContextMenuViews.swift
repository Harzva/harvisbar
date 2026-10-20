import AppKit
import SwiftUI

struct FinderContextMenuPopoverSection: View {
    @EnvironmentObject private var runtimeModel: HarvisRuntimeModel
    @StateObject private var manager = FinderContextMenuManagerModel.shared

    private var theme: HarvisTheme { runtimeModel.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "contextualmenu.and.cursorarrow")
                    .foregroundColor(stateColor)
                Text("Finder 右键菜单")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text(manager.state.title)
                    .font(.caption2.bold())
                    .foregroundColor(stateColor)
            }

            HStack(spacing: 5) {
                Text("/ + \(manager.mountedVolumeCount) 个挂载卷")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                Spacer(minLength: 4)
                if let version = manager.installedVersion {
                    Text("v\(version)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
            }

            Button {
                FinderContextMenuWindowController.shared.show(model: runtimeModel)
            } label: {
                Label("管理增强菜单", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .help("浏览、重载和更新 Finder 增强右键菜单")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line.opacity(0.86)))
        .onAppear { manager.refresh() }
    }

    private var stateColor: Color {
        switch manager.state {
        case .enabled: return theme.positive
        case .checking: return theme.accent
        case .disabled: return Color(hex: 0xD97706)
        case .missing, .failed: return Color(hex: 0xDC2626)
        }
    }
}

struct FinderContextMenuManagerView: View {
    @EnvironmentObject private var runtimeModel: HarvisRuntimeModel
    @StateObject private var manager = FinderContextMenuManagerModel.shared

    private var theme: HarvisTheme { runtimeModel.theme }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    coverageCard
                    actionInventory
                    managementCard
                    if let message = manager.lastMessage {
                        feedbackCard(
                            message,
                            color: theme.positive,
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    if let error = manager.lastError {
                        feedbackCard(
                            error,
                            color: Color(hex: 0xDC2626),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 660)
        .background(theme.background)
        .foregroundColor(theme.text)
        .tint(theme.accent)
        .preferredColorScheme(theme.preferredColorScheme)
        .onAppear { manager.refresh() }
        .toolbar {
            Button {
                manager.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(manager.isBusy)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "contextualmenu.and.cursorarrow")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(theme.accent)
                .frame(width: 42, height: 42)
                .background(theme.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Finder 右键菜单管理")
                    .font(.title3.bold())
                Text("浏览增强动作、检查覆盖范围并重新加载扩展")
                    .font(.caption)
                    .foregroundColor(theme.muted)
            }
            Spacer()
            Label(manager.state.title, systemImage: manager.state.systemImage)
                .font(.caption.bold())
                .foregroundColor(stateColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(stateColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(18)
        .background(theme.surface)
    }

    private var coverageCard: some View {
        managerCard(title: "覆盖范围", systemImage: "externaldrive.connected.to.line.below") {
            HStack(alignment: .top, spacing: 18) {
                metric(title: "根目录", value: "/")
                metric(title: "挂载卷", value: "\(manager.mountedVolumeCount)")
                metric(title: "版本", value: manager.installedVersion ?? "未安装")
                Spacer()
            }
            Text(manager.manifest.scope?.summary ?? "覆盖根目录与全部挂载卷。")
                .font(.callout)
            ForEach(manager.manifest.scope?.limitations ?? [], id: \.self) { limitation in
                Label(limitation, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(theme.muted)
            }
        }
    }

    private var actionInventory: some View {
        managerCard(title: "增强动作", systemImage: "list.bullet.rectangle") {
            ForEach(placementOrder, id: \.self) { placement in
                let actions = manager.manifest.actions.filter { $0.placement == placement }
                if !actions.isEmpty {
                    Text(placementTitle(placement))
                        .font(.caption.bold())
                        .foregroundColor(theme.muted)
                        .padding(.top, 2)
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(actions) { action in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: action.systemImage)
                                    .foregroundColor(theme.accent)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                        .font(.callout.bold())
                                    Text(action.description)
                                        .font(.caption)
                                        .foregroundColor(theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(theme.surfaceAlt.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.line.opacity(0.7))
                            )
                        }
                    }
                }
            }
        }
    }

    private var managementCard: some View {
        managerCard(title: "管理与更新", systemImage: "slider.horizontal.3") {
            HStack(spacing: 8) {
                managerButton("启用并重载", systemImage: "arrow.clockwise.circle") {
                    manager.enableAndReload()
                }
                .disabled(manager.isBusy || manager.state == .missing)
                managerButton("从源码更新", systemImage: "hammer") {
                    manager.installOrUpdateFromSource()
                }
                .disabled(manager.isBusy || manager.sourceRoot == nil)
                managerButton("扩展设置", systemImage: "switch.2") {
                    manager.openFinderExtensionSettings()
                }
            }

            HStack(spacing: 8) {
                managerButton("显示应用", systemImage: "app.dashed") {
                    manager.revealInstalledApplication()
                }
                .disabled(manager.state == .missing)
                managerButton("显示源码", systemImage: "folder") {
                    manager.revealSourceRoot()
                }
                .disabled(manager.sourceRoot == nil)
                managerButton("选择源码…", systemImage: "folder.badge.gearshape") {
                    manager.chooseSourceRoot()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("扩展：\(FinderContextMenuManagerModel.extensionID)")
                Text("源码：\(manager.sourceRoot ?? "未定位，可手动选择")")
            }
            .font(.caption.monospaced())
            .foregroundColor(theme.muted)
            .textSelection(.enabled)
        }
    }

    private var stateColor: Color {
        switch manager.state {
        case .enabled: return theme.positive
        case .checking: return theme.accent
        case .disabled: return Color(hex: 0xD97706)
        case .missing, .failed: return Color(hex: 0xDC2626)
        }
    }

    private var placementOrder: [String] {
        ["toolbar", "selected-items", "container"]
    }

    private func placementTitle(_ placement: String) -> String {
        switch placement {
        case "toolbar": return "Finder 工具栏"
        case "selected-items": return "选中文件或文件夹"
        case "container": return "文件夹空白区域"
        default: return placement
        }
    }

    private func managerCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line))
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(theme.muted)
            Text(value)
                .font(.callout.bold().monospacedDigit())
        }
    }

    private func managerButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func feedbackCard(
        _ message: String,
        color: Color,
        systemImage: String
    ) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundColor(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}

@MainActor
final class FinderContextMenuWindowController: NSObject, NSWindowDelegate {
    static let shared = FinderContextMenuWindowController()

    private var window: NSWindow?

    func show(model: HarvisRuntimeModel) {
        if window == nil {
            let root = FinderContextMenuManagerView()
                .environmentObject(model)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Finder 右键菜单管理"
            window.minSize = NSSize(width: 720, height: 560)
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.delegate = self
            window.center()
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}
