import SwiftUI

enum ManagedProjectBrainDecisionApproval: Equatable {
    case approvable
    case readOnly(String)
}

struct ManagedProjectBrainDeliveryPresentation: Equatable {
    let label: String
    let systemImage: String
    let tone: ManagedConversationPlanTone
}

enum ManagedProjectBrainPreviewPolicy {
    static let defaultObjective =
        "检查当前项目任务清单与对话状态，提出一个下一步最小、可验证且与显式任务绑定一致的动作。"

    static func normalizedObjective(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canGenerate(
        brainEnabled: Bool?,
        endpointAvailable: Bool,
        objective: String,
        isGenerating: Bool,
        hasPreview: Bool,
        generatorAvailable: Bool
    ) -> Bool {
        let normalized = normalizedObjective(objective)
        return brainEnabled == true
            && endpointAvailable
            && generatorAvailable
            && !isGenerating
            && !hasPreview
            && !normalized.isEmpty
            && normalized.count
                <= ConversationManagementSchemaV1.maxPromptCharacters
    }

    static func approval(
        for decision: ConversationManagementDecisionV1
    ) -> ManagedProjectBrainDecisionApproval {
        guard decision.kind == .dispatch else {
            return .readOnly("该决策仅供查看；当前安全审批接口只接受显式派发决策。")
        }
        guard let target = decision.target,
              !target.provider.isEmpty,
              !target.sourceScope.isEmpty,
              !target.sourceID.isEmpty,
              decision.taskID?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false,
              decision.prompt?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false,
              decision.expectedEvidence?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false else {
            return .readOnly("决策缺少精确 target、taskID、prompt 或预期证据，已禁止批准。")
        }
        return .approvable
    }

    static func decisionKindLabel(
        _ kind: ConversationManagementDecisionKindV1
    ) -> String {
        switch kind {
        case .dispatch: return "派发"
        case .complete: return "完成建议"
        case .needsUser: return "需要用户"
        case .recommendHandoff: return "交接建议"
        }
    }

    static func deliveryPresentation(
        _ delivery: ConversationDeliveryStateV1
    ) -> ManagedProjectBrainDeliveryPresentation {
        switch delivery {
        case .completed:
            return .init(
                label: "已完成",
                systemImage: "checkmark.circle.fill",
                tone: .positive
            )
        case .failed:
            return .init(
                label: "派发失败",
                systemImage: "xmark.octagon.fill",
                tone: .critical
            )
        case .deliveryUnknown:
            return .init(
                label: "送达状态未知",
                systemImage: "questionmark.diamond.fill",
                tone: .critical
            )
        case .waitingApproval:
            return .init(
                label: "等待运行时审批",
                systemImage: "hand.raised.fill",
                tone: .warning
            )
        case .cancelled:
            return .init(
                label: "已取消",
                systemImage: "nosign",
                tone: .warning
            )
        case .queued:
            return .init(
                label: "已加入队列",
                systemImage: "tray.full.fill",
                tone: .informational
            )
        case .dispatching:
            return .init(
                label: "正在派发",
                systemImage: "arrow.up.forward.circle.fill",
                tone: .informational
            )
        case .accepted:
            return .init(
                label: "已接受",
                systemImage: "circle.dotted",
                tone: .neutral
            )
        case .running:
            return .init(
                label: "运行中",
                systemImage: "play.circle",
                tone: .neutral
            )
        case .none:
            return .init(
                label: "尚未派发",
                systemImage: "circle",
                tone: .neutral
            )
        }
    }
}

struct ManagedProjectBrainPreviewView: View {
    @ObservedObject var coordinator: DshMetaAgentCoordinator
    let project: ManagedChatProjectIdentity
    let brainEnabled: Bool?
    let endpoint: DshRuntimeEndpoint?
    let endpointError: String?
    let theme: HarvisTheme
    var managementSnapshot: ConversationManagementSnapshotV1? = nil
    var managementThreads: [ManagedChatThread] = []
    var managementScope: ManagedProjectSupervisionScope? = nil
    let onGenerate:
        ((String) async throws -> DshMetaAgentPreview)?
    let onApprove:
        ((DshMetaAgentPreview, ConversationManagementDecisionV1) async throws
            -> DshMetaAgentDispatchOutcome)?
    let onCancel: ((UUID, Int) async throws -> Void)?

    @State private var objective = ManagedProjectBrainPreviewPolicy.defaultObjective
    @State private var preview: DshMetaAgentPreview?
    @State private var isGenerating = false
    @State private var approvingDecisionIDs: Set<UUID> = []
    @State private var outcomes: [UUID: DshMetaAgentDispatchOutcome] = [:]
    @State private var errorMessage: String?
    @State private var isCancelling = false
    @State private var showCancelConfirmation = false

    private var durableLedger: ConversationManagementProgressLedgerV1? {
        coordinator.latestLedger(projectID: project.id)
    }

    private var durablePreview: DshMetaAgentPreview? {
        guard let ledger = durableLedger,
              let proposal = ledger.latestProposal else {
            return nil
        }
        return DshMetaAgentPreview(
            runID: ledger.runID,
            proposal: proposal,
            ledgerRevision: ledger.revision
        )
    }

    private var displayedPreview: DshMetaAgentPreview? {
        durablePreview ?? preview
    }

    private var hasBlockingRun: Bool {
        guard let ledger = durableLedger else { return false }
        if ledger.entries.isEmpty,
           ledger.latestProposal == nil,
           ledger.currentState.delivery == .none,
           ledger.currentState.management == .observing {
            return false
        }
        guard !ledger.currentState.management.isTerminal else { return false }
        switch ledger.currentState.delivery {
        case .completed, .failed, .deliveryUnknown, .cancelled:
            return false
        default:
            return true
        }
    }

    private var canGenerate: Bool {
        ManagedProjectBrainPreviewPolicy.canGenerate(
            brainEnabled: brainEnabled,
            endpointAvailable: endpoint != nil,
            objective: objective,
            isGenerating: isGenerating,
            hasPreview: hasBlockingRun,
            generatorAvailable: onGenerate != nil
        )
    }

    private var resolvedManagementScope: ManagedProjectSupervisionScope? {
        if let managementScope { return managementScope }
        guard let managementSnapshot else { return nil }
        return ManagedProjectSupervisionScope(
            project: project,
            snapshot: managementSnapshot,
            threads: managementThreads
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(theme.line)

            HStack(spacing: 6) {
                Label("管理建议预览", systemImage: "text.magnifyingglass")
                    .harvisFont(.caption.bold())
                    .foregroundColor(theme.text)
                Spacer(minLength: 6)
                Text("PREVIEW ONLY")
                    .harvisFont(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            endpointStatus
            managementScopeSummary
            durableRunStatus
            objectiveEditor

            HStack(spacing: 8) {
                Button {
                    generatePreview()
                } label: {
                    Label(
                        hasBlockingRun ? "已有持久化管理轮次" : "生成建议预览",
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(!canGenerate)
                .accessibilityIdentifier("project-brain-generate-preview")

                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text("DSH 正在分析…")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .harvisFont(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let preview = displayedPreview {
                proposalView(preview)
            }
        }
        .accessibilityIdentifier("project-brain-preview")
        .onAppear(perform: hydrateObjectiveFromDurableLedger)
        .onReceive(coordinator.$projectStatuses) { _ in
            hydrateObjectiveFromDurableLedger()
        }
        .confirmationDialog(
            "结束当前管理轮次？",
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认结束本轮", role: .destructive) {
                cancelDurableRun()
            }
            Button("保留本轮", role: .cancel) {}
        } message: {
            Text("会持久化 cancelled 状态，不会静默丢弃预览；之后可以创建新轮次。")
        }
    }

    @ViewBuilder
    private var durableRunStatus: some View {
        if let ledger = durableLedger {
            HStack(spacing: 7) {
                Label(
                    "持久化轮次 \(ledger.runID.uuidString.prefix(8)) · \(ledger.currentState.management.rawValue) · rev \(ledger.revision)",
                    systemImage: hasBlockingRun
                        ? "externaldrive.badge.timemachine"
                        : "checkmark.circle"
                )
                .harvisFont(.system(size: 9).monospaced())
                .foregroundColor(hasBlockingRun ? .orange : theme.muted)
                .help("关闭项目页或重启后，预览与审批修订从持久化 ledger 恢复。")
                .accessibilityIdentifier("project-brain-durable-run")

                Spacer(minLength: 4)

                if hasBlockingRun && ledger.dispatchMemory.isEmpty {
                    Button("结束本轮") {
                        showCancelConfirmation = true
                    }
                    .harvisFont(.caption2.bold())
                    .buttonStyle(.borderless)
                    .foregroundColor(.orange)
                    .disabled(isCancelling || onCancel == nil)
                    .help(
                        onCancel == nil
                            ? "安全取消接口尚未接入"
                            : "显式结束并持久化 cancelled 状态"
                    )
                    .accessibilityIdentifier("project-brain-cancel-run")
                } else if hasBlockingRun {
                    Text("Codex 命令已派发，请在任务面板等待或处理")
                        .harvisFont(.caption2)
                        .foregroundColor(.orange)
                        .help("管理脑不能把仍在队列或运行中的 Codex 命令伪装为已取消。")
                }
            }
        }
    }

    @ViewBuilder
    private var endpointStatus: some View {
        if let endpoint {
            Label(
                "专用端点 \(endpoint.homeID)/\(endpoint.profile) · 127.0.0.1:\(endpoint.port)",
                systemImage: "checkmark.shield.fill"
            )
            .harvisFont(.caption2.monospaced())
            .foregroundColor(theme.positive)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("只使用精确专用 DSH Home/Profile；不存在任意 endpoint fallback。")
        } else {
            Label(
                endpointError ?? "专用 DSH 管理端点尚不可用。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .harvisFont(.caption2)
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var managementScopeSummary: some View {
        if let scope = resolvedManagementScope {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "项目监督范围 · 共 \(scope.totalCount) 条 · 审批候选 \(scope.approvalCandidateCount)",
                    systemImage: "scope"
                )
                .harvisFont(.caption2.bold())
                .foregroundColor(scope.brainEnabled ? theme.text : theme.muted)
                Text(
                    scope.brainEnabled
                        ? "提案只从这份精确项目名单读取；候选仍需有效任务计划、证据核验和逐项批准。"
                        : "项目管理大脑已关闭，这份名单只用于配置与观察，当前没有正在进行的监督。"
                )
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                Text("范围不包含子项目；专用 DSH 分析端点不计入会话名单。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("project-brain-preview.supervision-scope")
        } else {
            Label(
                "项目监督范围尚未加载；当前不能声称正在监督。",
                systemImage: "exclamationmark.triangle"
            )
            .harvisFont(.caption2)
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("project-brain-preview.supervision-scope-unavailable")
        }
    }

    private var objectiveEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本轮管理目标")
                .harvisFont(.caption.bold())
                .foregroundColor(theme.muted)
            TextEditor(text: $objective)
                .harvisFont(.caption)
                .frame(minHeight: 66, maxHeight: 92)
                .padding(5)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
                .disabled(isGenerating || hasBlockingRun)
                .accessibilityIdentifier("project-brain-objective")
            HStack {
                Text("固定为单项建议；不会自动派发。")
                Spacer()
                Text(
                    "\(objective.count)/\(ConversationManagementSchemaV1.maxPromptCharacters)"
                )
                .monospacedDigit()
                .foregroundColor(
                    objective.count > ConversationManagementSchemaV1
                        .maxPromptCharacters ? .red : theme.muted
                )
            }
            .harvisFont(.system(size: 9))
            .foregroundColor(theme.muted)
        }
    }

    private func proposalView(_ preview: DshMetaAgentPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("DSH 建议", systemImage: "doc.text.magnifyingglass")
                    .harvisFont(.caption.bold())
                Spacer()
                Text("cycle \(preview.proposal.cycle) · rev \(preview.ledgerRevision)")
                    .harvisFont(.system(size: 9).monospaced())
                    .foregroundColor(theme.muted)
            }
            Text(preview.proposal.summary)
                .harvisFont(.caption)
                .foregroundColor(theme.text)
                .textSelection(.enabled)

            ForEach(preview.proposal.decisions) { decision in
                decisionView(decision, preview: preview)
            }

            Text("Run \(preview.runID.uuidString)")
                .harvisFont(.system(size: 9).monospaced())
                .foregroundColor(theme.muted)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(theme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line))
        .accessibilityIdentifier("project-brain-proposal")
    }

    private func decisionView(
        _ decision: ConversationManagementDecisionV1,
        preview: DshMetaAgentPreview
    ) -> some View {
        let approval = ManagedProjectBrainPreviewPolicy.approval(for: decision)
        let isApproving = approvingDecisionIDs.contains(decision.id)
        let outcome = durableOutcome(
            for: decision.id,
            preview: preview
        ) ?? outcomes[decision.id]

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(
                    ManagedProjectBrainPreviewPolicy.decisionKindLabel(
                        decision.kind
                    )
                )
                .harvisFont(.caption.bold())
                .foregroundColor(decision.kind == .dispatch ? .orange : theme.accent)
                Spacer()
                Text(decision.id.uuidString.prefix(8))
                    .harvisFont(.system(size: 9).monospaced())
                    .foregroundColor(theme.muted)
            }

            exactField("TASK ID", decision.taskID ?? "—")
            exactField("TARGET", decision.target?.stableID ?? "—")
            exactField("REASON", decision.reason)
            if let expectedEvidence = decision.expectedEvidence {
                exactField("EXPECTED EVIDENCE", expectedEvidence)
            }
            if let prompt = decision.prompt {
                VStack(alignment: .leading, spacing: 3) {
                    Text(decision.kind == .needsUser ? "QUESTION" : "EXACT PROMPT")
                        .harvisFont(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.muted)
                    ScrollView {
                        Text(prompt)
                            .harvisFont(.caption.monospaced())
                            .foregroundColor(theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    .padding(6)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }

            approvalControls(
                decision,
                preview: preview,
                approval: approval,
                isApproving: isApproving,
                outcome: outcome
            )
        }
        .padding(9)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
        .accessibilityIdentifier("project-brain-decision-\(decision.id.uuidString)")
    }

    @ViewBuilder
    private func approvalControls(
        _ decision: ConversationManagementDecisionV1,
        preview: DshMetaAgentPreview,
        approval: ManagedProjectBrainDecisionApproval,
        isApproving: Bool,
        outcome: DshMetaAgentDispatchOutcome?
    ) -> some View {
        if let outcome {
            let delivery = ManagedProjectBrainPreviewPolicy
                .deliveryPresentation(outcome.delivery)
            Label(
                "\(delivery.label) · \(outcome.commandID.uuidString)",
                systemImage: delivery.systemImage
            )
            .harvisFont(.caption2.monospaced())
            .foregroundColor(deliveryColor(delivery.tone))
            .textSelection(.enabled)
        } else {
            switch approval {
            case .approvable:
                HStack(spacing: 8) {
                    Button {
                        approve(decision, preview: preview)
                    } label: {
                        Label("显式批准并加入队列", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isApproving || onApprove == nil)
                    .accessibilityIdentifier(
                        "project-brain-approve-\(decision.id.uuidString)"
                    )
                    if isApproving {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("批准前运行时会重新校验项目修订、精确 target、taskID、Enrollment 与队列所有权。")
                    .harvisFont(.system(size: 9))
                    .foregroundColor(theme.muted)
            case let .readOnly(reason):
                Label(reason, systemImage: "eye")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func exactField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .harvisFont(.system(size: 9, weight: .bold))
                .foregroundColor(theme.muted)
            Text(value)
                .harvisFont(.caption.monospaced())
                .foregroundColor(theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deliveryColor(_ tone: ManagedConversationPlanTone) -> Color {
        switch tone {
        case .positive: return theme.positive
        case .informational: return theme.accent
        case .neutral: return theme.muted
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func generatePreview() {
        guard canGenerate, let onGenerate else { return }
        let normalized = ManagedProjectBrainPreviewPolicy.normalizedObjective(
            objective
        )
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                preview = try await onGenerate(normalized)
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func durableOutcome(
        for decisionID: UUID,
        preview: DshMetaAgentPreview
    ) -> DshMetaAgentDispatchOutcome? {
        guard let ledger = durableLedger,
              ledger.runID == preview.runID,
              let memory = ledger.dispatchMemory.first(where: {
                  $0.decisionID == decisionID
              }) else {
            return nil
        }
        return DshMetaAgentDispatchOutcome(
            commandID: memory.commandID,
            delivery: ledger.currentState.delivery
        )
    }

    private func hydrateObjectiveFromDurableLedger() {
        guard let ledger = durableLedger,
              objective == ManagedProjectBrainPreviewPolicy.defaultObjective
                || hasBlockingRun else {
            return
        }
        objective = ledger.objective
    }

    private func approve(
        _ decision: ConversationManagementDecisionV1,
        preview: DshMetaAgentPreview
    ) {
        guard ManagedProjectBrainPreviewPolicy.approval(for: decision)
                == .approvable,
              let onApprove else {
            return
        }
        approvingDecisionIDs.insert(decision.id)
        errorMessage = nil
        Task {
            do {
                outcomes[decision.id] = try await onApprove(preview, decision)
            } catch {
                errorMessage = error.localizedDescription
            }
            approvingDecisionIDs.remove(decision.id)
        }
    }

    private func cancelDurableRun() {
        guard let ledger = durableLedger,
              !ledger.currentState.management.isTerminal,
              ledger.dispatchMemory.isEmpty,
              let onCancel else {
            return
        }
        isCancelling = true
        errorMessage = nil
        Task {
            do {
                try await onCancel(ledger.runID, ledger.revision)
                preview = nil
                outcomes.removeAll()
            } catch {
                errorMessage = error.localizedDescription
            }
            isCancelling = false
        }
    }
}
