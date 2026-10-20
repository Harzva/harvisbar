import XCTest
@testable import HarvisBar

final class CodexInspectorTests: XCTestCase {
    func testPaginationAppendsAndDeduplicatesTimelineItems() {
        var state = CodexInspectorTimelineState()
        state.apply(page(items: [item("3"), item("2")], cursor: "2", total: 3), reset: true)
        state.apply(page(items: [item("2"), item("1")], cursor: nil, total: 3), reset: false)

        XCTAssertEqual(state.items.map(\.id), ["3", "2", "1"])
        XCTAssertFalse(state.canLoadMore)
        XCTAssertEqual(state.totalItems, 3)
    }

    func testRefreshReplacesExistingTimeline() {
        var state = CodexInspectorTimelineState()
        state.apply(page(items: [item("old")], cursor: nil, total: 1), reset: true)
        state.apply(page(items: [item("new")], cursor: nil, total: 1), reset: true)
        XCTAssertEqual(state.items.map(\.id), ["new"])
    }

    func testStructuredSearchSupportsTagsProjectsPinAndExclusion() {
        let thread = fixtureThread(title: "PDF crop benchmark")
        let query = CodexThreadQuery(
            #"tag:paper project:paper-crop model:gpt-5 is:pinned -"automation""#
        )
        XCTAssertTrue(query.matches(thread, tags: ["paper"], isPinned: true))
        XCTAssertFalse(query.matches(thread, tags: ["paper"], isPinned: false))
    }

    func testSearchFindsSubagentByIdentityAndType() {
        let thread = fixtureThread(
            threadSource: "subagent",
            agentNickname: "Huygens",
            agentPath: "/root/latex_paper",
            parentThreadId: "parent-1"
        )

        XCTAssertTrue(CodexThreadQuery("Huygens").matches(thread, tags: [], isPinned: false))
        XCTAssertTrue(CodexThreadQuery("is:subagent").matches(thread, tags: [], isPinned: false))
        XCTAssertFalse(CodexThreadQuery("is:main").matches(thread, tags: [], isPinned: false))
    }

    func testSearchDistinguishesSidechatFromMainAndSubagent() {
        let thread = fixtureThread(threadSource: "sidechat", parentThreadId: "parent-1")

        XCTAssertTrue(CodexThreadQuery("is:sidechat").matches(thread, tags: [], isPinned: false))
        XCTAssertFalse(CodexThreadQuery("is:main").matches(thread, tags: [], isPinned: false))
        XCTAssertFalse(CodexThreadQuery("is:subagent").matches(thread, tags: [], isPinned: false))
    }

    private func item(_ id: String) -> CodexEvidenceItem {
        CodexEvidenceItem(
            id: id,
            timestamp: "2026-07-23T00:00:00.000Z",
            kind: "message",
            turnId: "turn-1",
            title: "Message",
            detail: nil,
            toolName: nil,
            outcome: nil
        )
    }

    private func page(
        items: [CodexEvidenceItem],
        cursor: String?,
        total: Int
    ) -> CodexThreadEvidencePage {
        CodexThreadEvidencePage(
            ok: true,
            schemaVersion: "harvis.codex-thread-evidence.v1",
            threadId: "thread-1",
            source: "fixture",
            sourceAvailable: true,
            items: items,
            nextCursor: cursor,
            totalItems: total,
            summary: CodexEvidenceSummary(
                latestTurnState: "completed",
                reason: "fixture",
                latestEventAt: nil,
                turnCount: 1,
                toolCallCount: 0,
                failureCount: 0,
                completionCount: 1
            )
        )
    }
}
