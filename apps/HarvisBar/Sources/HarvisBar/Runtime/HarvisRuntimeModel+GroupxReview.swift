import Foundation

@MainActor
extension HarvisRuntimeModel {
    private var groupxReviewBridges: [DshBridgeEndpointState] {
        dshBridgeStatesByScope.values
            .filter { state in
                state.supports("groupx.review", operation: "start")
                    && state.supports("groupx.review", operation: "status")
                    && state.supports("groupx.review", operation: "cancel")
                    && dshRunningEndpoints.contains(state.endpoint)
            }
            .sorted { $0.endpoint.sourceScope < $1.endpoint.sourceScope }
    }

    private var groupxReviewBridge: DshBridgeEndpointState? {
        let choices = groupxReviewBridges
        if let scope = projectGroupxReviewSelectedScope {
            return choices.first { $0.endpoint.sourceScope == scope }
        }
        return choices.count == 1 ? choices.first : nil
    }

    private var groupxReviewCatalog: [ManagedProjectRecord] {
        managedChatProjectCatalog.map { project in
            managedProjectOrganization.projects[project.id]
                ?? ManagedProjectRecord(id: project.id, name: project.label, purpose: "")
        }
    }

    private var groupxReviewIsUnsettled: Bool {
        projectGroupxReviewIdentity != nil && (projectGroupxReviewJob == nil
            || projectGroupxReviewJob?.state.isActive == true || projectGroupxReviewJob?.state == .unknown)
    }

    var projectGroupxReviewPresentation: ManagedProjectGroupxReviewPresentation {
        let bridge = groupxReviewBridge
        let currentFingerprint = projectOrganizerProposal.flatMap {
            ManagedProjectGroupxReviewPayload.contextFingerprint($0, catalog: groupxReviewCatalog)
        }
        let alreadyReviewed = projectGroupxReviewJob?.state == .succeeded
            && currentFingerprint == projectGroupxReviewFingerprint
            && bridge?.endpoint == projectGroupxReviewEndpoint
        let host = projectGroupxReviewEndpoint ?? bridge?.endpoint
        return ManagedProjectGroupxReviewPresentation(
            hostLabel: host.map { "\($0.homeID) · \($0.profile)" } ?? "",
            hosts: groupxReviewBridges.map {
                .init(id: $0.endpoint.sourceScope, title: "\($0.endpoint.homeID) · \($0.endpoint.profile)")
            },
            selectedHostID: bridge?.endpoint.sourceScope ?? "",
            canSelectHost: !projectGroupxReviewBusy && !groupxReviewIsUnsettled,
            actionLabel: groupxReviewIsUnsettled ? "查询状态" : alreadyReviewed ? "已复核此版本" : "复核建议",
            canStart: projectOrganizerProposal != nil && !projectOrganizerIsAnalyzing
                && !projectOrganizerIsApplying && !projectGroupxReviewBusy
                && (groupxReviewIsUnsettled || (bridge != nil && !alreadyReviewed)),
            canCancel: groupxReviewIsUnsettled,
            isBusy: projectGroupxReviewBusy,
            isStale: projectGroupxReviewFingerprint != nil && currentFingerprint != projectGroupxReviewFingerprint,
            job: projectGroupxReviewJob,
            message: projectGroupxReviewMessage ?? (bridge == nil
                ? groupxReviewBridges.isEmpty ? "当前 DSH 实例未提供 GroupX 复核。" : "请选择负责本次复核的 DSH 实例。"
                : nil)
        )
    }

    func selectProjectGroupxReviewHost(_ scope: String) {
        guard !projectGroupxReviewBusy, !groupxReviewIsUnsettled,
              groupxReviewBridges.contains(where: { $0.endpoint.sourceScope == scope }) else { return }
        projectGroupxReviewSelectedScope = scope
    }

    func startProjectGroupxReview() {
        guard !projectGroupxReviewBusy, !projectOrganizerIsAnalyzing, !projectOrganizerIsApplying else { return }
        // A lost start response is queried with the same identity. Never resend
        // start automatically or manufacture a new paid run after uncertainty.
        if let identity = projectGroupxReviewIdentity, groupxReviewIsUnsettled {
            runProjectGroupxReview(identity: identity, start: nil)
            return
        }
        guard let proposal = projectOrganizerProposal, let bridge = groupxReviewBridge,
              let authority = bridge.authority,
              let fingerprint = ManagedProjectGroupxReviewPayload.contextFingerprint(proposal, catalog: groupxReviewCatalog) else { return }
        guard projectGroupxReviewJob?.state != .succeeded || projectGroupxReviewFingerprint != fingerprint
                || projectGroupxReviewEndpoint != bridge.endpoint else { return }
        let catalog = groupxReviewCatalog
        let task = ManagedProjectGroupxReviewPayload.task(proposal, catalog: catalog)
        let identity = DshGroupxReviewIdentity(jobID: UUID().uuidString, proposalRevision: DshGroupxReviewStart.revision(task))
        projectGroupxReviewIdentity = identity
        projectGroupxReviewEndpoint = bridge.endpoint
        projectGroupxReviewAuthority = authority
        projectGroupxReviewFingerprint = fingerprint
        projectGroupxReviewJob = nil
        runProjectGroupxReview(identity: identity, start: DshGroupxReviewStart(
            jobID: identity.jobID, proposalRevision: identity.proposalRevision, task: task
        ))
    }

    private func runProjectGroupxReview(identity: DshGroupxReviewIdentity, start: DshGroupxReviewStart?) {
        guard let endpoint = projectGroupxReviewEndpoint, let authority = projectGroupxReviewAuthority else { return }
        let client = makeDshBridgeClient(endpoint)
        let generation = UUID()
        projectGroupxReviewGeneration = generation
        projectGroupxReviewBusy = true
        projectGroupxReviewMessage = nil
        projectGroupxReviewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.projectGroupxReviewGeneration == generation {
                    self.projectGroupxReviewBusy = false
                    self.projectGroupxReviewTask = nil
                }
            }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(90))
                var statusTransportFailures = 0
                for attempt in 0..<80 {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { break }
                    let result: DshBridgeValue<DshGroupxReviewJob>
                    if attempt == 0, let start {
                        result = try await client.startGroupxReview(start)
                    } else {
                        do {
                            result = try await client.groupxReviewStatus(identity)
                            statusTransportFailures = 0
                        } catch let error as URLError {
                            statusTransportFailures += 1
                            guard statusTransportFailures <= 3 else { throw error }
                            try await Task.sleep(for: .seconds(1))
                            continue
                        }
                    }
                    if result.authority != authority && result.value.state == .unknown {
                        guard self.projectGroupxReviewGeneration == generation else { return }
                        self.projectGroupxReviewJob = result.value
                        self.projectGroupxReviewMessage = "实例已重启，原复核状态未知。重新分析会结束本批复核，之后可主动提交新复核。"
                        return
                    }
                    guard result.authority == authority,
                          self.dshRunningEndpoints.contains(endpoint),
                          self.dshBridgeStatesByScope[endpoint.sourceScope]?.authority == authority else {
                        throw DshCapabilityBridgeError.authorityMismatch
                    }
                    guard self.projectGroupxReviewGeneration == generation else { return }
                    self.projectGroupxReviewJob = result.value.redactedForDisplay
                    if !result.value.state.isActive { return }
                    try await Task.sleep(for: .seconds(1))
                }
                self.projectGroupxReviewMessage = "复核仍在运行，可再次查询状态或取消。"
            } catch is CancellationError {
                // Only the matching generation may publish any remote result.
            } catch {
                guard self.projectGroupxReviewGeneration == generation else { return }
                let reason = (error as? DshCapabilityBridgeError)?.localizedDescription ?? "网络连接中断。"
                self.projectGroupxReviewMessage = "\(reason)再次点击会查询原任务，不会重新提交。"
            }
        }
    }

    func cancelProjectGroupxReview() {
        projectGroupxReviewTask?.cancel()
        projectGroupxReviewTask = nil
        projectGroupxReviewBusy = false
        let generation = UUID()
        projectGroupxReviewGeneration = generation
        guard let identity = projectGroupxReviewIdentity, let endpoint = projectGroupxReviewEndpoint,
              let authority = projectGroupxReviewAuthority else { return }
        let client = makeDshBridgeClient(endpoint)
        projectGroupxReviewBusy = true
        projectGroupxReviewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.projectGroupxReviewGeneration == generation {
                    self.projectGroupxReviewBusy = false
                    self.projectGroupxReviewTask = nil
                }
            }
            do {
                let result = try await client.groupxReviewStatus(identity, cancel: true)
                guard result.authority == authority else { throw DshCapabilityBridgeError.authorityMismatch }
                guard self.projectGroupxReviewGeneration == generation else { return }
                self.projectGroupxReviewJob = result.value.redactedForDisplay
                self.projectGroupxReviewMessage = nil
            } catch {
                guard self.projectGroupxReviewGeneration == generation else { return }
                self.projectGroupxReviewMessage = "取消尚未确认，请查询状态。"
            }
        }
    }

    func resetProjectGroupxReview() {
        if let identity = projectGroupxReviewIdentity, let endpoint = projectGroupxReviewEndpoint,
           groupxReviewIsUnsettled {
            let client = makeDshBridgeClient(endpoint)
            Task { _ = try? await client.groupxReviewStatus(identity, cancel: true) }
        }
        projectGroupxReviewTask?.cancel()
        projectGroupxReviewTask = nil
        projectGroupxReviewGeneration = nil
        projectGroupxReviewBusy = false
        projectGroupxReviewIdentity = nil
        projectGroupxReviewEndpoint = nil
        projectGroupxReviewAuthority = nil
        projectGroupxReviewFingerprint = nil
        projectGroupxReviewJob = nil
        projectGroupxReviewMessage = nil
    }
}
