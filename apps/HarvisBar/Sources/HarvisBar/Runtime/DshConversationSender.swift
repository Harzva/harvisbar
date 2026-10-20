import Foundation
import Combine

/// Delivery state survives closing the detail panel. A timed-out POST is never retried.
@MainActor
final class DshConversationSender: ObservableObject {
    struct State {
        var status = ""
        var busy = false
        var accepted = false
        var pendingRPCID: String?
        var endpoint: DshRuntimeEndpoint?
        var messages: [DshConversationMessage] = []
        var lastReply: String?
    }
    @Published private(set) var states: [String: State] = [:]
    private var drafts: [String: DshConversationDraft] = [:]
    func draft(for thread: ManagedChatThread) -> DshConversationDraft {
        if let draft = drafts[thread.id] { return draft }
        let draft = DshConversationDraft()
        drafts[thread.id] = draft
        return draft
    }
    private var refreshing: Set<String> = []
    private struct PendingPoll { var lastChecked: Date; var count: Int }
    private var pendingPolls: [String: PendingPoll] = [:]
    private var reconciling = false
    private let makeClient: (DshRuntimeEndpoint) -> DshHostApiClient

    init(makeClient: @escaping (DshRuntimeEndpoint) -> DshHostApiClient = { DshHostApiClient(endpoint: $0) }) {
        self.makeClient = makeClient
    }

    static func endpoint(for thread: ManagedChatThread, endpoints: [DshRuntimeEndpoint]) -> DshRuntimeEndpoint? {
        guard thread.provider == .dsh, !thread.archived, !thread.isSubagent else { return nil }
        let matches = Set(endpoints.filter { $0.sourceScope == thread.sourceScope }.map { $0.port })
        guard matches.count == 1 else { return nil }
        return endpoints.first { $0.sourceScope == thread.sourceScope }
    }

    @discardableResult
    func send(_ text: String, thread: ManagedChatThread, endpoint: DshRuntimeEndpoint,
              isCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 32_000, isCurrent(),
              Self.endpoint(for: thread, endpoints: [endpoint]) == endpoint,
              states[thread.id]?.busy != true, states[thread.id]?.pendingRPCID == nil else { return false }
        var state = states[thread.id] ?? State()
        state.busy = true
        state.accepted = false
        state.lastReply = nil
        state.endpoint = endpoint
        state.status = "正在核对目标会话…"
        states[thread.id] = state
        let client = makeClient(endpoint)
        do {
            let discovery = try await client.discover()
            guard isCurrent(), discovery.sessions.contains(where: { $0.sourceID == thread.sourceID && $0.parentSessionID == nil && $0.origin != "subagent" }),
                  !discovery.archivedSessionIDs.contains(thread.sourceID) else {
                throw DshConversationError.unavailable
            }
        } catch {
            states[thread.id]?.busy = false
            if let error = error as? URLError {
                states[thread.id]?.status = error.code == .timedOut
                    ? "未发送：连接 DSH 超时，草稿已保留。请稍后重试。"
                    : "未发送：无法连接 DSH，草稿已保留。请检查实例。"
            } else if error is DshConversationError {
                states[thread.id]?.status = "未发送：目标会话或实例已变化。请刷新会话列表。"
            } else {
                states[thread.id]?.status = "未发送：DSH 返回的会话信息未通过核对。草稿已保留。"
            }
            return false
        }
        let rpcID = UUID().uuidString
        states[thread.id]?.pendingRPCID = rpcID
        states[thread.id]?.status = "正在发送…"
        do {
            let result = try await client.sessionPrompt(.init(sessionID: thread.sourceID, mode: .queue,
                content: [.text(text)], clientTimeZone: TimeZone.current.identifier), rpcID: rpcID)
            states[thread.id]?.accepted = result.accepted
            if !result.accepted {
                states[thread.id]?.pendingRPCID = nil
                states[thread.id]?.status = "DSH 未接受消息。"
            } else if result.command != nil {
                states[thread.id]?.pendingRPCID = nil
                states[thread.id]?.status = "DSH 已接受命令。"
            } else {
                states[thread.id]?.status = "DSH 已接受，等待本次回复…"
            }
        } catch DshHostApiError.remoteFailure {
            states[thread.id]?.pendingRPCID = nil
            states[thread.id]?.status = "DSH 拒绝了本次消息，请检查会话后重试。"
        } catch {
            // A failed transport may have delivered the request. Keep its ID and reconcile history.
            states[thread.id]?.status = "发送结果待核对；不会自动重发。点击刷新检查本次消息。"
        }
        states[thread.id]?.busy = false
        let submitted = states[thread.id]?.accepted == true || states[thread.id]?.pendingRPCID != nil
        if states[thread.id]?.pendingRPCID != nil {
            pendingPolls[thread.id] = PendingPoll(lastChecked: Date(), count: 0)
        }
        if isCurrent() { await refresh(thread: thread, endpoint: endpoint) }
        return submitted
    }

    /// One shared runtime tick reconciles only messages actually submitted by Harvis.
    /// Cards create no timers or idle history requests. Stop automatic checks after
    /// 100 attempts; preserve the request ID so a manual refresh cannot duplicate it.
    func refreshPending(threads: [ManagedChatThread], endpoints: [DshRuntimeEndpoint], now: Date = Date()) async {
        guard !reconciling, !pendingPolls.isEmpty else { return }
        reconciling = true
        defer { reconciling = false }
        var visited: Set<String> = []
        for thread in threads where visited.insert(thread.id).inserted {
            guard var poll = pendingPolls[thread.id], poll.count < 100,
                  now.timeIntervalSince(poll.lastChecked) >= 3,
                  states[thread.id]?.pendingRPCID != nil,
                  let endpoint = Self.endpoint(for: thread, endpoints: endpoints),
                  states[thread.id]?.endpoint == endpoint else { continue }
            poll.lastChecked = now
            poll.count += 1
            pendingPolls[thread.id] = poll
            await refresh(thread: thread, endpoint: endpoint)
            if poll.count == 100, states[thread.id]?.pendingRPCID != nil {
                states[thread.id]?.status = "等待较久，点击核对继续检查；不会自动重发。"
            }
        }
    }

    func refresh(thread: ManagedChatThread, endpoint: DshRuntimeEndpoint) async {
        guard !refreshing.contains(thread.id),
              Self.endpoint(for: thread, endpoints: [endpoint]) == endpoint else { return }
        if let previous = states[thread.id], let previousEndpoint = previous.endpoint, previousEndpoint != endpoint {
            guard previous.pendingRPCID == nil, !previous.busy else { return }
            states[thread.id] = State()
        }
        refreshing.insert(thread.id)
        defer { refreshing.remove(thread.id) }
        do {
            let history = try await makeClient(endpoint).sessionHistory(
                .init(sessionID: thread.sourceID, beforeSeq: nil, maxMessages: 100))
            var state = states[thread.id] ?? State()
            state.endpoint = endpoint
            state.messages = history.events.compactMap { entry in
                guard (entry.event.type == "user/message" || entry.event.type == "assistant/message"),
                      !DshConversationHistoryScanner.isInternalContext(entry.event),
                      let text = DshConversationMessage.text(entry.event.data) else { return nil }
                return DshConversationMessage(id: entry.event.seq, isUser: entry.event.type == "user/message", text: String(text.prefix(24_000)))
            }.suffix(30).map { $0 }
            if let rpcID = state.pendingRPCID {
                switch DshConversationHistoryScanner.scan(history.events, promptRPCID: rpcID) {
                case .pending: break
                case let .proposalJSON(data):
                    state.lastReply = String(data: data, encoding: .utf8)
                    state.pendingRPCID = nil
                    state.status = "本次回复已完成（已核对请求与会话）。"
                case .failed:
                    state.pendingRPCID = nil
                    state.status = "本次 DSH 运行已结束，但未正常返回回复。"
                case .deliveryUnknown:
                    state.status = "本次回复归属待核对；请在 DSH 中检查，当前不会重复发送。"
                }
            }
            states[thread.id] = state
            if state.pendingRPCID == nil { pendingPolls.removeValue(forKey: thread.id) }
        } catch {
            if states[thread.id] == nil { states[thread.id] = State() }
            states[thread.id]?.status = "暂时无法读取 DSH 会话。可点击刷新重试。"
        }
    }
}

private enum DshConversationError: Error { case unavailable }

struct DshConversationMessage: Identifiable, Equatable {
    let id: Int
    let isUser: Bool
    let text: String

    static func text(_ data: DshJSONValue) -> String? {
        if let text = data["text"]?.stringValue, !text.isEmpty { return text }
        if let content = data["content"]?.arrayValue {
            let text = content.filter { $0["type"]?.stringValue == "text" }
                .compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        if let message = data["message"] { return text(message) }
        return nil
    }
}

/// DSH records plugin-injected context as user/message, alongside the actual user prompt.
/// Ignore only explicitly identified plugin and skill-catalog context; competing user or unknown sources
/// still prevent attributing an assistant response to this request.
enum DshConversationHistoryScanner {
    static func isInternalContext(_ event: DshSessionEvent) -> Bool {
        guard event.type == "user/message",
              event.data["source"]?["rpcId"]?.stringValue == nil,
              let kind = event.data["source"]?["kind"]?.stringValue else { return false }
        return kind == "plugin" || kind == "skill-catalog"
    }

    static func scan(_ entries: [DshSessionHistoryEntry], promptRPCID: String) -> DshMetaAgentHistoryScanResult {
        DshMetaAgentHistoryScanner.scan(entries.filter { !isInternalContext($0.event) }, promptRPCID: promptRPCID)
    }
}

/// Per-conversation observation keeps keystrokes from invalidating the card grid.
@MainActor
final class DshConversationDraft: ObservableObject {
    @Published var text = ""
}
