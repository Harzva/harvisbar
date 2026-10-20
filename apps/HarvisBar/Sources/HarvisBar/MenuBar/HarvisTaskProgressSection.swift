import AppKit
import Foundation
import SwiftUI

extension HarvisPopoverView {
    @ViewBuilder
    var taskProgressSection: some View {
        if let progress = model.taskProgressLastSuccess,
           let current = taskProgressDisplayItem(progress) {
            compactPanel("Tasks") {
                HStack(spacing: 6) {
                    if taskProgressIsAbnormal(current) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.red)
                            .help(taskProgressAlertReason(current))
                            .frame(width: 12, height: 12)
                    } else {
                        Circle()
                            .fill(statusColor(current.status ?? "active"))
                            .frame(width: 7, height: 7)
                            .frame(width: 12, height: 12)
                    }
                    Text(current.title ?? "Task")
                        .font(.caption2.bold())
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(taskProgressPercent(current))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                    if let count = progress.activeCount, count > 1 {
                        Text("+\(count - 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(theme.accent)
                    }
                }

                ProgressView(value: taskProgressValue(current), total: 100)
                    .progressViewStyle(.linear)
                    .controlSize(.small)

                HStack(spacing: 5) {
                    Text(taskProgressUnits(current))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(taskProgressTiming(current))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }

                if let summary = current.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }

                if model.taskProgressFailure != nil {
                    taskProgressDegradedView
                }
            }
            .accessibilityIdentifier("harvis-task-progress-section")
        } else if model.taskProgressFailure != nil {
            compactPanel("Tasks") {
                taskProgressDegradedView
            }
            .accessibilityIdentifier("harvis-task-progress-section")
        }
    }

    private var taskProgressDegradedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("任务进度局部降级")
                        .font(.caption2.bold())
                    Text(model.taskProgressFailure?.localizedSummary ?? "")
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.taskProgressLastSuccess != nil {
                        Text("已保留上次成功结果。")
                            .font(.caption2)
                            .foregroundColor(theme.muted)
                    }
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button {
                    Task { await model.refreshTaskProgress() }
                } label: {
                    Label(
                        model.isTaskProgressRefreshing ? "正在重试" : "重试",
                        systemImage: "arrow.clockwise"
                    )
                    .font(.caption2.bold())
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(model.isTaskProgressRefreshing)
                .accessibilityLabel("重试任务进度")
                .accessibilityValue(model.isTaskProgressRefreshing ? "正在重试" : "可重试")
                .accessibilityIdentifier("harvis-task-progress-retry")
            }
        }
        .padding(.top, model.taskProgressLastSuccess == nil ? 0 : 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("harvis-task-progress-degraded")
    }

    func taskProgressDisplayItem(_ progress: TaskProgressStatus) -> TaskProgressItem? {
        let items = ([progress.current].compactMap { $0 } + (progress.items ?? []))
        if let failed = items.first(where: taskProgressHasFailureStatus) {
            return failed
        }
        guard (progress.activeCount ?? 0) > 0 else {
            return nil
        }
        return progress.current ?? progress.items?.first
    }

    func taskProgressHasFailureStatus(_ item: TaskProgressItem) -> Bool {
        let status = normalizedTaskProgressStatus(item.status)
        return [
            "aborted", "blocked", "canceled", "cancelled", "error", "failed",
            "interrupted", "stalled", "timed-out", "timeout", "unavailable",
        ].contains(status)
    }

    func taskProgressIsAbnormal(_ item: TaskProgressItem) -> Bool {
        taskProgressHasFailureStatus(item) || taskProgressHasFailureMarker(item) || taskProgressIsStale(item)
    }

    func taskProgressHasFailureMarker(_ item: TaskProgressItem) -> Bool {
        item.summary?.lowercased().contains("[failure]") == true
    }

    func taskProgressIsStale(_ item: TaskProgressItem) -> Bool {
        guard let updatedAt = item.updatedAt,
              let updated = Self.taskProgressDate(from: updatedAt) else {
            return false
        }
        let status = normalizedTaskProgressStatus(item.status)
        guard !["complete", "completed", "done", "passed", "ready", "success", "succeeded"].contains(status) else {
            return false
        }
        return Date().timeIntervalSince(updated) > 30
    }

    func taskProgressAlertReason(_ item: TaskProgressItem) -> String {
        if taskProgressHasFailureStatus(item) {
            return "Task needs attention: \(normalizedTaskProgressStatus(item.status))"
        }
        if taskProgressHasFailureMarker(item) {
            return item.summary?.replacingOccurrences(of: "[failure] ", with: "")
                ?? "A subtask failed and needs attention."
        }
        return "Task progress has not updated for more than 30 seconds."
    }

    func normalizedTaskProgressStatus(_ status: String?) -> String {
        (status ?? "active")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    static func taskProgressDate(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    func taskProgressValue(_ item: TaskProgressItem) -> Double {
        min(max(item.progress?.percent ?? 0, 0), 100)
    }

    func taskProgressPercent(_ item: TaskProgressItem) -> String {
        let percent = taskProgressValue(item)
        return String(format: "%.1f%%", percent)
    }

    func taskProgressUnits(_ item: TaskProgressItem) -> String {
        guard let current = item.progress?.current, let total = item.progress?.total else {
            return item.status ?? "active"
        }
        return "\(current)/\(total) \(item.progress?.unit ?? "items")"
    }

    func taskProgressTiming(_ item: TaskProgressItem) -> String {
        let eta = item.metrics?.eta?.isEmpty == false ? "ETA \(item.metrics?.eta ?? "")" : ""
        let speed = item.metrics?.speed ?? ""
        if !eta.isEmpty && !speed.isEmpty {
            return "\(eta) · \(speed)"
        }
        if !eta.isEmpty {
            return eta
        }
        if !speed.isEmpty {
            return speed
        }
        return item.detail ?? ""
    }

}
