import SwiftUI

enum ManagedConversationPlanTone: String, Equatable, Sendable {
    case positive
    case informational
    case neutral
    case warning
    case critical
}

/// Pure UI projection for a conversation's explicit project-plan metadata.
///
/// This value never infers a task or work kind from chat text, titles, tags,
/// roles, or runtime activity. Until the management store supplies an exact
/// record, `.unavailable` keeps the UI visibly fail-closed.
struct ManagedConversationPlanPresentation: Equatable, Sendable {
    let alignment: ConversationPlanAlignmentV1
    let workKind: ConversationWorkKindV1?
    let taskIDs: [String]
    let metadataAvailable: Bool

    static let unavailable = ManagedConversationPlanPresentation(
        alignment: .unknown,
        workKind: nil,
        taskIDs: [],
        metadataAvailable: false
    )

    init(
        alignment: ConversationPlanAlignmentV1,
        workKind: ConversationWorkKindV1?,
        taskIDs: [String],
        metadataAvailable: Bool = true
    ) {
        self.alignment = alignment
        self.workKind = workKind
        self.taskIDs = taskIDs
        self.metadataAvailable = metadataAvailable
    }

    var title: String {
        switch alignment {
        case .onPlan: return "计划内"
        case .exempt: return "计划豁免"
        case .outOfPlan: return "偏离计划"
        case .unknown: return "计划未知"
        case .conflict: return "计划冲突"
        }
    }

    var systemImage: String {
        switch alignment {
        case .onPlan: return "checkmark.circle.fill"
        case .exempt: return "arrow.triangle.branch"
        case .outOfPlan: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        case .conflict: return "xmark.octagon.fill"
        }
    }

    var tone: ManagedConversationPlanTone {
        switch alignment {
        case .onPlan: return .positive
        case .exempt: return .informational
        case .outOfPlan: return .warning
        case .unknown: return .neutral
        case .conflict: return .critical
        }
    }

    var workKindLabel: String {
        guard metadataAvailable, let workKind else { return "管理数据未接入" }
        switch workKind {
        case .unclassified: return "未分类"
        case .task: return "任务"
        case .exploration: return "探索"
        case .operations: return "运维"
        case .knowledge: return "知识"
        case .management: return "管理"
        }
    }

    var bindingLabel: String {
        guard metadataAvailable else { return "未验证任务绑定" }
        guard workKind == .task else { return workKindLabel }
        guard let first = taskIDs.first else {
            return "任务 · 未绑定"
        }
        if taskIDs.count == 1 {
            return "任务 · \(first)"
        }
        return "任务 · \(first) +\(taskIDs.count - 1)"
    }

    var helpText: String {
        var components = [title, "工作类型：\(workKindLabel)"]
        if metadataAvailable, workKind == .task {
            components.append(
                taskIDs.isEmpty
                    ? "尚未显式绑定任务"
                    : "任务绑定：\(taskIDs.joined(separator: ", "))"
            )
        }
        components.append("该状态由显式任务关系派生；不会根据标题、标签或提示词猜测。")
        return components.joined(separator: " · ")
    }
}

enum ManagedConversationPlanPresentationPolicy {
    static func make(
        alignment: ConversationPlanAlignmentV1,
        managementExtension: ConversationManagementExtensionV1?
    ) -> ManagedConversationPlanPresentation {
        guard let managementExtension else {
            return ManagedConversationPlanPresentation(
                alignment: alignment,
                workKind: nil,
                taskIDs: [],
                metadataAvailable: false
            )
        }
        return ManagedConversationPlanPresentation(
            alignment: alignment,
            workKind: managementExtension.workKind,
            taskIDs: managementExtension.taskBindings.map(\.taskID),
            metadataAvailable: true
        )
    }
}

struct ManagedConversationPlanBadge: View {
    let presentation: ManagedConversationPlanPresentation
    let theme: HarvisTheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.systemImage)
            Text(presentation.title)
                .fontWeight(.bold)
            Text("·")
                .foregroundColor(theme.muted)
            Text(presentation.bindingLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .harvisFont(.system(size: 9))
        .foregroundColor(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(color.opacity(0.28))
        )
        .help(presentation.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.title)，\(presentation.bindingLabel)")
    }

    var color: Color {
        switch presentation.tone {
        case .positive: return theme.positive
        case .informational: return theme.accent
        case .neutral: return theme.muted
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
