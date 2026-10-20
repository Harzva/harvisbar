import XCTest
@testable import HarvisBar

final class CodeIdentityInspectorTests: XCTestCase {
    func testInspectsSignedSystemExecutableWithoutPersistingItsPath() throws {
        let identity = try CodeIdentityInspector().inspect(URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertFalse(identity.displayName.isEmpty)
        XCTAssertFalse(identity.signingIdentifier.isEmpty)
        XCTAssertFalse(identity.codeDirectoryHash.isEmpty)
    }

    func testCommandLookupRejectsPathTraversal() {
        let inspector = CodeIdentityInspector()
        XCTAssertNil(inspector.locateCommand(named: "../agy", environment: ["PATH": "/usr/bin"]))
    }
}
