import AppKit
import Foundation
import SwiftUI
import WebKit

struct HarvisNetworkContainerView: View {
    @ObservedObject var model: HarvisRuntimeModel

    var body: some View {
        Group {
            if let url = model.networkURL() {
                HarvisNetworkWebView(url: url, model: model)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 34))
                    Text("Network console unavailable")
                        .font(.headline)
                    Text("Check the local H.A.R.V.I.S. runtime port.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}

private struct HarvisNetworkWebView: NSViewRepresentable {
    let url: URL
    let model: HarvisRuntimeModel

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: HarvisRuntimeModel
        weak var webView: WKWebView?

        init(model: HarvisRuntimeModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            Task { @MainActor in
                let payload = await model.networkConsoleSnapshot()
                deliver(payload)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "harvisNetwork",
                  let payload = message.body as? [String: Any]
            else { return }
            Task { @MainActor in
                let response = await model.performNetworkConsoleAction(payload)
                deliver(response)
            }
        }

        @MainActor
        private func deliver(_ payload: String) {
            webView?.evaluateJavaScript("window.HarvisNetwork && window.HarvisNetwork.receive(\(payload));")
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "harvisNetwork")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "harvisNetwork")
        webView.navigationDelegate = nil
    }
}

struct HarvisDesktopView: View {
    @EnvironmentObject var model: HarvisRuntimeModel

    private var theme: HarvisTheme { model.theme }

    var body: some View {
        VStack(spacing: 0) {
            desktopToolbar
            Divider()
                .overlay(theme.line)
            HStack(spacing: 0) {
                companionRail
                    .frame(width: 286)
                Divider()
                    .overlay(theme.line)
                studioWorkspace
            }
        }
        .background(
            theme.usesFlatSurfaces ? AnyShapeStyle(theme.background) : AnyShapeStyle(LinearGradient(
                colors: [theme.background, theme.surfaceAlt.opacity(0.72), theme.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        )
        .foregroundColor(theme.text)
        .tint(theme.accent)
        .preferredColorScheme(theme.preferredColorScheme)
    }

    private var desktopToolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.usesFlatSurfaces ? AnyShapeStyle(theme.accent) : AnyShapeStyle(LinearGradient(colors: [theme.accent, theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Text("H")
                            .font(.system(size: 18, weight: .black))
                            .foregroundColor(theme.usesFlatSurfaces ? theme.selectionText : .white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("H.A.R.V.I.S. Desktop")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Local teammate cockpit")
                        .font(.caption)
                        .foregroundColor(theme.muted)
                }
            }

            Spacer()

            DesktopServiceChip(name: "HTTP", loaded: model.services?.service(named: "http")?.loaded, running: model.services?.service(named: "http")?.running, listening: model.services?.service(named: "http")?.listening, theme: theme)
            DesktopServiceChip(name: "Tick", loaded: model.services?.service(named: "tick")?.loaded, running: model.services?.service(named: "tick")?.running, listening: nil, theme: theme)

            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)

            Button {
                model.startServices()
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .disabled(model.isBusy)

            Button {
                model.restartServices()
            } label: {
                Label("Restart", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(theme.surface.opacity(0.76))
    }

    private var companionRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        HarvisAvatarView()
                            .environmentObject(model)
                            .frame(width: 76, height: 76)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.currentState.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(model.tintColor)
                            Text(model.stateCaption)
                                .font(.caption2)
                                .foregroundColor(theme.muted)
                            Text(model.shortSummary)
                                .font(.caption)
                                .foregroundColor(theme.muted)
                                .lineLimit(4)
                        }
                    }

                    HarvisThemePicker(
                        selection: $model.themeID,
                        theme: theme,
                        label: "Theme"
                    )

                    Text(model.theme.subtitle)
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                }
                .padding(12)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    DesktopMetricTile(title: "Packets", value: model.barStatus?.work?.packets ?? 0, theme: theme)
                    DesktopMetricTile(title: "Runs", value: model.barStatus?.work?.runs ?? 0, theme: theme)
                    DesktopMetricTile(title: "Approvals", value: model.barStatus?.work?.pendingApprovals ?? 0, theme: theme)
                    DesktopMetricTile(title: "Blocked", value: model.barStatus?.work?.blocked ?? 0, theme: theme)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Important Ports")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(model.barStatus?.ports?.summary ?? "not loaded")
                            .font(.caption2)
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                    }
                    ForEach(model.importantPorts) { item in
                        Button {
                            model.openPort(item)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.listening == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundColor(item.listening == true ? theme.positive : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label ?? item.id)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                    Text(item.detailSummary)
                                        .font(.caption2)
                                        .foregroundColor(theme.muted)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(":\(item.port ?? 0)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(theme.muted)
                            }
                            .padding(8)
                            .background(theme.surfaceAlt.opacity(0.74))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line.opacity(0.72)))
                        }
                        .buttonStyle(.plain)
                    }
                    DesktopActionButton(title: "Open Port Manager", systemImage: "network", theme: theme) {
                        model.openPorts()
                    }
                }
                .padding(12)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("First Run")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(model.firstRunSummary)
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(model.firstRunReadyCount == model.firstRunSteps.count ? theme.positive : theme.accent)
                    }
                    ForEach(model.firstRunSteps) { step in
                        FirstRunStepRow(step: step, theme: theme)
                    }
                    HStack(spacing: 8) {
                        DesktopActionButton(title: "Initialize", systemImage: "wand.and.stars", theme: theme) {
                            model.initializeFirstRun()
                        }
                        DesktopActionButton(title: "FDA", systemImage: "lock.shield", theme: theme) {
                            model.openFullDiskAccessSettings()
                        }
                    }
                }
                .padding(12)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))

                PermissionWatcherControls(watcher: .shared, compact: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Actions")
                        .font(.system(size: 12, weight: .semibold))
                    DesktopActionButton(title: "Test cxspark", systemImage: "checkmark.seal", theme: theme) {
                        model.testHarnesses()
                    }
                    DesktopActionButton(title: "Open Studio in Browser", systemImage: "safari", theme: theme) {
                        model.openStudio()
                    }
                    DesktopActionButton(title: "Open H5Magic Workbench", systemImage: "wand.and.stars.inverse", theme: theme) {
                        model.openH5MagicWorkbench()
                    }
                    DesktopActionButton(title: "Open Presence", systemImage: "sparkles", theme: theme) {
                        model.openPresence()
                    }
                    DesktopActionButton(title: "Archive Scheduled Codex Chats", systemImage: "archivebox.fill", theme: theme) {
                        model.archiveScheduledCodexThreads()
                    }
                    DesktopActionButton(title: "Open Ports", systemImage: "network", theme: theme) {
                        model.openPorts()
                    }
                    DesktopActionButton(title: "Open Network Console", systemImage: "point.3.connected.trianglepath.dotted", theme: theme) {
                        model.openNetworkConsole()
                    }
                    DesktopActionButton(title: "Reveal Logs", systemImage: "doc.text.magnifyingglass", theme: theme) {
                        model.revealLogs()
                    }
                    DesktopActionButton(title: "Full Disk Access", systemImage: "lock.shield", theme: theme) {
                        model.openFullDiskAccessSettings()
                    }
                    if let result = model.codexArchiveResult {
                        Text(result.summary)
                            .font(.caption2)
                            .foregroundColor(theme.muted)
                    }
                }
                .padding(12)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Workspace")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("Workspace root", text: $model.workspaceRoot)
                    TextField("Profile root", text: $model.profileRoot)
                    HStack(spacing: 8) {
                        TextField("Port", text: $model.portText)
                            .frame(width: 74)
                        Button("Apply") {
                            Task { await model.refreshAll() }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
            }
            .padding(14)
        }
        .background(theme.background.opacity(0.46))
    }

    private var studioWorkspace: some View {
        ZStack {
            theme.surfaceAlt.opacity(0.32)
            if let url = model.studioURL() {
                HarvisStudioWebView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                    .shadow(color: theme.shadow, radius: theme.usesFlatSurfaces ? 0 : 18, x: 0, y: theme.usesFlatSurfaces ? 0 : 14)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundColor(theme.accent)
                    Text("Studio URL is unavailable.")
                        .font(.headline)
                    Text("Check the local port and H.A.R.V.I.S. service settings.")
                        .foregroundColor(theme.muted)
                }
            }
        }
    }
}

struct HarvisStudioWebView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var lastURL: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let next = url.absoluteString
        guard context.coordinator.lastURL != next else { return }
        context.coordinator.lastURL = next
        webView.load(URLRequest(url: url))
    }
}

struct HarvisAvatarView: View {
    @EnvironmentObject var model: HarvisRuntimeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var avatarImage: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(model.theme.surfaceAlt)
                    .overlay(Text("H").font(.system(size: 28, weight: .black)))
            }
            Circle()
                .fill(model.tintColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(model.theme.surface, lineWidth: 2))
                .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.tintColor.opacity(reduceMotion ? 0.36 : (pulse ? 0.52 : 0.18)), lineWidth: 2)
                .scaleEffect(reduceMotion ? 1 : (pulse ? 1.08 : 0.96))
                .opacity(reduceMotion ? 0.72 : (pulse ? 0.88 : 0.36))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.theme.line))
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
            value: pulse
        )
        .onAppear {
            pulse = true
        }
        .task(id: model.personaImageCandidatePaths) {
            avatarImage = nil
            let candidatePaths = model.personaImageCandidatePaths
            let data = await model.avatarImageLoadCache.data(
                candidatePaths: candidatePaths
            )
            guard !Task.isCancelled else { return }
            avatarImage = data.flatMap(NSImage.init(data:))
        }
    }
}

private struct DesktopMetricTile: View {
    let title: String
    let value: Int
    let theme: HarvisTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundColor(theme.muted)
            Text("\(value)")
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
    }
}

private struct DesktopServiceChip: View {
    let name: String
    let loaded: Bool?
    let running: Bool?
    let listening: Bool?
    let theme: HarvisTheme

    var body: some View {
        let ok = listening ?? running ?? false
        let warning = (loaded ?? false) && !ok
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? theme.positive : (warning ? Color.orange : theme.muted))
                .frame(width: 7, height: 7)
            Text(name)
                .font(.caption)
                .foregroundColor(theme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.surfaceAlt.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
    }
}

private struct DesktopActionButton: View {
    let title: String
    let systemImage: String
    let theme: HarvisTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(theme.surfaceAlt.opacity(0.82))
        .foregroundColor(theme.text)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line))
    }
}

struct FirstRunStepRow: View {
    let step: FirstRunStep
    let theme: HarvisTheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: step.ok ? "checkmark.circle.fill" : step.systemImage)
                .foregroundColor(step.ok ? theme.positive : theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.caption.bold())
                    .foregroundColor(theme.text)
                Text(step.detail)
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(theme.surfaceAlt.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(step.ok ? theme.positive.opacity(0.38) : theme.line.opacity(0.72)))
    }
}
