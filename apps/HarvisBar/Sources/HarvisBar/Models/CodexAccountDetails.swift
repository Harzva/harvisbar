import Foundation

struct CodexAccountActionFeedback: Equatable {
    let message: String
    let isError: Bool
}

enum CodexAccountDetailAction: String {
    case refreshQuota
    case openCLI
    case openDesktop
}

struct CodexAccountIdentity: Equatable {
    let id: String
    let path: String
    let accountKey: String?
    let quotaMode: String?

    init(_ home: CodexHome) {
        id = home.id
        path = home.path
        accountKey = home.accountKey
        quotaMode = home.quotaMode
    }
}

struct CodexAccountQuotaLine: Identifiable {
    let id: String
    let title: String
    let window: CodexQuotaWindow
}

/// A read-only, account-bound projection. It never falls back to the selected
/// management account when quota or identity information is unavailable.
struct CodexAccountDetails: Identifiable {
    let home: CodexHome
    let workspacePath: String
    let threadCount: Int
    let quota: CodexHomeQuota?
    let quotaError: String?
    let quotaUpdatedAt: Date?
    let isQuotaLoading: Bool
    let isActionRunning: Bool
    let actionFeedback: CodexAccountActionFeedback?
    let observedAt: Date

    var id: String { home.id }

    init(
        home: CodexHome, workspacePath: String, threadCount: Int,
        quota: CodexHomeQuota?, quotaError: String?, quotaUpdatedAt: Date?,
        isQuotaLoading: Bool, isActionRunning: Bool,
        actionFeedback: CodexAccountActionFeedback? = nil, observedAt: Date = Date()
    ) {
        self.home = home
        self.workspacePath = workspacePath
        self.threadCount = threadCount
        let matches = !home.isCustomModelHome && quota?.homeId == home.id && quota?.ok == true
        self.quota = matches ? quota : nil
        self.quotaError = quota != nil && !matches ? "额度数据与此账号不匹配，请刷新。" : quotaError
        self.quotaUpdatedAt = matches ? quotaUpdatedAt : nil
        self.isQuotaLoading = isQuotaLoading
        self.isActionRunning = isActionRunning
        self.actionFeedback = actionFeedback
        self.observedAt = observedAt
    }

    var quotaLines: [CodexAccountQuotaLine] {
        guard home.officialQuotaBlockedReason == nil,
              let quota, quota.available else { return [] }
        return quota.buckets.flatMap { bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { kind, window in
                guard let window else { return nil }
                return CodexAccountQuotaLine(
                    id: "\(bucket.limitId)/\(kind)",
                    title: "\(bucket.displayName) · \(window.durationLabel)", window: window
                )
            }
        }
    }

    var quotaNeedsRefresh: Bool {
        guard !quotaLines.isEmpty else { return false }
        guard let quotaUpdatedAt else { return true }
        if observedAt.timeIntervalSince(quotaUpdatedAt) >= 300 { return true }
        return quotaLines.contains { line in
            guard let reset = line.window.resetsAt, reset > 0 else { return false }
            let resetDate = Date(timeIntervalSince1970: TimeInterval(reset))
            return resetDate <= observedAt && resetDate > quotaUpdatedAt
        }
    }

    var quotaNotice: String? {
        if home.quotaMode == "missing-auth" { return "此账号尚未登录，登录后可读取额度。" }
        if let reason = home.officialQuotaBlockedReason { return reason }
        if let quotaError, !quotaError.isEmpty {
            let message = readableQuotaError(quotaError)
            return quotaLines.isEmpty ? message : "刷新失败，以下为缓存额度。\n\(message)"
        }
        if quotaNeedsRefresh { return "缓存额度可能已变化，可刷新确认。" }
        if quotaLines.isEmpty {
            return isQuotaLoading ? "正在读取此账号额度…" : "此账号暂未返回额度数据。"
        }
        return nil
    }

    var requiresLogin: Bool {
        guard !home.isCustomModelHome else { return false }
        guard let quotaError else { return home.isAuthInvalid }
        let message = quotaError.lowercased()
        return home.isAuthInvalid || message.contains("401") || message.contains("unauthorized")
    }

    var authenticationLabel: String {
        if home.isCustomModelHome { return home.authStatusLabel }
        if requiresLogin { return home.hasAuth ? "需要重新登录" : "未登录" }
        if quota?.available == true, quotaError == nil { return "登录可用" }
        if ["valid", "configured"].contains(home.normalizedAuthStatus) { return "已配置认证" }
        return home.authStatusLabel
    }

    private func readableQuotaError(_ error: String) -> String {
        let message = error.lowercased()
        if message.contains("401") || message.contains("unauthorized") {
            return "此账号登录已失效，请重新登录后刷新额度。"
        }
        if message.contains("403") || message.contains("forbidden") {
            return "此账号暂时无法访问额度，请检查账号权限后重试。"
        }
        if message.contains("429") || message.contains("too many requests") {
            return "额度请求过于频繁，请稍后刷新。"
        }
        if message.contains("timeout") || message.contains("timed out") || message.contains("超时") {
            return "额度请求超时，请稍后刷新。"
        }
        if message.contains("不匹配") { return "额度数据与此账号不匹配，请刷新。" }
        return "额度读取失败，请稍后刷新。"
    }

    var quotaUpdatedLabel: String {
        guard let quotaUpdatedAt else { return "尚未读取" }
        return "读取于 \(quotaUpdatedAt.formatted(date: .omitted, time: .shortened))"
    }

    var hoverSummary: String {
        var lines = [home.accountDisplayLabel, authenticationLabel]
        if let plan = quota?.planLabel { lines[1] += " · \(plan)" }
        if !quotaLines.isEmpty {
            lines += quotaLines.prefix(4).map { "\($0.title)：剩余 \($0.window.remainingPercent)%" }
            if quotaLines.count > 4 { lines.append("更多额度见账号详情") }
            lines.append(quotaUpdatedLabel + (quotaNeedsRefresh || quotaError != nil ? " · 缓存，建议刷新" : ""))
        } else if let notice = quotaNotice {
            lines.append(String(notice.prefix(180)))
        }
        lines.append("点击账号名查看详情、打开 CLI / Desktop；左侧勾选控制会话显示。")
        return lines.joined(separator: "\n")
    }
}
