import Foundation
import XCTest
@testable import HarvisBar

final class CodexThreadSnapshotStoreTests: XCTestCase {
    func testRoundTripIsPrivateAndPreservesEmptyHomeSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = CodexThreadSnapshotStore(snapshotURL: fixture.file)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        try await store.save([thread("thread-a")], for: "home-a", now: now)
        try await store.save([], for: "home-empty", now: now.addingTimeInterval(1))
        let loaded = try await store.load(now: now.addingTimeInterval(2))

        XCTAssertEqual(loaded["home-a"]?.threads.map(\.id), ["thread-a"])
        XCTAssertNotNil(loaded["home-empty"])
        XCTAssertEqual(loaded["home-empty"]?.threads.count, 0)
        XCTAssertEqual(permissions(at: fixture.file), 0o600)
        XCTAssertEqual(permissions(at: fixture.file.deletingLastPathComponent()), 0o700)
    }

    func testLoadPrunesExpiredHomesAndBoundsHomesAndThreads() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = CodexThreadSnapshotStore(
            snapshotURL: fixture.file,
            retention: 100,
            maximumHomeCount: 2,
            maximumThreadsPerHome: 2
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        try await store.save([thread("expired")], for: "expired", now: now.addingTimeInterval(-200))
        try await store.save([thread("a-1")], for: "home-a", now: now.addingTimeInterval(-2))
        try await store.save([thread("b-1")], for: "home-b", now: now.addingTimeInterval(-1))
        try await store.save(
            [thread("c-1"), thread("c-2"), thread("c-3")],
            for: "home-c",
            now: now
        )
        let loaded = try await store.load(now: now)

        XCTAssertEqual(Set(loaded.keys), ["home-b", "home-c"])
        XCTAssertEqual(loaded["home-c"]?.threads.map(\.id), ["c-1", "c-2"])
    }

    func testCorruptCacheSelfHealsOnNextSuccessfulSave() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fixture.file)
        let store = CodexThreadSnapshotStore(snapshotURL: fixture.file)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        try await store.save([thread("recovered")], for: "home", now: now)
        let loaded = try await store.load(now: now)

        XCTAssertEqual(loaded["home"]?.threads.map(\.id), ["recovered"])
    }

    @MainActor
    func testRuntimeProjectsCachedAccountImmediatelyWithoutCrossAccountRelabeling() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = CodexThreadSnapshotStore(snapshotURL: fixture.file)
        let now = Date()
        try await store.save([thread("thread-a")], for: "home-a", now: now)
        try await store.save([thread("thread-b")], for: "home-b", now: now)
        let suite = "local.harzva.harvisbar.snapshot-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("home-a", forKey: "harvisBar.selectedCodexHomeID")
        let model = HarvisRuntimeModel(
            defaults: defaults,
            codexThreadSnapshotStore: store
        )

        await model.restoreCodexThreadSnapshots()
        XCTAssertEqual(model.codexThreads.map(\.id), ["thread-a"])
        XCTAssertEqual(model.codexThreadsSourceHomeID, "home-a")

        model.selectedCodexHomeID = "home-b"
        XCTAssertEqual(model.codexThreads.map(\.id), ["thread-b"])
        XCTAssertEqual(model.codexThreadsSourceHomeID, "home-b")

        model.acceptCodexThreads([thread("late-a")], sourceHomeID: "home-a")
        XCTAssertEqual(model.codexThreads.map(\.id), ["thread-b"])
        XCTAssertEqual(model.codexThreadsSourceHomeID, "home-b")
    }

    private func makeFixture() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarvisBarSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        let file = root
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("snapshots-v1.json")
        return (root, file)
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func thread(_ id: String) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            title: "Snapshot \(id)",
            titleSource: "test",
            hasMeaningfulTitle: true,
            createdAt: 1,
            updatedAt: 2,
            tokensUsed: 3,
            model: "test-model",
            cwd: "/tmp/project",
            archived: false,
            running: false,
            threadSource: "main",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadId: nil,
            agentDepth: nil,
            rootThreadId: id,
            familyActivity: CodexThreadFamilyActivity(
                main: 0,
                subagent: 0,
                sidechat: 0,
                members: []
            )
        )
    }
}
