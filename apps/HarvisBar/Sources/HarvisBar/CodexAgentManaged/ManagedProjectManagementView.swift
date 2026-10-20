import AppKit
import SwiftUI

struct ManagedProjectManagementView: View {
    let project: ManagedChatProjectIdentity
    let threads: [ManagedChatThread]
    /// The card list above may be filtered for presentation. These optional
    /// management inputs keep the project roster anchored to the exact
    /// snapshot and complete provider inventory instead.
    var managementSnapshot: ConversationManagementSnapshotV1? = nil
    var managementThreads: [ManagedChatThread] = []
    var managementScope: ManagedProjectSupervisionScope? = nil
    let taskPlan: ManagedProjectTaskPlan?
    let taskSummary: ManagedProjectTaskSummary
    let taskFreshness: ManagedGovernanceFreshness
    let attention: ManagedAttentionPreference
    let gitSummary: ProjectGitSummary?
    let gitRefreshing: Bool
    let brainEnabled: Bool?
    let brainError: String?
    let onSetBrainEnabled: ((Bool) -> Void)?
    let defaultEnrollmentEnabled: Bool?
    let onSetDefaultEnrollmentEnabled: ((Bool) -> Void)?
    let brainEndpoint: DshRuntimeEndpoint?
    let brainEndpointError: String?
    let onGenerateBrainPreview:
        ((String) async throws -> DshMetaAgentPreview)?
    let onApproveBrainDecision:
        ((DshMetaAgentPreview, ConversationManagementDecisionV1) async throws
            -> DshMetaAgentDispatchOutcome)?
    let onCancelBrainRun: ((UUID, Int) async throws -> Void)?
    @ObservedObject var brainCoordinator: DshMetaAgentCoordinator
    @ObservedObject var fileStatistics: ManagedProjectFileStatisticsStore
    let theme: HarvisTheme
    let onClose: () -> Void
    let onEditAttention: () -> Void

    private var runningCount: Int {
        threads.filter(\.isCardRunning).count
    }

    private var providerSummary: String {
        let grouped = Dictionary(grouping: threads, by: \.provider)
        return ManagedChatProvider.allCases.compactMap { provider in
            guard let count = grouped[provider]?.count, count > 0 else { return nil }
            return "\(provider.label) \(count)"
        }.joined(separator: " · ")
    }

    private var stats: ManagedProjectFileStatistics? {
        fileStatistics.statistics(for: project)
    }

    private var displayedTasks: [ManagedProjectTaskPlanItem] {
        (taskPlan?.tasks ?? []).sorted(by: taskOrder)
    }

    private var resolvedManagementThreads: [ManagedChatThread] {
        managementThreads.isEmpty ? threads : managementThreads
    }

    private var resolvedManagementScope: ManagedProjectSupervisionScope? {
        if let managementScope { return managementScope }
        guard let managementSnapshot else { return nil }
        return ManagedProjectSupervisionScope(
            project: project,
            snapshot: managementSnapshot,
            threads: resolvedManagementThreads
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ManagedProjectSupervisionScopeView(
                        project: project,
                        managementSnapshot: managementSnapshot,
                        managementThreads: resolvedManagementThreads,
                        managementScope: resolvedManagementScope,
                        theme: theme
                    )
                    managementBrainOverview
                    fileOverview
                    taskPlanOverview
                    conversationOverview
                    repositoryOverview
                    projectActions
                }
                .padding(14)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .harvisFont(.caption.bold())
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.muted)
            .background(theme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(10)
            .help("关闭项目管理页")
            .accessibilityLabel("关闭项目管理页")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("managed-project-page")
        .accessibilityLabel("\(project.label) 项目管理页")
        .task(id: project.id) {
            await fileStatistics.refresh(project: project)
        }
    }

    private var managementBrainOverview: some View {
        managementSection("DSH 管理大脑", systemImage: "brain.head.profile") {
            Toggle(
                isOn: Binding(
                    get: { brainEnabled ?? false },
                    set: { enabled in onSetBrainEnabled?(enabled) }
                )
            ) {
                HStack(spacing: 6) {
                    Text("启用项目管理大脑")
                        .harvisFont(.caption.bold())
                    Spacer(minLength: 6)
                    Text(brainStatusLabel)
                        .harvisFont(.system(size: 9, weight: .bold))
                        .foregroundColor(brainStatusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(brainStatusColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(brainEnabled == nil || onSetBrainEnabled == nil)
            .accessibilityIdentifier("managed-project-brain-toggle")

            Text(brainStatusDescription)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(theme.line)

            Toggle(
                isOn: Binding(
                    get: { defaultEnrollmentEnabled ?? false },
                    set: { enabled in onSetDefaultEnrollmentEnabled?(enabled) }
                )
            ) {
                HStack(spacing: 6) {
                    Text("默认允许 inherit 对话进入审批候选")
                        .harvisFont(.caption.bold())
                    Spacer(minLength: 6)
                    Text(enrollmentStatusLabel)
                        .harvisFont(.system(size: 9, weight: .bold))
                        .foregroundColor(enrollmentStatusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(enrollmentStatusColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(
                defaultEnrollmentEnabled == nil
                    || onSetDefaultEnrollmentEnabled == nil
            )
            .accessibilityIdentifier("managed-project-default-enrollment-toggle")

            Text("该开关只解析 Enrollment=inherit 的对话。在单个对话保存工作类型/任务绑定会显式设为 enabled，清除时恢复 inherit；无论哪种情况都必须逐项批准，绝不自动派发。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let brainError, !brainError.isEmpty {
                Label(brainError, systemImage: "exclamationmark.triangle.fill")
                    .harvisFont(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("默认仅生成预览与建议；不会自动向任何对话派发。", systemImage: "hand.raised.fill")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)

            ManagedProjectBrainPreviewView(
                coordinator: brainCoordinator,
                project: project,
                brainEnabled: brainEnabled,
                endpoint: brainEndpoint,
                endpointError: brainEndpointError,
                theme: theme,
                managementSnapshot: managementSnapshot,
                managementThreads: resolvedManagementThreads,
                managementScope: resolvedManagementScope,
                onGenerate: onGenerateBrainPreview,
                onApprove: onApproveBrainDecision,
                onCancel: onCancelBrainRun
            )
        }
    }

    private var brainStatusLabel: String {
        guard let brainEnabled else { return "尚未接入" }
        return brainEnabled ? "已开启" : "已关闭"
    }

    private var brainStatusDescription: String {
        guard let brainEnabled else {
            return "当前运行时尚未提供该项目的大脑配置接口，因此这里不会伪装为已启用。"
        }
        if brainEnabled {
            return "DSH 可以读取经过验证的项目任务清单并生成管理提案；每次派发仍需明确确认。"
        }
        return "该项目只显示任务与对话状态，不运行 DSH 管理提案。"
    }

    private var brainStatusColor: Color {
        guard let brainEnabled else { return theme.muted }
        return brainEnabled ? theme.positive : theme.muted
    }

    private var enrollmentStatusLabel: String {
        guard let defaultEnrollmentEnabled else { return "尚未加载" }
        return defaultEnrollmentEnabled ? "inherit 可候选" : "inherit 已排除"
    }

    private var enrollmentStatusColor: Color {
        guard let defaultEnrollmentEnabled else { return theme.muted }
        return defaultEnrollmentEnabled ? theme.positive : theme.muted
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundColor(theme.accent)
                Text("项目管理")
                    .harvisFont(.caption.bold())
                    .foregroundColor(theme.muted)
                if !attention.isEmpty {
                    ManagedAttentionBadge(preference: attention, theme: theme)
                }
            }
            Text(project.label)
                .harvisFont(.title2.bold())
                .foregroundColor(theme.text)
                .lineLimit(2)
                .padding(.trailing, 28)
            Text(project.displayPath)
                .harvisFont(.caption2.monospaced())
                .foregroundColor(theme.muted)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var fileOverview: some View {
        managementSection("项目内容", systemImage: "externaldrive") {
            if let stats {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    metricTile("文件夹", value: "\(stats.folderCount)", icon: "folder")
                    metricTile("文件", value: "\(stats.fileCount)", icon: "doc")
                    metricTile("内容大小", value: stats.formattedSize, icon: "internaldrive")
                    metricTile("符号链接", value: "\(stats.symbolicLinkCount)", icon: "link")
                }

                HStack(spacing: 6) {
                    if stats.isTruncated {
                        Label("统计已达安全上限", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    } else {
                        Label("统计完成", systemImage: "checkmark.circle")
                            .foregroundColor(theme.positive)
                    }
                    Spacer()
                    Text(stats.scannedAt.formatted(date: .omitted, time: .shortened))
                }
                .harvisFont(.caption2)

                Text("已跳过 \(stats.excludedDirectoryCount) 个依赖或缓存目录；不跟随符号链接。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            } else if fileStatistics.scanningProjectIDs.contains(project.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在统计项目文件…")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                }
            } else {
                let fileStatisticsError = fileStatistics.errors[project.id]
                Label(
                    fileStatisticsError ?? "尚未读取项目内容。",
                    systemImage: "exclamationmark.triangle"
                )
                .harvisFont(.caption)
                .foregroundColor(
                    fileStatisticsError == nil ? theme.muted : .orange
                )
            }

            Button {
                Task { await fileStatistics.refresh(project: project, force: true) }
            } label: {
                Label("重新统计", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .harvisFont(.caption)
            .disabled(fileStatistics.scanningProjectIDs.contains(project.id))
        }
    }

    private var taskPlanOverview: some View {
        managementSection("控制平台任务计划", systemImage: "checklist") {
            if case let .stale(lastSuccessfulAt, _) = taskFreshness {
                Label(
                    "上次任务数据 · \(lastSuccessfulAt.formatted(date: .omitted, time: .shortened)) · 当前已陈旧",
                    systemImage: "clock.badge.exclamationmark"
                )
                .harvisFont(.caption2)
                .foregroundColor(.orange)
            }

            if taskFreshness.isFresh, taskSummary.sourceAvailable {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    metricTile("全部任务", value: "\(taskSummary.total)", icon: "checklist")
                    metricTile("已完成", value: "\(taskSummary.done)", icon: "checkmark.circle")
                    metricTile("未完成", value: "\(taskSummary.open)", icon: "circle.dotted")
                    metricTile(
                        "需处理",
                        value: "\(taskSummary.blocked + taskSummary.waitingApproval)",
                        icon: "exclamationmark.triangle"
                    )
                }
                ProgressView(value: taskSummary.completionFraction ?? 0)
                    .tint(taskSummary.total > 0 && taskSummary.done == taskSummary.total
                        ? theme.positive
                        : theme.accent)
            } else {
                Text(taskFreshness.error ?? "项目还没有可验证的任务清单数据。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
            }

            if let taskPlan, !displayedTasks.isEmpty {
                Divider().overlay(theme.line)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(taskFreshness.isFresh ? "任务清单" : "上次任务清单")
                            .harvisFont(.caption.bold())
                            .foregroundColor(theme.text)
                        Spacer()
                        Text("共 \(taskPlan.tasks.count) 项")
                            .harvisFont(.caption2.monospacedDigit())
                            .foregroundColor(theme.muted)
                    }
                    ForEach(displayedTasks, id: \.taskId) { task in
                        taskPlanRow(task)
                    }
                }
                .opacity(taskFreshness.isFresh ? 1 : 0.72)

                if let revision = taskPlan.sourceRevision {
                    Text("计划修订 \(revision.replacingOccurrences(of: "sha256:", with: "").prefix(12))")
                        .harvisFont(.system(size: 9).monospaced())
                        .foregroundColor(theme.muted)
                        .help(revision)
                }
            }
        }
    }

    private var conversationOverview: some View {
        managementSection("智能体对话", systemImage: "bubble.left.and.bubble.right") {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                metricTile("全部对话", value: "\(threads.count)", icon: "rectangle.stack")
                metricTile("运行中", value: "\(runningCount)", icon: "play.circle")
            }
            Text(providerSummary.isEmpty ? "暂无对话" : providerSummary)
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
        }
    }

    private var repositoryOverview: some View {
        managementSection("版本库", systemImage: "point.3.connected.trianglepath.dotted") {
            if gitRefreshing && gitSummary == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取 Git 状态…")
                }
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
            } else if let gitSummary, gitSummary.isRepository {
                detailRow("分支", gitSummary.branch ?? "未知")
                detailRow("工作树", gitSummary.isDirty ? "\(gitSummary.changedFileCount) 个变更" : "干净")
                detailRow("Worktree", "\(gitSummary.worktreeCount)")
                detailRow("远端", gitSummary.remotes.isEmpty ? "无" : gitSummary.remotes.joined(separator: ", "))
            } else {
                Text("该项目不在 Git 仓库中。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
            }
        }
    }

    private var projectActions: some View {
        HStack(spacing: 8) {
            Button(action: onEditAttention) {
                Label("关注设置", systemImage: "star")
            }
            .buttonStyle(.plain)

            if let path = project.canonicalPath {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .buttonStyle(.plain)

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(path, forType: .string)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
        }
        .harvisFont(.caption)
        .foregroundColor(theme.accent)
    }

    private func managementSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .harvisFont(.caption.bold())
                .foregroundColor(theme.muted)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
    }

    private func metricTile(
        _ label: String,
        value: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
            Text(value)
                .harvisFont(.headline.monospacedDigit())
                .foregroundColor(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundColor(theme.muted)
            Spacer(minLength: 8)
            Text(value)
                .foregroundColor(theme.text)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .harvisFont(.caption)
    }

    private func taskPlanRow(
        _ task: ManagedProjectTaskPlanItem
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: taskStatusIcon(task.status))
                .foregroundColor(taskStatusColor(task.status))
                .frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .harvisFont(.caption.bold())
                    .foregroundColor(theme.text)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(task.taskId)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text(task.owner)
                        .lineLimit(1)
                }
                .harvisFont(.system(size: 9).monospaced())
                .foregroundColor(theme.muted)
            }
            Spacer(minLength: 4)
            Text(taskStatusLabel(task.status))
                .harvisFont(.system(size: 9, weight: .bold))
                .foregroundColor(taskStatusColor(task.status))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(taskStatusColor(task.status).opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.vertical, 3)
        .help(task.description ?? task.title)
    }

    private func taskOrder(
        _ left: ManagedProjectTaskPlanItem,
        _ right: ManagedProjectTaskPlanItem
    ) -> Bool {
        let leftRank = taskStatusRank(left.status)
        let rightRank = taskStatusRank(right.status)
        if leftRank != rightRank { return leftRank < rightRank }
        if left.updatedAt != right.updatedAt {
            return (left.updatedAt ?? "") > (right.updatedAt ?? "")
        }
        return left.taskId.localizedStandardCompare(right.taskId) == .orderedAscending
    }

    private func taskStatusRank(_ status: String) -> Int {
        switch status {
        case "blocked", "waiting_approval": return 0
        case "in_progress", "reviewing": return 1
        case "pending": return 2
        case "done": return 3
        case "cancelled", "archived", "closed": return 4
        default: return 5
        }
    }

    private func taskStatusLabel(_ status: String) -> String {
        switch status {
        case "pending": return "待办"
        case "in_progress": return "进行中"
        case "waiting_approval": return "待审批"
        case "blocked": return "阻塞"
        case "reviewing": return "审核中"
        case "done": return "完成"
        case "cancelled": return "取消"
        case "archived": return "归档"
        case "closed": return "关闭"
        default: return status
        }
    }

    private func taskStatusIcon(_ status: String) -> String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "blocked", "waiting_approval": return "exclamationmark.triangle.fill"
        case "in_progress", "reviewing": return "arrow.triangle.2.circlepath"
        case "cancelled", "archived", "closed": return "archivebox"
        default: return "circle"
        }
    }

    private func taskStatusColor(_ status: String) -> Color {
        switch status {
        case "done": return theme.positive
        case "blocked", "waiting_approval": return .orange
        case "in_progress", "reviewing": return theme.accent
        case "cancelled", "archived", "closed": return theme.muted
        default: return theme.text.opacity(0.72)
        }
    }
}
