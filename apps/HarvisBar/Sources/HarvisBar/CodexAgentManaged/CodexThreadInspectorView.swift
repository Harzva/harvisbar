import AppKit
import SwiftUI

extension CodexThreadTrustState {
    func color(in theme: HarvisTheme) -> Color {
        switch self {
        case .running: return theme.positive
        case .completed: return theme.positive
        case .failed: return .red
        case .incomplete: return theme.accent2
        case .recentlyActive: return theme.accent2
        case .idle: return theme.recentStatus
        case .stale: return theme.muted
        case .archived: return theme.muted
        }
    }
}

struct CodexThreadInspectorView: View {
    let thread: CodexThreadSummary
    let tags: [String]
    let isPinned: Bool
    let timeline: CodexInspectorTimelineState
    let isTimelineLoading: Bool
    let timelineError: String?
    let theme: HarvisTheme
    let onTogglePin: () -> Void
    let onEditTags: () -> Void
    let onRefreshTimeline: () -> Void
    let onLoadMoreTimeline: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    private var trust: CodexThreadTrustProjection {
        thread.trustProjection(evidence: timeline.summary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeader
            Divider()
                .overlay(theme.line)
                .padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    familyActivitySection
                    if thread.isSubagent {
                        agentSection
                    }
                    CodexEvidenceTimelineView(
                        timeline: timeline,
                        isLoading: isTimelineLoading,
                        error: timelineError,
                        theme: theme,
                        onRefresh: onRefreshTimeline,
                        onLoadMore: onLoadMoreTimeline
                    )
                    metadataSection
                    tagSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 5)
            }
            Divider()
                .overlay(theme.line)
                .padding(.vertical, 10)
            actionBar
        }
        .foregroundColor(theme.text)
    }

    private var inspectorHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "sidebar.right")
                .harvisFont(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.accent)
                .frame(width: 28, height: 28)
                .background(theme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text("Inspector")
                    .harvisFont(.headline)
                if thread.isSubagent {
                    HStack(spacing: 6) {
                        CodexAgentIdentityBadge(thread: thread, theme: theme)
                        if let task = thread.agentTaskLabel {
                            Text(task)
                                .harvisFont(.caption2.monospaced())
                                .foregroundColor(theme.muted)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text(thread.title)
                    .harvisFont(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close Inspector")
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Trusted Status")
            HStack(spacing: 7) {
                if trust.state == .running {
                    PulsingStatusDot(color: theme.positive)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: trust.state.systemImage)
                        .foregroundColor(trust.state.color(in: theme))
                        .frame(width: 14, height: 14)
                }
                Text(trust.state.rawValue)
                    .harvisFont(.subheadline.bold())
                    .foregroundColor(trust.state.color(in: theme))
            }
            Text(trust.reason)
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Status uses the live-process scan plus explicit rollout lifecycle evidence. Completion and failure are never inferred from time alone.")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Session")
            inspectorValue("Directory", value: thread.cwd, monospaced: true)
            inspectorValue("Model", value: thread.model?.isEmpty == false ? thread.model! : "Not reported")
            inspectorValue("Tokens", value: thread.tokenLabel)
            inspectorValue("Updated", value: thread.updatedLabel)
            inspectorValue("Session ID", value: thread.id, monospaced: true)
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Agent")
            inspectorValue("Name", value: thread.agentDisplayName)
            if let role = thread.agentRole, !role.isEmpty {
                inspectorValue("Role", value: role)
            }
            if let path = thread.agentPath, !path.isEmpty {
                inspectorValue("Task path", value: path, monospaced: true)
            }
            if let parent = thread.parentThreadId, !parent.isEmpty {
                inspectorValue("Parent session", value: parent, monospaced: true)
            }
            if let depth = thread.agentDepth {
                inspectorValue("Depth", value: "\(depth)")
            }
        }
    }

    private var familyActivitySection: some View {
        let activity = thread.runningFamilyActivity
        return VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Live task family")
            CodexFamilyActivityBreakdown(activity: activity, theme: theme)
            if activity.members.isEmpty {
                Text("No indexed main task or subagent is currently running.")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
            } else {
                ForEach(activity.members) { member in
                    HStack(alignment: .top, spacing: 7) {
                        PulsingStatusDot(color: theme.positive)
                            .frame(width: 12, height: 12)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(member.displayName)
                                    .harvisFont(.caption.weight(.semibold))
                                Text(member.kind.uppercased())
                                    .harvisFont(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.muted)
                            }
                            if let detail = member.detail {
                                Text(detail)
                                    .harvisFont(.caption2.monospaced())
                                    .foregroundColor(theme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            if activity.sidechat == nil {
                Text("Side chats are temporary Codex UI sessions. Their live count is not exposed by the thread index, so Harvis shows “—” instead of an incorrect zero.")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Tags")
                Spacer()
                Button(action: onEditTags) {
                    Image(systemName: tags.isEmpty ? "tag" : "tag.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(tags.isEmpty ? "Add tags" : "Edit tags")
            }
            if tags.isEmpty {
                Text("No tags")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
            } else {
                FlexibleTagList(tags: tags, theme: theme)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 7) {
            Button(action: onTogglePin) {
                Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .help(isPinned ? "Remove this session from Pinned" : "Keep this session in Pinned")

            Button(action: revealDirectory) {
                Image(systemName: "folder")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .help("Reveal session directory")

            Button(action: copySessionID) {
                Image(systemName: "doc.on.doc")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .help("Copy session ID")

            Spacer(minLength: 4)
            Button(action: onOpen) {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .help("Open in Codex Desktop")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .harvisFont(.caption.weight(.semibold))
            .foregroundColor(theme.muted)
            .textCase(.uppercase)
    }

    private func inspectorValue(_ label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .harvisFont(.caption2.weight(.semibold))
                .foregroundColor(theme.muted)
            Text(value)
                .harvisFont(monospaced ? .caption.monospaced() : .caption)
                .lineLimit(
                    ["Directory", "Session ID", "Task path", "Parent session"].contains(label)
                        ? 3
                        : 2
                )
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func revealDirectory() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.cwd)
    }

    private func copySessionID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(thread.id, forType: .string)
    }
}

private struct FlexibleTagList: View {
    let tags: [String]
    let theme: HarvisTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                Text("#\(tag)")
                    .harvisFont(.caption.weight(.medium))
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.accent.opacity(0.10))
                    .clipShape(Capsule())
            }
        }
    }
}
