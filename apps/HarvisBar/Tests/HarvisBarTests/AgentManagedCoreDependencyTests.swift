import Foundation
import XCTest
@testable import HarvisBar

final class AgentManagedCoreDependencyTests: XCTestCase {
    func testCoreSourceDependencyContract() throws {
        let files = try coreSourceFiles()
        let directory = coreDirectory()
        let requiredFiles: Set<String> = [
            "AgentIdentity.swift",
            "AgentProviderID.swift",
            "ConversationCapabilities.swift",
            "ConversationTrustState.swift",
            "ManagedConversation.swift",
            "ManagedConversationAddress.swift",
            "ManagedConversationGovernance.swift",
            "ManagedConversationProject.swift",
        ]
        let actualFiles = Set(files.map { relativePath($0, under: directory) })

        XCTAssertTrue(
            actualFiles.isSuperset(of: requiredFiles),
            "Core is missing required files: \(requiredFiles.subtracting(actualFiles))"
        )

        let forbiddenTokens = [
            "HarvisRuntimeModel",
            "SwiftUI",
            "AppKit",
            "Combine",
            "UserDefaults",
            "FileManager",
            "FileHandle",
            "NSWorkspace",
            "URLSession",
            "Process(",
            "Codex",
            "Dsh",
            "WorkBuddy",
            "supportsCodex",
            "contentsOf:",
            "write(to:",
            "standardizingPath",
            "resolvingSymlinksInPath",
        ]

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(
                    source.contains(token),
                    "\(file.lastPathComponent) must not depend on \(token)"
                )
            }
        }
    }

    func testCoreSourcesTypecheckInIsolation() throws {
        let files = try coreSourceFiles()
        let configurations = [
            [String](),
            ["-DDEBUG"],
            ["-DSWIFT_PACKAGE"],
            ["-DSWIFT_PACKAGE", "-DDEBUG"],
        ]
        for configurationArguments in configurations {
            let result = try runSwiftCompiler(
                arguments: [
                "swiftc",
                "-swift-version", "6",
                "-parse-as-library",
                "-typecheck",
                "-module-name", "AgentManagedCorePurityProbe",
                ] + configurationArguments + files.map(\.path)
            )
            XCTAssertEqual(
                result.status,
                0,
                "Core did not typecheck independently \(configurationArguments):\n\(result.text)"
            )
        }
    }

    func testCoreCompilerDependencyGraphAllowsOnlyFoundation() throws {
        let moduleName = "AgentManagedCorePurityProbe"
        let files = try coreSourceFiles()
        let allowedDependencies: Set<String> = [
            "swift:Swift",
            "swift:SwiftOnoneSupport",
            "swift:_Concurrency",
            "swift:_StringProcessing",
            "swift:Foundation",
            "clang:_SwiftConcurrencyShims",
        ]
        for configurationArguments in [
            ["-DSWIFT_PACKAGE"],
            ["-DSWIFT_PACKAGE", "-DDEBUG"],
        ] {
            let result = try runSwiftCompiler(
                arguments: [
                    "swiftc",
                    "-swift-version", "6",
                    "-parse-as-library",
                    "-whole-module-optimization",
                    "-module-name", moduleName,
                    "-scan-dependencies",
                ] + configurationArguments + files.map(\.path) + ["-o", "-"]
            )
            XCTAssertEqual(
                result.status,
                0,
                "Core dependency scan failed \(configurationArguments):\n\(result.text)"
            )
            guard result.status == 0 else { continue }

            let graph = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: result.output)
                    as? [String: Any]
            )
            XCTAssertEqual(graph["mainModuleName"] as? String, moduleName)
            let modules = try XCTUnwrap(graph["modules"] as? [Any])
            let mainIndex = try XCTUnwrap(modules.firstIndex { item in
                (item as? [String: Any])?["swift"] as? String == moduleName
            })
            XCTAssertLessThan(mainIndex + 1, modules.count)
            let main = try XCTUnwrap(
                modules[mainIndex + 1] as? [String: Any]
            )

            let scannedFiles = Set(
                (try XCTUnwrap(main["sourceFiles"] as? [String])).map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                }
            )
            XCTAssertEqual(
                scannedFiles,
                Set(files.map { $0.standardizedFileURL.path }),
                "The compiler scan must include every recursively discovered Core source"
            )

            let directDependencies = dependencyNames(
                try XCTUnwrap(main["directDependencies"] as? [Any])
            )
            XCTAssertTrue(
                directDependencies.isSubset(of: allowedDependencies),
                "Unexpected direct Core dependencies: \(directDependencies.subtracting(allowedDependencies))"
            )

            let details = try XCTUnwrap(main["details"] as? [String: Any])
            let swiftDetails = try XCTUnwrap(
                details["swift"] as? [String: Any]
            )
            let sourceDependencies = dependencyNames(
                try XCTUnwrap(
                    swiftDetails["sourceImportedDependencies"] as? [Any]
                )
            )
            XCTAssertTrue(
                sourceDependencies.isSubset(of: allowedDependencies),
                "Unexpected source-imported Core dependencies: \(sourceDependencies.subtracting(allowedDependencies))"
            )

            let sourceImportNames = Set(
                (try XCTUnwrap(main["imports"] as? [[String: Any]]))
                    .filter { record in
                        guard let locations = record["importLocations"]
                            as? [[String: Any]]
                        else {
                            return false
                        }
                        return locations.contains { location in
                            guard let path = location["bufferIdentifier"] as? String
                            else {
                                return false
                            }
                            return path.hasPrefix(coreDirectory().path + "/")
                        }
                    }
                    .compactMap { $0["identifier"] as? String }
            )
            XCTAssertTrue(
                sourceImportNames.isSubset(of: ["Foundation"]),
                "Core source imports are restricted to Foundation: \(sourceImportNames)"
            )
        }
    }

    private func coreSourceFiles() throws -> [URL] {
        let directory = coreDirectory()
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(file.standardizedFileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func coreDirectory() -> URL {
        packageRoot()
            .appendingPathComponent("Sources/HarvisBar/AgentManaged/Core")
            .standardizedFileURL
    }

    private func relativePath(_ file: URL, under directory: URL) -> String {
        let prefix = directory.path + "/"
        guard file.path.hasPrefix(prefix) else { return file.path }
        return String(file.path.dropFirst(prefix.count))
    }

    private func dependencyNames(_ values: [Any]) -> Set<String> {
        Set(values.compactMap { value in
            guard let dependency = value as? [String: Any] else {
                return "unknown:\(String(describing: value))"
            }
            if let name = dependency["swift"] as? String {
                return "swift:\(name)"
            }
            if let name = dependency["clang"] as? String {
                return "clang:\(name)"
            }
            return "unknown:\(dependency.keys.sorted().joined(separator: ","))"
        })
    }

    private func runSwiftCompiler(arguments: [String]) throws -> CompilerResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CompilerResult(status: process.terminationStatus, output: data)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct CompilerResult {
    let status: Int32
    let output: Data

    var text: String {
        String(data: output, encoding: .utf8) ?? ""
    }
}
