import Foundation

enum HarvisGroupMemberWorkState: String, Codable, CaseIterable, Sendable {
    case idle, queued, running, awaitingApproval, blocked, completed, failed, cancelled

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .queued: return "排队中"
        case .running: return "进行中"
        case .awaitingApproval: return "待审批"
        case .blocked: return "已阻塞"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

/// Rebuilt from existing work ledgers and live evidence. It stores no additional
/// lifecycle state and exposes no account, connection or native session address.
struct HarvisGroupMemberWorkStatus: Codable, Equatable, Sendable {
    let state: HarvisGroupMemberWorkState
    let currentTask: String?
    let queuedTaskCount: Int
    let completedTaskCount: Int
    var label: String { state.label }

    static func project(group: HarvisGroupConversation, member: HarvisGroupMember,
                        live: CodexThreadLiveState?, queue: [CodexTaskQueueItem] = []) -> Self {
        struct TaskProjection {
            let id: UUID
            var state: HarvisGroupMemberWorkState
            let task: String?
            let turnID: String?
            let sequence: Int
        }
        let memberDispatches = group.dispatches.filter { $0.memberID == member.id }
        let completed = memberDispatches.filter { $0.state == .completed && $0.nativeReplyVerified }.count
        var tasks: [TaskProjection] = []

        func rootText(_ run: HarvisGroupRun) -> String? {
            group.messages.first { $0.id == run.rootMessageID }?.text
        }
        func ownerTask(_ run: HarvisGroupRun, review: Bool) -> String {
            let title = review ? "群主复核与汇总" : "群主规划与分派"
            return rootText(run).map { title + "：" + $0 } ?? title
        }
        func state(_ value: CodexDeliveryState, verified: Bool) -> HarvisGroupMemberWorkState {
            switch value {
            case .queued, .waiting: return .queued
            case .dispatching, .running: return .running
            case .waitingApproval: return .awaitingApproval
            case .deliveryUnknown: return .blocked
            case .completed: return verified ? .completed : .blocked
            case .failed: return .failed
            case .cancelled: return .cancelled
            }
        }

        for dispatch in memberDispatches {
            let message = group.messages.first { $0.id == dispatch.messageID }
            let step = group.runs.flatMap(\.steps).first { $0.dispatchID == dispatch.id }
            let run = group.runs.first { $0.steps.contains { $0.dispatchID == dispatch.id } || $0.ownerDispatchID == dispatch.id }
            var task = step?.task ?? message?.text
            if case let .ownerReview(runID)? = message?.origin,
               let ownerRun = group.runs.first(where: { $0.id == runID && $0.ownerMemberID == member.id }) {
                task = ownerTask(ownerRun, review: true)
            } else if let ownerRun = group.runs.first(where: {
                $0.ownerMemberID == member.id && ($0.ownerDispatchID == dispatch.id || $0.rootMessageID == dispatch.messageID)
            }) { task = ownerTask(ownerRun, review: false) }

            // Durable queue evidence may be newer than the 200ms group projection.
            // Verified native history is stronger than an old queue unknown marker.
            let queued = queue.first {
                $0.id == dispatch.id && $0.command.homePath == dispatch.binding?.homePath
                    && $0.command.threadID == dispatch.binding?.threadID
            }
            let effective = dispatch.nativeReplyVerified ? dispatch.state : (queued?.state ?? dispatch.state)
            var projected = state(effective, verified: dispatch.nativeReplyVerified)
            if (run?.state == .cancelled || step?.state == .cancelled), projected == .queued {
                projected = .cancelled
            } else if (step?.state == .deliveryUnknown || run?.state == .deliveryUnknown || run?.state == .needsInput), projected == .queued {
                projected = .blocked
            }
            tasks.append(.init(id: dispatch.id, state: projected, task: task,
                               turnID: queued?.ownership?.turnID ?? dispatch.turnID,
                               sequence: message?.sequence ?? 0))
        }

        // A dependency step is real accepted work even before its delivery row
        // exists. Do not double-count it when the normal outbox row is present.
        for run in group.runs where !run.state.isTerminal {
            for step in run.steps where step.memberID == member.id && !tasks.contains(where: { $0.id == step.dispatchID }) {
                guard step.state != .finished, step.state != .cancelled else { continue }
                let blocked = step.state == .deliveryUnknown || run.state == .deliveryUnknown || run.state == .needsInput
                let projected: HarvisGroupMemberWorkState = blocked ? .blocked : (step.state == .planned ? .queued : .running)
                tasks.append(.init(id: step.dispatchID, state: projected, task: step.task, turnID: nil,
                                   sequence: group.messages.first { $0.id == run.rootMessageID }?.sequence ?? 0))
            }
            if run.ownerMemberID == member.id, let id = run.ownerDispatchID,
               run.ownerDispatchState == .planned, !tasks.contains(where: { $0.id == id }) {
                tasks.append(.init(id: id, state: .queued, task: ownerTask(run, review: run.state == .reviewing),
                                   turnID: nil, sequence: group.messages.first { $0.id == run.rootMessageID }?.sequence ?? 0))
            }
        }
        let waiting = tasks.filter { $0.state == .queued }.count
        func result(_ state: HarvisGroupMemberWorkState, _ task: String?) -> Self {
            .init(state: state, currentTask: task, queuedTaskCount: waiting, completedTaskCount: completed)
        }
        let matchingLive = live.flatMap { value -> CodexThreadLiveState? in
            guard value.target.homePath == member.binding?.homePath,
                  value.target.threadID == member.binding?.threadID else { return nil }
            return value
        }
        if let live = matchingLive {
            let turn = live.pendingApproval?.turnID ?? live.activeTurnID
            let current = tasks.last { $0.turnID != nil && $0.turnID == turn }
            if live.pendingApproval != nil || live.status == .waitingApproval || live.status == .waitingUserInput {
                return result(.awaitingApproval, current?.task ?? tasks.last { $0.state == .awaitingApproval }?.task)
            }
            if live.activeTurnID != nil || live.status == .active { return result(.running, current?.task) }
        }
        if let task = tasks.last(where: { $0.state == .awaitingApproval }) { return result(.awaitingApproval, task.task) }
        if let task = tasks.last(where: { $0.state == .running }) { return result(.running, task.task) }
        if let task = tasks.last(where: { $0.state == .blocked }) { return result(.blocked, task.task) }
        if let run = group.runs.last(where: { $0.ownerMemberID == member.id && ($0.state == .needsInput || $0.state == .deliveryUnknown) }) {
            let title = run.state == .needsInput ? "群主等待补充信息" : "群主等待执行核验"
            return result(.blocked, rootText(run).map { title + "：" + $0 } ?? title)
        }
        if let task = tasks.enumerated().filter({ $0.element.state == .queued }).min(by: {
            $0.element.sequence == $1.element.sequence ? $0.offset < $1.offset : $0.element.sequence < $1.element.sequence
        })?.element { return result(.queued, task.task) }
        if let run = group.runs.last(where: { $0.ownerMemberID == member.id && $0.state == .working }) {
            let title = "群主协调：等待成员结果并复核"
            return result(.running, rootText(run).map { title + "：" + $0 } ?? title)
        }
        if let run = group.runs.last(where: { $0.ownerMemberID == member.id && ($0.state == .planning || $0.state == .reviewing) }) {
            let resultPending = tasks.contains { $0.id == run.ownerDispatchID && $0.state == .completed }
            return result(resultPending ? .running : .blocked, ownerTask(run, review: run.state == .reviewing))
        }
        // The last recorded task, rather than an unrelated stale native final
        // summary, determines the member's visible terminal state.
        if let task = tasks.enumerated().max(by: {
            $0.element.sequence == $1.element.sequence ? $0.offset < $1.offset : $0.element.sequence < $1.element.sequence
        })?.element { return result(task.state, task.task) }
        return result(.idle, nil)
    }
}

@MainActor
extension HarvisGroupCoordinator {
    func memberWorkStatus(groupID: UUID, memberID: UUID) -> HarvisGroupMemberWorkStatus? {
        guard let group = group(groupID), let member = group.members.first(where: { $0.id == memberID }) else { return nil }
        return .project(group: group, member: member,
                        live: liveState(groupID: groupID, memberID: memberID), queue: delivery.durableQueueItems)
    }
}
