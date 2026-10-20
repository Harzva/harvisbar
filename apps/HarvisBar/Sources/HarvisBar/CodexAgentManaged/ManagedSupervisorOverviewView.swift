import SwiftUI

/// Native, read-first overview for the currently selected managed-chat scope.
/// The overview never starts a read on appearance; refresh is an explicit
/// user action so cached supervisor state remains visible and trustworthy.
struct ManagedSupervisorOverviewView: View {
    @EnvironmentObject private var model: HarvisRuntimeModel

    let threads: [ManagedChatThread]
    let theme: HarvisTheme
    let onOpenCard: (ManagedChatThread) -> Void
    let onBack: () -> Void

    @State private var query = ""
    @State private var statusFilter: ManagedSupervisorOverviewStatus?
    @State private var now = Date()
    @State private var refreshProgress: ManagedSupervisorRefreshProgress?
    @State private var refreshTask: Task<Void, Never>?
    @State private var isRefreshing = false

    private struct SourceGroup: Identifiable {
        let id: String
        let label: String
        let detail: String
        let threads: [ManagedChatThread]
    }

    private var filteredThreads: [ManagedChatThread] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return threads.filter { thread in
            let status = model.supervisorOverviewStatus(for: thread, now: now)
            guard statusFilter.map({ $0.rawValue == status.rawValue }) ?? true else { return false }
            guard !needle.isEmpty else { return true }
            return [thread.title, thread.sourceID, thread.sourceScope, thread.cwd]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(needle)
        }
    }

    private var sourceGroups: [SourceGroup] {
        Dictionary(grouping: filteredThreads, by: sourceKey(for:))
            .map { key, cards in
                let account = model.managedChatDisplayAccounts.first { $0.id == key }
                return SourceGroup(
                    id: key,
                    label: account?.label ?? cards.first.map { "\($0.provider.label) · \($0.sourceScope)" } ?? key,
                    detail: account?.detail ?? cards.first?.provider.label ?? "",
                    threads: cards.sorted {
                        let left = model.supervisorOverviewStatus(for: $0, now: now).rawValue
                        let right = model.supervisorOverviewStatus(for: $1, now: now).rawValue
                        if left != right { return left < right }
                        return $0.updatedAt > $1.updatedAt
                    }
                )
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private var dshCount: Int {
        threads.filter { ManagedSupervisorCompatibility.resolve($0) == .dsh }.count
    }

    private var freshCount: Int {
        threads.filter { thread in
            guard ManagedSupervisorCompatibility.resolve(thread) == .dsh,
                  model.supervisorErrors[thread.id] == nil,
                  let snapshot = model.supervisorSnapshot(for: thread) else { return false }
            return now.timeIntervalSince(snapshot.readAt) < 30
        }.count
    }

    private var unverifiedCount: Int { max(0, dshCount - freshCount) }

    private var eligibleRefreshCount: Int {
        var ids = Set<String>()
        return threads.filter {
            ManagedSupervisorCompatibility.resolve($0) == .dsh
                && !$0.sourceID.isEmpty
                && ids.insert($0.id).inserted
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.line)
            if threads.isEmpty {
                emptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "当前范围没有会话",
                    detail: "请调整管理模块的智能体、账号或搜索条件。"
                )
            } else if filteredThreads.isEmpty {
                emptyState(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "没有匹配的监督卡片",
                    detail: "请调整搜索词或状态筛选。"
                )
            } else {
                List {
                    ForEach(sourceGroups) { group in
                        Section {
                            ForEach(group.threads) { thread in
                                overviewRow(thread)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                                    .listRowBackground(theme.surface)
                            }
                        } header: {
                            HStack(spacing: 7) {
                                Image(systemName: group.threads.first?.provider.systemImage ?? "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.label).harvisFont(.subheadline.weight(.semibold))
                                    if !group.detail.isEmpty {
                                        Text(group.detail).harvisFont(.caption2).foregroundColor(theme.muted).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text("\(group.threads.count)").harvisFont(.caption.monospacedDigit()).foregroundColor(theme.muted)
                            }
                            .foregroundColor(theme.text)
                            .textCase(nil)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("supervisor-overview.source.\(group.id)")
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.background)
        .foregroundColor(theme.text)
        .accessibilityIdentifier("supervisor-overview")
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    now = Date()
                } catch {
                    return
                }
            }
        }
        .onChange(of: threads.map(\.id).sorted()) { _ in
            // The refresh progress belongs to the exact range visible when
            // the user started it. A changed ID set invalidates that batch.
            if isRefreshing { cancelRefresh() }
            now = Date()
        }
        .onDisappear {
            cancelRefresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("监督总览", systemImage: "eye.circle")
                    .harvisFont(.title3.weight(.semibold))
                Text("\(threads.count) 个会话 · \(dshCount) 个 DSH")
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                Spacer()
                Button("返回卡片", action: onBack)
                    .buttonStyle(HarvisControlButtonStyle(theme: theme))
                    .accessibilityIdentifier("supervisor-overview.back")
            }

            HStack(spacing: 8) {
                Text("已核对 \(freshCount) · 待核对 \(unverifiedCount)")
                    .harvisFont(.caption2.monospacedDigit())
                    .foregroundColor(theme.muted)
                Spacer()
                if isRefreshing, let refreshProgress {
                    ProgressView(value: Double(refreshProgress.completed), total: Double(max(refreshProgress.total, 1)))
                        .frame(width: 86)
                        .accessibilityLabel("监督刷新进度")
                    Text("\(refreshProgress.completed)/\(refreshProgress.total)")
                        .harvisFont(.caption2.monospacedDigit())
                        .foregroundColor(theme.muted)
                    Button("取消", action: cancelRefresh)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("supervisor-overview.cancel-refresh")
                } else {
                    Button("刷新", action: startRefresh)
                        .disabled(eligibleRefreshCount == 0)
                        .accessibilityIdentifier("supervisor-overview.refresh")
                }
            }

            if dshCount == 0 && !threads.isEmpty {
                Text("当前范围没有 DSH；Codex 可进入项目管理，其他来源显示观察状态。")
                    .harvisFont(.caption2)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("此页汇总当前筛选的状态，不会批量开启监督。DSH 逐会话设置；项目大脑的完整范围请进入项目管理查看。")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("supervisor-overview.scope-explanation")

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(theme.muted)
                    TextField("搜索会话、来源或路径", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("supervisor-overview.search")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(theme.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除监督总览搜索")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))

                Menu {
                    Button { statusFilter = nil } label: {
                        Label("全部状态", systemImage: statusFilter == nil ? "checkmark" : "circle")
                    }
                    Divider()
                    ForEach(ManagedSupervisorOverviewStatus.allCases) { status in
                        Button { statusFilter = status } label: {
                            Label(status.title, systemImage: statusFilter?.rawValue == status.rawValue ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    Label(statusFilter?.title ?? "全部状态", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(HarvisControlButtonStyle(theme: theme))
                .accessibilityIdentifier("supervisor-overview.status-filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(theme.surfaceAlt.opacity(0.45))
    }

    private func overviewRow(_ thread: ManagedChatThread) -> some View {
        let status = model.supervisorOverviewStatus(for: thread, now: now)
        let snapshot = model.supervisorSnapshot(for: thread)
        let compatibility = ManagedSupervisorCompatibility.resolve(thread)
        let snapshotIsFresh = snapshot.map { now.timeIntervalSince($0.readAt) < 30 } ?? false
        let project = ManagedChatProjectResolver.resolve(thread: thread)
        let projectLabel = project.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationLabel: String
        if !projectLabel.isEmpty {
            locationLabel = projectLabel
        } else if !thread.cwd.isEmpty {
            locationLabel = URL(fileURLWithPath: thread.cwd).lastPathComponent
        } else {
            locationLabel = "未指定路径"
        }
        return Button { onOpenCard(thread) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon(status))
                    .harvisFont(.system(size: 17, weight: .semibold))
                    .foregroundColor(statusColor(status))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(thread.title.isEmpty ? "未命名会话" : thread.title)
                            .harvisFont(.body.weight(.medium))
                            .foregroundColor(theme.text)
                            .lineLimit(1)
                        Text(status.title)
                            .harvisFont(.caption2.weight(.semibold))
                            .foregroundColor(statusColor(status))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(statusColor(status).opacity(0.12))
                            .clipShape(Capsule())
                    }
                    HStack(spacing: 7) {
                        Text(compatibilityLabel(compatibility))
                        if let state = snapshot?.state {
                            Text(snapshotIsFresh
                                ? "· \(state.modeLabel) · \(state.statusLabel)"
                                : "· 上次\(state.modeLabel) · \(state.statusLabel)")
                        }
                        if let error = model.supervisorErrors[thread.id], !error.isEmpty {
                            Text("· \(error)").lineLimit(1)
                        }
                    }
                    .harvisFont(.caption)
                    .foregroundColor(theme.muted)
                    HStack(spacing: 8) {
                        Text(locationLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let readAt = snapshot?.readAt {
                            Text("· 核对 \(ageLabel(readAt))")
                                .foregroundColor(snapshotIsFresh ? theme.positive : .orange)
                        } else {
                            Text("· 尚未核对")
                        }
                        if model.supervisorBusyThreadIDs.contains(thread.id) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .harvisFont(.caption2.monospaced())
                    .foregroundColor(theme.muted)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .harvisFont(.caption.weight(.semibold))
                    .foregroundColor(theme.muted)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("supervisor-overview.row.\(thread.id)")
        .accessibilityLabel("\(thread.title)，\(status.title)")
        .accessibilityValue("项目 \(locationLabel)，会话 ID \(thread.sourceID)")
        .accessibilityHint("打开监督卡片")
        .help("会话 ID：\(thread.sourceID)")
    }

    private func emptyState(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: systemImage).harvisFont(.system(size: 28)).foregroundColor(theme.muted)
            Text(title).harvisFont(.headline)
            Text(detail).harvisFont(.caption).foregroundColor(theme.muted).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func sourceKey(for thread: ManagedChatThread) -> String {
        "\(thread.provider.rawValue)::\(thread.sourceScope)"
    }

    private func compatibilityLabel(_ compatibility: ManagedSupervisorCompatibility) -> String {
        switch compatibility {
        case .dsh: return "DSH Supervisor"
        case .codexProject: return "Codex 项目管理"
        case .observation: return "只读观察"
        }
    }

    private func statusIcon(_ status: ManagedSupervisorOverviewStatus) -> String {
        switch status {
        case .active: return "eye.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .off: return "pause.circle"
        case .unread: return "arrow.clockwise.circle"
        case .unavailable: return "questionmark.circle"
        case .observation: return "eye.slash"
        }
    }

    private func statusColor(_ status: ManagedSupervisorOverviewStatus) -> Color {
        switch status {
        case .active: return theme.positive
        case .attention, .unavailable: return .orange
        case .off, .observation: return theme.muted
        case .unread: return theme.accent
        }
    }

    private func ageLabel(_ date: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) 秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return "\(hours / 24) 天前"
    }

    private func startRefresh() {
        guard !isRefreshing, eligibleRefreshCount > 0 else { return }
        refreshTask?.cancel()
        isRefreshing = true
        refreshProgress = .init(completed: 0, total: eligibleRefreshCount)
        let request = threads
        refreshTask = Task { @MainActor in
            await model.refreshSupervisorOverview(for: request) { progress in
                guard !Task.isCancelled else { return }
                refreshProgress = progress
                now = Date()
            }
            if !Task.isCancelled {
                isRefreshing = false
                refreshProgress = nil
                now = Date()
            }
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        refreshProgress = nil
        now = Date()
    }
}
