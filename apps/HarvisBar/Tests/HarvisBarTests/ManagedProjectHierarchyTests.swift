import Foundation
import XCTest
@testable import HarvisBar

final class ManagedProjectHierarchyTests: XCTestCase {
    func testPathBoundaryDoesNotTreatApp2AsAChildOfApp() throws {
        let app = identity("/workspace/team/projects/app")
        let app2 = identity("/workspace/team/projects/app2")
        let hierarchy = ManagedProjectHierarchy(
            catalog: [app, app2], records: [:], threads: [thread("one", in: app), thread("two", in: app2)]
        )
        XCTAssertNotEqual(try XCTUnwrap(hierarchy.node(app2.id)).parentID, app.id)
        XCTAssertFalse(hierarchy.descendantIDs(of: app.id).contains(app2.id))
        XCTAssertEqual(hierarchy.threads(includingDescendantsOf: app.id).map(\.sourceID), ["one"])
    }

    func testClosestKnownAncestorAndBreadcrumbWorkAtArbitraryDepth() throws {
        let root = identity("/workspace/team/projects")
        let middle = identity("/workspace/team/projects/app")
        let leaf = identity("/workspace/team/projects/app/modules/domain")
        let hierarchy = ManagedProjectHierarchy(
            catalog: [leaf, root, middle], records: [:], threads: [thread("leaf", in: leaf)]
        )
        XCTAssertEqual(try XCTUnwrap(hierarchy.node(leaf.id)).parentID, middle.id)
        XCTAssertEqual(try XCTUnwrap(hierarchy.node(middle.id)).parentID, root.id)
        XCTAssertNil(try XCTUnwrap(hierarchy.node(root.id)).parentID)
        XCTAssertEqual(hierarchy.breadcrumb(to: leaf.id).map(\.id), [root.id, middle.id, leaf.id])
        XCTAssertEqual(hierarchy.children(of: root.id).map(\.id), [middle.id])
        XCTAssertEqual(hierarchy.descendantIDs(of: root.id), Set([root.id, middle.id, leaf.id]))
        XCTAssertTrue(try XCTUnwrap(hierarchy.node(root.id)).isContainer)
        XCTAssertTrue(try XCTUnwrap(hierarchy.node(middle.id)).directThreads.isEmpty)
    }

    func testSiblingRootsGainOnlyTheirImmediateSharedContainer() throws {
        let first = identity("/workspace/team/projects/first")
        let second = identity("/workspace/team/projects/second")
        let hierarchy = ManagedProjectHierarchy(
            catalog: [first, second], records: [:],
            threads: [thread("first", in: first), thread("second", in: second)]
        )
        let root = try XCTUnwrap(hierarchy.children(of: nil).first)
        XCTAssertEqual(hierarchy.children(of: nil).count, 1)
        XCTAssertEqual(root.project.canonicalPath, "/workspace/team/projects")
        XCTAssertTrue(root.isContainer)
        XCTAssertFalse(root.isLogicalProject)
        XCTAssertEqual(Set(hierarchy.children(of: root.id).map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(hierarchy.nodes.count, 3)
        XCTAssertTrue(root.directThreads.isEmpty)
        XCTAssertEqual(hierarchy.threads(includingDescendantsOf: root.id).count, 2)
    }

    func testBroadFilesystemParentsAreNotInventedAboveWorkingRoots() {
        let first = identity("/Users/first")
        let second = identity("/Users/second")
        let hierarchy = ManagedProjectHierarchy(
            catalog: [first, second], records: [:],
            threads: [thread("first", in: first), thread("second", in: second)]
        )
        XCTAssertEqual(hierarchy.children(of: nil).count, 2)
        XCTAssertEqual(hierarchy.nodes.count, 2)
        XCTAssertFalse(hierarchy.nodes.contains { $0.project.canonicalPath == "/Users" })
    }

    func testEmptyRegisteredProjectRemainsVisibleWithoutCatalogOrConversations() throws {
        let record = ManagedProjectRecord(name: "Future work", purpose: "Prepare an independent deliverable")
        let hierarchy = ManagedProjectHierarchy(catalog: [], records: [record.id: record], threads: [])
        let node = try XCTUnwrap(hierarchy.node(record.id))
        XCTAssertEqual(node.project, record.identity)
        XCTAssertEqual(node.purpose, record.purpose)
        XCTAssertTrue(node.isLogicalProject)
        XCTAssertTrue(node.directThreads.isEmpty)
        XCTAssertEqual(hierarchy.children(of: nil).map(\.id), [record.id])
    }

    func testRegisteredProjectsSharingOnePathRetainSeparateNodesAndConversations() throws {
        let parent = identity("/workspace/team/projects/shared")
        let first = ManagedProjectRecord(
            name: "First goal", purpose: "First deliverable", parentID: parent.id, path: parent.canonicalPath
        )
        let second = ManagedProjectRecord(
            name: "Second goal", purpose: "Second deliverable", parentID: parent.id, path: parent.canonicalPath
        )
        let hierarchy = ManagedProjectHierarchy(
            catalog: [parent, first.identity, second.identity], records: [first.id: first, second.id: second],
            threads: [thread("first", in: first.identity), thread("second", in: second.identity)]
        )
        XCTAssertEqual(hierarchy.nodes.count, 3)
        XCTAssertEqual(Set(hierarchy.children(of: parent.id).map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(try XCTUnwrap(hierarchy.node(first.id)).directThreads.map(\.sourceID), ["first"])
        XCTAssertEqual(try XCTUnwrap(hierarchy.node(second.id)).directThreads.map(\.sourceID), ["second"])
        XCTAssertEqual(hierarchy.threads(includingDescendantsOf: parent.id).count, 2)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testDirectAndAggregateCountsDeduplicateFullConversationIdentity() throws {
        let parent = identity("/workspace/team/projects")
        let child = identity("/workspace/team/projects/child")
        let direct = thread("direct", in: parent)
        let firstAccount = thread("same-source-id", scope: "account-a", in: child)
        let secondAccount = thread("same-source-id", scope: "account-b", in: child)
        let hierarchy = ManagedProjectHierarchy(
            catalog: [parent, child], records: [:],
            threads: [direct, direct, firstAccount, firstAccount, secondAccount]
        )
        XCTAssertEqual(try XCTUnwrap(hierarchy.node(parent.id)).directThreads.count, 1)
        XCTAssertEqual(try XCTUnwrap(hierarchy.node(child.id)).directThreads.count, 2)
        XCTAssertEqual(Set(hierarchy.threads(includingDescendantsOf: parent.id).map(\.id)),
                       Set([direct.id, firstAccount.id, secondAccount.id]))
        XCTAssertEqual(hierarchy.threads(includingDescendantsOf: parent.id).count, 3)
        XCTAssertEqual(hierarchy.threads(includingDescendantsOf: child.id).count, 2)
    }

    func testMissingParentDoesNotHideExistingLogicalProject() throws {
        let record = ManagedProjectRecord(
            name: "Available child", purpose: "An existing independent goal", parentID: "path::/temporarily-missing"
        )
        let hierarchy = ManagedProjectHierarchy(catalog: [record.identity], records: [record.id: record], threads: [])
        XCTAssertNil(try XCTUnwrap(hierarchy.node(record.id)).parentID)
        XCTAssertEqual(hierarchy.children(of: nil).map(\.id), [record.id])
        XCTAssertEqual(hierarchy.breadcrumb(to: record.id).map(\.id), [record.id])
    }

    func testParticipantCountUsesProviderAccountAndExplicitAgentIdentity() {
        let project = identity("/workspace/team/projects")
        let first = thread("first", scope: "account-a", in: project)
        let sameAccount = thread("second", scope: "account-a", in: project)
        let anotherAccount = thread("first", scope: "account-b", in: project)
        let anotherProvider = thread("first", provider: .dsh, scope: "account-a", in: project)
        XCTAssertEqual(ManagedProjectHierarchy.participantCount([first, sameAccount, first]), 1)
        XCTAssertEqual(ManagedProjectHierarchy.participantCount([first, anotherAccount, anotherProvider]), 3)
        let agentA = thread("agent-task-1", agentPath: "agents/reviewer", in: project)
        let agentAAgain = thread("agent-task-2", agentPath: "agents/reviewer", in: project)
        let agentB = thread("agent-task-3", agentPath: "agents/implementer", in: project)
        XCTAssertEqual(ManagedProjectHierarchy.participantCount([first, agentA, agentAAgain, agentB]), 3)
        let nickname = thread("nickname-1", agentNickname: "Reviewer", in: project)
        let sameNickname = thread("nickname-2", agentNickname: "Reviewer", in: project)
        XCTAssertEqual(ManagedProjectHierarchy.participantCount([nickname, sameNickname]), 1)
        XCTAssertEqual(ManagedProjectHierarchy.participantCount([]), 0)
    }

    func testDuplicateCatalogIdentitiesProduceOneNode() throws {
        let project = identity("/workspace/team/projects")
        let hierarchy = ManagedProjectHierarchy(
            catalog: [project, project], records: [:], threads: [thread("one", in: project)]
        )
        XCTAssertEqual(hierarchy.nodes.map(\.id), [project.id])
        XCTAssertEqual(try XCTUnwrap(hierarchy.node(project.id)).directThreads.count, 1)
    }

    func testScopedProjectionHidesUnrelatedInferredPathsButKeepsRegisteredProjects() throws {
        let parent = identity("/workspace/team/projects")
        let inScope = identity("/workspace/team/projects/in-scope")
        let unrelated = identity("/workspace/team/elsewhere")
        let registered = ManagedProjectRecord(name: "Registered", purpose: "A saved goal without activity")
        let hierarchy = ManagedProjectHierarchy(
            catalog: [unrelated, inScope, registered.identity, parent], records: [registered.id: registered],
            threads: [thread("scope-session", in: inScope)]
        )
        XCTAssertNil(hierarchy.node(unrelated.id))
        XCTAssertNotNil(hierarchy.node(registered.id))
        XCTAssertEqual(hierarchy.threads(includingDescendantsOf: parent.id).map(\.sourceID), ["scope-session"])
        XCTAssertTrue(try XCTUnwrap(hierarchy.node(parent.id)).directThreads.isEmpty)
    }

    private func identity(_ path: String) -> ManagedChatProjectIdentity {
        ManagedChatProjectIdentity(
            id: "path::\(path)", canonicalPath: path, displayPath: path,
            label: (path as NSString).lastPathComponent, resolution: .resolved
        )
    }

    private func thread(
        _ id: String,
        provider: ManagedChatProvider = .codex,
        scope: String = "account-a",
        agentPath: String? = nil,
        agentNickname: String? = nil,
        in project: ManagedChatProjectIdentity
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider, sourceScope: scope, sourceID: id, title: id,
            titleSource: "fixture", hasMeaningfulTitle: true, createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100, tokensUsed: 0, model: "fixture", cwd: project.canonicalPath ?? "",
            archived: false, running: false, sourceStatus: "idle", threadSource: "fixture",
            agentNickname: agentNickname, agentRole: nil, agentPath: agentPath, parentThreadID: nil,
            rootThreadId: "\(provider.rawValue)::\(scope)::\(id)", isSubagent: agentPath != nil,
            isSidechat: false, activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(state: .idle, reason: "Fixture"),
            managementProjectAssignment: ManagedChatProjectAssignment(
                project: project, source: .manual, assignedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }
}
