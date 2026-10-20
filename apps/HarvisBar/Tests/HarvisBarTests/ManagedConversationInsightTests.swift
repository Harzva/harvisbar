import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedConversationInsightTests: XCTestCase {
    func testStrictDecoderRejectsActionAndUnknownNestedFields() throws {
        var topLevel = responseObject(requestID: requestUUID.uuidString)
        topLevel["action"] = ["type": "dispatch"]
        XCTAssertThrowsError(try decode(response: topLevel)) { error in
            XCTAssertEqual(
                error as? ManagedConversationInsightValidationError,
                .unknownKeys(path: "$", keys: ["action"])
            )
        }

        var nested = responseObject(requestID: requestUUID.uuidString)
        var relevance = nested["relevance"] as! [String: Any]
        relevance["targetPrompt"] = "run this"
        nested["relevance"] = relevance
        XCTAssertThrowsError(try decode(response: nested)) { error in
            XCTAssertEqual(
                error as? ManagedConversationInsightValidationError,
                .unknownKeys(path: "$.relevance", keys: ["targetPrompt"])
            )
        }
    }

    func testStrictDecoderRequiresExactIdentityAndCandidateSet() throws {
        var wrong = responseObject(requestID: requestUUID.uuidString)
        wrong["inputFingerprint"] = "sha256:wrong"
        XCTAssertThrowsError(try decode(response: wrong)) { error in
            XCTAssertEqual(
                error as? ManagedConversationInsightValidationError,
                .requestMismatch(field: "inputFingerprint")
            )
        }

        var outside = responseObject(requestID: requestUUID.uuidString)
        var relevance = outside["relevance"] as! [String: Any]
        relevance["recommendedCandidateID"] = "project-outside"
        relevance["recommendedScore"] = 99
        outside["relevance"] = relevance
        XCTAssertThrowsError(try decode(response: outside)) { error in
            XCTAssertEqual(
                error as? ManagedConversationInsightValidationError,
                .recommendationNotInCandidates("project-outside")
            )
        }
    }

    func testLocalRedactorRemovesSecretsPathsURLsAndLargeBase64() {
        let base64 = String(
            repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo",
            count: 4
        )
        let raw = """
        Authorization: Bearer super-secret
        Cookie: sid=cookie-value
        API_KEY=env-value
        Open /Users/alice/private/project/file.txt and https://example.com/private?q=1
        \(base64)
        -----BEGIN PRIVATE KEY-----
        key-material
        -----END PRIVATE KEY-----
        """
        let redacted = ManagedConversationInsightRedactor.redact(raw)

        for forbidden in [
            "super-secret", "cookie-value", "env-value", "/Users/alice",
            "https://example.com", base64, "key-material",
        ] {
            XCTAssertFalse(redacted.contains(forbidden), forbidden)
        }
        XCTAssertTrue(redacted.contains("[REDACTED_LOCAL_PATH]"))
        XCTAssertTrue(redacted.contains("[REDACTED_PRIVATE_KEY]"))
    }

    func testSecurityUnavailableBlocksBeforeAnyDshMutation() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        let verifier = FakeInsightCapabilityVerifier(
            [.unavailable("catalog cannot be proven")]
        )
        let coordinator = makeCoordinator(
            store: store,
            client: client,
            verifier: verifier
        )
        await coordinator.activate()

        let preflight = await coordinator.attestSecurity(endpoint: endpoint)
        XCTAssertFalse(preflight.isAvailable)
        let prepared = try coordinator.prepare(makeInput())
        do {
            _ = try await coordinator.analyzePrepared(
                prepared,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
            XCTFail("An unattested preset must fail closed")
        } catch let error as ManagedConversationInsightCoordinatorError {
            guard case .securityUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let prepares = await client.sessionRequests()
        let prompts = await client.promptRequests()
        XCTAssertTrue(prepares.isEmpty)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertFalse(coordinator.securityAvailability.isAvailable)
    }

    func testCoordinatorWireContainsOnlyIrreversibleFactsAndExactCounts() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: requestUUID.uuidString
        ))))
        let coordinator = makeCoordinator(store: store, client: client)
        await coordinator.activate()

        let input = makeInput(includeUnknownAndExcludedManager: true)
        let prepared = try coordinator.prepare(input)
        let preparedDescription = String(reflecting: prepared)
        XCTAssertFalse(preparedDescription.contains("RAW_SENTENCE_NEVER_ON_WIRE_Z9"))
        XCTAssertFalse(preparedDescription.contains("PRIVATE_PROJECT_LABEL_P8"))
        let result = try await coordinator.analyzePrepared(
            prepared,
            endpoint: endpoint,
            brainWorkingDirectory: "/tmp/brain-work"
        )

        XCTAssertEqual(result.analyzedInputCount, 3)
        XCTAssertEqual(result.totalInputCount, 3)
        XCTAssertEqual(result.omittedInputCount, 0)
        let prompts = await client.promptRequests()
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.mode, .queue)
        XCTAssertLessThanOrEqual(
            prompt.text.count,
            ManagedConversationInsightSchemaV1.maximumPromptCharacters
        )
        for forbidden in [
            "RAW_SENTENCE_NEVER_ON_WIRE_Z9",
            "UNKNOWN_SOURCE_SECRET_PHRASE_Q7",
            "MANAGER_COMMAND_MUST_BE_EXCLUDED_X3",
            "PRIVATE_PROJECT_LABEL_P8",
            "PRIVATE_TASK_TITLE_T4",
            "PRIVATE_CONVERSATION_TITLE_C2",
            "top-secret",
            "/Users/alice",
            "\"userInputs\"",
            "\"text\"",
            "\"label\"",
            "\"taskTitles\"",
            "\"conversationTitles\"",
        ] {
            XCTAssertFalse(prompt.text.contains(forbidden), forbidden)
        }
        XCTAssertTrue(prompt.text.contains("conversation_management"))
        XCTAssertTrue(prompt.text.contains("\"unverifiedSourceInputCount\":1"))
        XCTAssertTrue(prompt.text.contains("\"analyzedInputCount\":3"))

        let sessions = await client.sessionRequests()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(
            sessions[0].presetID,
            ManagedConversationInsightPolicy.requiredPresetID
        )
        XCTAssertEqual(
            sessions[0].sessionID,
            ManagedConversationInsightPolicy.ephemeralSessionID(
                for: target,
                generationID: generationUUID
            )
        )
    }

    func testCapabilityChangeAfterSessionPrepareBlocksPrompt() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        let verified = verifiedAvailability()
        let verifier = FakeInsightCapabilityVerifier([
            verified,
            .unavailable("composition changed"),
        ])
        let coordinator = makeCoordinator(
            store: store,
            client: client,
            verifier: verifier
        )
        await coordinator.activate()

        let prepared = try coordinator.prepare(makeInput())
        do {
            _ = try await coordinator.analyzePrepared(
                prepared,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
            XCTFail("A TOCTOU capability change must block delivery")
        } catch let error as ManagedConversationInsightCoordinatorError {
            guard case .securityUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let sessions = await client.sessionRequests()
        let prompts = await client.promptRequests()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(
            coordinator.status(
                for: target,
                currentInputFingerprint: fingerprint,
                currentProjectCandidateID: "project-1"
            )?.state,
            .failed
        )
    }

    func testForgedPreparedProjectionCannotCarryArbitraryStringsToWire() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        let coordinator = makeCoordinator(store: store, client: client)
        await coordinator.activate()
        let valid = try coordinator.prepare(makeInput())
        let forgedProjection = ManagedConversationInsightFactProjectionV1(
            inputSignals: [
                ManagedConversationInsightFactSignalV1(
                    id: "RAW_ARBITRARY_SIGNAL_MUST_NOT_LEAVE",
                    count: 1
                ),
            ],
            projectFacts: valid.factProjection.projectFacts,
            analyzedInputCount: valid.analyzedInputCount,
            totalInputCount: valid.totalInputCount,
            omittedInputCount: valid.omittedInputCount,
            truncatedInputCount: 0,
            unverifiedSourceInputCount: 0
        )
        let forged = ManagedConversationPreparedInsightRequest(
            target: valid.target,
            inputFingerprint: valid.inputFingerprint,
            totalInputCount: valid.totalInputCount,
            analyzedInputCount: valid.analyzedInputCount,
            omittedInputCount: valid.omittedInputCount,
            currentProjectCandidateID: valid.currentProjectCandidateID,
            candidateIDs: valid.candidateIDs,
            factProjection: forgedProjection
        )

        do {
            _ = try await coordinator.analyzePrepared(
                forged,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
            XCTFail("A forged non-taxonomy signal must fail before attestation")
        } catch let error as ManagedConversationInsightValidationError {
            guard case .invalidSummary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let sessions = await client.sessionRequests()
        let prompts = await client.promptRequests()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(prompts.isEmpty)
    }

    func testStoreIsPrivateAtomicAndRecoversInFlightWithoutRawMessages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root
            .appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("insight-v2.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedConversationInsightStoreV1(storeURL: url)
        let record = makeRecord(state: .running)

        try await store.save(
            ManagedConversationInsightStoreEnvelopeV1(records: [record])
        )
        XCTAssertEqual(
            try permissions(at: url.deletingLastPathComponent()) & 0o777,
            0o700
        )
        XCTAssertEqual(try permissions(at: url) & 0o777, 0o600)
        let disk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(disk.contains("RAW_SENTENCE_NEVER_ON_WIRE_Z9"))

        let restarted = ManagedConversationInsightStoreV1(storeURL: url)
        let recovered = try await restarted.load()
        XCTAssertEqual(recovered.records.first?.state, .deliveryUnknown)
        XCTAssertEqual(recovered.records.first?.revision, record.revision + 1)
        XCTAssertTrue(recovered.records.first?.lastError?.contains("not replayed") == true)
        let loadedAgain = try await restarted.load()
        XCTAssertEqual(loadedAgain, recovered)
    }

    func testStoreCASRejectsLateCancelAfterNewGenerationWins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("insight-v2.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedConversationInsightStoreV1(storeURL: url)

        let first = makeRecord(state: .running)
        try await store.upsert(first, expectedRevision: nil)
        var cancelling = first
        cancelling.revision = 2
        cancelling.intent = .cancel
        cancelling.state = .cancelling
        cancelling.cancelRPCID = cancelUUID.uuidString
        try await store.upsert(cancelling, expectedRevision: 1)

        var newRun = cancelling
        newRun.generationID = secondGenerationUUID
        newRun.revision = 3
        newRun.intent = .analyze
        newRun.requestID = secondRequestUUID.uuidString
        newRun.rpcID = secondRPCUUID.uuidString
        newRun.sessionID = ManagedConversationInsightPolicy
            .ephemeralSessionID(for: target, generationID: secondGenerationUUID)
        newRun.cancelRPCID = nil
        newRun.state = .dispatching
        try await store.upsert(newRun, expectedRevision: 2)

        var lateCancel = cancelling
        lateCancel.revision = 3
        lateCancel.state = .cancelled
        do {
            try await store.upsert(lateCancel, expectedRevision: 2)
            XCTFail("A late cancel must lose the CAS")
        } catch {
            guard case .staleRevision(expected: 2, actual: 3) =
                    error as? ManagedConversationInsightStoreErrorV1 else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let storedGeneration = try await store.record(for: target)?.generationID
        XCTAssertEqual(storedGeneration, secondGenerationUUID)
    }

    func testAcceptedPromptPersistenceFailurePublishesVolatileUnknown() async throws {
        let store = RecordingInsightStore(failCASFromCall: 2)
        let client = FakeConversationInsightClient()
        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: requestUUID.uuidString
        ))))
        let coordinator = makeCoordinator(store: store, client: client)
        await coordinator.activate()

        let prepared = try coordinator.prepare(makeInput())
        do {
            _ = try await coordinator.analyzePrepared(
                prepared,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
            XCTFail("A non-durable accepted prompt must be unknown")
        } catch let error as ManagedConversationInsightCoordinatorError {
            guard case .deliveryUnknown = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let promptCount = await client.promptRequests().count
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(
            coordinator.status(
                for: target,
                currentInputFingerprint: fingerprint,
                currentProjectCandidateID: "project-1"
            )?.state,
            .deliveryUnknown
        )
        let durableState = await store.currentRecord()?.state
        XCTAssertEqual(durableState, .dispatching)
    }

    func testCancelIntentIsDurableBeforeRPCAndLateResultIsDropped() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient(cancelProbe: {
            let record = await store.currentRecord()
            return record?.intent == .cancel
                && record?.state == .cancelling
                && record?.cancelRPCID != nil
        })
        await client.setSuspendDecision(true)
        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: requestUUID.uuidString
        ))))
        let coordinator = makeCoordinator(store: store, client: client)
        await coordinator.activate()
        let prepared = try coordinator.prepare(makeInput())

        let analysis = Task { @MainActor in
            try await coordinator.analyzePrepared(
                prepared,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
        }
        await client.waitUntilDecisionWaitStarted()
        try await coordinator.cancel(target: target, endpoint: endpoint)
        let durableIntentObserved = await client.cancelObservedDurableIntent()
        XCTAssertTrue(durableIntentObserved)
        await client.resumeDecisionWait()

        do {
            _ = try await analysis.value
            XCTFail("A late result must be discarded")
        } catch let error as ManagedConversationInsightCoordinatorError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            coordinator.status(
                for: target,
                currentInputFingerprint: fingerprint,
                currentProjectCandidateID: "project-1"
            )?.state,
            .cancelled
        )
    }

    func testPlanningReservationRejectsConcurrentDoubleClick() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: requestUUID.uuidString
        ))))
        let verifier = SuspendingInsightCapabilityVerifier(
            availability: verifiedAvailability()
        )
        let uuids = UUIDSequence([
            generationUUID, requestUUID, rpcUUID,
        ])
        let coordinator = ManagedConversationInsightCoordinator(
            store: store,
            dshClient: client,
            capabilityVerifier: verifier,
            makeUUID: { uuids.next() },
            now: { Date(timeIntervalSince1970: 10) }
        )
        await coordinator.activate()
        let prepared = try coordinator.prepare(makeInput())

        let first = Task { @MainActor in
            try await coordinator.analyzePrepared(
                prepared,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
        }
        await verifier.waitUntilFirstVerificationStarted()
        do {
            _ = try await coordinator.analyzePrepared(
                prepared,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
            XCTFail("The planning reservation must reject a second click")
        } catch let error as ManagedConversationInsightCoordinatorError {
            guard case .analysisAlreadyInFlight = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        await verifier.resumeFirstVerification()
        _ = try await first.value
        let prompts = await client.promptRequests()
        XCTAssertEqual(prompts.count, 1)
    }

    func testDeactivateReactivateReconcilesOwnedInFlightAsUnknown() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        await client.setSuspendDecision(true)
        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: requestUUID.uuidString
        ))))
        let coordinator = makeCoordinator(store: store, client: client)
        await coordinator.activate()
        let prepared = try coordinator.prepare(makeInput())

        let analysis = Task { @MainActor in
            try await coordinator.analyzePrepared(
                prepared,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
        }
        await client.waitUntilDecisionWaitStarted()
        coordinator.deactivate()
        await coordinator.activate()
        let recovered = coordinator.status(
            for: target,
            currentInputFingerprint: fingerprint,
            currentProjectCandidateID: "project-1"
        )
        XCTAssertEqual(recovered?.state, .deliveryUnknown)

        await client.resumeDecisionWait()
        do {
            _ = try await analysis.value
            XCTFail("A result after lifecycle ownership ended must be discarded")
        } catch let error as ManagedConversationInsightCoordinatorError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let durable = await store.currentRecord()
        XCTAssertEqual(durable?.state, .deliveryUnknown)
    }

    func testCompletedInsightBecomesStaleForNewInputOrProjectAssignment() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: requestUUID.uuidString
        ))))
        let coordinator = makeCoordinator(store: store, client: client)
        await coordinator.activate()
        let prepared = try coordinator.prepare(makeInput())
        _ = try await coordinator.analyzePrepared(
            prepared,
            endpoint: endpoint,
            brainWorkingDirectory: "/tmp/brain-work"
        )

        let fresh = try XCTUnwrap(coordinator.status(
            for: target,
            currentInputFingerprint: fingerprint,
            currentProjectCandidateID: "project-1"
        ))
        XCTAssertTrue(fresh.isApplicable)

        let reassigned = try XCTUnwrap(coordinator.status(
            for: target,
            currentInputFingerprint: fingerprint,
            currentProjectCandidateID: "project-2"
        ))
        XCTAssertFalse(reassigned.summaryIsStale)
        XCTAssertTrue(reassigned.relevanceIsStale)
        XCTAssertFalse(reassigned.isApplicable)

        let refreshed = try XCTUnwrap(coordinator.status(
            for: target,
            currentInputFingerprint: "sha256:new",
            currentProjectCandidateID: "project-1"
        ))
        XCTAssertTrue(refreshed.summaryIsStale)
        XCTAssertTrue(refreshed.relevanceIsStale)
        XCTAssertFalse(refreshed.isApplicable)
    }

    func testFailedRefreshRetainsOldInsightButCannotApplyIt() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: requestUUID.uuidString
        ))))
        let coordinator = makeCoordinator(store: store, client: client)
        await coordinator.activate()
        let firstPrepared = try coordinator.prepare(makeInput())
        let completed = try await coordinator.analyzePrepared(
            firstPrepared,
            endpoint: endpoint,
            brainWorkingDirectory: "/tmp/brain-work"
        )

        var invalid = responseObject(
            requestID: secondRequestUUID.uuidString,
            fingerprint: "sha256:new"
        )
        invalid["action"] = "dispatch"
        await client.setResult(.proposalJSON(try data(invalid)))
        let refreshedPrepared = try coordinator.prepare(
            makeInput(fingerprint: "sha256:new")
        )
        do {
            _ = try await coordinator.analyzePrepared(
                refreshedPrepared,
                endpoint: endpoint,
                brainWorkingDirectory: "/tmp/brain-work"
            )
            XCTFail("Unknown output fields must fail closed")
        } catch let error as ManagedConversationInsightCoordinatorError {
            guard case .invalidInsight = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let failed = try XCTUnwrap(coordinator.status(
            for: target,
            currentInputFingerprint: "sha256:new",
            currentProjectCandidateID: "project-1"
        ))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.latestInsight, completed)
        XCTAssertTrue(failed.isStale)
        XCTAssertFalse(failed.isApplicable)
    }

    func testEachAnalysisUsesANewEphemeralSession() async throws {
        let store = RecordingInsightStore()
        let client = FakeConversationInsightClient()
        let coordinator = makeCoordinator(store: store, client: client)
        await coordinator.activate()

        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: requestUUID.uuidString
        ))))
        let firstPrepared = try coordinator.prepare(makeInput())
        _ = try await coordinator.analyzePrepared(
            firstPrepared,
            endpoint: endpoint,
            brainWorkingDirectory: "/tmp/brain-work"
        )
        await client.setResult(.proposalJSON(try data(responseObject(
            requestID: secondRequestUUID.uuidString
        ))))
        let secondPrepared = try coordinator.prepare(makeInput())
        _ = try await coordinator.analyzePrepared(
            secondPrepared,
            endpoint: endpoint,
            brainWorkingDirectory: "/tmp/brain-work"
        )

        let sessions = await client.sessionRequests()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertNotEqual(sessions[0].sessionID, sessions[1].sessionID)
        XCTAssertEqual(
            sessions[1].sessionID,
            ManagedConversationInsightPolicy.ephemeralSessionID(
                for: target,
                generationID: secondGenerationUUID
            )
        )
    }

    private let target = ManagedConversationInsightTarget(
        provider: "codex",
        sourceScope: "home-1",
        sourceID: "thread-1"
    )
    private let endpoint = DshRuntimeEndpoint(
        homeID: DshMetaAgentPolicy.dedicatedHomeID,
        profile: DshMetaAgentPolicy.dedicatedProfile,
        port: 54_720
    )
    private let fingerprint = "sha256:input-1"
    private let generationUUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let requestUUID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let rpcUUID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let cancelUUID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    private let secondGenerationUUID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
    private let secondRequestUUID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    private let secondRPCUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func makeInput(
        fingerprint: String = "sha256:input-1",
        includeUnknownAndExcludedManager: Bool = false
    ) -> ManagedConversationInsightInput {
        var messages = [
            ManagedConversationUserInput(
                id: "input-1",
                sequence: 1,
                turnID: "turn-1",
                timestamp: nil,
                text: "Build the conversation manager. RAW_SENTENCE_NEVER_ON_WIRE_Z9 Authorization: Bearer top-secret /Users/alice/private",
                originalCharacterCount: 120,
                truncated: false,
                source: .human
            ),
            ManagedConversationUserInput(
                id: "input-2",
                sequence: 2,
                turnID: "turn-2",
                timestamp: nil,
                text: "Keep the existing privacy and security boundaries.",
                originalCharacterCount: 51,
                truncated: false,
                source: .human
            ),
        ]
        if includeUnknownAndExcludedManager {
            messages.append(ManagedConversationUserInput(
                id: "unknown-1",
                sequence: 3,
                turnID: nil,
                timestamp: nil,
                text: "UNKNOWN_SOURCE_SECRET_PHRASE_Q7 summarize project relevance",
                originalCharacterCount: 58,
                truncated: true,
                source: .unknown
            ))
            messages.append(ManagedConversationUserInput(
                id: "manager-1",
                sequence: 4,
                turnID: nil,
                timestamp: nil,
                text: "MANAGER_COMMAND_MUST_BE_EXCLUDED_X3 execute everything",
                originalCharacterCount: 53,
                truncated: false,
                source: .manager
            ))
        }
        return ManagedConversationInsightInput(
            target: target,
            messages: messages,
            inputFingerprint: fingerprint,
            totalUserMessageCount: includeUnknownAndExcludedManager ? 3 : 2,
            currentProjectCandidateID: "project-1",
            candidates: [
                ManagedConversationProjectCandidate(
                    candidateID: "project-1",
                    label: "PRIVATE_PROJECT_LABEL_P8 Manager",
                    taskTitles: ["PRIVATE_TASK_TITLE_T4 Upgrade task panel"],
                    conversationTitles: [
                        "PRIVATE_CONVERSATION_TITLE_C2 Conversation manager",
                    ]
                ),
                ManagedConversationProjectCandidate(
                    candidateID: "project-2",
                    label: "Unrelated",
                    taskTitles: ["Other task"],
                    conversationTitles: []
                ),
            ]
        )
    }

    private func responseObject(
        requestID: String,
        fingerprint: String = "sha256:input-1"
    ) -> [String: Any] {
        [
            "schema": ManagedConversationInsightSchemaV1.identifier,
            "requestID": requestID,
            "inputFingerprint": fingerprint,
            "currentProjectCandidateID": "project-1",
            "summary": [
                "coreGoal": "Manage the conversation requirements",
                "mainTasks": ["Summarize requirements", "Score relevance"],
                "constraints": ["Do not execute tasks"],
                "openQuestions": [],
            ],
            "relevance": [
                "currentScore": 92,
                "reason": "The aggregate facts match this project.",
                "recommendedCandidateID": NSNull(),
                "recommendedScore": NSNull(),
                "confidence": 0.95,
            ],
        ]
    }

    private func decode(response: [String: Any]) throws
        -> ManagedConversationInsightV1 {
        try ManagedConversationInsightWireDecoderV1.decode(
            data(response),
            requestID: requestUUID.uuidString,
            inputFingerprint: fingerprint,
            currentProjectCandidateID: "project-1",
            candidateIDs: ["project-1", "project-2"],
            analyzedInputCount: 2,
            totalInputCount: 2,
            generatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func verifiedAvailability()
        -> ManagedConversationInsightSecurityAvailability {
        .verified(ManagedConversationInsightCapabilityAttestation(
            endpoint: endpoint,
            presetID: ManagedConversationInsightPolicy.requiredPresetID,
            catalogRevision: "sha256:verified-composition",
            toolIdentifiers: [],
            allowsCommandExecution: false,
            allowsFileMutation: false,
            allowsNetwork: false,
            allowsMCP: false
        ))
    }

    private func makeCoordinator(
        store: RecordingInsightStore,
        client: FakeConversationInsightClient,
        verifier: FakeInsightCapabilityVerifier? = nil
    ) -> ManagedConversationInsightCoordinator {
        let uuids = UUIDSequence([
            generationUUID, requestUUID, rpcUUID,
            secondGenerationUUID, secondRequestUUID, secondRPCUUID,
            cancelUUID,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        ])
        return ManagedConversationInsightCoordinator(
            store: store,
            dshClient: client,
            capabilityVerifier: verifier
                ?? FakeInsightCapabilityVerifier([verifiedAvailability()]),
            makeUUID: { uuids.next() },
            now: { Date(timeIntervalSince1970: 10) }
        )
    }

    private func makeRecord(
        state: ManagedConversationInsightDeliveryState
    ) -> ManagedConversationInsightStoreRecordV1 {
        ManagedConversationInsightStoreRecordV1(
            target: target,
            generationID: generationUUID,
            revision: 1,
            intent: .analyze,
            requestID: requestUUID.uuidString,
            inputFingerprint: fingerprint,
            totalInputCount: 2,
            analyzedInputCount: 2,
            omittedInputCount: 0,
            state: state,
            sessionID: ManagedConversationInsightPolicy.ephemeralSessionID(
                for: target,
                generationID: generationUUID
            ),
            rpcID: rpcUUID.uuidString,
            analyzedCurrentProjectCandidateID: nil,
            latestInsight: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            lastError: nil
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

}

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UUID]
    private var index = 0

    init(_ values: [UUID]) { self.values = values }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard index < values.count else {
            XCTFail("UUID sequence exhausted")
            return UUID()
        }
        defer { index += 1 }
        return values[index]
    }
}

private actor FakeInsightCapabilityVerifier:
    ManagedConversationInsightCapabilityVerifying {
    private let values: [ManagedConversationInsightSecurityAvailability]
    private var calls = 0

    init(_ values: [ManagedConversationInsightSecurityAvailability]) {
        self.values = values
    }

    func verify(
        endpoint: DshRuntimeEndpoint,
        presetID: String
    ) async -> ManagedConversationInsightSecurityAvailability {
        defer { calls += 1 }
        guard !values.isEmpty else {
            return .unavailable("not configured")
        }
        return values[min(calls, values.count - 1)]
    }

    func callCount() -> Int { calls }
}

private actor SuspendingInsightCapabilityVerifier:
    ManagedConversationInsightCapabilityVerifying {
    private let availability: ManagedConversationInsightSecurityAvailability
    private var calls = 0
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWaiter: CheckedContinuation<Void, Never>?

    init(availability: ManagedConversationInsightSecurityAvailability) {
        self.availability = availability
    }

    func verify(
        endpoint: DshRuntimeEndpoint,
        presetID: String
    ) async -> ManagedConversationInsightSecurityAvailability {
        calls += 1
        if calls == 1 {
            firstStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstWaiter = continuation
            }
        }
        return availability
    }

    func waitUntilFirstVerificationStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeFirstVerification() {
        firstWaiter?.resume()
        firstWaiter = nil
    }
}

private enum RecordingInsightStoreFailure: Error {
    case injected
}

private actor RecordingInsightStore: ManagedConversationInsightStoringV1 {
    private var envelope: ManagedConversationInsightStoreEnvelopeV1
    private var writes: [ManagedConversationInsightStoreRecordV1] = []
    private var casCalls = 0
    private let failCASFromCall: Int?

    init(
        record: ManagedConversationInsightStoreRecordV1? = nil,
        failCASFromCall: Int? = nil
    ) {
        envelope = ManagedConversationInsightStoreEnvelopeV1(
            records: record.map { [$0] } ?? []
        )
        self.failCASFromCall = failCASFromCall
    }

    func load() throws -> ManagedConversationInsightStoreEnvelopeV1 { envelope }

    func save(_ envelope: ManagedConversationInsightStoreEnvelopeV1) throws {
        self.envelope = envelope
    }

    func record(for target: ManagedConversationInsightTarget) throws
        -> ManagedConversationInsightStoreRecordV1? {
        envelope.record(for: target)
    }

    func upsert(_ record: ManagedConversationInsightStoreRecordV1) throws {
        envelope.upsert(record)
        envelope.savedAt = record.updatedAt
        writes.append(record)
    }

    func upsert(
        _ record: ManagedConversationInsightStoreRecordV1,
        expectedRevision: Int?
    ) throws {
        casCalls += 1
        if let failCASFromCall, casCalls >= failCASFromCall {
            throw RecordingInsightStoreFailure.injected
        }
        let actual = envelope.record(for: record.target)?.revision
        guard actual == expectedRevision else {
            throw ManagedConversationInsightStoreErrorV1.staleRevision(
                expected: expectedRevision,
                actual: actual
            )
        }
        guard record.revision == (actual ?? 0) + 1 else {
            throw ManagedConversationInsightStoreErrorV1.invalidRevision(
                expected: (actual ?? 0) + 1,
                actual: record.revision
            )
        }
        try upsert(record)
    }

    func currentRecord() -> ManagedConversationInsightStoreRecordV1? {
        envelope.records.first
    }

    func history() -> [ManagedConversationInsightStoreRecordV1] { writes }
}

private actor FakeConversationInsightClient: DshMetaAgentDecisionClient {
    private var result: DshMetaAgentDecisionResult = .failed("not-configured")
    private var prompts: [DshMetaAgentPromptRequest] = []
    private var sessions: [DshMetaAgentSessionRequest] = []
    private var cancellations: [(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        rpcID: String
    )] = []
    private var suspendDecision = false
    private var decisionWaitStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var decisionWaiters: [
        CheckedContinuation<DshMetaAgentDecisionResult, Never>
    ] = []
    private let cancelProbe: (@Sendable () async -> Bool)?
    private var durableCancelObserved = false

    init(cancelProbe: (@Sendable () async -> Bool)? = nil) {
        self.cancelProbe = cancelProbe
    }

    func setResult(_ result: DshMetaAgentDecisionResult) { self.result = result }
    func setSuspendDecision(_ value: Bool) { suspendDecision = value }

    func prepareSession(_ request: DshMetaAgentSessionRequest) async throws {
        sessions.append(request)
    }

    func queuePrompt(_ request: DshMetaAgentPromptRequest) async throws -> Bool {
        prompts.append(request)
        return true
    }

    func waitForDecision(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        promptRPCID: String
    ) async throws -> DshMetaAgentDecisionResult {
        if suspendDecision {
            decisionWaitStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return await withCheckedContinuation { continuation in
                decisionWaiters.append(continuation)
            }
        }
        return result
    }

    func cancelSession(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        rpcID: String
    ) async throws -> Bool {
        if let cancelProbe { durableCancelObserved = await cancelProbe() }
        cancellations.append((endpoint, sessionID, rpcID))
        return true
    }

    func waitUntilDecisionWaitStarted() async {
        if decisionWaitStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeDecisionWait() {
        suspendDecision = false
        let waiters = decisionWaiters
        decisionWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }

    func promptRequests() -> [DshMetaAgentPromptRequest] { prompts }
    func sessionRequests() -> [DshMetaAgentSessionRequest] { sessions }
    func cancellationRequests() -> [(
        endpoint: DshRuntimeEndpoint,
        sessionID: String,
        rpcID: String
    )] { cancellations }
    func cancelObservedDurableIntent() -> Bool { durableCancelObserved }
}
