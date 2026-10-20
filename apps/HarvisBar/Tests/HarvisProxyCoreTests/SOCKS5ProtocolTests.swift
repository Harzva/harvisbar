import XCTest
@testable import HarvisProxyCore

final class SOCKS5ProtocolTests: XCTestCase {
    func testNoAuthenticationHandshake() throws {
        XCTAssertEqual(SOCKS5Protocol.noAuthenticationGreeting, Data([0x05, 0x01, 0x00]))
        XCTAssertEqual(try SOCKS5Protocol.validateMethodSelection(Data([0x05, 0x00, 0xaa])), 2)
    }

    func testMethodSelectionRejectsShortOrAuthenticatedReply() {
        XCTAssertThrowsError(try SOCKS5Protocol.validateMethodSelection(Data([0x05])))
        XCTAssertThrowsError(try SOCKS5Protocol.validateMethodSelection(Data([0x05, 0x02])))
    }

    func testDomainConnectRequest() throws {
        let request = try SOCKS5Protocol.connectRequest(to: .domain("example.com"), port: 443)
        XCTAssertEqual(
            request,
            Data([0x05, 0x01, 0x00, 0x03, 0x0b] + Array("example.com".utf8) + [0x01, 0xbb])
        )
    }

    func testIPv4AndIPv6AddressValidation() {
        XCTAssertThrowsError(try SOCKS5Protocol.connectRequest(to: .ipv4([127, 0, 0]), port: 80))
        XCTAssertThrowsError(try SOCKS5Protocol.connectRequest(to: .ipv6([0, 1]), port: 80))
    }

    func testParsesReplyAndLeavesTrailingPayload() throws {
        let frame = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1e, 0xd2, 0xaa, 0xbb])
        let reply = try SOCKS5Protocol.parseConnectReply(frame)
        XCTAssertEqual(reply.boundAddress, .ipv4([127, 0, 0, 1]))
        XCTAssertEqual(reply.boundPort, 7890)
        XCTAssertEqual(reply.consumedByteCount, 10)
    }

    func testReplyParserReportsIncompleteFrames() {
        XCTAssertThrowsError(try SOCKS5Protocol.parseConnectReply(Data([0x05, 0x00, 0x00])))
        XCTAssertThrowsError(try SOCKS5Protocol.parseConnectReply(Data([0x05, 0x00, 0x00, 0x03, 0x04, 0x61])))
    }

    func testDestinationPolicyBypassesLoopbackAndPrivateNetworks() {
        XCTAssertTrue(ProxyDestinationPolicy.shouldBypass(.domain("printer.local")))
        XCTAssertTrue(ProxyDestinationPolicy.shouldBypass(.ipv4([127, 0, 0, 1])))
        XCTAssertTrue(ProxyDestinationPolicy.shouldBypass(.ipv4([10, 20, 30, 40])))
        XCTAssertTrue(ProxyDestinationPolicy.shouldBypass(.ipv4([172, 31, 1, 1])))
        XCTAssertTrue(ProxyDestinationPolicy.shouldBypass(.ipv4([192, 168, 1, 1])))
        XCTAssertTrue(ProxyDestinationPolicy.shouldBypass(.ipv6(Array(repeating: 0, count: 15) + [1])))
        XCTAssertFalse(ProxyDestinationPolicy.shouldBypass(.domain("example.com")))
        XCTAssertFalse(ProxyDestinationPolicy.shouldBypass(.ipv4([8, 8, 8, 8])))
    }
}
