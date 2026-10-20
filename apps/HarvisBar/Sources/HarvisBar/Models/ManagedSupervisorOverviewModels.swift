import Foundation

enum ManagedSupervisorOverviewStatus: String, CaseIterable, Identifiable, Sendable {
    case active, attention, off, unread, unavailable, observation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "监督中"
        case .attention: return "待处理"
        case .off: return "已关闭"
        case .unread: return "待刷新"
        case .unavailable: return "未就绪"
        case .observation: return "项目管理 / 观察"
        }
    }
}

enum ManagedSupervisorIssueKind: Equatable, Sendable {
    case sessionUnloaded, unavailable, connection, requiresReview
}

struct ManagedSupervisorRefreshProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
}
