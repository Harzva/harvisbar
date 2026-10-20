import SwiftUI

/// The checkmark controls visibility; the account name opens anchored details.
/// Keeping those actions separate avoids changing the chat list while inspecting.
struct ManagedCodexAccountChip: View {
    let account: ManagedChatDisplayAccount
    let details: CodexAccountDetails
    let isSelected: Bool
    @Binding var presentedHomeID: String?
    let onToggle: () -> Void
    let onOpen: (CodexHome) -> Void
    let onAction: (CodexAccountDetailAction, CodexHome) -> Void
    let theme: HarvisTheme

    private var showsDetails: Binding<Bool> {
        Binding(
            get: { presentedHomeID == account.sourceScope },
            set: { showing in
                if showing { presentedHomeID = account.sourceScope }
                else if presentedHomeID == account.sourceScope { presentedHomeID = nil }
            }
        )
    }

    private var accountSummary: String {
        [details.connectionSummary, details.creditsSummary]
            .compactMap { $0 }
            .joined(separator: "；")
    }

    var body: some View {
        HStack(spacing: 1) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .harvisFont(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-manager.account.\(account.id)")
            .accessibilityLabel("显示 \(details.home.accountDisplayLabel) 的会话")
            .accessibilityValue(isSelected ? "已选择" : "未选择")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(isSelected ? "隐藏此账号的会话" : "显示此账号的会话")

            Button {
                presentedHomeID = account.sourceScope
                onOpen(details.home)
            } label: {
                HStack(spacing: 5) {
                    Text(account.label)
                        .harvisFont(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("\(max(account.threadCount, 0))")
                        .harvisFont(.system(size: 11, weight: .semibold).monospacedDigit())
                    Image(systemName: "chevron.down")
                        .harvisFont(.system(size: 7, weight: .semibold))
                        .opacity(0.72)
                }
                .padding(.trailing, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-manager.account.\(account.id).details")
            .accessibilityLabel("\(details.home.accountDisplayLabel) 的账号详情")
            .accessibilityValue(accountSummary)
            .help(details.hoverSummary)
            .popover(isPresented: showsDetails, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                CodexAccountDetailsPopover(
                    details: details,
                    onAction: { onAction($0, details.home) },
                    onClose: { presentedHomeID = nil },
                    theme: theme
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundColor(isSelected ? theme.positive : theme.muted)
        .background(isSelected ? theme.positive.opacity(0.12) : theme.surfaceAlt.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(
            presentedHomeID == account.sourceScope ? theme.accent :
                (isSelected ? theme.positive.opacity(0.72) : theme.line.opacity(0.58)),
            lineWidth: isSelected || presentedHomeID == account.sourceScope ? 1.2 : 1
        ))
        .onDisappear {
            if presentedHomeID == account.sourceScope { presentedHomeID = nil }
        }
        .onChange(of: CodexAccountIdentity(details.home)) { _ in
            if presentedHomeID == account.sourceScope { presentedHomeID = nil }
        }
    }
}
