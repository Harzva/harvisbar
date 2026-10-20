import SwiftUI

/// The UI-facing project/path projection. The runtime supplies these values;
/// this model never scans the filesystem or mutates project assignments.
struct ManagedProjectPathMatrixNode: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case folder
        case project
        case unclassified
        case leaf

        var label: String {
            switch self {
            case .folder: return "文件夹"
            case .project: return "项目"
            case .unclassified: return "未分类"
            case .leaf: return "会话"
            }
        }

        var systemImage: String {
            switch self {
            case .folder: return "folder.fill"
            case .project: return "square.stack.3d.up.fill"
            case .unclassified: return "questionmark.folder.fill"
            case .leaf: return "text.bubble.fill"
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind
    let path: String?
    let purpose: String?
    let parentID: String?
    let childCount: Int
    /// Sessions directly assigned to this layer.
    let directSessionCount: Int
    /// Sessions in this layer and all loaded descendants.
    let sessionCount: Int
    /// Distinct source identities represented by the sessions.
    let participantCount: Int
    let healthLabel: String?
    let healthReason: String?
    let isLoaded: Bool

    init(
        id: String,
        name: String,
        kind: Kind,
        path: String? = nil,
        purpose: String? = nil,
        parentID: String? = nil,
        childCount: Int = 0,
        sessionCount: Int = 0,
        directSessionCount: Int = 0,
        participantCount: Int = 0,
        healthLabel: String? = nil,
        healthReason: String? = nil,
        isLoaded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.purpose = purpose
        self.parentID = parentID
        self.childCount = max(0, childCount)
        self.directSessionCount = max(0, directSessionCount)
        self.sessionCount = max(0, sessionCount)
        self.participantCount = max(0, participantCount)
        self.healthLabel = healthLabel
        self.healthReason = healthReason
        self.isLoaded = isLoaded
    }

    var normalizedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名项目" : trimmed
    }

    var normalizedPath: String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ManagedProjectPathMatrixBreadcrumb: Identifiable, Hashable, Sendable {
    /// `nil` identifies the catalog root.
    let id: String?
    let label: String
    let path: String?

    init(id: String?, label: String, path: String? = nil) {
        self.id = id
        self.label = label
        self.path = path
    }
}

struct ManagedProjectPathMatrixSummary: Hashable, Sendable {
    let currentCount: Int
    let directCount: Int
    let loadedCount: Int
    let loadedTotal: Int?
    let sessionCount: Int
    let unresolvedCount: Int
    let note: String?

    init(
        currentCount: Int,
        directCount: Int,
        loadedCount: Int,
        loadedTotal: Int? = nil,
        sessionCount: Int = 0,
        unresolvedCount: Int = 0,
        note: String? = nil
    ) {
        self.currentCount = max(0, currentCount)
        self.directCount = max(0, directCount)
        self.loadedCount = max(0, loadedCount)
        self.loadedTotal = loadedTotal.map { max(0, $0) }
        self.sessionCount = max(0, sessionCount)
        self.unresolvedCount = max(0, unresolvedCount)
        self.note = note
    }

    var loadedRangeLabel: String {
        if let loadedTotal {
            return "已加载 \(loadedCount) / \(loadedTotal) 个会话"
        }
        return "已加载 \(loadedCount) 个会话"
    }
}

/// Stable public entry point kept for existing previews and tests. Rendering
/// lives in `ManagedProjectPathMatrixShell`; callbacks remain owned by the
/// runtime parent so navigation, properties, and organizer actions retain
/// their existing behavior.
struct ManagedProjectPathMatrixView: View {
    let nodes: [ManagedProjectPathMatrixNode]
    let breadcrumbs: [ManagedProjectPathMatrixBreadcrumb]
    let currentLayerID: String?
    let summary: ManagedProjectPathMatrixSummary
    let theme: HarvisTheme
    let conversationContent: AnyView?
    let sessionContent: ((ManagedProjectPathMatrixSession) -> AnyView?)?
    let sessionThreads: [ManagedProjectPathMatrixSession]
    let onNavigate: (String?) -> Void
    let onProperties: (ManagedProjectPathMatrixNode) -> Void
    let onOrganize: () -> Void
    let onSessionSelect: (String) -> Void

    init(
        nodes: [ManagedProjectPathMatrixNode],
        breadcrumbs: [ManagedProjectPathMatrixBreadcrumb] = [],
        currentLayerID: String? = nil,
        summary: ManagedProjectPathMatrixSummary,
        theme: HarvisTheme,
        onNavigate: @escaping (String?) -> Void,
        onProperties: @escaping (ManagedProjectPathMatrixNode) -> Void,
        onOrganize: @escaping () -> Void,
        conversationContent: AnyView? = nil,
        sessionThreads: [ManagedProjectPathMatrixSession] = [],
        sessionContent: ((ManagedProjectPathMatrixSession) -> AnyView?)? = nil,
        onSessionSelect: @escaping (String) -> Void = { _ in }
    ) {
        self.nodes = nodes
        self.breadcrumbs = breadcrumbs
        self.currentLayerID = currentLayerID
        self.summary = summary
        self.theme = theme
        self.conversationContent = conversationContent
        self.sessionThreads = sessionThreads
        self.sessionContent = sessionContent
        self.onNavigate = onNavigate
        self.onProperties = onProperties
        self.onOrganize = onOrganize
        self.onSessionSelect = onSessionSelect
    }

    var body: some View {
        ManagedProjectPathMatrixShell(
            nodes: nodes,
            breadcrumbs: breadcrumbs,
            currentLayerID: currentLayerID,
            summary: summary,
            theme: theme,
            conversationContent: conversationContent,
            sessionThreads: sessionThreads,
            sessionContent: sessionContent,
            onNavigate: onNavigate,
            onProperties: onProperties,
            onOrganize: onOrganize,
            onSessionSelect: onSessionSelect
        )
    }
}

/// Read-only properties for a projected project/path node. The primary action
/// returns to the existing project-management surface and never creates a
/// path or infers a responsible person from participant counts.
struct ManagedProjectPathPropertiesView: View {
    let node: ManagedProjectPathMatrixNode
    let theme: HarvisTheme
    let onOpenProject: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    propertySection("路径", systemImage: "folder") {
                        Text(node.normalizedPath ?? "未关联路径")
                            .harvisFont(.caption2.monospaced())
                            .foregroundColor(node.normalizedPath == nil ? theme.accent2 : theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    propertySection("用途", systemImage: "text.alignleft") {
                        Text(nonempty(node.purpose) ?? "未提供用途")
                            .harvisFont(.caption)
                            .foregroundColor(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    propertySection("层级与会话", systemImage: "chart.bar.xaxis") {
                        metricRow("子路径", value: "\(node.childCount)")
                        metricRow("本层会话", value: "\(node.directSessionCount)")
                        metricRow("含子路径会话", value: "\(node.sessionCount)")
                        metricRow("参与来源", value: "\(node.participantCount)")
                        metricRow("负责人", value: "未指定")
                        Text("参与来源按独立 Agent 身份或来源账号统计；不代表负责人。")
                            .harvisFont(.caption2)
                            .foregroundColor(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    propertySection("状态", systemImage: "checkmark.shield") {
                        if let healthLabel = nonempty(node.healthLabel) {
                            Text(healthLabel)
                                .harvisFont(.caption.bold())
                                .foregroundColor(healthLabel == "待分析" ? theme.muted
                                    : (["清晰", "已确认", "已验证"].contains(healthLabel) ? theme.positive : theme.accent2))
                            Text(nonempty(node.healthReason) ?? "未提供状态说明")
                                .harvisFont(.caption2)
                                .foregroundColor(theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(node.isLoaded ? "已加载" : "待加载")
                                .harvisFont(.caption.bold())
                                .foregroundColor(node.isLoaded ? theme.positive : theme.muted)
                            if let healthReason = nonempty(node.healthReason) {
                                Text(healthReason)
                                    .harvisFont(.caption2)
                                    .foregroundColor(theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(14)
            }
            Divider().overlay(theme.line)
            HStack(spacing: 8) {
                Button("关闭") {
                    onClose()
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .accessibilityIdentifier("project-path-properties.close")

                Spacer(minLength: 4)

                Button {
                    onOpenProject()
                } label: {
                    Label("进入项目管理", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .accessibilityIdentifier("project-path-properties.open-project")
            }
            .padding(12)
        }
        .frame(minWidth: 360, idealWidth: 400, maxWidth: 460, minHeight: 400, idealHeight: 560, maxHeight: 620)
        .background(theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-path-properties")
        .accessibilityLabel("\(node.normalizedName) 项目属性")
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: node.kind.systemImage)
                .foregroundColor(ManagedProjectPathMatrixPalette.color(for: node.kind, theme: theme))
                .harvisFont(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text(node.normalizedName)
                    .harvisFont(.headline)
                    .foregroundColor(theme.text)
                    .lineLimit(2)
                Text(node.kind.label)
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
            }
            Spacer(minLength: 5)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .harvisFont(.caption.bold())
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.muted)
            .accessibilityIdentifier("project-path-properties.dismiss")
            .accessibilityLabel("关闭项目属性")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func propertySection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .harvisFont(.caption.bold())
                .foregroundColor(theme.text)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
    }

    private func metricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
            Spacer(minLength: 8)
            Text(value)
                .harvisFont(.caption.monospacedDigit())
                .foregroundColor(theme.text)
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
