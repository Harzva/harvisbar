import Foundation
import XCTest
@testable import HarvisBar

final class AgentManagedCoreTests: XCTestCase {
    func testAddressIdentityAndCodableRoundTripAreStructural() throws {
        let first = ManagedConversationAddress(
            providerID: AgentProviderID(rawValue: "provider::a"),
            scope: "scope/一",
            sourceID: "source::ß"
        )
        let secondScope = ManagedConversationAddress(
            providerID: first.providerID,
            scope: "scope/二",
            sourceID: first.sourceID
        )
        let secondProvider = ManagedConversationAddress(
            providerID: AgentProviderID(rawValue: "provider-b"),
            scope: first.scope,
            sourceID: first.sourceID
        )

        XCTAssertEqual(Set([first, secondScope, secondProvider]).count, 3)
        XCTAssertNotEqual(first, secondScope)
        XCTAssertNotEqual(first, secondProvider)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ManagedConversationAddress.self,
                from: JSONEncoder().encode(first)
            ),
            first
        )
        XCTAssertEqual(
            first.serializedID,
            "provider::a::scope/一::source::ß",
            "The legacy display string is not used to recover structural identity"
        )
    }

    func testCapabilitiesDefaultDeniedAndSeparateSurfaceFromExactOpen() {
        let subject = address(provider: "provider-a", sourceID: "subject")
        let revision = ConversationAuthorityRevision.verified("revision-a")
        var surfaceOnly = ConversationCapabilities.denied(
            for: subject,
            generation: 12,
            reason: "Synthetic default denial."
        )
        surfaceOnly = surfaceOnly.setting(
            .allowedDirect(authorityRevision: revision),
            for: .openProviderSurface
        )

        XCTAssertEqual(surfaceOnly.subject, subject)
        XCTAssertEqual(surfaceOnly.generation, 12)
        XCTAssertEqual(
            surfaceOnly.route(for: .openProviderSurface),
            .direct(subject)
        )
        for action in ConversationCapabilityAction.allCases
        where action != .openProviderSurface {
            assertDenied(
                surfaceOnly.decision(for: action),
                containing: "Synthetic default denial"
            )
            XCTAssertNil(surfaceOnly.route(for: action))
        }
    }

    func testCapabilityRoutesPreserveDirectParentExplicitAndRevision() {
        let subject = address(provider: "provider-a", sourceID: "subject")
        let parent = address(provider: "provider-a", sourceID: "parent")
        let explicit = address(provider: "provider-b", sourceID: "explicit")
        let revision = ConversationAuthorityRevision.verified("opaque-revision")
        var capabilities = ConversationCapabilities.denied(
            for: subject,
            generation: 7
        )
        capabilities = capabilities
            .setting(
                .allowedDirect(authorityRevision: revision),
                for: .openExact
            )
            .setting(
                .allowedParent(
                    target: parent,
                    authorityRevision: revision
                ),
                for: .send
            )
            .setting(
                .allowedExplicit(
                    target: explicit,
                    authorityRevision: revision
                ),
                for: .handoff
            )

        XCTAssertEqual(capabilities.route(for: .openExact), .direct(subject))
        XCTAssertEqual(capabilities.route(for: .send), .parent(parent))
        XCTAssertEqual(capabilities.route(for: .handoff), .explicit(explicit))
        XCTAssertEqual(
            capabilities.decision(for: .openExact).authorityRevision,
            revision
        )
        XCTAssertEqual(
            capabilities.decision(for: .send).authorityRevision,
            revision
        )
        XCTAssertEqual(
            capabilities.decision(for: .handoff).authorityRevision,
            revision
        )
    }

    func testAgentIdentityDoesNotGrantCapabilities() {
        let subject = address(provider: "provider-a", sourceID: "subject")
        let denied = ConversationCapabilities.denied(for: subject)
        let identity = AgentIdentity(
            stableID: "agent-a",
            displayName: "Synthetic Agent",
            role: "planner",
            sourcePath: "synthetic/agent",
            skillIDs: ["skill-a"],
            presetIDs: ["preset-a"]
        )
        let conversation = makeCoreConversation(
            address: subject,
            agentIdentity: identity,
            capabilities: denied
        )

        XCTAssertEqual(conversation.agentIdentity, identity)
        for action in ConversationCapabilityAction.allCases {
            assertDenied(conversation.capabilities.decision(for: action))
        }
    }

    func testCompatibilitySendDecisionsPreserveDirectParentAndTransientDenial() {
        let main = makeThread(provider: .codex, sourceID: "main")
        let persistentSubagent = makeThread(
            provider: .codex,
            sourceID: "persistent",
            isSubagent: true
        )
        let managedSidechat = makeThread(
            provider: .codex,
            sourceID: "sidechat",
            parentThreadID: "parent::thread",
            isSidechat: true
        )
        let transientSidechat = makeThread(
            provider: .codex,
            sourceID: "transient",
            isSidechat: true
        )
        let revision = ConversationAuthorityRevision.compatibility(
            "synthetic-authority"
        )

        let mainCore = main.coreProjection(
            generation: 9,
            authorityRevision: revision
        )
        let persistentCore = persistentSubagent.coreProjection(
            generation: 9,
            authorityRevision: revision
        )
        let sidechatCore = managedSidechat.coreProjection(
            generation: 9,
            authorityRevision: revision
        )
        let transientCore = transientSidechat.coreProjection(
            generation: 9,
            authorityRevision: revision
        )

        XCTAssertEqual(
            mainCore.capabilities.decision(for: .send),
            .allowedDirect(authorityRevision: revision)
        )
        XCTAssertEqual(
            persistentCore.capabilities.decision(for: .send),
            .allowedDirect(authorityRevision: revision)
        )
        let parent = ManagedConversationAddress(
            providerID: AgentProviderID(rawValue: "codex"),
            scope: "scope-a",
            sourceID: "parent::thread"
        )
        XCTAssertEqual(
            sidechatCore.capabilities.decision(for: .send),
            .allowedParent(target: parent, authorityRevision: revision)
        )
        XCTAssertEqual(sidechatCore.capabilities.route(for: .send), .parent(parent))
        assertDenied(
            transientCore.capabilities.decision(for: .send),
            containing: "no reliable parent"
        )

        XCTAssertEqual(main.dispatchCapability, .direct(threadID: "main"))
        XCTAssertEqual(
            managedSidechat.dispatchCapability,
            .parentOnly(threadID: "parent::thread")
        )
        guard case .unavailable = transientSidechat.dispatchCapability else {
            return XCTFail("The legacy dispatch bridge must remain denied")
        }
        XCTAssertTrue(
            transientSidechat.capabilities.supportsCodexDispatch,
            "The legacy provider-wide boolean is intentionally not a Core send grant"
        )
    }

    func testTransientCompatibilityFactsDoNotGrantInsightOrPlanning() {
        let transient = makeThread(
            provider: .codex,
            sourceID: "transient",
            isSidechat: true
        )
        let core = transient.coreProjection(
            generation: 3,
            authorityRevision: .compatibility("phase-0-fact")
        )

        XCTAssertTrue(core.capabilities.decision(for: .openExact).isAllowed)
        XCTAssertTrue(core.capabilities.decision(for: .readInputs).isAllowed)
        XCTAssertTrue(core.capabilities.decision(for: .inspect).isAllowed)
        assertDenied(core.capabilities.decision(for: .analyzeInsight))
        assertDenied(core.capabilities.decision(for: .plan))
        assertDenied(core.capabilities.decision(for: .send))

        // Phase 0 records these provider-wide legacy facts without declaring
        // them to be the future safety contract.
        XCTAssertTrue(transient.capabilities.supportsCodexDispatch)
        XCTAssertTrue(transient.capabilities.supportsCodexWorkbench)
        XCTAssertTrue(transient.capabilities.supportsExactThreadOpen)
    }

    func testObservationProvidersAllowSurfaceAndFailClosedForExactActions() {
        for provider in [ManagedChatProvider.dsh, .workBuddy] {
            let thread = makeThread(provider: provider, sourceID: "observation")
            let core = thread.coreProjection(
                generation: 4,
                authorityRevision: .compatibility("surface-only")
            )

            XCTAssertTrue(core.capabilities.decision(for: .observe).isAllowed)
            XCTAssertTrue(
                core.capabilities.decision(for: .openProviderSurface).isAllowed
            )
            for action in ConversationCapabilityAction.allCases
            where action != .observe && action != .openProviderSurface {
                assertDenied(core.capabilities.decision(for: action))
            }
            XCTAssertTrue(thread.capabilities.isObservationOnly)
        }
    }

    func testLegacyTrustStatesRoundTripWithoutPresentationLoss() {
        let cases: [(
            legacy: CodexThreadTrustState,
            state: ConversationTrustState,
            qualifier: ConversationTrustQualifier?
        )] = [
            (.running, .running, nil),
            (.completed, .completed, nil),
            (.failed, .failed, nil),
            (.incomplete, .unknown, .incomplete),
            (.recentlyActive, .idle, .recentlyActive),
            (.idle, .idle, nil),
            (.stale, .idle, .stale),
            (.archived, .archived, nil),
        ]

        for item in cases {
            let legacy = CodexThreadTrustProjection(
                state: item.legacy,
                reason: "Synthetic \(item.legacy.rawValue)"
            )
            let core = ConversationTrustProjection(legacy: legacy)
            XCTAssertEqual(core.state, item.state)
            XCTAssertEqual(core.qualifier, item.qualifier)
            XCTAssertEqual(core.legacyProjection.state, item.legacy)
            XCTAssertEqual(core.legacyProjection.reason, legacy.reason)
        }

        let unknown = ConversationTrustProjection(
            state: .unknown,
            reason: "No verified state"
        )
        XCTAssertEqual(
            unknown.legacyProjection.state,
            .incomplete,
            "Unknown must remain warning-like instead of silently becoming idle"
        )
    }

    func testKnownLegacyRootsBecomeStructuredWithoutDelimiterGuessing() {
        let codex = makeThread(
            provider: .codex,
            sourceID: "source::child",
            legacyRootThreadID: "codex::root::child"
        )
        let core = codex.coreProjection(
            generation: 1,
            authorityRevision: .compatibility("root-test")
        )
        XCTAssertEqual(core.lineage.rootAddress?.sourceID, "root::child")
        XCTAssertEqual(core.lineage.rootAddress?.scope, "scope-a")

        let arbitrary = makeThread(
            provider: .codex,
            sourceID: "source",
            legacyRootThreadID: "arbitrary::root"
        )
        XCTAssertNil(
            arbitrary.coreProjection(
                generation: 1,
                authorityRevision: .compatibility("root-test")
            ).lineage.rootAddress,
            "Unknown legacy shapes must not be split or guessed"
        )
    }

    func testProjectAndGovernanceAliasesPreserveValuesAndRules() throws {
        let project = ManagedChatProjectIdentity(
            id: "synthetic-project",
            canonicalPath: nil,
            displayPath: "Synthetic project",
            label: "Synthetic project",
            resolution: .unassigned
        )
        let assignment = ManagedChatProjectAssignment(
            project: project,
            source: .manual,
            assignedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try JSONEncoder().encode(assignment)
        let decoded = try JSONDecoder().decode(
            ManagedConversationProjectAssignment.self,
            from: encoded
        )
        XCTAssertEqual(decoded, assignment)
        XCTAssertEqual(
            ManagedConversationProjectRules.effectiveProject(
                source: ManagedConversationProjectRules.unassigned(
                    fallbackID: "fallback"
                ),
                assignment: assignment
            ),
            project
        )

        let preference = ManagedAttentionPreference(
            level: .high,
            focusStartsAt: Date(timeIntervalSince1970: 100),
            focusEndsAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(
            preference.focusState(at: Date(timeIntervalSince1970: 150)),
            .active
        )
        XCTAssertEqual(preference.level?.label, "P2 重要")
        XCTAssertFalse(
            ManagedConversationVisibilityRules.shouldShowUnnamedSubagent(
                isUnnamedSubagent: true,
                hasExplicitShowOverride: false
            )
        )
    }

    func testThreeProviderCompatibilityProjectionRoundTripsLegacyPresentation() throws {
        let project = ManagedChatProjectIdentity(
            id: "unassigned::synthetic",
            canonicalPath: nil,
            displayPath: "No working directory",
            label: "Unassigned",
            resolution: .unassigned
        )
        let assignment = ManagedChatProjectAssignment(
            project: project,
            source: .manual,
            assignedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let fixtures = [
            makeThread(
                provider: .codex,
                sourceID: "codex-source",
                parentThreadID: "codex-parent",
                isSidechat: true,
                trustState: .recentlyActive,
                agentNickname: "cxglm",
                agentRole: "reviewer",
                agentPath: "agents/cxglm",
                assignment: assignment
            ),
            makeThread(
                provider: .dsh,
                sourceID: "dsh-source",
                trustState: .archived,
                assignment: assignment
            ),
            makeThread(
                provider: .workBuddy,
                sourceID: "workbuddy-source",
                trustState: .completed,
                assignment: assignment
            ),
        ]

        for (generation, original) in fixtures.enumerated() {
            let core = original.coreProjection(
                generation: UInt64(generation + 1),
                authorityRevision: .compatibility("roundtrip-\(generation)")
            )
            XCTAssertEqual(core.address.serializedID, original.id)
            XCTAssertEqual(
                core.tokenUsage,
                original.tokensUsed >= 0 ? original.tokensUsed : nil
            )
            XCTAssertEqual(core.projectAssignment, original.managementProjectAssignment)

            let restored = try XCTUnwrap(
                ManagedChatThread(
                    coreProjection: core,
                    legacyRootThreadID: original.rootThreadId
                )
            )
            assertLegacyEquivalent(restored, original)
        }
    }

    func testCoreValueTypesSatisfySendableContracts() {
        assertSendable(AgentProviderID.self)
        assertSendable(ManagedConversationAddress.self)
        assertSendable(AgentIdentity.self)
        assertSendable(ManagedConversation.self)
        assertSendable(ConversationCapabilities.self)
        assertSendable(ConversationCapabilityRoute.self)
        assertSendable(ConversationTrustProjection.self)
        assertSendable(ManagedConversationProjectAssignment.self)
        assertSendable(ManagedConversationGovernanceSnapshot.self)
    }

    private func address(
        provider: String,
        scope: String = "scope-a",
        sourceID: String
    ) -> ManagedConversationAddress {
        ManagedConversationAddress(
            providerID: AgentProviderID(rawValue: provider),
            scope: scope,
            sourceID: sourceID
        )
    }

    private func makeCoreConversation(
        address: ManagedConversationAddress,
        agentIdentity: AgentIdentity?,
        capabilities: ConversationCapabilities
    ) -> ManagedConversation {
        ManagedConversation(
            address: address,
            title: "Synthetic conversation",
            titleSource: "test",
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokenUsage: nil,
            model: nil,
            sourceWorkingDirectory: "",
            archived: false,
            running: false,
            sourceStatus: nil,
            sourceKind: nil,
            agentIdentity: agentIdentity,
            lineage: ManagedConversationLineage(
                rootAddress: nil,
                parentAddress: nil,
                isSubagent: false,
                isSidechat: false
            ),
            activity: ManagedConversationActivity(
                main: 0,
                subagent: 0,
                sidechat: nil
            ),
            trust: ConversationTrustProjection(
                state: .unknown,
                reason: "Synthetic fixture"
            ),
            capabilities: capabilities,
            projectAssignment: nil
        )
    }

    private func makeThread(
        provider: ManagedChatProvider,
        sourceID: String,
        parentThreadID: String? = nil,
        isSubagent: Bool = false,
        isSidechat: Bool = false,
        trustState: CodexThreadTrustState = .idle,
        legacyRootThreadID: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        agentPath: String? = nil,
        assignment: ManagedChatProjectAssignment? = nil
    ) -> ManagedChatThread {
        let sourceScope = "scope-a"
        let rootThreadID: String
        if let legacyRootThreadID {
            rootThreadID = legacyRootThreadID
        } else {
            switch provider {
            case .codex:
                rootThreadID = "codex::root-id"
            case .dsh:
                rootThreadID = "\(sourceScope)::root-id"
            case .workBuddy:
                rootThreadID = "workbuddy::\(sourceID)"
            }
        }
        var thread = ManagedChatThread(
            provider: provider,
            sourceScope: sourceScope,
            sourceID: sourceID,
            title: "Synthetic conversation",
            titleSource: "test",
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: provider == .dsh ? -1 : 42,
            model: "synthetic-model",
            cwd: "/tmp/synthetic-project",
            archived: trustState == .archived,
            running: trustState == .running,
            sourceStatus: trustState.rawValue,
            threadSource: isSidechat ? "sidechat" : provider.rawValue,
            agentNickname: agentNickname,
            agentRole: agentRole,
            agentPath: agentPath,
            parentThreadID: parentThreadID,
            rootThreadId: rootThreadID,
            isSubagent: isSubagent,
            isSidechat: isSidechat,
            activity: ManagedChatActivity(
                main: isSubagent || isSidechat ? 0 : 1,
                subagent: isSubagent ? 1 : 0,
                sidechat: isSidechat ? 1 : nil
            ),
            trustProjection: CodexThreadTrustProjection(
                state: trustState,
                reason: "Synthetic fixture"
            )
        )
        thread.managementProjectAssignment = assignment
        return thread
    }

    private func assertLegacyEquivalent(
        _ actual: ManagedChatThread,
        _ expected: ManagedChatThread,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.provider, expected.provider, file: file, line: line)
        XCTAssertEqual(actual.sourceScope, expected.sourceScope, file: file, line: line)
        XCTAssertEqual(actual.sourceID, expected.sourceID, file: file, line: line)
        XCTAssertEqual(actual.title, expected.title, file: file, line: line)
        XCTAssertEqual(actual.titleSource, expected.titleSource, file: file, line: line)
        XCTAssertEqual(
            actual.hasMeaningfulTitle,
            expected.hasMeaningfulTitle,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.createdAt, expected.createdAt, file: file, line: line)
        XCTAssertEqual(actual.updatedAt, expected.updatedAt, file: file, line: line)
        XCTAssertEqual(actual.tokensUsed, expected.tokensUsed, file: file, line: line)
        XCTAssertEqual(actual.model, expected.model, file: file, line: line)
        XCTAssertEqual(actual.cwd, expected.cwd, file: file, line: line)
        XCTAssertEqual(actual.archived, expected.archived, file: file, line: line)
        XCTAssertEqual(actual.running, expected.running, file: file, line: line)
        XCTAssertEqual(actual.sourceStatus, expected.sourceStatus, file: file, line: line)
        XCTAssertEqual(actual.threadSource, expected.threadSource, file: file, line: line)
        XCTAssertEqual(actual.agentNickname, expected.agentNickname, file: file, line: line)
        XCTAssertEqual(actual.agentRole, expected.agentRole, file: file, line: line)
        XCTAssertEqual(actual.agentPath, expected.agentPath, file: file, line: line)
        XCTAssertEqual(
            actual.parentThreadID,
            expected.parentThreadID,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.rootThreadId, expected.rootThreadId, file: file, line: line)
        XCTAssertEqual(actual.isSubagent, expected.isSubagent, file: file, line: line)
        XCTAssertEqual(actual.isSidechat, expected.isSidechat, file: file, line: line)
        XCTAssertEqual(actual.activity.main, expected.activity.main, file: file, line: line)
        XCTAssertEqual(
            actual.activity.subagent,
            expected.activity.subagent,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.activity.sidechat,
            expected.activity.sidechat,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.trustProjection.state,
            expected.trustProjection.state,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.trustProjection.reason,
            expected.trustProjection.reason,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.managementProjectAssignment,
            expected.managementProjectAssignment,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.capabilities, expected.capabilities, file: file, line: line)
        XCTAssertEqual(actual.taskCardType, expected.taskCardType, file: file, line: line)
        XCTAssertEqual(
            actual.dispatchCapability,
            expected.dispatchCapability,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.agentDisplayName, expected.agentDisplayName, file: file, line: line)
        XCTAssertEqual(actual.agentIdentityLabel, expected.agentIdentityLabel, file: file, line: line)
        XCTAssertEqual(actual.agentTaskLabel, expected.agentTaskLabel, file: file, line: line)
        XCTAssertEqual(actual.tokenLabel, expected.tokenLabel, file: file, line: line)
    }

    private func assertDenied(
        _ decision: ConversationCapabilityDecision,
        containing expectedText: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .denied(reason) = decision else {
            return XCTFail("Expected a denied capability", file: file, line: line)
        }
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
        if let expectedText {
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains(expectedText),
                file: file,
                line: line
            )
        }
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}
