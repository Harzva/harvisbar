import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class DshGroupxReviewTests: XCTestCase {
    func testLiveGroupxBridgeWithSyntheticProposalOnly() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HARVIS_GROUPX_LIVE_SMOKE"] == "1",
              let portText = environment["HARVIS_GROUPX_LIVE_PORT"], let port = Int(portText) else {
            throw XCTSkip("Opt-in model call with synthetic project names only")
        }
        let homeID = environment["HARVIS_GROUPX_LIVE_HOME_ID"] ?? "dsh"
        let profile = environment["HARVIS_GROUPX_LIVE_PROFILE"] ?? "digital-me"
        let endpoint = DshRuntimeEndpoint(homeID: homeID, profile: profile, port: port)
        let catalog = try await DshCapabilityBridgeClient(endpoint: endpoint).describe()
        XCTAssertTrue(catalog.value.supports("groupx.review", operation: "start"))
        let name = "HarvisGroupxLiveSmoke.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = HarvisRuntimeModel(defaults: defaults)
        model.dshRunningEndpoints = [endpoint]
        model.dshBridgeStatesByScope = [endpoint.sourceScope: DshBridgeEndpointState(
            endpoint: endpoint, authority: catalog.authority, catalog: catalog.value, error: nil
        )]
        let proposal = fixtureProposal()
        model.projectOrganizerProposal = proposal
        model.startProjectGroupxReview()
        func saveReceipt() throws {
            guard let path = environment["HARVIS_GROUPX_LIVE_RECEIPT_PATH"],
                  let identity = model.projectGroupxReviewIdentity else { return }
            let receipt: [String: Any] = [
                "jobId": identity.jobID, "proposalRevision": identity.proposalRevision,
                "runtimeId": catalog.authority.runtimeID,
                "state": model.projectGroupxReviewJob?.state.rawValue ?? "not-confirmed",
                "modelCalls": model.projectGroupxReviewJob?.modelCalls ?? 0,
                "message": model.projectGroupxReviewMessage ?? "",
                "errorCode": model.projectGroupxReviewJob?.errorCode ?? "",
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: path), options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        try saveReceipt()
        await model.projectGroupxReviewTask?.value
        try saveReceipt()
        let job = try XCTUnwrap(model.projectGroupxReviewJob)
        XCTAssertEqual(job.state, .succeeded, job.errorCode ?? "no error code")
        XCTAssertGreaterThan(job.modelCalls, 0)
        XCTAssertLessThanOrEqual(job.modelCalls, 16)
        XCTAssertEqual(model.projectOrganizerProposal, proposal)
        XCTAssertEqual(model.managedProjectOrganization, .init())
    }

    func testPayloadExcludesPathsCredentialsIdentifiersAndPreservesBounds() throws {
        var proposal = fixtureProposal()
        proposal.suggestions[0].reason = "API_KEY=synthetic-private-value\nMove to a clearer project"
        proposal.suggestions[0].evidence = ["/Users/private/example/project", "Bearer synthetic-private-token"]
        proposal.suggestions = Array(repeating: proposal.suggestions[0], count: 100)
        let task = ManagedProjectGroupxReviewPayload.task(proposal, catalog: [])
        XCTAssertFalse(task.contains("synthetic-private-value"))
        XCTAssertFalse(task.contains("synthetic-private-token"))
        XCTAssertFalse(task.contains("/Users/private"))
        XCTAssertFalse(task.contains(proposal.id))
        XCTAssertLessThanOrEqual(task.unicodeScalars.count, 16_000)
        XCTAssertTrue(task.contains("reviewedSuggestions"))
        let start = DshGroupxReviewStart(jobID: UUID().uuidString, proposalRevision: DshGroupxReviewStart.revision(task), task: task)
        XCTAssertNoThrow(try start.validate())
        XCTAssertThrowsError(try DshGroupxReviewStart(jobID: start.jobID, proposalRevision: start.proposalRevision, task: task + "changed").validate())
    }

    func testAdvisoryNeverAppliesOrSelectsProposalAndShowsChangedVersion() async throws {
        let (model, defaults, name) = makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = GroupxFixtureTransport()
        model.makeDshBridgeClient = { DshCapabilityBridgeClient(endpoint: $0, transport: transport) }
        let proposal = fixtureProposal()
        model.projectOrganizerProposal = proposal
        model.startProjectGroupxReview()
        await model.projectGroupxReviewTask?.value
        XCTAssertEqual(model.projectGroupxReviewJob?.state, .succeeded)
        XCTAssertEqual(model.projectOrganizerProposal, proposal)
        XCTAssertEqual(model.managedProjectOrganization, .init())
        XCTAssertNil(defaults.object(forKey: ManagedProjectOrganizationStore.storageKey))
        XCTAssertFalse(model.projectGroupxReviewPresentation.isStale)
        XCTAssertFalse(model.projectGroupxReviewPresentation.canStart)
        model.startProjectGroupxReview()
        XCTAssertNil(model.projectGroupxReviewTask)
        model.projectOrganizerProposal?.suggestions[0].reason = "Changed by reviewer"
        XCTAssertTrue(model.projectGroupxReviewPresentation.isStale)
        let methods = await transport.methodSnapshot()
        XCTAssertEqual(methods, ["groupx.review.start"])
    }

    func testUncertainStartQueriesSameJobWithoutResubmitting() async throws {
        let (model, defaults, name) = makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = GroupxFixtureTransport(loseStart: true)
        model.makeDshBridgeClient = { DshCapabilityBridgeClient(endpoint: $0, transport: transport) }
        model.projectOrganizerProposal = fixtureProposal()
        model.startProjectGroupxReview()
        await model.projectGroupxReviewTask?.value
        XCTAssertNil(model.projectGroupxReviewJob)
        let identity = model.projectGroupxReviewIdentity
        model.startProjectGroupxReview()
        await model.projectGroupxReviewTask?.value
        XCTAssertEqual(model.projectGroupxReviewIdentity, identity)
        XCTAssertEqual(model.projectGroupxReviewJob?.state, .succeeded)
        let methods = await transport.methodSnapshot()
        XCTAssertEqual(methods, ["groupx.review.start", "groupx.review.status"])
    }

    func testTransientStatusFailureRetriesReadWithoutRestartingJob() async throws {
        let (model, defaults, name) = makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = GroupxFixtureTransport(loseFirstStatus: true)
        model.makeDshBridgeClient = { DshCapabilityBridgeClient(endpoint: $0, transport: transport) }
        model.projectOrganizerProposal = fixtureProposal()
        model.startProjectGroupxReview()
        await model.projectGroupxReviewTask?.value
        XCTAssertEqual(model.projectGroupxReviewJob?.state, .succeeded)
        let methods = await transport.methodSnapshot()
        XCTAssertEqual(methods, ["groupx.review.start", "groupx.review.status", "groupx.review.status"])
    }

    func testRestartAuthorityCannotPublishSuccess() async throws {
        let (model, defaults, name) = makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = GroupxFixtureTransport(runtimeID: "restarted")
        model.makeDshBridgeClient = { DshCapabilityBridgeClient(endpoint: $0, transport: transport) }
        model.projectOrganizerProposal = fixtureProposal()
        model.startProjectGroupxReview()
        await model.projectGroupxReviewTask?.value
        XCTAssertNil(model.projectGroupxReviewJob)
        XCTAssertNotNil(model.projectGroupxReviewMessage)
        XCTAssertEqual(model.managedProjectOrganization, .init())
    }

    func testUnknownReceiptOnlyQueriesOriginalIdentity() async throws {
        let (model, defaults, name) = makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = GroupxFixtureTransport(loseStart: true, state: "unknown")
        model.makeDshBridgeClient = { DshCapabilityBridgeClient(endpoint: $0, transport: transport) }
        model.projectOrganizerProposal = fixtureProposal()
        model.startProjectGroupxReview()
        await model.projectGroupxReviewTask?.value
        let identity = model.projectGroupxReviewIdentity
        for _ in 0..<2 {
            model.startProjectGroupxReview()
            await model.projectGroupxReviewTask?.value
        }
        XCTAssertEqual(model.projectGroupxReviewJob?.state, .unknown)
        XCTAssertEqual(model.projectGroupxReviewIdentity, identity)
        XCTAssertEqual(model.projectGroupxReviewPresentation.actionLabel, "查询状态")
        let methods = await transport.methodSnapshot()
        XCTAssertEqual(methods, ["groupx.review.start", "groupx.review.status", "groupx.review.status"])
    }

    func testMultipleReviewHostsRequireExplicitSelection() async throws {
        let (model, defaults, name) = makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = GroupxFixtureTransport()
        model.makeDshBridgeClient = { DshCapabilityBridgeClient(endpoint: $0, transport: transport) }
        let existing = try XCTUnwrap(model.dshBridgeStatesByScope.values.first)
        let other = DshRuntimeEndpoint(homeID: "other", profile: "other", port: 12346)
        model.dshRunningEndpoints.append(other)
        model.dshBridgeStatesByScope[other.sourceScope] = DshBridgeEndpointState(
            endpoint: other, authority: DshBridgeAuthority(homeID: "other", profile: "other", runtimeID: "other"),
            catalog: existing.catalog, error: nil
        )
        model.projectOrganizerProposal = fixtureProposal()
        XCTAssertFalse(model.projectGroupxReviewPresentation.canStart)
        model.startProjectGroupxReview()
        XCTAssertNil(model.projectGroupxReviewIdentity)
        model.selectProjectGroupxReviewHost(existing.endpoint.sourceScope)
        XCTAssertTrue(model.projectGroupxReviewPresentation.canStart)
        model.startProjectGroupxReview()
        await model.projectGroupxReviewTask?.value
        XCTAssertEqual(model.projectGroupxReviewEndpoint, existing.endpoint)
        XCTAssertEqual(model.projectGroupxReviewJob?.state, .succeeded)
    }

    func testCatalogNamesAndPurposesArePartOfLocalReviewFingerprint() {
        let proposal = fixtureProposal()
        var project = ManagedProjectRecord(id: "p1", name: "Invoices", purpose: "Track invoices")
        let first = ManagedProjectGroupxReviewPayload.contextFingerprint(proposal, catalog: [project])
        project.purpose = "Weather forecasts"
        XCTAssertNotEqual(first, ManagedProjectGroupxReviewPayload.contextFingerprint(proposal, catalog: [project]))
    }

    private func makeModel() -> (HarvisRuntimeModel, UserDefaults, String) {
        let name = "HarvisGroupxReviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let model = HarvisRuntimeModel(defaults: defaults)
        let endpoint = DshRuntimeEndpoint(homeID: "synthetic", profile: "review", port: 12345)
        model.dshRunningEndpoints = [endpoint]
        model.dshBridgeStatesByScope = [endpoint.sourceScope: DshBridgeEndpointState(
            endpoint: endpoint, authority: DshBridgeAuthority(homeID: "synthetic", profile: "review", runtimeID: "runtime"),
            catalog: DshCapabilityCatalog(schemaVersion: "harvis.dsh-capabilities.v1", bridgeVersion: "0.1.0", capabilities: [
                DshCapabilityDescriptor(id: "groupx.review", version: 1, title: "GroupX", scope: "project", operations: ["start", "status", "cancel"], availability: .available, reason: nil, requiresApproval: false, supportsCancel: true)
            ]), error: nil
        )]
        return (model, defaults, name)
    }

    private func fixtureProposal() -> ManagedProjectOrganizerProposal {
        ManagedProjectOrganizerProposal(baseStateRevision: 0, catalogFingerprint: "synthetic", snapshots: [], suggestions: [
            ManagedProjectOrganizerSuggestion(action: .createSubproject, conversationIDs: [], proposedProject: ManagedProjectRecord(name: "Invoices", purpose: "Track invoices"), reason: "Shared project goal")
        ])
    }
}

private actor GroupxFixtureTransport: DshHostTransport {
    let loseStart: Bool
    let runtimeID: String
    let state: String
    let loseFirstStatus: Bool
    var statusLost = false
    var methods: [String] = []
    init(loseStart: Bool = false, runtimeID: String = "runtime", state: String = "succeeded", loseFirstStatus: Bool = false) {
        self.loseStart = loseStart
        self.runtimeID = runtimeID
        self.state = state
        self.loseFirstStatus = loseFirstStatus
    }
    func methodSnapshot() -> [String] { methods }
    func send(_ request: URLRequest) async throws -> DshHostTransportResponse {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let method = try XCTUnwrap(body["method"] as? String)
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        methods.append(method)
        if loseStart && method == "groupx.review.start" { throw URLError(.networkConnectionLost) }
        if loseFirstStatus && method == "groupx.review.status" && !statusLost {
            statusLost = true
            throw URLError(.timedOut)
        }
        let value: [String: Any] = [
            "schemaVersion": "harvis.groupx-review-job.v1", "jobId": params["jobId"]!, "proposalRevision": params["proposalRevision"]!,
            "state": loseFirstStatus && method == "groupx.review.start" ? "running" : state,
            "summary": "Synthetic review: check the proposed goal.", "participantCount": 1, "modelCalls": 2, "maxModelCalls": 16,
        ]
        let reply: [String: Any] = ["schemaVersion": "harvis.dsh-bridge.v1", "requestId": body["requestId"]!,
            "authority": ["homeID": "synthetic", "profile": "review", "runtimeId": runtimeID], "result": ["ok": true, "value": value]]
        return DshHostTransportResponse(data: try JSONSerialization.data(withJSONObject: reply), statusCode: 200)
    }
}
