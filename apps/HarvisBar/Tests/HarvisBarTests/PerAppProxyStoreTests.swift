import HarvisProxyCore
import XCTest
@testable import HarvisBar

final class PerAppProxyStoreTests: XCTestCase {
    func testConfigurationRoundTripUsesPrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("rules.json")
        let store = PerAppProxyStore(fileURL: fileURL)
        let identity = try AppCodeIdentity(
            displayName: "Fixture App",
            signingIdentifier: "example.fixture",
            codeDirectoryHashHex: "00112233"
        )
        let configuration = try PerAppProxyConfiguration(
            isEnabled: true,
            endpoint: ProxyEndpoint(host: "127.0.0.1", port: 7890),
            rules: [.init(application: identity)]
        )

        try store.save(configuration)

        XCTAssertEqual(try store.load(), configuration)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testMissingStoreReturnsNil() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.json")
        XCTAssertNil(try PerAppProxyStore(fileURL: fileURL).load())
    }
}
