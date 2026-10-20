import Foundation
import SwiftUI

struct DigitalMeNavigationRefreshContext: Equatable {
    let port: Int
    let workspaceRoot: String
}

extension HarvisPopoverView {
    var digitalMeNavigationContext: DigitalMeNavigationRefreshContext {
        DigitalMeNavigationRefreshContext(
            port: model.port,
            workspaceRoot: model.expanded(model.workspaceRoot)
        )
    }

    var digitalMeSnapshot: DigitalMeNavigationSnapshot {
        let workspaceRoot = model.expanded(model.workspaceRoot)
        return DigitalMeNavigationProjection.makeSnapshot(
            from: DigitalMeNavigationProjection.makeInput(
                runtimeWork: model.barStatus?.work,
                durableQueueItems: model.codexTaskDelivery.isReady
                    ? model.codexTaskDelivery.durableQueueItems
                    : nil,
                managedChatThreads: digitalMeManagedChatThreads,
                remote: digitalMeNavigation.sources(
                    matchingPort: model.port,
                    workspaceRoot: workspaceRoot,
                    now: digitalMeNavigationNow
                )
            )
        )
    }

    func monitorDigitalMeNavigationContext() async {
        while !Task.isCancelled {
            digitalMeNavigationNow = Date()
            await refreshDigitalMeNavigation(
                sources: Set(DigitalMeNavigationSource.allCases)
            )
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        DigitalMeNavigationStore.defaultTTL * 1_000_000_000
                    )
                )
            } catch {
                return
            }
        }
    }

    func refreshDigitalMeNavigationForSelectedSection() async {
        let sources: Set<DigitalMeNavigationSource>
        switch selectedSection {
        case .review:
            sources = Set(DigitalMeNavigationSource.allCases)
        case .memory:
            sources = [.memoryCandidates, .persona]
        case .persona:
            sources = [.persona]
        case .overview, .codex, .agents, .system, .network, .dsh, .ports, .tools, .work:
            sources = []
        }
        guard !sources.isEmpty else { return }
        await refreshDigitalMeNavigation(sources: sources)
    }

    func sectionPickerHelp(_ section: HarvisBarSection) -> String {
        guard section == .review else { return section.title }
        return "Review · \(digitalMeReviewAccessibilityValue)"
    }

    func sectionPickerAccessibilityLabel(_ section: HarvisBarSection) -> String {
        switch section {
        case .work:
            return "Work, Digital-Me work queue"
        case .review:
            return "Review, Digital-Me review center"
        case .memory:
            return "Memory, Digital-Me memory"
        case .persona:
            return "Persona, Digital-Me identity"
        case .overview, .codex, .agents, .system, .network, .dsh, .ports, .tools:
            return section.title
        }
    }

    func sectionPickerAccessibilityValue(_ section: HarvisBarSection) -> String {
        if section == .review {
            return digitalMeReviewAccessibilityValue
        }
        return ""
    }

    var digitalMeWorkSection: some View {
        let snapshot = digitalMeSnapshot.work
        let activeCount = snapshot.activeCount.flatMap { $0 > 0 ? $0 : nil }
        let activeCompleteness: DigitalMeCountCompleteness? = activeCount == nil
            ? nil
            : .atLeast
        let queuedCount = model.codexTaskDelivery.isReady
            ? snapshot.queuedCount
            : nil
        let queuedCompleteness: DigitalMeCountCompleteness? = queuedCount == nil
            ? nil
            : .exact
        let blockedPresentation = digitalMeBlockedPresentation(snapshot)
        let hasWorkLowerBound = activeCompleteness == .atLeast
            || blockedPresentation.completeness == .atLeast

        return compactPanel("1 · Work") {
            HStack(spacing: 5) {
                digitalMeMetric(
                    "Active",
                    activeCount,
                    completeness: activeCompleteness
                )
                digitalMeMetric(
                    "Queued",
                    queuedCount,
                    completeness: queuedCompleteness
                )
                digitalMeMetric(
                    "Blocked",
                    blockedPresentation.value,
                    completeness: blockedPresentation.completeness
                )
            }

            HStack(spacing: 5) {
                digitalMeMetric("Packets", snapshot.packetCount)
                digitalMeMetric("Runs history", snapshot.runCount)
            }

            if let primary = snapshot.primaryItem {
                digitalMeStatusRow(
                    digitalMeWorkStatus(primary.kind),
                    systemImage: digitalMeWorkStatusImage(primary.kind)
                )
            } else if snapshot.availability == .available,
                      activeCount == nil,
                      queuedCount == nil,
                      blockedPresentation.value == nil {
                digitalMeStatusRow(
                    "Work counts are not reported yet.",
                    systemImage: "questionmark.circle"
                )
            }

            if hasWorkLowerBound {
                digitalMeStatusRow(
                    "≥ marks confirmed work; other providers may add more.",
                    systemImage: "info.circle"
                )
            }

            digitalMeAvailabilityNotice(
                snapshot.availability,
                issues: [],
                hasLowerBound: false
            )

            Button {
                model.openDigitalMeStudio(.work)
            } label: {
                Label("Open Work in Studio", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .accessibilityHint("Opens the read-only Work view in Studio")
        }
    }

    var digitalMeReviewSection: some View {
        let snapshot = digitalMeSnapshot.review
        let hasLowerBound = [
            snapshot.approvalCountCompleteness,
            snapshot.memoryCandidateCountCompleteness,
            snapshot.personalityCandidateCountCompleteness,
        ].contains(.atLeast)

        return compactPanel("2 · Review") {
            HStack(spacing: 5) {
                digitalMeMetric(
                    "Approvals",
                    snapshot.approvalCount,
                    completeness: snapshot.approvalCountCompleteness
                )
                digitalMeMetric(
                    "Memory",
                    snapshot.memoryCandidateCount,
                    completeness: snapshot.memoryCandidateCountCompleteness
                )
                digitalMeMetric(
                    "Persona",
                    snapshot.personalityCandidateCount,
                    completeness: snapshot.personalityCandidateCountCompleteness
                )
            }

            digitalMeReviewSummaryRow(snapshot)

            digitalMeAvailabilityNotice(
                snapshot.availability,
                issues: snapshot.issues,
                hasLowerBound: hasLowerBound
            )

            Button {
                model.openDigitalMeStudio(.review)
            } label: {
                Label("Open Review Center", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .accessibilityHint("Opens Review Center without making a decision")
        }
    }

    var digitalMeMemorySection: some View {
        let snapshot = digitalMeSnapshot.memory
        let hasLowerBound = snapshot.vaultCountCompleteness == .atLeast
            || snapshot.pendingCandidateCountCompleteness == .atLeast

        return compactPanel("3 · Memory") {
            HStack(spacing: 5) {
                digitalMeMetric(
                    "Vaults",
                    snapshot.vaultCount,
                    completeness: snapshot.vaultCountCompleteness
                )
                digitalMeMetric(
                    "Pending",
                    snapshot.pendingCandidateCount,
                    completeness: snapshot.pendingCandidateCountCompleteness
                )
            }

            HStack(spacing: 5) {
                digitalMeMetric("Signals", snapshot.candidateSignalCount)
                digitalMeMetric("Sources", snapshot.knowledgeSourceCount)
            }

            digitalMeMemorySnapshotRow(snapshot)

            if let pending = snapshot.pendingCandidateCount, pending > 0 {
                digitalMeStatusRow(
                    "Memory candidates are handled in Review Center.",
                    systemImage: "checklist"
                )
            }

            digitalMeAvailabilityNotice(
                snapshot.availability,
                issues: snapshot.issues,
                hasLowerBound: hasLowerBound
            )

            if snapshot.availability == .available,
               snapshot.pendingCandidateCount == 0 {
                digitalMeStatusRow(
                    "No pending memory candidates are reported.",
                    systemImage: "checkmark.circle"
                )
            }

            Button {
                model.openDigitalMeStudio(.memory)
            } label: {
                Label("Open Memory", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
            .accessibilityHint("Opens the Memory view in Studio")
        }
    }

    var digitalMePersonaSection: some View {
        let snapshot = digitalMeSnapshot.persona
        let hasLowerBound = snapshot.activePersonaCountCompleteness == .atLeast
            || snapshot.runningTwinCountCompleteness == .atLeast
        let activeNames = snapshot.activePersonaNames.compactMap {
            digitalMeConservativeDisplayText($0)
        }
        let runningNames = snapshot.runningTwinNames.compactMap {
            digitalMeConservativeDisplayText($0)
        }

        return compactPanel("4 · Persona") {
            HStack(spacing: 5) {
                digitalMeMetric(
                    "Active personas",
                    snapshot.activePersonaCount,
                    completeness: snapshot.activePersonaCountCompleteness
                )
                digitalMeMetric(
                    "Running twins",
                    snapshot.runningTwinCount,
                    completeness: snapshot.runningTwinCountCompleteness
                )
            }

            if !activeNames.isEmpty {
                digitalMeLabelValueRow("Active", activeNames.joined(separator: " · "))
            }
            if !runningNames.isEmpty {
                digitalMeLabelValueRow("Running", runningNames.joined(separator: " · "))
            }
            if let version = digitalMeConservativeDisplayText(snapshot.registryVersion) {
                digitalMeLabelValueRow("Registry", version)
            }
            if let version = digitalMeConservativeDisplayText(snapshot.reviewQueueVersion) {
                digitalMeLabelValueRow("Review queue", version)
            }

            digitalMeAvailabilityNotice(
                snapshot.availability,
                issues: snapshot.issues,
                hasLowerBound: hasLowerBound
            )

            if snapshot.availability == .available,
               snapshot.activePersonaCount == 0,
               snapshot.runningTwinCount == 0 {
                digitalMeStatusRow(
                    "No active personas or running twins are reported.",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            }

            VStack(spacing: 4) {
                Button {
                    model.openDigitalMeStudio(.personaEditor)
                } label: {
                    Label("Persona Editor", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    model.openDigitalMeStudio(.copyMeBuilder)
                } label: {
                    Label("Copy-Me Builder", systemImage: "person.2")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(HarvisControlButtonStyle(theme: theme))
        }
    }

    private var digitalMeManagedChatThreads: [ManagedChatThread]? {
        let runningThreads = model.managedChatThreads.filter(\.running)
        return runningThreads.isEmpty ? nil : runningThreads
    }

    private var digitalMeReviewAccessibilityValue: String {
        let review = digitalMeSnapshot.review
        if let total = review.totalAttentionCount {
            return total == 0
                ? "No items need review"
                : "\(total) items need review"
        }
        if review.knownAttentionCount > 0 {
            return "At least \(review.knownAttentionCount) items need review"
        }
        return "Review count unavailable"
    }

    private func refreshDigitalMeNavigation(
        sources: Set<DigitalMeNavigationSource>
    ) async {
        await digitalMeNavigation.refreshIfNeeded(
            sources: sources,
            port: model.port,
            workspaceRoot: model.expanded(model.workspaceRoot),
            authToken: model.readAuthToken()
        )
    }

    private func digitalMeBlockedPresentation(
        _ summary: DigitalMeWorkSummary
    ) -> (value: Int?, completeness: DigitalMeCountCompleteness?) {
        let hasRuntimeWork = model.barStatus?.work != nil
        let hasDurableDelivery = model.codexTaskDelivery.isReady
        if hasRuntimeWork, hasDurableDelivery {
            return (
                summary.blockedCount,
                summary.blockedCount == nil ? nil : .exact
            )
        }
        guard let value = summary.blockedCount, value > 0 else {
            return (nil, nil)
        }
        return (value, .atLeast)
    }

    private func digitalMeMetric(
        _ title: String,
        _ value: Int?,
        completeness: DigitalMeCountCompleteness? = nil
    ) -> some View {
        let displayValue: String
        let accessibilityValue: String
        if let value {
            if completeness == .atLeast {
                displayValue = "≥\(value)"
                accessibilityValue = "At least \(value)"
            } else {
                displayValue = "\(value)"
                accessibilityValue = "\(value)"
            }
        } else {
            displayValue = "—"
            accessibilityValue = "Unavailable"
        }

        return HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 2)
            Text(displayValue)
                .font(.caption.bold())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(theme.surfaceAlt.opacity(0.80))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.opacity(0.65)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private func digitalMeReviewSummaryRow(
        _ summary: DigitalMeReviewSummary
    ) -> some View {
        let text: String
        let color: Color
        if let total = summary.totalAttentionCount {
            text = total == 0
                ? "Nothing currently needs review."
                : "\(total) items need review."
            color = total == 0 ? theme.positive : .red
        } else if summary.knownAttentionCount > 0 {
            text = "At least \(summary.knownAttentionCount) items need review."
            color = .red
        } else {
            text = "The complete review total is unavailable."
            color = theme.muted
        }
        return digitalMeStatusRow(text, systemImage: "checklist", color: color)
    }

    private func digitalMeMemorySnapshotRow(
        _ summary: DigitalMeMemorySummary
    ) -> some View {
        let status: String
        switch summary.snapshotExists {
        case true?: status = "Available"
        case false?: status = "Not available"
        case nil: status = "Unknown"
        }
        let formattedDate = digitalMeFormattedTimestamp(summary.lastSnapshotAt)

        return HStack(spacing: 5) {
            Text("Snapshot")
                .font(.caption2)
                .foregroundColor(theme.muted)
            Spacer(minLength: 4)
            if let formattedDate, summary.snapshotExists == true {
                Text("\(status) · \(formattedDate)")
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            } else {
                Text(status)
                    .font(.caption2.bold())
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(theme.surfaceAlt.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
    }

    private func digitalMeStatusRow(
        _ text: String,
        systemImage: String,
        color: Color? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundColor(color ?? theme.accent)
            Text(text)
                .font(.caption2)
                .foregroundColor(color ?? theme.text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceAlt.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func digitalMeLabelValueRow(
        _ label: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundColor(theme.muted)
            Spacer(minLength: 5)
            Text(value)
                .font(.caption2.bold())
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(theme.surfaceAlt.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func digitalMeAvailabilityNotice(
        _ availability: DigitalMeNavigationAvailability,
        issues: [DigitalMeNavigationSourceIssue],
        hasLowerBound: Bool
    ) -> some View {
        let sourceNames = digitalMeIssueSourceNames(issues)
        switch availability {
        case .available:
            EmptyView()
        case .notLoaded:
            messageBox(
                title: "Not loaded",
                message: "The read-only Digital-Me summary has not loaded yet.",
                color: .gray
            )
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading read-only Digital-Me summary…")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
        case .partial:
            messageBox(
                title: "Partial data",
                message: digitalMePartialMessage(
                    sourceNames: sourceNames,
                    hasLowerBound: hasLowerBound
                ),
                color: .orange
            )
        case .unavailable:
            messageBox(
                title: "Unavailable",
                message: sourceNames.isEmpty
                    ? "The local read-only Digital-Me source is unavailable."
                    : "Unavailable sources: \(sourceNames).",
                color: .red
            )
        }
    }

    private func digitalMePartialMessage(
        sourceNames: String,
        hasLowerBound: Bool
    ) -> String {
        switch (hasLowerBound, sourceNames.isEmpty) {
        case (true, true):
            return "Values marked ≥ are lower bounds because a local result page is full."
        case (true, false):
            return "Values marked ≥ are lower bounds. Unavailable sources: \(sourceNames)."
        case (false, false):
            return "Some read-only sources are loading or unavailable: \(sourceNames)."
        case (false, true):
            return "Some read-only sources are still loading or unavailable."
        }
    }

    private func digitalMeIssueSourceNames(
        _ issues: [DigitalMeNavigationSourceIssue]
    ) -> String {
        let sources = Set(issues.map(\.source))
        return DigitalMeNavigationSource.allCases
            .filter(sources.contains)
            .map(digitalMeSourceTitle)
            .joined(separator: ", ")
    }

    private func digitalMeSourceTitle(_ source: DigitalMeNavigationSource) -> String {
        switch source {
        case .approvals: return "Approvals"
        case .memoryCandidates: return "Memory candidates"
        case .persona: return "Persona"
        }
    }

    private func digitalMeWorkStatus(
        _ kind: DigitalMeWorkPrimaryKind
    ) -> String {
        switch kind {
        case .blockedDelivery: return "Work needs attention."
        case .activeConversation: return "A managed conversation is running."
        case .activeDelivery: return "A Codex delivery is running."
        case .queuedDelivery: return "A Codex delivery is queued."
        case .runtimeHistory: return "Harvis work history is available."
        }
    }

    private func digitalMeWorkStatusImage(
        _ kind: DigitalMeWorkPrimaryKind
    ) -> String {
        switch kind {
        case .blockedDelivery: return "exclamationmark.triangle"
        case .activeConversation, .activeDelivery: return "play.circle"
        case .queuedDelivery: return "clock"
        case .runtimeHistory: return "clock.arrow.circlepath"
        }
    }

    private func digitalMeFormattedTimestamp(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue.count <= 64,
              !rawValue.contains("\n"),
              !rawValue.contains("\r") else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: rawValue)
            ?? standard.date(from: rawValue) else {
            return nil
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func digitalMeConservativeDisplayText(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 48,
              !value.contains("\n"),
              !value.contains("\r"),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("://"),
              !value.contains("=") else {
            return nil
        }
        let lowered = value.lowercased()
        let sensitiveFragments = [
            "token", "secret", "password", "passwd", "bearer",
            "api_key", "apikey", "credential",
        ]
        guard !sensitiveFragments.contains(where: lowered.contains) else {
            return nil
        }
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_.·'()"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return value
    }
}
