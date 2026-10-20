import CryptoKit
import Foundation

struct ManagedProjectOrganizerInputReadStamp: Equatable, Sendable {
    let storageKey: String
    let generation: Int
    let loadedAt: Date?
}

@MainActor
extension HarvisRuntimeModel {
    func projectOrganizerInputReadStamp(for thread: ManagedChatThread) -> ManagedProjectOrganizerInputReadStamp {
        let key = managedChatStorageKey(thread)
        return ManagedProjectOrganizerInputReadStamp(
            storageKey: key,
            generation: managedConversationInputLoadGenerations[key, default: 0],
            loadedAt: conversationInputState(for: thread).loadedAt
        )
    }

    /// A forced refresh can return early when another load owns the panel, or
    /// be superseded while awaiting the adapter. Neither is a fresh authority read.
    func projectOrganizerInputReadCompleted(
        for thread: ManagedChatThread,
        after stamp: ManagedProjectOrganizerInputReadStamp
    ) -> Bool {
        let key = managedChatStorageKey(thread)
        let state = conversationInputState(for: thread)
        guard key == stamp.storageKey, stamp.generation < Int.max,
              managedConversationInputLoadGenerations[key] == stamp.generation + 1,
              !state.isLoading, let loadedAt = state.loadedAt else { return false }
        return loadedAt != stamp.loadedAt
    }

    @discardableResult
    func persistProjectOrganization(_ next: ManagedProjectOrganizationState) -> Bool {
        guard projectOrganizationLoadError == nil else {
            projectOrganizerError = "项目整理存储无法读取，已保留原数据并暂停修改。"
            return false
        }
        do {
            try projectOrganizationStore.save(next)
            managedProjectOrganization = next
            return true
        } catch {
            projectOrganizerError = "保存项目归属失败：\(error.localizedDescription)"
            return false
        }
    }

    var lastProjectOrganizationReceipt: ManagedProjectOrganizationReceipt? {
        managedProjectOrganization.history.last { !$0.isUndone }
    }

    func undoLastProjectOrganization() {
        guard !projectOrganizerIsApplying, !projectOrganizerIsAnalyzing,
              let receipt = lastProjectOrganizationReceipt else { return }
        do {
            let result = try ManagedProjectOrganizationEngine.undo(
                state: managedProjectOrganization, receiptID: receipt.id
            )
            guard persistProjectOrganization(result.state) else { return }
            projectOrganizerProposal = nil
            projectOrganizerError = nil
            projectOrganizerFeedback = "已撤销本批 \(receipt.appliedConversationCount) 个会话的归属调整，移除 \(receipt.createdProjectCount) 个本批新建子项目。"
            clearPersistedProjectOrganizerDraft()
        } catch {
            projectOrganizerError = error.localizedDescription
        }
    }

    /// Binds a source snapshot to both the account/home identity and the input
    /// bytes supplied by the read-only adapter. Launch cwd is never reassigned.
    func projectOrganizationSnapshot(
        _ thread: ManagedChatThread,
        inputRevision: String?
    ) -> ManagedProjectOrganizationConversation {
        let accountIdentity: String
        if let home = codexHome(for: thread) {
            accountIdentity = [home.id, home.path, home.accountKey ?? "", home.quotaMode ?? ""].joined(separator: "\u{0}")
        } else {
            accountIdentity = thread.sourceScope
        }
        let material = [
            "project-organizer-source-v1", thread.id, accountIdentity,
            String(thread.updatedAt), thread.cwd, thread.title,
            thread.parentThreadID ?? "", thread.rootThreadId,
            inputRevision ?? "not-inspected",
        ].map { "\($0.utf8.count):\($0)" }.joined()
        let revision = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ManagedProjectOrganizationConversation(
            id: thread.id,
            storageKey: managedChatStorageKey(thread),
            sourceRevision: "sha256:\(revision)",
            sourceProject: ManagedChatProjectResolver.resolveSource(thread: thread),
            effectiveProject: ManagedChatProjectResolver.resolve(thread: thread),
            assignment: projectAssignment(for: thread),
            title: thread.title,
            provider: thread.provider.label
        )
    }

    func persistProjectOrganizerDraft() {
        guard let proposal = projectOrganizerProposal else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            defaults.set(try encoder.encode(proposal), forKey: "harvisBar.projectOrganizerDraft.v1")
        } catch {
            projectOrganizerError = "建议草稿未能保存：\(error.localizedDescription)"
        }
    }

    func restoreProjectOrganizerDraft() {
        guard projectOrganizerProposal == nil,
              let data = defaults.data(forKey: "harvisBar.projectOrganizerDraft.v1") else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let proposal = try decoder.decode(ManagedProjectOrganizerProposal.self, from: data)
            projectOrganizerProposal = proposal
            projectOrganizerScopeConversationIDs = proposal.snapshots.map(\.id)
            projectOrganizerCoverage = "已恢复 \(proposal.snapshots.count) 个会话的建议；应用前会重新校验。"
        } catch {
            projectOrganizerError = "旧建议草稿无法读取，请重新生成。"
        }
    }

    func clearPersistedProjectOrganizerDraft() {
        defaults.removeObject(forKey: "harvisBar.projectOrganizerDraft.v1")
    }

    func cancelProjectOrganizerAnalysis() {
        projectOrganizerGeneration = nil
        projectOrganizerTask?.cancel()
        projectOrganizerTask = nil
        projectOrganizerIsAnalyzing = false
        projectOrganizerIsApplying = false
        projectOrganizerProgress = "已取消，项目归属未改变。"
    }

    func validateProjectOrganizerAssociatedPaths(_ proposal: ManagedProjectOrganizerProposal) throws {
        for suggestion in proposal.suggestions where suggestion.isSelected && suggestion.action == .createSubproject {
            guard let path = suggestion.proposedProject?.path else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw HarvisBarError.api("关联路径尚不存在或不是文件夹。请选择现有路径，或清空路径仅建立项目分类。")
            }
        }
    }
}
