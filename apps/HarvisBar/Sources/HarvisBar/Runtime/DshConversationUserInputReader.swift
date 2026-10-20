import Foundation

/// Reads only the Host's purpose-built user-input projection. It never calls
/// session.history, and keeps source bodies in the caller-owned result only.
struct DshConversationUserInputReader: Sendable {
    static let maximumItems = 1_000

    struct Snapshot: Sendable {
        let authority: DshBridgeAuthority
        let sourceRevision: String
        let items: [ManagedConversationUserInput]
        let totalCount: Int
        let excludedNonHumanCount: Int
        let nextCursor: String?

        var isTruncated: Bool { nextCursor != nil || items.count < totalCount }
    }

    let client: DshCapabilityBridgeClient

    func read(sessionID: String) async throws -> Snapshot {
        let description = try await client.describe()
        guard description.value.supports("session.userInputs", operation: "read") else {
            throw DshCapabilityBridgeError.unavailable
        }
        var cursor: String?
        var revision: String?
        var totalCount: Int?
        var excludedCount: Int?
        var items: [ManagedConversationUserInput] = []
        var seenIDs = Set<String>()
        var seenCursors = Set<String>()
        var lastSequence: Int64?
        var pages = 0
        repeat {
            try Task.checkCancellation()
            let remaining = Self.maximumItems - items.count
            let response = try await client.userInputs(
                sessionID: sessionID, cursor: cursor, limit: min(100, remaining)
            )
            guard response.authority == description.authority else {
                throw DshCapabilityBridgeError.authorityMismatch
            }
            let page = response.value
            guard page.sourceAvailable, let pageRevision = page.sourceRevision else {
                throw DshCapabilityBridgeError.remoteFailure("source-unavailable")
            }
            guard revision == nil || revision == pageRevision,
                  totalCount == nil || totalCount == page.totalItems,
                  excludedCount == nil || excludedCount == page.excludedNonHumanItems else {
                throw DshCapabilityBridgeError.sourceChanged
            }
            revision = pageRevision
            totalCount = page.totalItems
            excludedCount = page.excludedNonHumanItems
            for item in page.items {
                guard seenIDs.insert(item.id).inserted,
                      lastSequence.map({ item.sequence > $0 }) != false else {
                    throw DshCapabilityBridgeError.invalidResponse
                }
                items.append(item.projected)
                lastSequence = item.sequence
            }
            guard items.count <= page.totalItems else { throw DshCapabilityBridgeError.invalidResponse }
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw DshCapabilityBridgeError.invalidResponse
            }
            pages += 1
            guard pages <= 100 else { throw DshCapabilityBridgeError.invalidResponse }
        } while cursor != nil && items.count < Self.maximumItems
        try Task.checkCancellation()
        guard let revision, let totalCount, let excludedCount else {
            throw DshCapabilityBridgeError.invalidResponse
        }
        return Snapshot(
            authority: description.authority, sourceRevision: revision, items: items,
            totalCount: totalCount, excludedNonHumanCount: excludedCount, nextCursor: cursor
        )
    }
}
