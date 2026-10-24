import AppKit
import SwiftUI

@MainActor
struct HarvisGroupWindowView: View {
    @ObservedObject var runtime: HarvisRuntimeModel
    @ObservedObject var coordinator: HarvisGroupCoordinator
    @ObservedObject var composerState: HarvisGroupComposerState

    @State private var sheetRoute: HarvisGroupSheetRoute?
    @State private var fallbackSelectedGroupID: UUID?
    @State private var visibleMessageCount = 100
    @State private var submitErrors: [UUID: String] = [:]
    @State private var groupSettingsErrors: [UUID: String] = [:]
    @State private var sendingGroupIDs: Set<UUID> = []
    @State private var settingOwnerGroupIDs: Set<UUID> = []
    @State private var pendingProjectPermissions: [UUID: HarvisGroupPermission] = [:]
    @State private var pendingBackgroundValues: [UUID: Bool] = [:]
    @State private var pendingRunIDs: Set<UUID> = []
    @State private var runActionErrors: [UUID: String] = [:]
    @State private var expandedRunID: UUID?
    @State private var copiedAgentEntryGroupID: UUID?
    @State private var isRetryingActivation = false
    @State private var isRetryingComposerPersistence = false
    @State private var observedDeliveryReady = false
    @State private var observedDeliveryError: String?
    @State private var timelineIsFollowingLatest = true
    @State private var newTimelineMessageCount = 0
    @State private var timelineObservedMessageCounts: [UUID: Int] = [:]
    @State private var timelineObservedLatestMessageIDs: [UUID: UUID] = [:]
    @State private var pendingOwnSendTexts: [UUID: String] = [:]
    @State private var pendingEarlierAnchorID: UUID?
    @State private var didScheduleInitialComposerFocus = false
    @FocusState private var composerFocused: Bool

    private var theme: HarvisTheme { runtime.theme }
    private var selectedGroupID: UUID? {
        composerState.isReady ? composerState.selectedGroupID : (fallbackSelectedGroupID ?? coordinator.groups.first?.id)
    }
    private var currentDraft: HarvisGroupComposerDraft {
        guard let selectedGroupID else { return HarvisGroupComposerDraft() }
        return composerState.draft(for: selectedGroupID)
    }
    private var draft: String { currentDraft.text }
    private var recipientMode: HarvisGroupRecipientMode { currentDraft.recipientMode }
    private var currentGroup: HarvisGroupConversation? {
        coordinator.groups.first { $0.id == selectedGroupID }
    }

    var body: some View {
        VStack(spacing: 0) {
            windowToolbar
            Rectangle().fill(theme.line).frame(height: 1)

            if !coordinator.isReady {
                loadingState
            } else if coordinator.groups.isEmpty {
                noGroupsState
            } else if let group = currentGroup {
                groupWorkspace(group)
            } else {
                loadingState
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(theme.background)
        .foregroundColor(theme.text)
        .tint(theme.accent)
        .preferredColorScheme(theme.preferredColorScheme)
        .onAppear {
            refreshDeliveryStatus()
            selectInitialGroupIfNeeded()
            focusComposerWhenReady()
        }
        .onDisappear { Task { _ = await composerState.flush() } }
        .onReceive(coordinator.delivery.$isReady.removeDuplicates()) { ready in
            observedDeliveryReady = ready
        }
        .onReceive(coordinator.delivery.$lastError.removeDuplicates()) { error in
            observedDeliveryError = error
        }
        .onReceive(composerState.$isReady.removeDuplicates()) { ready in
            if ready {
                selectInitialGroupIfNeeded()
                focusComposerWhenReady()
            }
        }
        .onChange(of: coordinator.groups.map(\.id)) { _ in
            selectInitialGroupIfNeeded()
            focusComposerWhenReady()
        }
        .onChange(of: selectedGroupID) { newGroupID in
            visibleMessageCount = 100
            timelineIsFollowingLatest = true
            newTimelineMessageCount = 0
            pendingEarlierAnchorID = nil
            if let newGroupID {
                pendingOwnSendTexts = pendingOwnSendTexts.filter { $0.key == newGroupID }
            } else {
                pendingOwnSendTexts.removeAll()
            }
            if let id = newGroupID, let group = coordinator.group(id) {
                timelineObservedMessageCounts[id] = group.messages.count
                timelineObservedLatestMessageIDs[id] = group.messages.last?.id
            }
        }
        .onChange(of: sheetRoute?.id) { routeID in
            if routeID == nil { focusComposerWhenReady() }
        }
        .sheet(item: $sheetRoute) { route in
            sheetContent(for: route)
                .environment(\.harvisTextSize, HarvisTextSize.defaultValue)
        }
        .accessibilityIdentifier("harvis.group-chat.window")
    }

    private var windowToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .harvisFont(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("成员群聊").harvisFont(.headline)
                Text(coordinator.isReady ? "共享项目 · 按成员隔离原生会话" : (activationError == nil ? "正在恢复群聊数据…" : "群聊恢复失败"))
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }
            Spacer(minLength: 12)
            if coordinator.isReady {
                Button {
                    sheetRoute = .createGroup
                } label: {
                    Label("新建群聊", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("harvis.group-chat.create")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(theme.surface)
    }

    private var activationError: String? { coordinator.lastError ?? observedDeliveryError }

    private func refreshDeliveryStatus() {
        observedDeliveryReady = coordinator.delivery.isReady
        observedDeliveryError = coordinator.delivery.lastError
    }

    private func focusComposerWhenReady() {
        guard !didScheduleInitialComposerFocus,
              composerState.isReady,
              coordinator.isReady,
              currentGroup != nil,
              sheetRoute == nil else { return }
        didScheduleInitialComposerFocus = true
        DispatchQueue.main.async {
            guard sheetRoute == nil, currentGroup != nil else {
                didScheduleInitialComposerFocus = false
                return
            }
            composerFocused = true
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            if let activationError {
                Image(systemName: "exclamationmark.triangle")
                    .harvisFont(.system(size: 25))
                    .foregroundColor(theme.accent2)
                    .accessibilityHidden(true)
                Text("群聊数据没有恢复").harvisFont(.headline)
                Text(activationError)
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                Button {
                    retryActivation()
                } label: {
                    if isRetryingActivation { ProgressView().controlSize(.small) }
                    else { Label("重试", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRetryingActivation)
            } else {
                ProgressView().controlSize(.small)
                Text("正在恢复群聊…").harvisFont(.subheadline).foregroundColor(theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func retryActivation() {
        guard !isRetryingActivation else { return }
        isRetryingActivation = true
        Task {
            await runtime.activateGroupChat()
            isRetryingActivation = false
        }
    }

    private func retryComposerPersistence() {
        guard !isRetryingComposerPersistence else { return }
        isRetryingComposerPersistence = true
        Task {
            await composerState.activate()
            _ = await composerState.flush()
            isRetryingComposerPersistence = false
        }
    }

    private var noGroupsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .harvisFont(.system(size: 30))
                .foregroundColor(theme.accent)
                .accessibilityHidden(true)
            Text("还没有群聊").harvisFont(.title3.weight(.semibold))
            Text("先选一个共享项目，再添加不同账号下的 Codex 成员。")
                .harvisFont(.body)
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            Button {
                sheetRoute = .createGroup
            } label: {
                Label("创建第一个群聊", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            .accessibilityIdentifier("harvis.group-chat.empty-create")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func groupWorkspace(_ group: HarvisGroupConversation) -> some View {
        HStack(spacing: 0) {
            groupSidebar
            Rectangle().fill(theme.line).frame(width: 1)
            VStack(spacing: 0) {
                groupHeader(group)
                Rectangle().fill(theme.line).frame(height: 1)
                memberSection(group)
                orchestrationRunPanel(group)
                Rectangle().fill(theme.line).frame(height: 1)
                timeline(group)
                    .id(group.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                composer(group)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var groupSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("群聊").harvisFont(.subheadline.weight(.semibold))
                Text("\(coordinator.groups.count)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                Spacer()
                Button {
                    sheetRoute = .createGroup
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("新建群聊")
                .accessibilityLabel("新建群聊")
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(coordinator.groups) { group in
                        groupRow(group)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 224)
        .frame(maxHeight: .infinity)
        .background(theme.surfaceAlt.opacity(theme.usesFlatSurfaces ? 0.72 : 0.54))
    }

    private func groupRow(_ group: HarvisGroupConversation) -> some View {
        let isSelected = group.id == selectedGroupID
        let preview = group.messages.last.map {
            HarvisGroupMessagePresentation.displayText(for: $0, in: group)
        } ?? "添加成员并开始讨论"
        return Button {
            if composerState.isReady { composerState.selectGroup(group.id) }
            else { fallbackSelectedGroupID = group.id }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .harvisFont(.caption)
                        .foregroundColor(isSelected ? theme.accent : theme.muted)
                    Text(group.title)
                        .harvisFont(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(group.members.count)")
                        .harvisFont(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Text(preview)
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                Text(URL(fileURLWithPath: group.projectPath).lastPathComponent)
                    .harvisFont(.caption2.monospaced())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? theme.surface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).stroke(theme.line, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title)，\(group.members.count) 位成员")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("harvis.group-chat.group.\(group.id.uuidString)")
    }

    private func groupHeader(_ group: HarvisGroupConversation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .harvisFont(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(group.projectPath)
                    .harvisFont(.caption2.monospaced())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(group.projectPath)
            }
            Spacer(minLength: 6)
            Menu {
                Button {
                    copyToPasteboard(runtime.groupAgentServiceInstallationText(group: group))
                    copiedAgentEntryGroupID = group.id
                } label: {
                    Label(
                        copiedAgentEntryGroupID == group.id ? "已复制接入入口" : "复制接入入口",
                        systemImage: copiedAgentEntryGroupID == group.id ? "checkmark" : "doc.on.doc"
                    )
                }
                Button {
                    sheetRoute = .memory(group.id)
                } label: {
                    Label("查看协作记忆", systemImage: "brain.head.profile")
                }
                Button {
                    sheetRoute = .mcpConfiguration(group.id)
                } label: {
                    Label("接入智能体服务…", systemImage: "doc.text.magnifyingglass")
                }
            } label: {
                Label("协作", systemImage: "brain.head.profile")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("协作记忆与后台接入配置")

            VStack(alignment: .trailing, spacing: 2) {
                Toggle("后台接入", isOn: backgroundEnabledBinding(for: group))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(pendingBackgroundValues[group.id] != nil)
                    .help("开启后，其他本机智能体可调用本群；关闭窗口后，已开始的协作任务仍继续，退出 HarvisBar 后后台接入不可用。关闭后台接入不会停止已开始的协作任务；请用“停止”取消。")
                Text(runtime.groupControlServiceStatus)
                    .harvisFont(.caption2)
                    .foregroundColor(runtime.groupControlServiceStatus.localizedCaseInsensitiveContains("失败")
                        || runtime.groupControlServiceStatus.localizedCaseInsensitiveContains("错误") ? .red : theme.muted)
                    .lineLimit(1)
                    .help(runtime.groupControlServiceStatus)
            }

            Button {
                sheetRoute = .addMember(group.id)
            } label: {
                Label("添加成员", systemImage: "person.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("harvis.group-chat.add-member")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.surface)
    }

    private func memberSection(_ group: HarvisGroupConversation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("成员").harvisFont(.caption.weight(.semibold))
                Text("\(group.members.count)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                Spacer()
                Text(group.projectPermission == .workspaceWrite ? "全员项目读写" : "全员只读")
                    .harvisFont(.caption2)
                    .foregroundColor(group.projectPermission == .workspaceWrite ? theme.accent : theme.muted)
                    .accessibilityLabel("当前全体成员项目权限：\(group.projectPermission == .workspaceWrite ? "项目读写" : "只读")")
                if group.members.isEmpty {
                    Text("首次指派成员时会创建原生会话")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                }
            }
            if group.members.isEmpty {
                Text("成员尚未加入。为每位成员设置唯一名字、职责和 Codex 账号。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .padding(.vertical, 5)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(group.members) { member in
                            HarvisGroupMemberRow(
                                member: member,
                                liveState: coordinator.liveState(groupID: group.id, memberID: member.id),
                                latestDispatch: latestDispatch(group: group, memberID: member.id),
                                workStatus: coordinator.memberWorkStatus(groupID: group.id, memberID: member.id),
                                homeLabel: homeLabel(for: member.binding?.homePath ?? member.homePath),
                                theme: theme,
                                isOwner: group.ownerMemberID == member.id,
                                isChangingOwner: settingOwnerGroupIDs.contains(group.id),
                                onEdit: { sheetRoute = .editMember(group.id, member.id) },
                                onSetOwner: { setOwner(groupID: group.id, memberID: member.id) },
                                onRemoveOwner: { setOwner(groupID: group.id, memberID: nil) },
                                onHistory: { sheetRoute = .history(group.id, member.id) },
                                onFork: { Task { await coordinator.forkMember(groupID: group.id, memberID: member.id) } },
                                onHandoff: { sheetRoute = .handoff(group.id, member.id) },
                                onStop: { Task { await coordinator.stop(groupID: group.id, memberID: member.id) } },
                                onRecover: { await coordinator.recover() },
                                onApproval: { decision, answers in
                                    await coordinator.resolveApproval(
                                        groupID: group.id,
                                        memberID: member.id,
                                        decision: decision,
                                        answers: answers
                                    )
                                }
                            )
                            if member.id != group.members.last?.id {
                                Rectangle().fill(theme.line.opacity(0.72)).frame(height: 1)
                            }
                        }
                    }
                }
                .frame(height: min(140, CGFloat(max(1, group.members.count)) * 56))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.background)
    }

    private func ownerMember(in group: HarvisGroupConversation) -> HarvisGroupMember? {
        guard let ownerID = group.ownerMemberID else { return nil }
        return group.members.first { $0.id == ownerID }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func setOwner(groupID: UUID, memberID: UUID?) {
        guard !settingOwnerGroupIDs.contains(groupID) else { return }
        settingOwnerGroupIDs.insert(groupID)
        groupSettingsErrors[groupID] = nil
        Task {
            let saved = await coordinator.setOwner(groupID: groupID, memberID: memberID)
            settingOwnerGroupIDs.remove(groupID)
            if saved {
                groupSettingsErrors[groupID] = nil
                if memberID != nil, composerState.isReady {
                    updateComposerDraft(groupID: groupID, recipientMode: .coordinated)
                }
            } else {
                groupSettingsErrors[groupID] = coordinator.lastError ?? "群主设置失败。"
            }
        }
    }

    private func projectPermissionBinding(for group: HarvisGroupConversation) -> Binding<HarvisGroupPermission> {
        Binding(
            get: { pendingProjectPermissions[group.id] ?? group.projectPermission },
            set: { permission in
                guard pendingProjectPermissions[group.id] == nil,
                      permission != group.projectPermission else { return }
                pendingProjectPermissions[group.id] = permission
                groupSettingsErrors[group.id] = nil
                Task {
                    let saved = await coordinator.setProjectPermission(groupID: group.id, permission: permission)
                    pendingProjectPermissions[group.id] = nil
                    groupSettingsErrors[group.id] = saved ? nil : (coordinator.lastError ?? "群组项目权限未更改。")
                }
            }
        )
    }

    private func backgroundEnabledBinding(for group: HarvisGroupConversation) -> Binding<Bool> {
        Binding(
            get: { pendingBackgroundValues[group.id] ?? group.backgroundEnabled },
            set: { enabled in
                guard pendingBackgroundValues[group.id] == nil,
                      enabled != group.backgroundEnabled else { return }
                pendingBackgroundValues[group.id] = enabled
                groupSettingsErrors[group.id] = nil
                Task {
                    let saved = await coordinator.setBackgroundEnabled(groupID: group.id, enabled: enabled)
                    pendingBackgroundValues[group.id] = nil
                    groupSettingsErrors[group.id] = saved ? nil : (coordinator.lastError ?? "后台接入设置未更改。")
                }
            }
        )
    }

    @ViewBuilder
    private func orchestrationRunPanel(_ group: HarvisGroupConversation) -> some View {
        if let run = group.runs.last(where: { !$0.state.isTerminal }) ?? group.runs.last {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Button {
                        expandedRunID = expandedRunID == run.id ? nil : run.id
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: runStateIcon(run.state))
                                .foregroundColor(runStateColor(run.state))
                            Text("协作 · \(runStateLabel(run.state))")
                                .harvisFont(.caption.weight(.semibold))
                            Text(run.summary.isEmpty ? runProgressSummary(run) : run.summary)
                                .harvisFont(.caption2)
                                .foregroundColor(theme.muted)
                                .lineLimit(1)
                            Image(systemName: expandedRunID == run.id ? "chevron.up" : "chevron.down")
                                .harvisFont(.caption2.weight(.semibold))
                                .foregroundColor(theme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("协作运行：\(runStateLabel(run.state))。\(expandedRunID == run.id ? "收起" : "展开")任务详情")

                    if run.state == .needsInput {
                        Button {
                            performRunAction(run, groupID: group.id, resume: true)
                        } label: {
                            if pendingRunIDs.contains(run.id) { ProgressView().controlSize(.mini) }
                            else { Label("继续", systemImage: "arrow.clockwise") }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(pendingRunIDs.contains(run.id))
                        .help("为本次协作增加8轮与24个任务预算后继续")
                    }
                    if !run.state.isTerminal {
                        Button(role: .destructive) {
                            performRunAction(run, groupID: group.id, resume: false)
                        } label: {
                            if pendingRunIDs.contains(run.id) { ProgressView().controlSize(.mini) }
                            else { Label("停止", systemImage: "stop.fill") }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(pendingRunIDs.contains(run.id))
                    }
                }

                if expandedRunID == run.id {
                    if run.steps.isEmpty {
                        Text(run.ownerDispatchState == .finished ? "群主已完成本轮协调。" : "群主正在整理任务安排…")
                            .harvisFont(.caption2)
                            .foregroundColor(theme.muted)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(run.steps) { step in
                                    runStepRow(step, group: group)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 96)
                    }
                    if run.state == .deliveryUnknown {
                        HStack(spacing: 6) {
                            Text("状态待核；不会自动重试，请检查群主原生历史。")
                                .harvisFont(.caption2)
                                .foregroundColor(theme.accent2)
                            if let owner = ownerMember(in: group), owner.binding != nil {
                                Button("查看群主历史") { sheetRoute = .history(group.id, owner.id) }
                                    .buttonStyle(.link)
                                    .controlSize(.mini)
                            }
                        }
                    }
                    if let error = runActionErrors[run.id] ?? run.lastError, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .harvisFont(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .help(error)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(theme.surfaceAlt.opacity(theme.usesFlatSurfaces ? 1 : 0.6))
            .accessibilityIdentifier("harvis.group-chat.run.\(run.id.uuidString)")
        }
    }

    private func runStepRow(_ step: HarvisGroupRunStep, group: HarvisGroupConversation) -> some View {
        let memberName = group.members.first(where: { $0.id == step.memberID })?.name ?? "已移除成员"
        let result = group.messages.last(where: { $0.memberID == step.memberID && $0.dispatchID == step.dispatchID })?.text
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("@\(memberName)").harvisFont(.caption2.weight(.semibold))
                Text(runStepStateLabel(step.state)).harvisFont(.caption2).foregroundColor(theme.muted)
                Text(step.task).harvisFont(.caption2).lineLimit(2)
            }
            if let result, !result.isEmpty {
                Text(result)
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func performRunAction(_ run: HarvisGroupRun, groupID: UUID, resume: Bool) {
        guard pendingRunIDs.insert(run.id).inserted else { return }
        runActionErrors[run.id] = nil
        Task {
            let succeeded: Bool
            if resume {
                succeeded = await coordinator.resumeRun(groupID: groupID, runID: run.id)
            } else {
                succeeded = await coordinator.cancelRun(groupID: groupID, runID: run.id)
            }
            pendingRunIDs.remove(run.id)
            runActionErrors[run.id] = succeeded ? nil : (coordinator.lastError ?? (resume ? "协作未能继续。" : "协作未能停止。"))
        }
    }

    private func runProgressSummary(_ run: HarvisGroupRun) -> String {
        if !run.steps.isEmpty { return "\(run.steps.filter { $0.state == .finished }.count)/\(run.steps.count) 项任务完成" }
        if run.ownerRound > 0 { return "群主第 \(run.ownerRound) 轮协调" }
        return "群主正在安排任务"
    }

    private func runStateLabel(_ state: HarvisGroupRunState) -> String {
        switch state {
        case .planning: return "规划中"
        case .working: return "执行中"
        case .reviewing: return "汇总中"
        case .completed: return "已完成"
        case .needsInput: return "待继续"
        case .deliveryUnknown: return "状态待核"
        case .cancelled: return "已停止"
        case .failed: return "失败"
        }
    }

    private func runStateIcon(_ state: HarvisGroupRunState) -> String {
        switch state {
        case .planning: return "list.bullet.clipboard"
        case .working: return "arrow.triangle.2.circlepath"
        case .reviewing: return "checkmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .needsInput: return "pause.circle"
        case .deliveryUnknown: return "questionmark.circle"
        case .cancelled: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func runStateColor(_ state: HarvisGroupRunState) -> Color {
        switch state {
        case .planning, .working, .reviewing: return theme.accent
        case .completed: return theme.positive
        case .needsInput, .deliveryUnknown: return theme.accent2
        case .cancelled: return theme.muted
        case .failed: return .red
        }
    }

    private func runStepStateLabel(_ state: HarvisGroupStepState) -> String {
        switch state {
        case .planned: return "待派发"
        case .enqueueStarted: return "正在提交"
        case .submitted: return "执行中"
        case .finished: return "已完成"
        case .deliveryUnknown: return "状态待核"
        case .cancelled: return "已停止"
        }
    }

    private func timeline(_ group: HarvisGroupConversation) -> some View {
        let visibleMessages = Array(group.messages.suffix(visibleMessageCount))
        let bottomAnchorID = "harvis.group-chat.timeline.bottom.\(group.id.uuidString)"
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 0) {
                        HarvisGroupTimelineScrollObserver { isAtBottom in
                            if timelineIsFollowingLatest != isAtBottom {
                                timelineIsFollowingLatest = isAtBottom
                            }
                            if isAtBottom, newTimelineMessageCount > 0 {
                                newTimelineMessageCount = 0
                            }
                        }
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)

                        LazyVStack(alignment: .leading, spacing: 12) {
                            if group.messages.count > visibleMessages.count {
                                Button("加载更早的群聊记录（\(group.messages.count - visibleMessages.count) 条）") {
                                    pendingEarlierAnchorID = visibleMessages.first?.id
                                    timelineIsFollowingLatest = false
                                    visibleMessageCount += 100
                                }
                                .buttonStyle(.plain)
                                .harvisFont(.caption)
                                .foregroundColor(theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                            }

                            if group.messages.isEmpty {
                                VStack(spacing: 6) {
                                    Text("这里是共享群时间线")
                                        .harvisFont(.subheadline.weight(.semibold))
                                    Text("发送消息默认唤醒全体成员；写出成员名字可定向指派，也可选择仅记录。")
                                        .harvisFont(.caption)
                                        .foregroundColor(theme.muted)
                                }
                                .frame(maxWidth: .infinity, minHeight: 120)
                            } else {
                                ForEach(visibleMessages) { message in
                                    HarvisGroupMessageRow(
                                        message: message,
                                        group: group,
                                        homeLabel: message.source.map { homeLabel(for: $0.homePath) },
                                        theme: theme
                                    )
                                    .id(message.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
                if !timelineIsFollowingLatest {
                    Button {
                        newTimelineMessageCount = 0
                        timelineIsFollowingLatest = true
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    } label: {
                        Label(
                            newTimelineMessageCount > 0 ? "\(newTimelineMessageCount) 条新消息 · 返回最新" : "返回最新",
                            systemImage: "arrow.down.to.line"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(12)
                    .accessibilityIdentifier("harvis.group-chat.return-latest")
                }
            }
            .onAppear {
                timelineIsFollowingLatest = true
                newTimelineMessageCount = 0
                timelineObservedMessageCounts[group.id] = group.messages.count
                timelineObservedLatestMessageIDs[group.id] = group.messages.last?.id
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: visibleMessageCount) { _ in
                guard let anchorID = pendingEarlierAnchorID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(anchorID, anchor: .top)
                    pendingEarlierAnchorID = nil
                }
            }
            .onReceive(coordinator.$groups) { groups in
                guard let updatedGroup = groups.first(where: { $0.id == group.id }) else { return }
                let latestID = updatedGroup.messages.last?.id
                let previousCount = timelineObservedMessageCounts[group.id] ?? max(0, updatedGroup.messages.count - 1)
                guard timelineObservedLatestMessageIDs[group.id] != latestID else {
                    timelineObservedMessageCounts[group.id] = updatedGroup.messages.count
                    return
                }
                timelineObservedLatestMessageIDs[group.id] = latestID
                timelineObservedMessageCounts[group.id] = updatedGroup.messages.count
                guard latestID != nil else { return }
                let newMessages = Array(updatedGroup.messages.dropFirst(min(previousCount, updatedGroup.messages.count)))
                guard !newMessages.isEmpty else { return }

                if let pendingText = pendingOwnSendTexts[group.id],
                   newMessages.contains(where: { $0.memberID == nil && $0.speaker == "你" && $0.text == pendingText }) {
                    pendingOwnSendTexts[group.id] = nil
                    timelineIsFollowingLatest = true
                    newTimelineMessageCount = 0
                    DispatchQueue.main.async {
                        guard selectedGroupID == group.id, timelineIsFollowingLatest else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                } else if timelineIsFollowingLatest {
                    newTimelineMessageCount = 0
                    DispatchQueue.main.async {
                        guard selectedGroupID == group.id, timelineIsFollowingLatest else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                } else {
                    newTimelineMessageCount += newMessages.count
                }
            }
        }
        .accessibilityIdentifier("harvis.group-chat.timeline")
    }

    private func composer(_ group: HarvisGroupConversation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Menu {
                    if group.members.isEmpty {
                        Text("请先添加群成员")
                    } else {
                        Button {
                            setRecipientMode(.allMembers, groupID: group.id)
                        } label: {
                            Label("全体成员", systemImage: recipientMode == .allMembers ? "checkmark" : "person.3")
                        }

                        Section("指定成员") {
                            ForEach(group.members) { member in
                                Toggle(isOn: specificRecipientBinding(for: member.id, groupID: group.id)) {
                                    Text("@\(member.name) · \(member.role)")
                                }
                            }
                        }

                        Divider()
                        if let owner = ownerMember(in: group) {
                            Button {
                                setRecipientMode(.coordinated, groupID: group.id)
                            } label: {
                                Label(
                                    "由群主分配（@\(owner.name)）",
                                    systemImage: recipientMode == .coordinated ? "checkmark" : "crown"
                                )
                            }
                        } else {
                            Text("由群主分配：请先在成员菜单中设置群主")
                                .foregroundColor(theme.muted)
                        }

                        Divider()
                        Button {
                            setRecipientMode(.recordOnly, groupID: group.id)
                        } label: {
                            Label("仅记录，不唤醒", systemImage: recipientMode == .recordOnly ? "checkmark" : "text.alignleft")
                        }
                    }
                } label: {
                    Label(recipientSummary(group), systemImage: "at")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("选择消息接收成员")
                .accessibilityHint("选择全体成员、指定成员、交给群主安排或仅记录。直接指派时，正文出现成员名字会定向到这些成员，无需输入 @；仅记录不会唤醒成员。")
                .help("选择全体成员、指定成员、交给群主安排或仅记录。直接指派时，正文出现成员名字会定向到这些成员，无需输入 @；仅记录不会唤醒成员。")
                .disabled(!composerState.isReady)

                Picker("全员权限", selection: projectPermissionBinding(for: group)) {
                    Text("全员只读").tag(HarvisGroupPermission.discussion)
                    Text("全员项目读写").tag(HarvisGroupPermission.workspaceWrite)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("全体成员共享项目权限")
                .help("此设置持续作用于本群所有成员，但只限上方共享项目目录；需要批准的操作仍由你确认。先完成运行中的任务再切换权限。")
                .disabled(!composerState.isReady || pendingProjectPermissions[group.id] != nil)

                Spacer(minLength: 4)
                if !observedDeliveryReady {
                    Text(observedDeliveryError.map { "Codex 队列未就绪：\($0)" } ?? "Codex 队列尚未就绪")
                        .harvisFont(.caption2)
                        .foregroundColor(observedDeliveryError == nil ? theme.muted : .red)
                        .lineLimit(1)
                        .help(observedDeliveryError ?? "Codex 任务队列尚未就绪")
                }
            }

            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("输入群聊内容，写出成员名字即可指派…")
                        .harvisFont(.body)
                        .foregroundColor(theme.muted.opacity(0.9))
                        .padding(.leading, 6)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: textBinding(for: group.id))
                    .harvisFont(.body)
                    .focused($composerFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 62, maxHeight: 100)
                    .disabled(!composerState.isReady)
                    .accessibilityLabel("群聊消息")
                    .accessibilityIdentifier("harvis.group-chat.composer")
            }
            .padding(5)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line, lineWidth: 1))

            if let submitError = submitErrors[group.id] {
                Label(submitError, systemImage: "exclamationmark.triangle")
                    .harvisFont(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            if let settingsError = groupSettingsErrors[group.id] {
                Label(settingsError, systemImage: "exclamationmark.triangle")
                    .harvisFont(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let stateError = composerState.lastError {
                HStack(alignment: .center, spacing: 8) {
                    Label("草稿状态需要处理：\(stateError)", systemImage: "exclamationmark.triangle")
                        .harvisFont(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        retryComposerPersistence()
                    } label: {
                        if isRetryingComposerPersistence {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("正在重试保存草稿")
                        } else {
                            Label("重试保存", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRetryingComposerPersistence)
                    .accessibilityIdentifier("harvis.group-chat.retry-draft-save")
                }
            }

            HStack(spacing: 7) {
                Image(systemName: effectiveRecipients(group, draft: currentDraft).isEmpty ? "info.circle" : "paperplane")
                    .accessibilityHidden(true)
                Text(composerState.isReady ? composerHint(group) : (composerState.lastError.map { "草稿状态恢复失败：\($0)" } ?? "正在恢复群聊草稿…"))
                    .harvisFont(.caption2)
                    .foregroundColor(composerState.isReady || composerState.lastError == nil ? theme.muted : .red)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    send(group)
                } label: {
                    if sendingGroupIDs.contains(group.id) {
                        ProgressView().controlSize(.small).accessibilityLabel("正在发送")
                    } else {
                        Label("发送", systemImage: "arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sendingGroupIDs.contains(group.id) || !composerState.isReady || !coordinator.isReady || !observedDeliveryReady)
                .accessibilityIdentifier("harvis.group-chat.send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(theme.surfaceAlt.opacity(theme.usesFlatSurfaces ? 1 : 0.64))
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private func specificRecipientBinding(for memberID: UUID, groupID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                guard case let .selected(memberIDs) = composerState.draft(for: groupID).recipientMode else { return false }
                return memberIDs.contains(memberID)
            },
            set: { selected in
                let currentMode = composerState.draft(for: groupID).recipientMode
                var memberIDs: Set<UUID>
                if case let .selected(current) = currentMode { memberIDs = current }
                else { memberIDs = [] }
                if selected { memberIDs.insert(memberID) }
                else { memberIDs.remove(memberID) }
                setRecipientMode(memberIDs.isEmpty ? .recordOnly : .selected(memberIDs), groupID: groupID)
            }
        )
    }

    private func setRecipientMode(_ mode: HarvisGroupRecipientMode, groupID: UUID) {
        updateComposerDraft(groupID: groupID, recipientMode: mode)
    }

    private func textBinding(for groupID: UUID) -> Binding<String> {
        Binding(
            get: { composerState.draft(for: groupID).text },
            set: { updateComposerDraft(groupID: groupID, text: $0) }
        )
    }

    private func updateComposerDraft(
        groupID: UUID,
        text: String? = nil,
        recipientMode: HarvisGroupRecipientMode? = nil
    ) {
        let current = composerState.draft(for: groupID)
        composerState.updateDraft(
            groupID: groupID,
            text: text ?? current.text,
            recipientMode: recipientMode ?? current.recipientMode,
            permission: current.permission
        )
    }

    private func explicitRecipients(_ group: HarvisGroupConversation) -> [UUID] {
        HarvisGroupMentions.resolve(draft, members: group.members)
    }

    private func recipientSummary(_ group: HarvisGroupConversation) -> String {
        if case .coordinated = recipientMode {
            return ownerMember(in: group).map { "群主分配 · @\($0.name)" } ?? "先设置群主"
        }
        if case .recordOnly = recipientMode { return "仅记录" }

        let mentions = explicitRecipients(group)
        if !mentions.isEmpty {
            return "指派给：" + memberNames(mentions, in: group).joined(separator: "、")
        }

        switch recipientMode {
        case .allMembers:
            return group.members.isEmpty ? "暂无成员" : "全体成员"
        case let .selected(memberIDs):
            let names = memberNames(Array(memberIDs), in: group)
            return names.isEmpty ? "仅记录" : names.joined(separator: "、")
        case .recordOnly:
            return "仅记录"
        case .coordinated:
            return ownerMember(in: group).map { "群主分配 · @\($0.name)" } ?? "先设置群主"
        }
    }

    private func effectiveRecipients(_ group: HarvisGroupConversation, draft: HarvisGroupComposerDraft) -> [UUID] {
        if case .recordOnly = draft.recipientMode { return [] }
        if case .coordinated = draft.recipientMode {
            return ownerMember(in: group).map { [$0.id] } ?? []
        }
        let typed = HarvisGroupMentions.resolve(draft.text, members: group.members)
        if !typed.isEmpty { return typed }

        switch draft.recipientMode {
        case .allMembers:
            return group.members.map(\.id)
        case let .selected(memberIDs):
            return group.members.map(\.id).filter { memberIDs.contains($0) }
        case .recordOnly:
            return []
        case .coordinated:
            return ownerMember(in: group).map { [$0.id] } ?? []
        }
    }

    private func memberNames(_ memberIDs: [UUID], in group: HarvisGroupConversation) -> [String] {
        group.members.filter { memberIDs.contains($0.id) }.map(\.name)
    }

    private func composerHint(_ group: HarvisGroupConversation) -> String {
        let recipients = effectiveRecipients(group, draft: currentDraft)
        let permissionLabel = group.projectPermission == .discussion ? "全体成员只读" : "全体成员可写入共享项目"
        if case .recordOnly = recipientMode {
            let mentionNote = explicitRecipients(group).isEmpty ? "" : "；提到名字也不执行"
            return "仅记录到群时间线\(mentionNote) · 不唤醒成员"
        }
        if case .coordinated = recipientMode {
            guard let owner = ownerMember(in: group) else {
                return "请先在成员菜单中设置群主；此消息不会广播。"
            }
            return "交给群主 @\(owner.name) 安排成员任务 · \(permissionLabel)"
        }
        if recipients.isEmpty { return "没有可唤醒成员；消息仅记录到群时间线。" }
        if !explicitRecipients(group).isEmpty {
            return "将唤醒 \(memberNames(recipients, in: group).joined(separator: "、")) · \(permissionLabel)"
        }
        if case .allMembers = recipientMode {
            return "将唤醒全体 \(recipients.count) 位成员 · \(permissionLabel)"
        }
        return "将唤醒 \(recipientSummary(group)) · \(permissionLabel)"
    }

    private func send(_ group: HarvisGroupConversation) {
        let initialDraft = composerState.draft(for: group.id)
        let originalDraft = initialDraft.text
        let text = initialDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard composerState.isReady,
              composerState.selectedGroupID == group.id,
              !text.isEmpty,
              !sendingGroupIDs.contains(group.id) else { return }
        let isRecordOnly: Bool
        if case .recordOnly = initialDraft.recipientMode { isRecordOnly = true } else { isRecordOnly = false }
        if case .coordinated = initialDraft.recipientMode, ownerMember(in: group) == nil {
            submitErrors[group.id] = "请先在成员操作菜单中设置群主；当前消息未发送，也不会广播。"
            return
        }
        let recipients = effectiveRecipients(group, draft: initialDraft)
        if !isRecordOnly, initialDraft.recipientMode != .coordinated, recipients.isEmpty {
            submitErrors[group.id] = "没有可唤醒的成员；请添加成员或选择仅记录。"
            return
        }
        let groupID = group.id
        let requestID = UUID().uuidString
        submitErrors[groupID] = nil
        sendingGroupIDs.insert(groupID)
        pendingOwnSendTexts[groupID] = text
        updateComposerDraft(groupID: groupID, text: "")
        Task {
            do {
                if case .coordinated = initialDraft.recipientMode {
                    _ = try await coordinator.submitCoordinated(groupID: groupID, text: text, requestID: requestID)
                } else if isRecordOnly {
                    let saved = await coordinator.send(
                        groupID: groupID,
                        text: text,
                        mentionedMemberIDs: [],
                        permission: .discussion,
                        resolveTextMentions: false
                    )
                    guard saved else {
                        throw HarvisGroupError.invalid(coordinator.lastError ?? "仅记录消息未能保存。")
                    }
                } else {
                    _ = try await coordinator.submitDirect(
                        groupID: groupID,
                        text: text,
                        memberIDs: recipients,
                        permission: group.projectPermission,
                        requestID: requestID
                    )
                }
                sendingGroupIDs.remove(groupID)
            } catch {
                pendingOwnSendTexts[groupID] = nil
                sendingGroupIDs.remove(groupID)
                let latestDraft = composerState.draft(for: groupID)
                if latestDraft.text.isEmpty {
                    composerState.updateDraft(
                        groupID: groupID,
                        text: originalDraft,
                        recipientMode: latestDraft.recipientMode,
                        permission: latestDraft.permission
                    )
                    if composerState.selectedGroupID == groupID, sheetRoute == nil {
                        composerFocused = true
                    }
                }
                submitErrors[groupID] = error.localizedDescription
            }
        }
    }

    private func latestDispatch(group: HarvisGroupConversation, memberID: UUID) -> HarvisGroupDispatch? {
        group.dispatches.last { $0.memberID == memberID }
    }

    private func homeLabel(for path: String) -> String {
        if let home = runtime.codexHomes.first(where: { CodexGroupAdapter.normalize($0.path) == CodexGroupAdapter.normalize(path) }) {
            return home.accountDisplayLabel
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func selectInitialGroupIfNeeded() {
        guard coordinator.isReady else { return }
        guard composerState.isReady else {
            if let fallbackSelectedGroupID,
               coordinator.groups.contains(where: { $0.id == fallbackSelectedGroupID }) { return }
            fallbackSelectedGroupID = coordinator.groups.first?.id
            return
        }
        fallbackSelectedGroupID = nil
        if coordinator.groups.isEmpty {
            composerState.selectGroup(nil)
            return
        }
        if let selectedGroupID, coordinator.groups.contains(where: { $0.id == selectedGroupID }) { return }
        composerState.selectGroup(coordinator.groups.first?.id)
    }

    @ViewBuilder
    private func sheetContent(for route: HarvisGroupSheetRoute) -> some View {
        switch route {
        case .createGroup:
            HarvisCreateGroupSheet(runtime: runtime) { title, path in
                guard let id = await coordinator.createGroup(title: title, projectPath: path) else { return false }
                if composerState.isReady { composerState.selectGroup(id) }
                else { fallbackSelectedGroupID = id }
                return true
            }
        case let .addMember(groupID):
            HarvisAddMemberSheet(
                runtime: runtime,
                group: coordinator.group(groupID),
                theme: theme
            ) { name, role, path in
                await coordinator.addMember(groupID: groupID, name: name, role: role, homePath: path) != nil
            }
        case let .editMember(groupID, memberID):
            if let group = coordinator.group(groupID),
               let member = group.members.first(where: { $0.id == memberID }) {
                HarvisEditMemberSheet(group: group, member: member, theme: theme) { name, role in
                    let saved = await coordinator.updateMember(groupID: groupID, memberID: memberID, name: name, role: role)
                    return (saved, coordinator.lastError)
                }
            } else {
                HarvisUnavailableGroupMemberSheet(theme: theme)
            }
        case let .history(groupID, memberID):
            HarvisGroupHistorySheet(
                coordinator: coordinator,
                groupID: groupID,
                member: coordinator.group(groupID)?.members.first { $0.id == memberID },
                theme: theme,
                homeLabel: { homeLabel(for: $0) }
            )
        case let .handoff(groupID, memberID):
            HarvisGroupHandoffSheet(
                runtime: runtime,
                coordinator: coordinator,
                groupID: groupID,
                member: coordinator.group(groupID)?.members.first { $0.id == memberID },
                theme: theme,
                onError: { message in submitErrors[groupID] = message }
            )
        case let .memory(groupID):
            if let group = coordinator.group(groupID) {
                HarvisGroupMemorySheet(
                    group: group,
                    owner: ownerMember(in: group),
                    theme: theme,
                    onHistory: { owner in sheetRoute = .history(groupID, owner.id) }
                )
            } else {
                HarvisUnavailableGroupMemberSheet(theme: theme)
            }
        case let .mcpConfiguration(groupID):
            if let group = coordinator.group(groupID) {
                HarvisGroupMCPConfigurationSheet(
                    group: group,
                    serviceStatus: runtime.groupControlServiceStatus,
                    socketPath: runtime.groupControlSocketPath,
                    configuration: runtime.groupMCPConfiguration,
                    installationText: runtime.groupAgentServiceInstallationText(group: group),
                    theme: theme,
                    onRetry: { runtime.retryGroupControlService() }
                )
            } else {
                HarvisUnavailableGroupMemberSheet(theme: theme)
            }
        }
    }
}

private enum HarvisGroupSheetRoute: Identifiable {
    case createGroup
    case addMember(UUID)
    case editMember(UUID, UUID)
    case history(UUID, UUID)
    case handoff(UUID, UUID)
    case memory(UUID)
    case mcpConfiguration(UUID)

    var id: String {
        switch self {
        case .createGroup: return "create"
        case let .addMember(id): return "add-\(id)"
        case let .editMember(groupID, memberID): return "edit-\(groupID)-\(memberID)"
        case let .history(groupID, memberID): return "history-\(groupID)-\(memberID)"
        case let .handoff(groupID, memberID): return "handoff-\(groupID)-\(memberID)"
        case let .memory(groupID): return "memory-\(groupID)"
        case let .mcpConfiguration(groupID): return "mcp-configuration-\(groupID)"
        }
    }
}

@MainActor
private struct HarvisGroupMemberRow: View {
    let member: HarvisGroupMember
    let liveState: CodexThreadLiveState?
    let latestDispatch: HarvisGroupDispatch?
    let workStatus: HarvisGroupMemberWorkStatus?
    let homeLabel: String
    let theme: HarvisTheme
    let isOwner: Bool
    let isChangingOwner: Bool
    let onEdit: () -> Void
    let onSetOwner: () -> Void
    let onRemoveOwner: () -> Void
    let onHistory: () -> Void
    let onFork: () -> Void
    let onHandoff: () -> Void
    let onStop: () -> Void
    let onRecover: () async -> Void
    let onApproval: (CodexApprovalDecision, [String: [String]]) async -> Void

    @State private var isRecovering = false
    @State private var approvalAnswers: [String: String] = [:]
    @State private var selectedOptions: [String: String] = [:]
    @State private var approvalValidationError: String?
    @State private var isResolvingApproval = false

    private var approval: CodexPendingApproval? { liveState?.pendingApproval }
    private var canStop: Bool {
        guard let state = latestDispatch?.state else { return liveState?.activeTurnID != nil }
        return liveState?.activeTurnID != nil || [.queued, .waiting, .dispatching, .running, .waitingApproval].contains(state)
    }
    private var status: (String, Color) {
        let state = workStatus?.state ?? .idle
        let label = workStatus?.state.label ?? HarvisGroupMemberWorkState.idle.label
        switch state {
        case .idle: return (label, theme.muted)
        case .queued: return (label, theme.accent)
        case .running: return (label, theme.positive)
        case .awaitingApproval: return (label, theme.accent2)
        case .blocked: return (label, theme.accent2)
        case .completed: return (label, theme.positive)
        case .failed: return (label, .red)
        case .cancelled: return (label, theme.muted)
        }
    }

    private var statusDetail: String {
        let task = workStatus?.currentTask?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch workStatus?.state ?? .idle {
        case .idle:
            return "待指派"
        case .queued:
            if let task, !task.isEmpty { return "待执行：\(task)" }
            return "等待任务执行"
        case .running:
            if let task, !task.isEmpty { return "当前任务：\(task)" }
            return "正在执行任务"
        case .awaitingApproval:
            if let task, !task.isEmpty { return "待审批：\(task)" }
            return "等待你的审批"
        case .blocked:
            if let task, !task.isEmpty { return "等待处理：\(task)" }
            return "等待前置任务"
        case .completed:
            let count = workStatus?.completedTaskCount ?? 0
            if count > 0 { return "已完成 \(count) 项交付" }
            return "交付已完成"
        case .failed:
            if let task, !task.isEmpty { return "失败任务：\(task)" }
            return "任务执行失败"
        case .cancelled:
            return "任务已停止"
        }
    }

    private var statusCountSummary: String? {
        let queued = workStatus?.queuedTaskCount ?? 0
        let completed = workStatus?.completedTaskCount ?? 0
        let parts = [
            queued > 0 ? "待处理 \(queued) 项" : nil,
            completed > 0 ? "已交付 \(completed) 项" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.14)).frame(width: 23, height: 23)
                    Text(String(member.name.prefix(1)))
                        .harvisFont(.caption.weight(.semibold))
                        .foregroundColor(theme.accent)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("@\(member.name)").harvisFont(.caption.weight(.semibold)).lineLimit(1)
                        if isOwner {
                            Label("群主", systemImage: "crown.fill")
                                .harvisFont(.caption2.weight(.semibold))
                                .foregroundColor(theme.accent)
                                .labelStyle(.titleAndIcon)
                                .accessibilityLabel("群主")
                        }
                        Spacer(minLength: 2)
                        HStack(spacing: 4) {
                            Circle().fill(status.1).frame(width: 6, height: 6)
                            Text(status.0).harvisFont(.caption2.weight(.semibold)).lineLimit(1)
                        }
                        .foregroundColor(status.1)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("@\(member.name)，状态：\(status.0)")
                    }
                    Text("职责 · \(member.role)")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                        .help(member.role)
                    HStack(spacing: 5) {
                        Text(statusDetail)
                            .harvisFont(.caption2)
                            .foregroundColor(theme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(statusDetail)
                        if let statusCountSummary {
                            Text("· \(statusCountSummary)")
                                .harvisFont(.caption2)
                                .foregroundColor(theme.muted)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(minWidth: 115, maxWidth: 260, alignment: .leading)

                Spacer(minLength: 4)

                Button(action: onHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(member.binding == nil)
                .help("查看此成员的原生历史")
                .accessibilityLabel("查看 @\(member.name) 的原生历史")

                if latestDispatch?.state == .deliveryUnknown {
                    Button {
                        guard !isRecovering else { return }
                        isRecovering = true
                        Task {
                            await onRecover()
                            isRecovering = false
                        }
                    } label: {
                        if isRecovering { ProgressView().controlSize(.mini) }
                        else { Label("核对", systemImage: "arrow.clockwise") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isRecovering)
                    .help("核对执行状态")
                    .accessibilityLabel("核对 @\(member.name) 的执行状态")
                }

                Menu {
                    Button(action: onEdit) {
                        Label("编辑名字与职责…", systemImage: "pencil")
                    }
                    if isOwner {
                        Button(action: onRemoveOwner) {
                            Label("移除群主身份", systemImage: "person.crop.circle.badge.minus")
                        }
                        .disabled(isChangingOwner)
                    } else {
                        Button(action: onSetOwner) {
                            Label("设为群主", systemImage: "crown")
                        }
                        .disabled(isChangingOwner)
                    }
                    Divider()
                    Button(action: onHistory) {
                        Label("查看原生历史", systemImage: "clock.arrow.circlepath")
                    }
                        .disabled(member.binding == nil)
                    Button(action: onFork) {
                        Label("分叉原生会话", systemImage: "arrow.triangle.branch")
                    }
                        .disabled(member.binding == nil || canStop)
                    Divider()
                    Button(action: onHandoff) {
                        Label(member.binding == nil ? "绑定账号并新建会话…" : "换账号交接…", systemImage: "person.crop.circle.badge.arrow.right")
                    }
                    Section("接入详情") {
                        Button {} label: { Text("账号 · \(homeLabel)") }
                            .disabled(true)
                        if let binding = member.binding {
                            Button {} label: { Text("原生会话 · …\(binding.threadID.suffix(8))") }
                                .disabled(true)
                                .help("原生 thread ID：\(binding.threadID)")
                            if let model = binding.model, !model.isEmpty {
                                Button {} label: {
                                    Text("模型 · \(model) · 推理 \(binding.reasoningEffort ?? "默认")")
                                }
                                    .disabled(true)
                                    .help("原生配置：模型 \(model)，推理档位 \(binding.reasoningEffort ?? "默认")")
                            }
                        } else {
                            Button {} label: { Text("首次指派任务时会创建原生会话") }
                                .disabled(true)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("管理职责、交付状态与必要的接入选项")
                .accessibilityLabel("@\(member.name) 的职责与交付操作；状态：\(status.0)；\(statusDetail)")

                Button(action: onStop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!canStop)
                .help("只停止 @\(member.name) 的当前运行")
                .accessibilityLabel("停止 @\(member.name)")
            }

            if let dispatch = latestDispatch,
               [.failed, .deliveryUnknown].contains(dispatch.state),
               let error = dispatch.lastError, !error.isEmpty {
                Label(error, systemImage: dispatch.state == .deliveryUnknown ? "questionmark.circle" : "exclamationmark.triangle")
                    .harvisFont(.caption2)
                    .foregroundColor(dispatch.state == .deliveryUnknown ? theme.accent2 : .red)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityLabel("@\(member.name) 的错误：\(error)")
                    .padding(.leading, 30)
            }

            if let approval {
                approvalPanel(approval)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("harvis.group-chat.member.\(member.id.uuidString)")
        .onChange(of: approval?.id) { _ in
            approvalAnswers = [:]
            selectedOptions = [:]
            approvalValidationError = nil
        }
    }

    private func approvalPanel(_ approval: CodexPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill").accessibilityHidden(true)
                Text("@\(member.name) · 需要审批 · \(approval.title)").harvisFont(.caption.weight(.semibold))
            }
            .foregroundColor(theme.accent2)
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .harvisFont(.caption2.monospaced())
                    .foregroundColor(theme.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if approval.method == "item/tool/requestUserInput" {
                userInputControls(approval)
            } else if approval.method == "mcpServer/elicitation/request" {
                mcpCancellation
            } else if supportsGroupDecision(approval) {
                HStack(spacing: 6) {
                    if allows(.accept, approval: approval) {
                        Button("允许一次") { resolveApproval(.accept) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .disabled(isResolvingApproval)
                    }
                    if allows(.acceptForSession, approval: approval) {
                        Button("本会话允许") { resolveApproval(.acceptForSession) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(isResolvingApproval)
                    }
                    if allows(.decline, approval: approval) {
                        Button("拒绝", role: .destructive) { resolveApproval(.decline) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(isResolvingApproval)
                    }
                }
            } else {
                Text("此类请求无法在群聊面板中处理；请求绑定到当前群聊连接，其他 Codex 窗口无法回复。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if allows(.decline, approval: approval) {
                    Button("拒绝此请求", role: .destructive) { resolveApproval(.decline) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isResolvingApproval)
                }
                if allows(.cancel, approval: approval) {
                    Button("取消此请求", role: .destructive) { resolveApproval(.cancel) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isResolvingApproval)
                }
            }
            if let approvalValidationError {
                Label(approvalValidationError, systemImage: "exclamationmark.circle")
                    .harvisFont(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent2.opacity(theme.isDark ? 0.12 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line, lineWidth: 1))
        .accessibilityIdentifier("harvis.group-chat.approval.\(member.id.uuidString)")
    }

    private func userInputControls(_ approval: CodexPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("此请求由群聊连接持有，请在这里填写并提交回答。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if approval.questions.isEmpty {
                Text("请求没有可显示的问题，无法提交回答。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            } else {
                ForEach(approval.questions) { question in
                    VStack(alignment: .leading, spacing: 5) {
                        if let header = question.header, !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(header)
                                .harvisFont(.caption2.weight(.semibold))
                                .foregroundColor(theme.accent)
                        }
                        Text(question.question)
                            .harvisFont(.caption.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)

                        if question.options.isEmpty {
                            Group {
                                if question.isSecret {
                                    SecureField("输入保密回答", text: answerBinding(for: question.id))
                                } else {
                                    TextField("输入回答", text: answerBinding(for: question.id))
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                        } else {
                            ForEach(question.options) { option in
                                Button {
                                    selectedOptions[question.id] = option.label
                                    approvalAnswers[question.id] = ""
                                } label: {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: selectedOptions[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                                            .foregroundColor(theme.accent)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(option.label).harvisFont(.caption)
                                            if let description = option.description,
                                               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                                .accessibilityAddTraits(selectedOptions[question.id] == option.label ? .isSelected : [])
                            }

                            if question.isOther {
                                Group {
                                    if question.isSecret {
                                        SecureField("或输入保密自定义回答", text: answerBinding(for: question.id))
                                    } else {
                                        TextField("或输入自定义回答", text: answerBinding(for: question.id))
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
                    .padding(.top, 2)
                }
            }

            HStack(spacing: 6) {
                Button("提交回答") { submitAnswers(approval) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(isResolvingApproval || approval.questions.isEmpty)
                Button("拒绝", role: .destructive) { resolveApproval(.decline) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isResolvingApproval)
                Button("取消", role: .destructive) { resolveApproval(.cancel) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isResolvingApproval)
            }
        }
    }

    private var mcpCancellation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("这是由当前群聊连接持有的 MCP 请求，其他 Codex 窗口无法处理。你可以在这里取消此请求。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("取消此 MCP 请求", role: .destructive) { resolveApproval(.cancel) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isResolvingApproval)
        }
    }

    private func answerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { approvalAnswers[questionID, default: ""] },
            set: { approvalAnswers[questionID] = $0 }
        )
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
        resolveApproval(.accept, answers: answers)
    }

    private func resolveApproval(_ decision: CodexApprovalDecision, answers: [String: [String]] = [:]) {
        guard !isResolvingApproval else { return }
        isResolvingApproval = true
        Task {
            await onApproval(decision, answers)
            isResolvingApproval = false
        }
    }

    private func allows(_ decision: CodexApprovalDecisionOption, approval: CodexPendingApproval) -> Bool {
        approval.availableDecisions?.contains(decision) ?? true
    }

    private func supportsGroupDecision(_ approval: CodexPendingApproval) -> Bool {
        [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
        ].contains(approval.method)
    }
}

@MainActor
private enum HarvisGroupMessagePresentation {
    static func ownerDecision(
        for message: HarvisGroupMessage,
        in group: HarvisGroupConversation
    ) -> HarvisGroupOwnerDecision? {
        guard let dispatchID = message.dispatchID,
              let dispatch = group.dispatches.first(where: { $0.id == dispatchID }),
              dispatch.memberID == message.memberID else { return nil }

        let turnKey = HarvisGroupCoordinator.ownerTurnKey(dispatch)
        let isOwnerDecision = group.runs.contains { run in
            guard run.ownerMemberID == dispatch.memberID else { return false }
            if run.ownerDispatchID == dispatch.id { return true }
            guard let turnKey else { return false }
            return run.processedOwnerTurns.contains(turnKey)
        }
        guard isOwnerDecision,
              let data = message.text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HarvisGroupOwnerDecision.self, from: data)
    }

    static func displayText(for message: HarvisGroupMessage, in group: HarvisGroupConversation) -> String {
        guard let decision = ownerDecision(for: message, in: group) else { return message.text }
        let assignments = decision.assignments.map { assignment in
            let name = group.members.first(where: { $0.id == assignment.memberID })?.name ?? "已移除成员"
            return "@\(name)：\(assignment.task)"
        }
        return ([decision.summary] + assignments).joined(separator: "；")
    }
}

@MainActor
private struct HarvisGroupMessageRow: View {
    let message: HarvisGroupMessage
    let group: HarvisGroupConversation
    let homeLabel: String?
    let theme: HarvisTheme

    private var isUser: Bool { message.speaker == "你" }
    private var isSystem: Bool { message.speaker == "系统" }
    private var dispatches: [HarvisGroupDispatch] { group.dispatches.filter { $0.messageID == message.id } }

    private var ownerDecision: HarvisGroupOwnerDecision? {
        HarvisGroupMessagePresentation.ownerDecision(for: message, in: group)
    }

    private var metadata: String {
        if isUser {
            guard !dispatches.isEmpty else { return "仅记录 · 未唤醒成员" }
            let permission = dispatches.first?.permission == .workspaceWrite ? "项目写入" : "只读讨论"
            return "唤醒 \(dispatches.count) 位成员 · \(permission)"
        }
        if let homeLabel { return homeLabel }
        return isSystem ? "群聊记录" : "群成员"
    }

    var body: some View {
        let decision = ownerDecision
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 72) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(message.speaker).harvisFont(.caption.weight(.semibold))
                    Text(metadata).harvisFont(.caption2).foregroundColor(theme.muted)
                    Spacer(minLength: 4)
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .harvisFont(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                messageBody(decision)

                if isUser, !message.recipientMemberIDs.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.recipientMemberIDs, id: \.self) { id in
                            if let member = group.members.first(where: { $0.id == id }) {
                                Text("@\(member.name)")
                                    .harvisFont(.caption2.weight(.medium))
                                    .foregroundColor(theme.accent)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 650, alignment: .leading)
            .background(isUser ? theme.remoteSurface.opacity(theme.isDark ? 0.55 : 0.74) : (isSystem ? theme.surfaceAlt : theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            if !isUser { Spacer(minLength: 72) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.speaker)，\(metadata)：\(accessibleBody(decision))")
    }

    @ViewBuilder
    private func messageBody(_ decision: HarvisGroupOwnerDecision?) -> some View {
        if let decision {
            VStack(alignment: .leading, spacing: 8) {
                Text(decision.summary)
                    .harvisFont(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !decision.assignments.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("任务分派")
                            .harvisFont(.caption.weight(.semibold))
                            .foregroundColor(theme.muted)
                        ForEach(decision.assignments, id: \.id) { assignment in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("@\(group.members.first(where: { $0.id == assignment.memberID })?.name ?? "已移除成员")")
                                    .harvisFont(.caption2.weight(.semibold))
                                    .foregroundColor(theme.accent)
                                Text(assignment.task)
                                    .harvisFont(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(message.text)
                .harvisFont(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accessibleBody(_ decision: HarvisGroupOwnerDecision?) -> String {
        guard let decision else { return message.text }
        let assignments = decision.assignments.map { assignment in
            let name = group.members.first(where: { $0.id == assignment.memberID })?.name ?? "已移除成员"
            return "@\(name)：\(assignment.task)"
        }
        return ([decision.summary] + assignments).joined(separator: "；")
    }
}

@MainActor
private struct HarvisCreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let runtime: HarvisRuntimeModel
    let onCreate: (String, String) async -> Bool

    @State private var title = "新群聊"
    @State private var projectPath = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !projectPath.isEmpty && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建群聊").harvisFont(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("群聊名称").harvisFont(.caption.weight(.semibold))
                TextField("例如：增长项目评审", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .accessibilityIdentifier("harvis.group-chat.title")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("共享项目目录").harvisFont(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    Text(projectPath.isEmpty ? "请选择一个现有项目文件夹" : projectPath)
                        .harvisFont(.caption2.monospaced())
                        .foregroundColor(projectPath.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button("选择文件夹…", action: chooseProjectDirectory)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Text("所有成员共享此项目路径；每条消息仍需明确选择只读讨论或项目写入。")
                    .harvisFont(.caption2)
                    .foregroundColor(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .harvisFont(.caption)
                    .foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if isCreating { ProgressView().controlSize(.small) }
                    else { Text("创建群聊") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .accessibilityIdentifier("harvis.group-chat.confirm-create")
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { titleFocused = true }
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择共享项目目录"
        panel.prompt = "使用此目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !runtime.workspaceRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: runtime.workspaceRoot, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            errorMessage = nil
        }
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        Task {
            let created = await onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines), projectPath)
            isCreating = false
            if created { dismiss() }
            else { errorMessage = "群聊未创建。请确认项目目录存在且群聊存储可用。" }
        }
    }
}

@MainActor
private struct HarvisEditMemberSheet: View {
    @Environment(\.dismiss) private var dismiss

    let group: HarvisGroupConversation
    let member: HarvisGroupMember
    let theme: HarvisTheme
    let onSave: (String, String) async -> (Bool, String?)

    @State private var name: String
    @State private var role: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        group: HarvisGroupConversation,
        member: HarvisGroupMember,
        theme: HarvisTheme,
        onSave: @escaping (String, String) async -> (Bool, String?)
    ) {
        self.group = group
        self.member = member
        self.theme = theme
        self.onSave = onSave
        _name = State(initialValue: member.name)
        _role = State(initialValue: member.role)
    }

    private var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalizedRole: String { role.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicateName: Bool {
        group.members.contains { $0.id != member.id && $0.name == normalizedName }
    }
    private var nameValidationMessage: String? {
        if normalizedName.isEmpty { return "请输入成员名字。" }
        if normalizedName.contains("@") || normalizedName.contains(where: \.isWhitespace) {
            return "名字不能包含空白或 @。"
        }
        if duplicateName { return "群内已有同名成员，请换一个名字。" }
        return nil
    }
    private var roleValidationMessage: String? {
        normalizedRole.isEmpty ? "请输入职责。" : nil
    }
    private var hasChanges: Bool { normalizedName != member.name || normalizedRole != member.role }
    private var canSave: Bool {
        nameValidationMessage == nil && roleValidationMessage == nil && hasChanges && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("编辑成员").harvisFont(.title3.weight(.semibold))
            Text("修改名字或职责不会更换账号、原生会话或历史；后续指派会使用更新后的信息。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("成员名字").harvisFont(.caption.weight(.semibold))
                TextField("例如：reviewer", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)
                    .accessibilityLabel("成员名字")
                    .accessibilityHint(nameValidationMessage ?? "群内唯一，不能包含空白或 @；消息中直接写名字即可指派。")
                    .accessibilityIdentifier("harvis.group-chat.edit-member-name")
                if let nameValidationMessage {
                    Text(nameValidationMessage)
                        .harvisFont(.caption2)
                        .foregroundColor(.red)
                } else {
                    Text("群内名字须唯一；消息正文中直接写名字即可指派。")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("职责").harvisFont(.caption.weight(.semibold))
                TextField("例如：代码评审", text: $role)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)
                    .accessibilityLabel("职责")
                    .accessibilityHint("会在后续指派给该成员的消息上下文中使用。")
                    .accessibilityIdentifier("harvis.group-chat.edit-member-role")
                if let roleValidationMessage {
                    Text(roleValidationMessage)
                        .harvisFont(.caption2)
                        .foregroundColor(.red)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .harvisFont(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("harvis.group-chat.edit-member-error")
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text("保存") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("harvis.group-chat.save-member")
            }
        }
        .padding(20)
        .frame(width: 500)
        .onChange(of: name) { _ in errorMessage = nil }
        .onChange(of: role) { _ in errorMessage = nil }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            let (saved, detail) = await onSave(normalizedName, normalizedRole)
            isSaving = false
            if saved {
                dismiss()
            } else {
                let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = detail.flatMap { $0.isEmpty ? nil : $0 } ?? "保存失败，输入内容仍保留。请修正后重试，或取消返回。"
            }
        }
    }
}

@MainActor
private struct HarvisUnavailableGroupMemberSheet: View {
    @Environment(\.dismiss) private var dismiss
    let theme: HarvisTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("成员无法加载").harvisFont(.title3.weight(.semibold))
            Text("此群聊或成员已不存在，请关闭窗口后重试。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

@MainActor
private struct HarvisAddMemberSheet: View {
    @Environment(\.dismiss) private var dismiss
    let runtime: HarvisRuntimeModel
    let group: HarvisGroupConversation?
    let theme: HarvisTheme
    let onAdd: (String, String, String) async -> Bool

    @State private var name = ""
    @State private var role = "成员"
    @State private var homePath = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var homes: [CodexHome] { runtime.codexHomes.filter(\.isCodexAccountCandidate) }
    private var duplicateName: Bool { group?.members.contains(where: { $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) }) ?? false }
    private var validName: Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.contains("@") && !value.contains(where: \.isWhitespace) && !duplicateName
    }
    private var canAdd: Bool { validName && !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !homePath.isEmpty && !isAdding }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("添加群成员").harvisFont(.title3.weight(.semibold))
            Text("消息正文中直接写名字即可指派，无需 @。名字须在群内唯一；同一账号可加入多位成员。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
            VStack(alignment: .leading, spacing: 5) {
                Text("成员名字").harvisFont(.caption.weight(.semibold))
                TextField("例如：reviewer", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("harvis.group-chat.member-name")
                if duplicateName {
                    Text("这个群里已有同名成员，请换一个名称。")
                        .harvisFont(.caption2)
                        .foregroundColor(.red)
                } else if name.contains(where: \.isWhitespace) || name.contains("@") {
                    Text("名称不能包含空格或 @。")
                        .harvisFont(.caption2)
                        .foregroundColor(.red)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("职责").harvisFont(.caption.weight(.semibold))
                TextField("例如：代码评审", text: $role)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex 账号 / Home").harvisFont(.caption.weight(.semibold))
                if homes.isEmpty {
                    Text("没有可用的 Codex 账号。请先在主窗口添加或恢复账号。")
                        .harvisFont(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("账号", selection: $homePath) {
                        ForEach(homes) { home in
                            Text("\(home.accountDisplayLabel) · \(URL(fileURLWithPath: home.path).lastPathComponent)")
                                .tag(home.path)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("选择 Codex 账号")
                    if let selected = homes.first(where: { $0.path == homePath }) {
                        Text(selected.path).harvisFont(.caption2.monospaced()).foregroundColor(theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .harvisFont(.caption)
                    .foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    add()
                } label: {
                    if isAdding { ProgressView().controlSize(.small) }
                    else { Text("添加成员") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
                .accessibilityIdentifier("harvis.group-chat.confirm-add-member")
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            if homePath.isEmpty {
                homePath = homes.first(where: { $0.id == runtime.selectedCodexHomeID })?.path ?? homes.first?.path ?? ""
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        isAdding = true
        errorMessage = nil
        Task {
            let added = await onAdd(name.trimmingCharacters(in: .whitespacesAndNewlines), role.trimmingCharacters(in: .whitespacesAndNewlines), homePath)
            isAdding = false
            if added { dismiss() }
            else { errorMessage = "无法添加成员。请检查名称是否唯一，并确认账号 Home 可用。" }
        }
    }
}

@MainActor
private struct HarvisGroupHandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    let runtime: HarvisRuntimeModel
    let coordinator: HarvisGroupCoordinator
    let groupID: UUID
    let member: HarvisGroupMember?
    let theme: HarvisTheme
    let onError: (String?) -> Void

    @State private var targetHomePath = ""
    @State private var isHandingOff = false
    @State private var errorMessage: String?

    private var homes: [CodexHome] {
        let candidates = runtime.codexHomes.filter(\.isCodexAccountCandidate)
        guard let member, let binding = member.binding else { return candidates }
        return candidates.filter { CodexGroupAdapter.normalize($0.path) != CodexGroupAdapter.normalize(binding.homePath) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(member.map { "交接 @\($0.name) 的账号" } ?? "账号交接")
                .harvisFont(.title3.weight(.semibold))
            Text("交接会创建一个新的原生 Codex thread。下次指派该成员时会带上共享群记录；原账号中的私有原生历史不会迁移。")
                .harvisFont(.body)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let member, let binding = member.binding {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前账号").harvisFont(.caption.weight(.semibold))
                    Text(runtime.codexHomes.first(where: { CodexGroupAdapter.normalize($0.path) == CodexGroupAdapter.normalize(binding.homePath) })?.accountDisplayLabel ?? binding.homePath)
                        .harvisFont(.caption)
                    Text("thread …\(binding.threadID.suffix(8))").harvisFont(.caption2.monospaced()).foregroundColor(theme.muted)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("目标账号").harvisFont(.caption.weight(.semibold))
                if homes.isEmpty {
                    Text(member?.binding == nil ? "没有可用的 Codex 账号。" : "没有其他 Codex 账号可交接；请先添加另一个账号。")
                        .harvisFont(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("目标账号", selection: $targetHomePath) {
                        ForEach(homes) { home in
                            Text("\(home.accountDisplayLabel) · \(URL(fileURLWithPath: home.path).lastPathComponent)")
                                .tag(home.path)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("选择交接目标账号")
                    if let selected = homes.first(where: { $0.path == targetHomePath }) {
                        Text(selected.path).harvisFont(.caption2.monospaced()).foregroundColor(theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .harvisFont(.caption)
                    .foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    handoff()
                } label: {
                    if isHandingOff { ProgressView().controlSize(.small) }
                    else { Text("创建新会话并交接") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(member == nil || targetHomePath.isEmpty || isHandingOff)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { targetHomePath = homes.first?.path ?? "" }
    }

    private func handoff() {
        guard let member, !targetHomePath.isEmpty else { return }
        isHandingOff = true
        errorMessage = nil
        let oldThreadID = member.binding?.threadID
        Task {
            await coordinator.handoff(groupID: groupID, memberID: member.id, targetHomePath: targetHomePath)
            let updated = coordinator.group(groupID)?.members.first(where: { $0.id == member.id })?.binding
            let succeeded = updated?.homePath == CodexGroupAdapter.normalize(targetHomePath) && updated?.threadID != oldThreadID
            isHandingOff = false
            if succeeded {
                onError(nil)
                dismiss()
            } else {
                let detail = coordinator.lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message: String
                if let detail, !detail.isEmpty { message = "交接失败：\(detail)" }
                else { message = "交接没有完成。请确认目标账号已登录，且该成员没有未完成任务。" }
                errorMessage = message
                onError(message)
            }
        }
    }
}

@MainActor
private struct HarvisGroupHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: HarvisGroupCoordinator
    let groupID: UUID
    let member: HarvisGroupMember?
    let theme: HarvisTheme
    let homeLabel: (String) -> String

    @State private var turns: [HarvisNativeHistoryTurn] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.map { "@\($0.name) 的原生历史" } ?? "原生历史")
                        .harvisFont(.title3.weight(.semibold))
                    if let binding = member?.binding {
                        Text("\(homeLabel(binding.homePath)) · thread …\(binding.threadID.suffix(8))")
                            .harvisFont(.caption2.monospaced())
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Rectangle().fill(theme.line).frame(height: 1)
            if let errorMessage {
                VStack(alignment: .leading, spacing: 7) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .harvisFont(.caption)
                        .foregroundColor(.red)
                    Button("重试") { loadPage() }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.vertical, 8)
            } else if turns.isEmpty && isLoading {
                ProgressView("正在读取原生历史…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if turns.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: didLoad ? "doc.text" : "clock.arrow.circlepath")
                        .harvisFont(.system(size: 26)).foregroundColor(theme.muted).accessibilityHidden(true)
                    Text(didLoad ? "没有可显示的原生轮次" : "历史仅按需读取")
                        .harvisFont(.subheadline.weight(.semibold))
                    Text("此处只查看所选成员绑定账号中的原生 Codex 历史。")
                        .harvisFont(.caption).foregroundColor(theme.muted)
                    Button("读取原生历史") { loadPage() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(member?.binding == nil || isLoading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(turns) { turn in historyTurn(turn) }
                        if nextCursor != nil {
                            Button {
                                loadPage()
                            } label: {
                                if isLoading { ProgressView().controlSize(.small) }
                                else { Text("加载更早的原生历史") }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isLoading)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(16)
        .frame(width: 720, height: 560)
        .onAppear {
            if member?.binding != nil { loadPage() }
        }
        .accessibilityIdentifier("harvis.group-chat.native-history")
    }

    private func historyTurn(_ turn: HarvisNativeHistoryTurn) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(turn.statusLabel).harvisFont(.caption.weight(.semibold))
                Text(turn.id.suffix(10)).harvisFont(.caption2.monospaced()).foregroundColor(theme.muted)
                Spacer()
                if let timestamp = turn.timestamp { Text(timestamp).harvisFont(.caption2.monospacedDigit()).foregroundColor(theme.muted) }
            }
            ForEach(turn.entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.speaker).harvisFont(.caption2.weight(.semibold)).foregroundColor(theme.accent)
                    Text(entry.text).harvisFont(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(7)
                .background(theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            if turn.entries.isEmpty {
                DisclosureGroup("查看原生轮次数据") {
                    Text(turn.rawJSON)
                        .harvisFont(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)
                }
                .harvisFont(.caption)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 1))
    }

    private func loadPage() {
        guard !isLoading, member?.binding != nil else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let page = try await coordinator.readHistory(groupID: groupID, memberID: member!.id, cursor: nextCursor)
                let rawTurns = page["data"]?.arrayValue ?? []
                turns.append(contentsOf: rawTurns.map(HarvisNativeHistoryTurn.init(value:)))
                nextCursor = page["nextCursor"]?.stringValue
                didLoad = true
            } catch {
                errorMessage = "无法读取此成员的原生历史：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}

private struct HarvisNativeHistoryTurn: Identifiable {
    let id: String
    let statusLabel: String
    let timestamp: String?
    let entries: [HarvisNativeHistoryEntry]
    let rawJSON: String

    init(value: CodexJSONValue) {
        id = value["id"]?.stringValue ?? UUID().uuidString
        statusLabel = Self.label(for: value["status"]?.stringValue ?? "unknown")
        timestamp = value["createdAt"]?.stringValue
        entries = (value["items"]?.arrayValue ?? []).compactMap(HarvisNativeHistoryEntry.init(value:))
        rawJSON = value.encodedString() ?? ""
    }

    private static func label(for status: String) -> String {
        switch status {
        case "completed": return "已完成"
        case "inProgress", "running": return "进行中"
        case "failed": return "失败"
        case "interrupted": return "已中断"
        default: return status
        }
    }
}

private struct HarvisNativeHistoryEntry: Identifiable {
    let id = UUID()
    let speaker: String
    let text: String

    init?(value: CodexJSONValue) {
        let type = value["type"]?.stringValue ?? ""
        let label: String
        if type == "userMessage" { label = "用户" }
        else if type == "agentMessage" { label = "Codex" }
        else { label = type.isEmpty ? "内容" : type }

        var extracted = value["text"]?.stringValue
        if extracted == nil, let content = value["content"] {
            extracted = Self.text(in: content)
        }
        guard let extracted, !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        speaker = label
        text = extracted
    }

    private static func text(in value: CodexJSONValue) -> String? {
        switch value {
        case let .string(text): return text
        case let .array(values):
            return values.compactMap(text(in:)).joined(separator: "\n")
        case let .object(object):
            if let text = object["text"]?.stringValue { return text }
            if let value = object["value"], let text = text(in: value) { return text }
            return nil
        default: return nil
        }
    }
}

@MainActor
private struct HarvisGroupTimelineScrollObserver: NSViewRepresentable {
    let onAtBottomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAtBottomChange: onAtBottomChange)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onAtBottomChange = onAtBottomChange
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var onAtBottomChange: (Bool) -> Void
        private weak var scrollView: NSScrollView?
        private var scrollObservers: [NSObjectProtocol] = []
        private var hasUsedAttachmentRetry = false
        private var isDismantled = false

        init(onAtBottomChange: @escaping (Bool) -> Void) {
            self.onAtBottomChange = onAtBottomChange
        }

        func attach(to view: NSView) {
            guard !isDismantled else { return }
            guard let scrollView = view.enclosingScrollView else {
                guard !hasUsedAttachmentRetry else { return }
                hasUsedAttachmentRetry = true
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    guard !self.isDismantled else { return }
                    self.attach(to: view)
                }
                return
            }
            guard self.scrollView !== scrollView else { return }
            removeScrollObservers()
            self.scrollView = scrollView
            // Live-scroll events capture viewport intent; document growth alone cannot change follow state.
            for notification in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                scrollObservers.append(NotificationCenter.default.addObserver(
                    forName: notification,
                    object: scrollView,
                    queue: .main
                ) { [weak self, weak scrollView] _ in
                    MainActor.assumeIsolated {
                        guard let self, let scrollView, !self.isDismantled else { return }
                        self.publishScrollPosition(in: scrollView)
                    }
                })
            }
        }

        func detach() {
            isDismantled = true
            removeScrollObservers()
            scrollView = nil
        }

        private func removeScrollObservers() {
            for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
            scrollObservers.removeAll()
            scrollView = nil
        }

        private func publishScrollPosition(in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let documentBounds = documentView.bounds
            let visibleRect = scrollView.documentVisibleRect
            let distanceToBottom = documentView.isFlipped
                ? documentBounds.maxY - visibleRect.maxY
                : visibleRect.minY - documentBounds.minY
            onAtBottomChange(distanceToBottom <= 32)
        }
    }
}

@MainActor
private struct HarvisGroupMemorySheet: View {
    let group: HarvisGroupConversation
    let owner: HarvisGroupMember?
    let theme: HarvisTheme
    let onHistory: (HarvisGroupMember) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var memoryCopyText: String {
        [
            group.memory.summary.isEmpty ? nil : "协作摘要\n\(group.memory.summary)",
            group.memory.keyDecisions.isEmpty ? nil : "关键决定\n\(group.memory.keyDecisions.map { "- \($0)" }.joined(separator: "\n"))",
            group.memory.openItems.isEmpty ? nil : "未完成事项\n\(group.memory.openItems.map { "- \($0)" }.joined(separator: "\n"))"
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("协作记忆").harvisFont(.title3.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    memorySection("摘要", text: group.memory.summary, empty: "群主完成协作后会在这里留下摘要。")
                    memoryList("关键决定", items: group.memory.keyDecisions, empty: "暂无关键决定。")
                    memoryList("未完成事项", items: group.memory.openItems, empty: "暂无未完成事项。")

                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("群主原生会话").harvisFont(.caption.weight(.semibold))
                        if let owner {
                            Text("@\(owner.name)").harvisFont(.caption2).foregroundColor(theme.muted)
                            if let binding = owner.binding {
                                Text(binding.threadID)
                                    .harvisFont(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    copy(binding.threadID)
                                } label: {
                                    Label(copied ? "已复制会话 ID" : "复制会话 ID", systemImage: copied ? "checkmark" : "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button {
                                    onHistory(owner)
                                } label: {
                                    Label("查看群主原生历史", systemImage: "clock.arrow.circlepath")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Text("尚未创建原生会话；首次交给群主处理任务时会建立。")
                                    .harvisFont(.caption2)
                                    .foregroundColor(theme.muted)
                            }
                        } else {
                            Text("尚未设置群主。")
                                .harvisFont(.caption2)
                                .foregroundColor(theme.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                if !memoryCopyText.isEmpty {
                    Button {
                        copy(memoryCopyText)
                    } label: {
                        Label(copied ? "已复制" : "复制记忆", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 520, height: 480)
        .background(theme.background)
        .accessibilityIdentifier("harvis.group-chat.memory")
    }

    private func memorySection(_ title: String, text: String, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).harvisFont(.caption.weight(.semibold))
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(empty).harvisFont(.caption2).foregroundColor(theme.muted)
            } else {
                Text(text)
                    .harvisFont(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func memoryList(_ title: String, items: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).harvisFont(.caption.weight(.semibold))
            if items.isEmpty {
                Text(empty).harvisFont(.caption2).foregroundColor(theme.muted)
            } else {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(theme.accent.opacity(0.72)).frame(width: 4, height: 4).padding(.top, 5)
                        Text(items[index])
                            .harvisFont(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

@MainActor
private struct HarvisGroupMCPConfigurationSheet: View {
    let group: HarvisGroupConversation
    let serviceStatus: String
    let socketPath: String
    let configuration: String
    let installationText: String
    let theme: HarvisTheme
    let onRetry: () -> Void

    private enum CopiedContent: Equatable { case installationText, configuration }

    @Environment(\.dismiss) private var dismiss
    @State private var copiedContent: CopiedContent?

    private var serviceID: String { "harvis-group:\(group.id.uuidString)" }

    private var statusLooksUnhealthy: Bool {
        ["失败", "错误", "未就绪"].contains { serviceStatus.localizedCaseInsensitiveContains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("接入智能体服务").harvisFont(.title3.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(group.title).harvisFont(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Label("群主负责分配与验收", systemImage: "crown.fill")
                        .harvisFont(.caption2.weight(.semibold))
                        .foregroundColor(theme.accent)
                        .lineLimit(1)
                }
                Text("服务 ID · \(serviceID)")
                    .harvisFont(.caption2.monospaced())
                    .foregroundColor(theme.muted)
                    .textSelection(.enabled)
                Text("外部智能体可提交任务、查询状态、获取交付。")
                    .harvisFont(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(theme.surfaceAlt.opacity(theme.usesFlatSurfaces ? 1 : 0.65))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 6) {
                Circle().fill(statusLooksUnhealthy ? .red : theme.positive).frame(width: 7, height: 7)
                Text(serviceStatus).harvisFont(.caption2).foregroundColor(statusLooksUnhealthy ? .red : theme.muted)
                    .lineLimit(1)
                Spacer()
                Button("重试服务", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("本机 socket：\(socketPath)")
                    .harvisFont(.caption2.monospaced())
                    .foregroundColor(theme.muted)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text("HTTP 接入请按接口文档配置鉴权；此处提供本机 MCP 配置。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(configuration)
                    .harvisFont(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line, lineWidth: 1))
            .accessibilityIdentifier("harvis.group-chat.mcp-configuration")
            .frame(minHeight: 120, maxHeight: .infinity)

            Text("复制接入说明包含本群 ID、MCP JSON 与使用步骤；复制后粘贴至目标智能体设置。不会自动修改其他账号。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    copy(installationText, content: .installationText)
                } label: {
                    Label(
                        copiedContent == .installationText ? "已复制接入说明" : "复制接入说明",
                        systemImage: copiedContent == .installationText ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()
                Button {
                    copy(configuration, content: .configuration)
                } label: {
                    Label(
                        copiedContent == .configuration ? "已复制配置" : "复制 MCP 配置",
                        systemImage: copiedContent == .configuration ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 560, height: 560)
        .background(theme.background)
        .accessibilityIdentifier("harvis.group-chat.mcp-configuration-sheet")
    }

    private func copy(_ text: String, content: CopiedContent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedContent = content
    }
}
