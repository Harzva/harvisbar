import SwiftUI

struct ManagedProjectGroupxReviewView: View {
    let presentation: ManagedProjectGroupxReviewPresentation
    let theme: HarvisTheme
    let onStart: () -> Void
    let onCancel: () -> Void
    let onSelectHost: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("GroupX 复核", systemImage: "person.2.badge.gearshape")
                    .harvisFont(.system(size: 13, weight: .semibold))
                Spacer()
                if presentation.isBusy { ProgressView().controlSize(.small) }
                Button(presentation.actionLabel, action: onStart)
                    .buttonStyle(HarvisControlButtonStyle(theme: theme))
                    .disabled(!presentation.canStart)
                    .accessibilityIdentifier("project-organizer.groupx-start")
                if presentation.canCancel {
                    Button("取消", action: onCancel)
                        .buttonStyle(HarvisControlButtonStyle(theme: theme))
                        .accessibilityIdentifier("project-organizer.groupx-cancel")
                }
            }
            if presentation.hosts.count > 1 || (!presentation.hosts.isEmpty && presentation.selectedHostID.isEmpty) {
                Picker("复核实例", selection: Binding(
                    get: { presentation.selectedHostID }, set: onSelectHost
                )) {
                    Text("选择实例").tag("")
                    ForEach(presentation.hosts) { host in Text(host.title).tag(host.id) }
                }
                .disabled(!presentation.canSelectHost)
                .accessibilityIdentifier("project-organizer.groupx-host")
            }
            Text("将本批建议的脱敏片段交给 GroupX 评议，使用此 DSH 实例配置的模型。复核意见需要人工判断。")
                .harvisFont(.system(size: 11))
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !presentation.hostLabel.isEmpty {
                Text("来源：\(presentation.hostLabel)")
                    .harvisFont(.system(size: 11)).foregroundColor(theme.muted)
            }
            if presentation.isStale {
                Label("建议已修改，以下复核对应修改前的版本。", systemImage: "clock.arrow.circlepath")
                    .harvisFont(.system(size: 11)).foregroundColor(theme.accent2)
            }
            if let job = presentation.job {
                Text("\(job.state.label) · \(job.participantCount) 个参与者 · 模型调用 \(job.modelCalls)/\(job.maxModelCalls)")
                    .harvisFont(.system(size: 11, weight: .medium))
                if job.state == .unknown {
                    Text("服务未找到此复核记录；实例重启后不会自动重跑。")
                        .harvisFont(.system(size: 11)).foregroundColor(theme.muted)
                }
                if let summary = job.summary, !summary.isEmpty {
                    Text(summary)
                        .harvisFont(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = presentation.message {
                Text(message).harvisFont(.system(size: 11)).foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundColor(theme.text)
        .padding(12)
        .background(theme.surfaceAlt.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-organizer.groupx-review")
    }
}
