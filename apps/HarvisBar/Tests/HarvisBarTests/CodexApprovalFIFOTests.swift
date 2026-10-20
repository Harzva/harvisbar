import XCTest
@testable import HarvisBar

final class CodexApprovalFIFOTests: XCTestCase {
    func testApprovalsRemainFIFOAndCannotResolveOutOfOrder() {
        var state = CodexThreadLiveState(target: CodexTaskTarget(
            homePath: "/tmp/codex-home",
            threadID: "thread-a"
        ))
        let first = approval(id: "first", method: "command")
        let second = approval(id: "second", method: "file")

        state.enqueueApproval(first)
        state.enqueueApproval(second)
        state.enqueueApproval(first)

        XCTAssertEqual(state.pendingApprovals.map(\.id), [first.id, second.id])
        XCTAssertEqual(state.pendingApproval?.id, first.id)
        XCTAssertFalse(state.dequeueApproval(matching: second))
        XCTAssertEqual(state.pendingApproval?.id, first.id)
        XCTAssertTrue(state.dequeueApproval(matching: first))
        XCTAssertEqual(state.pendingApproval?.id, second.id)
        XCTAssertTrue(state.dequeueApproval(matching: second))
        XCTAssertNil(state.pendingApproval)
    }

    func testFileEvidenceEnrichesAlreadyQueuedApproval() {
        var state = CodexThreadLiveState(target: CodexTaskTarget(
            homePath: "/tmp/codex-home",
            threadID: "thread-a"
        ))
        let fileApproval = approval(
            id: "file",
            method: "item/fileChange/requestApproval",
            itemID: "item-file"
        )
        state.enqueueApproval(fileApproval)

        let change = CodexFileApprovalChange(
            path: "Sources/App.swift",
            kind: "update",
            diff: "@@ -1 +1 @@"
        )
        state.rememberFileChanges(
            itemID: "item-file",
            changes: [change]
        )

        XCTAssertEqual(state.pendingApproval?.fileChanges, [change])
    }

    private func approval(
        id: String,
        method: String,
        itemID: String = "item"
    ) -> CodexPendingApproval {
        CodexPendingApproval(
            id: .string(id),
            connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            method: method,
            threadID: "thread-a",
            turnID: "turn-a",
            title: "Approval",
            detail: "",
            params: .object([
                "threadId": .string("thread-a"),
                "itemId": .string(itemID),
            ]),
            questions: []
        )
    }
}
