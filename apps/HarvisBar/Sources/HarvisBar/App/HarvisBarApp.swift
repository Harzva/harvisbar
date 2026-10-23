import AppKit
import Darwin
import SwiftUI

enum HarvisAppMode {
    static var isLegacyInteractionTest: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--harvisbar-ui-test")
            || arguments.contains("--per-app-proxy-ui-test")
    }

    static var isVersionFixture: Bool {
#if HARVIS_VERSION_UI_TESTING
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        return arguments.contains(HarvisVersionFixtureProvider.argumentName)
#else
        return false
#endif
    }

    static var isInteractionTest: Bool {
        isLegacyInteractionTest || isVersionFixture || isPerformanceFixture || isGroupFixture
    }

    static var isGroupFixture: Bool {
#if DEBUG
        HarvisGroupUIFixture.isRequested(arguments: ProcessInfo.processInfo.arguments)
#else
        false
#endif
    }

    static var isPerformanceFixture: Bool {
#if HARVIS_PERFORMANCE_FIXTURE
        HarvisPopoverPerformanceFixture.isRequested(arguments: ProcessInfo.processInfo.arguments)
#else
        false
#endif
    }

    static var isDesktopBundle: Bool {
        let bundleID = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        let bundlePath = Bundle.main.bundlePath.lowercased()
        return bundleID.contains("harvisdesk") || bundlePath.hasSuffix("harvisdesk.app")
    }
}

enum HarvisAppLaunchArguments {
    static let openVersionManager = "--open-harvis-version-manager"

    static func shouldOpenHarvisVersionManager(_ arguments: [String]) -> Bool {
        arguments.contains(openVersionManager)
    }
}

enum HarvisAppBootRoute: Equatable {
    case production
    case legacyInteractionTest
    case isolatedVersionTest

    static func resolve(
        legacyInteractionTest: Bool,
        isolatedVersionTest: Bool
    ) -> HarvisAppBootRoute {
        if isolatedVersionTest { return .isolatedVersionTest }
        if legacyInteractionTest { return .legacyInteractionTest }
        return .production
    }

    var startsRuntime: Bool { self == .production }
    var performsLegacyRefresh: Bool { self == .legacyInteractionTest }
    var showsLegacyProxyWindow: Bool { self == .legacyInteractionTest }
}

enum HarvisSingleInstance {
    static func existingApplication(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> NSRunningApplication? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { application in
                application.processIdentifier != currentProcessIdentifier
                    && !application.isTerminated
            }
    }
}

@main
struct HarvisBarApp: App {
    @NSApplicationDelegateAdaptor(HarvisBarReopenDelegate.self) private var appDelegate
    @StateObject private var model: HarvisRuntimeModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isLegacyUITestMode = HarvisAppMode.isLegacyInteractionTest
#if HARVIS_VERSION_UI_TESTING
        let versionFixtureProvider: HarvisVersionFixtureProvider?
        if HarvisAppMode.isVersionFixture {
            do {
                versionFixtureProvider = try HarvisVersionFixtureProvider(
                    arguments: Array(arguments.dropFirst())
                )
            } catch {
                let message = "Harvis version fixture boot rejected.\n"
                FileHandle.standardError.write(Data(message.utf8))
                Darwin.exit(EXIT_FAILURE)
            }
        } else {
            versionFixtureProvider = nil
        }
        let isVersionFixtureMode = versionFixtureProvider != nil
        let versionFixtureDefaults = isVersionFixtureMode
            ? UserDefaults(suiteName: HarvisVersionFixtureProvider.defaultsSuiteName)
            : nil
#else
        let isVersionFixtureMode = false
        let versionFixtureDefaults: UserDefaults? = nil
#endif
        let isUITestMode = HarvisAppMode.isInteractionTest
        let bootRoute = HarvisAppBootRoute.resolve(
            legacyInteractionTest: isLegacyUITestMode,
            isolatedVersionTest: isVersionFixtureMode
        )
        if let invocation = ManagedProjectFileStatisticsHelper.invokeIfRequested(
            arguments: arguments
        ) {
            FileHandle.standardOutput.write(invocation.standardOutput)
            FileHandle.standardError.write(invocation.standardError)
            Darwin.exit(invocation.exitCode)
        }

        if !HarvisAppMode.isInteractionTest,
           let existingApplication = HarvisSingleInstance.existingApplication() {
            existingApplication.activate(options: [.activateIgnoringOtherApps])
            Darwin.exit(EXIT_SUCCESS)
        }

        let runtimeModel: HarvisRuntimeModel
        if let isolatedDefaults = versionFixtureDefaults {
#if HARVIS_VERSION_UI_TESTING
            if let versionFixtureProvider,
               versionFixtureProvider.isTaskProgressFixture,
               let taskProgressLoader = versionFixtureProvider.makeTaskProgressLoader() {
                runtimeModel = HarvisRuntimeModel(
                    defaults: isolatedDefaults,
                    taskProgressLoader: taskProgressLoader,
                    taskProgressInitialSnapshot: versionFixtureProvider.taskProgressInitialSnapshot,
                    taskProgressDidPublish: { [weak versionFixtureProvider] event in
                        versionFixtureProvider?.acceptTaskProgressPublication(event)
                    }
                )
                versionFixtureProvider.seedTaskProgressRuntimeBaseline(on: runtimeModel)
            } else {
                runtimeModel = HarvisRuntimeModel(defaults: isolatedDefaults)
            }
#else
            runtimeModel = HarvisRuntimeModel(defaults: isolatedDefaults)
#endif
        } else if isLegacyUITestMode,
           let isolatedDefaults = UserDefaults(
            suiteName: "local.harzva.harvisbar.interaction-test"
           ) {
            isolatedDefaults.removePersistentDomain(
                forName: "local.harzva.harvisbar.interaction-test"
            )
            runtimeModel = HarvisRuntimeModel(defaults: isolatedDefaults)
        } else if HarvisAppMode.isGroupFixture {
#if DEBUG
            do {
                runtimeModel = try HarvisGroupUIFixture.makeRuntime(arguments: arguments)
            } catch {
                FileHandle.standardError.write(Data("Harvis group fixture boot rejected.\n".utf8))
                Darwin.exit(EXIT_FAILURE)
            }
#else
            runtimeModel = HarvisRuntimeModel()
#endif
        } else if HarvisAppMode.isPerformanceFixture {
#if HARVIS_PERFORMANCE_FIXTURE
            runtimeModel = HarvisPopoverPerformanceFixture.makeRuntime()
#else
            runtimeModel = HarvisRuntimeModel()
#endif
        } else {
            runtimeModel = HarvisRuntimeModel()
        }
        _model = StateObject(wrappedValue: runtimeModel)
        HarvisBarReopenDelegate.runtimeModel = runtimeModel
        NSApplication.shared.setActivationPolicy(
            HarvisAppMode.isDesktopBundle || isUITestMode ? .regular : .accessory
        )

        DispatchQueue.main.async {
#if DEBUG
            if HarvisAppMode.isGroupFixture {
                runtimeModel.openCodexGroupChat()
                return
            }
#endif
#if HARVIS_PERFORMANCE_FIXTURE
            if HarvisAppMode.isPerformanceFixture {
                HarvisPopoverPerformanceFixture.show(runtime: runtimeModel)
                return
            }
#endif
#if HARVIS_VERSION_UI_TESTING
            if let versionFixtureProvider {
                if versionFixtureProvider.isTaskProgressFixture {
                    HarvisTaskProgressFixtureWindowController.shared.show(
                        model: runtimeModel,
                        provider: versionFixtureProvider
                    )
                    Task { await runtimeModel.refreshTaskProgress() }
                    return
                }
                HarvisVersionCatalogWindowController.installFixtureProvider(
                    versionFixtureProvider
                )
                runtimeModel.openHarvisVersionCatalog()
                return
            }
#endif
            if bootRoute.performsLegacyRefresh {
                Task { await runtimeModel.refreshAll() }
            } else if bootRoute.startsRuntime {
                runtimeModel.start()
            }
            if HarvisAppMode.isDesktopBundle {
                runtimeModel.openDesktopApp()
            }
            if arguments.contains("--open-codex-manager") {
                runtimeModel.openCodexChatManager()
            }
            if arguments.contains("--open-codex-group-chat") {
                runtimeModel.openCodexGroupChat()
            }
            if arguments.contains("--open-unified-versions") {
                UnifiedVersionCatalogWindowController.shared.show(runtime: runtimeModel)
            }
            if arguments.contains("--open-dsh-manager") {
                runtimeModel.openDshRuntimeCatalog()
            }
            if HarvisAppLaunchArguments.shouldOpenHarvisVersionManager(arguments) {
                runtimeModel.openHarvisVersionCatalog()
            }
            if bootRoute.showsLegacyProxyWindow {
                PerAppProxyUITestWindowController.shared.show(model: runtimeModel)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            HarvisPopoverView()
                .environmentObject(model)
                .frame(width: 318, height: 620)
        } label: {
            HarvisStatusLabel()
                .environmentObject(model)
                .onAppear {
                    if !HarvisAppMode.isInteractionTest {
                        model.start()
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
        .commands {
            CommandMenu("Codex") {
                Button("成员群聊") { model.openCodexGroupChat() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("会话管理") { model.openCodexChatManager() }
            }
            CommandMenu("DSH") {
                Button("DSH 快捷管理") {
                    HarvisDshQuickWindowController.shared.show(model: model)
                }
                Button("DSH 环境与插件") {
                    model.openDshRuntimeCatalog()
                }
            }
        }
    }
}

@MainActor
final class HarvisBarReopenDelegate: NSObject, NSApplicationDelegate {
    static weak var runtimeModel: HarvisRuntimeModel?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, !HarvisAppMode.isInteractionTest,
              !HarvisAppMode.isDesktopBundle, let model = Self.runtimeModel else { return true }
        HarvisDshQuickWindowController.shared.show(model: model)
        return true
    }
}
