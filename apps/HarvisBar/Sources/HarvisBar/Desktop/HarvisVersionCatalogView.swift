import AppKit
import HarvisVersionCore
import SwiftUI

enum HarvisVersionCatalogSection: String, CaseIterable, Identifiable {
    case overview
    case installedApp
    case stableHelper
    case sourceWorktree
    case localWorktrees

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .installedApp: return "已安装 App"
        case .stableHelper: return "稳定 Helper"
        case .sourceWorktree: return "源码 Worktree"
        case .localWorktrees: return "本地 Worktrees"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "身份与对齐"
        case .installedApp: return "版本与构建来源"
        case .stableHelper: return "绑定与文件校验"
        case .sourceWorktree: return "Git 与远程仓库"
        case .localWorktrees: return "关联工作区"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .installedApp: return "app.badge.checkmark"
        case .stableHelper: return "wrench.and.screwdriver"
        case .sourceWorktree: return "arrow.triangle.branch"
        case .localWorktrees: return "rectangle.3.group"
        }
    }

    var accessibilityIdentifier: String {
        "harvis-version-sidebar-\(identifierSuffix)"
    }

    var detailAccessibilityIdentifier: String {
        "harvis-version-detail-\(identifierSuffix)"
    }

    private var identifierSuffix: String {
        switch self {
        case .overview: return "overview"
        case .installedApp: return "installed-app"
        case .stableHelper: return "stable-helper"
        case .sourceWorktree: return "source-worktree"
        case .localWorktrees: return "local-worktrees"
        }
    }
}

enum HarvisVersionClipboardKind: String {
    case source
    case commit
}

@MainActor
struct HarvisVersionUIEffects {
    var chooseSourceDirectory: () -> String?
    var copy: (_ rawValue: String, _ kind: HarvisVersionClipboardKind) -> Void
    var reveal: (_ canonicalURL: URL) -> Void
    var openGitHub: (_ sanitizedURL: URL) -> Void

    static let live = HarvisVersionUIEffects(
        chooseSourceDirectory: {
            let panel = NSOpenPanel()
            panel.title = "选择 Harvis 源码目录"
            panel.message = "可以选择 Harvis 仓库根目录或其中的子目录。"
            panel.prompt = "选择"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = false
            return panel.runModal() == .OK ? panel.url?.path : nil
        },
        copy: { value, _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        },
        reveal: { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        },
        openGitHub: { url in
            NSWorkspace.shared.open(url)
        }
    )
}

struct HarvisVersionCatalogView: View {
    @StateObject private var model: HarvisVersionCatalogModel
    @State private var selectedSection: HarvisVersionCatalogSection = .overview

    private let effects: HarvisVersionUIEffects
    private let closeAction: @MainActor () -> Void

    init(
        model: HarvisVersionCatalogModel,
        effects: HarvisVersionUIEffects,
        closeAction: @escaping @MainActor () -> Void
    ) {
        _model = StateObject(wrappedValue: model)
        self.effects = effects
        self.closeAction = closeAction
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("harvis-version-content-root")
        .task {
            model.refresh()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Harvis 版本管理")
                        .font(.headline)
                    Text(sidebarSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button {
                    model.refresh()
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("重新读取 App、API、Helper 与源码 Git 状态")
                .accessibilityLabel("刷新版本与源码")
                .accessibilityValue(model.isRefreshing ? "正在刷新" : "可刷新")
                .accessibilityIdentifier("harvis-version-refresh")
                .disabled(model.isRefreshing)
            }
            .padding(12)

            Divider()

            List(selection: $selectedSection) {
                ForEach(HarvisVersionCatalogSection.allCases) { section in
                    HarvisVersionSidebarRow(
                        section: section,
                        status: sidebarStatus(for: section)
                    )
                    .tag(section)
                    .accessibilityIdentifier(section.accessibilityIdentifier)
                }
            }
            .listStyle(.sidebar)

            if let error = model.error, !error.isEmpty {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("harvis-version-local-error")
            } else if let message = model.message, !message.isEmpty {
                Divider()
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("harvis-version-local-message")
            }

            Divider()
            Button(action: closeAction) {
                Label("关闭", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("harvis-version-close")
            .padding(10)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .overview:
            overviewDetail
        case .installedApp:
            installedAppDetail
        case .stableHelper:
            stableHelperDetail
        case .sourceWorktree:
            sourceDetail
        case .localWorktrees:
            worktreesDetail
        }
    }

    private var overviewDetail: some View {
        detailScroll(section: .overview) {
            detailHeader(
                title: "运行身份概览",
                subtitle: "把正在运行的 App、API、Helper、构建收据与本地源码分开核验。",
                systemImage: "checkmark.shield"
            )

            overviewStatusGrid

            statusCard(
                title: "Alignment",
                icon: alignmentIcon,
                identifier: "alignment",
                status: model.alignment.rawValue,
                summary: alignmentSummary
            )

            if model.source.status == .unbound {
                chooseSourceButton(identifier: "harvis-version-source-choose")
            } else {
                sourceSelectionActions(includeClear: true)
            }
        }
    }

    private var installedAppDetail: some View {
        detailScroll(section: .installedApp) {
            detailHeader(
                title: "已安装 Harvis App",
                subtitle: "App identity 与 bundle receipt 分开呈现；收据损坏不会抹掉 App 身份。",
                systemImage: "app.badge.checkmark"
            )

            fieldGroup("App Identity") {
                fieldRow("Version", value: model.appIdentity.version, id: "harvis-version-field-app-version")
                fieldRow("Bundle ID", value: model.appIdentity.bundleIdentifier, id: "harvis-version-field-app-bundle-id")
                fieldRow("API", value: model.apiVersion ?? "unavailable", id: "harvis-version-field-api-version")
            }

            fieldGroup("Build Provenance") {
                fieldRow("Receipt", value: receiptSchema, id: "harvis-version-field-receipt-schema")
                fieldRow("Source commit", value: installedCommit, id: "harvis-version-field-installed-source-commit", copyKind: .commit)
                fieldRow("Source tree", value: installedTree, id: "harvis-version-field-installed-source-tree")
                fieldRow("Provenance SHA", value: provenanceSHA, id: "harvis-version-field-provenance-sha256")
            }
        }
    }

    @ViewBuilder
    private var overviewStatusGrid: some View {
        HarvisVersionCardLayout {
            statusCard(
                title: "App",
                icon: "app",
                identifier: "app",
                status: appStatus,
                summary: model.appIdentity.version
            )
            statusCard(
                title: "API",
                icon: "point.3.connected.trianglepath.dotted",
                identifier: "api",
                status: apiStatus,
                summary: model.apiVersion ?? "当前不可达"
            )
            statusCard(
                title: "Helper",
                icon: "wrench.and.screwdriver",
                identifier: "helper",
                status: helperStatus,
                summary: helperSummary
            )
            statusCard(
                title: "Provenance",
                icon: "checkmark.seal",
                identifier: "provenance",
                status: provenanceStatus,
                summary: model.receipt.receipt.map {
                    shortObjectID($0.provenance.sourceCommit)
                } ?? "收据不可用"
            )
            statusCard(
                title: "Source",
                icon: "arrow.triangle.branch",
                identifier: "source",
                status: model.source.status.rawValue,
                summary: sourceSummary
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stableHelperDetail: some View {
        detailScroll(section: .stableHelper) {
            detailHeader(
                title: "稳定 Helper",
                subtitle: "同时核验 LaunchAgent 绑定、helper 文件与 bundle receipt，不用 wrapper 充当版本依据。",
                systemImage: "wrench.and.screwdriver"
            )

            fieldGroup("Artifact Roles") {
                fieldRow("Wrapper", value: "context-only:scripts/harvis", id: "harvis-version-field-wrapper-role")
                fieldRow("Bundled runtime", value: bundledRuntimeValue, id: "harvis-version-field-bundled-runtime")
            }

            fieldGroup("Stable Helper") {
                fieldRow("Path", value: visibleEscape(model.stableHelperPath), id: "harvis-version-field-stable-helper-path")
                fieldRow("Size", value: model.helper?.sizeBytes.map(String.init) ?? "unavailable", id: "harvis-version-field-stable-helper-size")
                fieldRow("SHA-256", value: model.helper?.sha256 ?? "unavailable", id: "harvis-version-field-stable-helper-sha256")
                fieldRow("HTTP binding", value: model.helper?.httpLaunchBindingStatus.rawValue ?? "unavailable", id: "harvis-version-field-launch-http")
                fieldRow("Tick binding", value: model.helper?.tickLaunchBindingStatus.rawValue ?? "unavailable", id: "harvis-version-field-launch-tick")
                fieldRow("Helper file", value: model.helper?.helperFileStatus.rawValue ?? "unavailable", id: "harvis-version-field-helper-file-status")
                fieldRow("Receipt match", value: model.helper?.receiptMatchStatus.rawValue ?? "notEvaluated", id: "harvis-version-field-receipt-match-status")
            }
        }
    }

    private var sourceDetail: some View {
        detailScroll(section: .sourceWorktree) {
            detailHeader(
                title: "源码 Worktree",
                subtitle: "只读取已选择的 Harvis 仓库；不会把 DSH pluginRoot 或当前工作目录当作源码。",
                systemImage: "arrow.triangle.branch"
            )

            fieldGroup("Source Authority") {
                fieldRow("Root", value: sourceRootValue, id: "harvis-version-field-source-root")
                fieldRow("HEAD state", value: sourceHeadState, id: "harvis-version-field-source-head-state")
                fieldRow("Branch", value: sourceBranch, id: "harvis-version-field-source-branch")
                fieldRow("HEAD", value: sourceHead, id: "harvis-version-field-source-head", copyKind: sourceHead == "unavailable" || sourceHead == "unborn" ? nil : .commit)
                fieldRow("Dirty", value: sourceDirtyCount, id: "harvis-version-field-source-dirty-count")
                fieldRow("Upstream", value: sourceUpstream, id: "harvis-version-field-source-upstream")
                fieldRow("Ahead", value: sourceAhead, id: "harvis-version-field-source-ahead")
                fieldRow("Behind", value: sourceBehind, id: "harvis-version-field-source-behind")
                fieldRow("Observed", value: sourceObservedAt, id: "harvis-version-field-source-observed-at")
                fieldRow("Snapshot stale", value: sourceTrackingStale, id: "harvis-version-field-source-tracking-stale")
                fieldRow("Snapshot incomplete", value: sourceTrackingIncomplete, id: "harvis-version-field-source-tracking-incomplete")
                fieldRow("Remotes", value: String(sourceRemotes.count), id: "harvis-version-field-remote-count")
            }

            if model.source.status == .ready,
               model.source.git?.trackingSnapshotMayBeStale == true {
                Text("本地快照，可能陈旧")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityValue("本地快照，可能陈旧")
                    .accessibilityIdentifier("harvis-version-local-snapshot-notice")
            }

            sourceSelectionActions(includeClear: true)

            if model.source.status == .ready {
                fieldGroup("Remotes") {
                    if sourceRemotes.isEmpty {
                        Text("未配置远程仓库")
                            .foregroundStyle(.secondary)
                            .accessibilityValue("未配置远程仓库")
                            .accessibilityIdentifier("harvis-version-remote-empty")
                    } else {
                        ForEach(Array(sourceRemotes.enumerated()), id: \.offset) { index, remote in
                            remoteRow(remote, index: index)
                        }
                    }
                }
            }
        }
    }

    private var worktreesDetail: some View {
        detailScroll(section: .localWorktrees) {
            detailHeader(
                title: "本地 Worktrees",
                subtitle: "包含 attached、detached、unborn 与 bare 状态；路径按 Git 记录展示。",
                systemImage: "rectangle.3.group"
            )

            fieldRow(
                "Worktree count",
                value: String(sourceWorktrees.count),
                id: "harvis-version-field-worktree-count"
            )

            if sourceWorktrees.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("没有可显示的 Worktree")
                        .font(.headline)
                    Text(model.source.status == .ready ? "Git 没有返回 worktree 条目。" : "源码就绪后会显示本地 worktree。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(Array(sourceWorktrees.enumerated()), id: \.offset) { index, worktree in
                    worktreeCard(worktree, index: index)
                }
            }
        }
    }

    private func detailScroll<Content: View>(
        section: HarvisVersionCatalogSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(section.detailAccessibilityIdentifier)
    }

    private func detailHeader(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusCard(
        title: String,
        icon: String,
        identifier: String,
        status: String,
        summary: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(statusColor(status))
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(status)
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(statusColor(status))
                    .accessibilityValue(status)
                    .accessibilityIdentifier("harvis-version-card-\(identifier)-status")
            }
            Text(summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("harvis-version-card-\(identifier)")
    }

    private func fieldGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func fieldRow(
        _ label: String,
        value: String,
        id: String,
        copyKind: HarvisVersionClipboardKind? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityValue(value)
                .accessibilityIdentifier(id)
            Spacer(minLength: 6)
            if let copyKind, value != "unavailable" {
                Button {
                    effects.copy(value, copyKind)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制")
                .accessibilityLabel("复制 (label)")
                .accessibilityIdentifier("\(id)-copy")
            }
        }
        .padding(.vertical, 9)
    }

    private func chooseSourceButton(identifier: String) -> some View {
        Button {
            chooseSource()
        } label: {
            Label("选择源码目录", systemImage: "folder.badge.plus")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func sourceSelectionActions(includeClear: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            sourceActionRow(includeClear: includeClear)
                // Preserve the natural button widths so the compact fallback
                // is selected before any action label is compressed.
                .fixedSize(horizontal: true, vertical: false)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                sourceActionItems(includeClear: includeClear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private func sourceActionRow(includeClear: Bool) -> some View {
        HStack(spacing: 10) {
            sourceActionItems(includeClear: includeClear)
        }
    }

    @ViewBuilder
    private func sourceActionItems(includeClear: Bool) -> some View {
        Button {
            chooseSource()
        } label: {
            Label(model.source.status == .unbound ? "选择源码目录" : "重新选择源码", systemImage: "folder.badge.gearshape")
        }
        .accessibilityIdentifier(
            model.source.status == .unbound
                ? "harvis-version-source-choose"
                : "harvis-version-source-reselect"
        )

        if let root = validSourceRoot {
            Button {
                effects.copy(root, .source)
            } label: {
                Label("复制路径", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("harvis-version-copy-source")

            Button {
                effects.reveal(URL(fileURLWithPath: root, isDirectory: true))
            } label: {
                Label("Finder", systemImage: "folder")
            }
            .accessibilityIdentifier("harvis-version-show-source-in-finder")
        }

        if let commit = model.source.git?.headCommit {
            Button {
                effects.copy(commit, .commit)
            } label: {
                Label("复制 Commit", systemImage: "number")
            }
            .accessibilityIdentifier("harvis-version-copy-commit")
        }

        if includeClear, model.source.status != .unbound {
            Button("清除绑定", role: .destructive) {
                model.clearSource()
            }
            .accessibilityIdentifier("harvis-version-source-clear")
        }
    }

    private func chooseSource() {
        guard let path = effects.chooseSourceDirectory() else { return }
        Task {
            await model.chooseSource(path: path)
        }
    }

    private func remoteRow(_ remote: HarvisGitRemoteSummary, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            Text(remote.name)
                .font(.body.weight(.medium).monospaced())
                .accessibilityValue(visibleEscape(remote.name))
                .accessibilityIdentifier("harvis-version-remote-row-\(index)-name")
            Spacer(minLength: 8)
            if let value = remote.githubBrowseURL, let url = URL(string: value) {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityValue(value)
                    .accessibilityIdentifier("harvis-version-remote-row-\(index)-github-url")
                if index == firstSafeRemoteIndex {
                    Button {
                        effects.openGitHub(url)
                    } label: {
                        Label("GitHub", systemImage: "safari")
                    }
                    .accessibilityIdentifier("harvis-version-open-github")
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("harvis-version-remote-row-\(index)")
    }

    private func worktreeCard(_ worktree: HarvisGitWorktreeSummary, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldRow("Path", value: visibleEscape(worktree.path), id: "harvis-version-worktree-row-\(index)-path")
            fieldRow("Branch", value: worktreeBranch(worktree), id: "harvis-version-worktree-row-\(index)-branch")
            fieldRow("HEAD", value: worktreeHead(worktree), id: "harvis-version-worktree-row-\(index)-head")
            fieldRow("Flags", value: worktreeFlags(worktree), id: "harvis-version-worktree-row-\(index)-flags")
            if let reason = worktree.lockedReason, !reason.isEmpty {
                fieldRow("Locked", value: visibleEscape(reason), id: "harvis-version-worktree-row-\(index)-locked-reason")
            }
            if let reason = worktree.prunableReason, !reason.isEmpty {
                fieldRow("Prunable", value: visibleEscape(reason), id: "harvis-version-worktree-row-\(index)-prunable-reason")
            }
        }
        .padding(.horizontal, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("harvis-version-worktree-row-\(index)")
    }

    private var sidebarSummary: String {
        "App \(model.appIdentity.version) · Source \(model.source.status.rawValue)"
    }

    private func sidebarStatus(for section: HarvisVersionCatalogSection) -> String {
        switch section {
        case .overview: return model.alignment.rawValue
        case .installedApp: return appStatus
        case .stableHelper: return helperStatus
        case .sourceWorktree: return model.source.status.rawValue
        case .localWorktrees: return "\(sourceWorktrees.count)"
        }
    }

    private var appStatus: String {
        model.appIdentity.version.isEmpty ? "unavailable" : "ready"
    }

    private var apiStatus: String { model.apiVersion == nil ? "offline" : "ready" }

    private var provenanceStatus: String {
        model.receipt.status == .valid ? "ready" : model.receipt.status.rawValue
    }

    private var helperStatus: String {
        model.helper?.status.rawValue ?? "receiptUnavailable"
    }

    private var helperSummary: String {
        guard let helper = model.helper else { return "尚未完成本地校验" }
        return "bindings \(helper.httpLaunchBindingStatus.rawValue)/\(helper.tickLaunchBindingStatus.rawValue) · file \(helper.helperFileStatus.rawValue)"
    }

    private var sourceSummary: String {
        if let root = model.source.canonicalRepositoryRoot ?? model.source.selectedPath {
            return visibleEscape(root)
        }
        return "尚未绑定 Harvis 源码"
    }

    private var alignmentIcon: String {
        switch model.alignment {
        case .exact: return "equal.circle"
        case .sourceAhead: return "arrow.up.forward.circle"
        case .installedAhead: return "arrow.down.backward.circle"
        case .diverged: return "arrow.triangle.branch"
        case .missingCommit: return "questionmark.diamond"
        case .unknown: return "questionmark.circle"
        }
    }

    private var alignmentSummary: String {
        switch model.alignment {
        case .exact: return "当前源码 HEAD 与安装收据 commit 一致"
        case .sourceAhead: return "源码包含已安装 commit，并有后续本地提交"
        case .installedAhead: return "已安装 commit 位于当前源码 HEAD 之后"
        case .diverged: return "源码与已安装 commit 已分叉"
        case .missingCommit: return "本地对象库中找不到已安装 commit"
        case .unknown: return "证据不足，暂不能判断源码与安装版本关系"
        }
    }

    private var receiptSchema: String {
        model.receipt.receipt?.schemaVersion ?? "unavailable"
    }

    private var installedCommit: String {
        model.receipt.receipt?.provenance.sourceCommit ?? "unavailable"
    }

    private var installedTree: String {
        model.receipt.receipt?.provenance.sourceTree ?? "unavailable"
    }

    private var provenanceSHA: String {
        model.receipt.receipt?.provenance.sha256 ?? "unavailable"
    }

    private var bundledRuntimeValue: String {
        guard let record = model.receipt.receipt?.artifacts.runtimeRecord else {
            return "unavailable"
        }
        return "receipt:\(record.relativePath);size=\(record.sizeBytes);sha256=\(record.sha256)"
    }

    private var validSourceRoot: String? {
        guard model.source.status == .ready else { return nil }
        return model.source.canonicalRepositoryRoot
    }

    private var sourceRootValue: String {
        if let raw = model.source.canonicalRepositoryRoot ?? model.source.selectedPath {
            return visibleEscape(raw)
        }
        return "unbound"
    }

    private var sourceHeadState: String {
        model.source.git?.headState.rawValue ?? "unavailable"
    }

    private var sourceBranch: String {
        guard let git = model.source.git else { return "unavailable" }
        switch git.headState {
        case .attached, .unborn: return git.branch.map(visibleEscape) ?? "unavailable"
        case .detached: return "none"
        }
    }

    private var sourceHead: String {
        guard let git = model.source.git else { return "unavailable" }
        if git.headState == .unborn { return "unborn" }
        return git.headCommit ?? "unavailable"
    }

    private var sourceDirtyCount: String {
        model.source.git.map { String($0.changedFileCount) } ?? "unavailable"
    }

    private var sourceUpstream: String {
        guard let git = model.source.git else { return "unavailable" }
        return git.upstream.map(visibleEscape) ?? "none"
    }

    private var sourceAhead: String {
        model.source.git?.aheadCount.map(String.init) ?? "unavailable"
    }

    private var sourceBehind: String {
        model.source.git?.behindCount.map(String.init) ?? "unavailable"
    }

    private var sourceObservedAt: String {
        guard let date = model.source.git?.observedAt else { return "unavailable" }
        return Self.rfc3339.string(from: date)
    }

    private var sourceTrackingStale: String {
        model.source.git?.trackingSnapshotMayBeStale == true ? "true" : "unavailable"
    }

    private var sourceTrackingIncomplete: String {
        model.source.git.map { String($0.trackingSnapshotIncomplete) } ?? "unavailable"
    }

    private var sourceRemotes: [HarvisGitRemoteSummary] {
        model.source.status == .ready ? model.source.git?.remotes ?? [] : []
    }

    private var firstSafeRemoteIndex: Int? {
        sourceRemotes.firstIndex { remote in
            guard let value = remote.githubBrowseURL else { return false }
            return URL(string: value) != nil
        }
    }

    private var sourceWorktrees: [HarvisGitWorktreeSummary] {
        model.source.status == .ready ? model.source.git?.worktrees ?? [] : []
    }

    private func worktreeBranch(_ worktree: HarvisGitWorktreeSummary) -> String {
        switch worktree.headState {
        case .bare: return "unavailable"
        case .detached: return "none"
        case .attached, .unborn: return worktree.branch.map(visibleEscape) ?? "unavailable"
        }
    }

    private func worktreeHead(_ worktree: HarvisGitWorktreeSummary) -> String {
        switch worktree.headState {
        case .bare: return "unavailable"
        case .unborn: return "unborn"
        case .attached, .detached: return worktree.headCommit ?? "unavailable"
        }
    }

    private func worktreeFlags(_ worktree: HarvisGitWorktreeSummary) -> String {
        var values: [String] = []
        switch worktree.headState {
        case .bare: values.append("bare")
        case .unborn: values.append("unborn")
        case .detached: values.append("detached")
        case .attached: break
        }
        if worktree.lockedReason != nil { values.append("locked") }
        if worktree.prunableReason != nil { values.append("prunable") }
        return values.isEmpty ? "none" : values.joined(separator: ",")
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "ready", "valid", "matched", "exact": return .green
        case "unbound", "unknown", "offline", "receiptUnavailable": return .secondary
        case "sourceAhead", "installedAhead": return .orange
        default: return .red
        }
    }

    private func shortObjectID(_ value: String) -> String {
        value.count > 12 ? String(value.prefix(12)) : value
    }

    private func visibleEscape(_ raw: String) -> String {
        HarvisVersionVisibleEscape.encode(raw)
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private struct HarvisVersionSidebarRow: View {
    let section: HarvisVersionCatalogSection
    let status: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: section.systemImage)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(section.subtitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status)
                        .monospaced()
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The version overview deliberately switches from a three-column dashboard
/// to one readable column at the minimum window width. An adaptive grid alone
/// would choose two columns in the 860pt window, leaving each card too narrow
/// for status text and making the source actions compete for the same row.
private struct HarvisVersionCardLayout: Layout {
    typealias Cache = ()

    private let columnSpacing: CGFloat = 12
    private let rowSpacing: CGFloat = 12
    private let minimumColumnWidth: CGFloat = 220
    private let maximumColumnCount = 3

    func makeCache(subviews: Subviews) -> Cache {}

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposedWidth(proposal: proposal, subviews: subviews)
        let columnCount = columnCount(for: width)
        let columnWidth = columnWidth(for: width, columnCount: columnCount)
        let rowHeights = rowHeights(
            for: subviews,
            columnCount: columnCount,
            columnWidth: columnWidth
        )
        let height = rowHeights.reduce(0, +)
            + CGFloat(max(0, rowHeights.count - 1)) * rowSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard !subviews.isEmpty else { return }

        let columnCount = columnCount(for: bounds.width)
        let columnWidth = columnWidth(for: bounds.width, columnCount: columnCount)
        let rowHeights = rowHeights(
            for: subviews,
            columnCount: columnCount,
            columnWidth: columnWidth
        )
        var y = bounds.minY

        for row in rowHeights.indices {
            let rowStart = row * columnCount
            let rowEnd = min(rowStart + columnCount, subviews.count)
            let rowHeight = rowHeights[row]
            for index in rowStart..<rowEnd {
                let column = index - rowStart
                let x = bounds.minX + CGFloat(column) * (columnWidth + columnSpacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: columnWidth, height: rowHeight)
                )
            }
            y += rowHeight + rowSpacing
        }
    }

    private func proposedWidth(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> CGFloat {
        if let width = proposal.width, width.isFinite, width > 0 {
            return width
        }
        return max(
            minimumColumnWidth,
            subviews.reduce(CGFloat.zero) { partial, subview in
                max(partial, subview.sizeThatFits(.unspecified).width)
            }
        )
    }

    private func columnCount(for width: CGFloat) -> Int {
        // 3 × 220 + 2 × 12 = 684. Below that threshold the contract requires
        // one column; at the standard and wide widths three columns fit.
        guard width >= 684 else { return 1 }
        let count = Int((width + columnSpacing) / (minimumColumnWidth + columnSpacing))
        return min(maximumColumnCount, max(1, count))
    }

    private func columnWidth(for width: CGFloat, columnCount: Int) -> CGFloat {
        max(
            minimumColumnWidth,
            (width - CGFloat(columnCount - 1) * columnSpacing) / CGFloat(columnCount)
        )
    }

    private func rowHeights(
        for subviews: Subviews,
        columnCount: Int,
        columnWidth: CGFloat
    ) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columnCount).map { start in
            let end = min(start + columnCount, subviews.count)
            return (start..<end).reduce(CGFloat.zero) { partial, index in
                max(
                    partial,
                    subviews[index].sizeThatFits(
                        ProposedViewSize(width: columnWidth, height: nil)
                    ).height
                )
            }
        }
    }
}

enum HarvisVersionVisibleEscape {
    static func encode(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C: output.append("\\\\")
            case 0x0A: output.append("\\n")
            case 0x0D: output.append("\\r")
            case 0x09: output.append("\\t")
            case 0x00...0x1F,
                 0x7F...0x9F,
                 0x2028...0x2029,
                 0x061C,
                 0x200E...0x200F,
                 0x202A...0x202E,
                 0x2066...0x2069:
                output.append(String(format: "\\u{%04X}", scalar.value))
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}

#if HARVIS_VERSION_UI_TESTING
@MainActor
final class HarvisVersionFixtureViewState: ObservableObject {
    @Published private(set) var fixtureReceipt: String
    @Published private(set) var openerReceipt: String?
    @Published private(set) var clipboardReceipt: String?
    @Published private(set) var finderReceipt: String?

    let provider: HarvisVersionFixtureProvider

    init(provider: HarvisVersionFixtureProvider) {
        self.provider = provider
        fixtureReceipt = provider.fixtureReceipt ?? "unavailable"
        syncEffects()
        provider.onFixtureReceiptChange = { [weak self] value in
            self?.fixtureReceipt = value
        }
    }

    var effects: HarvisVersionUIEffects {
        HarvisVersionUIEffects(
            chooseSourceDirectory: { [weak self] in
                self?.provider.sourceSelectionCandidate
            },
            copy: { [weak self] value, kind in
                guard let self else { return }
                provider.effects.copy(
                    value,
                    kind: kind == .source ? .source : .commit
                )
                syncEffects()
            },
            reveal: { [weak self] url in
                guard let self else { return }
                _ = provider.effects.showInFinder(canonicalPath: url.path)
                syncEffects()
            },
            openGitHub: { [weak self] url in
                guard let self else { return }
                _ = provider.effects.openGitHub(url.absoluteString)
                syncEffects()
            }
        )
    }

    func releaseLatestWinsA() {
        guard provider.releaseLatestWinsA() else { return }
        // The provider publishes the third observable barrier only when the A
        // continuation actually returns; `onFixtureReceiptChange` updates us.
        fixtureReceipt = provider.fixtureReceipt ?? fixtureReceipt
    }

    func removeSourceAfterReady(model: HarvisVersionCatalogModel) {
        guard provider.removeSourceAfterReady() else { return }
        fixtureReceipt = provider.fixtureReceipt ?? fixtureReceipt
        model.refresh()
    }

    func releaseTaskProgressSuccess() {
        guard provider.releaseTaskProgressSuccess() else { return }
        fixtureReceipt = provider.fixtureReceipt ?? fixtureReceipt
    }

    private func syncEffects() {
        openerReceipt = provider.effects.openerReceipt
        clipboardReceipt = provider.effects.clipboardReceipt
        finderReceipt = provider.effects.finderReceipt
    }
}

struct HarvisVersionFixtureCatalogRoot: View {
    let model: HarvisVersionCatalogModel
    @StateObject var state: HarvisVersionFixtureViewState
    let closeAction: @MainActor () -> Void

    init(
        model: HarvisVersionCatalogModel,
        state: HarvisVersionFixtureViewState,
        closeAction: @escaping @MainActor () -> Void
    ) {
        self.model = model
        _state = StateObject(wrappedValue: state)
        self.closeAction = closeAction
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HarvisVersionCatalogView(
                model: model,
                effects: state.effects,
                closeAction: closeAction
            )
            fixtureEvidence
        }
    }

    private var fixtureEvidence: some View {
        VStack(alignment: .trailing, spacing: 3) {
            evidenceText(
                state.fixtureReceipt,
                identifier: "harvis-version-fixture-receipt"
            )
            if let receipt = state.openerReceipt {
                evidenceText(
                    receipt,
                    identifier: "harvis-version-fixture-opener-receipt"
                )
            }
            if let receipt = state.clipboardReceipt {
                evidenceText(
                    receipt,
                    identifier: "harvis-version-fixture-clipboard-receipt"
                )
            }
            if let receipt = state.finderReceipt {
                evidenceText(
                    receipt,
                    identifier: "harvis-version-fixture-finder-receipt"
                )
            }
            if state.provider.fixtureID == .latestWins {
                Button("Release A") {
                    state.releaseLatestWinsA()
                }
                .controlSize(.small)
                .accessibilityIdentifier("harvis-version-fixture-release-a")
            }
            if state.provider.fixtureID == .sourceRemovedAfterReady {
                Button("Remove source") {
                    state.removeSourceAfterReady(model: model)
                }
                .controlSize(.small)
                .accessibilityIdentifier("harvis-version-fixture-remove-source")
            }
        }
        .font(.caption2.monospaced())
        .padding(7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
        .padding(10)
    }

    private func evidenceText(_ value: String, identifier: String) -> some View {
        Text(value)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}

struct HarvisTaskProgressFixtureRoot: View {
    @ObservedObject var model: HarvisRuntimeModel
    @StateObject var state: HarvisVersionFixtureViewState

    init(
        model: HarvisRuntimeModel,
        state: HarvisVersionFixtureViewState
    ) {
        self.model = model
        _state = StateObject(wrappedValue: state)
    }

    var body: some View {
        VStack(spacing: 8) {
            HarvisPopoverView()
                .environmentObject(model)
                .frame(width: 318, height: 620)
                .accessibilityIdentifier("harvis-task-progress-fixture-popover")

            HStack(spacing: 10) {
                Text(state.fixtureReceipt)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .accessibilityValue(state.fixtureReceipt)
                    .accessibilityIdentifier("harvis-version-fixture-receipt")
                Spacer(minLength: 4)
                if state.fixtureReceipt.hasSuffix(":retrying:count=2") {
                    Button("发布成功结果") {
                        state.releaseTaskProgressSuccess()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("harvis-task-progress-fixture-release-success")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(width: 338, height: 668)
    }
}
#endif
