import AppKit
import Foundation
import SwiftUI

extension HarvisPopoverView {
    var topMenuSection: some View {
        compactSection {
            Menu {
                if model.visibleCodexHomes.isEmpty {
                    Text("No CODEX_HOME found")
                } else {
                    ForEach(model.visibleCodexHomes) { home in
                        let isSelected = home.id == model.selectedCodexHome?.id
                        Button {
                            model.selectCodexHome(home)
                        } label: {
                            Label(
                                home.accountDisplayLabel,
                                systemImage: isSelected ? "checkmark.circle.fill" : home.authSystemImage
                            )
                        }
                    }

                    if let selected = model.selectedCodexHome {
                        Divider()
                        Button {
                            model.launchCodexCLI(selected)
                        } label: {
                            Label("Open CLI", systemImage: "terminal")
                        }
                        Button {
                            model.launchCodexDesktop(selected)
                        } label: {
                            Label("Open / Focus Desktop", systemImage: "macwindow")
                        }
                        Button {
                            model.revealCodexHome(selected)
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        Divider()
                        Menu("Manage \(quickCodexAccountLabel(selected))") {
                            Button("Skills · coming soon") {}
                                .disabled(true)
                            Button("MCP · coming soon") {}
                                .disabled(true)
                            Button("Hooks · coming soon") {}
                                .disabled(true)
                        }
                    }
                }
                Divider()
                Button {
                    model.refreshCodexHomeList()
                } label: {
                    Label("Refresh Homes", systemImage: "arrow.clockwise")
                }
                Button {
                    model.archiveScheduledCodexThreads()
                } label: {
                    Label("Archive Scheduled Chats", systemImage: "archivebox")
                }
            } label: {
                Label("Codex", systemImage: "shippingbox")
            }

            Menu {
                Menu("Services") {
                    Button("Start") { model.startServices() }
                    Button("Restart") { model.restartServices() }
                    Button("Stop") { model.stopServices() }
                }
                Divider()
                Button("Skill · L2 / approved L3") {}
                    .disabled(true)
                Text("Resident tick remains Level 1; Level 4 actions require separate approval.")
            } label: {
                Label("Runtime", systemImage: "bolt.horizontal")
            }

            Menu {
                Button("Harvis Desktop") { model.openDesktopApp() }
                Button("Studio") { model.openStudio() }
                Button("Panel") { model.openPanel() }
                Button("Presence") { model.openPresence() }
                Button("Ports") { model.openPorts() }
                Button("Network") { model.openNetworkConsole() }
                Divider()
                Button("Logs") { model.revealLogs() }
            } label: {
                Label("Open", systemImage: "square.grid.2x2")
            }
        }
        .font(.caption)
        .menuStyle(.borderlessButton)
        .foregroundStyle(theme.text)
        .tint(theme.text)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 8) {
            HarvisAvatarView()
                .environmentObject(model)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("H.A.R.V.I.S.")
                        .font(.system(size: 14, weight: .bold))
                    Text(model.currentState)
                        .font(.caption2.bold())
                        .foregroundColor(model.tintColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(model.tintColor.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 999))
                }
                Text(model.stateCaption)
                    .font(.caption2)
                    .foregroundColor(model.tintColor)
                Text(model.shortSummary)
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 18, height: 18)
            }
            .help("Refresh")
            .accessibilityLabel(HarvisGlobalAction.refresh.accessibilityLabel)
            .accessibilityIdentifier(HarvisGlobalAction.refresh.accessibilityIdentifier)
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            theme.usesFlatSurfaces ? AnyShapeStyle(theme.surface) : AnyShapeStyle(LinearGradient(
                colors: [theme.surface, theme.surfaceAlt.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
    }

    var firstRunSection: some View {
        compactPanel("First Run") {
            HStack(spacing: 8) {
                Image(systemName: model.firstRunReadyCount == model.firstRunSteps.count ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundColor(model.firstRunReadyCount == model.firstRunSteps.count ? theme.positive : theme.accent)
                Text("Setup")
                    .font(.caption2.bold())
                Spacer()
                Text(model.firstRunSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(model.firstRunReadyCount == model.firstRunSteps.count ? theme.positive : theme.accent)
            }

            if model.firstRunReadyCount != model.firstRunSteps.count {
                VStack(spacing: 5) {
                    ForEach(model.firstRunSteps.filter { !$0.ok }) { step in
                        FirstRunStepRow(step: step, theme: theme)
                    }
                }

                HStack(spacing: 6) {
                    Button {
                        model.initializeFirstRun()
                    } label: {
                        Label("Init", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isBusy)

                    Button {
                        model.openFullDiskAccessSettings()
                    } label: {
                        Label("FDA", systemImage: "lock.shield")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    var themeSection: some View {
        compactSection {
            Label("Theme", systemImage: "paintpalette")
                .font(.caption.bold())
            Spacer()
            Menu(theme.title) {
                ForEach(HarvisTheme.allCases) { item in
                    Button {
                        model.themeID = item.rawValue
                    } label: {
                        HStack {
                            Text(item.title)
                            if item == theme {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .font(.caption)
        }
    }

    var runtimeSection: some View {
        compactPanel("Runtime") {
            HStack(spacing: 6) {
                inlineMetric("P", model.barStatus?.work?.packets)
                inlineMetric("R", model.barStatus?.work?.runs)
                inlineMetric("A", model.barStatus?.work?.pendingApprovals)
                inlineMetric("B", model.barStatus?.work?.blocked)
                Spacer(minLength: 4)
                Text("\(model.barStatus?.runtime?.mode ?? "-") · L\(model.barStatus?.runtime?.autonomyLevel ?? 1)")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }
        }
    }

}
