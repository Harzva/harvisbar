import AppKit
import ApplicationServices
import Combine
import SwiftUI

enum CodexChatWorkbenchDefaults {
    static let expandedKey = "harvis.codex.chatManager.workbenchExpanded"
    static let compactWidthKey = "harvis.codex.chatManager.compact.width"
    static let compactHeightKey = "harvis.codex.chatManager.compact.height"
    static let expandedWidthKey = "harvis.codex.chatManager.expanded.width"
    static let expandedHeightKey = "harvis.codex.chatManager.expanded.height"

    static func widthKey(for mode: CodexWorkbenchMode) -> String {
        mode == .expanded ? expandedWidthKey : compactWidthKey
    }

    static func heightKey(for mode: CodexWorkbenchMode) -> String {
        mode == .expanded ? expandedHeightKey : compactHeightKey
    }
}

/// Restores the manager window in one coordinate domain: all persisted and
/// default dimensions describe the outer AppKit window frame, not its content
/// rect. Older builds could save an expanded/full-screen frame under the
/// compact keys, so those legacy values are migrated back to the compact
/// default instead of making "收起" appear to do nothing.
struct CodexChatWorkbenchSizePolicy {
    struct Restoration: Equatable {
        let size: CodexWorkbenchWindowSize
        let migratedLegacyCompactSize: Bool
    }

    static func restore(
        mode: CodexWorkbenchMode,
        storedWidth: Double?,
        storedHeight: Double?
    ) -> Restoration {
        let fallback = mode == .expanded
            ? CodexWorkbenchWindowSize.expandedDefault
            : CodexWorkbenchWindowSize.compactDefault
        guard let storedWidth,
              let storedHeight,
              storedWidth.isFinite,
              storedHeight.isFinite,
              storedWidth > 0,
              storedHeight > 0 else {
            return Restoration(size: fallback, migratedLegacyCompactSize: false)
        }

        let candidate = CodexWorkbenchWindowSize(
            width: storedWidth,
            height: storedHeight
        ).clamped(for: mode)
        guard mode == .compact else {
            return Restoration(size: candidate, migratedLegacyCompactSize: false)
        }

        // An ordinary compact resize may be wider *or* taller than the default.
        // Treat it as legacy expanded pollution only when both dimensions have
        // crossed into expanded-workbench territory. The generous single-axis
        // ceilings still catch old maximized values on unusually shaped screens.
        let looksExpanded =
            candidate.width >= CodexWorkbenchWindowSize.expandedDefault.width
                && candidate.height >= CodexWorkbenchWindowSize.expandedDefault.height
        let looksMaximized =
            candidate.width > CodexWorkbenchWindowSize.compactDefault.width * 1.5
                || candidate.height > CodexWorkbenchWindowSize.compactDefault.height * 1.5
        guard looksExpanded || looksMaximized else {
            return Restoration(size: candidate, migratedLegacyCompactSize: false)
        }
        return Restoration(size: fallback, migratedLegacyCompactSize: true)
    }

    static func restore(
        mode: CodexWorkbenchMode,
        defaults: UserDefaults
    ) -> Restoration {
        let widthKey = CodexChatWorkbenchDefaults.widthKey(for: mode)
        let heightKey = CodexChatWorkbenchDefaults.heightKey(for: mode)
        let restoration = restore(
            mode: mode,
            storedWidth: defaults.object(forKey: widthKey) == nil
                ? nil
                : defaults.double(forKey: widthKey),
            storedHeight: defaults.object(forKey: heightKey) == nil
                ? nil
                : defaults.double(forKey: heightKey)
        )
        if restoration.migratedLegacyCompactSize {
            defaults.set(restoration.size.width, forKey: widthKey)
            defaults.set(restoration.size.height, forKey: heightKey)
        }
        return restoration
    }

    @MainActor
    static func contentRect(
        forWindowFrameSize frameSize: NSSize,
        styleMask: NSWindow.StyleMask
    ) -> NSRect {
        NSWindow.contentRect(
            forFrameRect: NSRect(origin: .zero, size: frameSize),
            styleMask: styleMask
        )
    }

    static func resizedFrame(
        _ original: NSRect,
        toWindowFrameSize size: CodexWorkbenchWindowSize,
        within visibleFrame: NSRect?
    ) -> NSRect {
        let width = min(
            CGFloat(size.width),
            visibleFrame?.width ?? .greatestFiniteMagnitude
        )
        let height = min(
            CGFloat(size.height),
            visibleFrame?.height ?? .greatestFiniteMagnitude
        )
        var frame = NSRect(
            x: original.maxX - width,
            y: original.maxY - height,
            width: width,
            height: height
        )
        if let visibleFrame {
            frame.origin.x = min(
                max(frame.origin.x, visibleFrame.minX),
                visibleFrame.maxX - frame.width
            )
            frame.origin.y = min(
                max(frame.origin.y, visibleFrame.minY),
                visibleFrame.maxY - frame.height
            )
        }
        return frame
    }
}

struct CodexDockGeometry {
    enum Side {
        case left
        case right
    }

    static func lockedFrame(
        beside codexFrame: NSRect,
        side: Side,
        visibleWidth: CGFloat,
        overlap: CGFloat,
        gap: CGFloat
    ) -> NSRect {
        let width = visibleWidth + overlap
        let x = side == .left
            ? codexFrame.minX - width + overlap - gap
            : codexFrame.maxX - overlap + gap
        return NSRect(
            x: x,
            y: codexFrame.minY,
            width: width,
            height: codexFrame.height
        )
    }

    static func appKitFrame(
        quartzOrigin: CGPoint,
        size: CGSize,
        mainDisplayTop: CGFloat
    ) -> NSRect {
        NSRect(
            x: quartzOrigin.x,
            y: mainDisplayTop - quartzOrigin.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}

private func codexDockAccessibilityCallback(
    observer _: AXObserver,
    element _: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let controller = Unmanaged<HarvisCodexChatWindowController>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let notificationName = notification as String
    DispatchQueue.main.async {
        controller.handleAttachedCodexAccessibilityEvent(notificationName)
    }
}

@MainActor
final class HarvisDesktopWindowController: NSObject, NSWindowDelegate {
    static let shared = HarvisDesktopWindowController()

    private var window: NSWindow?
    private var displayNameSubscription: AnyCancellable?

    func show(model: HarvisRuntimeModel) {
        if window == nil {
            let root = HarvisDesktopView()
                .environmentObject(model)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1220, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = Self.windowTitle(displayName: HarvisBarPreferences.shared.displayName)
            window.minSize = NSSize(width: 1040, height: 650)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.delegate = self
            window.center()
            self.window = window
        }

        displayNameSubscription?.cancel()
        displayNameSubscription = HarvisBarPreferences.shared.$displayName.sink { [weak self] name in
            Task { @MainActor in
                self?.window?.title = Self.windowTitle(displayName: name)
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            self.displayNameSubscription = nil
        }
    }

    private static func windowTitle(displayName: String) -> String {
        "\(displayName) · Desktop"
    }
}

@MainActor
final class HarvisNetworkWindowController: NSObject, NSWindowDelegate {
    static let shared = HarvisNetworkWindowController()

    private var window: NSWindow?
    private var displayNameSubscription: AnyCancellable?

    func show(model: HarvisRuntimeModel) {
        if window == nil {
            let root = HarvisNetworkContainerView(model: model)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = Self.windowTitle(displayName: HarvisBarPreferences.shared.displayName)
            window.minSize = NSSize(width: 980, height: 640)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.delegate = self
            window.center()
            self.window = window
        }

        displayNameSubscription?.cancel()
        displayNameSubscription = HarvisBarPreferences.shared.$displayName.sink { [weak self] name in
            Task { @MainActor in
                self?.window?.title = Self.windowTitle(displayName: name)
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            self.displayNameSubscription = nil
        }
    }

    private static func windowTitle(displayName: String) -> String {
        "\(displayName) · Network"
    }
}

@MainActor
final class HarvisCodexChatWindowController: NSObject, NSWindowDelegate {
    static let shared = HarvisCodexChatWindowController()

    private static let accessibilityPromptedKey =
        "harvisBar.codexChatWindowAccessibilityPrompted"
    private static let regularWindowStyle: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
    ]

    private typealias DockSide = CodexDockGeometry.Side

    private struct CodexWindow {
        let id: CGWindowID
        let ownerPID: pid_t
        let frame: NSRect
    }

    private struct DockAttachment {
        let codexWindowID: CGWindowID
        let ownerPID: pid_t
        let side: DockSide
    }

    private struct DockCandidate {
        let attachment: DockAttachment
        let codexFrame: NSRect
        let frame: NSRect
        let distance: CGFloat
    }

    private var window: NSWindow?
    private weak var model: HarvisRuntimeModel?
    private var workbenchMode: CodexWorkbenchMode = .compact
    private var dockAttachment: DockAttachment?
    private var dockTimer: Timer?
    private var undockedFrameBeforeDock: NSRect?
    private var dockingEnabled = true
    private var attachmentLocked = false
    private var isApplyingDockFrame = false
    private var lockedVisibleWidth: CGFloat?
    private var attachedWindowMissingSince: Date?
    private var dockMonitorTick = 0
    private var lastAttachedCodexFrame: NSRect?
    private var accessibilityObserver: AXObserver?
    private var accessibilityWindow: AXUIElement?

    private let dockGap: CGFloat = 0
    private let cornerFillOverlap: CGFloat = 14
    private let snapDistance: CGFloat = 36
    private let detachDistance: CGFloat = 72
    private let lockedMonitorInterval: TimeInterval = 1.0 / 60.0
    private let attachedWindowGracePeriod: TimeInterval = 1.5
    private let accessibilityNotifications = [
        kAXMovedNotification,
        kAXResizedNotification,
        kAXUIElementDestroyedNotification,
    ]

    func show(model: HarvisRuntimeModel) {
        self.model = model
        if window == nil {
            workbenchMode = restoredWorkbenchMode()
            let restoredSize = restoredWorkbenchSize(for: workbenchMode)
            let root = HarvisCodexChatManagerView()
                .environmentObject(model)
            let hosting = NSHostingController(rootView: root)
            let restoredFrameSize = NSSize(
                width: CGFloat(restoredSize.width),
                height: CGFloat(restoredSize.height)
            )
            let window = NSWindow(
                contentRect: CodexChatWorkbenchSizePolicy.contentRect(
                    forWindowFrameSize: restoredFrameSize,
                    styleMask: Self.regularWindowStyle
                ),
                styleMask: Self.regularWindowStyle,
                backing: .buffered,
                defer: false
            )
            window.title = "Chat Agent Managed"
            window.minSize = minimumWindowSize(for: workbenchMode)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            // Installing an NSHostingController sizes the window to SwiftUI's
            // fitting content size (980×560 for the expanded workbench). Apply
            // the user's remembered outer-window frame size afterwards, before
            // the delegate can persist that transient fitting size.
            var restoredFrame = window.frame
            restoredFrame.size = restoredFrameSize
            window.setFrame(restoredFrame, display: false)
            window.delegate = self
            positionAtRightEdge(window)
            self.window = window
        }

        setDockingEnabled(model.isCodexChatWindowDockingEnabled)
        setAttachmentLocked(model.isCodexChatWindowAttachmentLocked)
        setPinned(model.isCodexChatWindowPinned)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.refreshSelectedCodexThreads()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.snapToCodexIfPossible()
        }
    }

    /// Switches the existing manager window between its compact card view and
    /// expanded workbench. Each mode remembers its own user-resized dimensions.
    func setWorkbenchExpanded(_ expanded: Bool) {
        let newMode: CodexWorkbenchMode = expanded ? .expanded : .compact
        UserDefaults.standard.set(
            expanded,
            forKey: CodexChatWorkbenchDefaults.expandedKey
        )
        guard newMode != workbenchMode else { return }

        if let window {
            persistWorkbenchSize(of: window, for: workbenchMode)
        }
        workbenchMode = newMode

        guard let window else { return }
        window.minSize = minimumWindowSize(for: newMode)
        applyWorkbenchSize(
            restoredWorkbenchSize(for: newMode),
            to: window,
            animate: true
        )
    }

    func setPinned(_ pinned: Bool) {
        guard let window else { return }
        applyWindowLevel()
        window.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed]
        if pinned && dockAttachment == nil {
            positionAtRightEdge(window)
        }
    }

    func requestStrongAttachmentPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        UserDefaults.standard.set(true, forKey: Self.accessibilityPromptedKey)
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func setDockingEnabled(_ enabled: Bool) {
        dockingEnabled = enabled
        if !enabled {
            detachFromCodex()
        } else if let window, dockAttachment == nil,
                  let candidate = bestDockCandidate(for: window.frame) {
            attach(to: candidate, animate: true)
        }
    }

    func setAttachmentLocked(_ locked: Bool) {
        let wasLocked = attachmentLocked
        attachmentLocked = locked
        if locked {
            if !AXIsProcessTrusted(),
               !UserDefaults.standard.bool(forKey: Self.accessibilityPromptedKey) {
                requestStrongAttachmentPermissionIfNeeded()
            }
            dockingEnabled = true
            if lockedVisibleWidth == nil, let window {
                lockedVisibleWidth = dockAttachment == nil
                    ? window.frame.width
                    : max(480, window.frame.width - cornerFillOverlap)
            }
            if let attachment = dockAttachment {
                applyDockedWindowChrome(true, side: attachment.side)
                startDockMonitor()
                updateDockedFrame(animate: false)
            } else {
                startDockMonitor()
                forceAttachToCodex(animate: false)
            }
        } else if wasLocked, dockAttachment != nil {
            detachFromCodex()
        } else if let attachment = dockAttachment {
            applyDockedWindowChrome(true, side: attachment.side)
        }
        if !locked {
            lockedVisibleWidth = nil
        }
    }

    private func positionAtRightEdge(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        let margin: CGFloat = 14
        var frame = window.frame
        frame.size.width = min(frame.width, visibleFrame.width - (margin * 2))
        frame.size.height = min(frame.height, visibleFrame.height - (margin * 2))
        frame.origin = NSPoint(
            x: visibleFrame.maxX - frame.width - margin,
            y: visibleFrame.maxY - frame.height - margin
        )
        window.setFrame(frame, display: false)
    }

    private func restoredWorkbenchMode() -> CodexWorkbenchMode {
        UserDefaults.standard.bool(
            forKey: CodexChatWorkbenchDefaults.expandedKey
        ) ? .expanded : .compact
    }

    private func restoredWorkbenchSize(
        for mode: CodexWorkbenchMode
    ) -> CodexWorkbenchWindowSize {
        CodexChatWorkbenchSizePolicy.restore(
            mode: mode,
            defaults: .standard
        ).size
    }

    private func persistWorkbenchSize(
        of window: NSWindow,
        for mode: CodexWorkbenchMode
    ) {
        let current = window.frame.size
        let prior = restoredWorkbenchSize(for: mode)
        let isDocked = dockAttachment != nil
        let visibleWidth = isDocked
            ? max(480, current.width - cornerFillOverlap)
            : current.width
        // Docking follows the attached Codex window's height. Do not overwrite
        // the user's undocked height with that transient attached height.
        let height = isDocked ? prior.height : Double(current.height)
        let persisted = CodexWorkbenchWindowSize(
            width: Double(visibleWidth),
            height: height
        ).clamped(for: mode)
        let defaults = UserDefaults.standard
        defaults.set(
            persisted.width,
            forKey: CodexChatWorkbenchDefaults.widthKey(for: mode)
        )
        defaults.set(
            persisted.height,
            forKey: CodexChatWorkbenchDefaults.heightKey(for: mode)
        )
    }

    private func minimumWindowSize(for mode: CodexWorkbenchMode) -> NSSize {
        let minimum = CodexWorkbenchWindowSize(width: 0, height: 0)
            .clamped(for: mode)
        return NSSize(width: minimum.width, height: minimum.height)
    }

    private func applyWorkbenchSize(
        _ size: CodexWorkbenchWindowSize,
        to window: NSWindow,
        animate: Bool
    ) {
        let target = size.clamped(for: workbenchMode)

        if let undockedFrameBeforeDock {
            self.undockedFrameBeforeDock = resizedUndockedFrame(
                undockedFrameBeforeDock,
                to: target
            )
        }

        if let attachment = dockAttachment {
            if attachmentLocked {
                lockedVisibleWidth = CGFloat(target.width)
            }
            guard let codexWindow = codexWindow(withID: attachment.codexWindowID),
                  let frame = dockedFrame(
                      for: NSSize(
                          width: CGFloat(target.width) + cornerFillOverlap,
                          height: CGFloat(target.height)
                      ),
                      beside: codexWindow.frame,
                      side: attachment.side
                  ) else {
                var frame = window.frame
                frame.size.width = CGFloat(target.width) + cornerFillOverlap
                applyDockFrame(frame, animate: animate)
                return
            }
            applyDockFrame(frame, animate: animate)
            return
        }

        if attachmentLocked {
            // Preserve the intended visible width for a subsequent forced snap.
            lockedVisibleWidth = CGFloat(target.width)
        }
        applyDockFrame(
            resizedUndockedFrame(window.frame, to: target),
            animate: animate
        )
    }

    private func resizedUndockedFrame(
        _ original: NSRect,
        to size: CodexWorkbenchWindowSize
    ) -> NSRect {
        let targetScreen = screen(containing: original)
        let visible = targetScreen?.visibleFrame.insetBy(dx: 4, dy: 4)
        return CodexChatWorkbenchSizePolicy.resizedFrame(
            original,
            toWindowFrameSize: size,
            within: visible
        )
    }

    private func applyWindowLevel() {
        guard let window else { return }
        let pinned = model?.isCodexChatWindowPinned == true
        window.level = dockAttachment != nil ? .normal : (pinned ? .floating : .normal)
    }

    private func applyDockedWindowChrome(_ docked: Bool, side: DockSide? = nil) {
        guard let window else { return }
        if docked {
            window.styleMask = attachmentLocked
                ? [.fullSizeContentView]
                : [.resizable, .fullSizeContentView]
        } else {
            window.styleMask = Self.regularWindowStyle
        }
        window.titleVisibility = docked ? .hidden : .visible
        window.hasShadow = !docked
        window.isMovableByWindowBackground = docked && !attachmentLocked
        window.isMovable = !docked || !attachmentLocked
    }

    private func handleWindowMoved() {
        guard dockingEnabled, !isApplyingDockFrame, let window else { return }
        if let attachment = dockAttachment {
            if attachmentLocked {
                updateDockedFrame(animate: false)
                return
            }
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
            guard let codexWindow = codexWindow(withID: attachment.codexWindowID),
                  let expected = dockedFrame(
                    for: window.frame.size,
                    beside: codexWindow.frame,
                    side: attachment.side
                  ) else {
                detachFromCodex()
                return
            }
            let departure = hypot(
                window.frame.minX - expected.minX,
                window.frame.minY - expected.minY
            )
            if departure >= detachDistance {
                detachFromCodex()
            }
            return
        }

        guard let candidate = bestDockCandidate(for: window.frame) else { return }
        attach(to: candidate, animate: true)
    }

    private func forceAttachToCodex(animate: Bool) {
        guard attachmentLocked, let window,
              let candidate = forcedDockCandidate(for: window.frame) else {
            return
        }
        attach(to: candidate, animate: animate)
    }

    private func forcedDockCandidate(for frame: NSRect) -> DockCandidate? {
        var candidates: [DockCandidate] = []
        for codexWindow in codexWindows() {
            for side in [DockSide.left, DockSide.right] {
                guard let docked = dockedFrame(
                    for: frame.size,
                    beside: codexWindow.frame,
                    side: side
                ) else {
                    continue
                }
                candidates.append(DockCandidate(
                    attachment: DockAttachment(
                        codexWindowID: codexWindow.id,
                        ownerPID: codexWindow.ownerPID,
                        side: side
                    ),
                    codexFrame: codexWindow.frame,
                    frame: docked,
                    distance: hypot(frame.midX - docked.midX, frame.midY - docked.midY)
                ))
            }
        }
        return candidates.min { $0.distance < $1.distance }
    }

    private func snapToCodexIfPossible() {
        guard dockingEnabled, dockAttachment == nil else { return }
        if attachmentLocked {
            forceAttachToCodex(animate: true)
            return
        }
        guard let window,
              let candidate = bestDockCandidate(for: window.frame) else {
            return
        }
        attach(to: candidate, animate: true)
    }

    private func handleWindowResized() {
        guard !isApplyingDockFrame, window != nil else { return }
        guard dockAttachment != nil else { return }
        updateDockedFrame(animate: false)
    }

    private func handleWindowLiveResizeEnded() {
        guard !isApplyingDockFrame, let window else { return }
        persistWorkbenchSize(of: window, for: workbenchMode)
    }

    private func bestDockCandidate(for frame: NSRect) -> DockCandidate? {
        var candidates: [DockCandidate] = []
        for codexWindow in codexWindows() {
            guard let targetScreen = screen(containing: codexWindow.frame) else { continue }
            let visibleFrame = targetScreen.visibleFrame.insetBy(dx: 4, dy: 4)
            let verticalOverlap = max(
                0,
                min(frame.maxY, codexWindow.frame.maxY)
                    - max(frame.minY, codexWindow.frame.minY)
            )
            let requiredOverlap = min(180, min(frame.height, codexWindow.frame.height) * 0.25)
            guard verticalOverlap >= requiredOverlap else { continue }

            let leftDistance = abs(frame.maxX - (codexWindow.frame.minX - dockGap))
            let pushedAgainstLeftEdge =
                abs(frame.minX - visibleFrame.minX) <= 18
                    && frame.maxX <= codexWindow.frame.minX
                    && codexWindow.frame.minX - frame.maxX <= 180
            if (leftDistance <= snapDistance || pushedAgainstLeftEdge),
               let docked = dockedFrame(
                for: frame.size,
                beside: codexWindow.frame,
                side: .left
               ) {
                candidates.append(DockCandidate(
                    attachment: DockAttachment(
                        codexWindowID: codexWindow.id,
                        ownerPID: codexWindow.ownerPID,
                        side: .left
                    ),
                    codexFrame: codexWindow.frame,
                    frame: docked,
                    distance: pushedAgainstLeftEdge ? snapDistance : leftDistance
                ))
            }

            let rightDistance = abs(frame.minX - (codexWindow.frame.maxX + dockGap))
            let pushedAgainstRightEdge =
                abs(frame.maxX - visibleFrame.maxX) <= 18
                    && frame.minX >= codexWindow.frame.maxX
                    && frame.minX - codexWindow.frame.maxX <= 180
            if (rightDistance <= snapDistance || pushedAgainstRightEdge),
               let docked = dockedFrame(
                for: frame.size,
                beside: codexWindow.frame,
                side: .right
               ) {
                candidates.append(DockCandidate(
                    attachment: DockAttachment(
                        codexWindowID: codexWindow.id,
                        ownerPID: codexWindow.ownerPID,
                        side: .right
                    ),
                    codexFrame: codexWindow.frame,
                    frame: docked,
                    distance: pushedAgainstRightEdge ? snapDistance : rightDistance
                ))
            }
        }
        return candidates.min { $0.distance < $1.distance }
    }

    private func attach(to candidate: DockCandidate, animate: Bool) {
        guard dockingEnabled, let window else { return }
        if dockAttachment == nil {
            undockedFrameBeforeDock = window.frame
        }
        dockAttachment = candidate.attachment
        lastAttachedCodexFrame = candidate.codexFrame
        attachedWindowMissingSince = nil
        model?.updateCodexChatWindowDocked(
            true,
            side: candidate.attachment.side == .right ? "right" : "left"
        )
        applyDockedWindowChrome(true, side: candidate.attachment.side)
        applyWindowLevel()
        startAccessibilityObserver(
            for: candidate.attachment,
            matching: candidate.codexFrame
        )
        startDockMonitor()
        applyDockFrame(candidate.frame, animate: animate)
        orderBehindAttachedCodex()
    }

    private func detachFromCodex(restoreFrame: Bool = true) {
        guard dockAttachment != nil || dockTimer != nil else { return }
        dockAttachment = nil
        lastAttachedCodexFrame = nil
        attachedWindowMissingSince = nil
        stopAccessibilityObserver()
        dockTimer?.invalidate()
        dockTimer = nil
        model?.updateCodexChatWindowDocked(false)
        applyDockedWindowChrome(false)
        applyWindowLevel()

        guard restoreFrame, let window, let previousFrame = undockedFrameBeforeDock else {
            undockedFrameBeforeDock = nil
            return
        }
        undockedFrameBeforeDock = nil

        var restoredFrame = window.frame
        restoredFrame.size = previousFrame.size
        if let screen = screen(containing: restoredFrame) {
            let visible = screen.visibleFrame.insetBy(dx: 4, dy: 4)
            restoredFrame.origin.x = min(
                max(restoredFrame.origin.x, visible.minX),
                visible.maxX - restoredFrame.width
            )
            restoredFrame.origin.y = min(
                max(restoredFrame.origin.y, visible.minY),
                visible.maxY - restoredFrame.height
            )
        }
        applyDockFrame(restoredFrame, animate: true)
    }

    private func startDockMonitor() {
        dockTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            timeInterval: attachmentLocked ? lockedMonitorInterval : 0.25,
            target: self,
            selector: #selector(dockTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        dockTimer = timer
    }

    @objc private func dockTimerFired(_ timer: Timer) {
        if attachmentLocked {
            dockMonitorTick &+= 1
            if dockAttachment == nil {
                forceAttachToCodex(animate: false)
            } else {
                updateDockedFrame(animate: false)
                if dockMonitorTick.isMultiple(of: 30) {
                    orderBehindAttachedCodex()
                }
            }
            return
        }
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        updateDockedFrame(animate: false)
        orderBehindAttachedCodex()
    }

    private func orderBehindAttachedCodex() {
        guard let window, let attachment = dockAttachment else { return }
        window.order(.below, relativeTo: Int(attachment.codexWindowID))
    }

    private func updateDockedFrame(animate: Bool) {
        guard let window, let attachment = dockAttachment else { return }
        guard let codexWindow = codexWindow(withID: attachment.codexWindowID) else {
            if attachmentLocked {
                let now = Date()
                if attachedWindowMissingSince == nil {
                    attachedWindowMissingSince = now
                    return
                }
                guard now.timeIntervalSince(attachedWindowMissingSince ?? now)
                    >= attachedWindowGracePeriod else {
                    return
                }
                if let replacement = replacementDockCandidate(
                    for: window.frame,
                    attachment: attachment
                ) {
                    attach(to: replacement, animate: false)
                }
            } else {
                detachFromCodex()
            }
            return
        }
        guard codexWindow.ownerPID == attachment.ownerPID else {
            return
        }
        attachedWindowMissingSince = nil
        lastAttachedCodexFrame = codexWindow.frame
        if attachmentLocked, accessibilityObserver == nil, AXIsProcessTrusted() {
            startAccessibilityObserver(for: attachment, matching: codexWindow.frame)
        }
        guard let frame = dockedFrame(
                for: window.frame.size,
                beside: codexWindow.frame,
                side: attachment.side
              ) else {
            if attachmentLocked,
               let replacement = replacementDockCandidate(
                   for: window.frame,
                   attachment: attachment
               ) {
                attach(to: replacement, animate: false)
            } else if !attachmentLocked {
                detachFromCodex()
            }
            return
        }
        let frameChanged =
            abs(window.frame.minX - frame.minX) > 1
                || abs(window.frame.minY - frame.minY) > 1
                || abs(window.frame.width - frame.width) > 1
                || abs(window.frame.height - frame.height) > 1
        guard frameChanged else { return }
        applyDockFrame(frame, animate: animate)
    }

    private func replacementDockCandidate(
        for frame: NSRect,
        attachment: DockAttachment
    ) -> DockCandidate? {
        let anchor = lastAttachedCodexFrame
        return codexWindows()
            .filter { $0.ownerPID == attachment.ownerPID }
            .compactMap { codexWindow -> DockCandidate? in
                guard let docked = dockedFrame(
                    for: frame.size,
                    beside: codexWindow.frame,
                    side: attachment.side
                ) else {
                    return nil
                }
                let distance: CGFloat
                if let anchor {
                    distance = hypot(
                        codexWindow.frame.midX - anchor.midX,
                        codexWindow.frame.midY - anchor.midY
                    )
                } else {
                    distance = hypot(frame.midX - docked.midX, frame.midY - docked.midY)
                }
                return DockCandidate(
                    attachment: DockAttachment(
                        codexWindowID: codexWindow.id,
                        ownerPID: codexWindow.ownerPID,
                        side: attachment.side
                    ),
                    codexFrame: codexWindow.frame,
                    frame: docked,
                    distance: distance
                )
            }
            .min { $0.distance < $1.distance }
    }

    fileprivate func handleAttachedCodexAccessibilityEvent(_ notification: String) {
        guard attachmentLocked, dockAttachment != nil else { return }
        if notification == kAXUIElementDestroyedNotification as String {
            stopAccessibilityObserver()
            attachedWindowMissingSince = Date()
            return
        }
        guard let accessibilityWindow,
              let codexFrame = accessibilityFrame(for: accessibilityWindow),
              let window,
              let attachment = dockAttachment,
              let frame = dockedFrame(
                  for: window.frame.size,
                  beside: codexFrame,
                  side: attachment.side
              ) else {
            updateDockedFrame(animate: false)
            return
        }
        lastAttachedCodexFrame = codexFrame
        attachedWindowMissingSince = nil
        applyDockFrame(frame, animate: false)
        orderBehindAttachedCodex()
    }

    private func startAccessibilityObserver(
        for attachment: DockAttachment,
        matching codexFrame: NSRect
    ) {
        stopAccessibilityObserver()
        guard AXIsProcessTrusted(),
              let targetWindow = accessibilityWindow(
                  for: attachment.ownerPID,
                  matching: codexFrame
              ) else {
            return
        }

        var observer: AXObserver?
        guard AXObserverCreate(
            attachment.ownerPID,
            codexDockAccessibilityCallback,
            &observer
        ) == .success, let observer else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for notification in accessibilityNotifications {
            if AXObserverAddNotification(
                observer,
                targetWindow,
                notification as CFString,
                refcon
            ) == .success {
                registered = true
            }
        }
        guard registered else { return }

        accessibilityObserver = observer
        accessibilityWindow = targetWindow
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func stopAccessibilityObserver() {
        guard let observer = accessibilityObserver else {
            accessibilityWindow = nil
            return
        }
        if let accessibilityWindow {
            for notification in accessibilityNotifications {
                AXObserverRemoveNotification(
                    observer,
                    accessibilityWindow,
                    notification as CFString
                )
            }
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        accessibilityObserver = nil
        accessibilityWindow = nil
    }

    private func accessibilityWindow(
        for pid: pid_t,
        matching codexFrame: NSRect
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
            let windows = value as? [AXUIElement] else {
            return nil
        }
        return windows
            .compactMap { window -> (AXUIElement, CGFloat)? in
                guard let frame = accessibilityFrame(for: window) else { return nil }
                let distance = abs(frame.minX - codexFrame.minX)
                    + abs(frame.minY - codexFrame.minY)
                    + abs(frame.width - codexFrame.width)
                    + abs(frame.height - codexFrame.height)
                return (window, distance)
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func accessibilityFrame(for element: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
            AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
            ) == .success,
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }
        return CodexDockGeometry.appKitFrame(
            quartzOrigin: position,
            size: size,
            mainDisplayTop: mainDisplayTop
        )
    }

    private func applyDockFrame(_ frame: NSRect, animate: Bool) {
        guard let window else { return }
        isApplyingDockFrame = true
        window.setFrame(frame, display: true, animate: animate)
        if animate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                self?.isApplyingDockFrame = false
            }
        } else {
            isApplyingDockFrame = false
        }
    }

    private func dockedFrame(
        for size: NSSize,
        beside codexFrame: NSRect,
        side: DockSide
    ) -> NSRect? {
        if attachmentLocked {
            let visibleWidth = lockedVisibleWidth
                ?? max(480, size.width - (dockAttachment == nil ? 0 : cornerFillOverlap))
            return CodexDockGeometry.lockedFrame(
                beside: codexFrame,
                side: side,
                visibleWidth: visibleWidth,
                overlap: cornerFillOverlap,
                gap: dockGap
            )
        }

        guard let screen = screen(containing: codexFrame) else { return nil }
        let visible = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        let availableWidth = side == .left
            ? codexFrame.minX - visible.minX - dockGap
            : visible.maxX - codexFrame.maxX - dockGap
        let requestedVisibleWidth = dockAttachment == nil
            ? size.width
            : max(480, size.width - cornerFillOverlap)
        let visibleDockedWidth = min(requestedVisibleWidth, floor(availableWidth))
        guard visibleDockedWidth >= 480 else { return nil }
        let dockedWidth = visibleDockedWidth + cornerFillOverlap
        let dockedSize = NSSize(
            width: dockedWidth,
            height: min(codexFrame.height, visible.height)
        )
        let x = side == .left
            ? codexFrame.minX - dockedSize.width + cornerFillOverlap - dockGap
            : codexFrame.maxX - cornerFillOverlap + dockGap
        let y = min(
            max(codexFrame.minY, visible.minY),
            visible.maxY - dockedSize.height
        )
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: dockedSize)
        guard frame.minX >= visible.minX, frame.maxX <= visible.maxX,
              frame.minY >= visible.minY, frame.maxY <= visible.maxY else {
            return nil
        }
        return frame
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let point = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.screens.max {
                let left = NSIntersectionRect($0.frame, frame)
                let right = NSIntersectionRect($1.frame, frame)
                return left.width * left.height < right.width * right.height
            }
    }

    private var mainDisplayTop: CGFloat {
        NSScreen.screens
            .first { $0.frame.contains(NSPoint.zero) }?
            .frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    private func codexWindow(withID id: CGWindowID) -> CodexWindow? {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            id
        ) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap(codexWindow(from:)).first { $0.id == id }
    }

    private func codexWindows() -> [CodexWindow] {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap(codexWindow(from:))
    }

    private func codexWindow(from row: [String: Any]) -> CodexWindow? {
        let owner = row[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == "ChatGPT" || owner == "Codex",
              (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != false,
              let number = row[kCGWindowNumber as String] as? NSNumber,
              let ownerPID = row[kCGWindowOwnerPID as String] as? NSNumber,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(dictionaryRepresentation: bounds) else {
            return nil
        }
        guard quartzFrame.width >= 500, quartzFrame.height >= 400 else { return nil }
        return CodexWindow(
            id: CGWindowID(number.uint32Value),
            ownerPID: pid_t(ownerPID.int32Value),
            frame: CodexDockGeometry.appKitFrame(
                quartzOrigin: quartzFrame.origin,
                size: quartzFrame.size,
                mainDisplayTop: mainDisplayTop
            )
        )
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            self.handleWindowMoved()
        }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        Task { @MainActor in
            self.handleWindowResized()
        }
    }

    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        Task { @MainActor in
            self.handleWindowLiveResizeEnded()
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if let window = self.window {
                self.persistWorkbenchSize(of: window, for: self.workbenchMode)
            }
            self.detachFromCodex(restoreFrame: false)
            self.window = nil
            self.model = nil
        }
    }
}
