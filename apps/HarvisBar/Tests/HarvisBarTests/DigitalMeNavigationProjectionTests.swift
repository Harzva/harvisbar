import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class DigitalMeNavigationProjectionTests: XCTestCase {
    func testNilAndRealZeroRemainDistinct() {
        let unavailable = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: DigitalMeWorkProjectionInput(
                    runtimeWork: nil,
                    durableQueue: nil,
                    runningConversations: nil
                ),
                remote: .notRequested
            )
        )

        XCTAssertEqual(unavailable.work.availability, .notLoaded)
        XCTAssertNil(unavailable.work.activeCount)
        XCTAssertNil(unavailable.work.queuedCount)
        XCTAssertNil(unavailable.review.approvalCount)
        XCTAssertNil(unavailable.review.totalAttentionCount)
        XCTAssertNil(unavailable.memory.vaultCount)
        XCTAssertNil(unavailable.persona.activePersonaCount)

        let empty = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: DigitalMeWorkProjectionInput(
                    runtimeWork: DigitalMeRuntimeWork(
                        packetCount: 0,
                        blockedCount: 0,
                        runCount: 0
                    ),
                    durableQueue: [],
                    runningConversations: []
                ),
                remote: loadedRemoteSources()
            )
        )

        XCTAssertEqual(empty.work.availability, .available)
        XCTAssertEqual(empty.work.activeCount, 0)
        XCTAssertEqual(empty.work.queuedCount, 0)
        XCTAssertEqual(empty.work.blockedCount, 0)
        XCTAssertEqual(empty.work.runCount, 0)
        XCTAssertEqual(empty.review.totalAttentionCount, 0)
        XCTAssertEqual(empty.memory.vaultCount, 0)
        XCTAssertEqual(empty.persona.activePersonaCount, 0)
    }

    func testWorkClassifiesDurableQueueAndDoesNotDoubleCountRunningConversation() {
        let now = Date(timeIntervalSince1970: 100)
        let input = DigitalMeWorkProjectionInput(
            runtimeWork: DigitalMeRuntimeWork(
                packetCount: 7,
                blockedCount: 1,
                runCount: 2
            ),
            durableQueue: [
                durable(.running, now, threadID: "codex-thread"),
                durable(.queued, now, threadID: "queued"),
                durable(.waiting, now, threadID: "waiting"),
                durable(.waitingApproval, now, threadID: "approval"),
                durable(.failed, now, threadID: "failed"),
                durable(.deliveryUnknown, now, threadID: "unknown"),
                durable(.completed, now, threadID: "completed"),
                durable(.cancelled, now, threadID: "cancelled"),
            ],
            runningConversations: [
                DigitalMeRunningConversation(
                    provider: .codex,
                    sourceID: "codex-thread",
                    updatedAt: now
                ),
                DigitalMeRunningConversation(
                    provider: .dsh,
                    sourceID: "dsh-session",
                    updatedAt: now.addingTimeInterval(1)
                ),
            ]
        )

        let snapshot = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: input,
                remote: .notRequested
            )
        )

        // The Codex conversation is the same identity as the durable delivery;
        // the independent DSH conversation remains an additional active item.
        XCTAssertEqual(snapshot.work.activeCount, 2)
        XCTAssertEqual(snapshot.work.queuedCount, 2)
        XCTAssertEqual(snapshot.work.blockedCount, 4)
        XCTAssertEqual(snapshot.work.packetCount, 7)
        XCTAssertEqual(snapshot.work.runCount, 2)
        XCTAssertEqual(snapshot.work.primaryItem?.kind, .blockedDelivery)
        XCTAssertEqual(snapshot.work.primaryItem?.title, "Work needs attention")
    }

    func testSameCodexThreadAcrossDeliveryAndConversationCountsOnce() {
        let now = Date(timeIntervalSince1970: 101)
        let snapshot = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: DigitalMeWorkProjectionInput(
                    runtimeWork: nil,
                    durableQueue: [
                        durable(.running, now, threadID: "same-thread"),
                    ],
                    runningConversations: [
                        DigitalMeRunningConversation(
                            provider: .codex,
                            sourceID: "same-thread",
                            updatedAt: now
                        ),
                    ]
                ),
                remote: .notRequested
            )
        )

        XCTAssertEqual(snapshot.work.activeCount, 1)
    }

    func testManagedConversationTitleNeverEntersProjectionOrSnapshot() {
        let sensitiveTitle = "SECRET prompt /Users/private/token=abc123"
        let input = DigitalMeNavigationProjection.makeInput(
            runtimeWork: nil,
            durableQueueItems: nil,
            managedChatThreads: [
                managedChat(
                    provider: .dsh,
                    sourceID: "safe-session-id",
                    title: sensitiveTitle
                ),
            ],
            remote: .notRequested
        )
        let snapshot = DigitalMeNavigationProjection.makeSnapshot(from: input)

        XCTAssertFalse(String(reflecting: input).contains(sensitiveTitle))
        XCTAssertFalse(String(reflecting: snapshot).contains(sensitiveTitle))
        XCTAssertEqual(snapshot.work.primaryItem?.title, "DSH conversation is running")
    }

    func testReviewSeparatesThreePendingKindsWithoutMemoryMirrorDuplication() {
        let pendingApprovals = DigitalMeApprovalsResponse(
            approvalCount: 4,
            approvals: [
                approval(id: "ordinary", status: "pending", targetKind: "deployment"),
                approval(id: "memory", status: "pending", targetKind: "memory_candidate"),
                approval(id: "done", status: "approved", targetKind: "deployment"),
                approval(id: "waiting", status: "waiting", targetKind: nil),
            ]
        )
        let memory = DigitalMeMemoryCandidatesResponse(
            memoryIndex: memoryIndex(),
            candidateCount: 3,
            candidates: [
                memoryCandidate(id: "one"),
                memoryCandidate(id: "two"),
                memoryCandidate(
                    id: "reviewed",
                    review: DigitalMeMemoryCandidateReview(
                        decision: "approve",
                        approvalDecision: "approved"
                    )
                ),
            ]
        )
        let persona = DigitalMePersonaResponse(
            personaRegistryVersion: "v1",
            reviewQueueVersion: "v2",
            memoryVaults: [],
            personaCards: [],
            twinInstances: [],
            personalityCandidates: [],
            pendingPersonalityReview: [
                DigitalMePersonalityCandidate(
                    candidateID: "pc-pending",
                    trait: "Evidence first",
                    status: "pending_review"
                ),
                DigitalMePersonalityCandidate(
                    candidateID: "pc-done",
                    trait: "Done",
                    status: "accepted"
                ),
            ]
        )
        let remote = DigitalMeNavigationRemoteSources(
            approvals: loaded(pendingApprovals),
            memoryCandidates: loaded(memory),
            persona: loaded(persona)
        )

        let snapshot = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: unloadedWork(),
                remote: remote
            )
        )

        XCTAssertEqual(snapshot.review.approvalCount, 2)
        XCTAssertEqual(snapshot.review.memoryCandidateCount, 2)
        XCTAssertEqual(snapshot.review.personalityCandidateCount, 1)
        XCTAssertEqual(snapshot.review.totalAttentionCount, 5)
        XCTAssertEqual(snapshot.review.knownAttentionCount, 5)
        XCTAssertEqual(snapshot.review.availability, .available)
    }

    func testPartialSourceFailureKeepsKnownCountsButNotCompleteTotal() {
        let remote = DigitalMeNavigationRemoteSources(
            approvals: loaded(
                DigitalMeApprovalsResponse(
                    approvalCount: 1,
                    approvals: [approval(id: "one", status: "pending", targetKind: nil)]
                )
            ),
            memoryCandidates: DigitalMeNavigationSourceState(
                value: nil,
                isLoading: false,
                errorMessage: "Memory source unavailable",
                lastAttemptedAt: Date(),
                refreshedAt: nil
            ),
            persona: loaded(emptyPersona())
        )

        let snapshot = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: unloadedWork(),
                remote: remote
            )
        )

        XCTAssertEqual(snapshot.review.availability, .partial)
        XCTAssertEqual(snapshot.review.approvalCount, 1)
        XCTAssertNil(snapshot.review.memoryCandidateCount)
        XCTAssertNil(snapshot.review.totalAttentionCount)
        XCTAssertEqual(snapshot.review.knownAttentionCount, 1)
        XCTAssertEqual(snapshot.review.issues.map(\.source), [.memoryCandidates])
    }

    func testLoadingOrFailedCachedValueDoesNotContributeToCurrentAttention() {
        let staleApprovals = DigitalMeApprovalsResponse(
            approvalCount: 1,
            approvals: [approval(id: "stale", status: "pending", targetKind: "run")]
        )
        let freshMemory = DigitalMeMemoryCandidatesResponse(
            memoryIndex: memoryIndex(),
            candidateCount: 1,
            candidates: [memoryCandidate(id: "fresh-memory")]
        )
        let freshPersona = DigitalMePersonaResponse(
            personaRegistryVersion: "v1",
            reviewQueueVersion: "v1",
            memoryVaults: [],
            personaCards: [],
            twinInstances: [],
            personalityCandidates: [],
            pendingPersonalityReview: [
                DigitalMePersonalityCandidate(
                    candidateID: "fresh-personality",
                    trait: nil,
                    status: "pending_review"
                ),
            ]
        )
        let staleStates = [
            DigitalMeNavigationSourceState(
                value: staleApprovals,
                isLoading: true,
                errorMessage: nil,
                lastAttemptedAt: Date(),
                refreshedAt: Date(timeIntervalSince1970: 1)
            ),
            DigitalMeNavigationSourceState(
                value: staleApprovals,
                isLoading: false,
                errorMessage: "Approval refresh failed",
                lastAttemptedAt: Date(),
                refreshedAt: Date(timeIntervalSince1970: 1)
            ),
        ]

        for staleState in staleStates {
            let snapshot = DigitalMeNavigationProjection.makeSnapshot(
                from: DigitalMeNavigationProjectionInput(
                    work: unloadedWork(),
                    remote: DigitalMeNavigationRemoteSources(
                        approvals: staleState,
                        memoryCandidates: loaded(freshMemory),
                        persona: loaded(freshPersona)
                    )
                )
            )

            XCTAssertNil(snapshot.review.approvalCount)
            XCTAssertNil(snapshot.review.approvalCountCompleteness)
            XCTAssertEqual(snapshot.review.memoryCandidateCount, 1)
            XCTAssertEqual(snapshot.review.personalityCandidateCount, 1)
            XCTAssertEqual(snapshot.review.knownAttentionCount, 2)
            XCTAssertNil(snapshot.review.totalAttentionCount)
            XCTAssertEqual(snapshot.review.availability, .partial)
        }
    }

    func testFullFiveHundredRowPagesAreLowerBoundsAndNeverProduceExactTotal() {
        let snapshot = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: unloadedWork(),
                remote: remotePage(count: DigitalMeNavigationContract.pageLimit)
            )
        )

        XCTAssertEqual(snapshot.review.approvalCount, 500)
        XCTAssertEqual(snapshot.review.approvalCountCompleteness, .atLeast)
        XCTAssertEqual(snapshot.review.memoryCandidateCount, 500)
        XCTAssertEqual(snapshot.review.memoryCandidateCountCompleteness, .atLeast)
        XCTAssertEqual(snapshot.review.personalityCandidateCount, 500)
        XCTAssertEqual(snapshot.review.personalityCandidateCountCompleteness, .atLeast)
        XCTAssertEqual(snapshot.review.knownAttentionCount, 1_500)
        XCTAssertNil(snapshot.review.totalAttentionCount)
        XCTAssertEqual(snapshot.review.availability, .partial)

        XCTAssertEqual(snapshot.memory.vaultCount, 500)
        XCTAssertEqual(snapshot.memory.vaultCountCompleteness, .atLeast)
        XCTAssertEqual(snapshot.memory.pendingCandidateCountCompleteness, .atLeast)
        XCTAssertEqual(snapshot.memory.availability, .partial)
        XCTAssertEqual(snapshot.persona.activePersonaCountCompleteness, .atLeast)
        XCTAssertEqual(snapshot.persona.runningTwinCountCompleteness, .atLeast)
        XCTAssertEqual(snapshot.persona.availability, .partial)
    }

    func testFourHundredNinetyNineRowPagesRemainExact() {
        let snapshot = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: unloadedWork(),
                remote: remotePage(count: DigitalMeNavigationContract.pageLimit - 1)
            )
        )

        XCTAssertEqual(snapshot.review.approvalCountCompleteness, .exact)
        XCTAssertEqual(snapshot.review.memoryCandidateCountCompleteness, .exact)
        XCTAssertEqual(snapshot.review.personalityCandidateCountCompleteness, .exact)
        XCTAssertEqual(snapshot.review.totalAttentionCount, 1_497)
        XCTAssertEqual(snapshot.review.availability, .available)
        XCTAssertEqual(snapshot.memory.vaultCountCompleteness, .exact)
        XCTAssertEqual(snapshot.memory.pendingCandidateCountCompleteness, .exact)
        XCTAssertEqual(snapshot.memory.availability, .available)
        XCTAssertEqual(snapshot.persona.activePersonaCountCompleteness, .exact)
        XCTAssertEqual(snapshot.persona.runningTwinCountCompleteness, .exact)
        XCTAssertEqual(snapshot.persona.availability, .available)
    }

    func testMemoryAndPersonaExposeOnlySupportedClaims() {
        let persona = DigitalMePersonaResponse(
            personaRegistryVersion: "persona-v1",
            reviewQueueVersion: "review-v1",
            memoryVaults: [
                DigitalMeMemoryVault(vaultID: "v1", displayName: "Private", status: "active"),
            ],
            personaCards: [
                DigitalMePersonaCard(personaID: "p1", displayName: "Alpha", status: "active"),
                DigitalMePersonaCard(personaID: "p2", displayName: "Beta", status: "disabled"),
            ],
            twinInstances: [
                DigitalMeTwinInstance(instanceID: "t1", displayName: "Twin One", status: "running"),
                DigitalMeTwinInstance(instanceID: "t2", displayName: "Twin Two", status: "stopped"),
            ],
            personalityCandidates: [],
            pendingPersonalityReview: []
        )
        let memory = DigitalMeMemoryCandidatesResponse(
            memoryIndex: DigitalMeMemoryIndex(
                exists: true,
                latestGeneratedAt: "2026-08-28T00:00:00Z",
                candidateSignalCount: 3,
                knowledgeSourceCount: 9,
                warnings: []
            ),
            candidateCount: 1,
            candidates: [memoryCandidate(id: "pending")]
        )
        let remote = DigitalMeNavigationRemoteSources(
            approvals: loaded(DigitalMeApprovalsResponse(approvalCount: 0, approvals: [])),
            memoryCandidates: loaded(memory),
            persona: loaded(persona)
        )

        let snapshot = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: unloadedWork(),
                remote: remote
            )
        )

        XCTAssertEqual(snapshot.memory.vaultCount, 1)
        XCTAssertEqual(snapshot.memory.snapshotExists, true)
        XCTAssertEqual(snapshot.memory.pendingCandidateCount, 1)
        XCTAssertEqual(snapshot.memory.candidateSignalCount, 3)
        XCTAssertEqual(snapshot.memory.knowledgeSourceCount, 9)
        XCTAssertEqual(snapshot.persona.activePersonaCount, 1)
        XCTAssertEqual(snapshot.persona.runningTwinCount, 1)
        XCTAssertEqual(snapshot.persona.activePersonaNames, ["Alpha"])
        XCTAssertEqual(snapshot.persona.runningTwinNames, ["Twin One"])
        XCTAssertEqual(snapshot.persona.registryVersion, "persona-v1")

        let memoryFields = Set(Mirror(reflecting: snapshot.memory).children.compactMap(\.label))
        XCTAssertFalse(memoryFields.contains("acceptedCount"))
        let personaFields = Set(Mirror(reflecting: snapshot.persona).children.compactMap(\.label))
        XCTAssertFalse(personaFields.contains("selectedPersona"))
        XCTAssertFalse(personaFields.contains("currentPersona"))
        XCTAssertFalse(personaFields.contains("evaluationState"))
    }

    func testPersonaNamesFilterUnsafeValuesBeforeTakingFirstThree() {
        let unsafeNames = [
            "Line\nBreak",
            "/Users/private/persona",
            "token holder",
            "https://example.test",
            "password vault",
            String(repeating: "A", count: 49),
        ]
        let safeNames = [
            "安全 人格-1_(A)·O'Neil",
            "Beta.2",
            "第三 人格",
            "Fourth Safe",
        ]
        let cards = (unsafeNames + safeNames).enumerated().map { index, name in
            DigitalMePersonaCard(
                personaID: "persona-\(index)",
                displayName: name,
                status: "active"
            )
        }
        let twins = [
            DigitalMeTwinInstance(
                instanceID: "unsafe",
                displayName: "bearer secret",
                status: "running"
            ),
            DigitalMeTwinInstance(
                instanceID: "safe",
                displayName: "安全 Twin_(1)",
                status: "running"
            ),
        ]
        let persona = DigitalMePersonaResponse(
            personaRegistryVersion: "v1",
            reviewQueueVersion: "v1",
            memoryVaults: [],
            personaCards: cards,
            twinInstances: twins,
            personalityCandidates: [],
            pendingPersonalityReview: []
        )
        let snapshot = DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjectionInput(
                work: unloadedWork(),
                remote: DigitalMeNavigationRemoteSources(
                    approvals: .notRequested,
                    memoryCandidates: .notRequested,
                    persona: loaded(persona)
                )
            )
        )

        XCTAssertEqual(snapshot.persona.activePersonaNames, Array(safeNames.prefix(3)))
        XCTAssertEqual(snapshot.persona.runningTwinNames, ["安全 Twin_(1)"])
        XCTAssertFalse(String(reflecting: snapshot.persona).contains("token holder"))
    }

    func testProjectionIsDeterministicAndDoesNotMutateInput() {
        let input = DigitalMeNavigationProjectionInput(
            work: DigitalMeWorkProjectionInput(
                runtimeWork: DigitalMeRuntimeWork(
                    packetCount: 1,
                    blockedCount: 0,
                    runCount: 1
                ),
                durableQueue: [],
                runningConversations: []
            ),
            remote: loadedRemoteSources()
        )
        let original = input

        let first = DigitalMeNavigationProjection.makeSnapshot(from: input)
        let second = DigitalMeNavigationProjection.makeSnapshot(from: input)

        XCTAssertEqual(first, second)
        XCTAssertEqual(input, original)
    }

    func testReadOnlyContractsDecodeCurrentSnakeCasePayloads() throws {
        let decoder = JSONDecoder()
        let approvals = try decoder.decode(
            DigitalMeApprovalsResponse.self,
            from: Data(#"{"approval_count":1,"approvals":[{"approval_id":"a1","status":"pending","action_type":"other","target":{"kind":"memory_candidate","display":"c1"},"updated_at":"now"}]}"#.utf8)
        )
        let memory = try decoder.decode(
            DigitalMeMemoryCandidatesResponse.self,
            from: Data(#"{"memory_index":{"exists":true,"latest_generated_at":"now","candidate_signal_count":2,"knowledge_source_count":4,"warnings":[]},"candidate_count":1,"candidates":[{"candidate_id":"c1","status":"candidate","requires_review":true,"adoption":{"status":"not_adopted","requires_human_review":true}}]}"#.utf8)
        )
        let persona = try decoder.decode(
            DigitalMePersonaResponse.self,
            from: Data(#"{"persona_registry_version":"v1","review_queue_version":"v2","memory_vaults":[],"persona_cards":[],"twin_instances":[],"personality_candidates":[],"pending_personality_review":[]}"#.utf8)
        )

        XCTAssertEqual(approvals.approvals.first?.target?.kind, "memory_candidate")
        XCTAssertEqual(memory.memoryIndex?.knowledgeSourceCount, 4)
        XCTAssertEqual(persona.personaRegistryVersion, "v1")
    }

    func testStoreRefreshesSourcesConcurrentlyAndKeepsErrorsIndependentWithinTTL() async {
        let transport = RecordingDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 10)
        let firstAttempt = Date(timeIntervalSince1970: 1_000)

        await store.refreshIfNeeded(
            port: 8_765,
            workspaceRoot: "/workspace/private",
            authToken: "secret",
            now: firstAttempt
        )

        XCTAssertNotNil(store.sources.approvals.value)
        XCTAssertNil(store.sources.approvals.errorMessage)
        XCTAssertNil(store.sources.memoryCandidates.value)
        XCTAssertNotNil(store.sources.memoryCandidates.errorMessage)
        XCTAssertNotNil(store.sources.persona.value)
        XCTAssertNil(store.sources.persona.errorMessage)
        let maximumConcurrentRequests = await transport.maximumConcurrentRequests()
        let initialRequestCount = await transport.requestCount()
        XCTAssertGreaterThanOrEqual(maximumConcurrentRequests, 2)
        XCTAssertEqual(initialRequestCount, 3)

        await store.refreshIfNeeded(
            port: 8_765,
            workspaceRoot: "/workspace/private",
            authToken: "secret",
            now: firstAttempt.addingTimeInterval(5)
        )

        let cachedRequestCount = await transport.requestCount()
        let allRequestsAreReadOnlyLoopback = await transport.allRequestsAreReadOnlyLoopback()
        XCTAssertEqual(cachedRequestCount, 3)
        XCTAssertTrue(allRequestsAreReadOnlyLoopback)
    }

    func testStoreCanRefreshOnlyTheSourcesRequestedByTheVisibleSection() async {
        let transport = RecordingDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 10)

        await store.refreshIfNeeded(
            sources: [.persona],
            port: 8_765,
            workspaceRoot: "/workspace/private",
            authToken: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertNil(store.sources.approvals.lastAttemptedAt)
        XCTAssertNil(store.sources.memoryCandidates.lastAttemptedAt)
        XCTAssertNotNil(store.sources.persona.value)
        let requestCount = await transport.requestCount()
        let paths = await transport.requestPaths()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(paths, ["/persona"])
    }

    func testOverlappingSubsetRefreshDoesNotDropLaterSources() async {
        let transport = RecordingDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 10)
        let now = Date(timeIntervalSince1970: 3_000)

        let personaRefresh = Task { @MainActor in
            await store.refreshIfNeeded(
                sources: [.persona],
                port: 8_765,
                workspaceRoot: "/workspace/private",
                authToken: nil,
                now: now
            )
        }
        while await transport.requestCount() == 0 {
            await Task.yield()
        }
        let approvalsRefresh = Task { @MainActor in
            await store.refreshIfNeeded(
                sources: [.approvals],
                port: 8_765,
                workspaceRoot: "/workspace/private",
                authToken: nil,
                now: now
            )
        }

        await personaRefresh.value
        await approvalsRefresh.value

        XCTAssertNotNil(store.sources.persona.value)
        XCTAssertNotNil(store.sources.approvals.value)
        XCTAssertNil(store.sources.memoryCandidates.lastAttemptedAt)
        let paths = await transport.requestPaths()
        XCTAssertEqual(paths.sorted(), ["/approvals", "/persona"])
    }

    func testWorkspaceScopeChangeInvalidatesTTLAndClearsOldValuesImmediately() async {
        let transport = RecordingDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 15)
        let now = Date(timeIntervalSince1970: 4_000)

        await store.refreshIfNeeded(
            sources: [.approvals],
            port: 8_765,
            workspaceRoot: "/workspace/A/",
            authToken: nil,
            now: now
        )
        XCTAssertNotNil(store.sources.approvals.value)

        let workspaceBRefresh = Task { @MainActor in
            await store.refreshIfNeeded(
                sources: [.approvals],
                port: 8_765,
                workspaceRoot: "/workspace/B/",
                authToken: nil,
                now: now.addingTimeInterval(1)
            )
        }
        while await transport.requestCount() < 2 {
            await Task.yield()
        }

        XCTAssertNil(store.sources.approvals.value)
        XCTAssertTrue(store.sources.approvals.isLoading)
        await workspaceBRefresh.value
        let roots = await transport.requestRoots()
        XCTAssertEqual(roots, ["/workspace/A", "/workspace/B"])
    }

    func testSynchronousScopeAccessorHidesCachedWorkspaceBeforeRefreshTaskStarts() async {
        let transport = RecordingDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 15)

        await store.refreshIfNeeded(
            sources: [.approvals],
            port: 8_765,
            workspaceRoot: "/workspace/A/",
            authToken: nil
        )

        let matchingA = store.sources(
            matchingPort: 8_765,
            workspaceRoot: "/workspace/A"
        )
        let requestedB = store.sources(
            matchingPort: 8_765,
            workspaceRoot: "/workspace/B"
        )

        XCTAssertNotNil(matchingA.approvals.value)
        XCTAssertEqual(requestedB, .notRequested)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSynchronousScopeAccessorFailsClosedWhenCachedValueExpires() async {
        let transport = RecordingDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 10)
        let refreshedAt = Date(timeIntervalSince1970: 3_500)

        await store.refreshIfNeeded(
            sources: [.approvals],
            port: 8_765,
            workspaceRoot: "/workspace/A",
            authToken: nil,
            now: refreshedAt
        )

        let fresh = store.sources(
            matchingPort: 8_765,
            workspaceRoot: "/workspace/A",
            now: refreshedAt.addingTimeInterval(9)
        )
        let expired = store.sources(
            matchingPort: 8_765,
            workspaceRoot: "/workspace/A",
            now: refreshedAt.addingTimeInterval(10)
        )

        XCTAssertNotNil(fresh.approvals.value)
        XCTAssertNil(expired.approvals.value)
        XCTAssertNotNil(store.sources.approvals.value)
    }

    func testSlowOldWorkspaceCannotOverwriteNewWorkspaceResult() async {
        let transport = ControlledDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 15)

        let oldRefresh = Task { @MainActor in
            await store.refreshIfNeeded(
                sources: [.approvals],
                port: 8_765,
                workspaceRoot: "/workspace/A",
                authToken: nil
            )
        }
        while await transport.requestCount() < 1 {
            await Task.yield()
        }
        let newRefresh = Task { @MainActor in
            await store.refreshIfNeeded(
                sources: [.approvals],
                port: 8_765,
                workspaceRoot: "/workspace/B",
                authToken: nil
            )
        }
        while await transport.requestCount() < 2 {
            await Task.yield()
        }

        await transport.completeRequest(at: 1, approvalID: "workspace-B")
        await newRefresh.value
        XCTAssertEqual(store.sources.approvals.value?.approvals.first?.approvalID, "workspace-B")

        await transport.completeRequest(at: 0, approvalID: "workspace-A")
        await oldRefresh.value
        XCTAssertEqual(store.sources.approvals.value?.approvals.first?.approvalID, "workspace-B")
    }

    func testCancelledGenerationCannotOverwriteSubsequentRefresh() async {
        let transport = ControlledDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 15)

        let cancelledRefresh = Task { @MainActor in
            await store.refreshIfNeeded(
                sources: [.approvals],
                port: 8_765,
                workspaceRoot: "/workspace/same",
                authToken: nil
            )
        }
        while await transport.requestCount() < 1 {
            await Task.yield()
        }
        store.cancelRefresh()

        let replacementRefresh = Task { @MainActor in
            await store.refreshIfNeeded(
                sources: [.approvals],
                port: 8_765,
                workspaceRoot: "/workspace/same",
                authToken: nil
            )
        }
        while await transport.requestCount() < 2 {
            await Task.yield()
        }

        await transport.completeRequest(at: 1, approvalID: "replacement")
        await replacementRefresh.value
        XCTAssertEqual(store.sources.approvals.value?.approvals.first?.approvalID, "replacement")

        await transport.completeRequest(at: 0, approvalID: "cancelled")
        await cancelledRefresh.value
        XCTAssertEqual(store.sources.approvals.value?.approvals.first?.approvalID, "replacement")
    }

    func testInvalidPortFailsBeforeTransportReceivesBearerOrWorkspace() async {
        let transport = RecordingDigitalMeNavigationTransport()
        let store = DigitalMeNavigationStore(transport: transport, ttl: 15)

        await store.refreshIfNeeded(
            sources: [.approvals],
            port: 0,
            workspaceRoot: "/workspace/private",
            authToken: "must-not-leave-request-builder"
        )

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(store.sources.approvals.value)
        XCTAssertEqual(
            store.sources.approvals.errorMessage,
            "The local Digital-Me API endpoint is invalid."
        )
    }

    private func durable(
        _ state: CodexDeliveryState,
        _ date: Date,
        threadID: String
    ) -> DigitalMeDurableWorkItem {
        DigitalMeDurableWorkItem(
            state: state,
            stateChangedAt: date,
            threadID: threadID
        )
    }

    private func managedChat(
        provider: ManagedChatProvider,
        sourceID: String,
        title: String
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider,
            sourceScope: "scope",
            sourceID: sourceID,
            title: title,
            titleSource: "fixture",
            hasMeaningfulTitle: true,
            createdAt: 100,
            updatedAt: 200,
            tokensUsed: 999,
            model: nil,
            cwd: "/private/sensitive/path",
            archived: false,
            running: true,
            sourceStatus: "running",
            threadSource: provider.rawValue,
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: sourceID,
            isSubagent: false,
            isSidechat: false,
            activity: ManagedChatActivity(main: 1, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(
                state: .running,
                reason: "fixture"
            )
        )
    }

    private func approval(
        id: String,
        status: String?,
        targetKind: String?
    ) -> DigitalMeApproval {
        DigitalMeApproval(
            approvalID: id,
            status: status,
            risk: "low",
            actionType: "other",
            target: DigitalMeApprovalTarget(kind: targetKind, display: id),
            updatedAt: nil
        )
    }

    private func memoryCandidate(
        id: String,
        review: DigitalMeMemoryCandidateReview? = nil
    ) -> DigitalMeMemoryCandidate {
        DigitalMeMemoryCandidate(
            candidateID: id,
            name: id,
            status: "candidate",
            requiresReview: true,
            adoption: DigitalMeMemoryCandidateAdoption(
                status: "not_adopted",
                requiresHumanReview: true
            ),
            review: review
        )
    }

    private func memoryIndex() -> DigitalMeMemoryIndex {
        DigitalMeMemoryIndex(
            exists: true,
            latestGeneratedAt: nil,
            candidateSignalCount: 0,
            knowledgeSourceCount: 0,
            warnings: []
        )
    }

    private func emptyPersona() -> DigitalMePersonaResponse {
        DigitalMePersonaResponse(
            personaRegistryVersion: nil,
            reviewQueueVersion: nil,
            memoryVaults: [],
            personaCards: [],
            twinInstances: [],
            personalityCandidates: [],
            pendingPersonalityReview: []
        )
    }

    private func loadedRemoteSources() -> DigitalMeNavigationRemoteSources {
        DigitalMeNavigationRemoteSources(
            approvals: loaded(DigitalMeApprovalsResponse(approvalCount: 0, approvals: [])),
            memoryCandidates: loaded(
                DigitalMeMemoryCandidatesResponse(
                    memoryIndex: memoryIndex(),
                    candidateCount: 0,
                    candidates: []
                )
            ),
            persona: loaded(emptyPersona())
        )
    }

    private func remotePage(count: Int) -> DigitalMeNavigationRemoteSources {
        let approvals = (0..<count).map {
            approval(id: "approval-\($0)", status: "pending", targetKind: "run")
        }
        let memoryCandidates = (0..<count).map {
            memoryCandidate(id: "memory-\($0)")
        }
        let vaults = (0..<count).map {
            DigitalMeMemoryVault(
                vaultID: "vault-\($0)",
                displayName: nil,
                status: "active"
            )
        }
        let cards = (0..<count).map {
            DigitalMePersonaCard(
                personaID: "persona-\($0)",
                displayName: nil,
                status: "active"
            )
        }
        let twins = (0..<count).map {
            DigitalMeTwinInstance(
                instanceID: "twin-\($0)",
                displayName: nil,
                status: "running"
            )
        }
        let personality = (0..<count).map {
            DigitalMePersonalityCandidate(
                candidateID: "personality-\($0)",
                trait: nil,
                status: "pending_review"
            )
        }
        return DigitalMeNavigationRemoteSources(
            approvals: loaded(
                DigitalMeApprovalsResponse(
                    approvalCount: count,
                    approvals: approvals
                )
            ),
            memoryCandidates: loaded(
                DigitalMeMemoryCandidatesResponse(
                    memoryIndex: memoryIndex(),
                    candidateCount: count,
                    candidates: memoryCandidates
                )
            ),
            persona: loaded(
                DigitalMePersonaResponse(
                    personaRegistryVersion: "v1",
                    reviewQueueVersion: "v1",
                    memoryVaults: vaults,
                    personaCards: cards,
                    twinInstances: twins,
                    personalityCandidates: personality,
                    pendingPersonalityReview: personality
                )
            )
        )
    }

    private func loaded<Value>(
        _ value: Value
    ) -> DigitalMeNavigationSourceState<Value> {
        let now = Date(timeIntervalSince1970: 1)
        return DigitalMeNavigationSourceState(
            value: value,
            isLoading: false,
            errorMessage: nil,
            lastAttemptedAt: now,
            refreshedAt: now
        )
    }

    private func unloadedWork() -> DigitalMeWorkProjectionInput {
        DigitalMeWorkProjectionInput(
            runtimeWork: nil,
            durableQueue: nil,
            runningConversations: nil
        )
    }
}

private actor RecordingDigitalMeNavigationTransport: DigitalMeNavigationTransport {
    private var requests: [URLRequest] = []
    private var activeRequests = 0
    private var maximumActiveRequests = 0

    func send(_ request: URLRequest) async throws -> DigitalMeNavigationTransportResponse {
        requests.append(request)
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }
        try await Task.sleep(for: .milliseconds(25))

        switch request.url?.path {
        case "/approvals":
            return response(#"{"ok":true,"data":{"approval_count":0,"approvals":[]}}"#)
        case "/memory-candidates":
            return DigitalMeNavigationTransportResponse(data: Data(), statusCode: 503)
        case "/persona":
            return response(#"{"ok":true,"data":{"persona_registry_version":"v1","review_queue_version":"v1","memory_vaults":[],"persona_cards":[],"twin_instances":[],"personality_candidates":[],"pending_personality_review":[]}}"#)
        default:
            return DigitalMeNavigationTransportResponse(data: Data(), statusCode: 404)
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func maximumConcurrentRequests() -> Int {
        maximumActiveRequests
    }

    func requestPaths() -> [String] {
        requests.compactMap { $0.url?.path }
    }

    func requestRoots() -> [String] {
        requests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "root" })?
                .value
        }
    }

    func allRequestsAreReadOnlyLoopback() -> Bool {
        requests.allSatisfy {
            $0.httpMethod == "GET"
                && $0.url?.host == "127.0.0.1"
                && $0.url?.query?.contains("root=") == true
                && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "limit" })?
                    .value == "500"
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret"
        }
    }

    private func response(_ json: String) -> DigitalMeNavigationTransportResponse {
        DigitalMeNavigationTransportResponse(
            data: Data(json.utf8),
            statusCode: 200
        )
    }
}

private actor ControlledDigitalMeNavigationTransport: DigitalMeNavigationTransport {
    private typealias Continuation = CheckedContinuation<
        DigitalMeNavigationTransportResponse,
        any Error
    >

    private var requests: [URLRequest] = []
    private var continuations: [Int: Continuation] = [:]

    func send(_ request: URLRequest) async throws -> DigitalMeNavigationTransportResponse {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func completeRequest(at index: Int, approvalID: String) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            return
        }
        let json = """
        {"ok":true,"data":{"approval_count":1,"approvals":[{"approval_id":"\(approvalID)","status":"pending","target":{"kind":"run"}}]}}
        """
        continuation.resume(
            returning: DigitalMeNavigationTransportResponse(
                data: Data(json.utf8),
                statusCode: 200
            )
        )
    }
}
