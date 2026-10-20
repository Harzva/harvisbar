import Foundation
import XCTest
@testable import HarvisBar

final class CodexCLIAlignmentTests: XCTestCase {
    func testDecodesMismatchWithoutTreatingAppBundleAsAlignmentTarget() throws {
        let output = #"{"schema":"harvis.codex-cli-alignment.v1","sampled_at":"2026-08-23T07:00:00+00:00","local":{"label":"Mini Terminal","host":null,"path":"/Users/example/.local/bin/codex","version":"0.146.0","available":true,"error":null},"remote":{"label":"Studio Terminal","host":"studio","path":"/Users/example/.local/bin/codex","version":"0.149.0","available":true,"error":null},"app_bundled":{"label":"Codex App","host":null,"path":"/Applications/ChatGPT.app/Contents/Resources/codex","version":"0.148.0-alpha.21","available":true,"error":null},"aligned":false,"action_message":null}"#

        let status = try HarvisRuntimeModel.decodeCodexCLIAlignmentStatus(output)

        XCTAssertEqual(status.local.version, "0.146.0")
        XCTAssertEqual(status.remote.version, "0.149.0")
        XCTAssertEqual(status.appBundled.version, "0.148.0-alpha.21")
        XCTAssertTrue(status.terminalVersionsAvailable)
        XCTAssertFalse(status.aligned)
        XCTAssertEqual(status.stateLabel, "版本不一致")
    }

    func testAlignedStateOnlyRequiresTheTwoTerminalVersions() throws {
        let output = #"{"schema":"harvis.codex-cli-alignment.v1","sampled_at":null,"local":{"label":"Mini Terminal","host":null,"path":"/mini/codex","version":"0.149.0","available":true,"error":null},"remote":{"label":"Studio Terminal","host":"studio","path":"/studio/codex","version":"0.149.0","available":true,"error":null},"app_bundled":{"label":"Codex App","host":null,"path":"/app/codex","version":"0.148.0-alpha.21","available":true,"error":null},"aligned":true,"action_message":"done"}"#

        let status = try HarvisRuntimeModel.decodeCodexCLIAlignmentStatus(output)

        XCTAssertTrue(status.aligned)
        XCTAssertEqual(status.stateLabel, "已对齐")
        XCTAssertEqual(status.actionMessage, "done")
    }

    func testRejectsUnknownStatusSchema() {
        let output = #"{"schema":"future","sampled_at":null,"local":{"label":"Mini","host":null,"path":null,"version":null,"available":false,"error":null},"remote":{"label":"Studio","host":null,"path":null,"version":null,"available":false,"error":null},"app_bundled":{"label":"App","host":null,"path":null,"version":null,"available":false,"error":null},"aligned":false,"action_message":null}"#

        XCTAssertThrowsError(try HarvisRuntimeModel.decodeCodexCLIAlignmentStatus(output))
    }
}
