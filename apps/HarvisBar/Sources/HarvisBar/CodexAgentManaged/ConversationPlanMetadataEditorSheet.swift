import SwiftUI

enum ConversationPlanEditorPolicy {
    static func includeForDispatch(
        workKind: ConversationWorkKindV1
    ) -> Bool {
        workKind != .unclassified
    }

    static func label(for workKind: ConversationWorkKindV1) -> String {
        switch workKind {
        case .unclassified: return "未分类（清除绑定）"
        case .task: return "项目任务"
        case .exploration: return "探索"
        case .operations: return "运维"
        case .knowledge: return "知识"
        case .management: return "管理"
        }
    }

    static func description(for workKind: ConversationWorkKindV1) -> String {
        switch workKind {
        case .unclassified:
            return "不声明工作类型，并清除现有任务绑定。"
        case .task:
            return "必须绑定项目任务清单中一个 fresh、未结束的精确任务。"
        case .exploration:
            return "探索性工作；不绑定任务，但必须显式声明。"
        case .operations:
            return "运行、部署或维护工作；不绑定任务。"
        case .knowledge:
            return "知识整理与文档工作；不绑定任务。"
        case .management:
            return "项目管理与协调工作；不绑定任务。"
        }
    }

    static func openTasks(
        from taskPlan: ConversationProjectTaskPlanProjectionV1
    ) -> [ConversationProjectTaskV1] {
        guard taskPlan.isAuthoritative else { return [] }
        return taskPlan.openTasks.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            return titleOrder == .orderedAscending
                || (titleOrder == .orderedSame && $0.taskID < $1.taskID)
        }
    }

    static func taskIDForPersistence(
        workKind: ConversationWorkKindV1,
        selectedTaskID: String
    ) -> String? {
        guard workKind == .task else { return nil }
        let trimmed = selectedTaskID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    static func canSave(
        brainEnabled: Bool,
        taskPlan: ConversationProjectTaskPlanProjectionV1,
        workKind: ConversationWorkKindV1,
        selectedTaskID: String
    ) -> Bool {
        guard brainEnabled else { return false }
        guard workKind == .task else { return true }
        guard let taskID = taskIDForPersistence(
            workKind: workKind,
            selectedTaskID: selectedTaskID
        ) else {
            return false
        }
        return openTasks(from: taskPlan).contains { $0.taskID == taskID }
    }
}

struct ConversationPlanMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let thread: ManagedChatThread
    let project: ManagedChatProjectIdentity
    let snapshot: ConversationManagementSnapshotV1?
    let theme: HarvisTheme
    let onSave: (ConversationWorkKindV1, String?, Bool) async throws -> Void
    let onClear: () async throws -> Void

    @State private var selectedWorkKind: ConversationWorkKindV1
    @State private var selectedTaskID: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        thread: ManagedChatThread,
        project: ManagedChatProjectIdentity,
        snapshot: ConversationManagementSnapshotV1?,
        theme: HarvisTheme,
        onSave: @escaping (
            ConversationWorkKindV1,
            String?,
            Bool
        ) async throws -> Void,
        onClear: @escaping () async throws -> Void
    ) {
        self.thread = thread
        self.project = project
        self.snapshot = snapshot
        self.theme = theme
        self.onSave = onSave
        self.onClear = onClear

        let target = ConversationManagementProjectorV1.target(for: thread)
        let extensionValue = snapshot?.record(for: target)?.managementExtension
        _selectedWorkKind = State(
            initialValue: extensionValue?.workKind ?? .unclassified
        )
        _selectedTaskID = State(
            initialValue: extensionValue?.taskBindings.first?.taskID ?? ""
        )
    }

    private var taskPlan: ConversationProjectTaskPlanProjectionV1 {
        snapshot?.taskPlan ?? .unavailable
    }

    private var brainEnabled: Bool {
        snapshot?.brainEnabled == true
    }

    private var openTasks: [ConversationProjectTaskV1] {
        ConversationPlanEditorPolicy.openTasks(from: taskPlan)
    }

    private var currentExtension: ConversationManagementExtensionV1? {
        snapshot?.record(
            for: ConversationManagementProjectorV1.target(for: thread)
        )?.managementExtension
    }

    private var canSave: Bool {
        !isSaving && ConversationPlanEditorPolicy.canSave(
            brainEnabled: brainEnabled,
            taskPlan: taskPlan,
            workKind: selectedWorkKind,
            selectedTaskID: selectedTaskID
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().overlay(theme.line)
            authorityNotice
            metadataEditor
            currentBinding
            errorNotice
            footer
        }
        .padding(20)
        .frame(width: 520)
        .background(theme.background)
        .foregroundColor(theme.text)
        .onChange(of: selectedWorkKind) { workKind in
            if workKind != .task {
                selectedTaskID = ""
            }
            errorMessage = nil
        }
        .accessibilityIdentifier("conversation-plan-metadata-editor")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("任务绑定与工作类型", systemImage: "checklist.checked")
                .harvisFont(.title3.bold())
                .foregroundColor(theme.accent)
            Text(thread.title)
                .harvisFont(.headline)
                .lineLimit(2)
            Text("\(project.label) · \(thread.provider.label)")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
        }
    }

    @ViewBuilder
    private var authorityNotice: some View {
        if snapshot == nil {
            Label(
                "项目管理快照尚未加载；当前不会假定大脑已开启，也不会保存任何关系。",
                systemImage: "questionmark.circle"
            )
            .harvisFont(.caption)
            .foregroundColor(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        } else if !brainEnabled {
            Label(
                "项目 DSH 管理大脑尚未开启。请先在项目管理页开启，才能保存分类或绑定。",
                systemImage: "brain.head.profile"
            )
            .harvisFont(.caption)
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Label(
                "保存会将此对话显式纳入可审批候选；仍需 exact taskID（任务类）与用户逐项批准，绝不会自动派发。不会写普通标签。",
                systemImage: "hand.raised.fill"
            )
            .harvisFont(.caption)
            .foregroundColor(theme.muted)
        }
    }

    private var metadataEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("工作类型", selection: $selectedWorkKind) {
                ForEach(ConversationWorkKindV1.allCases, id: \.rawValue) { kind in
                    Text(ConversationPlanEditorPolicy.label(for: kind))
                        .tag(kind)
                }
            }
            .pickerStyle(.menu)
            .disabled(isSaving)
            .accessibilityIdentifier("conversation-work-kind-picker")

            Text(ConversationPlanEditorPolicy.description(for: selectedWorkKind))
                .harvisFont(.caption2)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if selectedWorkKind == .task {
                taskPicker
            }
        }
        .padding(12)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
    }

    @ViewBuilder
    private var taskPicker: some View {
        if !taskPlan.isAuthoritative {
            Label(
                "项目任务清单当前不是 fresh、valid 的权威数据，不能建立任务绑定。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .harvisFont(.caption)
            .foregroundColor(.orange)
        } else if openTasks.isEmpty {
            Label("项目没有可绑定的未结束任务。", systemImage: "checkmark.circle")
                .harvisFont(.caption)
                .foregroundColor(theme.muted)
        } else {
            Picker("项目任务", selection: $selectedTaskID) {
                Text("选择一个未结束任务").tag("")
                ForEach(openTasks, id: \.taskID) { task in
                    Text("\(task.taskID) · \(task.title)")
                        .tag(task.taskID)
                }
            }
            .pickerStyle(.menu)
            .disabled(isSaving)
            .accessibilityIdentifier("conversation-project-task-picker")
        }
    }

    @ViewBuilder
    private var currentBinding: some View {
        if let currentExtension {
            VStack(alignment: .leading, spacing: 4) {
                Text("当前显式关系")
                    .harvisFont(.caption.bold())
                    .foregroundColor(theme.muted)
                Text(
                    ManagedConversationPlanPresentation(
                        alignment: .unknown,
                        workKind: currentExtension.workKind,
                        taskIDs: currentExtension.taskBindings.map(\.taskID)
                    ).bindingLabel
                )
                .harvisFont(.caption.monospaced())
                .foregroundColor(theme.text)
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var errorNotice: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .harvisFont(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("清除分类与绑定") {
                performClear()
            }
            .buttonStyle(.borderless)
            .foregroundColor(theme.muted)
            .disabled(isSaving || !brainEnabled || currentExtension == nil)

            Spacer()

            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button("保存") { performSave() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("conversation-plan-save")
        }
    }

    private func performSave() {
        let workKind = selectedWorkKind
        let taskID = ConversationPlanEditorPolicy.taskIDForPersistence(
            workKind: workKind,
            selectedTaskID: selectedTaskID
        )
        isSaving = true
        errorMessage = nil
        Task {
            do {
                if workKind == .unclassified {
                    try await onClear()
                } else {
                    try await onSave(
                        workKind,
                        taskID,
                        ConversationPlanEditorPolicy.includeForDispatch(
                            workKind: workKind
                        )
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func performClear() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onClear()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
