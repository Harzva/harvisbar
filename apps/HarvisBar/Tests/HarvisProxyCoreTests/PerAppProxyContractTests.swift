import XCTest
@testable import HarvisProxyCore

final class PerAppProxyContractTests: XCTestCase {
    func testEndpointAcceptsOnlyLoopback() throws {
        XCTAssertEqual(try ProxyEndpoint(host: " LOCALHOST ", port: 7890).host, "localhost")
        XCTAssertEqual(try ProxyEndpoint(host: "[::1]", port: 7890).host, "::1")
        XCTAssertThrowsError(try ProxyEndpoint(host: "10.0.0.2", port: 7890))
        XCTAssertThrowsError(try ProxyEndpoint(host: "127.0.0.1", port: 0))
    }

    func testIdentityRequiresSigningIdentifierAndHash() throws {
        let application = try AppCodeIdentity(
            displayName: "agy",
            signingIdentifier: "cli",
            codeDirectoryHashHex: "0011aaff"
        )

        XCTAssertTrue(application.matches(.init(
            signingIdentifier: "cli",
            codeDirectoryHash: [0x00, 0x11, 0xaa, 0xff]
        )))
        XCTAssertFalse(application.matches(.init(
            signingIdentifier: "other",
            codeDirectoryHash: [0x00, 0x11, 0xaa, 0xff]
        )))
        XCTAssertFalse(application.matches(.init(
            signingIdentifier: "cli",
            codeDirectoryHash: [0x00, 0x11, 0xaa, 0xfe]
        )))
    }

    func testConfigurationHonorsMasterAndRuleSwitches() throws {
        let identity = try AppCodeIdentity(
            displayName: "agy",
            signingIdentifier: "cli",
            codeDirectoryHashHex: "abcd"
        )
        let flow = SourceApplicationIdentity(signingIdentifier: "cli", codeDirectoryHash: [0xab, 0xcd])
        let endpoint = try ProxyEndpoint(host: "127.0.0.1", port: 7890)

        let off = try PerAppProxyConfiguration(
            isEnabled: false,
            endpoint: endpoint,
            rules: [.init(application: identity)]
        )
        XCTAssertNil(off.matchingRule(for: flow))

        let enabled = try PerAppProxyConfiguration(
            isEnabled: true,
            endpoint: endpoint,
            rules: [.init(application: identity)]
        )
        XCTAssertNotNil(enabled.matchingRule(for: flow))
    }

    func testConfigurationRejectsDuplicateRuleIDs() throws {
        let identity = try AppCodeIdentity(
            displayName: "agy",
            signingIdentifier: "cli",
            codeDirectoryHashHex: "abcd"
        )
        let id = UUID()
        let rules = [
            PerAppProxyRule(id: id, application: identity),
            PerAppProxyRule(id: id, application: identity)
        ]

        XCTAssertThrowsError(try PerAppProxyConfiguration(
            endpoint: ProxyEndpoint(host: "127.0.0.1", port: 7890),
            rules: rules
        ))
    }
}
