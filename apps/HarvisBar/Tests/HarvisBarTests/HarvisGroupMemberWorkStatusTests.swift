import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisGroupMemberWorkStatusTests: XCTestCase {
    func testNoHistoryIsIdleAndTerminalStatesRemainDistinct() {
        var group = fixture()
        let member = group.members[0]
        var status = HarvisGroupMemberWorkStatus.project(group: group, member: member, live: nil)
        XCTAssertEqual(status.state, .idle)
        XCTAssertNil(status.currentTask)
        XCTAssertEqual(status.queuedTaskCount, 0)
        XCTAssertEqual(status.completedTaskCount, 0)
        appendTask(&group, state: .completed, verified: true, text: "Completed evidence")
        status = .project(group: group, member: member, live: nil)
        XCTAssertEqual(status.state, .completed)
        XCTAssertEqual(status.currentTask, "Completed evidence")
        XCTAssertEqual(status.completedTaskCount, 1)
        appendTask(&group, state: .failed, text: "Failed review")
        status = .project(group: group, member: member, live: nil)
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.label, "失败")
        appendTask(&group, state: .cancelled, text: "Cancelled request")
        status = .project(group: group, member: member, live: nil)
        XCTAssertEqual(status.state, .cancelled)
        XCTAssertEqual(status.currentTask, "Cancelled request")
        XCTAssertEqual(status.completedTaskCount, 1)
        appendTask(&group, state: .waiting, text: "Next request")
        status = .project(group: group, member: member, live: nil)
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(status.currentTask, "Next request")
        XCTAssertEqual(status.queuedTaskCount, 1)
    }

    func testLiveApprovalHasPriorityAndRunningTaskDoesNotUseStaleFinalSummary() {
        var group = fixture()
        let member = group.members[0], binding = member.binding!
        appendTask(&group, state: .completed, verified: true, text: "Old finished work")
        appendTask(&group, state: .waiting, text: "Queued next work")
        var running = appendTask(&group, state: .running, text: "Actual active assignment")
        running.turnID = "active-turn"
        group.dispatches[group.dispatches.count - 1] = running
        var live = CodexThreadLiveState(target: .init(homePath: binding.homePath, threadID: binding.threadID))
        live.status = .active; live.activeTurnID = "active-turn"; live.finalSummary = "Old assistant final text"
        var status = HarvisGroupMemberWorkStatus.project(group: group, member: member, live: live)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.currentTask, "Actual active assignment")
        XCTAssertEqual(status.queuedTaskCount, 1)
        XCTAssertEqual(status.completedTaskCount, 1)
        live.enqueueApproval(.init(id: .string("approval"), connectionID: UUID(), method: "item/commandExecution/requestApproval",
                                   threadID: binding.threadID, turnID: "active-turn", title: "Approval", detail: "", params: .object([:]), questions: []))
        status = .project(group: group, member: member, live: live)
        XCTAssertEqual(status.state, .awaitingApproval)
        XCTAssertEqual(status.currentTask, "Actual active assignment")
        XCTAssertEqual(status.label, "待审批")
        let foreign = CodexThreadLiveState(target: .init(homePath: "/other-profile", threadID: binding.threadID))
        status = .project(group: group, member: member, live: foreign)
        XCTAssertEqual(status.state, .running)
    }

    func testPlannedDependencyIsQueuedBeforeSubmissionAndNotCountedTwice() {
        var group = fixture()
        let producer = group.members[0]
        let reviewer = HarvisGroupMember(name: "Reviewer", role: "review", homePath: "/metadata/reviewer")
        group.members.append(reviewer)
        group.lastSequence = 1
        let root = HarvisGroupMessage(sequence: 1, speaker: "你", text: "Produce and review", recipientMemberIDs: [producer.id, reviewer.id])
        group.messages.append(root)
        var run = HarvisGroupRun(rootMessageID: root.id, permission: .discussion, state: .working)
        run.steps = [.init(id: "produce", memberID: producer.id, task: "Produce evidence", state: .submitted),
                     .init(id: "review", memberID: reviewer.id, task: "Review produced evidence", dependencies: ["produce"])]
        group.orchestration = .init(runs: [run])
        var status = HarvisGroupMemberWorkStatus.project(group: group, member: reviewer, live: nil)
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(status.currentTask, "Review produced evidence")
        XCTAssertEqual(status.queuedTaskCount, 1)
        XCTAssertEqual(status.completedTaskCount, 0)
        let row = HarvisGroupDispatch(id: run.steps[1].dispatchID, messageID: root.id, memberID: reviewer.id, permission: .discussion)
        group.dispatches.append(row)
        status = .project(group: group, member: reviewer, live: nil)
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(status.currentTask, "Review produced evidence")
        XCTAssertEqual(status.queuedTaskCount, 1)
    }

    func testUnknownAndUnverifiedCompletionCannotBecomeCompleted() {
        var group = fixture()
        let member = group.members[0]
        appendTask(&group, state: .completed, verified: true, text: "Verified task")
        appendTask(&group, state: .completed, text: "Unverified terminal notification")
        var status = HarvisGroupMemberWorkStatus.project(group: group, member: member, live: nil)
        XCTAssertEqual(status.state, .blocked)
        XCTAssertEqual(status.currentTask, "Unverified terminal notification")
        XCTAssertEqual(status.completedTaskCount, 1)
        group.dispatches[group.dispatches.count - 1].state = .deliveryUnknown
        status = .project(group: group, member: member, live: nil)
        XCTAssertEqual(status.state, .blocked)
        XCTAssertEqual(status.completedTaskCount, 1)
        XCTAssertEqual(status.label, "已阻塞")
    }

    func testOwnerPlanningReviewAndWaitingForMembersUseWorkflowDescriptions() {
        var group = fixture()
        let owner = group.members[0]
        let planning = appendTask(&group, state: .queued, text: "Deliver a verified report")
        var run = HarvisGroupRun(rootMessageID: planning.messageID, ownerMemberID: owner.id,
                                permission: .discussion, state: .planning, ownerDispatchID: planning.id)
        group.orchestration = .init(ownerMemberID: owner.id, runs: [run])
        var status = HarvisGroupMemberWorkStatus.project(group: group, member: owner, live: nil)
        XCTAssertEqual(status.state, .queued)
        XCTAssertEqual(status.currentTask, "群主规划与分派：Deliver a verified report")
        group.dispatches[0].state = .completed; group.dispatches[0].nativeReplyVerified = true
        status = .project(group: group, member: owner, live: nil)
        XCTAssertEqual(status.state, .running, "Owner still has a plan to process; the workflow is not complete")
        let review = appendTask(&group, state: .dispatching, text: "INTERNAL_REVIEW_PAYLOAD")
        group.messages[group.messages.count - 1].origin = .ownerReview(runID: run.id)
        run.state = .reviewing; run.ownerDispatchID = review.id; run.ownerDispatchState = .enqueueStarted
        group.orchestration?.runs = [run]
        status = .project(group: group, member: owner, live: nil)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.currentTask, "群主复核与汇总：Deliver a verified report")
        XCTAssertFalse(status.currentTask?.contains("INTERNAL_REVIEW_PAYLOAD") ?? true)
        group.dispatches[1].state = .completed; group.dispatches[1].nativeReplyVerified = true
        run.state = .working; run.ownerDispatchState = .finished
        group.orchestration?.runs = [run]
        status = .project(group: group, member: owner, live: nil)
        XCTAssertEqual(status.state, .running)
        XCTAssertTrue(status.currentTask?.contains("等待成员结果并复核") == true)
        XCTAssertEqual(status.completedTaskCount, 2)
        run.state = .needsInput; group.orchestration?.runs = [run]
        status = .project(group: group, member: owner, live: nil)
        XCTAssertEqual(status.state, .blocked)
        XCTAssertTrue(status.currentTask?.contains("等待补充信息") == true)
    }

    func testDurableQueueUpdatesLaggingProjectionButCannotOverrideVerifiedHistory() {
        var group = fixture()
        let member = group.members[0], binding = member.binding!
        let dispatch = appendTask(&group, state: .queued, text: "Queued task becomes active")
        let command = CodexTaskCommand(id: dispatch.id, homeID: "account", homePath: binding.homePath,
                                       threadID: binding.threadID, sourceThreadID: binding.threadID, cardType: .main, text: "Model packet")
        let connection = UUID()
        var item = CodexTaskQueueItem(command: command, state: .running, ownership: .manager(turnID: "current-turn", connectionID: connection), connectionID: connection)
        var live = CodexThreadLiveState(target: .init(homePath: binding.homePath, threadID: binding.threadID))
        live.status = .active; live.activeTurnID = "current-turn"
        var status = HarvisGroupMemberWorkStatus.project(group: group, member: member, live: live, queue: [item])
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.currentTask, "Queued task becomes active")
        XCTAssertEqual(status.queuedTaskCount, 0)
        group.dispatches[0].state = .completed; group.dispatches[0].nativeReplyVerified = true
        item.state = .deliveryUnknown
        status = .project(group: group, member: member, live: nil, queue: [item])
        XCTAssertEqual(status.state, .completed)
        XCTAssertEqual(status.completedTaskCount, 1)
    }

    func testCoordinatorUnknownTargetsReturnNilWithoutStartingExecution() {
        let coordinator = HarvisGroupCoordinator(delivery: CodexTaskDeliveryCoordinator())
        XCTAssertNil(coordinator.memberWorkStatus(groupID: UUID(), memberID: UUID()))
    }

    private func fixture() -> HarvisGroupConversation {
        let binding = HarvisGroupBinding(homePath: "/metadata/profile", accountIdentity: "fixture", threadID: "private-native-session", permission: .discussion)
        return HarvisGroupConversation(title: "Projection", projectPath: "/metadata/project",
                                       members: [.init(name: "Member", role: "review", homePath: binding.homePath, binding: binding)])
    }

    @discardableResult
    private func appendTask(_ group: inout HarvisGroupConversation, state: CodexDeliveryState, verified: Bool = false, text: String) -> HarvisGroupDispatch {
        group.lastSequence += 1
        let member = group.members[0]
        let message = HarvisGroupMessage(sequence: group.lastSequence, speaker: "你", text: text, recipientMemberIDs: [member.id])
        group.messages.append(message)
        let dispatch = HarvisGroupDispatch(messageID: message.id, memberID: member.id, permission: .discussion,
                                           state: state, binding: member.binding, nativeReplyVerified: verified)
        group.dispatches.append(dispatch)
        return dispatch
    }
}
