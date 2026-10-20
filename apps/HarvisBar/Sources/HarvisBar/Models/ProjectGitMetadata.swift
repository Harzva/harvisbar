import Combine
import Foundation
import HarvisVersionCore

struct ProjectGitSummary: Equatable, Sendable {
    let projectPath: String
    let repositoryRoot: String?
    let branch: String?
    let isDetached: Bool
    let changedFileCount: Int
    let localBranches: [String]
    let remoteBranches: [String]
    let remotes: [String]
    let worktreeCount: Int

    var isRepository: Bool { repositoryRoot != nil }
    var isDirty: Bool { changedFileCount > 0 }
}

private struct ProjectGitInspectionResult: Sendable {
    let path: String
    let summary: ProjectGitSummary
}

@MainActor
final class ProjectGitMetadataStore: ObservableObject {
    @Published private(set) var summaries: [String: ProjectGitSummary] = [:]
    @Published private(set) var refreshingPaths: Set<String> = []

    private var refreshedAt: [String: Date] = [:]
    private let cacheLifetime: TimeInterval

    init(cacheLifetime: TimeInterval = 60) {
        self.cacheLifetime = cacheLifetime
    }

    func summary(for path: String) -> ProjectGitSummary? {
        summaries[path]
    }

    func refresh(paths: [String], force: Bool = false) async {
        let now = Date()
        let requested = Array(Set(paths))
            .filter { !$0.isEmpty }
            .filter { path in
                force || refreshedAt[path].map { now.timeIntervalSince($0) >= cacheLifetime } != false
            }
            .filter { !refreshingPaths.contains($0) }
            .sorted()
        guard !requested.isEmpty else { return }

        refreshingPaths.formUnion(requested)
        let results = await Task.detached(priority: .utility) {
            requested.map { path in
                ProjectGitInspectionResult(
                    path: path,
                    summary: ProjectGitInspector.inspect(path: path)
                )
            }
        }.value

        for result in results {
            summaries[result.path] = result.summary
            refreshedAt[result.path] = Date()
            refreshingPaths.remove(result.path)
        }
    }
}

enum ProjectGitInspector {
    static let defaultInspectionTimeout = HarvisGenericGitInspector.defaultInspectionTimeout

    static func inspect(
        path: String,
        timeout: TimeInterval = defaultInspectionTimeout,
        gitExecutable: String = "/usr/bin/git",
        gitArgumentPrefix: [String] = []
    ) -> ProjectGitSummary {
        let inspected = HarvisGenericGitInspector().inspect(
            path: path,
            timeout: timeout,
            gitExecutable: gitExecutable,
            gitArgumentPrefix: gitArgumentPrefix
        )
        return ProjectGitSummary(
            projectPath: path,
            repositoryRoot: inspected.repositoryRoot,
            branch: inspected.branch,
            isDetached: inspected.isDetached,
            changedFileCount: inspected.changedFileCount,
            localBranches: inspected.localBranches,
            remoteBranches: inspected.remoteBranches,
            remotes: inspected.remotes,
            worktreeCount: inspected.worktreeCount
        )
    }
}
