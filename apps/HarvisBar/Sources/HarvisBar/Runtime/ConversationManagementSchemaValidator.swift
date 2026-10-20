import Foundation

/// Provider-specific eligibility is supplied at the integration boundary.
/// The schema and validator never infer it from display text or provider names.
struct ConversationManagementValidationPolicyV1: Equatable, Sendable {
    let allowedTargets: Set<ConversationManagementTargetV1>
    let maxDecisions: Int

    init(
        allowedTargets: Set<ConversationManagementTargetV1>,
        maxDecisions: Int = ConversationManagementSchemaV1.maxDecisionsPerProposal
    ) {
        self.allowedTargets = allowedTargets
        self.maxDecisions = maxDecisions
    }
}

enum ConversationManagementSchemaValidatorV1 {
    static func validate(
        snapshot: ConversationManagementSnapshotV1
    ) throws {
        try requireCurrentVersion(snapshot.schemaVersion)
        try requireNonempty(snapshot.projectID, field: "projectID")
        try requireNonnegative(snapshot.revision, field: "revision")
        try validate(taskPlan: snapshot.taskPlan)

        if let openTaskCount = snapshot.completionEvidence.openTaskCount {
            try requireNonnegative(
                openTaskCount,
                field: "completionEvidence.openTaskCount"
            )
        }
        if snapshot.completionEvidence.taskFreshness == .fresh {
            guard snapshot.completionEvidence.openTaskCount != nil,
                  snapshot.completionEvidence.observedAt != nil else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "completionEvidence",
                    reason: "fresh task evidence requires a count and observation time"
                )
            }
        }

        var targets: Set<ConversationManagementTargetV1> = []
        for record in snapshot.conversations {
            let target = record.base.target
            try validate(target: target)
            guard targets.insert(target).inserted else {
                throw ConversationManagementSchemaErrorV1.duplicateTarget(
                    target.stableID
                )
            }
            guard record.base.projectID == snapshot.projectID else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "conversations.base.projectID",
                    reason: "must match the containing project"
                )
            }
            try requireNonempty(record.base.role, field: "conversations.base.role")
            try validate(progress: record.base.progress)
            try requireNonnegative(
                record.base.evidence.revision,
                field: "conversations.base.evidence.revision"
            )
            if let extensionValue = record.managementExtension {
                guard extensionValue.target == target else {
                    throw ConversationManagementSchemaErrorV1.targetMismatch(
                        target.stableID
                    )
                }
                try requireNonnegative(
                    extensionValue.revision,
                    field: "conversations.managementExtension.revision"
                )
                var boundTaskIDs: Set<String> = []
                for binding in extensionValue.taskBindings {
                    try requireNonempty(
                        binding.taskID,
                        field: "conversations.managementExtension.taskBindings.taskID"
                    )
                    try requireNonempty(
                        binding.projectID,
                        field: "conversations.managementExtension.taskBindings.projectID"
                    )
                    try validate(target: binding.target)
                    guard binding.projectID == snapshot.projectID,
                          binding.target == target else {
                        throw ConversationManagementSchemaErrorV1.invalidValue(
                            field: "conversations.managementExtension.taskBindings",
                            reason: "project and target must exactly match the containing conversation"
                        )
                    }
                    guard boundTaskIDs.insert(binding.taskID).inserted else {
                        throw ConversationManagementSchemaErrorV1.invalidValue(
                            field: "conversations.managementExtension.taskBindings",
                            reason: "task IDs must be unique per conversation"
                        )
                    }
                }
            }
        }
    }

    static func validate(
        proposal: ConversationManagementProposalV1,
        snapshot: ConversationManagementSnapshotV1,
        ledger: ConversationManagementProgressLedgerV1,
        policy: ConversationManagementValidationPolicyV1
    ) throws {
        try validate(snapshot: snapshot)
        try validate(ledger: ledger)
        try requireCurrentVersion(proposal.schemaVersion)

        guard proposal.runID == ledger.runID else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "runID",
                reason: "must match the progress ledger"
            )
        }
        guard proposal.projectID == snapshot.projectID,
              proposal.projectID == ledger.projectID else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "projectID",
                reason: "must match both snapshot and progress ledger"
            )
        }
        guard snapshot.brainEnabled else {
            throw ConversationManagementSchemaErrorV1.brainDisabled(
                snapshot.projectID
            )
        }
        guard proposal.expectedRevision == ledger.revision else {
            throw ConversationManagementSchemaErrorV1.staleRevision(
                expected: proposal.expectedRevision,
                actual: ledger.revision
            )
        }
        guard proposal.projectionRevision == snapshot.revision else {
            throw ConversationManagementSchemaErrorV1.staleRevision(
                expected: proposal.projectionRevision,
                actual: snapshot.revision
            )
        }
        guard proposal.cycle == ledger.cycle + 1 else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "cycle",
                reason: "must be exactly one greater than the ledger cycle"
            )
        }
        try requireNonempty(proposal.summary, field: "summary")
        guard !proposal.decisions.isEmpty else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "decisions",
                reason: "at least one decision is required"
            )
        }
        let effectiveMaximum = max(
            1,
            min(
                policy.maxDecisions,
                ConversationManagementSchemaV1.maxDecisionsPerProposal
            )
        )
        guard proposal.decisions.count <= effectiveMaximum else {
            throw ConversationManagementSchemaErrorV1.tooManyDecisions(
                proposal.decisions.count
            )
        }
        if proposal.decisions.contains(where: { $0.kind != .dispatch }),
           proposal.decisions.count != 1 {
            throw ConversationManagementSchemaErrorV1.mixedDecisionKinds
        }

        var decisionIDs: Set<UUID> = []
        for decision in proposal.decisions {
            guard decisionIDs.insert(decision.id).inserted else {
                throw ConversationManagementSchemaErrorV1.duplicateDecision(
                    decision.id
                )
            }
            try requireNonempty(
                decision.reason,
                field: "decisions[\(decision.id.uuidString)].reason"
            )
            switch decision.kind {
            case .dispatch:
                try validateDispatch(
                    decision,
                    snapshot: snapshot,
                    ledger: ledger,
                    policy: policy
                )
            case .complete:
                guard decision.target == nil,
                      blankToNil(decision.taskID) == nil,
                      blankToNil(decision.prompt) == nil,
                      blankToNil(decision.expectedEvidence) == nil else {
                    throw invalid(
                        decision,
                        "complete cannot carry a target, prompt, or expected evidence"
                    )
                }
                guard snapshot.supportsCompletion else {
                    throw ConversationManagementSchemaErrorV1
                        .completionEvidenceRequired
                }
            case .needsUser:
                guard decision.target == nil,
                      blankToNil(decision.taskID) == nil,
                      let prompt = blankToNil(decision.prompt),
                      blankToNil(decision.expectedEvidence) == nil else {
                    throw invalid(
                        decision,
                        "needs_user requires one question and no target or expected evidence"
                    )
                }
                try validatePromptLength(prompt, decision: decision)
            case .recommendHandoff:
                guard let target = decision.target,
                      blankToNil(decision.taskID) == nil,
                      blankToNil(decision.prompt) == nil,
                      blankToNil(decision.expectedEvidence) == nil else {
                    throw invalid(
                        decision,
                        "recommend_handoff requires only an eligible target and reason"
                    )
                }
                _ = try eligibleRecord(
                    for: target,
                    snapshot: snapshot,
                    policy: policy
                )
            }
        }
    }

    static func validate(
        ledger: ConversationManagementProgressLedgerV1
    ) throws {
        try requireCurrentVersion(ledger.schemaVersion)
        try requireNonempty(ledger.projectID, field: "ledger.projectID")
        try requireNonempty(ledger.objective, field: "ledger.objective")
        try requireNonnegative(ledger.revision, field: "ledger.revision")
        try requireNonnegative(ledger.cycle, field: "ledger.cycle")

        guard ledger.entries.count == ledger.revision else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "ledger.entries",
                reason: "entry count must equal the ledger revision"
            )
        }
        for (offset, entry) in ledger.entries.enumerated() {
            guard entry.revision == offset + 1 else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "ledger.entries.revision",
                    reason: "entries must have contiguous one-based revisions"
                )
            }
            try requireNonnegative(entry.cycle, field: "ledger.entries.cycle")
            if let target = entry.target {
                try validate(target: target)
            }
        }
        for memory in ledger.dispatchMemory {
            try validate(target: memory.target)
            try requireNonnegative(
                memory.evidenceRevision,
                field: "ledger.dispatchMemory.evidenceRevision"
            )
            try requireNonempty(
                memory.instructionFingerprint,
                field: "ledger.dispatchMemory.instructionFingerprint"
            )
        }
        if let proposal = ledger.latestProposal {
            guard proposal.runID == ledger.runID,
                  proposal.projectID == ledger.projectID,
                  proposal.cycle == ledger.cycle else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "ledger.latestProposal",
                    reason: "must match the containing run, project, and cycle"
                )
            }
        }
    }

    /// Stable across launches and independent of Swift's randomized `Hashable`.
    static func instructionFingerprint(_ value: String) -> String {
        let bytes = Array(normalizedInstruction(value).utf8)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    static func isGenericContinuation(_ value: String) -> Bool {
        let compact = normalizedInstruction(value).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        let bases = ["continue", "继续", "goon", "proceed", "keepgoing"]
        for base in bases where compact.hasPrefix(base) {
            var suffix = String(compact.dropFirst(base.count))
            if suffix.hasPrefix("x") {
                suffix.removeFirst()
            }
            if suffix.hasSuffix("times") {
                suffix.removeLast(5)
            } else if suffix.hasSuffix("time") {
                suffix.removeLast(4)
            } else if suffix.hasSuffix("次") {
                suffix.removeLast()
            }
            if suffix.isEmpty || suffix.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }

    private static func validateDispatch(
        _ decision: ConversationManagementDecisionV1,
        snapshot: ConversationManagementSnapshotV1,
        ledger: ConversationManagementProgressLedgerV1,
        policy: ConversationManagementValidationPolicyV1
    ) throws {
        guard let target = decision.target,
              let taskID = decision.taskID,
              blankToNil(taskID) != nil,
              let prompt = blankToNil(decision.prompt),
              let expectedEvidence = blankToNil(decision.expectedEvidence) else {
            throw invalid(
                decision,
                "dispatch requires an eligible target, exact task ID, semantic prompt, and expected evidence"
            )
        }
        let record = try eligibleRecord(
            for: target,
            snapshot: snapshot,
            policy: policy
        )
        let taskPlan = snapshot.taskPlan
        switch taskPlan.freshness {
        case .unavailable:
            throw ConversationManagementSchemaErrorV1.taskPlanUnavailable
        case .stale:
            throw ConversationManagementSchemaErrorV1.taskPlanStale
        case .fresh:
            guard taskPlan.isValid else {
                throw ConversationManagementSchemaErrorV1.taskPlanInvalid
            }
        }
        guard taskPlan.isAuthoritative else {
            throw ConversationManagementSchemaErrorV1.taskPlanInvalid
        }
        guard let task = taskPlan.task(id: taskID) else {
            throw ConversationManagementSchemaErrorV1.unknownTask(taskID)
        }
        guard task.status.isOpen else {
            throw ConversationManagementSchemaErrorV1.taskNotOpen(taskID)
        }
        guard record.managementExtension?.taskBindings.contains(where: {
            $0.taskID == taskID
                && $0.projectID == snapshot.projectID
                && $0.target == target
        }) == true else {
            throw ConversationManagementSchemaErrorV1.taskNotLinked(
                taskID: taskID,
                target: target.stableID
            )
        }
        guard record.managementExtension?.workKind == .task else {
            throw ConversationManagementSchemaErrorV1.taskWorkKindRequired(
                target.stableID
            )
        }
        try requireNonempty(
            expectedEvidence,
            field: "decisions[\(decision.id.uuidString)].expectedEvidence"
        )
        try validatePromptLength(prompt, decision: decision)
        if isGenericContinuation(prompt) {
            throw ConversationManagementSchemaErrorV1.genericContinuation(
                decision.id
            )
        }
        let fingerprint = instructionFingerprint(prompt)
        if ledger.dispatchMemory.contains(where: {
            $0.target == target
                && $0.instructionFingerprint == fingerprint
                && record.base.evidence.revision <= $0.evidenceRevision
        }) {
            throw ConversationManagementSchemaErrorV1
                .duplicateWithoutNewEvidence(decision.id)
        }
    }

    private static func eligibleRecord(
        for target: ConversationManagementTargetV1,
        snapshot: ConversationManagementSnapshotV1,
        policy: ConversationManagementValidationPolicyV1
    ) throws -> ConversationManagementRecordV1 {
        guard let record = snapshot.record(for: target) else {
            throw ConversationManagementSchemaErrorV1.unknownTarget(
                target.stableID
            )
        }
        guard policy.allowedTargets.contains(target) else {
            throw ConversationManagementSchemaErrorV1.targetNotAllowed(
                target.stableID
            )
        }
        guard record.isEnrolled(
            projectDefaultEnabled: snapshot.projectDefaultEnrollmentEnabled
        ) else {
            throw ConversationManagementSchemaErrorV1.targetExcluded(
                target.stableID
            )
        }
        return record
    }

    private static func validate(
        taskPlan: ConversationProjectTaskPlanProjectionV1
    ) throws {
        switch taskPlan.freshness {
        case .unavailable:
            guard taskPlan.sourceRevision == nil,
                  taskPlan.observedAt == nil,
                  !taskPlan.isValid,
                  taskPlan.tasks.isEmpty else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskPlan",
                    reason: "unavailable task plans cannot carry revision, observation, validity, or tasks"
                )
            }
        case .stale:
            guard let revision = taskPlan.sourceRevision else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskPlan.sourceRevision",
                    reason: "stale task plans require a source revision"
                )
            }
            try requireNonempty(revision, field: "taskPlan.sourceRevision")
            guard taskPlan.observedAt != nil else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskPlan.observedAt",
                    reason: "stale task plans require the last observation time"
                )
            }
        case .fresh:
            guard let revision = taskPlan.sourceRevision else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskPlan.sourceRevision",
                    reason: "fresh task plans require a source revision"
                )
            }
            try requireNonempty(revision, field: "taskPlan.sourceRevision")
            guard taskPlan.observedAt != nil else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskPlan.observedAt",
                    reason: "fresh task plans require an observation time"
                )
            }
        }
        guard taskPlan.isValid || taskPlan.tasks.isEmpty else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "taskPlan.tasks",
                reason: "invalid task plans must fail closed with no tasks"
            )
        }

        var taskIDs: Set<String> = []
        for task in taskPlan.tasks {
            try requireNonempty(task.taskID, field: "taskPlan.tasks.taskID")
            try requireNonempty(task.title, field: "taskPlan.tasks.title")
            try requireNonempty(task.owner, field: "taskPlan.tasks.owner")
            guard taskIDs.insert(task.taskID).inserted else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskPlan.tasks",
                    reason: "task IDs must be unique"
                )
            }
            guard task.evidence.count <= 5 else {
                throw ConversationManagementSchemaErrorV1.invalidValue(
                    field: "taskPlan.tasks.evidence",
                    reason: "at most five safe evidence references are allowed"
                )
            }
            let allowedEvidenceKinds: Set<String> = [
                "source_event_id",
                "approval_id",
                "handoff_id",
                "run_id",
                "packet_id",
            ]
            for reference in task.evidence {
                guard allowedEvidenceKinds.contains(reference.kind),
                      isSafeEvidenceID(reference.id) else {
                    throw ConversationManagementSchemaErrorV1.invalidValue(
                        field: "taskPlan.tasks.evidence",
                        reason: "must contain only supported kinds and safe ASCII IDs"
                    )
                }
            }
        }
    }

    private static func isSafeEvidenceID(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                return true
            default:
                return false
            }
        }
    }

    private static func validate(target: ConversationManagementTargetV1) throws {
        try requireNonempty(target.provider, field: "target.provider")
        try requireNonempty(target.sourceScope, field: "target.sourceScope")
        try requireNonempty(target.sourceID, field: "target.sourceID")
    }

    private static func validate(
        progress: ConversationProgressProjectionV1
    ) throws {
        if let completed = progress.completedUnitCount {
            try requireNonnegative(
                completed,
                field: "progress.completedUnitCount"
            )
        }
        if let total = progress.totalUnitCount {
            try requireNonnegative(total, field: "progress.totalUnitCount")
        }
        if let completed = progress.completedUnitCount,
           let total = progress.totalUnitCount,
           completed > total {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: "progress",
                reason: "completed units cannot exceed total units"
            )
        }
    }

    private static func validatePromptLength(
        _ value: String,
        decision: ConversationManagementDecisionV1
    ) throws {
        guard !value.contains("\0"),
              value.count <= ConversationManagementSchemaV1.maxPromptCharacters else {
            throw invalid(
                decision,
                "prompt contains NUL or exceeds the v1 character limit"
            )
        }
    }

    private static func requireCurrentVersion(_ actual: Int) throws {
        guard actual == ConversationManagementSchemaV1.version else {
            throw ConversationManagementSchemaErrorV1.unsupportedVersion(
                expected: ConversationManagementSchemaV1.version,
                actual: actual
            )
        }
    }

    private static func requireNonnegative(
        _ value: Int,
        field: String
    ) throws {
        guard value >= 0 else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: field,
                reason: "must be nonnegative"
            )
        }
    }

    private static func requireNonempty(
        _ value: String,
        field: String
    ) throws {
        guard let normalized = blankToNil(value),
              !normalized.contains("\0"),
              normalized.count <= 8_000 else {
            throw ConversationManagementSchemaErrorV1.invalidValue(
                field: field,
                reason: "must be nonempty, bounded, and contain no NUL"
            )
        }
    }

    private static func normalizedInstruction(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func invalid(
        _ decision: ConversationManagementDecisionV1,
        _ reason: String
    ) -> ConversationManagementSchemaErrorV1 {
        .invalidDecision(decision.id, reason)
    }
}
