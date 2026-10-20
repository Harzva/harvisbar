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
    let providerID: String?
    let endpointHost: String?
    let billingIdentity: [String]

    init(_ home: CodexHome) {
        id = home.id
        path = home.path
        accountKey = home.accountKey
        quotaMode = home.quotaMode
        providerID = home.providerId ?? home.provider
        endpointHost = home.endpointHost
        billingIdentity = (home.connections ?? []).map {
            [$0.id, $0.providerId ?? "", $0.endpointHost ?? "", $0.accessMode, $0.billingMode].joined(separator: "\u{1f}")
        }.sorted()
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
    let billing: CodexHomeBilling?
    let billingError: String?
    let isBillingLoading: Bool
    let observedAt: Date

    var id: String { home.id }

    init(
        home: CodexHome, workspacePath: String, threadCount: Int,
        quota: CodexHomeQuota?, quotaError: String?, quotaUpdatedAt: Date?,
        isQuotaLoading: Bool, isActionRunning: Bool,
        actionFeedback: CodexAccountActionFeedback? = nil,
        billing: CodexHomeBilling? = nil, billingError: String? = nil,
        isBillingLoading: Bool = false, observedAt: Date = Date()
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
        let billingMatches = billing?.ok == true && billing?.homeId == home.id
        self.billing = billingMatches ? billing : nil
        self.billingError = billing != nil && !billingMatches ? "用量数据与此账号不匹配，请刷新。" : billingError
        self.isBillingLoading = isBillingLoading
        self.observedAt = observedAt
    }

    var configuredModels: [CodexConfiguredModel] {
        if let models = home.configuredModels, !models.isEmpty { return models }
        guard let model = home.model, !model.isEmpty else { return [] }
        return [CodexConfiguredModel(id: model, displayName: model, providerId: home.providerId ?? home.provider, source: "configured")]
    }

    private var configuredConnections: [CodexBillingConnection] {
        if let connections = home.connections, !connections.isEmpty { return connections }
        let usesChatGPT = !home.isCustomModelHome
        return [CodexBillingConnection(
            id: home.providerId ?? home.provider ?? "current", name: usesChatGPT ? "OpenAI / ChatGPT" : home.provider ?? "自定义 API",
            providerId: home.providerId ?? home.provider, endpointHost: home.endpointHost,
            modelIds: configuredModels.map(\.id), accessMode: usesChatGPT ? "chatgpt" : "api",
            billingMode: home.isSubscriptionHome ? "subscription" : "unknown", planName: quota?.planLabel,
            billingPeriod: nil, allowances: [], balances: []
        )]
    }

    var billingConnections: [CodexAccountBillingConnection] {
        configuredConnections.map { configuration in
            CodexAccountBillingConnection(
                configuration: configuration,
                usage: billing?.connections.first(where: { $0.id == configuration.id }),
                models: configuredModels, observedAt: observedAt, refreshFailed: billingError != nil
            )
        }
    }

    var canRefreshUsage: Bool {
        home.officialQuotaBlockedReason == nil || configuredConnections.contains { $0.accessMode == "api" }
    }

    var isUsageLoading: Bool { isQuotaLoading || isBillingLoading }

    var connectionSummary: String {
        "\(configuredConnections.count) 个服务 · \(configuredModels.count) 个模型选项"
    }

    var billingNotice: String? {
        if billingError != nil { return "用量刷新失败，保留上次读取的数据。" }
        if isBillingLoading { return "正在读取服务用量…" }
        return nil
    }

    var creditLines: [CodexAccountCreditLine] {
        guard home.officialQuotaBlockedReason == nil,
              let quota, quota.available else { return [] }
        var seen: Set<String> = []
        return quota.buckets.compactMap { bucket in
            guard let credits = bucket.credits,
                  credits.validatedBalance != nil || credits.hasCredits != nil || credits.unlimited != nil else { return nil }
            let identity = [credits.validatedBalance ?? "?", credits.hasCredits.map(String.init) ?? "?", credits.unlimited.map(String.init) ?? "?"].joined(separator: "/")
            guard seen.insert(identity).inserted else { return nil }
            return CodexAccountCreditLine(
                id: bucket.limitId, title: bucket.displayName, snapshot: credits,
                sourceLabel: "官方账号 · \(quotaUpdatedLabel)"
            )
        }
    }

    var creditsNotice: String? {
        guard !home.isCustomModelHome else { return "API 余额与套餐额度按服务分别显示。" }
        if !creditLines.isEmpty {
            if quotaError != nil { return "以下为缓存 Credits，刷新失败。" }
            if quotaNeedsRefresh { return "缓存 Credits 可能已变化，可刷新确认。" }
            return nil
        }
        if isQuotaLoading { return "正在读取此账号 Credits…" }
        if requiresLogin { return "登录此账号后可读取 Credits。" }
        if quotaError != nil { return "Credits 读取失败，请刷新重试。" }
        return "服务暂未返回此账号的 Credits 余额。"
    }

    var creditsSummary: String? {
        guard !home.isCustomModelHome else { return nil }
        return creditLines.first?.valueLabel ?? "Credits 未提供"
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
        guard !quotaLines.isEmpty || !creditLines.isEmpty else { return false }
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
        lines.append(connectionSummary)
        if !quotaLines.isEmpty {
            lines += quotaLines.prefix(4).map { "\($0.title)：剩余 \($0.window.remainingPercent)%" }
            if quotaLines.count > 4 { lines.append("更多额度见账号详情") }
            lines.append(quotaUpdatedLabel + (quotaNeedsRefresh || quotaError != nil ? " · 缓存，建议刷新" : ""))
        } else if let notice = quotaNotice {
            lines.append(String(notice.prefix(180)))
        }
        if let creditsSummary { lines.append(creditsSummary) }
        lines.append("点击账号名查看详情、打开 CLI / Desktop；左侧勾选控制会话显示。")
        return lines.joined(separator: "\n")
    }
}
