import Foundation
import XCTest
@testable import HarvisBar

final class ConversationManagementStoreTests: XCTestCase {
    func testAtomicStoreUsesPrivatePermissionsAndRoundTrips() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let envelope = ConversationManagementStoreEnvelopeV1(
            savedAt: date(1),
            snapshots: [makeSnapshot()],
            ledgers: [makeLedger()]
        )

        try await fixture.store.save(envelope)
        let reader = ConversationManagementStoreV1(storeURL: fixture.url)
        let loaded = try await reader.load()

        XCTAssertEqual(loaded, envelope)
        XCTAssertEqual(
            try permissions(at: fixture.url.deletingLastPathComponent())
                & 0o777,
            0o700
        )
        XCTAssertEqual(try permissions(at: fixture.url) & 0o777, 0o600)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            atPath: fixture.url.deletingLastPathComponent().path
        ).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testRestartConvertsIntermediateLedgerAndExtensionToDeliveryUnknown() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var ledger = makeLedger()
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-in-flight",
            expectedRevision: 0,
            at: date(1)
        )
        let snapshot = makeSnapshot(
            delivery: .dispatching,
            management: .dispatching
        )
        try await fixture.store.save(
            ConversationManagementStoreEnvelopeV1(
                savedAt: date(1),
                snapshots: [snapshot],
                ledgers: [ledger]
            )
        )

        let reader = ConversationManagementStoreV1(storeURL: fixture.url)
        let recovered = try await reader.load()
        let recoveredLedger = try XCTUnwrap(recovered.ledger(runID: ledger.runID))
        let recoveredSnapshot = try XCTUnwrap(
            recovered.snapshot(projectID: "project-1")
        )
        let extensionValue = try XCTUnwrap(
            recoveredSnapshot.conversations[0].managementExtension
        )

        XCTAssertEqual(recoveredLedger.currentState.delivery, .deliveryUnknown)
        XCTAssertEqual(recoveredLedger.currentState.management, .deliveryUnknown)
        XCTAssertEqual(recoveredLedger.entries.last?.kind, .recovered)
        XCTAssertTrue(
            recoveredLedger.entries.last?.note?.contains("not replayed") == true
        )
        XCTAssertEqual(extensionValue.delivery, .deliveryUnknown)
        XCTAssertEqual(extensionValue.management, .deliveryUnknown)
        XCTAssertEqual(extensionValue.revision, 1)
        XCTAssertEqual(recoveredSnapshot.revision, 1)

        let loadedAgain = try await reader.load()
        XCTAssertEqual(
            loadedAgain.ledger(runID: ledger.runID)?.revision,
            recoveredLedger.revision,
            "recovery must be idempotent and never synthesize a retry"
        )
        XCTAssertEqual(
            loadedAgain.snapshot(projectID: "project-1")?.revision,
            recoveredSnapshot.revision
        )
    }

    func testAwaitingPreviewSurvivesRestartBecauseNothingWasDelivered() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = makeSnapshot(
            delivery: .none,
            management: .awaitingPreview
        )
        try await fixture.store.save(
            ConversationManagementStoreEnvelopeV1(
                snapshots: [snapshot],
                ledgers: [makeLedger()]
            )
        )

        let reader = ConversationManagementStoreV1(storeURL: fixture.url)
        let loaded = try await reader.load()
        let extensionValue = try XCTUnwrap(
            loaded.snapshots[0].conversations[0].managementExtension
        )
        XCTAssertEqual(extensionValue.management, .awaitingPreview)
        XCTAssertEqual(extensionValue.delivery, .none)
        XCTAssertEqual(loaded.snapshots[0].revision, 0)
    }

    func testEnvelopeUpsertsRequireExactExpectedRevision() throws {
        var envelope = ConversationManagementStoreEnvelopeV1(
            snapshots: [makeSnapshot(revision: 2)],
            ledgers: [makeLedger()]
        )
        let replacement = makeSnapshot(revision: 3)
        try envelope.upsert(snapshot: replacement, expectedRevision: 2)
        XCTAssertEqual(envelope.snapshot(projectID: "project-1")?.revision, 3)

        XCTAssertThrowsError(
            try envelope.upsert(
                snapshot: makeSnapshot(revision: 4),
                expectedRevision: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationManagementSchemaErrorV1,
                .staleRevision(expected: 2, actual: 3)
            )
        }
    }

    func testActorUpsertIsOneReadCASWriteTransaction() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.store.upsert(
            snapshot: makeSnapshot(revision: 0),
            expectedRevision: nil
        )
        try await fixture.store.upsert(
            snapshot: makeSnapshot(revision: 1),
            expectedRevision: 0
        )
        let storedSnapshot = try await fixture.store.snapshot(
            projectID: "project-1"
        )
        XCTAssertEqual(storedSnapshot?.revision, 1)

        do {
            try await fixture.store.upsert(
                snapshot: makeSnapshot(revision: 2),
                expectedRevision: 0
            )
            XCTFail("Expected stale actor transaction to fail")
        } catch let error as ConversationManagementSchemaErrorV1 {
            XCTAssertEqual(error, .staleRevision(expected: 0, actual: 1))
        }

        var ledger = makeLedger()
        try await fixture.store.upsert(ledger: ledger, expectedRevision: nil)
        try ledger.startPlanning(
            metaSessionID: "meta-session",
            planningRPCID: "rpc-live",
            expectedRevision: 0
        )
        try await fixture.store.upsert(ledger: ledger, expectedRevision: 0)
        let storedLedger = try await fixture.store.ledger(runID: ledger.runID)
        XCTAssertEqual(storedLedger, ledger)
        XCTAssertEqual(storedLedger?.currentState.management, .planning)
        XCTAssertNotEqual(
            storedLedger?.currentState.delivery,
            .deliveryUnknown,
            "ordinary in-process reads must not masquerade as a restart"
        )
    }

    func testOrphanLedgerIsRejectedBeforeWriting() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            try await fixture.store.save(
                ConversationManagementStoreEnvelopeV1(
                    snapshots: [],
                    ledgers: [makeLedger()]
                )
            )
            XCTFail("Expected orphan ledger to fail")
        } catch let error as ConversationManagementStoreErrorV1 {
            XCTAssertEqual(
                error,
                .orphanLedger(
                    runID: makeLedger().runID,
                    projectID: "project-1"
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testLegacyV1StoreMigratesNewAuthorityFieldsFailClosed() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let currentData = try encoder.encode(
            ConversationManagementStoreEnvelopeV1(
                savedAt: date(1),
                snapshots: [makeSnapshot()],
                ledgers: [makeLedger()]
            )
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        var snapshots = try XCTUnwrap(root["snapshots"] as? [[String: Any]])
        var snapshot = try XCTUnwrap(snapshots.first)
        snapshot.removeValue(forKey: "brainEnabled")
        snapshot.removeValue(forKey: "taskPlan")
        var conversations = try XCTUnwrap(
            snapshot["conversations"] as? [[String: Any]]
        )
        var conversation = try XCTUnwrap(conversations.first)
        var base = try XCTUnwrap(conversation["base"] as? [String: Any])
        base.removeValue(forKey: "startedAt")
        conversation["base"] = base
        var extensionValue = try XCTUnwrap(
            conversation["managementExtension"] as? [String: Any]
        )
        extensionValue.removeValue(forKey: "workKind")
        extensionValue.removeValue(forKey: "taskBindings")
        conversation["managementExtension"] = extensionValue
        conversations[0] = conversation
        snapshot["conversations"] = conversations
        snapshots[0] = snapshot
        root["snapshots"] = snapshots

        try FileManager.default.createDirectory(
            at: fixture.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: root)
            .write(to: fixture.url)

        let reader = ConversationManagementStoreV1(storeURL: fixture.url)
        let migrated = try await reader.load()
        let migratedSnapshot = try XCTUnwrap(migrated.snapshots.first)
        let migratedRecord = try XCTUnwrap(migratedSnapshot.conversations.first)
        let migratedExtension = try XCTUnwrap(
            migratedRecord.managementExtension
        )

        XCTAssertFalse(migratedSnapshot.brainEnabled)
        XCTAssertEqual(migratedSnapshot.taskPlan, .unavailable)
        XCTAssertEqual(
            migratedRecord.base.startedAt,
            migratedRecord.base.observedAt
        )
        XCTAssertEqual(migratedExtension.workKind, .unclassified)
        XCTAssertTrue(migratedExtension.taskBindings.isEmpty)

        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.url)
            ) as? [String: Any]
        )
        let rewrittenSnapshot = try XCTUnwrap(
            (rewritten["snapshots"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(rewrittenSnapshot["brainEnabled"] as? Bool, false)
        XCTAssertNotNil(rewrittenSnapshot["taskPlan"])
        let rewrittenConversation = try XCTUnwrap(
            (rewrittenSnapshot["conversations"] as? [[String: Any]])?.first
        )
        XCTAssertNotNil((rewrittenConversation["base"] as? [String: Any])?["startedAt"])
        let rewrittenExtension = try XCTUnwrap(
            rewrittenConversation["managementExtension"] as? [String: Any]
        )
        XCTAssertEqual(
            rewrittenExtension["workKind"] as? String,
            "unclassified"
        )
        XCTAssertNotNil(rewrittenExtension["taskBindings"])
    }

    private let target = ConversationManagementTargetV1(
        provider: "codex",
        sourceScope: "main",
        sourceID: "thread-1"
    )

    private func makeFixture() -> (
        root: URL,
        url: URL,
        store: ConversationManagementStoreV1
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ConversationManagementStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let url = root
            .appendingPathComponent("ConversationManagement", isDirectory: true)
            .appendingPathComponent("management-v1.json")
        return (root, url, ConversationManagementStoreV1(storeURL: url))
    }

    private func makeSnapshot(
        revision: Int = 0,
        delivery: ConversationDeliveryStateV1 = .none,
        management: ConversationManagementStateV1 = .observing
    ) -> ConversationManagementSnapshotV1 {
        ConversationManagementSnapshotV1(
            projectID: "project-1",
            revision: revision,
            brainEnabled: true,
            projectDefaultEnrollmentEnabled: true,
            taskPlan: ConversationProjectTaskPlanProjectionV1(
                sourceRevision: "sha256:store-fixture",
                freshness: .fresh,
                isValid: true,
                observedAt: date(0),
                tasks: [ConversationProjectTaskV1(
                    taskID: "task-1",
                    title: "Main task",
                    owner: "executor",
                    status: .pending
                )]
            ),
            generatedAt: date(0),
            conversations: [
                ConversationManagementRecordV1(
                    base: ConversationManagementBaseProjectionV1(
                        target: target,
                        projectID: "project-1",
                        title: "Main task",
                        role: "main",
                        startedAt: date(-10),
                        observedAt: date(0),
                        runtime: .idle,
                        progress: .unknown,
                        evidence: .none
                    ),
                    managementExtension: ConversationManagementExtensionV1(
                        target: target,
                        enrollment: .inherit,
                        workKind: .task,
                        taskBindings: [ConversationTaskBindingV1(
                            taskID: "task-1",
                            projectID: "project-1",
                            target: target,
                            boundAt: date(-5)
                        )],
                        delivery: delivery,
                        management: management,
                        updatedAt: date(0)
                    )
                ),
            ]
        )
    }

    private func makeLedger() -> ConversationManagementProgressLedgerV1 {
        ConversationManagementProgressLedgerV1(
            runID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            projectID: "project-1",
            objective: "Finish the project",
            createdAt: date(0)
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
}
