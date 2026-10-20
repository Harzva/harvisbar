import Foundation
import SwiftUI

/// The presentation layer for conversation evidence and project relevance.
///
/// This view deliberately consumes the provider-neutral input/insight models.
/// It does not read chat history itself and it never mutates a source project;
/// project actions are handed back to Harvis as grouping-only callbacks.
struct ManagedConversationInsightPanelView: View {
    let thread: ManagedChatThread
    let inputState: ManagedConversationUserInputState
    let insightStatus: ManagedConversationInsightStatus?
    let sourceProject: ManagedChatProjectIdentity
    let managedProject: ManagedChatProjectIdentity
    let projectCandidates: [ManagedChatProjectIdentity]
    let recommendedProject: ManagedChatProjectIdentity?
    let availabilityMessage: String?
    let canAnalyze: Bool
    let theme: HarvisTheme
    let onPrepareInputs: () -> Void
    let onClearInputs: () -> Void
    let onRefreshInputs: () -> Void
    let onAnalyze: () -> Void
    let onCancelAnalysis: () -> Void
    let onAssignProject: (ManagedChatProjectIdentity) -> Void
    let onRestoreSourceProject: () -> Void
    let onConfirmRecommendation: () -> Void

    @State private var expandedInputIDs: Set<String> = []
    @State private var expandedInputFingerprint = ""
    @State private var summaryExpanded = false
    @State private var projectSearch = ""
    @State private var pendingProjectID: String?

    private var isCodex: Bool { thread.provider == .codex }

    /// DSH and WorkBuddy are provider-neutral observation sources here.  Even
    /// if a stale in-memory projection happens to contain rows, never surface
    /// those rows as verified user evidence in the read-only panel.
    private var inputEvidenceAvailable: Bool {
        isCodex && inputState.sourceAvailable
    }

    private var displayableInputs: [ManagedConversationUserInput] {
        inputState.items.filter {
            $0.source == .human || $0.source == .unknown
        }
    }

    private var inputIDsFingerprint: String {
        displayableInputs.map(\.id).joined(separator: "|")
    }

    private var filteredProjects: [ManagedChatProjectIdentity] {
        let query = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return projectCandidates }
        return projectCandidates.filter {
            $0.label.lowercased().contains(query)
                || $0.displayPath.lowercased().contains(query)
        }
    }

    private var latestInsight: ManagedConversationInsightV1? {
        insightStatus?.latestInsight
    }

    private var pendingProject: ManagedChatProjectIdentity? {
        guard let pendingProjectID else { return nil }
        if pendingProjectID == sourceProject.id {
            return sourceProject
        }
        return projectCandidates.first { $0.id == pendingProjectID }
    }

    private var inputStatusText: String {
        guard isCodex else {
            return "该来源暂不提供可验证的用户输入接口。"
        }
        if inputState.isLoading { return "正在读取用户输入…" }
        if let error = inputState.error, !error.isEmpty { return error }
        guard inputState.sourceAvailable else {
            return isCodex
                ? "当前记录源不可用；不会猜测或展示助手正文。"
                : "该来源暂不提供可验证的用户输入接口。"
        }
        if inputState.isTruncated {
            return ManagedConversationInsightPresentation.inputCountLabel(
                loaded: displayableInputs.count,
                total: inputState.totalCount,
                truncated: true
            )
        }
        return ManagedConversationInsightPresentation.inputCountLabel(
            loaded: displayableInputs.count,
            total: inputState.totalCount,
            truncated: false
        )
    }

    private var insightStateLabel: String {
        guard let state = insightStatus?.state else { return "尚未分析" }
        switch state {
        case .dispatching: return "分析派发中"
        case .running: return "分析中"
        case .cancelling: return "正在取消"
        case .completed: return "已完成"
        case .failed: return "分析失败"
        case .deliveryUnknown: return "交付状态未知"
        case .cancelled: return "已取消"
        }
    }

    private var insightStateColor: Color {
        if insightStatus?.isStale == true { return .orange }
        guard let state = insightStatus?.state else { return theme.muted }
        switch state {
        case .completed: return theme.positive
        case .dispatching, .running: return theme.accent
        case .cancelling: return .orange
        case .failed: return .red
        case .deliveryUnknown: return theme.accent2
        case .cancelled: return theme.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader
            inputSection
            insightSection
            projectSection
        }
        // The workbench owns the 430pt detail column.  Keeping this view flexible
        // avoids adding 430pt on top of the observation detail's inner padding.
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(theme.text)
        .accessibilityIdentifier("managed-conversation-insight-panel")
        .onAppear {
            onPrepareInputs()
            onRefreshInputs()
            syncExpandedInputs()
            if latestInsight != nil { summaryExpanded = true }
        }
        .onChange(of: inputIDsFingerprint) { _ in
            syncExpandedInputs()
        }
        .onChange(of: insightStatus?.state) { state in
            if state == .completed { summaryExpanded = true }
        }
        .onChange(of: managedProject.id) { _ in
            pendingProjectID = nil
        }
        .onDisappear {
            onClearInputs()
        }
    }

    private var panelHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .harvisFont(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.accent)
                .frame(width: 28, height: 28)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text("对话理解与归属")
                    .harvisFont(.headline)
                Text("原句仅留在当前面板；DSH 只接收不可逆事实，Harvis 只改变卡片分组")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            statusPill(insightStateLabel, color: insightStateColor)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("用户输入")
                Spacer()
                Text(inputEvidenceAvailable ? "SOURCE" : "FAIL CLOSED")
                    .harvisFont(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(inputEvidenceAvailable ? theme.positive : theme.muted)
            }

            HStack(spacing: 6) {
                Image(systemName: inputState.isLoading ? "hourglass" : "person.fill")
                    .foregroundColor(inputState.isLoading ? theme.accent : theme.muted)
                Text(inputStatusText)
                    .harvisFont(.caption2)
                    .foregroundColor(inputState.error == nil ? theme.muted : .orange)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 3)
                Button(action: onRefreshInputs) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(inputState.isLoading || !isCodex)
                .help("重新读取用户输入")
                .accessibilityLabel("重新读取用户输入")
            }

            if !inputEvidenceAvailable || displayableInputs.isEmpty {
                Text(inputState.error ?? (isCodex ? "尚无可展示的用户输入。" : "DSH / WorkBuddy 默认不读取会话正文。"))
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(displayableInputs) { item in
                            ManagedConversationUserInputRow(
                                item: item,
                                isExpanded: expandedInputIDs.contains(item.id),
                                theme: theme,
                                onToggle: { toggleInput(item.id) }
                            )
                        }
                    }
                }
                .frame(height: 170)
                .accessibilityIdentifier("managed-conversation-input-list")
            }

            if inputEvidenceAvailable,
               let loadedAt = inputState.loadedAt,
               inputState.threadUpdatedAtAtLoad != thread.updatedAt {
                Label(
                    ManagedConversationInsightPresentation.staleInputEvidenceLabel(loadedAt),
                    systemImage: "clock.badge.exclamationmark"
                )
                .harvisFont(.caption2)
                .foregroundColor(.orange)
            }
        }
        .insightPanelCard(theme: theme)
    }

    private var insightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("AI 摘要与相关性")
                Spacer()
                Button {
                    if insightStatus?.state.isInFlight == true {
                        onCancelAnalysis()
                    } else {
                        onAnalyze()
                    }
                } label: {
                    Label(
                        insightStatus?.state.isInFlight == true
                            ? "取消分析"
                            : (canAnalyze ? "一键分析" : "不可分析"),
                        systemImage: insightStatus?.state.isInFlight == true
                            ? "stop.circle"
                            : "sparkles"
                    )
                        .harvisFont(.caption2.bold())
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(
                    insightStatus?.state.isInFlight != true
                        && !canAnalyze
                )
                .accessibilityIdentifier("managed-conversation-analyze")
                .accessibilityLabel(
                    insightStatus?.state.isInFlight == true
                        ? "取消对话分析"
                        : (canAnalyze ? "一键分析对话" : "当前来源不可分析")
                )
            }

            if !isCodex {
                Label(
                    ManagedConversationInsightPresentation.providerReadOnlyLabel(
                        thread.provider.label
                    ),
                    systemImage: "hand.raised.fill"
                )
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let availabilityMessage, !availabilityMessage.isEmpty {
                Label(availabilityMessage, systemImage: "info.circle")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if insightStatus?.isStale == true {
                Label(
                    "输入或项目已变化；以下摘要/相关性仅供参考，请重新分析。",
                    systemImage: "clock.badge.exclamationmark"
                )
                .harvisFont(.caption2)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = insightStatus?.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .harvisFont(.caption2)
                    .foregroundColor(insightStatus?.state == .deliveryUnknown ? theme.accent2 : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let latestInsight {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        summaryExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: summaryExpanded ? "chevron.down" : "chevron.right")
                            .harvisFont(.caption2.bold())
                        Text(latestInsight.summary.coreGoal)
                            .harvisFont(.caption.bold())
                            .lineLimit(summaryExpanded ? 4 : 2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Text(
                            ManagedConversationInsightPresentation.analyzedInputCountLabel(
                                analyzed: latestInsight.analyzedInputCount,
                                total: latestInsight.totalInputCount
                            )
                        )
                            .harvisFont(.caption2.monospacedDigit())
                            .foregroundColor(theme.muted)
                    }
                    .foregroundColor(theme.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summaryExpanded ? "收起 AI 摘要" : "展开 AI 摘要")

                if summaryExpanded {
                    insightList("主要任务", items: latestInsight.summary.mainTasks, icon: "checklist")
                    insightList("约束", items: latestInsight.summary.constraints, icon: "lock")
                    insightList("开放问题", items: latestInsight.summary.openQuestions, icon: "questionmark.circle")
                }

                relevanceView(latestInsight.relevance)
            } else {
                Text(insightStatus == nil ? "点击“一键分析”生成目标、任务、约束、问题和项目相关性。" : "分析完成后，摘要与相关性结果会显示在这里。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .insightPanelCard(theme: theme, emphasized: latestInsight != nil)
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("项目归属")
                Spacer()
                Text("Harvis 分组")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }

            projectRow("源项目", project: sourceProject, color: theme.muted)
            projectRow("当前管理项目", project: managedProject, color: theme.accent)

            if let recommendedProject,
               let relevance = latestInsight?.relevance {
                HStack(alignment: .top, spacing: 7) {
                    ManagedConversationRelevanceBadge(
                        score: relevance.recommendedScore ?? relevance.currentScore,
                        isStale: insightStatus?.isStale == true,
                        theme: theme
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            ManagedConversationInsightPresentation.recommendedProjectLabel(
                                recommendedProject.label
                            )
                        )
                            .harvisFont(.caption.bold())
                        Text(relevance.reason)
                            .harvisFont(.caption2)
                            .foregroundColor(theme.muted)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 2)
                    Button("确认") {
                        onConfirmRecommendation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(theme.accent)
                    .disabled(
                        !canAnalyze || insightStatus?.isStale == true
                    )
                    .accessibilityLabel(
                        ManagedConversationInsightPresentation.confirmRecommendationLabel(
                            recommendedProject.label
                        )
                    )
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.muted)
                TextField("搜索并手动选择项目", text: $projectSearch)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.surfaceAlt.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
            .accessibilityIdentifier("managed-conversation-project-search")

            if projectCandidates.isEmpty {
                Text("当前没有可选项目。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            } else {
                ForEach(filteredProjects) { project in
                    Button {
                        guard project.id != managedProject.id else { return }
                        pendingProjectID = project.id
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: project.id == managedProject.id ? "checkmark.circle.fill" : "folder")
                                .foregroundColor(project.id == managedProject.id ? theme.accent : theme.muted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.label)
                                    .harvisFont(.caption)
                                    .lineLimit(1)
                                Text(project.displayPath)
                                    .harvisFont(.caption2.monospaced())
                                    .foregroundColor(theme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(project.id == managedProject.id)
                    .accessibilityLabel(
                        ManagedConversationInsightPresentation.projectSelectionLabel(
                            project.label,
                            isCurrent: project.id == managedProject.id
                        )
                    )
                }
            }

            if let pendingProject,
               pendingProject.id != managedProject.id {
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待应用归属")
                            .harvisFont(.caption2.bold())
                            .foregroundColor(theme.accent)
                        Text(pendingProject.label)
                            .harvisFont(.caption)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Button("取消") {
                        pendingProjectID = nil
                    }
                    .buttonStyle(.plain)
                    Button("应用归属") {
                        if pendingProject.id == sourceProject.id {
                            onRestoreSourceProject()
                        } else {
                            onAssignProject(pendingProject)
                        }
                        pendingProjectID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(theme.accent)
                    .accessibilityIdentifier("managed-conversation-apply-project")
                    .accessibilityLabel(
                        ManagedConversationInsightPresentation.applyProjectLabel(
                            pendingProject.label
                        )
                    )
                }
                .padding(7)
                .background(theme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if managedProject.id != sourceProject.id {
                Button {
                    pendingProjectID = sourceProject.id
                } label: {
                    Label("恢复源项目", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
                .accessibilityIdentifier("managed-conversation-restore-source")
                .accessibilityLabel("恢复源项目归属")
            }

            Text("归属只影响 Harvis 卡片分组，不修改 Codex / DSH 会话工作目录或项目文件。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .insightPanelCard(theme: theme)
    }

    private func projectRow(
        _ label: String,
        project: ManagedChatProjectIdentity,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .frame(width: 82, alignment: .leading)
            Text(project.label)
                .harvisFont(.caption.bold())
                .foregroundColor(color)
                .lineLimit(1)
            Spacer(minLength: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ManagedConversationInsightPresentation.projectRowLabel(
                label: label,
                project: project.label
            )
        )
    }

    private func relevanceView(
        _ relevance: ManagedConversationProjectRelevanceV1
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("项目相关性")
                    .harvisFont(.caption.bold())
                ManagedConversationRelevanceBadge(
                    score: relevance.currentScore,
                    isStale: insightStatus?.isStale == true,
                    theme: theme
                )
                Text(
                    ManagedConversationInsightPresentation.confidenceLabel(
                        relevance.confidence
                    )
                )
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }
            Text(relevance.reason)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func insightList(
        _ title: String,
        items: [String],
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .harvisFont(.caption2.bold())
                .foregroundColor(theme.accent)
            if items.isEmpty {
                Text("未识别")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: icon)
                        .harvisFont(.caption2)
                        .foregroundColor(theme.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func statusPill(_ label: String, color: Color) -> some View {
        Text(label)
            .harvisFont(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .harvisFont(.caption.bold())
            .foregroundColor(theme.muted)
    }

    private func toggleInput(_ id: String) {
        withAnimation(.easeInOut(duration: 0.14)) {
            if expandedInputIDs.contains(id) {
                expandedInputIDs.remove(id)
            } else {
                expandedInputIDs.insert(id)
            }
        }
    }

    private func syncExpandedInputs() {
        guard expandedInputFingerprint != inputIDsFingerprint else { return }
        expandedInputFingerprint = inputIDsFingerprint
        let currentIDs = Set(displayableInputs.map(\.id))
        expandedInputIDs.formIntersection(currentIDs)
    }
}

private struct ManagedConversationUserInputRow: View {
    let item: ManagedConversationUserInput
    let isExpanded: Bool
    let theme: HarvisTheme
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .harvisFont(.caption2.bold())
                    Text(
                        ManagedConversationInsightPresentation.inputSequenceLabel(
                            item.sequence
                        )
                    )
                        .harvisFont(.caption2.monospacedDigit())
                    if let timestamp = item.timestamp, !timestamp.isEmpty {
                        Text(timestamp)
                            .harvisFont(.caption2.monospacedDigit())
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                    }
                    if item.truncated {
                        Text("已截断")
                            .harvisFont(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text(
                        ManagedConversationInsightPresentation
                            .inputSourceLabel(item.source)
                    )
                        .harvisFont(.system(size: 9, weight: .bold))
                        .foregroundColor(
                            item.source == .human ? theme.muted : .orange
                        )
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            (item.source == .human ? theme.muted : Color.orange)
                                .opacity(0.10)
                        )
                        .clipShape(Capsule())
                    Spacer(minLength: 2)
                    Text(isExpanded ? "收起" : "展开")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                }
                .foregroundColor(theme.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                ManagedConversationInsightPresentation.inputToggleLabel(
                    sequence: item.sequence,
                    isExpanded: isExpanded
                )
            )

            Group {
                if isExpanded {
                    ScrollView(.vertical) {
                        Text(item.text)
                            .harvisFont(.caption)
                            .foregroundColor(theme.text)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(item.text)
                        .harvisFont(.caption)
                        .foregroundColor(theme.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(height: isExpanded ? 142 : 32, alignment: .topLeading)
            .padding(7)
            .background(theme.surface.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line.opacity(0.8)))
        }
        .padding(7)
        .background(theme.surfaceAlt.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.opacity(0.8)))
        .accessibilityIdentifier(
            ManagedConversationInsightPresentation.inputIdentifier(item.id)
        )
    }
}

struct ManagedConversationRelevanceBadge: View {
    let score: Int
    let isStale: Bool
    let theme: HarvisTheme

    private var color: Color {
        if isStale { return .orange }
        if score >= 70 { return theme.positive }
        if score >= 40 { return .orange }
        return .red
    }

    var body: some View {
        Text(ManagedConversationInsightPresentation.relevanceLabel(score))
            .harvisFont(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel(
                ManagedConversationInsightPresentation.relevanceAccessibilityLabel(
                    score: score,
                    isStale: isStale
                )
            )
    }
}

struct ManagedConversationRelevanceAccent: View {
    let score: Int
    let isStale: Bool
    let theme: HarvisTheme

    private var color: Color {
        if isStale { return .orange }
        if score >= 70 { return theme.positive }
        if score >= 40 { return .orange }
        return .red
    }

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 3)
            .padding(.vertical, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Centralized dynamic labels for the insight panel.
///
/// Keeping these strings in pure functions makes the presentation contract
/// testable without requiring a SwiftUI/AppKit host and prevents an escaped
/// interpolation from silently becoming literal UI text.
enum ManagedConversationInsightPresentation {
    static func inputCountLabel(
        loaded: Int,
        total: Int,
        truncated: Bool
    ) -> String {
        if truncated {
            return "已读取 \(loaded)/\(total) 条；其余已安全截断。"
        }
        return "共 \(loaded) 条用户输入"
    }

    static func staleInputEvidenceLabel(_ loadedAt: Date) -> String {
        "输入证据可能已陈旧 · \(loadedAt.formatted(date: .omitted, time: .shortened))"
    }

    static func providerReadOnlyLabel(_ provider: String) -> String {
        "\(provider) 已安全降级为只读；不会派发分析或读取助手正文。"
    }

    static func analyzedInputCountLabel(analyzed: Int, total: Int) -> String {
        "\(analyzed)/\(total)"
    }

    static func recommendedProjectLabel(_ project: String) -> String {
        "推荐归属：\(project)"
    }

    static func confirmRecommendationLabel(_ project: String) -> String {
        "确认推荐项目 \(project)"
    }

    static func projectSelectionLabel(_ project: String, isCurrent: Bool) -> String {
        isCurrent ? "当前管理项目：\(project)" : "选择项目 \(project)"
    }

    static func applyProjectLabel(_ project: String) -> String {
        "应用项目归属 \(project)"
    }

    static func projectRowLabel(label: String, project: String) -> String {
        "\(label)：\(project)"
    }

    static func confidenceLabel(_ confidence: Double) -> String {
        "置信度 \(Int(confidence * 100))%"
    }

    static func inputSequenceLabel(_ sequence: Int64) -> String {
        "#\(sequence)"
    }

    static func inputToggleLabel(sequence: Int64, isExpanded: Bool) -> String {
        isExpanded ? "收起第 \(sequence) 条用户输入" : "展开第 \(sequence) 条用户输入"
    }

    static func inputSourceLabel(
        _ source: ManagedConversationUserInputSource
    ) -> String {
        switch source {
        case .human:
            return "用户输入"
        case .unknown:
            return "用户角色 · 来源未证实"
        case .manager:
            return "Manager 指令 · 已排除"
        case .system:
            return "系统指令 · 已排除"
        }
    }

    static func inputIdentifier(_ id: String) -> String {
        "managed-conversation-input-\(id)"
    }

    static func relevanceLabel(_ score: Int) -> String {
        "相关 \(score)"
    }

    static func relevanceAccessibilityLabel(score: Int, isStale: Bool) -> String {
        isStale ? "项目相关性 \(score)，数据陈旧" : "项目相关性 \(score)"
    }
}

extension View {
    fileprivate func insightPanelCard(
        theme: HarvisTheme,
        emphasized: Bool = false
    ) -> some View {
        self
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                emphasized
                    ? theme.accent.opacity(0.08)
                    : theme.surfaceAlt.opacity(0.42)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(emphasized ? theme.accent : theme.line, lineWidth: 1)
            )
    }
}
