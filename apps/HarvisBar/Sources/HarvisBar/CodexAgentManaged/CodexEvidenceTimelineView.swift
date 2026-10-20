import SwiftUI

struct CodexEvidenceTimelineView: View {
    let timeline: CodexInspectorTimelineState
    let isLoading: Bool
    let error: String?
    let theme: HarvisTheme
    let onRefresh: () -> Void
    let onLoadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Timeline")
                    .harvisFont(.caption.weight(.semibold))
                    .foregroundColor(theme.muted)
                    .textCase(.uppercase)
                if timeline.totalItems > 0 {
                    Text("\(timeline.items.count)/\(timeline.totalItems)")
                        .harvisFont(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Reload timeline evidence")
                .disabled(isLoading)
            }

            if isLoading && timeline.items.isEmpty {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading rollout evidence…")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .harvisFont(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !timeline.sourceAvailable {
                Text("No rollout evidence file is recorded for this session.")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
            } else if timeline.items.isEmpty {
                Text("No public timeline evidence was found.")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(timeline.items) { item in
                        evidenceRow(item)
                        if item.id != timeline.items.last?.id {
                            Divider()
                                .overlay(theme.line)
                                .padding(.leading, 22)
                        }
                    }
                }
            }

            if timeline.canLoadMore {
                Button(action: onLoadMore) {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Text("Load older")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(isLoading)
            }
        }
    }

    private func evidenceRow(_ item: CodexEvidenceItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon(for: item))
                .harvisFont(.system(size: 11, weight: .semibold))
                .foregroundColor(color(for: item))
                .frame(width: 15, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(item.title)
                        .harvisFont(.caption.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(item.timestampLabel)
                        .harvisFont(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func icon(for item: CodexEvidenceItem) -> String {
        switch item.kind {
        case "turn_started": return "play.fill"
        case "completion": return "checkmark.circle.fill"
        case "failure": return "xmark.octagon.fill"
        case "tool_call": return "wrench.and.screwdriver.fill"
        case "tool_result": return item.outcome == "failed" ? "exclamationmark.triangle.fill" : "return"
        case "message": return "text.bubble.fill"
        default: return "circle.fill"
        }
    }

    private func color(for item: CodexEvidenceItem) -> Color {
        if item.outcome == "failed" || item.kind == "failure" { return .red }
        if item.kind == "completion" { return theme.positive }
        if item.kind == "tool_call" || item.kind == "tool_result" { return theme.accent2 }
        return theme.accent
    }
}
