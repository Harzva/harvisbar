import Foundation
import XCTest
@testable import HarvisBar

final class QuickLocalToolsTests: XCTestCase {
    func testHTTPPreconditionErrorKeepsServerExplanation() {
        let error = HarvisBarError.httpStatus(
            412,
            "credential operations require the local HTTP bearer token"
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Local API returned HTTP 412: credential operations require the local HTTP bearer token"
        )
    }

    func testTaskProgressErrorProjectionIsClosedAndPathFree() {
        XCTAssertEqual(
            HarvisTaskProgressFailure.classify(
                HarvisTaskProgressClientError.httpStatus(400)
            ),
            .httpRejected
        )
        XCTAssertEqual(
            HarvisTaskProgressFailure.classify(
                NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            ),
            .permissionDenied
        )

        let rendered = HarvisTaskProgressFailure.permissionDenied.localizedSummary
        XCTAssertFalse(rendered.contains("/Users/"))
        XCTAssertFalse(rendered.contains("/Volumes/"))
        XCTAssertFalse(rendered.lowercased().contains("bearer"))
        XCTAssertFalse(rendered.lowercased().contains("token"))
    }

    func testCredentialServiceFailureSaysSecretWasNotWritten() {
        XCTAssertTrue(
            QuickLocalToolError.credentialServiceUnavailable.localizedDescription
                .contains("密钥未写入")
        )
    }

    func testCredentialJSONOpenErrorsAreActionable() {
        XCTAssertTrue(
            QuickLocalToolError.credentialJSONMissing.localizedDescription
                .contains("先保存一个密钥")
        )
        XCTAssertTrue(
            QuickLocalToolError.textEditorUnavailable.localizedDescription
                .contains("文本编辑")
        )
    }

    func testCredentialQuickEntryDerivesMetadataFromEnvironmentKey() throws {
        let metadata = try QuickCredentialMetadata.parse(
            key: "DEEPSEEK_API_KEY",
            keywords: "reasoning, 深度求索，reasoning"
        )

        XCTAssertEqual(metadata.provider, "deepseek")
        XCTAssertEqual(metadata.envVariable, "DEEPSEEK_API_KEY")
        XCTAssertEqual(metadata.sourcePath, "")
        XCTAssertEqual(metadata.keywords, ["reasoning", "深度求索"])
    }

    func testCredentialQuickEntryAcceptsAFilePath() throws {
        let metadata = try QuickCredentialMetadata.parse(
            key: "/tmp/qianwen-access.txt",
            keywords: "qwen"
        )

        XCTAssertEqual(metadata.provider, "qianwen-access")
        XCTAssertEqual(metadata.envVariable, "QIANWEN_ACCESS_API_KEY")
        XCTAssertEqual(metadata.sourcePath, "/tmp/qianwen-access.txt")
    }

    func testCredentialQuickEntryKeepsGeneratedIdentifiersASCIIOnly() throws {
        let metadata = try QuickCredentialMetadata.parse(key: "千问", keywords: "通义千问")

        XCTAssertEqual(metadata.provider, "local-key")
        XCTAssertEqual(metadata.envVariable, "HARVIS_API_KEY")
    }

    func testCredentialQuickEntryPreservesSharedSecretEnvironmentName() throws {
        let metadata = try QuickCredentialMetadata.parse(
            key: "VPN_IPSEC_SHARED_SECRET",
            keywords: "VPN,IPSec"
        )

        XCTAssertEqual(metadata.envVariable, "VPN_IPSEC_SHARED_SECRET")
        XCTAssertEqual(metadata.keywords, ["VPN", "IPSec"])
    }

    func testCredentialAgentHintContainsOnlySafeLocalMetadata() throws {
        let metadata = try QuickCredentialMetadata.parse(
            key: "/tmp/qianwen-access.txt",
            keywords: "qwen, 通义千问"
        )
        let response = try JSONDecoder().decode(
            QuickCredentialSaveResponse.self,
            from: Data(
                """
                {
                  "id": "qianwen-access-default",
                  "reference": "harvis-credential://qianwen-access-default",
                  "available": true,
                  "secret_included": false,
                  "source_path": "/tmp/qianwen-access.txt",
                  "keywords": ["qwen", "通义千问"],
                  "env_var": "QIANWEN_ACCESS_API_KEY"
                }
                """.utf8
            )
        )
        let hint = try QuickCredentialAgentHint(
            savedResponse: response,
            fallbackMetadata: metadata,
            registryPath: "/tmp/harvis/credentials/credentials.json"
        )

        XCTAssertEqual(hint.reference, "harvis-credential://qianwen-access-default")
        XCTAssertTrue(hint.text.contains("Harvis credential handoff: v1"))
        XCTAssertTrue(hint.text.contains("Environment variable: QIANWEN_ACCESS_API_KEY"))
        XCTAssertTrue(hint.text.contains("Keywords: qwen, 通义千问"))
        XCTAssertTrue(hint.text.contains("Harvis reference: harvis-credential://qianwen-access-default"))
        XCTAssertTrue(hint.text.contains("Do not read source files, export, print, paste, or log the plaintext secret."))
        XCTAssertFalse(hint.text.contains("/tmp/qianwen-access.txt"))
        XCTAssertFalse(hint.text.contains("credentials.json"))
        XCTAssertFalse(hint.text.contains("sk-test-secret-value"))
    }

    func testCredentialAgentHintUsesFallbackMetadataWithoutCopyingSourcePath() throws {
        let metadata = try QuickCredentialMetadata.parse(
            key: "DEEPSEEK_API_KEY",
            keywords: "deepseek"
        )
        let response = try JSONDecoder().decode(
            QuickCredentialSaveResponse.self,
            from: Data(
                """
                {
                  "reference": "harvis-credential://deepseek-default",
                  "available": true,
                  "secret_included": false
                }
                """.utf8
            )
        )
        let hint = try QuickCredentialAgentHint(
            savedResponse: response,
            fallbackMetadata: metadata,
            registryPath: "/tmp/harvis/credentials/credentials.json"
        )

        XCTAssertFalse(hint.text.contains("Credential file:"))
        XCTAssertFalse(hint.text.contains("credentials.json"))
        XCTAssertEqual(hint.reference, "harvis-credential://deepseek-default")
    }

    func testCredentialAgentHintRejectsUnsafeServerResponse() throws {
        let metadata = try QuickCredentialMetadata.parse(
            key: "DEEPSEEK_API_KEY",
            keywords: "deepseek"
        )
        let response = try JSONDecoder().decode(
            QuickCredentialSaveResponse.self,
            from: Data(
                """
                {
                  "reference": "harvis-credential://deepseek-default",
                  "available": true,
                  "secret_included": true
                }
                """.utf8
            )
        )

        XCTAssertThrowsError(
            try QuickCredentialAgentHint(
                savedResponse: response,
                fallbackMetadata: metadata,
                registryPath: "/tmp/harvis/credentials/credentials.json"
            )
        ) { error in
            XCTAssertEqual(
                error as? QuickLocalToolError,
                .unsafeCredentialResponse
            )
        }
    }

    func testCredentialAgentHintRejectsUnavailableReference() throws {
        let metadata = try QuickCredentialMetadata.parse(
            key: "DEEPSEEK_API_KEY",
            keywords: "deepseek"
        )
        let response = try JSONDecoder().decode(
            QuickCredentialSaveResponse.self,
            from: Data(
                """
                {
                  "reference": "harvis-credential://deepseek-default",
                  "available": false,
                  "secret_included": false
                }
                """.utf8
            )
        )

        XCTAssertThrowsError(
            try QuickCredentialAgentHint(
                savedResponse: response,
                fallbackMetadata: metadata,
                registryPath: "/tmp/harvis/credentials/credentials.json"
            )
        )
    }

    @MainActor
    func testCredentialRegistryPathUsesConfiguredProfileRoot() {
        let suiteName = "QuickLocalToolsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)

        model.profileRoot = "/tmp/custom-harvis-profile"

        XCTAssertEqual(
            model.quickCredentialRegistryPath,
            "/tmp/custom-harvis-profile/credentials/credentials.json"
        )
    }

    @MainActor
    func testLocalWebURLsNeverCarryBearerTokens() throws {
        let suiteName = "QuickLocalToolsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarvisRuntimeModel(defaults: defaults)

        let url = try XCTUnwrap(model.localURL(
            path: "/studio/",
            extraQueryItems: [URLQueryItem(name: "view", value: "settings")]
        ))

        XCTAssertNil(url.fragment)
        XCTAssertFalse(url.absoluteString.contains("token="))
    }

    func testCopyAvoidsOverwritingAnExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harvis-copy-tests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = sourceDirectory.appendingPathComponent("sample.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destinationDirectory.appendingPathComponent("sample.txt"))

        let summary = try LocalFileCopy.copy([source], to: destinationDirectory)

        XCTAssertEqual(summary.copiedCount, 1)
        XCTAssertEqual(
            try String(contentsOf: destinationDirectory.appendingPathComponent("sample.txt")),
            "old"
        )
        XCTAssertEqual(
            try String(contentsOf: destinationDirectory.appendingPathComponent("sample 2.txt")),
            "new"
        )
    }
}
