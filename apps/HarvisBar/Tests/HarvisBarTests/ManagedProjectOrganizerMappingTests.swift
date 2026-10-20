import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class ManagedProjectOrganizerMappingTests: XCTestCase {
    func testLargeCatalogKeepsScopedProjectsAndTheirParentAheadOfOtherCandidates() {
        let parent = record(id: "project::z-parent", name: "Parent")
        let first = record(id: "project::z-first", name: "First", parentID: parent.id)
        let second = record(id: "project::z-second", name: "Second", parentID: parent.id)
        let others = (1...120).map { record(id: "project::a-\($0)", name: "Other \($0)") }
        let catalog = (others + [parent, first, second]).map(\.identity)
        let records = Dictionary(uniqueKeysWithValues: [parent, first, second].map { ($0.id, $0) })
        let threads = [thread("first", project: first.identity), thread("second", project: second.identity)]

        let bounded = HarvisRuntimeModel.projectOrganizerAnalysisCatalog(
            catalog: catalog, records: records, threads: threads
        )
        XCTAssertEqual(bounded.count, 100)
        XCTAssertEqual(Array(bounded.prefix(3).map(\.id)), [first.id, second.id, parent.id])
        XCTAssertEqual(Set(bounded.map(\.id)).count, bounded.count)
        XCTAssertTrue(Set(bounded.map(\.id)).isSubset(of: Set(catalog.map(\.id))))
    }

    func testCatalogUsesManualLogicalAssignmentAndDoesNotDuplicateRepeatedScopes() {
        let logical = record(id: "project::logical", name: "Logical")
        let other = record(id: "project::other", name: "Other")
        let first = thread("one", project: logical.identity)
        let second = thread("two", project: logical.identity)
        let bounded = HarvisRuntimeModel.projectOrganizerAnalysisCatalog(
            catalog: [other.identity, logical.identity], records: [logical.id: logical],
            threads: [first, second]
        )
        XCTAssertEqual(bounded.map(\.id), [logical.id, other.id])
        XCTAssertEqual(first.cwd, "/synthetic/source-workspace")
        XCTAssertEqual(first.managementProjectAssignment?.project.id, logical.id)
    }

    func testAllOneHundredCurrentProjectsAreKeptBeforeOptionalCatalogCandidates() {
        let projects = (1...120).map { record(id: "project::\($0)", name: "Project \($0)") }
        let selected = Array(projects.suffix(100))
        let threads = selected.enumerated().map { thread("t\($0.offset)", project: $0.element.identity) }
        let bounded = HarvisRuntimeModel.projectOrganizerAnalysisCatalog(
            catalog: projects.map(\.identity), records: [:], threads: threads
        )
        XCTAssertEqual(bounded.map(\.id), selected.map(\.id))
        XCTAssertEqual(bounded.count, 100)
    }

    func testNewChildMapsToIndependentCreateAndPerConversationAssignmentsAllUnselected() throws {
        let parent = record(id: "project::parent", name: "Parent", path: "/synthetic/workspace")
        let other = record(id: "project::other", name: "Other")
        let snapshots = [snapshot("one", project: parent.identity), snapshot("two", project: parent.identity)]
        let analysisResponse = response(children: [child()], suggestions: [
            suggestion("c1", action: .newChild, childRef: "n1"),
            suggestion("c2", action: .newChild, childRef: "n1"),
        ])
        let proposal = try HarvisRuntimeModel.projectOrganizerProposal(
            response: analysisResponse, refProjects: ["p1": parent.identity, "p2": other.identity],
            refConversations: ["c1": "one", "c2": "two"], snapshots: snapshots,
            unavailable: [], baseStateRevision: 7, catalogFingerprint: "catalog-fingerprint"
        )
        XCTAssertEqual(proposal.baseStateRevision, 7)
        XCTAssertEqual(proposal.catalogFingerprint, "catalog-fingerprint")
        XCTAssertEqual(proposal.snapshots, snapshots)
        XCTAssertEqual(proposal.suggestions.count, 3)
        XCTAssertTrue(proposal.suggestions.allSatisfy { !$0.isSelected })
        let creation = try XCTUnwrap(proposal.suggestions.first { $0.action == .createSubproject })
        let project = try XCTUnwrap(creation.proposedProject)
        XCTAssertTrue(project.id.hasPrefix("project::"))
        XCTAssertNotEqual(project.id, "n1")
        XCTAssertEqual(project.parentID, parent.id)
        XCTAssertEqual(project.path, "/synthetic/workspace")
        XCTAssertEqual(project.name, "Invoice exports")
        XCTAssertEqual(creation.conversationIDs, [])
        XCTAssertNil(creation.targetProjectID)
        let assignments = proposal.suggestions.filter { $0.action == .assign }
        XCTAssertEqual(assignments.map(\.conversationIDs), [["one"], ["two"]])
        XCTAssertTrue(assignments.allSatisfy { $0.targetProjectID == project.id && $0.proposedProject == nil })
    }

    func testOmittedOrEvidenceFreeRowsNeverBecomeStrongAndUnavailableRowsRemainUntouched() throws {
        let parent = record(id: "project::parent", name: "Parent")
        let unavailable = ManagedProjectOrganizerSuggestion(
            id: "unavailable", action: .keep, conversationIDs: ["unread"],
            reason: "No supported input reader", evidence: ["Not analyzed"]
        )
        let proposal = try HarvisRuntimeModel.projectOrganizerProposal(
            response: response(suggestions: [
                suggestion("c1", action: .keep, confidence: 0.99, omitted: true),
                suggestion("c2", action: .keep, confidence: 0.99, evidence: []),
            ]),
            refProjects: ["p1": parent.identity], refConversations: ["c1": "one", "c2": "two"],
            snapshots: [], unavailable: [unavailable], baseStateRevision: 0, catalogFingerprint: "catalog"
        )
        XCTAssertEqual(proposal.suggestions.map(\.confidence), [.needsReview, .needsReview, .needsReview])
        XCTAssertEqual(proposal.suggestions.last, unavailable)
        XCTAssertTrue(proposal.suggestions.allSatisfy { $0.action == .keep && !$0.isSelected })
    }

    func testEvidenceRetainsActualExcerptAndUnverifiedSourceLabel() throws {
        let parent = record(id: "project::parent", name: "Parent")
        let evidence = ManagedProjectOrganizerAnalysisEvidence(
            messageRef: "m2", excerpt: "The actual locally validated excerpt.",
            source: .unverifiedUserRole, truncated: true
        )
        let proposal = try HarvisRuntimeModel.projectOrganizerProposal(
            response: response(suggestions: [suggestion("c1", action: .keep, evidence: [evidence])]),
            refProjects: ["p1": parent.identity], refConversations: ["c1": "one"],
            snapshots: [], unavailable: [], baseStateRevision: 0, catalogFingerprint: "catalog"
        )
        let rendered = try XCTUnwrap(proposal.suggestions.first?.evidence.first)
        XCTAssertTrue(rendered.contains("自然人来源未验证"))
        XCTAssertTrue(rendered.contains("m2"))
        XCTAssertTrue(rendered.contains("节选"))
        XCTAssertTrue(rendered.hasSuffix(evidence.excerpt))
    }

    func testUnknownConversationProjectChildParentAndPathReferencesAreRejected() {
        let parent = record(id: "project::parent", name: "Parent")
        let invalidResponses = [
            response(suggestions: [suggestion("c404", action: .keep)]),
            response(suggestions: [suggestion("c1", action: .move, projectRef: "p404")]),
            response(suggestions: [suggestion("c1", action: .newChild, childRef: "n404")]),
            response(children: [child(parentRef: "p404")], suggestions: []),
            response(children: [child(pathRef: "p404")], suggestions: []),
        ]
        for response in invalidResponses {
            XCTAssertThrowsError(try HarvisRuntimeModel.projectOrganizerProposal(
                response: response, refProjects: ["p1": parent.identity], refConversations: ["c1": "one"],
                snapshots: [], unavailable: [], baseStateRevision: 0, catalogFingerprint: "catalog"
            ))
        }
    }

    private func record(id: String, name: String, parentID: String? = nil, path: String? = nil) -> ManagedProjectRecord {
        ManagedProjectRecord(id: id, name: name, purpose: "Goal for \(name)", parentID: parentID, path: path)
    }

    private func child(parentRef: String = "p1", pathRef: String? = "p1") -> ManagedProjectOrganizerAnalysisChild {
        .init(ref: "n1", name: "Invoice exports", purpose: "Export and validate invoices.",
              parentProjectRef: parentRef, pathProjectRef: pathRef)
    }

    private func suggestion(
        _ ref: String, action: ManagedProjectOrganizerAnalysisAction,
        projectRef: String? = nil, childRef: String? = nil, confidence: Double = 0.9,
        evidence: [ManagedProjectOrganizerAnalysisEvidence] = [
            .init(messageRef: "m1", excerpt: "Add invoice exports.", source: .human, truncated: false),
        ], omitted: Bool = false
    ) -> ManagedProjectOrganizerAnalysisSuggestion {
        .init(conversationRef: ref, action: action, targetProjectRef: projectRef, targetChildRef: childRef,
              reason: "The evidence concerns invoice exports.", confidence: confidence,
              evidence: evidence, modelOmitted: omitted)
    }

    private func response(
        children: [ManagedProjectOrganizerAnalysisChild] = [],
        suggestions: [ManagedProjectOrganizerAnalysisSuggestion]
    ) -> ManagedProjectOrganizerAnalysisResponse {
        .init(requestID: "synthetic-request", generatedAt: Date(timeIntervalSince1970: 1),
              children: children, suggestions: suggestions,
              coverage: .init(selectedConversationCount: suggestions.count,
                              conversationsWithEvidenceCount: suggestions.count,
                              totalUserMessageCount: suggestions.count, sentUserMessageCount: suggestions.count,
                              unverifiedUserMessageCount: 0, truncatedMessageCount: 0,
                              uninspectedConversationCount: 0, modelOmittedConversationCount: 0,
                              promptUTF8ByteCount: 500, conservativeTokenUpperBound: 500))
    }

    private func snapshot(_ id: String, project: ManagedChatProjectIdentity) -> ManagedProjectOrganizationConversation {
        .init(id: id, storageKey: "synthetic-\(id)", sourceRevision: "source-revision",
              sourceProject: project, effectiveProject: project, title: id, provider: "codex")
    }

    private func thread(_ id: String, project: ManagedChatProjectIdentity) -> ManagedChatThread {
        ManagedChatThread(
            provider: .codex, sourceScope: "synthetic-account", sourceID: id, title: id,
            titleSource: "title", hasMeaningfulTitle: true, createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100, tokensUsed: 0, model: "synthetic",
            cwd: "/synthetic/source-workspace", archived: false, running: false,
            sourceStatus: "idle", threadSource: "codex", agentNickname: nil, agentRole: nil,
            agentPath: nil, parentThreadID: nil, rootThreadId: "synthetic-root-\(id)",
            isSubagent: false, isSidechat: false, activity: .init(main: 0, subagent: 0, sidechat: nil),
            trustProjection: .init(state: .idle, reason: "Synthetic fixture"),
            managementProjectAssignment: .init(project: project, source: .manual, assignedAt: Date(timeIntervalSince1970: 1))
        )
    }
}
