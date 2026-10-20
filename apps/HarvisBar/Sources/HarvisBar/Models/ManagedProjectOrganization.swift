import CryptoKit
import Foundation

/// Harvis's logical catalog. A path is descriptive and never causes filesystem work.
struct ManagedProjectRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String = "project::\(UUID().uuidString)"
    var name: String
    var purpose: String
    var parentID: String? = nil
    var path: String? = nil
    var createdAt: Date = Date()
    var revision: Int = 0

    var identity: ManagedChatProjectIdentity {
        ManagedChatProjectIdentity(
            id: id,
            canonicalPath: path,
            displayPath: path ?? "未关联路径",
            label: name,
            resolution: path == nil ? .unassigned : .resolved
        )
    }
}

/// Identity and source facts captured before analysis; no source content is stored here.
struct ManagedProjectOrganizationConversation: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var storageKey: String
    var sourceRevision: String
    var sourceProject: ManagedChatProjectIdentity
    var effectiveProject: ManagedChatProjectIdentity
    var assignment: ManagedChatProjectAssignment? = nil
    var title: String = ""
    var provider: String = ""
}

enum ManagedProjectOrganizerAction: String, Codable, Equatable, Sendable {
    case assign
    case createSubproject
    case keep
}

enum ManagedProjectOrganizerConfidence: String, Codable, Equatable, Sendable {
    case strong
    case needsReview
}

struct ManagedProjectOrganizerSuggestion: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var action: ManagedProjectOrganizerAction
    var conversationIDs: [String]
    var targetProjectID: String? = nil
    var proposedProject: ManagedProjectRecord? = nil
    var reason: String
    var evidence: [String] = []
    var confidence: ManagedProjectOrganizerConfidence = .needsReview
    /// Analysis always produces false. Only the review UI may select an operation.
    var isSelected: Bool = false
}

struct ManagedProjectOrganizerProposal: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var createdAt: Date = Date()
    var baseStateRevision: Int
    var catalogFingerprint: String
    var snapshots: [ManagedProjectOrganizationConversation]
    var suggestions: [ManagedProjectOrganizerSuggestion]
}

struct ManagedProjectOrganizationAssignmentChange: Codable, Equatable, Sendable {
    var storageKey: String
    var conversationID: String
    var before: ManagedChatProjectAssignment?
    var after: ManagedChatProjectAssignment?
}

struct ManagedProjectOrganizationProjectChange: Codable, Equatable, Sendable {
    var projectID: String
    var before: ManagedProjectRecord?
    var after: ManagedProjectRecord?
}

struct ManagedProjectOrganizationReceipt: Codable, Equatable, Sendable, Identifiable {
    /// The proposal ID is also the idempotency key for the reviewed operation.
    var id: String
    var proposalFingerprint: String
    var appliedAt: Date
    var appliedRevision: Int
    var undoneAt: Date? = nil
    var assignmentChanges: [ManagedProjectOrganizationAssignmentChange]
    var projectChanges: [ManagedProjectOrganizationProjectChange]

    var isUndone: Bool { undoneAt != nil }
    var appliedConversationCount: Int { assignmentChanges.count }
    var createdProjectCount: Int {
        projectChanges.filter { $0.before == nil && $0.after != nil }.count
    }
}

/// One envelope is the authoritative catalog, assignment map, and undo journal.
struct ManagedProjectOrganizationState: Codable, Equatable, Sendable {
    var revision: Int = 0
    var projects: [String: ManagedProjectRecord] = [:]
    var assignments: [String: ManagedChatProjectAssignment] = [:]
    var history: [ManagedProjectOrganizationReceipt] = []
}

struct ManagedProjectOrganizationApplication: Equatable, Sendable {
    var state: ManagedProjectOrganizationState
    var receipt: ManagedProjectOrganizationReceipt
}

enum ManagedProjectOrganizationError: Error, Equatable, LocalizedError {
    case nothingSelected
    case staleState
    case staleCatalog
    case malformedProposal(String)
    case staleConversation(String)
    case conflictingConversation(String)
    case missingProject(String)
    case invalidProject(String)
    case projectCycle(String)
    case proposalAlreadyUndone
    case duplicateOperationMismatch
    case missingReceipt
    case undoConflict(String)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .nothingSelected: return "请先审核并勾选需要应用的建议。"
        case .staleState: return "项目归属已变化，请重新分析并审核。"
        case .staleCatalog: return "项目目录已变化，请重新分析并审核。"
        case .malformedProposal(let detail): return "整理建议不完整：\(detail)"
        case .staleConversation(let id): return "会话已变化，请重新分析：\(id)"
        case .conflictingConversation(let id): return "同一会话被分配到多条建议：\(id)"
        case .missingProject(let id): return "目标或父项目不存在，或尚未选中创建：\(id)"
        case .invalidProject(let id): return "项目名称、标识或路径无效：\(id)"
        case .projectCycle(let id): return "项目层级形成循环：\(id)"
        case .proposalAlreadyUndone: return "这批操作已撤销，请重新生成建议。"
        case .duplicateOperationMismatch: return "同一批次的审核内容已变化，请重新生成建议。"
        case .missingReceipt: return "找不到这批操作的撤销记录。"
        case .undoConflict(let detail): return "相关内容后来已修改，无法安全撤销：\(detail)"
        case .invalidState(let detail): return "项目整理存储无效：\(detail)"
        }
    }
}

/// Pure validation and transformation. Callers persist the returned state once,
/// then publish it; errors cannot partially change the original value.
enum ManagedProjectOrganizationEngine {
    static func catalogFingerprint(_ catalog: [ManagedChatProjectIdentity]) -> String {
        let records = catalog.map { identity in
            [identity.id, identity.canonicalPath.map { "1\($0)" } ?? "0",
             identity.displayPath, identity.label, identity.resolution.rawValue]
                .map { "\($0.utf8.count):\($0)" }.joined()
        }.sorted()
        return digest(Data(records.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }

    static func apply(
        state: ManagedProjectOrganizationState,
        proposal: ManagedProjectOrganizerProposal,
        currentSnapshots: [ManagedProjectOrganizationConversation],
        currentCatalog: [ManagedChatProjectIdentity],
        now: Date = Date()
    ) throws -> ManagedProjectOrganizationApplication {
        try validateState(state)
        let fingerprint = try proposalFingerprint(proposal)
        if let existing = state.history.first(where: { $0.id == proposal.id }) {
            guard existing.proposalFingerprint == fingerprint else {
                throw ManagedProjectOrganizationError.duplicateOperationMismatch
            }
            guard !existing.isUndone else {
                throw ManagedProjectOrganizationError.proposalAlreadyUndone
            }
            return ManagedProjectOrganizationApplication(state: state, receipt: existing)
        }
        guard state.revision == proposal.baseStateRevision else {
            throw ManagedProjectOrganizationError.staleState
        }
        guard catalogFingerprint(currentCatalog) == proposal.catalogFingerprint else {
            throw ManagedProjectOrganizationError.staleCatalog
        }
        guard !proposal.id.isEmpty,
              Set(proposal.suggestions.map(\.id)).count == proposal.suggestions.count else {
            throw ManagedProjectOrganizationError.malformedProposal("duplicate or empty operation identity")
        }
        let selected = proposal.suggestions.filter { $0.isSelected && $0.action != .keep }
        guard !selected.isEmpty else { throw ManagedProjectOrganizationError.nothingSelected }
        let snapshots = try conversationMap(proposal.snapshots)
        let current = try conversationMap(currentSnapshots)
        var catalog: [String: ManagedChatProjectIdentity] = [:]
        for identity in currentCatalog {
            guard catalog.updateValue(identity, forKey: identity.id) == nil else {
                throw ManagedProjectOrganizationError.malformedProposal("duplicate catalog identity")
            }
        }
        for (id, project) in state.projects {
            if let existing = catalog[id], existing != project.identity {
                throw ManagedProjectOrganizationError.staleCatalog
            }
            catalog[id] = project.identity
        }

        var additions: [String: ManagedProjectRecord] = [:]
        for suggestion in selected {
            switch suggestion.action {
            case .createSubproject:
                guard var project = suggestion.proposedProject,
                      let parentID = project.parentID, !parentID.isEmpty,
                      suggestion.targetProjectID == nil || suggestion.targetProjectID == project.id else {
                    throw ManagedProjectOrganizationError.malformedProposal(suggestion.id)
                }
                try validateProject(project)
                // Every new logical project has an independent stable identity.
                guard project.id.hasPrefix("project::"), catalog[project.id] == nil,
                      additions[project.id] == nil else {
                    throw ManagedProjectOrganizationError.invalidProject(project.id)
                }
                project.createdAt = now
                project.revision = 0
                additions[project.id] = project
            case .assign:
                guard suggestion.proposedProject == nil,
                      let target = suggestion.targetProjectID, !target.isEmpty else {
                    throw ManagedProjectOrganizationError.malformedProposal(suggestion.id)
                }
            case .keep: break
            }
        }
        for project in additions.values { catalog[project.id] = project.identity }
        var allProjects = state.projects
        allProjects.merge(additions) { _, new in new }
        for project in additions.values {
            if let parent = project.parentID, catalog[parent] == nil {
                throw ManagedProjectOrganizationError.missingProject(parent)
            }
            try validateHierarchy(start: project.id, projects: allProjects)
        }

        var assignmentChanges: [ManagedProjectOrganizationAssignmentChange] = []
        var handled = Set<String>()
        var handledKeys = Set<String>()
        for suggestion in selected {
            let targetID = suggestion.action == .createSubproject
                ? suggestion.proposedProject?.id : suggestion.targetProjectID
            guard let targetID, let target = catalog[targetID] else {
                throw ManagedProjectOrganizationError.missingProject(targetID ?? suggestion.id)
            }
            guard suggestion.action == .createSubproject || !suggestion.conversationIDs.isEmpty else {
                throw ManagedProjectOrganizationError.malformedProposal("empty conversation set")
            }
            for id in suggestion.conversationIDs {
                guard handled.insert(id).inserted else {
                    throw ManagedProjectOrganizationError.conflictingConversation(id)
                }
                guard let expected = snapshots[id], let actual = current[id],
                      sameSourceSnapshot(expected, actual),
                      state.assignments[expected.storageKey] == expected.assignment,
                      expected.effectiveProject == (expected.assignment?.project ?? expected.sourceProject) else {
                    throw ManagedProjectOrganizationError.staleConversation(id)
                }
                guard handledKeys.insert(expected.storageKey).inserted else {
                    throw ManagedProjectOrganizationError.conflictingConversation(id)
                }
                let after = ManagedChatProjectAssignment(
                    project: target, source: .aiRecommendation, assignedAt: now
                )
                assignmentChanges.append(ManagedProjectOrganizationAssignmentChange(
                    storageKey: expected.storageKey, conversationID: id,
                    before: expected.assignment, after: after
                ))
            }
        }
        let projectChanges = additions.keys.sorted().map { id in
            ManagedProjectOrganizationProjectChange(projectID: id, before: nil, after: additions[id])
        }
        var updated = state
        updated.revision = try nextRevision(state.revision)
        for change in projectChanges { updated.projects[change.projectID] = change.after }
        for change in assignmentChanges { updated.assignments[change.storageKey] = change.after }
        let receipt = ManagedProjectOrganizationReceipt(
            id: proposal.id, proposalFingerprint: fingerprint,
            appliedAt: now, appliedRevision: updated.revision,
            assignmentChanges: assignmentChanges, projectChanges: projectChanges
        )
        updated.history.append(receipt)
        return ManagedProjectOrganizationApplication(state: updated, receipt: receipt)
    }

    static func undo(
        state: ManagedProjectOrganizationState,
        receiptID: String,
        now: Date = Date()
    ) throws -> ManagedProjectOrganizationApplication {
        try validateState(state)
        guard let index = state.history.firstIndex(where: { $0.id == receiptID }) else {
            throw ManagedProjectOrganizationError.missingReceipt
        }
        var receipt = state.history[index]
        if receipt.isUndone {
            return ManagedProjectOrganizationApplication(state: state, receipt: receipt)
        }
        for change in receipt.assignmentChanges {
            guard state.assignments[change.storageKey] == change.after else {
                throw ManagedProjectOrganizationError.undoConflict(change.conversationID)
            }
        }
        for change in receipt.projectChanges {
            guard state.projects[change.projectID] == change.after else {
                throw ManagedProjectOrganizationError.undoConflict(change.projectID)
            }
        }
        let removedProjectIDs = Set(receipt.projectChanges.filter {
            $0.before == nil && $0.after != nil
        }.map(\.projectID))
        let touchedKeys = Set(receipt.assignmentChanges.map(\.storageKey))
        for (key, assignment) in state.assignments where !touchedKeys.contains(key) {
            if removedProjectIDs.contains(assignment.project.id) {
                throw ManagedProjectOrganizationError.undoConflict(key)
            }
        }
        for project in state.projects.values where !removedProjectIDs.contains(project.id) {
            if let parent = project.parentID, removedProjectIDs.contains(parent) {
                throw ManagedProjectOrganizationError.undoConflict(project.id)
            }
        }
        var updated = state
        updated.revision = try nextRevision(state.revision)
        for change in receipt.assignmentChanges { updated.assignments[change.storageKey] = change.before }
        for change in receipt.projectChanges { updated.projects[change.projectID] = change.before }
        receipt.undoneAt = now
        updated.history[index] = receipt
        return ManagedProjectOrganizationApplication(state: updated, receipt: receipt)
    }

    static func validateState(_ state: ManagedProjectOrganizationState) throws {
        guard state.revision >= 0,
              Set(state.history.map(\.id)).count == state.history.count else {
            throw ManagedProjectOrganizationError.invalidState("invalid revision or duplicate receipt")
        }
        for (id, project) in state.projects {
            guard id == project.id else {
                throw ManagedProjectOrganizationError.invalidState("project key mismatch")
            }
            try validateProject(project)
            try validateHierarchy(start: id, projects: state.projects)
        }
        for (key, assignment) in state.assignments {
            guard !key.isEmpty, !assignment.project.id.isEmpty else {
                throw ManagedProjectOrganizationError.invalidState("empty assignment identity")
            }
            if assignment.project.id.hasPrefix("project::") {
                guard state.projects[assignment.project.id]?.identity == assignment.project else {
                    throw ManagedProjectOrganizationError.invalidState("unknown logical assignment target")
                }
            }
        }
        for receipt in state.history {
            guard !receipt.id.isEmpty, receipt.appliedRevision > 0,
                  receipt.appliedRevision <= state.revision,
                  Set(receipt.assignmentChanges.map(\.storageKey)).count == receipt.assignmentChanges.count,
                  Set(receipt.projectChanges.map(\.projectID)).count == receipt.projectChanges.count else {
                throw ManagedProjectOrganizationError.invalidState("malformed undo receipt")
            }
        }
    }

    private static func validateProject(_ project: ManagedProjectRecord) throws {
        let logicalID = project.id.hasPrefix("project::")
            && UUID(uuidString: String(project.id.dropFirst("project::".count))) != nil
        let pathID = project.path.map { project.id == "path::\($0)" } ?? false
        guard (logicalID || pathID), !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !project.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.revision >= 0, project.parentID != project.id else {
            throw ManagedProjectOrganizationError.invalidProject(project.id)
        }
        if let path = project.path {
            guard path.hasPrefix("/"), !path.contains("\0"),
                  path == path.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw ManagedProjectOrganizationError.invalidProject(project.id)
            }
        }
    }

    private static func validateHierarchy(
        start: String, projects: [String: ManagedProjectRecord]
    ) throws {
        var visited = Set<String>()
        var cursor: String? = start
        while let id = cursor {
            guard visited.insert(id).inserted else {
                throw ManagedProjectOrganizationError.projectCycle(start)
            }
            cursor = projects[id]?.parentID
            if let parent = cursor, parent.hasPrefix("project::"), projects[parent] == nil {
                throw ManagedProjectOrganizationError.missingProject(parent)
            }
        }
    }

    private static func conversationMap(
        _ snapshots: [ManagedProjectOrganizationConversation]
    ) throws -> [String: ManagedProjectOrganizationConversation] {
        var result: [String: ManagedProjectOrganizationConversation] = [:]
        var keys = Set<String>()
        for snapshot in snapshots {
            guard !snapshot.id.isEmpty, !snapshot.storageKey.isEmpty, !snapshot.sourceRevision.isEmpty,
                  result.updateValue(snapshot, forKey: snapshot.id) == nil,
                  keys.insert(snapshot.storageKey).inserted else {
                throw ManagedProjectOrganizationError.malformedProposal("duplicate or empty conversation identity")
            }
        }
        return result
    }

    private static func sameSourceSnapshot(
        _ lhs: ManagedProjectOrganizationConversation,
        _ rhs: ManagedProjectOrganizationConversation
    ) -> Bool {
        lhs.id == rhs.id && lhs.storageKey == rhs.storageKey
            && lhs.sourceRevision == rhs.sourceRevision && lhs.sourceProject == rhs.sourceProject
            && lhs.effectiveProject == rhs.effectiveProject && lhs.assignment == rhs.assignment
            && lhs.provider == rhs.provider
    }

    private static func proposalFingerprint(_ proposal: ManagedProjectOrganizerProposal) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return digest(try encoder.encode(proposal))
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nextRevision(_ revision: Int) throws -> Int {
        guard revision < Int.max else {
            throw ManagedProjectOrganizationError.invalidState("revision exhausted")
        }
        return revision + 1
    }
}
