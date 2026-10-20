import SwiftUI

/// Source-bound actions stay visible even when a card's input is collapsed.
/// Routing and draft ownership remain with the existing runtime parent.
struct ManagedCodexSessionActions: View {
    @Environment(\.harvisTextSize) private var textSize
    let thread: ManagedChatThread
    let theme: HarvisTheme
    let inputExpanded: Bool
    let isOpening: Bool
    let onToggleInput: () -> Void
    let onDesktop: () -> Void
    let onCLI: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            action("输入", icon: inputExpanded ? "text.bubble.fill" : "text.bubble",
                   selected: inputExpanded, perform: onToggleInput)
                .disabled(!thread.capabilities.supportsCodexDispatch)
                .accessibilityIdentifier("chat-manager.input.\(thread.id)")
                .accessibilityLabel("\(inputExpanded ? "收起" : "展开")此会话输入：\(thread.title)")
                .accessibilityValue(inputExpanded ? "已展开" : "已收起")
                .help(thread.capabilities.supportsCodexDispatch
                    ? "只切换此卡片的输入区，草稿会保留"
                    : "此会话当前不支持卡片发送")
            Spacer(minLength: 0)
            action("Desktop", icon: "macwindow", pending: isOpening, perform: onDesktop)
                .disabled(isOpening)
                .accessibilityIdentifier("chat-manager.open-desktop.\(thread.id)")
                .accessibilityLabel("在 Codex Desktop 中打开会话：\(thread.title)")
                .help("使用此卡片的来源账号，在 Codex Desktop 中打开对应会话")
            action("CLI", icon: "terminal", perform: onCLI)
                .disabled(isOpening)
                .accessibilityIdentifier("chat-manager.open-cli.\(thread.id)")
                .accessibilityLabel("在 Codex CLI 中继续会话：\(thread.title)")
                .help("使用此卡片的来源账号与项目目录，在终端继续对应会话")
        }
        .frame(height: CodexMatrixCardLayoutMetrics.actionSlotHeight * (textSize?.layoutScale ?? 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex 会话操作")
    }

    private func action(
        _ title: String,
        icon: String,
        selected: Bool = false,
        pending: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label {
                Text(title)
            } icon: {
                if pending {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: icon)
                }
            }
                .harvisFont(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7)
                .frame(height: CodexMatrixCardLayoutMetrics.actionSlotHeight * (textSize?.layoutScale ?? 1))
                .foregroundColor(selected ? theme.selectionText : theme.accent)
                .background(selected ? theme.selectionFill : theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? theme.selectionFill : theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
