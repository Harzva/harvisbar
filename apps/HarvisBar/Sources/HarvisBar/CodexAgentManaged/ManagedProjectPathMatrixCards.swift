import SwiftUI

/// The runtime supplies its existing conversation cards so every surface
/// shares the same composer, source routing, and conversation actions.
/// Compact rows remain available to presentation-only callers and previews.
struct ManagedProjectPathMatrixSessionList: View {
    let sessions: [ManagedProjectPathMatrixSession]
    let theme: HarvisTheme
    let onSessionSelect: (String) -> Void
    var sessionContent: ((ManagedProjectPathMatrixSession) -> AnyView?)? = nil

    @ViewBuilder
    var body: some View {
        if let sessionContent {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(sessions) { session in
                    if let content = sessionContent(session) {
                        content
                    } else {
                        ManagedProjectPathMatrixSessionRow(session: session, theme: theme, onSelect: onSessionSelect)
                    }
                }
            }
            .accessibilityIdentifier("project-path-matrix.session-cards")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sessions) { session in
                    ManagedProjectPathMatrixSessionRow(
                        session: session,
                        theme: theme,
                        onSelect: onSessionSelect
                    )
                    if session.id != sessions.last?.id {
                        Divider().overlay(theme.line.opacity(0.75))
                    }
                }
            }
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            .accessibilityIdentifier("project-path-matrix.session-list")
        }
    }
}

struct ManagedProjectPathMatrixSessionRow: View {
    let session: ManagedProjectPathMatrixSession
    let theme: HarvisTheme
    let onSelect: (String) -> Void

    var body: some View {
        Button {
            onSelect(session.id)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(ManagedProjectPathMatrixPalette.sessionSurface(for: theme))
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(ManagedProjectPathMatrixPalette.session(for: theme).opacity(0.30), lineWidth: 1)
                        )
                    Image(systemName: session.provider.systemImage)
                        .harvisFont(.system(size: 12, weight: .semibold))
                        .foregroundColor(ManagedProjectPathMatrixPalette.session(for: theme))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .harvisFont(.subheadline.weight(.medium))
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                    Text("会话 · \(session.provider.label) · \(session.updatedLabel)")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    if session.isRunning {
                        PulsingStatusDot(color: theme.positive)
                    } else {
                        Image(systemName: session.statusSystemImage)
                            .harvisFont(.system(size: 11, weight: .semibold))
                    }
                    Text(session.statusLabel)
                        .harvisFont(.caption)
                        .lineLimit(1)
                }
                .foregroundColor(statusColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project-path-matrix.session.\(session.id)")
        .accessibilityLabel("打开会话 \(session.title)")
        .accessibilityValue("\(session.provider.label)，\(session.statusLabel)")
    }

    private var statusColor: Color {
        if session.isRunning { return theme.positive }
        if session.statusLabel == "等待处理" || session.statusLabel == "未知状态" {
            return theme.accent2
        }
        return theme.muted
    }
}

/// A project card with one full-surface navigation button and an independent
/// properties control. Keeping the controls as siblings avoids nested buttons
/// while making the whole card a reliable navigation target.
struct ManagedProjectPathMatrixProjectCard: View {
    let node: ManagedProjectPathMatrixNode
    let theme: HarvisTheme
    let onNavigate: (String) -> Void
    let onProperties: (ManagedProjectPathMatrixNode) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                onNavigate(node.id)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: node.kind.systemImage)
                            .harvisFont(.system(size: 14, weight: .semibold))
                            .foregroundColor(
                                ManagedProjectPathMatrixPalette.color(
                                    for: node.kind,
                                    theme: theme
                                )
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.normalizedName)
                                .harvisFont(.subheadline.weight(.semibold))
                                .foregroundColor(theme.text)
                                .lineLimit(2)
                            Text(node.kind.label)
                                .harvisFont(.caption.weight(.medium))
                                .foregroundColor(
                                    ManagedProjectPathMatrixPalette.color(
                                        for: node.kind,
                                        theme: theme
                                    )
                                )
                        }
                        Spacer(minLength: 0)
                        // Reserve the properties control's width in the main
                        // label so a long title stays clear of the overlay.
                        Color.clear
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }

                    if let purpose = nonempty(node.purpose) {
                        Text(purpose)
                            .harvisFont(.caption)
                            .foregroundColor(theme.muted)
                            .lineLimit(2)
                            .padding(.top, 8)
                    }

                    if let path = node.normalizedPath {
                        Text(path)
                            .harvisFont(.caption2.monospaced())
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 7)
                    } else {
                        Text(node.kind == .unclassified ? "尚未绑定项目路径" : "路径未提供")
                            .harvisFont(.caption2.monospaced())
                            .foregroundColor(node.kind == .unclassified ? theme.accent2 : theme.muted)
                            .padding(.top, 7)
                    }

                    HStack(spacing: 8) {
                        Label("\(node.directSessionCount)", systemImage: "text.bubble")
                        Label("\(node.childCount)", systemImage: "folder")
                        Spacer(minLength: 2)
                        // Reserve the chevron control's width in the main
                        // label so the overlay does not alter card geometry.
                        Color.clear
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                    .harvisFont(.caption)
                    .foregroundColor(ManagedProjectPathMatrixPalette.project(for: theme))
                    .padding(.top, 11)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project-path-matrix.title.\(node.id)")
            .accessibilityLabel("进入 \(node.normalizedName)")
            .accessibilityHint("点击卡片任意位置进入此项目")
        }
        .overlay(alignment: .topTrailing) {
            Button {
                onProperties(node)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .harvisFont(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看项目属性")
            .accessibilityIdentifier("project-path-matrix.properties.\(node.id)")
            .accessibilityLabel("查看 \(node.normalizedName) 属性")
            .padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                onNavigate(node.id)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundColor(ManagedProjectPathMatrixPalette.project(for: theme))
            .contentShape(Rectangle())
            .accessibilityIdentifier("project-path-matrix.enter.\(node.id)")
            .accessibilityLabel("进入 \(node.normalizedName)")
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(node.kind == .unclassified ? theme.accent2.opacity(0.55) : theme.line, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    node.kind == .unclassified
                        ? theme.accent2
                        : ManagedProjectPathMatrixPalette.color(for: node.kind, theme: theme)
                )
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-path-matrix.card.\(node.id)")
        .accessibilityLabel("\(node.normalizedName)，\(node.kind.label)，\(node.sessionCount) 个会话")
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The unresolved queue has different semantics from a project: it is an
/// inbox for sessions without a confirmed project assignment.
struct ManagedProjectPathMatrixUnclassifiedCard: View {
    let node: ManagedProjectPathMatrixNode
    let theme: HarvisTheme
    let onNavigate: (String) -> Void
    let onProperties: (ManagedProjectPathMatrixNode) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                onNavigate(node.id)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "tray.full.fill")
                            .harvisFont(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.accent2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.normalizedName == "未命名项目" ? "待归属会话" : node.normalizedName)
                                .harvisFont(.subheadline.weight(.semibold))
                                .foregroundColor(theme.text)
                                .lineLimit(2)
                            Text("会话队列")
                                .harvisFont(.caption)
                                .foregroundColor(theme.accent2)
                        }
                        Spacer(minLength: 0)
                        // Reserve the properties control's width in the main
                        // label so the title stays clear of the overlay.
                        Color.clear
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                    Text("尚未确认项目路径，等待整理或手动归属。")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                        .lineLimit(2)
                    HStack(spacing: 7) {
                        Label("\(node.directSessionCount) 个会话", systemImage: "text.bubble")
                        Spacer(minLength: 3)
                        // Reserve the visible action's width in the main
                        // label so the overlay does not alter card geometry.
                        Color.clear
                            .frame(width: 52, height: 24)
                            .accessibilityHidden(true)
                    }
                    .harvisFont(.caption)
                    .foregroundColor(theme.accent2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project-path-matrix.title.\(node.id)")
            .accessibilityLabel("进入待归属会话")
            .accessibilityHint("点击卡片任意位置查看待归属会话")
        }
        .overlay(alignment: .topTrailing) {
            Button {
                onProperties(node)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .harvisFont(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看项目属性")
            .accessibilityIdentifier("project-path-matrix.properties.\(node.id)")
            .accessibilityLabel("查看待归属会话属性")
            .padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                onNavigate(node.id)
            } label: {
                Label("查看", systemImage: "chevron.right")
                    .harvisFont(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent2)
            .contentShape(Rectangle())
            .accessibilityIdentifier("project-path-matrix.enter.\(node.id)")
            .accessibilityLabel("查看待归属会话")
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent2.opacity(theme.isDark ? 0.12 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.accent2.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-path-matrix.unclassified-card.\(node.id)")
        .accessibilityLabel("待归属会话，\(node.sessionCount) 个会话")
    }
}
