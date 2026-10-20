import SwiftUI

extension HarvisPopoverView {
    var codexCLIAlignmentSection: some View {
        compactPanel("Codex CLI 内核") {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .foregroundColor(theme.accent)
                Text("终端版本")
                    .font(.caption2.bold())
                Spacer(minLength: 4)
                codexCLIAlignmentPill
                Button {
                    startTrackedRefresh("codex-alignment") {
                        await model.refreshCodexCLIAlignment(force: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("重新检查 Mini、Studio 与 Codex App 版本")
                .accessibilityIdentifier("harvis.refresh.codex-alignment")
                .accessibilityValue(
                    trackedRefreshAccessibilityValue(
                        "codex-alignment",
                        externallyRunning: model.isCodexCLIRefreshing
                            || model.isCodexCLIAligning
                    )
                )
                .disabled(
                    model.isCodexCLIRefreshing
                        || model.isCodexCLIAligning
                        || refreshActionRunningIDs.contains("codex-alignment")
                )
            }

            if let status = model.codexCLIAlignment {
                codexCLIEndpointRow(status.local, systemImage: "macmini")
                codexCLIEndpointRow(status.remote, systemImage: "desktopcomputer")
                codexCLIEndpointRow(status.appBundled, systemImage: "app.badge")

                if !status.aligned {
                    Button {
                        model.requestCodexCLIAlignment()
                    } label: {
                        HStack(spacing: 5) {
                            if model.isCodexCLIAligning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(model.isCodexCLIAligning ? "正在对齐…" : "一键对齐终端 CLI")
                                .font(.caption2.bold())
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HarvisControlButtonStyle(theme: theme))
                    .disabled(
                        model.isCodexCLIAligning
                            || model.isCodexCLIRefreshing
                            || !status.canAlignTerminals
                    )
                    .help("用 OpenAI 官方稳定版更新 Mini，并把同一 release 同步到 Studio")
                }
            } else {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查 Mini 与 Studio 终端 CLI…")
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                }
            }

            if let message = model.codexCLIAlignmentMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(theme.positive)
                    .lineLimit(2)
            }
            if let error = model.codexCLIAlignmentError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            Text("对齐按钮只更新两台机器的终端 CLI；Codex App 内置 CLI 只显示、不改动。")
                .font(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var codexCLIAlignmentPill: some View {
        let status = model.codexCLIAlignment
        let color = codexCLIAlignmentColor(status)
        HStack(spacing: 4) {
            if model.isCodexCLIRefreshing || model.isCodexCLIAligning {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(status?.stateLabel ?? "检查中")
                .font(.caption2.bold())
        }
        .foregroundColor(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func codexCLIEndpointRow(
        _ endpoint: CodexCLIEndpointStatus,
        systemImage: String
    ) -> some View {
        HStack(spacing: 5) {
            Label(endpoint.label, systemImage: systemImage)
                .font(.caption2.bold())
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(endpoint.version ?? "unavailable")
                .font(.caption2.monospacedDigit())
                .foregroundColor(endpoint.available ? theme.text : .red)
                .lineLimit(1)
        }
        .help(endpoint.path ?? endpoint.error ?? "Version unavailable")
    }

    private func codexCLIAlignmentColor(_ status: CodexCLIAlignmentStatus?) -> Color {
        guard let status else { return theme.muted }
        if status.aligned { return theme.positive }
        if status.terminalVersionsAvailable { return theme.accent2 }
        return .red
    }
}
