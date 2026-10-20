import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class CodexCustomHomeThreadRefreshTests: XCTestCase {
    func testCustomDefaultAndDueRefreshPreserveCachedStateWithoutInvokingCLI() async throws {
        for mode in ["proxy", "api-key"] {
            let fixture = try makeFixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let (model, defaults, suite) = try makeModel(fixture)
            defer { defaults.removePersistentDomain(forName: suite) }
            let cachedAt = Date().addingTimeInterval(-120)
            seedSnapshots(model, fixture: fixture, at: cachedAt)
            model.selectedCodexHomeID = fixture.home.id
            model.codexThreadError = "preserve prior error"
            model.codexThreadRefreshingHomeIDs = ["unrelated-request"]

            await model.refreshCodexThreads(fixture.home)
            await model.refreshCodexThreadsIfDue()

            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.callsFile.path), mode)
            XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.home.id]?.updatedAt, cachedAt, mode)
            XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.home.id]?.threads.map(\.id), [fixture.cached.id], mode)
            XCTAssertEqual(model.lastCodexThreadRefreshAtByHomeID[fixture.home.id], cachedAt, mode)
            XCTAssertEqual(model.codexThreadError, "preserve prior error", mode)
            XCTAssertEqual(model.codexThreads.map(\.id), [fixture.cached.id], mode)
            XCTAssertEqual(model.codexThreadsSourceHomeID, fixture.home.id, mode)
            XCTAssertEqual(model.codexThreadRefreshingHomeIDs, Set(["unrelated-request"]), mode)
            XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.otherHome.id]?.updatedAt, cachedAt, mode)
            XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.otherHome.id]?.threads.map(\.id), [fixture.other.id], mode)
        }
    }

    func testExplicitCustomRefreshInvokesCLIOnceAndReplacesOnlyItsSnapshot() async throws {
        for mode in ["proxy", "api-key"] {
            let fixture = try makeFixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let (model, defaults, suite) = try makeModel(fixture)
            defer { defaults.removePersistentDomain(forName: suite) }
            let cachedAt = Date().addingTimeInterval(-120)
            seedSnapshots(model, fixture: fixture, at: cachedAt)
            model.selectedCodexHomeID = fixture.home.id
            model.codexThreadError = "old discovery failure"
            let started = Date()

            await model.refreshCodexThreads(fixture.home, userInitiated: true)

            try assertOneCLIInvocation(fixture)
            XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.home.id]?.threads.map(\.id), [fixture.fresh.id], mode)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.codexThreadSnapshotsByHomeID[fixture.home.id]?.updatedAt), started, mode)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.lastCodexThreadRefreshAtByHomeID[fixture.home.id]), started, mode)
            XCTAssertEqual(model.codexThreads.map(\.id), [fixture.fresh.id], mode)
            XCTAssertEqual(model.codexThreadsSourceHomeID, fixture.home.id, mode)
            XCTAssertNil(model.codexThreadError, mode)
            XCTAssertTrue(model.codexThreadRefreshingHomeIDs.isEmpty, mode)
            XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.otherHome.id]?.updatedAt, cachedAt, mode)
            XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.otherHome.id]?.threads.map(\.id), [fixture.other.id], mode)
            XCTAssertEqual(model.lastCodexThreadRefreshAtByHomeID[fixture.otherHome.id], cachedAt, mode)
        }
    }

    func testExplicitCustomRefreshDoesNotOverwriteAnotherSelectedHomesErrorOrProjection() async throws {
        let fixture = try makeFixture(mode: "proxy")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (model, defaults, suite) = try makeModel(fixture)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.codexHomes = [fixture.home, fixture.otherHome]
        let cachedAt = Date().addingTimeInterval(-120)
        seedSnapshots(model, fixture: fixture, at: cachedAt)
        model.selectedCodexHomeID = fixture.otherHome.id
        model.codexThreadError = "other Home error"

        await model.refreshCodexThreads(fixture.home, userInitiated: true)

        try assertOneCLIInvocation(fixture)
        XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.home.id]?.threads.map(\.id), [fixture.fresh.id])
        XCTAssertEqual(model.selectedCodexHomeID, fixture.otherHome.id)
        XCTAssertEqual(model.codexThreadsSourceHomeID, fixture.otherHome.id)
        XCTAssertEqual(model.codexThreads.map(\.id), [fixture.other.id])
        XCTAssertEqual(model.codexThreadError, "other Home error")
        XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.otherHome.id]?.updatedAt, cachedAt)
        XCTAssertEqual(model.lastCodexThreadRefreshAtByHomeID[fixture.otherHome.id], cachedAt)
    }

    func testSubscriptionDefaultRefreshStillInvokesCLIAndUpdatesSnapshot() async throws {
        let fixture = try makeFixture(mode: "subscription")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (model, defaults, suite) = try makeModel(fixture)
        defer { defaults.removePersistentDomain(forName: suite) }
        let cachedAt = Date().addingTimeInterval(-120)
        seedSnapshots(model, fixture: fixture, at: cachedAt)
        model.selectedCodexHomeID = fixture.home.id
        let started = Date()

        await model.refreshCodexThreads(fixture.home)

        try assertOneCLIInvocation(fixture)
        XCTAssertEqual(model.codexThreadSnapshotsByHomeID[fixture.home.id]?.threads.map(\.id), [fixture.fresh.id])
        XCTAssertEqual(model.codexThreads.map(\.id), [fixture.fresh.id])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.lastCodexThreadRefreshAtByHomeID[fixture.home.id]), started)
        XCTAssertNil(model.codexThreadError)
    }

    private struct Fixture {
        let root: URL
        let pluginRoot: URL
        let callsFile: URL
        let argumentsFile: URL
        let home: CodexHome
        let otherHome: CodexHome
        let cached: CodexThreadSummary
        let fresh: CodexThreadSummary
        let other: CodexThreadSummary
    }

    private func makeFixture(mode: String) throws -> Fixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Harvis custom refresh \(UUID().uuidString)", isDirectory: true)
        let pluginRoot = root.appendingPathComponent("plugin's local root", isDirectory: true)
        let scripts = pluginRoot.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("harvis")
        let home = makeHome("target", mode: mode, root: root)
        let otherHome = makeHome("other", mode: "subscription", root: root)
        let cached = thread("cached-target", root: root)
        let fresh = thread("fresh-target", root: root)
        let other = thread("cached-other", root: root)
        let threadObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh))
        let responseData = try JSONSerialization.data(withJSONObject: [
            "ok": true, "home": home.path, "items": [threadObject]
        ])
        let response = String(decoding: responseData, as: UTF8.self)
        let contents = """
        #!/bin/sh
        set -eu
        printf 'call\\n' >> "$0.calls"
        printf '%s\\n' "$@" > "$0.args"
        cat <<'JSON'
        \(response)
        JSON
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return Fixture(
            root: root, pluginRoot: pluginRoot,
            callsFile: URL(fileURLWithPath: script.path + ".calls"),
            argumentsFile: URL(fileURLWithPath: script.path + ".args"),
            home: home, otherHome: otherHome, cached: cached, fresh: fresh, other: other
        )
    }

    private func makeModel(_ fixture: Fixture) throws -> (HarvisRuntimeModel, UserDefaults, String) {
        let suite = "CodexCustomHomeThreadRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = HarvisRuntimeModel(
            defaults: defaults,
            codexThreadSnapshotStore: IgnoringCustomRefreshSnapshotStore()
        )
        model.pluginRoot = fixture.pluginRoot.path
        model.codexHomes = [fixture.home]
        return (model, defaults, suite)
    }

    private func seedSnapshots(_ model: HarvisRuntimeModel, fixture: Fixture, at date: Date) {
        model.codexThreadSnapshotsByHomeID = [
            fixture.home.id: CodexThreadSnapshot(updatedAt: date, threads: [fixture.cached]),
            fixture.otherHome.id: CodexThreadSnapshot(updatedAt: date, threads: [fixture.other])
        ]
        model.lastCodexThreadRefreshAtByHomeID = [fixture.home.id: date, fixture.otherHome.id: date]
    }

    private func assertOneCLIInvocation(_ fixture: Fixture) throws {
        let calls = try String(contentsOf: fixture.callsFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(calls, ["call"])
        let arguments = try String(contentsOf: fixture.argumentsFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(arguments, ["codex", "chats", "--home", fixture.home.path, "--limit", "100"])
    }

    private func makeHome(_ id: String, mode: String, root: URL) -> CodexHome {
        CodexHome(
            id: id, label: "Fixture \(id)", accountNote: "Fixture \(id)",
            path: root.appendingPathComponent("CODEX HOME \(id)'s path", isDirectory: true).path,
            source: mode == "subscription" ? "default" : "harvis-configured",
            model: mode == "subscription" ? "subscription-model" : "deepseek-flash",
            provider: mode == "subscription" ? "openai" : "DeepSeek",
            endpointHost: nil, hasAuth: mode == "subscription",
            accountEmail: mode == "subscription" ? "\(id)@example.test" : nil,
            authStatus: mode == "subscription" ? "valid" : "missing",
            authExpiresAt: nil, authNote: nil, hasConfig: true, skillCount: 0,
            quotaMode: mode, quotaNote: nil
        )
    }

    private func thread(_ id: String, root: URL) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id, title: "Fixture \(id)", titleSource: "test", hasMeaningfulTitle: true,
            createdAt: 1, updatedAt: 2, tokensUsed: 0, model: "fixture-model",
            cwd: root.path, archived: false, running: false, threadSource: "main",
            agentNickname: nil, agentRole: nil, agentPath: nil, parentThreadId: nil,
            agentDepth: nil, rootThreadId: id, familyActivity: nil
        )
    }
}

private actor IgnoringCustomRefreshSnapshotStore: CodexThreadSnapshotStoring {
    func load(now: Date) throws -> [String: CodexThreadSnapshot] { [:] }
    func save(_ threads: [CodexThreadSummary], for homeID: String, now: Date) throws {}
}
