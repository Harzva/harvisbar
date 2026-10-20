import XCTest
@testable import HarvisProxyCore

final class TCPBridgeStateMachineTests: XCTestCase {
    func testHappyPathAndHalfClose() throws {
        var machine = TCPBridgeStateMachine()
        XCTAssertEqual(try machine.handle(.start), .connectingToProxy)
        XCTAssertEqual(try machine.handle(.proxyConnected), .negotiatingMethod)
        XCTAssertEqual(try machine.handle(.methodAccepted), .requestingConnection)
        XCTAssertEqual(try machine.handle(.connectionAccepted), .openingApplicationFlow)
        XCTAssertEqual(try machine.handle(.applicationFlowOpened), .copying)
        XCTAssertEqual(try machine.handle(.reachedEOF(.application)), .halfClosed(.application))
        XCTAssertEqual(try machine.handle(.reachedEOF(.proxy)), .closed)
    }

    func testFailureClosesFromAnyActiveStage() throws {
        var machine = TCPBridgeStateMachine()
        try machine.handle(.start)
        XCTAssertEqual(try machine.handle(.failed), .closed)
    }

    func testInvalidTransitionDoesNotMutateState() throws {
        var machine = TCPBridgeStateMachine()
        XCTAssertThrowsError(try machine.handle(.methodAccepted))
        XCTAssertEqual(machine.stage, .idle)
    }

    func testSameSideCannotCloseTwice() throws {
        var machine = TCPBridgeStateMachine()
        for event in [
            TCPBridgeEvent.start,
            .proxyConnected,
            .methodAccepted,
            .connectionAccepted,
            .applicationFlowOpened,
            .reachedEOF(.proxy)
        ] {
            try machine.handle(event)
        }

        XCTAssertThrowsError(try machine.handle(.reachedEOF(.proxy)))
        XCTAssertEqual(machine.stage, .halfClosed(.proxy))
    }
}
