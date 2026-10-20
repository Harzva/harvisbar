import Foundation

typealias ManagedChatProjectResolution = ManagedConversationProjectResolution
typealias ManagedChatProjectIdentity = ManagedConversationProjectIdentity
typealias ManagedChatProjectAssignmentSource =
    ManagedConversationProjectAssignmentSource
typealias ManagedChatProjectAssignment = ManagedConversationProjectAssignment

/// A local Harvis-only organization override.
///
/// The source conversation's `cwd` remains authoritative for execution. This
/// value changes only how Chat Agent Managed groups the card, and is always
/// reversible without mutating Codex, DSH, WorkBuddy, or project files.
enum ManagedChatProjectResolver {
    static func resolve(
        cwd: String,
        fallbackID: String,
        fileManager: FileManager = .default
    ) -> ManagedChatProjectIdentity {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ManagedConversationProjectRules.unassigned(
                fallbackID: fallbackID
            )
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        if fileManager === FileManager.default,
           let cached = ManagedProjectPathCache.shared.value(for: standardized) {
            return cached
        }
        let exists = fileManager.fileExists(atPath: standardized)
        let canonical = exists
            ? URL(fileURLWithPath: standardized, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            : standardized
        let label = URL(fileURLWithPath: canonical, isDirectory: true).lastPathComponent

        let result = ManagedChatProjectIdentity(
            id: "path::\(canonical)",
            canonicalPath: canonical,
            displayPath: canonical,
            label: label.isEmpty ? canonical : label,
            resolution: exists ? .resolved : .unresolved
        )
        if fileManager === FileManager.default {
            ManagedProjectPathCache.shared.insert(result, for: standardized)
        }
        return result
    }

    static func resolve(
        thread: ManagedChatThread,
        fileManager: FileManager = .default
    ) -> ManagedChatProjectIdentity {
        if let assignment = thread.managementProjectAssignment {
            return assignment.project
        }
        return resolveSource(thread: thread, fileManager: fileManager)
    }

    static func resolveSource(
        thread: ManagedChatThread,
        fileManager: FileManager = .default
    ) -> ManagedChatProjectIdentity {
        resolve(cwd: thread.cwd, fallbackID: thread.id, fileManager: fileManager)
    }
}
