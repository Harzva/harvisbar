import Combine
import Foundation

enum HarvisGroupRecipientMode: Codable, Equatable, Sendable {
    case coordinated
    case allMembers
    case selected(Set<UUID>)
    case recordOnly
}

struct HarvisGroupComposerDraft: Codable, Equatable, Sendable {
    var text = ""
    var recipientMode: HarvisGroupRecipientMode = .allMembers
    var permission: HarvisGroupPermission = .discussion
}

struct HarvisGroupComposerSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var selectedGroupID: UUID?
    var drafts: [UUID: HarvisGroupComposerDraft] = [:]
}

protocol HarvisGroupComposerPersisting: Sendable {
    func load() async throws -> HarvisGroupComposerSnapshot
    func save(_ snapshot: HarvisGroupComposerSnapshot, revision: UInt64) async throws -> UInt64
}

actor HarvisGroupComposerStore: HarvisGroupComposerPersisting {
    let url: URL
    private var savedRevision: UInt64 = 0

    init(url: URL) { self.url = url }

    func load() throws -> HarvisGroupComposerSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let snapshot = try JSONDecoder().decode(HarvisGroupComposerSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else {
            throw HarvisGroupError.invalid("无法读取此版本的群聊草稿。原文件已保留。")
        }
        return snapshot
    }

    func save(_ snapshot: HarvisGroupComposerSnapshot, revision: UInt64) throws -> UInt64 {
        // A delayed save must never overwrite a newer snapshot.
        guard revision > savedRevision else { return savedRevision }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        savedRevision = revision
        return savedRevision
    }
}

/// Window-independent composer state. It never submits a message or alters the
/// group ledger, and disk IO is isolated from the main actor.
@MainActor
final class HarvisGroupComposerState: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?
    @Published private(set) var selectedGroupID: UUID?
    @Published private(set) var drafts: [UUID: HarvisGroupComposerDraft] = [:]

    private let store: any HarvisGroupComposerPersisting
    private let saveDelay: Duration
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var canSave = false
    private var revision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private var editedGroups: Set<UUID> = []
    private var selectionEdited = false

    init(store: any HarvisGroupComposerPersisting, saveDelay: Duration = .milliseconds(250)) {
        self.store = store
        self.saveDelay = saveDelay
    }

    var hasUnsavedChanges: Bool { revision > savedRevision }

    func draft(for groupID: UUID) -> HarvisGroupComposerDraft { drafts[groupID] ?? .init() }

    func updateDraft(groupID: UUID, text: String, recipientMode: HarvisGroupRecipientMode,
                     permission: HarvisGroupPermission) {
        let value = HarvisGroupComposerDraft(text: text, recipientMode: recipientMode, permission: permission)
        guard draft(for: groupID) != value else { return }
        drafts[groupID] = value
        editedGroups.insert(groupID)
        didChange()
    }

    func selectGroup(_ id: UUID?) {
        guard selectedGroupID != id else { return }
        selectedGroupID = id
        selectionEdited = true
        didChange()
    }

    func activate() async {
        if let loadTask { await loadTask.value; return }
        guard !isReady || !canSave else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await store.load()
                for (id, var draft) in snapshot.drafts where !editedGroups.contains(id) {
                    // Restoring a draft never restores a grant to edit files.
                    draft.permission = .discussion
                    drafts[id] = draft
                }
                if !selectionEdited { selectedGroupID = snapshot.selectedGroupID }
                canSave = true
                lastError = nil
            } catch {
                // Do not replace an unread/corrupt file with an empty draft.
                canSave = false
                lastError = "草稿读取失败，原文件已保留：\(error.localizedDescription)"
            }
            isReady = true
            if canSave, hasUnsavedChanges { scheduleSave() }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    @discardableResult
    func flush() async -> Bool {
        saveTask?.cancel()
        saveTask = nil
        if !isReady { await activate() }
        guard hasUnsavedChanges else { return true }
        return await savePendingChanges()
    }

    private func didChange() {
        revision += 1
        if canSave { scheduleSave() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            do { try await Task.sleep(for: saveDelay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = await savePendingChanges()
        }
    }

    private func savePendingChanges() async -> Bool {
        guard canSave else { return false }
        while hasUnsavedChanges {
            let currentRevision = revision
            let snapshot = HarvisGroupComposerSnapshot(selectedGroupID: selectedGroupID, drafts: drafts)
            do {
                let persisted = try await store.save(snapshot, revision: currentRevision)
                savedRevision = max(savedRevision, persisted)
                lastError = nil
            } catch {
                lastError = "草稿尚未保存：\(error.localizedDescription)"
                return false
            }
        }
        return true
    }
}
