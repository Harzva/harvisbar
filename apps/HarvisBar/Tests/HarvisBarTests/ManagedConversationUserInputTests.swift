import XCTest
@testable import HarvisBar

@MainActor
final class ManagedConversationUserInputTests: XCTestCase {
    func testCodexProjectionValidatesExactTargetRevisionAndUniqueItems() throws {
        let page = CodexUserInputPage(
            ok: true,
            schemaVersion: CodexUserInputPage.supportedSchemaVersion,
            threadId: "thread-a",
            source: "codex_rollout_jsonl",
            sourceAvailable: true,
            sourceRevision: "sha256:" + String(repeating: "a", count: 64),
            items: [
                CodexUserInputWireItem(
                    id: "message-1",
                    sequence: 4,
                    timestamp: "2026-08-24T00:00:00Z",
                    turnId: "turn-1",
                    text: "请完成相关性分析",
                    truncated: false,
                    originalCharacterCount: 9,
                    source: .unknown,
                    originMessageIDHash: "sha256:" + String(repeating: "c", count: 64)
                ),
            ],
            nextCursor: nil,
            excludedNonHumanItems: 2,
            totalItems: 1
        )

        XCTAssertNoThrow(
            try ManagedConversationInputProjection.validate(
                page,
                expectedThreadID: "thread-a"
            )
        )
        XCTAssertThrowsError(
            try ManagedConversationInputProjection.validate(
                page,
                expectedThreadID: "thread-b"
            )
        )
    }

    func testDuplicateInputIDFailsClosed() {
        let item = CodexUserInputWireItem(
            id: "duplicate",
            sequence: 1,
            timestamp: nil,
            turnId: nil,
            text: "continue",
            truncated: false,
            originalCharacterCount: 8,
            source: .unknown,
            originMessageIDHash: nil
        )
        let page = CodexUserInputPage(
            ok: true,
            schemaVersion: CodexUserInputPage.supportedSchemaVersion,
            threadId: "thread",
            source: "codex_rollout_jsonl",
            sourceAvailable: true,
            sourceRevision: "sha256:" + String(repeating: "b", count: 64),
            items: [item, item],
            nextCursor: nil,
            excludedNonHumanItems: 0,
            totalItems: 2
        )

        XCTAssertThrowsError(
            try ManagedConversationInputProjection.validate(
                page,
                expectedThreadID: "thread"
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedConversationInputProjectionError,
                .duplicateItem("duplicate")
            )
        }
    }

    func testCodexPaginationStopsOnRepeatedCursor() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "harvis-codex-input-pagination-" + UUID().uuidString,
                isDirectory: true
            )
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let revision = "sha256:" + String(repeating: "a", count: 64)
        let script = scripts.appendingPathComponent("harvis")
        let scriptContents = """
        #!/bin/sh
        cat <<'JSON'
        {"ok":true,"schemaVersion":"harvis.codex-user-inputs.v1","threadId":"thread","source":"codex_rollout_jsonl","sourceAvailable":true,"sourceRevision":"REVISION","items":[],"nextCursor":"repeat-cursor","excludedNonHumanItems":0,"totalItems":0}
        JSON
        """.replacingOccurrences(of: "REVISION", with: revision)
        try scriptContents.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )

        let suiteName = "ManagedConversationUserInputTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)
        model.pluginRoot = root.path

        let home = CodexHome(
            id: "fixture-home",
            label: "Fixture Codex",
            accountNote: nil,
            path: root.path,
            source: "default",
            model: nil,
            provider: nil,
            endpointHost: nil,
            hasAuth: false,
            accountEmail: nil,
            authStatus: "missing",
            authExpiresAt: nil,
            authNote: nil,
            hasConfig: false,
            skillCount: 0,
            quotaMode: nil,
            quotaNote: nil
        )
        let summary = CodexThreadSummary(
            id: "thread",
            title: "Fixture thread",
            titleSource: "test",
            hasMeaningfulTitle: true,
            createdAt: 1,
            updatedAt: 2,
            tokensUsed: 0,
            model: nil,
            cwd: root.path,
            archived: false,
            running: false,
            threadSource: nil,
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadId: nil,
            agentDepth: nil,
            rootThreadId: "thread",
            familyActivity: nil
        )
        model.codexHomes = [home]
        model.codexThreadSnapshotsByHomeID[home.id] = CodexThreadSnapshot(
            updatedAt: Date(),
            threads: [summary]
        )

        let thread = ManagedChatThread(codex: summary, sourceScope: home.id)
        await model.refreshConversationInputs(for: thread, force: true)

        let state = try XCTUnwrap(
            model.managedConversationInputStates[model.managedChatStorageKey(thread)]
        )
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.error?.contains("游标重复") == true)
    }

    func testPreparingAnotherPanelDropsRawTextButRetainsEvidenceStamp() throws {
        let model = HarvisRuntimeModel()
        let first = thread(id: "first")
        let second = thread(id: "second")
        let firstKey = model.managedChatStorageKey(first)
        model.managedConversationInputStates[firstKey] = ManagedConversationUserInputState(
            targetKey: firstKey,
            provider: .dsh,
            sourceAvailable: true,
            sourceRevision: "sha256:" + String(repeating: "c", count: 64),
            items: [
                ManagedConversationUserInput(
                    id: "private",
                    sequence: 1,
                    turnID: nil,
                    timestamp: nil,
                    text: "private user text",
                    originalCharacterCount: 17,
                    truncated: false,
                    source: .human
                ),
            ],
            totalCount: 1
        )

        model.prepareConversationInputPanel(for: second)

        let scrubbed = try XCTUnwrap(
            model.managedConversationInputStates[firstKey]
        )
        XCTAssertTrue(scrubbed.items.isEmpty)
        XCTAssertEqual(
            scrubbed.sourceRevision,
            "sha256:" + String(repeating: "c", count: 64)
        )
        XCTAssertEqual(scrubbed.totalCount, 1)
    }

    private func thread(id: String) -> ManagedChatThread {
        ManagedChatThread(
            provider: .dsh,
            sourceScope: "dsh-home/web",
            sourceID: id,
            title: id,
            titleSource: nil,
            hasMeaningfulTitle: true,
            createdAt: 1,
            updatedAt: 2,
            tokensUsed: 0,
            model: nil,
            cwd: "/tmp/\(id)",
            archived: false,
            running: false,
            sourceStatus: nil,
            threadSource: "dsh",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadID: nil,
            rootThreadId: "dsh::dsh-home/web::\(id)",
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
