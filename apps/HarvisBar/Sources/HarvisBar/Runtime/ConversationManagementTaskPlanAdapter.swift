import Foundation

enum ConversationManagementTaskPlanAdapterV1 {
    static func projection(
        plan: ManagedProjectTaskPlan?,
        freshness: ManagedGovernanceFreshness,
        previous: ConversationProjectTaskPlanProjectionV1?,
        observedAt: Date = Date()
    ) throws -> ConversationProjectTaskPlanProjectionV1 {
        guard freshness.isFresh, let plan else {
            return ConversationManagementProjectorV1.makeTaskPlanProjection(
                sourceAvailable: false,
                sourceRevision: nil,
                isValid: false,
                tasks: [],
                observedAt: observedAt,
                previous: previous
            )
        }

        _ = try ManagedProjectTaskPlanProjector.summary(from: plan)
        let tasks = try plan.tasks.map { task in
            guard let status = ConversationProjectTaskStatusV1(
                rawValue: task.status
            ) else {
                throw ManagedProjectTaskPlanValidationError.unsupportedStatus(
                    taskID: task.taskId,
                    status: task.status
                )
            }
            let updatedAt: Date?
            if let value = task.updatedAt {
                guard let parsed = parseRFC3339(value) else {
                    throw ManagedProjectTaskPlanValidationError.invalidTimestamp(
                        taskID: task.taskId
                    )
                }
                updatedAt = parsed
            } else {
                updatedAt = nil
            }
            return ConversationProjectTaskV1(
                taskID: task.taskId,
                title: task.title,
                description: task.description,
                owner: task.owner,
                status: status,
                updatedAt: updatedAt,
                evidence: task.evidence.map {
                    ConversationProjectTaskEvidenceReferenceV1(
                        kind: $0.kind,
                        id: $0.id
                    )
                }
            )
        }
        return ConversationManagementProjectorV1.makeTaskPlanProjection(
            sourceAvailable: plan.sourceAvailable,
            sourceRevision: plan.sourceRevision,
            isValid: plan.isValid,
            tasks: tasks,
            observedAt: observedAt,
            previous: previous
        )
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
