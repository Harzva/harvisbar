import SwiftUI

/// A compact, read-only account inspector. The owner supplies an account-bound
/// snapshot and handles every side effect through `onAction`.
struct CodexAccountDetailsPopover: View {
    let details: CodexAccountDetails
    let onAction: (CodexAccountDetailAction) -> Void
    let onClose: () -> Void
    let theme: HarvisTheme

    @State private var isEnvironmentExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 9) {
                    identityHeader
                    Divider().overlay(theme.line.opacity(0.72))
                    authenticationSummary
                    quotaSection
                    environmentSection
                }
                .padding(12)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 450)
            .accessibilityIdentifier("codex-account.\(details.id).details")

            actionFooter
        }
        .frame(width: 360)
        .background(theme.background)
        .foregroundColor(theme.text)
        .tint(theme.accent)
    }

    private var identityHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: details.home.isSubscriptionHome
                ? "person.crop.circle.badge.checkmark"
                : "externaldrive.connected.to.line.below")
                .harvisFont(.system(size: 18, weight: .semibold))
                .foregroundColor(details.home.isSubscriptionHome ? theme.positive : theme.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Codex 账号")
                        .harvisFont(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    if let plan = details.quota?.planLabel {
                        Text(plan)
                            .harvisFont(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.accent)
                            .lineLimit(1)
                    } else {
                        Text("套餐未提供")
                            .harvisFont(.caption2)
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                    }
                }

                Text(details.home.accountDisplayLabel)
                    .harvisFont(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)

                    .textSelection(.enabled)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .harvisFont(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.muted)
            .accessibilityIdentifier("codex-account.\(details.home.id).close")
            .accessibilityLabel("关闭账号详情")
            .help("关闭账号详情")
        }
    }

    private var authenticationSummary: some View {
        detailPanel {
            HStack(spacing: 7) {
                Label(details.authenticationLabel, systemImage: details.requiresLogin
                    ? "exclamationmark.shield.fill" : details.home.authSystemImage)
                    .harvisFont(.caption.bold())
                    .foregroundColor(authColor)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Label(
                    "\(max(details.threadCount, 0)) 个会话",
                    systemImage: "bubble.left.and.bubble.right"
                )
                .harvisFont(.caption2.monospacedDigit())
                .foregroundColor(theme.muted)
            }

        }
    }

    private var quotaSection: some View {
        detailPanel {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("账号额度", systemImage: "gauge.with.dots.needle.33percent")
                    .harvisFont(.caption.bold())

                Spacer(minLength: 4)

                Text(details.quotaUpdatedLabel)
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)

                Button {
                    onAction(.refreshQuota)
                } label: {
                    if details.isQuotaLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("codex-account.\(details.home.id).refresh")
                .accessibilityLabel("刷新额度")
                .accessibilityValue(details.isQuotaLoading ? "正在读取" : "可刷新")
                .help("刷新此账号额度")
                .disabled(details.isQuotaLoading || details.home.officialQuotaBlockedReason != nil)
            }

            if let notice = details.quotaNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: quotaNoticeIcon)
                        .foregroundColor(quotaNoticeColor)
                    Text(notice)
                        .harvisFont(.caption2)
                        .foregroundColor(quotaNoticeColor == theme.muted ? theme.muted : theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(quotaNoticeColor.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(quotaNoticeColor.opacity(0.28))
                )
            }

            if details.quotaLines.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(details.quotaLines) { line in
                        quotaLine(line)
                    }
                }
            }
        }
    }

    private func quotaLine(_ line: CodexAccountQuotaLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(line.title)
                    .harvisFont(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("剩余 \(line.window.remainingPercent)%")
                    .harvisFont(.caption2.bold().monospacedDigit())
                    .foregroundColor(quotaColor(line.window.remainingPercent))
            }

            ProgressView(value: Double(line.window.remainingPercent), total: 100)
                .progressViewStyle(.linear)
                .tint(quotaColor(line.window.remainingPercent))

            if let resetLabel = line.window.resetLabel {
                Text(resetLabel)
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(theme.surfaceAlt.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(theme.line.opacity(0.42))
        )
        .help("\(line.title) · 剩余 \(line.window.remainingPercent)%\(line.window.resetLabel.map { " · \($0)" } ?? "")")
    }

    private var environmentSection: some View {
        DisclosureGroup(isExpanded: $isEnvironmentExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                environmentValue("工作区", details.workspacePath)
                environmentValue("CODEX_HOME", details.home.path)
                environmentValue("模型", normalized(details.home.model) ?? "未提供")
                environmentValue("Provider", normalized(details.home.provider) ?? "未提供")
                environmentValue("Skills", "\(max(details.home.skillCount, 0))")
                if let expiration = details.home.authExpirationLabel {
                    environmentValue("凭据到期", expiration)
                        .help("本地凭据记录的到期时间；登录刷新后可能已变化。")
                }
            }
            .padding(.top, 5)
        } label: {
            Label("环境信息", systemImage: "info.circle")
                .harvisFont(.caption.bold())
        }
        .tint(theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.line.opacity(0.65))
        )
    }

    private func environmentValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .harvisFont(.caption2.monospaced())
                .foregroundColor(theme.text)
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
            Spacer(minLength: 0)
        }
    }

    private var actionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let feedback = details.actionFeedback {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(feedback.isError ? .orange : theme.positive)
                    Text(feedback.message)
                        .harvisFont(.caption2)
                        .foregroundColor(feedback.isError ? .orange : theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background((feedback.isError ? Color.orange : theme.positive).opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke((feedback.isError ? Color.orange : theme.positive).opacity(0.28))
                )
            }

            HStack(spacing: 7) {
                Button {
                    onAction(.openCLI)
                } label: {
                    actionLabel(
                        title: "打开 CLI",
                        systemImage: "terminal",
                        isRunning: details.isActionRunning
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .accessibilityIdentifier("codex-account.\(details.home.id).open-cli")
                .accessibilityLabel("打开 CLI")
                .help("使用此账号打开 Codex CLI")

                Button {
                    onAction(.openDesktop)
                } label: {
                    actionLabel(
                        title: "打开 Desktop",
                        systemImage: "macwindow",
                        isRunning: details.isActionRunning
                    )
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)
                .accessibilityIdentifier("codex-account.\(details.home.id).open-desktop")
                .accessibilityLabel("打开 Desktop")
                .help("使用此账号打开 Codex Desktop")
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .disabled(details.isActionRunning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surface.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.line.opacity(0.72))
                .frame(height: 1)
        }
    }

    private func actionLabel(title: String, systemImage: String, isRunning: Bool) -> some View {
        HStack(spacing: 5) {
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: systemImage)
            }
            Text(isRunning ? "处理中…" : title)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func detailPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(theme.surface.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(theme.line.opacity(0.72))
            )
    }

    private var authColor: Color {
        if details.home.isCustomModelHome { return theme.muted }
        if details.requiresLogin { return .red }
        if ["valid", "configured"].contains(details.home.normalizedAuthStatus) {
            return theme.positive
        }
        return .orange
    }

    private var quotaNoticeIcon: String {
        if details.isQuotaLoading { return "arrow.triangle.2.circlepath" }
        if details.home.officialQuotaBlockedReason != nil { return "person.crop.circle.badge.exclamationmark" }
        if details.quotaError != nil { return "exclamationmark.triangle" }
        return "info.circle"
    }

    private var quotaNoticeColor: Color {
        if details.home.officialQuotaBlockedReason != nil || details.quotaError != nil {
            return .orange
        }
        return theme.muted
    }

    private func quotaColor(_ remainingPercent: Int) -> Color {
        if remainingPercent <= 10 { return .red }
        if remainingPercent <= 30 { return .orange }
        return theme.positive
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
