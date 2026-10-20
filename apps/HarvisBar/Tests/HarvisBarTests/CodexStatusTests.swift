import XCTest
@testable import HarvisBar

final class CodexStatusTests: XCTestCase {
    func testLiveProcessWinsOverHistoricalCompletion() {
        let thread = fixtureThread(running: true)
        let status = thread.trustProjection(evidence: summary("completed"))
        XCTAssertEqual(status.state, .running)
    }

    func testExplicitCompletionAndFailureAreProjected() {
        let thread = fixtureThread()
        XCTAssertEqual(
            thread.trustProjection(evidence: summary("completed")).state,
            .completed
        )
        XCTAssertEqual(
            thread.trustProjection(evidence: summary("failed")).state,
            .failed
        )
    }

    func testStartedTurnWithoutLiveProcessIsIncomplete() {
        let status = fixtureThread().trustProjection(evidence: summary("running"))
        XCTAssertEqual(status.state, .incomplete)
        XCTAssertTrue(status.reason.contains("no live process"))
    }

    func testSubagentIdentityUsesNicknameAndTaskPath() {
        let thread = fixtureThread(
            threadSource: "subagent",
            agentNickname: "Huygens",
            agentPath: "/root/latex_paper",
            parentThreadId: "parent-1",
            agentDepth: 1
        )

        XCTAssertTrue(thread.isSubagent)
        XCTAssertEqual(thread.agentIdentityLabel, "Huygens · SUBAGENT")
        XCTAssertEqual(thread.agentTaskLabel, "latex_paper")
        XCTAssertFalse(fixtureThread().isSubagent)
    }

    func testFamilyActivityTotalsMainAgentsAndReportedSideChats() {
        let thread = fixtureThread(
            familyActivity: CodexThreadFamilyActivity(
                main: 1,
                subagent: 2,
                sidechat: 3,
                members: []
            )
        )

        XCTAssertEqual(thread.runningFamilyActivity.total, 6)
        XCTAssertTrue(thread.hasRunningFamily)
    }

    func testStoppedSubagentCardDoesNotInheritRunningParentState() {
        let activity = CodexThreadFamilyActivity(
            main: 1,
            subagent: 0,
            sidechat: nil,
            members: []
        )
        let subagent = fixtureThread(
            running: false,
            threadSource: "subagent",
            agentNickname: "Huygens",
            parentThreadId: "parent-1",
            familyActivity: activity
        )
        let main = fixtureThread(running: true, familyActivity: activity)

        XCTAssertFalse(subagent.isCardRunning)
        XCTAssertTrue(main.isCardRunning)
        XCTAssertEqual(main.cardActivity.main, 1)
    }

    private func summary(_ state: String) -> CodexEvidenceSummary {
        CodexEvidenceSummary(
            latestTurnState: state,
            reason: "explicit fixture",
            latestEventAt: "2026-07-23T00:00:00Z",
            turnCount: 1,
            toolCallCount: 0,
            failureCount: state == "failed" ? 1 : 0,
            completionCount: state == "completed" ? 1 : 0
        )
    }
}

func fixtureThread(
    id: String = "thread-1",
    title: String = "PDF crop benchmark",
    titleSource: String? = "title",
    hasMeaningfulTitle: Bool? = nil,
    model: String? = "gpt-5.6-sol",
    cwd: String = "/tmp/paper-crop-bench",
    archived: Bool = false,
    running: Bool = false,
    threadSource: String? = nil,
    agentNickname: String? = nil,
    agentRole: String? = nil,
    agentPath: String? = nil,
    parentThreadId: String? = nil,
    agentDepth: Int? = nil,
    rootThreadId: String? = nil,
    familyActivity: CodexThreadFamilyActivity? = nil
) -> CodexThreadSummary {
    CodexThreadSummary(
        id: id,
        title: title,
        titleSource: titleSource,
        hasMeaningfulTitle: hasMeaningfulTitle,
        createdAt: 1_700_000_000,
        updatedAt: 1_700_000_100,
        tokensUsed: 12_000,
        model: model,
        cwd: cwd,
        archived: archived,
        running: running,
        threadSource: threadSource,
        agentNickname: agentNickname,
        agentRole: agentRole,
        agentPath: agentPath,
        parentThreadId: parentThreadId,
        agentDepth: agentDepth,
        rootThreadId: rootThreadId,
        familyActivity: familyActivity
    )
}
