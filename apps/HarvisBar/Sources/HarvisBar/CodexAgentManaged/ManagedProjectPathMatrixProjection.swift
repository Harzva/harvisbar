import Foundation
import SwiftUI

/// Presentation-only session data used by the native structure surface. The
/// source thread remains authoritative for opening and inspecting a session.
///
/// The source identity fields deliberately travel with the projection. A
/// source ID alone is not enough to resolve a parent because the same ID may
/// exist in another account, runtime, or provider.
struct ManagedProjectPathMatrixSession: Identifiable, Hashable {
    let id: String
    let title: String
    let provider: ManagedChatProvider
    let sourceScope: String
    let sourceID: String
    let threadSource: String?
    let parentThreadID: String?
    let rootThreadID: String
    let isSubagent: Bool
    let isSidechat: Bool
    let agentDisplayName: String?
    let agentTaskLabel: String?
    /// A friendly account/configuration label supplied by the caller. It is
    /// presentation metadata only and never participates in identity lookup.
    let sourceDisplayLabel: String?
    let taskBinding: ManagedProjectPathMatrixTaskBinding?
    let projectID: String
    let assignmentSourceLabel: String?
    let cwd: String
    let createdAt: Int64
    let updatedAt: Int64
    let updatedLabel: String
    let statusLabel: String
    let statusSystemImage: String
    let isRunning: Bool
    let isArchived: Bool

    init(
        thread: ManagedChatThread,
        projectID: String? = nil,
        taskBinding: ManagedProjectPathMatrixTaskBinding? = nil,
        sourceDisplayLabel: String? = nil
    ) {
        let normalizedTitle = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve source identity bytes exactly. Whitespace is only used to
        // decide whether a display title/token is empty; it must never turn
        // one source ID or account scope into another source ID or scope.
        let sourceScope = thread.sourceScope
        let sourceID = thread.sourceID
        // Decode the documented legacy adapter prefix exactly once at this
        // boundary. The graph itself receives opaque source IDs and must not
        // guess whether a source ID containing `::` is an encoded reference.
        let rootPrefix: String
        switch thread.provider {
        case .codex: rootPrefix = "codex::"
        case .dsh: rootPrefix = "\(sourceScope)::"
        case .workBuddy: rootPrefix = "workbuddy::"
        }
        let rootID = thread.rootThreadId.hasPrefix(rootPrefix)
            ? String(thread.rootThreadId.dropFirst(rootPrefix.count))
            : thread.rootThreadId

        self.init(
            id: thread.id,
            title: normalizedTitle.isEmpty ? "未命名会话" : normalizedTitle,
            provider: thread.provider,
            projectID: projectID ?? ManagedChatProjectResolver.resolve(thread: thread).id,
            cwd: thread.cwd,
            updatedLabel: thread.updatedLabel,
            statusLabel: Self.statusLabel(for: thread),
            statusSystemImage: Self.statusSystemImage(for: thread),
            isRunning: thread.isCardRunning,
            isArchived: thread.archived,
            sourceScope: sourceScope,
            sourceID: sourceID,
            threadSource: thread.threadSource,
            parentThreadID: thread.parentThreadID,
            rootThreadID: Self.isBlank(rootID) ? sourceID : rootID,
            isSubagent: thread.isSubagent,
            isSidechat: thread.isSidechat,
            agentDisplayName: Self.nonempty(thread.agentNickname),
            agentTaskLabel: thread.agentTaskLabel,
            taskBinding: taskBinding,
            assignmentSourceLabel: thread.managementProjectAssignment?.source.rawValue,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            sourceDisplayLabel: sourceDisplayLabel
        )
    }

    /// Explicit initializer retained for previews and projection tests that
    /// do not need to construct a full source thread.
    init(
        id: String,
        title: String,
        provider: ManagedChatProvider,
        projectID: String,
        cwd: String,
        updatedLabel: String,
        statusLabel: String,
        statusSystemImage: String,
        isRunning: Bool,
        isArchived: Bool,
        sourceScope: String = "",
        sourceID: String? = nil,
        threadSource: String? = nil,
        parentThreadID: String? = nil,
        rootThreadID: String? = nil,
        isSubagent: Bool = false,
        isSidechat: Bool = false,
        agentDisplayName: String? = nil,
        agentTaskLabel: String? = nil,
        taskBinding: ManagedProjectPathMatrixTaskBinding? = nil,
        assignmentSourceLabel: String? = nil,
        createdAt: Int64 = 0,
        updatedAt: Int64 = 0,
        sourceDisplayLabel: String? = nil
    ) {
        let normalizedID = id
        let rawSourceID = sourceID ?? normalizedID
        let rawRootID = rootThreadID ?? rawSourceID

        self.id = Self.isBlank(normalizedID) ? rawSourceID : normalizedID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名会话"
            : title
        self.provider = provider
        self.sourceScope = sourceScope
        self.sourceID = rawSourceID
        self.threadSource = threadSource
        self.parentThreadID = parentThreadID
        self.rootThreadID = Self.isBlank(rawRootID) ? rawSourceID : rawRootID
        self.isSubagent = isSubagent
        self.isSidechat = isSidechat
        self.agentDisplayName = agentDisplayName
        self.agentTaskLabel = agentTaskLabel
        self.sourceDisplayLabel = Self.nonempty(sourceDisplayLabel)
        self.taskBinding = taskBinding
        self.projectID = projectID
        self.assignmentSourceLabel = assignmentSourceLabel
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedLabel = updatedLabel
        self.statusLabel = statusLabel
        self.statusSystemImage = statusSystemImage
        self.isRunning = isRunning
        self.isArchived = isArchived
    }

    var sourceIdentity: ManagedProjectPathMatrixSourceIdentity {
        ManagedProjectPathMatrixSourceIdentity(
            provider: provider,
            sourceScope: sourceScope,
            sourceID: sourceID
        )
    }

    var roleLabel: String {
        if isSidechat { return "Sidechat" }
        if isSubagent { return "子智能体" }
        return "主会话"
    }

    var sourceLabel: String {
        let scope = sourceDisplayLabel ?? (Self.isBlank(sourceScope) ? "未标识范围" : sourceScope)
        return "\(provider.label) · \(scope)"
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func statusLabel(for thread: ManagedChatThread) -> String {
        if thread.isCardRunning { return "进行中" }
        if thread.archived { return "已归档" }
        if isWaitingStatus(thread.sourceStatus) { return "等待处理" }

        switch normalizedStatus(thread.sourceStatus) {
        case "idle", "ready", "configured", "standby", "空闲":
            return "空闲"
        case "complete", "completed", "done", "success", "succeeded", "finished", "已结束":
            return "已结束"
        case .some where !(normalizedStatus(thread.sourceStatus)?.isEmpty ?? true):
            return "未知状态"
        default:
            return "空闲"
        }
    }

    private static func statusSystemImage(for thread: ManagedChatThread) -> String {
        if thread.isCardRunning { return "activity" }
        if thread.archived { return "archivebox" }
        if isWaitingStatus(thread.sourceStatus) { return "circle.pause" }

        switch normalizedStatus(thread.sourceStatus) {
        case "complete", "completed", "done", "success", "succeeded", "finished", "已结束":
            return "checkmark.circle"
        case .some where !(normalizedStatus(thread.sourceStatus)?.isEmpty ?? true):
            return "questionmark.circle"
        default:
            return "circle"
        }
    }

    private static func normalizedStatus(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isWaitingStatus(_ value: String?) -> Bool {
        guard let value = normalizedStatus(value) else { return false }
        return value.contains("wait")
            || value.contains("pending")
            || value.contains("queued")
            || value.contains("pause")
            || value.contains("等待")
            || value.contains("待处理")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func == (
        lhs: ManagedProjectPathMatrixSession,
        rhs: ManagedProjectPathMatrixSession
    ) -> Bool {
        lhs.id == rhs.id && lhs.sourceIdentity == rhs.sourceIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(sourceIdentity)
    }
}

/// A task edge is optional because the current source adapters do not always
/// expose an explicit task plan binding for every conversation.
struct ManagedProjectPathMatrixTaskBinding: Hashable, Sendable, Identifiable {
    let id: String
    let label: String
    let statusLabel: String?

    init(id: String, label: String, statusLabel: String? = nil) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = normalizedID.isEmpty ? normalizedLabel : normalizedID
        self.label = normalizedLabel.isEmpty ? "未命名任务" : normalizedLabel
        self.statusLabel = statusLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The provider, scope, and source ID form one complete conversation
/// identity. Parent lookup and unresolved placeholders use this value without
/// falling back to cwd, title, or an ID from another account.
struct ManagedProjectPathMatrixSourceIdentity: Hashable {
    let provider: ManagedChatProvider
    let sourceScope: String
    let sourceID: String

    var key: String {
        let encoded = ManagedProjectPathMatrixIdentityKeyCodec.encode([
            provider.rawValue, sourceScope, sourceID
        ])
        return "identity::\(encoded)"
    }

    var displayLabel: String {
        let scope = sourceScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未标识范围"
            : sourceScope
        return "\(provider.label) · \(scope) · \(sourceID)"
    }

    static func == (
        lhs: ManagedProjectPathMatrixSourceIdentity,
        rhs: ManagedProjectPathMatrixSourceIdentity
    ) -> Bool {
        lhs.provider.rawValue == rhs.provider.rawValue
            && lhs.sourceScope == rhs.sourceScope
            && lhs.sourceID == rhs.sourceID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(provider.rawValue)
        hasher.combine(sourceScope)
        hasher.combine(sourceID)
    }
}

/// Length-prefixed components are injective while keeping the public key type
/// as `String`. Raw source IDs and scopes may themselves contain `::`.
private enum ManagedProjectPathMatrixIdentityKeyCodec {
    static func encode(_ components: [String]) -> String {
        components
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }
}

enum ManagedProjectPathMatrixDisplayMode: String, CaseIterable, Identifiable {
    case structure
    case relationships

    var id: String { rawValue }

    var title: String {
        switch self {
        case .structure: return "结构视图"
        case .relationships: return "关系图"
        }
    }

    var systemImage: String {
        switch self {
        case .structure: return "rectangle.grid.1x2"
        case .relationships: return "point.3.connected.trianglepath.dotted"
        }
    }
}

enum ManagedProjectPathMatrixRelationshipKind: String, CaseIterable, Identifiable, Hashable {
    case projectHierarchy
    case projectAssignment
    case conversationParent
    case role
    case rootFamily
    case taskBinding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectHierarchy: return "项目层级"
        case .projectAssignment: return "项目归属"
        case .conversationParent: return "同一来源父子"
        case .role: return "智能体角色"
        case .rootFamily: return "同一根会话"
        case .taskBinding: return "任务绑定"
        }
    }

    var systemImage: String {
        switch self {
        case .projectHierarchy: return "folder"
        case .projectAssignment: return "arrow.right"
        case .conversationParent: return "arrow.down.right"
        case .role: return "person.2"
        case .rootFamily: return "link"
        case .taskBinding: return "checklist"
        }
    }
}

struct ManagedProjectPathMatrixRelationshipNode: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case project
        case session
        case placeholder
        case role
        case task
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let projectID: String?
    let parentID: String?
    let sessionID: String?
    let sourceIdentity: ManagedProjectPathMatrixSourceIdentity?
    let roleLabel: String?
    let taskBinding: ManagedProjectPathMatrixTaskBinding?
    let isPlaceholder: Bool
}

struct ManagedProjectPathMatrixRelationshipEdge: Identifiable, Hashable {
    let id: String
    let from: String
    let to: String
    let kind: ManagedProjectPathMatrixRelationshipKind
    let label: String
    let isUnresolved: Bool
}

/// Pure relationship projection used by the graph view and tests. It is
/// intentionally independent of SwiftUI state: session caps, exact lineage
/// matching, unresolved placeholders, and deterministic ordering can all be
/// checked without rendering a window.
struct ManagedProjectPathMatrixRelationshipProjection {
    static let defaultSessionLimit = 72
    static let sessionIncrement = 72
    static let maximumSessionLimit = 300

    let nodes: [ManagedProjectPathMatrixRelationshipNode]
    let edges: [ManagedProjectPathMatrixRelationshipEdge]
    let visibleSessions: [ManagedProjectPathMatrixSession]
    let totalSessionCount: Int
    let displayedSessionCount: Int
    let omittedSessionCount: Int
    let sessionOffset: Int
    let hasPreviousPage: Bool
    let hasNextPage: Bool
    /// Parent/root edges whose endpoint is known in the complete input but is
    /// outside the displayed session page. They are counted even when a
    /// neutral "not in the current range" placeholder keeps the edge visible.
    let omittedRelationshipCount: Int
    /// Invalid cyclic or ambiguous lineage relationships are rejected rather
    /// than connected across an unsafe identity boundary.
    let rejectedRelationshipCount: Int
    let relationshipNotes: [String]

    private enum ReferenceResolution {
        case resolved(ManagedProjectPathMatrixSession)
        case unavailable
        case ambiguous

        var resolvedSession: ManagedProjectPathMatrixSession? {
            guard case let .resolved(session) = self else { return nil }
            return session
        }

        var isAmbiguous: Bool {
            if case .ambiguous = self { return true }
            return false
        }
    }

    private struct RootReference {
        let token: String?
        let endpoint: ManagedProjectPathMatrixSession?
        let rawID: String?
        let isAmbiguous: Bool
    }

    init(
        projects: [ManagedProjectPathMatrixNode],
        sessions: [ManagedProjectPathMatrixSession],
        sessionLimit: Int = ManagedProjectPathMatrixRelationshipProjection.defaultSessionLimit,
        sessionOffset: Int = 0
    ) {
        let uniqueSessions = Self.uniqueSessions(sessions)
        let orderedSessions = uniqueSessions.sorted(by: Self.sessionSort)
        let boundedLimit = min(max(0, sessionLimit), Self.maximumSessionLimit)
        let boundedOffset = min(max(0, sessionOffset), orderedSessions.count)
        let displayed = Array(
            orderedSessions.dropFirst(boundedOffset).prefix(boundedLimit)
        )
        let projectOrder = Self.uniqueProjects(projects).sorted(by: Self.projectSort)

        let sessionByIdentity = Dictionary(
            grouping: uniqueSessions,
            by: { $0.sourceIdentity }
        )
        let sessionByManagedID = Dictionary(
            grouping: uniqueSessions,
            by: { $0.id }
        )

        let projectIDs = Set(projectOrder.map(\.id))
        let projectParentByID = Dictionary(
            uniqueKeysWithValues: projectOrder.compactMap { project -> (String, String)? in
                guard let parentID = project.parentID,
                      projectIDs.contains(parentID) else { return nil }
                return (project.id, parentID)
            }
        )
        let cyclicProjectIDs = Self.cycleIDs(in: projectParentByID)

        let sessionParentByID = Dictionary(
            uniqueSessions.compactMap { child -> (String, String)? in
                guard case let .resolved(parent) = Self.resolveSessionReference(
                    for: child,
                    referenceID: child.parentThreadID,
                    byIdentity: sessionByIdentity,
                    byManagedID: sessionByManagedID
                ) else { return nil }
                return (child.id, parent.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let cyclicSessionIDs = Self.cycleIDs(in: sessionParentByID)

        var graphNodes: [ManagedProjectPathMatrixRelationshipNode] = projectOrder.map {
            ManagedProjectPathMatrixRelationshipNode(
                id: $0.id,
                kind: .project,
                title: $0.normalizedName,
                subtitle: $0.kind.label,
                projectID: $0.id,
                parentID: cyclicProjectIDs.contains($0.id) ? nil : $0.parentID,
                sessionID: nil,
                sourceIdentity: nil,
                roleLabel: nil,
                taskBinding: nil,
                isPlaceholder: false
            )
        }
        var graphEdges: [ManagedProjectPathMatrixRelationshipEdge] = []
        var graphEdgeIDs = Set<String>()
        var nodeIDs = Set(graphNodes.map(\.id))
        var omittedRelationships = 0
        var rejectedRelationships = 0
        var relationshipNotes: [String] = []

        func addNote(_ note: String) {
            if !relationshipNotes.contains(note) {
                relationshipNotes.append(note)
            }
        }

        func appendNode(_ node: ManagedProjectPathMatrixRelationshipNode) {
            guard nodeIDs.insert(node.id).inserted else { return }
            graphNodes.append(node)
        }

        func appendEdge(
            from: String,
            to: String,
            kind: ManagedProjectPathMatrixRelationshipKind,
            label: String,
            isUnresolved: Bool = false
        ) {
            let edge = ManagedProjectPathMatrixRelationshipEdge(
                id: Self.edgeID(from: from, to: to, kind: kind),
                from: from,
                to: to,
                kind: kind,
                label: label,
                isUnresolved: isUnresolved
            )
            guard graphEdgeIDs.insert(edge.id).inserted else { return }
            graphEdges.append(edge)
        }

        // Project hierarchy is explicit in the path matrix. A missing project
        // parent is kept out of this graph rather than inferred from a path.
        for project in projectOrder {
            guard let parentID = project.parentID,
                  projectIDs.contains(parentID) else { continue }
            if cyclicProjectIDs.contains(project.id) {
                rejectedRelationships += 1
                addNote("检测到循环项目层级；循环边已省略。")
                continue
            }
            appendEdge(
                from: parentID,
                to: project.id,
                kind: .projectHierarchy,
                label: ManagedProjectPathMatrixRelationshipKind.projectHierarchy.title
            )
        }

        let visibleSessionIDs = Set(displayed.map(\.id))

        for session in displayed {
            let sessionNodeID = Self.sessionNodeID(session.id)
            appendNode(Self.sessionNode(for: session))

            // Assignment IDs were selected by the parent path hierarchy and
            // are carried through unchanged. If a target is unavailable, show
            // a project placeholder rather than resolving by cwd.
            if !session.projectID.isEmpty {
                if !nodeIDs.contains(session.projectID) {
                    appendNode(
                        ManagedProjectPathMatrixRelationshipNode(
                            id: session.projectID,
                            kind: .project,
                            title: "项目未加载",
                            subtitle: "项目归属目标：\(session.projectID)",
                            projectID: session.projectID,
                            parentID: nil,
                            sessionID: nil,
                            sourceIdentity: nil,
                            roleLabel: nil,
                            taskBinding: nil,
                            isPlaceholder: true
                        )
                    )
                }
                appendEdge(
                    from: session.projectID,
                    to: sessionNodeID,
                    kind: .projectAssignment,
                    label: ManagedProjectPathMatrixRelationshipKind.projectAssignment.title
                )
            }

            if let parentID = session.parentThreadID, !Self.isBlank(parentID) {
                let resolution = Self.resolveSessionReference(
                    for: session,
                    referenceID: parentID,
                    byIdentity: sessionByIdentity,
                    byManagedID: sessionByManagedID
                )
                if Self.isSelfReference(
                    child: session,
                    referenceID: parentID,
                    resolved: resolution
                ) || (cyclicSessionIDs.contains(session.id) && resolution.resolvedSession != nil) {
                    rejectedRelationships += 1
                    addNote("检测到循环会话父子关系；循环边已省略。")
                } else if let parent = resolution.resolvedSession,
                          visibleSessionIDs.contains(parent.id) {
                    appendEdge(
                        from: Self.sessionNodeID(parent.id),
                        to: sessionNodeID,
                        kind: .conversationParent,
                        label: ManagedProjectPathMatrixRelationshipKind.conversationParent.title
                    )
                } else {
                    if resolution.isAmbiguous {
                        rejectedRelationships += 1
                        addNote("存在来源身份不明确的父会话引用；未跨来源连接。")
                    }
                    let identity = resolution.resolvedSession?.sourceIdentity
                        ?? ManagedProjectPathMatrixSourceIdentity(
                            provider: session.provider,
                            sourceScope: session.sourceScope,
                            sourceID: parentID
                        )
                    let placeholderID = Self.placeholderNodeID(
                        for: identity,
                        disambiguator: Self.hasUsableScope(session.sourceScope) ? nil : session.id
                    )
                    appendNode(
                        ManagedProjectPathMatrixRelationshipNode(
                            id: placeholderID,
                            kind: .placeholder,
                            title: "父会话不在当前范围",
                            subtitle: identity.displayLabel,
                            projectID: session.projectID,
                            parentID: nil,
                            sessionID: nil,
                            sourceIdentity: identity,
                            roleLabel: "同一来源父会话",
                            taskBinding: nil,
                            isPlaceholder: true
                        )
                    )
                    appendEdge(
                        from: placeholderID,
                        to: sessionNodeID,
                        kind: .conversationParent,
                        label: ManagedProjectPathMatrixRelationshipKind.conversationParent.title,
                        isUnresolved: true
                    )
                    if resolution.resolvedSession != nil {
                        omittedRelationships += 1
                    }
                }
            }

            if session.isSubagent || session.isSidechat {
                let role = session.isSidechat ? "sidechat" : "subagent"
                let roleParts: [String] = Self.hasUsableScope(session.sourceScope)
                    ? [session.provider.rawValue, session.sourceScope, role]
                    : [session.provider.rawValue, session.id, role]
                let roleNodeID = "role::\(ManagedProjectPathMatrixIdentityKeyCodec.encode(roleParts))"
                appendNode(
                    ManagedProjectPathMatrixRelationshipNode(
                        id: roleNodeID,
                        kind: .role,
                        title: session.isSidechat ? "Sidechat" : "子智能体",
                        subtitle: "\(session.provider.label) · \(Self.displayScope(for: session))",
                        projectID: session.projectID,
                        parentID: nil,
                        sessionID: nil,
                        sourceIdentity: nil,
                        roleLabel: session.isSidechat ? "Sidechat" : "子智能体",
                        taskBinding: nil,
                        isPlaceholder: false
                    )
                )
                appendEdge(
                    from: roleNodeID,
                    to: sessionNodeID,
                    kind: .role,
                    label: session.isSidechat ? "Sidechat 角色" : "子智能体角色"
                )
            }

            if let task = session.taskBinding {
                let taskParts: [String] = Self.hasUsableScope(session.sourceScope)
                    ? [session.provider.rawValue, session.sourceScope, task.id]
                    : [session.provider.rawValue, session.id, task.id]
                let taskNodeID = "task::\(ManagedProjectPathMatrixIdentityKeyCodec.encode(taskParts))"
                appendNode(
                    ManagedProjectPathMatrixRelationshipNode(
                        id: taskNodeID,
                        kind: .task,
                        title: task.label,
                        subtitle: task.statusLabel ?? "任务计划",
                        projectID: session.projectID,
                        parentID: nil,
                        sessionID: nil,
                        sourceIdentity: nil,
                        roleLabel: nil,
                        taskBinding: task,
                        isPlaceholder: false
                    )
                )
                appendEdge(
                    from: taskNodeID,
                    to: sessionNodeID,
                    kind: .taskBinding,
                    label: ManagedProjectPathMatrixRelationshipKind.taskBinding.title
                )
            }
        }

        let rootReferences = Dictionary(
            uniqueSessions.map { session in
                (
                    session.id,
                    Self.rootReference(
                        for: session,
                        byIdentity: sessionByIdentity,
                        byManagedID: sessionByManagedID
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        let rootedSessions = uniqueSessions.compactMap { session -> (String, ManagedProjectPathMatrixSession)? in
            guard let token = rootReferences[session.id]?.token else { return nil }
            return (
                Self.rootFamilyKey(
                    provider: session.provider,
                    sourceScope: session.sourceScope,
                    rootToken: token
                ),
                session
            )
        }
        let allRootGroups = Dictionary(grouping: rootedSessions, by: { $0.0 })
            .mapValues { $0.map(\.1) }
        let visibleRootGroups = Dictionary(grouping: displayed.compactMap { session -> (String, ManagedProjectPathMatrixSession)? in
            guard let token = rootReferences[session.id]?.token else { return nil }
            return (
                Self.rootFamilyKey(
                    provider: session.provider,
                    sourceScope: session.sourceScope,
                    rootToken: token
                ),
                session
            )
        }, by: { $0.0 })
            .mapValues { $0.map(\.1) }

        for key in allRootGroups.keys.sorted() {
            guard let allMembers = allRootGroups[key],
                  let visibleMembers = visibleRootGroups[key],
                  !visibleMembers.isEmpty else { continue }
            let orderedVisibleMembers = visibleMembers.sorted(by: Self.sessionSort)
            let endpointIDs = Set(
                allMembers.compactMap { rootReferences[$0.id]?.endpoint?.id }
            )
            let endpoint = endpointIDs.count == 1
                // `endpointIDs` contains the actual root session IDs. Looking
                // up a member by the reference that points at that ID would
                // select the child as the root and fabricate a child-root
                // edge when the root's own metadata is incomplete.
                ? allMembers.compactMap { rootReferences[$0.id]?.endpoint }
                    .first { $0.id == endpointIDs.first }
                : nil
            if endpointIDs.count > 1 {
                rejectedRelationships += 1
                addNote("存在来源身份不明确的根会话引用；未跨来源连接。")
            }

            if let endpoint, visibleSessionIDs.contains(endpoint.id) {
                for member in orderedVisibleMembers where member.id != endpoint.id {
                    appendEdge(
                        from: Self.sessionNodeID(endpoint.id),
                        to: Self.sessionNodeID(member.id),
                        kind: .rootFamily,
                        label: "同一根会话 · 根会话记录"
                    )
                }
            } else {
                guard let representative = orderedVisibleMembers.first,
                      let reference = rootReferences[representative.id],
                      let rawID = reference.rawID,
                      !Self.isBlank(rawID) else { continue }
                let identity = endpoint?.sourceIdentity
                    ?? ManagedProjectPathMatrixSourceIdentity(
                        provider: representative.provider,
                        sourceScope: representative.sourceScope,
                        sourceID: reference.token ?? rawID
                    )
                let placeholderID = Self.rootPlaceholderNodeID(
                    for: identity,
                    disambiguator: Self.hasUsableScope(representative.sourceScope) ? nil : representative.id
                )
                appendNode(
                    ManagedProjectPathMatrixRelationshipNode(
                        id: placeholderID,
                        kind: .placeholder,
                        title: "根会话不在当前范围",
                        subtitle: identity.displayLabel,
                        projectID: representative.projectID,
                        parentID: nil,
                        sessionID: nil,
                        sourceIdentity: identity,
                        roleLabel: "同一根会话",
                        taskBinding: nil,
                        isPlaceholder: true
                    )
                )
                for member in orderedVisibleMembers {
                    appendEdge(
                        from: placeholderID,
                        to: Self.sessionNodeID(member.id),
                        kind: .rootFamily,
                        label: "同一根会话",
                        isUnresolved: true
                    )
                }
            }
            omittedRelationships += max(0, allMembers.count - orderedVisibleMembers.count)
        }

        // A missing/ambiguous/unscoped root cannot safely participate in a
        // grouped family. Keep its visible session reachable through a neutral
        // placeholder instead of guessing an account or parsing an opaque ID.
        for session in displayed {
            guard let reference = rootReferences[session.id],
                  reference.token == nil,
                  let rawID = reference.rawID,
                  !Self.isBlank(rawID), rawID != session.sourceID else { continue }
            if reference.isAmbiguous {
                rejectedRelationships += 1
                addNote("存在来源身份不明确的根会话引用；未跨来源连接。")
            } else if !Self.hasUsableScope(session.sourceScope) {
                addNote("未标识来源范围的会话不建立跨会话根关系。")
            }
            let identity = ManagedProjectPathMatrixSourceIdentity(
                provider: session.provider,
                sourceScope: session.sourceScope,
                sourceID: rawID
            )
            let placeholderID = Self.rootPlaceholderNodeID(
                for: identity,
                disambiguator: session.id
            )
            appendNode(
                ManagedProjectPathMatrixRelationshipNode(
                    id: placeholderID,
                    kind: .placeholder,
                    title: "根会话不在当前范围",
                    subtitle: identity.displayLabel,
                    projectID: session.projectID,
                    parentID: nil,
                    sessionID: nil,
                    sourceIdentity: identity,
                    roleLabel: "同一根会话",
                    taskBinding: nil,
                    isPlaceholder: true
                )
            )
            appendEdge(
                from: placeholderID,
                to: Self.sessionNodeID(session.id),
                kind: .rootFamily,
                label: "同一根会话",
                isUnresolved: true
            )
        }

        if !cyclicProjectIDs.isEmpty || !cyclicSessionIDs.isEmpty {
            addNote("检测到循环关系；相关边已省略。")
        }
        if omittedRelationships > 0 {
            addNote("部分关系端点不在当前范围；可通过分页查看。")
        }

        self.nodes = graphNodes
        self.edges = graphEdges
        self.visibleSessions = displayed
        self.totalSessionCount = uniqueSessions.count
        self.displayedSessionCount = displayed.count
        self.omittedSessionCount = uniqueSessions.count - displayed.count
        self.sessionOffset = boundedOffset
        self.hasPreviousPage = boundedOffset > 0
        self.hasNextPage = boundedOffset + displayed.count < uniqueSessions.count
        self.omittedRelationshipCount = omittedRelationships
        self.rejectedRelationshipCount = rejectedRelationships
        self.relationshipNotes = relationshipNotes
    }

    static func sessionNodeID(_ sessionID: String) -> String {
        "session::\(sessionID)"
    }

    static func placeholderNodeID(
        for identity: ManagedProjectPathMatrixSourceIdentity,
        disambiguator: String? = nil
    ) -> String {
        let parts = [identity.provider.rawValue, identity.sourceScope, identity.sourceID]
            + (disambiguator.map { [$0] } ?? [])
        return "placeholder::parent::\(ManagedProjectPathMatrixIdentityKeyCodec.encode(parts))"
    }

    private static func rootPlaceholderNodeID(
        for identity: ManagedProjectPathMatrixSourceIdentity,
        disambiguator: String? = nil
    ) -> String {
        let parts = [identity.provider.rawValue, identity.sourceScope, identity.sourceID]
            + (disambiguator.map { [$0] } ?? [])
        return "placeholder::root::\(ManagedProjectPathMatrixIdentityKeyCodec.encode(parts))"
    }

    private static func sessionNode(
        for session: ManagedProjectPathMatrixSession
    ) -> ManagedProjectPathMatrixRelationshipNode {
        let role = session.roleLabel
        let status = session.statusLabel
        let source = session.sourceLabel
        return ManagedProjectPathMatrixRelationshipNode(
            id: sessionNodeID(session.id),
            kind: .session,
            title: session.title,
            subtitle: "\(source) · \(status)",
            projectID: session.projectID,
            parentID: nil,
            sessionID: session.id,
            sourceIdentity: session.sourceIdentity,
            roleLabel: role,
            taskBinding: session.taskBinding,
            isPlaceholder: false
        )
    }

    private static func uniqueSessions(
        _ sessions: [ManagedProjectPathMatrixSession]
    ) -> [ManagedProjectPathMatrixSession] {
        var seen = Set<String>()
        return sessions.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueProjects(
        _ projects: [ManagedProjectPathMatrixNode]
    ) -> [ManagedProjectPathMatrixNode] {
        var seen = Set<String>()
        return projects.filter { seen.insert($0.id).inserted }
    }

    private static func sessionSort(
        _ lhs: ManagedProjectPathMatrixSession,
        _ rhs: ManagedProjectPathMatrixSession
    ) -> Bool {
        if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func projectSort(
        _ lhs: ManagedProjectPathMatrixNode,
        _ rhs: ManagedProjectPathMatrixNode
    ) -> Bool {
        let nameOrder = lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func resolveSessionReference(
        for child: ManagedProjectPathMatrixSession,
        referenceID: String?,
        byIdentity: [ManagedProjectPathMatrixSourceIdentity: [ManagedProjectPathMatrixSession]],
        byManagedID: [String: [ManagedProjectPathMatrixSession]]
    ) -> ReferenceResolution {
        guard let referenceID, !isBlank(referenceID), hasUsableScope(child.sourceScope) else {
            return .unavailable
        }

        // Treat the supplied value as an opaque raw source ID first. Never
        // split a source ID on `::`; source adapters may legitimately contain
        // that sequence in an ID.
        let sourceIdentity = ManagedProjectPathMatrixSourceIdentity(
            provider: child.provider,
            sourceScope: child.sourceScope,
            sourceID: referenceID
        )
        if let candidates = byIdentity[sourceIdentity] {
            let matchingCandidates = candidates.filter { Self.sameSource(child, $0) }
            if matchingCandidates.count == 1 { return .resolved(matchingCandidates[0]) }
            return matchingCandidates.isEmpty ? .unavailable : .ambiguous
        }

        // A managed ID is accepted only after its candidate metadata proves
        // the exact provider and scope. This prevents a same-ID sibling from
        // another account/provider becoming a parent by string coincidence.
        let managedCandidates = (byManagedID[referenceID] ?? []).filter {
            sameSource(child, $0)
        }
        if managedCandidates.count == 1 { return .resolved(managedCandidates[0]) }
        return managedCandidates.isEmpty ? .unavailable : .ambiguous
    }

    private static func rootReference(
        for session: ManagedProjectPathMatrixSession,
        byIdentity: [ManagedProjectPathMatrixSourceIdentity: [ManagedProjectPathMatrixSession]],
        byManagedID: [String: [ManagedProjectPathMatrixSession]]
    ) -> RootReference {
        let rawID = isBlank(session.rootThreadID) ? nil : session.rootThreadID
        guard let rawID else {
            return RootReference(token: nil, endpoint: nil, rawID: nil, isAmbiguous: false)
        }
        guard hasUsableScope(session.sourceScope) else {
            return RootReference(token: nil, endpoint: nil, rawID: rawID, isAmbiguous: false)
        }
        // The source ID is already the root. This is a self fact and does not
        // guess another account.
        if rawID == session.sourceID {
            return RootReference(token: session.sourceID, endpoint: session, rawID: rawID, isAmbiguous: false)
        }
        switch resolveSessionReference(
            for: session,
            referenceID: rawID,
            byIdentity: byIdentity,
            byManagedID: byManagedID
        ) {
        case .resolved(let endpoint):
            return RootReference(
                token: endpoint.sourceID,
                endpoint: endpoint,
                rawID: rawID,
                isAmbiguous: false
            )
        case .ambiguous:
            return RootReference(token: nil, endpoint: nil, rawID: rawID, isAmbiguous: true)
        case .unavailable:
            break
        }

        return RootReference(token: rawID, endpoint: nil, rawID: rawID, isAmbiguous: false)
    }

    private static func rootFamilyKey(
        provider: ManagedChatProvider,
        sourceScope: String,
        rootToken: String
    ) -> String {
        let encoded = ManagedProjectPathMatrixIdentityKeyCodec.encode([
            provider.rawValue, sourceScope, rootToken
        ])
        return "root::\(encoded)"
    }

    private static func sameSource(
        _ lhs: ManagedProjectPathMatrixSession,
        _ rhs: ManagedProjectPathMatrixSession
    ) -> Bool {
        lhs.provider == rhs.provider
            && hasUsableScope(lhs.sourceScope)
            && lhs.sourceScope == rhs.sourceScope
    }

    private static func isSelfReference(
        child: ManagedProjectPathMatrixSession,
        referenceID: String,
        resolved: ReferenceResolution
    ) -> Bool {
        if referenceID == child.id || referenceID == child.sourceID { return true }
        if case let .resolved(parent) = resolved {
            return parent.id == child.id
        }
        return false
    }

    private static func hasUsableScope(_ scope: String) -> Bool {
        !isBlank(scope)
    }

    private static func displayScope(
        for session: ManagedProjectPathMatrixSession
    ) -> String {
        session.sourceDisplayLabel
            ?? (hasUsableScope(session.sourceScope) ? session.sourceScope : "未标识范围")
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func cycleIDs(in parentByID: [String: String]) -> Set<String> {
        var state: [String: Int] = [:]
        var cyclic = Set<String>()

        for start in parentByID.keys {
            guard state[start] != 2 else { continue }
            var path: [String] = []
            var pathIndex: [String: Int] = [:]
            var current: String? = start
            while let currentID = current {
                if let index = pathIndex[currentID] {
                    cyclic.formUnion(path[index...])
                    break
                }
                if state[currentID] == 2 { break }
                pathIndex[currentID] = path.count
                path.append(currentID)
                state[currentID] = 1
                current = parentByID[currentID]
            }
            for id in path { state[id] = 2 }
        }
        return cyclic
    }

    private static func edgeID(
        from: String,
        to: String,
        kind: ManagedProjectPathMatrixRelationshipKind
    ) -> String {
        let encoded = ManagedProjectPathMatrixIdentityKeyCodec.encode([
            kind.rawValue, from, to
        ])
        return "edge::\(encoded)"
    }
}

/// Deterministic, dependency-free placement for the relationship canvas.
/// Projects and explanatory nodes share the left lane, and sessions stay on
/// the right. This leaves an open corridor for relationship edges. The layout remains stable
/// when a user changes relation filters or selects a node.
struct ManagedProjectPathMatrixRelationshipLayout {
    let positions: [String: CGPoint]
    let canvasSize: CGSize
    let nodeSize: CGSize

    init(projection: ManagedProjectPathMatrixRelationshipProjection) {
        self.init(nodes: projection.nodes, edges: projection.edges)
    }

    /// Re-layout an already filtered node/edge set. The graph view uses this
    /// when relation toggles hide nodes; using the full projection here would
    /// leave filtered nodes occupying invisible columns and rows.
    init(
        nodes: [ManagedProjectPathMatrixRelationshipNode],
        edges _: [ManagedProjectPathMatrixRelationshipEdge] = []
    ) {
        self.nodeSize = CGSize(width: 210, height: 76)

        let projectNodes = nodes.filter { $0.kind == .project }
        let auxiliaryNodes = nodes.filter {
            $0.kind == .role || $0.kind == .placeholder || $0.kind == .task
        }
        let sessionNodes = nodes.filter { $0.kind == .session }
        let projectDepths = Self.projectDepths(for: projectNodes)
        let maxDepth = projectDepths.values.max() ?? 0
        let projectX = 36 + nodeSize.width / 2
        let auxiliaryX = projectX + CGFloat(maxDepth) * 116
        let sessionX = auxiliaryX + 310

        var result: [String: CGPoint] = [:]
        var maxY = CGFloat(0)
        let verticalSpacing = nodeSize.height + 18

        let orderedProjects = projectNodes.sorted {
            let lhsDepth = projectDepths[$0.id] ?? 0
            let rhsDepth = projectDepths[$1.id] ?? 0
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedAscending || (order == .orderedSame && $0.id < $1.id)
        }
        for (index, node) in orderedProjects.enumerated() {
            let depth = projectDepths[node.id] ?? 0
            let point = CGPoint(
                x: projectX + CGFloat(depth) * 116,
                y: 38 + CGFloat(index) * verticalSpacing
            )
            result[node.id] = point
            maxY = max(maxY, point.y + nodeSize.height / 2)
        }

        let orderedAuxiliary = auxiliaryNodes.sorted {
            let lhs = "\($0.kind.rawValue)::\($0.title)"
            let rhs = "\($1.kind.rawValue)::\($1.title)"
            return lhs.localizedStandardCompare(rhs) == .orderedAscending || (lhs == rhs && $0.id < $1.id)
        }
        for (index, node) in orderedAuxiliary.enumerated() {
            let point = CGPoint(
                x: auxiliaryX,
                y: 38 + CGFloat(projectNodes.count + index) * verticalSpacing
            )
            result[node.id] = point
            maxY = max(maxY, point.y + nodeSize.height / 2)
        }

        let orderedSessions = sessionNodes.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedAscending || (order == .orderedSame && $0.id < $1.id)
        }
        for (index, node) in orderedSessions.enumerated() {
            let point = CGPoint(
                x: sessionX,
                y: 38 + CGFloat(index) * verticalSpacing
            )
            result[node.id] = point
            maxY = max(maxY, point.y + nodeSize.height / 2)
        }

        let maxX = max(projectX, max(auxiliaryX, sessionX)) + nodeSize.width / 2
        self.positions = result
        self.canvasSize = CGSize(
            width: max(620, maxX + 64),
            height: max(360, maxY + 36)
        )
    }

    private static func projectDepths(
        for nodes: [ManagedProjectPathMatrixRelationshipNode]
    ) -> [String: Int] {
        let parentByID = Dictionary(
            nodes.compactMap { node -> (String, String)? in
                guard let parent = node.parentID, parent != node.id else { return nil }
                return (node.id, parent)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var depths: [String: Int] = [:]

        // Resolve each functional parent chain iteratively. Cyclic input gets
        // depth zero for the cycle members, so layout remains finite and does
        // not assign arbitrary increasing depths around a loop.
        for node in nodes where depths[node.id] == nil {
            var path: [String] = []
            var pathIndex: [String: Int] = [:]
            var current: String? = node.id
            while let currentID = current, depths[currentID] == nil {
                if let cycleStart = pathIndex[currentID] {
                    for cycleID in path[cycleStart...] {
                        depths[cycleID] = 0
                    }
                    break
                }
                pathIndex[currentID] = path.count
                path.append(currentID)
                current = parentByID[currentID]
            }

            var nextDepth = current.flatMap { depths[$0] } ?? 0
            for id in path.reversed() where depths[id] == nil {
                depths[id] = nextDepth
                nextDepth += 1
            }
        }
        return depths
    }
}
