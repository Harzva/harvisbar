import Foundation
import XCTest
@testable import HarvisBar

final class CodexProfileEnvironmentTests: XCTestCase {
    func testSelectedChatGPTProfileCannotInheritAnotherProviderCredential() {
        let parent = ["HOME": "/Users/example", "PATH": "/usr/bin", "HTTPS_PROXY": "http://localhost:7890",
                      "CODEX_HOME": "/other", "OPENAI_API_KEY": "wrong-account", "OPENAI_BASE_URL": "https://wrong.example",
                      "CUSTOM_API_TOKEN": "wrong-account", "CODEX_THREAD_ID": "parent-thread"]
        let isolated = CodexProfileEnvironmentPolicy.chatGPTProfile.environment(homePath: "/selected", parent: parent)
        XCTAssertEqual(isolated["CODEX_HOME"], "/selected")
        XCTAssertEqual(isolated["HTTPS_PROXY"], parent["HTTPS_PROXY"])
        XCTAssertEqual(isolated["HOME"], parent["HOME"])
        XCTAssertNil(isolated["OPENAI_API_KEY"])
        XCTAssertNil(isolated["OPENAI_BASE_URL"])
        XCTAssertNil(isolated["CUSTOM_API_TOKEN"])
        XCTAssertNil(isolated["CODEX_THREAD_ID"])
        XCTAssertEqual(CodexProfileEnvironmentPolicy.inherited.environment(homePath: "/selected", parent: parent)["OPENAI_API_KEY"], "wrong-account")
    }

    func testTokenRefreshPreservesGenerationButWorkspaceOrConfigurationChangeDoesNot() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAuth(root, account: "workspace-a", refresh: "first")
        let original = CodexProfileEnvironmentPolicy.chatGPTProfile.fingerprint(homePath: root.path)
        try writeAuth(root, account: "workspace-a", refresh: "refreshed")
        XCTAssertEqual(CodexProfileEnvironmentPolicy.chatGPTProfile.fingerprint(homePath: root.path), original)
        try writeAuth(root, account: "workspace-b", refresh: "refreshed")
        XCTAssertNotEqual(CodexProfileEnvironmentPolicy.chatGPTProfile.fingerprint(homePath: root.path), original)
        let changedAccount = CodexProfileEnvironmentPolicy.chatGPTProfile.fingerprint(homePath: root.path)
        try "model = \"changed-model\"".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(CodexProfileEnvironmentPolicy.chatGPTProfile.fingerprint(homePath: root.path), changedAccount)
    }

    func testProfileReplacementInvalidatesConnectionBeforeNextRequest() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAuth(root, account: "workspace-a", refresh: "first")
        let fake = try CodexAppServerTestSupport.makeFakeExecutable(in: root)
        let connection = CodexAppServerConnection(homePath: root.path,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            executableArgumentsPrefix: [fake.path], requestTimeout: 2, environmentPolicy: .chatGPTProfile)
        let original = try await connection.connect()
        try writeAuth(root, account: "workspace-b", refresh: "second")
        do {
            _ = try await connection.request(method: "turn/start", params: .object([:]))
            XCTFail("A replaced profile must not send a turn on the old connection")
        } catch { }
        let log = try String(contentsOf: root.appendingPathComponent("request-log.txt"), encoding: .utf8)
        XCTAssertFalse(log.contains("turn/start"))
        let replacement = try await connection.connect()
        XCTAssertNotEqual(replacement, original)
        await connection.stop()
    }

    private func fixture() throws -> URL {
        let base = ProcessInfo.processInfo.environment["HARVIS_GROUP_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("profile-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeAuth(_ root: URL, account: String, refresh: String) throws {
        let value: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["account_id": account, "access_token": refresh, "refresh_token": refresh]]
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("auth.json"), options: .atomic)
    }
}
