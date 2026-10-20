import Foundation
import XCTest
@testable import HarvisBar

final class AgentLauncherTests: XCTestCase {
    func testLaunchDescriptorDecodesAndRemainsOptionalForOlderRuntime() throws {
        let current = try harness(
            #"""
            {
              "id": "codex",
              "launch": {
                "launcherID": "harvis.cli.codex",
                "productID": "codex",
                "kind": "cli",
                "mode": "new-terminal-session",
                "workingDirectoryPolicy": "workspace-root"
              }
            }
            """#
        )
        let legacy = try harness(#"{"id":"codex","cliCommand":"codex"}"#)

        XCTAssertEqual(current.launch?.launcherID, "harvis.cli.codex")
        XCTAssertEqual(current.launch?.productID, "codex")
        XCTAssertEqual(current.launch?.kind, "cli")
        XCTAssertEqual(current.launch?.mode, "new-terminal-session")
        XCTAssertEqual(current.launch?.workingDirectoryPolicy, "workspace-root")
        XCTAssertNil(legacy.launch)
    }

    func testCLIUsesManagedExecutableInsteadOfAPICommand() throws {
        let item = try harness(
            #"""
            {
              "id": "codex",
              "label": "Codex CLI",
              "runtime": "codex-cli",
              "model": "openai:gpt-5-codex",
              "status": "ready",
              "summary": "Route is ready.",
              "cliPresent": true,
              "cliCommand": "/tmp/untrusted-command --delete-everything",
              "launch": {
                "launcherID": "harvis.cli.codex",
                "productID": "codex",
                "kind": "cli",
                "mode": "new-terminal-session",
                "workingDirectoryPolicy": "workspace-root"
              }
            }
            """#
        )

        let targets = AgentLauncherCatalog.cliTargets(
            harnesses: [item],
            searchPaths: ["/managed/bin"],
            isExecutable: { $0 == "/managed/bin/codex" }
        )

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].resolvedResourceURL?.path, "/managed/bin/codex")
        XCTAssertEqual(targets[0].statusCode, "ready")
        XCTAssertTrue(targets[0].isLaunchable)
        XCTAssertFalse(targets[0].detailSummary.contains("/tmp/untrusted-command"))

        let command = AgentLauncherCommandBuilder.terminalCommand(
            executableURL: try XCTUnwrap(targets[0].resolvedResourceURL),
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        )
        XCTAssertEqual(command, "cd '/tmp/workspace' && exec '/managed/bin/codex'")
        XCTAssertFalse(command.contains("untrusted-command"))
    }

    func testEveryDeclaredCLITargetIsRetainedWhenExecutableIsMissing() throws {
        let codex = try managedHarness(id: "codex", launcherID: "harvis.cli.codex")
        let dsh = try managedHarness(id: "dsh", launcherID: "harvis.cli.dsh")

        let targets = AgentLauncherCatalog.cliTargets(
            harnesses: [codex, dsh],
            searchPaths: ["/managed/bin"],
            isExecutable: { $0.hasSuffix("/codex") }
        )

        XCTAssertEqual(targets.map(\.productID), ["codex", "dsh"])
        XCTAssertEqual(targets[0].availability, .available)
        XCTAssertEqual(targets[1].availability, .missing)
        XCTAssertFalse(targets[1].isLaunchable)
        XCTAssertEqual(targets[1].buttonLabel, "Open CLI")
    }

    func testUnknownLauncherIsRetainedButCannotExecute() throws {
        let item = try managedHarness(
            id: "future-cli",
            launcherID: "harvis.cli.future"
        )

        let targets = AgentLauncherCatalog.cliTargets(
            harnesses: [item],
            searchPaths: ["/managed/bin"],
            isExecutable: { _ in true }
        )

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].availability, .unsupported)
        XCTAssertFalse(targets[0].isLaunchable)
        XCTAssertNil(targets[0].resolvedResourceURL)
    }

    func testCXSparkPresetNeverBecomesACLIEvenWithForgedDescriptor() throws {
        let spark = try managedHarness(
            id: "cxspark",
            launcherID: "harvis.cli.codex",
            productID: "codex"
        )

        let targets = AgentLauncherCatalog.cliTargets(
            harnesses: [spark],
            searchPaths: ["/managed/bin"],
            isExecutable: { _ in true }
        )

        XCTAssertTrue(targets.isEmpty)
    }

    func testTerminalCommandQuotesWorkspaceAndExecutable() {
        let command = AgentLauncherCommandBuilder.terminalCommand(
            executableURL: URL(fileURLWithPath: "/opt/Agent's Tools/bin/codex"),
            workspaceURL: URL(fileURLWithPath: "/Volumes/Team's Work", isDirectory: true)
        )

        XCTAssertEqual(
            command,
            "cd '/Volumes/Team'\\''s Work' && exec '/opt/Agent'\\''s Tools/bin/codex'"
        )
    }

    func testExecutableSearchPathsRejectRelativeEntriesAndPreserveOrder() {
        let paths = AgentLauncherCatalog.executableSearchPaths(
            environment: ["PATH": "relative:/one:/two:/one"],
            homeDirectory: "/home/example"
        )

        XCTAssertEqual(Array(paths.prefix(2)), ["/one", "/two"])
        XCTAssertFalse(paths.contains("relative"))
        XCTAssertEqual(paths.filter { $0 == "/one" }.count, 1)
        XCTAssertTrue(paths.contains("/home/example/.local/bin"))
    }

    func testExecutableResolutionRejectsDirectoryWithManagedCLIName() throws {
        let spec = try XCTUnwrap(AgentLauncherCatalog.managedCLILaunchers.first)
        let executable = AgentLauncherCatalog.executableURL(
            for: spec,
            searchPaths: ["/managed/bin"],
            isExecutable: { $0 == "/managed/bin/codex" },
            isDirectory: { $0 == "/managed/bin/codex" }
        )

        XCTAssertNil(executable)
    }

    func testDesktopCatalogRetainsEveryMissingApplication() {
        let targets = AgentLauncherCatalog.desktopTargets(
            bundleURLForIdentifier: { _ in nil },
            applicationURLForName: { _ in nil },
            isRunning: { _, _ in false }
        )

        XCTAssertEqual(targets.count, AgentLauncherCatalog.managedDesktopLaunchers.count)
        XCTAssertEqual(targets.count, 10)
        XCTAssertTrue(targets.allSatisfy { $0.availability == .missing })
        XCTAssertTrue(targets.allSatisfy { !$0.isLaunchable })
        XCTAssertTrue(targets.allSatisfy { $0.buttonLabel == "Open" })
    }

    func testDesktopResolutionPrefersBundleIdentifierAndMarksRunning() throws {
        let spec = try XCTUnwrap(AgentLauncherCatalog.managedDesktopLaunchers.first)
        let bundleURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
        var fallbackWasCalled = false

        let target = try XCTUnwrap(
            AgentLauncherCatalog.desktopTargets(
                specs: [spec],
                bundleURLForIdentifier: { identifier in
                    XCTAssertEqual(identifier, "com.openai.codex")
                    return bundleURL
                },
                applicationURLForName: { _ in
                    fallbackWasCalled = true
                    return URL(fileURLWithPath: "/Applications/Wrong.app")
                },
                isRunning: { identifier, url in
                    identifier == spec.bundleIdentifier && url == bundleURL
                }
            ).first
        )

        XCTAssertFalse(fallbackWasCalled)
        XCTAssertEqual(target.resolvedResourceURL, bundleURL)
        XCTAssertEqual(target.availability, .running)
        XCTAssertEqual(target.statusCode, "running")
        XCTAssertEqual(target.buttonLabel, "Go to")
        XCTAssertEqual(target.buttonSystemImage, "arrow.up.forward.app")
        XCTAssertEqual(target.accessibilityLabel, "Go to Codex Desktop")
    }

    func testDesktopResolutionFallsBackToManagedApplicationName() throws {
        let spec = try XCTUnwrap(AgentLauncherCatalog.managedDesktopLaunchers.first)
        let fallbackURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)

        let target = try XCTUnwrap(
            AgentLauncherCatalog.desktopTargets(
                specs: [spec],
                bundleURLForIdentifier: { _ in nil },
                applicationURLForName: { name in
                    name == "ChatGPT" ? fallbackURL : nil
                },
                isRunning: { _, _ in false }
            ).first
        )

        XCTAssertEqual(target.resolvedResourceURL, fallbackURL)
        XCTAssertEqual(target.availability, .available)
        XCTAssertTrue(target.isLaunchable)
        XCTAssertEqual(target.buttonLabel, "Open")
    }

    private func managedHarness(
        id: String,
        launcherID: String,
        productID: String? = nil
    ) throws -> AgentHarnessItem {
        try harness(
            """
            {
              "id": "\(id)",
              "label": "\(id)",
              "runtime": "\(id)",
              "model": "test:model",
              "status": "ready",
              "launch": {
                "launcherID": "\(launcherID)",
                "productID": "\(productID ?? id)",
                "kind": "cli",
                "mode": "new-terminal-session",
                "workingDirectoryPolicy": "workspace-root"
              }
            }
            """
        )
    }

    private func harness(_ json: String) throws -> AgentHarnessItem {
        try JSONDecoder().decode(AgentHarnessItem.self, from: Data(json.utf8))
    }
}
