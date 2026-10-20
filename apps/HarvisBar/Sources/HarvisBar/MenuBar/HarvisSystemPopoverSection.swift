import AppKit
import Foundation
import SwiftUI

extension HarvisPopoverView {
    var systemSection: some View {
        compactPanel("System") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 2),
                spacing: 5
            ) {
                systemChip("Load", model.systemInfo.cpuLabel, systemImage: "gauge.with.dots.needle.50percent", color: model.systemInfo.cpuColor)
                    .help(model.systemInfo.cpuDetail)
                systemChip("GPU", model.systemInfo.gpu.utilizationLabel, systemImage: "square.stack.3d.up", color: gpuColor)
                    .help(gpuDetail)
                systemChip("Temp", model.systemInfo.temperatureLabel, systemImage: "thermometer.medium", color: model.systemInfo.temperatureColor)
                    .help(model.systemInfo.temperatureDetail)
                systemChip("Therm", model.systemInfo.thermalLabel, systemImage: "thermometer.medium", color: model.systemInfo.thermalColor)
                    .help(model.systemInfo.thermalDetail)
            }

            hardwareSummary

            if model.systemInfo.hardware.gpuName != nil {
                gpuUsageRow
            }

            if model.disks.isEmpty {
                Text("Scanning mounted disks…")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
            } else {
                VStack(spacing: 5) {
                    ForEach(model.disks) { disk in
                        diskUsageRow(disk)
                    }
                }
                if let diskActionMessage {
                    Label(
                        diskActionMessage,
                        systemImage: diskActionSucceeded
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundColor(
                        diskActionSucceeded ? theme.positive : Color(hex: 0xDC2626)
                    )
                    .lineLimit(2)
                    .accessibilityIdentifier("harvis.disk.feedback")
                }
            }

            Divider()

            HStack(spacing: 5) {
                Label("CPU cores", systemImage: "cpu")
                    .font(.caption2.bold())
                Spacer()
                Text("\(model.systemInfo.logicalCPUCount) logical")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4),
                spacing: 5
            ) {
                ForEach(Array(model.systemInfo.perCorePercent.enumerated()), id: \.offset) { index, percent in
                    cpuCoreCell(index: index, percent: percent)
                }
            }
        }
    }

    var hardwareSummary: some View {
        let hardware = model.systemInfo.hardware
        return VStack(spacing: 3) {
            HStack(spacing: 5) {
                Label(hardware.chipName, systemImage: "memorychip")
                    .font(.caption2.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(hardware.memoryLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }
            HStack(spacing: 5) {
                Text(hardware.cpuConfigurationLabel)
                Text("·")
                Text(hardware.gpuLabel)
                Spacer(minLength: 4)
                Text(hardware.modelIdentifier)
            }
            .font(.caption2)
            .foregroundColor(theme.muted)
        }
        .padding(.horizontal, 2)
    }

    var gpuUsageRow: some View {
        let metrics = model.systemInfo.gpu
        return VStack(spacing: 3) {
            HStack(spacing: 5) {
                Label(model.systemInfo.hardware.gpuName ?? "GPU", systemImage: "square.stack.3d.up")
                    .font(.caption2.bold())
                Spacer(minLength: 4)
                if let memory = metrics.memoryLabel {
                    Text("shared \(memory)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Text(metrics.utilizationLabel)
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundColor(gpuColor)
            }
            ProgressView(value: metrics.utilizationPercent ?? 0, total: 100)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(gpuColor)
        }
        .help(gpuDetail)
    }

    var gpuColor: Color {
        guard let percent = model.systemInfo.gpu.utilizationPercent else { return Color(hex: 0x64748B) }
        if percent >= 90 { return Color(hex: 0xDC2626) }
        if percent >= 70 { return Color(hex: 0xB45309) }
        return Color(hex: 0x15803D)
    }

    var gpuDetail: String {
        let gpu = model.systemInfo.gpu
        guard let utilization = gpu.utilizationPercent else {
            return "GPU telemetry is unavailable on this Mac."
        }
        var details = ["GPU usage: \(String(format: "%.1f", utilization))%"]
        if let renderer = gpu.rendererPercent {
            details.append("Renderer: \(String(format: "%.1f", renderer))%")
        }
        if let tiler = gpu.tilerPercent {
            details.append("Tiler: \(String(format: "%.1f", tiler))%")
        }
        return details.joined(separator: " · ")
    }

    var remoteStudioSection: some View {
        compactPanel("Remote Compute") {
            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer")
                    .foregroundColor(theme.remoteLine)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac Studio")
                        .font(.caption2.bold())
                    Text(model.remoteStudio?.host?.hostname ?? "Not configured")
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                remoteStudioStatusPill(model.remoteStudio)
                Button {
                    startTrackedRefresh("remote-studio") {
                        await model.refreshRemoteStudio(force: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Refresh Mac Studio metrics")
                .accessibilityIdentifier("harvis.refresh.remote-studio")
                .accessibilityValue(
                    trackedRefreshAccessibilityValue(
                        "remote-studio",
                        externallyRunning: model.isRefreshing
                    )
                )
                .disabled(
                    model.isRefreshing
                        || refreshActionRunningIDs.contains("remote-studio")
                )
            }

            if let remote = model.remoteStudio, remote.isAvailable {
                remoteProgressRow(
                    "CPU",
                    percent: remote.cpuPercent,
                    label: remote.cpuLabel,
                    detail: remote.cpuDetail
                )
                remoteProgressRow(
                    "RAM",
                    percent: remote.memoryPercent,
                    label: remote.memoryLabel,
                    detail: remote.memoryDetail
                )
                remoteProgressRow(
                    "Disk",
                    percent: remote.diskPercent,
                    label: remote.diskLabel,
                    detail: remote.diskDetail
                )

                HStack(spacing: 5) {
                    Label("GPU", systemImage: "square.stack.3d.up")
                        .font(.caption2.bold())
                    Spacer(minLength: 4)
                    Text(remote.gpuLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }
                .help(remote.gpuDetail)

                if let processSummary = remote.processSummary {
                    HStack(alignment: .top, spacing: 5) {
                        Label("Top", systemImage: "list.number")
                            .font(.caption2.bold())
                        Text(processSummary)
                            .font(.caption2)
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 4) {
                    Text("SSH cache · read-only")
                    Spacer(minLength: 4)
                    Text(remote.sampleTimeLabel)
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundColor(theme.muted)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(theme.muted)
                    Text("Waiting for the Studio monitor cache…")
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(2)
                }
                Text("studio · remote host · read-only")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
            }
        }
    }

    func remoteStudioStatusPill(_ remote: RemoteStudioMetrics?) -> some View {
        let online = remote?.isAvailable == true
        return HStack(spacing: 4) {
            Circle()
                .fill(online ? theme.positive : theme.muted)
                .frame(width: 6, height: 6)
            Text(online ? "online" : "waiting")
                .font(.caption2.bold())
        }
        .foregroundColor(online ? theme.positive : theme.muted)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background((online ? theme.positive : theme.muted).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    func remoteProgressRow(
        _ title: String,
        percent: Double?,
        label: String,
        detail: String
    ) -> some View {
        let clampedPercent = min(100, max(0, percent ?? 0))
        let color = remoteUsageColor(percent)
        return HStack(spacing: 5) {
            Text(title)
                .font(.caption2.bold())
                .frame(width: 28, alignment: .leading)
            ProgressView(value: clampedPercent, total: 100)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(color)
            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundColor(theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: 92, alignment: .trailing)
        }
        .help(detail)
    }

    func remoteUsageColor(_ percent: Double?) -> Color {
        guard let percent else { return theme.muted }
        if percent >= 90 { return Color(hex: 0xDC2626) }
        if percent >= 75 { return Color(hex: 0xB45309) }
        return theme.positive
    }

    var serviceSection: some View {
        compactPanel("Services") {
            let http = model.services?.service(named: "http")
            let tick = model.services?.service(named: "tick")
            HStack(spacing: 5) {
                servicePill("HTTP", loaded: http?.loaded, running: http?.running, listening: http?.listening)
                servicePill("Tick", loaded: tick?.loaded, running: tick?.running, listening: nil)
                servicePill("API", loaded: model.health != nil, running: model.health != nil, listening: model.health != nil)
                Spacer(minLength: 4)
                Button { model.restartServices() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Restart services")
            }
            .disabled(model.isBusy)

            Divider()

            Button {
                model.openHarvisVersionCatalog()
            } label: {
                HStack(spacing: 6) {
                    Label("版本与源码", systemImage: "shippingbox.and.arrow.backward")
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("查看 Harvis App、API、源码、Git、Helper 与构建来源")
            .accessibilityLabel("版本与源码")
            .accessibilityIdentifier(HarvisVersionPopoverEntryContract.accessibilityIdentifier)
        }
    }

    func systemChip(_ title: String, _ value: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(theme.muted)
            Text(value)
                .font(.caption2.bold())
                .foregroundColor(theme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(theme.surfaceAlt.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line.opacity(0.54)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func diskUsageRow(_ disk: DiskInfo) -> some View {
        let volumeActions = VolumeRootActions.live
        let identifier = VolumeRootActions.accessibilityIdentifierComponent(for: disk)
        return VStack(spacing: 3) {
            HStack(spacing: 5) {
                Button {
                    let succeeded = volumeActions.revealRoot(for: disk)
                    setDiskActionFeedback(
                        succeeded: succeeded,
                        success: "Shown in Finder: \(disk.volumeURL.path)",
                        failure: "Could not show in Finder: \(disk.volumeURL.path)"
                    )
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: disk.isInternal == true ? "internaldrive" : "externaldrive")
                            .font(.caption2)
                            .foregroundColor(disk.warningColor)
                            .frame(width: 14)
                        Text(disk.name)
                            .font(.caption2.bold())
                            .lineLimit(1)
                        Text(disk.typeLabel)
                            .font(.caption2)
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Show volume in Finder: \(disk.volumeURL.path)")
                .accessibilityLabel("Show \(disk.name) volume in Finder")
                .accessibilityIdentifier("harvis.disk.\(identifier).show")

                Button {
                    let succeeded = volumeActions.copyRootPath(for: disk)
                    setDiskActionFeedback(
                        succeeded: succeeded,
                        success: "Copied root path: \(disk.volumeURL.path)",
                        failure: "Could not copy root path: \(disk.volumeURL.path)"
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Copy root path: \(disk.volumeURL.path)")
                .accessibilityLabel("Copy \(disk.name) root path")
                .accessibilityIdentifier("harvis.disk.\(identifier).copy")

                Button {
                    let succeeded = volumeActions.openRoot(for: disk)
                    setDiskActionFeedback(
                        succeeded: succeeded,
                        success: "Opened root: \(disk.volumeURL.path)",
                        failure: "Could not open root: \(disk.volumeURL.path)"
                    )
                } label: {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Open root in Finder: \(disk.volumeURL.path)")
                .accessibilityLabel("Open \(disk.name) root in Finder")
                .accessibilityIdentifier("harvis.disk.\(identifier).open")

                Text("\(disk.usedPercent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(disk.warningColor)
            }
            HStack(spacing: 5) {
                ProgressView(value: Double(disk.usedPercent), total: 100)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(disk.warningColor)
                Text(disk.usageLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .frame(minWidth: 88, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let succeeded = volumeActions.revealRoot(for: disk)
                setDiskActionFeedback(
                    succeeded: succeeded,
                    success: "Shown in Finder: \(disk.volumeURL.path)",
                    failure: "Could not show in Finder: \(disk.volumeURL.path)"
                )
            }
            .help(disk.detailText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(disk.name) disk usage")
            .accessibilityValue("\(disk.usedPercent) percent used; \(disk.usageLabel)")
        }
    }

    func setDiskActionFeedback(
        succeeded: Bool,
        success: String,
        failure: String
    ) {
        diskActionSucceeded = succeeded
        diskActionMessage = succeeded ? success : failure
    }

    func cpuCoreCell(index: Int, percent: Double?) -> some View {
        let color = model.systemInfo.cpuColor(for: percent)
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                Text("C\(index + 1)")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                Spacer(minLength: 2)
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundColor(color)
            }
            ProgressView(value: percent ?? 0, total: 100)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(color)
        }
        .help(percent.map { "CPU core \(index + 1): \(String(format: "%.1f", $0))%" } ?? "CPU core \(index + 1): warming up")
    }

}
