import Foundation

struct CodexArchiveResult: Decodable {
    let ok: Bool
    let action: String?
    let matched: Int
    let archived: Int
    let failed: Int
    let error: String?

    var summary: String {
        if matched == 0 {
            return "没有需要归档的定时任务对话。"
        }
        if failed > 0 {
            return "已归档 \(archived) 条，失败 \(failed) 条。"
        }
        return "已归档 \(archived) 条定时任务对话。"
    }

    var compactSummary: String {
        failed > 0 ? "\(archived) ok · \(failed) failed" : "\(archived) archived"
    }
}

struct CodexHomeList: Decodable {
    let ok: Bool
    let schemaVersion: String?
    let items: [CodexHome]
    let warnings: [String]
}

struct CodexHome: Decodable, Identifiable {
    let id: String
    let label: String
    let accountNote: String?
    let path: String
    let source: String
    let model: String?
    let provider: String?
    let endpointHost: String?
    let hasAuth: Bool
    let accountEmail: String?
    let authStatus: String?
    let authExpiresAt: Int64?
    let authNote: String?
    let hasConfig: Bool
    let skillCount: Int
    let quotaMode: String?
    let quotaNote: String?
    let providerId: String?
    let configuredModels: [CodexConfiguredModel]?
    let connections: [CodexBillingConnection]?

    init(
        id: String, label: String, accountNote: String?, path: String, source: String,
        model: String?, provider: String?, endpointHost: String?, hasAuth: Bool,
        accountEmail: String?, authStatus: String?, authExpiresAt: Int64?, authNote: String?,
        hasConfig: Bool, skillCount: Int, quotaMode: String?, quotaNote: String?,
        providerId: String? = nil, configuredModels: [CodexConfiguredModel]? = nil,
        connections: [CodexBillingConnection]? = nil
    ) {
        self.id = id
        self.label = label
        self.accountNote = accountNote
        self.path = path
        self.source = source
        self.model = model
        self.provider = provider
        self.endpointHost = endpointHost
        self.hasAuth = hasAuth
        self.accountEmail = accountEmail
        self.authStatus = authStatus
        self.authExpiresAt = authExpiresAt
        self.authNote = authNote
        self.hasConfig = hasConfig
        self.skillCount = skillCount
        self.quotaMode = quotaMode
        self.quotaNote = quotaNote
        self.providerId = providerId
        self.configuredModels = configuredModels
        self.connections = connections
    }

    var detailSummary: String {
        [provider, model, endpointHost, "\(skillCount) skills"]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    var capabilitySummary: String {
        let values = [hasAuth ? "auth" : nil, hasConfig ? "config" : nil].compactMap { $0 }
        return values.isEmpty ? source : "\(source) · \(values.joined(separator: "+"))"
    }

    var normalizedAuthStatus: String {
        authStatus ?? (hasAuth ? "unknown" : "missing")
    }

    var accountDisplayLabel: String {
        let note = accountDisplayNote
        if isCustomModelHome {
            return [note, model, provider, label]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? label
        }
        let email = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note, !note.isEmpty,
           let email, !email.isEmpty,
           note.caseInsensitiveCompare(email) != .orderedSame {
            return "\(note) · \(email)"
        }
        if let email, !email.isEmpty {
            return email
        }
        if let note, !note.isEmpty {
            return note
        }
        return label
    }

    var accountDisplayNote: String? {
        let explicit = accountNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return explicit
        }

        // Older HarvisRuntime builds expose a managed account's saved note
        // through `label` but do not yet project the separate `accountNote`
        // field. Keep the UI compatible without mistaking generated labels
        // such as "Managed · codex-current" for user-authored notes.
        let fallback = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else { return nil }
        switch source {
        case "managed-agent":
            return fallback.hasPrefix("Managed · ") ? nil : fallback
        case "default":
            return fallback == "Default Codex" ? nil : fallback
        case "environment":
            return fallback == "Environment Codex" ? nil : fallback
        default:
            return nil
        }
    }

    var accountKey: String? {
        accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var accountGroupingKey: String {
        if isDirectEmailAccount, let accountKey {
            return "email:\(accountKey)"
        }
        return "home:\(id)"
    }

    var isDirectEmailAccount: Bool {
        accountKey != nil && !isCustomModelHome
    }

    var isCustomModelHome: Bool {
        quotaMode == "proxy" || quotaMode == "api-key"
    }

    /// A remembered account stays visible even when its auth is expired,
    /// missing, or temporarily unreadable. Auth state controls the badge and
    /// relogin action. Custom providers use their own credentials and remain
    /// visible when configured without a ChatGPT login.
    var isCodexAccountCandidate: Bool {
        return accountKey != nil
            || accountDisplayNote != nil
            || hasAuth
            || ["default", "environment", "managed-agent"].contains(source)
            || (isCustomModelHome && hasConfig)
    }

    var authStatusLabel: String {
        if isCustomModelHome { return "API 凭据待验证" }
        switch normalizedAuthStatus {
        case "valid": return "Auth 有效"
        case "configured": return "Auth 已配置"
        case "refresh-needed": return "Auth 待刷新"
        case "expired": return "Auth 已过期"
        case "invalid": return "Auth 无效"
        case "missing": return "未登录"
        default: return "Auth 待验证"
        }
    }

    var authSystemImage: String {
        if isCustomModelHome { return "key.horizontal" }
        switch normalizedAuthStatus {
        case "valid", "configured": return "checkmark.shield.fill"
        case "refresh-needed": return "arrow.clockwise.circle.fill"
        case "expired", "invalid": return "exclamationmark.shield.fill"
        case "missing": return "person.crop.circle.badge.exclamationmark"
        default: return "questionmark.diamond.fill"
        }
    }

    var isAuthInvalid: Bool {
        !isCustomModelHome && ["expired", "invalid", "missing"].contains(normalizedAuthStatus)
    }

    var authExpirationLabel: String? {
        guard !isCustomModelHome else { return nil }
        guard let authExpiresAt, authExpiresAt > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(authExpiresAt)))
    }

    var compactAuthExpirationLabel: String? {
        guard !isCustomModelHome else { return nil }
        guard let authExpiresAt, authExpiresAt > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(authExpiresAt)))
    }

    var authMenuSummary: String {
        if let compactAuthExpirationLabel {
            return "\(authStatusLabel) · \(compactAuthExpirationLabel)"
        }
        return authStatusLabel
    }

    var isSubscriptionHome: Bool {
        quotaMode == "subscription"
    }

    var officialQuotaBlockedReason: String? {
        switch quotaMode {
        case "proxy":
            return "使用自定义模型，不适用 ChatGPT 订阅额度。"
        case "api-key":
            return "使用 API Key，不适用 ChatGPT 订阅额度。"
        case "missing-auth":
            return quotaNote ?? "此 Home 尚未完成独立 ChatGPT 登录。"
        default:
            return nil
        }
    }

    var quotaMenuLabel: String? {
        switch quotaMode {
        case "proxy": "自定义模型"
        case "api-key": "API Key"
        case "missing-auth": "未登录"
        default: nil
        }
    }
}

struct CodexHomeQuota: Decodable {
    let ok: Bool
    let schemaVersion: String?
    let homeId: String
    let available: Bool
    let planType: String?
    let buckets: [CodexQuotaBucket]
    let error: String?

    var compactSummary: String {
        guard available,
              let window = buckets.first?.primary ?? buckets.first?.secondary else {
            return "额度不可用"
        }
        return "剩余 \(window.remainingPercent)%"
    }

    var planLabel: String? {
        guard let planType, !planType.isEmpty, planType != "unknown" else { return nil }
        return planType.replacingOccurrences(of: "_", with: " ").uppercased()
    }
}

struct CodexQuotaBucket: Decodable, Identifiable {
    let limitId: String
    let limitName: String?
    let planType: String?
    let primary: CodexQuotaWindow?
    let secondary: CodexQuotaWindow?
    let credits: CodexCreditsSnapshot?

    init(
        limitId: String, limitName: String?, planType: String?, primary: CodexQuotaWindow?,
        secondary: CodexQuotaWindow?, credits: CodexCreditsSnapshot? = nil
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
    }

    var id: String { limitId }

    var displayName: String {
        if let limitName, !limitName.isEmpty {
            return limitName
        }
        return limitId == "codex" ? "Codex" : limitId
    }
}

struct CodexQuotaWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var durationLabel: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "额度周期" }
        if minutes % (24 * 60) == 0 {
            return "\(minutes / (24 * 60))天"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)小时"
        }
        return "\(minutes)分钟"
    }

    var resetLabel: String? {
        guard let resetsAt, resetsAt > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return "重置 \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(resetsAt))))"
    }
}

struct CodexThreadList: Decodable {
    let ok: Bool
    let schemaVersion: String?
    let home: String
    let items: [CodexThreadSummary]
}

struct CodexThreadSummary: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let titleSource: String?
    let hasMeaningfulTitle: Bool?
    let createdAt: Int64
    let updatedAt: Int64
    let tokensUsed: Int64
    let model: String?
    let cwd: String
    let archived: Bool
    let running: Bool
    let threadSource: String?
    let agentNickname: String?
    let agentRole: String?
    let agentPath: String?
    let parentThreadId: String?
    let agentDepth: Int?
    let rootThreadId: String?
    let familyActivity: CodexThreadFamilyActivity?

    var hasMeaningfulDisplayTitle: Bool {
        if let hasMeaningfulTitle {
            return hasMeaningfulTitle
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Untitled chat") != .orderedSame
    }

    var isSubagent: Bool {
        guard !isSidechat else { return false }
        return threadSource?.caseInsensitiveCompare("subagent") == .orderedSame
            || parentThreadId?.isEmpty == false
            || agentNickname?.isEmpty == false
    }

    var isSidechat: Bool {
        threadSource?.caseInsensitiveCompare("sidechat") == .orderedSame
    }

    var agentDisplayName: String {
        nonempty(agentNickname) ?? "Subagent"
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

    var runningFamilyActivity: CodexThreadFamilyActivity {
        familyActivity ?? CodexThreadFamilyActivity(
            main: running && !isSubagent && !isSidechat ? 1 : 0,
            subagent: running && isSubagent ? 1 : 0,
            sidechat: running && isSidechat ? 1 : nil,
            members: []
        )
    }

    var hasRunningFamily: Bool {
        runningFamilyActivity.total > 0
    }

    var cardActivity: CodexThreadFamilyActivity {
        guard isSubagent || isSidechat else { return runningFamilyActivity }
        guard running else {
            return CodexThreadFamilyActivity(
                main: 0,
                subagent: 0,
                sidechat: isSidechat ? 0 : nil,
                members: []
            )
        }
        let ownMember = runningFamilyActivity.members.filter { $0.id == id }
        return CodexThreadFamilyActivity(
            main: 0,
            subagent: isSubagent ? 1 : 0,
            sidechat: isSidechat ? 1 : nil,
            members: ownMember
        )
    }

    var isCardRunning: Bool {
        cardActivity.total > 0
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
        let value = Double(max(tokensUsed, 0))
        if value >= 1_000_000 {
            return String(format: "%.1fM tok", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK tok", value / 1_000)
        }
        return "\(tokensUsed) tok"
    }

    var trustProjection: CodexThreadTrustProjection {
        trustProjection(evidence: nil)
    }

    func trustProjection(evidence: CodexEvidenceSummary?) -> CodexThreadTrustProjection {
        if running {
            return CodexThreadTrustProjection(
                state: .running,
                reason: "A live Codex process is currently associated with this session."
            )
        }
        if let evidence {
            switch evidence.latestTurnState {
            case "failed":
                return CodexThreadTrustProjection(
                    state: .failed,
                    reason: evidence.reason
                )
            case "completed":
                return CodexThreadTrustProjection(
                    state: .completed,
                    reason: evidence.reason
                )
            case "running":
                return CodexThreadTrustProjection(
                    state: .incomplete,
                    reason: "The rollout contains turn_started without a later completion, but no live process is attached."
                )
            default:
                break
            }
        }
        if archived {
            return CodexThreadTrustProjection(
                state: .archived,
                reason: "The session index explicitly marks this chat as archived."
            )
        }

        let age = max(0, Date().timeIntervalSince1970 - TimeInterval(updatedAt))
        if age <= 10 * 60 {
            return CodexThreadTrustProjection(
                state: .recentlyActive,
                reason: "Updated \(updatedLabel), but no live Codex process is associated with it."
            )
        }
        if age >= 7 * 24 * 60 * 60 {
            return CodexThreadTrustProjection(
                state: .stale,
                reason: "No live process and no recorded update for at least seven days."
            )
        }
        return CodexThreadTrustProjection(
            state: .idle,
            reason: "No live Codex process is associated with it; last update was \(updatedLabel)."
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CodexThreadFamilyActivity: Codable, Sendable {
    let main: Int
    let subagent: Int
    let sidechat: Int?
    let members: [CodexRunningFamilyMember]

    var total: Int {
        main + subagent + (sidechat ?? 0)
    }
}

struct CodexRunningFamilyMember: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let title: String
    let agentNickname: String?
    let agentRole: String?
    let agentPath: String?
    let depth: Int?

    var displayName: String {
        if let agentNickname, !agentNickname.isEmpty {
            return agentNickname
        }
        if kind.caseInsensitiveCompare("main") == .orderedSame {
            return "Main task"
        }
        return kind.caseInsensitiveCompare("sidechat") == .orderedSame ? "Sidechat" : "Subagent"
    }

    var detail: String? {
        if let agentRole, !agentRole.isEmpty {
            return agentRole
        }
        guard let agentPath, !agentPath.isEmpty else { return nil }
        return agentPath.split(separator: "/").last.map(String.init)
    }
}

enum CodexThreadTrustState: String {
    case running = "Running"
    case completed = "Completed"
    case failed = "Failed"
    case incomplete = "Incomplete"
    case recentlyActive = "Recently Active"
    case idle = "Idle"
    case stale = "Stale"
    case archived = "Archived"

    var systemImage: String {
        switch self {
        case .running: return "bolt.fill"
        case .completed: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon.fill"
        case .incomplete: return "exclamationmark.circle.fill"
        case .recentlyActive: return "clock.badge.checkmark"
        case .idle: return "pause.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .archived: return "archivebox.fill"
        }
    }
}

struct CodexThreadTrustProjection {
    let state: CodexThreadTrustState
    let reason: String
}

struct CodexHomeLaunchResult: Decodable {
    let ok: Bool
    let action: String
    let homeId: String
    let userDataDir: String?
    let message: String
}
