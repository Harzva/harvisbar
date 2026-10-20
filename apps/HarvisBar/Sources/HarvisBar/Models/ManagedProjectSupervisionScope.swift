import Foundation

/// The result of projecting one exact project management snapshot into a
/// read-only roster. The roster is intentionally derived from the snapshot's
/// records rather than from the cards currently visible in a view.
enum ManagedProjectSupervisionScopeEntryStatus: String, Codable, CaseIterable,
    Sendable
{
    case approvalCandidate
    case observation
    case enrollmentExcluded
    case unavailable

    var label: String {
        switch self {
        case .approvalCandidate: return "已纳入审批候选"
        case .observation: return "仅供观察"
        case .enrollmentExcluded: return "Enrollment 已关闭"
        case .unavailable: return "来源未加载或已失联"
        }
    }

    var systemImage: String {
        switch self {
        case .approvalCandidate: return "checkmark.shield"
        case .observation: return "eye"
        case .enrollmentExcluded: return "nosign"
        case .unavailable: return "questionmark.circle"
        }
    }
}

struct ManagedProjectSupervisionScopeEntry: Identifiable, Equatable, Sendable {
    let target: ConversationManagementTargetV1
    let title: String
    let providerLabel: String
    let sourceLabel: String
    let status: ManagedProjectSupervisionScopeEntryStatus
    let reason: String
    let enrollment: ConversationManagementEnrollmentV1
    let runtime: ConversationRuntimeStateV1
    let isConnected: Bool

    var id: String { target.stableID }

    var searchText: String {
        [title, providerLabel, sourceLabel, target.stableID, status.label, reason]
            .joined(separator: " ")
            .lowercased()
    }
}

/// Read-only scope evidence for one exact project. It carries no dispatch
/// handle and does not mutate the durable management snapshot.
struct ManagedProjectSupervisionScope: Equatable, Sendable {
    let projectID: String
    let projectLabel: String
    let projectDisplayPath: String
    let snapshotRevision: Int
    let snapshotGeneratedAt: Date
    let brainEnabled: Bool
    let projectDefaultEnrollmentEnabled: Bool
    let entries: [ManagedProjectSupervisionScopeEntry]

    var totalCount: Int { entries.count }

    var approvalCandidateCount: Int {
        entries.filter { $0.status == .approvalCandidate }.count
    }

    var observationCount: Int {
        entries.filter { $0.status == .observation }.count
    }

    var enrollmentExcludedCount: Int {
        entries.filter { $0.status == .enrollmentExcluded }.count
    }

    var unavailableCount: Int {
        entries.filter { $0.status == .unavailable }.count
    }

    /// Builds a scope from one exact snapshot and the complete provider
    /// inventory. `nil` means that the snapshot belongs to another project and
    /// therefore must not be rendered under this project.
    init?(
        project: ManagedChatProjectIdentity,
        snapshot: ConversationManagementSnapshotV1,
        threads: [ManagedChatThread],
        allowedTargets: Set<ConversationManagementTargetV1>? = nil,
        projectDefaultEnrollmentEnabled: Bool? = nil
    ) {
        guard snapshot.projectID == project.id else { return nil }

        let resolvedDefault = projectDefaultEnrollmentEnabled
            ?? snapshot.projectDefaultEnrollmentEnabled
        let resolvedAllowedTargets = allowedTargets
            ?? ConversationManagementProjectorV1.allowedTargets(
                project: project,
                threads: threads
            )
        var threadsByTarget: [ConversationManagementTargetV1: ManagedChatThread] = [:]
        for thread in threads {
            let target = ConversationManagementProjectorV1.target(for: thread)
            guard ManagedChatProjectResolver.resolve(thread: thread).id == project.id
            else { continue }
            // The target is the complete provider identity. Keep the first
            // exact occurrence so duplicate provider rows cannot alter scope.
            if threadsByTarget[target] == nil {
                threadsByTarget[target] = thread
            }
        }

        self.projectID = project.id
        self.projectLabel = project.label
        self.projectDisplayPath = project.displayPath
        self.snapshotRevision = snapshot.revision
        self.snapshotGeneratedAt = snapshot.generatedAt
        self.brainEnabled = snapshot.brainEnabled
        self.projectDefaultEnrollmentEnabled = resolvedDefault
        self.entries = snapshot.conversations
            .map { record in
                let target = record.base.target
                let thread = threadsByTarget[target]
                let enrollment = record.managementExtension?.enrollment ?? .inherit
                let isEnrolled = record.isEnrolled(
                    projectDefaultEnabled: resolvedDefault
                )
                let allowed = resolvedAllowedTargets.contains(target)
                let connected = thread != nil
                    && record.base.runtime != .disconnected
                let statusAndReason = Self.statusAndReason(
                    record: record,
                    thread: thread,
                    allowed: allowed,
                    isEnrolled: isEnrolled,
                    connected: connected,
                    brainEnabled: snapshot.brainEnabled,
                    projectDefaultEnrollmentEnabled: resolvedDefault
                )
                return ManagedProjectSupervisionScopeEntry(
                    target: target,
                    title: Self.title(for: record),
                    providerLabel: Self.providerLabel(for: target.provider),
                    sourceLabel: Self.sourceLabel(for: target, thread: thread),
                    status: statusAndReason.status,
                    reason: statusAndReason.reason,
                    enrollment: enrollment,
                    runtime: record.base.runtime,
                    isConnected: connected
                )
            }
            .sorted { $0.target.stableID < $1.target.stableID }
    }

    static func make(
        project: ManagedChatProjectIdentity,
        snapshot: ConversationManagementSnapshotV1,
        threads: [ManagedChatThread],
        allowedTargets: Set<ConversationManagementTargetV1>? = nil,
        projectDefaultEnrollmentEnabled: Bool? = nil
    ) -> Self? {
        Self(
            project: project,
            snapshot: snapshot,
            threads: threads,
            allowedTargets: allowedTargets,
            projectDefaultEnrollmentEnabled: projectDefaultEnrollmentEnabled
        )
    }

    private static func statusAndReason(
        record: ConversationManagementRecordV1,
        thread: ManagedChatThread?,
        allowed: Bool,
        isEnrolled: Bool,
        connected: Bool,
        brainEnabled: Bool,
        projectDefaultEnrollmentEnabled: Bool
    ) -> (
        status: ManagedProjectSupervisionScopeEntryStatus,
        reason: String
    ) {
        guard connected, let thread else {
            return (
                .unavailable,
                "来源会话当前未加载或已失联；该历史记录会保留用于核对，但不能派发。"
            )
        }

        guard allowed else {
            return (
                .observation,
                observationReason(for: thread)
            )
        }

        guard isEnrolled else {
            switch record.managementExtension?.enrollment ?? .inherit {
            case .inherit:
                return (
                    .enrollmentExcluded,
                    projectDefaultEnrollmentEnabled
                        ? "Enrollment=inherit；当前项目默认允许候选。"
                        : "Enrollment=inherit 且项目默认未开启，当前不进入审批候选。"
                )
            case .excluded:
                return (
                    .enrollmentExcluded,
                    "该对话已明确排除，当前不进入审批候选。"
                )
            case .enabled:
                // This branch is defensive: enabled always resolves true.
                return (
                    .enrollmentExcluded,
                    "Enrollment 配置未解析为已纳入，当前不进入审批候选。"
                )
            }
        }

        if brainEnabled {
            return (
                .approvalCandidate,
                "精确 target 在当前项目 allowlist 中且 Enrollment 已纳入；仍需有效任务计划、证据核验和逐项批准，当前不代表正在派发。"
            )
        }
        return (
            .approvalCandidate,
            "配置上已纳入审批候选；项目管理大脑当前已关闭，尚未开始监督。开启后仍需有效任务计划、证据核验和逐项批准。"
        )
    }

    private static func title(
        for record: ConversationManagementRecordV1
    ) -> String {
        let trimmed = record.base.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? "未命名会话" : trimmed
    }

    private static func providerLabel(for rawValue: String) -> String {
        switch rawValue.lowercased() {
        case ManagedChatProvider.codex.rawValue: return ManagedChatProvider.codex.label
        case ManagedChatProvider.dsh.rawValue: return ManagedChatProvider.dsh.label
        case ManagedChatProvider.workBuddy.rawValue:
            return ManagedChatProvider.workBuddy.label
        default: return rawValue.isEmpty ? "未知来源" : rawValue
        }
    }

    private static func sourceLabel(
        for target: ConversationManagementTargetV1,
        thread: ManagedChatThread?
    ) -> String {
        let scope = target.sourceScope.isEmpty ? "来源未指定" : target.sourceScope
        guard let thread else { return "\(scope) · 未加载" }
        if let nickname = thread.agentNickname?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !nickname.isEmpty {
            return "\(scope) · \(nickname)"
        }
        if let source = thread.threadSource?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !source.isEmpty {
            return "\(scope) · \(source)"
        }
        return scope
    }

    private static func observationReason(
        for thread: ManagedChatThread
    ) -> String {
        switch thread.taskCardType {
        case .sidechatParent:
            return "Sidechat 仅参与观察；项目管理审批候选只支持主会话与已持久化 Subagent。"
        case .transientSidechat:
            return "Transient Sidechat 没有可靠父会话目标，仅参与观察，不能进入项目管理审批候选。"
        case .dsh:
            if thread.isSubagent {
                return "DSH 子会话仅参与观察；DSH Supervisor 与项目管理审批候选都只接受顶层或 Codex 合约目标。"
            }
            return "DSH 会话由 DSH Supervisor 按单会话控制；它不会进入项目管理审批候选。"
        case .workBuddy:
            return "WorkBuddy 目前仅提供会话状态观察，尚未提供项目管理派发接口。"
        case .main, .persistedSubagent:
            return "该会话未通过当前项目派发 allowlist，仅参与观察。"
        }
    }
}
