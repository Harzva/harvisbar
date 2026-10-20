import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// A deliberately narrow, opt-in helper for Harvis-attributed macOS access dialogs.
///
/// The image template is the primary detector. Accessibility text and the exact
/// Allow button are mandatory safety guards before any action can be performed.
@MainActor
final class PermissionWindowWatcher: ObservableObject {
    static let shared = PermissionWindowWatcher()

    @Published private(set) var isRunning = false
    @Published var autoClickEnabled = false
    @Published var keepRunningAfterClick = false
    @Published var idleThresholdSeconds: Double = 15 {
        didSet {
            idleThresholdSeconds = min(max(idleThresholdSeconds, 5), 120)
            defaults.set(idleThresholdSeconds, forKey: Keys.idleThreshold)
        }
    }
    @Published private(set) var status = "已停止"
    @Published private(set) var detail = "先录入整个权限弹窗模板，再以仅检测模式校准。"
    @Published private(set) var lastScore: Double?
    @Published private(set) var templateCount = 0
    @Published private(set) var screenCaptureAllowed = false
    @Published private(set) var accessibilityAllowed = false

    private enum Keys {
        static let idleThreshold = "harvis.permissionWatcher.idleThreshold"
    }

    private struct VisualTemplate {
        let aspectRatio: Double
        let feature: ImageFeature
    }

    private struct ImageFeature {
        let luminance: [Double]
        let edges: [Double]
    }

    private struct WindowCandidate {
        let key: String
        let allowButton: AXUIElement
        let order: Int
        let appName: String
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var templates: [VisualTemplate] = []
    private var stableCandidateKey: String?
    private var stableFrameCount = 0
    private var lastClickAt: Date?
    private var recentClickTimes: [Date] = []
    private var evaluationInFlight = false

    private init() {
        let savedIdle = defaults.double(forKey: Keys.idleThreshold)
        if savedIdle >= 5 {
            idleThresholdSeconds = savedIdle
        }
        refreshAuthorizationState()
        reloadTemplates()
    }

    func setRunning(_ enabled: Bool) {
        if enabled {
            guard !templates.isEmpty else {
                status = "缺少模板"
                detail = "请先截取或导入一个完整的 Harvis 权限弹窗模板。"
                isRunning = false
                return
            }
            refreshAuthorizationState()
            guard screenCaptureAllowed, accessibilityAllowed else {
                status = "等待系统授权"
                detail = "监视器需要屏幕录制来匹配图像，并需要辅助功能来读取和按下精确按钮。"
                isRunning = false
                return
            }
            isRunning = true
            status = autoClickEnabled ? "自动点击已待命" : "仅检测已待命"
            detail = "只接受含 Harvis 身份、精确允许按钮和高置信度模板匹配的前景弹窗。"
            startTimer()
            appendAudit(event: "watcher_started", score: nil, action: autoClickEnabled ? "auto_click" : "detect_only")
        } else {
            stop(reason: "已由用户停止")
        }
    }

    func runDetectionOnce() {
        Task { await evaluate(requireIdle: false, allowAction: false) }
    }

    func requestSystemPermissions() {
        _ = CGRequestScreenCaptureAccess()
        // Use the documented option key value directly so Swift 6 does not treat
        // the imported CoreFoundation global as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshAuthorizationState()
        }
    }

    func captureTemplateInteractively() {
        do {
            let directory = try ensureTemplateDirectory()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let destination = directory.appendingPathComponent("harvis-permission-\(formatter.string(from: Date())).png")
            status = "等待截图"
            detail = "请只框选最前面的完整权限弹窗；不要只截取“允许”按钮。"

            Task {
                let path = destination.path
                let exitCode = await Task.detached(priority: .userInitiated) { () -> Int32 in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-i", "-x", path]
                    do {
                        try process.run()
                        process.waitUntilExit()
                        return process.terminationStatus
                    } catch {
                        return -1
                    }
                }.value

                if exitCode == 0, FileManager.default.fileExists(atPath: path) {
                    reloadTemplates()
                    status = "模板已录入"
                    detail = "建议先点“检测一次”，确认分数与身份守卫，再开启自动点击。"
                    appendAudit(event: "template_captured", score: nil, action: destination.lastPathComponent)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    status = "截图已取消"
                    detail = "没有修改现有模板。"
                }
            }
        } catch {
            status = "模板目录不可用"
            detail = error.localizedDescription
        }
    }

    func importTemplate() {
        let panel = NSOpenPanel()
        panel.title = "导入 Harvis 权限弹窗模板"
        panel.message = "请选择只包含完整权限弹窗的 PNG 或 JPEG 图片。"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }

        do {
            let directory = try ensureTemplateDirectory()
            let stem = source.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
            let destination = directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(ext)")
            try FileManager.default.copyItem(at: source, to: destination)
            reloadTemplates()
            status = "模板已导入"
            detail = "已保存到 HarvisBar 的本机 Application Support；不会进入仓库。"
            appendAudit(event: "template_imported", score: nil, action: destination.lastPathComponent)
        } catch {
            status = "导入失败"
            detail = error.localizedDescription
        }
    }

    func revealTemplates() {
        do {
            let directory = try ensureTemplateDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            status = "模板目录不可用"
            detail = error.localizedDescription
        }
    }

    func refreshAuthorizationState() {
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        accessibilityAllowed = AXIsProcessTrusted()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.evaluate(requireIdle: true, allowAction: self.autoClickEnabled)
            }
        }
        timer?.tolerance = 0.2
    }

    private func stop(reason: String) {
        timer?.invalidate()
        timer = nil
        isRunning = false
        stableCandidateKey = nil
        stableFrameCount = 0
        status = "已停止"
        detail = reason
        appendAudit(event: "watcher_stopped", score: lastScore, action: nil)
    }

    private func evaluate(requireIdle: Bool, allowAction: Bool) async {
        guard !evaluationInFlight else { return }
        evaluationInFlight = true
        defer { evaluationInFlight = false }

        refreshAuthorizationState()
        guard screenCaptureAllowed, accessibilityAllowed else {
            status = "权限不足"
            detail = "请授予屏幕录制和辅助功能权限。"
            return
        }
        guard !templates.isEmpty else {
            status = "缺少模板"
            detail = "请先录入完整弹窗模板。"
            return
        }

        let idle = currentInputIdleSeconds()
        if requireIdle, idle < idleThresholdSeconds {
            status = "等待键鼠空闲"
            detail = "当前空闲 \(Int(idle)) 秒；阈值为 \(Int(idleThresholdSeconds)) 秒。"
            resetStability()
            return
        }

        guard let match = bestCandidate() else {
            status = allowAction ? "监视中" : "未检测到匹配"
            detail = "没有同时通过 Harvis 身份、允许按钮和图像模板守卫的前景弹窗。"
            lastScore = nil
            resetStability()
            return
        }

        lastScore = match.score
        guard match.score >= 0.90 else {
            status = "候选置信度不足"
            detail = "最高匹配 \(match.score.formatted(.percent.precision(.fractionLength(1))))；要求至少 90%。"
            resetStability()
            return
        }

        if stableCandidateKey == match.candidate.key {
            stableFrameCount += 1
        } else {
            stableCandidateKey = match.candidate.key
            stableFrameCount = 1
        }

        guard stableFrameCount >= 3 else {
            status = "正在复核弹窗"
            detail = "连续稳定帧 \(stableFrameCount)/3，匹配 \(match.score.formatted(.percent.precision(.fractionLength(1))))。"
            return
        }

        status = "已确认 Harvis 权限弹窗"
        detail = "\(match.candidate.appName) · 匹配 \(match.score.formatted(.percent.precision(.fractionLength(1)))) · 精确按钮“允许/Allow”。"
        appendAudit(event: "dialog_detected", score: match.score, action: allowAction ? "eligible" : "detect_only")

        guard allowAction else { return }
        guard clickRateLimitAllowsAction() else {
            status = "自动点击已限流"
            detail = "10 分钟内最多自动处理 3 次，且两次之间至少间隔 30 秒。"
            return
        }
        guard currentInputIdleSeconds() >= idleThresholdSeconds else {
            status = "点击前检测到用户活动"
            detail = "本次动作已取消；等待下一次完整空闲周期。"
            resetStability()
            return
        }

        let result = AXUIElementPerformAction(match.candidate.allowButton, kAXPressAction as CFString)
        guard result == .success else {
            status = "按钮操作失败"
            detail = "辅助功能返回错误码 \(result.rawValue)，未注入坐标点击。"
            appendAudit(event: "click_failed", score: match.score, action: "ax_press_\(result.rawValue)")
            resetStability()
            return
        }

        let now = Date()
        lastClickAt = now
        recentClickTimes.append(now)
        status = "已按下允许"
        detail = "已通过同一弹窗内的辅助功能按钮执行；未使用盲点坐标。"
        appendAudit(event: "allow_pressed", score: match.score, action: "ax_press")
        resetStability()
        if !keepRunningAfterClick {
            stop(reason: "单次模式已完成；再次使用需重新显式开启。")
        }
    }

    private func bestCandidate() -> (candidate: WindowCandidate, score: Double)? {
        let orderedWindows = cgWindowOrder()
        var matches: [(WindowCandidate, Double)] = []

        for application in NSWorkspace.shared.runningApplications where application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            guard let windows = axElements(appElement, attribute: kAXWindowsAttribute) else { continue }

            for window in windows {
                guard let frame = axFrame(window), frame.width >= 170, frame.height >= 100,
                      frame.width <= 900, frame.height <= 700 else { continue }
                let snapshot = inspect(window)
                guard snapshot.hasHarvisIdentity, snapshot.hasAccessLanguage,
                      let allowButton = snapshot.allowButton else { continue }
                let order = windowOrder(pid: application.processIdentifier, frame: frame, windows: orderedWindows)
                guard order <= 3 else { continue }
                guard let image = CGWindowListCreateImage(
                    frame,
                    .optionOnScreenOnly,
                    kCGNullWindowID,
                    [.bestResolution, .boundsIgnoreFraming]
                ) else { continue }
                let score = templateScore(for: image)
                let key = "\(application.processIdentifier):\(Int(frame.origin.x)):\(Int(frame.origin.y)):\(Int(frame.width)):\(Int(frame.height))"
                matches.append((WindowCandidate(
                    key: key,
                    allowButton: allowButton,
                    order: order,
                    appName: application.localizedName ?? "macOS"
                ), score))
            }
        }

        return matches.min { lhs, rhs in
            if lhs.0.order == rhs.0.order { return lhs.1 > rhs.1 }
            return lhs.0.order < rhs.0.order
        }
    }

    private func templateScore(for image: CGImage) -> Double {
        guard let candidate = makeFeature(image) else { return 0 }
        let ratio = Double(image.width) / Double(max(image.height, 1))
        return templates.reduce(0) { best, template in
            let ratioDelta = abs(log(max(ratio, 0.01) / max(template.aspectRatio, 0.01)))
            guard ratioDelta <= 0.22 else { return best }
            let luminance = correlation(candidate.luminance, template.feature.luminance)
            let edges = correlation(candidate.edges, template.feature.edges)
            let combined = max(0, min(1, luminance * 0.40 + edges * 0.60))
            return max(best, combined)
        }
    }

    private func reloadTemplates() {
        do {
            let directory = try ensureTemplateDirectory()
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }

            templates = urls.compactMap { url in
                guard let image = NSImage(contentsOf: url),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let feature = makeFeature(cgImage) else { return nil }
                return VisualTemplate(
                    aspectRatio: Double(cgImage.width) / Double(max(cgImage.height, 1)),
                    feature: feature
                )
            }
            templateCount = templates.count
        } catch {
            templates = []
            templateCount = 0
        }
    }

    private func makeFeature(_ image: CGImage) -> ImageFeature? {
        let width = 96
        let height = 72
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let luminance = bytes.map { Double($0) / 255.0 }
        var edges = [Double](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let gx = luminance[index + 1] - luminance[index - 1]
                let gy = luminance[index + width] - luminance[index - width]
                edges[index] = min(1, sqrt(gx * gx + gy * gy))
            }
        }
        return ImageFeature(luminance: luminance, edges: edges)
    }

    private func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let lhsMean = lhs.reduce(0, +) / Double(lhs.count)
        let rhsMean = rhs.reduce(0, +) / Double(rhs.count)
        var numerator = 0.0
        var lhsEnergy = 0.0
        var rhsEnergy = 0.0
        for index in lhs.indices {
            let a = lhs[index] - lhsMean
            let b = rhs[index] - rhsMean
            numerator += a * b
            lhsEnergy += a * a
            rhsEnergy += b * b
        }
        let denominator = sqrt(lhsEnergy * rhsEnergy)
        guard denominator > 0.000_001 else { return 0 }
        return max(0, numerator / denominator)
    }

    private func inspect(_ root: AXUIElement) -> (hasHarvisIdentity: Bool, hasAccessLanguage: Bool, allowButton: AXUIElement?) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var textParts: [String] = []
        var allowButton: AXUIElement?
        var visited = 0

        while !queue.isEmpty, visited < 240 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = axString(element, attribute: kAXRoleAttribute) ?? ""
            let title = axString(element, attribute: kAXTitleAttribute) ?? ""
            let value = axString(element, attribute: kAXValueAttribute) ?? ""
            let description = axString(element, attribute: kAXDescriptionAttribute) ?? ""
            textParts.append(contentsOf: [title, value, description].filter { !$0.isEmpty })

            if role == (kAXButtonRole as String) {
                let buttonName = [title, value, description]
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if buttonName == "允许" || buttonName.caseInsensitiveCompare("Allow") == .orderedSame {
                    allowButton = element
                }
            }

            if depth < 7, let children = axElements(element, attribute: kAXChildrenAttribute) {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }

        let combined = textParts.joined(separator: " ").lowercased()
        let hasHarvisIdentity = combined.contains("harvis") || combined.contains("h.a.r.v.i.s")
        let accessTokens = ["想访问", "访问", "文件", "可移除", "would like to access", "wants to access", "access files", "removable volume"]
        let hasAccessLanguage = accessTokens.contains { combined.contains($0) }
        return (hasHarvisIdentity, hasAccessLanguage, allowButton)
    }

    private func cgWindowOrder() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private func windowOrder(pid: pid_t, frame: CGRect, windows: [[String: Any]]) -> Int {
        for (index, info) in windows.enumerated() {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let candidate = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let delta = abs(candidate.minX - frame.minX) + abs(candidate.minY - frame.minY)
                + abs(candidate.width - frame.width) + abs(candidate.height - frame.height)
            if delta < 24 { return index }
        }
        return Int.max
    }

    private func currentInputIdleSeconds() -> Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    private func clickRateLimitAllowsAction() -> Bool {
        let now = Date()
        recentClickTimes = recentClickTimes.filter { now.timeIntervalSince($0) < 600 }
        if recentClickTimes.count >= 3 { return false }
        if let lastClickAt, now.timeIntervalSince(lastClickAt) < 30 { return false }
        return true
    }

    private func resetStability() {
        stableCandidateKey = nil
        stableFrameCount = 0
    }

    private func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? [AXUIElement]
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeDowncast(rawSize, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func permissionWatcherDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HarvisBar/PermissionWatcher", isDirectory: true)
    }

    private func ensureTemplateDirectory() throws -> URL {
        let directory = permissionWatcherDirectory().appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func appendAudit(event: String, score: Double?, action: String?) {
        do {
            let directory = permissionWatcherDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("events.jsonl")
            var payload: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "event": event,
                "mode": autoClickEnabled ? "auto_click" : "detect_only"
            ]
            if let score { payload["score"] = score }
            if let action { payload["action"] = action }
            let data = try JSONSerialization.data(withJSONObject: payload)
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            // Monitoring must remain fail-closed even if local audit persistence fails.
        }
    }
}

struct PermissionWatcherControls: View {
    @ObservedObject var watcher: PermissionWindowWatcher
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: watcher.isRunning ? "eye.circle.fill" : "eye.slash.circle")
                    .foregroundStyle(watcher.isRunning ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("权限窗口监视器")
                        .font(.caption.bold())
                    Text(watcher.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("监视", isOn: Binding(
                    get: { watcher.isRunning },
                    set: { watcher.setRunning($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Text(watcher.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 3 : 5)

            HStack(spacing: 8) {
                Toggle("自动点击", isOn: $watcher.autoClickEnabled)
                    .font(.caption2)
                Toggle("连续处理", isOn: $watcher.keepRunningAfterClick)
                    .font(.caption2)
                    .disabled(!watcher.autoClickEnabled)
                Spacer()
                Text("模板 \(watcher.templateCount)")
                    .font(.caption2.monospacedDigit())
            }

            HStack(spacing: 6) {
                Stepper(value: $watcher.idleThresholdSeconds, in: 5...120, step: 5) {
                    Text("空闲 \(Int(watcher.idleThresholdSeconds))s")
                        .font(.caption2.monospacedDigit())
                }
                if let score = watcher.lastScore {
                    Text(score.formatted(.percent.precision(.fractionLength(1))))
                        .font(.caption2.monospacedDigit())
                }
            }

            HStack(spacing: 6) {
                Button("检测一次") { watcher.runDetectionOnce() }
                Button("截取模板") { watcher.captureTemplateInteractively() }
                Button("导入") { watcher.importTemplate() }
                Button("模板目录") { watcher.revealTemplates() }
            }
            .font(.caption2)
            .buttonStyle(.bordered)

            if !watcher.screenCaptureAllowed || !watcher.accessibilityAllowed {
                HStack(spacing: 8) {
                    Text("屏幕录制 \(watcher.screenCaptureAllowed ? "✓" : "×") · 辅助功能 \(watcher.accessibilityAllowed ? "✓" : "×")")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("请求授权") { watcher.requestSystemPermissions() }
                        .font(.caption2)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }
}
