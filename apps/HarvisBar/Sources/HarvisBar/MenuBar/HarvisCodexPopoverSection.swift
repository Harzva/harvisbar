import AppKit
import Foundation
import SwiftUI

extension HarvisPopoverView {
    var codexChatLauncherSection: some View {
        compactSection {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat 会话")
                        .font(.caption.bold())
                    Text("\(model.runningCodexThreads.count) 运行中 · \(model.recentCodexThreads.count) 最近")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 4)
                Button {
                    model.openCodexChatManager()
                } label: {
                    Label("打开 Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .help("打开 Codex Chat 管理器与 Attach 控制")
            }
        }
    }

    var codexHomesSection: some View {
        compactPanel("CODEX_HOME") {
            HStack(spacing: 6) {
                Text("\(model.visibleCodexHomes.count) 个 Codex 配置")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                Spacer(minLength: 4)
                Button {
                    showCodexAccountAddSheet = true
                } label: {
                    Label("添加新的账户", systemImage: "person.badge.plus")
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("创建独立 CODEX_HOME 与工作区，并开始登录")
                Button {
                    model.refreshCodexHomeList()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Discover local CODEX_HOME directories")
                .disabled(model.isCodexHomeRefreshing)
            }

            if model.visibleCodexHomes.count > 1 {
                HStack(spacing: 5) {
                    ForEach(model.visibleCodexHomes.prefix(3)) { home in
                        let isSelected = home.id == model.selectedCodexHome?.id
                        Button {
                            model.selectCodexHome(home)
                        } label: {
                            Label(
                                quickCodexAccountLabel(home),
                                systemImage: isSelected
                                    ? "checkmark.circle.fill"
                                    : "person.crop.circle"
                            )
                            .font(.caption2.bold())
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(isSelected ? theme.accent : theme.muted)
                        .accessibilityLabel(
                            isSelected
                                ? "当前 Codex 账户，\(home.accountDisplayLabel)"
                                : "切换到 Codex 账户，\(home.accountDisplayLabel)"
                        )
                    }

                    if model.visibleCodexHomes.count > 3 {
                        Menu {
                            ForEach(model.visibleCodexHomes.dropFirst(3)) { home in
                                Button {
                                    model.selectCodexHome(home)
                                } label: {
                                    Label(home.accountDisplayLabel, systemImage: home.authSystemImage)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    .help("更多 Codex 配置")
                    }
                }
            }

            if model.visibleCodexHomes.isEmpty {
                Text(model.isCodexHomeRefreshing ? "Discovering…" : "No CODEX_HOME directories found.")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
            } else if let selected = model.selectedCodexHome {
                Menu {
                    ForEach(model.visibleCodexHomes) { home in
                        Button {
                            model.selectCodexHome(home)
                        } label: {
                            if home.id == selected.id {
                                Label(
                                    "\(home.accountDisplayLabel) · \(home.authStatusLabel)",
                                    systemImage: "checkmark"
                                )
                            } else {
                                Label(
                                    "\(home.accountDisplayLabel) · \(home.authStatusLabel)",
                                    systemImage: home.authSystemImage
                                )
                            }
                        }
                    }
                    Divider()
                    Button {
                        codexHomePendingRename = selected
                    } label: {
                        Label("重命名当前备注…", systemImage: "square.and.pencil")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .foregroundColor(theme.accent)
                        Text(selected.accountDisplayLabel)
                            .font(.caption.bold())
                            .foregroundColor(theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(selected.skillCount) skills")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(theme.muted)
                        Image(systemName: "chevron.down")
                            .font(.caption2.bold())
                            .foregroundColor(theme.muted)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(theme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
                }
                .menuStyle(.borderlessButton)
                .tint(theme.text)

                codexHomeRow(selected)
            }

            if !model.codexHomeWarnings.isEmpty {
                Text("\(model.codexHomeWarnings.count) homes could not be inspected")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }

    var codexChatsSection: some View {
        compactPanel("Chat 会话") {
            HStack(spacing: 6) {
                Text(model.selectedCodexHome?.accountDisplayLabel ?? "未选择账户")
                    .font(.caption2.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(model.runningCodexThreads.count) running · \(model.recentCodexThreads.count) recent")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                Button {
                    model.openCodexChatManager()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("打开 Codex Chat 管理器")
                Button {
                    model.refreshSelectedCodexThreads(userInitiated: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新当前 CODEX_HOME 的会话")
                .disabled(model.selectedCodexHome == nil || model.isCodexThreadRefreshing)
            }

            if model.isCodexThreadRefreshing && model.codexThreads.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading this Home's chats…")
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                }
            } else if let error = model.codexThreadError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(3)
            } else if model.codexThreads.isEmpty {
                Text(model.selectedCodexHome?.isCustomModelHome == true
                    ? "点击刷新以读取此配置的本地会话。"
                    : "No chats recorded in this CODEX_HOME.")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.runningCodexThreads.isEmpty {
                        codexThreadGroupLabel("Running", count: model.runningCodexThreads.count, color: theme.positive, animated: true)
                        ForEach(model.runningCodexThreads) { thread in
                            codexThreadRow(thread)
                        }
                    }
                    if !model.recentCodexThreads.isEmpty {
                        codexThreadGroupLabel("Recent", count: model.recentCodexThreads.count, color: theme.recentStatus, animated: false)
                        ForEach(model.recentCodexThreads) { thread in
                            codexThreadRow(thread)
                        }
                    }
                }
            }
        }
    }

    var codexProcessSection: some View {
        compactPanel("Codex Processes") {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.codexProcesses.total > 0 ? theme.positive : theme.muted)
                    .frame(width: 7, height: 7)
                Text("\(model.codexProcesses.total) running")
                    .font(.caption.bold().monospacedDigit())
                Spacer(minLength: 4)
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
            }

            HStack(spacing: 5) {
                inlineMetric("Worker", model.codexProcesses.workers)
                inlineMetric("Render", model.codexProcesses.renderers)
                inlineMetric("Service", model.codexProcesses.services)
                inlineMetric("Host", model.codexProcesses.hosts)
            }
        }
    }

    @ViewBuilder
    var codexObservabilitySection: some View {
        if let observation = model.barStatus?.codexhomeObservability {
            compactPanel("Run Observability") {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundColor(theme.accent)
                    Text(observation.summary ?? "No run metrics")
                        .font(.caption2)
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                HStack(spacing: 5) {
                    inlineMetric("Runs", observation.runs)
                    inlineMetric("Attempts", observation.attempts)
                    inlineMetric("Tokens", observation.totalTokens)
                }
                HStack(spacing: 8) {
                    Text("Cache \(basisPointLabel(observation.cacheHitRateBasisPoints))")
                    Text("Failure \(basisPointLabel(observation.failureRateBasisPoints))")
                    Text("Retries \(observation.retries ?? 0)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundColor(theme.muted)
            }
        }
    }

    func basisPointLabel(_ value: Int?) -> String {
        String(format: "%.1f%%", Double(value ?? 0) / 100.0)
    }

    var codexSection: some View {
        compactSection {
            Label("定时任务对话", systemImage: "archivebox")
                .font(.caption.bold())
            Spacer(minLength: 4)
            if let result = model.codexArchiveResult {
                Text(result.compactSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(result.failed == 0 ? theme.positive : .orange)
            }
            Button {
                model.archiveScheduledCodexThreads()
            } label: {
                Label("一键归档", systemImage: "archivebox.fill")
            }
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .disabled(model.isBusy)
            .help("只归档与本机定时任务同名或带 AUTO 标记的 Codex 对话；不删除历史。")
        }
    }

    func codexHomeRow(_ home: CodexHome) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: home.isCustomModelHome ? "slider.horizontal.3" : (home.isSubscriptionHome ? "person.crop.circle.badge.checkmark" : "shippingbox"))
                    .foregroundColor(home.isCustomModelHome ? theme.accent : (home.isSubscriptionHome ? theme.positive : .orange))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(home.accountDisplayLabel)
                        .font(.caption2.bold())
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(home.detailSummary.isEmpty ? home.capabilitySummary : home.detailSummary)
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 3)
            }

            codexHomeConnectionSummary(home, details: model.codexAccountDetails(for: home))

            codexHomeQuotaView(home)

            HStack(spacing: 6) {
                Label(home.authStatusLabel, systemImage: home.authSystemImage)
                    .font(.caption2.bold())
                    .foregroundColor(
                        home.isCustomModelHome
                            ? theme.muted
                            : home.isAuthInvalid
                            ? .red
                            : (["valid", "configured"].contains(home.normalizedAuthStatus)
                                ? theme.positive
                                : .orange)
                    )
                if let expiration = home.authExpirationLabel {
                    Text("到期 \(expiration)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 3)
            }

            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundColor(theme.accent)
                Text(model.codexWorkspacePath(for: home))
                    .font(.caption2.monospaced())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 3)
                Button("更改") { model.chooseCodexWorkspace(home) }
                    .font(.caption2)
            }

            if home.isAuthInvalid {
                Text(home.authNote ?? "Auth 已失效；工作区和本地会话仍然保留。")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.codexHomeActionIDs.contains(home.id) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Opening…")
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                    Spacer()
                }
            } else {
                HStack(spacing: 6) {
                    Button {
                        model.launchCodexCLI(home)
                    } label: {
                        Label("Open CLI", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Open Codex CLI with this Home")

                    Button {
                        model.launchCodexDesktop(home)
                    } label: {
                        Label("Desktop", systemImage: "macwindow")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Focus this Home's running Codex Desktop, or open it if needed")

                    if home.isCustomModelHome {
                        Button {
                            model.openCodexConfig(home)
                        } label: {
                            Label("设置", systemImage: "gearshape")
                                .frame(maxWidth: .infinity)
                        }
                        .help("打开此 Codex Home 的 config.toml")
                    } else {
                        Button {
                            model.loginCodexHome(home)
                        } label: {
                            Label("重新登录", systemImage: "person.badge.key")
                                .frame(maxWidth: .infinity)
                        }
                        .help("在 Terminal 中使用这个 CODEX_HOME 运行官方 codex login；登录完成后点击刷新")
                    }

                    Menu {
                        Button("Open config.toml") { model.openCodexConfig(home) }
                        Button("Show in Finder") { model.revealCodexHome(home) }
                        Divider()
                        Button("Skills · coming soon") {}
                            .disabled(true)
                        Button("MCP · coming soon") {}
                            .disabled(true)
                        Button("Hooks · coming soon") {}
                            .disabled(true)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(theme.surfaceAlt.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.opacity(0.55)))
    }

    func codexHomeConnectionSummary(_ home: CodexHome, details: CodexAccountDetails) -> some View {
        Button {
            presentedCodexAccountIdentity = CodexAccountIdentity(home)
            model.prepareCodexAccountDetails(home)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundColor(theme.accent)
                    Text(details.connectionSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: 3)
                    Text("详情")
                        .font(.caption2.bold())
                        .foregroundColor(theme.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.accent)
                }

                if let credits = details.creditsSummary {
                    HStack(spacing: 5) {
                        Image(systemName: "creditcard")
                            .foregroundColor(theme.accent)
                        Text("Credits")
                            .font(.caption2)
                            .foregroundColor(theme.muted)
                        Spacer(minLength: 3)
                        Text(credits)
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundColor(theme.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(theme.surface.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(theme.line.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("codex-home.\(home.id).details")
        .accessibilityLabel("查看 \(home.accountDisplayLabel) 的模型、订阅和 Credits 详情")
        .accessibilityValue("\(details.connectionSummary)\(details.creditsSummary.map { "；Credits \($0)" } ?? "")")
        .help("查看模型、订阅额度和 Credits 详情")
        .popover(
            isPresented: codexDetailsPresentation(for: home),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            CodexAccountDetailsPopover(
                details: model.codexAccountDetails(for: home),
                onAction: { model.performCodexAccountDetailAction($0, home: home) },
                onClose: { dismissCodexDetails(for: home) },
                theme: theme
            )
        }
        .onDisappear {
            dismissCodexDetails(for: home)
        }
        .onChange(of: CodexAccountIdentity(home)) { _ in
            dismissCodexDetails(for: home)
        }
    }

    private func codexDetailsPresentation(for home: CodexHome) -> Binding<Bool> {
        let identity = CodexAccountIdentity(home)
        return Binding(
            get: { presentedCodexAccountIdentity == identity },
            set: { isPresented in
                if isPresented {
                    presentedCodexAccountIdentity = identity
                    model.prepareCodexAccountDetails(home)
                } else if presentedCodexAccountIdentity == identity {
                    presentedCodexAccountIdentity = nil
                }
            }
        )
    }

    private func dismissCodexDetails(for home: CodexHome) {
        let identity = CodexAccountIdentity(home)
        if presentedCodexAccountIdentity == identity {
            presentedCodexAccountIdentity = nil
        }
    }

    @ViewBuilder
    func codexHomeQuotaView(_ home: CodexHome) -> some View {
        if let blockedReason = home.officialQuotaBlockedReason {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: home.isCustomModelHome ? "key.horizontal" : "person.crop.circle.badge.exclamationmark")
                    .foregroundColor(home.isCustomModelHome ? theme.accent : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(home.isCustomModelHome ? (home.quotaMode == "api-key" ? "API Key" : "自定义模型") : "非订阅 Home")
                        .font(.caption2.bold())
                        .foregroundColor(home.isCustomModelHome ? theme.accent : .orange)
                    Text(blockedReason)
                        .font(.caption2)
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 3)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background((home.isCustomModelHome ? theme.accent : Color.orange).opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke((home.isCustomModelHome ? theme.accent : Color.orange).opacity(0.28)))
        } else if model.codexHomeQuotaLoadingIDs.contains(home.id),
           model.codexHomeQuotas[home.id] == nil {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取此账号额度…")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                Spacer(minLength: 3)
            }
        } else if let quota = model.codexHomeQuotas[home.id], quota.available {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Label("账号额度", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.caption2.bold())
                        .foregroundColor(theme.text)
                    Spacer(minLength: 3)
                    if let plan = quota.planLabel {
                        Text(plan)
                            .font(.caption2.bold().monospaced())
                            .foregroundColor(theme.accent)
                    }
                    if model.codexHomeQuotaLoadingIDs.contains(home.id) {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                ForEach(quota.buckets) { bucket in
                    if let primary = bucket.primary {
                        codexQuotaWindowRow(bucket.displayName, window: primary, suffix: nil)
                    }
                    if let secondary = bucket.secondary {
                        codexQuotaWindowRow(bucket.displayName, window: secondary, suffix: "次级")
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(theme.surface.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line.opacity(0.45)))
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .foregroundColor(theme.muted)
                Text(model.codexHomeQuotaErrors[home.id] ?? "此账号暂未返回额度数据")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                    .lineLimit(2)
                Spacer(minLength: 3)
            }
        }
    }

    func codexQuotaWindowRow(
        _ name: String,
        window: CodexQuotaWindow,
        suffix: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text([name, suffix, window.durationLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 3)
                Text("剩余 \(window.remainingPercent)%")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundColor(codexQuotaColor(window.remainingPercent))
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .progressViewStyle(.linear)
                .tint(codexQuotaColor(window.remainingPercent))
            if let resetLabel = window.resetLabel {
                Text(resetLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
            }
        }
    }

    func codexQuotaColor(_ remainingPercent: Int) -> Color {
        if remainingPercent <= 10 { return .red }
        if remainingPercent <= 30 { return .orange }
        return theme.positive
    }

    func quickCodexAccountLabel(_ home: CodexHome) -> String {
        if let note = home.accountDisplayNote, !note.isEmpty {
            return note
        }
        if let email = home.accountEmail,
           let localPart = email.split(separator: "@", maxSplits: 1).first,
           !localPart.isEmpty {
            return String(localPart)
        }
        return home.label
    }

    func codexThreadGroupLabel(_ title: String, count: Int, color: Color, animated: Bool) -> some View {
        HStack(spacing: 5) {
            if animated {
                PulsingStatusDot(color: color)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .frame(width: 10, height: 10)
            }
            Text(title)
                .font(.caption2.bold())
                .foregroundColor(theme.text)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(theme.muted)
        }
        .padding(.top, 2)
    }

    func codexThreadRow(_ thread: CodexThreadSummary) -> some View {
        Button {
            model.openCodexThread(thread)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                if thread.running {
                    PulsingStatusDot(color: theme.positive)
                } else {
                    Circle()
                        .fill(thread.archived ? theme.muted : theme.recentStatus)
                        .frame(width: 7, height: 7)
                        .frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(thread.title)
                            .font(.caption2.bold())
                            .foregroundColor(theme.text)
                            .lineLimit(2)
                        if thread.running {
                            Text("LIVE")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(theme.positiveText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(theme.positive)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 5) {
                        Text(thread.updatedLabel)
                        if let model = thread.model, !model.isEmpty {
                            Text(model)
                        }
                        Text(thread.tokenLabel)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(thread.running ? theme.positive.opacity(0.09) : theme.surfaceAlt.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(thread.running ? theme.positive.opacity(0.42) : theme.line.opacity(0.28))
            )
        }
        .buttonStyle(.plain)
        .help("Open in Codex Desktop · \(thread.cwd)")
        .contextMenu {
            Button {
                model.openCodexThread(thread)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            Button {
                model.openCodexThreadInNewWindow(thread)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
    }

}
