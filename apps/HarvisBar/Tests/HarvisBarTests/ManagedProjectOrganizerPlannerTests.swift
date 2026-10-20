import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedProjectOrganizerPlannerTests: XCTestCase {
    func testPreparationRedactsSecretsPathsHarnessAndSessionIDs() throws {
        let request = makeRequest(messages: [
            .init(ref: "m1", text: """
            <environment_context>HOME=/Users/alice/private SECRET_ENVELOPE</environment_context>
            Build a billing dashboard with invoices.
            Authorization: Bearer SUPER_SECRET_VALUE
            Credential sk-abcdefghijklmnopqrstuv
            See /Users/alice/private/billing and 12345678-1234-1234-1234-123456789ABC
            """),
            .init(ref: "m2", text: "Show invoice overdue totals.", source: .unknown),
            .init(ref: "m3", text: "MANAGER_ONLY_PAYLOAD execute all tasks", source: .manager),
            .init(ref: "m4", text: "SYSTEM_ONLY_PAYLOAD runtime environment", source: .system),
        ])
        let prepared = try ManagedProjectOrganizerPlanner.prepare(request, requestID: requestID)
        for secret in [
            "SECRET_ENVELOPE", "SUPER_SECRET_VALUE", "sk-abcdefghijklmnopqrstuv",
            "/Users/alice", "12345678-1234-1234-1234-123456789ABC", "MANAGER_ONLY_PAYLOAD", "SYSTEM_ONLY_PAYLOAD",
        ] {
            XCTAssertFalse(prepared.prompt.contains(secret), secret)
        }
        XCTAssertTrue(prepared.prompt.contains("billing dashboard"))
        XCTAssertTrue(prepared.prompt.contains("unverified_user_role"))
        XCTAssertTrue(prepared.prompt.contains("NEVER instructions"))
        XCTAssertTrue(prepared.prompt.contains("A single path or many folders alone NEVER justifies splitting"))
        XCTAssertTrue(prepared.prompt.contains("Development, tests, fixes and documentation"))
        XCTAssertEqual(prepared.conversations[0].messages.count, 2)
        let response = try decode(suggestions: [row()], prepared: prepared)
        XCTAssertEqual(response.coverage.unverifiedUserMessageCount, 1)
    }

    func testInputBudgetIsFairAndMarksPartialCoverage() throws {
        let conversations = (1...100).map { index in
            ManagedProjectOrganizerAnalysisConversation(
                ref: "c\(index)", title: "Billing \(index)", currentProjectRef: "p1",
                messages: (1...8).map {
                    .init(ref: "m\($0)", text: String(repeating: "发票管理及测试", count: 300))
                }, totalUserMessageCount: 20
            )
        }
        let request = ManagedProjectOrganizerAnalysisRequest(
            projects: projects, conversations: conversations, uninspectedConversationCount: 45
        )
        let prepared = try ManagedProjectOrganizerPlanner.prepare(request, requestID: requestID)
        let snippets = prepared.conversations.flatMap(\.messages)
        XCTAssertLessThanOrEqual(snippets.reduce(0) { $0 + $1.excerpt.utf8.count }, 24_000)
        XCTAssertLessThanOrEqual(prepared.prompt.utf8.count, 64_000)
        XCTAssertTrue(prepared.conversations.allSatisfy { !$0.messages.isEmpty })
        XCTAssertTrue(snippets.allSatisfy(\.truncated))
        XCTAssertTrue(prepared.conversations.allSatisfy { $0.omittedUserMessageCount == 17 })
        XCTAssertEqual(prepared.conversations.first?.messages.map(\.ref), ["m1", "m7", "m8"])
        let response = try decode(suggestions: [], prepared: prepared)
        XCTAssertEqual(response.coverage.selectedConversationCount, 100)
        XCTAssertEqual(response.coverage.uninspectedConversationCount, 45)
        XCTAssertEqual(response.coverage.totalUserMessageCount, 2_000)
        XCTAssertEqual(response.coverage.sentUserMessageCount, 300)
        XCTAssertEqual(response.coverage.modelOmittedConversationCount, 100)
        XCTAssertEqual(response.coverage.conservativeTokenUpperBound, prepared.prompt.utf8.count)
    }

    func testQuotedMultilineAndEnvironmentCredentialValuesNeverBecomeSnippets() {
        let values = [
            #"{"token":"json opaque secret","api_key":"json api secret"}"#,
            "\"accessToken\":\n  \"multiline token secret\"",
            "\"AWS_SECRET_ACCESS_KEY\": \"aws credential secret\"",
            "password = 'a password with spaces'",
            "token is this-is-a-secret-value",
            "密码: chinese-secret-value",
            "\"client_secret\": \"unterminated sensitive value",
            #"See \\private-server\credentials\account.json"#,
        ]
        for value in values {
            let redacted = ManagedProjectOrganizerAnalysisRedactor.redact(value)
            for forbidden in [
                "json opaque secret", "json api secret", "multiline token secret",
                "aws credential secret", "a password with spaces", "this-is-a-secret-value",
                "chinese-secret-value", "unterminated sensitive value", "private-server",
            ] {
                XCTAssertFalse(redacted.contains(forbidden), forbidden)
            }
        }
        let acrossCap = String(repeating: "a ", count: 5_995) + "sk-abcdefghijklmnopqrstuv"
        XCTAssertFalse(ManagedProjectOrganizerAnalysisRedactor.redact(acrossCap).contains("sk-"))
    }

    func testRejectsRawIdentitiesDuplicateReferencesAndParentCycles() throws {
        let valid = makeRequest()
        let badConversation = ManagedProjectOrganizerAnalysisConversation(
            ref: "12345678-1234-1234-1234-123456789abc", title: "Billing",
            currentProjectRef: "p1", messages: [.init(ref: "m1", text: "Billing")],
            totalUserMessageCount: 1
        )
        for request in [
            ManagedProjectOrganizerAnalysisRequest(projects: projects, conversations: [badConversation]),
            ManagedProjectOrganizerAnalysisRequest(projects: projects, conversations: valid.conversations + valid.conversations),
            ManagedProjectOrganizerAnalysisRequest(projects: [
                .init(ref: "p1", name: "One", parentRef: "p2"),
                .init(ref: "p2", name: "Two", parentRef: "p1"),
            ], conversations: valid.conversations),
        ] {
            XCTAssertThrowsError(try ManagedProjectOrganizerPlanner.prepare(request, requestID: requestID))
        }
    }

    func testNoEvidenceIsExcludedFromModelAndLocallyKept() throws {
        let empty = ManagedProjectOrganizerAnalysisConversation(
            ref: "c2", title: "Unknown", currentProjectRef: "p1",
            messages: [], totalUserMessageCount: 0
        )
        let prepared = try ManagedProjectOrganizerPlanner.prepare(
            .init(projects: projects, conversations: makeRequest().conversations + [empty]),
            requestID: requestID
        )
        XCTAssertFalse(prepared.prompt.contains("\"ref\":\"c2\""))
        let response = try decode(suggestions: [row()], prepared: prepared)
        XCTAssertEqual(response.suggestions.count, 2)
        XCTAssertEqual(response.suggestions[1].action, .keep)
        XCTAssertTrue(response.suggestions[1].modelOmitted)
        XCTAssertTrue(response.suggestions[1].reason.contains("没有可分析"))
        XCTAssertEqual(response.coverage.conversationsWithEvidenceCount, 1)
        XCTAssertEqual(response.coverage.modelOmittedConversationCount, 0)
        XCTAssertThrowsError(try ManagedProjectOrganizerPlanner.prepare(
            .init(projects: projects, conversations: [empty]), requestID: requestID
        ))
    }

    func testValidMoveAndNewChildUseOnlyKnownReferences() throws {
        let prepared = try ManagedProjectOrganizerPlanner.prepare(makeRequest(), requestID: requestID)
        var move = row(action: "move")
        move["targetProjectRef"] = "p2"
        let response = try decode(suggestions: [move], prepared: prepared)
        XCTAssertEqual(response.suggestions[0].targetProjectRef, "p2")
        XCTAssertEqual(response.suggestions[0].evidence[0].excerpt, "Build invoice tracking.")
        XCTAssertEqual(response.suggestions[0].evidence[0].source, .human)

        var childRow = row(action: "new_child")
        childRow["targetChildRef"] = "n1"
        let child = try decode(suggestions: [childRow], children: [childObject()], prepared: prepared)
        XCTAssertEqual(child.children[0].parentProjectRef, "p1")
        XCTAssertEqual(child.children[0].pathProjectRef, "p1")
        XCTAssertEqual(child.suggestions[0].targetChildRef, "n1")
    }

    func testEvidenceMustBeFromThatConversationsSentMessagesAndCannotContainQuote() throws {
        let request = ManagedProjectOrganizerAnalysisRequest(
            projects: projects,
            conversations: makeRequest().conversations + [
                .init(ref: "c2", title: "Other", currentProjectRef: "p2",
                      messages: [.init(ref: "m2", text: "Different project")], totalUserMessageCount: 1),
            ]
        )
        let prepared = try ManagedProjectOrganizerPlanner.prepare(request, requestID: requestID)
        var wrongEvidence = row()
        wrongEvidence["evidenceMessageRefs"] = ["m2"]
        XCTAssertThrowsError(try decode(suggestions: [wrongEvidence], prepared: prepared))
        var fabricatedQuote = row()
        fabricatedQuote["quote"] = "Fabricated model quote"
        XCTAssertThrowsError(try decode(suggestions: [fabricatedQuote], prepared: prepared))
        var duplicateEvidence = row()
        duplicateEvidence["evidenceMessageRefs"] = ["m1", "m1"]
        XCTAssertThrowsError(try decode(suggestions: [duplicateEvidence], prepared: prepared))
    }

    func testRejectsUnknownDuplicateAndExecutableFields() throws {
        let prepared = try ManagedProjectOrganizerPlanner.prepare(makeRequest(), requestID: requestID)
        var unknown = row()
        unknown["conversationRef"] = "c999"
        var extra = row()
        extra["command"] = "mkdir /tmp/example"
        var sameProject = row(action: "move")
        sameProject["targetProjectRef"] = "p1"
        var lowConfidence = row(action: "move")
        lowConfidence["targetProjectRef"] = "p2"
        lowConfidence["confidence"] = 0.2
        var emptyEvidence = row(action: "move")
        emptyEvidence["targetProjectRef"] = "p2"
        emptyEvidence["evidenceMessageRefs"] = []
        for rows in [[unknown], [extra], [row(), row()], [sameProject], [lowConfidence], [emptyEvidence]] {
            XCTAssertThrowsError(try decode(suggestions: rows, prepared: prepared))
        }
        XCTAssertThrowsError(try decode(suggestions: [row()], prepared: prepared, overrideRequestID: "old-request"))
    }

    func testStrictJSONRejectsDuplicateKeysIncludingEscapedAliases() throws {
        let prepared = try ManagedProjectOrganizerPlanner.prepare(makeRequest(), requestID: requestID)
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": ManagedProjectOrganizerAnalysisLimits.schema, "requestID": requestID,
            "children": [], "suggestions": [row()],
        ])
        let json = String(decoding: data, as: UTF8.self)
        for duplicate in [#""action":"keep","action":"keep""#, #""action":"keep","\u0061ction":"keep""#] {
            let ambiguous = json.replacingOccurrences(of: #""action":"keep""#, with: duplicate)
            XCTAssertNotEqual(ambiguous, json)
            XCTAssertThrowsError(try ManagedProjectOrganizerPlanner.decode(
                Data(ambiguous.utf8), prepared: prepared, generatedAt: Date()
            ))
        }
    }

    func testRejectsChildCycleArbitraryPathsAndUnreferencedChildren() throws {
        let prepared = try ManagedProjectOrganizerPlanner.prepare(makeRequest(), requestID: requestID)
        var newRow = row(action: "new_child")
        newRow["targetChildRef"] = "n1"
        var cyclic = childObject()
        cyclic["parentProjectRef"] = "n1"
        var path = childObject()
        path["pathProjectRef"] = "/tmp/new-project"
        var withPath = childObject()
        withPath["path"] = "/tmp/new-project"
        for child in [cyclic, path, withPath] {
            XCTAssertThrowsError(try decode(suggestions: [newRow], children: [child], prepared: prepared))
        }
        XCTAssertThrowsError(try decode(suggestions: [row()], children: [childObject()], prepared: prepared))
        XCTAssertThrowsError(try decode(suggestions: [newRow], children: [childObject(), childObject()], prepared: prepared))
    }

    func testAnalysisUsesFreshSessionQueueModeAndTwoExactAttestations() async throws {
        let client = OrganizerTestClient()
        let verifier = OrganizerTestVerifier([availability()])
        let planner = ManagedProjectOrganizerPlanner(dshClient: client, capabilityVerifier: verifier)
        let first = try await planner.analyze(makeRequest(), endpoint: endpoint, brainWorkingDirectory: "/tmp/brain")
        let second = try await planner.analyze(makeRequest(), endpoint: endpoint, brainWorkingDirectory: "/tmp/brain")
        let sessions = await client.sessionRequests()
        let prompts = await client.promptRequests()
        let verificationCount = await verifier.callCount()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertNotEqual(sessions[0].sessionID, sessions[1].sessionID)
        XCTAssertNotEqual(first.requestID, second.requestID)
        XCTAssertEqual(verificationCount, 4)
        XCTAssertEqual(prompts.map(\.mode), [.queue, .queue])
        XCTAssertTrue(sessions.allSatisfy { $0.presetID == DshMetaAgentPolicy.requiredPresetID })
        XCTAssertEqual(first.suggestions[0].action, .keep)
        let cancellations = await client.cancelledSessionIDs()
        XCTAssertTrue(cancellations.isEmpty)
    }

    func testSecurityUnavailablePreventsSessionAndPromptMutation() async {
        let client = OrganizerTestClient()
        let planner = ManagedProjectOrganizerPlanner(
            dshClient: client, capabilityVerifier: OrganizerTestVerifier([.unavailable("No exact attestation")])
        )
        do {
            _ = try await planner.analyze(makeRequest(), endpoint: endpoint, brainWorkingDirectory: "/tmp/brain")
            XCTFail("Unavailable security must fail closed")
        } catch let error as ManagedProjectOrganizerAnalysisError {
            guard case .securityUnavailable = error else { return XCTFail("Unexpected \(error)") }
        } catch { XCTFail("Unexpected \(error)") }
        let sessions = await client.sessionRequests()
        let prompts = await client.promptRequests()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(prompts.isEmpty)
    }

    func testChangedOrToolEnabledAttestationPreventsPrompt() async {
        for second in [availability(revision: "changed"), availability(allowsTools: true)] {
            let client = OrganizerTestClient()
            let planner = ManagedProjectOrganizerPlanner(
                dshClient: client, capabilityVerifier: OrganizerTestVerifier([availability(), second])
            )
            do {
                _ = try await planner.analyze(makeRequest(), endpoint: endpoint, brainWorkingDirectory: "/tmp/brain")
                XCTFail("Changed capability must fail closed")
            } catch let error as ManagedProjectOrganizerAnalysisError {
                guard case .securityUnavailable = error else { return XCTFail("Unexpected \(error)") }
            } catch { XCTFail("Unexpected \(error)") }
            let sessions = await client.sessionRequests()
            let prompts = await client.promptRequests()
            XCTAssertEqual(sessions.count, 1)
            XCTAssertTrue(prompts.isEmpty)
        }
    }

    func testUnknownDeliveryIsNeverReplayedOrReplacedWithLocalAIResult() async {
        for mode in [OrganizerTestClient.Mode.throwOnQueue, .unknownDecision, .failedDecision, .rejectQueue] {
            let client = OrganizerTestClient(mode: mode)
            let planner = ManagedProjectOrganizerPlanner(
                dshClient: client, capabilityVerifier: OrganizerTestVerifier([availability()])
            )
            do {
                _ = try await planner.analyze(makeRequest(), endpoint: endpoint, brainWorkingDirectory: "/tmp/brain")
                XCTFail("No synthetic success is allowed")
            } catch let error as ManagedProjectOrganizerAnalysisError {
                if mode == .failedDecision {
                    guard case .analysisFailed = error else { return XCTFail("Unexpected \(error)") }
                } else if mode == .rejectQueue {
                    XCTAssertEqual(error, .promptRejected)
                } else {
                    XCTAssertEqual(error, .deliveryUnknown)
                }
            } catch { XCTFail("Unexpected \(error)") }
            let prompts = await client.promptRequests()
            XCTAssertEqual(prompts.count, 1)
        }
    }

    func testCancellationOnlyCancelsTheOwnedFreshSession() async throws {
        let client = OrganizerTestClient(mode: .suspendDecision)
        let planner = ManagedProjectOrganizerPlanner(
            dshClient: client, capabilityVerifier: OrganizerTestVerifier([availability()])
        )
        let request = makeRequest()
        let testEndpoint = endpoint
        let task = Task {
            try await planner.analyze(request, endpoint: testEndpoint, brainWorkingDirectory: "/tmp/brain")
        }
        await client.waitUntilWaiting()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled result must never be published")
        } catch is CancellationError {
            // Expected, including when the gateway completes during cancellation.
        }
        let sessions = await client.sessionRequests()
        let cancellations = await client.cancelledSessionIDs()
        let prompts = await client.promptRequests()
        XCTAssertEqual(cancellations, [sessions[0].sessionID])
        XCTAssertEqual(prompts.count, 1)
    }

    func testAlreadyCancelledAnalysisDoesNotCreateOrCancelAnySession() async {
        let client = OrganizerTestClient()
        let verifier = OrganizerTestVerifier([availability()])
        let planner = ManagedProjectOrganizerPlanner(dshClient: client, capabilityVerifier: verifier)
        let request = makeRequest()
        let testEndpoint = endpoint
        let task = Task {
            try await planner.analyze(request, endpoint: testEndpoint, brainWorkingDirectory: "/tmp/brain")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled analysis must not start")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected \(error)") }
        let sessions = await client.sessionRequests()
        let cancellations = await client.cancelledSessionIDs()
        let count = await verifier.callCount()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertEqual(count, 0)
    }

    func testDedicatedEndpointAndExplicitBrainDirectoryAreRequired() async {
        let client = OrganizerTestClient()
        let verifier = OrganizerTestVerifier([availability()])
        let planner = ManagedProjectOrganizerPlanner(dshClient: client, capabilityVerifier: verifier)
        let other = DshRuntimeEndpoint(homeID: "other", profile: "web", port: 54_720)
        for (testEndpoint, directory) in [(other, "/tmp/brain"), (endpoint, "relative/brain")] {
            do {
                _ = try await planner.analyze(makeRequest(), endpoint: testEndpoint, brainWorkingDirectory: directory)
                XCTFail("Invalid gateway configuration must fail closed")
            } catch let error as ManagedProjectOrganizerAnalysisError {
                XCTAssertTrue(error == .endpointUnavailable || error == .invalidBrainWorkingDirectory)
            } catch { XCTFail("Unexpected \(error)") }
        }
        let sessions = await client.sessionRequests()
        let count = await verifier.callCount()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(count, 0)
    }

    /// Opt-in integration smoke: synthetic project names and user text only.
    /// It uses the production verifier unchanged and cannot install a preset,
    /// relax its tool policy, inspect user sessions, or mutate project bindings.
    func testLiveGatewayWithSyntheticInputOnly() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HARVIS_ORGANIZER_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Opt in with HARVIS_ORGANIZER_LIVE_SMOKE=1 and explicit brain endpoint settings.")
        }
        let portText = try XCTUnwrap(environment["HARVIS_ORGANIZER_BRAIN_PORT"])
        let port = try XCTUnwrap(Int(portText))
        let directory = try XCTUnwrap(environment["HARVIS_ORGANIZER_BRAIN_CWD"])
        let liveEndpoint = DshRuntimeEndpoint(
            homeID: DshMetaAgentPolicy.dedicatedHomeID,
            profile: DshMetaAgentPolicy.dedicatedProfile,
            port: port
        )
        let request = ManagedProjectOrganizerAnalysisRequest(
            projects: [
                .init(ref: "p1", name: "示例账单应用", purpose: "管理发票和账单。"),
                .init(ref: "p2", name: "示例天气应用", purpose: "显示天气预报。"),
            ],
            conversations: [
                .init(ref: "c1", title: "账单发票导出", currentProjectRef: "p1",
                      messages: [.init(ref: "m1", text: "为示例账单应用添加发票导出，并测试金额汇总。")],
                      totalUserMessageCount: 1),
            ]
        )
        let response = try await ManagedProjectOrganizerPlanner().analyze(
            request, endpoint: liveEndpoint, brainWorkingDirectory: directory
        )
        XCTAssertEqual(response.suggestions.map(\.conversationRef), ["c1"])
        XCTAssertFalse(response.suggestions[0].modelOmitted)
        XCTAssertEqual(response.coverage.modelOmittedConversationCount, 0)
        XCTAssertEqual(response.coverage.sentUserMessageCount, 1)
    }

    private let requestID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let endpoint = DshRuntimeEndpoint(
        homeID: DshMetaAgentPolicy.dedicatedHomeID,
        profile: DshMetaAgentPolicy.dedicatedProfile, port: 54_720
    )
    private var projects: [ManagedProjectOrganizerAnalysisProject] {
        [.init(ref: "p1", name: "Billing"), .init(ref: "p2", name: "Support")]
    }

    private func makeRequest(
        messages: [ManagedProjectOrganizerAnalysisMessage] = [.init(ref: "m1", text: "Build invoice tracking.")]
    ) -> ManagedProjectOrganizerAnalysisRequest {
        .init(projects: projects, conversations: [
            .init(ref: "c1", title: "Invoice tracking", currentProjectRef: "p1", messages: messages,
                  totalUserMessageCount: messages.filter { $0.source == .human || $0.source == .unknown }.count),
        ])
    }

    private func row(action: String = "keep") -> [String: Any] {
        ["conversationRef": "c1", "action": action,
         "targetProjectRef": NSNull(), "targetChildRef": NSNull(),
         "reason": "发票功能属于当前账务项目。", "confidence": 0.8,
         "evidenceMessageRefs": ["m1"]]
    }

    private func childObject() -> [String: Any] {
        ["ref": "n1", "name": "Invoices", "purpose": "Manage invoice tracking.",
         "parentProjectRef": "p1", "pathProjectRef": "p1"]
    }

    private func decode(
        suggestions: [[String: Any]], children: [[String: Any]] = [],
        prepared: ManagedProjectOrganizerPlanner.PreparedRequest,
        overrideRequestID: String? = nil
    ) throws -> ManagedProjectOrganizerAnalysisResponse {
        let object: [String: Any] = [
            "schema": ManagedProjectOrganizerAnalysisLimits.schema,
            "requestID": overrideRequestID ?? requestID,
            "children": children, "suggestions": suggestions,
        ]
        return try ManagedProjectOrganizerPlanner.decode(
            JSONSerialization.data(withJSONObject: object), prepared: prepared, generatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func availability(revision: String = "sha256:verified", allowsTools: Bool = false)
        -> ManagedConversationInsightSecurityAvailability {
        .verified(.init(endpoint: endpoint, presetID: DshMetaAgentPolicy.requiredPresetID,
                        catalogRevision: revision, toolIdentifiers: allowsTools ? ["exec"] : [],
                        allowsCommandExecution: allowsTools, allowsFileMutation: false,
                        allowsNetwork: false, allowsMCP: false))
    }
}

private actor OrganizerTestVerifier: ManagedConversationInsightCapabilityVerifying {
    let values: [ManagedConversationInsightSecurityAvailability]
    private var calls = 0

    init(_ values: [ManagedConversationInsightSecurityAvailability]) { self.values = values }

    func verify(endpoint: DshRuntimeEndpoint, presetID: String) async -> ManagedConversationInsightSecurityAvailability {
        defer { calls += 1 }
        return values[min(calls, values.count - 1)]
    }

    func callCount() -> Int { calls }
}

private actor OrganizerTestClient: DshMetaAgentDecisionClient {
    enum Mode: Equatable { case success, throwOnQueue, unknownDecision, failedDecision, rejectQueue, suspendDecision }
    enum Failure: Error { case transport }
    let mode: Mode
    private var sessions: [DshMetaAgentSessionRequest] = []
    private var prompts: [DshMetaAgentPromptRequest] = []
    private var cancellations: [String] = []
    private var waiting = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var decisionWaiter: CheckedContinuation<DshMetaAgentDecisionResult, Never>?

    init(mode: Mode = .success) { self.mode = mode }

    func prepareSession(_ request: DshMetaAgentSessionRequest) async throws { sessions.append(request) }

    func queuePrompt(_ request: DshMetaAgentPromptRequest) async throws -> Bool {
        prompts.append(request)
        if mode == .throwOnQueue { throw Failure.transport }
        return mode != .rejectQueue
    }

    func waitForDecision(endpoint: DshRuntimeEndpoint, sessionID: String, promptRPCID: String) async throws -> DshMetaAgentDecisionResult {
        if mode == .unknownDecision { return .deliveryUnknown("Lost gateway response") }
        if mode == .failedDecision { return .failed("Gateway unavailable") }
        if mode == .suspendDecision {
            waiting = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return await withCheckedContinuation { decisionWaiter = $0 }
        }
        let prompt = try XCTUnwrap(prompts.last?.text)
        let data = try XCTUnwrap(prompt.components(separatedBy: "INPUT_DATA:\n").last?.data(using: .utf8))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requestID = try XCTUnwrap(input["requestID"] as? String)
        return .proposalJSON(try JSONSerialization.data(withJSONObject: [
            "schema": ManagedProjectOrganizerAnalysisLimits.schema, "requestID": requestID,
            "children": [], "suggestions": [[
                "conversationRef": "c1", "action": "keep",
                "targetProjectRef": NSNull(), "targetChildRef": NSNull(),
                "reason": "当前项目目标一致。", "confidence": 0.8,
                "evidenceMessageRefs": ["m1"],
            ]],
        ]))
    }

    func cancelSession(endpoint: DshRuntimeEndpoint, sessionID: String, rpcID: String) async throws -> Bool {
        cancellations.append(sessionID)
        decisionWaiter?.resume(returning: .failed("Cancelled"))
        decisionWaiter = nil
        return true
    }

    func waitUntilWaiting() async {
        if waiting { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func sessionRequests() -> [DshMetaAgentSessionRequest] { sessions }
    func promptRequests() -> [DshMetaAgentPromptRequest] { prompts }
    func cancelledSessionIDs() -> [String] { cancellations }
}
