import Foundation

struct ManagedProjectTaskPlan: Decodable, Equatable, Sendable {
    static let supportedSchemaVersion = "harvis.agent-room-task-plan.v1"

    let schemaVersion: String
    let sourceAvailable: Bool
    let sourceRevision: String?
    let isValid: Bool
    let invalidRecordCount: Int
    let tasks: [ManagedProjectTaskPlanItem]
}

struct ManagedProjectTaskPlanItem: Decodable, Equatable, Sendable {
    let taskId: String
    let title: String
    let description: String?
    let owner: String
    let status: String
    let updatedAt: String?
    let evidence: [ManagedProjectTaskEvidenceReference]
}

/// A deliberately narrow reference from the read-only task projection.
///
/// The wire contract carries identifiers only. It never transports evidence
/// bodies, filesystem paths, raw logs, or other private task metadata.
struct ManagedProjectTaskEvidenceReference: Decodable, Equatable, Sendable {
    let kind: String
    let id: String
}

enum ManagedProjectTaskPlanValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(String)
    case sourceUnavailable
    case invalidEnvelope(invalidRecordCount: Int)
    case invalidSourceRevision
    case invalidTask(taskID: String?)
    case duplicateTaskID(String)
    case unsupportedStatus(taskID: String, status: String)
    case invalidEvidence(taskID: String)
    case invalidTimestamp(taskID: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported project task plan schema: \(version)."
        case .sourceUnavailable:
            return "Project task source is unavailable."
        case let .invalidEnvelope(invalidRecordCount):
            let noun = invalidRecordCount == 1 ? "record" : "records"
            return "Project task plan is invalid (\(invalidRecordCount) invalid \(noun))."
        case .invalidSourceRevision:
            return "Project task plan source revision is invalid."
        case let .invalidTask(taskID):
            if let taskID {
                return "Project task plan contains an invalid task: \(taskID)."
            }
            return "Project task plan contains an invalid task."
        case let .duplicateTaskID(taskID):
            return "Project task plan contains duplicate task id: \(taskID)."
        case let .unsupportedStatus(taskID, status):
            return "Project task \(taskID) has unsupported status: \(status)."
        case let .invalidEvidence(taskID):
            return "Project task \(taskID) contains an invalid evidence reference."
        case let .invalidTimestamp(taskID):
            return "Project task \(taskID) contains an invalid update timestamp."
        }
    }
}

enum ManagedProjectTaskPlanProjector {
    private static let supportedEvidenceKinds: Set<String> = [
        "source_event_id",
        "approval_id",
        "handoff_id",
        "run_id",
        "packet_id",
    ]

    private static let supportedStatuses: Set<String> = [
        "pending",
        "in_progress",
        "waiting_approval",
        "blocked",
        "reviewing",
        "done",
        "cancelled",
        "archived",
        "closed",
    ]

    private static let openStatuses: Set<String> = [
        "pending",
        "in_progress",
        "waiting_approval",
        "blocked",
        "reviewing",
    ]

    static func summary(
        from plan: ManagedProjectTaskPlan
    ) throws -> ManagedProjectTaskSummary {
        guard plan.schemaVersion == ManagedProjectTaskPlan.supportedSchemaVersion else {
            throw ManagedProjectTaskPlanValidationError
                .unsupportedSchema(plan.schemaVersion)
        }
        guard plan.sourceAvailable else {
            throw ManagedProjectTaskPlanValidationError.sourceUnavailable
        }
        guard plan.isValid, plan.invalidRecordCount == 0 else {
            throw ManagedProjectTaskPlanValidationError.invalidEnvelope(
                invalidRecordCount: max(plan.invalidRecordCount, 0)
            )
        }
        guard let revision = plan.sourceRevision,
              isSHA256Revision(revision) else {
            throw ManagedProjectTaskPlanValidationError.invalidSourceRevision
        }

        var taskIDs: Set<String> = []
        for task in plan.tasks {
            let taskID = task.taskId.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let owner = task.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeID(taskID, maximumLength: 120),
                  !title.isEmpty,
                  title.count <= 300,
                  !owner.isEmpty,
                  owner.count <= 120,
                  task.description.map({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && $0.count <= 500
                  }) != false else {
                throw ManagedProjectTaskPlanValidationError.invalidTask(
                    taskID: taskID.isEmpty ? nil : taskID
                )
            }
            guard taskIDs.insert(taskID).inserted else {
                throw ManagedProjectTaskPlanValidationError.duplicateTaskID(taskID)
            }
            guard supportedStatuses.contains(task.status) else {
                throw ManagedProjectTaskPlanValidationError.unsupportedStatus(
                    taskID: taskID,
                    status: task.status
                )
            }
            var evidenceKeys: Set<String> = []
            guard task.evidence.count <= 5,
                  task.evidence.allSatisfy({ reference in
                      supportedEvidenceKinds.contains(reference.kind)
                          && isSafeID(reference.id, maximumLength: 500)
                          && evidenceKeys.insert(
                              "\(reference.kind)::\(reference.id)"
                          ).inserted
                  }) else {
                throw ManagedProjectTaskPlanValidationError.invalidEvidence(taskID: taskID)
            }
            if let updatedAt = task.updatedAt,
               !isRFC3339Timestamp(updatedAt) {
                throw ManagedProjectTaskPlanValidationError.invalidTimestamp(
                    taskID: taskID
                )
            }
        }

        let statuses = plan.tasks.map(\.status)
        return ManagedProjectTaskSummary(
            sourceAvailable: true,
            total: plan.tasks.count,
            done: statuses.filter { $0 == "done" }.count,
            open: statuses.filter { openStatuses.contains($0) }.count,
            blocked: statuses.filter { $0 == "blocked" }.count,
            waitingApproval: statuses.filter { $0 == "waiting_approval" }.count,
            reviewing: statuses.filter { $0 == "reviewing" }.count,
            sourceTruncated: false
        )
    }

    private static func isSHA256Revision(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy { character in
            character.isASCII
                && (character.isNumber || ("a" ... "f").contains(character))
        }
    }

    private static func isSafeID(
        _ value: String,
        maximumLength: Int
    ) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                return true
            default:
                return false
            }
        }
    }

    private static func isRFC3339Timestamp(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if fractional.date(from: value) != nil { return true }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value) != nil
    }
}
