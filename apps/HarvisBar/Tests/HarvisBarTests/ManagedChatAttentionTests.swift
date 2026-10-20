import XCTest
@testable import HarvisBar

final class ManagedChatAttentionTests: XCTestCase {
    func testAttentionWindowDistinguishesScheduledActiveAndExpired() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ManagedAttentionPreference(
                focusStartsAt: Date(timeIntervalSince1970: 1_100),
                focusEndsAt: Date(timeIntervalSince1970: 1_200)
            ).focusState(at: now),
            .scheduled
        )
        XCTAssertEqual(
            ManagedAttentionPreference(
                focusStartsAt: Date(timeIntervalSince1970: 900),
                focusEndsAt: Date(timeIntervalSince1970: 1_100)
            ).focusState(at: now),
            .active
        )
        XCTAssertEqual(
            ManagedAttentionPreference(
                focusStartsAt: Date(timeIntervalSince1970: 800),
                focusEndsAt: Date(timeIntervalSince1970: 900)
            ).focusState(at: now),
            .expired
        )
    }

    func testCompactionRiskFailsClosedWhenEvidenceIsUnavailable() {
        XCTAssertEqual(
            CodexConversationAttention(
                userInputCount: 30,
                turnCount: 30,
                compactionCount: nil,
                compactionEvidenceAvailable: false
            ).risk,
            .unknown
        )
    }

    func testCompactionRiskDoesNotUseInteractionCountAsProxy() {
        XCTAssertEqual(
            CodexConversationAttention(
                userInputCount: 200,
                turnCount: 200,
                compactionCount: 0,
                compactionEvidenceAvailable: true
            ).risk,
            .healthy
        )
        XCTAssertEqual(
            CodexConversationAttention(
                userInputCount: 3,
                turnCount: 3,
                compactionCount: 3,
                compactionEvidenceAvailable: true
            ).risk,
            .handoffRecommended
        )
    }

    func testNoTaskSourceIsUnknownInsteadOfComplete() {
        XCTAssertNil(ManagedProjectTaskSummary.unavailable.completionFraction)
    }

    func testClosedTasksAreNotMisreportedAsCompleted() {
        let summary = ManagedProjectTaskSummary(
            sourceAvailable: true,
            total: 4,
            done: 2,
            open: 0,
            blocked: 0,
            waitingApproval: 0,
            reviewing: 0,
            sourceTruncated: false
        )

        XCTAssertEqual(summary.completionFraction, 0.5)
        XCTAssertEqual(summary.closedWithoutCompletion, 2)
    }

    func testUnknownCompactionEvidenceHasLocalizedConservativeNote() {
        let metrics = CodexConversationMetrics(
            ok: true,
            schemaVersion: "harvis.codex-thread-metrics.v1",
            threadId: "thread-1",
            sourceAvailable: true,
            userInputCount: 5,
            turnCount: 5,
            compactionCount: nil,
            compactionEvidenceAvailable: false,
            reason: "backend detail"
        )

        XCTAssertEqual(
            metrics.userFacingEvidenceNote,
            "当前记录无法验证压缩次数；未知不会被当作 0。"
        )
    }

    func testRefreshFailurePreservesLastSuccessAsExplicitlyStale() {
        let successfulAt = Date(timeIntervalSince1970: 1_234)
        let state = ManagedGovernanceFreshness
            .fresh(lastSuccessfulAt: successfulAt)
            .recordingFailure("offline")

        XCTAssertEqual(
            state,
            .stale(lastSuccessfulAt: successfulAt, error: "offline")
        )
        XCTAssertFalse(state.isFresh)
        XCTAssertEqual(state.lastSuccessfulAt, successfulAt)
        XCTAssertEqual(state.error, "offline")
    }

    func testRefreshFailureWithoutPriorSuccessIsUnavailable() {
        let state = ManagedGovernanceFreshness
            .unavailable(error: nil)
            .recordingFailure("missing")

        XCTAssertEqual(state, .unavailable(error: "missing"))
        XCTAssertNil(state.lastSuccessfulAt)
    }

    func testStaleMetricsCannotDriveCurrentCompactionRisk() {
        let metrics = CodexConversationMetrics(
            ok: true,
            schemaVersion: "harvis.codex-thread-metrics.v1",
            threadId: "thread-1",
            sourceAvailable: true,
            userInputCount: 30,
            turnCount: 30,
            compactionCount: 4,
            compactionEvidenceAvailable: true,
            reason: nil
        )
        let successfulAt = Date(timeIntervalSince1970: 1_234)

        XCTAssertEqual(
            ManagedGovernanceFreshness
                .stale(lastSuccessfulAt: successfulAt, error: "offline")
                .currentConversationRisk(metrics: metrics),
            .unknown
        )
        XCTAssertEqual(
            ManagedGovernanceFreshness
                .fresh(lastSuccessfulAt: successfulAt)
                .currentConversationRisk(metrics: metrics),
            .handoffRecommended
        )
    }

    func testUnnamedSubagentIsHiddenUntilExplicitlyShown() {
        XCTAssertFalse(ManagedUnnamedSubagentVisibilityPolicy.shouldShow(
            isUnnamedSubagent: true,
            hasExplicitShowOverride: false
        ))
        XCTAssertTrue(ManagedUnnamedSubagentVisibilityPolicy.shouldShow(
            isUnnamedSubagent: true,
            hasExplicitShowOverride: true
        ))
        XCTAssertTrue(ManagedUnnamedSubagentVisibilityPolicy.shouldShow(
            isUnnamedSubagent: false,
            hasExplicitShowOverride: false
        ))
    }
}
