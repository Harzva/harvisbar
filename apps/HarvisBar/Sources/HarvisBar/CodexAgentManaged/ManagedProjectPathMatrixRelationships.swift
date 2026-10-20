import SwiftUI

/// A native, source-aware relationship graph for projects and managed
/// conversations. Selecting a node only updates this view's detail pane.
/// Navigation is exposed by the explicit project/session actions in that
/// pane, which keeps graph exploration safe for mouse, keyboard, and VoiceOver
/// users.
struct ManagedProjectRelationshipGraphView: View {
    let projects: [ManagedProjectPathMatrixNode]
    let sessions: [ManagedProjectPathMatrixSession]
    let availableWidth: CGFloat
    let theme: HarvisTheme
    let onProject: (String?) -> Void
    let onSession: (String) -> Void
    var sessionContent: ((ManagedProjectPathMatrixSession) -> AnyView?)? = nil

    @State private var selectedNodeID: String?
    @State private var enabledRelationshipKinds: Set<ManagedProjectPathMatrixRelationshipKind>
    @State private var focusedProjectID = ""
    @State private var focusRelatedOnly = false
    @State private var sessionLimit = ManagedProjectPathMatrixRelationshipProjection.defaultSessionLimit
    @State private var sessionOffset = 0
    @State private var zoomScale: CGFloat = 1
    @State private var magnificationStart: CGFloat = 1
    @State private var relationListExpanded = false
    @State private var relationDetailsExpanded = false
    @State private var fitsWidth = true
    @State private var narrowDetailsPresented = false

    private var usesInlineDetails: Bool { availableWidth >= 820 }

    /// Immutable data for one SwiftUI render pass. Building this once keeps
    /// graph filtering and detail rendering from reconstructing the complete
    /// relationship projection for every node and edge.
    private struct RelationshipRenderSnapshot {
        let projection: ManagedProjectPathMatrixRelationshipProjection
        let allSessions: [ManagedProjectPathMatrixSession]
        let sessionsByID: [String: ManagedProjectPathMatrixSession]
        let nodesByID: [String: ManagedProjectPathMatrixRelationshipNode]
        let scopedProjectIDs: Set<String>?
        let focusNodeIDs: Set<String>?
        let activeEdges: [ManagedProjectPathMatrixRelationshipEdge]
        let visibleNodes: [ManagedProjectPathMatrixRelationshipNode]
        let layout: ManagedProjectPathMatrixRelationshipLayout

        init(
            projects: [ManagedProjectPathMatrixNode],
            sessions: [ManagedProjectPathMatrixSession],
            enabledRelationshipKinds: Set<ManagedProjectPathMatrixRelationshipKind>,
            focusedProjectID: String,
            focusRelatedOnly: Bool,
            selectedNodeID: String?,
            sessionLimit: Int,
            sessionOffset: Int
        ) {
            let scopedIDs = Self.scopedProjectIDs(
                projects: projects,
                focusedProjectID: focusedProjectID
            )
            let projectedSessions: [ManagedProjectPathMatrixSession]
            if let scopedIDs {
                projectedSessions = sessions.filter { scopedIDs.contains($0.projectID) }
            } else {
                projectedSessions = sessions
            }

            let projection = ManagedProjectPathMatrixRelationshipProjection(
                projects: projects,
                sessions: projectedSessions,
                sessionLimit: sessionLimit,
                sessionOffset: sessionOffset
            )

            let projectFocusNodeIDs: Set<String>?
            if let scopedIDs {
                projectFocusNodeIDs = Self.focusedProjectNodeIDs(
                    projection: projection,
                    projectIDs: scopedIDs
                )
            } else {
                projectFocusNodeIDs = nil
            }

            let relatedIDs: Set<String>?
            if focusRelatedOnly, let selectedNodeID {
                relatedIDs = Self.relatedNodeIDs(
                    projection: projection,
                    selectedNodeID: selectedNodeID
                )
            } else {
                relatedIDs = nil
            }

            let focusIDs: Set<String>?
            if let projectFocusNodeIDs {
                if let relatedIDs {
                    focusIDs = projectFocusNodeIDs.intersection(relatedIDs)
                } else {
                    focusIDs = projectFocusNodeIDs
                }
            } else {
                focusIDs = relatedIDs
            }

            let activeEdges = projection.edges.filter { edge in
                guard enabledRelationshipKinds.contains(edge.kind) else { return false }
                guard let focusIDs else { return true }
                return focusIDs.contains(edge.from) && focusIDs.contains(edge.to)
            }
            let visibleNodes = projection.nodes.filter { node in
                if let focusIDs, !focusIDs.contains(node.id) {
                    return false
                }
                // Keep projects and sessions as stable anchors. Explanatory
                // nodes disappear when all of their relation kinds are
                // filtered out, so the canvas has no isolated cards.
                guard node.kind == .role || node.kind == .task || node.kind == .placeholder else {
                    return true
                }
                return activeEdges.contains { $0.from == node.id || $0.to == node.id }
            }

            self.projection = projection
            self.allSessions = sessions
            self.sessionsByID = Dictionary(
                sessions.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            self.nodesByID = Dictionary(
                projection.nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            self.scopedProjectIDs = scopedIDs
            self.focusNodeIDs = focusIDs
            self.activeEdges = activeEdges
            self.visibleNodes = visibleNodes
            self.layout = ManagedProjectPathMatrixRelationshipLayout(
                nodes: visibleNodes,
                edges: activeEdges
            )
        }

        private static func scopedProjectIDs(
            projects: [ManagedProjectPathMatrixNode],
            focusedProjectID: String
        ) -> Set<String>? {
            guard !focusedProjectID.isEmpty else { return nil }
            var result: Set<String> = [focusedProjectID]
            var changed = true
            while changed {
                changed = false
                for project in projects where result.contains(project.parentID ?? "") {
                    if result.insert(project.id).inserted {
                        changed = true
                    }
                }
            }
            return result
        }

        private static func focusedProjectNodeIDs(
            projection: ManagedProjectPathMatrixRelationshipProjection,
            projectIDs: Set<String>
        ) -> Set<String> {
            let sessionNodeIDs = Set(
                projection.visibleSessions
                    .filter { projectIDs.contains($0.projectID) }
                    .map { ManagedProjectPathMatrixRelationshipProjection.sessionNodeID($0.id) }
            )
            var nodeIDs = projectIDs.union(sessionNodeIDs)
            for edge in projection.edges {
                if sessionNodeIDs.contains(edge.from) {
                    nodeIDs.insert(edge.to)
                }
                if sessionNodeIDs.contains(edge.to) {
                    nodeIDs.insert(edge.from)
                }
            }
            return nodeIDs
        }

        private static func relatedNodeIDs(
            projection: ManagedProjectPathMatrixRelationshipProjection,
            selectedNodeID: String
        ) -> Set<String> {
            var result: Set<String> = [selectedNodeID]
            for edge in projection.edges {
                if edge.from == selectedNodeID {
                    result.insert(edge.to)
                } else if edge.to == selectedNodeID {
                    result.insert(edge.from)
                }
            }

            var frontier = [selectedNodeID]
            var lineageVisited: Set<String> = [selectedNodeID]
            while let current = frontier.popLast() {
                for edge in projection.edges where
                    edge.kind == .conversationParent || edge.kind == .rootFamily {
                    let neighbor: String?
                    if edge.from == current {
                        neighbor = edge.to
                    } else if edge.to == current {
                        neighbor = edge.from
                    } else {
                        neighbor = nil
                    }
                    if let neighbor, lineageVisited.insert(neighbor).inserted {
                        result.insert(neighbor)
                        frontier.append(neighbor)
                    }
                }
            }
            return result
        }
    }

    init(
        projects: [ManagedProjectPathMatrixNode],
        sessions: [ManagedProjectPathMatrixSession],
        availableWidth: CGFloat,
        theme: HarvisTheme,
        onProject: @escaping (String?) -> Void,
        onSession: @escaping (String) -> Void,
        sessionContent: ((ManagedProjectPathMatrixSession) -> AnyView?)? = nil
    ) {
        self.projects = projects
        self.sessions = sessions
        self.availableWidth = availableWidth
        self.theme = theme
        self.onProject = onProject
        self.onSession = onSession
        self.sessionContent = sessionContent
        _enabledRelationshipKinds = State(
            initialValue: Set(ManagedProjectPathMatrixRelationshipKind.allCases)
        )
    }

    private func renderSnapshot() -> RelationshipRenderSnapshot {
        RelationshipRenderSnapshot(
            projects: projects,
            sessions: sessions,
            enabledRelationshipKinds: enabledRelationshipKinds,
            focusedProjectID: focusedProjectID,
            focusRelatedOnly: focusRelatedOnly,
            selectedNodeID: selectedNodeID,
            sessionLimit: sessionLimit,
            sessionOffset: sessionOffset
        )
    }

    private func selectedNode(
        in snapshot: RelationshipRenderSnapshot
    ) -> ManagedProjectPathMatrixRelationshipNode? {
        guard let selectedNodeID else { return nil }
        return snapshot.nodesByID[selectedNodeID]
    }

    private func selectedSession(
        in snapshot: RelationshipRenderSnapshot
    ) -> ManagedProjectPathMatrixSession? {
        if let sessionID = selectedNode(in: snapshot)?.sessionID {
            return snapshot.sessionsByID[sessionID]
        }
        guard let selectedNodeID,
              selectedNodeID.hasPrefix("session::") else { return nil }
        let sessionID = String(selectedNodeID.dropFirst("session::".count))
        return snapshot.sessionsByID[sessionID]
    }

    var body: some View {
        let snapshot = renderSnapshot()
        return VStack(alignment: .leading, spacing: 10) {
            graphHeader(snapshot: snapshot)
            relationshipControls(snapshot: snapshot)
            if usesInlineDetails {
                HStack(alignment: .top, spacing: 12) {
                    graphPane(snapshot: snapshot)
                        .frame(width: availableWidth - 332, alignment: .topLeading)
                    detailPane(snapshot: snapshot)
                        .frame(width: 320)
                        .frame(minHeight: 260, maxHeight: 700, alignment: .topLeading)
                }
            } else {
                graphPane(snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(isPresented: $narrowDetailsPresented) {
            VStack(alignment: .trailing, spacing: 8) {
                Button("完成") { narrowDetailsPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("project-path-matrix.relationships.close-detail")
                detailPane(snapshot: snapshot)
            }
            .padding(14)
            .frame(width: 390)
            .background(theme.background)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("项目与会话关系图")
        .onChange(of: usesInlineDetails) { inline in
            if inline { narrowDetailsPresented = false }
        }
        .onChange(of: projects.map(\.id)) { _ in
            clearStaleSelection(snapshot: snapshot)
        }
        .onChange(of: sessions.map(\.id)) { _ in
            clearStaleSelection(snapshot: snapshot)
        }
        .onChange(of: focusedProjectID) { _ in
            sessionOffset = 0
            clearStaleSelection(snapshot: snapshot)
        }
    }

    private func graphHeader(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("关系图", systemImage: "point.3.connected.trianglepath.dotted")
                    .harvisFont(.subheadline.weight(.semibold))
                    .foregroundColor(theme.text)
                Text("\(snapshot.visibleNodes.count) 个节点 · \(snapshot.activeEdges.count) 条关系")
                    .harvisFont(.caption.monospacedDigit())
                    .foregroundColor(theme.muted)
                Spacer(minLength: 4)
            }
            HStack(alignment: .center, spacing: 7) {
                Text("会话 \(snapshot.projection.displayedSessionCount) / \(snapshot.projection.totalSessionCount)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                if snapshot.projection.hasPreviousPage {
                    Button("上一批") {
                        sessionOffset = max(0, sessionOffset - max(1, sessionLimit))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .accessibilityIdentifier("project-path-matrix.relationships.previous-page")
                    .accessibilityLabel("显示上一批会话")
                }
                if snapshot.projection.omittedSessionCount > 0 {
                    Button {
                        let next = min(
                            sessionLimit + ManagedProjectPathMatrixRelationshipProjection.sessionIncrement,
                            ManagedProjectPathMatrixRelationshipProjection.maximumSessionLimit
                        )
                        sessionLimit = next
                    } label: {
                        Label(
                            sessionLimit >= ManagedProjectPathMatrixRelationshipProjection.maximumSessionLimit
                                ? "已达显示上限"
                                : "显示更多",
                            systemImage: "plus"
                        )
                    }
                    .buttonStyle(HarvisControlButtonStyle(theme: theme))
                    .disabled(sessionLimit >= ManagedProjectPathMatrixRelationshipProjection.maximumSessionLimit)
                    .accessibilityIdentifier("project-path-matrix.relationships.show-more")
                        .accessibilityLabel(
                            sessionLimit >= ManagedProjectPathMatrixRelationshipProjection.maximumSessionLimit
                                ? "已达会话显示上限"
                                : "显示更多会话"
                        )
                }
                if snapshot.projection.hasNextPage {
                    Button("下一批") {
                        sessionOffset += max(1, sessionLimit)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .accessibilityIdentifier("project-path-matrix.relationships.next-page")
                    .accessibilityLabel("显示下一批会话")
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("project-path-matrix.relationships.header")
    }

    private func relationshipControls(snapshot: RelationshipRenderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Picker("项目焦点", selection: $focusedProjectID) {
                    Text("全部项目").tag("")
                    ForEach(projects.sorted(by: projectSort), id: \.id) { project in
                        Text(project.normalizedName).tag(project.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 230, alignment: .leading)
                .accessibilityIdentifier("project-path-matrix.relationships.project-focus")
                Spacer(minLength: 0)
                if !usesInlineDetails, selectedNodeID != nil {
                    Button("节点详情") { narrowDetailsPresented = true }
                        .buttonStyle(HarvisControlButtonStyle(theme: theme))
                        .accessibilityIdentifier("project-path-matrix.relationships.show-detail")
                }
            }

            HStack(alignment: .center, spacing: 7) {
                Button {
                    focusRelatedOnly.toggle()
                } label: {
                    Label(
                        focusRelatedOnly ? "显示全部节点" : "聚焦选中节点",
                        systemImage: focusRelatedOnly ? "scope" : "dot.scope"
                    )
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .disabled(selectedNodeID == nil)
                .accessibilityIdentifier("project-path-matrix.relationships.focus-related")
                .accessibilityLabel(focusRelatedOnly ? "显示全部节点" : "聚焦选中节点及相关节点")

                if !focusedProjectID.isEmpty || focusRelatedOnly {
                    Button("清除聚焦") {
                        focusedProjectID = ""
                        focusRelatedOnly = false
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .accessibilityIdentifier("project-path-matrix.relationships.clear-focus")
                }
                Spacer(minLength: 0)
                zoomControls(snapshot: snapshot)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(ManagedProjectPathMatrixRelationshipKind.allCases) { kind in
                    relationshipFilterButton(kind)
                }
            }
            .accessibilityIdentifier("project-path-matrix.relationships.legend")
        }
    }

    private func zoomControls(snapshot: RelationshipRenderSnapshot) -> some View {
        let scale = effectiveZoom(snapshot: snapshot)
        return HStack(spacing: 4) {
            Button("适应") { fitsWidth = true }
                .buttonStyle(.plain)
                .foregroundColor(theme.accent)
                .accessibilityIdentifier("project-path-matrix.relationships.fit-width")
                .accessibilityLabel("适应关系图宽度")
            Button {
                zoomScale = min(2.2, scale + 0.1)
                fitsWidth = false
                magnificationStart = zoomScale
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent)
            .accessibilityIdentifier("project-path-matrix.relationships.zoom-in")
            .accessibilityLabel("放大关系图")

            Text("\(Int((scale * 100).rounded()))%")
                .harvisFont(.caption2.monospacedDigit())
                .foregroundColor(theme.muted)
                .frame(minWidth: 38)
                .accessibilityLabel("缩放 \(Int((scale * 100).rounded()))%")

            Button {
                zoomScale = max(0.25, scale - 0.1)
                fitsWidth = false
                magnificationStart = zoomScale
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent)
            .accessibilityIdentifier("project-path-matrix.relationships.zoom-out")
            .accessibilityLabel("缩小关系图")

            Button {
                zoomScale = 1
                fitsWidth = false
                magnificationStart = 1
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent)
            .accessibilityIdentifier("project-path-matrix.relationships.reset-zoom")
            .accessibilityLabel("重置缩放")
        }
    }

    private func relationshipFilterButton(
        _ kind: ManagedProjectPathMatrixRelationshipKind
    ) -> some View {
        let isEnabled = enabledRelationshipKinds.contains(kind)
        return Button {
            if isEnabled {
                enabledRelationshipKinds.remove(kind)
            } else {
                enabledRelationshipKinds.insert(kind)
            }
        } label: {
            Label(kind.title, systemImage: kind.systemImage)
                .harvisFont(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .foregroundColor(isEnabled ? theme.text : theme.muted)
                .background(isEnabled ? relationColor(kind).opacity(0.17) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isEnabled ? relationColor(kind).opacity(0.65) : theme.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project-path-matrix.relationships.filter.\(kind.rawValue)")
        .accessibilityLabel("\(kind.title)关系")
        .accessibilityValue(isEnabled ? "已显示" : "已隐藏")
    }

    private func graphPane(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("点击节点查看详情；详情可进入项目、在工作台查看，或使用 Desktop / CLI 打开会话。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if snapshot.projection.nodes.isEmpty {
                graphEmptyState
            } else {
                graphViewport(snapshot: snapshot)
            }

            sessionCapNotice(snapshot: snapshot)
            projectionNotes(snapshot: snapshot)
            accessibleRelationList(snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func graphViewport(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            scaledGraphCanvas(snapshot: snapshot)
                .padding(24)
        }
        .frame(minHeight: 410, maxHeight: 520)
        .background(theme.surfaceAlt.opacity(theme.isDark ? 0.78 : 0.60))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    if fitsWidth {
                        magnificationStart = effectiveZoom(snapshot: snapshot)
                        fitsWidth = false
                    }
                    zoomScale = min(2.2, max(0.25, magnificationStart * value))
                }
                .onEnded { _ in
                    magnificationStart = zoomScale
                }
        )
        .accessibilityIdentifier("project-path-matrix.relationships.viewport")
        .accessibilityLabel("可滚动关系图画布")
        .accessibilityHint("可上下左右滚动，使用适应按钮查看全部列；点击节点查看详情")
    }

    private func effectiveZoom(snapshot: RelationshipRenderSnapshot) -> CGFloat {
        guard fitsWidth, availableWidth > 0 else { return zoomScale }
        let viewportWidth = usesInlineDetails ? availableWidth - 332 : availableWidth
        return min(1, max(0.25, (viewportWidth - 48) / snapshot.layout.canvasSize.width))
    }

    private func selectNode(_ id: String) {
        selectedNodeID = id
        if !usesInlineDetails { narrowDetailsPresented = true }
    }

    private func scaledGraphCanvas(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        let currentLayout = snapshot.layout
        let scale = effectiveZoom(snapshot: snapshot)
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in snapshot.activeEdges {
                    guard let start = currentLayout.positions[edge.from],
                          let end = currentLayout.positions[edge.to] else { continue }
                    let endpoints = edgeEndpoints(
                        from: start,
                        to: end,
                        nodeSize: currentLayout.nodeSize
                    )
                    let highlighted = selectedNodeID == edge.from || selectedNodeID == edge.to
                    let color = relationColor(edge.kind).opacity(
                        selectedNodeID == nil ? 0.70 : (highlighted ? 0.98 : 0.23)
                    )
                    var path = Path()
                    path.move(to: endpoints.start)
                    let sameColumn = abs(start.x - end.x) < 1
                    let middleX = sameColumn
                        ? max(endpoints.start.x, endpoints.end.x) + 34
                        : (endpoints.start.x + endpoints.end.x) / 2
                    path.addCurve(
                        to: endpoints.end,
                        control1: CGPoint(x: middleX, y: endpoints.start.y),
                        control2: CGPoint(x: middleX, y: endpoints.end.y)
                    )
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: edge.isUnresolved ? 2 : (highlighted ? 2.4 : 1.5),
                            dash: edge.isUnresolved ? [6, 4] : (edge.kind == .rootFamily ? [3, 4] : [])
                        )
                    )

                    var arrow = Path()
                    let angle = atan2(
                        0,
                        endpoints.end.x - middleX
                    )
                    let tip = endpoints.end
                    let left = CGPoint(
                        x: tip.x - 8 * cos(angle - CGFloat.pi / 6),
                        y: tip.y - 8 * sin(angle - CGFloat.pi / 6)
                    )
                    let right = CGPoint(
                        x: tip.x - 8 * cos(angle + CGFloat.pi / 6),
                        y: tip.y - 8 * sin(angle + CGFloat.pi / 6)
                    )
                    arrow.move(to: tip)
                    arrow.addLine(to: left)
                    arrow.addLine(to: right)
                    arrow.closeSubpath()
                    context.fill(arrow, with: .color(color))
                }
            }
            .frame(width: currentLayout.canvasSize.width, height: currentLayout.canvasSize.height)

            ForEach(snapshot.visibleNodes) { node in
                if let point = currentLayout.positions[node.id] {
                    relationshipNodeButton(node, layout: currentLayout)
                        .position(point)
                }
            }
        }
        .frame(
            width: currentLayout.canvasSize.width,
            height: currentLayout.canvasSize.height,
            alignment: .topLeading
        )
        .scaleEffect(scale, anchor: .topLeading)
        .frame(
            width: currentLayout.canvasSize.width * scale,
            height: currentLayout.canvasSize.height * scale,
            alignment: .topLeading
        )
    }

    private func relationshipNodeButton(
        _ node: ManagedProjectPathMatrixRelationshipNode,
        layout: ManagedProjectPathMatrixRelationshipLayout
    ) -> some View {
        let isSelected = selectedNodeID == node.id
        return Button {
            selectNode(node.id)
        } label: {
            relationshipNodeCard(node, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .frame(width: layout.nodeSize.width, height: layout.nodeSize.height)
        .accessibilityIdentifier("project-path-matrix.relationship-node.\(node.id)")
        .accessibilityLabel(nodeAccessibilityLabel(node))
        .accessibilityHint("选择节点查看详情")
        .accessibilityValue(isSelected ? "已选择" : "")
    }

    private func relationshipNodeCard(
        _ node: ManagedProjectPathMatrixRelationshipNode,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: nodeSystemImage(node))
                    .harvisFont(.system(size: 12, weight: .semibold))
                    .foregroundColor(nodeColor(node))
                Text(node.title)
                    .harvisFont(.caption.weight(.semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if node.isPlaceholder {
                    Image(systemName: "questionmark.circle")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.accent2)
                }
            }
            Text(node.subtitle)
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .lineLimit(2)
            if let roleLabel = node.roleLabel {
                Text(roleLabel)
                    .harvisFont(.caption2.weight(.medium))
                    .foregroundColor(node.kind == .role ? theme.accent2 : theme.accent)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(nodeSurface(node))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? theme.accent : (node.isPlaceholder ? theme.accent2.opacity(0.75) : theme.line),
                    lineWidth: isSelected ? 2 : 1
                )
        )
    }

    private var graphEmptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("暂无可绘制的关系", systemImage: "point.3.connected.trianglepath.dotted")
                .harvisFont(.subheadline.weight(.semibold))
                .foregroundColor(theme.text)
            Text("关系图需要至少一个项目或已载入会话。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .padding(14)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
    }

    private func sessionCapNotice(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        Group {
            if snapshot.projection.omittedSessionCount > 0 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(theme.accent2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "已显示 \(snapshot.projection.displayedSessionCount) / \(snapshot.projection.totalSessionCount) 个会话，省略 \(snapshot.projection.omittedSessionCount) 个。"
                        )
                        .harvisFont(.caption.weight(.medium))
                        .foregroundColor(theme.text)
                        Text(
                            snapshot.projection.omittedRelationshipCount > 0
                                ? "有 \(snapshot.projection.omittedRelationshipCount) 条关系指向已省略会话；扩大显示范围后可查看。"
                                : "扩大显示范围后可查看更多会话关系。"
                        )
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                    }
                    Spacer(minLength: 2)
                }
                .padding(9)
                .background(theme.accent2.opacity(theme.isDark ? 0.13 : 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("project-path-matrix.relationships.session-cap")
                .accessibilityLabel(
                    "已显示 \(snapshot.projection.displayedSessionCount) / \(snapshot.projection.totalSessionCount) 个会话，省略 \(snapshot.projection.omittedSessionCount) 个"
                )
            }
        }
    }

    @ViewBuilder
    private func projectionNotes(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        if !snapshot.projection.relationshipNotes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshot.projection.relationshipNotes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .harvisFont(.caption2)
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            .accessibilityIdentifier("project-path-matrix.relationships.notes")
        }
    }

    private func accessibleRelationList(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        DisclosureGroup(isExpanded: $relationListExpanded) {
            if snapshot.activeEdges.isEmpty {
                Text("当前筛选没有可见关系。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    .padding(.vertical, 5)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshot.activeEdges) { edge in
                        Button {
                            selectNode(edge.to)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle()
                                    .fill(relationColor(edge.kind))
                                    .frame(width: 6, height: 6)
                                Text(edge.label)
                                    .harvisFont(.caption2.weight(.medium))
                                    .foregroundColor(theme.text)
                                Text("\(nodeTitle(edge.from, snapshot: snapshot)) → \(nodeTitle(edge.to, snapshot: snapshot))")
                                    .harvisFont(.caption2)
                                    .foregroundColor(theme.muted)
                                    .lineLimit(1)
                                if edge.isUnresolved {
                                    Text("未解析")
                                        .harvisFont(.caption2.weight(.medium))
                                        .foregroundColor(theme.accent2)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("project-path-matrix.relationships.edge.\(edge.id)")
                        .accessibilityLabel(relationAccessibilityLabel(edge, snapshot: snapshot))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Label("可访问关系列表", systemImage: "list.bullet.rectangle")
                    .harvisFont(.caption.weight(.semibold))
                Text("\(snapshot.activeEdges.count)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }
            .foregroundColor(theme.text)
        }
        .padding(10)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
        .accessibilityIdentifier("project-path-matrix.relationships.accessible-list")
    }

    @ViewBuilder
    private func detailPane(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = selectedNode(in: snapshot) {
                VStack(alignment: .leading, spacing: 0) {
                    if let focusNodeIDs = snapshot.focusNodeIDs,
                       !focusNodeIDs.contains(node.id) {
                        selectionNotice(snapshot: snapshot)
                    }
                    selectedDetail(for: node, snapshot: snapshot)
                }
            } else if let session = selectedSession(in: snapshot) {
                VStack(alignment: .leading, spacing: 0) {
                    selectionNotice(snapshot: snapshot)
                    sessionDetail(for: session)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Label("选择一个节点", systemImage: "cursorarrow.click")
                        .harvisFont(.subheadline.weight(.semibold))
                        .foregroundColor(theme.text)
                    Text("项目、会话、角色和未解析来源都会在这里显示详情。")
                        .harvisFont(.caption)
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                .padding(13)
            }
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 1))
        .accessibilityIdentifier("project-path-matrix.relationships.detail")
    }

    private func selectionNotice(
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        Text(selectionNoticeLabel(snapshot: snapshot))
            .harvisFont(.caption)
            .foregroundColor(theme.accent2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, 10)
    }

    private func selectionNoticeLabel(
        snapshot: RelationshipRenderSnapshot
    ) -> String {
        guard let selectedSession = selectedSession(in: snapshot) else {
            return "此节点被当前筛选隐藏，详情仍保留。"
        }
        if let scopedProjectIDs = snapshot.scopedProjectIDs,
           !scopedProjectIDs.contains(selectedSession.projectID) {
            return "此会话被当前项目筛选排除，详情仍保留。"
        }
        if focusRelatedOnly {
            return "此节点被当前相关节点聚焦隐藏，详情仍保留。"
        }
        return "此会话当前被显示范围省略，详情仍保留。"
    }

    @ViewBuilder
    private func selectedDetail(
        for node: ManagedProjectPathMatrixRelationshipNode,
        snapshot: RelationshipRenderSnapshot
    ) -> some View {
        switch node.kind {
        case .project:
            projectDetail(for: node)
        case .session:
            if let session = selectedSession(in: snapshot) {
                sessionDetail(for: session)
            } else {
                unavailableDetail(title: "会话未加载", subtitle: node.subtitle)
            }
        case .placeholder:
            placeholderDetail(for: node)
        case .role:
            auxiliaryDetail(
                title: node.title,
                subtitle: node.subtitle,
                systemImage: "person.2",
                detail: "这是关系图中的角色说明节点。它按服务与账号分组，不代表一个可打开的会话。"
            )
        case .task:
            auxiliaryDetail(
                title: node.title,
                subtitle: node.subtitle,
                systemImage: "checklist",
                detail: "这是会话显式提供的可选任务绑定。"
            )
        }
    }

    private func projectDetail(
        for node: ManagedProjectPathMatrixRelationshipNode
    ) -> some View {
        let project = projects.first { $0.id == (node.projectID ?? node.id) }
        return VStack(alignment: .leading, spacing: 0) {
            detailHeader(
                title: project?.normalizedName ?? node.title,
                subtitle: project?.kind.label ?? node.subtitle,
                systemImage: project?.kind.systemImage ?? "square.stack.3d.up"
            )
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    if let project {
                        detailField("路径", value: project.normalizedPath ?? "未提供路径")
                        detailField("用途", value: project.purpose?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            ? project.purpose!
                            : "未提供用途")
                        detailField(
                            "层级与会话",
                            value: "子路径 \(project.childCount) · 本层会话 \(project.directSessionCount) · 含子路径 \(project.sessionCount)"
                        )
                        if let reason = project.healthReason {
                            detailField("状态", value: "\(project.healthLabel ?? "待分析") · \(reason)")
                        }
                    } else {
                        detailField("项目 ID", value: node.projectID ?? node.id)
                        detailField("状态", value: "项目节点不在当前范围")
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 140, idealHeight: 230, maxHeight: 360)
            Divider().overlay(theme.line)
            HStack {
                Spacer(minLength: 0)
                Button {
                    narrowDetailsPresented = false
                    onProject(node.projectID ?? node.id)
                } label: {
                    Label("进入项目", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .accessibilityIdentifier("project-path-matrix.detail.open-project.\(node.projectID ?? node.id)")
                .accessibilityLabel("进入项目 \(project?.normalizedName ?? node.title)")
            }
            .padding(10)
        }
    }

    private func sessionDetail(
        for session: ManagedProjectPathMatrixSession
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(
                title: session.title,
                subtitle: "\(session.sourceLabel) · \(session.statusLabel)",
                systemImage: session.provider.systemImage
            )
            HStack(spacing: 7) {
                Button {
                    narrowDetailsPresented = false
                    onSession(session.id)
                } label: {
                    Label("在工作台查看", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .accessibilityIdentifier("project-path-matrix.detail.open-session.\(session.id)")
                .accessibilityLabel("在工作台查看会话 \(session.title)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 9) {
                    if let content = originalSessionContent(for: session) {
                        content
                    } else {
                        sessionFallbackContent(for: session)
                    }

                    DisclosureGroup("关系详情", isExpanded: $relationDetailsExpanded) {
                        VStack(alignment: .leading, spacing: 7) {
                            detailField("来源", value: session.sourceIdentity.displayLabel)
                            detailField("角色", value: session.roleLabel)
                            if let parent = session.parentThreadID, !parent.isEmpty {
                                detailField(
                                    "父会话引用",
                                    value: "\(session.provider.label) · \(session.sourceScope) · \(parent)"
                                )
                            }
                            detailField("根会话记录", value: session.rootThreadID)
                            if let task = session.taskBinding {
                                detailField("任务绑定", value: "\(task.label) · \(task.statusLabel ?? "未提供状态")")
                            }
                        }
                    }
                    .harvisFont(.caption.weight(.semibold))
                    .foregroundColor(theme.text)
                }
                .padding(12)
            }
            .frame(minHeight: 170, idealHeight: 460, maxHeight: 560)
        }
    }

    private func originalSessionContent(
        for session: ManagedProjectPathMatrixSession
    ) -> AnyView? {
        guard let sessionContent else { return nil }
        return sessionContent(session)
    }

    private func sessionFallbackContent(
        for session: ManagedProjectPathMatrixSession
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("会话卡片暂不可用", systemImage: "bubble.left")
                .harvisFont(.caption.weight(.semibold))
                .foregroundColor(theme.text)
            Text("\(session.provider.label) · \(session.statusLabel)")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
            Text("来源：\(session.sourceIdentity.displayLabel)")
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .textSelection(.enabled)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ManagedProjectPathMatrixPalette.sessionSurface(for: theme))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func placeholderDetail(
        for node: ManagedProjectPathMatrixRelationshipNode
    ) -> some View {
        let identity = node.sourceIdentity
        return VStack(alignment: .leading, spacing: 0) {
            detailHeader(
                title: node.title,
                subtitle: node.subtitle,
                systemImage: "questionmark.circle"
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("该父会话记录不在当前范围。虚线关系表示待核查，不代表已找到可打开的父会话。")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                if let identity {
                    detailField("服务", value: identity.provider.label)
                    detailField("账号范围", value: identity.sourceScope.isEmpty ? "未标识范围" : identity.sourceScope)
                    detailField("会话 ID", value: identity.sourceID)
                }
            }
            .padding(12)
        }
    }

    private func auxiliaryDetail(
        title: String,
        subtitle: String,
        systemImage: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(title: title, subtitle: subtitle, systemImage: systemImage)
            Text(detail)
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }

    private func unavailableDetail(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailHeader(title: title, subtitle: subtitle, systemImage: "questionmark.circle")
            Text("当前会话详情不可用。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .padding(12)
        }
    }

    private func detailHeader(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .harvisFont(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .harvisFont(.subheadline.weight(.semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(3)
                Text(subtitle)
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private func detailField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .harvisFont(.caption2.weight(.semibold))
                .foregroundColor(theme.muted)
            Text(value)
                .harvisFont(.caption)
                .foregroundColor(theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(theme.surfaceAlt.opacity(theme.isDark ? 0.62 : 0.52))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func nodeAccessibilityLabel(
        _ node: ManagedProjectPathMatrixRelationshipNode
    ) -> String {
        let kind: String
        switch node.kind {
        case .project: kind = "项目"
        case .session: kind = "会话"
        case .placeholder: kind = "未解析来源"
        case .role: kind = "角色"
        case .task: kind = "任务"
        }
        return "\(kind)：\(node.title)，\(node.subtitle)"
    }

    private func relationAccessibilityLabel(
        _ edge: ManagedProjectPathMatrixRelationshipEdge,
        snapshot: RelationshipRenderSnapshot
    ) -> String {
        let unresolved = edge.isUnresolved ? "，未解析" : ""
        return "\(edge.label)：\(nodeTitle(edge.from, snapshot: snapshot)) 到 \(nodeTitle(edge.to, snapshot: snapshot))\(unresolved)"
    }

    private func nodeTitle(
        _ id: String,
        snapshot: RelationshipRenderSnapshot
    ) -> String {
        snapshot.nodesByID[id]?.title ?? id
    }

    private func clearStaleSelection(
        snapshot: RelationshipRenderSnapshot
    ) {
        guard let selectedNodeID else { return }
        let isVisible = snapshot.nodesByID[selectedNodeID] != nil
        let isKnownSession = snapshot.allSessions.contains {
            ManagedProjectPathMatrixRelationshipProjection.sessionNodeID($0.id) == selectedNodeID
        }
        let isKnownProject = projects.contains { $0.id == selectedNodeID }
        guard isVisible || isKnownSession || isKnownProject else {
            self.selectedNodeID = nil
            return
        }
    }

    private func projectSort(
        _ lhs: ManagedProjectPathMatrixNode,
        _ rhs: ManagedProjectPathMatrixNode
    ) -> Bool {
        let order = lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
        return order == .orderedAscending || (order == .orderedSame && lhs.id < rhs.id)
    }

    private func edgeEndpoints(
        from: CGPoint,
        to: CGPoint,
        nodeSize: CGSize
    ) -> (start: CGPoint, end: CGPoint) {
        var start = from
        var end = to
        if abs(to.x - from.x) < 1 {
            start.x += nodeSize.width / 2
            end.x += nodeSize.width / 2
        } else if to.x > from.x {
            start.x += nodeSize.width / 2
            end.x -= nodeSize.width / 2
        } else {
            start.x -= nodeSize.width / 2
            end.x += nodeSize.width / 2
        }
        return (start, end)
    }

    private func nodeSystemImage(
        _ node: ManagedProjectPathMatrixRelationshipNode
    ) -> String {
        switch node.kind {
        case .project: return node.isPlaceholder ? "questionmark.folder" : "square.stack.3d.up.fill"
        case .session: return "bubble.left.and.bubble.right"
        case .placeholder: return "questionmark.circle"
        case .role: return node.roleLabel == "Sidechat" ? "bubble.left.and.bubble.right" : "person.2"
        case .task: return "checklist"
        }
    }

    private func nodeColor(
        _ node: ManagedProjectPathMatrixRelationshipNode
    ) -> Color {
        switch node.kind {
        case .project: return ManagedProjectPathMatrixPalette.project(for: theme)
        case .session: return ManagedProjectPathMatrixPalette.session(for: theme)
        case .placeholder: return theme.accent2
        case .role: return theme.accent2
        case .task: return theme.positive
        }
    }

    private func nodeSurface(
        _ node: ManagedProjectPathMatrixRelationshipNode
    ) -> Color {
        switch node.kind {
        case .project: return ManagedProjectPathMatrixPalette.projectSurface(for: theme)
        case .session: return ManagedProjectPathMatrixPalette.sessionSurface(for: theme)
        case .placeholder: return theme.accent2.opacity(theme.isDark ? 0.15 : 0.08)
        case .role: return theme.accent2.opacity(theme.isDark ? 0.13 : 0.07)
        case .task: return theme.positive.opacity(theme.isDark ? 0.13 : 0.07)
        }
    }

    private func relationColor(
        _ kind: ManagedProjectPathMatrixRelationshipKind
    ) -> Color {
        switch kind {
        case .projectHierarchy: return ManagedProjectPathMatrixPalette.folder(for: theme)
        case .projectAssignment: return ManagedProjectPathMatrixPalette.project(for: theme)
        case .conversationParent: return ManagedProjectPathMatrixPalette.session(for: theme)
        case .role: return theme.accent2
        case .rootFamily: return theme.accent
        case .taskBinding: return theme.positive
        }
    }
}
