import Foundation

struct ManagedProjectFileStatistics: Codable, Equatable, Sendable {
    let projectPath: String
    let folderCount: Int
    let fileCount: Int
    let symbolicLinkCount: Int
    let totalBytes: Int64
    let excludedDirectoryCount: Int
    let unreadableEntryCount: Int
    let scannedEntryCount: Int
    let isTruncated: Bool
    let scannedAt: Date

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: totalBytes,
            countStyle: .file
        )
    }
}

enum ManagedProjectFileStatisticsError: LocalizedError, Equatable {
    case projectUnavailable
    case projectNotDirectory(String)
    case helperExecutableUnavailable
    case helperFailed(String)
    case invalidHelperResponse(String)
    case scanTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .projectUnavailable:
            return "项目目录不可用。"
        case let .projectNotDirectory(path):
            return "项目路径不是可读取的文件夹：\(path)"
        case .helperExecutableUnavailable:
            return "HarvisBar 内部项目统计程序不可用。"
        case let .helperFailed(message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "项目文件统计失败。"
                : "项目文件统计失败：\(detail)"
        case let .invalidHelperResponse(message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "项目文件统计返回了无效结果。"
                : "项目文件统计返回了无效结果：\(detail)"
        case let .scanTimedOut(timeout):
            return "项目文件统计超过 \(Self.formatted(timeout)) 秒，已停止并回收统计进程。请检查 HarvisBar 的文件访问权限后重试。"
        }
    }

    private static func formatted(_ value: TimeInterval) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}
