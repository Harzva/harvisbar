#!/usr/bin/env swift

import ApplicationServices
import Cocoa
import Darwin
import Foundation

// Native macOS Accessibility inventory driver for HarvisBar.
//
// Safe defaults:
//   swift scripts/harvis_bar_ax_audit.swift --pid <pid>
//     - Reads the current "HarvisBar UI Test" window only.
//     - Does not press controls or move the scroll position.
//
// Explicit safe navigation mode:
//   swift scripts/harvis_bar_ax_audit.swift --pid <pid> --all-sections
//     - May press only the 12 hard-coded harvis.section.* navigation buttons.
//     - Scrolls with the AX scrollbar, inventories each page, then restores the
//       originally selected page and scroll value.
//     - Never presses page actions, global actions, menu items, or Quit.

private let sectionNames = [
    "overview", "codex", "agents", "system",
    "network", "dsh", "ports", "tools",
    "work", "review", "memory", "persona",
]

private let allowedSectionIdentifiers = Set(
    sectionNames.map { "harvis.section.\($0)" }
)

private struct Options {
    var pid: pid_t?
    var windowTitle = "HarvisBar UI Test"
    var allSections = false
    var maxScrollSteps = 10
    var settleMilliseconds = 220
}

private struct RectSnapshot: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct NodeSnapshot: Codable {
    let key: String
    let path: String
    let identifier: String
    let role: String
    let subrole: String
    let title: String
    let description: String
    let help: String
    let value: String
    let enabled: Bool?
    let selected: Bool?
    let frame: RectSnapshot?
    let actions: [String]
}

private struct PageSnapshot: Codable {
    let section: String
    let navigationIdentifier: String
    let navigationPressResult: Int32?
    let navigationSelected: Bool
    let scrollMethod: String
    let scrollPositions: [Double]
    let interactiveNodes: [NodeSnapshot]
    let warnings: [String]
}

private struct AuditReport: Codable {
    let pid: Int32
    let windowTitle: String
    let mode: String
    let trusted: Bool
    let originalSection: String?
    let navigationIdentifiers: [String]
    let missingNavigationIdentifiers: [String]
    let fixedInteractiveNodes: [NodeSnapshot]
    let currentPageInteractiveNodes: [NodeSnapshot]
    let pages: [PageSnapshot]
    let restoredSection: Bool
    let restoredScroll: Bool
    let warnings: [String]
}

private enum DriverError: Error, CustomStringConvertible {
    case usage(String)
    case accessibilityPermission
    case processUnavailable(pid_t)
    case windowUnavailable(String)
    case unsafeIdentifier(String)
    case navigationUnavailable(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .accessibilityPermission: return "Accessibility permission is not granted"
        case .processUnavailable(let pid): return "No AX application for PID \(pid)"
        case .windowUnavailable(let title): return "AX window not found: \(title)"
        case .unsafeIdentifier(let identifier): return "Refusing non-allowlisted press: \(identifier)"
        case .navigationUnavailable(let identifier): return "Navigation control not found: \(identifier)"
        }
    }
}

private func stderr(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

private func parseOptions() throws -> Options {
    var options = Options()
    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
        switch arguments[index] {
        case "--pid":
            guard index + 1 < arguments.count,
                  let value = Int32(arguments[index + 1]),
                  value > 0 else {
                throw DriverError.usage("Usage: --pid <positive integer>")
            }
            options.pid = value
            index += 2
        case "--window-title":
            guard index + 1 < arguments.count else {
                throw DriverError.usage("Usage: --window-title <title>")
            }
            options.windowTitle = arguments[index + 1]
            index += 2
        case "--all-sections":
            options.allSections = true
            index += 1
        case "--max-scroll-steps":
            guard index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]),
                  (2...40).contains(value) else {
                throw DriverError.usage("Usage: --max-scroll-steps <2...40>")
            }
            options.maxScrollSteps = value
            index += 2
        case "--settle-ms":
            guard index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]),
                  (50...2000).contains(value) else {
                throw DriverError.usage("Usage: --settle-ms <50...2000>")
            }
            options.settleMilliseconds = value
            index += 2
        case "--help", "-h":
            throw DriverError.usage(
                "Usage: \(arguments[0]) --pid <pid> [--all-sections] " +
                "[--window-title <title>] [--max-scroll-steps <2...40>] " +
                "[--settle-ms <50...2000>]"
            )
        default:
            throw DriverError.usage("Unknown argument: \(arguments[index])")
        }
    }
    guard options.pid != nil else {
        throw DriverError.usage("Missing required --pid <pid>")
    }
    return options
}

private final class AXDriver {
    let pid: pid_t
    let application: AXUIElement
    let settleMicroseconds: useconds_t

    init(pid: pid_t, settleMilliseconds: Int) throws {
        guard AXIsProcessTrusted() else {
            throw DriverError.accessibilityPermission
        }
        self.pid = pid
        self.application = AXUIElementCreateApplication(pid)
        self.settleMicroseconds = useconds_t(settleMilliseconds * 1_000)

        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXRoleAttribute as CFString,
            &role
        ) == .success else {
            throw DriverError.processUnavailable(pid)
        }
    }

    func copy(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else {
            return nil
        }
        return raw
    }

    func elements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        (copy(element, attribute) as? [AnyObject] ?? []).map { $0 as! AXUIElement }
    }

    func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute as CFString)
    }

    func string(_ element: AXUIElement, _ attribute: CFString) -> String {
        if let value = copy(element, attribute) as? String { return value }
        if let value = copy(element, attribute) as? NSAttributedString { return value.string }
        return ""
    }

    func displayValue(_ element: AXUIElement, _ attribute: CFString) -> String {
        guard let raw = copy(element, attribute) else { return "" }
        if let value = raw as? String { return value }
        if let value = raw as? NSAttributedString { return value.string }
        if let value = raw as? NSNumber { return value.stringValue }
        return String(describing: raw)
    }

    func bool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        (copy(element, attribute) as? NSNumber)?.boolValue
    }

    func double(_ element: AXUIElement, _ attribute: CFString) -> Double? {
        (copy(element, attribute) as? NSNumber)?.doubleValue
    }

    func frame(_ element: AXUIElement) -> CGRect? {
        var point = CGPoint.zero
        var size = CGSize.zero
        guard let rawPoint = copy(element, kAXPositionAttribute as CFString),
              let rawSize = copy(element, kAXSizeAttribute as CFString),
              CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID(),
              AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    func actions(_ element: AXUIElement) -> [String] {
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success else { return [] }
        return (raw as? [String] ?? []).sorted()
    }

    func walk(
        _ root: AXUIElement,
        maximumNodes: Int = 2_500
    ) -> [(element: AXUIElement, path: String)] {
        var queue: [(AXUIElement, String)] = [(root, "0")]
        var output: [(AXUIElement, String)] = []
        var seen = Set<CFHashCode>()

        while !queue.isEmpty, output.count < maximumNodes {
            let (element, path) = queue.removeFirst()
            guard seen.insert(CFHash(element)).inserted else { continue }
            output.append((element, path))
            for (index, child) in children(element).enumerated() {
                queue.append((child, "\(path).\(index)"))
            }
        }
        return output
    }

    func window(titled expectedTitle: String, timeout: TimeInterval = 8) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let windows = elements(application, kAXWindowsAttribute as CFString)
            if let exact = windows.first(where: {
                string($0, kAXTitleAttribute as CFString) == expectedTitle
            }) {
                return exact
            }
            usleep(100_000)
        } while Date() < deadline
        throw DriverError.windowUnavailable(expectedTitle)
    }

    func find(
        identifier: String,
        in window: AXUIElement
    ) -> AXUIElement? {
        walk(window).first {
            string($0.element, kAXIdentifierAttribute as CFString) == identifier
        }?.element
    }

    func mainScrollArea(in window: AXUIElement) -> AXUIElement? {
        walk(window)
            .map(\.element)
            .filter {
                string($0, kAXRoleAttribute as CFString) == (kAXScrollAreaRole as String)
            }
            .max {
                let left = frame($0).map { $0.width * $0.height } ?? 0
                let right = frame($1).map { $0.width * $0.height } ?? 0
                return left < right
            }
    }

    func selectedSection(in window: AXUIElement) -> String? {
        for name in sectionNames {
            let identifier = "harvis.section.\(name)"
            guard let node = find(identifier: identifier, in: window) else { continue }
            if bool(node, kAXSelectedAttribute as CFString) == true { return name }
        }
        return nil
    }

    func waitForNavigationIdentifiers(
        inWindowTitled title: String,
        timeout: TimeInterval = 6
    ) throws -> ([String], [String]) {
        let deadline = Date().addingTimeInterval(timeout)
        var present = Set<String>()
        repeat {
            let window = try self.window(titled: title)
            present = Set(walk(window).compactMap { item in
                let identifier = string(item.element, kAXIdentifierAttribute as CFString)
                return allowedSectionIdentifiers.contains(identifier) ? identifier : nil
            })
            if present == allowedSectionIdentifiers { break }
            usleep(150_000)
        } while Date() < deadline

        let orderedPresent = sectionNames
            .map { "harvis.section.\($0)" }
            .filter { present.contains($0) }
        let missing = sectionNames
            .map { "harvis.section.\($0)" }
            .filter { !present.contains($0) }
        return (orderedPresent, missing)
    }

    @discardableResult
    func pressSection(
        identifier: String,
        windowTitle: String,
        timeout: TimeInterval = 6
    ) throws -> AXError {
        guard allowedSectionIdentifiers.contains(identifier) else {
            throw DriverError.unsafeIdentifier(identifier)
        }
        let window = try self.window(titled: windowTitle)
        guard let node = find(identifier: identifier, in: window) else {
            throw DriverError.navigationUnavailable(identifier)
        }
        let result = AXUIElementPerformAction(node, kAXPressAction as CFString)
        guard result == .success else { return result }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let freshWindow = try self.window(titled: windowTitle)
            if let fresh = find(identifier: identifier, in: freshWindow),
               bool(fresh, kAXSelectedAttribute as CFString) == true {
                usleep(settleMicroseconds)
                return result
            }
            usleep(100_000)
        } while Date() < deadline
        return result
    }

    func isInteractive(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute as CFString)
        let subrole = string(element, kAXSubroleAttribute as CFString)
        let standardWindowSubroles = Set([
            kAXCloseButtonSubrole as String,
            kAXMinimizeButtonSubrole as String,
            kAXZoomButtonSubrole as String,
            kAXFullScreenButtonSubrole as String,
        ])
        if standardWindowSubroles.contains(subrole) { return false }

        let interactiveRoles = Set([
            kAXButtonRole as String,
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXMenuButtonRole as String,
            kAXPopUpButtonRole as String,
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            kAXSliderRole as String,
            kAXIncrementorRole as String,
            "AXLink",
            kAXMenuItemRole as String,
            kAXDisclosureTriangleRole as String,
            "AXTab",
        ])
        if interactiveRoles.contains(role) { return true }

        let meaningfulActions = Set([
            kAXPressAction as String,
            kAXConfirmAction as String,
            kAXShowMenuAction as String,
            kAXIncrementAction as String,
            kAXDecrementAction as String,
            kAXPickAction as String,
        ])
        return !meaningfulActions.isDisjoint(with: actions(element))
    }

    func snapshot(_ element: AXUIElement, path: String) -> NodeSnapshot {
        let identifier = string(element, kAXIdentifierAttribute as CFString)
        let role = string(element, kAXRoleAttribute as CFString)
        let subrole = string(element, kAXSubroleAttribute as CFString)
        let title = string(element, kAXTitleAttribute as CFString)
        let description = string(element, kAXDescriptionAttribute as CFString)
        let help = string(element, kAXHelpAttribute as CFString)
        let value = displayValue(element, kAXValueAttribute as CFString)
        let rect = frame(element).map {
            RectSnapshot(
                x: $0.origin.x,
                y: $0.origin.y,
                width: $0.size.width,
                height: $0.size.height
            )
        }
        let semantic = [role, subrole, title, description, help].joined(separator: "|")
        let key = identifier.isEmpty ? "path:\(path)|\(semantic)" : "id:\(identifier)"
        return NodeSnapshot(
            key: key,
            path: path,
            identifier: identifier,
            role: role,
            subrole: subrole,
            title: title,
            description: description,
            help: help,
            value: value,
            enabled: bool(element, kAXEnabledAttribute as CFString),
            selected: bool(element, kAXSelectedAttribute as CFString),
            frame: rect,
            actions: actions(element)
        )
    }

    func interactiveSnapshots(in root: AXUIElement) -> [NodeSnapshot] {
        walk(root)
            .filter { isInteractive($0.element) }
            .map { snapshot($0.element, path: $0.path) }
    }

    func fixedInteractiveSnapshots(in window: AXUIElement) -> [NodeSnapshot] {
        let scrollHashes: Set<CFHashCode>
        if let scroll = mainScrollArea(in: window) {
            scrollHashes = Set(walk(scroll).map { CFHash($0.element) })
        } else {
            scrollHashes = []
        }
        return walk(window)
            .filter { !scrollHashes.contains(CFHash($0.element)) && isInteractive($0.element) }
            .map { snapshot($0.element, path: $0.path) }
    }

    func verticalScrollBar(in scrollArea: AXUIElement) -> AXUIElement? {
        copy(scrollArea, kAXVerticalScrollBarAttribute as CFString).map { $0 as! AXUIElement }
    }

    func scrollValue(in scrollArea: AXUIElement) -> Double? {
        guard let bar = verticalScrollBar(in: scrollArea) else { return nil }
        return double(bar, kAXValueAttribute as CFString)
    }

    func setScrollValue(_ value: Double, in scrollArea: AXUIElement) -> AXError {
        guard let bar = verticalScrollBar(in: scrollArea) else { return .attributeUnsupported }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            bar,
            kAXValueAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return .notImplemented
        }
        return AXUIElementSetAttributeValue(
            bar,
            kAXValueAttribute as CFString,
            NSNumber(value: max(0, min(value, 1)))
        )
    }

    func restoreScrollValue(
        _ value: Double,
        inWindowTitled windowTitle: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let target = max(0, min(value, 1))
        let epsilon = 0.005
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            guard let freshWindow = try? window(titled: windowTitle, timeout: 0.5),
                  let scroll = mainScrollArea(in: freshWindow) else {
                usleep(100_000)
                continue
            }

            if let current = scrollValue(in: scroll), abs(current - target) <= epsilon {
                return true
            }

            let result = setScrollValue(target, in: scroll)
            usleep(settleMicroseconds)

            if let observedWindow = try? window(titled: windowTitle, timeout: 0.5),
               let observedScroll = mainScrollArea(in: observedWindow) {
                if let observed = scrollValue(in: observedScroll),
                   abs(observed - target) <= epsilon {
                    return true
                }

                // Short pages can expose no writable scrollbar at all. When the
                // saved position was the top, that already represents a complete
                // restoration rather than a failed write.
                if target <= epsilon,
                   result != .success,
                   scrollValue(in: observedScroll) == nil {
                    return true
                }
            }
        } while Date() < deadline

        return false
    }

    func collectCurrentContent(
        windowTitle: String,
        scrollAll: Bool,
        maximumSteps: Int
    ) throws -> (
        nodes: [NodeSnapshot],
        method: String,
        positions: [Double],
        originalScroll: Double?,
        restored: Bool,
        warnings: [String]
    ) {
        let initialWindow = try window(titled: windowTitle)
        guard let initialScroll = mainScrollArea(in: initialWindow) else {
            return ([], "none", [], nil, true, ["Main AXScrollArea not found"])
        }

        let originalScroll = scrollValue(in: initialScroll)
        if !scrollAll {
            return (
                interactiveSnapshots(in: initialScroll),
                "read-only-current-position",
                originalScroll.map { [$0] } ?? [],
                originalScroll,
                true,
                []
            )
        }

        var warnings: [String] = []
        var byKey: [String: NodeSnapshot] = [:]
        for node in interactiveSnapshots(in: initialScroll) {
            byKey[node.key] = node
        }
        let denominator = max(1, maximumSteps - 1)
        let requested = (0..<maximumSteps).map { Double($0) / Double(denominator) }
        var observed: [Double] = []
        var method = "AXVerticalScrollBar.AXValue"
        var valueScrollingAvailable = true

        for position in requested {
            let freshWindow = try window(titled: windowTitle)
            guard let scroll = mainScrollArea(in: freshWindow) else {
                warnings.append("Scroll area disappeared at requested position \(position)")
                break
            }
            let result = setScrollValue(position, in: scroll)
            if result != .success {
                valueScrollingAvailable = false
                break
            }
            usleep(settleMicroseconds)
            let observedValue = scrollValue(in: scroll) ?? position
            observed.append(observedValue)

            let postWindow = try window(titled: windowTitle)
            guard let postScroll = mainScrollArea(in: postWindow) else { continue }
            for node in interactiveSnapshots(in: postScroll) {
                byKey[node.key] = node
            }
        }

        if !valueScrollingAvailable {
            method = "current-position-only"
            let freshWindow = try window(titled: windowTitle)
            if let scroll = mainScrollArea(in: freshWindow),
               actions(scroll).contains("AXScrollDownByPage") {
                var successfulPages = 0
                for _ in 0..<maximumSteps {
                    let result = AXUIElementPerformAction(
                        scroll,
                        "AXScrollDownByPage" as CFString
                    )
                    guard result == .success else { break }
                    successfulPages += 1
                    usleep(settleMicroseconds)
                    let postWindow = try window(titled: windowTitle)
                    guard let postScroll = mainScrollArea(in: postWindow) else { break }
                    observed.append(scrollValue(in: postScroll) ?? Double(successfulPages))
                    for node in interactiveSnapshots(in: postScroll) {
                        byKey[node.key] = node
                    }
                }
                if successfulPages > 0 {
                    method = "AXScrollDownByPage"
                    for _ in 0..<(successfulPages + 2) {
                        let restoreWindow = try window(titled: windowTitle)
                        guard let restoreScroll = mainScrollArea(in: restoreWindow) else { break }
                        let result = AXUIElementPerformAction(
                            restoreScroll,
                            "AXScrollUpByPage" as CFString
                        )
                        if result != .success { break }
                        usleep(settleMicroseconds)
                    }
                }
            }
        }

        let restored = originalScroll.map {
            restoreScrollValue($0, inWindowTitled: windowTitle)
        } ?? true

        if !valueScrollingAvailable, method == "current-position-only" {
            // A short page commonly exposes a disabled scrollbar whose AXValue
            // rejects writes. Its current tree is already the complete page.
            observed = originalScroll.map { [$0] } ?? []
        }

        return (
            byKey.values.sorted { $0.key < $1.key },
            method,
            observed,
            originalScroll,
            restored,
            warnings
        )
    }
}

private func run() throws -> AuditReport {
    let options = try parseOptions()
    let pid = options.pid!
    let driver = try AXDriver(pid: pid, settleMilliseconds: options.settleMilliseconds)
    let initialWindow = try driver.window(titled: options.windowTitle)
    let originalSection = driver.selectedSection(in: initialWindow)
    let initialScroll = driver.mainScrollArea(in: initialWindow)
        .flatMap { driver.scrollValue(in: $0) }
    let (navigationIdentifiers, missingNavigationIdentifiers) = try driver
        .waitForNavigationIdentifiers(inWindowTitled: options.windowTitle)
    let refreshedInitialWindow = try driver.window(titled: options.windowTitle)
    let fixedNodes = driver.fixedInteractiveSnapshots(in: refreshedInitialWindow)

    if !options.allSections {
        let current = try driver.collectCurrentContent(
            windowTitle: options.windowTitle,
            scrollAll: false,
            maximumSteps: options.maxScrollSteps
        )
        return AuditReport(
            pid: pid,
            windowTitle: options.windowTitle,
            mode: "read-only-current-page",
            trusted: AXIsProcessTrusted(),
            originalSection: originalSection,
            navigationIdentifiers: navigationIdentifiers,
            missingNavigationIdentifiers: missingNavigationIdentifiers,
            fixedInteractiveNodes: fixedNodes,
            currentPageInteractiveNodes: current.nodes,
            pages: [],
            restoredSection: true,
            restoredScroll: true,
            warnings: missingNavigationIdentifiers.isEmpty
                ? []
                : ["Navigation identifiers were still missing after stabilization"]
        )
    }

    var pages: [PageSnapshot] = []
    var globalWarnings: [String] = []
    var allScrollRestored = true

    for section in sectionNames {
        let identifier = "harvis.section.\(section)"
        guard navigationIdentifiers.contains(identifier) else {
            pages.append(PageSnapshot(
                section: section,
                navigationIdentifier: identifier,
                navigationPressResult: nil,
                navigationSelected: false,
                scrollMethod: "none",
                scrollPositions: [],
                interactiveNodes: [],
                warnings: ["Navigation identifier unavailable"]
            ))
            continue
        }

        let result = try driver.pressSection(
            identifier: identifier,
            windowTitle: options.windowTitle
        )
        let selectedWindow = try driver.window(titled: options.windowTitle)
        let selected = driver.find(identifier: identifier, in: selectedWindow)
            .flatMap { driver.bool($0, kAXSelectedAttribute as CFString) } == true
        let content = try driver.collectCurrentContent(
            windowTitle: options.windowTitle,
            scrollAll: true,
            maximumSteps: options.maxScrollSteps
        )
        allScrollRestored = allScrollRestored && content.restored

        pages.append(PageSnapshot(
            section: section,
            navigationIdentifier: identifier,
            navigationPressResult: result.rawValue,
            navigationSelected: selected,
            scrollMethod: content.method,
            scrollPositions: content.positions,
            interactiveNodes: content.nodes,
            warnings: content.warnings
        ))
    }

    var restoredSection = originalSection == nil
    if let originalSection {
        let identifier = "harvis.section.\(originalSection)"
        let result = try driver.pressSection(
            identifier: identifier,
            windowTitle: options.windowTitle
        )
        let restoredWindow = try driver.window(titled: options.windowTitle)
        restoredSection = result == .success
            && driver.find(identifier: identifier, in: restoredWindow)
                .flatMap { driver.bool($0, kAXSelectedAttribute as CFString) } == true

        if let initialScroll {
            allScrollRestored = allScrollRestored && driver.restoreScrollValue(
                initialScroll,
                inWindowTitled: options.windowTitle
            )
        }
    }

    if !restoredSection { globalWarnings.append("Original section was not restored") }
    if !allScrollRestored { globalWarnings.append("One or more scroll values were not restored") }
    if !missingNavigationIdentifiers.isEmpty {
        globalWarnings.append("Navigation identifier coverage is incomplete")
    }

    return AuditReport(
        pid: pid,
        windowTitle: options.windowTitle,
        mode: "safe-all-sections",
        trusted: AXIsProcessTrusted(),
        originalSection: originalSection,
        navigationIdentifiers: navigationIdentifiers,
        missingNavigationIdentifiers: missingNavigationIdentifiers,
        fixedInteractiveNodes: fixedNodes,
        currentPageInteractiveNodes: [],
        pages: pages,
        restoredSection: restoredSection,
        restoredScroll: allScrollRestored,
        warnings: globalWarnings
    )
}

do {
    let report = try run()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    stderr("harvis_bar_ax_audit: \(error)")
    exit(EXIT_FAILURE)
}
