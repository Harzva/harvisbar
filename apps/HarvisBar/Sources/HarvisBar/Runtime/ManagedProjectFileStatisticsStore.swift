import Combine
import Foundation

typealias ManagedProjectFileStatisticsProcessRunner = @Sendable (
    _ executableURL: URL,
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> BoundedProcessResult

enum ManagedProjectFileInspector {
    static let defaultIgnoredDirectoryNames: Set<String> = [
        ".build",
        ".cache",
        ".git",
        ".gradle",
        ".next",
        ".swiftpm",
        ".venv",
        "DerivedData",
        "Pods",
        "__pycache__",
        "build",
        "dist",
        "node_modules",
        "venv",
    ]

    static func inspect(
        path: String,
        maximumEntries: Int = 250_000,
        maximumDuration: TimeInterval = 5,
        ignoredDirectoryNames: Set<String> = defaultIgnoredDirectoryNames,
        fileManager: FileManager = .default,
        now: @Sendable () -> Date = Date.init
    ) throws -> ManagedProjectFileStatistics {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ManagedProjectFileStatisticsError.projectNotDirectory(path)
        }

        let startedAt = now()
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]

        var folderCount = 0
        var fileCount = 0
        var symbolicLinkCount = 0
        var totalBytes: Int64 = 0
        var excludedDirectoryCount = 0
        var unreadableEntryCount = 0
        var scannedEntryCount = 0
        var isTruncated = false

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                unreadableEntryCount += 1
                return true
            }
        ) else {
            throw ManagedProjectFileStatisticsError.projectNotDirectory(path)
        }

        for case let url as URL in enumerator {
            if Task.isCancelled {
                isTruncated = true
                break
            }
            if scannedEntryCount >= maximumEntries
                || now().timeIntervalSince(startedAt) >= maximumDuration {
                isTruncated = true
                break
            }

            scannedEntryCount += 1
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    symbolicLinkCount += 1
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values.isDirectory == true {
                    if ignoredDirectoryNames.contains(url.lastPathComponent) {
                        excludedDirectoryCount += 1
                        enumerator.skipDescendants()
                    } else {
                        folderCount += 1
                    }
                } else if values.isRegularFile == true {
                    fileCount += 1
                    totalBytes += Int64(max(values.fileSize ?? 0, 0))
                }
            } catch {
                unreadableEntryCount += 1
            }
        }

        return ManagedProjectFileStatistics(
            projectPath: root.path,
            folderCount: folderCount,
            fileCount: fileCount,
            symbolicLinkCount: symbolicLinkCount,
            totalBytes: totalBytes,
            excludedDirectoryCount: excludedDirectoryCount,
            unreadableEntryCount: unreadableEntryCount,
            scannedEntryCount: scannedEntryCount,
            isTruncated: isTruncated,
            scannedAt: now()
        )
    }
}

@MainActor
final class ManagedProjectFileStatisticsStore: ObservableObject {
    @Published private(set) var statistics: [String: ManagedProjectFileStatistics] = [:]
    @Published private(set) var scanningProjectIDs: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]

    private var refreshedAt: [String: Date] = [:]
    private let cacheLifetime: TimeInterval
    private let helperTimeout: TimeInterval
    private let helperExecutableURL: URL?
    private let processRunner: ManagedProjectFileStatisticsProcessRunner

    init(
        cacheLifetime: TimeInterval = 60,
        helperTimeout: TimeInterval = BoundedProcessRunner.defaultTimeout,
        helperExecutableURL: URL? = Bundle.main.executableURL,
        processRunner: @escaping ManagedProjectFileStatisticsProcessRunner = {
            executableURL,
            arguments,
            timeout in
            try await BoundedProcessRunner.run(
                executable: executableURL.path,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) {
        self.cacheLifetime = cacheLifetime
        self.helperTimeout = helperTimeout
        self.helperExecutableURL = helperExecutableURL
        self.processRunner = processRunner
    }

    func statistics(for project: ManagedChatProjectIdentity) -> ManagedProjectFileStatistics? {
        statistics[project.id]
    }

    func refresh(
        project: ManagedChatProjectIdentity,
        force: Bool = false
    ) async {
        guard let path = project.canonicalPath else {
            errors[project.id] = ManagedProjectFileStatisticsError
                .projectUnavailable.localizedDescription
            return
        }
        guard let helperExecutableURL else {
            errors[project.id] = ManagedProjectFileStatisticsError
                .helperExecutableUnavailable.localizedDescription
            return
        }

        let now = Date()
        if !force,
           let refreshed = refreshedAt[project.id],
           now.timeIntervalSince(refreshed) < cacheLifetime {
            return
        }
        guard scanningProjectIDs.insert(project.id).inserted else { return }
        defer { scanningProjectIDs.remove(project.id) }

        do {
            let result = try await processRunner(
                helperExecutableURL,
                [ManagedProjectFileStatisticsHelper.argument, path],
                helperTimeout
            )
            guard !Task.isCancelled else { return }
            guard result.terminationStatus == 0 else {
                throw ManagedProjectFileStatisticsError.helperFailed(
                    result.standardError
                )
            }
            let value = try ManagedProjectFileStatisticsHelper.decodeStatistics(
                from: Data(result.standardOutput.utf8)
            )
            guard !Task.isCancelled else { return }
            statistics[project.id] = value
            refreshedAt[project.id] = Date()
            errors.removeValue(forKey: project.id)
        } catch is CancellationError {
            return
        } catch let error as BoundedProcessRunnerError {
            if case .cancelled = error, Task.isCancelled {
                return
            }
            if case let .timedOut(_, timeout) = error {
                errors[project.id] = ManagedProjectFileStatisticsError
                    .scanTimedOut(timeout).localizedDescription
            } else {
                errors[project.id] = error.localizedDescription
            }
        } catch {
            guard !Task.isCancelled else { return }
            errors[project.id] = error.localizedDescription
        }
    }
}
