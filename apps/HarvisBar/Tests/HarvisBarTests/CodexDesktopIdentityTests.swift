import Foundation
import XCTest
@testable import HarvisBar

final class CodexDesktopIdentityTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/fixture/user", isDirectory: true)

    func testExplicitHomeWithSpacesOverridesCustomUserDataDirectory() {
        let identity = parse(arguments: ["Codex", "--user-data-dir=/fixture/app data/account one"],
                             environment: ["CODEX_HOME=/fixture/accounts/account one", "HOME=/different/root"])
        XCTAssertEqual(identity, CodexDesktopProcessIdentity(
            pid: 42, homePath: "/fixture/accounts/account one", userDataDir: "/fixture/app data/account one"
        ))
    }

    func testSplitUserDataDirectoryArgument() {
        let identity = parse(arguments: ["Codex", "--user-data-dir", "/fixture/app data/account two"],
                             environment: ["CODEX_HOME=/fixture/accounts/two"])
        XCTAssertEqual(identity?.homePath, "/fixture/accounts/two")
        XCTAssertEqual(identity?.userDataDir, "/fixture/app data/account two")
    }

    func testDefaultAccountRequiresDefaultUserDataAndExpectedHome() {
        XCTAssertEqual(parse()?.homePath, "/fixture/user/.codex")
        XCTAssertEqual(parse(environment: ["HOME=/fixture/user"])?.homePath, "/fixture/user/.codex")
        let defaultUserData = parse(arguments: ["Codex", "--user-data-dir=/fixture/user/Library/Application Support/Codex"])
        XCTAssertEqual(defaultUserData?.homePath, "/fixture/user/.codex")
        XCTAssertNil(parse(arguments: ["Codex", "--user-data-dir=/fixture/custom-profile"])?.homePath)
        XCTAssertNil(parse(environment: ["HOME=/fixture/another-user"])?.homePath)
        XCTAssertNil(parse(environment: ["HOME=relative"])?.homePath)
        XCTAssertNil(parse(environment: ["HOME="])?.homePath)
    }

    func testInvalidExplicitHomeNeverFallsBackToDefaultAccount() {
        for value in ["", "relative/account", "~/account", " file:///account"] {
            XCTAssertNil(parse(environment: ["CODEX_HOME=\(value)"]), "Invalid override: \(value)")
        }
        XCTAssertNil(parse(environment: ["CODEX_HOME=/fixture/one", "CODEX_HOME=/fixture/two"]))
        XCTAssertNil(parse(environment: ["CODEX_HOME"]))
    }

    func testElectronUserDataEnvironmentPreventsGuessingTheDefaultAccount() {
        let custom = parse(environment: ["CODEX_ELECTRON_USER_DATA_PATH=/fixture/custom data/account"])
        XCTAssertNotNil(custom)
        XCTAssertNil(custom?.homePath)
        XCTAssertEqual(custom?.userDataDir, "/fixture/custom data/account")

        let standard = parse(environment: [
            "CODEX_ELECTRON_USER_DATA_PATH=/fixture/user/Library/Application Support/Codex",
        ])
        XCTAssertEqual(standard?.homePath, "/fixture/user/.codex")
        XCTAssertEqual(standard?.userDataDir, "/fixture/user/Library/Application Support/Codex")
    }

    func testExplicitHomeRemainsAuthoritativeWithCustomElectronUserData() {
        for environment in [
            ["CODEX_HOME=/fixture/account", "CODEX_ELECTRON_USER_DATA_PATH=/fixture/custom data"],
            ["CODEX_ELECTRON_USER_DATA_PATH=/fixture/custom data", "CODEX_HOME=/fixture/account"],
        ] {
            let identity = parse(environment: environment)
            XCTAssertEqual(identity?.homePath, "/fixture/account")
            XCTAssertEqual(identity?.userDataDir, "/fixture/custom data")
        }
    }

    func testInvalidOrDuplicateElectronUserDataEnvironmentFailsClosed() {
        for value in ["", "relative/data", "~/data", "/" + String(repeating: "a", count: 4_096)] {
            XCTAssertNil(parse(environment: ["CODEX_ELECTRON_USER_DATA_PATH=\(value)"]))
        }
        XCTAssertNil(parse(environment: ["CODEX_ELECTRON_USER_DATA_PATH"]))
        for secondValue in ["/fixture/one", "/fixture/two"] {
            XCTAssertNil(parse(environment: [
                "CODEX_ELECTRON_USER_DATA_PATH=/fixture/one",
                "CODEX_ELECTRON_USER_DATA_PATH=\(secondValue)",
            ]))
        }
    }

    func testConflictingElectronEnvironmentAndArgumentAreRejected() {
        let matching = parse(arguments: ["Codex", "--user-data-dir=/fixture/custom data"], environment: [
            "CODEX_ELECTRON_USER_DATA_PATH=/fixture/custom data/",
            "CODEX_HOME=/fixture/account",
        ])
        XCTAssertEqual(matching?.homePath, "/fixture/account")
        XCTAssertEqual(matching?.userDataDir, "/fixture/custom data")

        for home in [[], ["CODEX_HOME=/fixture/account"]] {
            XCTAssertNil(parse(arguments: ["Codex", "--user-data-dir=/fixture/argument data"], environment:
                home + ["CODEX_ELECTRON_USER_DATA_PATH=/fixture/environment data"]
            ))
        }
    }

    func testArgumentsCannotSpoofEnvironmentAndUnknownSecretsAreNotRetained() {
        let identity = parse(
            arguments: ["Codex", "CODEX_HOME=/spoofed/account", "CODEX_ELECTRON_USER_DATA_PATH=/spoofed/data", "--token=argument-secret"],
            environment: ["AUTH_TOKEN=environment-secret", "API_COOKIE=cookie-secret", "HOME=/fixture/user"]
        )
        XCTAssertEqual(identity, CodexDesktopProcessIdentity(pid: 42, homePath: "/fixture/user/.codex", userDataDir: nil))
        let rendered = String(reflecting: identity)
        for secret in ["spoofed", "argument-secret", "environment-secret", "cookie-secret", "AUTH_TOKEN"] {
            XCTAssertFalse(rendered.contains(secret))
        }
    }

    func testHelperAndAmbiguousUserDataArgumentsAreRejected() {
        for arguments in [
            ["Codex Helper", "--type=renderer"],
            ["Codex Helper", "--type", "utility"],
            ["Codex", "--user-data-dir"],
            ["Codex", "--user-data-dir="],
            ["Codex", "--user-data-dir=relative"],
            ["Codex", "--user-data-dir", "--another-switch"],
            ["Codex", "--user-data-dir=/fixture/one", "--user-data-dir=/fixture/two"],
        ] {
            XCTAssertNil(parse(arguments: arguments), "Ambiguous arguments: \(arguments)")
        }
    }

    func testMalformedBuffersFailClosed() {
        let valid = processData(arguments: ["Codex"], environment: ["CODEX_HOME=/fixture/account"])
        XCTAssertNil(CodexDesktopIdentity.parseProcessArguments(Data(), pid: 42, userRoot: root))
        XCTAssertNil(CodexDesktopIdentity.parseProcessArguments(Data(valid.prefix(3)), pid: 42, userRoot: root))
        XCTAssertNil(CodexDesktopIdentity.parseProcessArguments(Data(valid.dropLast(2)), pid: 42, userRoot: root))
        XCTAssertNil(parse(data: processData(arguments: ["Codex"], argumentCount: -1)))
        XCTAssertNil(parse(data: processData(arguments: ["Codex"], argumentCount: 0)))
        XCTAssertNil(parse(data: processData(arguments: ["Codex"], argumentCount: Int32.max)))
        XCTAssertNil(parse(data: processData(arguments: ["Codex"], argumentCount: 5)))
        XCTAssertNil(parse(data: processData(arguments: ["Codex"], executable: "relative/Codex")))
        XCTAssertNil(parse(data: processData(arguments: ["Codex"], executable: "")))
        XCTAssertNil(parse(data: Data(repeating: 0, count: 1_048_577)))

        var invalidUTF8Home = processData(arguments: ["Codex"], environment: ["CODEX_HOME=/fixture/account"])
        invalidUTF8Home[invalidUTF8Home.count - 3] = 0xFF
        XCTAssertNil(parse(data: invalidUTF8Home))
        XCTAssertNil(parse(environment: ["=invalid-environment-entry"]))
    }

    func testEmptyArgumentsAndExecutablePaddingDoNotShiftEnvironmentBoundary() {
        let identity = parse(arguments: ["Codex", "", "CODEX_HOME=/argv-spoof"],
                             environment: ["CODEX_HOME=/fixture/real-account"])
        XCTAssertEqual(identity?.homePath, "/fixture/real-account")
    }

    func testSymlinkedHomeAndUserDataPathsAreCanonicalized() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexDesktopIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let actual = fixture.appendingPathComponent("actual home", isDirectory: true)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let identity = parse(arguments: ["Codex", "--user-data-dir=\(alias.path)/app-data"], environment: [
            "CODEX_HOME=\(alias.path)/",
            "CODEX_ELECTRON_USER_DATA_PATH=\(actual.path)/app-data",
        ])
        XCTAssertEqual(identity?.homePath, actual.resolvingSymlinksInPath().path)
        XCTAssertEqual(identity?.userDataDir, actual.appendingPathComponent("app-data").resolvingSymlinksInPath().path)
    }

    func testReadRejectsInvalidOrMissingProcessWithoutFallback() {
        XCTAssertNil(CodexDesktopIdentity.read(pid: -1, userRoot: root))
        XCTAssertNil(CodexDesktopIdentity.read(pid: 0, userRoot: root))
        XCTAssertNil(CodexDesktopIdentity.read(pid: Int32.max, userRoot: root))
    }

    private func parse(
        arguments: [String] = ["Codex"],
        environment: [String] = [],
        data: Data? = nil
    ) -> CodexDesktopProcessIdentity? {
        CodexDesktopIdentity.parseProcessArguments(
            data ?? processData(arguments: arguments, environment: environment), pid: 42, userRoot: root
        )
    }

    private func processData(
        arguments: [String],
        environment: [String] = [],
        argumentCount: Int32? = nil,
        executable: String = "/Applications/Codex.app/Contents/MacOS/Codex"
    ) -> Data {
        var count = argumentCount ?? Int32(arguments.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(contentsOf: executable.utf8)
        data.append(contentsOf: [0, 0, 0])
        for field in arguments + environment {
            data.append(contentsOf: field.utf8)
            data.append(0)
        }
        data.append(0)
        return data
    }
}
