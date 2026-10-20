import Foundation

struct CodexConfiguredModel: Decodable, Identifiable {
    let id: String
    let displayName: String
    let providerId: String?
    let source: String
}

struct CodexCreditsSnapshot: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?

    var validatedBalance: String? { CodexBillingAmount.decimal(balance) }

    var valueLabel: String {
        if unlimited == true { return "不限量 Credits" }
        if let amount = validatedBalance { return "\(amount) Credits" }
        if hasCredits == false { return "无可用 Credits" }
        if hasCredits == true { return "有可用 Credits，余额未提供" }
        return "Credits 未提供"
    }

    var isDepleted: Bool {
        if unlimited == true { return false }
        if let amount = validatedBalance, let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) {
            return value <= 0
        }
        return hasCredits == false
    }
}

enum CodexBillingAmount {
    static func decimal(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
              value.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    static func quantity(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }

    static func updatedLabel(_ timestamp: Int64?) -> String {
        guard let timestamp, timestamp > 0 else { return "尚未读取" }
        return "读取于 " + Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .omitted, time: .shortened)
    }
}

struct CodexBillingAllowance: Decodable, Identifiable {
    let id: String
    let label: String
    let remaining: Double?
    let used: Double?
    let limit: Double?
    let unit: String
    let resetsAt: Int64?
    let updatedAt: Int64?
    let source: String

    var summaryLabel: String {
        if let remaining, remaining.isFinite {
            let amount = CodexBillingAmount.quantity(remaining)
            if let limit, limit.isFinite { return "剩余 \(amount) / \(CodexBillingAmount.quantity(limit)) \(unit)" }
            return "剩余 \(amount) \(unit)"
        }
        if let used, used.isFinite {
            if let limit, limit.isFinite { return "已用 \(CodexBillingAmount.quantity(used)) / \(CodexBillingAmount.quantity(limit)) \(unit)" }
            return "已用 \(CodexBillingAmount.quantity(used)) \(unit)"
        }
        if let limit, limit.isFinite { return "总额度 \(CodexBillingAmount.quantity(limit)) \(unit)" }
        return "额度未提供"
    }

    var resetLabel: String {
        guard let resetsAt, resetsAt > 0 else { return "重置时间未提供" }
        return "重置 " + Date(timeIntervalSince1970: TimeInterval(resetsAt))
            .formatted(date: .abbreviated, time: .shortened)
    }

    var sourceLabel: String { source == "provider" ? "服务返回" : "本地配置" }
}

struct CodexBillingBalance: Decodable, Identifiable {
    let currency: String
    let amount: String
    let updatedAt: Int64?
    let source: String

    var id: String { currency }
    var summaryLabel: String {
        guard let amount = CodexBillingAmount.decimal(amount) else { return "余额未提供" }
        return "\(amount) \(currency)"
    }
    var sourceLabel: String { source == "provider" ? "服务返回" : "本地配置" }
}

struct CodexBillingConnection: Decodable, Identifiable {
    let id: String
    let name: String
    let providerId: String?
    let endpointHost: String?
    let modelIds: [String]
    let accessMode: String
    let billingMode: String
    let planName: String?
    let billingPeriod: String?
    let allowances: [CodexBillingAllowance]
    let balances: [CodexBillingBalance]

    var modeLabel: String {
        let access = accessMode == "chatgpt" ? "ChatGPT" : accessMode == "api" ? "API" : "接入方式未提供"
        let billing: String
        switch billingMode {
        case "usage": billing = "按量计费"
        case "subscription":
            billing = billingPeriod == "monthly" ? "包月订阅" : billingPeriod == "annual" ? "年订阅" : "订阅"
        default: billing = "计费方式未提供"
        }
        return "\(access) · \(billing)"
    }
}

struct CodexHomeBilling: Decodable {
    let ok: Bool
    let schemaVersion: String?
    let homeId: String
    let connections: [CodexConnectionUsageSnapshot]
}

struct CodexConnectionUsageSnapshot: Decodable, Identifiable {
    let id: String
    let available: Bool
    let status: String
    let serviceAvailable: Bool?
    let balances: [CodexBillingBalance]
    let allowances: [CodexBillingAllowance]
    let updatedAt: Int64
    let error: String?
}

struct CodexAccountCreditLine: Identifiable {
    let id: String
    let title: String
    let snapshot: CodexCreditsSnapshot
    let sourceLabel: String

    var valueLabel: String { snapshot.valueLabel }
    var isDepleted: Bool { snapshot.isDepleted }
}

struct CodexAccountBillingConnection: Identifiable {
    let configuration: CodexBillingConnection
    let usage: CodexConnectionUsageSnapshot?
    let models: [CodexConfiguredModel]
    let observedAt: Date
    let refreshFailed: Bool

    var id: String { configuration.id }
    var name: String { configuration.name }
    var modeLabel: String { configuration.modeLabel }
    var planLabel: String? { configuration.planName }
    var modelNames: [String] {
        configuration.modelIds.map { id in models.first(where: { $0.id == id })?.displayName ?? id }
    }
    var allowances: [CodexBillingAllowance] {
        if let usage, !usage.allowances.isEmpty { return usage.allowances }
        return configuration.allowances
    }
    var balances: [CodexBillingBalance] {
        if let usage, !usage.balances.isEmpty { return usage.balances }
        return configuration.balances
    }
    var updatedLabel: String { CodexBillingAmount.updatedLabel(usage?.updatedAt) }
    var isLive: Bool {
        guard let usage, usage.available, !refreshFailed else { return false }
        let age = observedAt.timeIntervalSince1970 - TimeInterval(usage.updatedAt)
        return age >= 0 && age < 300
    }
    var notice: String? {
        guard configuration.accessMode == "api" else { return nil }
        if usage?.status == "requires-authorization" { return "用量查询需额外只读授权；模型 API Key 不支持此查询。" }
        if refreshFailed { return balances.isEmpty && allowances.isEmpty ? "用量刷新失败，请稍后重试。" : "以下为缓存用量，刷新失败。" }
        if let usage, !usage.available {
            if usage.status == "not-configured" { return "尚未连接此服务的用量查询。" }
            return balances.isEmpty && allowances.isEmpty ? "服务暂未返回可用的用量数据。" : "以下为缓存用量，服务暂未返回新数据。"
        }
        if usage?.serviceAvailable == false { return "服务返回当前余额不足以调用。" }
        if let usage, !isLive, !usage.balances.isEmpty || !usage.allowances.isEmpty { return "缓存用量可能已变化，可刷新确认。" }
        if balances.isEmpty && allowances.isEmpty { return "额度和余额暂未提供。" }
        return nil
    }
}
