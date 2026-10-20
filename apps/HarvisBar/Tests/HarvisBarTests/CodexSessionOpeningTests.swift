import Foundation
import XCTest
@testable import HarvisBar

@MainActor
final class CodexSessionOpeningTests: XCTestCase {
    func testOpenManagedThreadInCLIUsesSourceHomeAndExactSessionAfterSelectionSwitch() async throws {
        let fixture = try makeFixture(action: "resume-cli", responseHomeID: "home-a")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (model, defaults, suite) = try makeModel(fixture, selectedHomeID: fixture.homeB.id)
        defer { defaults.removePersistentDomain(forName: suite) }

        let card = ManagedChatThread(codex: fixture.threadA, sourceScope: fixture.homeA.id)
        XCTAssertEqual(model.selectedCodexHomeID, fixture.homeB.id)
        XCTAssertEqual(model.codexHome(for: card)?.id, fixture.homeA.id)

        let action = try XCTUnwrap(model.openManagedThreadInCLI(card))
        let succeeded = await action.value
        XCTAssertTrue(succeeded, model.lastError ?? "CLI request did not succeed")
        let arguments = try String(contentsOf: fixture.argumentsFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)

        XCTAssertEqual(
            arguments,
            [
                "codex", "resume-cli",
                "--home", fixture.homeA.path,
                "--cwd", fixture.threadA.cwd,
                "--thread-id", fixture.threadA.id
            ]
        )
        XCTAssertTrue(model.lastActionOutput?.contains("已请求") == true)
        XCTAssertEqual(model.codexHomeActionFeedback[fixture.homeA.id]?.isError, false)
        XCTAssertEqual(model.selectedCodexHomeID, fixture.homeB.id)
    }

    func testOpenManagedThreadInCLIFailsClosedForWrongScopeAndMissingSnapshot() throws {
        let fixture = try makeFixture(action: "resume-cli", responseHomeID: "home-a")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (model, defaults, suite) = try makeModel(fixture, selectedHomeID: fixture.homeB.id)
        defer { defaults.removePersistentDomain(forName: suite) }

        let wrongScope = ManagedChatThread(
            codex: fixture.threadA,
            sourceScope: "home-that-is-not-visible"
        )
        model.openManagedThreadInCLI(wrongScope)
        XCTAssertTrue(model.lastError?.contains("来源账号或会话记录") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.argumentsFile.path))

        let missing = CodexThreadSummary(
            id: "missing-thread",
            title: "Missing",
            titleSource: "test",
            hasMeaningfulTitle: true,
            createdAt: 1,
            updatedAt: 2,
            tokensUsed: 0,
            model: "fixture",
            cwd: fixture.threadA.cwd,
            archived: false,
            running: false,
            threadSource: "main",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadId: nil,
            agentDepth: nil,
            rootThreadId: "missing-thread",
            familyActivity: nil
        )
        model.openManagedThreadInCLI(
            ManagedChatThread(codex: missing, sourceScope: fixture.homeA.id)
        )
        XCTAssertTrue(model.lastError?.contains("来源账号或会话记录") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.argumentsFile.path))
    }

    func testRunCodexThreadActionRejectsMismatchedActionAndHomeID() async throws {
        let actionFixture = try makeFixture(action: "launch-cli", responseHomeID: "home-a")
        defer { try? FileManager.default.removeItem(at: actionFixture.root) }
        let (actionModel, actionDefaults, actionSuite) = try makeModel(
            actionFixture,
            selectedHomeID: actionFixture.homeB.id
        )
        defer { actionDefaults.removePersistentDomain(forName: actionSuite) }

        let wrongAction = await actionModel.runCodexThreadAction(
            "resume-cli",
            home: actionFixture.homeA,
            threadID: actionFixture.threadA.id,
            workingDirectory: actionFixture.threadA.cwd
        )
        XCTAssertFalse(wrongAction)
        XCTAssertTrue(actionModel.lastError?.contains("会话恢复") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: actionFixture.argumentsFile.path))

        let homeFixture = try makeFixture(action: "resume-cli", responseHomeID: "home-b")
        defer { try? FileManager.default.removeItem(at: homeFixture.root) }
        let (homeModel, homeDefaults, homeSuite) = try makeModel(
            homeFixture,
            selectedHomeID: homeFixture.homeB.id
        )
        defer { homeDefaults.removePersistentDomain(forName: homeSuite) }

        let wrongHome = await homeModel.runCodexThreadAction(
            "resume-cli",
            home: homeFixture.homeA,
            threadID: homeFixture.threadA.id,
            workingDirectory: homeFixture.threadA.cwd
        )
        XCTAssertFalse(wrongHome)
        XCTAssertTrue(homeModel.lastError?.contains("目标账号") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: homeFixture.argumentsFile.path))
    }

    private struct ServiceFixture {
        let root: URL
        let pluginRoot: URL
        let argumentsFile: URL
        let homeA: CodexHome
        let homeB: CodexHome
        let threadA: CodexThreadSummary
        let threadB: CodexThreadSummary
    }

    private func makeFixture(
        action: String,
        responseHomeID: String
    ) throws -> ServiceFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Harvis Codex Session \(UUID().uuidString)", isDirectory: true)
        let pluginRoot = root.appendingPathComponent(
            "plugin root's space",
            isDirectory: true
        )
        let scripts = pluginRoot.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)

        let script = scripts.appendingPathComponent("harvis", isDirectory: false)
        let argumentsFile = URL(fileURLWithPath: script.path + ".args")
        let responseData = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "action": action,
            "homeId": responseHomeID,
            "userDataDir": NSNull(),
            "message": "synthetic response"
        ])
        let response = String(decoding: responseData, as: UTF8.self)
        let scriptContents = """
        #!/bin/sh
        set -eu
        printf '%s\\n' "$@" > "$0.args"
        cat <<'JSON'
        \(response)
        JSON
        """
        try scriptContents.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )

        let homeA = makeHome(
            id: "home-a",
            path: root.appendingPathComponent("CODEX HOME A's account", isDirectory: true)
        )
        let homeB = makeHome(
            id: "home-b",
            path: root.appendingPathComponent("CODEX HOME B", isDirectory: true)
        )
        let threadA = makeThread(
            id: "thread A's exact id",
            cwd: root.appendingPathComponent("workspace A's path", isDirectory: true).path
        )
        let threadB = makeThread(
            id: "thread-b",
            cwd: root.appendingPathComponent("workspace B", isDirectory: true).path
        )
        return ServiceFixture(
            root: root,
            pluginRoot: pluginRoot,
            argumentsFile: argumentsFile,
            homeA: homeA,
            homeB: homeB,
            threadA: threadA,
            threadB: threadB
        )
    }

    private func makeModel(
        _ fixture: ServiceFixture,
        selectedHomeID: String
    ) throws -> (HarvisRuntimeModel, UserDefaults, String) {
        let suite = "CodexSessionOpeningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = HarvisRuntimeModel(defaults: defaults)
        model.pluginRoot = fixture.pluginRoot.path
        model.codexHomes = [fixture.homeA, fixture.homeB]
        model.codexThreadSnapshotsByHomeID = [
            fixture.homeA.id: CodexThreadSnapshot(
                updatedAt: Date(),
                threads: [fixture.threadA]
            ),
            fixture.homeB.id: CodexThreadSnapshot(
                updatedAt: Date(),
                threads: [fixture.threadB]
            )
        ]
        model.selectedCodexHomeID = selectedHomeID
        return (model, defaults, suite)
    }

    private func makeHome(id: String, path: URL) -> CodexHome {
        CodexHome(
            id: id,
            label: "Fixture \(id)",
            accountNote: nil,
            path: path.path,
            source: "default",
            model: "fixture-model",
            provider: "openai",
            endpointHost: nil,
            hasAuth: false,
            accountEmail: "\(id)@example.test",
            authStatus: "missing",
            authExpiresAt: nil,
            authNote: nil,
            hasConfig: false,
            skillCount: 0,
            quotaMode: "subscription",
            quotaNote: nil
        )
    }

    private func makeThread(id: String, cwd: String) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            title: "Fixture \(id)",
            titleSource: "test",
            hasMeaningfulTitle: true,
            createdAt: 1,
            updatedAt: 2,
            tokensUsed: 0,
            model: "fixture-model",
            cwd: cwd,
            archived: false,
            running: false,
            threadSource: "main",
            agentNickname: nil,
            agentRole: nil,
            agentPath: nil,
            parentThreadId: nil,
            agentDepth: nil,
            rootThreadId: id,
            familyActivity: nil
        )
    }

}
