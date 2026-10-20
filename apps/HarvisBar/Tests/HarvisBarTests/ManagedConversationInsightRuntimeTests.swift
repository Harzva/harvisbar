import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedConversationInsightRuntimeTests: XCTestCase {
    func testProjectCandidatesAreOpaqueAndUseOnlyFreshOpenTasks() {
        let project = ManagedChatProjectIdentity(
            id: "path::/Users/private/brand-project",
            canonicalPath: "/Users/private/brand-project",
            displayPath: "/Users/private/brand-project",
            label: "Brand Project",
            resolution: .resolved
        )
        let plan = ManagedProjectTaskPlan(
            schemaVersion: ManagedProjectTaskPlan.supportedSchemaVersion,
            sourceAvailable: true,
            sourceRevision: "sha256:" + String(repeating: "a", count: 64),
            isValid: true,
            invalidRecordCount: 0,
            tasks: [
                task(id: "open", title: "Open work", status: "in_progress"),
                task(id: "done", title: "Private finished work", status: "done"),
            ]
        )

        let candidates = ManagedConversationInsightProjectCatalog.candidates(
            projects: [project],
            threads: [],
            taskPlans: [project.id: plan],
            taskFreshness: [
                project.id: .fresh(
                    lastSuccessfulAt: Date(timeIntervalSince1970: 1)
                ),
            ]
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].candidateID.hasPrefix("project-"))
        XCTAssertFalse(candidates[0].candidateID.contains("Users"))
        XCTAssertFalse(candidates[0].candidateID.contains("brand-project"))
        XCTAssertEqual(candidates[0].taskTitles, ["Open work"])
        XCTAssertFalse(candidates[0].taskTitles.contains("Private finished work"))

        let sourceRevision = "sha256:" + String(repeating: "f", count: 64)
        let firstFingerprint = ManagedConversationInsightProjectCatalog
            .analysisFingerprint(
                sourceRevision: sourceRevision,
                candidates: candidates
            )
        let changedCandidates = [
            ManagedConversationProjectCandidate(
                candidateID: candidates[0].candidateID,
                label: candidates[0].label,
                taskTitles: ["Different open work"],
                conversationTitles: candidates[0].conversationTitles
            ),
        ]
        let changedFingerprint = ManagedConversationInsightProjectCatalog
            .analysisFingerprint(
                sourceRevision: sourceRevision,
                candidates: changedCandidates
            )
        XCTAssertNotEqual(firstFingerprint, changedFingerprint)
        XCTAssertTrue(firstFingerprint.hasPrefix("sha256:"))
    }

    func testFreshRecommendationChangesOnlyHarvisGroupingThenBecomesStale() async throws {
        let suite = "ManagedConversationInsightRuntimeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = managedThread(
            scope: "dsh::fixture::web",
            id: "source",
            cwd: "/tmp/source-project"
        )
        let destinationThread = managedThread(
            scope: "dsh::fixture::web",
            id: "destination",
            cwd: "/tmp/destination-project"
        )
        let sourceProject = ManagedChatProjectResolver.resolveSource(thread: source)
        let destination = ManagedChatProjectResolver.resolveSource(
            thread: destinationThread
        )
        let target = ManagedConversationInsightTarget(
            provider: source.provider.rawValue,
            sourceScope: source.sourceScope,
            sourceID: source.sourceID
        )
        let sourceRevision = "sha256:" + String(repeating: "b", count: 64)
        let sourceCandidate = ManagedConversationInsightProjectCatalog
            .candidateID(for: sourceProject)
        let destinationCandidate = ManagedConversationInsightProjectCatalog
            .candidateID(for: destination)
        let candidates = ManagedConversationInsightProjectCatalog.candidates(
            projects: [sourceProject, destination],
            threads: [source, destinationThread],
            taskPlans: [:],
            taskFreshness: [:]
        )
        let fingerprint = ManagedConversationInsightProjectCatalog
            .analysisFingerprint(
                sourceRevision: sourceRevision,
                candidates: candidates
            )
        let insight = ManagedConversationInsightV1(
            schema: ManagedConversationInsightSchemaV1.identifier,
            requestID: UUID().uuidString,
            inputFingerprint: fingerprint,
            currentProjectCandidateID: sourceCandidate,
            summary: ManagedConversationRequirementSummaryV1(
                coreGoal: "Move only the local organization",
                mainTasks: ["Review project relevance"],
                constraints: ["Do not mutate cwd"],
                openQuestions: []
            ),
            relevance: ManagedConversationProjectRelevanceV1(
                currentScore: 20,
                reason: "The destination project is a closer match.",
                recommendedCandidateID: destinationCandidate,
                recommendedScore: 92,
                confidence: 0.9
            ),
            analyzedInputCount: 1,
            totalInputCount: 1,
            omittedInputCount: 0,
            generatedAt: Date(timeIntervalSince1970: 2)
        )
        let record = ManagedConversationInsightStoreRecordV1(
            target: target,
            inputFingerprint: fingerprint,
            totalInputCount: 1,
            analyzedInputCount: 1,
            omittedInputCount: 0,
            state: .completed,
            sessionID: ManagedConversationInsightPolicy.ephemeralSessionID(
                for: target,
                generationID: UUID()
            ),
            rpcID: UUID().uuidString,
            analyzedCurrentProjectCandidateID: sourceCandidate,
            latestInsight: insight,
            updatedAt: Date(timeIntervalSince1970: 2),
            lastError: nil
        )
        let store = SeededManagedConversationInsightStore(record: record)
        let coordinator = ManagedConversationInsightCoordinator(store: store)
        await coordinator.activate()
        let model = HarvisRuntimeModel(
            defaults: defaults,
            managedConversationInsights: coordinator
        )
        model.dshThreads = [source, destinationThread]
        let key = model.managedChatStorageKey(source)
        model.managedConversationInputStates[key] = ManagedConversationUserInputState(
            targetKey: key,
            provider: .dsh,
            sourceAvailable: true,
            sourceRevision: sourceRevision,
            items: [
                ManagedConversationUserInput(
                    id: "input",
                    sequence: 0,
                    turnID: nil,
                    timestamp: nil,
                    text: "organize this conversation",
                    originalCharacterCount: 26,
                    truncated: false,
                    source: .human
                ),
            ],
            totalCount: 1,
            nextCursor: nil,
            isLoading: false,
            isTruncated: false,
            loadedAt: Date(),
            threadUpdatedAtAtLoad: source.updatedAt,
            error: nil
        )

        let before = model.managedConversationInsightContext(for: source)
        XCTAssertEqual(before.recommendedProject?.id, destination.id)
        XCTAssertFalse(try XCTUnwrap(before.status).relevanceIsStale)

        model.clearConversationInputPanel(for: source)
        let scrubbed = model.managedConversationInsightContext(for: source)
        XCTAssertTrue(scrubbed.inputState.items.isEmpty)
        XCTAssertFalse(
            try XCTUnwrap(scrubbed.status).relevanceIsStale,
            "Removing raw panel text must retain the privacy-safe evidence stamp used by card badges"
        )

        var staleInput = try XCTUnwrap(
            model.managedConversationInputStates[key]
        )
        staleInput.threadUpdatedAtAtLoad = source.updatedAt - 1
        model.managedConversationInputStates[key] = staleInput
        XCTAssertThrowsError(
            try model.applyManagedConversationInsightRecommendation(for: source)
        ) { error in
            XCTAssertEqual(
                error as? ManagedConversationInsightRuntimeError,
                .staleInputEvidence
            )
        }
        staleInput.threadUpdatedAtAtLoad = source.updatedAt
        model.managedConversationInputStates[key] = staleInput

        try model.applyManagedConversationInsightRecommendation(for: source)
        let projected = try XCTUnwrap(model.managedChatThreads.first(where: {
            $0.id == source.id
        }))
        XCTAssertEqual(projected.cwd, source.cwd)
        XCTAssertEqual(
            ManagedChatProjectResolver.resolveSource(thread: projected).id,
            sourceProject.id
        )
        XCTAssertEqual(
            ManagedChatProjectResolver.resolve(thread: projected).id,
            destination.id
        )
        XCTAssertTrue(
            try XCTUnwrap(
                model.managedConversationInsightContext(for: projected).status
            ).relevanceIsStale
        )
        XCTAssertThrowsError(
            try model.applyManagedConversationInsightRecommendation(
                for: projected
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedConversationInsightRuntimeError,
                .staleRecommendation
            )
        }
    }

    private func task(
        id: String,
        title: String,
        status: String
    ) -> ManagedProjectTaskPlanItem {
        ManagedProjectTaskPlanItem(
            taskId: id,
            title: title,
            description: nil,
            owner: "owner",
            status: status,
            updatedAt: nil,
            evidence: []
        )
    }

    private func managedThread(
        scope: String,
        id: String,
        cwd: String
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: .dsh,
            sourceScope: scope,
            sourceID: id,
            title: id,
            titleSource: "title",
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: 0,
            model: "fixture",
            cwd: cwd,
            archived: false,
            running: false,
            sourceStatus: "idle",
            threadSource: "dsh",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: "dsh::\(scope)::\(id)",
            isSubagent: false,
            isSidechat: false,
            activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(
                state: .idle,
                reason: "Fixture"
            )
        )
    }
}

private actor SeededManagedConversationInsightStore:
    ManagedConversationInsightStoringV1 {
    private var envelope: ManagedConversationInsightStoreEnvelopeV1

    init(record: ManagedConversationInsightStoreRecordV1) {
        envelope = ManagedConversationInsightStoreEnvelopeV1(records: [record])
    }

    func load() throws -> ManagedConversationInsightStoreEnvelopeV1 {
        envelope
    }

    func save(_ envelope: ManagedConversationInsightStoreEnvelopeV1) throws {
        self.envelope = envelope
    }

    func record(
        for target: ManagedConversationInsightTarget
    ) throws -> ManagedConversationInsightStoreRecordV1? {
        envelope.record(for: target)
    }

    func upsert(_ record: ManagedConversationInsightStoreRecordV1) throws {
        envelope.upsert(record)
    }
}
