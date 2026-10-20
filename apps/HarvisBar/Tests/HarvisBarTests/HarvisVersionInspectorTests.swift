import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import HarvisVersionCore

final class HarvisVersionInspectorTests: XCTestCase {
    func testBuilderDerivedGoldenPassesStrictReceiptContract() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "harvis-bundle-receipt-v1", withExtension: "json"))
        let resources = try temporaryDirectory(named: "receipt")
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.copyItem(
            at: fixture,
            to: resources.appendingPathComponent("harvis-bundle-receipt.json")
        )

        let inspected = HarvisBundleReceiptReader().inspect(
            resourcesDirectory: resources.path,
            appIdentity: HarvisAppIdentity(
                bundleIdentifier: "local.harzva.harvisbar",
                executable: "HarvisBar",
                version: "0.33.0"
            )
        )

        XCTAssertEqual(inspected.status, .valid)
        XCTAssertEqual(inspected.receipt?.artifacts.records.count, 3)
        XCTAssertEqual(inspected.receipt?.provenance.sourceCommit, "485733a0550fb136ef3f0d0630d262709c6f202f")
    }

    func testReceiptRejectsCrossFieldArtifactDriftWithoutPartialReceipt() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "harvis-bundle-receipt-v1", withExtension: "json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var artifacts = try XCTUnwrap(object["artifacts"] as? [String: Any])
        artifacts["runtimeSha256"] = String(repeating: "f", count: 64)
        object["artifacts"] = artifacts
        let resources = try temporaryDirectory(named: "receipt-drift")
        defer { try? FileManager.default.removeItem(at: resources) }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: resources.appendingPathComponent("harvis-bundle-receipt.json"))

        let inspected = HarvisBundleReceiptReader().inspect(
            resourcesDirectory: resources.path,
            appIdentity: HarvisAppIdentity(bundleIdentifier: "local.harzva.harvisbar", executable: "HarvisBar", version: "0.33.0")
        )
        XCTAssertEqual(inspected.status, .invalidContract)
        XCTAssertNil(inspected.receipt)
    }

    func testStatusParserCountsRenameAsOneAndKeepsOpaquePathsOpaque() throws {
        var raw = Data(" M ordinary\0R  destination\0source\0?? ".utf8)
        raw.append(0xff)
        raw.append(0)
        XCTAssertEqual(try HarvisGitParsers.changedEntryCount(status: raw), 3)

        XCTAssertThrowsError(
            try HarvisGitParsers.changedEntryCount(status: Data("R  destination\0".utf8))
        )
        XCTAssertThrowsError(
            try HarvisGitParsers.changedEntryCount(status: Data("!! ignored\0".utf8))
        )
    }

    func testWorktreeParserRequiresDoubleNULTerminationAndClosedFieldOrder() throws {
        let oid = String(repeating: "a", count: 40)
        let raw = Data("worktree /repo\0HEAD \(oid)\0branch refs/heads/main\0locked review\0\0".utf8)
        let parsed = try HarvisGitParsers.worktrees(raw)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].headState, .attached)
        XCTAssertEqual(parsed[0].branch, "refs/heads/main")
        XCTAssertEqual(parsed[0].lockedReason, "review")

        XCTAssertThrowsError(
            try HarvisGitParsers.worktrees(Data("worktree /repo\0HEAD \(oid)\0detached\0".utf8))
        )
        XCTAssertThrowsError(
            try HarvisGitParsers.worktrees(Data("worktree /repo\0unknown value\0\0".utf8))
        )
    }

    func testGitHubRemoteSanitizerNeverPublishesCredentialOrAmbiguousURLs() {
        XCTAssertEqual(
            HarvisGitParsers.githubBrowseURL(from: "https://github.com/harzva/harvis.git"),
            "https://github.com/harzva/harvis"
        )
        for unsafe in [
            "git@github.com:harzva/harvis.git",
            "https://token@github.com/harzva/harvis.git",
            "https://github.com/harzva/harvis.git?token=secret",
            "https://github.com/harzva%2fprivate/harvis",
            "https://github.com/harzva/../private",
            "https://github.com/harzva/harvis/",
        ] {
            XCTAssertNil(HarvisGitParsers.githubBrowseURL(from: unsafe), unsafe)
        }
    }

    func testStableHelperSeparatesBindingFileAndReceiptAxes() throws {
        let home = try temporaryDirectory(named: "home")
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = home.appendingPathComponent(".harvis/bin/harvis")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helperData = Data("synthetic helper\n".utf8)
        try helperData.write(to: helper)
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        for (name, label) in [
            ("local.harzva.harvis.http.plist", "local.harzva.harvis.http"),
            ("local.harzva.harvis.tick.plist", "local.harzva.harvis.tick"),
        ] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["Label": label, "ProgramArguments": [helper.path, "serve"]],
                format: .xml,
                options: 0
            )
            try data.write(to: launchAgents.appendingPathComponent(name))
        }
        let sha = SHA256.hash(data: helperData).map { String(format: "%02x", $0) }.joined()
        let receipt = validReceipt(runtimeSize: UInt64(helperData.count), runtimeSHA: sha)

        let matched = HarvisStableHelperInspector().inspect(homeDirectory: home.path, receipt: receipt)
        XCTAssertEqual(matched.status, .matched)
        XCTAssertEqual(matched.httpLaunchBindingStatus, .valid)
        XCTAssertEqual(matched.helperFileStatus, .valid)
        XCTAssertEqual(matched.receiptMatchStatus, .matched)

        var http = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: launchAgents.appendingPathComponent("local.harzva.harvis.http.plist")),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        http["Program"] = helper.path
        let invalid = try PropertyListSerialization.data(fromPropertyList: http, format: .xml, options: 0)
        try invalid.write(to: launchAgents.appendingPathComponent("local.harzva.harvis.http.plist"))
        let bindingInvalid = HarvisStableHelperInspector().inspect(homeDirectory: home.path, receipt: receipt)
        XCTAssertEqual(bindingInvalid.status, .launchBindingInvalid)
        XCTAssertEqual(bindingInvalid.httpLaunchBindingStatus, .programPathMismatch)
        XCTAssertEqual(bindingInvalid.helperFileStatus, .valid)
        XCTAssertEqual(bindingInvalid.receiptMatchStatus, .matched)
    }

    func testRealLocalGitGoldenSliceIsReadOnlyAndRejectsUntrackedMarkerImpostor() async throws {
        let repository = try sourceTemporaryDirectory(named: "source")
        defer { try? FileManager.default.removeItem(at: repository) }
        try runGit(["init", "-b", "main"], at: repository)
        let markers: [(String, String, Int16)] = [
            ("Cargo.toml", "[workspace]\n", 0o644),
            ("apps/HarvisBar/Package.swift", "// package\n", 0o644),
            ("scripts/harvis", "#!/bin/sh\n", 0o755),
            ("schemas/bar-status.schema.json", "{}\n", 0o644),
        ]
        for (relative, contents, mode) in markers {
            let target = repository.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, atomically: true, encoding: .utf8)
            XCTAssertEqual(chmod(target.path, mode_t(mode)), 0)
        }
        try runGit(["add", "--all"], at: repository)
        try runGit(["-c", "user.name=Harvis Test", "-c", "user.email=harvis@example.invalid", "commit", "-m", "initial"], at: repository)
        let indexBefore = try Data(contentsOf: repository.appendingPathComponent(".git/index"))

        let inspected = await HarvisSourceInspector().inspect(
            selectedDirectory: repository.appendingPathComponent("apps/HarvisBar").path
        )
        XCTAssertEqual(inspected.status, .ready)
        XCTAssertEqual(inspected.git?.headState, .attached)
        XCTAssertEqual(inspected.git?.branch, "main")
        XCTAssertEqual(inspected.git?.changedFileCount, 0)
        XCTAssertEqual(try Data(contentsOf: repository.appendingPathComponent(".git/index")), indexBefore)

        try runGit(["rm", "--cached", "Cargo.toml"], at: repository)
        let rejected = await HarvisSourceInspector().inspect(selectedDirectory: repository.path)
        XCTAssertEqual(rejected.status, .notHarvis)
        XCTAssertNil(rejected.git)
    }

    func testSourceInspectorSupportsLinkedWorktreeAndRejectsBundlePayload() async throws {
        let container = try sourceTemporaryDirectory(named: "linked-worktree")
        defer { try? FileManager.default.removeItem(at: container) }
        let primary = container.appendingPathComponent("primary")
        let linked = container.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        _ = try createHarvisRepository(at: primary)
        try runGit(["worktree", "add", "-b", "linked", linked.path], at: primary)

        let inspected = await HarvisSourceInspector().inspect(
            selectedDirectory: linked.appendingPathComponent("apps/HarvisBar").path
        )
        XCTAssertEqual(inspected.status, .ready)
        XCTAssertEqual(inspected.canonicalRepositoryRoot, linked.path)
        XCTAssertEqual(inspected.git?.worktrees.count, 2)

        let bundleRejected = await HarvisSourceInspector().inspect(
            selectedDirectory: linked.path,
            appPluginRoot: linked.path
        )
        XCTAssertEqual(bundleRejected.status, .bundlePayload)
        XCTAssertNil(bundleRejected.git)
    }

    func testSourceInspectorPreflightTimeoutRunsBeforePathResolutionAndSkipsFileReads() async throws {
        let selected = "/private/tmp/harvis-tcc-blocked-\(UUID().uuidString)"

        var commandCalls = 0
        var fileReads = 0
        let commands = HarvisVersionCommandExecutor { _ in
            commandCalls += 1
            throw HarvisVersionProcessError.timedOut(executable: "/usr/bin/stat", timeout: 5)
        }
        let files = HarvisVersionFileReader { _, _, _ in
            fileReads += 1
            throw HarvisBoundedFileReaderError.unreadable
        }

        let inspected = await HarvisSourceInspector(
            commands: commands,
            files: files
        ).inspect(selectedDirectory: selected)

        XCTAssertEqual(inspected.status, HarvisSourceStatus.gitTimeout)
        XCTAssertEqual(commandCalls, 1)
        XCTAssertEqual(fileReads, 0)
    }

    func testSourceInspectorEnumerationTimeoutStopsBeforeInProcessDirectoryOpen() async throws {
        let repository = try sourceTemporaryDirectory(named: "preflight-enumeration-timeout")
        defer { try? FileManager.default.removeItem(at: repository) }

        var requests: [HarvisVersionProcessRequest] = []
        var fileReads = 0
        let commands = HarvisVersionCommandExecutor { request in
            requests.append(request)
            if request.executable == "/usr/bin/stat" {
                let output = Data("Directory\n".utf8)
                return HarvisVersionProcessDataResult(
                    standardOutput: output,
                    standardError: Data(),
                    terminationStatus: 0,
                    capturedByteCount: output.count
                )
            }
            throw HarvisVersionProcessError.timedOut(executable: request.executable, timeout: request.timeout)
        }
        let files = HarvisVersionFileReader { _, _, _ in
            fileReads += 1
            throw HarvisBoundedFileReaderError.unreadable
        }

        let inspected = await HarvisSourceInspector(
            commands: commands,
            files: files
        ).inspect(selectedDirectory: repository.path)

        XCTAssertEqual(inspected.status, .gitTimeout)
        XCTAssertEqual(requests.map(\.executable), ["/usr/bin/stat", "/usr/bin/find"])
        XCTAssertEqual(
            requests.last?.arguments,
            [repository.path + "/", "-mindepth", "1", "-maxdepth", "1", "-print", "-quit"]
        )
        XCTAssertLessThanOrEqual(requests[1].timeout, requests[0].timeout)
        XCTAssertEqual(requests[1].aggregateBytesBefore, Data("Directory\n".utf8).count)
        XCTAssertEqual(requests[0].environment, [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
            "LANG": "C",
        ])
        XCTAssertEqual(requests[1].environment, requests[0].environment)
        XCTAssertEqual(requests[0].standardOutputLimit, 64)
        XCTAssertEqual(requests[1].standardOutputLimit, 4_096)
        XCTAssertEqual(requests[0].standardErrorLimit, 4_096)
        XCTAssertEqual(requests[1].standardErrorLimit, 4_096)
        XCTAssertEqual(requests[0].aggregateLimit, 4_194_304)
        XCTAssertEqual(requests[1].aggregateLimit, 4_194_304)
        XCTAssertEqual(fileReads, 0)
    }

    func testSourceInspectorEnumerationOutputLimitIsDistinctAndSkipsFileReads() async throws {
        let repository = try sourceTemporaryDirectory(named: "preflight-enumeration-output-limit")
        defer { try? FileManager.default.removeItem(at: repository) }

        var requests: [HarvisVersionProcessRequest] = []
        var fileReads = 0
        let commands = HarvisVersionCommandExecutor { request in
            requests.append(request)
            if request.executable == "/usr/bin/stat" {
                let output = Data("Directory\n".utf8)
                return HarvisVersionProcessDataResult(
                    standardOutput: output,
                    standardError: Data(),
                    terminationStatus: 0,
                    capturedByteCount: output.count
                )
            }
            throw HarvisVersionProcessError.outputLimitExceeded(executable: request.executable)
        }
        let files = HarvisVersionFileReader { _, _, _ in
            fileReads += 1
            throw HarvisBoundedFileReaderError.unreadable
        }

        let inspected = await HarvisSourceInspector(
            commands: commands,
            files: files
        ).inspect(selectedDirectory: repository.path)

        XCTAssertEqual(inspected.status, .gitOutputLimitExceeded)
        XCTAssertEqual(requests.map(\.executable), ["/usr/bin/stat", "/usr/bin/find"])
        XCTAssertEqual(fileReads, 0)
    }

    func testSourceInspectorEnumerationNonzeroAndStderrFailOfflineBeforeFileReads() async throws {
        let repository = try sourceTemporaryDirectory(named: "preflight-enumeration-rejected")
        defer { try? FileManager.default.removeItem(at: repository) }

        let failures: [(status: Int32, stderr: Data)] = [
            (2, Data()),
            (0, Data("denied\n".utf8)),
        ]
        for failure in failures {
            var commandCalls = 0
            var fileReads = 0
            let commands = HarvisVersionCommandExecutor { request in
                commandCalls += 1
                if request.executable == "/usr/bin/stat" {
                    let output = Data("Directory\n".utf8)
                    return HarvisVersionProcessDataResult(
                        standardOutput: output,
                        standardError: Data(),
                        terminationStatus: 0,
                        capturedByteCount: output.count
                    )
                }
                return HarvisVersionProcessDataResult(
                    standardOutput: Data(),
                    standardError: failure.stderr,
                    terminationStatus: failure.status,
                    capturedByteCount: failure.stderr.count
                )
            }
            let files = HarvisVersionFileReader { _, _, _ in
                fileReads += 1
                throw HarvisBoundedFileReaderError.unreadable
            }

            let inspected = await HarvisSourceInspector(
                commands: commands,
                files: files
            ).inspect(selectedDirectory: repository.path)

            XCTAssertEqual(inspected.status, .offline)
            XCTAssertEqual(commandCalls, 2)
            XCTAssertEqual(fileReads, 0)
        }
    }

    func testSourceInspectorEmptyDirectoryPassesEnumerationBeforeNotHarvis() async throws {
        let repository = try sourceTemporaryDirectory(named: "preflight-empty-directory")
        defer { try? FileManager.default.removeItem(at: repository) }

        let inspected = await HarvisSourceInspector().inspect(selectedDirectory: repository.path)

        XCTAssertEqual(inspected.status, .notHarvis)
        XCTAssertNil(inspected.git)
    }

    func testSourceInspectorLeafSymlinkAliasRemainsSupportedAndBundleAliasIsRejected() async throws {
        let container = try sourceTemporaryDirectory(named: "preflight-leaf-symlink")
        defer { try? FileManager.default.removeItem(at: container) }
        let repository = container.appendingPathComponent("repository")
        let alias = container.appendingPathComponent("source-alias")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try createHarvisRepository(at: repository)
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: repository.path
        )

        let inspected = await HarvisSourceInspector().inspect(selectedDirectory: alias.path)
        XCTAssertEqual(inspected.status, .ready)
        XCTAssertEqual(inspected.canonicalRepositoryRoot, repository.path)

        let bundleRejected = await HarvisSourceInspector().inspect(
            selectedDirectory: alias.path,
            appPluginRoot: repository.path
        )
        XCTAssertEqual(bundleRejected.status, .bundlePayload)
        XCTAssertNil(bundleRejected.git)
    }

    func testSourceInspectorPreflightNonzeroReturnsOfflineAndSkipsGitAndFileReads() async throws {
        let repository = try sourceTemporaryDirectory(named: "preflight-nonzero")
        defer { try? FileManager.default.removeItem(at: repository) }

        var commandCalls = 0
        var fileReads = 0
        let commands = HarvisVersionCommandExecutor { _ in
            commandCalls += 1
            return HarvisVersionProcessDataResult(
                standardOutput: Data(),
                standardError: Data(),
                terminationStatus: 2,
                capturedByteCount: 0
            )
        }
        let files = HarvisVersionFileReader { _, _, _ in
            fileReads += 1
            throw HarvisBoundedFileReaderError.unreadable
        }

        let inspected = await HarvisSourceInspector(
            commands: commands,
            files: files
        ).inspect(selectedDirectory: repository.path)

        XCTAssertEqual(inspected.status, .offline)
        XCTAssertEqual(commandCalls, 1)
        XCTAssertEqual(fileReads, 0)
    }

    func testSourceInspectorPreflightMalformedOutputReturnsOfflineAndSkipsGitAndFileReads() async throws {
        let repository = try sourceTemporaryDirectory(named: "preflight-malformed")
        defer { try? FileManager.default.removeItem(at: repository) }

        var commandCalls = 0
        var fileReads = 0
        let commands = HarvisVersionCommandExecutor { request in
            commandCalls += 1
            let malformed = Data("File\n".utf8)
            return HarvisVersionProcessDataResult(
                standardOutput: malformed,
                standardError: Data(),
                terminationStatus: 0,
                capturedByteCount: malformed.count
            )
        }
        let files = HarvisVersionFileReader { _, _, _ in
            fileReads += 1
            throw HarvisBoundedFileReaderError.unreadable
        }

        let inspected = await HarvisSourceInspector(
            commands: commands,
            files: files
        ).inspect(selectedDirectory: repository.path)

        XCTAssertEqual(inspected.status, .offline)
        XCTAssertEqual(commandCalls, 1)
        XCTAssertEqual(fileReads, 0)
    }

    func testSourceInspectorPreflightSuccessAllowsDownstreamInspectionFlow() async throws {
        let repository = try sourceTemporaryDirectory(named: "preflight-success")
        defer { try? FileManager.default.removeItem(at: repository) }
        _ = try createHarvisRepository(at: repository)

        var commandCalls: [String] = []
        let commands = HarvisVersionCommandExecutor { request in
            commandCalls.append(request.executable + " " + request.arguments.joined(separator: " "))
            if request.arguments.count >= 3, request.executable == "/usr/bin/stat" {
                let output = Data("Directory\n".utf8)
                return HarvisVersionProcessDataResult(
                    standardOutput: output,
                    standardError: Data(),
                    terminationStatus: 0,
                    capturedByteCount: output.count
                )
            }
            return try HarvisVersionProcessRunner().runSynchronously(request)
        }

        let inspected = await HarvisSourceInspector(commands: commands).inspect(selectedDirectory: repository.path)

        XCTAssertEqual(inspected.status, .ready)
        XCTAssertGreaterThan(commandCalls.count, 2)
        XCTAssertEqual(commandCalls.first, "/usr/bin/stat -f %HT -- \(repository.path)/")
        XCTAssertEqual(
            commandCalls.dropFirst().first,
            "/usr/bin/find \(repository.path)/ -mindepth 1 -maxdepth 1 -print -quit"
        )
    }

    func testUnsafeConfigurationStopsBeforeGitDataPublication() async throws {
        let repository = try sourceTemporaryDirectory(named: "unsafe-config")
        defer { try? FileManager.default.removeItem(at: repository) }
        _ = try createHarvisRepository(at: repository)
        try runGit(["config", "filter.harvis-test.clean", "/bin/false"], at: repository)

        let inspected = await HarvisSourceInspector().inspect(selectedDirectory: repository.path)
        XCTAssertEqual(inspected.status, .unsafeGitConfig)
        XCTAssertNil(inspected.git)
    }

    func testRepositoryIdentityBarrierRejectsDeterministicAncestorReplacementWithSameRepository() async throws {
        let container = try sourceTemporaryDirectory(named: "identity-race")
        defer { try? FileManager.default.removeItem(at: container) }
        let activeAncestor = container.appendingPathComponent("active")
        let selected = activeAncestor.appendingPathComponent("source")
        let heldRepository = container.appendingPathComponent("source-held-during-swap")
        let displacedAncestor = container.appendingPathComponent("active-before-swap")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        _ = try createHarvisRepository(at: selected)

        var swapped = false
        let commands = HarvisVersionCommandExecutor { request in
            if !swapped, request.arguments.contains("config") {
                swapped = true
                // Preserve the repository and every marker leaf inode while
                // replacing only an ancestor directory in the live path.
                try FileManager.default.moveItem(at: selected, to: heldRepository)
                try FileManager.default.moveItem(at: activeAncestor, to: displacedAncestor)
                try FileManager.default.createDirectory(at: activeAncestor, withIntermediateDirectories: false)
                try FileManager.default.moveItem(at: heldRepository, to: selected)
            }
            return try HarvisVersionProcessRunner().runSynchronously(request)
        }
        let inspected = await HarvisSourceInspector(commands: commands).inspect(
            selectedDirectory: selected.path
        )
        XCTAssertTrue(swapped)
        XCTAssertEqual(inspected.status, .invalid)
        XCTAssertNil(inspected.git)
    }

    func testRepositoryIdentityBarrierRejectsAncestorMetadataDriftWithStableInodes() async throws {
        let container = try sourceTemporaryDirectory(named: "identity-metadata-race")
        defer { try? FileManager.default.removeItem(at: container) }
        let ancestor = container.appendingPathComponent("active")
        let selected = ancestor.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        _ = try createHarvisRepository(at: selected)

        var mutated = false
        let commands = HarvisVersionCommandExecutor { request in
            if !mutated, request.arguments.contains("config") {
                mutated = true
                let sentinel = ancestor.appendingPathComponent(".identity-metadata-drift")
                try Data([0x01]).write(to: sentinel)
                try FileManager.default.removeItem(at: sentinel)
            }
            return try HarvisVersionProcessRunner().runSynchronously(request)
        }
        let inspected = await HarvisSourceInspector(commands: commands).inspect(
            selectedDirectory: selected.path
        )
        XCTAssertTrue(mutated)
        XCTAssertEqual(inspected.status, .invalid)
        XCTAssertNil(inspected.git)
    }

    func testAlignmentInspectorCollectsObjectAndBidirectionalAncestryEvidence() async throws {
        let repository = try sourceTemporaryDirectory(named: "alignment")
        defer { try? FileManager.default.removeItem(at: repository) }
        let base = try createHarvisRepository(at: repository)

        try "main change\n".write(
            to: repository.appendingPathComponent("main-change.txt"),
            atomically: true,
            encoding: .utf8
        )
        let mainTip = try commitAll(at: repository, message: "main change")

        let exact = await HarvisSourceInspector().inspect(
            selectedDirectory: repository.path,
            receiptCommit: mainTip
        )
        XCTAssertEqual(exact.status, .ready)
        XCTAssertEqual(exact.alignment, .exact)

        let sourceAhead = await HarvisSourceInspector().inspect(
            selectedDirectory: repository.path,
            receiptCommit: base
        )
        XCTAssertEqual(sourceAhead.alignment, .sourceAhead)
        XCTAssertEqual(sourceAhead.alignmentEvidence?.receiptObject, .positive)
        XCTAssertEqual(sourceAhead.alignmentEvidence?.receiptIsAncestorOfSource, .positive)

        try runGit(["checkout", "--detach", base], at: repository)
        let installedAhead = await HarvisSourceInspector().inspect(
            selectedDirectory: repository.path,
            receiptCommit: mainTip
        )
        XCTAssertEqual(installedAhead.alignment, .installedAhead)
        XCTAssertEqual(installedAhead.alignmentEvidence?.sourceIsAncestorOfReceipt, .positive)

        try runGit(["checkout", "-b", "side"], at: repository)
        try "side change\n".write(
            to: repository.appendingPathComponent("side-change.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try commitAll(at: repository, message: "side change")
        let diverged = await HarvisSourceInspector().inspect(
            selectedDirectory: repository.path,
            receiptCommit: mainTip
        )
        XCTAssertEqual(diverged.alignment, .diverged)

        let missing = await HarvisSourceInspector().inspect(
            selectedDirectory: repository.path,
            receiptCommit: String(repeating: "f", count: 40)
        )
        XCTAssertEqual(missing.alignment, .missingCommit)
        XCTAssertEqual(missing.alignmentEvidence?.receiptObject, .negative)
    }

    func testAlignmentProbeFailureAndShallowDoubleNegativeRemainUnknown() async throws {
        let repository = try sourceTemporaryDirectory(named: "alignment-failure")
        defer { try? FileManager.default.removeItem(at: repository) }
        let base = try createHarvisRepository(at: repository)
        try "next\n".write(
            to: repository.appendingPathComponent("next.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tip = try commitAll(at: repository, message: "next")
        try runGit(["checkout", "--detach", base], at: repository)

        let commands = HarvisVersionCommandExecutor { request in
            if request.arguments.contains("merge-base") {
                return HarvisVersionProcessDataResult(
                    standardOutput: Data(),
                    standardError: Data(),
                    terminationStatus: 2,
                    capturedByteCount: 0
                )
            }
            return try HarvisVersionProcessRunner().runSynchronously(request)
        }
        let failedProbe = await HarvisSourceInspector(commands: commands).inspect(
            selectedDirectory: repository.path,
            receiptCommit: tip
        )
        XCTAssertEqual(failedProbe.status, .ready)
        XCTAssertEqual(failedProbe.alignment, .unknown)

        let shallowEvidence = HarvisAlignmentEvidence(
            sourceCommit: base,
            receiptCommit: tip,
            receiptObject: .positive,
            receiptIsAncestorOfSource: .negative,
            sourceIsAncestorOfReceipt: .negative,
            sourceIsShallow: true
        )
        XCTAssertEqual(HarvisVersionAlignmentResolver.resolve(shallowEvidence), .unknown)
    }

    private func validReceipt(runtimeSize: UInt64, runtimeSHA: String) -> HarvisBundleReceiptInspection {
        let appSHA = String(repeating: "b", count: 64)
        let extensionSHA = String(repeating: "c", count: 64)
        return HarvisBundleReceiptInspection(
            status: .valid,
            receipt: HarvisBundleReceiptSummary(
                schemaVersion: "harvis.app-bundle-receipt.v1",
                pluginRootMarker: "HarvisPlugin",
                app: HarvisAppIdentity(bundleIdentifier: "local.harzva.harvisbar", executable: "HarvisBar", version: "0.33.0"),
                artifacts: HarvisReceiptArtifacts(
                    runtimeSha256: runtimeSHA,
                    appUnsignedSha256: appSHA,
                    systemExtensionUnsignedSha256: extensionSHA,
                    records: [
                        HarvisReceiptArtifactRecord(role: "harvis-runtime", relativePath: "bin/harvis", mode: "0755", sizeBytes: runtimeSize, sha256: runtimeSHA),
                        HarvisReceiptArtifactRecord(role: "harvisbar-main", relativePath: "artifacts/HarvisBar", mode: "0755", sizeBytes: 1, sha256: appSHA),
                        HarvisReceiptArtifactRecord(role: "harvis-system-extension", relativePath: "artifacts/HarvisPerAppProxyExtension", mode: "0755", sizeBytes: 1, sha256: extensionSHA),
                    ]
                ),
                provenance: HarvisReceiptProvenance(cacheKey: "fixture", sha256: String(repeating: "d", count: 64), sourceCommit: String(repeating: "e", count: 40), sourceTree: String(repeating: "f", count: 40), stagedPayloadSha256: String(repeating: "0", count: 64)),
                payload: HarvisReceiptPayload(digestAlgorithm: "fixture", digestScope: "fixture", fileCount: 1, sha256: String(repeating: "1", count: 64)),
                appRuntimeAllowlist: HarvisReceiptAllowlist(relativePath: "fixture", sha256: String(repeating: "2", count: 64)),
                systemExtension: HarvisReceiptSystemExtension(bundleIdentifier: "extension", bundleName: "extension", executable: "extension", version: "0.33.0")
            )
        )
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harvis-version-\(name)-\(UUID().uuidString)")
        return try createCanonicalDirectory(url)
    }

    private func sourceTemporaryDirectory(named name: String) throws -> URL {
        // The production runner creates and immediately unlinks its anonymous
        // capture files below FileManager.default.temporaryDirectory. Keep
        // source fixtures on a disjoint canonical chain so exact ancestor
        // mtime/ctime comparison observes repository drift, not test transport.
        let url = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("harvis-version-source-\(name)-\(UUID().uuidString)")
        return try createCanonicalDirectory(url)
    }

    private func createCanonicalDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(url.path, &buffer) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let canonical = String(decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: canonical, isDirectory: true)
    }

    @discardableResult
    private func createHarvisRepository(at repository: URL) throws -> String {
        try runGit(["init", "-b", "main"], at: repository)
        let markers: [(String, String, Int16)] = [
            ("Cargo.toml", "[workspace]\n", 0o644),
            ("apps/HarvisBar/Package.swift", "// package\n", 0o644),
            ("scripts/harvis", "#!/bin/sh\n", 0o755),
            ("schemas/bar-status.schema.json", "{}\n", 0o644),
        ]
        for (relative, contents, mode) in markers {
            let target = repository.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, atomically: true, encoding: .utf8)
            XCTAssertEqual(chmod(target.path, mode_t(mode)), 0)
        }
        return try commitAll(at: repository, message: "initial")
    }

    @discardableResult
    private func commitAll(at repository: URL, message: String) throws -> String {
        try runGit(["add", "--all"], at: repository)
        try runGit([
            "-c", "user.name=Harvis Test",
            "-c", "user.email=harvis@example.invalid",
            "commit", "-m", message,
        ], at: repository)
        return try gitOutput(["rev-parse", "HEAD"], at: repository)
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
