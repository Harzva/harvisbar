import XCTest
@testable import HarvisBar

@MainActor
final class AgentManagedPhase0IdentityCapabilityTests: XCTestCase {
    func testIdentityAndStorageKeysPreserveProviderScopeAndLegacyCodexAlias() {
        let model = makeModel()
        let codexA = makeThread(
            provider: .codex,
            sourceScope: "codex-home-a",
            sourceID: "shared-source"
        )
        let codexB = makeThread(
            provider: .codex,
            sourceScope: "codex-home-b",
            sourceID: "shared-source"
        )
        let dsh = makeThread(
            provider: .dsh,
            sourceScope: "dsh-home-a/profile-a",
            sourceID: "shared-source"
        )
        let workBuddy = makeThread(
            provider: .workBuddy,
            sourceScope: ManagedChatSourceScope.workBuddyLocal,
            sourceID: "shared-source"
        )

        XCTAssertEqual(codexA.id, "codex::codex-home-a::shared-source")
        XCTAssertEqual(codexB.id, "codex::codex-home-b::shared-source")
        XCTAssertEqual(dsh.id, "dsh::dsh-home-a/profile-a::shared-source")
        XCTAssertEqual(workBuddy.id, "workbuddy::local::shared-source")
        XCTAssertEqual(Set([codexA.id, codexB.id, dsh.id, workBuddy.id]).count, 4)

        // Phase 0 freezes the mixed legacy payload shape by exact equality:
        // Codex remains scope::sourceID, while non-Codex stores the full ID.
        XCTAssertEqual(
            model.managedChatStorageKey(codexA),
            "codex-home-a::shared-source"
        )
        XCTAssertEqual(
            model.managedChatStorageKey(codexB),
            "codex-home-b::shared-source"
        )
        XCTAssertEqual(model.managedChatStorageKey(dsh), dsh.id)
        XCTAssertEqual(model.managedChatStorageKey(workBuddy), workBuddy.id)
    }

    func testCodexSendRoutingPreservesDirectParentAndTransientDenial() {
        let main = makeThread(
            provider: .codex,
            sourceScope: "codex-home",
            sourceID: "main"
        )
        let persistentSubagent = makeThread(
            provider: .codex,
            sourceScope: "codex-home",
            sourceID: "persistent-subagent",
            isSubagent: true
        )
        let managedSidechat = makeThread(
            provider: .codex,
            sourceScope: "codex-home",
            sourceID: "managed-sidechat",
            parentThreadID: "parent-thread",
            isSidechat: true
        )
        let transientSidechat = makeThread(
            provider: .codex,
            sourceScope: "codex-home",
            sourceID: "transient-sidechat",
            isSidechat: true
        )

        XCTAssertEqual(main.taskCardType, .main)
        XCTAssertEqual(main.dispatchCapability, .direct(threadID: "main"))
        XCTAssertEqual(persistentSubagent.taskCardType, .persistedSubagent)
        XCTAssertEqual(
            persistentSubagent.dispatchCapability,
            .direct(threadID: "persistent-subagent")
        )
        XCTAssertEqual(managedSidechat.taskCardType, .sidechatParent)
        XCTAssertEqual(
            managedSidechat.dispatchCapability,
            .parentOnly(threadID: "parent-thread")
        )
        XCTAssertEqual(transientSidechat.taskCardType, .transientSidechat)
        guard case let .unavailable(reason) = transientSidechat.dispatchCapability else {
            return XCTFail("A transient sidechat must not guess a send target")
        }
        XCTAssertTrue(reason.contains("no reliable parent"))
    }

    func testInsightStorageKeyIsStableWithoutExposingRawIdentity() {
        let target = ManagedConversationInsightTarget(
            provider: "synthetic-provider",
            sourceScope: "synthetic-scope",
            sourceID: "synthetic-source"
        )
        let same = ManagedConversationInsightTarget(
            provider: "synthetic-provider",
            sourceScope: "synthetic-scope",
            sourceID: "synthetic-source"
        )
        let differentScope = ManagedConversationInsightTarget(
            provider: "synthetic-provider",
            sourceScope: "other-scope",
            sourceID: "synthetic-source"
        )

        XCTAssertEqual(target.storageKey, same.storageKey)
        XCTAssertNotEqual(target.storageKey, differentScope.storageKey)
        XCTAssertEqual(target.storageKey.count, 64)
        XCTAssertTrue(target.storageKey.allSatisfy { $0.isHexDigit })
        XCTAssertFalse(target.storageKey.contains(target.provider))
        XCTAssertFalse(target.storageKey.contains(target.sourceScope))
        XCTAssertFalse(target.storageKey.contains(target.sourceID))
    }

    func testCurrentTransientExactInputAndInsightEligibilityIsCharacterizationOnly() throws {
        let model = makeModel()
        let home = makeCodexHome(id: "codex-home")
        let nativeMain = makeCodexThread(
            id: "main",
            threadSource: "main"
        )
        let nativeTransient = makeCodexThread(
            id: "transient",
            threadSource: "sidechat"
        )
        model.codexHomes = [home]
        model.selectedCodexHomeID = home.id
        model.acceptCodexThreads(
            [nativeMain, nativeTransient],
            sourceHomeID: home.id
        )

        let main = try XCTUnwrap(model.managedChatThreads.first {
            $0.sourceID == nativeMain.id
        })
        let transient = try XCTUnwrap(model.managedChatThreads.first {
            $0.sourceID == nativeTransient.id
        })
        XCTAssertEqual(transient.taskCardType, .transientSidechat)

        // Decision A: these assertions record the provider-wide legacy facts.
        // They are intentionally not future safety targets; only send-denied is
        // the Phase 0 safety invariant for a transient sidechat.
        XCTAssertTrue(transient.capabilities.supportsCodexWorkbench)
        XCTAssertTrue(transient.capabilities.supportsExactThreadOpen)
        XCTAssertEqual(model.codexThread(for: transient)?.id, nativeTransient.id)

        seedSyntheticInput(for: main, in: model)
        seedSyntheticInput(for: transient, in: model)
        XCTAssertTrue(model.conversationInputState(for: transient).sourceAvailable)
        XCTAssertEqual(
            model.conversationInputState(for: transient).items.map(\.text),
            ["synthetic-user-input"]
        )

        let mainInsight = model.managedConversationInsightContext(for: main)
        let transientInsight = model.managedConversationInsightContext(
            for: transient
        )
        XCTAssertEqual(
            transientInsight.availabilityMessage,
            mainInsight.availabilityMessage,
            "The current runtime has no transient-specific Insight denial"
        )
        XCTAssertFalse(
            transientInsight.canAnalyze,
            "Normal project/brain prerequisites still fail closed in this synthetic fixture"
        )
    }

    func testObservationProvidersFailClosedWithoutConflatingSurfaceAndExactOpen() async {
        let model = makeModel()
        let dsh = makeThread(
            provider: .dsh,
            sourceScope: "dsh-home/profile",
            sourceID: "dsh-session"
        )
        let workBuddy = makeThread(
            provider: .workBuddy,
            sourceScope: ManagedChatSourceScope.workBuddyLocal,
            sourceID: "workbuddy-session"
        )

        for thread in [dsh, workBuddy] {
            // Provider metadata gives Harvis a surface entry point, but it is
            // not evidence of an exact conversation deep link.
            XCTAssertFalse(thread.provider.label.isEmpty)
            XCTAssertFalse(thread.provider.systemImage.isEmpty)
            XCTAssertTrue(thread.capabilities.isObservationOnly)
            XCTAssertFalse(thread.capabilities.supportsExactThreadOpen)
            guard case .unavailable = thread.dispatchCapability else {
                return XCTFail("Observation providers must not dispatch")
            }

            await model.refreshConversationInputs(for: thread, force: true)
            let state = model.conversationInputState(for: thread)
            XCTAssertEqual(state.provider, thread.provider)
            XCTAssertFalse(state.sourceAvailable)
            XCTAssertNil(state.sourceRevision)
            XCTAssertTrue(state.items.isEmpty)
            XCTAssertEqual(state.totalCount, 0)
            XCTAssertNotNil(state.loadedAt)
            XCTAssertEqual(state.threadUpdatedAtAtLoad, thread.updatedAt)
            XCTAssertNotNil(state.error)

            let insight = model.managedConversationInsightContext(for: thread)
            XCTAssertFalse(insight.canAnalyze)
            XCTAssertNotNil(insight.availabilityMessage)
        }
    }

    private func makeModel() -> HarvisRuntimeModel {
        let suite = "AgentManagedPhase0IdentityCapabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return HarvisRuntimeModel(defaults: defaults)
    }

    private func makeThread(
        provider: ManagedChatProvider,
        sourceScope: String,
        sourceID: String,
        parentThreadID: String? = nil,
        isSubagent: Bool = false,
        isSidechat: Bool = false
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider,
            sourceScope: sourceScope,
            sourceID: sourceID,
            title: "Synthetic fixture",
            titleSource: nil,
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: 0,
            model: nil,
            cwd: "",
            archived: false,
            running: false,
            sourceStatus: "synthetic",
            threadSource: isSidechat ? "sidechat" : provider.rawValue,
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: parentThreadID,
            rootThreadId: "\(provider.rawValue)::\(sourceScope)::root",
            isSubagent: isSubagent,
            isSidechat: isSidechat,
            activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(
                state: .idle,
                reason: "Synthetic fixture"
            )
        )
    }

    private func makeCodexHome(id: String) -> CodexHome {
        CodexHome(
            id: id,
            label: "Synthetic Codex",
            accountNote: nil,
            path: "/tmp/harvis-phase0-synthetic-codex-home",
            source: "default",
            model: "synthetic-model",
            provider: "synthetic-provider",
            endpointHost: nil,
            hasAuth: false,
            accountEmail: "synthetic@example.test",
            authStatus: "missing",
            authExpiresAt: nil,
            authNote: nil,
            hasConfig: true,
            skillCount: 0,
            quotaMode: nil,
            quotaNote: nil
        )
    }

    private func makeCodexThread(
        id: String,
        threadSource: String
    ) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            title: "Synthetic fixture",
            titleSource: "test",
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: 0,
            model: "synthetic-model",
            cwd: "",
            archived: false,
            running: false,
            threadSource: threadSource,
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadId: nil,
            agentDepth: nil,
            rootThreadId: id,
            familyActivity: nil
        )
    }

    private func seedSyntheticInput(
        for thread: ManagedChatThread,
        in model: HarvisRuntimeModel
    ) {
        let key = model.managedChatStorageKey(thread)
        model.managedConversationInputStates[key] =
            ManagedConversationUserInputState(
                targetKey: key,
                provider: .codex,
                sourceAvailable: true,
                sourceRevision: "sha256:" + String(repeating: "a", count: 64),
                items: [
                    ManagedConversationUserInput(
                        id: "synthetic-input",
                        sequence: 1,
                        turnID: nil,
                        timestamp: nil,
                        text: "synthetic-user-input",
                        originalCharacterCount: 20,
                        truncated: false,
                        source: .human
                    ),
                ],
                totalCount: 1,
                nextCursor: nil,
                isLoading: false,
                isTruncated: false,
                loadedAt: Date(timeIntervalSince1970: 1_700_000_200),
                threadUpdatedAtAtLoad: thread.updatedAt,
                error: nil
            )
    }
}
