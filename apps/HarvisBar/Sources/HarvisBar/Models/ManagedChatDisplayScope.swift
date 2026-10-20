import Foundation

/// Display selection is independent of the account used by management actions.
/// nil accounts means all accounts, while an empty set deliberately shows none.
struct ManagedChatDisplayScope: Codable, Equatable {
    static let selectionKey = "harvis.chatManager.displayScope.v1"
    static let defaultKey = "harvis.chatManager.defaultDisplayScope.v1"
    static let all = ManagedChatDisplayScope()

    var providers: Set<String> = Set(ManagedChatProvider.allCases.map(\.rawValue))
    var codexHomeIDs: Set<String>? = nil
    /// Provider-local source scopes. Missing entries retain the legacy “all”
    /// behavior; an explicit empty set deliberately selects no accounts.
    var accountScopeIDsByProvider: [String: Set<String>]? = nil

    func includes(_ thread: ManagedChatThread) -> Bool {
        providers.contains(thread.provider.rawValue)
            && includesAccount(thread.sourceScope, provider: thread.provider)
    }

    func includesHome(_ id: String) -> Bool {
        includesAccount(id, provider: .codex)
    }

    func includesAccount(_ id: String, provider: ManagedChatProvider) -> Bool {
        if provider == .codex { return codexHomeIDs?.contains(id) ?? true }
        return accountScopeIDsByProvider?[provider.rawValue]?.contains(id) ?? true
    }

    mutating func toggleProvider(_ provider: ManagedChatProvider) {
        if !providers.insert(provider.rawValue).inserted {
            providers.remove(provider.rawValue)
        }
    }

    mutating func toggleHome(_ id: String, availableIDs: Set<String>) {
        toggleAccount(id, provider: .codex, availableIDs: availableIDs)
    }

    mutating func toggleAccount(_ id: String, provider: ManagedChatProvider, availableIDs: Set<String>) {
        var selected = provider == .codex
            ? (codexHomeIDs ?? availableIDs)
            : (accountScopeIDsByProvider?[provider.rawValue] ?? availableIDs)
        if !selected.insert(id).inserted { selected.remove(id) }
        if provider == .codex {
            codexHomeIDs = selected
        } else {
            var accounts = accountScopeIDsByProvider ?? [:]
            accounts[provider.rawValue] = selected
            accountScopeIDsByProvider = accounts
        }
    }

    mutating func setAllAccounts(provider: ManagedChatProvider) {
        if provider == .codex {
            codexHomeIDs = nil
        } else {
            accountScopeIDsByProvider?.removeValue(forKey: provider.rawValue)
            if accountScopeIDsByProvider?.isEmpty == true { accountScopeIDsByProvider = nil }
        }
    }

    mutating func clearAccounts(provider: ManagedChatProvider) {
        if provider == .codex {
            codexHomeIDs = []
        } else {
            var accounts = accountScopeIDsByProvider ?? [:]
            accounts[provider.rawValue] = []
            accountScopeIDsByProvider = accounts
        }
    }

    static func decode(_ raw: String) -> Self {
        guard let data = raw.data(using: .utf8),
              let scope = try? JSONDecoder().decode(Self.self, from: data) else { return .all }
        return scope
    }

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8) else { return "" }
        return result
    }

    var label: String {
        if self == .all { return "全部智能体 · 全部账号" }
        let names = ManagedChatProvider.allCases.filter { providers.contains($0.rawValue) }.map(\.label)
        guard !names.isEmpty else { return "未选择智能体" }
        let agents = names.joined(separator: " + ")
        let accountLabels = ManagedChatProvider.allCases.compactMap { provider -> String? in
            guard providers.contains(provider.rawValue) else { return nil }
            let ids = provider == .codex ? codexHomeIDs : accountScopeIDsByProvider?[provider.rawValue]
            return ids.map { "\($0.count) 个 \(provider.label) 账号/来源" }
        }
        return ([agents] + accountLabels).joined(separator: " · ")
    }
}
