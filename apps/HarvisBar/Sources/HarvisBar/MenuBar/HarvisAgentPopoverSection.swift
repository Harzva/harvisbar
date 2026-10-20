import AppKit
import Foundation
import SwiftUI

extension HarvisPopoverView {
    var catopSection: some View {
        compactPanel("catop · Cache") {
            let snapshot = model.catopStatus
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "rectangle.3.group.bubble.left")
                    .foregroundColor(catopStatusColor(snapshot?.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(catopTitle(snapshot))
                        .font(.caption.bold())
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                    Text(catopSubtitle(snapshot))
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(snapshot?.status ?? "setup")
                    .font(.caption2.monospaced())
                    .foregroundColor(catopStatusColor(snapshot?.status))
            }

            if let snapshot {
                HStack(spacing: 6) {
                    catopMetric("HIT", String(format: "%.1f%%", snapshot.cacheHitRate * 100))
                    catopMetric("SAVED", String(format: "$%.4f", snapshot.savedUSD))
                    catopMetric("COST", String(format: "$%.4f", snapshot.estimatedCostUSD))
                }
            }

            TextField("catop command", text: $model.catopCommand)
                .textFieldStyle(.roundedBorder)
                .help("A command name on PATH or the absolute path to catop. It is used only locally.")

            if let error = model.catopError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Button {
                    startTrackedRefresh("agent-catop") {
                        await model.refreshCatopStatus(force: true)
                    }
                } label: {
                    Label(model.isCatopRefreshing ? "Refreshing..." : "Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("harvis.refresh.agent-catop")
                .accessibilityValue(
                    trackedRefreshAccessibilityValue(
                        "agent-catop",
                        externallyRunning: model.isCatopRefreshing
                    )
                )
                .disabled(
                    model.isCatopRefreshing
                        || refreshActionRunningIDs.contains("agent-catop")
                )

                Button {
                    model.openCatopTerminal()
                } label: {
                    Label("Open TUI", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.catopCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    var agentMailSection: some View {
        compactPanel("Agent Mail") {
            let mail = model.barStatus?.agentMail
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "envelope.badge")
                    .foregroundColor(statusColor(mail?.status ?? "unknown"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mailTitle(mail))
                        .font(.caption.bold())
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                    Text(mailSubtitle(mail))
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(mailBadge(mail))
                    .font(.caption2.monospaced())
                    .foregroundColor(statusColor(mail?.status ?? "unknown"))
            }

            if let summary = model.agentMailSummary {
                VStack(spacing: 4) {
                    ForEach(summary.items.prefix(3)) { item in
                        HStack(spacing: 6) {
                            Text(item.from ?? "Unknown")
                                .font(.caption2.bold())
                                .lineLimit(1)
                            Text(item.subject ?? "(no subject)")
                                .font(.caption2)
                                .foregroundColor(theme.muted)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if item.hasAttachments == true {
                                Image(systemName: "paperclip")
                                    .font(.caption2)
                                    .foregroundColor(theme.accent)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(theme.surfaceAlt.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line.opacity(0.55)))
                    }
                    if summary.hasMore == true {
                        Text("More unread messages are available.")
                            .font(.caption2)
                            .foregroundColor(theme.muted)
                    }
                }
            }

            HStack(spacing: 6) {
                Button {
                    model.refreshAgentMailSummary()
                } label: {
                    Label(model.isMailRefreshing ? "Refreshing..." : "Unread", systemImage: "envelope.badge")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.health == nil || model.isMailRefreshing || mail?.available != true)

                Button {
                    model.openAgentMailWeb()
                } label: {
                    Label("Web Mail", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .help("Open Agent Mail web console")
            }
        }
    }

    var harnessSection: some View {
        compactPanel("Agent Launchers") {
            Picker("Launcher type", selection: $selectedAgentLaunchKind) {
                Text("CLI").tag(AgentLaunchKind.cli)
                Text("Desktop").tag(AgentLaunchKind.desktop)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let targets = model.agentLaunchTargets(kind: selectedAgentLaunchKind)
            HStack(spacing: 6) {
                Text(agentLauncherCompactSummary(targets))
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if selectedAgentLaunchKind == .cli {
                    Button {
                        model.testHarnesses()
                    } label: {
                        Image(systemName: "checkmark.seal")
                    }
                    .disabled(model.isBusy || model.health == nil)
                    .help("Test harnesses. This is separate from opening a CLI.")
                }
            }

            VStack(spacing: 3) {
                ForEach(targets) { target in
                    agentLauncherRow(target)
                }
                if targets.isEmpty {
                    Text(selectedAgentLaunchKind == .cli
                         ? "No CLI launchers were declared by this runtime."
                         : "No Desktop launchers are configured.")
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                }
            }
        }
    }

    func catopMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(theme.muted)
            Text(value)
                .font(.caption2.bold().monospacedDigit())
                .foregroundColor(theme.text)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(theme.surfaceAlt.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line.opacity(0.55)))
    }

    func catopTitle(_ status: CatopStatus?) -> String {
        guard let status else { return "Local cache monitor" }
        return "\(status.requestCount) requests · \(status.activeSessions) sessions"
    }

    func catopSubtitle(_ status: CatopStatus?) -> String {
        guard let status else { return "Set the local catop command, then refresh." }
        if status.alertCount > 0 {
            return "\(status.alertCount) policy alert\(status.alertCount == 1 ? "" : "s") need attention"
        }
        return "\(status.window.capitalized) snapshot · no raw prompts or sessions shared"
    }

    func catopStatusColor(_ status: String?) -> Color {
        switch status {
        case "ok": return theme.positive
        case "warning": return Color(hex: 0xB45309)
        case "alert": return Color(hex: 0xDC2626)
        default: return .secondary
        }
    }

    var knowledgeSection: some View {
        compactPanel("Knowledge") {
            HStack(spacing: 8) {
                valueRow("Hub", model.barStatus?.knowledge?.hub ?? "-")
                valueRow("Wiki", model.barStatus?.knowledge?.wiki ?? "-")
            }
            Text((model.barStatus?.knowledge?.activeSources ?? []).joined(separator: ", "))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
    }

    var settingsSection: some View {
        compactPanel("Config") {
            quickCredentialBank
            Divider()
            quickFileDrop
            Divider()
            TextField("Workspace root", text: $model.workspaceRoot)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Profile root", text: $model.profileRoot)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $model.portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
            }
            TextField("Plugin root", text: $model.pluginRoot)
                .textFieldStyle(.roundedBorder)
        }
    }

    func agentLauncherRow(_ target: AgentLaunchTarget) -> some View {
        let isOpening = model.agentLauncherOpeningIDs.contains(target.id)
        let status = isOpening ? "opening" : target.statusCode
        return HStack(spacing: 6) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 6, height: 6)
            Text(target.label)
                .font(.caption2.bold())
                .lineLimit(1)
            Text(target.subtitle)
                .font(.caption2)
                .foregroundColor(theme.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(statusDisplay(status))
                .font(.caption2.monospaced())
                .foregroundColor(statusColor(status))
                .lineLimit(1)
            Button {
                model.openAgentLauncher(target)
            } label: {
                Group {
                    if isOpening {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: target.buttonSystemImage)
                    }
                }
                .frame(width: 16, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(!target.isLaunchable || isOpening)
            .help(target.detailSummary)
            .accessibilityLabel(target.accessibilityLabel)
            .accessibilityHint(target.availabilityReason)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(theme.surfaceAlt.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line.opacity(0.48)))
        .help(target.detailSummary)
    }

    func agentLauncherCompactSummary(_ targets: [AgentLaunchTarget]) -> String {
        let available = targets.filter(\.isLaunchable).count
        if selectedAgentLaunchKind == .cli {
            return "\(available)/\(targets.count) CLI ready"
        }
        let running = targets.filter { $0.statusCode == "running" }.count
        if running > 0 {
            return "\(available)/\(targets.count) installed · \(running) running"
        }
        return "\(available)/\(targets.count) installed"
    }

    func metric(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("\(value ?? 0)")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(theme.surfaceAlt.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.opacity(0.72)))
    }

    func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(7)
        .background(theme.surfaceAlt.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.opacity(0.68)))
    }

    func valueLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
        .font(.caption2)
    }

    func mailTitle(_ mail: AgentMailStatus?) -> String {
        if let email = mail?.account?.email, !email.isEmpty {
            return email
        }
        if mail?.available == true {
            return "Agent Mail ready"
        }
        if mail?.cliPresent == true {
            return "Agent Mail needs auth"
        }
        return "Agent Mail unavailable"
    }

    func mailSubtitle(_ mail: AgentMailStatus?) -> String {
        if mail?.status == "limited" {
            return "Inbox probe is rate-limited; try summary later."
        }
        if let unread = mail?.unreadPreviewCount {
            return "\(unread) unread preview · \(mail?.unreadProbe ?? "probe")"
        }
        return mail?.summary ?? "Local QQ Agent Mail bridge."
    }

    func mailBadge(_ mail: AgentMailStatus?) -> String {
        if mail?.status == "limited" {
            return "limited"
        }
        return mail?.tokenStatus ?? mail?.status ?? "-"
    }

    func servicePill(_ name: String, loaded: Bool?, running: Bool?, listening: Bool?) -> some View {
        let ok = (listening ?? running ?? false)
        let warning = (loaded ?? false) && !ok
        return HStack(spacing: 5) {
            Circle()
                .fill(ok ? theme.positive : (warning ? .orange : .secondary))
                .frame(width: 7, height: 7)
            Text(name)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.surfaceAlt.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.opacity(0.70)))
    }

    func statusColor(_ status: String?) -> Color {
        switch status {
        case "ready", "passed", "available":
            return Color(hex: 0x15803D)
        case "running", "opening":
            return Color(hex: 0x2563EB)
        case "needs_review", "partial", "degraded", "limited":
            return Color(hex: 0xB45309)
        case "failed", "unavailable", "missing", "misconfigured", "unsupported":
            return Color(hex: 0xDC2626)
        default:
            return .secondary
        }
    }

    func statusDisplay(_ status: String) -> String {
        switch status {
        case "not-run":
            return "idle"
        case "needs_review":
            return "review"
        case "unavailable":
            return "missing"
        case "available":
            return "ready"
        default:
            return status.replacingOccurrences(of: "_", with: "-")
        }
    }

}
