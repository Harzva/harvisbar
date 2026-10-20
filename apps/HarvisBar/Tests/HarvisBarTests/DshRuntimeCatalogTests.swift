import XCTest
@testable import HarvisBar

final class DshRuntimeCatalogTests: XCTestCase {
    func testPreviewSeparatesHomePatchSharingAndSelectedMatrixVersionDifferences() {
        func plugin(_ name: String, _ version: String, homePatch: Bool = false) -> DshPluginCatalogItem {
            var p = DshPluginCatalogItem(name: name, spec: version, kind: "custom")
            p.packageType = "plugin"; p.installedVersion = version
            p.declaredIn = homePatch ? ["HOME 共享补丁"] : ["Profile 组合"]
            return p
        }
        func profile(_ id: String, _ plugins: [DshPluginCatalogItem]) -> DshProfileCatalogItem {
            DshProfileCatalogItem(id: id, name: id, path: id, mode: "web", launchable: true,
                launchCommand: nil, pluginCount: plugins.count, customPluginCount: plugins.count, plugins: plugins)
        }
        let a = profile("a", [plugin("common", "1"), plugin("home", "1", homePatch: true), plugin("only-a", "1")])
        let b = profile("b", [plugin("common", "2"), plugin("home", "1", homePatch: true)])
        let c = profile("c", [plugin("home", "1", homePatch: true)])
        let home = DshHomeCatalogItem(id: "h", label: "h", path: "/tmp/h", version: nil,
            runtimePath: nil, executable: nil, status: "ready", defaultProfile: nil, profileCount: 3,
            pluginCount: 6, customPluginCount: 6, profiles: [a,b,c], runningProfiles: [])
        XCTAssertEqual(home.previewPlugins(for: a, scope: .home).map(\.name), ["home"])
        XCTAssertEqual(Set(home.previewPlugins(for: a, scope: .shared).map(\.name)), ["common", "home"])
        XCTAssertEqual(home.previewPlugins(for: a, scope: .unique).map(\.name), ["only-a"])
        let rows = DshPluginComparisonRow.make(profiles: [a,b])
        XCTAssertTrue(rows.first { $0.name == "common" }!.common)
        XCTAssertTrue(rows.first { $0.name == "common" }!.versionsDiffer)
        XCTAssertTrue(rows.first { $0.name == "only-a" }!.unique)
        XCTAssertFalse(DshPluginComparisonRow.make(profiles: [a])[0].common)
        XCTAssertFalse(DshPluginComparisonRow.make(profiles: [a])[0].unique)
        XCTAssertEqual(home.previewSelectionID(for: a), "profile:a")
    }

    func testInventorySeparatesDependenciesAndNeverInfersOriginFromLegacyKind() throws {
        let json = #"""
        {"name":"@deepseek-ai/dsh-base","spec":"1.2","kind":"core",
         "origin":"official","originEvidence":"package metadata","installedVersion":"1.2.3",
         "installation":"resolved","packageType":"bundle","declaredIn":["Profile 组合"],
         "declarations":["bundle"],"description":"Core services"}
        """#
        let plugin = try JSONDecoder().decode(DshPluginCatalogItem.self, from: Data(json.utf8))
        XCTAssertEqual(plugin.originLabel, "官方")
        XCTAssertTrue(plugin.matches(query: "core services"))
        XCTAssertTrue(plugin.matches(query: "1.2.3"))
        XCTAssertTrue(plugin.matches(query: "Profile 组合"))
        XCTAssertFalse(plugin.matches(query: "nonexistent"))
        let legacy = DshPluginCatalogItem(name: "@deepseek-ai/example", spec: "1", kind: "core")
        XCTAssertEqual(legacy.originLabel, "来源待确认")
        var dependency = DshPluginCatalogItem(name: "library", spec: "1", kind: "custom")
        dependency.packageType = "dependency"
        dependency.origin = "third-party"
        let profile = DshProfileCatalogItem(id: "x", name: "x", path: "x", mode: "web",
            launchable: false, launchCommand: nil, pluginCount: 3, customPluginCount: 1,
            plugins: [plugin, legacy, dependency])
        XCTAssertEqual(profile.officialCount, 1)
        XCTAssertEqual(profile.thirdPartyCount, 0)
        XCTAssertEqual(profile.unknownCount, 1)
        XCTAssertEqual(profile.dependencyCount, 1)
        var disabled = plugin
        disabled.declarations = ["reference", "disabled-declaration"]
        XCTAssertTrue(disabled.declarationLabel.contains("最终状态未验"))
    }

    func testCatalogDecodesHomesProfilesPluginsAndRuntimeCopies() throws {
        let json = #"""
        {
          "ok": true,
          "schemaVersion": "harvis.dsh-catalog.v1",
          "homeCount": 1,
          "runtimeCount": 1,
          "homes": [{
            "id": "dsh-dev",
            "label": "Development",
            "path": "/tmp/.dsh-dev",
            "version": "0.1.0-rc.7",
            "runtimePath": "/tmp/runtime",
            "executable": "/tmp/runtime/lib/bin.js",
            "status": "ready",
            "defaultProfile": "web",
            "profileCount": 1,
            "pluginCount": 3,
            "customPluginCount": 1,
            "profiles": [{
              "id": "dsh-dev.web",
              "name": "web",
              "path": "~/.dsh-dev/profiles/web",
              "mode": "web",
              "launchable": true,
              "launchCommand": "DSH_HOME=/tmp/.dsh-dev dsh --profile web --port 0",
              "pluginCount": 3,
              "customPluginCount": 1,
              "plugins": [{"name":"dsh-restart","spec":"1.0.0","kind":"custom"}]
            }],
            "runningProfiles": [{"profile":"web","pid":42,"ports":[3080]}]
          }],
          "runtimes": [{
            "id": "dsh-runtime-1",
            "version": "0.1.0-rc.7",
            "path": "/tmp/runtime",
            "executable": "/tmp/runtime/lib/bin.js",
            "source": "managed-root",
            "launchable": true,
            "linkedHomeIds": ["dsh-dev"]
          }],
          "warnings": [],
          "includesSecrets": false
        }
        """#

        let catalog = try JSONDecoder().decode(
            DshRuntimeCatalog.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(catalog.homeCount, 1)
        XCTAssertEqual(catalog.runtimeCount, 1)
        XCTAssertEqual(catalog.homes[0].defaultLaunchProfile?.name, "web")
        XCTAssertEqual(catalog.homes[0].shortcutLabel, "Dev")
        XCTAssertEqual(catalog.homes[0].runningPortCount, 1)
        XCTAssertTrue(catalog.homes[0].ownsRunningInstance(profile: "web", pid: 42, port: 3080))
        XCTAssertTrue(catalog.homes[0].ownsRunningInstance(profile: "web", pid: nil, port: 3080))
        XCTAssertFalse(catalog.homes[0].ownsRunningInstance(profile: "web", pid: 99, port: 3090))
        XCTAssertFalse(catalog.homes[0].ownsRunningInstance(profile: "zhitro", pid: 42, port: 3080))
        XCTAssertEqual(catalog.homes[0].profiles[0].plugins[0].kind, "custom")
        XCTAssertEqual(catalog.runtimes[0].linkedHomeIds, ["dsh-dev"])
        XCTAssertFalse(catalog.includesSecrets)
        XCTAssertTrue(catalog.isSafeForLocalDisplay)
    }

    func testPopoverProjectionPromotesRunningAppAndShowsSixDistinctCapabilities() {
        let defaultHome = makeHome(
            id: "dsh",
            version: "0.1.1-rc.2",
            profiles: [
                makeProfile("web"),
                makeProfile("digital-me", plugins: [
                    "@harzva/dsh-memory",
                    "@harzva/dsh-preset-matrix",
                    "@nanmicoder/dsh-agent-teams",
                ]),
                makeProfile("digital-me-im", plugins: ["@xmanrui/dsh-im"]),
                makeProfile("voice-lab", plugins: ["@harness-flow/dsh-voice"]),
                makeProfile("qwen-image-lab", plugins: ["zhitro-qwen-image"]),
                makeProfile("ui-test-studio-dev", plugins: ["@harness-flow/dsh-ui-test"]),
                makeProfile("sidechat-lab", plugins: ["dsh-side-chat"]),
                makeProfile("zhitro", plugins: ["zhitro-dashboard"]),
            ],
            running: [
                DshRunningProfileCatalogItem(profile: "digital-me", pid: 42, ports: [64746]),
            ]
        )
        let rcHome = makeHome(
            id: "dsh-rc8-home",
            version: "0.1.0-rc.8",
            profiles: [makeProfile("web", idPrefix: "dsh-rc8-home")]
        )

        let apps = DshPopoverCatalogProjection.apps(from: [rcHome, defaultHome])
        let featured = DshPopoverCatalogProjection.featuredApps(from: [rcHome, defaultHome])

        XCTAssertEqual(apps.count, 9)
        XCTAssertEqual(apps.first?.profile.name, "digital-me")
        XCTAssertEqual(apps.first?.runningPort, 64746)
        XCTAssertEqual(
            featured.map(\.profile.name),
            [
                "digital-me",
                "digital-me-im",
                "voice-lab",
                "qwen-image-lab",
                "ui-test-studio-dev",
                "sidechat-lab",
            ]
        )
        XCTAssertEqual(DshPopoverCatalogProjection.versionCount(in: [rcHome, defaultHome]), 2)
        XCTAssertEqual(apps.first { $0.home.id == "dsh-rc8-home" }?.displayName, "RC8 Web")
    }

    func testPopoverAppCapabilitiesComeFromDeclaredPluginsWithBaselineFallbacks() {
        let digitalMe = DshPopoverApp(
            home: makeHome(id: "dsh", profiles: []),
            profile: makeProfile("digital-me", plugins: [
                "@harzva/dsh-memory",
                "@harzva/dsh-preset-workbench",
                "@nanmicoder/dsh-agent-teams",
            ]),
            runningProfile: nil
        )
        let voice = DshPopoverApp(
            home: makeHome(id: "dsh", profiles: []),
            profile: makeProfile("voice-lab", plugins: [
                "@harness-flow/dsh-voice",
                "dsh-image-mcp-fallback",
            ]),
            runningProfile: nil
        )

        XCTAssertEqual(digitalMe.capabilityLabels, ["对话", "记忆", "预设", "多 Agent"])
        XCTAssertEqual(voice.capabilityLabels, ["对话", "语音", "图像", "工作区"])
        XCTAssertFalse(voice.capabilityLabels.contains("IM"))
    }

    func testCatalogAndLaunchResponsesFailClosedForSecretsSchemasAndRemoteURLs() {
        let safeCatalog = DshRuntimeCatalog(
            ok: true,
            schemaVersion: "harvis.dsh-catalog.v1",
            homeCount: 0,
            runtimeCount: 0,
            homes: [],
            runtimes: [],
            warnings: [],
            includesSecrets: false
        )
        let wrongSchema = DshRuntimeCatalog(
            ok: true,
            schemaVersion: "harvis.dsh-catalog.v2",
            homeCount: 0,
            runtimeCount: 0,
            homes: [],
            runtimes: [],
            warnings: [],
            includesSecrets: false
        )
        let secretCatalog = DshRuntimeCatalog(
            ok: true,
            schemaVersion: "harvis.dsh-catalog.v1",
            homeCount: 0,
            runtimeCount: 0,
            homes: [],
            runtimes: [],
            warnings: [],
            includesSecrets: true
        )

        XCTAssertTrue(safeCatalog.isSafeForLocalDisplay)
        XCTAssertFalse(wrongSchema.isSafeForLocalDisplay)
        XCTAssertFalse(secretCatalog.isSafeForLocalDisplay)

        let local = makeStartResult(url: "http://127.0.0.1:64746/", includesSecrets: false)
        let localhost = makeStartResult(url: "http://localhost:64746/", includesSecrets: false)
        let remote = makeStartResult(url: "http://example.com:64746/", includesSecrets: false)
        let secureRemote = makeStartResult(url: "https://127.0.0.1:64746/", includesSecrets: false)
        let missingPort = makeStartResult(url: "http://127.0.0.1/", includesSecrets: false)
        let credentialURL = makeStartResult(
            url: "http://user:password@127.0.0.1:64746/",
            includesSecrets: false
        )
        let queryURL = makeStartResult(
            url: "http://127.0.0.1:64746/?token=hidden",
            includesSecrets: false
        )
        let withoutURL = makeStartResult(url: nil, includesSecrets: false)
        let secret = makeStartResult(url: "http://127.0.0.1:64746/", includesSecrets: true)

        XCTAssertTrue(local.isSafeForLocalOpen)
        XCTAssertEqual(local.safeLoopbackURL?.host, "127.0.0.1")
        XCTAssertTrue(localhost.isSafeForLocalOpen)
        XCTAssertFalse(remote.isSafeForLocalOpen)
        XCTAssertFalse(secureRemote.isSafeForLocalOpen)
        XCTAssertFalse(missingPort.isSafeForLocalOpen)
        XCTAssertFalse(credentialURL.isSafeForLocalOpen)
        XCTAssertFalse(queryURL.isSafeForLocalOpen)
        XCTAssertTrue(withoutURL.isSafeForLocalOpen)
        XCTAssertFalse(secret.isSafeForLocalOpen)
    }

    private func makeHome(
        id: String,
        version: String? = "0.1.1-rc.2",
        profiles: [DshProfileCatalogItem],
        running: [DshRunningProfileCatalogItem] = []
    ) -> DshHomeCatalogItem {
        DshHomeCatalogItem(
            id: id,
            label: id,
            path: "/tmp/\(id)",
            version: version,
            runtimePath: nil,
            executable: nil,
            status: "ready",
            defaultProfile: "web",
            profileCount: profiles.count,
            pluginCount: profiles.reduce(0) { $0 + $1.pluginCount },
            customPluginCount: profiles.reduce(0) { $0 + $1.customPluginCount },
            profiles: profiles,
            runningProfiles: running
        )
    }

    private func makeProfile(
        _ name: String,
        idPrefix: String = "dsh",
        plugins: [String] = []
    ) -> DshProfileCatalogItem {
        let declaredPlugins = ["@deepseek-ai/dsh-web-app"] + plugins
        return DshProfileCatalogItem(
            id: "\(idPrefix).\(name)",
            name: name,
            path: "/tmp/\(idPrefix)/\(name)",
            mode: "web",
            launchable: true,
            launchCommand: nil,
            pluginCount: declaredPlugins.count,
            customPluginCount: plugins.count,
            plugins: declaredPlugins.map {
                DshPluginCatalogItem(name: $0, spec: "1.0.0", kind: "custom")
            }
        )
    }

    private func makeStartResult(url: String?, includesSecrets: Bool) -> DshStartResult {
        DshStartResult(
            ok: true,
            action: "start",
            homeId: "dsh",
            home: "/tmp/dsh",
            version: "0.1.1-rc.2",
            profile: "digital-me",
            pid: 42,
            port: 64746,
            url: url,
            tmuxSession: "dsh-digital-me",
            runtime: "/tmp/runtime",
            includesSecrets: includesSecrets
        )
    }
}
