import AppKit
import Foundation
import SwiftUI

enum HarvisGlobalAction: String, CaseIterable {
    case refresh
    case desktop
    case studio
    case panel
    case presence
    case ports
    case network
    case logs
    case configuration
    case quit

    var accessibilityLabel: String {
        switch self {
        case .refresh: return "Refresh Harvis status"
        case .desktop: return "Open Harvis Desktop"
        case .studio: return "Open Harvis Studio"
        case .panel: return "Open Harvis Web Panel"
        case .presence: return "Open Harvis Presence"
        case .ports: return "Open Harvis Ports"
        case .network: return "Open Harvis Network Console"
        case .logs: return "Show Harvis logs in Finder"
        case .configuration: return "Open permissions and personalization"
        case .quit: return "Quit HarvisBar"
        }
    }

    var accessibilityIdentifier: String {
        "harvis.global.\(rawValue)"
    }
}

extension HarvisPopoverView {
    var actionSection: some View {
        HStack(spacing: 6) {
            Button {
                model.openDesktopApp()
            } label: {
                Image(systemName: "macwindow")
            }
            .help("打开 Harvis Desktop")
            .accessibilityLabel(HarvisGlobalAction.desktop.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.desktop.accessibilityIdentifier)
            .harvisHoverNote("Desktop：打开 Harvis 桌面控制台", placement: .aboveLeading)
            Button {
                model.openStudio()
            } label: {
                Image(systemName: "rectangle.grid.2x2")
            }
            .help("打开 Studio")
            .accessibilityLabel(HarvisGlobalAction.studio.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.studio.accessibilityIdentifier)
            .harvisHoverNote("Studio：查看任务、服务与运行状态", placement: .aboveLeading)
            Button {
                model.openPanel()
            } label: {
                Image(systemName: "safari")
            }
            .help("打开 Harvis Web Panel")
            .accessibilityLabel(HarvisGlobalAction.panel.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.panel.accessibilityIdentifier)
            .harvisHoverNote("Panel：打开 Harvis Web 管理面板", placement: .aboveCenter)
            Button {
                model.openPresence()
            } label: {
                Image(systemName: "sparkles")
            }
            .help("打开 Presence")
            .accessibilityLabel(HarvisGlobalAction.presence.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.presence.accessibilityIdentifier)
            .harvisHoverNote("Presence：查看 Agent 活动与在线状态", placement: .aboveCenter)
            Button {
                model.openPorts()
            } label: {
                Image(systemName: "network")
            }
            .help("打开端口管理器")
            .accessibilityLabel(HarvisGlobalAction.ports.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.ports.accessibilityIdentifier)
            .harvisHoverNote("Ports：查看本机端口与服务占用", placement: .aboveCenter)
            Button {
                model.openNetworkConsole()
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .help("打开网络控制台")
            .accessibilityLabel(HarvisGlobalAction.network.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.network.accessibilityIdentifier)
            .harvisHoverNote("Network：查看代理、路由与网络状态", placement: .aboveCenter)
            Button {
                model.revealLogs()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .help("在 Finder 中查看日志")
            .accessibilityLabel(HarvisGlobalAction.logs.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.logs.accessibilityIdentifier)
            .harvisHoverNote("Logs：在 Finder 中打开 Harvis 日志", placement: .aboveTrailing)
            Button {
                HarvisPermissionsAndProfileWindowController.shared.show(
                    model: model,
                    preferences: preferences
                )
            } label: {
                Image(systemName: "gearshape")
            }
            .help("打开权限与个性化设置")
            .accessibilityLabel(HarvisGlobalAction.configuration.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.configuration.accessibilityIdentifier)
            .harvisHoverNote("设置：权限与个人显示名称", placement: .aboveTrailing)
            Spacer()
        }
        .buttonStyle(.bordered)
        .zIndex(100)
    }

    var footer: some View {
        HStack {
            Text(
                HarvisBuildInfo.footerLabel(
                    appVersion: HarvisBuildInfo.bundleVersion(),
                    apiVersion: model.health?.apiVersion
                )
            )
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Button("Quit") { model.quit() }
                .accessibilityLabel(HarvisGlobalAction.quit.accessibilityLabel)
                .accessibilityIdentifier(HarvisGlobalAction.quit.accessibilityIdentifier)
        }
    }

    var harnessCompactSummary: String {
        let items = model.displayedHarnesses?.items ?? []
        guard !items.isEmpty else {
            return "not loaded"
        }
        let running = items.filter { model.harnessTestingIDs.contains($0.id) }.count
        if running > 0 {
            return "\(running) running"
        }
        let needsReview = items.filter { $0.effectiveStatus == "needs_review" }.count
        let ready = items.filter { $0.effectiveStatus == "ready" || $0.effectiveStatus == "passed" }.count
        let partial = items.filter { ["partial", "degraded", "limited"].contains($0.effectiveStatus) }.count
        if needsReview > 0 {
            return "\(needsReview)/\(items.count) pending review"
        }
        if partial > 0 {
            return "\(ready) ready · \(partial) partial"
        }
        return "\(ready)/\(items.count) ready"
    }

}
