import XCTest
@testable import HarvisBar

final class ManagedProjectPathMatrixRelationshipProjectionTests: XCTestCase {
    func testParentEdgeRequiresTheSameProviderAndScope() {
        let project = projectNode("project::one", name: "One")
        let child = session(
            "child",
            scope: "account-a",
            parent: "parent",
            root: "parent",
            projectID: project.id,
            updatedAt: 20
        )
        let sameIDOtherScope = session(
            "parent",
            scope: "account-b",
            root: "parent",
            projectID: project.id,
            updatedAt: 30
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [child, sameIDOtherScope]
        )

        let parentEdges = projection.edges.filter { $0.kind == .conversationParent }
        XCTAssertEqual(parentEdges.count, 1)
        XCTAssertTrue(parentEdges[0].isUnresolved)
        let placeholder = projection.nodes.first {
            $0.kind == .placeholder && $0.sourceIdentity?.sourceID == "parent"
        }
        XCTAssertEqual(placeholder?.sourceIdentity?.provider, .codex)
        XCTAssertEqual(placeholder?.sourceIdentity?.sourceScope, "account-a")
    }

    func testParentEdgeMatchesExactProviderAndScopeIdentity() {
        let project = projectNode("project::one", name: "One")
        let parent = session(
            "parent",
            scope: "account-a",
            root: "parent",
            projectID: project.id,
            updatedAt: 10
        )
        let child = session(
            "child",
            scope: "account-a",
            parent: "parent",
            root: "parent",
            projectID: project.id,
            updatedAt: 20
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [parent, child]
        )

        let edge = projection.edges.first { $0.kind == .conversationParent }
        XCTAssertEqual(edge?.from, ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(parent.id))
        XCTAssertEqual(edge?.to, ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(child.id))
        XCTAssertEqual(edge?.isUnresolved, false)
    }

    func testRootFamilyRelationDoesNotPretendToBeAParentEdge() {
        let project = projectNode("project::one", name: "One")
        let root = session(
            "root",
            scope: "account-a",
            root: "root",
            projectID: project.id,
            updatedAt: 10
        )
        let sidecar = session(
            "sidecar",
            scope: "account-a",
            root: "root",
            projectID: project.id,
            updatedAt: 20
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [root, sidecar]
        )

        XCTAssertTrue(projection.edges.contains { $0.kind == .rootFamily })
        XCTAssertFalse(projection.edges.contains { $0.kind == .conversationParent })
        XCTAssertTrue(
            projection.edges.contains {
                $0.kind == .rootFamily && $0.label.contains("同一根会话")
            }
        )
    }

    func testRootFamilyUsesTheActualRootWhenChildIsNewer() {
        let project = projectNode("project::one", name: "One")
        let root = session(
            "root",
            scope: "account-a",
            root: "root",
            projectID: project.id,
            updatedAt: 10
        )
        let child = session(
            "child",
            scope: "account-a",
            parent: "root",
            root: "root",
            projectID: project.id,
            updatedAt: 100
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [root, child]
        )

        let rootEdge = projection.edges.first {
            $0.kind == .rootFamily
                && $0.to == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(child.id)
        }
        XCTAssertEqual(
            rootEdge?.from,
            ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(root.id)
        )
        XCTAssertFalse(
            projection.edges.contains {
                $0.kind == .rootFamily
                    && $0.from == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(child.id)
            }
        )
    }

    func testEncodedRootIDResolvesToVisibleRootWithoutPlaceholder() {
        let project = projectNode("project::one", name: "One")
        let root = adaptedCodexSession("root", root: "root", projectID: project.id)
        let child = adaptedCodexSession("child", root: "root", projectID: project.id)
        XCTAssertEqual(root.rootThreadID, "root")
        XCTAssertEqual(child.rootThreadID, "root")

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [root, child]
        )

        XCTAssertFalse(projection.nodes.contains {
            $0.kind == .placeholder && $0.title == "根会话不在当前范围"
        })
        XCTAssertTrue(projection.edges.contains {
            $0.kind == .rootFamily
                && $0.from == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(root.id)
                && $0.to == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(child.id)
        })
    }

    func testRootCapUsesPlaceholderAndNeverUsesVisibleChildAsRoot() {
        let project = projectNode("project::one", name: "One")
        let root = session(
            "root",
            scope: "account-a",
            root: "root",
            projectID: project.id,
            updatedAt: 10
        )
        let child = session(
            "child",
            scope: "account-a",
            parent: "root",
            root: "root",
            projectID: project.id,
            updatedAt: 100
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [root, child],
            sessionLimit: 1
        )

        XCTAssertEqual(projection.visibleSessions.map(\.sourceID), ["child"])
        let placeholder = projection.nodes.first {
            $0.kind == .placeholder && $0.title == "根会话不在当前范围"
        }
        XCTAssertNotNil(placeholder)
        XCTAssertTrue(
            projection.edges.contains {
                $0.kind == .rootFamily
                    && $0.from == placeholder?.id
                    && $0.to == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(child.id)
                    && $0.isUnresolved
            }
        )
        XCTAssertFalse(projection.edges.contains {
            $0.kind == .rootFamily
                && $0.from == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(child.id)
        })
        XCTAssertGreaterThanOrEqual(projection.omittedRelationshipCount, 1)
    }

    func testRootSourceIDContainingDelimiterRemainsOpaque() {
        let project = projectNode("project::one", name: "One")
        let rootID = "root::with::delimiter"
        let root = session(
            rootID,
            scope: "account-a",
            root: rootID,
            projectID: project.id,
            updatedAt: 10
        )
        let child = session(
            "child",
            scope: "account-a",
            root: rootID,
            projectID: project.id,
            updatedAt: 20
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [root, child]
        )

        XCTAssertTrue(projection.edges.contains {
            $0.kind == .rootFamily
                && $0.from == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(root.id)
                && $0.to == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(child.id)
        })
        XCTAssertFalse(projection.nodes.contains { $0.kind == .placeholder })
    }

    func testProjectAssignmentPreservesCallerProvidedProjectID() {
        let project = projectNode("logical::registered", name: "Registered")
        let session = session(
            "assigned",
            scope: "account-a",
            root: "assigned",
            projectID: project.id,
            updatedAt: 10
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [session]
        )

        let assignment = projection.edges.first { $0.kind == .projectAssignment }
        XCTAssertEqual(assignment?.from, project.id)
        XCTAssertEqual(assignment?.to, ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(session.id))
        XCTAssertEqual(
            projection.nodes.first { $0.id == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(session.id) }?.projectID,
            project.id
        )
    }

    func testProjectHierarchyAndRoleTaskEdgesAreProjectedSeparately() {
        let parent = projectNode("project::parent", name: "Parent")
        let child = ManagedProjectPathMatrixNode(
            id: "project::child",
            name: "Child",
            kind: .project,
            parentID: parent.id
        )
        let session = session(
            "agent",
            scope: "account-a",
            root: "agent",
            projectID: child.id,
            isSubagent: true,
            taskBinding: ManagedProjectPathMatrixTaskBinding(
                id: "task-1",
                label: "Review"
            ),
            updatedAt: 10
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [parent, child],
            sessions: [session]
        )

        XCTAssertTrue(projection.edges.contains { $0.kind == .projectHierarchy })
        XCTAssertTrue(projection.edges.contains { $0.kind == .projectAssignment })
        XCTAssertTrue(projection.edges.contains { $0.kind == .role })
        XCTAssertTrue(projection.edges.contains { $0.kind == .taskBinding })
    }

    func testHiddenParentKeepsAnAccuratePlaceholderAndUnresolvedEdge() {
        let project = projectNode("project::one", name: "One")
        let parent = session(
            "parent",
            scope: "account-a",
            root: "parent",
            projectID: project.id,
            updatedAt: 1
        )
        let child = session(
            "child",
            scope: "account-a",
            parent: "parent",
            root: "parent",
            projectID: project.id,
            updatedAt: 100
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [parent, child],
            sessionLimit: 1
        )

        XCTAssertEqual(projection.displayedSessionCount, 1)
        XCTAssertEqual(projection.totalSessionCount, 2)
        XCTAssertEqual(projection.omittedSessionCount, 1)
        XCTAssertGreaterThanOrEqual(projection.omittedRelationshipCount, 1)
        XCTAssertTrue(projection.nodes.contains {
            $0.kind == .placeholder && $0.title == "父会话不在当前范围"
        })
        XCTAssertTrue(projection.edges.contains {
            $0.kind == .conversationParent && $0.isUnresolved
        })
    }

    func testSessionCapNeverDisplaysMoreThanThreeHundredSessions() {
        let project = projectNode("project::one", name: "One")
        let sessions = (0..<301).map { index in
            session(
                "session-\(index)",
                scope: "account-a",
                root: "session-\(index)",
                projectID: project.id,
                updatedAt: Int64(index)
            )
        }

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: sessions,
            sessionLimit: 999
        )

        XCTAssertEqual(projection.displayedSessionCount, 300)
        XCTAssertEqual(projection.totalSessionCount, 301)
        XCTAssertEqual(projection.omittedSessionCount, 1)
        XCTAssertFalse(projection.hasPreviousPage)
        XCTAssertTrue(projection.hasNextPage)
    }

    func testSelfAndMutualParentCyclesAreRejectedWithoutEdges() {
        let project = projectNode("project::one", name: "One")
        let selfSession = session(
            "self",
            scope: "account-a",
            parent: "self",
            root: "self",
            projectID: project.id,
            updatedAt: 30
        )
        let first = session(
            "first",
            scope: "account-a",
            parent: "second",
            root: "first",
            projectID: project.id,
            updatedAt: 20
        )
        let second = session(
            "second",
            scope: "account-a",
            parent: "first",
            root: "first",
            projectID: project.id,
            updatedAt: 10
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [selfSession, first, second]
        )

        XCTAssertFalse(projection.edges.contains { $0.kind == .conversationParent })
        XCTAssertGreaterThanOrEqual(projection.rejectedRelationshipCount, 2)
    }

    func testUnscopedParentDoesNotCrossLinkSessions() {
        let project = projectNode("project::one", name: "One")
        let child = session(
            "child",
            scope: "",
            parent: "parent",
            root: "parent",
            projectID: project.id,
            updatedAt: 20
        )
        let parent = session(
            "parent",
            scope: "",
            root: "parent",
            projectID: project.id,
            updatedAt: 10
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [child, parent]
        )

        XCTAssertFalse(projection.edges.contains {
            $0.kind == .conversationParent && !$0.isUnresolved
        })
        XCTAssertTrue(projection.edges.contains {
            $0.kind == .conversationParent && $0.isUnresolved
        })
    }

    func testIdentityKeyDoesNotCollideWhenComponentsContainDelimiter() {
        let first = ManagedProjectPathMatrixSourceIdentity(
            provider: .codex,
            sourceScope: "account::a",
            sourceID: "thread"
        )
        let second = ManagedProjectPathMatrixSourceIdentity(
            provider: .codex,
            sourceScope: "account",
            sourceID: "a::thread"
        )

        XCTAssertNotEqual(first.key, second.key)
    }

    func testSourceDisplayLabelAppearsInSessionNodeSubtitle() {
        let project = projectNode("project::one", name: "One")
        let session = ManagedProjectPathMatrixSession(
            id: "codex::account-a::thread",
            title: "Thread",
            provider: .codex,
            projectID: project.id,
            cwd: "/workspace/thread",
            updatedLabel: "now",
            statusLabel: "空闲",
            statusSystemImage: "circle",
            isRunning: false,
            isArchived: false,
            sourceScope: "account-a",
            sourceID: "thread",
            rootThreadID: "thread",
            sourceDisplayLabel: "Harzva Personal"
        )

        let projection = ManagedProjectPathMatrixRelationshipProjection(
            projects: [project],
            sessions: [session]
        )

        XCTAssertTrue(
            projection.nodes.first { $0.sessionID == session.id }?.subtitle.contains("Harzva Personal") == true
        )
    }

    func testOpaqueRootBeginningWithProviderNameIsNotReinterpreted() {
        let project = projectNode("project::one", name: "One")
        let unrelated = session("root", scope: "account-a", root: "root", projectID: project.id, updatedAt: 10)
        let child = adaptedCodexSession("child", root: "codex::root", projectID: project.id)
        XCTAssertEqual(child.rootThreadID, "codex::root")
        let projection = ManagedProjectPathMatrixRelationshipProjection(projects: [project], sessions: [unrelated, child])
        XCTAssertFalse(projection.edges.contains {
            $0.kind == .rootFamily && $0.from == ManagedProjectPathMatrixRelationshipProjection.sessionNodeID(unrelated.id)
        })
        XCTAssertTrue(projection.nodes.contains {
            $0.kind == .placeholder && $0.sourceIdentity?.sourceID == "codex::root"
        })
    }

    func testPaginationMakesEverySessionReachableBeyondTheDisplayLimit() {
        let project = projectNode("project::one", name: "One")
        let sessions = (0..<305).map {
            session("session-\($0)", scope: "account-a", root: "session-\($0)", projectID: project.id, updatedAt: Int64($0))
        }
        let first = ManagedProjectPathMatrixRelationshipProjection(projects: [project], sessions: sessions, sessionLimit: 300)
        let second = ManagedProjectPathMatrixRelationshipProjection(projects: [project], sessions: sessions, sessionLimit: 300, sessionOffset: 300)
        XCTAssertFalse(first.hasPreviousPage)
        XCTAssertTrue(first.hasNextPage)
        XCTAssertTrue(second.hasPreviousPage)
        XCTAssertFalse(second.hasNextPage)
        XCTAssertEqual(second.visibleSessions.count, 5)
        XCTAssertEqual(Set((first.visibleSessions + second.visibleSessions).map(\.id)), Set(sessions.map(\.id)))
    }

    private func adaptedCodexSession(_ id: String, root: String, projectID: String) -> ManagedProjectPathMatrixSession {
        let source = CodexThreadSummary(
            id: id, title: id, titleSource: "test", hasMeaningfulTitle: true,
            createdAt: 1, updatedAt: 2, tokensUsed: 0, model: "fixture",
            cwd: "/workspace/fixture", archived: false, running: false,
            threadSource: "main", agentNickname: nil, agentRole: nil, agentPath: nil,
            parentThreadId: nil, agentDepth: nil, rootThreadId: root, familyActivity: nil
        )
        return ManagedProjectPathMatrixSession(
            thread: ManagedChatThread(codex: source, sourceScope: "account-a"),
            projectID: projectID
        )
    }

    private func projectNode(
        _ id: String,
        name: String
    ) -> ManagedProjectPathMatrixNode {
        ManagedProjectPathMatrixNode(
            id: id,
            name: name,
            kind: .project,
            path: "/workspace/\(name.lowercased())"
        )
    }

    private func session(
        _ sourceID: String,
        provider: ManagedChatProvider = .codex,
        scope: String,
        parent: String? = nil,
        root: String,
        projectID: String,
        isSubagent: Bool = false,
        isSidechat: Bool = false,
        taskBinding: ManagedProjectPathMatrixTaskBinding? = nil,
        updatedAt: Int64
    ) -> ManagedProjectPathMatrixSession {
        ManagedProjectPathMatrixSession(
            id: "\(provider.rawValue)::\(scope)::\(sourceID)",
            title: sourceID,
            provider: provider,
            projectID: projectID,
            cwd: "/workspace/\(sourceID)",
            updatedLabel: "now",
            statusLabel: "空闲",
            statusSystemImage: "circle",
            isRunning: false,
            isArchived: false,
            sourceScope: scope,
            sourceID: sourceID,
            threadSource: "fixture",
            parentThreadID: parent,
            rootThreadID: root,
            isSubagent: isSubagent,
            isSidechat: isSidechat,
            taskBinding: taskBinding,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}
