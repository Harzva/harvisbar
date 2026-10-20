import Foundation

@MainActor
extension HarvisRuntimeModel {
    /// Opening the review surface captures a scope but does not analyze or
    /// alter the project registry. Generation is a separate explicit action.
    func prepareProjectOrganizer(threads: [ManagedChatThread]) {
        guard !projectOrganizerIsAnalyzing, !projectOrganizerIsApplying else { return }
        let ids = Array(Set(threads.map(\.id))).sorted()
        if Set(projectOrganizerScopeConversationIDs) != Set(ids) {
            resetProjectGroupxReview()
            projectOrganizerProposal = nil
            projectOrganizerError = nil
            projectOrganizerFeedback = nil
            projectOrganizerProgress = ""
        }
        projectOrganizerScopeConversationIDs = ids
        let eligible = threads.filter { hasProjectOrganizerInputCapability($0) }.count
        projectOrganizerCoverage = "当前范围 \(ids.count) 个已载入会话，可读取用户输入 \(eligible) 个。"
    }

    func analyzeProjectOrganizer() {
        guard !projectOrganizerIsAnalyzing, !projectOrganizerIsApplying else { return }
        guard projectOrganizationLoadError == nil else {
            projectOrganizerError = "项目整理存储无法读取，已保留原数据。"
            return
        }
        guard let endpoint = conversationManagementBrainEndpoint else {
            projectOrganizerError = "专用 AI 分析服务尚未就绪。请先在项目管理中连接 DSH 管理大脑。"
            return
        }
        let scope = Set(projectOrganizerScopeConversationIDs)
        let current = managedChatThreads.filter { scope.contains($0.id) }
        let eligible = current.filter { hasProjectOrganizerInputCapability($0) }
            .sorted { $0.updatedAt > $1.updatedAt || ($0.updatedAt == $1.updatedAt && $0.id < $1.id) }
        guard !eligible.isEmpty else {
            projectOrganizerError = "当前范围没有可读取用户输入的会话。请检查来源连接及 DSH 桥接能力。"
            return
        }
        let selected = Array(eligible.prefix(ManagedProjectOrganizerAnalysisLimits.maximumConversations))
        let generation = UUID()
        let baseRevision = managedProjectOrganization.revision
        let fullCatalog = managedChatProjectCatalog
        let catalogFingerprint = ManagedProjectOrganizationEngine.catalogFingerprint(fullCatalog)
        let records = managedProjectOrganization.projects
        let catalog = Self.projectOrganizerAnalysisCatalog(
            catalog: fullCatalog, records: records, threads: selected
        )
        resetProjectGroupxReview()
        projectOrganizerGeneration = generation
        projectOrganizerIsAnalyzing = true
        projectOrganizerError = nil
        projectOrganizerFeedback = nil
        projectOrganizerProposal = nil
        projectOrganizerProgress = "正在读取所选范围的用户输入…"
        projectOrganizerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.projectOrganizerGeneration == generation {
                    self.projectOrganizerIsAnalyzing = false
                    self.projectOrganizerTask = nil
                }
            }
            do {
                let projectRefs = Dictionary(uniqueKeysWithValues: catalog.enumerated().map { ($0.element.id, "p\($0.offset + 1)") })
                let refProjects = Dictionary(uniqueKeysWithValues: catalog.enumerated().map { ("p\($0.offset + 1)", $0.element) })
                let hierarchy = ManagedProjectHierarchy(catalog: catalog, records: records, threads: current)
                let parents = Dictionary(uniqueKeysWithValues: hierarchy.nodes.map { ($0.id, $0.parentID) })
                let projects = catalog.map { project in
                    ManagedProjectOrganizerAnalysisProject(
                        ref: projectRefs[project.id]!,
                        name: project.label,
                        purpose: records[project.id]?.purpose ?? "",
                        parentRef: (parents[project.id] ?? nil).flatMap { projectRefs[$0] }
                    )
                }
                var snapshots: [ManagedProjectOrganizationConversation] = []
                var inputs: [ManagedProjectOrganizerAnalysisConversation] = []
                var refConversations: [String: String] = [:]
                var unavailable: [ManagedProjectOrganizerSuggestion] = []
                for (index, original) in selected.enumerated() {
                    try Task.checkCancellation()
                    guard self.projectOrganizerGeneration == generation else { throw CancellationError() }
                    self.projectOrganizerProgress = "读取用户输入 \(index + 1)/\(selected.count)…"
                    let ref = "c\(index + 1)"
                    guard let thread = self.managedChatThreads.first(where: { $0.id == original.id }) else {
                        throw HarvisBarError.api("分析范围中的会话已变化，请重新打开整理。")
                    }
                    let before = self.projectOrganizationSnapshot(thread, inputRevision: nil)
                    defer { self.clearConversationInputPanel(for: thread) }
                    let readStamp = self.projectOrganizerInputReadStamp(for: thread)
                    guard !self.conversationInputState(for: thread).isLoading else {
                        throw HarvisBarError.api("该会话的用户输入正在其他面板读取，请稍后重试。")
                    }
                    await self.refreshConversationInputs(for: thread, force: true)
                    try Task.checkCancellation()
                    guard let refreshed = self.managedChatThreads.first(where: { $0.id == original.id }),
                          self.projectOrganizationSnapshot(refreshed, inputRevision: nil) == before else {
                        throw HarvisBarError.api("会话或来源账号在读取期间变化，请重新分析。")
                    }
                    let input = self.conversationInputState(for: refreshed)
                    guard self.projectOrganizerInputReadCompleted(for: refreshed, after: readStamp),
                          input.error == nil, input.sourceAvailable,
                          input.threadUpdatedAtAtLoad == refreshed.updatedAt,
                          let revision = input.sourceRevision, !input.items.isEmpty else {
                        snapshots.append(before)
                        unavailable.append(ManagedProjectOrganizerSuggestion(
                            action: .keep, conversationIDs: [refreshed.id],
                            reason: input.error ?? "没有足够的用户输入证据，保留当前归属。",
                            evidence: ["此会话未交给 AI 判断。"]
                        ))
                        continue
                    }
                    snapshots.append(self.projectOrganizationSnapshot(refreshed, inputRevision: revision))
                    var seen = Set<String>()
                    let excerptItems = (Array(input.items.prefix(2)) + Array(input.items.suffix(6)))
                        .filter { seen.insert($0.id).inserted }
                    let messages = excerptItems.enumerated().map {
                        ManagedProjectOrganizerAnalysisMessage(
                            ref: "m\($0.offset + 1)", text: $0.element.text,
                            truncated: $0.element.truncated || input.isTruncated,
                            source: $0.element.source
                        )
                    }
                    inputs.append(ManagedProjectOrganizerAnalysisConversation(
                        ref: ref, title: refreshed.title,
                        currentProjectRef: projectRefs[ManagedChatProjectResolver.resolve(thread: refreshed).id],
                        messages: messages, totalUserMessageCount: input.totalCount
                    ))
                    refConversations[ref] = refreshed.id
                }
                guard !inputs.isEmpty else {
                    throw HarvisBarError.api("所选会话均没有可分析的用户输入；未生成 AI 归类结果。")
                }
                let selectedIDs = Set(selected.map(\.id))
                for thread in current where !selectedIDs.contains(thread.id) {
                    snapshots.append(self.projectOrganizationSnapshot(thread, inputRevision: nil))
                    unavailable.append(ManagedProjectOrganizerSuggestion(
                        action: .keep, conversationIDs: [thread.id],
                        reason: self.hasProjectOrganizerInputCapability(thread)
                            ? "超出本批 100 个会话上限。请在所属项目中继续整理。"
                            : "该来源暂未接入可信的用户输入读取，保留当前归属。",
                        evidence: ["未分析，不代表归属已经确认。"]
                    ))
                }
                guard self.managedProjectOrganization.revision == baseRevision,
                      ManagedProjectOrganizationEngine.catalogFingerprint(self.managedChatProjectCatalog) == catalogFingerprint else {
                    throw ManagedProjectOrganizationError.staleState
                }
                self.projectOrganizerProgress = "AI 正在比较项目目标并生成建议…"
                self.projectOrganizerCoverage = "正在分析 \(inputs.count)/\(current.count) 个会话的必要用户输入片段。"
                let brainHome = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".dsh-harvis-meta", isDirectory: true).path
                let response = try await ManagedProjectOrganizerPlanner().analyze(
                    ManagedProjectOrganizerAnalysisRequest(
                        projects: projects, conversations: inputs,
                        uninspectedConversationCount: current.count - inputs.count
                    ),
                    endpoint: endpoint, brainWorkingDirectory: brainHome
                )
                try Task.checkCancellation()
                guard self.projectOrganizerGeneration == generation else { throw CancellationError() }
                let proposal = try Self.projectOrganizerProposal(
                    response: response,
                    refProjects: refProjects,
                    refConversations: refConversations,
                    snapshots: snapshots,
                    unavailable: unavailable,
                    baseStateRevision: baseRevision,
                    catalogFingerprint: catalogFingerprint
                )
                self.projectOrganizerProposal = proposal
                let coverage = response.coverage
                self.projectOrganizerCoverage = "已提交 \(coverage.conversationsWithEvidenceCount)/\(current.count) 个会话；AI 未返回建议 \(coverage.modelOmittedConversationCount) 个。使用 \(coverage.sentUserMessageCount)/\(coverage.totalUserMessageCount) 条输入片段（来源未验证 \(coverage.unverifiedUserMessageCount)，截短 \(coverage.truncatedMessageCount)）。比较 \(catalog.count)/\(fullCatalog.count) 个已知项目，其他会话保留待确认。"
                self.projectOrganizerProgress = "建议已生成，请查看证据、修改目标并勾选。"
                if self.managedProjectOrganization.revision != baseRevision {
                    self.projectOrganizerError = "分析期间项目归属已变化。这批建议可查看，应用前需要重新分析。"
                }
                self.persistProjectOrganizerDraft()
            } catch is CancellationError {
                // Cancellation never changes project state or publishes a late result.
            } catch {
                guard self.projectOrganizerGeneration == generation else { return }
                self.projectOrganizerError = error.localizedDescription
                self.projectOrganizerProgress = "分析未完成，项目归属未改变。"
            }
        }
    }

    /// Keep current project identities first, followed by their known parents
    /// and other candidates. Narrowing a scope therefore works even when the
    /// complete catalog exceeds one prompt's bounded project budget.
    static func projectOrganizerAnalysisCatalog(
        catalog: [ManagedChatProjectIdentity],
        records: [String: ManagedProjectRecord],
        threads: [ManagedChatThread]
    ) -> [ManagedChatProjectIdentity] {
        let hierarchy = ManagedProjectHierarchy(catalog: catalog, records: records, threads: threads)
        var ids: [String] = []
        var seen = Set<String>()
        func append(_ id: String) {
            if seen.insert(id).inserted { ids.append(id) }
        }
        for thread in threads { append(ManagedChatProjectResolver.resolve(thread: thread).id) }
        for id in ids {
            for node in hierarchy.breadcrumb(to: id).reversed() { append(node.id) }
        }
        for project in catalog.sorted(by: { $0.id < $1.id }) { append(project.id) }
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, rhs in rhs })
        return Array(ids.compactMap { byID[$0] }.prefix(ManagedProjectOrganizerAnalysisLimits.maximumProjects))
    }

    static func projectOrganizerProposal(
        response: ManagedProjectOrganizerAnalysisResponse,
        refProjects: [String: ManagedChatProjectIdentity],
        refConversations: [String: String],
        snapshots: [ManagedProjectOrganizationConversation],
        unavailable: [ManagedProjectOrganizerSuggestion],
        baseStateRevision: Int,
        catalogFingerprint: String
    ) throws -> ManagedProjectOrganizerProposal {
        var children: [String: ManagedProjectRecord] = [:]
        var suggestions: [ManagedProjectOrganizerSuggestion] = []
        for child in response.children {
            guard let parent = refProjects[child.parentProjectRef] else {
                throw ManagedProjectOrganizationError.missingProject(child.parentProjectRef)
            }
            if let pathRef = child.pathProjectRef, refProjects[pathRef] == nil {
                throw ManagedProjectOrganizationError.missingProject(pathRef)
            }
            let path = child.pathProjectRef.flatMap { refProjects[$0]?.canonicalPath }
            let project = ManagedProjectRecord(
                name: child.name, purpose: child.purpose, parentID: parent.id, path: path
            )
            children[child.ref] = project
            suggestions.append(ManagedProjectOrganizerSuggestion(
                action: .createSubproject, conversationIDs: [], proposedProject: project,
                reason: child.purpose,
                evidence: ["父项目：\(parent.label)", path == nil ? "仅建立项目分类，暂不关联文件夹。" : "关联现有工作路径，不创建目录或移动文件。"]
            ))
        }
        for item in response.suggestions {
            guard let conversationID = refConversations[item.conversationRef] else {
                throw ManagedProjectOrganizationError.malformedProposal("无法对应的会话引用")
            }
            let target: ManagedChatProjectIdentity?
            switch item.action {
            case .move:
                target = item.targetProjectRef.flatMap { refProjects[$0] }
            case .newChild:
                target = item.targetChildRef.flatMap { children[$0]?.identity }
            case .keep:
                target = nil
            }
            if item.action != .keep && target == nil {
                throw ManagedProjectOrganizationError.malformedProposal("无法对应的项目引用")
            }
            let evidence = item.evidence.map {
                let source = $0.source == .human ? "用户输入" : "用户角色输入（自然人来源未验证）"
                return "\(source) · \($0.messageRef)\($0.truncated ? " · 节选" : "")\n\($0.excerpt)"
            }
            suggestions.append(ManagedProjectOrganizerSuggestion(
                action: item.action == .keep ? .keep : .assign,
                conversationIDs: [conversationID], targetProjectID: target?.id,
                reason: item.reason,
                evidence: evidence,
                confidence: item.confidence >= 0.8 && !evidence.isEmpty && !item.modelOmitted ? .strong : .needsReview
            ))
        }
        return ManagedProjectOrganizerProposal(
            baseStateRevision: baseStateRevision,
            catalogFingerprint: catalogFingerprint,
            snapshots: snapshots,
            suggestions: suggestions + unavailable
        )
    }

    func applyProjectOrganizerSelection(_ selectedSuggestionIDs: [String]) {
        guard !projectOrganizerIsApplying, !projectOrganizerIsAnalyzing,
              var proposal = projectOrganizerProposal else { return }
        let selected = Set(selectedSuggestionIDs)
        for index in proposal.suggestions.indices {
            proposal.suggestions[index].isSelected = selected.contains(proposal.suggestions[index].id)
                && proposal.suggestions[index].action != .keep
        }
        let generation = UUID()
        projectOrganizerGeneration = generation
        projectOrganizerIsApplying = true
        projectOrganizerError = nil
        projectOrganizerFeedback = nil
        projectOrganizerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.projectOrganizerGeneration == generation {
                    self.projectOrganizerIsApplying = false
                    self.projectOrganizerTask = nil
                }
            }
            do {
                guard self.projectOrganizationLoadError == nil else {
                    throw HarvisBarError.api("项目整理存储无法读取，已暂停修改。")
                }
                try self.validateProjectOrganizerAssociatedPaths(proposal)
                let needed = Set(proposal.suggestions.filter(\.isSelected).flatMap(\.conversationIDs))
                var snapshots: [ManagedProjectOrganizationConversation] = []
                for (index, expected) in proposal.snapshots.filter({ needed.contains($0.id) }).enumerated() {
                    try Task.checkCancellation()
                    self.projectOrganizerProgress = "重新校验会话 \(index + 1)/\(needed.count)…"
                    guard let thread = self.managedChatThreads.first(where: { $0.id == expected.id }) else {
                        throw ManagedProjectOrganizationError.staleConversation(expected.title)
                    }
                    guard self.hasProjectOrganizerInputCapability(thread) else {
                        throw HarvisBarError.api("未分析的来源不能应用 AI 归属调整。")
                    }
                    let readStamp = self.projectOrganizerInputReadStamp(for: thread)
                    // Register cleanup before the await: cancellation or a
                    // replaced panel must never retain the just-read raw rows.
                    defer { self.clearConversationInputPanel(for: thread) }
                    await self.refreshConversationInputs(for: thread, force: true)
                    try Task.checkCancellation()
                    guard let current = self.managedChatThreads.first(where: { $0.id == expected.id }) else {
                        throw ManagedProjectOrganizationError.staleConversation(expected.title)
                    }
                    let input = self.conversationInputState(for: current)
                    guard self.projectOrganizerInputReadCompleted(for: current, after: readStamp),
                          input.error == nil, input.sourceAvailable,
                          input.threadUpdatedAtAtLoad == current.updatedAt,
                          let revision = input.sourceRevision else {
                        throw ManagedProjectOrganizationError.staleConversation(expected.title)
                    }
                    snapshots.append(self.projectOrganizationSnapshot(current, inputRevision: revision))
                }
                try Task.checkCancellation()
                guard self.projectOrganizerGeneration == generation else { throw CancellationError() }
                // Earlier items may have changed while later items were being
                // read. Recheck every live identity at the final no-await edge.
                for snapshot in snapshots {
                    guard let current = self.managedChatThreads.first(where: { $0.id == snapshot.id }) else {
                        throw ManagedProjectOrganizationError.staleConversation(snapshot.title)
                    }
                    let input = self.conversationInputState(for: current)
                    guard !input.isLoading, input.sourceAvailable, input.error == nil,
                          input.threadUpdatedAtAtLoad == current.updatedAt,
                          self.projectOrganizationSnapshot(
                            current, inputRevision: input.sourceRevision
                          ) == snapshot else {
                        throw ManagedProjectOrganizationError.staleConversation(snapshot.title)
                    }
                }
                try self.validateProjectOrganizerAssociatedPaths(proposal)
                let result = try ManagedProjectOrganizationEngine.apply(
                    state: self.managedProjectOrganization, proposal: proposal,
                    currentSnapshots: snapshots, currentCatalog: self.managedChatProjectCatalog
                )
                guard self.persistProjectOrganization(result.state) else { return }
                self.projectOrganizerProposal = nil
                self.clearPersistedProjectOrganizerDraft()
                self.projectOrganizerProgress = "本批整理已应用。"
                self.projectOrganizerFeedback = "已调整 \(result.receipt.appliedConversationCount) 个会话，新建 \(result.receipt.createdProjectCount) 个子项目；原始记录与运行目录保留。"
            } catch is CancellationError {
                // Validation is cancellable; the synchronous save has no await.
            } catch {
                guard self.projectOrganizerGeneration == generation else { return }
                self.projectOrganizerError = error.localizedDescription
                self.projectOrganizerProgress = "未应用，项目归属保持原状。"
            }
        }
    }
}
