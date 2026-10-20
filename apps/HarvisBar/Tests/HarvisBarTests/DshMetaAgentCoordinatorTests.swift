import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class DshMetaAgentCoordinatorTests: XCTestCase {
    func testProjectMetaSessionIdentityIsStableOpaqueAndProjectScoped() {
        let first = DshMetaAgentPolicy.projectSessionID(
            projectID: "project-sensitive-path-a"
        )
        let sameAfterRestart = DshMetaAgentPolicy.projectSessionID(
            projectID: "project-sensitive-path-a"
        )
        let second = DshMetaAgentPolicy.projectSessionID(
            projectID: "project-sensitive-path-b"
        )

        XCTAssertEqual(first, sameAfterRestart)
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertFalse(first.contains("project"))
        XCTAssertFalse(first.contains("path"))
    }

    func testPreviewPersistsRPCBeforeQueueAndNeverDispatches() async throws {
        let fixture = makeFixture()
        await fixture.coordinator.activate()

        let proposal = makeProposal(
            runID: runID,
            expectedRevision: 1
        )
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(proposal))
        )

        let accepted = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-plan-1"
        )

        XCTAssertEqual(accepted, proposal)
        let ledger = try XCTUnwrap(fixture.coordinator.ledger(runID: runID))
        XCTAssertEqual(ledger.revision, 2)
        XCTAssertEqual(ledger.planningRPCID, "rpc-plan-1")
        XCTAssertEqual(ledger.currentState.management, .awaitingPreview)
        XCTAssertEqual(ledger.currentState.delivery, .none)
        XCTAssertTrue(fixture.codex.submissions.isEmpty)

        let prompts = await fixture.dsh.promptRequests()
        let sessions = await fixture.dsh.sessionRequests()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].projectPath, "/tmp/project-1")
        XCTAssertEqual(
            sessions[0].presetID,
            DshMetaAgentPolicy.requiredPresetID
        )
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].mode, .queue)
        XCTAssertEqual(prompts[0].rpcID, "rpc-plan-1")
        XCTAssertTrue(prompts[0].text.contains(runID.uuidString))
        XCTAssertTrue(prompts[0].text.contains("expectedRevision"))

        let saves = await fixture.store.saveHistory()
        XCTAssertEqual(saves.count, 2)
        let durablePlanning = try XCTUnwrap(saves[0].ledger(runID: runID))
        XCTAssertEqual(durablePlanning.currentState.management, .planning)
        XCTAssertEqual(durablePlanning.planningRPCID, "rpc-plan-1")
        XCTAssertNil(durablePlanning.latestProposal)
    }

    func testPromptResponseLossIsTerminalAndNeverResent() async throws {
        let fixture = makeFixture()
        await fixture.dsh.setQueueFailure(.timeout)
        await fixture.coordinator.activate()

        do {
            _ = try await fixture.coordinator.requestDecision(
                runID: runID,
                metaSessionID: "meta-session",
                projectPath: "/tmp/project-1",
                endpoint: endpoint,
                preset: DshMetaAgentPolicy.requiredPresetID,
                policy: policy,
                expectedRevision: 0,
                planningRPCID: "rpc-lost"
            )
            XCTFail("A lost mutation response must become deliveryUnknown")
        } catch let error as DshMetaAgentCoordinatorError {
            guard case .deliveryUnknown = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let unknown = try XCTUnwrap(
            fixture.coordinator.ledger(runID: runID)
        )
        XCTAssertEqual(unknown.currentState.delivery, .deliveryUnknown)
        XCTAssertEqual(unknown.currentState.management, .deliveryUnknown)
        XCTAssertEqual(unknown.planningRPCID, "rpc-lost")
        let queueCountAfterLoss = await fixture.dsh.queueCount()
        XCTAssertEqual(queueCountAfterLoss, 1)

        do {
            _ = try await fixture.coordinator.requestDecision(
                runID: runID,
                metaSessionID: "meta-session",
                projectPath: "/tmp/project-1",
                endpoint: endpoint,
                preset: DshMetaAgentPolicy.requiredPresetID,
                policy: policy,
                expectedRevision: unknown.revision,
                planningRPCID: "rpc-must-not-send"
            )
            XCTFail("A terminal unknown run must not restart planning")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(
                error,
                .invalidTransition(
                    from: "deliveryUnknown",
                    to: "planning"
                )
            )
        }
        let queueCountAfterRetry = await fixture.dsh.queueCount()
        XCTAssertEqual(queueCountAfterRetry, 1)
    }

    func testV1CoordinatorRejectsMultipleDecisionsAndStopsRun() async throws {
        let fixture = makeFixture()
        await fixture.coordinator.activate()
        let first = makeProposal(runID: runID, expectedRevision: 1)
        let second = ConversationManagementDecisionV1(
            id: UUID(
                uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
            )!,
            kind: .dispatch,
            target: target,
            taskID: "task-1",
            prompt: "Run a second unrelated action",
            reason: "This must be rejected in a serial v1 cycle",
            expectedEvidence: "Second result"
        )
        let invalid = ConversationManagementProposalV1(
            runID: first.runID,
            projectID: first.projectID,
            expectedRevision: first.expectedRevision,
            projectionRevision: first.projectionRevision,
            cycle: first.cycle,
            summary: first.summary,
            decisions: first.decisions + [second]
        )
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(invalid))
        )

        do {
            _ = try await fixture.coordinator.requestDecision(
                runID: runID,
                metaSessionID: "meta-session",
                projectPath: "/tmp/project-1",
                endpoint: endpoint,
                preset: DshMetaAgentPolicy.requiredPresetID,
                policy: ConversationManagementValidationPolicyV1(
                    allowedTargets: [target],
                    maxDecisions: 5
                ),
                expectedRevision: 0,
                planningRPCID: "rpc-multi"
            )
            XCTFail("v1 must accept only one serial decision per cycle")
        } catch let error as DshMetaAgentCoordinatorError {
            guard case .invalidProposal = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            fixture.coordinator.ledger(runID: runID)?
                .currentState.management,
            .failed
        )
        XCTAssertTrue(fixture.codex.submissions.isEmpty)
    }

    func testMissingDedicatedPresetFailsClosedWithoutPromptOrFallback() async throws {
        let fixture = makeFixture()
        await fixture.dsh.setPrepareFailure(.presetMissing)
        await fixture.coordinator.activate()

        do {
            _ = try await fixture.coordinator.requestDecision(
                runID: runID,
                metaSessionID: "meta-session",
                projectPath: "/tmp/project-1",
                endpoint: endpoint,
                preset: DshMetaAgentPolicy.requiredPresetID,
                policy: policy,
                expectedRevision: 0,
                planningRPCID: "rpc-no-preset"
            )
            XCTFail("The coordinator must not fall back to a general preset")
        } catch let error as DshMetaAgentClientError {
            XCTAssertEqual(
                error,
                .unavailablePreset(DshMetaAgentPolicy.requiredPresetID)
            )
        }
        let queueCount = await fixture.dsh.queueCount()
        XCTAssertEqual(queueCount, 0)
        XCTAssertEqual(
            fixture.coordinator.ledger(runID: runID)?
                .currentState.management,
            .failed
        )
    }

    func testCoordinatorRejectsWrongEndpointAndDisabledBrainBeforePlanning() async throws {
        let wrongEndpointFixture = makeFixture()
        await wrongEndpointFixture.coordinator.activate()
        let wrongEndpoint = DshRuntimeEndpoint(
            homeID: "dsh-general",
            profile: "web",
            port: 54_720
        )
        do {
            _ = try await wrongEndpointFixture.coordinator.requestDecision(
                runID: runID,
                metaSessionID: "meta-session",
                projectPath: "/tmp/project-1",
                endpoint: wrongEndpoint,
                preset: DshMetaAgentPolicy.requiredPresetID,
                policy: policy,
                expectedRevision: 0,
                planningRPCID: "rpc-wrong-endpoint"
            )
            XCTFail("A general DSH endpoint must never host the project brain")
        } catch let error as DshMetaAgentCoordinatorError {
            XCTAssertEqual(
                error,
                .brainEndpointUnavailable(
                    homeID: DshMetaAgentPolicy.dedicatedHomeID,
                    profile: DshMetaAgentPolicy.dedicatedProfile
                )
            )
        }
        XCTAssertEqual(
            wrongEndpointFixture.coordinator.ledger(runID: runID)?.revision,
            0
        )
        let wrongEndpointPrompts = await wrongEndpointFixture.dsh.promptRequests()
        let wrongEndpointSessions = await wrongEndpointFixture.dsh.sessionRequests()
        XCTAssertTrue(wrongEndpointPrompts.isEmpty)
        XCTAssertTrue(wrongEndpointSessions.isEmpty)

        let disabledFixture = makeFixture()
        var disabled = makeSnapshot()
        disabled.brainEnabled = false
        disabled.revision += 1
        try await disabledFixture.store.upsert(
            snapshot: disabled,
            expectedRevision: 0
        )
        await disabledFixture.coordinator.activate()
        do {
            _ = try await disabledFixture.coordinator.requestDecision(
                runID: runID,
                metaSessionID: "meta-session",
                projectPath: "/tmp/project-1",
                endpoint: endpoint,
                preset: DshMetaAgentPolicy.requiredPresetID,
                policy: policy,
                expectedRevision: 0,
                planningRPCID: "rpc-disabled-brain"
            )
            XCTFail("A disabled project brain must not receive project context")
        } catch let error as DshMetaAgentCoordinatorError {
            XCTAssertEqual(error, .projectManagementDisabled(projectID))
        }
        XCTAssertEqual(
            disabledFixture.coordinator.ledger(runID: runID)?.revision,
            0
        )
        let disabledPrompts = await disabledFixture.dsh.promptRequests()
        let disabledSessions = await disabledFixture.dsh.sessionRequests()
        XCTAssertTrue(disabledPrompts.isEmpty)
        XCTAssertTrue(disabledSessions.isEmpty)
    }

    func testApprovalUsesCASPreallocatedCommandAndExactQueueItem() async throws {
        let commandID = UUID(
            uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
        )!
        let fixture = makeFixture(makeUUID: { commandID })
        fixture.codex.nextState = .waitingApproval
        await fixture.coordinator.activate()
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-plan"
        )

        do {
            _ = try await fixture.coordinator.approveProposal(
                runID: runID,
                decisionID: decisionID,
                destination: destination,
                policy: policy,
                projectManagementEnabled: true,
                expectedRevision: 1
            )
            XCTFail("Stale UI approval must not dispatch")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .staleRevision(expected: 1, actual: 2))
        }
        XCTAssertTrue(fixture.codex.submissions.isEmpty)

        let outcome = try await fixture.coordinator.approveProposal(
            runID: runID,
            decisionID: decisionID,
            destination: destination,
            policy: policy,
            projectManagementEnabled: true,
            expectedRevision: 2
        )
        XCTAssertEqual(outcome.commandID, commandID)
        XCTAssertEqual(outcome.delivery, .waitingApproval)
        XCTAssertTrue(outcome.isPaused)
        XCTAssertEqual(fixture.codex.submissions.map(\.commandID), [commandID])
        XCTAssertEqual(fixture.codex.itemRequests, [commandID])

        let ledger = try XCTUnwrap(fixture.coordinator.ledger(runID: runID))
        XCTAssertEqual(ledger.dispatchMemory.count, 1)
        XCTAssertEqual(ledger.dispatchMemory[0].commandID, commandID)
        XCTAssertEqual(ledger.dispatchMemory[0].evidenceRevision, 1)
        XCTAssertEqual(ledger.currentState.management, .waitingApproval)
        let saves = await fixture.store.saveHistory()
        XCTAssertTrue(saves.contains(where: {
            $0.ledger(runID: runID)?.currentState.delivery == .dispatching
        }))

        let duplicate = try await fixture.coordinator.approveProposal(
            runID: runID,
            decisionID: decisionID,
            destination: destination,
            policy: policy,
            projectManagementEnabled: true,
            expectedRevision: ledger.revision
        )
        XCTAssertEqual(duplicate, outcome)
        XCTAssertEqual(fixture.codex.submissions.count, 1)
        XCTAssertEqual(fixture.codex.itemRequests, [commandID, commandID])
    }

    func testCancelCannotRaceAnApprovalAcrossTheFinalEnqueueBoundary() async throws {
        let commandID = UUID(
            uuidString: "DADADADA-DADA-DADA-DADA-DADADADADADA"
        )!
        let fixture = makeFixture(makeUUID: { commandID })
        fixture.codex.shouldSuspendEnqueue = true
        await fixture.coordinator.activate()
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-cancel-race"
        )

        let approval = Task { @MainActor in
            try await fixture.coordinator.approveProposal(
                runID: self.runID,
                decisionID: self.decisionID,
                destination: self.destination,
                policy: self.policy,
                projectManagementEnabled: true,
                expectedRevision: 2
            )
        }
        await fixture.codex.waitUntilEnqueueStarted()
        let dispatching = try XCTUnwrap(
            fixture.coordinator.ledger(runID: runID)
        )
        XCTAssertEqual(dispatching.currentState.delivery, .dispatching)
        XCTAssertTrue(fixture.codex.submissions.isEmpty)

        do {
            try await fixture.coordinator.cancel(
                runID: runID,
                expectedRevision: dispatching.revision
            )
            XCTFail("Cancel must not terminalize a command during commit")
        } catch let error as DshMetaAgentCoordinatorError {
            XCTAssertEqual(error, .projectApprovalInFlight(projectID))
        }
        XCTAssertEqual(
            fixture.coordinator.ledger(runID: runID)?.currentState.delivery,
            .dispatching
        )

        fixture.codex.releaseEnqueue()
        _ = try await approval.value
        XCTAssertEqual(fixture.codex.submissions.map(\.commandID), [commandID])
    }

    func testPlanningCancelStopsOldResultAndReleasesProjectReservation() async throws {
        let cancelledRunID = UUID(
            uuidString: "ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC"
        )!
        let fixture = makeFixture(makeUUID: { cancelledRunID })
        await fixture.coordinator.activate()
        await fixture.dsh.setSuspendDecision(true)
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                ConversationManagementProposalV1(
                    runID: cancelledRunID,
                    projectID: projectID,
                    expectedRevision: 1,
                    projectionRevision: 0,
                    cycle: 1,
                    summary: "This result must be ignored after cancellation",
                    decisions: [
                        ConversationManagementDecisionV1(
                            id: decisionID,
                            kind: .dispatch,
                            target: target,
                            taskID: "task-1",
                            prompt: "Do not deliver this cancelled proposal",
                            reason: "Cancellation race regression",
                            expectedEvidence: "No Codex submission"
                        ),
                    ]
                )
            ))
        )

        let start = Task { @MainActor in
            try await fixture.coordinator.startPreview(
                projectID: self.projectID,
                objective: "Wait for a cancellable DSH decision",
                projectPath: "/tmp/project-1",
                endpoint: self.endpoint,
                policy: self.policy
            )
        }
        await fixture.dsh.waitUntilDecisionWaitStarted()
        let planning = try XCTUnwrap(
            fixture.coordinator.ledger(runID: cancelledRunID)
        )
        XCTAssertEqual(planning.currentState.management, .planning)

        try await fixture.coordinator.cancel(
            runID: cancelledRunID,
            expectedRevision: planning.revision
        )
        let cancellationCount = await fixture.dsh.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(
            fixture.coordinator.ledger(runID: cancelledRunID)?
                .currentState.management,
            .cancelled
        )

        try await fixture.coordinator.configureProjectSnapshot(
            makeSnapshot(),
            expectedRevision: 0
        )

        await fixture.dsh.resumeDecisionWait()
        do {
            _ = try await start.value
            XCTFail("A cancelled DSH result must never be accepted")
        } catch let error as DshMetaAgentCoordinatorError {
            XCTAssertEqual(error, .runCancelled(cancelledRunID))
        }
        XCTAssertTrue(fixture.codex.submissions.isEmpty)
    }

    func testDispatchedCodexCommandCannotBeCancelledByMetaRun() async throws {
        let fixture = makeFixture()
        fixture.codex.nextState = .running
        await fixture.coordinator.activate()
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-active-cancel"
        )
        _ = try await fixture.coordinator.approveProposal(
            runID: runID,
            decisionID: decisionID,
            destination: destination,
            policy: policy,
            projectManagementEnabled: true,
            expectedRevision: 2
        )
        let running = try XCTUnwrap(fixture.coordinator.ledger(runID: runID))

        do {
            try await fixture.coordinator.cancel(
                runID: runID,
                expectedRevision: running.revision
            )
            XCTFail("Meta cancellation cannot masquerade as Codex cancellation")
        } catch let error as DshMetaAgentCoordinatorError {
            XCTAssertEqual(error, .runNotCancellable(runID))
        }
        XCTAssertEqual(
            fixture.coordinator.ledger(runID: runID)?.currentState.delivery,
            .running
        )
        XCTAssertEqual(fixture.codex.submissions.count, 1)
    }

    func testRecordedDispatchReconcileTracksExactQueueLifecycleWithoutReplay() async throws {
        let commandID = UUID(
            uuidString: "D0D0D0D0-D0D0-D0D0-D0D0-D0D0D0D0D0D0"
        )!
        let fixture = makeFixture(makeUUID: { commandID })
        fixture.codex.nextState = .waiting
        await fixture.coordinator.activate()
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-lifecycle"
        )
        _ = try await fixture.coordinator.approveProposal(
            runID: runID,
            decisionID: decisionID,
            destination: destination,
            policy: policy,
            projectManagementEnabled: true,
            expectedRevision: 2
        )
        XCTAssertEqual(
            fixture.coordinator.ledger(runID: runID)?.currentState.delivery,
            .accepted
        )

        for (queueState, expectedDelivery) in [
            (CodexDeliveryState.running, ConversationDeliveryStateV1.running),
            (.waitingApproval, .waitingApproval),
            (.running, .running),
            (.completed, .completed),
        ] {
            fixture.codex.setItemState(queueState, commandID: commandID)
            await fixture.coordinator.reconcileRecordedDispatches()
            XCTAssertEqual(
                fixture.coordinator.ledger(runID: runID)?.currentState.delivery,
                expectedDelivery
            )
        }

        XCTAssertEqual(
            fixture.codex.submissions.map(\.commandID),
            [commandID],
            "Status reconciliation must never enqueue or replay a command"
        )
    }

    func testRejectedTerminalQueueSaveCannotAdvanceMetaLedger() async throws {
        let commandID = UUID(
            uuidString: "D1D1D1D1-D1D1-D1D1-D1D1-D1D1D1D1D1D1"
        )!
        let queueStore = StateBlockingCodexTaskQueueStore()
        await queueStore.setBlockedState(.cancelled)
        let codex = CodexTaskDeliveryCoordinator(
            store: queueStore,
            handoffStore: InMemoryCodexConversationHandoffStore(),
            activityProbe: ScriptedCodexActivityProbe([true]),
            monitorIntervalNanoseconds: 60_000_000_000
        )
        await codex.activate(probeExecutablePath: "/bin/false")

        let managementStore = InMemoryConversationManagementStore(
            ConversationManagementStoreEnvelopeV1(
                snapshots: [makeSnapshot()],
                ledgers: [ConversationManagementProgressLedgerV1(
                    runID: runID,
                    projectID: projectID,
                    objective: "Prove only durable queue evidence advances Meta"
                )]
            )
        )
        let dsh = FakeDshMetaAgentClient()
        let coordinator = DshMetaAgentCoordinator(
            store: managementStore,
            dshClient: dsh,
            codexDispatcher: codex,
            makeUUID: { commandID }
        )
        let suite = "DurableMetaQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = HarvisRuntimeModel(
            defaults: defaults,
            codexTaskDelivery: codex,
            dshMetaAgentCoordinator: coordinator
        )
        await runtime.activateConversationManagement()
        await dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-durable-queue"
        )
        let accepted = try await coordinator.approveProposal(
            runID: runID,
            decisionID: decisionID,
            destination: destination,
            policy: policy,
            projectManagementEnabled: true,
            expectedRevision: 2
        )
        XCTAssertEqual(accepted.delivery, .accepted)
        let ledgerRevision = try XCTUnwrap(
            coordinator.ledger(runID: runID)
        ).revision
        let durableRevision = codex.durableQueueRevision

        await codex.cancelQueuedCommand(commandID)
        XCTAssertEqual(
            codex.queueItems.first(where: { $0.id == commandID })?.state,
            .cancelled
        )
        XCTAssertEqual(
            codex.durableQueueItems.first(where: { $0.id == commandID })?
                .state,
            .waiting
        )
        XCTAssertEqual(codex.durableQueueRevision, durableRevision)

        // Give the Runtime observer enough time to react if it were still
        // subscribed to the optimistic `queueItems` publication.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            coordinator.ledger(runID: runID)?.currentState.delivery,
            .accepted
        )
        XCTAssertEqual(
            coordinator.ledger(runID: runID)?.revision,
            ledgerRevision
        )

        // A direct reconciliation pass is also constrained to durable queue
        // evidence and therefore cannot observe the rejected cancellation.
        await coordinator.reconcileRecordedDispatches()
        XCTAssertEqual(
            coordinator.ledger(runID: runID)?.currentState.delivery,
            .accepted
        )
        XCTAssertEqual(
            coordinator.ledger(runID: runID)?.revision,
            ledgerRevision
        )
        let blockedAttemptCount = await queueStore.blockedAttemptCount
        XCTAssertEqual(blockedAttemptCount, 1)

        runtime.deactivateConversationManagement()
        await codex.deactivate()
    }

    func testApprovalRevalidatesBrainAllowlistAndCurrentSnapshot() async throws {
        let fixture = makeFixture()
        await fixture.coordinator.activate()
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-plan"
        )

        do {
            _ = try await fixture.coordinator.approveProposal(
                runID: runID,
                decisionID: decisionID,
                destination: destination,
                policy: policy,
                projectManagementEnabled: false,
                expectedRevision: 2
            )
            XCTFail("A disabled project brain must block approval")
        } catch let error as DshMetaAgentCoordinatorError {
            XCTAssertEqual(error, .projectManagementDisabled(projectID))
        }

        do {
            _ = try await fixture.coordinator.approveProposal(
                runID: runID,
                decisionID: decisionID,
                destination: destination,
                policy: ConversationManagementValidationPolicyV1(
                    allowedTargets: [],
                    maxDecisions: 1
                ),
                projectManagementEnabled: true,
                expectedRevision: 2
            )
            XCTFail("A target removed from the current allowlist must block")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .targetNotAllowed(target.stableID))
        }

        var changedSnapshot = makeSnapshot()
        try changedSnapshot.setEnrollment(
            .excluded,
            for: target,
            expectedRevision: 0
        )
        try await fixture.store.upsert(
            snapshot: changedSnapshot,
            expectedRevision: 0
        )
        do {
            _ = try await fixture.coordinator.approveProposal(
                runID: runID,
                decisionID: decisionID,
                destination: destination,
                policy: policy,
                projectManagementEnabled: true,
                expectedRevision: 2
            )
            XCTFail("A preview over a superseded snapshot must not dispatch")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .staleRevision(expected: 0, actual: 1))
        }
        XCTAssertTrue(fixture.codex.submissions.isEmpty)
    }

    func testApprovalRejectsExcludedDisappearedAndMovedTargets() async throws {
        let excludedFixture = makeFixture()
        await excludedFixture.coordinator.activate()
        await excludedFixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await excludedFixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-excluded"
        )
        var excluded = makeSnapshot()
        var extensionValue = try XCTUnwrap(
            excluded.conversations[0].managementExtension
        )
        extensionValue.enrollment = .excluded
        excluded.conversations[0].managementExtension = extensionValue
        try await excludedFixture.store.upsert(
            snapshot: excluded,
            expectedRevision: 0
        )
        do {
            _ = try await excludedFixture.coordinator.approveProposal(
                runID: runID,
                decisionID: decisionID,
                destination: destination,
                policy: policy,
                projectManagementEnabled: true,
                expectedRevision: 2
            )
            XCTFail("A target excluded after preview must not dispatch")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .targetExcluded(target.stableID))
        }
        XCTAssertTrue(excludedFixture.codex.submissions.isEmpty)

        let disappearedFixture = makeFixture()
        await disappearedFixture.coordinator.activate()
        await disappearedFixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await disappearedFixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-disappeared"
        )
        var disappeared = makeSnapshot()
        disappeared.conversations = []
        try await disappearedFixture.store.upsert(
            snapshot: disappeared,
            expectedRevision: 0
        )
        do {
            _ = try await disappearedFixture.coordinator.approveProposal(
                runID: runID,
                decisionID: decisionID,
                destination: destination,
                policy: policy,
                projectManagementEnabled: true,
                expectedRevision: 2
            )
            XCTFail("A target that disappeared after preview must not dispatch")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .unknownTarget(target.stableID))
        }
        XCTAssertTrue(disappearedFixture.codex.submissions.isEmpty)

        let movedFixture = makeFixture()
        await movedFixture.coordinator.activate()
        await movedFixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await movedFixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-moved"
        )
        var originalProject = makeSnapshot()
        originalProject.conversations = []
        try await movedFixture.store.upsert(
            snapshot: originalProject,
            expectedRevision: 0
        )
        try await movedFixture.store.upsert(
            snapshot: makeSnapshot(projectID: "project-2"),
            expectedRevision: nil
        )
        do {
            _ = try await movedFixture.coordinator.approveProposal(
                runID: runID,
                decisionID: decisionID,
                destination: destination,
                policy: policy,
                projectManagementEnabled: true,
                expectedRevision: 2
            )
            XCTFail("A target moved to another project must not dispatch")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .unknownTarget(target.stableID))
        }
        XCTAssertTrue(movedFixture.codex.submissions.isEmpty)
    }

    func testSecondCycleRejectsDuplicateInstructionWithoutNewEvidence() async throws {
        let fixture = makeFixture()
        fixture.codex.nextState = .completed
        await fixture.coordinator.activate()
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-first-cycle"
        )
        _ = try await fixture.coordinator.approveProposal(
            runID: runID,
            decisionID: decisionID,
            destination: destination,
            policy: policy,
            projectManagementEnabled: true,
            expectedRevision: 2
        )
        let completed = try XCTUnwrap(
            fixture.coordinator.ledger(runID: runID)
        )
        XCTAssertEqual(completed.currentState.delivery, .completed)
        XCTAssertEqual(completed.dispatchMemory[0].evidenceRevision, 1)

        let duplicateDecisionID = UUID(
            uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        )!
        let duplicate = ConversationManagementProposalV1(
            runID: runID,
            projectID: projectID,
            expectedRevision: completed.revision + 1,
            projectionRevision: 0,
            cycle: 2,
            summary: "Repeat the same instruction without new evidence",
            decisions: [
                ConversationManagementDecisionV1(
                    id: duplicateDecisionID,
                    kind: .dispatch,
                    target: target,
                    taskID: "task-1",
                    prompt: "Run the focused test and report exact evidence",
                    reason: "This duplicate must be rejected",
                    expectedEvidence: "Test command and terminal result"
                ),
            ]
        )
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(duplicate))
        )
        do {
            _ = try await fixture.coordinator.requestDecision(
                runID: runID,
                metaSessionID: "meta-session",
                projectPath: "/tmp/project-1",
                endpoint: endpoint,
                preset: DshMetaAgentPolicy.requiredPresetID,
                policy: policy,
                expectedRevision: completed.revision,
                planningRPCID: "rpc-duplicate-cycle"
            )
            XCTFail("The same instruction requires newer target evidence")
        } catch let error as DshMetaAgentCoordinatorError {
            guard case let .invalidProposal(reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("without new evidence"))
        }
        XCTAssertEqual(fixture.codex.submissions.count, 1)
        XCTAssertEqual(
            fixture.coordinator.ledger(runID: runID)?
                .currentState.management,
            .failed
        )
    }

    func testMissingExactQueueItemBecomesUnknownWithoutRecreation() async throws {
        let commandID = UUID(
            uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
        )!
        let fixture = makeFixture(makeUUID: { commandID })
        fixture.codex.removeItemAfterEnqueue = true
        await fixture.coordinator.activate()
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-plan"
        )

        do {
            _ = try await fixture.coordinator.approveProposal(
                runID: runID,
                decisionID: decisionID,
                destination: destination,
                policy: policy,
                projectManagementEnabled: true,
                expectedRevision: 2
            )
            XCTFail("Missing exact command evidence must fail closed")
        } catch let error as DshMetaAgentCoordinatorError {
            XCTAssertEqual(error, .exactQueueItemMissing(commandID))
        }
        let ledger = try XCTUnwrap(fixture.coordinator.ledger(runID: runID))
        XCTAssertEqual(ledger.currentState.delivery, .deliveryUnknown)
        XCTAssertEqual(fixture.codex.submissions.count, 1)

        let paused = try await fixture.coordinator.approveProposal(
            runID: runID,
            decisionID: decisionID,
            destination: destination,
            policy: policy,
            projectManagementEnabled: true,
            expectedRevision: ledger.revision
        )
        XCTAssertEqual(paused.delivery, .deliveryUnknown)
        XCTAssertEqual(fixture.codex.submissions.count, 1)
    }

    func testPauseResumeCancelPublishesProjectStatus() async throws {
        let fixture = makeFixture()
        await fixture.coordinator.activate()
        await fixture.dsh.setResult(
            .proposalJSON(try JSONEncoder().encode(
                makeProposal(runID: runID, expectedRevision: 1)
            ))
        )
        _ = try await fixture.coordinator.requestDecision(
            runID: runID,
            metaSessionID: "meta-session",
            projectPath: "/tmp/project-1",
            endpoint: endpoint,
            preset: DshMetaAgentPolicy.requiredPresetID,
            policy: policy,
            expectedRevision: 0,
            planningRPCID: "rpc-plan"
        )

        try await fixture.coordinator.pause(
            runID: runID,
            expectedRevision: 2
        )
        XCTAssertEqual(
            fixture.coordinator.status(projectID: projectID)?
                .state?.management,
            .paused
        )
        try await fixture.coordinator.resume(
            runID: runID,
            expectedRevision: 3
        )
        XCTAssertEqual(
            fixture.coordinator.status(projectID: projectID)?
                .state?.management,
            .awaitingPreview
        )
        try await fixture.coordinator.cancel(
            runID: runID,
            expectedRevision: 4
        )
        XCTAssertEqual(
            fixture.coordinator.status(projectID: projectID)?
                .state?.management,
            .cancelled
        )
    }

    func testHistoryScannerUsesExactRPCIDAndFailsClosedOnInterleaving() throws {
        let start = historyEntry(
            type: "turn/start",
            seq: 9,
            data: .object(["turn": .number(1)])
        )
        let exact = historyEntry(
            type: "user/message",
            seq: 10,
            data: .object([
                "source": .object(["rpcId": .string("rpc-exact")]),
            ])
        )
        let assistant = historyEntry(
            type: "assistant/message",
            seq: 12,
            data: .object([
                "turn": .number(1),
                "step": .number(1),
                "message": .object([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("{\"schemaVersion\":1}"),
                        ]),
                    ]),
                ]),
            ])
        )
        let earlierAssistant = historyEntry(
            type: "assistant/message",
            seq: 11,
            data: .object([
                "turn": .number(1),
                "step": .number(1),
                "message": .object([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("{\"stale\":true}"),
                        ]),
                    ]),
                ]),
            ])
        )
        let end = historyEntry(
            type: "turn/end",
            seq: 13,
            data: .object([
                "turn": .number(1),
                "reason": .object(["kind": .string("completed")]),
            ])
        )
        XCTAssertEqual(
            DshMetaAgentHistoryScanner.scan(
                [start, assistant, exact, earlierAssistant],
                promptRPCID: "rpc-exact"
            ),
            .pending,
            "An assistant message is not final before exact turn/end"
        )
        XCTAssertEqual(
            DshMetaAgentHistoryScanner.scan(
                [end, start, assistant, exact, earlierAssistant],
                promptRPCID: "rpc-exact"
            ),
            .proposalJSON(Data("{\"schemaVersion\":1}".utf8))
        )

        let interleaved = historyEntry(
            type: "user/message",
            seq: 11,
            data: .object([
                "source": .object(["rpcId": .string("rpc-other")]),
            ])
        )
        guard case .deliveryUnknown = DshMetaAgentHistoryScanner.scan(
            [start, exact, interleaved, historyEntry(
                type: "assistant/message",
                seq: 12,
                data: assistant.event.data
            ), historyEntry(
                type: "turn/end",
                seq: 13,
                data: end.event.data
            )],
            promptRPCID: "rpc-exact"
        ) else {
            return XCTFail("Interleaved messages must not be misattributed")
        }
    }

    func testHistoryScannerMapsMissingCredentialWithoutExposingBackendMessage() {
        let entries = terminalErrorHistory(code: "MISSING_CREDENTIAL")
        XCTAssertEqual(
            DshMetaAgentHistoryScanner.scan(entries, promptRPCID: "rpc-error-fixture"),
            .failed("分析服务缺少模型凭据，请配置专用分析服务的模型凭据后重试。")
        )
    }

    func testHistoryScannerUnknownOrMissingErrorCodeUsesFixedSafeMessage() {
        for code in ["UNKNOWN_fixture-secret", "AUTH_UNVERIFIED_CODE", nil] {
            XCTAssertEqual(
                DshMetaAgentHistoryScanner.scan(terminalErrorHistory(code: code), promptRPCID: "rpc-error-fixture"),
                .failed("分析服务执行失败，请检查专用分析服务的配置后重试。")
            )
        }
    }

    func testHistoryScannerErrorNeverAcceptsEarlierAssistantJSON() {
        var entries = terminalErrorHistory(code: "MISSING_CREDENTIAL")
        entries.append(historyEntry(type: "assistant/message", seq: 3, data: .object([
            "turn": .number(1), "text": .string("{\"completed\":true}"),
        ])))
        XCTAssertEqual(
            DshMetaAgentHistoryScanner.scan(entries, promptRPCID: "rpc-error-fixture"),
            .failed("分析服务缺少模型凭据，请配置专用分析服务的模型凭据后重试。")
        )
    }

    func testHistoryScannerErrorMappingDoesNotBypassExactTurnOrRPCBoundaries() {
        guard case .deliveryUnknown = DshMetaAgentHistoryScanner.scan(
            terminalErrorHistory(code: "MISSING_CREDENTIAL", turn: 2), promptRPCID: "rpc-error-fixture"
        ) else {
            return XCTFail("A known error code must not bypass the exact-turn boundary")
        }
        XCTAssertEqual(
            DshMetaAgentHistoryScanner.scan(terminalErrorHistory(code: "MISSING_CREDENTIAL"), promptRPCID: "different-rpc"),
            .pending
        )
    }

    private func terminalErrorHistory(code: String?, turn: Int = 1) -> [DshSessionHistoryEntry] {
        var error: [String: DshJSONValue] = [
            "message": .string("fixture-secret-not-for-display /synthetic/private/provider-detail"),
        ]
        if let code { error["code"] = .string(code) }
        return [
            historyEntry(type: "turn/start", seq: 1, data: .object(["turn": .number(1)])),
            historyEntry(type: "user/message", seq: 2, data: .object([
                "source": .object(["rpcId": .string("rpc-error-fixture")]),
            ])),
            historyEntry(type: "turn/end", seq: 4, data: .object([
                "turn": .number(Double(turn)),
                "reason": .object(["kind": .string("error"), "error": .object(error)]),
            ])),
        ]
    }

    private let projectID = "project-1"
    private let runID = UUID(
        uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    )!
    private let decisionID = UUID(
        uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    )!
    private let endpoint = DshRuntimeEndpoint(
        homeID: DshMetaAgentPolicy.dedicatedHomeID,
        profile: DshMetaAgentPolicy.dedicatedProfile,
        port: 54_719
    )

    private var target: ConversationManagementTargetV1 {
        ConversationManagementTargetV1(
            provider: "codex",
            sourceScope: "home-a",
            sourceID: "thread-1"
        )
    }

    private var policy: ConversationManagementValidationPolicyV1 {
        ConversationManagementValidationPolicyV1(
            allowedTargets: [target],
            maxDecisions: 1
        )
    }

    private var destination: DshMetaCodexDestination {
        DshMetaCodexDestination(
            target: target,
            homeID: "home-a",
            homePath: "/tmp/codex-home-a",
            sourceThreadID: "thread-1",
            targetThreadID: "thread-1",
            cardType: .main
        )
    }

    private func makeFixture(
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) -> (
        store: InMemoryConversationManagementStore,
        dsh: FakeDshMetaAgentClient,
        codex: FakeDshMetaCodexDispatcher,
        coordinator: DshMetaAgentCoordinator
    ) {
        let envelope = ConversationManagementStoreEnvelopeV1(
            snapshots: [makeSnapshot()],
            ledgers: [ConversationManagementProgressLedgerV1(
                runID: runID,
                projectID: projectID,
                objective: "Finish the bounded project task"
            )]
        )
        let store = InMemoryConversationManagementStore(envelope)
        let dsh = FakeDshMetaAgentClient()
        let codex = FakeDshMetaCodexDispatcher()
        let coordinator = DshMetaAgentCoordinator(
            store: store,
            dshClient: dsh,
            codexDispatcher: codex,
            makeUUID: makeUUID
        )
        return (store, dsh, codex, coordinator)
    }

    private func makeSnapshot(
        projectID: String? = nil
    ) -> ConversationManagementSnapshotV1 {
        let resolvedProjectID = projectID ?? self.projectID
        return ConversationManagementSnapshotV1(
            projectID: resolvedProjectID,
            brainEnabled: true,
            projectDefaultEnrollmentEnabled: true,
            taskPlan: ConversationProjectTaskPlanProjectionV1(
                sourceRevision: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                freshness: .fresh,
                isValid: true,
                observedAt: Date(timeIntervalSince1970: 1),
                tasks: [
                    ConversationProjectTaskV1(
                        taskID: "task-1",
                        title: "Run focused verification",
                        owner: "test-owner",
                        status: .inProgress,
                        updatedAt: Date(timeIntervalSince1970: 1)
                    ),
                ]
            ),
            conversations: [
                ConversationManagementRecordV1(
                    base: ConversationManagementBaseProjectionV1(
                        target: target,
                        projectID: resolvedProjectID,
                        title: "Primary task",
                        role: "main",
                        observedAt: Date(timeIntervalSince1970: 1),
                        runtime: .idle,
                        progress: .unknown,
                        evidence: ConversationEvidenceProjectionV1(
                            revision: 1,
                            status: .fresh,
                            fingerprint: "evidence-1",
                            summary: "Tests have not run yet",
                            observedAt: Date(timeIntervalSince1970: 1)
                        )
                    ),
                    managementExtension: ConversationManagementExtensionV1(
                        target: target,
                        enrollment: .inherit,
                        workKind: .task,
                        taskBindings: [
                            ConversationTaskBindingV1(
                                taskID: "task-1",
                                projectID: resolvedProjectID,
                                target: target,
                                boundAt: Date(timeIntervalSince1970: 1)
                            ),
                        ],
                        management: .observing
                    )
                ),
            ]
        )
    }

    private func makeProposal(
        runID: UUID,
        expectedRevision: Int
    ) -> ConversationManagementProposalV1 {
        ConversationManagementProposalV1(
            runID: runID,
            projectID: projectID,
            expectedRevision: expectedRevision,
            projectionRevision: 0,
            cycle: 1,
            summary: "Run one focused verification",
            decisions: [
                ConversationManagementDecisionV1(
                    id: decisionID,
                    kind: .dispatch,
                    target: target,
                    taskID: "task-1",
                    prompt: "Run the focused test and report exact evidence",
                    reason: "The test result determines the next action",
                    expectedEvidence: "Test command and terminal result"
                ),
            ]
        )
    }

    private func historyEntry(
        type: String,
        seq: Int,
        data: DshJSONValue
    ) -> DshSessionHistoryEntry {
        DshSessionHistoryEntry(
            event: DshSessionEvent(
                type: type,
                seq: seq,
                time: Int64(seq),
                data: data,
                ignorable: nil
            ),
            view: nil
        )
    }
}

private actor InMemoryConversationManagementStore: ConversationManagementStoringV1 {
    private var envelope: ConversationManagementStoreEnvelopeV1
    private var saves: [ConversationManagementStoreEnvelopeV1] = []

    init(_ envelope: ConversationManagementStoreEnvelopeV1) {
        self.envelope = envelope
    }

    func load() throws -> ConversationManagementStoreEnvelopeV1 {
        envelope
    }

    func save(_ envelope: ConversationManagementStoreEnvelopeV1) throws {
        self.envelope = envelope
        saves.append(envelope)
    }

    func snapshot(
        projectID: String
    ) throws -> ConversationManagementSnapshotV1? {
        envelope.snapshot(projectID: projectID)
    }

    func ledger(
        runID: UUID
    ) throws -> ConversationManagementProgressLedgerV1? {
        envelope.ledger(runID: runID)
    }

    func upsert(
        snapshot: ConversationManagementSnapshotV1,
        expectedRevision: Int?
    ) throws {
        try envelope.upsert(
            snapshot: snapshot,
            expectedRevision: expectedRevision
        )
        envelope.savedAt = Date()
        saves.append(envelope)
    }

    func upsert(
        ledger: ConversationManagementProgressLedgerV1,
        expectedRevision: Int?
    ) throws {
        try envelope.upsert(
            ledger: ledger,
            expectedRevision: expectedRevision
        )
        envelope.savedAt = Date()
        saves.append(envelope)
    }

    func saveHistory() -> [ConversationManagementStoreEnvelopeV1] {
        saves
    }
}

private actor FakeDshMetaAgentClient: DshMetaAgentDecisionClient {
    enum PrepareFailure {
        case none
        case presetMissing
    }

    enum QueueFailure {
        case none
        case timeout
    }

    private var result: DshMetaAgentDecisionResult = .failed(
        "No fake decision was configured"
    )
    private var prepareFailure: PrepareFailure = .none
    private var queueFailure: QueueFailure = .none
    private var prompts: [DshMetaAgentPromptRequest] = []
    private var sessions: [DshMetaAgentSessionRequest] = []
    private var cancellations: [(DshRuntimeEndpoint, String, String)] = []
    private var suspendDecision = false
    private var decisionWaitStarted = false
    private var decisionWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedDecisionContinuations: [
        CheckedContinuation<DshMetaAgentDecisionResult, Never>
    ] = []

    func setResult(_ result: DshMetaAgentDecisionResult) {
        self.result = result
    }

    func setQueueFailure(_ failure: QueueFailure) {
        queueFailure = failure
    }

    func setPrepareFailure(_ failure: PrepareFailure) {
        prepareFailure = failure
    }

    func setSuspendDecision(_ suspend: Bool) {
        suspendDecision = suspend
    }

    func prepareSession(_ request: DshMetaAgentSessionRequest) async throws {
        sessions.append(request)
        if prepareFailure == .presetMissing {
            throw DshMetaAgentClientError.unavailablePreset(
                DshMetaAgentPolicy.requiredPresetID
            )
        }
    }

    func queuePrompt(
        _ request: DshMetaAgentPromptRequest
    ) async throws -> Bool {
        prompts.append(request)
        if queueFailure == .timeout {
            throw URLError(.timedOut)
        }
        return true
    }

    func waitForDecision(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        promptRPCID: String
    ) async throws -> DshMetaAgentDecisionResult {
        if suspendDecision {
            decisionWaitStarted = true
            let waiters = decisionWaiters
            decisionWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return await withCheckedContinuation { continuation in
                suspendedDecisionContinuations.append(continuation)
            }
        }
        return result
    }

    func cancelSession(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        rpcID: String
    ) async throws -> Bool {
        cancellations.append((endpoint, sessionID, rpcID))
        return true
    }

    func promptRequests() -> [DshMetaAgentPromptRequest] {
        prompts
    }

    func sessionRequests() -> [DshMetaAgentSessionRequest] {
        sessions
    }

    func queueCount() -> Int {
        prompts.count
    }

    func cancellationCount() -> Int {
        cancellations.count
    }

    func waitUntilDecisionWaitStarted() async {
        if decisionWaitStarted { return }
        await withCheckedContinuation { continuation in
            decisionWaiters.append(continuation)
        }
    }

    func resumeDecisionWait() {
        suspendDecision = false
        let continuations = suspendedDecisionContinuations
        suspendedDecisionContinuations.removeAll()
        continuations.forEach { $0.resume(returning: result) }
    }
}

@MainActor
private final class FakeDshMetaCodexDispatcher: DshMetaCodexCommandDispatching {
    struct Submission: Equatable {
        let commandID: UUID
        let destination: DshMetaCodexDestination
        let text: String
    }

    var nextState: CodexDeliveryState = .waiting
    var removeItemAfterEnqueue = false
    var shouldSuspendEnqueue = false
    private(set) var submissions: [Submission] = []
    private(set) var itemRequests: [UUID] = []
    private var items: [UUID: CodexTaskQueueItem] = [:]
    private var enqueueStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var enqueueRelease: CheckedContinuation<Void, Never>?
    private var enqueueStarted = false

    func enqueueMetaCommand(
        commandID: UUID,
        destination: DshMetaCodexDestination,
        text: String
    ) async -> UUID? {
        if shouldSuspendEnqueue {
            enqueueStarted = true
            let waiters = enqueueStartedWaiters
            enqueueStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                enqueueRelease = continuation
            }
        }
        submissions.append(Submission(
            commandID: commandID,
            destination: destination,
            text: text
        ))
        let command = CodexTaskCommand(
            id: commandID,
            homeID: destination.homeID,
            homePath: destination.homePath,
            threadID: destination.targetThreadID,
            sourceThreadID: destination.sourceThreadID,
            cardType: destination.cardType,
            text: text
        )
        items[commandID] = CodexTaskQueueItem(
            command: command,
            state: nextState
        )
        if removeItemAfterEnqueue {
            items.removeValue(forKey: commandID)
        }
        return commandID
    }

    func metaQueueItem(commandID: UUID) -> CodexTaskQueueItem? {
        itemRequests.append(commandID)
        return items[commandID]
    }

    func setItemState(_ state: CodexDeliveryState, commandID: UUID) {
        guard var item = items[commandID] else { return }
        item.state = state
        items[commandID] = item
    }

    func waitUntilEnqueueStarted() async {
        if enqueueStarted { return }
        await withCheckedContinuation { continuation in
            enqueueStartedWaiters.append(continuation)
        }
    }

    func releaseEnqueue() {
        shouldSuspendEnqueue = false
        enqueueRelease?.resume()
        enqueueRelease = nil
    }
}
