import SwiftUI

/// Always present on DSH cards, independent of the Codex composer tag filter.
struct DshConversationCardComposer: View {
    @EnvironmentObject private var model: HarvisRuntimeModel
    @ObservedObject var sender: DshConversationSender
    @ObservedObject var draft: DshConversationDraft
    let thread: ManagedChatThread
    let theme: HarvisTheme
    let compact: Bool

    @Environment(\.harvisTextSize) private var harvisTextSize

    private var endpoint: DshRuntimeEndpoint? {
        DshConversationSender.endpoint(for: thread, endpoints: model.dshRunningEndpoints)
    }
    private var state: DshConversationSender.State { sender.states[thread.id] ?? .init() }
    private var locked: Bool { state.busy || state.pendingRPCID != nil }
    private var unavailableReason: String? {
        if thread.archived { return "会话已归档" }
        if thread.isSubagent { return "子智能体请在 DSH 中发送" }
        if endpoint == nil { return "实例离线或存在标识冲突" }
        return nil
    }
    private var canSend: Bool {
        unavailableReason == nil && !locked && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.text.count <= 32_000
    }
    private var statusLabel: String {
        if let unavailableReason { return unavailableReason }
        if draft.text.count > 32_000 { return "消息超过 32,000 字" }
        if let reply = state.lastReply { return "已回复：\(reply)" }
        if !state.status.isEmpty { return state.status }
        return "Enter 发送 · Shift+Enter 换行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CodexTaskComposerLayoutMetrics.verticalSpacing(for: harvisTextSize)) {
            ZStack(alignment: .topLeading) {
                ManagedChatMultilineInput(
                    text: $draft.text,
                    isEnabled: unavailableReason == nil && !locked,
                    onSubmit: submit,
                    inputAccessibilityID: "dsh-card-input-\(thread.id)",
                    inputAccessibilityLabel: "DSH 卡片消息输入 · \(thread.title)"
                )
                if draft.text.isEmpty {
                    Text(unavailableReason ?? (locked ? "等待 DSH 回复…" : "发送消息给 DSH…"))
                        .harvisFont(.system(size: 12)).foregroundColor(theme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: CodexTaskComposerLayoutMetrics.inputHeight(compact: compact, for: harvisTextSize))
            .background(theme.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line, lineWidth: 1))
            HStack(spacing: 4) {
                Text(statusLabel).harvisFont(.system(size: 9))
                    .foregroundColor(state.lastReply == nil ? theme.muted : theme.positive)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .help(statusLabel)
                    .accessibilityIdentifier("dsh-card-status-\(thread.id)")
                if state.pendingRPCID != nil && !state.busy {
                    Button {
                        guard let endpoint else { return }
                        Task { await sender.refresh(thread: thread, endpoint: endpoint) }
                    } label: { Image(systemName: "arrow.clockwise").harvisFont(.caption2) }
                    .buttonStyle(.plain).help("核对本次消息，不会重新发送")
                    .accessibilityLabel("核对 DSH 消息")
                    .disabled(endpoint == nil)
                }
                Button("发送", action: submit)
                    .harvisFont(.system(size: 10)).controlSize(.mini)
                    .accessibilityLabel("发送 DSH 卡片消息 · \(thread.title)")
                    .accessibilityIdentifier("dsh-card-send-\(thread.id)")
                    .disabled(!canSend)
            }
            .frame(height: CodexTaskComposerLayoutMetrics.controlsHeight(for: harvisTextSize))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DSH 卡片发送区 · \(thread.title)")
    }

    private func submit() {
        guard canSend, let endpoint else { return }
        let submittedText = draft.text
        Task {
            let submitted = await sender.send(submittedText, thread: thread, endpoint: endpoint) {
                DshConversationSender.endpoint(for: thread, endpoints: model.dshRunningEndpoints) == endpoint
                    && model.dshThreads.contains { $0.id == thread.id && !$0.archived }
            }
            if submitted && draft.text == submittedText { draft.text = "" }
        }
    }
}
