import Foundation

/// A derived view of explicit project-task authority. Alignment is never
/// persisted and never inferred from titles, prompts, roles, or descriptions.
enum ConversationPlanAlignmentV1: String, Codable, CaseIterable, Sendable {
    case onPlan
    case exempt
    case outOfPlan
    case unknown
    case conflict
}

enum ConversationPlanAlignmentProjectorV1 {
    static let defaultGraceInterval: TimeInterval = 24 * 60 * 60

    static func alignment(
        for record: ConversationManagementRecordV1,
        taskPlan: ConversationProjectTaskPlanProjectionV1,
        now: Date = Date(),
        graceInterval: TimeInterval = defaultGraceInterval
    ) -> ConversationPlanAlignmentV1 {
        guard let extensionValue = record.managementExtension else {
            return .unknown
        }

        let bindings = extensionValue.taskBindings
        if bindings.contains(where: {
            $0.projectID != record.base.projectID
                || $0.target != record.base.target
                || $0.taskID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
        }) {
            return .conflict
        }
        if Set(bindings.map(\.taskID)).count != bindings.count {
            return .conflict
        }
        if extensionValue.workKind.isPlanExempt {
            return bindings.isEmpty ? .exempt : .conflict
        }

        guard taskPlan.isAuthoritative else {
            return .unknown
        }
        guard !bindings.isEmpty else {
            let boundedGrace = max(0, graceInterval)
            return now.timeIntervalSince(record.base.startedAt) < boundedGrace
                ? .unknown
                : .outOfPlan
        }

        guard extensionValue.workKind == .task else {
            return .conflict
        }

        var boundTasks: [ConversationProjectTaskV1] = []
        for binding in bindings {
            guard let task = taskPlan.task(id: binding.taskID) else {
                return .conflict
            }
            boundTasks.append(task)
        }
        if boundTasks.contains(where: { $0.status.isOpen }) {
            return .onPlan
        }

        switch record.base.runtime {
        case .running, .waitingApproval, .waitingUserInput:
            return .outOfPlan
        default:
            break
        }
        if boundTasks.contains(where: { task in
            guard let updatedAt = task.updatedAt else { return false }
            return record.base.observedAt > updatedAt
        }) {
            return .outOfPlan
        }
        guard boundTasks.allSatisfy({ $0.updatedAt != nil }) else {
            return .unknown
        }
        switch record.base.runtime {
        case .idle, .completed:
            return .onPlan
        case .unknown, .disconnected, .failed,
             .running, .waitingApproval, .waitingUserInput:
            return .unknown
        }
    }
}

extension ConversationManagementRecordV1 {
    func planAlignment(
        taskPlan: ConversationProjectTaskPlanProjectionV1,
        now: Date = Date(),
        graceInterval: TimeInterval = ConversationPlanAlignmentProjectorV1
            .defaultGraceInterval
    ) -> ConversationPlanAlignmentV1 {
        ConversationPlanAlignmentProjectorV1.alignment(
            for: self,
            taskPlan: taskPlan,
            now: now,
            graceInterval: graceInterval
        )
    }
}
