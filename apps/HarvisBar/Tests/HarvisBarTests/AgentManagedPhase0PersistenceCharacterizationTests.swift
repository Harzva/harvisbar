import XCTest
@testable import HarvisBar

/// Phase 0 characterization for the legacy Agent Managed preference surface.
///
/// These tests intentionally describe the mixed storage-key payload that
/// exists before Core extraction. They must not be interpreted as a request
/// to normalize, split, or migrate any key in production during Phase 0.
@MainActor
final class AgentManagedPhase0PersistenceCharacterizationTests: XCTestCase {
    private static let selectedThreadKey =
        "harvis.codex.chatManager.selectedThreadID"
    private static let tagsKey = "harvisBar.codexThreadTags"
    private static let pinsKey = "harvisBar.pinnedCodexThreads"
    private static let assignmentsKey =
        "harvisBar.managedChatProjectAssignments"

    func testMixedLegacyKeysRoundTripAndSelectionUsesExactEquality() throws {
        let (suiteName, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let threads = syntheticThreads()
        let model = HarvisRuntimeModel(defaults: defaults)
        let keys = threads.map(model.managedChatStorageKey)

        XCTAssertEqual(
            keys,
            [
                "codex-home-a::shared-source",
                "dsh::dsh-scope-a::shared-source",
                "workbuddy::local::shared-source",
            ]
        )
        XCTAssertEqual(Set(keys).count, threads.count)

        for (index, thread) in threads.enumerated() {
            model.setTags(
                [" provider-\(index) ", "provider-\(index)"],
                for: thread
            )
            model.toggleThreadPin(thread)
        }

        let assignment = syntheticAssignment()
        model.codexPreferences.saveProjectAssignments(
            Dictionary(uniqueKeysWithValues: keys.map { ($0, assignment) })
        )

        XCTAssertNotNil(defaults.data(forKey: Self.tagsKey))
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: Self.pinsKey) ?? []),
            Set(keys)
        )
        XCTAssertNotNil(defaults.data(forKey: Self.assignmentsKey))

        let restored = HarvisRuntimeModel(defaults: defaults)
        for (index, thread) in threads.enumerated() {
            XCTAssertEqual(restored.tags(for: thread), ["provider-\(index)"])
            XCTAssertTrue(restored.isThreadPinned(thread))
            XCTAssertEqual(restored.projectAssignment(for: thread), assignment)
        }

        // The existing selection payload can contain either the Codex legacy
        // alias or a non-Codex full ID. Restoration compares the whole string;
        // it does not parse delimiters or infer a provider.
        for (expectedIndex, key) in keys.enumerated() {
            defaults.set(key, forKey: Self.selectedThreadKey)
            let persisted = try XCTUnwrap(
                defaults.string(forKey: Self.selectedThreadKey)
            )
            let matches = threads.enumerated().filter {
                restored.managedChatStorageKey($0.element) == persisted
            }

            XCTAssertEqual(matches.map(\.offset), [expectedIndex])
        }

        for guessedKey in [
            "codex::codex-home-a::shared-source",
            "dsh-scope-a::shared-source",
            "local::shared-source",
        ] {
            defaults.set(guessedKey, forKey: Self.selectedThreadKey)
            let matches = threads.filter {
                restored.managedChatStorageKey($0) == guessedKey
            }
            XCTAssertTrue(matches.isEmpty)
        }

        let persistedPayloads = [
            defaults.data(forKey: Self.tagsKey),
            defaults.data(forKey: Self.assignmentsKey),
        ]
            .compactMap { $0 }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(persistedPayloads.contains("/Users/"))
        XCTAssertFalse(persistedPayloads.contains("/home/"))
    }

    func testMalformedLegacyPreferencePayloadsFailClosed() throws {
        let (suiteName, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let malformed = Data("not-json".utf8)
        defaults.set(malformed, forKey: Self.tagsKey)
        defaults.set(malformed, forKey: Self.pinsKey)
        defaults.set(malformed, forKey: Self.assignmentsKey)
        defaults.set(
            "codex::unknown-scope::unknown-source",
            forKey: Self.selectedThreadKey
        )

        let preferences = CodexThreadPreferences(defaults: defaults)
        XCTAssertEqual(preferences.loadTags(), [:])
        XCTAssertTrue(preferences.loadPins().isEmpty)
        XCTAssertEqual(preferences.loadProjectAssignments(), [:])

        let model = HarvisRuntimeModel(
            defaults: defaults,
            codexPreferences: preferences
        )
        let persistedSelection = try XCTUnwrap(
            defaults.string(forKey: Self.selectedThreadKey)
        )
        XCTAssertFalse(syntheticThreads().contains {
            model.managedChatStorageKey($0) == persistedSelection
        })
    }

    func testLegacyWindowKeysDefaultsAndRestorationRemainStable() throws {
        XCTAssertEqual(
            CodexChatWorkbenchDefaults.expandedKey,
            "harvis.codex.chatManager.workbenchExpanded"
        )
        XCTAssertEqual(
            CodexChatWorkbenchDefaults.compactWidthKey,
            "harvis.codex.chatManager.compact.width"
        )
        XCTAssertEqual(
            CodexChatWorkbenchDefaults.compactHeightKey,
            "harvis.codex.chatManager.compact.height"
        )
        XCTAssertEqual(
            CodexChatWorkbenchDefaults.expandedWidthKey,
            "harvis.codex.chatManager.expanded.width"
        )
        XCTAssertEqual(
            CodexChatWorkbenchDefaults.expandedHeightKey,
            "harvis.codex.chatManager.expanded.height"
        )
        XCTAssertEqual(
            HarvisRuntimeModel.Keys.codexChatWindowPinned,
            "harvisBar.codexChatWindowPinned"
        )
        XCTAssertEqual(
            HarvisRuntimeModel.Keys.codexChatWindowDockingEnabled,
            "harvisBar.codexChatWindowDockingEnabled"
        )
        XCTAssertEqual(
            HarvisRuntimeModel.Keys.codexChatWindowAttachmentLocked,
            "harvisBar.codexChatWindowAttachmentLocked"
        )

        let (freshSuite, freshDefaults) = try isolatedDefaults()
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        let fresh = HarvisRuntimeModel(defaults: freshDefaults)

        XCTAssertFalse(fresh.isCodexChatWindowPinned)
        XCTAssertTrue(fresh.isCodexChatWindowDockingEnabled)
        XCTAssertFalse(fresh.isCodexChatWindowAttachmentLocked)
        XCTAssertFalse(fresh.isCodexChatWindowDocked)
        XCTAssertNil(fresh.codexChatWindowDockSide)
        XCTAssertEqual(
            CodexChatWorkbenchSizePolicy.restore(
                mode: .compact,
                defaults: freshDefaults
            ).size,
            .compactDefault
        )
        XCTAssertEqual(
            CodexChatWorkbenchSizePolicy.restore(
                mode: .expanded,
                defaults: freshDefaults
            ).size,
            .expandedDefault
        )

        let (storedSuite, storedDefaults) = try isolatedDefaults()
        defer { storedDefaults.removePersistentDomain(forName: storedSuite) }
        storedDefaults.set(
            true,
            forKey: HarvisRuntimeModel.Keys.codexChatWindowPinned
        )
        storedDefaults.set(
            false,
            forKey: HarvisRuntimeModel.Keys.codexChatWindowDockingEnabled
        )
        storedDefaults.set(
            true,
            forKey: HarvisRuntimeModel.Keys.codexChatWindowAttachmentLocked
        )
        let restored = HarvisRuntimeModel(defaults: storedDefaults)

        XCTAssertTrue(restored.isCodexChatWindowPinned)
        XCTAssertFalse(restored.isCodexChatWindowDockingEnabled)
        XCTAssertTrue(restored.isCodexChatWindowAttachmentLocked)
        // Dock attachment is live window state and is deliberately not
        // restored from these legacy preference flags.
        XCTAssertFalse(restored.isCodexChatWindowDocked)
        XCTAssertNil(restored.codexChatWindowDockSide)
    }

    func testInvalidWindowDimensionsFallBackWithoutPropagatingPayload() throws {
        let (suiteName, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "not-a-number",
            forKey: CodexChatWorkbenchDefaults.compactWidthKey
        )
        defaults.set(
            -100,
            forKey: CodexChatWorkbenchDefaults.compactHeightKey
        )

        let restoration = CodexChatWorkbenchSizePolicy.restore(
            mode: .compact,
            defaults: defaults
        )

        XCTAssertEqual(restoration.size, .compactDefault)
        XCTAssertFalse(restoration.migratedLegacyCompactSize)
    }

    private func isolatedDefaults() throws -> (String, UserDefaults) {
        let suiteName =
            "AgentManagedPhase0PersistenceCharacterizationTests.\(UUID().uuidString)"
        return (suiteName, try XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    private func syntheticThreads() -> [ManagedChatThread] {
        [
            syntheticThread(
                provider: .codex,
                sourceScope: "codex-home-a"
            ),
            syntheticThread(
                provider: .dsh,
                sourceScope: "dsh-scope-a"
            ),
            syntheticThread(
                provider: .workBuddy,
                sourceScope: ManagedChatSourceScope.workBuddyLocal
            ),
        ]
    }

    private func syntheticThread(
        provider: ManagedChatProvider,
        sourceScope: String
    ) -> ManagedChatThread {
        ManagedChatThread(
            provider: provider,
            sourceScope: sourceScope,
            sourceID: "shared-source",
            title: "Synthetic conversation",
            titleSource: nil,
            hasMeaningfulTitle: true,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            tokensUsed: 0,
            model: nil,
            cwd: "",
            archived: false,
            running: false,
            sourceStatus: nil,
            threadSource: provider.rawValue,
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: "synthetic-root",
            isSubagent: false,
            isSidechat: false,
            activity: ManagedChatActivity(main: 0, subagent: 0, sidechat: nil),
            trustProjection: CodexThreadTrustProjection(
                state: .idle,
                reason: "Synthetic fixture"
            )
        )
    }

    private func syntheticAssignment() -> ManagedChatProjectAssignment {
        ManagedChatProjectAssignment(
            project: ManagedChatProjectIdentity(
                id: "synthetic-project",
                canonicalPath: nil,
                displayPath: "Synthetic project",
                label: "Synthetic project",
                resolution: .unassigned
            ),
            source: .manual,
            assignedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
    }
}
