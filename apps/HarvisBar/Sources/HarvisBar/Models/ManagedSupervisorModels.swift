import Foundation

/// Card identity and supervision authority remain separate from provider activity.
enum ManagedSupervisorCompatibility: Equatable {
    case dsh
    case codexProject
    case observation(String)

    static func resolve(_ thread: ManagedChatThread) -> Self {
        switch thread.provider {
        case .dsh:
            if thread.isSubagent || thread.isSidechat {
                return .observation("DSH Supervisor 只接受顶层会话。请打开对应的主会话卡片；此卡片不会自动改指向其他会话。")
            }
            if thread.archived {
                return .observation("此会话已归档。请先在 DSH 中恢复并打开会话，再启用监督。")
            }
            return .dsh
        case .codex:
            return ConversationManagementProjectorV1.isDispatchEligible(thread)
                ? .codexProject
                : .observation("此类 Codex 会话目前只参与项目状态观察。项目管理派发支持主会话与已持久化的 Subagent。")
        case .workBuddy:
            return .observation("WorkBuddy 目前提供会话状态观察，尚未提供 Supervisor 控制接口。")
        }
    }
}

struct ManagedSupervisorSnapshot: Equatable, Sendable {
    let endpoint: DshRuntimeEndpoint
    let authority: DshBridgeAuthority
    let state: DshSupervisorState
    let readAt: Date
}

extension DshSupervisorState {
    var modeLabel: String {
        switch mode {
        case "advice": return "提意见"
        case "takeover": return "接管中"
        default: return "已关闭"
        }
    }

    var statusLabel: String {
        if !recoveryRequired.isEmpty { return "需要恢复核对" }
        if done { return "监督轮次完成" }
        switch status {
        case "working": return "原会话正在执行"
        case "thinking": return "正在生成监督建议"
        case "suggested": return "建议已就绪"
        case "silent": return "等待下一次检查"
        default: return "监督已关闭"
        }
    }

    var canRegenerate: Bool {
        mode != "off" && recoveryRequired.isEmpty && !done
            && remaining > 0 && status != "working" && status != "thinking"
            && !["running", "working", "waitingApproval", "waiting-approval", "pendingApproval", "pending-approval"].contains(agentStatus)
    }

    var canAdopt: Bool {
        mode != "off" && recoveryRequired.isEmpty && !done && remaining > 0
            && !suggestion.isEmpty && !suggestionID.isEmpty
            && status != "working" && status != "thinking"
            && !["running", "working", "waitingApproval", "waiting-approval", "pendingApproval", "pending-approval"].contains(agentStatus)
    }
}
