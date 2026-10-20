import SwiftUI

/// DSH-specific navigation from B·DSH. Reuses the existing transport and
/// delivery coordinator, without opening or changing Chat/Agent Managed UI.
struct DshEnvironmentSessionsView: View {
    let home: DshHomeCatalogItem
    @Binding var profileFilter: String
    @ObservedObject var runtime: HarvisRuntimeModel
    @State private var query = ""
    @State private var selectedThread: ManagedChatThread?

    private var threads: [ManagedChatThread] {
        runtime.dshThreads.filter { thread in
            home.profiles.contains { profile in
                thread.sourceScope == DshRuntimeEndpoint(homeID: home.id, profile: profile.name, port: 1).sourceScope
                    && (profileFilter.isEmpty || profileFilter == profile.name)
            } && (query.isEmpty || thread.title.localizedCaseInsensitiveContains(query)
                  || (thread.agentNickname ?? "").localizedCaseInsensitiveContains(query))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Profile", selection: $profileFilter) {
                    Text("全部 Profile").tag("")
                    ForEach(home.profiles) { Text($0.name).tag($0.name) }
                }.frame(maxWidth: 320)
                Spacer()
                Button(runtime.isDshThreadRefreshing ? "正在刷新…" : "刷新会话") {
                    Task { await runtime.refreshDshThreads() }
                }.disabled(runtime.isDshThreadRefreshing)
            }
            TextField("搜索会话或 Preset", text: $query).textFieldStyle(.roundedBorder)
            Text("\(threads.count) 个会话 · 点击读取历史和发送消息。会话仍归属原 DSH 实例。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = runtime.dshThreadError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            if threads.isEmpty {
                Text(runtime.isDshThreadRefreshing ? "正在读取会话…" : "暂无匹配会话；实例需运行且开放会话接口。")
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(threads) { thread in
                Button { selectedThread = thread } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(thread.title).font(.body.weight(.medium)).lineLimit(2)
                            Spacer()
                            Text(thread.archived ? "已归档" : thread.running ? "运行中" : "空闲")
                                .font(.caption).foregroundStyle(thread.running ? .green : .secondary)
                        }
                        Text("Preset：\(thread.agentNickname ?? "未提供")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(thread.sourceScope).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
        }
        .task { await runtime.refreshDshThreads() }
        .sheet(item: $selectedThread) { thread in
            DshEnvironmentConversationView(runtime: runtime, sender: runtime.dshConversationSender, thread: thread)
                .frame(minWidth: 720, minHeight: 600)
        }
    }
}

private struct DshEnvironmentConversationView: View {
    @ObservedObject var runtime: HarvisRuntimeModel
    @ObservedObject var sender: DshConversationSender
    let thread: ManagedChatThread
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var draft: DshConversationDraft
    init(runtime: HarvisRuntimeModel, sender: DshConversationSender, thread: ManagedChatThread) {
        self.runtime = runtime
        self.sender = sender
        self.thread = thread
        self.draft = sender.draft(for: thread)
    }
    private var state: DshConversationSender.State { sender.states[thread.id] ?? .init() }
    private var endpoint: DshRuntimeEndpoint? {
        DshConversationSender.endpoint(for: thread, endpoints: runtime.dshRunningEndpoints)
    }
    private var canSend: Bool {
        endpoint != nil && !state.busy && state.pendingRPCID == nil
            && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.text.count <= 32_000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.title).font(.headline)
                    Text("Preset：\(thread.agentNickname ?? "未提供") · \(thread.sourceScope)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("在 DSH 打开") { runtime.openManagedThread(thread) }
                Button("完成") { dismiss() }
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if state.messages.isEmpty { Text("暂无历史，或正在读取…").foregroundStyle(.secondary) }
                    ForEach(state.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.isUser ? "你" : "DSH").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(message.text).textSelection(.enabled)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            TextEditor(text: $draft.text).frame(height: 80).border(.secondary.opacity(0.2))
                .accessibilityLabel("DSH 管理消息输入")
                .disabled(endpoint == nil || state.busy || state.pendingRPCID != nil)
            HStack {
                Text(state.status.isEmpty ? "消息发送到此会话的原实例" : state.status)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新历史") { Task { await refresh() } }.disabled(endpoint == nil)
                Button("发送到此会话") {
                    guard let endpoint else { return }
                    let submittedText = draft.text
                    Task {
                        let submitted = await sender.send(submittedText, thread: thread, endpoint: endpoint) {
                            DshConversationSender.endpoint(for: thread, endpoints: runtime.dshRunningEndpoints) == endpoint
                                && runtime.dshThreads.contains { $0.id == thread.id && !$0.archived }
                        }
                        if submitted && draft.text == submittedText { draft.text = "" }
                    }
                }.buttonStyle(.borderedProminent).disabled(!canSend)
            }
            if endpoint == nil {
                Text("实例离线、归属不唯一或此会话不可发送。请返回刷新实例和会话。").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
        .task(id: endpoint) { await refresh() }
    }
    private func refresh() async {
        guard let endpoint else { return }
        await sender.refresh(thread: thread, endpoint: endpoint)
    }
}
