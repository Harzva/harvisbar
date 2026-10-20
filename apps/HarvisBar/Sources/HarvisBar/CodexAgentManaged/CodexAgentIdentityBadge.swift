import SwiftUI

struct CodexAgentIdentityBadge: View {
    let identityLabel: String
    let displayName: String
    let theme: HarvisTheme

    init(thread: CodexThreadSummary, theme: HarvisTheme) {
        identityLabel = thread.agentIdentityLabel
        displayName = thread.agentDisplayName
        self.theme = theme
    }

    init(thread: ManagedChatThread, theme: HarvisTheme) {
        identityLabel = thread.agentIdentityLabel
        displayName = thread.agentDisplayName
        self.theme = theme
    }

    var body: some View {
        Label(identityLabel, systemImage: "person.crop.circle.fill")
            .harvisFont(.system(size: 9, weight: .semibold))
            .foregroundColor(theme.muted)
            .lineLimit(1)
            .accessibilityLabel("Subagent \(displayName)")
    }
}

struct CodexFamilyActivityBreakdown: View {
    let activity: ManagedChatActivity
    let theme: HarvisTheme

    init(activity: CodexThreadFamilyActivity, theme: HarvisTheme) {
        self.activity = ManagedChatActivity(
            main: activity.main,
            subagent: activity.subagent,
            sidechat: activity.sidechat
        )
        self.theme = theme
    }

    init(activity: ManagedChatActivity, theme: HarvisTheme) {
        self.activity = activity
        self.theme = theme
    }

    var body: some View {
        HStack(spacing: 7) {
            Text("MAIN \(activity.main)")
            Text("SUBAGENT \(activity.subagent)")
            Text("SIDECHAT \(activity.sidechat.map(String.init) ?? "—")")
        }
        .harvisFont(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundColor(theme.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .help(
            activity.sidechat == nil
                ? "Side chats are temporary Codex UI sessions and are not reported by the thread index."
                : "Live task-family activity"
        )
    }
}
