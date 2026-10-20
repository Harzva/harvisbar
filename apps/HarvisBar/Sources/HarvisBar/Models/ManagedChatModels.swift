import Foundation

enum ManagedChatProvider: String, CaseIterable, Identifiable {
    case codex
    case dsh
    case workBuddy = "workbuddy"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .dsh: return "DSH"
        case .workBuddy: return "WorkBuddy"
        }
    }

    var systemImage: String {
        switch self {
        case .codex: return "terminal"
        case .dsh: return "bolt.horizontal.circle"
        case .workBuddy: return "person.crop.circle.badge.checkmark"
        }
    }

    var capabilities: ManagedChatCapabilities {
        switch self {
        case .codex:
            return .init(
                supportsCodexDispatch: true,
                supportsCodexWorkbench: true,
                supportsExactThreadOpen: true
            )
        case .dsh, .workBuddy:
            return .observationOnly
        }
    }
}

enum ManagedChatSourceScope {
    static let codexDefault = "default"
    static let workBuddyLocal = "local"
}

struct ManagedChatCapabilities: Equatable, Sendable {
    static let observationOnly = ManagedChatCapabilities(
        supportsCodexDispatch: false,
        supportsCodexWorkbench: false,
        supportsExactThreadOpen: false
    )

    let supportsCodexDispatch: Bool
    let supportsCodexWorkbench: Bool
    let supportsExactThreadOpen: Bool

    var isObservationOnly: Bool {
        !supportsCodexDispatch
            && !supportsCodexWorkbench
            && !supportsExactThreadOpen
    }
}

struct ManagedChatActivity {
    let main: Int
    let subagent: Int
    let sidechat: Int?

    var total: Int {
        main + subagent + (sidechat ?? 0)
    }
}

struct ManagedChatThread: Identifiable {
    let provider: ManagedChatProvider
    let sourceScope: String
    let sourceID: String
    let title: String
    let titleSource: String?
    let hasMeaningfulTitle: Bool
    let createdAt: Int64
    let updatedAt: Int64
    let tokensUsed: Int64
    let model: String?
    let cwd: String
    let archived: Bool
    let running: Bool
    let sourceStatus: String?
    let threadSource: String?
    let agentNickname: String?
    let agentRole: String?
    let agentPath: String?
    let parentThreadID: String?
    let rootThreadId: String
    let isSubagent: Bool
    let isSidechat: Bool
    let activity: ManagedChatActivity
    let trustProjection: CodexThreadTrustProjection
    /// Optional Harvis-only grouping override. It never replaces `cwd` for
    /// opening, dispatch, permissions, task evidence, or provider identity.
    var managementProjectAssignment: ManagedChatProjectAssignment? = nil

    var id: String {
        "\(provider.rawValue)::\(sourceScope)::\(sourceID)"
    }
    var capabilities: ManagedChatCapabilities { provider.capabilities }
    var isCodex: Bool { provider == .codex }
    var isDsh: Bool { provider == .dsh }
    var isWorkBuddy: Bool { provider == .workBuddy }
    var isCardRunning: Bool { running }
    var cardActivity: ManagedChatActivity { activity }

    var agentDisplayName: String {
        nonempty(agentNickname) ?? provider.label
    }

    var agentIdentityLabel: String {
        "\(agentDisplayName) · SUBAGENT"
    }

    var agentTaskLabel: String? {
        if let role = nonempty(agentRole) {
            return role
        }
        guard let path = nonempty(agentPath) else { return nil }
        return path.split(separator: "/").last.map(String.init)
    }

    var updatedLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
            relativeTo: Date()
        )
    }

    var tokenLabel: String {
        guard tokensUsed >= 0 else { return "—" }
        let value = Double(max(tokensUsed, 0))
        if value >= 1_000_000 {
            return String(format: "%.1fM tok", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK tok", value / 1_000)
        }
        return "\(tokensUsed) tok"
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
