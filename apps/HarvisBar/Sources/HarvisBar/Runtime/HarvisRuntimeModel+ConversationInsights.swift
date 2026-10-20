import CryptoKit
import Foundation

struct ManagedConversationInsightRuntimeContext: Equatable, Sendable {
    let inputState: ManagedConversationUserInputState
    let sourceProject: ManagedChatProjectIdentity
    let managedProject: ManagedChatProjectIdentity
    let status: ManagedConversationInsightStatus?
    let projectCatalog: [ManagedChatProjectIdentity]
    let recommendedProject: ManagedChatProjectIdentity?
    let brainEnabled: Bool
    let availabilityMessage: String?

    var canAnalyze: Bool {
        availabilityMessage == nil
    }
}

enum ManagedConversationInsightRuntimeError: LocalizedError, Equatable {
    case staleTarget
    case sourceUnavailable(String)
    case staleInputEvidence
    case noUserInputs
    case projectUnavailable
    case projectBrainDisabled(String)
    case brainHomeUnavailable
    case recommendationUnavailable
    case staleRecommendation

    var errorDescription: String? {
        switch self {
        case .staleTarget:
            return "对话来源已经变化，请重新选择后再分析。"
        case let .sourceUnavailable(reason):
            return reason
        case .staleInputEvidence:
            return "用户输入证据不是当前对话的最新成功快照，请重新读取后再分析。"
        case .noUserInputs:
            return "当前对话没有可供分析的用户输入。"
        case .projectUnavailable:
            return "当前对话尚未归入可管理的项目。"
        case let .projectBrainDisabled(label):
            return "请先在“\(label)”项目管理页开启 DSH 管理大脑。"
        case .brainHomeUnavailable:
            return "专用 DSH 大脑 Home 不可访问；Harvis 没有创建或迁移任何凭据。"
        case .recommendationUnavailable:
            return "AI 没有提供仍然有效的项目建议。"
        case .staleRecommendation:
            return "用户输入或当前项目已经变化，请重新分析后再调整归属。"
        }
    }
}

enum ManagedConversationInsightProjectCatalog {
    private static let openTaskStatuses: Set<String> = [
        "pending", "in_progress", "waiting_approval", "blocked", "reviewing",
    ]

    static func candidateID(for project: ManagedChatProjectIdentity) -> String {
        let material = "harvis-project-candidate-v1:\(project.id)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "project-\(digest)"
    }

    static func candidateMap(
        projects: [ManagedChatProjectIdentity]
    ) -> [String: ManagedChatProjectIdentity] {
        Dictionary(uniqueKeysWithValues: projects.compactMap { project in
            guard project.canonicalPath != nil else { return nil }
            return (candidateID(for: project), project)
        })
    }

    static func candidates(
        projects: [ManagedChatProjectIdentity],
        threads: [ManagedChatThread],
        taskPlans: [String: ManagedProjectTaskPlan],
        taskFreshness: [String: ManagedGovernanceFreshness]
    ) -> [ManagedConversationProjectCandidate] {
        let threadsByProject = Dictionary(grouping: threads) {
            ManagedChatProjectResolver.resolve(thread: $0).id
        }
        return projects.compactMap { project in
            guard project.canonicalPath != nil else { return nil }
            let taskTitles: [String]
            if taskFreshness[project.id]?.isFresh == true,
               let plan = taskPlans[project.id],
               plan.sourceAvailable,
               plan.isValid,
               plan.invalidRecordCount == 0 {
                let titles = plan.tasks
                    .filter { openTaskStatuses.contains($0.status) }
                    .map(\.title)
                taskTitles = Array(titles.prefix(4))
            } else {
                taskTitles = []
            }
            let sortedConversationTitles = (threadsByProject[project.id] ?? [])
                .sorted {
                    if $0.updatedAt != $1.updatedAt {
                        return $0.updatedAt > $1.updatedAt
                    }
                    return $0.id < $1.id
                }
                .map(\.title)
            let conversationTitles = Array(sortedConversationTitles.prefix(4))
            return ManagedConversationProjectCandidate(
                candidateID: candidateID(for: project),
                label: project.label,
                taskTitles: taskTitles,
                conversationTitles: conversationTitles
            )
        }
        .sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedAscending
                || (order == .orderedSame && $0.candidateID < $1.candidateID)
        }
    }

    /// Binds an insight result to both the exact conversation projection and
    /// the project facts used for relevance scoring. A task-plan, project
    /// title, or candidate-conversation change therefore makes an old
    /// recommendation stale before it can be applied.
    static func analysisFingerprint(
        sourceRevision: String,
        candidates: [ManagedConversationProjectCandidate]
    ) -> String {
        var data = Data()
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        append("harvis-conversation-insight-fingerprint-v1")
        append(sourceRevision)
        for candidate in candidates.sorted(by: {
            $0.candidateID < $1.candidateID
        }) {
            append(candidate.candidateID)
            append(candidate.label)
            for title in candidate.taskTitles {
                append("task")
                append(title)
            }
            for title in candidate.conversationTitles {
                append("conversation")
                append(title)
            }
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }
}

@MainActor
extension HarvisRuntimeModel {
    func managedConversationInsightTarget(
        for thread: ManagedChatThread
    ) -> ManagedConversationInsightTarget {
        ManagedConversationInsightTarget(
            provider: thread.provider.rawValue,
            sourceScope: thread.sourceScope,
            sourceID: thread.sourceID
        )
    }

    func managedConversationInsightContext(
        for thread: ManagedChatThread
    ) -> ManagedConversationInsightRuntimeContext {
        let inputState = conversationInputState(for: thread)
        let sourceProject = ManagedChatProjectResolver.resolveSource(thread: thread)
        let managedProject = ManagedChatProjectResolver.resolve(thread: thread)
        let sharedCatalog = cachedManagedInsightCatalog
        let catalog = sharedCatalog.projects
        let candidateFacts = sharedCatalog.candidates
        let candidateMap = sharedCatalog.candidateMap
        let currentCandidateID = managedProject.canonicalPath == nil
            ? nil
            : ManagedConversationInsightProjectCatalog.candidateID(
                for: managedProject
            )
        let evidenceRevision: String
        if inputState.loadedAt != nil,
           inputState.threadUpdatedAtAtLoad == thread.updatedAt,
           let sourceRevision = inputState.sourceRevision {
            evidenceRevision = sourceRevision
        } else {
            evidenceRevision = "source-unavailable-or-stale:\(thread.updatedAt)"
        }
        let fingerprint = ManagedConversationInsightProjectCatalog
            .analysisFingerprint(
                sourceRevision: evidenceRevision,
                candidates: candidateFacts
            )
        let status = managedConversationInsights.status(
            for: managedConversationInsightTarget(for: thread),
            currentInputFingerprint: fingerprint,
            currentProjectCandidateID: currentCandidateID
        )
        let recommendedProject = status?.latestInsight?.relevance
            .recommendedCandidateID.flatMap { candidateMap[$0] }
        let brainEnabled = managedProject.canonicalPath != nil
            && isConversationManagementBrainEnabled(for: managedProject)

        let availabilityMessage: String?
        if inputState.isLoading {
            availabilityMessage = "正在读取用户输入…"
        } else if thread.provider != .codex {
            availabilityMessage = inputState.error
                ?? "该提供方尚未提供只读取用户输入的安全接口。"
        } else if let error = inputState.error, !error.isEmpty {
            availabilityMessage = error
        } else if !inputState.sourceAvailable {
            availabilityMessage = inputState.error ?? "用户输入来源暂不可用。"
        } else if inputState.loadedAt == nil
            || inputState.threadUpdatedAtAtLoad != thread.updatedAt {
            availabilityMessage = "用户输入证据可能已陈旧，请重新读取。"
        } else if inputState.items.isEmpty {
            availabilityMessage = "当前对话没有可供分析的用户输入。"
        } else if managedProject.canonicalPath == nil {
            availabilityMessage = "请先把对话归入一个可管理的项目。"
        } else if !brainEnabled {
            availabilityMessage = "请先在“\(managedProject.label)”项目管理页开启 DSH 管理大脑。"
        } else if conversationManagementBrainEndpoint == nil {
            availabilityMessage = conversationManagementBrainEndpointError
                ?? "专用 DSH 大脑 endpoint 不可用。"
        } else if !managedConversationInsights.isReady {
            availabilityMessage = "正在恢复对话分析状态…"
        } else if !managedConversationInsights.securityAvailability.isAvailable {
            availabilityMessage = managedConversationInsights
                .securityAvailability.unavailableReason
                ?? "正在验证专用 DSH 分析 Preset 的零工具边界…"
        } else {
            availabilityMessage = nil
        }

        return ManagedConversationInsightRuntimeContext(
            inputState: inputState,
            sourceProject: sourceProject,
            managedProject: managedProject,
            status: status,
            projectCatalog: catalog.filter { $0.canonicalPath != nil },
            recommendedProject: recommendedProject,
            brainEnabled: brainEnabled,
            availabilityMessage: availabilityMessage
        )
    }

    func attestManagedConversationInsightSecurity() async {
        await managedConversationInsights.activate()
        guard let endpoint = conversationManagementBrainEndpoint else {
            managedConversationInsightRevision &+= 1
            return
        }
        _ = await managedConversationInsights.attestSecurity(endpoint: endpoint)
        managedConversationInsightRevision &+= 1
    }

    @discardableResult
    func analyzeManagedConversationInsight(
        for thread: ManagedChatThread
    ) async throws -> ManagedConversationInsightV1 {
        await managedConversationInsights.activate()
        managedConversationInsightRevision &+= 1

        let storageKey = managedChatStorageKey(thread)
        guard let currentBeforeRead = managedChatThreads.first(where: {
            managedChatStorageKey($0) == storageKey
        }) else {
            throw ManagedConversationInsightRuntimeError.staleTarget
        }
        await refreshConversationInputs(for: currentBeforeRead, force: true)
        guard let current = managedChatThreads.first(where: {
            managedChatStorageKey($0) == storageKey
        }) else {
            throw ManagedConversationInsightRuntimeError.staleTarget
        }
        let managedProject = ManagedChatProjectResolver.resolve(thread: current)
        guard managedProject.canonicalPath != nil else {
            throw ManagedConversationInsightRuntimeError.projectUnavailable
        }
        guard isConversationManagementBrainEnabled(for: managedProject) else {
            throw ManagedConversationInsightRuntimeError.projectBrainDisabled(
                managedProject.label
            )
        }
        guard let endpoint = conversationManagementBrainEndpoint else {
            throw DshMetaAgentCoordinatorError.brainEndpointUnavailable(
                homeID: DshMetaAgentPolicy.dedicatedHomeID,
                profile: DshMetaAgentPolicy.dedicatedProfile
            )
        }

        let brainHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh-harvis-meta", isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: brainHome.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ManagedConversationInsightRuntimeError.brainHomeUnavailable
        }

        let catalog = managedChatProjectCatalog
        let candidates = ManagedConversationInsightProjectCatalog.candidates(
            projects: catalog,
            threads: managedChatThreads,
            taskPlans: managedProjectTaskPlans,
            taskFreshness: managedProjectTaskPlanFreshness
        )
        let currentCandidateID = ManagedConversationInsightProjectCatalog
            .candidateID(for: managedProject)
        guard candidates.contains(where: {
            $0.candidateID == currentCandidateID
        }) else {
            throw ManagedConversationInsightRuntimeError.projectUnavailable
        }
        // This synchronous helper is the privacy boundary: it reads raw panel
        // rows, produces the irreversible fact projection, and returns a value
        // that contains no source text. The async DSH state machine therefore
        // never retains a raw input model across an await.
        let prepared = try prepareManagedConversationInsightRequest(
            for: current,
            candidates: candidates,
            currentCandidateID: currentCandidateID
        )

        defer { managedConversationInsightRevision &+= 1 }
        return try await managedConversationInsights.analyzePrepared(
            prepared,
            endpoint: endpoint,
            // Insight sessions are deliberately rooted in the dedicated DSH
            // Home, never in the source project. The model receives only the
            // redacted evidence embedded in the explicit prompt.
            brainWorkingDirectory: brainHome.path
        )
    }

    private func prepareManagedConversationInsightRequest(
        for thread: ManagedChatThread,
        candidates: [ManagedConversationProjectCandidate],
        currentCandidateID: String
    ) throws -> ManagedConversationPreparedInsightRequest {
        let state = conversationInputState(for: thread)
        guard state.error == nil,
              state.sourceAvailable,
              let sourceRevision = state.sourceRevision else {
            throw ManagedConversationInsightRuntimeError.sourceUnavailable(
                state.error ?? "用户输入来源暂不可用。"
            )
        }
        guard state.loadedAt != nil,
              state.threadUpdatedAtAtLoad == thread.updatedAt else {
            throw ManagedConversationInsightRuntimeError.staleInputEvidence
        }
        guard !state.items.isEmpty else {
            throw ManagedConversationInsightRuntimeError.noUserInputs
        }
        let fingerprint = ManagedConversationInsightProjectCatalog
            .analysisFingerprint(
                sourceRevision: sourceRevision,
                candidates: candidates
            )
        return try managedConversationInsights.prepare(
            ManagedConversationInsightInput(
                target: managedConversationInsightTarget(for: thread),
                messages: state.items,
                inputFingerprint: fingerprint,
                totalUserMessageCount: state.totalCount,
                currentProjectCandidateID: currentCandidateID,
                candidates: candidates
            )
        )
    }

    func cancelManagedConversationInsight(
        for thread: ManagedChatThread
    ) async throws {
        guard let endpoint = conversationManagementBrainEndpoint else {
            throw DshMetaAgentCoordinatorError.brainEndpointUnavailable(
                homeID: DshMetaAgentPolicy.dedicatedHomeID,
                profile: DshMetaAgentPolicy.dedicatedProfile
            )
        }
        defer { managedConversationInsightRevision &+= 1 }
        try await managedConversationInsights.cancel(
            target: managedConversationInsightTarget(for: thread),
            endpoint: endpoint
        )
    }

    /// Applies only a fresh, exact recommendation to Harvis's local grouping.
    /// Provider cwd, files, thread identity, and execution permissions remain
    /// untouched.
    func applyManagedConversationInsightRecommendation(
        for thread: ManagedChatThread,
        at now: Date = Date()
    ) throws {
        let key = managedChatStorageKey(thread)
        guard let current = managedChatThreads.first(where: {
            managedChatStorageKey($0) == key
        }) else {
            throw ManagedConversationInsightRuntimeError.staleTarget
        }
        let context = managedConversationInsightContext(for: current)
        guard context.inputState.error == nil,
              context.inputState.sourceAvailable,
              context.inputState.loadedAt != nil,
              context.inputState.threadUpdatedAtAtLoad == current.updatedAt else {
            throw ManagedConversationInsightRuntimeError.staleInputEvidence
        }
        guard let status = context.status,
              status.state == .completed,
              !status.relevanceIsStale else {
            throw ManagedConversationInsightRuntimeError.staleRecommendation
        }
        guard let recommendation = context.recommendedProject else {
            throw ManagedConversationInsightRuntimeError
                .recommendationUnavailable
        }
        assignConversation(
            current,
            to: recommendation,
            source: .aiRecommendation,
            at: now
        )
    }
}
