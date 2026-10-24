import AppKit
import Combine
import SwiftUI

struct HarvisPermissionsAndProfileView: View {
    private enum SettingsPage: Hashable {
        case permissions
        case personalName
    }

    @ObservedObject private var model: HarvisRuntimeModel
    @ObservedObject private var preferences: HarvisBarPreferences
    @ObservedObject private var accessPreferences: HarvisAccessPreferences
    @ObservedObject private var permissionCenter: HarvisPermissionCenter

    let isFirstLaunch: Bool
    let onContinue: () -> Void

    @State private var displayNameDraft = "HarvisBar"
    @State private var displayNameError: String?
    @State private var isRefreshingProviders = false
    @State private var selectedPage: SettingsPage = .permissions
    @State private var automationExpanded = false
    @State private var profilePathExpanded = false
    @FocusState private var displayNameFocused: Bool

    private var theme: HarvisTheme { model.theme }

    init(
        model: HarvisRuntimeModel,
        preferences: HarvisBarPreferences = .shared,
        permissionCenter: HarvisPermissionCenter,
        isFirstLaunch: Bool,
        onContinue: @escaping () -> Void
    ) {
        _model = ObservedObject(wrappedValue: model)
        _preferences = ObservedObject(wrappedValue: preferences)
        _accessPreferences = ObservedObject(wrappedValue: model.accessPreferences)
        _permissionCenter = ObservedObject(wrappedValue: permissionCenter)
        self.isFirstLaunch = isFirstLaunch
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            settingsPagePicker
            Divider().overlay(theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if selectedPage == .permissions {
                        permissionsSection
                        additionalAccessSection
                    } else {
                        displayNameSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isFirstLaunch {
                firstLaunchFooter
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(theme.background)
        .foregroundColor(theme.text)
        .tint(theme.accent)
        .preferredColorScheme(theme.preferredColorScheme)
        .onAppear {
            displayNameDraft = preferences.displayName
            permissionCenter.refreshStatus()
        }
        .onChange(of: preferences.displayName) { newValue in
            if !displayNameFocused {
                displayNameDraft = newValue
            }
        }
        .onChange(of: displayNameDraft) { _ in
            displayNameError = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionCenter.refreshStatus()
        }
        .accessibilityIdentifier("harvis.permissions.window")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "hand.raised.square")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 42, height: 42)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("权限与个性化")
                    .font(.system(size: 20, weight: .semibold))
                Text("按需要开启权限；基本功能可以先用。授权由 macOS 管理。")
                    .font(.subheadline)
                    .foregroundColor(theme.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                permissionCenter.refreshStatus()
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("只读取 macOS 提供的权限状态，不会弹出授权请求")
            .accessibilityIdentifier("harvis.permissions.refresh-status")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.surface.opacity(0.72))
    }

    private var settingsPagePicker: some View {
        Picker("设置页面", selection: $selectedPage) {
            Text("权限").tag(SettingsPage.permissions)
            Text("个人名称").tag(SettingsPage.personalName)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.background)
        .accessibilityIdentifier("harvis.permissions.page-picker")
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(
                "系统权限",
                detail: "仅在使用对应功能时开启；每项都可稍后设置。"
            )
            .padding(.bottom, 10)

            appIdentityRow
            if let actionError = permissionCenter.actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(Color(hex: 0xB42318))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("harvis.permissions.action-error")
            }
            Divider().overlay(theme.line)

            workspacePermissionRow
            Divider().overlay(theme.line)

            accessibilityPermissionRow
            Divider().overlay(theme.line)

            screenRecordingPermissionRow
            Divider().overlay(theme.line)

            fullDiskAccessPermissionRow
            Divider().overlay(theme.line)

            automationPermissionRow
        }
        .padding(16)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line))
    }

    private var appIdentityRow: some View {
        HStack(spacing: 12) {
            Image(nsImage: permissionCenter.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)
                .help("拖动此图标到系统设置的权限应用列表")
                .onDrag {
                    NSItemProvider(object: permissionCenter.appURL as NSURL)
                }
                .accessibilityLabel("HarvisBar 应用图标，可拖入系统权限列表")

            VStack(alignment: .leading, spacing: 3) {
                Text("HarvisBar.app")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("个人名称只用于菜单栏和窗口；系统设置中仍显示 HarvisBar。若列表没有它，可将图标拖入权限列表。")
                    .font(.caption)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("在 Finder 显示") {
                permissionCenter.revealAppInFinder()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("harvis.permissions.reveal-app")
        }
        .padding(.bottom, 12)
    }

    private var workspacePermissionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("工作区访问")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    statusLabel(workspaceStatus, color: workspaceStatusColor)
                }

                Text("选择工作区并显式验证。检查通过后启用工作区和配置目录的后台读取，可随时关闭。验证只检查这两处路径的写入能力，不代表已获完全磁盘访问。")
                    .font(.caption)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("当前工作区")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(theme.muted)
                    Text(model.workspaceRoot.isEmpty ? "尚未选择" : model.workspaceRoot)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.workspaceRoot)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("选择文件夹…", action: chooseWorkspace)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("harvis.permissions.workspace.choose")

                    Button {
                        Task { await model.refreshPermissionProbe(force: true) }
                    } label: {
                        if model.isPermissionProbeRefreshing {
                            ProgressView().controlSize(.small)
                            Text("验证中…")
                        } else {
                            Label("验证并启用", systemImage: "checkmark.magnifyingglass")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isPermissionProbeRefreshing || model.workspaceRoot.isEmpty)
                    .accessibilityIdentifier("harvis.permissions.workspace.verify")
                }

                Toggle(isOn: workspaceAccessBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("后台读取所选工作区")
                            .font(.system(size: 13, weight: .medium))
                        Text("开启后允许状态栏和任务进度周期读取此工作区与配置目录；关闭后停止这两类周期读取。其他功能仍按各自设置读取。此选择不会授予 macOS 系统权限。")
                            .font(.caption)
                            .foregroundColor(theme.muted)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!workspaceAccessScopeConfigured)
                .accessibilityIdentifier("harvis.permissions.workspace.background-access")

                if let workspaceNotice = model.permissionProbeFailureMessage
                    ?? model.workspaceAccessPauseReason {
                    Label(
                        workspaceNotice,
                        systemImage: model.permissionProbeFailureMessage == nil
                            ? "pause.circle.fill" : "exclamationmark.triangle.fill"
                    )
                        .font(.caption)
                        .foregroundColor(theme.isDark ? Color(hex: 0xF4C777) : Color(hex: 0x8A4B00))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("harvis.permissions.workspace.notice")
                }

                DisclosureGroup(isExpanded: $profilePathExpanded) {
                    Text(model.profileRoot.isEmpty ? "尚未设置配置目录" : model.profileRoot)
                        .font(.caption.monospaced())
                        .foregroundColor(theme.muted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(model.profileRoot)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } label: {
                    Text("查看配置目录")
                        .font(.caption.weight(.medium))
                }
                .accessibilityIdentifier("harvis.permissions.workspace.profile-path")
            }
        }
        .padding(.vertical, 11)
    }

    private var accessibilityPermissionRow: some View {
        permissionRow(
            icon: "cursorarrow.and.square.on.square.dashed",
            title: "辅助功能",
            detail: "控制其他 App，并读取其窗口位置；仅在需要窗口控制时开启。",
            status: permissionCenter.accessibilityGranted ? "已允许" : "未允许",
            statusColor: permissionCenter.accessibilityGranted ? theme.positive : theme.muted
        ) {
            HStack(spacing: 8) {
                if !permissionCenter.accessibilityGranted {
                    Button("请求辅助功能…") {
                        permissionCenter.requestAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("harvis.permissions.accessibility.request")
                }
                Button("打开系统设置") {
                    permissionCenter.openSettings(.accessibility)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("harvis.permissions.accessibility.settings")
            }
        }
    }

    private var screenRecordingPermissionRow: some View {
        permissionRow(
            icon: "rectangle.dashed.and.camera",
            title: "屏幕录制",
            detail: "仅在启用截图识别时需要。可先跳过，稍后在系统设置中开启。",
            status: permissionCenter.screenRecordingGranted ? "已允许" : "未允许",
            statusColor: permissionCenter.screenRecordingGranted ? theme.positive : theme.muted
        ) {
            HStack(spacing: 8) {
                if !permissionCenter.screenRecordingGranted {
                    Button("请求屏幕录制…") {
                        permissionCenter.requestScreenRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("harvis.permissions.screen-recording.request")
                }
                Button("打开系统设置") {
                    permissionCenter.openSettings(.screenRecording)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("harvis.permissions.screen-recording.settings")
            }
        }
    }

    private var fullDiskAccessPermissionRow: some View {
        permissionRow(
            icon: "lock.shield",
            title: "完全磁盘访问",
            detail: "跨受保护目录读取时才需要。HarvisBar 不会自行判断是否已授权，请在系统设置中确认。",
            status: "在系统设置中确认",
            statusColor: theme.muted
        ) {
            Button("打开系统设置") {
                permissionCenter.openSettings(.fullDiskAccess)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("harvis.permissions.full-disk-access.settings")
        }
    }

    private var automationPermissionRow: some View {
        DisclosureGroup(isExpanded: $automationExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("首次控制某个目标 App 时，macOS 会单独询问。只有实际使用自动化时才需要允许；目标 App 可能需要分别确认。")
                    .font(.caption)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开自动化设置") {
                    permissionCenter.openSettings(.automation)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("harvis.permissions.automation.settings")
            }
            .padding(.leading, 34)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "applescript")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动化")
                        .font(.system(size: 13, weight: .semibold))
                    Text("首次控制目标 App 时由 macOS 单独询问")
                        .font(.caption)
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 8)
                Text("按目标 App")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.surfaceAlt)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 11)
        .accessibilityIdentifier("harvis.permissions.automation.disclosure")
    }

    private var additionalAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                "额外读取范围",
                detail: "这些选择会立即保存。启用后，HarvisBar 可能在后台读取相应来源；macOS 可能询问文件夹访问。"
            )

            Toggle(isOn: $accessPreferences.externalHomeDiscoveryEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("发现外部 Codex 启动器")
                        .font(.system(size: 13, weight: .medium))
                    Text("读取自定义启动器位置中的 Codex 配置元数据。开启后可能开始后台发现。默认关闭。")
                        .font(.caption)
                        .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("harvis.permissions.external-home-discovery")

            Divider().overlay(theme.line)

            Toggle(isOn: $accessPreferences.historicalProjectAccessEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("读取项目历史信息")
                        .font(.system(size: 13, weight: .medium))
                    Text("读取项目会话的计划、摘要和指标；访问范围可能超出当前工作区。默认关闭。")
                        .font(.caption)
                        .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("harvis.permissions.historical-project-access")

            HStack {
                Text("开启后可能触发后台读取。")
                    .font(.caption)
                    .foregroundColor(theme.muted)
                Spacer(minLength: 8)
                Button {
                    guard !isRefreshingProviders, !HarvisAppMode.isPermissionFixture else { return }
                    isRefreshingProviders = true
                    Task { @MainActor in
                        await model.refreshManagedChatProviders()
                        isRefreshingProviders = false
                    }
                } label: {
                    if isRefreshingProviders {
                        ProgressView().controlSize(.small)
                        Text("刷新中…")
                    } else {
                        Label("按当前选择刷新", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshingProviders || HarvisAppMode.isPermissionFixture)
                .accessibilityIdentifier("harvis.permissions.refresh-providers")
            }
        }
        .padding(16)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line))
    }

    private var displayNameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                "个人显示名称",
                detail: "显示在菜单栏、菜单标题和桌面窗口中；系统权限列表仍显示 HarvisBar。"
            )

            HStack(spacing: 10) {
                TextField("HarvisBar", text: $displayNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($displayNameFocused)
                    .onSubmit(saveDisplayName)
                    .accessibilityIdentifier("harvis.permissions.display-name")

                Text("\(displayNameDraft.count)/40")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(theme.muted)
                    .frame(minWidth: 42, alignment: .trailing)

                Button("保存") { saveDisplayName() }
                    .buttonStyle(.borderedProminent)
                    .disabled(displayNameDraft == preferences.displayName)
                    .accessibilityIdentifier("harvis.permissions.display-name.save")

                Button("恢复默认") {
                    preferences.resetDisplayName()
                    displayNameDraft = preferences.displayName
                    displayNameError = nil
                }
                .buttonStyle(.bordered)
                .disabled(preferences.displayName == HarvisBarPreferences.defaultDisplayName)
                .accessibilityIdentifier("harvis.permissions.display-name.reset")
            }

            if let displayNameError {
                Label(displayNameError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(Color(hex: 0xB42318))
                    .accessibilityIdentifier("harvis.permissions.display-name.error")
            } else {
                Text("支持中文与 emoji，最多 40 个字符。")
                    .font(.caption)
                    .foregroundColor(theme.muted)
            }
        }
        .padding(16)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line))
    }

    private var firstLaunchFooter: some View {
        HStack(spacing: 12) {
            Label("权限可以稍后设置；继续不会授予任何权限。", systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(theme.muted)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("稍后设置", action: onContinue)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("harvis.permissions.guide.later")

            Button("开始使用基本功能", action: onContinue)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("harvis.permissions.guide.continue")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.surface)
        .overlay(alignment: .top) { Divider().overlay(theme.line) }
        .accessibilityIdentifier("harvis.permissions.guide.footer")
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        status: String,
        statusColor: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    statusLabel(status, color: statusColor)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundColor(theme.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(.vertical, 11)
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundColor(color)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var workspaceStatus: String {
        if model.isPermissionProbeRefreshing { return "验证中" }
        switch model.permissionVerificationState {
        case .unverified: return "尚未验证"
        case .verifiedReady: return "路径检查通过"
        case .verifiedBlocked: return "路径写入受限"
        case .stale: return "需要重新验证"
        }
    }

    private var workspaceStatusColor: Color {
        switch model.permissionVerificationState {
        case .verifiedReady: return theme.positive
        case .verifiedBlocked: return Color(hex: 0xB42318)
        case .unverified, .stale: return theme.muted
        }
    }

    private var workspaceAccessBinding: Binding<Bool> {
        Binding(
            get: {
                guard workspaceAccessScopeConfigured else { return false }
                return accessPreferences.allowsWorkspaceAccess(
                    workspaceRoot: model.workspaceRoot,
                    profileRoot: model.profileRoot
                )
            },
            set: { allowed in
                if allowed {
                    guard workspaceAccessScopeConfigured else { return }
                    accessPreferences.allowWorkspaceAccess(
                        workspaceRoot: model.workspaceRoot,
                        profileRoot: model.profileRoot
                    )
                } else {
                    accessPreferences.revokeWorkspaceAccess()
                }
            }
        )
    }

    private var workspaceAccessScopeConfigured: Bool {
        !model.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.profileRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "选择工作区文件夹"
        panel.message = "选择 HarvisBar 要使用的工作区。选择文件夹只会更新路径；点击“验证并启用”后才会进行写入检查，并在通过后启用后台读取。"
        panel.prompt = "选择工作区"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !model.workspaceRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: model.workspaceRoot, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.workspaceRoot = url.path
    }

    private func saveDisplayName() {
        displayNameError = nil
        do {
            try preferences.setDisplayName(displayNameDraft)
            displayNameDraft = preferences.displayName
            displayNameFocused = false
        } catch {
            displayNameError = error.localizedDescription
        }
    }
}

@MainActor
final class HarvisPermissionsAndProfileWindowController: NSObject, NSWindowDelegate {
    static let shared = HarvisPermissionsAndProfileWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<HarvisPermissionsAndProfileView>?
    private var activeModel: HarvisRuntimeModel?
    private var activePreferences: HarvisBarPreferences?
    private var activePermissionCenter: HarvisPermissionCenter?
    private var displayNameSubscription: AnyCancellable?
    private var isFirstLaunchWindow = false
    private var firstLaunchCompleted = false

    func show(
        model: HarvisRuntimeModel,
        preferences: HarvisBarPreferences = .shared,
        permissionCenter: HarvisPermissionCenter? = nil,
        isFirstLaunch: Bool = false
    ) {
        let effectivePermissionCenter: HarvisPermissionCenter
        if let supplied = permissionCenter ?? activePermissionCenter {
            effectivePermissionCenter = supplied
        } else {
#if DEBUG
            effectivePermissionCenter = HarvisAppMode.isPermissionFixture
                ? HarvisPermissionCenter(environment: .fixture) : HarvisPermissionCenter()
#else
            effectivePermissionCenter = HarvisPermissionCenter()
#endif
        }
        activeModel = model
        activePreferences = preferences
        activePermissionCenter = effectivePermissionCenter
        isFirstLaunchWindow = isFirstLaunch || !model.accessPreferences.hasSeenPermissionGuide
        firstLaunchCompleted = !isFirstLaunchWindow

        let content = HarvisPermissionsAndProfileView(
            model: model,
            preferences: preferences,
            permissionCenter: effectivePermissionCenter,
            isFirstLaunch: isFirstLaunchWindow,
            onContinue: { [weak self] in self?.finishFirstLaunch(closeWindow: true) }
        )

        if let hostingController {
            hostingController.rootView = content
        } else {
            let hostingController = NSHostingController(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = Self.windowTitle(displayName: preferences.displayName)
            window.minSize = NSSize(width: 720, height: 540)
            window.isReleasedWhenClosed = false
            window.contentViewController = hostingController
            window.delegate = self
            window.center()
            self.hostingController = hostingController
            self.window = window
        }

        displayNameSubscription?.cancel()
        displayNameSubscription = preferences.$displayName.sink { [weak self] displayName in
            Task { @MainActor in
                self?.window?.title = Self.windowTitle(displayName: displayName)
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func windowTitle(displayName: String) -> String {
        "\(displayName) · 权限与个性化"
    }

    private func finishFirstLaunch(closeWindow: Bool) {
        guard isFirstLaunchWindow, !firstLaunchCompleted, let activeModel else { return }
        firstLaunchCompleted = true
        isFirstLaunchWindow = false
        activeModel.accessPreferences.markPermissionGuideSeen()
        activeModel.start()
        if closeWindow { window?.close() }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.finishFirstLaunch(closeWindow: false)
            self.window = nil
            self.hostingController = nil
            self.displayNameSubscription = nil
            self.activeModel = nil
            self.activePreferences = nil
            self.activePermissionCenter = nil
        }
    }
}
