import Foundation

/// An account or local conversation source that the existing adapters can
/// actually distinguish. DSH profiles and WorkBuddy's local store are not
/// presented as authenticated identities.
struct ManagedChatDisplayAccount: Identifiable {
    let provider: ManagedChatProvider
    let sourceScope: String
    let label: String
    let detail: String
    let threadCount: Int

    var id: String { "\(provider.rawValue)::\(sourceScope)" }

    static func catalog(
        homes: [CodexHome],
        dshEndpoints: [DshRuntimeEndpoint],
        threads: [ManagedChatThread]
    ) -> [Self] {
        let counts = Dictionary(grouping: threads) { "\($0.provider.rawValue)::\($0.sourceScope)" }
            .mapValues(\.count)
        let shortLabels = Dictionary(grouping: homes, by: compactCodexLabel)
        var accounts = homes.map { home in
            let shortLabel = compactCodexLabel(home)
            let peers = (shortLabels[shortLabel] ?? []).sorted { $0.id < $1.id }
            let ordinal = peers.firstIndex { $0.id == home.id }.map { $0 + 1 } ?? 1
            let label = peers.count > 1 ? "\(shortLabel) · \(ordinal)" : shortLabel
            let detail = peers.count > 1
                ? "\(home.accountDisplayLabel)\n来源：\(home.label)"
                : home.accountDisplayLabel
            return Self(provider: .codex, sourceScope: home.id,
                        label: label, detail: detail,
                        threadCount: counts["codex::\(home.id)", default: 0])
        }
        var knownIDs = Set(accounts.map(\.id))
        // Keep running sources visible even before their first conversation.
        for endpoint in dshEndpoints {
            let id = "dsh::\(endpoint.sourceScope)"
            guard knownIDs.insert(id).inserted else { continue }
            let label = "\(endpoint.homeID) / \(endpoint.profile)"
            accounts.append(Self(provider: .dsh, sourceScope: endpoint.sourceScope,
                                 label: label, detail: "DSH 本地配置 · \(label)",
                                 threadCount: counts[id, default: 0]))
        }
        // Retain cached and disconnected sources, using the same identity as
        // the cards. Never collapse distinct profiles or provider namespaces.
        for thread in threads where thread.provider != .codex {
            let id = "\(thread.provider.rawValue)::\(thread.sourceScope)"
            guard knownIDs.insert(id).inserted else { continue }
            let label: String
            if thread.provider == .workBuddy && thread.sourceScope == ManagedChatSourceScope.workBuddyLocal {
                label = "本地会话"
            } else if thread.provider == .dsh && thread.sourceScope.hasPrefix("dsh::") {
                label = thread.sourceScope.components(separatedBy: "::").dropFirst().joined(separator: " / ")
            } else {
                label = thread.sourceScope
            }
            accounts.append(Self(provider: thread.provider, sourceScope: thread.sourceScope,
                                 label: label.isEmpty ? "本地会话" : label,
                                 detail: "\(thread.provider.label) 本地会话来源",
                                 threadCount: counts[id, default: 0]))
        }
        return accounts.sorted {
            if $0.provider != $1.provider {
                return ManagedChatProvider.allCases.firstIndex(of: $0.provider)!
                    < ManagedChatProvider.allCases.firstIndex(of: $1.provider)!
            }
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func compactCodexLabel(_ home: CodexHome) -> String {
        // A short numeric note is often the user's own recognizable account
        // shorthand. Otherwise prefer the actual account over a workspace alias.
        if let note = home.accountDisplayNote, note.count <= 6, note.allSatisfy(\.isNumber) {
            return note
        }
        if let email = home.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
           let name = email.split(separator: "@").first, !name.isEmpty {
            return abbreviated(String(name))
        }
        return abbreviated(home.accountDisplayNote ?? home.accountDisplayLabel)
    }

    private static func abbreviated(_ value: String) -> String {
        guard value.count > 10 else { return value }
        if value.allSatisfy(\.isNumber) {
            return "\(value.prefix(3))…\(value.suffix(4))"
        }
        return "\(value.prefix(6))…\(value.suffix(2))"
    }
}
