import Foundation

@MainActor
extension HarvisGroupCoordinator {
    func advanceOrchestration() async {
        guard isReady, delivery.isReady, !orchestrationAdvancing else { return }
        orchestrationAdvancing = true
        let generation = orchestrationGeneration
        defer { orchestrationAdvancing = false }
        do {
            try await commit { values in
                guard isReady, orchestrationGeneration == generation else { return }
                let queue = Dictionary(uniqueKeysWithValues: delivery.durableQueueItems.map { ($0.id, $0) })
                for g in values.indices {
                    guard var config = values[g].orchestration else { continue }
                    for r in config.runs.indices where !config.runs[r].state.isTerminal && config.runs[r].state != .needsInput {
                        var run = config.runs[r]
                        var uncertain = false
                        for s in run.steps.indices where run.steps[s].state != .planned && run.steps[s].state != .cancelled {
                            let id = run.steps[s].dispatchID
                            guard let dispatch = values[g].dispatches.first(where: { $0.id == id }) else { uncertain = true; continue }
                            if let accepted = queue[id], accepted.command.threadID == dispatch.binding?.threadID,
                               accepted.command.homePath == dispatch.binding?.homePath {
                                if dispatch.state == .deliveryUnknown { run.steps[s].state = .deliveryUnknown; uncertain = true }
                                else if dispatch.state.isTerminal && (dispatch.nativeReplyVerified || dispatch.turnID == nil) { run.steps[s].state = .finished }
                                else { run.steps[s].state = .submitted }
                            } else if orchestrationTasks[id] != nil { continue }
                            else if dispatch.state == .failed || dispatch.state == .cancelled { run.steps[s].state = .finished }
                            else { run.steps[s].state = .deliveryUnknown; uncertain = true }
                        }
                        if let id = run.ownerDispatchID,
                           let dispatch = values[g].dispatches.first(where: { $0.id == id }) {
                            if run.ownerBinding == nil { run.ownerBinding = dispatch.binding }
                            let key = Self.ownerTurnKey(dispatch)
                            if dispatch.state == .completed, dispatch.nativeReplyVerified,
                               dispatch.memberID == run.ownerMemberID,
                               dispatch.binding?.homePath == run.ownerBinding?.homePath,
                               dispatch.binding?.threadID == run.ownerBinding?.threadID,
                               let key, !run.processedOwnerTurns.contains(key) {
                                if let messageID = dispatch.responseMessageID,
                                   let reply = values[g].messages.first(where: { $0.id == messageID }) {
                                    do {
                                        let decision = try JSONDecoder().decode(HarvisGroupOwnerDecision.self, from: Data(reply.text.utf8))
                                        try Self.validateDecision(decision, run: run, group: values[g])
                                        run.processedOwnerTurns.append(key)
                                        run.ownerDispatchState = .finished
                                        run.ownerRound += 1
                                        run.summary = decision.summary
                                        run.lastError = nil
                                        if reply.sequence >= config.memorySequence { config.memory = decision.memory; config.memorySequence = reply.sequence }
                                        switch decision.action {
                                        case .complete: run.state = .completed
                                        case .needsInput: run.state = .needsInput
                                        case .assign:
                                            for assignment in decision.assignments {
                                                let step = HarvisGroupRunStep(id: assignment.id, memberID: assignment.memberID, task: assignment.task, dependencies: assignment.dependencies)
                                                run.steps.append(step)
                                                values[g].lastSequence += 1
                                                let message = HarvisGroupMessage(sequence: values[g].lastSequence, memberID: run.ownerMemberID,
                                                    speaker: "群主分派", text: assignment.task, recipientMemberIDs: [assignment.memberID],
                                                    origin: .ownerPlan(runID: run.id, sourceDispatchID: id, stepID: step.id))
                                                values[g].messages.append(message)
                                                values[g].dispatches.append(HarvisGroupDispatch(id: step.dispatchID, messageID: message.id, memberID: step.memberID, permission: run.permission))
                                            }
                                            run.state = .working
                                        }
                                    } catch {
                                        if !run.processedOwnerTurns.contains(key) { run.processedOwnerTurns.append(key); run.ownerRound += 1 }
                                        run.ownerDispatchState = .finished
                                        run.state = .needsInput; run.lastError = "群主计划未执行：\(error.localizedDescription)"
                                    }
                                }
                            } else if run.ownerDispatchState != .planned && !run.processedOwnerTurns.contains(key ?? "") {
                                if dispatch.state == .deliveryUnknown || (queue[id] == nil && orchestrationTasks[id] == nil && !dispatch.state.isTerminal) { uncertain = true }
                                else if dispatch.state == .failed || dispatch.state == .cancelled { run.state = .failed; run.lastError = dispatch.lastError ?? "Owner turn did not complete." }
                            }
                        }
                        if uncertain { run.state = .deliveryUnknown; run.lastError = "执行状态不确定；只读取原生证据，不自动重发。" }
                        else if run.state == .deliveryUnknown {
                            if run.ownerDispatchState == .finished { run.state = .working }
                            else { run.state = values[g].messages.first(where: { $0.id == values[g].dispatches.first(where: { $0.id == run.ownerDispatchID })?.messageID })?.origin == .ownerReview(runID: run.id) ? .reviewing : .planning }
                            run.lastError = nil
                        }
                        if run.state == .working {
                            for s in run.steps.indices where run.steps[s].state == .planned {
                                let blocked = run.steps[s].dependencies.contains { dependency in
                                    guard let previous = run.steps.first(where: { $0.id == dependency }), previous.state == .finished || previous.state == .cancelled,
                                          let result = values[g].dispatches.first(where: { $0.id == previous.dispatchID }) else { return false }
                                    return result.state == .failed || result.state == .cancelled
                                }
                                if blocked {
                                    run.steps[s].state = .cancelled
                                    if let d = values[g].dispatches.firstIndex(where: { $0.id == run.steps[s].dispatchID }) {
                                        values[g].dispatches[d].state = .cancelled; values[g].dispatches[d].lastError = "Dependency failed; this step was not submitted."
                                    }
                                }
                            }
                        }
                        if run.state == .working, run.steps.allSatisfy({ $0.state == .finished || $0.state == .cancelled }) {
                            if let owner = run.ownerMemberID {
                                if run.ownerRound >= run.roundLimit { run.state = .needsInput; run.lastError = "已到本轮协作预算，可明确继续后追加预算。" }
                                else {
                                    values[g].lastSequence += 1
                                    let resultText = run.steps.map { step -> String in
                                        let dispatch = values[g].dispatches.first { $0.id == step.dispatchID }
                                        let reply = values[g].messages.first { $0.id == dispatch?.responseMessageID }
                                        return "Step \(step.id), member \(step.memberID), status \(dispatch?.state.rawValue ?? "unknown"):\n\(reply?.text ?? dispatch?.lastError ?? "No final text")"
                                    }.joined(separator: "\n\n")
                                    let message = HarvisGroupMessage(sequence: values[g].lastSequence, memberID: owner, speaker: "协作复核", text: "Review the completed member work for the original user request. Verify the results, delegate further concrete work only if needed, or produce the final summary.\n\n\(resultText)", recipientMemberIDs: [owner], origin: .ownerReview(runID: run.id))
                                    let dispatch = HarvisGroupDispatch(messageID: message.id, memberID: owner, permission: run.permission)
                                    values[g].messages.append(message); values[g].dispatches.append(dispatch)
                                    run.ownerDispatchID = dispatch.id; run.ownerDispatchState = .planned; run.state = .reviewing
                                }
                            } else {
                                let failed = run.steps.contains { step in values[g].dispatches.first(where: { $0.id == step.dispatchID })?.state != .completed }
                                run.state = failed ? .failed : .completed
                                run.summary = failed ? "Some direct member tasks failed or were cancelled; inspect their results." : "Direct member tasks completed."
                            }
                        }
                        config.runs[r] = run
                    }
                    values[g].orchestration = config
                }
            }
            guard isReady, orchestrationGeneration == generation else { return }
            // Only mark a command enqueueStarted while atomically acquiring its project lease.
            var eligible: [(UUID, UUID)] = []
            var scheduledMembers: Set<UUID> = []
            try await commit { values in
                guard isReady, orchestrationGeneration == generation else { return }
                for g in values.indices {
                    guard values[g].orchestration != nil else { continue }
                    for r in values[g].orchestration!.runs.indices {
                        let run = values[g].orchestration!.runs[r]
                        guard !run.state.isTerminal, run.state != .needsInput, run.state != .deliveryUnknown else { continue }
                        var candidates: [UUID] = []
                        if [.planning, .reviewing].contains(run.state), run.ownerDispatchState == .planned, let id = run.ownerDispatchID { candidates.append(id) }
                        if run.state == .working {
                            candidates += run.steps.filter { step in
                                step.state == .planned && step.dependencies.allSatisfy { dependency in
                                    run.steps.first { $0.id == dependency }?.state == .finished
                                }
                            }.map(\.dispatchID)
                        }
                        for id in candidates {
                            guard orchestrationTasks[id] == nil,
                                  let d = values[g].dispatches.firstIndex(where: { $0.id == id }) else { continue }
                            let member = values[g].dispatches[d].memberID
                            guard !scheduledMembers.contains(member), !busyMembers.contains(member),
                                  !values.contains(where: { candidate in candidate.dispatches.contains { $0.memberID == member && orchestrationTasks[$0.id] != nil } }) else { continue }
                            if run.permission == .workspaceWrite, Self.projectHasWriter(values, path: values[g].projectPath, excluding: id) { continue }
                            if run.ownerDispatchID == id { values[g].orchestration?.runs[r].ownerDispatchState = .enqueueStarted }
                            if let s = values[g].orchestration?.runs[r].steps.firstIndex(where: { $0.dispatchID == id }) { values[g].orchestration?.runs[r].steps[s].state = .enqueueStarted }
                            values[g].dispatches[d].state = .queued
                            scheduledMembers.insert(member)
                            eligible.append((values[g].id, id))
                        }
                    }
                }
            }
            guard isReady, orchestrationGeneration == generation else { return }
            for (groupID, id) in eligible {
                orchestrationTasks[id] = Task { [weak self] in
                    guard let self else { return }
                    await self.dispatch(groupID: groupID, dispatchID: id, expectedGeneration: generation)
                    if self.orchestrationGeneration == generation { self.orchestrationTasks.removeValue(forKey: id) }
                }
            }
        } catch { lastError = "协作状态保存失败：\(error.localizedDescription)" }
    }

    static func projectHasWriter(_ groups: [HarvisGroupConversation], path: String, excluding: UUID) -> Bool {
        for group in groups where group.projectPath == path {
            for dispatch in group.dispatches where dispatch.id != excluding && dispatch.permission == .workspaceWrite && (!dispatch.state.isTerminal || dispatch.state == .deliveryUnknown) {
                let step = group.runs.flatMap(\.steps).first { $0.dispatchID == dispatch.id }
                if step?.state == .planned || step?.state == .cancelled { continue }
                if let run = group.runs.first(where: { $0.ownerDispatchID == dispatch.id }), run.ownerDispatchState == .planned { continue }
                return true
            }
        }
        return false
    }

    static func ownerTurnKey(_ dispatch: HarvisGroupDispatch) -> String? {
        guard let binding = dispatch.binding, let turn = dispatch.turnID else { return nil }
        return binding.homePath + "/" + binding.threadID + "/" + turn
    }

    static func validateDecision(_ decision: HarvisGroupOwnerDecision, run: HarvisGroupRun, group: HarvisGroupConversation) throws {
        guard run.ownerRound < run.roundLimit else { throw HarvisGroupError.invalid("Owner round budget reached; continue explicitly.") }
        if decision.action != .assign {
            guard decision.assignments.isEmpty else { throw HarvisGroupError.invalid("Non-assignment decision cannot carry tasks.") }; return
        }
        guard !decision.assignments.isEmpty, run.steps.count + decision.assignments.count <= run.taskLimit else { throw HarvisGroupError.invalid("Task budget reached; continue explicitly.") }
        var ids = Set(run.steps.map(\.id))
        for assignment in decision.assignments {
            guard !assignment.id.isEmpty, assignment.id.count <= 128, ids.insert(assignment.id).inserted,
                  assignment.memberID != run.ownerMemberID, group.members.contains(where: { $0.id == assignment.memberID }),
                  !assignment.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HarvisGroupError.invalid("Duplicate step, invalid member, or empty assignment.") }
        }
        let dependencies = Dictionary(uniqueKeysWithValues: run.steps.map { ($0.id, $0.dependencies) } + decision.assignments.map { ($0.id, $0.dependencies) })
        for item in decision.assignments {
            guard item.dependencies.allSatisfy({ ids.contains($0) && $0 != item.id }) else { throw HarvisGroupError.invalid("Invalid dependency.") }
            func cyclic(_ id: String, path: Set<String>) -> Bool {
                if path.contains(id) { return true }
                return (dependencies[id] ?? []).contains { cyclic($0, path: path.union([id])) }
            }
            guard !cyclic(item.id, path: []) else { throw HarvisGroupError.invalid("Cyclic plan.") }
        }
    }
}
