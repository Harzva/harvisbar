import CryptoKit
import Foundation

@MainActor
extension HarvisGroupCoordinator {
    func setOwner(groupID: UUID, memberID: UUID?) async -> Bool {
        guard !configurationGroups.contains(groupID) else { lastError = "Group configuration is being updated."; return false }
        await advanceOrchestration()
        do {
            try await change(groupID) { group in
                guard !configurationGroups.contains(groupID) else { throw HarvisGroupError.invalid("Group configuration is being updated.") }
                guard memberID == nil || group.members.contains(where: { $0.id == memberID }) else { throw HarvisGroupError.invalid("Unknown owner member.") }
                guard !group.runs.contains(where: { !$0.state.isTerminal }) else { throw HarvisGroupError.invalid("Finish or stop the current run before changing owner.") }
                if group.orchestration == nil { group.orchestration = .init() }
                group.orchestration?.ownerMemberID = memberID
            }
            lastError = nil; return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func setProjectPermission(groupID: UUID, permission: HarvisGroupPermission) async -> Bool {
        guard !configurationGroups.contains(groupID) else { lastError = "Group configuration is being updated."; return false }
        await recover(groupID: groupID)
        await advanceOrchestration()
        guard configurationGroups.insert(groupID).inserted else { lastError = "Group configuration is being updated."; return false }
        defer { configurationGroups.remove(groupID) }
        var changed: [(UUID, HarvisGroupBinding)] = []
        do {
            guard let group = group(groupID) else { throw HarvisGroupError.invalid("Group missing.") }
            guard !group.members.contains(where: { busyMembers.contains($0.id) }) else { throw HarvisGroupError.invalid("A member binding is being prepared or handed off; retry after it finishes.") }
            if group.projectPermission != permission {
                guard !group.dispatches.contains(where: { !$0.state.isTerminal || $0.state == .deliveryUnknown }),
                      !group.runs.contains(where: { !$0.state.isTerminal }) else { throw HarvisGroupError.invalid("Finish or stop pending work before changing project permission.") }
                // Reconfigure the existing native thread, preserving all native context.
                for member in group.members {
                    guard let binding = member.binding, binding.permission != permission else { continue }
                    let updated = try await reconfigureProjectBinding(binding, projectPath: group.projectPath, permission: permission, emptyLineage: "permission-reconfiguration-empty")
                    changed.append((member.id, binding))
                    try await setBinding(groupID, member.id, updated)
                }
            }
            try await change(groupID) { value in
                guard isReady, !value.dispatches.contains(where: { !$0.state.isTerminal || $0.state == .deliveryUnknown }),
                      !value.runs.contains(where: { !$0.state.isTerminal }) else { throw HarvisGroupError.invalid("Group work changed during permission update.") }
                if value.orchestration == nil { value.orchestration = .init() }
                value.orchestration?.projectPermission = permission
            }
            lastError = nil; return true
        } catch {
            let reason = error.localizedDescription
            var rollbackFailed = false
            if let project = group(groupID)?.projectPath {
                for (memberID, original) in changed.reversed() {
                    do {
                        let current = group(groupID)?.members.first(where: { $0.id == memberID })?.binding ?? original
                        let restored = try await reconfigureProjectBinding(current, projectPath: project, permission: original.permission, emptyLineage: "permission-rollback-empty")
                        try await setBinding(groupID, memberID, restored)
                    } catch { rollbackFailed = true }
                }
            }
            lastError = reason + (rollbackFailed ? " Partial native configuration requires inspection; future turns must revalidate the persisted project grant." : "")
            return false
        }
    }

    private func reconfigureProjectBinding(_ binding: HarvisGroupBinding, projectPath: String, permission: HarvisGroupPermission, emptyLineage: String) async throws -> HarvisGroupBinding {
        do {
            let probe = CodexGroupNativeActivityProbe(pool: delivery.pool)
            guard try await !probe.isThreadRunning(homePath: binding.homePath, threadID: binding.threadID) else { throw HarvisGroupError.invalid("A member is still active.") }
            return try await adapter.reconfigure(binding, projectPath: projectPath, permission: permission)
        } catch {
            guard !hasDispatchReference(binding),
                  case let CodexAppServerError.rpc(code, message) = error, code == -32600,
                  message == "thread not loaded: \(binding.threadID)" || message.lowercased().hasPrefix("no rollout found for thread id"),
                  try await adapter.identity(homePath: binding.homePath) == binding.accountIdentity else { throw error }
            var replacement = try await adapter.start(homePath: binding.homePath, projectPath: projectPath, permission: permission, predecessor: binding)
            replacement.lineage = emptyLineage
            return replacement
        }
    }

    func setBackgroundEnabled(groupID: UUID, enabled: Bool) async -> Bool {
        do {
            try await change(groupID) { group in
                if group.orchestration == nil { group.orchestration = .init() }
                group.orchestration?.backgroundEnabled = enabled
            }
            lastError = nil; return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func submitCoordinated(groupID: UUID, text: String, requestID: String? = nil, requireBackgroundEnabled: Bool = false) async throws -> HarvisGroupSubmissionReceipt {
        return try await acceptSubmission(groupID: groupID, text: text, memberIDs: [], permission: .discussion, requestID: requestID, coordinated: true, requireBackgroundEnabled: requireBackgroundEnabled)
    }

    func submitDirect(groupID: UUID, text: String, memberIDs: [UUID], permission: HarvisGroupPermission,
                      requestID: String? = nil, requireBackgroundEnabled: Bool = false) async throws -> HarvisGroupSubmissionReceipt {
        try await acceptSubmission(groupID: groupID, text: text, memberIDs: memberIDs, permission: permission, requestID: requestID, coordinated: false, requireBackgroundEnabled: requireBackgroundEnabled)
    }

    private func acceptSubmission(groupID: UUID, text: String, memberIDs: [UUID], permission: HarvisGroupPermission,
                                  requestID: String?, coordinated: Bool, requireBackgroundEnabled: Bool) async throws -> HarvisGroupSubmissionReceipt {
        guard isReady, delivery.isReady else { throw HarvisGroupError.invalid("Group runtime is not ready.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HarvisGroupError.invalid("Message cannot be empty.") }
        if let requestID { guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, requestID.count <= 128 else { throw HarvisGroupError.invalid("Invalid request ID.") } }
        let ids = Array(Set(memberIDs)).sorted { $0.uuidString < $1.uuidString }
        let payload = try JSONSerialization.data(withJSONObject: ["mode": coordinated ? "coordinated" : "direct", "text": text, "members": ids.map(\.uuidString), "permission": (coordinated || requireBackgroundEnabled) ? "groupGrant" : permission.rawValue], options: [.sortedKeys])
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        var receipt: HarvisGroupSubmissionReceipt?
        try await commit { values in
            guard let g = values.firstIndex(where: { $0.id == groupID }) else { throw HarvisGroupError.invalid("Group missing.") }
            guard isReady, delivery.isReady, !configurationGroups.contains(groupID) else { throw HarvisGroupError.invalid("Group configuration is being updated or runtime is inactive.") }
            guard !requireBackgroundEnabled || values[g].backgroundEnabled else { throw HarvisGroupError.invalid("Background access is disabled for this group.") }
            if let requestID, let prior = values[g].orchestration?.requests.first(where: { $0.requestID == requestID }) {
                guard prior.payloadHash == hash else { throw HarvisGroupError.invalid("Request ID conflict: payload differs from the accepted request.") }
                receipt = prior.receipt; return
            }
            let recipients: [UUID]
            if coordinated {
                guard let owner = values[g].ownerMemberID else { throw HarvisGroupError.invalid("Set a group owner before starting coordinated work.") }
                recipients = [owner]
            } else { recipients = ids }
            let effectivePermission = (coordinated || requireBackgroundEnabled) ? values[g].projectPermission : permission
            guard recipients.allSatisfy({ id in values[g].members.contains { $0.id == id } }) else { throw HarvisGroupError.invalid("Unknown recipient.") }
            guard effectivePermission != .workspaceWrite || values[g].projectPermission == .workspaceWrite else { throw HarvisGroupError.invalid("Project write permission has not been granted for this group.") }
            if values[g].orchestration == nil { values[g].orchestration = .init() }
            values[g].lastSequence += 1
            let message = HarvisGroupMessage(sequence: values[g].lastSequence, speaker: "你", text: text, recipientMemberIDs: recipients, origin: .user)
            values[g].messages.append(message)
            var runID: UUID?
            var dispatchIDs: [UUID] = []
            if !recipients.isEmpty {
                var run = HarvisGroupRun(requestID: requestID, rootMessageID: message.id,
                    ownerMemberID: coordinated ? values[g].ownerMemberID : nil,
                    ownerBinding: coordinated ? values[g].members.first { $0.id == values[g].ownerMemberID }?.binding : nil,
                    permission: effectivePermission, state: coordinated ? .planning : .working)
                if coordinated {
                    let dispatch = HarvisGroupDispatch(messageID: message.id, memberID: recipients[0], permission: effectivePermission)
                    run.ownerDispatchID = dispatch.id; values[g].dispatches.append(dispatch); dispatchIDs = [dispatch.id]
                } else {
                    for id in recipients {
                        let dispatch = HarvisGroupDispatch(messageID: message.id, memberID: id, permission: effectivePermission)
                        run.steps.append(HarvisGroupRunStep(id: "direct-" + id.uuidString, memberID: id, task: text, dispatchID: dispatch.id))
                        values[g].dispatches.append(dispatch); dispatchIDs.append(dispatch.id)
                    }
                }
                runID = run.id; values[g].orchestration?.runs.append(run)
            }
            let value = HarvisGroupSubmissionReceipt(groupID: groupID, messageID: message.id, runID: runID, dispatchIDs: dispatchIDs)
            if let requestID { values[g].orchestration?.requests.append(.init(requestID: requestID, payloadHash: hash, receipt: value)) }
            receipt = value
        }
        lastError = nil
        Task { await self.advanceOrchestration() }
        guard let receipt else { throw HarvisGroupError.invalid("Submission could not be persisted.") }
        return receipt
    }

    func cancelRun(groupID: UUID, runID: UUID) async -> Bool {
        do {
            var dispatchIDs: Set<UUID> = []
            try await change(groupID) { group in
                guard let r = group.orchestration?.runs.firstIndex(where: { $0.id == runID }) else { throw HarvisGroupError.invalid("Run missing.") }
                let run = group.orchestration!.runs[r]
                dispatchIDs = Set(run.steps.map(\.dispatchID) + [run.ownerDispatchID].compactMap { $0 })
                group.orchestration?.runs[r].state = .cancelled
                for s in group.orchestration!.runs[r].steps.indices where group.orchestration!.runs[r].steps[s].state == .planned {
                    group.orchestration?.runs[r].steps[s].state = .cancelled
                }
                for d in group.dispatches.indices where dispatchIDs.contains(group.dispatches[d].id) && group.dispatches[d].binding == nil {
                    group.dispatches[d].state = .cancelled
                }
            }
            stoppedDispatches.formUnion(dispatchIDs)
            for id in dispatchIDs { await delivery.cancelQueuedCommand(id) }
            // Interrupt only the exact owned active turn belonging to this run.
            for item in delivery.durableQueueItems where dispatchIDs.contains(item.id) {
                let live = delivery.liveState(homePath: item.command.homePath, threadID: item.command.threadID)
                guard let turn = item.ownership?.managerTurnID(on: live.connectionID), turn == live.activeTurnID else { continue }
                let connection = await delivery.pool.connection(for: item.command.homePath)
                guard await connection.connectionID() == live.connectionID else { continue }
                _ = try await connection.request(method: "turn/interrupt", params: .object(["threadId": .string(item.command.threadID), "turnId": .string(turn)]))
            }
            lastError = nil; return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func resumeRun(groupID: UUID, runID: UUID) async -> Bool {
        do {
            try await change(groupID) { group in
                guard let r = group.orchestration?.runs.firstIndex(where: { $0.id == runID }) else { throw HarvisGroupError.invalid("Run missing.") }
                guard group.orchestration?.runs[r].state == .needsInput else { throw HarvisGroupError.invalid("Stopped or uncertain runs cannot be replayed. Start a new explicit request or recover native evidence.") }
                group.orchestration?.runs[r].roundLimit += 8
                group.orchestration?.runs[r].taskLimit += 24
                group.orchestration?.runs[r].state = .working
            }
            await advanceOrchestration(); lastError = nil; return true
        } catch { lastError = error.localizedDescription; return false }
    }
}
