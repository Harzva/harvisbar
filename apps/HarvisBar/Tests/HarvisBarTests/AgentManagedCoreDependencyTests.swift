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
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarvisBar-Core-Imports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let foundationOnlyFile = fixtureDirectory.appendingPathComponent("FoundationOnly.swift")
        try "import Foundation\n".write(to: foundationOnlyFile, atomically: true, encoding: .utf8)

        for configurationArguments in [
            ["-DSWIFT_PACKAGE"],
            ["-DSWIFT_PACKAGE", "-DDEBUG"],
        ] {
            // Older scanners include Foundation overlays in directDependencies.
            // Compare with this compiler's Foundation-only scan, not a transitive
            // closure that could also allow a new explicit framework import.
            let foundationOnlyMain = try scanMainModule(
                files: [foundationOnlyFile],
                moduleName: moduleName,
                configurationArguments: configurationArguments
            )
            let main = try scanMainModule(
                files: files,
                moduleName: moduleName,
                configurationArguments: configurationArguments
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

            let unexpected = try unexpectedCoreDependencies(
                in: main,
                foundationOnlyMain: foundationOnlyMain
            )
            XCTAssertTrue(
                unexpected.isEmpty,
                "Unexpected Core dependencies: \(unexpected)"
            )
        }
    }

    func testLegacyDependencyGraphUsesFoundationOnlyBaseline() throws {
        let baseline: [String: Any] = [
            "directDependencies": [
                ["swift": "Foundation"], ["swift": "Swift"],
                ["swift": "Darwin"], ["swift": "_math"],
                ["clang": "_Darwin_xlocale"],
            ],
            "details": ["swift": ["isFramework": false]],
        ]
        XCTAssertEqual(
            try unexpectedCoreDependencies(in: baseline, foundationOnlyMain: baseline),
            []
        )
        for module in ["AppKit", "SwiftUI", "ThirdPartyCore"] {
            var main = baseline
            main["directDependencies"] = try XCTUnwrap(
                baseline["directDependencies"] as? [[String: String]]
            ) + [["swift": module]]
            XCTAssertEqual(
                try unexpectedCoreDependencies(in: main, foundationOnlyMain: baseline),
                ["swift:\(module)"]
            )
        }
    }

    func testModernDependencyGraphStillChecksSourceImportMetadata() throws {
        let baseline: [String: Any] = [
            "directDependencies": [["swift": "Foundation"], ["swift": "Swift"]],
            "details": ["swift": ["isFramework": false]],
        ]
        var main = baseline
        main["details"] = ["swift": [
            "sourceImportedDependencies": [["swift": "Foundation"]],
        ]]
        main["imports"] = [[
            "identifier": "Foundation",
            "importLocations": [["bufferIdentifier": coreDirectory().appendingPathComponent("Core.swift").path]],
        ] as [String: Any]]
        XCTAssertEqual(
            try unexpectedCoreDependencies(in: main, foundationOnlyMain: baseline),
            []
        )
        main["details"] = ["swift": [
            "sourceImportedDependencies": [["swift": "Foundation"], ["swift": "AppKit"]],
        ]]
        XCTAssertEqual(
            try unexpectedCoreDependencies(in: main, foundationOnlyMain: baseline),
            ["swift:AppKit"]
        )
        main["details"] = baseline["details"]
        main["imports"] = [[
            "identifier": "SwiftUI",
            "importLocations": [["bufferIdentifier": coreDirectory().appendingPathComponent("Core.swift").path]],
        ] as [String: Any]]
        XCTAssertEqual(
            try unexpectedCoreDependencies(in: main, foundationOnlyMain: baseline),
            ["source:SwiftUI"]
        )
    }

    private func scanMainModule(
        files: [URL],
        moduleName: String,
        configurationArguments: [String]
    ) throws -> [String: Any] {
        let result = try runSwiftCompiler(
            arguments: [
                "swiftc", "-swift-version", "6", "-parse-as-library",
                "-whole-module-optimization", "-module-name", moduleName,
                "-scan-dependencies",
            ] + configurationArguments + files.map(\.path) + ["-o", "-"]
        )
        let output = try XCTUnwrap(
            result.status == 0 ? result.output : nil,
            "Core dependency scan failed \(configurationArguments):\n\(result.text)"
        )
        let graph = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        XCTAssertEqual(graph["mainModuleName"] as? String, moduleName)
        let modules = try XCTUnwrap(graph["modules"] as? [Any])
        let mainIndex = try XCTUnwrap(modules.firstIndex { item in
            (item as? [String: Any])?["swift"] as? String == moduleName
        })
        return try XCTUnwrap(
            modules.indices.contains(mainIndex + 1)
                ? modules[mainIndex + 1] as? [String: Any] : nil
        )
    }

    private func unexpectedCoreDependencies(
        in main: [String: Any],
        foundationOnlyMain: [String: Any]
    ) throws -> Set<String> {
        let allowedDirectDependencies = dependencyNames(
            try XCTUnwrap(foundationOnlyMain["directDependencies"] as? [Any])
        )
        var unexpected = dependencyNames(
            try XCTUnwrap(main["directDependencies"] as? [Any])
        ).subtracting(allowedDirectDependencies)
        let allowedSourceDependencies: Set<String> = [
            "swift:Swift", "swift:SwiftOnoneSupport", "swift:_Concurrency",
            "swift:_StringProcessing", "swift:Foundation", "clang:_SwiftConcurrencyShims",
        ]
        let details = try XCTUnwrap(main["details"] as? [String: Any])
        let swiftDetails = try XCTUnwrap(details["swift"] as? [String: Any])
        // These additive fields are absent in older compiler scan schemas.
        if let imported = swiftDetails["sourceImportedDependencies"] {
            unexpected.formUnion(
                dependencyNames(try XCTUnwrap(imported as? [Any]))
                    .subtracting(allowedSourceDependencies)
            )
        }
        if let imports = main["imports"] {
            let records = try XCTUnwrap(imports as? [[String: Any]])
            for record in records {
                let locations = record["importLocations"] as? [[String: Any]] ?? []
                let isCoreImport = locations.contains { location in
                    guard let path = location["bufferIdentifier"] as? String else { return false }
                    return path.hasPrefix(coreDirectory().path + "/")
                }
                if isCoreImport, let name = record["identifier"] as? String, name != "Foundation" {
                    unexpected.insert("source:\(name)")
                }
            }
        }
        return unexpected
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
