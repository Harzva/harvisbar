import AppKit
import Foundation
import SwiftUI

private enum CodexChatManagerFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case recent = "Recent"

    var id: String { rawValue }
}

private enum CodexChatManagerLayout: String {
    case list
    case matrix
}

enum CodexMatrixCardKind: CaseIterable {
    case standard
    case sidechat
}

enum CodexMatrixCardLayoutMetrics {
    static let sectionSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 10

    // Matrix cards use a fixed upper content slot. Without this reservation,
    // a LazyVGrid row shares its bottom edge but each card's variable title and
    // metadata push the composer to a different vertical position.
    static let contentSlotSpacing: CGFloat = 5
    static let headerSlotHeight: CGFloat = 22
    static let identitySlotHeight: CGFloat = 20
    static let titleSlotHeight: CGFloat = 76
    static let metadataSlotHeight: CGFloat = 18
    static let managementSlotHeight: CGFloat = 20
    static let contentSlotHeight: CGFloat =
        headerSlotHeight
        + identitySlotHeight
        + titleSlotHeight
        + metadataSlotHeight
        + managementSlotHeight
        + (contentSlotSpacing * 4)

    /// The complete composer slot, including the input, hint/controls row,
    /// and their shared spacing. Hidden/read-only cards reserve this too.
    static let composerSlotHeight = CodexTaskComposerLayoutMetrics.matrixComposerSlotHeight
    static let actionSlotHeight: CGFloat = 28

    /// Shared footer slot keeps the bottom action row on one baseline.
    static let footerHeight: CGFloat = 24
    static let compactionRiskBarHeight: CGFloat = 3

    /// The explicit height makes the composer and footer start at the same
    /// y-coordinate for every card in a matrix row, including sidechats.
    static let cardHeight: CGFloat =
        (cardPadding * 2)
        + contentSlotHeight
        + actionSlotHeight
        + composerSlotHeight
        + footerHeight
        + 1
        + (sectionSpacing * 4)

    static func cardHeight(for _: CodexMatrixCardKind) -> CGFloat {
        cardHeight
    }

    static func composerSlotHeight(for _: CodexMatrixCardKind) -> CGFloat {
        composerSlotHeight
    }

    static func planStripeTopInset(preservingRiskBar: Bool) -> CGFloat {
        preservingRiskBar ? compactionRiskBarHeight + 1 : 1
    }
}

private enum CodexChatManagerSort: String, CaseIterable, Identifiable {
    case directory = "Directory"
    case attention = "Attention"
    case updated = "Updated"
    case title = "Title"
    case tokens = "Tokens"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .directory: return "folder"
        case .attention: return "star"
        case .updated: return "clock"
        case .title: return "textformat"
        case .tokens: return "number"
        }
    }
}

private struct CodexThreadProjectGroup: Identifiable {
    let project: ManagedChatProjectIdentity
    let threads: [ManagedChatThread]

    var id: String { project.id }
    var label: String { project.label }
    var gitPath: String { project.canonicalPath ?? "" }
}

struct CodexAccountAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var workspacePath: String
    let theme: HarvisTheme
    let onAdd: (String, String) -> Void

    init(
        initialWorkspace: String,
        theme: HarvisTheme,
        onAdd: @escaping (String, String) -> Void
    ) {
        _workspacePath = State(initialValue: initialWorkspace)
        self.theme = theme
        self.onAdd = onAdd
    }

    private var canAdd: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspacePath.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.plus")
                    .harvisFont(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加 Codex 账户")
                        .harvisFont(.title3.bold())
                    Text("创建独立 CODEX_HOME，并在下一步打开官方登录。")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("账户备注")
                    .harvisFont(.caption.bold())
                TextField("例如：论文研究", text: $label)
                    .textFieldStyle(.roundedBorder)
                Text("仅用于识别账户；登录后显示为“备注 · 邮箱”，不会改变登录身份。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("独立工作区")
                    .harvisFont(.caption.bold())
                HStack(spacing: 8) {
                    Text(workspacePath)
                        .harvisFont(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择…") { chooseWorkspace() }
                }
                Text("Auth 过期、重新登录或从列表移出账户，都不会删除此目录。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建并登录") {
                    onAdd(label, workspacePath)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(!canAdd)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.background)
        .foregroundColor(theme.text)
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "选择此账户的工作区"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.standardizedFileURL.path
        }
    }
}

struct CodexAccountRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    let home: CodexHome
    let theme: HarvisTheme
    let onSave: (String) -> Void

    init(home: CodexHome, theme: HarvisTheme, onSave: @escaping (String) -> Void) {
        self.home = home
        self.theme = theme
        self.onSave = onSave
        _note = State(initialValue: home.accountDisplayNote ?? "")
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var preview: String {
        if let email = home.accountEmail, !email.isEmpty {
            return trimmedNote.isEmpty ? email : "\(trimmedNote) · \(email)"
        }
        return trimmedNote.isEmpty ? "未登录" : "\(trimmedNote) · 未登录"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .harvisFont(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("重命名账户备注")
                        .harvisFont(.title3.bold())
                    Text("只改变 Harvis 中的显示名称，不改变邮箱、认证或 CODEX_HOME。")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("备注名称")
                    .harvisFont(.caption.bold())
                TextField("例如：论文研究", text: $note)
                    .textFieldStyle(.roundedBorder)
                Text("显示预览：\(preview)")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                if home.accountDisplayNote?.isEmpty == false {
                    Button("清除备注") {
                        onSave("")
                        dismiss()
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(trimmedNote)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(trimmedNote.count > 60)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(theme.background)
        .foregroundColor(theme.text)
    }
}

struct HarvisCodexChatManagerView: View {
    @EnvironmentObject var model: HarvisRuntimeModel
    var conversationPlanPresentationProvider:
        ((ManagedChatThread) -> ManagedConversationPlanPresentation)? = nil
    var onEditConversationPlan: ((ManagedChatThread) -> Void)? = nil
    var projectBrainEnabledProvider:
        ((ManagedChatProjectIdentity) -> Bool?)? = nil
    var onSetProjectBrainEnabled:
        ((ManagedChatProjectIdentity, Bool) -> Void)? = nil
    @State private var query = ""
    @FocusState private var searchIsFocused: Bool
    @State private var filter: CodexChatManagerFilter = .all
    @AppStorage(ManagedChatDisplayScope.selectionKey) private var displayScopeRaw = ""
    @AppStorage(ManagedChatDisplayScope.defaultKey) private var defaultDisplayScopeRaw = ""
    @State private var sort: CodexChatManagerSort = .directory
    @State private var pinnedOnly = false
    @State private var selectedTags: Set<String> = []
    @State private var collapsedProjectIDs: Set<String> = []
    @State private var currentPathID: String?
    @State private var pathProperties: ManagedProjectPathMatrixNode?
    @State private var showProjectOrganizer = false
    @State private var emptyOrganizerProposal = ManagedProjectOrganizerProposal(
        baseStateRevision: 0, catalogFingerprint: "", snapshots: [], suggestions: []
    )
    @State private var composerDrafts: [String: String] = [:]
    @State private var composerVisibilityOverrides: [String: Bool] = [:]
    @State private var submittingComposerIDs: Set<String> = []
    @State private var tagEditorThread: ManagedChatThread?
    @State private var projectAttentionEditor: ManagedChatProjectIdentity?
    @State private var conversationAttentionEditorThread: ManagedChatThread?
    @State private var conversationPlanEditorThread: ManagedChatThread?
    @State private var supervisorThread: ManagedChatThread?
    @State private var showSupervisorOverview = false
    @State private var showUnnamedSubagentManager = false
    @State private var showAddAccount = false
    @State private var showInvalidAccountCleanup = false
    @State private var showCurrentAccountRemoval = false
    @State private var accountPendingRemoval: CodexHome?
    @State private var accountPendingRename: CodexHome?
    @StateObject private var gitMetadata = ProjectGitMetadataStore()
    @StateObject private var projectFileStatistics = ManagedProjectFileStatisticsStore()
    @AppStorage("harvis.codex.chatManager.layout") private var layoutRawValue = CodexChatManagerLayout.list.rawValue
    @AppStorage("harvis.codex.chatManager.showSidechats") private var showSidechats = true
    @AppStorage("harvis.codex.chatManager.selectedThreadID") private var selectedThreadID = ""
    @AppStorage("harvis.codex.chatManager.selectedProjectID") private var selectedProjectID = ""
    @AppStorage("harvis.codex.chatManager.workbenchExpanded") private var workbenchExpanded = false
    @AppStorage("harvis.codex.chatManager.textSize") private var textSizeRaw = "medium"
    @AppStorage("harvis.codex.chatManager.workbenchPlacement") private var workbenchPlacementRaw = "automatic"
    @AppStorage("harvis.codex.chatManager.workbenchWidth") private var workbenchWidth = 460.0
    @AppStorage("harvis.codex.chatManager.workbenchHeight") private var workbenchHeight = 300.0
    @AppStorage("harvis.codex.chatManager.railWidth") private var projectRailWidth = 224.0
    @AppStorage("harvis.codex.chatManager.railCollapsed") private var projectRailCollapsed = false
    @AppStorage(CodexComposerVisibilityPolicy.isVisibleDefaultsKey)
    private var taskComposersVisible = true
    @AppStorage(CodexComposerVisibilityPolicy.selectedTagsDefaultsKey)
    private var composerSelectedTagsRaw = "[]"

    private var theme: HarvisTheme { model.theme }

    private func conversationInsightContext(
        for thread: ManagedChatThread
    ) -> ManagedConversationInsightRuntimeContext {
        model.managedConversationInsightContext(for: thread)
    }

    private var layout: CodexChatManagerLayout {
        CodexChatManagerLayout(rawValue: layoutRawValue) ?? .list
    }

    private var displayScope: ManagedChatDisplayScope {
        ManagedChatDisplayScope.decode(displayScopeRaw.isEmpty ? defaultDisplayScopeRaw : displayScopeRaw)
    }

    private var displayScopeBinding: Binding<ManagedChatDisplayScope> {
        Binding(get: { displayScope }, set: { displayScopeRaw = $0.encoded })
    }

    private var scopedThreads: [ManagedChatThread] {
        model.managedChatThreads.filter(displayScope.includes)
    }

    private var displayAccounts: [ManagedChatDisplayAccount] {
        model.managedChatDisplayAccounts
    }

    private var matchingThreads: [ManagedChatThread] {
        let parsedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : CodexThreadQuery(query)
        return scopedThreads
            .filter { thread in
                switch filter {
                case .all: return true
                case .running: return thread.isCardRunning
                case .recent: return !thread.isCardRunning
                }
            }
            .filter { matches($0, parsedQuery: parsedQuery) }
            .filter { showSidechats || !$0.isSidechat }
            .filter {
                ManagedUnnamedSubagentVisibilityPolicy.shouldShow(
                    isUnnamedSubagent: $0.isUnnamedSubagent,
                    hasExplicitShowOverride: model.isUnnamedSubagentVisible($0)
                )
            }
            .filter { !pinnedOnly || model.isThreadPinned($0) }
            .sorted(by: threadSort)
    }

    private var unnamedSubagents: [ManagedChatThread] {
        model.managedChatThreads
            .filter { $0.isUnnamedSubagent }
            .sorted(by: threadSort)
    }

    private var hiddenUnnamedSubagents: [ManagedChatThread] {
        unnamedSubagents.filter { !model.isUnnamedSubagentVisible($0) }
    }

    private var selectedThread: ManagedChatThread? {
        guard !selectedThreadID.isEmpty else { return nil }
        return matchingThreads.first {
            model.managedChatStorageKey($0) == selectedThreadID
        }
    }

    private var selectedProjectGroup: CodexThreadProjectGroup? {
        guard !selectedProjectID.isEmpty else { return nil }
        let hierarchy = projectHierarchy
        if let node = hierarchy.node(selectedProjectID) {
            return CodexThreadProjectGroup(
                project: node.project,
                threads: directoryThreadOrder(hierarchy.threads(includingDescendantsOf: node.id))
            )
        }
        let threads = matchingThreads.filter {
            ManagedChatProjectResolver.resolve(thread: $0).id == selectedProjectID
        }
        guard let project = model.managedChatProjectCatalog.first(where: { $0.id == selectedProjectID }) else { return nil }
        return CodexThreadProjectGroup(
            project: project,
            threads: directoryThreadOrder(threads)
        )
    }

    private var availableTags: [String] {
        Array(Set(model.managedChatThreads.flatMap(model.tags)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var composerSelectedTags: Set<String> {
        CodexComposerVisibilityPolicy.selectedTags(from: composerSelectedTagsRaw)
    }

    private var composerScopeTags: [String] {
        var seen: Set<String> = []
        return (availableTags + Array(composerSelectedTags))
            .filter { tag in
                seen.insert(tag.lowercased()).inserted
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var directoryGroups: [CodexThreadProjectGroup] {
        Dictionary(grouping: matchingThreads) { thread in
            ManagedChatProjectResolver.resolve(thread: thread)
        }
        .map { project, threads in
            CodexThreadProjectGroup(
                project: project,
                threads: directoryThreadOrder(threads)
            )
        }
        .sorted(by: projectGroupSort)
    }

    private var governanceSignature: String {
        let home = model.selectedCodexHomeID ?? "none"
        let threads = model.managedChatThreads.map {
            "\($0.id):\($0.updatedAt)"
        }.joined(separator: "|")
        return "\(home)::\(threads)"
    }

    private func projectGroupSort(
        _ left: CodexThreadProjectGroup,
        _ right: CodexThreadProjectGroup
    ) -> Bool {
        switch sort {
        case .directory:
            let labelOrder = left.label.localizedStandardCompare(right.label)
            return labelOrder == .orderedAscending
                || (labelOrder == .orderedSame && left.id < right.id)
        case .attention:
            let leftAttention = model.attention(for: left.project)
            let rightAttention = model.attention(for: right.project)
            let leftFocus = attentionFocusRank(leftAttention)
            let rightFocus = attentionFocusRank(rightAttention)
            if leftFocus != rightFocus { return leftFocus > rightFocus }
            let leftLevel = leftAttention.level?.rawValue ?? 0
            let rightLevel = rightAttention.level?.rawValue ?? 0
            if leftLevel != rightLevel { return leftLevel > rightLevel }
            let leftTasks = model.managedProjectTaskSummaries[left.project.id]
            let rightTasks = model.managedProjectTaskSummaries[right.project.id]
            let leftBlocked = model.projectTaskSummaryFreshness(for: left.project).isFresh
                && leftTasks?.needsAttention == true
            let rightBlocked = model.projectTaskSummaryFreshness(for: right.project).isFresh
                && rightTasks?.needsAttention == true
            if leftBlocked != rightBlocked { return leftBlocked }
            let leftUpdated = left.threads.map(\.updatedAt).max() ?? 0
            let rightUpdated = right.threads.map(\.updatedAt).max() ?? 0
            return leftUpdated != rightUpdated
                ? leftUpdated > rightUpdated
                : left.id < right.id
        case .updated:
            let leftUpdated = left.threads.map(\.updatedAt).max() ?? 0
            let rightUpdated = right.threads.map(\.updatedAt).max() ?? 0
            return leftUpdated != rightUpdated
                ? leftUpdated > rightUpdated
                : left.id < right.id
        case .title:
            let leftTitle = left.threads.map(\.title).min { $0.localizedStandardCompare($1) == .orderedAscending } ?? ""
            let rightTitle = right.threads.map(\.title).min { $0.localizedStandardCompare($1) == .orderedAscending } ?? ""
            let titleOrder = leftTitle.localizedStandardCompare(rightTitle)
            return titleOrder == .orderedAscending
                || (titleOrder == .orderedSame && left.id < right.id)
        case .tokens:
            let leftTokens = left.threads.map(\.tokensUsed).max() ?? 0
            let rightTokens = right.threads.map(\.tokensUsed).max() ?? 0
            return leftTokens != rightTokens
                ? leftTokens > rightTokens
                : left.id < right.id
        }
    }

    private func attentionFocusRank(
        _ preference: ManagedAttentionPreference
    ) -> Int {
        switch preference.focusState() {
        case .active: return 3
        case .scheduled: return 2
        case .expired: return 1
        case .unset: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            managerHeader
                .zIndex(10)
            managerControls
            Divider()
                .overlay(theme.line)
            if workbenchExpanded && !showSupervisorOverview {
                adjustableWorkspace
            } else {
                managerContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .padding(.leading, model.codexChatWindowDockSide == "right" ? 28 : 14)
        .padding(.trailing, model.codexChatWindowDockSide == "left" ? 28 : 14)
        .frame(minWidth: 480, minHeight: 560)
        .background(theme.background)
        .overlay {
            if model.codexChatWindowDockSide == "right" {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 14)
                    Rectangle()
                        .fill(theme.line)
                        .frame(width: 1)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            } else if model.codexChatWindowDockSide == "left" {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(theme.line)
                        .frame(width: 1)
                    Color.clear.frame(width: 14)
                }
                .allowsHitTesting(false)
            }
        }
        .foregroundColor(theme.text)
        .tint(theme.accent)
        .preferredColorScheme(theme.preferredColorScheme)
        .onReceive(model.codexTaskDelivery.handoffs.$transactions) { transactions in
            model.syncVerifiedHandoffTags(transactions)
        }
        .task(id: directoryGroups.map(\.gitPath).filter { !$0.isEmpty }) {
            await gitMetadata.refresh(
                paths: directoryGroups.map(\.gitPath).filter { !$0.isEmpty }
            )
        }
        .task(id: governanceSignature) {
            repeat {
                await model.refreshManagedChatGovernance(
                    threads: model.managedChatThreads,
                    projects: model.managedChatProjectCatalog
                )
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
            } while !Task.isCancelled
        }
        .sheet(item: $tagEditorThread) { thread in
            CodexThreadTagEditor(
                thread: thread,
                initialTags: model.tags(for: thread),
                theme: theme
            ) { tags in
                model.setTags(tags, for: thread)
            }
        }
        .sheet(item: $projectAttentionEditor) { project in
            ManagedAttentionEditorSheet(
                subject: project.label,
                initial: model.attention(for: project),
                theme: theme
            ) { preference in
                model.setAttention(preference, for: project)
            }
        }
        .sheet(item: $conversationAttentionEditorThread) { thread in
            ManagedAttentionEditorSheet(
                subject: thread.title,
                initial: model.attention(for: thread),
                theme: theme
            ) { preference in
                model.setAttention(preference, for: thread)
            }
        }
        .sheet(item: $supervisorThread) { thread in
            ManagedSupervisorSheet(thread: thread, theme: theme) {
                showSupervisorOverview = false
                selectedThreadID = ""
                selectedProjectID = ManagedChatProjectResolver.resolve(thread: thread).id
                setWorkbenchExpanded(true)
            }
            .environmentObject(model)
        }
        .sheet(item: $conversationPlanEditorThread) { thread in
            let project = ManagedChatProjectResolver.resolve(thread: thread)
            ConversationPlanMetadataEditorSheet(
                thread: thread,
                project: project,
                snapshot: model.conversationManagementSnapshots[project.id],
                theme: theme,
                onSave: { workKind, taskID, includeForDispatch in
                    try await model.setConversationManagementPlanBinding(
                        for: thread,
                        project: project,
                        workKind: workKind,
                        taskID: taskID,
                        includeForDispatch: includeForDispatch
                    )
                },
                onClear: {
                    try await model.clearConversationManagementPlanBinding(
                        for: thread,
                        project: project
                    )
                }
            )
        }
        .sheet(isPresented: $showUnnamedSubagentManager) {
            UnnamedSubagentVisibilitySheet(
                threads: unnamedSubagents,
                theme: theme,
                isVisible: model.isUnnamedSubagentVisible,
                setVisible: { visible, thread in
                    model.setUnnamedSubagentVisible(visible, thread: thread)
                }
            )
        }
        .sheet(isPresented: $showAddAccount) {
            CodexAccountAddSheet(
                initialWorkspace: model.expanded(model.workspaceRoot),
                theme: theme
            ) { label, workspace in
                model.addManagedCodexAccount(label: label, workspacePath: workspace)
            }
        }
        .sheet(item: $pathProperties) { node in
            ManagedProjectPathPropertiesView(
                node: node, theme: theme,
                onOpenProject: {
                    currentPathID = node.id
                    selectedThreadID = ""
                    selectedProjectID = node.id
                    pathProperties = nil
                    setWorkbenchExpanded(true)
                },
                onClose: { pathProperties = nil }
            )
        }
        .sheet(isPresented: $showProjectOrganizer, onDismiss: {
            model.cancelProjectOrganizerAnalysis()
            model.persistProjectOrganizerDraft()
        }) {
            organizerReview
        }
        .sheet(item: $accountPendingRename) { home in
            CodexAccountRenameSheet(home: home, theme: theme) { note in
                model.renameCodexAccountNote(home, note: note)
            }
        }
        .confirmationDialog(
            "移出失效账户？",
            isPresented: $showInvalidAccountCleanup,
            titleVisibility: .visible
        ) {
            Button("移出 \(model.invalidVisibleCodexHomes.count) 个账户") {
                model.hideInvalidCodexHomes()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只从 Harvis 列表移出；CODEX_HOME、工作区和本地会话不会删除，可随时恢复。")
        }
        .confirmationDialog(
            "移出当前账户？",
            isPresented: $showCurrentAccountRemoval,
            titleVisibility: .visible
        ) {
            Button("移出账户") {
                if let home = accountPendingRemoval {
                    model.hideCodexHome(home)
                }
                accountPendingRemoval = nil
            }
            Button("取消", role: .cancel) { accountPendingRemoval = nil }
        } message: {
            Text("账户目录与独立工作区都会保留；这里只隐藏列表项。")
        }
        .harvisFont(.body)
        .environment(\.harvisTextSize, textSize)
    }

    private var textSize: HarvisTextSize {
        HarvisTextSize(rawValue: textSizeRaw) ?? .medium
    }

    private var workbenchPlacement: ManagedWorkbenchPlacement {
        ManagedWorkbenchPlacement(rawValue: workbenchPlacementRaw) ?? .automatic
    }

    private var adjustableWorkspace: some View {
        GeometryReader { geometry in
            // A saved side-by-side preference is retained while a narrow
            // window temporarily uses a vertical split to keep both panes usable.
            let sideBySide = workbenchPlacement != .bottom
                && geometry.size.width >= (workbenchPlacement == .right ? 820 : 960) * textSize.layoutScale
            ManagedResizableSplitView(
                axis: sideBySide ? .horizontal : .vertical,
                fixedPane: .trailing,
                length: sideBySide ? $workbenchWidth : $workbenchHeight,
                defaultLength: sideBySide ? 460 : 300,
                minimumLeading: sideBySide ? 380 : 160,
                minimumTrailing: sideBySide ? 320 : 180,
                theme: theme,
                label: sideBySide ? "调整工作台宽度" : "调整工作台高度",
                identifier: "chat-manager.workbench-divider"
            ) {
                managerContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } trailing: {
                workbenchDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var projectHierarchy: ManagedProjectHierarchy {
        ManagedProjectHierarchy(
            catalog: model.managedChatProjectCatalog,
            records: model.managedProjectOrganization.projects,
            threads: matchingThreads
        )
    }

    private var organizerProposalBinding: Binding<ManagedProjectOrganizerProposal> {
        Binding(
            get: { model.projectOrganizerProposal ?? emptyOrganizerProposal },
            set: { draft in
                guard model.projectOrganizerProposal != nil,
                      !model.projectOrganizerIsApplying else { return }
                model.projectOrganizerProposal = draft
                model.projectOrganizerError = nil
                model.persistProjectOrganizerDraft()
            }
        )
    }

    private var organizerReview: some View {
        let status: ManagedProjectOrganizerReviewAnalysisStatus =
            model.projectOrganizerIsApplying ? .applying
            : model.projectOrganizerIsAnalyzing ? .analyzing
            : model.projectOrganizerError != nil ? .failed
            : model.projectOrganizerProposal != nil ? .ready
            : model.projectOrganizerFeedback != nil ? .applied : .idle
        return ManagedProjectOrganizerReviewView(
            proposal: organizerProposalBinding,
            catalog: model.managedChatProjectCatalog.map { project in
                model.managedProjectOrganization.projects[project.id]
                    ?? ManagedProjectRecord(id: project.id, name: project.label, purpose: "", path: project.canonicalPath)
            },
            analysis: ManagedProjectOrganizerReviewAnalysis(
                status: status,
                coverage: model.projectOrganizerCoverage,
                feedback: model.projectOrganizerError ?? model.projectOrganizerFeedback ?? model.projectOrganizerProgress
            ),
            theme: theme,
            onAnalyze: model.analyzeProjectOrganizer,
            onClose: {
                guard !model.projectOrganizerIsApplying else { return }
                model.cancelProjectOrganizerAnalysis()
                if model.projectGroupxReviewBusy || model.projectGroupxReviewJob?.state.isActive == true {
                    model.cancelProjectGroupxReview()
                }
                model.persistProjectOrganizerDraft()
                showProjectOrganizer = false
            },
            onCancelAnalysis: model.cancelProjectOrganizerAnalysis,
            onApply: model.applyProjectOrganizerSelection,
            onUndo: { receiptID in
                guard model.lastProjectOrganizationReceipt?.id == receiptID else { return }
                model.undoLastProjectOrganization()
            },
            latestReceipt: model.lastProjectOrganizationReceipt,
            groupxReview: model.projectGroupxReviewPresentation,
            onGroupxStart: model.startProjectGroupxReview,
            onGroupxCancel: model.cancelProjectGroupxReview,
            onGroupxSelectHost: model.selectProjectGroupxReviewHost
        )
        .interactiveDismissDisabled(model.projectOrganizerIsApplying)
    }

    private var projectPathMatrix: some View {
        let hierarchy = projectHierarchy
        let layerID = hierarchy.node(currentPathID)?.id
        let direct = layerID.map { hierarchy.node($0)?.directThreads ?? [] } ?? matchingThreads
        let scope = layerID.map { hierarchy.threads(includingDescendantsOf: $0) } ?? matchingThreads
        let projectIDsBySession = hierarchy.nodes.reduce(into: [String: String]()) { assignments, node in
            for thread in node.directThreads {
                assignments[thread.id] = node.id
            }
        }
        let nodes = hierarchy.nodes.map { node in
            let children = hierarchy.children(of: node.id)
            let allThreads = hierarchy.threads(includingDescendantsOf: node.id)
            let unavailable = node.project.resolution == .unresolved
            return ManagedProjectPathMatrixNode(
                id: node.id, name: node.project.label,
                kind: node.isContainer ? .folder : (node.project.canonicalPath == nil && !node.isLogicalProject ? .unclassified : .project),
                path: node.project.canonicalPath, purpose: node.purpose, parentID: node.parentID,
                childCount: children.count, sessionCount: allThreads.count,
                directSessionCount: node.directThreads.count,
                participantCount: ManagedProjectHierarchy.participantCount(allThreads),
                healthLabel: unavailable ? "待核查" : "待分析",
                healthReason: unavailable
                    ? "已记录路径当前无法定位，需核查路径是否迁移或暂未挂载。"
                    : "尚未进行内容归属分析；目录数量和层级深度不影响健康判断。"
            )
        }
        let breadcrumbs = [ManagedProjectPathMatrixBreadcrumb(id: nil, label: "所有项目")]
            + hierarchy.breadcrumb(to: layerID).map {
                ManagedProjectPathMatrixBreadcrumb(id: $0.id, label: $0.project.label, path: $0.project.canonicalPath)
            }
        return ManagedProjectPathMatrixView(
            nodes: nodes, breadcrumbs: breadcrumbs, currentLayerID: layerID,
            summary: ManagedProjectPathMatrixSummary(
                currentCount: hierarchy.children(of: layerID).count,
                directCount: direct.count, loadedCount: matchingThreads.count,
                sessionCount: scope.count,
                unresolvedCount: nodes.filter { $0.healthLabel == "待核查" }.count,
                note: "统计限当前筛选的已载入会话。参与来源按账号及已知智能体身份去重，不代表项目负责人。"
            ),
            theme: theme,
            onNavigate: { pathID in
                currentPathID = pathID
                // Keep an open inspector in the browsed project context.
                // Folder and logical nodes are resolved by the same hierarchy.
                if workbenchExpanded {
                    selectedThreadID = ""
                    selectedProjectID = pathID ?? ""
                }
            },
            onProperties: { pathProperties = $0 },
            onOrganize: {
                model.restoreProjectOrganizerDraft()
                model.prepareProjectOrganizer(threads: scope)
                showProjectOrganizer = true
            },
            sessionThreads: scope.map { thread in
                let sourceLabel = model.codexHome(for: thread)?.accountDisplayLabel
                    ?? model.managedChatDisplayAccounts.first {
                        $0.provider == thread.provider && $0.sourceScope == thread.sourceScope
                    }?.label
                return ManagedProjectPathMatrixSession(
                    thread: thread,
                    projectID: projectIDsBySession[thread.id] ?? ManagedChatProjectResolver.resolve(thread: thread).id,
                    sourceDisplayLabel: sourceLabel
                )
            },
            sessionContent: { session in
                // ManagedChatThread.id includes provider, source scope, and
                // source ID. Reuse the original source-bound card unchanged.
                guard let thread = scope.first(where: { $0.id == session.id }) else { return nil }
                return AnyView(
                    VStack(alignment: .leading, spacing: 6) {
                        Label("会话", systemImage: "bubble.left.and.bubble.right")
                            .harvisFont(.caption.weight(.semibold))
                            .foregroundColor(ManagedProjectPathMatrixPalette.session(for: theme))
                        managerThreadMatrixCard(thread)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("project-path-matrix.session-card.\(thread.id)")
                )
            },
            onSessionSelect: { sessionID in
                guard let thread = scope.first(where: { $0.id == sessionID }) else { return }
                inspectThread(thread)
            }
        )
    }

    private func inspectThread(_ thread: ManagedChatThread) {
        guard thread.provider == .dsh || (thread.isCodex && thread.capabilities.supportsCodexWorkbench) else {
            model.openManagedThread(thread)
            return
        }
        selectThread(thread)
    }

    private func selectThread(_ thread: ManagedChatThread) {
        selectedProjectID = ""
        selectedThreadID = model.managedChatStorageKey(thread)
        if !workbenchExpanded {
            setWorkbenchExpanded(true)
        }
    }

    private func selectProject(_ group: CodexThreadProjectGroup) {
        selectedThreadID = ""
        selectedProjectID = group.id
        if !workbenchExpanded {
            setWorkbenchExpanded(true)
        }
    }

    private func resolvedProjectBrainEnabled(
        _ project: ManagedChatProjectIdentity
    ) -> Bool? {
        if let projectBrainEnabledProvider {
            return projectBrainEnabledProvider(project)
        }
        guard let snapshot = model.conversationManagementSnapshots[project.id] else {
            return nil
        }
        return snapshot.brainEnabled
    }

    private func setProjectBrainEnabled(
        _ enabled: Bool,
        for project: ManagedChatProjectIdentity
    ) {
        if let onSetProjectBrainEnabled {
            onSetProjectBrainEnabled(project, enabled)
            return
        }
        Task {
            do {
                try await model.setConversationManagementBrainEnabled(
                    enabled,
                    for: project
                )
            } catch {
                model.conversationManagementErrors[project.id] =
                    error.localizedDescription
            }
        }
    }

    private func setProjectDefaultEnrollmentEnabled(
        _ enabled: Bool,
        for project: ManagedChatProjectIdentity
    ) {
        Task {
            do {
                try await model
                    .setConversationManagementDefaultEnrollmentEnabled(
                        enabled,
                        for: project
                    )
            } catch {
                model.conversationManagementErrors[project.id] =
                    error.localizedDescription
            }
        }
    }

    private func setWorkbenchExpanded(_ expanded: Bool) {
        workbenchExpanded = expanded
        HarvisCodexChatWindowController.shared
            .setWorkbenchExpanded(expanded)

        if expanded,
           selectedThread == nil,
           selectedProjectGroup == nil,
           let firstCodexThread = matchingThreads.first(where: { $0.isCodex && $0.capabilities.supportsCodexWorkbench }) {
            inspectThread(firstCodexThread)
        }
    }

    private func toggleSupervisorOverview() {
        showSupervisorOverview.toggle()
    }

    @ViewBuilder
    private func taskComposer(
        for thread: ManagedChatThread,
        compact: Bool
    ) -> some View {
        let shouldShowComposer = isComposerVisible(for: thread)

        if thread.isDsh {
            DshConversationCardComposer(
                sender: model.dshConversationSender,
                draft: model.dshConversationSender.draft(for: thread),
                thread: thread, theme: theme, compact: compact
            )
        } else if shouldShowComposer {
            let sourceHome = model.codexHome(for: thread)
            CodexTaskComposerView(
                coordinator: model.codexTaskDelivery,
                thread: thread,
                home: sourceHome,
                homePath: sourceHome.map { model.expanded($0.path) },
                text: composerDraftBinding(for: thread),
                isSubmitting: composerSubmittingBinding(for: thread),
                theme: theme,
                compact: compact
            )
        } else if thread.isCodex && thread.capabilities.supportsCodexDispatch {
            HStack(spacing: 7) {
                Image(systemName: "text.bubble")
                Text(composerDraftBinding(for: thread).wrappedValue.isEmpty
                    ? "输入已收起" : "输入已收起 · 草稿已保留")
                Spacer(minLength: 0)
                Button("展开输入") { setComposerVisible(true, for: thread) }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .accessibilityIdentifier("chat-manager.expand-input.\(thread.id)")
            }
            .harvisFont(.system(size: 12))
            .foregroundColor(theme.muted)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 30 * textSize.layoutScale : CodexTaskComposerLayoutMetrics.matrixComposerSlotHeight * textSize.layoutScale)
            .background(theme.surfaceAlt.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else if !compact {
            CodexMatrixComposerPlaceholder(
                thread: thread,
                theme: theme,
                inputPolicyHidden: thread.capabilities.supportsCodexDispatch
                    && !shouldShowComposer
            )
        }
    }

    private func isComposerVisible(for thread: ManagedChatThread) -> Bool {
        thread.isCodex && thread.capabilities.supportsCodexDispatch
            && CodexComposerVisibilityPolicy.shouldShow(
                isEnabled: taskComposersVisible,
                selectedTags: composerSelectedTags,
                threadTags: model.tags(for: thread),
                cardOverride: composerVisibilityOverrides[model.managedChatStorageKey(thread)]
            )
    }

    private func setComposerVisible(_ visible: Bool, for thread: ManagedChatThread) {
        composerVisibilityOverrides[model.managedChatStorageKey(thread)] = visible
    }

    private func composerDraftBinding(
        for thread: ManagedChatThread
    ) -> Binding<String> {
        let key = model.managedChatStorageKey(thread)
        return Binding(
            get: { composerDrafts[key, default: ""] },
            set: { value in
                if value.isEmpty {
                    composerDrafts.removeValue(forKey: key)
                } else {
                    composerDrafts[key] = value
                }
            }
        )
    }

    private func composerSubmittingBinding(
        for thread: ManagedChatThread
    ) -> Binding<Bool> {
        let key = model.managedChatStorageKey(thread)
        return Binding(
            get: { submittingComposerIDs.contains(key) },
            set: { isSubmitting in
                if isSubmitting {
                    submittingComposerIDs.insert(key)
                } else {
                    submittingComposerIDs.remove(key)
                }
            }
        )
    }

    @ViewBuilder
    private var workbenchDetail: some View {
        if let group = selectedProjectGroup {
            ManagedProjectManagementView(
                project: group.project,
                threads: group.threads,
                managementSnapshot: model.conversationManagementSnapshot(for: group.project),
                managementThreads: model.managedChatThreads,
                taskPlan: model.projectTaskPlan(for: group.project),
                taskSummary: model.managedProjectTaskSummaries[group.project.id]
                    ?? .unavailable,
                taskFreshness: model.projectTaskSummaryFreshness(for: group.project),
                attention: model.attention(for: group.project),
                gitSummary: gitMetadata.summary(for: group.gitPath),
                gitRefreshing: gitMetadata.refreshingPaths.contains(group.gitPath),
                brainEnabled: resolvedProjectBrainEnabled(group.project),
                brainError: model.conversationManagementErrors[group.id],
                onSetBrainEnabled: { enabled in
                    setProjectBrainEnabled(enabled, for: group.project)
                },
                defaultEnrollmentEnabled: model
                    .conversationManagementSnapshots[group.id]?
                    .projectDefaultEnrollmentEnabled,
                onSetDefaultEnrollmentEnabled: { enabled in
                    setProjectDefaultEnrollmentEnabled(
                        enabled,
                        for: group.project
                    )
                },
                brainEndpoint: model.conversationManagementBrainEndpoint,
                brainEndpointError: model.conversationManagementBrainEndpointError,
                onGenerateBrainPreview: { objective in
                    try await model.startConversationManagementPreview(
                        project: group.project,
                        objective: objective
                    )
                },
                onApproveBrainDecision: { preview, decision in
                    try await model.approveConversationManagementProposal(
                        project: group.project,
                        runID: preview.runID,
                        decisionID: decision.id,
                        expectedLedgerRevision: preview.ledgerRevision
                    )
                },
                onCancelBrainRun: { runID, expectedRevision in
                    try await model.cancelConversationManagementRun(
                        project: group.project,
                        runID: runID,
                        expectedLedgerRevision: expectedRevision
                    )
                },
                brainCoordinator: model.dshMetaAgentCoordinator,
                fileStatistics: projectFileStatistics,
                theme: theme,
                onClose: {
                    selectedProjectID = ""
                    setWorkbenchExpanded(false)
                },
                onEditAttention: {
                    projectAttentionEditor = group.project
                }
            )
        } else if let selectedThread,
           selectedThread.isCodex,
           selectedThread.capabilities.supportsCodexWorkbench,
           let home = model.codexHome(for: selectedThread) {
            let stableStorageKey = model.managedChatStorageKey(selectedThread)
            let project = ManagedChatProjectResolver.resolve(thread: selectedThread)
            let governance = ManagedChatGovernanceSnapshot(
                project: project,
                projectAttention: model.attention(for: project),
                projectTasks: model.managedProjectTaskSummaries[project.id] ?? .unavailable,
                projectTasksFreshness: model.projectTaskSummaryFreshness(for: project),
                conversationAttention: model.attention(for: selectedThread),
                conversationMetrics: model.conversationMetrics(for: selectedThread),
                conversationMetricsFreshness: model.conversationMetricsFreshness(
                    for: selectedThread
                )
            )
            let insightContext = conversationInsightContext(for: selectedThread)
            CodexTurnPanelView(
                thread: selectedThread,
                home: home,
                coordinator: model.codexTaskDelivery,
                handoffs: model.codexTaskDelivery.handoffs,
                governance: governance,
                conversationInputState: insightContext.inputState,
                conversationInsightStatus: insightContext.status,
                conversationSourceProject: insightContext.sourceProject,
                conversationManagedProject: insightContext.managedProject,
                conversationProjectCandidates: insightContext.projectCatalog,
                conversationRecommendedProject: insightContext.recommendedProject,
                conversationInsightAvailabilityMessage: insightContext.availabilityMessage,
                conversationInsightCanAnalyze: insightContext.canAnalyze,
                theme: theme,
                onOpen: { model.openManagedThread(selectedThread) },
                onClose: { setWorkbenchExpanded(false) },
                onHandoffVerified: { verified in
                    guard verified.sourceThreadID == selectedThread.sourceID,
                          verified.homeID == home.id else { return }
                    model.appendTag("done", toStorageKey: stableStorageKey)
                    model.refreshManagedChatList()
                },
                onOpenHandoffDestination: { threadID in
                    model.openCodexThreadID(threadID, home: home)
                },
                onEditConversationAttention: {
                    conversationAttentionEditorThread = selectedThread
                },
                onEditProjectAttention: {
                    projectAttentionEditor = project
                },
                onRefreshConversationInputs: {
                    Task {
                        async let inputs: Void = model.refreshConversationInputs(
                            for: selectedThread,
                            force: true
                        )
                        async let security: Void = model
                            .attestManagedConversationInsightSecurity()
                        _ = await (inputs, security)
                    }
                },
                onPrepareConversationInputs: {
                    model.prepareConversationInputPanel(for: selectedThread)
                },
                onClearConversationInputs: {
                    model.clearConversationInputPanel(for: selectedThread)
                },
                onAnalyzeConversation: {
                    Task {
                        do {
                            _ = try await model.analyzeManagedConversationInsight(
                                for: selectedThread
                            )
                        } catch {
                            model.lastError = error.localizedDescription
                        }
                    }
                },
                onCancelConversationAnalysis: {
                    Task {
                        do {
                            try await model.cancelManagedConversationInsight(
                                for: selectedThread
                            )
                        } catch {
                            model.lastError = error.localizedDescription
                        }
                    }
                },
                onAssignConversationProject: { destination in
                    _ = model.assignConversation(
                        selectedThread,
                        to: destination,
                        source: .manual
                    )
                },
                onRestoreConversationSourceProject: {
                    model.clearConversationProjectAssignment(selectedThread)
                },
                onConfirmConversationRecommendation: {
                    do {
                        try model.applyManagedConversationInsightRecommendation(
                            for: selectedThread
                        )
                    } catch {
                        model.lastError = error.localizedDescription
                    }
                }
            )
            .id(stableStorageKey)
        } else if let selectedThread, selectedThread.provider == .dsh {
            DshConversationPanel(sender: model.dshConversationSender, thread: selectedThread,
                onClose: { setWorkbenchExpanded(false) })
                .id(selectedThread.id)
        } else if let selectedThread {
            observationWorkbenchDetail(for: selectedThread)
        } else {
            emptyWorkbenchDetail
        }
    }

    private var emptyWorkbenchDetail: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.rightthird.inset.filled")
                    .harvisFont(.system(size: 28, weight: .medium))
                    .foregroundColor(theme.muted)
                Text("选择左侧任务")
                    .harvisFont(.headline)
                Text("这里会显示 Codex 工作台、DSH 会话或 WorkBuddy 详情。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            closeWorkbenchButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func observationWorkbenchDetail(for thread: ManagedChatThread) -> some View {
        let insightContext = conversationInsightContext(for: thread)
        return ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    providerBadge(for: thread)
                    Text(thread.title)
                        .harvisFont(.title3.bold())
                        .foregroundColor(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("只读观察")
                        .harvisFont(.caption.bold())
                        .foregroundColor(theme.muted)
                    Text(
                        thread.isDsh
                            ? "DSH 会话由对应的 DSH Host 管理；此处只展示状态，不提供 Codex 派发或编辑器。"
                            : "WorkBuddy 会话只读展示；需要操作时请打开原始会话。"
                    )
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    observationDetailRow("Project", value: ManagedChatProjectResolver.resolve(thread: thread).displayPath)
                    observationDetailRow("Status", value: thread.isCardRunning ? "Running" : "Idle")
                    if let threadModel = thread.model, !threadModel.isEmpty {
                        observationDetailRow("Model", value: threadModel)
                    }
                    observationDetailRow("Updated", value: thread.updatedLabel)
                    observationDetailRow("Tokens", value: thread.tokenLabel)

                    ManagedConversationInsightPanelView(
                        thread: thread,
                        inputState: insightContext.inputState,
                        insightStatus: insightContext.status,
                        sourceProject: insightContext.sourceProject,
                        managedProject: insightContext.managedProject,
                        projectCandidates: insightContext.projectCatalog,
                        recommendedProject: insightContext.recommendedProject,
                        availabilityMessage: insightContext.availabilityMessage,
                        canAnalyze: false,
                        theme: theme,
                        onPrepareInputs: {
                            model.prepareConversationInputPanel(for: thread)
                        },
                        onClearInputs: {
                            model.clearConversationInputPanel(for: thread)
                        },
                        onRefreshInputs: {
                            Task {
                                await model.refreshConversationInputs(
                                    for: thread,
                                    force: true
                                )
                            }
                        },
                        onAnalyze: {},
                        onCancelAnalysis: {},
                        onAssignProject: { destination in
                            _ = model.assignConversation(
                                thread,
                                to: destination,
                                source: .manual
                            )
                        },
                        onRestoreSourceProject: {
                            model.clearConversationProjectAssignment(thread)
                        },
                        onConfirmRecommendation: {}
                    )
                    .id(model.managedChatStorageKey(thread))

                    Button {
                        model.openManagedThread(thread)
                    } label: {
                        Label(thread.isDsh ? "打开 DSH" : "打开 WorkBuddy", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .help(thread.isDsh ? "打开对应 DSH Host 根页" : "打开 WorkBuddy 会话")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            closeWorkbenchButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func observationDetailRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .harvisFont(.system(size: 9, weight: .bold))
                .foregroundColor(theme.muted)
            Text(value)
                .harvisFont(.caption.monospaced())
                .foregroundColor(theme.text)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    private var closeWorkbenchButton: some View {
        Button {
            setWorkbenchExpanded(false)
        } label: {
            Image(systemName: "xmark")
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("关闭右侧栏并收起工作台")
        .accessibilityLabel("关闭右侧栏并收起工作台")
        .padding(8)
    }

    private func copyProjectDirectory(_ thread: ManagedChatThread) {
        copyToPasteboard(thread.cwd)
    }

    private func copySessionID(_ thread: ManagedChatThread) {
        copyToPasteboard(thread.sourceID)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealProjectDirectory(_ thread: ManagedChatThread) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.cwd)
    }

    private func isComposerScopeTagSelected(_ tag: String) -> Bool {
        composerSelectedTags.contains {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }
    }

    private func setComposerScopeTags(_ tags: Set<String>) {
        composerSelectedTagsRaw =
            CodexComposerVisibilityPolicy.encodeSelectedTags(tags)
    }

    private func toggleComposerScopeTag(_ tag: String) {
        var tags = composerSelectedTags
        if isComposerScopeTagSelected(tag) {
            tags = Set(tags.filter {
                $0.caseInsensitiveCompare(tag) != .orderedSame
            })
        } else {
            tags.insert(tag)
        }
        setComposerScopeTags(tags)
    }

    private var composerVisibilityButton: some View {
        Button {
            taskComposersVisible.toggle()
            composerVisibilityOverrides.removeAll()
        } label: {
            Label(taskComposersVisible ? "收起输入" : "展开输入", systemImage: taskComposersVisible ? "text.bubble.fill" : "text.bubble")
                .harvisFont(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(taskComposersVisible ? theme.selectionFill : theme.surfaceAlt)
                .foregroundColor(taskComposersVisible ? theme.selectionText : theme.muted)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(taskComposersVisible ? theme.selectionFill : theme.line)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-manager.bulk-input")
        .accessibilityLabel(taskComposersVisible ? "隐藏 Codex 卡片输入框" : "显示 Codex 卡片输入框")
        .help(taskComposersVisible ? "隐藏 Codex 卡片输入框；DSH 输入框始终显示" : "按当前标签范围显示 Codex 卡片输入框")
    }

    private var composerTagScopeMenu: some View {
        Menu {
            Button {
                setComposerScopeTags([])
            } label: {
                Label(
                    "全部 Codex 卡片",
                    systemImage: composerSelectedTags.isEmpty ? "checkmark" : "rectangle.stack"
                )
            }

            Divider()
            if composerScopeTags.isEmpty {
                Text("当前没有卡片标签")
            } else {
                Text("命中任一所选标签")
                ForEach(composerScopeTags, id: \.self) { tag in
                    Button {
                        toggleComposerScopeTag(tag)
                    } label: {
                        Label(
                            tag,
                            systemImage: isComposerScopeTagSelected(tag) ? "checkmark" : "tag"
                        )
                    }
                }
            }
        } label: {
            Image(systemName: composerSelectedTags.isEmpty ? "tag" : "tag.fill")
                .harvisFont(.system(size: 12, weight: .semibold))
                .foregroundColor(composerSelectedTags.isEmpty ? theme.muted : theme.accent)
                .frame(width: 26, height: 30)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(
            composerSelectedTags.isEmpty
                ? "Codex 输入框标签范围：全部卡片"
                : "Codex 输入框标签范围：\(composerSelectedTags.count) 个标签"
        )
        .help(
            composerSelectedTags.isEmpty
                ? "输入框显示在全部 Codex 卡片；DSH 输入框始终显示"
                : "Codex 输入框仅显示在命中所选标签之一的卡片；DSH 输入框始终显示"
        )
    }

    private var managerHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                managerHeaderTitle
                Spacer(minLength: 12)
                managerConversationTools
                managerTextSizePicker
                managerLayoutMenu
                HarvisThemePicker(selection: $model.themeID, theme: theme)
                managerWindowMenu
                managerRefreshButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    managerHeaderTitle
                    Spacer(minLength: 8)
                }
                HStack(spacing: 10) {
                    managerTextSizePicker
                    managerLayoutMenu
                    Spacer(minLength: 4)
                    HarvisThemePicker(selection: $model.themeID, theme: theme)
                }
                HStack(spacing: 8) {
                    managerConversationTools
                    Spacer(minLength: 8)
                    managerWindowMenu
                    managerRefreshButton
                }
            }
        }
    }

    private var managerTextSizePicker: some View {
        HStack(spacing: 6) {
            Text("字号").harvisFont(.caption)
            Picker("字号", selection: $textSizeRaw) {
                ForEach(HarvisTextSize.allCases) { size in
                    Text(size.title).tag(size.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 126)
            .accessibilityIdentifier("chat-manager.text-size")
            .accessibilityLabel("界面字号")
            .accessibilityValue(textSize.title)
        }
        .fixedSize()
        .help("小／中／大字号；账号、会话卡片、工作台与监督面板同步调整")
    }

    private var managerLayoutMenu: some View {
        Menu {
            Picker("工作台位置", selection: $workbenchPlacementRaw) {
                ForEach(ManagedWorkbenchPlacement.allCases) { placement in
                    Text(placement.title).tag(placement.rawValue)
                }
            }
            Toggle("显示项目侧栏", isOn: Binding(
                get: { !projectRailCollapsed },
                set: { projectRailCollapsed = !$0 }
            ))
            Divider()
            Text("拖动分隔线调整大小；双击恢复默认。")
            Text("窄窗口临时上下排列，侧栏从按钮展开。")
            Button("恢复默认布局") {
                workbenchPlacementRaw = "automatic"
                workbenchWidth = 460
                workbenchHeight = 300
                projectRailWidth = 224
                projectRailCollapsed = false
            }
        } label: {
            Label("布局", systemImage: "rectangle.split.2x1")
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(HarvisControlButtonStyle(theme: theme))
        .fixedSize()
        .accessibilityIdentifier("chat-manager.layout-settings")
        .help("调整工作台位置、侧栏显示或恢复分隔线尺寸；选择会自动保存")
    }

    private var managerHeaderTitle: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right")
                .harvisFont(.system(size: 21, weight: .medium))
                .foregroundColor(theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Chat Agent Managed")
                    .harvisFont(.system(size: 16, weight: .semibold))
                HStack(spacing: 7) {
                    Text("\(scopedThreads.filter(\.isCardRunning).count) 运行中 · \(scopedThreads.count) 个会话")
                        .harvisFont(.system(size: 11).monospacedDigit())
                        .foregroundColor(theme.muted)
                    if model.isCodexChatWindowAttachmentLocked {
                        Label("跟随 Codex", systemImage: "link")
                            .harvisFont(.system(size: 11))
                            .foregroundColor(theme.accent)
                    } else if model.isCodexChatWindowDocked {
                        Label("已吸附", systemImage: "arrow.left.and.right")
                            .harvisFont(.system(size: 11))
                            .foregroundColor(theme.accent)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var managerConversationTools: some View {
        HStack(spacing: 5) {
            composerVisibilityButton
            composerTagScopeMenu
            Button {
                setWorkbenchExpanded(!workbenchExpanded)
            } label: {
                Label(
                    workbenchExpanded ? "收起工作台" : "工作台",
                    systemImage: "sidebar.right"
                )
                .harvisFont(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .foregroundColor(workbenchExpanded ? theme.selectionText : theme.text)
                .background(workbenchExpanded ? theme.selectionFill : theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-manager.workbench")
            .accessibilityLabel(workbenchExpanded ? "收起工作台" : "展开工作台")
            .help(workbenchExpanded ? "收起会话详情工作台" : "打开会话详情工作台；位置可在布局菜单中调整")
        }
        .fixedSize()
    }

    private var managerWindowMenu: some View {
        Menu {
            Toggle("窗口置顶", isOn: Binding(
                get: { model.isCodexChatWindowPinned },
                set: { value in
                    if value != model.isCodexChatWindowPinned { model.toggleCodexChatWindowPin() }
                }
            ))
            .accessibilityIdentifier("chat-manager.window-pin")
            Toggle("靠近 Codex 时磁吸", isOn: Binding(
                get: { model.isCodexChatWindowDockingEnabled },
                set: { value in
                    if value != model.isCodexChatWindowDockingEnabled { model.toggleCodexChatWindowDocking() }
                }
            ))
            .accessibilityIdentifier("chat-manager.window-docking")
            Toggle("锁定跟随 Codex", isOn: Binding(
                get: { model.isCodexChatWindowAttachmentLocked },
                set: { value in
                    if value != model.isCodexChatWindowAttachmentLocked { model.toggleCodexChatWindowAttachmentLock() }
                }
            ))
            .accessibilityIdentifier("chat-manager.window-attachment")
        } label: {
            Label("窗口", systemImage: model.isCodexChatWindowPinned ? "pin.fill" : "macwindow")
                .harvisFont(.system(size: 12, weight: .medium))
                .foregroundColor(theme.text)
                .padding(.horizontal, 7)
                .frame(height: 30)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("chat-manager.window-menu")
        .accessibilityLabel("窗口选项")
        .help("设置窗口置顶、磁吸和跟随 Codex")
    }

    private var managerRefreshButton: some View {
        Button {
            model.refreshManagedChatList()
        } label: {
            Image(systemName: "arrow.clockwise")
                .harvisFont(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundColor(theme.text)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-manager.refresh")
        .accessibilityLabel("刷新会话")
        .help("刷新 Codex、DSH 与 WorkBuddy 会话状态")
        .disabled(
            model.isCodexThreadRefreshing
                || model.isDshThreadRefreshing
                || model.isWorkBuddyThreadRefreshing
        )
    }

    private var codexAccountManagementMenu: some View {
        Menu {
            if model.visibleCodexHomes.isEmpty {
                Text("No CODEX_HOME found")
            }
            ForEach(model.visibleCodexHomes) { home in
                Button {
                    selectedThreadID = ""
                    model.selectCodexHome(home)
                } label: {
                    if home.id == model.selectedCodexHome?.id {
                        Label("\(home.accountDisplayLabel) · \(home.authStatusLabel)", systemImage: "checkmark")
                    } else {
                        Label(
                            "\(home.accountDisplayLabel) · \(home.authStatusLabel)",
                            systemImage: home.authSystemImage
                        )
                    }
                }
            }
            Divider()
            Button {
                showAddAccount = true
            } label: {
                Label("添加账户…", systemImage: "person.badge.plus")
            }
            if let selected = model.selectedCodexHome {
                Button {
                    accountPendingRename = selected
                } label: {
                    Label("重命名当前备注…", systemImage: "square.and.pencil")
                }
            }
            if !model.invalidVisibleCodexHomes.isEmpty {
                Button {
                    showInvalidAccountCleanup = true
                } label: {
                    Label(
                        "清理 \(model.invalidVisibleCodexHomes.count) 个失效账户…",
                        systemImage: "person.2.slash"
                    )
                }
            }
            if let selected = model.selectedCodexHome {
                Button {
                    accountPendingRemoval = selected
                    showCurrentAccountRemoval = true
                } label: {
                    Label("移出当前账户…", systemImage: "minus.circle")
                }
            }
            if !model.hiddenCodexHomes.isEmpty {
                Menu("恢复已移出账户") {
                    ForEach(model.hiddenCodexHomes) { home in
                        Button(home.accountDisplayLabel) { model.restoreCodexHome(home) }
                    }
                    Divider()
                    Button("全部恢复") { model.restoreAllCodexHomes() }
                }
            }
        } label: {
            Label("Codex 账号管理", systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(HarvisControlButtonStyle(theme: theme))

    }

    private var managerControls: some View {
        VStack(spacing: 8) {
            ManagedChatDisplayScopeMatrix(
                selection: displayScopeBinding,
                accounts: displayAccounts,
                onSaveDefault: { defaultDisplayScopeRaw = displayScope.encoded },
                onRestoreDefault: { displayScopeRaw = ManagedChatDisplayScope.decode(defaultDisplayScopeRaw).encoded },
                theme: theme,
                codexDetails: model.managedCodexAccountDetails,
                onOpenCodexDetails: { model.prepareCodexAccountDetails($0) },
                onCodexAction: { model.performCodexAccountDetailAction($0, home: $1) }
            )

            HStack(spacing: 8) {
                Menu {
                    codexAccountManagementMenu
                    Button(action: toggleSupervisorOverview) {
                        Label(
                            showSupervisorOverview ? "返回卡片" : "监督总览",
                            systemImage: showSupervisorOverview ? "rectangle.grid.1x2" : "eye.circle"
                        )
                    }
                    Button {
                        model.openDshRuntimeCatalog()
                    } label: {
                        Label("DSH 管理", systemImage: "bolt.horizontal.circle")
                    }
                } label: {
                    Label("管理模块", systemImage: "square.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .accessibilityIdentifier("chat-manager.management-modules")

                Button(action: toggleSupervisorOverview) {
                    Label(
                        showSupervisorOverview ? "返回卡片" : "监督总览",
                        systemImage: showSupervisorOverview ? "rectangle.grid.1x2" : "eye.circle"
                    )
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .accessibilityIdentifier("chat-manager.supervisor-overview")
                .accessibilityValue(showSupervisorOverview ? "已打开" : "已关闭")

                HStack(spacing: 7) {
                    Button { searchIsFocused = true } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(theme.muted)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("聚焦会话搜索")
                    .help("搜索会话 ⌘F")
                    TextField("搜索会话、项目或标签", text: $query)
                        .harvisFont(.system(size: 13))
                        .textFieldStyle(.plain)
                        .focused($searchIsFocused)
                        .accessibilityIdentifier("chat-manager.search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                            searchIsFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
                    .help("支持 tag:、project:、model:、status:、is:pinned、-排除词和引号短语；⌘F 聚焦搜索")
            }

            if let home = model.selectedCodexHome {
                DisclosureGroup("Codex 管理账号 · \(home.accountDisplayLabel)") {
                    codexAccountStatusRow(home)
                }
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
            }

            HStack(spacing: 6) {
                // Native segmented-control sizing can repeatedly re-enter the
                // hosting graph during live catalog updates on macOS 26.
                HStack(spacing: 0) {
                    ForEach(CodexChatManagerFilter.allCases) { item in
                        Button { filter = item } label: {
                            Text(item.rawValue)
                                .harvisFont(.caption)
                                .frame(maxWidth: .infinity)
                                .frame(height: 24)
                                .background(filter == item ? theme.accent.opacity(0.16) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(filter == item ? theme.accent : theme.text)
                        .accessibilityIdentifier("chat-manager.status.\(item.rawValue.lowercased())")
                        .accessibilityValue(filter == item ? "已选择" : "未选择")
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }
                .frame(width: 215)
                .background(theme.surfaceAlt.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Chat filter")

                Menu {
                    Menu {
                        ForEach(CodexChatManagerSort.allCases) { item in
                            Button {
                                sort = item
                            } label: {
                                if item == sort {
                                    Label(item.rawValue, systemImage: "checkmark")
                                } else {
                                    Label(item.rawValue, systemImage: item.systemImage)
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: sort.systemImage)
                    }

                    Menu {
                        if availableTags.isEmpty {
                            Text("No tags")
                        } else {
                            if !selectedTags.isEmpty {
                                Button("Clear Tag Filter") {
                                    selectedTags = []
                                }
                                Divider()
                            }
                            ForEach(availableTags, id: \.self) { tag in
                                Button {
                                    if selectedTags.contains(tag) {
                                        selectedTags.remove(tag)
                                    } else {
                                        selectedTags.insert(tag)
                                    }
                                } label: {
                                    Label(
                                        tag,
                                        systemImage: selectedTags.contains(tag) ? "checkmark" : "tag"
                                    )
                                }
                            }
                        }
                    } label: {
                        Label(
                            selectedTags.isEmpty ? "Tags" : "Tags (\(selectedTags.count))",
                            systemImage: selectedTags.isEmpty ? "tag" : "tag.fill"
                        )
                    }
                } label: {
                    Image(
                        systemName: displayScope == .all && sort == .directory && selectedTags.isEmpty
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                    .foregroundColor(theme.text)
                    .frame(width: 24, height: 24)
                    .background(theme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .help("Sort order and tags")
                .accessibilityLabel("Chat filters and sorting")

                Spacer()
                Button {
                    layoutRawValue = layout == .list
                        ? CodexChatManagerLayout.matrix.rawValue
                        : CodexChatManagerLayout.list.rawValue
                } label: {
                    Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                        .foregroundColor(theme.text)
                        .frame(width: 24, height: 24)
                        .background(theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(layout == .list ? "Switch to matrix view" : "Switch to list view")
                .accessibilityLabel(layout == .list ? "Show chats as a matrix" : "Show chats as a list")
                Button {
                    pinnedOnly.toggle()
                } label: {
                    Image(systemName: pinnedOnly ? "pin.fill" : "pin")
                        .foregroundColor(pinnedOnly ? theme.selectionText : theme.text)
                        .frame(width: 24, height: 24)
                        .background(pinnedOnly ? theme.selectionFill : theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(pinnedOnly ? "Show all chats" : "Show pinned chats only")
                .accessibilityLabel(pinnedOnly ? "Show all chats" : "Show pinned chats only")
                Button {
                    showUnnamedSubagentManager = true
                } label: {
                    Image(systemName: hiddenUnnamedSubagents.isEmpty ? "person.2" : "person.2.slash")
                        .foregroundColor(hiddenUnnamedSubagents.isEmpty ? theme.text : theme.accent)
                        .frame(width: 24, height: 24)
                        .background(theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topTrailing) {
                            if !hiddenUnnamedSubagents.isEmpty {
                                Text("\(min(hiddenUnnamedSubagents.count, 99))")
                                    .harvisFont(.system(size: 8, weight: .bold).monospacedDigit())
                                    .foregroundColor(theme.selectionText)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(theme.selectionFill)
                                    .clipShape(Capsule())
                                    .offset(x: 7, y: -6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help("管理默认隐藏的未命名 Subagent")
                .accessibilityLabel("管理未命名 Subagent 显示")
                Button {
                    showSidechats.toggle()
                } label: {
                    Image(systemName: showSidechats ? "bubble.left.and.bubble.right.fill" : "bubble.left")
                        .foregroundColor(showSidechats ? theme.selectionText : theme.text)
                        .frame(width: 24, height: 24)
                        .background(showSidechats ? theme.selectionFill : theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(showSidechats ? "Hide active sidechats" : "Show active sidechats")
                .accessibilityLabel(showSidechats ? "Hide active sidechats" : "Show active sidechats")
            }
        }
    }

    private func codexAccountStatusRow(_ home: CodexHome) -> some View {
        let statusColor: Color
        if home.isCustomModelHome {
            statusColor = theme.muted
        } else {
            statusColor = switch home.normalizedAuthStatus {
            case "valid", "configured": theme.positive
            case "expired", "invalid", "missing": .red
            default: .orange
            }
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Label(home.authStatusLabel, systemImage: home.authSystemImage)
                    .harvisFont(.caption.bold())
                    .foregroundColor(statusColor)
                if let expiration = home.authExpirationLabel {
                    Text("到期 \(expiration)")
                        .harvisFont(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 6)
                Label(model.codexWorkspaceLabel(for: home), systemImage: "folder.fill")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.codexWorkspacePath(for: home))
                Button {
                    model.chooseCodexWorkspace(home)
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .buttonStyle(.plain)
                .help("更改此账户的独立工作区")
                Button {
                    model.revealCodexWorkspace(home)
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.plain)
                .help("在 Finder 中打开此账户的工作区")
                if home.isCustomModelHome {
                    Button("设置") { model.openCodexConfig(home) }
                        .harvisFont(.caption2.bold())
                        .buttonStyle(.borderless)
                } else if home.isAuthInvalid || home.normalizedAuthStatus == "refresh-needed" {
                    Button("重新登录") { model.loginCodexHome(home) }
                        .harvisFont(.caption2.bold())
                        .buttonStyle(.borderless)
                }
            }
            if !home.isCustomModelHome && (home.isAuthInvalid || home.normalizedAuthStatus == "refresh-needed") {
                Text(home.authNote ?? "Auth 已失效；工作区和本地会话仍然保留。")
                    .harvisFont(.caption2)
                    .foregroundColor(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.hasDedicatedCodexWorkspace(for: home) {
                Text("当前沿用全局工作区；选择一次目录后，会只绑定到这个账户。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(statusColor.opacity(0.28)))
    }

    @ViewBuilder
    private var managerContent: some View {
        if showSupervisorOverview {
            ManagedSupervisorOverviewView(
                threads: matchingThreads,
                theme: theme,
                onOpenCard: { thread in
                    DispatchQueue.main.async {
                        supervisorThread = thread
                    }
                },
                onBack: toggleSupervisorOverview
            )
            .environmentObject(model)
        } else if displayScope.providers.isEmpty {
            managerMessage(systemImage: "checkmark.circle", title: "未选择智能体", detail: "勾选左侧智能体，再选择同一行中要显示的账号或配置。")
        } else if model.isCodexThreadRefreshing
            && !model.hasSelectedCodexThreadSnapshot
            && model.managedChatThreads.isEmpty {
            Spacer()
            HStack {
                Spacer()
                ProgressView("Loading chats…")
                    .controlSize(.small)
                Spacer()
            }
            Spacer()
        } else if let error = model.codexThreadError,
                  model.managedChatThreads.isEmpty {
            managerMessage(systemImage: "exclamationmark.triangle.fill", title: "Chats unavailable", detail: error)
        } else if model.managedChatThreads.isEmpty {
            managerMessage(
                systemImage: "bubble.left",
                title: "No chats",
                detail: model.dshThreadError == nil
                    ? "No managed Codex, DSH, or WorkBuddy chats were found."
                    : "No Codex or WorkBuddy chats were found. DSH is currently unavailable; account switching remains available."
            )
        } else if scopedThreads.isEmpty && displayScope != .all {
            managerMessage(systemImage: "person.crop.circle.badge.checkmark", title: "当前选择下暂无会话", detail: "在对应智能体这一行勾选账号或配置，也可以点击全选。")
        } else if matchingThreads.isEmpty {
            if !hiddenUnnamedSubagents.isEmpty,
               query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               selectedTags.isEmpty,
               !pinnedOnly {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "person.2.slash")
                        .harvisFont(.system(size: 30))
                        .foregroundColor(theme.muted)
                    Text("未命名 Subagent 已隐藏")
                        .harvisFont(.headline)
                    Text("当前隐藏 \(hiddenUnnamedSubagents.count) 个；隐藏不会删除、归档或停止任务。")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                    Button("管理显示项") {
                        showUnnamedSubagentManager = true
                    }
                    .buttonStyle(HarvisControlButtonStyle(theme: theme))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                managerMessage(systemImage: "magnifyingglass", title: "No matches", detail: "Try another search or filter.")
            }
        } else if layout == .matrix {
            projectPathMatrix
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(directoryGroups) { group in
                        directoryGroupHeader(group)
                            .padding(.top, group.id == directoryGroups.first?.id ? 0 : 7)
                        if !collapsedProjectIDs.contains(group.id) {
                            ForEach(group.threads) { thread in
                                managerThreadRow(thread)
                            }
                        }
                    }
                }
                .padding(.trailing, 5)
            }
        }
    }

    private func matches(_ thread: ManagedChatThread, parsedQuery: CodexThreadQuery?) -> Bool {
        if parsedQuery == nil && selectedTags.isEmpty { return true }
        let tags = model.tags(for: thread)
        guard selectedTags.allSatisfy({ selected in
            tags.contains { $0.caseInsensitiveCompare(selected) == .orderedSame }
        }) else {
            return false
        }
        guard let parsedQuery else { return true }
        return parsedQuery.matches(
            thread,
            tags: tags,
            isPinned: model.isThreadPinned(thread)
        )
    }

    private func threadSort(_ left: ManagedChatThread, _ right: ManagedChatThread) -> Bool {
        switch sort {
        case .directory:
            if left.isCardRunning != right.isCardRunning { return left.isCardRunning }
            return left.updatedAt > right.updatedAt
        case .attention:
            let leftAttention = model.attention(for: left)
            let rightAttention = model.attention(for: right)
            let leftFocus = attentionFocusRank(leftAttention)
            let rightFocus = attentionFocusRank(rightAttention)
            if leftFocus != rightFocus { return leftFocus > rightFocus }
            let leftLevel = leftAttention.level?.rawValue ?? 0
            let rightLevel = rightAttention.level?.rawValue ?? 0
            if leftLevel != rightLevel { return leftLevel > rightLevel }
            return left.updatedAt > right.updatedAt
        case .updated:
            return left.updatedAt > right.updatedAt
        case .title:
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        case .tokens:
            if left.tokensUsed != right.tokensUsed { return left.tokensUsed > right.tokensUsed }
            return left.updatedAt > right.updatedAt
        }
    }

    private func directoryThreadOrder(_ threads: [ManagedChatThread]) -> [ManagedChatThread] {
        Dictionary(grouping: threads) { thread in
            thread.rootThreadId.isEmpty ? thread.id : thread.rootThreadId
        }
        .values
        .sorted { left, right in
            let leftPinned = left.contains(where: model.isThreadPinned)
            let rightPinned = right.contains(where: model.isThreadPinned)
            if leftPinned != rightPinned { return leftPinned }
            let leftRunning = left.contains(where: \.isCardRunning)
            let rightRunning = right.contains(where: \.isCardRunning)
            if leftRunning != rightRunning { return leftRunning }
            return (left.map(\.updatedAt).max() ?? 0) > (right.map(\.updatedAt).max() ?? 0)
        }
        .flatMap { family in
            family.sorted { left, right in
                let leftPinned = model.isThreadPinned(left)
                let rightPinned = model.isThreadPinned(right)
                if leftPinned != rightPinned { return leftPinned }
                let leftRank = left.isSidechat ? 0 : (left.isSubagent ? 2 : 1)
                let rightRank = right.isSidechat ? 0 : (right.isSubagent ? 2 : 1)
                if leftRank != rightRank { return leftRank < rightRank }
                return threadSort(left, right)
            }
        }
    }

    private func directoryLabel(_ path: String) -> String {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !normalized.isEmpty else { return path.isEmpty ? "Unknown Directory" : path }
        return URL(fileURLWithPath: normalized).lastPathComponent
    }

    private func directoryGroupHeader(_ group: CodexThreadProjectGroup) -> some View {
        let attention = model.attention(for: group.project)
        let taskSummary = model.managedProjectTaskSummaries[group.project.id]
            ?? .unavailable
        let taskFreshness = model.projectTaskSummaryFreshness(for: group.project)
        return HStack(spacing: 7) {
            Button {
                if collapsedProjectIDs.contains(group.id) {
                    collapsedProjectIDs.remove(group.id)
                } else {
                    collapsedProjectIDs.insert(group.id)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: collapsedProjectIDs.contains(group.id) ? "chevron.right" : "chevron.down")
                        .harvisFont(.caption2.bold())
                        .foregroundColor(theme.muted)
                        .frame(width: 10)
                    Image(systemName: "folder.fill")
                        .foregroundColor(theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.label)
                            .harvisFont(.subheadline.bold())
                            .foregroundColor(theme.text)
                            .lineLimit(1)
                        Text(group.project.displayPath)
                            .harvisFont(.caption2.monospaced())
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(collapsedProjectIDs.contains(group.id) ? "Expand project" : "Collapse project")

            Spacer(minLength: 8)
            if !attention.isEmpty {
                ManagedAttentionBadge(preference: attention, theme: theme)
            }
            projectTaskSummaryBadge(taskSummary, freshness: taskFreshness)
            Button {
                selectProject(group)
            } label: {
                Label("管理", systemImage: "rectangle.grid.1x2")
                    .harvisFont(.caption.bold())
                    .foregroundColor(
                        selectedProjectID == group.id
                            ? theme.selectionText
                            : theme.accent
                    )
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        selectedProjectID == group.id
                            ? theme.selectionFill
                            : theme.surfaceAlt
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("打开 \(group.label) 项目管理页")
            .accessibilityLabel("打开 \(group.label) 项目管理页")
            Button {
                projectAttentionEditor = group.project
            } label: {
                Image(systemName: attention.isEmpty ? "star" : "star.fill")
                    .foregroundColor(attention.isEmpty ? theme.muted : theme.accent)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("设置项目重要级与关注时间")
            .accessibilityLabel("设置项目关注")
            if group.project.canonicalPath != nil {
                projectGitMenu(for: group)
            }
            Text("\(group.threads.count)")
                .harvisFont(.caption.monospacedDigit())
                .foregroundColor(theme.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(theme.surfaceAlt)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 3)
    }

    @ViewBuilder
    private func projectTaskSummaryBadge(
        _ summary: ManagedProjectTaskSummary,
        freshness: ManagedGovernanceFreshness
    ) -> some View {
        if case let .stale(lastSuccessfulAt, error) = freshness {
            Label(
                staleProjectTaskLabel(summary),
                systemImage: "clock.badge.exclamationmark"
            )
            .harvisFont(.caption2.bold())
            .foregroundColor(.orange)
            .help(staleGovernanceHelp(lastSuccessfulAt: lastSuccessfulAt, error: error))
        } else if !freshness.isFresh || !summary.sourceAvailable {
            Label("任务未知", systemImage: "checklist.unchecked")
                .harvisFont(.caption2.bold())
                .foregroundColor(theme.muted)
                .help(freshness.error ?? "尚无可验证的项目任务数据。")
        } else if summary.total == 0 {
            Label("暂无任务", systemImage: "checklist")
                .harvisFont(.caption2.bold())
                .foregroundColor(theme.muted)
        } else if summary.done == summary.total {
            Label("已完成 \(summary.done)/\(summary.total)", systemImage: "checkmark.circle.fill")
                .harvisFont(.caption2.bold())
                .foregroundColor(theme.positive)
        } else if summary.open == 0 {
            Label("已关闭 \(summary.closedWithoutCompletion) · 完成 \(summary.done)/\(summary.total)", systemImage: "archivebox")
                .harvisFont(.caption2.bold())
                .foregroundColor(theme.muted)
        } else {
            Label(
                "未完成 \(summary.open)",
                systemImage: summary.needsAttention
                    ? "exclamationmark.triangle.fill"
                    : "checklist.unchecked"
            )
            .harvisFont(.caption2.bold())
            .foregroundColor(summary.needsAttention ? .orange : theme.muted)
        }
    }

    @ViewBuilder
    private func conversationMetricsBadge(
        _ thread: ManagedChatThread
    ) -> some View {
        let freshness = model.conversationMetricsFreshness(for: thread)
        if case let .stale(lastSuccessfulAt, error) = freshness,
           let metrics = model.conversationMetrics(for: thread) {
            let attention = metrics.attention
            HStack(spacing: 5) {
                Text("上次\(attention.interactionLabel)")
                Text("·")
                Text("上次\(attention.compactionLabel)")
                Label("数据陈旧", systemImage: "clock.badge.exclamationmark")
                    .foregroundColor(.orange)
            }
            .harvisFont(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundColor(theme.muted)
            .help(staleGovernanceHelp(lastSuccessfulAt: lastSuccessfulAt, error: error))
        } else if freshness.isFresh,
                  let metrics = model.conversationMetrics(for: thread) {
            let attention = metrics.attention
            HStack(spacing: 5) {
                Text(attention.interactionLabel)
                Text("·")
                Text(attention.compactionLabel)
                if attention.risk == .handoffRecommended {
                    Label("建议交接", systemImage: "arrow.triangle.branch")
                        .foregroundColor(.orange)
                }
            }
            .harvisFont(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundColor(theme.muted)
            .help(metrics.userFacingEvidenceNote ?? "只统计结构化事件类型，不读取或显示对话正文。")
        } else if model.codexConversationMetricsLoadingKeys.contains(
            model.managedChatStorageKey(thread)
        ) {
            Label("读取交互/压缩指标", systemImage: "ellipsis")
                .harvisFont(.system(size: 10))
                .foregroundColor(theme.muted)
        } else if let error = freshness.error {
            Label("交互/压缩指标不可用", systemImage: "exclamationmark.triangle")
                .harvisFont(.system(size: 10))
                .foregroundColor(theme.muted)
                .help(error)
        }
    }

    private func conversationPlanBadge(
        _ thread: ManagedChatThread
    ) -> some View {
        ManagedConversationPlanBadge(
            presentation: resolvedConversationPlanPresentation(thread),
            theme: theme
        )
    }

    private func resolvedConversationPlanPresentation(
        _ thread: ManagedChatThread
    ) -> ManagedConversationPlanPresentation {
        if let conversationPlanPresentationProvider {
            return conversationPlanPresentationProvider(thread)
        }
        let project = ManagedChatProjectResolver.resolve(thread: thread)
        guard let snapshot = model.conversationManagementSnapshots[project.id],
              let record = snapshot.record(
                  for: ConversationManagementProjectorV1.target(for: thread)
              ) else {
            return .unavailable
        }
        return ManagedConversationPlanPresentationPolicy.make(
            alignment: record.planAlignment(taskPlan: snapshot.taskPlan),
            managementExtension: record.managementExtension
        )
    }

    private func conversationPlanEditButton(
        _ thread: ManagedChatThread,
        size: CGFloat = 22
    ) -> some View {
        Button {
            editConversationPlan(thread)
        } label: {
            Image(systemName: "checklist.checked")
                .foregroundColor(
                    theme.accent
                )
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .help("设置显式任务绑定与工作类型")
        .accessibilityLabel("设置任务绑定与工作类型")
    }

    private func editConversationPlan(_ thread: ManagedChatThread) {
        if let onEditConversationPlan {
            onEditConversationPlan(thread)
        } else {
            conversationPlanEditorThread = thread
        }
    }

    private func conversationPlanColor(
        _ presentation: ManagedConversationPlanPresentation
    ) -> Color {
        switch presentation.tone {
        case .positive: return theme.positive
        case .informational: return theme.accent
        case .neutral: return theme.muted
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func conversationPlanStripe(
        _ thread: ManagedChatThread,
        preservingTopRiskBar: Bool
    ) -> some View {
        Rectangle()
            .fill(
                conversationPlanColor(
                    resolvedConversationPlanPresentation(thread)
                )
            )
            .frame(width: 3)
            .padding(
                .top,
                CodexMatrixCardLayoutMetrics.planStripeTopInset(
                    preservingRiskBar: preservingTopRiskBar
                )
            )
            .padding(.bottom, 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func conversationRisk(
        _ thread: ManagedChatThread
    ) -> CodexConversationRisk {
        model.conversationMetricsFreshness(for: thread).currentConversationRisk(
            metrics: model.conversationMetrics(for: thread)
        )
    }

    private func staleProjectTaskLabel(
        _ summary: ManagedProjectTaskSummary
    ) -> String {
        guard summary.sourceAvailable else { return "任务数据陈旧" }
        guard summary.total > 0 else { return "上次暂无任务 · 数据陈旧" }
        return "上次完成 \(summary.done)/\(summary.total) · 数据陈旧"
    }

    private func staleGovernanceHelp(
        lastSuccessfulAt: Date,
        error: String
    ) -> String {
        "上次成功 \(lastSuccessfulAt.formatted(date: .omitted, time: .shortened))。当前数据不可作为实时信号：\(error)"
    }

    private func conversationRiskColor(
        _ risk: CodexConversationRisk
    ) -> Color {
        switch risk {
        case .handoffRecommended: return .orange
        case .watch: return Color.yellow.opacity(0.85)
        case .healthy, .unknown: return .clear
        }
    }

    private func projectGitMenu(for group: CodexThreadProjectGroup) -> some View {
        let summary = gitMetadata.summary(for: group.gitPath)
        let isRefreshing = gitMetadata.refreshingPaths.contains(group.gitPath)
        return Menu {
            if let summary, summary.isRepository {
                Section("Repository") {
                    Text("Root: \(directoryLabel(summary.repositoryRoot ?? group.gitPath))")
                    Text(summary.isDetached ? "Detached at \(summary.branch ?? "unknown")" : "Branch: \(summary.branch ?? "unborn")")
                    Text(summary.isDirty ? "\(summary.changedFileCount) changed files" : "Working tree clean")
                    Text("\(summary.worktreeCount) worktree\(summary.worktreeCount == 1 ? "" : "s")")
                    Text(summary.remotes.isEmpty ? "No remotes" : "Remotes: \(summary.remotes.joined(separator: ", "))")
                }
                branchMenu(
                    title: "Local branches",
                    branches: summary.localBranches,
                    current: summary.branch
                )
                branchMenu(
                    title: "Remote branches",
                    branches: summary.remoteBranches,
                    current: nil
                )
                Divider()
                Button {
                    copyToPasteboard(summary.repositoryRoot ?? group.gitPath)
                } label: {
                    Label("Copy repository path", systemImage: "doc.on.doc")
                }
                Button {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: summary.repositoryRoot ?? group.gitPath
                    )
                } label: {
                    Label("Open repository in Finder", systemImage: "folder")
                }
            } else if isRefreshing {
                Text("Reading Git metadata…")
            } else {
                Text("This project is not inside a Git repository.")
            }
            Divider()
            Button {
                openRepoAtlas()
            } label: {
                Label("Open RepoAtlas", systemImage: "map")
            }
            Button {
                Task { await gitMetadata.refresh(paths: [group.gitPath], force: true) }
            } label: {
                Label("Refresh Git status", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                if isRefreshing && summary == nil {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: gitIcon(summary))
                }
                Text(gitLabel(summary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .harvisFont(.caption)
            .foregroundColor(gitColor(summary))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: 145)
        }
        .menuStyle(.borderlessButton)
        .help(gitHelp(summary, isRefreshing: isRefreshing))
    }

    private var repoAtlasApplicationURL: URL? {
        [
            URL(fileURLWithPath: "/Applications/RepoAtlas.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/RepoAtlas.app")
        ]
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func openRepoAtlas() {
        guard let application = repoAtlasApplicationURL else { return }
        NSWorkspace.shared.openApplication(
            at: application,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @ViewBuilder
    private func branchMenu(title: String, branches: [String], current: String?) -> some View {
        Menu("\(title) (\(branches.count))") {
            if branches.isEmpty {
                Text("None")
            } else {
                ForEach(Array(branches.prefix(16)), id: \.self) { branch in
                    if branch == current {
                        Label(branch, systemImage: "checkmark")
                    } else {
                        Text(branch)
                    }
                }
                if branches.count > 16 {
                    Text("+\(branches.count - 16) more")
                }
            }
        }
    }

    private func gitIcon(_ summary: ProjectGitSummary?) -> String {
        guard let summary else { return "arrow.triangle.branch" }
        guard summary.isRepository else { return "minus.circle" }
        return summary.isDirty ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    private func gitLabel(_ summary: ProjectGitSummary?) -> String {
        guard let summary else { return "Git" }
        guard summary.isRepository else { return "No Git" }
        return summary.branch ?? "Unborn"
    }

    private func gitColor(_ summary: ProjectGitSummary?) -> Color {
        guard let summary, summary.isRepository else { return theme.muted }
        return summary.isDirty ? theme.accent2 : theme.positive
    }

    private func gitHelp(_ summary: ProjectGitSummary?, isRefreshing: Bool) -> String {
        if isRefreshing && summary == nil {
            return "Reading repository status"
        }
        guard let summary, summary.isRepository else {
            return "No Git repository found for this project"
        }
        let status = summary.isDirty ? "\(summary.changedFileCount) changed files" : "clean"
        return "\(summary.branch ?? "detached") · \(status) · \(summary.localBranches.count) local branches"
    }

    private func providerBadge(for thread: ManagedChatThread) -> some View {
        let color: Color
        switch thread.provider {
        case .codex:
            color = theme.accent
        case .dsh:
            color = theme.accent2
        case .workBuddy:
            color = theme.positive
        }
        return HStack(spacing: 4) {
            Label(thread.provider.label.uppercased(), systemImage: thread.provider.systemImage)
                .fixedSize()
            if thread.isCodex {
                Text(model.codexHome(for: thread)?.accountDisplayLabel ?? "来源账号不可用")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
            .help(thread.isCodex ? (model.codexHome(for: thread)?.accountDisplayLabel ?? "来源账号不可用") : thread.provider.label)
            .harvisFont(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.11))
            .clipShape(Capsule())
            .accessibilityLabel("Provider: \(thread.provider.label)")
    }

    private func providerOpenHelp(for thread: ManagedChatThread) -> String {
        switch thread.provider {
        case .codex:
            return "在 Codex 中打开会话，优先复用账号窗口"
        case .dsh:
            return "在 DSH 中打开此会话"
        case .workBuddy:
            return "Open WorkBuddy"
        }
    }

    private func managerThreadRow(_ thread: ManagedChatThread) -> some View {
        let tags = model.tags(for: thread)
        let isRemote = thread.isCodex && CodexThreadPreferences.hasRemoteTag(tags)
        let isDone = CodexThreadPreferences.hasDoneTag(tags)
        let isPinned = model.isThreadPinned(thread)
        let trust = thread.trustProjection
        let activity = thread.cardActivity
        let familyRunning = thread.isCardRunning
        let risk = conversationRisk(thread)
        let attention = model.attention(for: thread)
        let insightContext = conversationInsightContext(for: thread)
        let isSelected = selectedThreadID == model.managedChatStorageKey(thread)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                if familyRunning {
                    PulsingStatusDot(color: theme.positive)
                } else {
                    Circle()
                        .fill(thread.archived ? theme.muted : theme.recentStatus)
                        .frame(width: 8, height: 8)
                        .frame(width: 14, height: 14)
                }

                Button {
                    selectOrOpenThread(thread)
                } label: {
                VStack(alignment: .leading, spacing: 4) {
                    providerBadge(for: thread)
                    if thread.isCodex && thread.isSubagent {
                        HStack(spacing: 6) {
                            CodexAgentIdentityBadge(thread: thread, theme: theme)
                            if let task = thread.agentTaskLabel {
                                Text(task)
                                    .harvisFont(.caption2.monospaced())
                                    .foregroundColor(theme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if thread.isSidechat {
                        Label("SIDECHAT", systemImage: "bubble.left.and.bubble.right.fill")
                            .harvisFont(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.accent)
                    }
                    if thread.isWorkBuddy {
                        Label("WORKBUDDY", systemImage: "person.crop.circle.badge.checkmark")
                            .harvisFont(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.accent)
                    }
                    HStack(spacing: 7) {
                        Text(thread.title)
                            .harvisFont(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.text)
                            .lineLimit(2)
                        Text(
                            familyRunning
                                ? "RUNNING \(activity.total)"
                                : trust.state.rawValue.uppercased()
                        )
                                .harvisFont(.system(size: 9, weight: .bold))
                                .foregroundColor(familyRunning ? theme.positiveText : trust.state.color(in: theme))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    familyRunning
                                        ? theme.positive
                                        : trust.state.color(in: theme).opacity(0.12)
                                )
                                .clipShape(Capsule())
                        if isDone {
                            Text("DONE")
                                .harvisFont(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.muted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(theme.muted.opacity(0.10))
                                .clipShape(Capsule())
                        }
                    }
                    Text(thread.cwd)
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(thread.updatedLabel)
                        if let threadModel = thread.model, !threadModel.isEmpty {
                            Text(threadModel)
                        }
                        Text(thread.tokenLabel)
                    }
                    .harvisFont(.caption.monospacedDigit())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    if thread.capabilities.supportsCodexWorkbench && familyRunning {
                        CodexFamilyActivityBreakdown(activity: activity, theme: theme)
                    }
                    if !tags.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                                Text("#\(tag)")
                                    .harvisFont(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.accent)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.accent.opacity(0.10))
                                    .clipShape(Capsule())
                            }
                            if tags.count > 3 {
                                Text("+\(tags.count - 3)")
                                    .harvisFont(.caption2.monospacedDigit())
                                    .foregroundColor(theme.muted)
                            }
                        }
                    }
                    if !attention.isEmpty {
                        ManagedAttentionBadge(
                            preference: attention,
                            theme: theme
                        )
                    }
                    if thread.isCodex {
                        conversationMetricsBadge(thread)
                    }
                    conversationPlanBadge(thread)
                    if let insight = insightContext.status?.latestInsight {
                        ManagedConversationRelevanceBadge(
                            score: insight.relevance.currentScore,
                            isStale: insightContext.status?.isStale == true,
                            theme: theme
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .help(providerOpenHelp(for: thread))

                VStack(spacing: 6) {
                Button {
                    model.toggleThreadPin(thread)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundColor(isPinned ? theme.accent : theme.muted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin chat" : "Pin chat")
                .accessibilityLabel(isPinned ? "Unpin chat" : "Pin chat")

                Button {
                    conversationAttentionEditorThread = thread
                } label: {
                    Image(systemName: attention.isEmpty ? "star" : "star.fill")
                        .foregroundColor(attention.isEmpty ? theme.muted : theme.accent)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("设置对话重要级与关注时间")
                .accessibilityLabel("设置对话重要级与关注时间")

                conversationPlanEditButton(thread)

                Menu {
                    Button {
                        tagEditorThread = thread
                    } label: {
                        Label(tags.isEmpty ? "Add Tags" : "Edit Tags", systemImage: "tag")
                    }
                    if !tags.isEmpty {
                        Divider()
                        ForEach(tags, id: \.self) { tag in
                            Button(role: .destructive) {
                                model.removeTag(tag, from: thread)
                            } label: {
                                Label("Remove #\(tag)", systemImage: "xmark")
                            }
                        }
                    }
                } label: {
                    Image(systemName: tags.isEmpty ? "tag" : "tag.fill")
                        .foregroundColor(tags.isEmpty ? theme.muted : theme.accent)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .help(tags.isEmpty ? "Add tags" : "Edit tags")

                Button {
                    copyProjectDirectory(thread)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(theme.muted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Copy project directory")
                .accessibilityLabel("Copy project directory")

                Button {
                    copySessionID(thread)
                } label: {
                    Image(systemName: "number")
                        .foregroundColor(theme.muted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Copy session ID")
                .accessibilityLabel("Copy session ID")

                if thread.provider == .dsh || (thread.isCodex && thread.capabilities.supportsCodexWorkbench) {
                    Button {
                        inspectThread(thread)
                    } label: {
                        Image(systemName: "sidebar.right")
                            .foregroundColor(theme.accent)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Open Inspector")
                    .accessibilityLabel("Open Inspector")
                }
                }
            }

            HStack(spacing: 8) {
                supervisorCardButton(thread)
                if thread.isCodex { codexSessionActions(thread) }
                else { Spacer(minLength: 0) }
            }
            taskComposer(for: thread, compact: true)
        }
        .padding(10)
        .background(
            isSelected
                ? theme.accent.opacity(0.12)
                : (isRemote
                    ? theme.remoteSurface
                    : (familyRunning
                        ? theme.positive.opacity(0.09)
                        : (isDone ? theme.surfaceAlt.opacity(0.62) : theme.surface)))
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isSelected
                        ? theme.accent
                        : (isRemote
                            ? theme.remoteLine
                            : (familyRunning
                                ? theme.positive.opacity(0.48)
                                : (isDone ? theme.muted.opacity(0.32) : theme.line))),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .overlay(alignment: .top) {
            if risk >= .watch {
                Rectangle()
                    .fill(conversationRiskColor(risk))
                    .frame(height: CodexMatrixCardLayoutMetrics.compactionRiskBarHeight)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            conversationPlanStripe(
                thread,
                preservingTopRiskBar: risk >= .watch
            )
        }
        .overlay(alignment: .trailing) {
            if let insight = insightContext.status?.latestInsight {
                ManagedConversationRelevanceAccent(
                    score: insight.relevance.currentScore,
                    isStale: insightContext.status?.isStale == true,
                    theme: theme
                )
            }
        }
        .contextMenu {
            Button {
                model.toggleThreadPin(thread)
            } label: {
                Label(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                selectOrOpenThread(thread)
            } label: {
                Label(thread.isCodex ? "在 Desktop 中打开" : "打开会话", systemImage: "arrow.up.right.square")
            }
            if thread.isCodex {
                Button {
                    model.openManagedThreadInNewWindow(thread)
                } label: {
                    Label("在 Desktop 新窗口中打开", systemImage: "macwindow.badge.plus")
                }
                Button {
                    model.openManagedThreadInCLI(thread)
                } label: {
                    Label("在 CLI 中继续", systemImage: "terminal")
                }
            }
            Button {
                editConversationPlan(thread)
            } label: {
                Label("设置任务绑定与工作类型", systemImage: "checklist.checked")
            }
            Divider()
            Button {
                revealProjectDirectory(thread)
            } label: {
                Label("Open Project in Finder", systemImage: "folder")
            }
            Button {
                copyProjectDirectory(thread)
            } label: {
                Label("Copy Project Directory", systemImage: "doc.on.doc")
            }
            Button {
                copySessionID(thread)
            } label: {
                Label("Copy Session ID", systemImage: "number")
            }
        }
    }

    @ViewBuilder
    private func managerThreadMatrixCard(_ thread: ManagedChatThread) -> some View {
        if thread.isSidechat {
            managerSidechatMatrixCard(thread)
        } else {
            managerStandardThreadMatrixCard(thread)
        }
    }

    private func selectOrOpenThread(_ thread: ManagedChatThread) {
        model.openManagedThread(thread)
    }

    private func supervisorCardButton(_ thread: ManagedChatThread) -> some View {
        Button { supervisorThread = thread } label: {
            Label(model.supervisorCardLabel(for: thread), systemImage: "eye")
                .harvisFont(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accent)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("查看此会话的监督状态与可用控制")
        .accessibilityIdentifier("chat-manager.supervisor.\(thread.id)")
        .accessibilityLabel("监督与管理：\(thread.title)")
    }

    @ViewBuilder
    private func codexSessionActions(_ thread: ManagedChatThread) -> some View {
        if thread.isCodex {
            ManagedCodexSessionActions(
                thread: thread, theme: theme,
                inputExpanded: isComposerVisible(for: thread),
                isOpening: model.codexHome(for: thread).map { model.codexHomeActionIDs.contains($0.id) } ?? false,
                onToggleInput: { setComposerVisible(!isComposerVisible(for: thread), for: thread) },
                onDesktop: { model.openManagedThread(thread) },
                onCLI: { model.openManagedThreadInCLI(thread) }
            )
        } else {
            HStack {
                Label(thread.isDsh ? "DSH 输入" : "只读观察",
                      systemImage: thread.isDsh ? "text.bubble" : "eye")
                    .harvisFont(.system(size: 12))
                    .foregroundColor(theme.muted)
                Spacer(minLength: 0)
            }
            .frame(height: (CodexMatrixCardLayoutMetrics.actionSlotHeight * textSize.layoutScale))
        }
    }

    private func matrixSidechatTitleButton(_ thread: ManagedChatThread) -> some View {
        Button {
            selectOrOpenThread(thread)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .harvisFont(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(2)
                Label(directoryLabel(thread.cwd), systemImage: "folder")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(providerOpenHelp(for: thread))
        .frame(
            maxWidth: .infinity,
            alignment: .topLeading
        )
        .frame(height: (CodexMatrixCardLayoutMetrics.titleSlotHeight * textSize.layoutScale), alignment: .topLeading)
    }

    private func matrixStandardTitleButton(_ thread: ManagedChatThread) -> some View {
        Button {
            selectOrOpenThread(thread)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    Text(thread.title)
                        .harvisFont(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right")
                        .harvisFont(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.muted)
                        .accessibilityHidden(true)
                }
                .frame(height: 34 * textSize.layoutScale, alignment: .topLeading)
                Label(directoryLabel(thread.cwd), systemImage: "folder")
                    .harvisFont(.system(size: 11))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                Text(thread.cwd)
                    .harvisFont(.system(size: 11).monospaced())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(providerOpenHelp(for: thread))
        .accessibilityHint(providerOpenHelp(for: thread))
        .accessibilityIdentifier("chat-manager.open.\(thread.id)")
        .frame(
            maxWidth: .infinity,
            alignment: .topLeading
        )
        .frame(height: (CodexMatrixCardLayoutMetrics.titleSlotHeight * textSize.layoutScale), alignment: .topLeading)
    }

    private func matrixTagSummary(_ tags: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(tags.prefix(2)), id: \.self) { tag in
                Text("#\(tag)")
                    .harvisFont(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.10))
                    .clipShape(Capsule())
            }
            if tags.count > 2 {
                Text("+\(tags.count - 2)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }
        }
    }

    private func managerSidechatMatrixCard(_ thread: ManagedChatThread) -> some View {
        let isPinned = model.isThreadPinned(thread)
        let insightContext = conversationInsightContext(for: thread)

        return VStack(
            alignment: .leading,
            spacing: (CodexMatrixCardLayoutMetrics.sectionSpacing * textSize.layoutScale)
        ) {
            // Keep the same fixed upper slot as standard cards. Sidechat has
            // less metadata, but its composer must start on the same baseline.
            VStack(alignment: .leading, spacing: (CodexMatrixCardLayoutMetrics.contentSlotSpacing * textSize.layoutScale)) {
                HStack(spacing: 6) {
                    PulsingStatusDot(color: theme.positive)
                    providerBadge(for: thread)
                    Label("SIDECHAT", systemImage: "bubble.left.and.bubble.right.fill")
                    .harvisFont(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.accent)
                    Spacer(minLength: 4)
                    supervisorCardButton(thread)
                    Button {
                        model.toggleThreadPin(thread)
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .foregroundColor(isPinned ? theme.accent : theme.muted)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "Unpin sidechat" : "Pin sidechat")
                }
                .frame(height: (CodexMatrixCardLayoutMetrics.headerSlotHeight * textSize.layoutScale))

                HStack(spacing: 6) {
                    Label("追加到父任务", systemImage: "arrow.turn.down.right")
                        .harvisFont(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.muted)
                    Spacer(minLength: 0)
                }
                .frame(height: (CodexMatrixCardLayoutMetrics.identitySlotHeight * textSize.layoutScale))

                matrixSidechatTitleButton(thread)

                HStack {
                    Text(thread.updatedLabel)
                        .harvisFont(.system(size: 11).monospacedDigit())
                        .foregroundColor(theme.muted)
                    Spacer(minLength: 0)
                }
                .frame(height: (CodexMatrixCardLayoutMetrics.metadataSlotHeight * textSize.layoutScale))

                HStack(spacing: 5) {
                    conversationPlanBadge(thread)
                    if let insight = insightContext.status?.latestInsight {
                        ManagedConversationRelevanceBadge(
                            score: insight.relevance.currentScore,
                            isStale: insightContext.status?.isStale == true,
                            theme: theme
                        )
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: (CodexMatrixCardLayoutMetrics.managementSlotHeight * textSize.layoutScale))
            }
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
            .frame(height: (CodexMatrixCardLayoutMetrics.contentSlotHeight * textSize.layoutScale), alignment: .topLeading)
            .clipped()

            codexSessionActions(thread)
            taskComposer(for: thread, compact: false)

            Divider()
                .overlay(theme.line)

            HStack(spacing: 6) {
                conversationPlanEditButton(thread)
                Text(thread.updatedLabel)
                    .harvisFont(.system(size: 11).monospacedDigit())
                    .foregroundColor(theme.muted)
                Spacer(minLength: 0)
                Button {
                    copyProjectDirectory(thread)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.muted)
                .help("Copy project directory")
                Button {
                    copySessionID(thread)
                } label: {
                    Image(systemName: "number")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.muted)
                .help("Copy session ID")
            }
            .frame(height: (CodexMatrixCardLayoutMetrics.footerHeight * textSize.layoutScale))
        }
        .padding((CodexMatrixCardLayoutMetrics.cardPadding * textSize.layoutScale))
        .frame(
            maxWidth: .infinity,
            alignment: .topLeading
        )
        .frame(
            height: CodexMatrixCardLayoutMetrics.cardHeight(for: .sidechat) * textSize.layoutScale,
            alignment: .topLeading
        )
        .background(theme.positive.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(theme.positive.opacity(0.42), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            conversationPlanStripe(thread, preservingTopRiskBar: false)
        }
        .overlay(alignment: .trailing) {
            if let insight = insightContext.status?.latestInsight {
                ManagedConversationRelevanceAccent(
                    score: insight.relevance.currentScore,
                    isStale: insightContext.status?.isStale == true,
                    theme: theme
                )
            }
        }
        .contextMenu {
            Button {
                selectOrOpenThread(thread)
            } label: {
                Label("Open Sidechat", systemImage: "arrow.up.right.square")
            }
            Button {
                editConversationPlan(thread)
            } label: {
                Label("设置任务绑定与工作类型", systemImage: "checklist.checked")
            }
            Button {
                revealProjectDirectory(thread)
            } label: {
                Label("Open Project in Finder", systemImage: "folder")
            }
            Button {
                copyProjectDirectory(thread)
            } label: {
                Label("Copy Project Directory", systemImage: "doc.on.doc")
            }
            Button {
                copySessionID(thread)
            } label: {
                Label("Copy Session ID", systemImage: "number")
            }
        }
    }

    private func managerStandardThreadMatrixCard(_ thread: ManagedChatThread) -> some View {
        let tags = model.tags(for: thread)
        let isRemote = thread.isCodex && CodexThreadPreferences.hasRemoteTag(tags)
        let isDone = CodexThreadPreferences.hasDoneTag(tags)
        let isPinned = model.isThreadPinned(thread)
        let trust = thread.trustProjection
        let activity = thread.cardActivity
        let familyRunning = thread.isCardRunning
        let risk = conversationRisk(thread)
        let attention = model.attention(for: thread)
        let insightContext = conversationInsightContext(for: thread)
        let isSelected = selectedThreadID == model.managedChatStorageKey(thread)

        return VStack(
            alignment: .leading,
            spacing: (CodexMatrixCardLayoutMetrics.sectionSpacing * textSize.layoutScale)
        ) {
            // Every card gets the same measured upper slot. Keep optional
            // provider/activity/management details inside compact rows so they
            // cannot push the composer down for only one card in a grid row.
            VStack(alignment: .leading, spacing: (CodexMatrixCardLayoutMetrics.contentSlotSpacing * textSize.layoutScale)) {
                HStack(spacing: 7) {
                    if familyRunning {
                        PulsingStatusDot(color: theme.positive)
                    } else {
                        Circle()
                            .fill(thread.archived ? theme.muted : theme.recentStatus)
                            .frame(width: 8, height: 8)
                            .frame(width: 14, height: 14)
                    }
                    Text(
                        familyRunning
                            ? "RUNNING \(activity.total)"
                            : trust.state.rawValue.uppercased()
                    )
                        .harvisFont(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .foregroundColor(familyRunning ? theme.positiveText : trust.state.color(in: theme))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            familyRunning
                                ? theme.positive
                                : trust.state.color(in: theme).opacity(0.12)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if isDone {
                        Text("DONE")
                            .harvisFont(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(theme.muted.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 4)
                    supervisorCardButton(thread)
                    Button {
                        model.toggleThreadPin(thread)
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .foregroundColor(isPinned ? theme.accent : theme.muted)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "Unpin chat" : "Pin chat")
                }
                .frame(height: (CodexMatrixCardLayoutMetrics.headerSlotHeight * textSize.layoutScale))

                HStack(spacing: 6) {
                    providerBadge(for: thread)
                    if thread.capabilities.supportsCodexWorkbench && familyRunning {
                        CodexFamilyActivityBreakdown(activity: activity, theme: theme)
                    }
                    if thread.isWorkBuddy {
                        Label("WORKBUDDY", systemImage: "person.crop.circle.badge.checkmark")
                            .harvisFont(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.accent)
                    }
                    if thread.isCodex && thread.isSubagent {
                        CodexAgentIdentityBadge(thread: thread, theme: theme)
                        if let task = thread.agentTaskLabel {
                            Text(task)
                                .harvisFont(.caption2.monospaced())
                                .foregroundColor(theme.muted)
                                .lineLimit(1)
                        }
                    }
                    if thread.isSidechat {
                        Label("SIDECHAT", systemImage: "bubble.left.and.bubble.right.fill")
                            .harvisFont(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.accent)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: (CodexMatrixCardLayoutMetrics.identitySlotHeight * textSize.layoutScale))
                .clipped()

                matrixStandardTitleButton(thread)

                HStack(spacing: 7) {
                    Text(thread.updatedLabel)
                    if let threadModel = thread.model, !threadModel.isEmpty {
                        Text(threadModel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(thread.tokenLabel)
                }
                .harvisFont(.system(size: 11).monospacedDigit())
                .foregroundColor(theme.muted)
                .frame(height: (CodexMatrixCardLayoutMetrics.metadataSlotHeight * textSize.layoutScale))

                HStack(spacing: 5) {
                    conversationPlanBadge(thread)
                    if !tags.isEmpty {
                        matrixTagSummary(tags)
                    }
                    if !attention.isEmpty {
                        ManagedAttentionBadge(
                            preference: attention,
                            theme: theme
                        )
                    }
                    if thread.isCodex {
                        conversationMetricsBadge(thread)
                    }
                    if let insight = insightContext.status?.latestInsight {
                        ManagedConversationRelevanceBadge(
                            score: insight.relevance.currentScore,
                            isStale: insightContext.status?.isStale == true,
                            theme: theme
                        )
                    }
                    Spacer(minLength: 0)
                }
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .frame(height: (CodexMatrixCardLayoutMetrics.managementSlotHeight * textSize.layoutScale), alignment: .leading)
                .clipped()
            }
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
            .frame(height: (CodexMatrixCardLayoutMetrics.contentSlotHeight * textSize.layoutScale), alignment: .topLeading)
            .clipped()

            codexSessionActions(thread)
            taskComposer(for: thread, compact: false)

            Divider()
                .overlay(theme.line)

            HStack {
                Button {
                    conversationAttentionEditorThread = thread
                } label: {
                    Image(systemName: attention.isEmpty ? "star" : "star.fill")
                        .foregroundColor(attention.isEmpty ? theme.muted : theme.accent)
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .help("设置对话重要级与关注时间")
                .accessibilityLabel("设置对话重要级与关注时间")

                conversationPlanEditButton(thread, size: 24)

                Menu {
                    Button {
                        tagEditorThread = thread
                    } label: {
                        Label(tags.isEmpty ? "Add Tags" : "Edit Tags", systemImage: "tag")
                    }
                    if !tags.isEmpty {
                        Divider()
                        ForEach(tags, id: \.self) { tag in
                            Button(role: .destructive) {
                                model.removeTag(tag, from: thread)
                            } label: {
                                Label("Remove #\(tag)", systemImage: "xmark")
                            }
                        }
                    }
                } label: {
                    Image(systemName: tags.isEmpty ? "tag" : "tag.fill")
                        .foregroundColor(tags.isEmpty ? theme.muted : theme.accent)
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .help(tags.isEmpty ? "Add tags" : "Edit tags")

                Spacer()

                Button {
                    copyProjectDirectory(thread)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.muted)
                .help("Copy project directory")
                .accessibilityLabel("Copy project directory")

                Button {
                    copySessionID(thread)
                } label: {
                    Image(systemName: "number")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.muted)
                .help("Copy session ID")
                .accessibilityLabel("Copy session ID")

                if thread.provider == .dsh || (thread.isCodex && thread.capabilities.supportsCodexWorkbench) {
                    Button {
                        inspectThread(thread)
                    } label: {
                        Label("Inspect", systemImage: "sidebar.right")
                            .harvisFont(.caption)
                            .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Open Inspector")
                }
            }
            .frame(height: (CodexMatrixCardLayoutMetrics.footerHeight * textSize.layoutScale))
        }
        .padding((CodexMatrixCardLayoutMetrics.cardPadding * textSize.layoutScale))
        .frame(
            maxWidth: .infinity,
            alignment: .topLeading
        )
        .frame(
            height: CodexMatrixCardLayoutMetrics.cardHeight(for: .standard) * textSize.layoutScale,
            alignment: .topLeading
        )
        .background(
            isSelected
                ? theme.accent.opacity(0.12)
                : (isRemote
                    ? theme.remoteSurface
                    : (familyRunning
                        ? theme.positive.opacity(0.09)
                        : (isDone ? theme.surfaceAlt.opacity(0.62) : theme.surface)))
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isSelected
                        ? theme.accent
                        : (isRemote
                            ? theme.remoteLine
                            : (familyRunning
                                ? theme.positive.opacity(0.48)
                                : (isDone ? theme.muted.opacity(0.32) : theme.line))),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .overlay(alignment: .top) {
            if risk >= .watch {
                Rectangle()
                    .fill(conversationRiskColor(risk))
                    .frame(height: CodexMatrixCardLayoutMetrics.compactionRiskBarHeight)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            conversationPlanStripe(
                thread,
                preservingTopRiskBar: risk >= .watch
            )
        }
        .overlay(alignment: .trailing) {
            if let insight = insightContext.status?.latestInsight {
                ManagedConversationRelevanceAccent(
                    score: insight.relevance.currentScore,
                    isStale: insightContext.status?.isStale == true,
                    theme: theme
                )
            }
        }
        .contextMenu {
            Button {
                model.toggleThreadPin(thread)
            } label: {
                Label(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                model.openManagedThread(thread)
            } label: {
                Label(thread.isCodex ? "在 Desktop 中打开" : "打开会话", systemImage: "arrow.up.right.square")
            }
            if thread.isCodex {
                Button {
                    model.openManagedThreadInNewWindow(thread)
                } label: {
                    Label("在 Desktop 新窗口中打开", systemImage: "macwindow.badge.plus")
                }
                Button {
                    model.openManagedThreadInCLI(thread)
                } label: {
                    Label("在 CLI 中继续", systemImage: "terminal")
                }
            }
            Button {
                editConversationPlan(thread)
            } label: {
                Label("设置任务绑定与工作类型", systemImage: "checklist.checked")
            }
            Divider()
            Button {
                revealProjectDirectory(thread)
            } label: {
                Label("Open Project in Finder", systemImage: "folder")
            }
            Button {
                copyProjectDirectory(thread)
            } label: {
                Label("Copy Project Directory", systemImage: "doc.on.doc")
            }
            Button {
                copySessionID(thread)
            } label: {
                Label("Copy Session ID", systemImage: "number")
            }
        }
    }

    private func managerMessage(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: systemImage)
                .harvisFont(.system(size: 30))
                .foregroundColor(theme.muted)
            Text(title)
                .harvisFont(.headline)
            Text(detail)
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CodexThreadTagEditor: View {
    @Environment(\.dismiss) private var dismiss

    let thread: ManagedChatThread
    let theme: HarvisTheme
    let onSave: ([String]) -> Void

    @State private var tagsText: String

    init(
        thread: ManagedChatThread,
        initialTags: [String],
        theme: HarvisTheme,
        onSave: @escaping ([String]) -> Void
    ) {
        self.thread = thread
        self.theme = theme
        self.onSave = onSave
        _tagsText = State(initialValue: initialTags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .foregroundColor(theme.accent)
                Text("Session Tags")
                    .harvisFont(.headline)
            }
            Text(thread.title)
                .harvisFont(.subheadline)
                .foregroundColor(theme.muted)
                .lineLimit(2)
            TextField("Tags", text: $tagsText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack(spacing: 8) {
                Text("Quick tag")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                Button {
                    addRemoteTag()
                } label: {
                    Label(
                        hasRemoteTag ? "Remote added" : "Add Remote",
                        systemImage: hasRemoteTag ? "checkmark.circle.fill" : "plus.circle"
                    )
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(hasRemoteTag)
                .accessibilityLabel(hasRemoteTag ? "Remote tag added" : "Add remote tag")
                Spacer()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(theme.background)
        .foregroundColor(theme.text)
        .tint(theme.accent)
    }

    private var parsedTags: [String] {
        let separators = CharacterSet(charactersIn: ",;，；")
        return tagsText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var hasRemoteTag: Bool {
        CodexThreadPreferences.hasRemoteTag(parsedTags)
    }

    private func addRemoteTag() {
        guard !hasRemoteTag else { return }
        tagsText = (parsedTags + ["remote"]).joined(separator: ", ")
    }

    private func save() {
        onSave(parsedTags)
        dismiss()
    }
}
