import Foundation

struct CodexThreadEvidencePage: Decodable {
    let ok: Bool
    let schemaVersion: String
    let threadId: String
    let source: String
    let sourceAvailable: Bool
    let items: [CodexEvidenceItem]
    let nextCursor: String?
    let totalItems: Int
    let summary: CodexEvidenceSummary
}

struct CodexEvidenceSummary: Decodable, Equatable {
    let latestTurnState: String
    let reason: String
    let latestEventAt: String?
    let turnCount: Int
    let toolCallCount: Int
    let failureCount: Int
    let completionCount: Int
}

struct CodexEvidenceItem: Decodable, Identifiable, Equatable {
    let id: String
    let timestamp: String
    let kind: String
    let turnId: String?
    let title: String
    let detail: String?
    let toolName: String?
    let outcome: String?

    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp)
    }

    var timestampLabel: String {
        guard let date else { return timestamp }
        return date.formatted(date: .omitted, time: .standard)
    }
}

struct CodexInspectorTimelineState: Equatable {
    var items: [CodexEvidenceItem] = []
    var summary: CodexEvidenceSummary?
    var nextCursor: String?
    var totalItems = 0
    var sourceAvailable = true

    var canLoadMore: Bool { nextCursor != nil }

    mutating func apply(_ page: CodexThreadEvidencePage, reset: Bool) {
        let existing = reset ? [] : items
        var seen = Set(existing.map(\.id))
        let additions = page.items.filter { seen.insert($0.id).inserted }
        items = existing + additions
        summary = page.summary
        nextCursor = page.nextCursor
        totalItems = page.totalItems
        sourceAvailable = page.sourceAvailable
    }
}
