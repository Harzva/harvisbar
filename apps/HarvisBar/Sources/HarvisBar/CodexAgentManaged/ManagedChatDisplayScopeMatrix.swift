import SwiftUI

/// One row per agent, with its account/configuration choices alongside it.
struct ManagedChatDisplayScopeMatrix: View {
    @Environment(\.harvisTextSize) private var textSize
    @Binding var selection: ManagedChatDisplayScope
    let accounts: [ManagedChatDisplayAccount]
    let onSaveDefault: () -> Void
    let onRestoreDefault: () -> Void
    let theme: HarvisTheme
    var codexDetails: [String: CodexAccountDetails] = [:]
    var onOpenCodexDetails: (CodexHome) -> Void = { _ in }
    var onCodexAction: (CodexAccountDetailAction, CodexHome) -> Void = { _, _ in }
    @State private var presentedCodexHomeID: String?

    private var providerColumnWidth: CGFloat { 112 * (textSize?.layoutScale ?? 1) }
    private var rowHeight: CGFloat { 32 * (textSize?.layoutScale ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ManagedChatProvider.allCases) { provider in
                providerRow(provider)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("智能体与账号显示范围")
        .accessibilityValue(selection.label)
    }

    private func providerRow(_ provider: ManagedChatProvider) -> some View {
        let providerAccounts = accounts.filter { $0.provider == provider }
        let availableIDs = Set(providerAccounts.map(\.sourceScope))
        let isSelected = selection.providers.contains(provider.rawValue)
        let count = providerAccounts.reduce(0) { $0 + $1.threadCount }

        return HStack(alignment: .center, spacing: 7) {
            choiceChip(
                title: provider.label, systemImage: provider.systemImage,
                count: count, isSelected: isSelected,
                identifier: "chat-manager.provider.\(provider.rawValue)",
                accessibilityLabel: "\(provider.label) 智能体",
                help: "\(provider.label)：\(count) 个会话；勾选后展开\(sourceLabel(provider))"
            ) {
                selection.toggleProvider(provider)
            }
            // Align the account rows while leaving the button itself intrinsic.
            .frame(width: providerColumnWidth, alignment: .leading)

            Text(":")
                .harvisFont(.caption.weight(.semibold))
                .foregroundColor(theme.muted)
                .accessibilityHidden(true)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    if !isSelected {
                        hint("勾选后展开\(sourceLabel(provider))")
                    } else if providerAccounts.isEmpty {
                        hint("尚未发现\(sourceLabel(provider))")
                    } else {
                        ForEach(providerAccounts) { account in
                            accountChip(account, availableIDs: availableIDs)
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
            .help("\(provider.label) \(sourceLabel(provider))；较多时可左右滚动")

            HStack(spacing: 5) {
                rowAction("全选", provider: provider, actionID: "all") {
                    selection.setAllAccounts(provider: provider)
                }
                rowAction("清空", provider: provider, actionID: "clear") {
                    selection.clearAccounts(provider: provider)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!isSelected || providerAccounts.isEmpty)
            .opacity(isSelected && !providerAccounts.isEmpty ? 1 : 0.4)

            if provider == .codex {
                defaultsMenu.frame(width: 28)
            } else {
                Color.clear.frame(width: 28, height: 26)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: rowHeight)
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.line.opacity(0.46))
                .frame(height: 1)
                .padding(.leading, providerColumnWidth + 7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-manager.scope-row.\(provider.rawValue)")
    }

    @ViewBuilder
    private func accountChip(_ account: ManagedChatDisplayAccount, availableIDs: Set<String>) -> some View {
        if account.provider == .codex, let details = codexDetails[account.sourceScope] {
            ManagedCodexAccountChip(
                account: account, details: details,
                isSelected: selection.includesAccount(account.sourceScope, provider: .codex),
                presentedHomeID: $presentedCodexHomeID,
                onToggle: { selection.toggleAccount(account.sourceScope, provider: .codex, availableIDs: availableIDs) },
                onOpen: onOpenCodexDetails, onAction: onCodexAction, theme: theme
            )
        } else {
            choiceChip(
            title: account.label, systemImage: "circle",
            count: account.threadCount,
            isSelected: selection.includesAccount(account.sourceScope, provider: account.provider),
            identifier: "chat-manager.account.\(account.id)",
            accessibilityLabel: "\(account.provider.label) · \(account.detail)",
            help: "\(account.provider.label) · \(account.label)\n\(account.detail)"
            ) {
                selection.toggleAccount(account.sourceScope, provider: account.provider, availableIDs: availableIDs)
            }
        }
    }

    private func choiceChip(
        title: String, systemImage: String, count: Int, isSelected: Bool,
        identifier: String, accessibilityLabel: String, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : systemImage)
                    .harvisFont(.system(size: 11, weight: .semibold))
                Text(title)
                    .harvisFont(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Text("\(max(count, 0))")
                    .harvisFont(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundColor(isSelected ? theme.positive : theme.muted)
            }
            .foregroundColor(isSelected ? theme.positive : theme.muted)
            .padding(.horizontal, 8)
            .frame(height: 28 * (textSize?.layoutScale ?? 1))
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? theme.positive.opacity(0.12) : theme.surfaceAlt.opacity(0.58))
            )
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                isSelected ? theme.positive.opacity(0.72) : theme.line.opacity(0.58),
                lineWidth: isSelected ? 1.2 : 1
            ))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(isSelected ? "已选择" : "未选择")，\(max(count, 0)) 个会话")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help)
    }

    private func rowAction(
        _ title: String, provider: ManagedChatProvider, actionID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .harvisFont(.caption2)
            .foregroundColor(theme.muted)
            .padding(.horizontal, 6)
            .frame(height: 24 * (textSize?.layoutScale ?? 1))
            .contentShape(Rectangle())
            .accessibilityIdentifier("chat-manager.accounts.\(provider.rawValue).\(actionID)")
            .accessibilityLabel("\(title) \(provider.label) \(sourceLabel(provider))")
    }

    private func hint(_ message: String) -> some View {
        Text(message)
            .harvisFont(.caption)
            .foregroundColor(theme.muted)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func sourceLabel(_ provider: ManagedChatProvider) -> String {
        switch provider {
        case .codex: return "账号"
        case .dsh: return "配置"
        case .workBuddy: return "本地会话来源"
        }
    }

    private var defaultsMenu: some View {
        Menu {
            Button("显示全部智能体和账号") { selection = .all }
            Button("选择全部智能体") {
                selection.providers = Set(ManagedChatProvider.allCases.map(\.rawValue))
            }
            Button("清空智能体选择") { selection.providers.removeAll() }
            Divider()
            Button("将当前选择设为默认", action: onSaveDefault)
            Button("恢复默认选择", action: onRestoreDefault)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundColor(theme.muted)
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("chat-manager.display-scope.defaults")
        .accessibilityLabel("显示范围默认设置")
        .help("显示范围自动记住；也可以保存或恢复默认选择")
    }
}
