import Foundation
import SwiftUI

/// A bounded, live-only view of the selected Codex task.
///
/// The panel deliberately does not reconstruct chat history. It renders the
/// app-server state owned by `CodexTaskDeliveryCoordinator`, plus the recent
/// durable delivery records for this task.
struct CodexTurnPanelView: View {
    let thread: ManagedChatThread
    let home: CodexHome
    @ObservedObject var coordinator: CodexTaskDeliveryCoordinator
    @ObservedObject var handoffs: CodexConversationHandoffCoordinator
    let governance: ManagedChatGovernanceSnapshot
    let conversationInputState: ManagedConversationUserInputState
    let conversationInsightStatus: ManagedConversationInsightStatus?
    let conversationSourceProject: ManagedChatProjectIdentity
    let conversationManagedProject: ManagedChatProjectIdentity
    let conversationProjectCandidates: [ManagedChatProjectIdentity]
    let conversationRecommendedProject: ManagedChatProjectIdentity?
    let conversationInsightAvailabilityMessage: String?
    let conversationInsightCanAnalyze: Bool
    let theme: HarvisTheme
    let onOpen: () -> Void
    let onClose: () -> Void
    let onHandoffVerified: (CodexVerifiedHandoff) -> Void
    let onOpenHandoffDestination: (String) -> Void
    let onEditConversationAttention: () -> Void
    let onEditProjectAttention: () -> Void
    let onRefreshConversationInputs: () -> Void
    let onPrepareConversationInputs: () -> Void
    let onClearConversationInputs: () -> Void
    let onAnalyzeConversation: () -> Void
    let onCancelConversationAnalysis: () -> Void
    let onAssignConversationProject: (ManagedChatProjectIdentity) -> Void
    let onRestoreConversationSourceProject: () -> Void
    let onConfirmConversationRecommendation: () -> Void

    @State private var approvalAnswers: [String: String] = [:]
    @State private var selectedOptions: [String: String] = [:]
    @State private var mcpJSON = "{}"
    @State private var approvalValidationError: String?
    @State private var isResolvingApproval = false

    private let visibleEventLimit = 40
    private let visibleQueueLimit = 5

    private var normalizedHomePath: String {
        (home.path as NSString).expandingTildeInPath
    }

    private var targetThreadID: String {
        switch thread.dispatchCapability {
        case let .direct(threadID), let .parentOnly(threadID):
            return threadID
        case .unavailable:
            return thread.sourceID
        }
    }

    private var liveState: CodexThreadLiveState {
        coordinator.liveState(
            homePath: normalizedHomePath,
            threadID: targetThreadID
        )
    }

    private var recentEvents: [CodexLiveEvent] {
        Array(liveState.events.suffix(visibleEventLimit))
    }

    private var targetQueueItems: [CodexTaskQueueItem] {
        coordinator.queueItems.filter {
            $0.command.homePath == normalizedHomePath
                && $0.command.threadID == targetThreadID
        }
    }

    private var recentQueueItems: [CodexTaskQueueItem] {
        Array(targetQueueItems.sorted(by: queueItemPrecedes).prefix(visibleQueueLimit))
    }

    private var latestHandoff: CodexConversationHandoff? {
        handoffs.latestHandoff(
            homePath: normalizedHomePath,
            sourceThreadID: thread.sourceID
        )
    }

    private var handoffSupported: Bool {
        thread.isCodex
            && thread.sourceScope == home.id
            && CodexConversationHandoffPolicy.supports(thread.taskCardType)
    }

    private func queueItemPrecedes(
        _ lhs: CodexTaskQueueItem,
        _ rhs: CodexTaskQueueItem
    ) -> Bool {
        if lhs.state.isTerminal != rhs.state.isTerminal {
            return !lhs.state.isTerminal
        }
        if let lhsBatch = lhs.command.batch,
           let rhsBatch = rhs.command.batch,
           lhsBatch.batchID == rhsBatch.batchID,
           lhsBatch.ordinal != rhsBatch.ordinal {
            return lhsBatch.ordinal < rhsBatch.ordinal
        }
        return lhs.stateChangedAt > rhs.stateChangedAt
    }

    private var approvalIdentity: String {
        guard let approval = liveState.pendingApproval else { return "none" }
        return [
            approval.connectionID.uuidString,
            approval.id.displayValue,
            approval.method,
        ].joined(separator: "::")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .overlay(theme.line)
                .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    runtimeStatusSection
                    governanceSection
                    ManagedConversationInsightPanelView(
                        thread: thread,
                        inputState: conversationInputState,
                        insightStatus: conversationInsightStatus,
                        sourceProject: conversationSourceProject,
                        managedProject: conversationManagedProject,
                        projectCandidates: conversationProjectCandidates,
                        recommendedProject: conversationRecommendedProject,
                        availabilityMessage: conversationInsightAvailabilityMessage,
                        canAnalyze: conversationInsightCanAnalyze,
                        theme: theme,
                        onPrepareInputs: onPrepareConversationInputs,
                        onClearInputs: onClearConversationInputs,
                        onRefreshInputs: onRefreshConversationInputs,
                        onAnalyze: onAnalyzeConversation,
                        onCancelAnalysis: onCancelConversationAnalysis,
                        onAssignProject: onAssignConversationProject,
                        onRestoreSourceProject: onRestoreConversationSourceProject,
                        onConfirmRecommendation: onConfirmConversationRecommendation
                    )

                    if handoffSupported, let latestHandoff {
                        handoffStatusSection(latestHandoff)
                    }

                    if let approval = liveState.pendingApproval {
                        approvalSection(approval)
                    }

                    if let tool = nonempty(liveState.currentToolSummary) {
                        currentToolSection(tool)
                    }

                    queueSection
                    eventSection

                    if let summary = nonempty(liveState.finalSummary) {
                        finalSummarySection(summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 5)
                .padding(.bottom, 4)
            }

            Divider()
                .overlay(theme.line)
                .padding(.vertical, 10)
            footerActions
        }
        .foregroundColor(theme.text)
        .onAppear(perform: resetApprovalForm)
        .onChange(of: approvalIdentity) { _ in
            resetApprovalForm()
        }
        .task(id: "\(thread.id)::\(thread.updatedAt)") {
            onPrepareConversationInputs()
            onRefreshConversationInputs()
        }
    }

    private var panelHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .harvisFont(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.accent)
                .frame(width: 28, height: 28)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text("实时 Turn")
                    .harvisFont(.headline)
                Text(thread.title)
                    .harvisFont(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if targetThreadID != thread.sourceID {
                    Label("显示父任务实时状态", systemImage: "arrow.turn.up.left")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                }
            }

            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("关闭右侧栏并收起工作台")
            .accessibilityLabel("关闭右侧栏并收起工作台")
        }
    }

    private var runtimeStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("当前状态")

            HStack(spacing: 7) {
                if liveState.status == .active {
                    PulsingStatusDot(color: runtimeStatusColor)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: liveState.status.systemImage)
                        .foregroundColor(runtimeStatusColor)
                        .frame(width: 14, height: 14)
                }
                Text(liveState.status.displayLabel)
                    .harvisFont(.subheadline.bold())
                    .foregroundColor(runtimeStatusColor)
                Spacer()
                ownershipBadge
            }

            if let turnID = nonempty(liveState.activeTurnID) {
                compactValue("Turn", value: turnID, monospaced: true)
            }
            compactValue("任务", value: targetThreadID, monospaced: true)
            compactValue("Home", value: home.accountDisplayLabel)

            if let error = nonempty(coordinator.lastError) {
                Label(String(error.prefix(1_000)), systemImage: "exclamationmark.triangle.fill")
                    .harvisFont(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .panelCard(theme: theme)
    }

    private var governanceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("关注与交接信号")
                Spacer()
                Button("项目") { onEditProjectAttention() }
                    .buttonStyle(.plain)
                    .harvisFont(.caption2)
                Button("对话") { onEditConversationAttention() }
                    .buttonStyle(.plain)
                    .harvisFont(.caption2)
            }

            HStack(spacing: 7) {
                Label(governance.project.label, systemImage: "folder.fill")
                    .harvisFont(.caption.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                ManagedAttentionBadge(
                    preference: governance.projectAttention,
                    theme: theme
                )
            }

            projectTasksLine(
                governance.projectTasks,
                freshness: governance.projectTasksFreshness
            )

            if !governance.conversationAttention.isEmpty {
                HStack {
                    Text("对话")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                    ManagedAttentionBadge(
                        preference: governance.conversationAttention,
                        theme: theme
                    )
                }
            }

            if case let .stale(lastSuccessfulAt, error) = governance.conversationMetricsFreshness,
               let metrics = governance.conversationMetrics {
                let attention = metrics.attention
                HStack(spacing: 6) {
                    Text("上次\(attention.interactionLabel)")
                    Text("·")
                    Text("上次\(attention.compactionLabel)")
                    Spacer(minLength: 4)
                    Label("数据陈旧", systemImage: "clock.badge.exclamationmark")
                        .foregroundColor(.orange)
                }
                .harvisFont(.caption.monospacedDigit())
                Text(staleGovernanceHelp(
                    lastSuccessfulAt: lastSuccessfulAt,
                    error: error
                ))
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            } else if governance.conversationMetricsFreshness.isFresh,
                      let metrics = governance.conversationMetrics {
                let attention = metrics.attention
                HStack(spacing: 6) {
                    Text(attention.interactionLabel)
                    Text("·")
                    Text(attention.compactionLabel)
                    Spacer(minLength: 4)
                    if attention.risk == .handoffRecommended {
                        Label("建议交接", systemImage: "arrow.triangle.branch")
                            .foregroundColor(.orange)
                    } else if attention.risk == .watch {
                        Text("关注")
                            .foregroundColor(.yellow)
                    }
                }
                .harvisFont(.caption.monospacedDigit())
                if let note = metrics.userFacingEvidenceNote {
                    Text(note)
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let error = governance.conversationMetricsFreshness.error {
                Label(
                    "交互与压缩指标不可用：\(error)",
                    systemImage: "exclamationmark.triangle"
                )
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("交互与压缩指标正在按需读取；不会读取或显示对话正文。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }
        }
        .panelCard(theme: theme)
    }

    @ViewBuilder
    private func projectTasksLine(
        _ summary: ManagedProjectTaskSummary,
        freshness: ManagedGovernanceFreshness
    ) -> some View {
        if case let .stale(lastSuccessfulAt, error) = freshness {
            Label(
                staleProjectTaskLabel(summary),
                systemImage: "clock.badge.exclamationmark"
            )
            .harvisFont(.caption2)
            .foregroundColor(.orange)
            .help(staleGovernanceHelp(lastSuccessfulAt: lastSuccessfulAt, error: error))
        } else if !freshness.isFresh || !summary.sourceAvailable {
            Label("项目任务：未知（未发现 Agent Room 任务板）", systemImage: "checklist.unchecked")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .help(freshness.error ?? "尚无可验证的项目任务数据。")
        } else if summary.total == 0 {
            Label("项目任务：暂无任务", systemImage: "checklist")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
        } else if summary.done == summary.total {
            Label("项目任务：\(summary.done)/\(summary.total) 已完成", systemImage: "checkmark.circle.fill")
                .harvisFont(.caption2)
                .foregroundColor(theme.positive)
        } else if summary.open == 0 {
            Label(
                "项目任务：无进行中 · 已关闭 \(summary.closedWithoutCompletion) · 完成 \(summary.done)/\(summary.total)",
                systemImage: "archivebox"
            )
            .harvisFont(.caption2)
            .foregroundColor(theme.muted)
        } else {
            Label(
                "项目任务：未完成 \(summary.open) · 阻塞 \(summary.blocked) · 待审批 \(summary.waitingApproval)",
                systemImage: summary.needsAttention
                    ? "exclamationmark.triangle.fill"
                    : "checklist.unchecked"
            )
            .harvisFont(.caption2)
            .foregroundColor(summary.needsAttention ? .orange : theme.muted)
        }
    }

    private func staleProjectTaskLabel(
        _ summary: ManagedProjectTaskSummary
    ) -> String {
        guard summary.sourceAvailable else { return "项目任务：数据陈旧" }
        guard summary.total > 0 else { return "项目任务：上次暂无任务 · 数据陈旧" }
        return "项目任务：上次完成 \(summary.done)/\(summary.total) · 数据陈旧"
    }

    private func staleGovernanceHelp(
        lastSuccessfulAt: Date,
        error: String
    ) -> String {
        "上次成功 \(lastSuccessfulAt.formatted(date: .omitted, time: .shortened))。当前数据不可作为实时信号：\(error)"
    }

    private func handoffStatusSection(
        _ transaction: CodexConversationHandoff
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("任务交接")
                Spacer()
                statusPill(
                    transaction.statusLabel,
                    color: handoffColor(transaction.state)
                )
            }
            Text("Harvis 会先从旧任务生成有限交接包，再创建干净的新任务并验证接收。只有验证成功后旧任务才会标记 #done。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error = nonempty(transaction.lastError) {
                Text(String(error.prefix(1_000)))
                    .harvisFont(.caption2)
                    .foregroundColor(
                        transaction.state == .deliveryUnknown ? .orange : .red
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = nonempty(transaction.warning) {
                Label(String(warning.prefix(1_000)), systemImage: "exclamationmark.triangle")
                    .harvisFont(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let destination = nonempty(transaction.destinationThreadID) {
                Button {
                    onOpenHandoffDestination(destination)
                } label: {
                    Label("打开接手任务", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
            }
        }
        .panelCard(theme: theme)
    }

    @ViewBuilder
    private var ownershipBadge: some View {
        switch liveState.ownership {
        case .manager:
            statusPill("Manager", color: theme.positive)
        case .external:
            statusPill("External", color: theme.accent2)
        case nil:
            statusPill("Unowned", color: theme.muted)
        }
    }

    private func currentToolSection(_ tool: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("当前工具")
            HStack(alignment: .top, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 1)
                Text(String(tool.prefix(1_000)))
                    .harvisFont(.caption.monospaced())
                    .foregroundColor(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .panelCard(theme: theme)
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("派发队列")
                Spacer()
                Text("显示 \(recentQueueItems.count)/\(targetQueueItems.count)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }

            if recentQueueItems.isEmpty {
                Text("这个任务还没有由 Manager 派发的指令。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
            } else {
                ForEach(recentQueueItems) { item in
                    queueRow(item)
                    if item.id != recentQueueItems.last?.id {
                        Divider().overlay(theme.line.opacity(0.65))
                    }
                }
            }
        }
        .panelCard(theme: theme)
    }

    private func queueRow(_ item: CodexTaskQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: item.state.systemImage)
                    .foregroundColor(item.state.color(in: theme))
                Text(item.state.displayLabel)
                    .harvisFont(.caption.bold())
                    .foregroundColor(item.state.color(in: theme))
                Text(item.dispatchPhase.rawValue.uppercased())
                    .harvisFont(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.muted)
                if let batch = item.command.batch {
                    Text("AUTO \(batch.displayIndex)/\(batch.count)")
                        .harvisFont(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accent)
                }
                Spacer()
                Text(item.stateChangedAt, style: .time)
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                if let batch = item.command.batch,
                   !item.state.isTerminal {
                    Button {
                        Task {
                            await coordinator.cancelPendingBatch(batch.batchID)
                        }
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.plain)
                    .help("停止这个自动批次尚未派发的剩余次数；当前 Turn 不会被强制中断")
                    .accessibilityLabel("停止自动续发剩余次数")
                } else if item.state == .queued || item.state == .waiting {
                    Button {
                        Task { await coordinator.cancelQueuedCommand(item.id) }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("取消这条尚未派发的指令")
                    .accessibilityLabel("取消排队指令")
                }
            }

            Text(String(item.command.text.prefix(260)))
                .harvisFont(.caption)
                .lineLimit(3)
                .textSelection(.enabled)

            if let error = nonempty(item.lastError) {
                Text(String(error.prefix(600)))
                    .harvisFont(.caption2)
                    .foregroundColor(item.state == .deliveryUnknown ? theme.accent2 : theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if item.state == .deliveryUnknown {
                Text("交付状态未知；为避免重复执行，Manager 不会盲目重发。")
                    .harvisFont(.caption2.bold())
                    .foregroundColor(theme.accent2)
            }
        }
    }

    private var eventSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("实时事件")
                Spacer()
                Text("\(recentEvents.count)/\(visibleEventLimit)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }

            if recentEvents.isEmpty {
                Text("连接后，这里只显示最近的状态、工具和 Turn 事件，不复制完整聊天历史。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recentEvents.reversed()) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: event.kind.systemImage)
                            .harvisFont(.system(size: 10, weight: .semibold))
                            .foregroundColor(event.kind.color(in: theme))
                            .frame(width: 14, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(event.summary.prefix(700)))
                                .harvisFont(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text(event.timestamp, style: .time)
                                if let turnID = nonempty(event.turnID) {
                                    Text("turn \(String(turnID.prefix(10)))")
                                }
                            }
                            .harvisFont(.caption2.monospacedDigit())
                            .foregroundColor(theme.muted)
                        }
                    }
                }
            }
        }
        .panelCard(theme: theme)
    }

    private func finalSummarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最终结果摘要")
            Text(String(summary.suffix(2_000)))
                .harvisFont(.caption)
                .lineLimit(16)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if summary.count > 2_000 {
                Text("仅显示结果末尾 2,000 个字符。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }
        }
        .panelCard(theme: theme)
    }

    private func approvalSection(_ approval: CodexPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(theme.accent2)
                sectionTitle(approval.title)
                Spacer()
                if liveState.pendingApprovals.count > 1 {
                    Text("1 / \(liveState.pendingApprovals.count)")
                        .harvisFont(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Text("必须人工确认")
                    .harvisFont(.caption2.bold())
                    .foregroundColor(theme.accent2)
            }

            Text(String(approval.detail.prefix(2_000)))
                .harvisFont(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if approval.method == "item/fileChange/requestApproval"
                || approval.method == "applyPatchApproval" {
                fileChangeDetails(approval)
            }

            approvalControls(approval)

            if let approvalValidationError {
                Label(approvalValidationError, systemImage: "exclamationmark.circle.fill")
                    .harvisFont(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelCard(theme: theme, emphasized: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("等待人工审批：\(approval.title)")
    }

    @ViewBuilder
    private func approvalControls(_ approval: CodexPendingApproval) -> some View {
        switch approval.method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "execCommandApproval",
             "applyPatchApproval":
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    if allows(.accept, for: approval) {
                        approvalButton("仅本次允许", decision: .accept, approval: approval)
                    }
                    if allows(.acceptForSession, for: approval) {
                        approvalButton("本会话允许", decision: .acceptForSession, approval: approval)
                    }
                    if allows(.decline, for: approval) {
                        approvalButton("拒绝", decision: .decline, approval: approval, destructive: true)
                    }
                    if approval.availableDecisions?.contains(.cancel) == true {
                        approvalButton("取消 Turn", decision: .cancel, approval: approval, destructive: true)
                    }
                }
                if approval.availableDecisions?.isEmpty == true {
                    Text("Codex 没有提供此面板支持的标准审批决定。")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                }
            }

        case "item/permissions/requestApproval":
            VStack(alignment: .leading, spacing: 8) {
                if let permissions = approval.params["permissions"]?.encodedString() {
                    Text(String(permissions.prefix(1_200)))
                        .harvisFont(.caption2.monospaced())
                        .foregroundColor(theme.muted)
                        .textSelection(.enabled)
                }
                HStack(spacing: 7) {
                    approvalButton("允许权限", decision: .accept, approval: approval)
                    approvalButton("拒绝", decision: .decline, approval: approval, destructive: true)
                }
            }

        case "item/tool/requestUserInput":
            userInputControls(approval)

        case "mcpServer/elicitation/request":
            mcpControls(approval)

        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("未知请求类型：\(approval.method)。HarvisBar 不会自动响应。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("显式拒绝未知请求") {
                    rejectUnsupported(approval)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isResolvingApproval)
            }
        }
    }

    private func userInputControls(_ approval: CodexPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(approval.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = nonempty(question.header) {
                        Text(header)
                            .harvisFont(.caption.bold())
                            .foregroundColor(theme.accent)
                    }
                    Text(question.question)
                        .harvisFont(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if question.options.isEmpty {
                        if question.isSecret {
                            SecureField(
                                "输入保密回答",
                                text: answerBinding(for: question.id)
                            )
                            .textFieldStyle(.roundedBorder)
                        } else {
                            TextField(
                                "输入回答",
                                text: answerBinding(for: question.id)
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                    } else {
                        ForEach(question.options) { option in
                            Button {
                                selectedOptions[question.id] = option.label
                                approvalAnswers[question.id] = ""
                            } label: {
                                HStack(alignment: .top, spacing: 7) {
                                    Image(
                                        systemName: selectedOptions[question.id] == option.label
                                            ? "largecircle.fill.circle"
                                            : "circle"
                                    )
                                    .foregroundColor(theme.accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(option.label)
                                            .harvisFont(.caption)
                                        if let description = nonempty(option.description) {
                                            Text(description)
                                                .harvisFont(.caption2)
                                                .foregroundColor(theme.muted)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if question.isOther {
                            Group {
                                if question.isSecret {
                                    SecureField(
                                        "或输入保密自定义回答",
                                        text: answerBinding(for: question.id)
                                    )
                                } else {
                                    TextField(
                                        "或输入自定义回答",
                                        text: answerBinding(for: question.id)
                                    )
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                                .onChange(of: approvalAnswers[question.id, default: ""]) { value in
                                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        selectedOptions[question.id] = nil
                                    }
                                }
                        }
                    }
                }
            }

            HStack(spacing: 7) {
                Button("提交回答") {
                    submitAnswers(approval)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(isResolvingApproval || approval.questions.isEmpty)

                Button("拒绝") {
                    resolve(approval, decision: .decline)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isResolvingApproval)

                Button("取消") {
                    resolve(approval, decision: .cancel)
                }
                .buttonStyle(.bordered)
                .disabled(isResolvingApproval)
            }
        }
    }

    private func fileChangeDetails(
        _ approval: CodexPendingApproval
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("具体文件变更")
                .harvisFont(.caption.bold())
                .foregroundColor(theme.text)

            if approval.fileChanges.isEmpty {
                Text("尚未收到与 itemId 对应的 fileChange diff；不会用路径或原因代替实际变更。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(
                    Array(approval.fileChanges.prefix(8).enumerated()),
                    id: \.offset
                ) { entry in
                    let change = entry.element
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(change.kind.uppercased())
                                .harvisFont(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.accent2)
                            Text(change.path)
                                .harvisFont(.caption2.monospaced())
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Text(String(change.diff.prefix(3_000)))
                            .harvisFont(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(theme.line.opacity(0.75))
                    )
                }
                if approval.fileChanges.count > 8 {
                    Text("仅显示前 8 个文件变更。")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                }
            }
        }
    }

    private func mcpControls(_ approval: CodexPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("返回给 MCP 的结构化 JSON 对象")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)

            TextEditor(text: $mcpJSON)
                .harvisFont(.caption.monospaced())
                .frame(minHeight: 82, maxHeight: 150)
                .padding(5)
                .scrollContentBackground(.hidden)
                .background(theme.surfaceAlt.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line))

            HStack(spacing: 7) {
                Button("接受并返回 JSON") {
                    acceptMCP(approval)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(isResolvingApproval)

                Button("拒绝") {
                    resolve(approval, decision: .decline)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isResolvingApproval)
            }
        }
    }

    @ViewBuilder
    private func approvalButton(
        _ label: String,
        decision: CodexApprovalDecision,
        approval: CodexPendingApproval,
        destructive: Bool = false
    ) -> some View {
        if decision == .accept {
            Button(label) {
                resolve(approval, decision: decision)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .disabled(isResolvingApproval)
        } else {
            Button(label) {
                resolve(approval, decision: decision)
            }
            .buttonStyle(.bordered)
            .tint(destructive ? .red : theme.accent)
            .disabled(isResolvingApproval)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 7) {
            Button(action: onOpen) {
                Label("在 Codex 打开", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .help("在 Codex Desktop 打开选中任务")

            if handoffSupported {
                Button {
                    beginHandoff()
                } label: {
                    Label(handoffButtonLabel, systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(!handoffCanBegin)
                .help(handoffButtonHelp)
            }

            Spacer(minLength: 4)

            Text("只显示实时事件与结果摘要")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
        }
    }

    private var handoffCanBegin: Bool {
        guard handoffSupported else { return false }
        guard coordinator.isReady, handoffs.isReady else { return false }
        guard let latestHandoff else { return true }
        switch latestHandoff.state {
        case .failed, .cancelled:
            return true
        case .queuedSummary, .summarizing, .summaryWaitingApproval,
             .creatingDestination, .seedingDestination,
             .destinationWaitingApproval, .verified, .deliveryUnknown:
            return false
        }
    }

    private var handoffButtonLabel: String {
        guard let latestHandoff else { return "一键交接" }
        switch latestHandoff.state {
        case .failed, .cancelled: return "重新交接"
        case .verified: return "已交接"
        case .deliveryUnknown: return "状态未知"
        default: return latestHandoff.statusLabel
        }
    }

    private var handoffButtonHelp: String {
        if !coordinator.isReady || !handoffs.isReady {
            return "正在恢复持久化任务队列与交接记录，完成前不会创建或发送交接任务。"
        }
        if latestHandoff?.state == .deliveryUnknown {
            return "交付是否到达无法确认；请先检查源任务与可能的新任务，Harvis 不会盲目重发。"
        }
        return "创建干净的新 Codex 任务；验证成功后给旧任务添加 #done。"
    }

    private func beginHandoff() {
        guard handoffCanBegin, thread.sourceScope == home.id else { return }
        Task {
            _ = await handoffs.begin(
                homeID: home.id,
                homePath: normalizedHomePath,
                sourceThreadID: thread.sourceID,
                sourceTitle: thread.title,
                cardType: thread.taskCardType,
                onVerified: onHandoffVerified
            )
        }
    }

    private func handoffColor(
        _ state: CodexConversationHandoffState
    ) -> Color {
        switch state {
        case .verified: return theme.positive
        case .failed: return .red
        case .deliveryUnknown, .summaryWaitingApproval,
             .destinationWaitingApproval: return .orange
        case .cancelled: return theme.muted
        case .queuedSummary, .summarizing, .creatingDestination,
             .seedingDestination: return theme.accent
        }
    }

    private var runtimeStatusColor: Color {
        switch liveState.status {
        case .active: return theme.positive
        case .waitingApproval, .waitingUserInput: return theme.accent2
        case .idle: return theme.recentStatus
        case .disconnected, .notLoaded: return theme.muted
        case .systemError: return .red
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .harvisFont(.caption.bold())
            .foregroundColor(theme.text)
    }

    private func compactValue(
        _ label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .frame(width: 38, alignment: .leading)
            Text(value)
                .harvisFont(monospaced ? .caption2.monospaced() : .caption2)
                .lineLimit(2)
                .textSelection(.enabled)
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

    private func answerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { approvalAnswers[questionID, default: ""] },
            set: { approvalAnswers[questionID] = $0 }
        )
    }

    private func allows(
        _ decision: CodexApprovalDecisionOption,
        for approval: CodexPendingApproval
    ) -> Bool {
        approval.availableDecisions?.contains(decision) ?? true
    }

    private func submitAnswers(_ approval: CodexPendingApproval) {
        var answers: [String: [String]] = [:]
        for question in approval.questions {
            let custom = approvalAnswers[question.id, default: ""]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty {
                answers[question.id] = [custom]
            } else if let selected = selectedOptions[question.id] {
                answers[question.id] = [selected]
            } else {
                approvalValidationError = "请回答“\(question.header ?? question.question)”。"
                return
            }
        }
        approvalValidationError = nil
        resolve(approval, decision: .accept, answers: answers)
    }

    private func acceptMCP(_ approval: CodexPendingApproval) {
        guard let data = mcpJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(CodexJSONValue.self, from: data),
              value.objectValue != nil else {
            approvalValidationError = "MCP 内容必须是有效的 JSON 对象。"
            return
        }
        approvalValidationError = nil
        resolve(approval, decision: .accept, mcpContent: value)
    }

    private func resolve(
        _ approval: CodexPendingApproval,
        decision: CodexApprovalDecision,
        answers: [String: [String]] = [:],
        mcpContent: CodexJSONValue? = nil
    ) {
        guard !isResolvingApproval else { return }
        isResolvingApproval = true
        Task {
            await coordinator.resolveApproval(
                approval,
                homePath: home.path,
                decision: decision,
                answers: answers,
                mcpContent: mcpContent
            )
            isResolvingApproval = false
        }
    }

    private func rejectUnsupported(_ approval: CodexPendingApproval) {
        guard !isResolvingApproval else { return }
        isResolvingApproval = true
        Task {
            await coordinator.rejectUnsupportedApproval(
                approval,
                homePath: home.path
            )
            isResolvingApproval = false
        }
    }

    private func resetApprovalForm() {
        approvalAnswers = [:]
        selectedOptions = [:]
        mcpJSON = "{}"
        approvalValidationError = nil
        isResolvingApproval = false
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension View {
    func panelCard(
        theme: HarvisTheme,
        emphasized: Bool = false
    ) -> some View {
        self
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                emphasized
                    ? theme.accent2.opacity(0.08)
                    : theme.surfaceAlt.opacity(0.42)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(emphasized ? theme.accent2 : theme.line, lineWidth: 1)
            )
    }
}

private extension CodexThreadRuntimeStatus {
    var displayLabel: String {
        switch self {
        case .disconnected: return "未连接"
        case .idle: return "空闲"
        case .active: return "运行中"
        case .waitingApproval: return "等待审批"
        case .waitingUserInput: return "等待回答"
        case .notLoaded: return "未加载"
        case .systemError: return "系统错误"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: return "bolt.slash"
        case .idle: return "pause.circle"
        case .active: return "waveform.path.ecg"
        case .waitingApproval: return "hand.raised.fill"
        case .waitingUserInput: return "questionmark.bubble.fill"
        case .notLoaded: return "tray"
        case .systemError: return "exclamationmark.triangle.fill"
        }
    }
}

private extension CodexDeliveryState {
    var displayLabel: String {
        switch self {
        case .queued: return "已排队"
        case .waiting: return "等待空闲"
        case .dispatching: return "派发中"
        case .running: return "运行中"
        case .waitingApproval: return "等待审批"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .deliveryUnknown: return "交付未知"
        case .cancelled: return "已取消"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "list.bullet.rectangle"
        case .waiting: return "clock"
        case .dispatching: return "paperplane"
        case .running: return "play.circle.fill"
        case .waitingApproval: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .deliveryUnknown: return "questionmark.diamond.fill"
        case .cancelled: return "nosign"
        }
    }

    func color(in theme: HarvisTheme) -> Color {
        switch self {
        case .completed: return theme.positive
        case .running, .dispatching: return theme.accent
        case .waitingApproval, .waiting, .queued, .deliveryUnknown: return theme.accent2
        case .failed: return .red
        case .cancelled: return theme.muted
        }
    }
}

private extension CodexLiveEventKind {
    var systemImage: String {
        switch self {
        case .connection: return "bolt.horizontal.circle"
        case .status: return "gauge.with.dots.needle.33percent"
        case .turn: return "arrow.triangle.2.circlepath"
        case .tool: return "hammer"
        case .message: return "text.bubble"
        case .approval: return "hand.raised"
        case .error: return "exclamationmark.triangle"
        }
    }

    func color(in theme: HarvisTheme) -> Color {
        switch self {
        case .error: return .red
        case .approval: return theme.accent2
        case .connection, .status: return theme.muted
        case .turn, .tool, .message: return theme.accent
        }
    }
}
