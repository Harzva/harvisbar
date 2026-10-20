import SwiftUI

struct DshConversationPanel: View {
    @EnvironmentObject private var model: HarvisRuntimeModel
    @ObservedObject var sender: DshConversationSender
    let thread: ManagedChatThread
    let onClose: () -> Void
    @State private var draft = ""

    private var endpoint: DshRuntimeEndpoint? {
        DshConversationSender.endpoint(for: thread, endpoints: model.dshRunningEndpoints)
    }
    private var state: DshConversationSender.State { sender.states[thread.id] ?? .init() }
    private var canSend: Bool {
        endpoint != nil && !state.busy && state.pendingRPCID == nil &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 32_000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DSH 会话").harvisFont(.headline)
                Spacer()
                Button("在 DSH 中打开") { model.openManagedThread(thread) }
                Button("关闭", action: onClose)
            }
            Text(thread.title).harvisFont(.headline).textSelection(.enabled)
            Text("实例：\(thread.sourceScope) · 会话：\(thread.sourceID)")
                .harvisFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if state.messages.isEmpty { Text("暂无可显示消息，或正在读取会话…").foregroundStyle(.secondary) }
                    ForEach(state.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.isUser ? "你" : "DSH").harvisFont(.caption.bold()).foregroundStyle(.secondary)
                            Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10).background(Color.primary.opacity(0.04)).cornerRadius(8)
                    }
                }
            }
            if endpoint == nil {
                Text(thread.isSubagent ? "子智能体会话请在 DSH 中操作。" : "实例离线、会话已归档或实例标识冲突，暂不可发送。")
                    .foregroundStyle(.secondary)
            } else {
                TextEditor(text: $draft)
                    .harvisFont(.body).frame(minHeight: 72, maxHeight: 110)
                    .border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("DSH 消息输入")
                    .accessibilityIdentifier("dsh-message-input")
                    .disabled(state.busy || state.pendingRPCID != nil)
            }
            HStack {
                Text(state.status).harvisFont(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dsh-send-status")
                Spacer()
                Button("刷新") { Task { await refresh() } }.disabled(endpoint == nil)
                Button("发送到 DSH") {
                    guard let endpoint else { return }
                    let text = draft
                    Task {
                        let submitted = await sender.send(text, thread: thread, endpoint: endpoint) {
                            DshConversationSender.endpoint(for: thread, endpoints: model.dshRunningEndpoints) == endpoint
                                && model.dshThreads.contains { $0.id == thread.id && !$0.archived }
                        }
                        if submitted && draft == text {
                            draft = ""
                        }
                    }
                }
                .accessibilityIdentifier("dsh-send-message")
                .disabled(!canSend)
            }
        }
        .padding(16)
        .task(id: endpoint) {
            await refresh()
        }
    }

    private func refresh() async {
        guard let endpoint else { return }
        await sender.refresh(thread: thread, endpoint: endpoint)
    }
}
