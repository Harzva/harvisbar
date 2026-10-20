import SwiftUI

private extension ManagedProjectRecord {
    var reviewName: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名项目" : value
    }
}

private extension ManagedProjectOrganizationConversation {
    var reviewTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名会话" : value
    }
}

private extension ManagedProjectOrganizerAction {
    var reviewLabel: String {
        switch self {
        case .assign: return "调整到已有项目"
        case .createSubproject: return "新建子项目建议"
        case .keep: return "保持现状"
        }
    }

    var reviewSystemImage: String {
        switch self {
        case .assign: return "arrow.triangle.branch"
        case .createSubproject: return "folder.badge.plus"
        case .keep: return "checkmark.circle"
        }
    }
}

private extension ManagedProjectOrganizerConfidence {
    var reviewLabel: String {
        switch self {
        case .strong: return "较有把握"
        case .needsReview: return "需要复核"
        }
    }

    var reviewSystemImage: String {
        switch self {
        case .strong: return "checkmark.seal"
        case .needsReview: return "questionmark.diamond"
        }
    }
}

enum ManagedProjectOrganizerReviewAnalysisStatus: Hashable, Sendable {
    case idle
    case analyzing
    case ready
    case applying
    case applied
    case cancelled
    case failed

    var label: String {
        switch self {
        case .idle: return "等待分析"
        case .analyzing: return "正在分析"
        case .ready: return "分析完成"
        case .applying: return "校验并应用"
        case .applied: return "已应用"
        case .cancelled: return "已取消"
        case .failed: return "分析失败"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "circle.dashed"
        case .analyzing: return "progress.indicator"
        case .ready: return "checkmark.circle.fill"
        case .applying: return "arrow.triangle.2.circlepath"
        case .applied: return "checkmark.seal.fill"
        case .cancelled: return "nosign"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

struct ManagedProjectOrganizerReviewAnalysis: Hashable, Sendable {
    let status: ManagedProjectOrganizerReviewAnalysisStatus
    let coverage: String?
    let feedback: String?

    init(
        status: ManagedProjectOrganizerReviewAnalysisStatus = .idle,
        coverage: String? = nil,
        feedback: String? = nil
    ) {
        self.status = status
        self.coverage = coverage
        self.feedback = feedback
    }
}

/// Review-only UI for project organizer suggestions.
///
/// Applying a suggestion is always delegated to `onApply`; this view never
/// writes a record, creates a folder, or starts a task. `onUndo` lets the
/// runtime reverse a previously applied suggestion without coupling the sheet
/// to its persistence layer.
struct ManagedProjectOrganizerReviewView: View {
    @Binding var proposal: ManagedProjectOrganizerProposal
    let catalog: [ManagedProjectRecord]
    let analysis: ManagedProjectOrganizerReviewAnalysis
    let theme: HarvisTheme
    let onAnalyze: () -> Void
    let onClose: () -> Void
    let onCancelAnalysis: () -> Void
    let onApply: ([String]) -> Void
    let onUndo: (String) -> Void
    let latestReceipt: ManagedProjectOrganizationReceipt?
    let groupxReview: ManagedProjectGroupxReviewPresentation?
    let onGroupxStart: () -> Void
    let onGroupxCancel: () -> Void
    let onGroupxSelectHost: (String) -> Void

    @State private var expandedSuggestionIDs: Set<String> = []

    init(
        proposal: Binding<ManagedProjectOrganizerProposal>,
        catalog: [ManagedProjectRecord],
        analysis: ManagedProjectOrganizerReviewAnalysis,
        theme: HarvisTheme,
        onAnalyze: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onCancelAnalysis: @escaping () -> Void,
        onApply: @escaping ([String]) -> Void,
        onUndo: @escaping (String) -> Void,
        latestReceipt: ManagedProjectOrganizationReceipt? = nil,
        groupxReview: ManagedProjectGroupxReviewPresentation? = nil,
        onGroupxStart: @escaping () -> Void = {},
        onGroupxCancel: @escaping () -> Void = {},
        onGroupxSelectHost: @escaping (String) -> Void = { _ in }
    ) {
        self._proposal = proposal
        self.catalog = catalog
        self.analysis = analysis
        self.theme = theme
        self.onAnalyze = onAnalyze
        self.onClose = onClose
        self.onCancelAnalysis = onCancelAnalysis
        self.onApply = onApply
        self.onUndo = onUndo
        self.latestReceipt = latestReceipt
        self.groupxReview = groupxReview
        self.onGroupxStart = onGroupxStart
        self.onGroupxCancel = onGroupxCancel
        self.onGroupxSelectHost = onGroupxSelectHost
    }

    private var selectedSuggestions: [ManagedProjectOrganizerSuggestion] {
        proposal.suggestions.filter { $0.isSelected && $0.action != .keep }
    }

    private var canApply: Bool {
        analysis.status == .ready && !selectedSuggestions.isEmpty
    }

    private var targetProjects: [ManagedProjectRecord] {
        var result = catalog
        var seen = Set(result.map(\.id))
        for suggestion in proposal.suggestions where suggestion.action == .createSubproject {
            guard let project = suggestion.proposedProject,
                  seen.insert(project.id).inserted else { continue }
            result.append(project)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    analysisNotice
                    analysisStatus
                    if let groupxReview {
                        ManagedProjectGroupxReviewView(
                            presentation: groupxReview, theme: theme,
                            onStart: onGroupxStart, onCancel: onGroupxCancel,
                            onSelectHost: onGroupxSelectHost
                        )
                    }
                    suggestionList
                }
                .padding(16)
            }
            Divider().overlay(theme.line)
            footer
        }
        .frame(
            minWidth: 560,
            idealWidth: 720,
            maxWidth: 760,
            minHeight: 480,
            idealHeight: 700,
            maxHeight: 700
        )
        .background(theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-organizer.review")
        .accessibilityLabel("AI 项目整理审核")
        .onExitCommand {
            guard analysis.status != .applying else { return }
            onClose()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "wand.and.stars")
                .harvisFont(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 项目整理审核")
                    .harvisFont(.headline)
                    .foregroundColor(theme.text)
                Text("只审核归属建议，应用前请逐项确认")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .harvisFont(.caption.bold())
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.muted)
            .background(theme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(analysis.status == .applying)
            .accessibilityIdentifier("project-organizer.close")
            .accessibilityLabel("关闭项目整理审核")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var analysisNotice: some View {
        Label(
            "将项目名称与目标、会话标题及必要用户输入片段交给专用 AI 分析；建议需审核后应用",
            systemImage: "hand.raised.fill"
        )
        .harvisFont(.caption2)
        .foregroundColor(theme.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceAlt.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityIdentifier("project-organizer.ai-notice")
    }

    private var analysisStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Label(analysis.status.label, systemImage: analysis.status.systemImage)
                    .harvisFont(.caption.bold())
                    .foregroundColor(statusColor)
                Spacer(minLength: 5)
                Button {
                    onAnalyze()
                } label: {
                    Label(
                        analysis.status == .ready ? "重新分析" : "开始分析",
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(analysis.status == .analyzing || analysis.status == .applying)
                .accessibilityIdentifier("project-organizer.analyze")
            }
            if let coverage = nonempty(analysis.coverage) {
                Text(coverage)
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let feedback = nonempty(analysis.feedback) {
                Text(feedback)
                    .harvisFont(.caption2)
                    .foregroundColor(analysis.status == .failed ? theme.accent2 : theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if analysis.status == .analyzing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在分析")
                    Button("取消分析") {
                        onCancelAnalysis()
                    }
                    .buttonStyle(.plain)
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .accessibilityIdentifier("project-organizer.cancel-analysis")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-organizer.analysis-status")
    }

    @ViewBuilder
    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("建议 \(proposal.suggestions.count)")
                    .harvisFont(.caption.bold())
                    .foregroundColor(theme.text)
                Spacer(minLength: 6)
                Text("已选择 \(selectedSuggestions.count)")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }

            if proposal.suggestions.isEmpty {
                Text("当前没有可审核的项目整理建议。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                    .accessibilityIdentifier("project-organizer.empty")
            } else {
                ForEach(proposal.suggestions.indices, id: \.self) { index in
                    suggestionRow(index: index)
                }
            }
        }
        .accessibilityIdentifier("project-organizer.suggestions")
    }

    private func suggestionRow(index: Int) -> some View {
        let suggestion = proposal.suggestions[index]
        let directConversationIDs = Set(suggestion.conversationIDs)
        let childConversationIDs: Set<String>
        if suggestion.action == .createSubproject,
           let projectID = suggestion.proposedProject?.id {
            childConversationIDs = Set(
                proposal.suggestions
                    .filter { $0.action == .assign && $0.targetProjectID == projectID }
                    .flatMap(\.conversationIDs)
            )
        } else {
            childConversationIDs = []
        }
        let relatedConversationIDs = directConversationIDs.union(childConversationIDs)
        let relatedConversations = proposal.snapshots.filter {
            relatedConversationIDs.contains($0.id)
        }
        let isExpanded = expandedSuggestionIDs.contains(suggestion.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Toggle(
                    isOn: Binding(
                        get: { proposal.suggestions[index].isSelected },
                        set: { proposal.suggestions[index].isSelected = $0 }
                    )
                ) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(suggestion.action == .keep || analysis.status == .applying)
                .accessibilityIdentifier("project-organizer.suggestion.\(suggestion.id).select")
                .accessibilityLabel("选择建议")

                Image(systemName: suggestion.action.reviewSystemImage)
                    .foregroundColor(theme.accent)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(suggestion.action.reviewLabel)
                            .harvisFont(.caption.bold())
                            .foregroundColor(theme.text)
                        confidenceBadge(suggestion.confidence)
                    }
                    if relatedConversations.isEmpty {
                        Text("未找到会话快照")
                            .harvisFont(.caption2)
                            .foregroundColor(theme.accent2)
                    } else {
                        ForEach(relatedConversations.prefix(3)) { conversation in
                            conversationLine(conversation: conversation, suggestion: suggestion)
                        }
                        if relatedConversations.count > 3 {
                            Text("另有 \(relatedConversations.count - 3) 个会话")
                                .harvisFont(.system(size: 9))
                                .foregroundColor(theme.muted)
                        }
                    }
                }
                Spacer(minLength: 4)
                Button {
                    toggleExpanded(suggestion.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .harvisFont(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.muted)
                .accessibilityIdentifier("project-organizer.suggestion.\(suggestion.id).evidence")
                .accessibilityLabel(isExpanded ? "收起证据" : "展开证据")
            }

            suggestionEditor(index: index)

            if isExpanded {
                evidencePanel(suggestion)
            }

        }
        .padding(11)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(suggestion.isSelected ? theme.accent.opacity(0.68) : theme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-organizer.suggestion.\(suggestion.id)")
    }

    private func conversationLine(
        conversation: ManagedProjectOrganizationConversation,
        suggestion: ManagedProjectOrganizerSuggestion
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(conversation.reviewTitle)
                    .harvisFont(.caption2.bold())
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Text(conversation.provider.isEmpty ? "未知来源" : conversation.provider)
                    .harvisFont(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.muted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(theme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            HStack(spacing: 4) {
                Text(projectLabel(conversation.effectiveProject.label))
                Image(systemName: "arrow.right")
                    .harvisFont(.system(size: 8, weight: .bold))
                Text(destinationLabel(for: suggestion))
            }
            .harvisFont(.system(size: 9, design: .monospaced))
            .foregroundColor(theme.muted)
            .lineLimit(1)
            Text("原始路径：\(projectPathLabel(conversation.sourceProject))")
                .harvisFont(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.muted.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)
                .help("原始 cwd 路径，仅用于来源说明")
        }
    }

    @ViewBuilder
    private func suggestionEditor(index: Int) -> some View {
        let action = proposal.suggestions[index].action
        VStack(alignment: .leading, spacing: 7) {
            switch action {
            case .assign:
                existingProjectPicker(index: index)
            case .createSubproject:
                newSubprojectEditor(index: index)
            case .keep:
                Text("保持现状：无需应用此建议。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }
        }
    }

    private func existingProjectPicker(index: Int) -> some View {
        Picker(
            "目标项目",
            selection: Binding(
                get: { proposal.suggestions[index].targetProjectID ?? "" },
                set: { proposal.suggestions[index].targetProjectID = $0.isEmpty ? nil : $0 }
            )
        ) {
            Text("选择目标项目").tag("")
            ForEach(targetProjects) { project in
                Text(project.reviewName).tag(project.id)
            }
        }
        .pickerStyle(.menu)
        .harvisFont(.caption2)
        .tint(theme.accent)
        .disabled(analysis.status == .applying)
        .accessibilityIdentifier("project-organizer.suggestion.\(proposal.suggestions[index].id).target")
    }

    @ViewBuilder
    private func newSubprojectEditor(index: Int) -> some View {
        if proposal.suggestions[index].proposedProject == nil {
            Button {
                let parentID = proposal.snapshots
                    .first(where: { snapshot in
                        catalog.contains { $0.id == snapshot.effectiveProject.id }
                    })?
                    .effectiveProject.id ?? catalog.first?.id
                proposal.suggestions[index].proposedProject = ManagedProjectRecord(
                    name: "",
                    purpose: "",
                    parentID: parentID,
                    path: nil
                )
            } label: {
                Label("填写子项建议", systemImage: "plus.circle")
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .disabled(analysis.status == .applying)
            .accessibilityIdentifier("project-organizer.suggestion.\(proposal.suggestions[index].id).new")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "子项目名称",
                    text: Binding(
                        get: { proposal.suggestions[index].proposedProject?.name ?? "" },
                        set: { proposal.suggestions[index].proposedProject?.name = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .harvisFont(.caption)
                .accessibilityIdentifier("project-organizer.suggestion.\(proposal.suggestions[index].id).name")
                .disabled(analysis.status == .applying)

                TextField(
                    "用途（必填）",
                    text: Binding(
                        get: { proposal.suggestions[index].proposedProject?.purpose ?? "" },
                        set: { proposal.suggestions[index].proposedProject?.purpose = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .harvisFont(.caption)
                .accessibilityIdentifier("project-organizer.suggestion.\(proposal.suggestions[index].id).purpose")
                .disabled(analysis.status == .applying)

                TextField(
                    "关联路径（可选）",
                    text: Binding(
                        get: { proposal.suggestions[index].proposedProject?.path ?? "" },
                        set: { proposal.suggestions[index].proposedProject?.path = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .harvisFont(.system(size: 10, design: .monospaced))
                .accessibilityIdentifier("project-organizer.suggestion.\(proposal.suggestions[index].id).path")
                .disabled(analysis.status == .applying)
                Text("路径只作为关联，不会创建文件夹。")
                    .harvisFont(.system(size: 9))
                    .foregroundColor(theme.muted)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project-organizer.suggestion.\(proposal.suggestions[index].id).new-fields")
        }
    }

    private func evidencePanel(_ suggestion: ManagedProjectOrganizerSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("分析依据")
                .harvisFont(.caption2.bold())
                .foregroundColor(theme.text)
            Text(nonempty(suggestion.reason) ?? "未提供理由。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if suggestion.evidence.isEmpty {
                Text("未提供额外证据。")
                    .harvisFont(.system(size: 9))
                    .foregroundColor(theme.muted)
            } else {
                ForEach(Array(suggestion.evidence.enumerated()), id: \.offset) { _, evidence in
                    Label(evidence, systemImage: "quote.bubble")
                        .harvisFont(.system(size: 9))
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(9)
        .background(theme.surfaceAlt.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("project-organizer.suggestion.\(suggestion.id).evidence-panel")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let latestReceipt {
                HStack(spacing: 8) {
                    Label(
                        "已调整 \(latestReceipt.appliedConversationCount) 个会话 / 新建 \(latestReceipt.createdProjectCount) 个项目",
                        systemImage: latestReceipt.isUndone ? "arrow.uturn.backward.circle" : "checkmark.seal"
                    )
                    .harvisFont(.caption2)
                    .foregroundColor(latestReceipt.isUndone ? theme.muted : theme.positive)
                    Spacer(minLength: 4)
                    if !latestReceipt.isUndone {
                        Button("撤销上次整理") {
                            onUndo(latestReceipt.id)
                        }
                        .buttonStyle(.plain)
                        .harvisFont(.caption2)
                        .foregroundColor(theme.accent)
                        .disabled(analysis.status == .applying)
                        .accessibilityIdentifier("project-organizer.undo-last")
                    }
                }
            }

            HStack(spacing: 8) {
                Text("建议需逐项审核")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                Spacer(minLength: 6)
                Button(
                    analysis.status == .applying
                        ? "正在应用…"
                        : "应用所选 \(selectedSuggestions.count)"
                ) {
                    onApply(selectedSuggestions.map(\.id))
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(!canApply)
                .accessibilityIdentifier("project-organizer.apply")
                .accessibilityLabel("应用所选项目整理建议")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var statusColor: Color {
        switch analysis.status {
        case .idle: return theme.muted
        case .analyzing: return theme.accent
        case .ready: return theme.positive
        case .applying: return theme.accent
        case .applied: return theme.positive
        case .cancelled: return theme.muted
        case .failed: return theme.accent2
        }
    }

    private func confidenceBadge(
        _ confidence: ManagedProjectOrganizerConfidence
    ) -> some View {
        Label(confidence.reviewLabel, systemImage: confidence.reviewSystemImage)
            .harvisFont(.system(size: 9, weight: .semibold))
            .foregroundColor(confidence == .strong ? theme.positive : theme.accent2)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background((confidence == .strong ? theme.positive : theme.accent2).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func destinationLabel(
        for suggestion: ManagedProjectOrganizerSuggestion
    ) -> String {
        switch suggestion.action {
        case .assign:
            guard let targetProjectID = suggestion.targetProjectID,
                  let project = targetProjects.first(where: { $0.id == targetProjectID }) else {
                return "待选择目标"
            }
            return project.reviewName
        case .createSubproject:
            return suggestion.proposedProject?.reviewName ?? "待填写子项目"
        case .keep:
            return "保持现状"
        }
    }

    private func projectLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分类" : trimmed
    }

    private func projectPathLabel(_ project: ManagedChatProjectIdentity) -> String {
        let path = project.displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "未提供路径" : path
    }

    private func toggleExpanded(_ id: String) {
        if expandedSuggestionIDs.contains(id) {
            expandedSuggestionIDs.remove(id)
        } else {
            expandedSuggestionIDs.insert(id)
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
