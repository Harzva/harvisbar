import XCTest
@testable import HarvisBar

@MainActor
final class ManagedChatProjectTests: XCTestCase {
    func testPathVariantsResolveToOneProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let direct = ManagedChatProjectResolver.resolve(
            cwd: root.path,
            fallbackID: "direct"
        )
        let dotted = ManagedChatProjectResolver.resolve(
            cwd: root.appendingPathComponent("child/..").path,
            fallbackID: "dotted"
        )
        let trailing = ManagedChatProjectResolver.resolve(
            cwd: root.path + "/",
            fallbackID: "trailing"
        )

        XCTAssertEqual(direct.id, dotted.id)
        XCTAssertEqual(direct.id, trailing.id)
        XCTAssertEqual(direct.resolution, .resolved)
    }

    func testSymlinkAndTargetResolveToOneProject() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-project-link-\(UUID().uuidString)", isDirectory: true)
        let target = base.appendingPathComponent("target", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(
            ManagedChatProjectResolver.resolve(cwd: target.path, fallbackID: "target").id,
            ManagedChatProjectResolver.resolve(cwd: link.path, fallbackID: "link").id
        )
    }

    func testMissingPathsRemainStableAndDistinctUnassignedCardsDoNotCollapse() {
        let missing = ManagedChatProjectResolver.resolve(
            cwd: "/tmp/harvis-missing/child/..",
            fallbackID: "missing"
        )
        let firstUnassigned = ManagedChatProjectResolver.resolve(cwd: "", fallbackID: "one")
        let secondUnassigned = ManagedChatProjectResolver.resolve(cwd: "  ", fallbackID: "two")

        XCTAssertEqual(missing.canonicalPath, "/tmp/harvis-missing")
        XCTAssertEqual(missing.resolution, .unresolved)
        XCTAssertNotEqual(firstUnassigned.id, secondUnassigned.id)
        XCTAssertEqual(firstUnassigned.resolution, .unassigned)
    }

    func testHarvisAssignmentChangesGroupingWithoutChangingSourceCwdAndCanUndo() {
        let suite = "ManagedChatProjectTests.assignment.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = managedThread(
            scope: "dsh-home-a/web",
            id: "conversation-a",
            cwd: "/tmp/source-project"
        )
        let destinationThread = managedThread(
            scope: "dsh-home-a/web",
            id: "conversation-b",
            cwd: "/tmp/destination-project"
        )
        let model = HarvisRuntimeModel(defaults: defaults)
        model.dshThreads = [source, destinationThread]
        let destination = ManagedChatProjectResolver.resolveSource(
            thread: destinationThread
        )

        XCTAssertTrue(
            model.assignConversation(
                source,
                to: destination,
                source: .manual,
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        guard let projected = model.managedChatThreads.first(where: {
            $0.id == source.id
        }) else {
            return XCTFail("assigned conversation remains visible")
        }
        XCTAssertEqual(projected.cwd, source.cwd)
        XCTAssertEqual(
            ManagedChatProjectResolver.resolveSource(thread: projected).id,
            ManagedChatProjectResolver.resolveSource(thread: source).id
        )
        XCTAssertEqual(
            ManagedChatProjectResolver.resolve(thread: projected).id,
            destination.id
        )

        let restored = HarvisRuntimeModel(defaults: defaults)
        restored.dshThreads = [source, destinationThread]
        XCTAssertEqual(
            restored.managedChatThreads.first(where: { $0.id == source.id })?
                .managementProjectAssignment?.project.id,
            destination.id
        )

        model.clearConversationProjectAssignment(source)
        XCTAssertNil(
            model.managedChatThreads.first(where: { $0.id == source.id })?
                .managementProjectAssignment
        )
    }

    func testAssignmentResolutionShortCircuitsSourceFileSystemLookup() {
        var thread = managedThread(
            scope: "dsh-home-a/web",
            id: "assigned-conversation",
            cwd: "/synthetic/path/that-must-not-be-resolved"
        )
        let assignedProject = ManagedChatProjectIdentity(
            id: "unassigned::manual-target",
            canonicalPath: nil,
            displayPath: "Manual target",
            label: "Manual target",
            resolution: .unassigned
        )
        thread.managementProjectAssignment = ManagedChatProjectAssignment(
            project: assignedProject,
            source: .manual,
            assignedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let fileManager = ProjectResolverFileManagerSpy()

        XCTAssertEqual(
            ManagedChatProjectResolver.resolve(
                thread: thread,
                fileManager: fileManager
            ),
            assignedProject
        )
        XCTAssertEqual(fileManager.fileExistsCallCount, 0)
    }

    func testAssignmentKeyKeepsSameConversationIDIsolatedAcrossScopes() {
        let suite = "ManagedChatProjectTests.scope.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = managedThread(
            scope: "dsh-home-a/web",
            id: "shared-id",
            cwd: "/tmp/source-a"
        )
        let second = managedThread(
            scope: "dsh-home-b/web",
            id: "shared-id",
            cwd: "/tmp/source-b"
        )
        let destinationThread = managedThread(
            scope: "dsh-home-a/web",
            id: "destination",
            cwd: "/tmp/destination"
        )
        let model = HarvisRuntimeModel(defaults: defaults)
        model.dshThreads = [first, second, destinationThread]
        let destination = ManagedChatProjectResolver.resolveSource(
            thread: destinationThread
        )

        XCTAssertTrue(
            model.assignConversation(first, to: destination, source: .aiRecommendation)
        )
        XCTAssertNotNil(
            model.managedChatThreads.first(where: { $0.id == first.id })?
                .managementProjectAssignment
        )
        XCTAssertNil(
            model.managedChatThreads.first(where: { $0.id == second.id })?
                .managementProjectAssignment
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

private final class ProjectResolverFileManagerSpy: FileManager {
    private(set) var fileExistsCallCount = 0

    override func fileExists(atPath path: String) -> Bool {
        fileExistsCallCount += 1
        return false
    }
}
