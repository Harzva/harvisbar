import AppKit
import SwiftUI

@MainActor
struct HarvisGroupWindowView: View {
    @ObservedObject var runtime: HarvisRuntimeModel
    @ObservedObject var coordinator: HarvisGroupCoordinator

    @State private var selectedGroupID: UUID?
    @State private var lastSelectedGroupID: UUID?
    @State private var sheetRoute: HarvisGroupSheetRoute?
    @State private var draft = ""
    @State private var recipientMode: HarvisGroupRecipientMode = .allMembers
    @State private var permission: HarvisGroupPermission = .discussion
    @State private var visibleMessageCount = 100
    @State private var draftsByGroupID: [UUID: String] = [:]
    @State private var recipientModesByGroupID: [UUID: HarvisGroupRecipientMode] = [:]
    @State private var permissionsByGroupID: [UUID: HarvisGroupPermission] = [:]
    @State private var submitErrors: [UUID: String] = [:]
    @State private var isRetryingActivation = false
    @State private var observedDeliveryReady = false
    @State private var observedDeliveryError: String?
    @State private var timelineIsFollowingLatest = true
    @State private var timelineViewportHeight: CGFloat = 0
    @State private var timelineBottomY = CGFloat.greatestFiniteMagnitude
    @State private var timelineVisibleMessageID: UUID?
    @State private var pendingEarlierAnchorID: UUID?
    @FocusState private var composerFocused: Bool

    private var theme: HarvisTheme { runtime.theme }
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
        }
        .onReceive(coordinator.delivery.$isReady.removeDuplicates()) { ready in
            observedDeliveryReady = ready
        }
        .onReceive(coordinator.delivery.$lastError.removeDuplicates()) { error in
            observedDeliveryError = error
        }
        .onChange(of: coordinator.groups.map(\.id)) { _ in selectInitialGroupIfNeeded() }
        .onChange(of: selectedGroupID) { nextGroupID in
            if let previousGroupID = lastSelectedGroupID {
                draftsByGroupID[previousGroupID] = draft
                recipientModesByGroupID[previousGroupID] = recipientMode
                permissionsByGroupID[previousGroupID] = permission
            }
            lastSelectedGroupID = nextGroupID
            visibleMessageCount = 100
            timelineIsFollowingLatest = true
            pendingEarlierAnchorID = nil
            if let nextGroupID {
                draft = draftsByGroupID[nextGroupID] ?? ""
                recipientMode = recipientModesByGroupID[nextGroupID] ?? .allMembers
                permission = permissionsByGroupID[nextGroupID] ?? .discussion
            } else {
                draft = ""
                recipientMode = .allMembers
                permission = .discussion
            }
        }
        .onChange(of: draft) { value in
            if let selectedGroupID { draftsByGroupID[selectedGroupID] = value }
        }
        .onChange(of: permission) { value in
            if let selectedGroupID { permissionsByGroupID[selectedGroupID] = value }
        }
        .onChange(of: recipientMode) { value in
            if let selectedGroupID { recipientModesByGroupID[selectedGroupID] = value }
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
                Rectangle().fill(theme.line).frame(height: 1)
                timeline(group)
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
        }
        .frame(width: 224)
        .background(theme.surfaceAlt.opacity(theme.usesFlatSurfaces ? 0.72 : 0.54))
    }

    private func groupRow(_ group: HarvisGroupConversation) -> some View {
        let isSelected = group.id == selectedGroupID
        let preview = group.messages.last?.text ?? "添加成员并开始讨论"
        return Button {
            selectedGroupID = group.id
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
                if group.members.isEmpty {
                    Text("首次 @ 成员时会创建原生会话")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                }
            }
            if group.members.isEmpty {
                Text("成员尚未加入。为每位成员选择唯一 @ 名称、职责和 Codex 账号。")
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
                                homeLabel: homeLabel(for: member.binding?.homePath ?? member.homePath),
                                theme: theme,
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
                .frame(maxHeight: 140)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.background)
    }

    private func timeline(_ group: HarvisGroupConversation) -> some View {
        let visibleMessages = Array(group.messages.suffix(visibleMessageCount))
        let bottomAnchorID = "harvis.group-chat.timeline.bottom.\(group.id.uuidString)"
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if group.messages.count > visibleMessages.count {
                        Button("加载更早的群聊记录（\(group.messages.count - visibleMessages.count) 条）") {
                            pendingEarlierAnchorID = timelineVisibleMessageID ?? visibleMessages.first?.id
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
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: HarvisGroupTimelineMessageFramesPreferenceKey.self,
                                        value: [message.id: geometry.frame(in: .named("harvis.group-chat.timeline.viewport"))]
                                    )
                                }
                            }
                            .id(message.id)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: HarvisGroupTimelineBottomYPreferenceKey.self,
                                    value: geometry.frame(in: .named("harvis.group-chat.timeline.viewport")).minY
                                )
                            }
                        }
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .coordinateSpace(name: "harvis.group-chat.timeline.viewport")
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: HarvisGroupTimelineViewportHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(HarvisGroupTimelineViewportHeightPreferenceKey.self) { height in
                timelineViewportHeight = height
                updateTimelineFollowState()
            }
            .onPreferenceChange(HarvisGroupTimelineBottomYPreferenceKey.self) { bottomY in
                timelineBottomY = bottomY
                updateTimelineFollowState()
            }
            .onPreferenceChange(HarvisGroupTimelineMessageFramesPreferenceKey.self) { frames in
                timelineVisibleMessageID = frames
                    .filter { $0.value.maxY > 0 }
                    .min { $0.value.minY < $1.value.minY }?
                    .key
            }
            .onAppear {
                timelineIsFollowingLatest = true
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
            .onChange(of: group.messages.last?.id) { latestID in
                guard latestID != nil else { return }
                guard timelineIsFollowingLatest else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier("harvis.group-chat.timeline")
    }

    private func updateTimelineFollowState() {
        guard timelineViewportHeight > 0, timelineBottomY.isFinite else { return }
        timelineIsFollowingLatest = timelineBottomY <= timelineViewportHeight + 32
    }

    private func composer(_ group: HarvisGroupConversation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Menu {
                    if group.members.isEmpty {
                        Text("请先添加群成员")
                    } else {
                        Button {
                            setRecipientMode(.allMembers)
                        } label: {
                            Label("全体成员", systemImage: recipientMode == .allMembers ? "checkmark" : "person.3")
                        }

                        Section("指定成员") {
                            ForEach(group.members) { member in
                                Toggle(isOn: specificRecipientBinding(for: member.id)) {
                                    Text("@\(member.name) · \(member.role)")
                                }
                            }
                        }

                        Divider()
                        Button {
                            setRecipientMode(.recordOnly)
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
                .accessibilityHint("默认唤醒全体成员；正文出现成员名字时，只唤醒这些成员，无需输入 @。仅记录模式不会唤醒成员。")
                .help("默认唤醒全体成员；正文出现成员名字时，只唤醒这些成员，无需输入 @。仅记录模式不会唤醒成员。")

                Picker("权限", selection: $permission) {
                    Text("讨论 · 只读").tag(HarvisGroupPermission.discussion)
                    Text("项目写入").tag(HarvisGroupPermission.workspaceWrite)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("本条消息权限")
                .help("讨论会话只读；只有明确选择“项目写入”才允许修改共享项目。")

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
                TextEditor(text: $draft)
                    .harvisFont(.body)
                    .focused($composerFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 62, maxHeight: 100)
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

            HStack(spacing: 7) {
                Image(systemName: effectiveRecipients(group).isEmpty ? "info.circle" : "paperplane")
                    .accessibilityHidden(true)
                Text(composerHint(group))
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    send(group)
                } label: {
                    Label("发送", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !coordinator.isReady || !observedDeliveryReady)
                .accessibilityIdentifier("harvis.group-chat.send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(theme.surfaceAlt.opacity(theme.usesFlatSurfaces ? 1 : 0.64))
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private func specificRecipientBinding(for memberID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                guard case let .selected(memberIDs) = recipientMode else { return false }
                return memberIDs.contains(memberID)
            },
            set: { selected in
                var memberIDs: Set<UUID>
                if case let .selected(current) = recipientMode { memberIDs = current }
                else { memberIDs = [] }
                if selected { memberIDs.insert(memberID) }
                else { memberIDs.remove(memberID) }
                setRecipientMode(memberIDs.isEmpty ? .recordOnly : .selected(memberIDs))
            }
        )
    }

    private func setRecipientMode(_ mode: HarvisGroupRecipientMode) {
        recipientMode = mode
        if let selectedGroupID { recipientModesByGroupID[selectedGroupID] = mode }
    }

    private func explicitRecipients(_ group: HarvisGroupConversation) -> [UUID] {
        HarvisGroupMentions.resolve(draft, members: group.members)
    }

    private func recipientSummary(_ group: HarvisGroupConversation) -> String {
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
        }
    }

    private func effectiveRecipients(_ group: HarvisGroupConversation) -> [UUID] {
        if case .recordOnly = recipientMode { return [] }
        let typed = explicitRecipients(group)
        if !typed.isEmpty { return typed }

        switch recipientMode {
        case .allMembers:
            return group.members.map(\.id)
        case let .selected(memberIDs):
            return group.members.map(\.id).filter { memberIDs.contains($0) }
        case .recordOnly:
            return []
        }
    }

    private func memberNames(_ memberIDs: [UUID], in group: HarvisGroupConversation) -> [String] {
        group.members.filter { memberIDs.contains($0.id) }.map(\.name)
    }

    private func composerHint(_ group: HarvisGroupConversation) -> String {
        let recipients = effectiveRecipients(group)
        let permissionLabel = permission == .discussion ? "只读讨论" : "允许写入共享项目"
        if case .recordOnly = recipientMode {
            let mentionNote = explicitRecipients(group).isEmpty ? "" : "；提到名字也不执行"
            return "仅记录到群时间线\(mentionNote) · \(permissionLabel)"
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
        let originalDraft = draft
        let originalRecipientMode = recipientMode
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let recipients = effectiveRecipients(group)
        let sendPermission = permission
        let groupID = group.id
        submitErrors[groupID] = nil
        draft = ""
        draftsByGroupID[groupID] = ""
        setRecipientMode(.allMembers)
        Task {
            let persisted = await coordinator.send(
                groupID: groupID,
                text: text,
                mentionedMemberIDs: recipients,
                permission: sendPermission,
                resolveTextMentions: false
            )
            if !persisted {
                if (draftsByGroupID[groupID] ?? "").isEmpty {
                    draftsByGroupID[groupID] = originalDraft
                    let shouldRestoreMode = (recipientModesByGroupID[groupID] ?? .allMembers) == .allMembers
                    if shouldRestoreMode { recipientModesByGroupID[groupID] = originalRecipientMode }
                    if selectedGroupID == groupID {
                        draft = originalDraft
                        if shouldRestoreMode { setRecipientMode(originalRecipientMode) }
                        composerFocused = true
                    }
                    submitErrors[groupID] = "消息未保存，草稿已恢复；请检查群聊状态后重试。"
                } else {
                    submitErrors[groupID] = "上一条消息未保存；当前编辑内容已保留。"
                }
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
        if let selectedGroupID, coordinator.groups.contains(where: { $0.id == selectedGroupID }) { return }
        selectedGroupID = coordinator.groups.first?.id
    }

    @ViewBuilder
    private func sheetContent(for route: HarvisGroupSheetRoute) -> some View {
        switch route {
        case .createGroup:
            HarvisCreateGroupSheet(runtime: runtime) { title, path in
                guard let id = await coordinator.createGroup(title: title, projectPath: path) else { return false }
                selectedGroupID = id
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
        }
    }
}

private enum HarvisGroupSheetRoute: Identifiable {
    case createGroup
    case addMember(UUID)
    case history(UUID, UUID)
    case handoff(UUID, UUID)

    var id: String {
        switch self {
        case .createGroup: return "create"
        case let .addMember(id): return "add-\(id)"
        case let .history(groupID, memberID): return "history-\(groupID)-\(memberID)"
        case let .handoff(groupID, memberID): return "handoff-\(groupID)-\(memberID)"
        }
    }
}

@MainActor
private struct HarvisGroupMemberRow: View {
    let member: HarvisGroupMember
    let liveState: CodexThreadLiveState?
    let latestDispatch: HarvisGroupDispatch?
    let homeLabel: String
    let theme: HarvisTheme
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
        if approval != nil { return ("待审批", theme.accent2) }
        if liveState?.activeTurnID != nil || liveState?.status == .active { return ("运行中", theme.positive) }
        if let latestDispatch {
            switch latestDispatch.state {
            case .queued: return ("排队中", theme.accent)
            case .waiting: return ("等待中", theme.accent)
            case .dispatching: return ("启动中", theme.accent)
            case .running: return ("运行中", theme.positive)
            case .waitingApproval: return ("待审批", theme.accent2)
            case .completed: return ("已完成", theme.positive)
            case .failed: return ("失败", .red)
            case .deliveryUnknown: return ("状态待核", theme.accent2)
            case .cancelled: return ("已停止", theme.muted)
            }
        }
        return (member.binding == nil ? "首次 @ 时启动" : "已绑定 · 空闲", theme.muted)
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
                        Text(member.role).harvisFont(.caption2).foregroundColor(theme.muted).lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text(homeLabel).lineLimit(1)
                        if let binding = member.binding {
                            Text("· 原生 \(binding.threadID.suffix(8))")
                                .lineLimit(1)
                                .help("原生 thread ID：\(binding.threadID)")
                        } else {
                            Text("· 未启动原生会话").lineLimit(1)
                        }
                    }
                    .harvisFont(.caption2.monospaced())
                    .foregroundColor(theme.muted)
                    if let binding = member.binding, let model = binding.model, !model.isEmpty {
                        Text("模型 \(model) · 推理 \(binding.reasoningEffort ?? "默认")")
                            .harvisFont(.caption2)
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                            .help("原生配置：模型 \(model)，推理档位 \(binding.reasoningEffort ?? "默认")")
                    }
                }
                .frame(minWidth: 115, maxWidth: 260, alignment: .leading)

                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Circle().fill(status.1).frame(width: 6, height: 6)
                    Text(status.0).harvisFont(.caption2).lineLimit(1)
                }
                .foregroundColor(status.1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("@\(member.name)，状态：\(status.0)")

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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("成员会话操作")
                .accessibilityLabel("@\(member.name) 的会话操作")

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
private struct HarvisGroupMessageRow: View {
    let message: HarvisGroupMessage
    let group: HarvisGroupConversation
    let homeLabel: String?
    let theme: HarvisTheme

    private var isUser: Bool { message.speaker == "你" }
    private var isSystem: Bool { message.speaker == "系统" }
    private var dispatches: [HarvisGroupDispatch] { group.dispatches.filter { $0.messageID == message.id } }

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
                Text(message.text)
                    .harvisFont(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
        .accessibilityLabel("\(message.speaker)，\(metadata)：\(message.text)")
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
            Text("在正文写出名字即可指派，无需 @。名字须在群内唯一；同一账号可加入多位成员。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
            VStack(alignment: .leading, spacing: 5) {
                Text("@ 名称").harvisFont(.caption.weight(.semibold))
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
            Text("交接会创建一个新的原生 Codex thread。下一次 @ 该成员时会带上共享群记录；原账号中的私有原生历史不会迁移。")
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

private struct HarvisGroupTimelineViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HarvisGroupTimelineBottomYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HarvisGroupTimelineMessageFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private enum HarvisGroupRecipientMode: Equatable {
    case allMembers
    case selected(Set<UUID>)
    case recordOnly
}
