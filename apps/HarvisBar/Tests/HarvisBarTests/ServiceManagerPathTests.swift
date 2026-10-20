import XCTest
@testable import HarvisBar

@MainActor
final class ServiceManagerPathTests: XCTestCase {
    func testLegacyPluginRootCandidatesAreRejectedBeforeUse() {
        let legacyRoot = "\(NSHomeDirectory())/plugins/harvis"

        XCTAssertTrue(HarvisRuntimeModel.isLegacyPluginRoot(legacyRoot))
        XCTAssertTrue(HarvisRuntimeModel.isLegacyPluginRoot("\(legacyRoot)/nested"))
        XCTAssertTrue(
            HarvisRuntimeModel.isLegacyPluginRoot("\(legacyRoot)/../harvis")
        )
        XCTAssertFalse(
            HarvisRuntimeModel.isLegacyPluginRoot(
                "\(NSHomeDirectory())/.codex/plugins/cache/personal/harvis/current"
            )
        )
    }

    func testPluginRootResolutionNeverProbesLegacyCandidate() {
        let legacyRoot = "\(NSHomeDirectory())/plugins/harvis"
        let modularRoot = "\(NSHomeDirectory())/.codex/plugins/cache/personal/harvis/current"
        var probedPaths: [String] = []

        let selected = HarvisRuntimeModel.resolvePluginRoot(
            candidates: [legacyRoot, modularRoot],
            fallbackCandidates: ["/Applications/HarvisBar.app/Contents/Resources"],
            scriptExists: { path in
                probedPaths.append(path)
                return path == "\(modularRoot)/scripts/harvis"
            }
        )

        XCTAssertEqual(selected, modularRoot)
        XCTAssertEqual(probedPaths, ["\(modularRoot)/scripts/harvis"])
    }

    func testPluginRootResolutionUsesBundleSafeFallback() {
        let legacyRoot = "\(NSHomeDirectory())/plugins/harvis"
        let bundleResources = "/Applications/HarvisBar.app/Contents/Resources"

        let selected = HarvisRuntimeModel.resolvePluginRoot(
            candidates: [legacyRoot],
            fallbackCandidates: [legacyRoot, bundleResources],
            scriptExists: { _ in
                XCTFail("retired candidate must be rejected before probing")
                return false
            }
        )

        XCTAssertEqual(selected, bundleResources)
    }

    func testBundledPluginRootResolvesRelativePayloadWithoutLeakingBuildPath() {
        let resources = "/Applications/HarvisBar.app/Contents/Resources"

        XCTAssertEqual(
            HarvisRuntimeModel.resolveBundledPluginRoot(
                resourcePath: resources,
                marker: "HarvisPlugin\n"
            ),
            "\(resources)/HarvisPlugin"
        )
        XCTAssertNil(
            HarvisRuntimeModel.resolveBundledPluginRoot(
                resourcePath: resources,
                marker: "../outside"
            )
        )
        XCTAssertNil(
            HarvisRuntimeModel.resolveBundledPluginRoot(
                resourcePath: resources,
                marker: "/private/plugin-root"
            )
        )
    }

    func testBundledPluginRootOverridesPersistedDevelopmentRoot() {
        let resources = "/Applications/HarvisBar.app/Contents/Resources"
        let bundled = "\(resources)/HarvisPlugin"

        XCTAssertEqual(
            HarvisRuntimeModel.resolveInitialPluginRoot(
                stored: "/Volumes/External/old-harvis-checkout",
                detected: bundled,
                bundledPluginRoot: bundled
            ),
            bundled
        )
    }

    func testDevelopmentBuildKeepsExplicitNonLegacyRoot() {
        XCTAssertEqual(
            HarvisRuntimeModel.resolveInitialPluginRoot(
                stored: "/work/custom-harvis",
                detected: "/work/current-harvis",
                bundledPluginRoot: nil
            ),
            "/work/custom-harvis"
        )
    }

    func testPersonalCacheUpgradeUsesDetectedVersion() {
        XCTAssertEqual(
            HarvisRuntimeModel.resolveInitialPluginRoot(
                stored: "/home/test/.codex/plugins/cache/personal/harvis/old",
                detected: "/home/test/.codex/plugins/cache/personal/harvis/current",
                bundledPluginRoot: nil
            ),
            "/home/test/.codex/plugins/cache/personal/harvis/current"
        )
    }

    func testBundledWrapperWinsOverStableHelper() {
        var probedPaths: [String] = []
        let path = HarvisRuntimeModel.resolveServiceManagerPath(
            pluginRoot: "/plugin",
            homeDirectory: "/Users/test",
            isExecutable: { path in
                probedPaths.append(path)
                return true
            }
        )

        XCTAssertEqual(path, "/plugin/scripts/harvis")
        XCTAssertEqual(probedPaths, ["/plugin/scripts/harvis"])
    }

    func testStableHelperIsFallbackWhenWrapperIsUnavailable() {
        var probedPaths: [String] = []
        let path = HarvisRuntimeModel.resolveServiceManagerPath(
            pluginRoot: "/plugin",
            homeDirectory: "/Users/test",
            isExecutable: { path in
                probedPaths.append(path)
                return path == "/Users/test/.harvis/bin/harvis"
            }
        )

        XCTAssertEqual(path, "/Users/test/.harvis/bin/harvis")
        XCTAssertEqual(
            probedPaths,
            ["/plugin/scripts/harvis", "/Users/test/.harvis/bin/harvis"]
        )
    }

    func testLegacyRuntimeAppIsNeverProbedAndWrapperRemainsFailurePath() {
        var probedPaths: [String] = []
        let path = HarvisRuntimeModel.resolveServiceManagerPath(
            pluginRoot: "/plugin",
            homeDirectory: "/Users/test",
            isExecutable: { candidate in
                probedPaths.append(candidate)
                XCTAssertFalse(candidate.contains("HarvisRuntime.app"))
                return false
            }
        )

        XCTAssertEqual(path, "/plugin/scripts/harvis")
        XCTAssertEqual(
            probedPaths,
            ["/plugin/scripts/harvis", "/Users/test/.harvis/bin/harvis"]
        )
    }
}
