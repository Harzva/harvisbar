import SwiftUI

struct ManagedAttentionEditorSheet: View {
    let subject: String
    let initial: ManagedAttentionPreference
    let theme: HarvisTheme
    let onSave: (ManagedAttentionPreference) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var levelRaw: Int
    @State private var focusEnabled: Bool
    @State private var focusStartsAt: Date
    @State private var focusEndsAt: Date

    init(
        subject: String,
        initial: ManagedAttentionPreference,
        theme: HarvisTheme,
        onSave: @escaping (ManagedAttentionPreference) -> Void
    ) {
        self.subject = subject
        self.initial = initial
        self.theme = theme
        self.onSave = onSave
        let now = Date()
        _levelRaw = State(initialValue: initial.level?.rawValue ?? 0)
        _focusEnabled = State(initialValue: initial.focusStartsAt != nil && initial.focusEndsAt != nil)
        _focusStartsAt = State(initialValue: initial.focusStartsAt ?? now)
        _focusEndsAt = State(
            initialValue: initial.focusEndsAt ?? now.addingTimeInterval(24 * 60 * 60)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("关注设置")
                        .harvisFont(.title3.bold())
                    Text(subject)
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                        .lineLimit(2)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("人工重要级")
                    .harvisFont(.caption.bold())
                    .foregroundColor(theme.muted)
                Picker("人工重要级", selection: $levelRaw) {
                    Text("未评价").tag(0)
                    ForEach(ManagedAttentionLevel.allCases) { level in
                        Text(level.label).tag(level.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Toggle("设定关注时间区间", isOn: $focusEnabled)
                .toggleStyle(.switch)

            if focusEnabled {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("开始")
                            .foregroundColor(theme.muted)
                        DatePicker(
                            "开始",
                            selection: $focusStartsAt,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                    }
                    GridRow {
                        Text("结束")
                            .foregroundColor(theme.muted)
                        DatePicker(
                            "结束",
                            selection: $focusEndsAt,
                            in: focusStartsAt...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                    }
                }
                .harvisFont(.caption)
            }

            Text("重要级只来自你的人工判断；任务数量和会话长度不会偷偷改写它。")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)

            HStack {
                Button("清除") {
                    onSave(ManagedAttentionPreference())
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.muted)
                Spacer()
                Button("保存") {
                    let level = ManagedAttentionLevel(rawValue: levelRaw)
                    onSave(ManagedAttentionPreference(
                        level: level,
                        focusStartsAt: focusEnabled ? focusStartsAt : nil,
                        focusEndsAt: focusEnabled ? focusEndsAt : nil
                    ))
                    dismiss()
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(focusEnabled && focusEndsAt <= focusStartsAt)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.background)
        .foregroundColor(theme.text)
    }
}

struct UnnamedSubagentVisibilitySheet: View {
    let threads: [ManagedChatThread]
    let theme: HarvisTheme
    let isVisible: (ManagedChatThread) -> Bool
    let setVisible: (Bool, ManagedChatThread) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matchingThreads: [ManagedChatThread] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return threads }
        return threads.filter {
            [$0.agentDisplayName, $0.agentTaskLabel ?? "", $0.cwd, $0.sourceID]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("未命名 Subagent 显示管理")
                        .harvisFont(.title3.bold())
                    Text("默认隐藏；按任务单独显示。隐藏不会删除、归档或停止任务。")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(HarvisControlButtonStyle(theme: theme))
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.muted)
                TextField("搜索 Agent、角色、项目或 ID", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line))

            HStack {
                Text("\(threads.filter { !isVisible($0) }.count) 隐藏 · \(threads.filter(isVisible).count) 显示")
                    .harvisFont(.caption.monospacedDigit())
                    .foregroundColor(theme.muted)
                Spacer()
                Button("全部隐藏") {
                    threads.forEach { setVisible(false, $0) }
                }
                .buttonStyle(.plain)
                Button("全部显示") {
                    threads.forEach { setVisible(true, $0) }
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(theme.line)

            if matchingThreads.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash")
                        .harvisFont(.system(size: 28))
                        .foregroundColor(theme.muted)
                    Text("没有匹配项")
                        .harvisFont(.headline)
                    Text("调整搜索词后重试。")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(matchingThreads) { thread in
                    Toggle(isOn: Binding(
                        get: { isVisible(thread) },
                        set: { setVisible($0, thread) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(thread.agentDisplayName)
                                    .harvisFont(.subheadline.bold())
                                if let role = thread.agentTaskLabel {
                                    Text(role)
                                        .harvisFont(.caption2.monospaced())
                                        .foregroundColor(theme.muted)
                                }
                                if thread.isCardRunning {
                                    Text("RUNNING")
                                        .harvisFont(.system(size: 9, weight: .bold))
                                        .foregroundColor(theme.positive)
                                }
                            }
                            Text(thread.cwd)
                                .harvisFont(.caption2.monospaced())
                                .foregroundColor(theme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .listStyle(.inset)
            }
        }
        .padding(18)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 620)
        .background(theme.background)
        .foregroundColor(theme.text)
    }
}

struct ManagedAttentionBadge: View {
    let preference: ManagedAttentionPreference
    let theme: HarvisTheme

    var body: some View {
        HStack(spacing: 5) {
            if let level = preference.level {
                Label(level.compactLabel, systemImage: "star.fill")
                    .foregroundColor(theme.accent)
            }
            switch preference.focusState() {
            case .active:
                Label(focusEndLabel, systemImage: "bell.fill")
                    .foregroundColor(.orange)
            case .scheduled:
                Label("待关注", systemImage: "clock")
                    .foregroundColor(theme.muted)
            case .expired:
                Label("关注已到期", systemImage: "bell.badge")
                    .foregroundColor(.orange)
            case .unset:
                EmptyView()
            }
        }
        .harvisFont(.system(size: 10, weight: .semibold))
    }

    private var focusEndLabel: String {
        guard let end = preference.focusEndsAt else { return "关注中" }
        return "关注至 \(end.formatted(date: .omitted, time: .shortened))"
    }
}
