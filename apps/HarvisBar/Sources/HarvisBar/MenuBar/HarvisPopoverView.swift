import AppKit
import Foundation
import SwiftUI

struct HarvisStatusLabel: View {
    @EnvironmentObject var model: HarvisRuntimeModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.tintColor)
                .frame(width: 8, height: 8)
            Text("H.A.R.V.I.S.")
                .font(.system(size: 11, weight: .semibold))
            if let pending = model.barStatus?.work?.pendingApprovals, pending > 0 {
                Text("\(pending)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
            }
        }
        .help(model.shortSummary)
    }
}

enum HarvisBarSection: String, CaseIterable, Identifiable {
    case overview
    case codex
    case agents
    case system
    case network
    case dsh
    case ports
    case tools
    case work
    case review
    case memory
    case persona

    static let primarySections: [HarvisBarSection] = [.overview, .codex, .agents, .system]
    static let utilitySections: [HarvisBarSection] = [.network, .dsh, .ports, .tools]
    static let digitalMeSections: [HarvisBarSection] = [.work, .review, .memory, .persona]
    static let navigationRows: [[HarvisBarSection]] = [
        primarySections,
        utilitySections,
        digitalMeSections,
    ]

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .overview: return "甲"
        case .codex: return "乙"
        case .agents: return "丙"
        case .system: return "丁"
        case .network: return "A"
        case .dsh: return "B"
        case .ports: return "C"
        case .tools: return "D"
        case .work: return "1"
        case .review: return "2"
        case .memory: return "3"
        case .persona: return "4"
        }
    }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .codex: return "Codex"
        case .agents: return "Agent"
        case .system: return "Harvis"
        case .network: return "Network"
        case .dsh: return "DSH"
        case .ports: return "Ports"
        case .tools: return "Tools"
        case .work: return "Work"
        case .review: return "Review"
        case .memory: return "Memory"
        case .persona: return "Persona"
        }
    }
}

struct HarvisPopoverView: View {
    @EnvironmentObject var model: HarvisRuntimeModel
    @State var selectedSection: HarvisBarSection = .overview
    @State var quickCredentialKey = ""
    @State var quickCredentialValue = ""
    @State var quickCredentialKeywords = ""
    @State var droppedFileURLs: [URL] = []
    @State var isFileDropTargeted = false
    @State var dshManagementLayer: DshManagementLayer = .launch
    @State var dshSelectedHomeID = ""
    @State var dshShortcutHomes: [DshHomeCatalogItem] = []
    @State var dshShortcutLoading = false
    @State var dshShortcutError: String?
    @State var dshShortcutLaunchingIDs: Set<String> = []
    @State var codexHomePendingRename: CodexHome?
    @State var showCodexAccountAddSheet = false
    @State var selectedAgentLaunchKind: AgentLaunchKind = .cli
    @State var digitalMeNavigationNow = Date()
    @State var diskActionMessage: String?
    @State var diskActionSucceeded = true
    @State var refreshActionRunningIDs: Set<String> = []
    @State var refreshActionCompletions: [String: Int] = [:]
    @StateObject var digitalMeNavigation = DigitalMeNavigationStore()

    var theme: HarvisTheme { model.theme }

    func startTrackedRefresh(
        _ identifier: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard !refreshActionRunningIDs.contains(identifier) else { return }
        refreshActionRunningIDs.insert(identifier)
        Task { @MainActor in
            await operation()
            refreshActionRunningIDs.remove(identifier)
            refreshActionCompletions[identifier, default: 0] += 1
        }
    }

    func trackedRefreshAccessibilityValue(
        _ identifier: String,
        externallyRunning: Bool = false
    ) -> String {
        if externallyRunning || refreshActionRunningIDs.contains(identifier) {
            return "Refreshing"
        }
        if let count = refreshActionCompletions[identifier] {
            return "Completed \(count)"
        }
        return "Ready"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            topMenuSection
            sectionPicker
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                selectedSectionContent
                    if let error = model.lastError {
                        messageBox(title: "Attention", message: error, color: .red)
                            .accessibilityIdentifier("harvis-global-attention")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selectedSection)
            Button {
                UnifiedVersionCatalogWindowController.shared.show(runtime: model)
            } label: {
                HStack {
                    Label("版本管理", systemImage: "square.stack.3d.up")
                    Spacer()
                    Text("Harvis · DSH · 插件 · 仓库").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("harvis-unified-versions-entry")
            .help("统一查看版本、源码与安装地址；提供 Agent JSON 和 Schema")
            actionSection
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .foregroundColor(theme.text)
        .tint(theme.accent)
        .preferredColorScheme(theme.preferredColorScheme)
        .task {
            guard !HarvisAppMode.isVersionFixture else { return }
            await model.refreshCodexCLIAlignment()
        }
        .task(id: digitalMeNavigationContext) {
            guard !HarvisAppMode.isVersionFixture else { return }
            await monitorDigitalMeNavigationContext()
        }
        .task(id: selectedSection) {
            guard !HarvisAppMode.isVersionFixture else { return }
            await refreshDigitalMeNavigationForSelectedSection()
        }
        .sheet(item: $codexHomePendingRename) { home in
            CodexAccountRenameSheet(home: home, theme: theme) { note in
                model.renameCodexAccountNote(home, note: note)
            }
        }
        .sheet(isPresented: $showCodexAccountAddSheet) {
            CodexAccountAddSheet(
                initialWorkspace: model.expanded(model.workspaceRoot),
                theme: theme
            ) { label, workspace in
                model.addManagedCodexAccount(label: label, workspacePath: workspace)
            }
        }
    }

    private var sectionPicker: some View {
        VStack(spacing: 3) {
            ForEach(
                Array(HarvisBarSection.navigationRows.enumerated()),
                id: \.offset
            ) { _, sections in
                sectionPickerRow(sections)
            }
        }
        .padding(3)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line))
    }

    private func sectionPickerRow(_ sections: [HarvisBarSection]) -> some View {
        HStack(spacing: 3) {
            ForEach(sections) { section in
                sectionPickerButton(section)
            }
        }
    }

    private func sectionPickerButton(_ section: HarvisBarSection) -> some View {
        Button {
            selectedSection = section
            if section == .codex {
                model.refreshCodexHomeList()
            }
            if section == .agents {
                model.refreshCatop()
            }
            if section == .dsh {
                refreshDshShortcuts()
            }
        } label: {
            Text("\(section.shortTitle)·\(section.title)")
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundColor(selectedSection == section ? theme.selectionText : theme.text)
                .background(selectedSection == section ? theme.selectionFill : theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            selectedSection == section ? theme.selectionFill : theme.muted.opacity(0.78),
                            lineWidth: selectedSection == section ? 1.5 : 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if section == .review,
                       digitalMeSnapshot.review.knownAttentionCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(sectionPickerHelp(section))
        .accessibilityLabel(sectionPickerAccessibilityLabel(section))
        .accessibilityValue(sectionPickerAccessibilityValue(section))
        .accessibilityIdentifier("harvis.section.\(section.rawValue)")
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    @ViewBuilder
    var selectedSectionContent: some View {
        switch selectedSection {
        case .overview:
            if model.firstRunReadyCount != model.firstRunSteps.count {
                firstRunSection
            }
            themeSection
            runtimeSection
            taskProgressSection
            systemSection
            remoteStudioSection
            codexCLIAlignmentSection
        case .codex:
            Group {
                codexChatLauncherSection
                codexProcessSection
                codexObservabilitySection
                codexHomesSection
                codexChatsSection
                codexSection
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
        case .agents:
            catopSection
            agentMailSection
            harnessSection
            knowledgeSection
        case .system:
            Group {
                serviceSection
                FinderContextMenuPopoverSection()
                PermissionWatcherControls(watcher: .shared, compact: true)
                settingsSection
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
        case .network:
            networkConsoleSection
            proxySection
            perAppProxySection
        case .dsh:
            dshServiceSection
        case .ports:
            portSection
        case .tools:
            quickCredentialBank
            quickFileDrop
        case .work:
            digitalMeWorkSection
        case .review:
            digitalMeReviewSection
        case .memory:
            digitalMeMemorySection
        case .persona:
            digitalMePersonaSection
        }
    }
}
