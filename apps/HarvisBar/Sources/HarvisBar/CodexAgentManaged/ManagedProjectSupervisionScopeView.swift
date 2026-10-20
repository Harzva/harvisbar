import SwiftUI

/// Read-only project roster. The current card filter is intentionally not an
/// input to this view: callers pass the exact management snapshot and the
/// complete provider inventory separately.
struct ManagedProjectSupervisionScopeView: View {
    let project: ManagedChatProjectIdentity
    let managementSnapshot: ConversationManagementSnapshotV1?
    let managementThreads: [ManagedChatThread]
    let managementScope: ManagedProjectSupervisionScope?
    let theme: HarvisTheme

    @State private var isExpanded = false
    @State private var query = ""

    init(
        project: ManagedChatProjectIdentity,
        managementSnapshot: ConversationManagementSnapshotV1? = nil,
        managementThreads: [ManagedChatThread] = [],
        managementScope: ManagedProjectSupervisionScope? = nil,
        theme: HarvisTheme
    ) {
        self.project = project
        self.managementSnapshot = managementSnapshot
        self.managementThreads = managementThreads
        self.managementScope = managementScope
        self.theme = theme
    }

    private var resolvedScope: ManagedProjectSupervisionScope? {
        if let managementScope { return managementScope }
        guard let managementSnapshot else { return nil }
        return ManagedProjectSupervisionScope(
            project: project,
            snapshot: managementSnapshot,
            threads: managementThreads
        )
    }

    private var filteredEntries: [ManagedProjectSupervisionScopeEntry] {
        guard let scope = resolvedScope else { return [] }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return scope.entries }
        return scope.entries.filter { $0.searchText.contains(normalized) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let scope = resolvedScope {
                scopeSummary(scope)
                exactProjectNotice(scope)
                DisclosureGroup(isExpanded: $isExpanded) {
                    completeRoster(scope)
                } label: {
                    HStack(spacing: 7) {
                        Label("完整会话名单", systemImage: "rectangle.stack")
                            .harvisFont(.caption.bold())
                            .foregroundColor(theme.text)
                        Spacer(minLength: 8)
                        Text("\(scope.totalCount) 条")
                            .harvisFont(.caption2.monospacedDigit())
                            .foregroundColor(theme.muted)
                    }
                }
                .accessibilityIdentifier("managed-project-supervision-scope.roster")
            } else {
                unavailableScopeNotice
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
        .accessibilityIdentifier("managed-project-supervision-scope")
        .onChange(of: project.id) { _ in
            isExpanded = false
            query = ""
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Label("项目监督范围", systemImage: "scope")
                .harvisFont(.caption.bold())
                .foregroundColor(theme.text)
            Spacer(minLength: 8)
            if let scope = resolvedScope {
                Text(scope.brainEnabled ? "大脑已开启" : "大脑已关闭")
                    .harvisFont(.caption2.bold())
                    .foregroundColor(scope.brainEnabled ? theme.positive : theme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((scope.brainEnabled ? theme.positive : theme.muted).opacity(0.12))
                    .clipShape(Capsule())
            } else {
                Text("尚未加载")
                    .harvisFont(.caption2.bold())
                    .foregroundColor(theme.muted)
            }
        }
    }

    private func scopeSummary(
        _ scope: ManagedProjectSupervisionScope
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), alignment: .leading)], alignment: .leading, spacing: 8) {
                summaryMetric("全部", value: scope.totalCount, color: theme.text)
                summaryMetric("审批候选", value: scope.approvalCandidateCount, color: theme.positive)
                summaryMetric("仅观察", value: scope.observationCount, color: theme.muted)
                summaryMetric("已排除", value: scope.enrollmentExcludedCount, color: theme.muted)
                if scope.unavailableCount > 0 {
                    summaryMetric("失联", value: scope.unavailableCount, color: .orange)
                }
            }
            Text(
                scope.brainEnabled
                    ? "候选名单只代表配置结果；每项仍需有效任务计划、证据核验和逐项批准。"
                    : "项目大脑已关闭；以下是配置与观察范围。DSH 单会话监督另行设置，不受这个开关影响。"
            )
            .harvisFont(.caption2)
            .foregroundColor(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("managed-project-supervision-scope.summary")
    }

    private func summaryMetric(
        _ label: String,
        value: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
            Text("\(value)")
                .harvisFont(.headline.monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exactProjectNotice(
        _ scope: ManagedProjectSupervisionScope
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("精确项目归属", systemImage: "folder.badge.checkmark")
                .harvisFont(.caption.bold())
                .foregroundColor(theme.text)
            Text(scope.projectLabel)
                .harvisFont(.caption)
                .foregroundColor(theme.text)
                .lineLimit(2)
            Text(scope.projectDisplayPath)
                .harvisFont(.caption2.monospaced())
                .foregroundColor(theme.muted)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("范围按此项目的归属精确匹配，不包含子项目或相邻目录；主界面的搜索、智能体、账号和状态筛选不会缩小这份名单。提供分析的 DSH 服务也不是被监督会话。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(theme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("managed-project-supervision-scope.exact-project")
    }

    private func completeRoster(
        _ scope: ManagedProjectSupervisionScope
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(theme.muted)
                    TextField("搜索完整名单", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("managed-project-supervision-scope.search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除项目监督范围搜索")
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line))
                Spacer(minLength: 6)
                Text("显示 \(filteredEntries.count)/\(scope.totalCount)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }

            if filteredEntries.isEmpty {
                Text("完整名单中没有匹配项。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .padding(.vertical, 6)
            } else {
                ForEach(filteredEntries) { entry in
                    rosterRow(entry)
                }
            }

            Text("快照读入 \(scope.snapshotGeneratedAt.formatted(date: .abbreviated, time: .shortened)) · revision \(scope.snapshotRevision)")
                .harvisFont(.caption2.monospaced())
                .foregroundColor(theme.muted)
                .accessibilityIdentifier("managed-project-supervision-scope.snapshot-time")
        }
        .padding(.top, 4)
    }

    private func rosterRow(
        _ entry: ManagedProjectSupervisionScopeEntry
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(entry.title)
                    .harvisFont(.caption.bold())
                    .foregroundColor(theme.text)
                    .lineLimit(2)
                Spacer(minLength: 5)
                Text(entry.status.label)
                    .harvisFont(.caption2.bold())
                    .foregroundColor(statusColor(entry.status))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(statusColor(entry.status).opacity(0.12))
                    .clipShape(Capsule())
            }
            Text("\(entry.providerLabel) · 来源 \(entry.sourceLabel)")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(entry.reason)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.target.stableID)
                .harvisFont(.system(size: 9).monospaced())
                .foregroundColor(theme.muted)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("managed-project-supervision-scope.row.\(entry.id)")
        .accessibilityLabel("\(entry.title)，\(entry.status.label)")
        .accessibilityValue("\(entry.providerLabel)，\(entry.sourceLabel)，\(entry.reason)")
    }

    private var unavailableScopeNotice: some View {
        Label(
            "项目管理快照尚未加载；当前不能声称项目正在监督。请先刷新项目管理状态。",
            systemImage: "exclamationmark.triangle"
        )
        .harvisFont(.caption)
        .foregroundColor(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("managed-project-supervision-scope.unavailable")
    }

    private func statusColor(
        _ status: ManagedProjectSupervisionScopeEntryStatus
    ) -> Color {
        switch status {
        case .approvalCandidate: return theme.positive
        case .observation: return theme.muted
        case .enrollmentExcluded: return theme.muted
        case .unavailable: return .orange
        }
    }
}
