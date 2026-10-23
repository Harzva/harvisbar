import Foundation
import XCTest

/// Opt-in subprocess acceptance: the fixture owns a real NSApplication loop.
/// Build with HARVIS_PERFORMANCE_FIXTURE and supply the test-only .app path.
final class HarvisPopoverNativePerformanceTests: XCTestCase {
    func testVisiblePopoverRemainsResponsiveDuringTwoSecondRefreshes() throws {
        guard let appPath = ProcessInfo.processInfo.environment["HARVIS_POPOVER_NATIVE_FIXTURE_APP"] else {
            throw XCTSkip("Set HARVIS_POPOVER_NATIVE_FIXTURE_APP to an isolated native fixture app.")
        }
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        guard info["HarvisPerformanceFixture"] as? Bool == true,
              let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID.hasPrefix("local.harzva.harvisbar.performance-"),
              let executable = info["CFBundleExecutable"] as? String,
              !executable.contains("/"), !executable.isEmpty else {
            XCTFail("Only a dedicated performance fixture bundle may be launched.")
            return
        }
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/\(executable)")
        process.arguments = ["--harvis-popover-performance-fixture"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HARVIS_PERFORMANCE_MOTION_MODE": "candidate",
            "HARVIS_PERFORMANCE_REFRESH_PRESSURE": "1",
        ], uniquingKeysWith: { _, candidate in candidate })
        // Do not leave an unread Pipe while the child runs: a small macOS pipe
        // buffer can itself block the fixture's main-thread JSON reporting.
        let outputURL = app.deletingLastPathComponent()
            .appendingPathComponent("native-regression-\(UUID().uuidString).jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        defer {
            if process.isRunning { process.terminate() }
        }
        // Build artifacts can live on a mechanical external volume. Warm the
        // executable's file cache so this measures UI work, not code-page I/O.
        _ = try Data(contentsOf: try XCTUnwrap(process.executableURL))
        try process.run()
        // The child measures 5 s idle, 10 s scrolling, 5 s settled. It never
        // starts production services; only this owned child is terminated.
        // Its clock starts after AppKit bootstrap, which can take seconds.
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if let partial = try? String(contentsOf: outputURL, encoding: .utf8),
               partial.contains("\"event\":\"completed\"") {
                break
            }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try output.close()
        let log = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        let records = log.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let bytes = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        let completed = try XCTUnwrap(records.first { $0["event"] as? String == "completed" }, log)
        XCTAssertGreaterThanOrEqual(completed["scrollSteps"] as? Int ?? 0, 500)
        let publications = records.filter { $0["event"] as? String == "publication" }
        XCTAssertGreaterThanOrEqual(publications.count, 8, "The refresh stressor must run.")
        var publicationTimes: [Int: Double] = [:]
        for row in publications {
            if let generation = row["generation"] as? Int, let elapsed = row["elapsed"] as? Double {
                publicationTimes[generation] = elapsed
            }
        }
        let samples = records.filter {
            $0["event"] as? String == "sample"
                && ($0["elapsed"] as? Double ?? 0) >= 2
                && ($0["probeCount"] as? Int ?? 0) > 10
        }
        let idleCPU = samples.filter { $0["phase"] as? String == "idle" }
            .compactMap { $0["cpuPercent"] as? Double }
        XCTAssertGreaterThanOrEqual(idleCPU.count, 3)
        let idleMean = idleCPU.reduce(0, +) / Double(max(1, idleCPU.count))
        XCTAssertLessThan(idleMean, 30, "Persistent menu rows must not run continuous animation work.")
        let scrollMax = samples.filter { $0["phase"] as? String == "scroll" }
            .compactMap { $0["mainDelayMaxMs"] as? Double }.max() ?? .infinity
        XCTAssertLessThan(scrollMax, 80, "Scrolling must not stall main-thread event delivery.")
        let warmPublicationLags = records.compactMap { row -> Double? in
            guard row["event"] as? String == "lag",
                  let generation = row["publicationGeneration"] as? Int, generation >= 2,
                  let publication = publicationTimes[generation],
                  let elapsed = row["elapsed"] as? Double,
                  elapsed >= publication, elapsed - publication < 0.25 else { return nil }
            return row["delayMs"] as? Double
        }
        let publicationMax = warmPublicationLags.max() ?? 0
        XCTAssertLessThan(publicationMax, 30, "Refreshing offscreen chats must not stall visible controls.")
        print("NATIVE_POPOVER idleCPU=\(idleMean) maxScrollDelayMs=\(scrollMax) warmOver25msLagMax=\(publicationMax) log=\(outputURL.path)")
    }
}
