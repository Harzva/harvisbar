import SwiftUI

/// Native shell for the project/path matrix. It deliberately renders only
/// project nodes and the real sessions supplied by the caller. Execution
/// tasks, artifacts, and inferred cross-project edges do not belong here.
struct ManagedProjectPathMatrixShell: View {
    @Environment(\.harvisTextSize) private var textSize
    let nodes: [ManagedProjectPathMatrixNode]
    let breadcrumbs: [ManagedProjectPathMatrixBreadcrumb]
    let currentLayerID: String?
    let summary: ManagedProjectPathMatrixSummary
    let theme: HarvisTheme
    let conversationContent: AnyView?
    let sessionThreads: [ManagedProjectPathMatrixSession]
    let sessionContent: ((ManagedProjectPathMatrixSession) -> AnyView?)?
    let onNavigate: (String?) -> Void
    let onProperties: (ManagedProjectPathMatrixNode) -> Void
    let onOrganize: () -> Void
    let onSessionSelect: (String) -> Void

    @AppStorage("harvis.codex.chatManager.projectDisplayMode")
    private var displayModeRaw = ManagedProjectPathMatrixDisplayMode.structure.rawValue
    @AppStorage("harvis.codex.chatManager.railCollapsed") private var isRailCollapsed = false
    @AppStorage("harvis.codex.chatManager.railWidth") private var railWidth = 224.0
    @State private var showRailPopover = false
    @State private var collapsedRailNodeIDs: Set<String>

    private var displayMode: ManagedProjectPathMatrixDisplayMode {
        ManagedProjectPathMatrixDisplayMode(rawValue: displayModeRaw) ?? .structure
    }

    init(
        nodes: [ManagedProjectPathMatrixNode],
        breadcrumbs: [ManagedProjectPathMatrixBreadcrumb],
        currentLayerID: String?,
        summary: ManagedProjectPathMatrixSummary,
        theme: HarvisTheme,
        conversationContent: AnyView?,
        sessionThreads: [ManagedProjectPathMatrixSession],
        sessionContent: ((ManagedProjectPathMatrixSession) -> AnyView?)? = nil,
        onNavigate: @escaping (String?) -> Void,
        onProperties: @escaping (ManagedProjectPathMatrixNode) -> Void,
        onOrganize: @escaping () -> Void,
        onSessionSelect: @escaping (String) -> Void
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
        _collapsedRailNodeIDs = State(
            initialValue: Self.defaultCollapsedRailNodeIDs(
                nodes: nodes,
                currentLayerID: currentLayerID
            )
        )
    }

    private var visibleNodes: [ManagedProjectPathMatrixNode] {
        nodes
            .filter { $0.parentID == currentLayerID }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return kindSortIndex(lhs.kind) < kindSortIndex(rhs.kind)
                }
                return lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
                    == .orderedAscending
            }
    }

    private var currentNode: ManagedProjectPathMatrixNode? {
        guard let currentLayerID else { return nil }
        return nodes.first { $0.id == currentLayerID }
    }

    private var currentTitle: String {
        currentNode?.normalizedName ?? "所有项目"
    }

    private var currentKindLabel: String {
        currentNode?.kind.label ?? "工作区"
    }

    private var currentPath: String? {
        currentNode?.normalizedPath
    }

    private var rootNodes: [ManagedProjectPathMatrixNode] {
        nodes
            .filter { $0.parentID == nil }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return kindSortIndex(lhs.kind) < kindSortIndex(rhs.kind)
                }
                return lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
                    == .orderedAscending
            }
    }

    private var graphNodes: [ManagedProjectPathMatrixNode] {
        guard let currentLayerID else { return nodes }
        let descendants = descendantIDs(of: currentLayerID)
        return nodes.filter { descendants.contains($0.id) }
    }

    private var graphProjects: [ManagedProjectPathMatrixNode] {
        graphNodes
            .filter { $0.kind != .leaf }
            .sorted { lhs, rhs in
                if lhs.id == currentLayerID { return true }
                if rhs.id == currentLayerID { return false }
                return lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
                    == .orderedAscending
            }
    }

    private var graphSessions: [ManagedProjectPathMatrixSession] {
        let projectIDs = Set(graphProjects.map(\.id))
        return sessionThreads
            .filter { projectIDs.contains($0.projectID) }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.line)
            GeometryReader { geometry in
                let compact = geometry.size.width < 620 * (textSize?.layoutScale ?? 1)
                if isRailCollapsed || compact {
                    HStack(alignment: .top, spacing: 0) {
                        collapsedRailControl(compact: compact)
                            .frame(width: 34)
                        Divider().overlay(theme.line)
                        mainContent
                    }
                } else {
                    ManagedResizableSplitView(
                        axis: .horizontal,
                        fixedPane: .leading,
                        length: $railWidth,
                        defaultLength: 224,
                        minimumLeading: 160,
                        minimumTrailing: 320 * (textSize?.layoutScale ?? 1),
                        theme: theme,
                        label: "调整项目侧栏宽度",
                        identifier: "project-path-matrix.rail-divider"
                    ) {
                        structureRail
                    } trailing: {
                        mainContent
                    }
                }
            }
        }
        .background(theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("managed-project-path-matrix")
        .accessibilityLabel("Chat Agent Managed 项目路径矩阵")
        .onChange(of: currentLayerID) { _ in showRailPopover = false }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "rectangle.3.group")
                .harvisFont(.system(size: 16, weight: .semibold))
                .foregroundColor(ManagedProjectPathMatrixPalette.project(for: theme))
            Text("项目与会话")
                .harvisFont(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.text)
                .help("按路径浏览项目层级与会话归属")
            Spacer(minLength: 8)
            Button(action: onOrganize) {
                Label("AI 整理", systemImage: "sparkles")
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .accessibilityIdentifier("project-path-matrix.organize")
            .accessibilityLabel("打开 AI 项目整理审核")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var structureRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("项目结构")
                .harvisFont(.subheadline.weight(.semibold))
                .foregroundColor(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    railToggleButton
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    railButton(
                        id: nil,
                        title: "所有项目",
                        kind: nil,
                        count: sessionThreads.isEmpty ? 0 : summary.sessionCount,
                        depth: 0
                    )
                    ForEach(rootNodes) { node in
                        railNode(node, depth: 0, visited: [])
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Divider().overlay(theme.line)
            Text("会话来源")
                .harvisFont(.caption.weight(.medium))
                .foregroundColor(theme.muted)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ManagedChatProvider.allCases) { provider in
                    let count = sessionThreads.filter { $0.provider == provider }.count
                    sourceRow(provider: provider, count: count)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceAlt.opacity(0.32))
        .accessibilityIdentifier("project-path-matrix.rail")
    }

    private var railToggleButton: some View {
        Button {
            isRailCollapsed = true
            showRailPopover = false
        } label: {
            Image(systemName: "sidebar.left")
                .harvisFont(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.muted)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("收起项目结构")
        .accessibilityIdentifier("project-path-matrix.rail.collapse")
        .accessibilityLabel("收起项目结构")
    }

    private func collapsedRailControl(compact: Bool) -> some View {
        VStack(spacing: 8) {
            Button {
                if compact {
                    showRailPopover = true
                } else {
                    isRailCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .harvisFont(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.muted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(compact ? "窄窗口中打开项目结构；加宽窗口后可拖动侧栏分隔线" : "展开项目结构")
            .accessibilityIdentifier("project-path-matrix.rail.expand")
            .accessibilityLabel("展开项目结构")
            .popover(isPresented: $showRailPopover, arrowEdge: .trailing) {
                structureRail
                    .frame(width: 300, height: 420)
                    .background(theme.background)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 13)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surfaceAlt.opacity(0.32))
    }

    private func railNode(
        _ node: ManagedProjectPathMatrixNode,
        depth: Int,
        visited: Set<String>
    ) -> AnyView {
        guard !visited.contains(node.id) else {
            return AnyView(EmptyView())
        }
        let nextVisited = visited.union([node.id])
        let children = nodes
            .filter { $0.parentID == node.id && !nextVisited.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return kindSortIndex(lhs.kind) < kindSortIndex(rhs.kind)
                }
                return lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
                    == .orderedAscending
            }
        let hasChildren = !children.isEmpty
        let button = railButton(
            id: node.id,
            title: node.normalizedName,
            kind: node.kind,
            count: node.sessionCount,
            depth: depth + 1
        )
        let row = HStack(alignment: .top, spacing: 2) {
            if hasChildren {
                Button {
                    if collapsedRailNodeIDs.contains(node.id) {
                        collapsedRailNodeIDs.remove(node.id)
                    } else {
                        collapsedRailNodeIDs.insert(node.id)
                    }
                } label: {
                    Image(systemName: collapsedRailNodeIDs.contains(node.id)
                        ? "chevron.right"
                        : "chevron.down")
                        .harvisFont(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.muted)
                        .frame(width: 12, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-path-matrix.rail.toggle.\(node.id)")
                .accessibilityLabel(
                    collapsedRailNodeIDs.contains(node.id)
                        ? "展开 \(node.normalizedName)"
                        : "收起 \(node.normalizedName)"
                )
            } else {
                Color.clear.frame(width: 12, height: 26)
            }
            button
        }
        if !hasChildren || collapsedRailNodeIDs.contains(node.id) {
            return AnyView(row)
        }
        let descendants = VStack(alignment: .leading, spacing: 3) {
            ForEach(children) { child in
                railNode(child, depth: depth + 1, visited: nextVisited)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.line)
                .frame(width: 1)
                .padding(.leading, 5)
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 3) {
                row
                descendants
            }
        )
    }

    private func railButton(
        id: String?,
        title: String,
        kind: ManagedProjectPathMatrixNode.Kind?,
        count: Int,
        depth: Int
    ) -> some View {
        Button {
            onNavigate(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind?.systemImage ?? "square.grid.2x2")
                    .harvisFont(.system(size: 11, weight: .semibold))
                    .foregroundColor(ManagedProjectPathMatrixPalette.color(for: kind, theme: theme))
                    .frame(width: 15)
                Text(title)
                    .harvisFont(.caption.weight(id == currentLayerID ? .semibold : .regular))
                    .foregroundColor(id == currentLayerID ? theme.text : theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                if count > 0 {
                    Text("\(count)")
                        .harvisFont(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
            }
            .padding(.leading, CGFloat(depth) * 5)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(id == currentLayerID ? ManagedProjectPathMatrixPalette.activeSurface(for: theme) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(id == currentLayerID)
        .accessibilityIdentifier("project-path-matrix.rail.\(id ?? "root")")
        .accessibilityLabel("进入 \(title)")
        .accessibilityValue(id == currentLayerID ? "已选择" : "")
    }

    private func sourceRow(provider: ManagedChatProvider, count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: provider.systemImage)
                .harvisFont(.system(size: 11, weight: .semibold))
                .foregroundColor(ManagedProjectPathMatrixPalette.session(for: theme))
                .frame(width: 15)
            Text(provider.label)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
            Spacer(minLength: 2)
            Text("\(count)")
                .harvisFont(.caption2.monospacedDigit())
                .foregroundColor(theme.muted)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("会话来源 \(provider.label)，\(count) 个")
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 1)
                            .id("project-path-matrix.scroll-top")
                        breadcrumbBar
                        heading
                        locationRow
                        if displayMode == .structure {
                            structureContent
                        } else {
                            relationshipContent(availableWidth: max(0, geometry.size.width - 36))
                        }
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .onChange(of: currentLayerID) { _ in
                    proxy.scrollTo("project-path-matrix.scroll-top", anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if breadcrumbs.isEmpty {
                    Text(currentTitle)
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                } else {
                    ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .harvisFont(.system(size: 11, weight: .bold))
                                .foregroundColor(theme.muted.opacity(0.7))
                        }
                        Button {
                            onNavigate(crumb.id)
                        } label: {
                            Text(crumb.label.isEmpty ? "未命名项目" : crumb.label)
                        }
                        .buttonStyle(.plain)
                        .harvisFont(.caption2.weight(crumb.id == currentLayerID ? .semibold : .regular))
                        .foregroundColor(crumb.id == currentLayerID ? theme.text : theme.muted)
                        .disabled(crumb.id == currentLayerID)
                        .accessibilityIdentifier(
                            "project-path-matrix.breadcrumb.\(crumb.id ?? "root")"
                        )
                        .accessibilityLabel("路径 \(crumb.label)")
                    }
                }
            }
        }
        .padding(.bottom, 10)
        .accessibilityIdentifier("project-path-matrix.breadcrumbs")
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: currentNode?.kind.systemImage ?? "square.grid.2x2")
                    Text(currentKindLabel)
                }
                .harvisFont(.caption2.weight(.semibold))
                .foregroundColor(
                    ManagedProjectPathMatrixPalette.color(
                        for: currentNode?.kind,
                        theme: theme
                    )
                )
                Text(currentTitle)
                    .harvisFont(.title3.weight(.semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            viewModePicker
        }
        .padding(.bottom, 12)
    }

    private var viewModePicker: some View {
        HStack(spacing: 3) {
            ForEach(ManagedProjectPathMatrixDisplayMode.allCases) { mode in
                Button {
                    displayModeRaw = mode.rawValue
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                        .harvisFont(.caption.weight(.medium))
                        .foregroundColor(displayMode == mode ? theme.text : theme.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(displayMode == mode ? ManagedProjectPathMatrixPalette.activeSurface(for: theme) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-path-matrix.view.\(mode.rawValue)")
                .accessibilityLabel(mode.title)
                .accessibilityValue(displayMode == mode ? "已选择" : "未选择")
                .accessibilityAddTraits(displayMode == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("项目结构展示")
    }

    @ViewBuilder
    private var locationRow: some View {
        if currentNode != nil {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "folder")
                .foregroundColor(ManagedProjectPathMatrixPalette.folder(for: theme))
            Text("关联目录")
                .foregroundColor(theme.muted)
            Text(currentPath ?? "未关联目录")
                .foregroundColor(currentPath == nil ? theme.muted : theme.text)
                .fontDesign(.monospaced)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .harvisFont(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
        .accessibilityIdentifier("project-path-matrix.location")
        }
    }

    private var structureContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryStrip
                .padding(.top, 14)
            if !visibleNodes.isEmpty {
                sectionHeader("本层项目与目录", count: visibleNodes.count)
                projectGrid
            }
            sectionHeader(
                currentNode == nil ? "本工作区会话" : "本层会话",
                count: sessionThreads.filter { isDirectSession($0) }.count
            )
            if !directSessionThreads.isEmpty {
                compactSessionList
            } else if sessionThreads.isEmpty, let conversationContent {
                // Legacy previews can still supply their own content.
                conversationContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 3)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("project-path-matrix.conversations")
            } else {
                sessionEmptyState
            }
        }
    }

    private var directSessionThreads: [ManagedProjectPathMatrixSession] {
        sessionThreads
            .filter { isDirectSession($0) }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    private var compactSessionList: some View {
        ManagedProjectPathMatrixSessionList(
            sessions: directSessionThreads,
            theme: theme,
            onSessionSelect: onSessionSelect,
            sessionContent: sessionContent
        )
    }

    private var summaryStrip: some View {
        HStack(alignment: .center, spacing: 0) {
            summaryMetric(
                value: summary.currentCount,
                label: "当前路径",
                icon: "folder",
                color: ManagedProjectPathMatrixPalette.folder(for: theme)
            )
            summaryMetric(
                value: summary.directCount,
                label: "直属会话",
                icon: "text.bubble",
                color: ManagedProjectPathMatrixPalette.session(for: theme)
            )
            summaryMetric(
                value: summary.sessionCount,
                label: "含子路径",
                icon: "arrow.down.right",
                color: ManagedProjectPathMatrixPalette.project(for: theme)
            )
            Rectangle()
                .fill(theme.line.opacity(0.7))
                .frame(width: 1, height: 30)
                .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("数据范围")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                Text(summary.loadedRangeLabel)
                    .harvisFont(.caption.monospacedDigit())
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-path-matrix.summary")
    }

    private func summaryMetric(
        value: Int,
        label: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .labelStyle(.titleAndIcon)
                .symbolRenderingMode(.hierarchical)
                .tint(color)
            Text("\(value)")
                .harvisFont(.headline.monospacedDigit())
                .foregroundColor(theme.text)
        }
        .frame(minWidth: 70, alignment: .leading)
    }

    private var projectGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(visibleNodes) { node in
                if node.kind == .unclassified {
                    ManagedProjectPathMatrixUnclassifiedCard(
                        node: node,
                        theme: theme,
                        onNavigate: onNavigate,
                        onProperties: onProperties
                    )
                } else {
                    ManagedProjectPathMatrixProjectCard(
                        node: node,
                        theme: theme,
                        onNavigate: onNavigate,
                        onProperties: onProperties
                    )
                }
            }
        }
        .accessibilityIdentifier("project-path-matrix.grid")
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title)
                .harvisFont(.subheadline.weight(.semibold))
                .foregroundColor(theme.text)
            Text("\(count)")
                .harvisFont(.caption2.monospacedDigit())
                .foregroundColor(theme.muted)
            Spacer(minLength: 3)
        }
        .padding(.top, 16)
        .padding(.bottom, 9)
    }

    private var sessionEmptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("这一层没有直属会话", systemImage: "bubble.left")
                .harvisFont(.subheadline.weight(.semibold))
                .foregroundColor(theme.text)
            Text("会话归属在子项目中显示；也可以返回上一级查看其他路径。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
    }

    private func relationshipContent(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("已知项目与会话关系", count: graphSessions.count)
            Text("显示项目归属与会话关联。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            if graphSessions.isEmpty {
                relationshipEmptyState
            } else {
                ManagedProjectRelationshipGraphView(
                    projects: graphProjects,
                    sessions: graphSessions,
                    availableWidth: availableWidth,
                    theme: theme,
                    onProject: onNavigate,
                    onSession: onSessionSelect,
                    sessionContent: sessionContent
                )
            }
            relationshipLegend
        }
        .accessibilityIdentifier("project-path-matrix.relationships")
    }

    private var relationshipEmptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("暂无可绘制的会话关系", systemImage: "point.3.connected.trianglepath.dotted")
                .harvisFont(.subheadline.weight(.semibold))
                .foregroundColor(theme.text)
            Text("关系图需要当前项目树中存在至少一个已归属会话。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
    }

    private var relationshipLegend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(ManagedProjectPathMatrixPalette.project(for: theme))
                    .frame(width: 18, height: 2)
                Text("项目归属")
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(ManagedProjectPathMatrixPalette.session(for: theme))
                    .frame(width: 7, height: 7)
                Text("会话")
            }
        }
        .harvisFont(.caption2)
        .foregroundColor(theme.muted)
        .padding(.top, 10)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: summary.unresolvedCount > 0 ? "exclamationmark.triangle" : "questionmark.circle")
                .foregroundColor(summary.unresolvedCount > 0 ? theme.accent2 : theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.unresolvedCount > 0
                    ? "有 \(summary.unresolvedCount) 个项目需要确认"
                    : "路径索引已载入，内容归属尚待分析")
                    .harvisFont(.caption.weight(.semibold))
                    .foregroundColor(theme.text)
                Text(summary.note ?? "路径只用于导航和归属展示；文件夹不会由此页面创建。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text(summary.loadedRangeLabel)
                .harvisFont(.caption2.monospacedDigit())
                .foregroundColor(theme.muted)
        }
        .padding(.top, 16)
        .accessibilityIdentifier("project-path-matrix.footer")
    }

    private func isDirectSession(_ session: ManagedProjectPathMatrixSession) -> Bool {
        guard let currentLayerID else { return true }
        return session.projectID == currentLayerID
    }

    private static func defaultCollapsedRailNodeIDs(
        nodes: [ManagedProjectPathMatrixNode],
        currentLayerID: String?
    ) -> Set<String> {
        var expanded = Set<String>()
        var cursor = currentLayerID
        while let id = cursor, expanded.insert(id).inserted {
            cursor = nodes.first(where: { $0.id == id })?.parentID
        }
        let parentIDs = Set(nodes.compactMap(\.parentID))
        return Set(parentIDs).subtracting(expanded)
    }

    private func descendantIDs(of id: String) -> Set<String> {
        var result: Set<String> = [id]
        var pending: [String] = [id]
        while let parent = pending.popLast() {
            for child in nodes where child.parentID == parent {
                if result.insert(child.id).inserted {
                    pending.append(child.id)
                }
            }
        }
        return result
    }

    private func kindSortIndex(_ kind: ManagedProjectPathMatrixNode.Kind) -> Int {
        switch kind {
        case .folder: return 0
        case .project: return 1
        case .unclassified: return 2
        case .leaf: return 3
        }
    }

}
