import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class HarvisGroupComposerStateTests: XCTestCase {
    func testRestartRestoresEachDraftRecipientModeAndSelectionButResetsWritePermission() async throws {
        let url = try fixtureURL(); defer { removeFixture(url) }
        let first = UUID(), second = UUID(), third = UUID(), member = UUID()
        let state = makeState(url)
        await state.activate()
        state.selectGroup(second)
        state.updateDraft(groupID: first, text: "未发送草稿", recipientMode: .recordOnly, permission: .workspaceWrite)
        state.updateDraft(groupID: second, text: "review", recipientMode: .selected([member]), permission: .discussion)
        state.updateDraft(groupID: third, text: "broadcast", recipientMode: .allMembers, permission: .discussion)
        let saved = await state.flush()
        XCTAssertTrue(saved)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(state.draft(for: first).permission, .workspaceWrite, "Closing a window does not reset its live state")

        let restored = makeState(url)
        await restored.activate()
        XCTAssertEqual(restored.selectedGroupID, second)
        XCTAssertEqual(restored.draft(for: first), .init(text: "未发送草稿", recipientMode: .recordOnly, permission: .discussion))
        XCTAssertEqual(restored.draft(for: second).recipientMode, .selected([member]))
        XCTAssertEqual(restored.draft(for: third).recipientMode, .allMembers)
        XCTAssertFalse(restored.hasUnsavedChanges)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testImmediateFlushPersistsClearedDraftInsteadOfEarlierDebouncedInput() async throws {
        let url = try fixtureURL(); defer { removeFixture(url) }
        let group = UUID()
        let state = makeState(url)
        await state.activate()
        state.updateDraft(groupID: group, text: "already submitted", recipientMode: .selected([UUID()]), permission: .discussion)
        state.updateDraft(groupID: group, text: "", recipientMode: .allMembers, permission: .discussion)
        let saved = await state.flush()
        XCTAssertTrue(saved)
        let restored = makeState(url)
        await restored.activate()
        XCTAssertEqual(restored.draft(for: group), .init())
    }

    func testDebounceSavesLatestInputWithoutExplicitFlush() async throws {
        let url = try fixtureURL(); defer { removeFixture(url) }
        let group = UUID()
        let state = HarvisGroupComposerState(store: HarvisGroupComposerStore(url: url), saveDelay: .milliseconds(15))
        await state.activate()
        for text in ["a", "ab", "最新草稿"] {
            state.updateDraft(groupID: group, text: text, recipientMode: .recordOnly, permission: .discussion)
        }
        let deadline = Date().addingTimeInterval(3)
        while state.hasUnsavedChanges && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(state.hasUnsavedChanges)
        let saved = try await HarvisGroupComposerStore(url: url).load()
        XCTAssertEqual(saved.drafts[group]?.text, "最新草稿")
        XCTAssertEqual(saved.drafts[group]?.recipientMode, .recordOnly)
    }

    func testCorruptFileIsPreservedAndRetryMergesOnlyLocallyEditedDrafts() async throws {
        let url = try fixtureURL(); defer { removeFixture(url) }
        let broken = Data("not json".utf8)
        try broken.write(to: url)
        let state = makeState(url)
        await state.activate()
        XCTAssertTrue(state.isReady)
        XCTAssertNotNil(state.lastError)
        let edited = UUID(), untouched = UUID()
        state.selectGroup(edited)
        state.updateDraft(groupID: edited, text: "保留新输入", recipientMode: .recordOnly, permission: .discussion)
        let refused = await state.flush()
        XCTAssertFalse(refused)
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), broken)

        let recovered = HarvisGroupComposerSnapshot(selectedGroupID: untouched, drafts: [
            edited: .init(text: "旧草稿"), untouched: .init(text: "另一群聊的草稿")
        ])
        try JSONEncoder().encode(recovered).write(to: url)
        await state.activate()
        XCTAssertEqual(state.selectedGroupID, edited)
        XCTAssertEqual(state.draft(for: edited).text, "保留新输入")
        XCTAssertEqual(state.draft(for: untouched).text, "另一群聊的草稿")
        let saved = await state.flush()
        XCTAssertTrue(saved)
        XCTAssertNil(state.lastError)
    }

    func testStoreRejectsStaleSaveAfterNewerRevision() async throws {
        let url = try fixtureURL(); defer { removeFixture(url) }
        let store = HarvisGroupComposerStore(url: url), group = UUID()
        let latest = HarvisGroupComposerSnapshot(selectedGroupID: group, drafts: [group: .init(text: "latest")])
        _ = try await store.save(latest, revision: 4)
        let revision = try await store.save(.init(), revision: 3)
        XCTAssertEqual(revision, 4)
        let saved = try await store.load()
        XCTAssertEqual(saved, latest)
    }

    func testSaveFailureLeavesDirtyStateAndRetryPersistsIt() async throws {
        let url = try fixtureURL(); defer { removeFixture(url) }
        let state = makeState(url), group = UUID()
        await state.activate()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.updateDraft(groupID: group, text: "不能丢失", recipientMode: .recordOnly, permission: .discussion)
        let failed = await state.flush()
        XCTAssertFalse(failed)
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertNotNil(state.lastError)
        try FileManager.default.removeItem(at: url)
        let saved = await state.flush()
        XCTAssertTrue(saved)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertNil(state.lastError)
        let restored = try await HarvisGroupComposerStore(url: url).load()
        XCTAssertEqual(restored.drafts[group]?.text, "不能丢失")
    }

    private func makeState(_ url: URL) -> HarvisGroupComposerState {
        HarvisGroupComposerState(store: HarvisGroupComposerStore(url: url), saveDelay: .seconds(60))
    }

    private func fixtureURL() throws -> URL {
        let base = ProcessInfo.processInfo.environment["HARVIS_GROUP_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("composer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("composer-v1.json")
    }

    private func removeFixture(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
