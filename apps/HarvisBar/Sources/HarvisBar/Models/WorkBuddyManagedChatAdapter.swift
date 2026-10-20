import Foundation

extension ManagedChatThread {
    init(workBuddy thread: WorkBuddyThreadSummary) {
        self.init(
            workBuddy: thread,
            sourceScope: ManagedChatSourceScope.workBuddyLocal
        )
    }

    init(workBuddy thread: WorkBuddyThreadSummary, sourceScope: String) {
        self.init(
            provider: .workBuddy,
            sourceScope: sourceScope,
            sourceID: thread.id,
            title: thread.title,
            titleSource: nil,
            hasMeaningfulTitle: true,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            tokensUsed: thread.tokensUsed,
            model: thread.model,
            cwd: thread.cwd,
            archived: thread.archived,
            running: thread.running,
            sourceStatus: thread.sourceStatus,
            threadSource: "workbuddy",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: "workbuddy::\(thread.id)",
            isSubagent: false,
            isSidechat: false,
            activity: ManagedChatActivity(
                main: thread.running ? 1 : 0,
                subagent: 0,
                sidechat: nil
            ),
            trustProjection: Self.workBuddyTrustProjection(thread)
        )
    }

    private static func workBuddyTrustProjection(
        _ thread: WorkBuddyThreadSummary
    ) -> CodexThreadTrustProjection {
        if thread.running {
            return CodexThreadTrustProjection(
                state: .running,
                reason: "WorkBuddy reports this session as \(thread.sourceStatus)."
            )
        }
        switch thread.sourceStatus.lowercased() {
        case "completed":
            return CodexThreadTrustProjection(
                state: .completed,
                reason: "WorkBuddy reports this session as completed."
            )
        case "failed", "error":
            return CodexThreadTrustProjection(
                state: .failed,
                reason: "WorkBuddy reports this session as \(thread.sourceStatus)."
            )
        default:
            return CodexThreadTrustProjection(
                state: .idle,
                reason: "WorkBuddy reports this session as \(thread.sourceStatus)."
            )
        }
    }
}
