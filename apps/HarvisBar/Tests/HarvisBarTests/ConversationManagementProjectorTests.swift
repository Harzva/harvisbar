import Foundation
import XCTest
@testable import HarvisBar

final class ConversationManagementProjectorTests: XCTestCase {
    func testAllProvidersProjectBaseButOnlyCodexMainAndPersistedSubagentAreAllowed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let threads = [
            thread(provider: .codex, scope: "home-a", id: "main", cwd: fixture.root.path),
            thread(
                provider: .codex,
                scope: "home-a",
                id: "sub",
                cwd: fixture.root.path,
                isSubagent: true
            ),
            thread(
                provider: .codex,
                scope: "home-a",
                id: "side",
                cwd: fixture.root.path,
                isSidechat: true,
                parentThreadID: "main"
            ),
            thread(provider: .dsh, scope: "dsh::home::web", id: "dsh", cwd: fixture.root.path),
            thread(provider: .workBuddy, scope: "local", id: "wb", cwd: fixture.root.path),
        ]

        let snapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: threads,
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true,
            now: date(100)
        )

        XCTAssertEqual(snapshot.conversations.count, 5)
        XCTAssertEqual(
            Set(snapshot.conversations.map { $0.base.target.provider }),
            ["codex", "dsh", "workbuddy"]
        )
        XCTAssertEqual(
            Set(snapshot.conversations.compactMap {
                $0.managementExtension?.target.sourceID
            }),
            ["main", "sub", "side", "dsh", "wb"]
        )
        XCTAssertTrue(snapshot.conversations.allSatisfy {
            $0.managementExtension?.enrollment == .inherit
        })
        XCTAssertEqual(
            ConversationManagementProjectorV1.allowedTargets(
                project: fixture.project,
                threads: threads
            ),
            [
                ConversationManagementTargetV1(
                    provider: "codex",
                    sourceScope: "home-a",
                    sourceID: "main"
                ),
                ConversationManagementTargetV1(
                    provider: "codex",
                    sourceScope: "home-a",
                    sourceID: "sub"
                ),
            ]
        )
    }

    func testProjectionRevisionChangesOnlyWhenManagementRelevantFactsChange() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initialThread = thread(
            provider: .codex,
            scope: "home-a",
            id: "main",
            cwd: fixture.root.path,
            updatedAt: 10
        )
        let first = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [initialThread],
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true,
            now: date(100)
        )
        let unchanged = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [initialThread],
            previous: first,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true,
            now: date(200)
        )
        let changed = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [thread(
                provider: .codex,
                scope: "home-a",
                id: "main",
                cwd: fixture.root.path,
                updatedAt: 11,
                running: true
            )],
            previous: unchanged,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true,
            now: date(300)
        )

        XCTAssertEqual(first.revision, 0)
        XCTAssertEqual(unchanged.revision, 0)
        XCTAssertEqual(changed.revision, 1)
        XCTAssertEqual(changed.conversations[0].base.runtime, .running)
        XCTAssertEqual(changed.conversations[0].base.progress.phase, .active)
        XCTAssertNotNil(changed.conversations[0].managementExtension)
    }

    func testSameSecondEvidenceChangeAdvancesMonotonicEvidenceRevision() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [thread(
                provider: .codex,
                scope: "home-a",
                id: "main",
                cwd: fixture.root.path,
                updatedAt: 10,
                tokensUsed: 10
            )],
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true
        )
        let second = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [thread(
                provider: .codex,
                scope: "home-a",
                id: "main",
                cwd: fixture.root.path,
                updatedAt: 10,
                tokensUsed: 11
            )],
            previous: first,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true
        )

        XCTAssertEqual(first.conversations[0].base.evidence.revision, 10)
        XCTAssertEqual(second.conversations[0].base.evidence.revision, 11)
        XCTAssertNotEqual(
            first.conversations[0].base.evidence.fingerprint,
            second.conversations[0].base.evidence.fingerprint
        )
        XCTAssertEqual(second.revision, 1)
    }

    func testTemporarilyMissingManagedConversationIsRetainedButNotDispatchable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let visible = thread(
            provider: .codex,
            scope: "home-a",
            id: "main",
            cwd: fixture.root.path,
            updatedAt: 10
        )
        let first = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [visible],
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true
        )
        let missing = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [],
            previous: first,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true
        )

        XCTAssertEqual(missing.conversations.count, 1)
        XCTAssertEqual(missing.conversations[0].base.runtime, .disconnected)
        XCTAssertEqual(missing.conversations[0].base.evidence.status, .stale)
        XCTAssertNotNil(missing.conversations[0].managementExtension)
        XCTAssertTrue(
            ConversationManagementProjectorV1.allowedTargets(
                project: fixture.project,
                threads: []
            ).isEmpty
        )
    }

    func testProviderWaitingStatesMapWithoutGrantingCapabilities() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let approval = thread(
            provider: .codex,
            scope: "home-a",
            id: "approval",
            cwd: fixture.root.path,
            sourceStatus: "waiting_on_approval"
        )
        let userInput = thread(
            provider: .dsh,
            scope: "dsh::home::web",
            id: "question",
            cwd: fixture.root.path,
            sourceStatus: "waiting-on-user-input"
        )
        let snapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [approval, userInput],
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true
        )
        let runtimeByID = Dictionary(uniqueKeysWithValues: snapshot.conversations.map {
            ($0.base.target.sourceID, $0.base.runtime)
        })

        XCTAssertEqual(runtimeByID["approval"], .waitingApproval)
        XCTAssertEqual(runtimeByID["question"], .waitingUserInput)
        XCTAssertNotNil(
            snapshot.conversations.first {
                $0.base.target.sourceID == "question"
            }?.managementExtension
        )
    }

    func testBrainObservationWithDefaultEnrollmentOffDetectsOldOutOfPlanChats() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let start = Int64(1_700_000_000)
        let now = Date(
            timeIntervalSince1970: TimeInterval(start) + 25 * 60 * 60
        )
        let threads = [
            thread(
                provider: .codex,
                scope: "home-a",
                id: "old-codex",
                cwd: fixture.root.path,
                createdAt: start,
                updatedAt: start + 10
            ),
            thread(
                provider: .dsh,
                scope: "dsh::brain::web",
                id: "old-dsh",
                cwd: fixture.root.path,
                createdAt: start,
                updatedAt: start + 10
            ),
        ]
        let taskPlan = ConversationProjectTaskPlanProjectionV1(
            sourceRevision: "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            freshness: .fresh,
            isValid: true,
            observedAt: now,
            tasks: [
                ConversationProjectTaskV1(
                    taskID: "task-1",
                    title: "Authoritative project task",
                    owner: "owner",
                    status: .inProgress
                ),
            ]
        )
        let snapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: threads,
            previous: nil,
            projectDefaultEnrollmentEnabled: false,
            completionEvidence: .unavailable,
            brainEnabled: true,
            taskPlan: taskPlan,
            now: now
        )

        XCTAssertEqual(snapshot.conversations.count, 2)
        XCTAssertTrue(snapshot.conversations.allSatisfy {
            $0.managementExtension != nil
                && !$0.isEnrolled(projectDefaultEnabled: false)
                && $0.planAlignment(taskPlan: taskPlan, now: now) == .outOfPlan
        })
        XCTAssertEqual(
            ConversationManagementProjectorV1.allowedTargets(
                project: fixture.project,
                threads: threads
            ),
            [ConversationManagementTargetV1(
                provider: "codex",
                sourceScope: "home-a",
                sourceID: "old-codex"
            )]
        )

        let disabled = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: threads,
            previous: nil,
            projectDefaultEnrollmentEnabled: false,
            completionEvidence: .unavailable,
            brainEnabled: false,
            taskPlan: taskPlan,
            now: now
        )
        XCTAssertTrue(disabled.conversations.allSatisfy {
            $0.managementExtension == nil
        })
    }

    func testTaskPlanProjectionIsFreshOnlyForExactValidSourceRead() {
        let task = ConversationProjectTaskV1(
            taskID: "task-1",
            title: "Implement the bounded change",
            owner: "executor",
            status: .inProgress
        )
        let fresh = ConversationManagementProjectorV1.makeTaskPlanProjection(
            sourceAvailable: true,
            sourceRevision: "sha256:one",
            isValid: true,
            tasks: [task],
            observedAt: date(10),
            previous: nil
        )
        XCTAssertTrue(fresh.isAuthoritative)
        XCTAssertEqual(fresh.tasks, [task])

        let stale = ConversationManagementProjectorV1.makeTaskPlanProjection(
            sourceAvailable: false,
            sourceRevision: nil,
            isValid: false,
            tasks: [],
            observedAt: date(20),
            previous: fresh
        )
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertEqual(stale.sourceRevision, "sha256:one")
        XCTAssertEqual(stale.tasks, [task])
        XCTAssertFalse(stale.isAuthoritative)

        let invalid = ConversationManagementProjectorV1.makeTaskPlanProjection(
            sourceAvailable: true,
            sourceRevision: "sha256:two",
            isValid: false,
            tasks: [task],
            observedAt: date(30),
            previous: stale
        )
        XCTAssertEqual(invalid.freshness, .fresh)
        XCTAssertFalse(invalid.isValid)
        XCTAssertTrue(invalid.tasks.isEmpty)
        XCTAssertFalse(invalid.isAuthoritative)
    }

    func testStartedAtRemainsStableWhenActiveConversationKeepsUpdating() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [thread(
                provider: .codex,
                scope: "home-a",
                id: "main",
                cwd: fixture.root.path,
                createdAt: 2,
                updatedAt: 10
            )],
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true
        )
        let updated = ConversationManagementProjectorV1.makeSnapshot(
            project: fixture.project,
            threads: [thread(
                provider: .codex,
                scope: "home-a",
                id: "main",
                cwd: fixture.root.path,
                createdAt: 999,
                updatedAt: 1_000,
                running: true
            )],
            previous: first,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true
        )

        XCTAssertEqual(
            first.conversations[0].base.startedAt,
            Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(
            updated.conversations[0].base.startedAt,
            first.conversations[0].base.startedAt
        )
        XCTAssertEqual(
            updated.conversations[0].base.observedAt,
            Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        project: ManagedChatProjectIdentity
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ConversationManagementProjectorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return (
            root,
            ManagedChatProjectResolver.resolve(
                cwd: root.path,
                fallbackID: "project"
            )
        )
    }

    private func thread(
        provider: ManagedChatProvider,
        scope: String,
        id: String,
        cwd: String,
        createdAt: Int64 = 1,
        updatedAt: Int64 = 10,
        tokensUsed: Int64 = 1,
        running: Bool = false,
        sourceStatus: String? = nil,
        isSubagent: Bool = false,
        isSidechat: Bool = false,
        parentThreadID: String? = nil
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider,
            sourceScope: scope,
            sourceID: id,
            title: id,
            titleSource: "title",
            hasMeaningfulTitle: true,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tokensUsed: tokensUsed,
            model: nil,
            cwd: cwd,
            archived: false,
            running: running,
            sourceStatus: sourceStatus,
            threadSource: isSubagent ? "subagent" : "cli",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: parentThreadID,
            rootThreadId: parentThreadID ?? id,
            isSubagent: isSubagent,
            isSidechat: isSidechat,
            activity: ManagedChatActivity(
                main: running && !isSubagent ? 1 : 0,
                subagent: running && isSubagent ? 1 : 0,
                sidechat: isSidechat && running ? 1 : 0
            ),
            trustProjection: CodexThreadTrustProjection(
                state: running ? .running : .idle,
                reason: running
                    ? "Running fixture"
                    : "Idle fixture"
            )
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }
}
