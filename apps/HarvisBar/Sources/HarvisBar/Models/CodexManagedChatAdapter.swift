import Foundation

extension ManagedChatThread {
    init(codex thread: CodexThreadSummary) {
        self.init(
            codex: thread,
            sourceScope: ManagedChatSourceScope.codexDefault
        )
    }

    init(codex thread: CodexThreadSummary, sourceScope: String) {
        let activity = thread.cardActivity
        self.init(
            provider: .codex,
            sourceScope: sourceScope,
            sourceID: thread.id,
            title: thread.title,
            titleSource: thread.titleSource,
            hasMeaningfulTitle: thread.hasMeaningfulDisplayTitle,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            tokensUsed: thread.tokensUsed,
            model: thread.model,
            cwd: thread.cwd,
            archived: thread.archived,
            running: thread.isCardRunning,
            sourceStatus: nil,
            threadSource: thread.threadSource,
            agentNickname: thread.agentNickname,
            agentRole: thread.agentRole,
            agentPath: thread.agentPath,
            parentThreadID: thread.parentThreadId,
            rootThreadId: "codex::\(thread.rootThreadId ?? thread.id)",
            isSubagent: thread.isSubagent,
            isSidechat: thread.isSidechat,
            activity: ManagedChatActivity(
                main: activity.main,
                subagent: activity.subagent,
                sidechat: activity.sidechat
            ),
            trustProjection: thread.trustProjection
        )
    }
}
