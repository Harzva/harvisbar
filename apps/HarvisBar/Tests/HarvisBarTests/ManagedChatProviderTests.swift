import XCTest
@testable import HarvisBar

final class ManagedChatProviderTests: XCTestCase {
    func testCodexAdapterPreservesFamilyAndSourceIdentity() {
        let source = fixtureThread(
            id: "codex-1",
            running: true,
            rootThreadId: "root-1",
            familyActivity: CodexThreadFamilyActivity(
                main: 1,
                subagent: 2,
                sidechat: 1,
                members: []
            )
        )

        let chat = ManagedChatThread(codex: source)

        XCTAssertEqual(chat.provider, .codex)
        XCTAssertEqual(chat.sourceScope, ManagedChatSourceScope.codexDefault)
        XCTAssertEqual(chat.sourceID, "codex-1")
        XCTAssertEqual(chat.id, "codex::default::codex-1")
        XCTAssertEqual(chat.rootThreadId, "codex::root-1")
        XCTAssertEqual(chat.cardActivity.total, 4)
        XCTAssertTrue(chat.isCodex)
        XCTAssertFalse(chat.isDsh)
        XCTAssertTrue(chat.capabilities.supportsCodexDispatch)
        XCTAssertTrue(chat.capabilities.supportsCodexWorkbench)
        XCTAssertTrue(chat.capabilities.supportsExactThreadOpen)
        XCTAssertEqual(chat.taskCardType, .main)
        XCTAssertEqual(chat.dispatchCapability, .direct(threadID: "codex-1"))
    }

    func testCodexAdapterAcceptsExplicitStableSourceScope() {
        let source = fixtureThread(id: "shared-session")
        let first = ManagedChatThread(codex: source, sourceScope: "home-a")
        let second = ManagedChatThread(codex: source, sourceScope: "home-b")

        XCTAssertEqual(first.sourceID, second.sourceID)
        XCTAssertEqual(first.id, "codex::home-a::shared-session")
        XCTAssertEqual(second.id, "codex::home-b::shared-session")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testCodexAdapterPreservesAuthoritativeTitleProvenance() {
        let source = fixtureThread(
            title: "Untitled chat",
            titleSource: "fallback",
            hasMeaningfulTitle: false
        )

        let chat = ManagedChatThread(codex: source)

        XCTAssertEqual(chat.titleSource, "fallback")
        XCTAssertFalse(chat.hasMeaningfulTitle)
    }

    func testOlderThreadPayloadFallsBackWithoutBreakingDecoding() throws {
        let data = Data(#"""
        {
          "id":"legacy-thread",
          "title":"Untitled chat",
          "createdAt":1,
          "updatedAt":2,
          "tokensUsed":0,
          "model":null,
          "cwd":"/tmp/project",
          "archived":false,
          "running":false
        }
        """#.utf8)

        let source = try JSONDecoder().decode(CodexThreadSummary.self, from: data)

        XCTAssertNil(source.titleSource)
        XCTAssertNil(source.hasMeaningfulTitle)
        XCTAssertFalse(source.hasMeaningfulDisplayTitle)
    }

    func testWorkBuddyAdapterDoesNotMasqueradeAsCodex() {
        let source = WorkBuddyThreadSummary(
            id: "workbuddy-1",
            title: "Temporary WorkBuddy task",
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: 0,
            model: "hy3",
            cwd: "/tmp/workbuddy",
            archived: false,
            running: false,
            sourceStatus: "completed"
        )

        let chat = ManagedChatThread(workBuddy: source)

        XCTAssertEqual(chat.provider, .workBuddy)
        XCTAssertEqual(chat.sourceScope, ManagedChatSourceScope.workBuddyLocal)
        XCTAssertEqual(chat.sourceID, "workbuddy-1")
        XCTAssertEqual(chat.id, "workbuddy::local::workbuddy-1")
        XCTAssertEqual(chat.trustProjection.state, .completed)
        XCTAssertFalse(chat.isCodex)
        XCTAssertFalse(chat.isDsh)
        XCTAssertFalse(chat.isSidechat)
        XCTAssertFalse(chat.isSubagent)
        XCTAssertTrue(chat.capabilities.isObservationOnly)
        XCTAssertNil(chat.titleSource)
        XCTAssertTrue(chat.hasMeaningfulTitle)
        XCTAssertEqual(chat.taskCardType, .workBuddy)
        guard case .unavailable = chat.dispatchCapability else {
            return XCTFail("WorkBuddy must remain observation-only")
        }
    }

    func testSidechatPreservesParentAndCanOnlyForwardToParent() {
        let source = fixtureThread(
            id: "sidechat-1",
            threadSource: "sidechat",
            parentThreadId: "parent-1",
            rootThreadId: "parent-1"
        )

        let chat = ManagedChatThread(codex: source)

        XCTAssertEqual(chat.parentThreadID, "parent-1")
        XCTAssertEqual(chat.taskCardType, .sidechatParent)
        XCTAssertEqual(
            chat.dispatchCapability,
            .parentOnly(threadID: "parent-1")
        )
    }

    func testTransientSidechatWithoutParentCannotDispatch() {
        let source = fixtureThread(
            id: "sidechat-transient",
            threadSource: "sidechat"
        )

        let chat = ManagedChatThread(codex: source)

        XCTAssertEqual(chat.taskCardType, .transientSidechat)
        guard case .unavailable = chat.dispatchCapability else {
            return XCTFail("Transient Sidechat must not guess a parent")
        }
    }

    func testProviderRegistryDrivesSourceControls() {
        XCTAssertTrue(ManagedChatProvider.allCases.contains(.codex))
        XCTAssertTrue(ManagedChatProvider.allCases.contains(.dsh))
        XCTAssertTrue(ManagedChatProvider.allCases.contains(.workBuddy))
        XCTAssertEqual(ManagedChatProvider.dsh.label, "DSH")
        XCTAssertFalse(ManagedChatProvider.dsh.systemImage.isEmpty)
        XCTAssertFalse(ManagedChatProvider.workBuddy.systemImage.isEmpty)
    }

    func testDshIsScopeIsolatedAndCannotDispatchThroughCodex() {
        let first = managedChatFixture(
            provider: .dsh,
            sourceScope: "home-a/profile-web",
            sourceID: "shared-session",
            parentThreadID: "codex-parent",
            isSidechat: true
        )
        let second = managedChatFixture(
            provider: .dsh,
            sourceScope: "home-b/profile-web",
            sourceID: "shared-session"
        )

        XCTAssertTrue(first.isDsh)
        XCTAssertFalse(first.isCodex)
        XCTAssertFalse(first.isWorkBuddy)
        XCTAssertTrue(first.capabilities.isObservationOnly)
        XCTAssertEqual(first.taskCardType, .dsh)
        XCTAssertNotEqual(first.id, second.id)
        guard case let .unavailable(reason) = first.dispatchCapability else {
            return XCTFail("DSH must never dispatch through the Codex coordinator")
        }
        XCTAssertTrue(reason.contains("DSH"))
    }

    private func managedChatFixture(
        provider: ManagedChatProvider,
        sourceScope: String,
        sourceID: String,
        parentThreadID: String? = nil,
        isSidechat: Bool = false
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider,
            sourceScope: sourceScope,
            sourceID: sourceID,
            title: "Fixture",
            titleSource: nil,
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: 0,
            model: nil,
            cwd: "/tmp/fixture",
            archived: false,
            running: false,
            sourceStatus: nil,
            threadSource: provider.rawValue,
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: parentThreadID,
            rootThreadId: "\(provider.rawValue)::\(sourceScope)::\(sourceID)",
            isSubagent: false,
            isSidechat: isSidechat,
            activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(
                state: .idle,
                reason: "Fixture"
            )
        )
    }
}
