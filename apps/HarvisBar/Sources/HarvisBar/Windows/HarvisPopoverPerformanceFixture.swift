#if HARVIS_PERFORMANCE_FIXTURE
import AppKit
import Darwin
import Foundation
import SwiftUI

/// Runs inside the app's normal NSApplication event loop, never a manually
/// pumped XCTest RunLoop. No production runtime, credentials or chat history.
@MainActor
final class HarvisPopoverPerformanceFixture: NSObject {
    static let shared = HarvisPopoverPerformanceFixture()
    nonisolated static let argument = "--harvis-popover-performance-fixture"

    nonisolated static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(argument)
            || Bundle.main.object(forInfoDictionaryKey: "HarvisPerformanceFixture") as? Bool == true
    }

    static func makeRuntime() -> HarvisRuntimeModel {
        let suite = "local.harzva.harvisbar.performance-fixture.defaults"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = HarvisRuntimeModel(defaults: defaults)
        model.pluginRoot = "/fixture/unavailable-plugin"
        model.workspaceRoot = "/fixture/synthetic-project"
        model.profileRoot = "/fixture/unavailable-profile"
        model.codexThreads = syntheticThreads(generation: 0)
        return model
    }

    private static func syntheticThreads(generation: Int64) -> [CodexThreadSummary] {
        (0..<100).map { index in
            CodexThreadSummary(
                id: "performance-\(index)",
                title: "Synthetic chat \(index) — scrolling and native button responsiveness",
                titleSource: "fixture", hasMeaningfulTitle: true,
                createdAt: 1_700_000_000, updatedAt: 1_700_000_100 + generation,
                tokensUsed: 12_000 + generation * 100, model: "fixture-model",
                cwd: "/fixture/synthetic-project", archived: false,
                running: index % 4 == 0, threadSource: nil,
                agentNickname: nil, agentRole: nil, agentPath: nil,
                parentThreadId: nil, agentDepth: nil, rootThreadId: nil,
                familyActivity: nil
            )
        }
    }

    private var window: NSWindow?
    private var hosting: NSView?
    private var probeTimer: Timer?
    private var lastProbe: TimeInterval = 0
    private var lastCPU: TimeInterval = 0
    private var lastReport: TimeInterval = 0
    private var started: TimeInterval = 0
    private var delays: [Double] = []
    private var phase = "idle"
    private var scrollStep = 0
    private var reduceMotion = false
    private weak var runtime: HarvisRuntimeModel?
    private var refreshPressure = false
    private var lastPublication: TimeInterval = 0
    private var publicationGeneration: Int64 = 0

    static func show(runtime: HarvisRuntimeModel) {
        shared.showWindow(runtime: runtime)
    }

    private func showWindow(runtime: HarvisRuntimeModel) {
        reduceMotion = ProcessInfo.processInfo.environment["HARVIS_PERFORMANCE_MOTION_MODE"] != "baseline"
        refreshPressure = ProcessInfo.processInfo.environment["HARVIS_PERFORMANCE_REFRESH_PRESSURE"] == "1"
        self.runtime = runtime
        let root = HarvisPopoverView(selectedSection: .codex, allowsBackgroundRefresh: false)
            .environmentObject(runtime)
            .frame(width: 318, height: 620)
        let controller = NSHostingController(rootView: root)
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 318, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        created.title = "HarvisBar performance fixture"
        created.isReleasedWhenClosed = false
        created.contentViewController = controller
        created.setAccessibilityIdentifier("harvis-popover-performance-fixture")
        created.center()
        created.makeKeyAndOrderFront(nil)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window = created
        hosting = controller.view
        started = ProcessInfo.processInfo.systemUptime
        lastProbe = started
        lastReport = started
        lastCPU = cpuSeconds()
        lastPublication = started
        emit(["event": "started", "pid": ProcessInfo.processInfo.processIdentifier,
              "reduceMotion": reduceMotion, "syntheticChats": 100,
              "refreshPressure": refreshPressure])
        // A main-run-loop timer measures how long UI work postpones ordinary
        // event delivery. Automatic scrolls use the same AppKit scroll view.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    private func probe() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, now - lastProbe - 1.0 / 60.0) * 1_000
        delays.append(delay)
        if delay > 25 {
            emit(["event": "lag", "phase": phase, "elapsed": now - started,
                  "delayMs": delay, "scrollSteps": scrollStep,
                  "publicationGeneration": publicationGeneration])
        }
        lastProbe = now
        let elapsed = now - started
        if refreshPressure, now - lastPublication >= 2 {
            publicationGeneration += 1
            runtime?.codexThreads = Self.syntheticThreads(generation: publicationGeneration)
            lastPublication = now
            emit(["event": "publication", "elapsed": elapsed,
                  "generation": publicationGeneration])
        }
        let requestedPhase = elapsed < 5 ? "idle" : elapsed < 15 ? "scroll" : "settled"
        if requestedPhase != phase {
            report(now: now)
            phase = requestedPhase
            delays.removeAll(keepingCapacity: true)
        }
        if phase == "scroll", let hosting, let scroll = firstScrollView(in: hosting) {
            let range = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            let progress = Double(scrollStep % 240) / 120.0
            let fraction = progress <= 1 ? progress : 2 - progress
            scroll.contentView.scroll(to: NSPoint(x: 0, y: range * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            scrollStep += 1
        }
        if now - lastReport >= 1 { report(now: now) }
        if elapsed >= 20 {
            report(now: now)
            probeTimer?.invalidate()
            probeTimer = nil
            emit(["event": "completed", "scrollSteps": scrollStep])
        }
    }

    private func report(now: TimeInterval) {
        let cpu = cpuSeconds()
        let interval = max(0.001, now - lastReport)
        let sorted = delays.sorted()
        let percentile = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        emit(["event": "sample", "phase": phase, "elapsed": now - started,
              "cpuPercent": (cpu - lastCPU) / interval * 100,
              "mainDelayP95Ms": percentile, "mainDelayMaxMs": sorted.last ?? 0,
              "probeCount": sorted.count, "scrollSteps": scrollStep])
        delays.removeAll(keepingCapacity: true)
        lastReport = now
        lastCPU = cpu
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }

    private func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
#endif
