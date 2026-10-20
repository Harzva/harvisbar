import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisRuntimeConversationManagementTests: XCTestCase {
    func testCompleteProviderInventoryBuildsDisabledSnapshotAndPersistsOptIn() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.model.dshThreads = [
            makeDshThread(
                sourceID: "dsh-visible",
                cwd: fixture.projectPath
            ),
        ]
        fixture.model.workBuddyThreads = [
            WorkBuddyThreadSummary(
                id: "workbuddy-hidden-by-view-filter",
                title: "Background review",
                createdAt: 10,
                updatedAt: 20,
                tokensUsed: 0,
                model: "hy3",
                cwd: fixture.projectPath,
                archived: false,
                running: false,
                sourceStatus: "idle"
            ),
        ]
        XCTAssertTrue(fixture.model.acceptManagedProjectTaskPlan(
            makePlan(revisionCharacter: "a"),
            for: fixture.project,
            at: Date(timeIntervalSince1970: 100)
        ))

        await fixture.model.refreshConversationManagementSnapshots(
            additionalProjects: [fixture.project],
            at: Date(timeIntervalSince1970: 110)
        )

        let initial = try XCTUnwrap(
            fixture.model.conversationManagementSnapshot(for: fixture.project)
        )
        XCTAssertFalse(initial.brainEnabled)
        XCTAssertFalse(initial.projectDefaultEnrollmentEnabled)
        XCTAssertEqual(initial.conversations.count, 2)
        XCTAssertEqual(
            Set(initial.conversations.map(\.base.target.provider)),
            ["dsh", "workbuddy"]
        )
        XCTAssertEqual(
            initial.taskPlan.sourceRevision,
            "sha256:" + String(repeating: "a", count: 64)
        )
        XCTAssertTrue(initial.taskPlan.isAuthoritative)
        XCTAssertEqual(
            fixture.model.conversationManagementSnapshots[fixture.project.id],
            initial
        )

        try await fixture.model.setConversationManagementBrainEnabled(
            true,
            for: fixture.project,
            at: Date(timeIntervalSince1970: 120)
        )
        XCTAssertTrue(
            fixture.model.isConversationManagementBrainEnabled(
                for: fixture.project
            )
        )
        XCTAssertEqual(
            fixture.model.conversationManagementSnapshot(for: fixture.project)?
                .revision,
            initial.revision + 1
        )
        XCTAssertTrue(
            fixture.model.conversationManagementSnapshots[fixture.project.id]?
                .brainEnabled == true
        )

        let reloaded = DshMetaAgentCoordinator(store: fixture.store)
        await reloaded.activate()
        XCTAssertTrue(
            try XCTUnwrap(reloaded.snapshot(projectID: fixture.project.id))
                .brainEnabled
        )
        XCTAssertEqual(
            reloaded.status(projectID: fixture.project.id)?.executionMode,
            .previewOnly
        )
    }

    func testTaskPlanSourceRevisionAdvancesProjectionRevision() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.model.dshThreads = [
            makeDshThread(sourceID: "dsh-1", cwd: fixture.projectPath),
        ]
        XCTAssertTrue(fixture.model.acceptManagedProjectTaskPlan(
            makePlan(revisionCharacter: "b"),
            for: fixture.project,
            at: Date(timeIntervalSince1970: 200)
        ))
        await fixture.model.refreshConversationManagementSnapshots(
            additionalProjects: [fixture.project],
            at: Date(timeIntervalSince1970: 210)
        )
        let first = try XCTUnwrap(
            fixture.model.conversationManagementSnapshot(for: fixture.project)
        )

        XCTAssertTrue(fixture.model.acceptManagedProjectTaskPlan(
            makePlan(revisionCharacter: "c"),
            for: fixture.project,
            at: Date(timeIntervalSince1970: 300)
        ))
        await fixture.model.refreshConversationManagementSnapshots(
            additionalProjects: [fixture.project],
            at: Date(timeIntervalSince1970: 310)
        )
        let second = try XCTUnwrap(
            fixture.model.conversationManagementSnapshot(for: fixture.project)
        )

        XCTAssertEqual(second.revision, first.revision + 1)
        XCTAssertEqual(
            second.taskPlan.sourceRevision,
            "sha256:" + String(repeating: "c", count: 64)
        )
        XCTAssertEqual(
            second.taskPlan.observedAt,
            Date(timeIntervalSince1970: 300)
        )
    }

    func testDedicatedBrainEndpointNeverFallsBackOrChoosesAmbiguously() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.model.dshRunningEndpoints = [
            DshRuntimeEndpoint(
                homeID: "dsh-general",
                profile: "web",
                port: 40_001
            ),
        ]
        XCTAssertNil(fixture.model.conversationManagementBrainEndpoint)
        XCTAssertNotNil(fixture.model.conversationManagementBrainEndpointError)

        let dedicated = DshRuntimeEndpoint(
            homeID: DshMetaAgentPolicy.dedicatedHomeID,
            profile: DshMetaAgentPolicy.dedicatedProfile,
            port: 40_002
        )
        fixture.model.dshRunningEndpoints.append(dedicated)
        XCTAssertEqual(
            fixture.model.conversationManagementBrainEndpoint,
            dedicated
        )
        XCTAssertNil(fixture.model.conversationManagementBrainEndpointError)

        fixture.model.dshRunningEndpoints.append(
            DshRuntimeEndpoint(
                homeID: DshMetaAgentPolicy.dedicatedHomeID,
                profile: DshMetaAgentPolicy.dedicatedProfile,
                port: 40_003
            )
        )
        XCTAssertNil(fixture.model.conversationManagementBrainEndpoint)
    }

    func testApprovalWrapperResolvesExactCurrentCodexHomeAndTarget() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "harvis-runtime-approval-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let project = ManagedChatProjectResolver.resolve(
            cwd: projectURL.path,
            fallbackID: "approval"
        )
        let source = fixtureThread(
            id: "thread-approval",
            cwd: projectURL.path,
            threadSource: "main"
        )
        let thread = ManagedChatThread(codex: source, sourceScope: "home-a")
        let target = ConversationManagementProjectorV1.target(for: thread)
        let observedAt = Date(timeIntervalSince1970: 600)
        let wirePlan = makePlan(revisionCharacter: "a")
        let taskPlan = try ConversationManagementTaskPlanAdapterV1.projection(
            plan: wirePlan,
            freshness: .fresh(lastSuccessfulAt: observedAt),
            previous: nil,
            observedAt: observedAt
        )
        var snapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: project,
            threads: [thread],
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: ConversationProjectCompletionEvidenceV1(
                taskFreshness: .fresh,
                openTaskCount: 1,
                observedAt: observedAt,
                userConfirmedAt: nil
            ),
            brainEnabled: true,
            taskPlan: taskPlan,
            now: Date(timeIntervalSince1970: 610)
        )
        var managementExtension = try XCTUnwrap(
            snapshot.conversations[0].managementExtension
        )
        managementExtension.workKind = .task
        managementExtension.taskBindings = [
            ConversationTaskBindingV1(
                taskID: "task-1",
                projectID: project.id,
                target: target,
                boundAt: Date(timeIntervalSince1970: 611)
            ),
        ]
        snapshot.conversations[0].managementExtension = managementExtension

        let runID = UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!
        let decisionID = UUID(
            uuidString: "22222222-2222-2222-2222-222222222222"
        )!
        var ledger = ConversationManagementProgressLedgerV1(
            runID: runID,
            projectID: project.id,
            objective: "Run exact approved task"
        )
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-approval",
            expectedRevision: 0
        )
        try ledger.accept(
            proposal: ConversationManagementProposalV1(
                runID: runID,
                projectID: project.id,
                expectedRevision: 1,
                projectionRevision: snapshot.revision,
                cycle: 1,
                summary: "Dispatch one exact task",
                decisions: [
                    ConversationManagementDecisionV1(
                        id: decisionID,
                        kind: .dispatch,
                        target: target,
                        taskID: "task-1",
                        prompt: "Run the exact focused test and report evidence",
                        reason: "The approved task requires current evidence",
                        expectedEvidence: "Focused test command and result"
                    ),
                ]
            ),
            snapshot: snapshot,
            policy: ConversationManagementValidationPolicyV1(
                allowedTargets: [target],
                maxDecisions: 1
            ),
            expectedRevision: 1
        )

        let store = RuntimeConversationManagementStore(
            envelope: ConversationManagementStoreEnvelopeV1(
                snapshots: [snapshot],
                ledgers: [ledger]
            )
        )
        let dispatcher = RuntimeConversationManagementCodexDispatcher()
        let coordinator = DshMetaAgentCoordinator(
            store: store,
            codexDispatcher: dispatcher
        )
        let suite = "HarvisRuntimeConversationApproval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(
            defaults: defaults,
            dshMetaAgentCoordinator: coordinator
        )
        model.projectTaskPlanAuthorityLoader = { _ in wirePlan }
        let home = makeCodexHome(id: "home-a")
        model.codexHomes = [home]
        model.selectedCodexHomeID = home.id
        model.acceptCodexThreads([source], sourceHomeID: home.id)
        XCTAssertTrue(model.acceptManagedProjectTaskPlan(
            wirePlan,
            for: project,
            at: observedAt
        ))
        await model.activateConversationManagement()

        let outcome = try await model.approveConversationManagementProposal(
            project: project,
            runID: runID,
            decisionID: decisionID,
            expectedLedgerRevision: ledger.revision
        )

        XCTAssertEqual(outcome.delivery, .completed)
        XCTAssertEqual(dispatcher.submissions.count, 1)
        XCTAssertEqual(dispatcher.submissions[0].destination.target, target)
        XCTAssertEqual(dispatcher.submissions[0].destination.homeID, "home-a")
        XCTAssertEqual(
            dispatcher.submissions[0].destination.homePath,
            "/tmp/codex-home-a"
        )
        XCTAssertEqual(
            dispatcher.submissions[0].destination.targetThreadID,
            "thread-approval"
        )
        XCTAssertEqual(
            model.conversationManagementLatestLedgers[project.id]?
                .currentState.delivery,
            .completed
        )
        XCTAssertEqual(
            model.conversationManagementProjectStatuses[project.id]?
                .state?.delivery,
            .completed
        )
    }

    func testExplicitTaskBindingEnablesPreviewApprovalAndClearExcludes() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "harvis-runtime-full-preview-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let project = ManagedChatProjectResolver.resolve(
            cwd: projectURL.path,
            fallbackID: "full-preview"
        )
        let source = fixtureThread(
            id: "thread-full-preview",
            cwd: projectURL.path,
            threadSource: "main"
        )
        let thread = ManagedChatThread(codex: source, sourceScope: "home-a")
        let target = ConversationManagementProjectorV1.target(for: thread)
        let runID = UUID(
            uuidString: "33333333-3333-3333-3333-333333333333"
        )!
        let decisionID = UUID(
            uuidString: "44444444-4444-4444-4444-444444444444"
        )!
        let store = RuntimeConversationManagementStore()
        let dsh = RuntimeConversationManagementDshClient()
        let dispatcher = RuntimeConversationManagementCodexDispatcher()
        let coordinator = DshMetaAgentCoordinator(
            store: store,
            dshClient: dsh,
            codexDispatcher: dispatcher,
            makeUUID: { runID }
        )
        let suite = "HarvisRuntimeConversationFullPreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarvisRuntimeModel(
            defaults: defaults,
            dshMetaAgentCoordinator: coordinator
        )
        let home = makeCodexHome(id: "home-a")
        model.codexHomes = [home]
        model.selectedCodexHomeID = home.id
        model.acceptCodexThreads([source], sourceHomeID: home.id)
        let observedAt = Date(timeIntervalSince1970: 700)
        let authoritativePlan = makePlan(revisionCharacter: "9")
        model.projectTaskPlanAuthorityLoader = { _ in authoritativePlan }
        XCTAssertTrue(model.acceptManagedProjectTaskPlan(
            authoritativePlan,
            for: project,
            at: observedAt
        ))
        await model.refreshConversationManagementSnapshots(
            additionalProjects: [project],
            at: Date(timeIntervalSince1970: 710)
        )
        try await model.setConversationManagementBrainEnabled(
            true,
            for: project,
            at: Date(timeIntervalSince1970: 720)
        )
        try await model.setConversationManagementPlanBinding(
            for: thread,
            project: project,
            workKind: .task,
            taskID: "task-1",
            includeForDispatch: true,
            at: Date(timeIntervalSince1970: 730)
        )
        let bound = try XCTUnwrap(
            model.conversationManagementSnapshot(for: project)
        )
        XCTAssertFalse(bound.projectDefaultEnrollmentEnabled)
        XCTAssertEqual(
            bound.record(for: target)?.managementExtension?.enrollment,
            .enabled
        )
        XCTAssertTrue(try XCTUnwrap(bound.record(for: target)).isEnrolled(
            projectDefaultEnabled: false
        ))

        await dsh.setResult(.proposalJSON(try JSONEncoder().encode(
            ConversationManagementProposalV1(
                runID: runID,
                projectID: project.id,
                expectedRevision: 1,
                projectionRevision: bound.revision,
                cycle: 1,
                summary: "Dispatch the explicitly bound task",
                decisions: [
                    ConversationManagementDecisionV1(
                        id: decisionID,
                        kind: .dispatch,
                        target: target,
                        taskID: "task-1",
                        prompt: "Run the exact bound task and report evidence",
                        reason: "The user explicitly enrolled this task binding",
                        expectedEvidence: "Focused verification result"
                    ),
                ]
            )
        )))
        let endpoint = DshRuntimeEndpoint(
            homeID: DshMetaAgentPolicy.dedicatedHomeID,
            profile: DshMetaAgentPolicy.dedicatedProfile,
            port: 40_010
        )
        model.dshRunningEndpoints = [endpoint]
        let preview = try await model.startConversationManagementPreview(
            project: project,
            objective: "Finish one exact project task"
        )
        XCTAssertEqual(preview.runID, runID)
        XCTAssertEqual(
            model.conversationManagementLatestLedgers[project.id]?
                .currentState.management,
            .awaitingPreview
        )

        let outcome = try await model.approveConversationManagementProposal(
            project: project,
            runID: runID,
            decisionID: decisionID,
            expectedLedgerRevision: preview.ledgerRevision
        )
        XCTAssertEqual(outcome.delivery, .completed)
        XCTAssertEqual(dispatcher.submissions.count, 1)

        try await model.clearConversationManagementPlanBinding(
            for: thread,
            project: project,
            at: Date(timeIntervalSince1970: 740)
        )
        let cleared = try XCTUnwrap(
            model.conversationManagementSnapshot(for: project)?
                .record(for: target)
        )
        XCTAssertEqual(cleared.managementExtension?.enrollment, .inherit)
        XCTAssertFalse(cleared.isEnrolled(projectDefaultEnabled: false))
        XCTAssertTrue(cleared.managementExtension?.taskBindings.isEmpty == true)
    }

    func testLifecycleDeactivateLeavesDurableStateAndFailsClosed() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        await fixture.model.activateConversationManagement()
        XCTAssertTrue(fixture.model.dshMetaAgentCoordinator.isReady)

        fixture.model.deactivateConversationManagement()

        XCTAssertFalse(fixture.model.dshMetaAgentCoordinator.isReady)
        XCTAssertFalse(
            fixture.model.isConversationManagementBrainEnabled(
                for: fixture.project
            )
        )
    }

    func testExactPlanBindingIsolatedByHomeAndPreservesProviderFacts() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let homeA = makeCodexProjectionThread(
            sourceScope: "home-a",
            sourceID: "shared-thread",
            cwd: fixture.projectPath
        )
        let homeB = makeCodexProjectionThread(
            sourceScope: "home-b",
            sourceID: "shared-thread",
            cwd: fixture.projectPath
        )
        // Runtime tests inject provider projections directly; production fills
        // this complete inventory through the provider adapters.
        fixture.model.dshThreads = [homeA, homeB]
        XCTAssertTrue(fixture.model.acceptManagedProjectTaskPlan(
            makePlan(revisionCharacter: "e"),
            for: fixture.project,
            at: Date(timeIntervalSince1970: 400)
        ))
        await fixture.model.refreshConversationManagementSnapshots(
            additionalProjects: [fixture.project],
            at: Date(timeIntervalSince1970: 410)
        )
        try await fixture.model.setConversationManagementBrainEnabled(
            true,
            for: fixture.project,
            at: Date(timeIntervalSince1970: 420)
        )
        let targetA = ConversationManagementProjectorV1.target(for: homeA)
        let targetB = ConversationManagementProjectorV1.target(for: homeB)
        let startedAt = try XCTUnwrap(
            fixture.model.conversationManagementSnapshot(for: fixture.project)?
                .record(for: targetA)?.base.startedAt
        )

        try await fixture.model.setConversationManagementPlanBinding(
            for: homeA,
            project: fixture.project,
            workKind: .task,
            taskID: "task-1",
            includeForDispatch: true,
            at: Date(timeIntervalSince1970: 430)
        )

        let bound = try XCTUnwrap(
            fixture.model.conversationManagementSnapshot(for: fixture.project)
        )
        let homeARecord = try XCTUnwrap(bound.record(for: targetA))
        let homeBRecord = try XCTUnwrap(bound.record(for: targetB))
        XCTAssertEqual(homeARecord.base.startedAt, startedAt)
        XCTAssertEqual(homeARecord.managementExtension?.workKind, .task)
        XCTAssertEqual(homeARecord.managementExtension?.enrollment, .enabled)
        XCTAssertEqual(
            homeARecord.managementExtension?.taskBindings,
            [
                ConversationTaskBindingV1(
                    taskID: "task-1",
                    projectID: fixture.project.id,
                    target: targetA,
                    boundAt: Date(timeIntervalSince1970: 430)
                ),
            ]
        )
        XCTAssertEqual(
            homeBRecord.managementExtension?.workKind,
            .unclassified
        )
        XCTAssertTrue(
            homeBRecord.managementExtension?.taskBindings.isEmpty == true
        )
        XCTAssertNotEqual(targetA, targetB)
        XCTAssertEqual(
            fixture.model.conversationManagementSnapshots[fixture.project.id],
            bound
        )

        try await fixture.model.setConversationManagementPlanBinding(
            for: homeA,
            project: fixture.project,
            workKind: .exploration,
            taskID: nil,
            includeForDispatch: true,
            at: Date(timeIntervalSince1970: 440)
        )
        let cleared = try XCTUnwrap(
            fixture.model.conversationManagementSnapshot(for: fixture.project)?
                .record(for: targetA)?.managementExtension
        )
        XCTAssertEqual(cleared.workKind, .exploration)
        XCTAssertEqual(cleared.enrollment, .enabled)
        XCTAssertTrue(cleared.taskBindings.isEmpty)

        try await fixture.model.clearConversationManagementPlanBinding(
            for: homeA,
            project: fixture.project,
            at: Date(timeIntervalSince1970: 450)
        )
        let excluded = try XCTUnwrap(
            fixture.model.conversationManagementSnapshot(for: fixture.project)?
                .record(for: targetA)?.managementExtension
        )
        XCTAssertEqual(excluded.workKind, .unclassified)
        XCTAssertEqual(excluded.enrollment, .inherit)
        XCTAssertFalse(excluded.enrollment.resolves(
            projectDefaultEnabled: false
        ))
        XCTAssertTrue(excluded.taskBindings.isEmpty)
    }

    func testPlanBindingRejectsBrainOffUnknownAndClosedTasks() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let thread = makeCodexProjectionThread(
            sourceScope: "home-a",
            sourceID: "thread-1",
            cwd: fixture.projectPath
        )
        fixture.model.dshThreads = [thread]
        XCTAssertTrue(fixture.model.acceptManagedProjectTaskPlan(
            makePlan(revisionCharacter: "f"),
            for: fixture.project,
            at: Date(timeIntervalSince1970: 500)
        ))
        await fixture.model.refreshConversationManagementSnapshots(
            additionalProjects: [fixture.project],
            at: Date(timeIntervalSince1970: 510)
        )

        do {
            try await fixture.model.setConversationManagementPlanBinding(
                for: thread,
                project: fixture.project,
                workKind: .task,
                taskID: "task-1",
                includeForDispatch: true
            )
            XCTFail("A disabled project brain must reject task binding")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .brainDisabled(fixture.project.id))
        }

        try await fixture.model.setConversationManagementBrainEnabled(
            true,
            for: fixture.project
        )
        do {
            try await fixture.model.setConversationManagementPlanBinding(
                for: thread,
                project: fixture.project,
                workKind: .task,
                taskID: "missing-task",
                includeForDispatch: true
            )
            XCTFail("An unknown task id must fail closed")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .unknownTask("missing-task"))
        }

        XCTAssertTrue(fixture.model.acceptManagedProjectTaskPlan(
            makePlan(revisionCharacter: "1", status: "done"),
            for: fixture.project,
            at: Date(timeIntervalSince1970: 520)
        ))
        await fixture.model.refreshConversationManagementSnapshots(
            additionalProjects: [fixture.project],
            at: Date(timeIntervalSince1970: 530)
        )
        do {
            try await fixture.model.setConversationManagementPlanBinding(
                for: thread,
                project: fixture.project,
                workKind: .task,
                taskID: "task-1",
                includeForDispatch: true
            )
            XCTFail("A closed project task must not authorize a new binding")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .taskNotOpen("task-1"))
        }
    }

    private func makeFixture() throws -> (
        model: HarvisRuntimeModel,
        store: RuntimeConversationManagementStore,
        project: ManagedChatProjectIdentity,
        projectPath: String,
        cleanup: () -> Void
    ) {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "harvis-runtime-management-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        let project = ManagedChatProjectResolver.resolve(
            cwd: projectURL.path,
            fallbackID: "fixture"
        )
        let store = RuntimeConversationManagementStore()
        let coordinator = DshMetaAgentCoordinator(store: store)
        let suite = "HarvisRuntimeConversationManagementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = HarvisRuntimeModel(
            defaults: defaults,
            dshMetaAgentCoordinator: coordinator
        )
        return (
            model,
            store,
            project,
            projectURL.path,
            {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: projectURL)
            }
        )
    }

    private func makeDshThread(
        sourceID: String,
        cwd: String
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: .dsh,
            sourceScope: "dsh-home/web",
            sourceID: sourceID,
            title: "DSH management evidence",
            titleSource: nil,
            hasMeaningfulTitle: true,
            createdAt: 10,
            updatedAt: 20,
            tokensUsed: 0,
            model: "deepseek",
            cwd: cwd,
            archived: false,
            running: false,
            sourceStatus: "idle",
            threadSource: "dsh",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: "dsh::dsh-home/web::\(sourceID)",
            isSubagent: false,
            isSidechat: false,
            activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(
                state: .idle,
                reason: "Fixture"
            )
        )
    }

    private func makeCodexProjectionThread(
        sourceScope: String,
        sourceID: String,
        cwd: String
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: .codex,
            sourceScope: sourceScope,
            sourceID: sourceID,
            title: "Codex task",
            titleSource: "user",
            hasMeaningfulTitle: true,
            createdAt: 10,
            updatedAt: 20,
            tokensUsed: 10,
            model: "gpt-5.6-sol",
            cwd: cwd,
            archived: false,
            running: false,
            sourceStatus: "idle",
            threadSource: "main",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: "codex::\(sourceScope)::\(sourceID)",
            isSubagent: false,
            isSidechat: false,
            activity: ManagedChatActivity(main: 1, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(
                state: .idle,
                reason: "Fixture"
            )
        )
    }

    private func makeCodexHome(id: String) -> CodexHome {
        CodexHome(
            id: id,
            label: "Brain executor",
            accountNote: nil,
            path: "/tmp/codex-home-a",
            source: "default",
            model: "gpt-5.6-sol",
            provider: "openai",
            endpointHost: nil,
            hasAuth: true,
            accountEmail: "runtime@example.test",
            authStatus: "valid",
            authExpiresAt: 1_900_000_000,
            authNote: nil,
            hasConfig: true,
            skillCount: 1,
            quotaMode: "subscription",
            quotaNote: nil
        )
    }

    private func makePlan(
        revisionCharacter: Character,
        status: String = "in_progress"
    ) -> ManagedProjectTaskPlan {
        ManagedProjectTaskPlan(
            schemaVersion: ManagedProjectTaskPlan.supportedSchemaVersion,
            sourceAvailable: true,
            sourceRevision: "sha256:" + String(
                repeating: revisionCharacter,
                count: 64
            ),
            isValid: true,
            invalidRecordCount: 0,
            tasks: [
                ManagedProjectTaskPlanItem(
                    taskId: "task-1",
                    title: "Finish integration",
                    description: nil,
                    owner: "harvis",
                    status: status,
                    updatedAt: "2026-08-24T00:00:00Z",
                    evidence: []
                ),
            ]
        )
    }
}

private actor RuntimeConversationManagementStore:
    ConversationManagementStoringV1 {
    private var envelope: ConversationManagementStoreEnvelopeV1

    init(
        envelope: ConversationManagementStoreEnvelopeV1
            = ConversationManagementStoreEnvelopeV1()
    ) {
        self.envelope = envelope
    }

    func load() throws -> ConversationManagementStoreEnvelopeV1 {
        envelope
    }

    func save(_ envelope: ConversationManagementStoreEnvelopeV1) throws {
        self.envelope = envelope
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
        var next = envelope
        try next.upsert(
            snapshot: snapshot,
            expectedRevision: expectedRevision
        )
        envelope = next
    }

    func upsert(
        ledger: ConversationManagementProgressLedgerV1,
        expectedRevision: Int?
    ) throws {
        var next = envelope
        try next.upsert(
            ledger: ledger,
            expectedRevision: expectedRevision
        )
        envelope = next
    }
}

private actor RuntimeConversationManagementDshClient:
    DshMetaAgentDecisionClient {
    private var result: DshMetaAgentDecisionResult = .failed(
        "No runtime test proposal was configured"
    )

    func setResult(_ result: DshMetaAgentDecisionResult) {
        self.result = result
    }

    func prepareSession(
        _ request: DshMetaAgentSessionRequest
    ) async throws {}

    func queuePrompt(
        _ request: DshMetaAgentPromptRequest
    ) async throws -> Bool {
        true
    }

    func waitForDecision(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        promptRPCID: String
    ) async throws -> DshMetaAgentDecisionResult {
        result
    }

    func cancelSession(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        rpcID: String
    ) async throws -> Bool {
        true
    }
}

@MainActor
private final class RuntimeConversationManagementCodexDispatcher:
    DshMetaCodexCommandDispatching {
    struct Submission {
        let commandID: UUID
        let destination: DshMetaCodexDestination
        let text: String
    }

    private(set) var submissions: [Submission] = []
    private var items: [UUID: CodexTaskQueueItem] = [:]

    func enqueueMetaCommand(
        commandID: UUID,
        destination: DshMetaCodexDestination,
        text: String
    ) async -> UUID? {
        submissions.append(Submission(
            commandID: commandID,
            destination: destination,
            text: text
        ))
        items[commandID] = CodexTaskQueueItem(
            command: CodexTaskCommand(
                id: commandID,
                homeID: destination.homeID,
                homePath: destination.homePath,
                threadID: destination.targetThreadID,
                sourceThreadID: destination.sourceThreadID,
                cardType: destination.cardType,
                text: text
            ),
            state: .completed
        )
        return commandID
    }

    func metaQueueItem(commandID: UUID) -> CodexTaskQueueItem? {
        items[commandID]
    }
}
