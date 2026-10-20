import SwiftUI

struct ManagedSupervisorSheet: View {
    @EnvironmentObject var model: HarvisRuntimeModel
    @Environment(\.dismiss) private var dismiss
    let thread: ManagedChatThread
    let theme: HarvisTheme
    let onOpenProject: () -> Void

    @State private var supervisorReadReady = false
    @State private var supervisorOpenedAt = Date()
    @State private var acceptedSupervisorReadAt: Date?
    @State private var actionFeedback: String?
    @State private var successfulSettingsToken: UUID?

    var body: some View {
        let reviewedSnapshot = model.supervisorSnapshot(for: thread)
        ManagedSupervisorPanel(
            title: thread.title,
            source: "\(thread.provider.label) · \(thread.sourceScope)",
            sessionID: thread.sourceID,
            cardIdentity: thread.id,
            compatibility: ManagedSupervisorCompatibility.resolve(thread),
            state: reviewedSnapshot?.state,
            readAt: reviewedSnapshot?.readAt,
            error: model.supervisorErrors[thread.id],
            issueKind: model.supervisorIssueKinds[thread.id],
            busy: model.supervisorBusyThreadIDs.contains(thread.id),
            readReady: supervisorReadReady,
            actionFeedback: actionFeedback,
            successfulSettingsToken: successfulSettingsToken,
            availableOperations: Set(model.supervisorEndpoint(for: thread)?.catalog?.capabilities
                .first(where: { $0.id == "supervisor.session" })?.operations ?? []),
            theme: theme,
            onRefresh: {
                actionFeedback = nil
                Task { @MainActor in
                    await refreshSupervisor(discover: true)
                }
            },
            onAction: { operation, patch in
                actionFeedback = nil
                Task { @MainActor in
                    let succeeded = await model.updateSupervisor(
                        for: thread,
                        operation: operation,
                        patch: patch,
                        expectedRevision: reviewedSnapshot?.state.revision
                    )
                    guard !Task.isCancelled, succeeded else { return }
                    if operation == .set {
                        successfulSettingsToken = UUID()
                    }
                    actionFeedback = successFeedback(
                        for: operation,
                        state: model.supervisorSnapshot(for: thread)?.state
                    )
                }
            },
            onOpenSession: { model.openManagedThread(thread) },
            onOpenProject: { dismiss(); onOpenProject() },
            onClose: { dismiss() }
        )
        .onAppear {
            supervisorOpenedAt = Date()
            acceptedSupervisorReadAt = nil
            supervisorReadReady = false
        }
        .onChange(of: thread.id) { _ in
            supervisorOpenedAt = Date()
            acceptedSupervisorReadAt = nil
            supervisorReadReady = false
            actionFeedback = nil
            successfulSettingsToken = nil
        }
        .task(id: thread.id) {
            // A prior ambiguous mutation is a requires-review condition. It
            // must remain visible until the user explicitly chooses refresh;
            // reopening the sheet must not silently reconcile it.
            if !hasRequiresReviewIssue {
                await refreshSupervisor(discover: true)
            }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                // Preserve an ambiguous action error until the user explicitly
                // asks to reconcile. Polling never repeats a control request.
                if model.supervisorErrors[thread.id] == nil {
                    await refreshSupervisor(discover: false)
                }
            }
        }
    }

    private var hasRequiresReviewIssue: Bool {
        if case .requiresReview = model.supervisorIssueKinds[thread.id] { return true }
        return false
    }

    @MainActor
    private func refreshSupervisor(discover: Bool) async {
        // The overview can already be reading this card.  Its guard returns
        // without a new read, so an old cached snapshot must not make a newly
        // opened sheet actionable.
        let requestedAt = Date()
        let hadAcceptedRead = acceptedSupervisorReadAt != nil
        supervisorReadReady = false
        await model.refreshSupervisor(for: thread, discover: discover)
        guard !Task.isCancelled else { return }
        guard model.supervisorErrors[thread.id] == nil,
              !model.supervisorBusyThreadIDs.contains(thread.id),
              let snapshot = model.supervisorSnapshot(for: thread),
              snapshot.readAt > requestedAt,
              snapshot.readAt >= supervisorOpenedAt else {
            // A background poll may lose a race with another read.  Once this
            // sheet has accepted one read, the existing controls can become
            // available again when that in-flight work ends; a newly opened
            // sheet has no accepted read and stays locked.
            supervisorReadReady = hadAcceptedRead
            return
        }
        acceptedSupervisorReadAt = snapshot.readAt
        supervisorReadReady = true
    }

    private func successFeedback(
        for operation: DshSupervisorOperation,
        state: DshSupervisorState?
    ) -> String {
        switch operation {
        case .set:
            return state?.mode == "off" ? "监督已关闭。" : "监督设置已保存。"
        case .regenerate: return "已请求重新生成监督建议。"
        case .adopt: return "建议已发送，后续执行/审批由 DSH 管理。"
        case .recover:
            return state?.recoveryRequired.isEmpty == false
                ? "已核对，但仍有待处理恢复事项。"
                : "已核对，监督状态已恢复。"
        }
    }
}

/// Presentation-only surface also used by synthetic native rendering fixtures.
struct ManagedSupervisorPanel: View {
    @Environment(\.harvisTextSize) private var textSize
    let title: String
    let source: String
    let sessionID: String
    let cardIdentity: String
    let compatibility: ManagedSupervisorCompatibility
    let state: DshSupervisorState?
    let readAt: Date?
    let error: String?
    let issueKind: ManagedSupervisorIssueKind?
    let busy: Bool
    let readReady: Bool
    let actionFeedback: String?
    let successfulSettingsToken: UUID?
    let availableOperations: Set<String>
    let theme: HarvisTheme
    let onRefresh: () -> Void
    let onAction: (DshSupervisorOperation, DshSupervisorPatch?) -> Void
    let onOpenSession: () -> Void
    let onOpenProject: () -> Void
    let onClose: () -> Void

    @State private var settingsDraft: ManagedSupervisorSettingsDraft?

    init(
        title: String,
        source: String,
        sessionID: String,
        cardIdentity: String = "",
        compatibility: ManagedSupervisorCompatibility,
        state: DshSupervisorState?,
        readAt: Date?,
        error: String?,
        issueKind: ManagedSupervisorIssueKind? = nil,
        busy: Bool,
        readReady: Bool = false,
        actionFeedback: String? = nil,
        successfulSettingsToken: UUID? = nil,
        availableOperations: Set<String>,
        theme: HarvisTheme,
        onRefresh: @escaping () -> Void,
        onAction: @escaping (DshSupervisorOperation, DshSupervisorPatch?) -> Void,
        onOpenSession: @escaping () -> Void,
        onOpenProject: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.source = source
        self.sessionID = sessionID
        self.cardIdentity = cardIdentity
        self.compatibility = compatibility
        self.state = state
        self.readAt = readAt
        self.error = error
        self.issueKind = issueKind
        self.busy = busy
        self.readReady = readReady
        self.actionFeedback = actionFeedback
        self.successfulSettingsToken = successfulSettingsToken
        self.availableOperations = availableOperations
        self.theme = theme
        self.onRefresh = onRefresh
        self.onAction = onAction
        self.onOpenSession = onOpenSession
        self.onOpenProject = onOpenProject
        self.onClose = onClose
        _settingsDraft = State(initialValue: state.map {
            ManagedSupervisorSettingsDraft(state: $0, identity: cardIdentity.isEmpty ? sessionID : cardIdentity)
        })
    }

    private var canAct: Bool { state != nil && error == nil && !busy && readReady }
    private var draftIdentity: String { cardIdentity.isEmpty ? sessionID : cardIdentity }
    private var settingsCanAct: Bool {
        canAct && settingsDraft != nil && !(settingsDraft?.isConflicted ?? true)
    }
    private var settingsCanSubmit: Bool {
        settingsCanAct && settingsDraft?.canSubmit == true
    }

    private var selectedMode: String {
        settingsDraft?.mode ?? state?.mode ?? "off"
    }

    private var selectedStrategy: String {
        settingsDraft?.strategy ?? state?.strategy ?? "plan"
    }

    private var rounds: Int {
        settingsDraft?.rounds ?? state?.rounds ?? 1
    }

    private var intervalSeconds: Int {
        settingsDraft?.intervalSeconds
            ?? max(2, (state?.intervalMs ?? 60_000) / 1_000)
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { selectedMode },
            set: { value in
                guard var draft = settingsDraft else { return }
                draft.setMode(value)
                settingsDraft = draft
            }
        )
    }

    private var strategyBinding: Binding<String> {
        Binding(
            get: { selectedStrategy },
            set: { value in
                guard var draft = settingsDraft else { return }
                draft.setStrategy(value)
                settingsDraft = draft
            }
        )
    }

    private var roundsBinding: Binding<Int> {
        Binding(
            get: { rounds },
            set: { value in
                guard var draft = settingsDraft else { return }
                draft.setRounds(value)
                settingsDraft = draft
            }
        )
    }

    private var intervalSecondsBinding: Binding<Int> {
        Binding(
            get: { intervalSeconds },
            set: { value in
                guard var draft = settingsDraft else { return }
                draft.setIntervalSeconds(value)
                settingsDraft = draft
            }
        )
    }

    private func canPerform(_ operation: DshSupervisorOperation) -> Bool {
        canAct && availableOperations.contains(operation.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eye.circle")
                    .harvisFont(.system(size: 25))
                    .foregroundColor(theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(compatibility == .codexProject ? "会话项目管理" : "会话监督")
                        .harvisFont(.title3.bold())
                    Text(title).harvisFont(.subheadline).lineLimit(2)
                    Text(source).harvisFont(.caption).foregroundColor(theme.muted)
                }
                Spacer(minLength: 8)
                Button("完成", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("supervisor.close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch compatibility {
                    case .dsh: dshControls
                    case .codexProject:
                        explanation(
                            "所属项目的监督范围",
                            "项目管理大脑会读取所属项目的完整会话清单，其中可能还有其他账号或被当前筛选隐藏的会话。请在项目管理中查看完整名单及纳入状态。"
                        )
                        Text("项目大脑按精确项目归属划分，不自动覆盖子项目。建议仍需逐项批准；DSH 会话的自动接管在各自卡片单独设置。")
                            .harvisFont(.caption).foregroundColor(theme.muted)
                        Button("查看项目监督范围", action: onOpenProject)
                            .buttonStyle(HarvisControlButtonStyle(theme: theme))
                            .accessibilityIdentifier("supervisor.open-project")
                    case let .observation(reason):
                        explanation("当前仅支持观察", reason)
                    }

                    DisclosureGroup("会话身份") {
                        Text(sessionID)
                            .harvisFont(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
        }
        .padding(20)
        .frame(width: textSize == .large ? 660 : (textSize == .medium ? 600 : 540),
               height: compatibility == .dsh ? 690 : 430)
        .foregroundColor(theme.text)
        .background(theme.background)
        .accessibilityIdentifier("supervisor.panel")
        .onAppear { syncSettings() }
        .onChange(of: cardIdentity) { _ in
            settingsDraft = nil
            syncSettings()
        }
        .onChange(of: state) { _ in syncSettings() }
        .onChange(of: successfulSettingsToken) { _ in
            guard let state else { return }
            settingsDraft = ManagedSupervisorSettingsDraft(
                state: state, identity: draftIdentity
            )
        }
    }

    @ViewBuilder
    private var dshControls: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.map { "DSH Supervisor · \($0.modeLabel)" } ?? "DSH Supervisor")
                    .harvisFont(.headline)
                Text(state?.statusLabel ?? (busy ? "正在读取监督状态…" : "尚未读取监督状态"))
                    .harvisFont(.caption).foregroundColor(theme.muted)
                if let readAt {
                    Text("上次核对 \(readAt.formatted(date: .omitted, time: .standard))")
                        .harvisFont(.caption2).foregroundColor(theme.muted)
                }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("刷新", action: onRefresh)
                .disabled(busy)
                .accessibilityIdentifier("supervisor.refresh")
        }

        VStack(alignment: .leading, spacing: 6) {
            Label("监督对象：仅此 DSH 会话（1 个）", systemImage: "scope")
                .harvisFont(.subheadline.bold())
            Text("提意见、自动接管及关闭都只作用于上方这一个会话；不会连带开启同项目、同账号或子会话的监督。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("supervisor.exact-scope")

        if let error {
            Label(error, systemImage: "exclamationmark.circle")
                .harvisFont(.caption)
                .foregroundColor(theme.accent2)
                .textSelection(.enabled)
                .accessibilityIdentifier("supervisor.error")
        }

        if let actionFeedback {
            Label(actionFeedback, systemImage: "checkmark.circle")
                .harvisFont(.caption)
                .foregroundColor(theme.positive)
                .accessibilityIdentifier("supervisor.feedback")
        }

        if !readReady {
            Text(busy ? "正在核对监督状态，控制项暂不可用。" : "请先刷新以核对监督状态；控制项会在首次读回后启用。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .accessibilityIdentifier("supervisor.read-pending")
        }

        if state == nil && !busy {
            Button("打开此 DSH 会话", action: onOpenSession)
                .accessibilityIdentifier("supervisor.open-session")
            Text("未加载的会话需先在 DSH 中打开，然后点击刷新。")
                .harvisFont(.caption).foregroundColor(theme.muted)
        }

        if let state {
            HStack(spacing: 16) {
                Label("已用 \(state.used) / \(state.rounds) 轮", systemImage: "repeat")
                Text("剩余 \(state.remaining) 轮")
                if !state.mentorName.isEmpty { Text(state.mentorName).lineLimit(1) }
            }
            .harvisFont(.caption.monospacedDigit())
            .foregroundColor(theme.muted)

            if !state.recoveryRequired.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("监督执行需要恢复核对").harvisFont(.subheadline.bold())
                    Text(state.recoveryRequired).harvisFont(.caption)
                    Button("核对持久化执行状态") { onAction(.recover, nil) }
                        .disabled(!canPerform(.recover))
                        .accessibilityIdentifier("supervisor.recover")
                }
            }

            Divider().overlay(theme.line)

            VStack(alignment: .leading, spacing: 10) {
                Text("监督设置").harvisFont(.subheadline.bold())
                if let draft = settingsDraft, draft.isConflicted {
                    Label(
                        "远端监督设置已变化（\(draft.conflictFields.count) 项）。本地编辑已保留，请使用最新设置后重新编辑。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .harvisFont(.caption)
                    .foregroundColor(theme.accent2)
                    .accessibilityIdentifier("supervisor.settings-conflict")
                    HStack(spacing: 10) {
                        Button("使用最新设置") { useLatestSettings() }
                            .disabled(!canAct)
                            .accessibilityIdentifier("supervisor.use-latest-settings")
                        Button("刷新核对", action: onRefresh)
                            .disabled(busy)
                            .accessibilityIdentifier("supervisor.recheck-settings")
                    }
                }
                Picker("监督模式", selection: modeBinding) {
                    Text("关闭").tag("off")
                    Text("提意见").tag("advice")
                    Text("自动接管").tag("takeover")
                }
                .pickerStyle(.segmented)
                .disabled(!settingsCanAct)
                .accessibilityIdentifier("supervisor.mode")
                Text(modeDescription)
                    .harvisFont(.caption).foregroundColor(theme.muted)
                HStack(spacing: 12) {
                    Picker("策略", selection: strategyBinding) {
                        Text("计划驱动").tag("plan")
                        Text("理解驱动").tag("insight")
                        Text("固定提示").tag("fixed")
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!settingsCanAct)
                    Stepper("\(rounds) 轮", value: roundsBinding, in: 1...10_000)
                        .frame(width: 130)
                        .disabled(!settingsCanAct)
                }
                Stepper("检查间隔：\(intervalSeconds) 秒", value: intervalSecondsBinding, in: 2...3_600, step: 2)
                    .harvisFont(.caption.monospacedDigit())
                    .disabled(!settingsCanAct)
                HStack {
                    Button(settingsApplyTitle) {
                        guard let patch = settingsDraft?.patch() else { return }
                        onAction(.set, patch)
                    }
                    .buttonStyle(HarvisControlButtonStyle(theme: theme))
                    .disabled(!settingsCanSubmit || !state.recoveryRequired.isEmpty
                        || !availableOperations.contains(DshSupervisorOperation.set.rawValue))
                    .accessibilityIdentifier("supervisor.apply")
                    Spacer()
                    Button("关闭监督") {
                        onAction(.set, DshSupervisorPatch(mode: "off"))
                    }
                        .disabled(!canPerform(.set) || state.mode == "off")
                        .accessibilityIdentifier("supervisor.off")
                }
                Text("关闭监督会停止后续监督建议；原会话已经开始的执行与审批由 DSH 继续管理。")
                    .harvisFont(.caption2).foregroundColor(theme.muted)
            }

            Divider().overlay(theme.line)

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("最新建议").harvisFont(.subheadline.bold())
                    Spacer()
                    Button("重新生成") { onAction(.regenerate, nil) }
                        .disabled(!canPerform(.regenerate) || !state.canRegenerate)
                        .accessibilityIdentifier("supervisor.regenerate")
                }
                if !state.suggestError.isEmpty {
                    Text(state.suggestError).harvisFont(.caption).foregroundColor(theme.accent2)
                }
                Text(state.suggestion.isEmpty ? "尚无建议。启用监督后可在此查看生成结果。" : state.suggestion)
                    .harvisFont(.system(size: 13))
                    .foregroundColor(state.suggestion.isEmpty ? theme.muted : theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
                    .accessibilityIdentifier("supervisor.suggestion")
                Button("将建议发送到此会话") { onAction(.adopt, nil) }
                    .buttonStyle(HarvisControlButtonStyle(theme: theme))
                    .disabled(!canPerform(.adopt) || !state.canAdopt)
                    .accessibilityIdentifier("supervisor.adopt")
            }
        }
    }

    private func explanation(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).harvisFont(.headline)
            Text(text).harvisFont(.subheadline).foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeDescription: String {
        switch selectedMode {
        case "takeover": return "按轮次上限自动将建议送入此 DSH 会话；原生审批仍需在 DSH 中处理。"
        case "off":
            return state?.mode == "off"
                ? "监督已关闭，不会产生新的监督建议。"
                : "应用后关闭监督；当前监督仍按原设置运行。"
        default: return "生成建议后由你决定是否发送到此 DSH 会话。"
        }
    }

    private var settingsApplyTitle: String {
        switch selectedMode {
        case "takeover": return "应用接管设置"
        case "off": return "应用关闭设置"
        default: return "应用提意见设置"
        }
    }

    private func useLatestSettings() {
        guard let state else { return }
        if var draft = settingsDraft {
            draft.useLatestSettings(state)
            settingsDraft = draft
        } else {
            settingsDraft = ManagedSupervisorSettingsDraft(
                state: state, identity: draftIdentity
            )
        }
    }

    private func syncSettings() {
        guard let state else { return }
        if var draft = settingsDraft {
            draft.observe(state, identity: draftIdentity)
            settingsDraft = draft
        } else {
            settingsDraft = ManagedSupervisorSettingsDraft(
                state: state, identity: draftIdentity
            )
        }
    }
}
