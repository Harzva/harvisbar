import Foundation

/// Status visible to this native server, scoped by home and thread. Unknown status is never idle.
/// `notLoaded` permits restoring an owned group thread, but cannot establish that a different
/// app-server process has no active writer. Group threads require a single-writer ownership contract.
struct CodexGroupNativeActivityProbe: CodexThreadActivityProbing {
    let pool: CodexAppServerPool
    func isThreadRunning(homePath: String, threadID: String) async throws -> Bool {
        let connection = await pool.connection(for: homePath)
        let generation = try await connection.connect()
        let result = try await connection.request(method: "thread/read", params: .object([
            "threadId": .string(threadID), "includeTurns": .bool(false)]))
        guard await connection.connectionID() == generation,
              result["thread"]?["id"]?.stringValue == threadID else {
            throw HarvisGroupError.invalid("Native activity check returned a different thread or connection.")
        }
        switch result["thread"]?["status"]?["type"]?.stringValue {
        case "idle", "notLoaded": return false
        case "active": return true
        default: throw HarvisGroupError.invalid("Native activity is unknown; delivery remains queued.")
        }
    }
}
