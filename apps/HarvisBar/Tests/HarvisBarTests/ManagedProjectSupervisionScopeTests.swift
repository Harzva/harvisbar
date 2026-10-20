import Foundation
import XCTest
@testable import HarvisBar

final class ManagedProjectSupervisionScopeTests: XCTestCase {
    func testRosterUsesSnapshotRecordsAndFullInventoryForCandidates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = project(for: root)
        let threads = [
            thread(provider: .codex, scope: "codex-main", id: "main", cwd: root.path),
            thread(
                provider: .codex,
                scope: "codex-main",
                id: "subagent",
                cwd: root.path,
                isSubagent: true
            ),
            thread(
                provider: .codex,
                scope: "codex-main",
                id: "sidechat",
                cwd: root.path,
                isSidechat: true,
                parentThreadID: "main"
            ),
            thread(provider: .dsh, scope: "dsh::fixture::web", id: "dsh", cwd: root.path),
            thread(provider: .workBuddy, scope: "local", id: "workbuddy", cwd: root.path),
        ]
        let snapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: project,
            threads: threads,
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true,
            now: Date(timeIntervalSince1970: 100)
        )

        let scope = try XCTUnwrap(
            ManagedProjectSupervisionScope(
                project: project,
                snapshot: snapshot,
                // This is intentionally the complete inventory, even though
                // a card view could be showing only the first row.
                threads: threads
            )
        )

        XCTAssertEqual(scope.totalCount, 5)
        XCTAssertEqual(scope.approvalCandidateCount, 2)
        XCTAssertEqual(scope.observationCount, 3)
        XCTAssertEqual(
            scope.entries.first(where: { $0.target.sourceID == "main" })?.status,
            .approvalCandidate
        )
        XCTAssertEqual(
            scope.entries.first(where: { $0.target.sourceID == "sidechat" })?.status,
            .observation
        )
        XCTAssertTrue(
            scope.entries.first(where: { $0.target.sourceID == "sidechat" })?.reason
                .contains("Sidechat") == true
        )
        XCTAssertTrue(
            scope.entries.first(where: { $0.target.sourceID == "dsh" })?.reason
                .contains("DSH") == true
        )
        XCTAssertTrue(
            scope.entries.first(where: { $0.target.sourceID == "workbuddy" })?.reason
                .contains("WorkBuddy") == true
        )
    }

    func testEnrollmentAndDisconnectedRecordsRemainVisibleButCannotBecomeCandidates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = project(for: root)
        let visible = thread(provider: .codex, scope: "codex", id: "main", cwd: root.path)
        let first = ConversationManagementProjectorV1.makeSnapshot(
            project: project,
            threads: [visible],
            previous: nil,
            projectDefaultEnrollmentEnabled: false,
            completionEvidence: .unavailable,
            brainEnabled: true,
            now: Date(timeIntervalSince1970: 100)
        )
        let enrolledOff = try XCTUnwrap(
            ManagedProjectSupervisionScope(
                project: project,
                snapshot: first,
                threads: [visible]
            )
        )
        XCTAssertEqual(enrolledOff.entries.count, 1)
        XCTAssertEqual(enrolledOff.entries[0].status, .enrollmentExcluded)
        XCTAssertEqual(enrolledOff.approvalCandidateCount, 0)

        let disconnectedSnapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: project,
            threads: [],
            previous: first,
            projectDefaultEnrollmentEnabled: false,
            completionEvidence: .unavailable,
            brainEnabled: true,
            now: Date(timeIntervalSince1970: 200)
        )
        let disconnected = try XCTUnwrap(
            ManagedProjectSupervisionScope(
                project: project,
                snapshot: disconnectedSnapshot,
                threads: []
            )
        )
        XCTAssertEqual(disconnected.entries.count, 1)
        XCTAssertEqual(disconnected.entries[0].status, .unavailable)
        XCTAssertFalse(disconnected.entries[0].isConnected)
        XCTAssertTrue(disconnected.entries[0].reason.contains("失联"))
    }

    func testScopeRejectsOtherProjectSnapshotAndDoesNotIncludeSubproject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let subprojectURL = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: subprojectURL, withIntermediateDirectories: true)
        let project = project(for: root)
        let parentThread = thread(provider: .codex, scope: "codex", id: "parent", cwd: root.path)
        let childThread = thread(provider: .codex, scope: "codex", id: "child", cwd: subprojectURL.path)
        let snapshot = ConversationManagementProjectorV1.makeSnapshot(
            project: project,
            threads: [parentThread, childThread],
            previous: nil,
            projectDefaultEnrollmentEnabled: true,
            completionEvidence: .unavailable,
            brainEnabled: true
        )
        let scope = try XCTUnwrap(
            ManagedProjectSupervisionScope(
                project: project,
                snapshot: snapshot,
                threads: [parentThread, childThread]
            )
        )
        XCTAssertEqual(scope.entries.map(\.target.sourceID), ["parent"])

        let other = ManagedChatProjectIdentity(
            id: "path::/tmp/another-project",
            canonicalPath: "/tmp/another-project",
            displayPath: "/tmp/another-project",
            label: "Another",
            resolution: .unresolved
        )
        XCTAssertNil(
            ManagedProjectSupervisionScope(
                project: other,
                snapshot: snapshot,
                threads: [parentThread, childThread]
            )
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-supervision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func project(for root: URL) -> ManagedChatProjectIdentity {
        ManagedChatProjectIdentity(
            id: "path::\(root.path)",
            canonicalPath: root.path,
            displayPath: root.path,
            label: root.lastPathComponent,
            resolution: .resolved
        )
    }

    private func thread(
        provider: ManagedChatProvider,
        scope: String,
        id: String,
        cwd: String,
        isSubagent: Bool = false,
        isSidechat: Bool = false,
        parentThreadID: String? = nil
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider,
            sourceScope: scope,
            sourceID: id,
            title: id,
            titleSource: "fixture",
            hasMeaningfulTitle: true,
            createdAt: 1,
            updatedAt: 2,
            tokensUsed: 0,
            model: "fixture",
            cwd: cwd,
            archived: false,
            running: false,
            sourceStatus: "idle",
            threadSource: "fixture",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: parentThreadID,
            rootThreadId: "root",
            isSubagent: isSubagent,
            isSidechat: isSidechat,
            activity: .init(main: 0, subagent: 0, sidechat: nil),
            trustProjection: .init(state: .idle, reason: "fixture")
        )
    }
}
