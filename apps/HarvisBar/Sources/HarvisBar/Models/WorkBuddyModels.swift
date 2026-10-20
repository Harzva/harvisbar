import Foundation

struct WorkBuddyThreadList: Decodable {
    let ok: Bool
    let schemaVersion: String?
    let home: String
    let items: [WorkBuddyThreadSummary]
}

struct WorkBuddyThreadSummary: Decodable, Identifiable {
    let id: String
    let title: String
    let createdAt: Int64
    let updatedAt: Int64
    let tokensUsed: Int64
    let model: String?
    let cwd: String
    let archived: Bool
    let running: Bool
    let sourceStatus: String
}
