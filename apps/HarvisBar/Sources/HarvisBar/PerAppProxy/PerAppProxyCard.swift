import HarvisProxyCore
import SwiftUI

struct PerAppProxyCard: View {
    @ObservedObject var model: PerAppProxyModel
    let theme: HarvisTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isLauncherRunning ? theme.positive : theme.muted)
                    .frame(width: 7, height: 7)
                Text("Per-App Proxy")
                    .font(.caption2.bold())
                Spacer(minLength: 4)
                Text(model.isLauncherRunning ? "Running" : "Ready")
                    .font(.caption2.bold())
                    .foregroundColor(model.isLauncherRunning ? theme.positive : theme.muted)
                Toggle("", isOn: Binding(
                    get: { model.isLauncherRunning },
                    set: { model.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!model.canEnable)
                .help(model.canEnable ? "通过 Terminal 启停 agy Launcher" : model.statusLabel)
            }

            HStack(spacing: 7) {
                Image(systemName: "app.badge.checkmark")
                    .foregroundColor(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Launcher · \(model.primaryRule?.application.displayName ?? "agy")")
                        .font(.caption2.bold())
                        .lineLimit(1)
                    Text("ALL_PROXY · SOCKS5 \(model.configuration.endpoint.host):\(model.configuration.endpoint.port)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 4)
                Button {
                    model.refreshLauncherState()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新 agy Launcher 状态")
                .accessibilityIdentifier("harvis.refresh.agy-launcher")
                .accessibilityValue("Completed \(model.refreshRevision)")
            }

            Text(model.statusLabel)
                .font(.caption2)
                .foregroundColor(model.lastError == nil ? theme.muted : .orange)
                .lineLimit(2)

        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("agy 无证书代理启动器")
    }
}
