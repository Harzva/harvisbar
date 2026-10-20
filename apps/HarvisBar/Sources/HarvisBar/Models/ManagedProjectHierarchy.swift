import Foundation

/// A navigation projection over known paths and explicitly created projects.
/// It does not scan the disk, infer ownership, or turn source folders into repos.
struct ManagedProjectHierarchy {
    struct Node: Identifiable {
        let project: ManagedChatProjectIdentity
        var parentID: String?
        var purpose: String
        var isContainer: Bool
        var isLogicalProject: Bool
        var directThreads: [ManagedChatThread]
        var id: String { project.id }
    }

    let nodes: [Node]

    init(
        catalog: [ManagedChatProjectIdentity],
        records: [String: ManagedProjectRecord],
        threads: [ManagedChatThread]
    ) {
        var seenThreads = Set<String>()
        let grouped = Dictionary(grouping: threads.filter { seenThreads.insert($0.id).inserted }) {
            ManagedChatProjectResolver.resolve(thread: $0).id
        }
        // Preserve empty registered projects. Empty inferred paths stay visible
        // only when they have a descendant in the currently selected scope.
        var all = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, rhs in rhs })
        for record in records.values { all[record.id] = record.identity }
        let candidates = Array(all.values)
        var relevant = Set(grouped.keys).union(records.keys)
        for identity in candidates where !relevant.contains(identity.id) {
            if let path = identity.canonicalPath, candidates.contains(where: {
                relevant.contains($0.id)
                    && Self.isStrictAncestor(path, of: $0.canonicalPath)
            }) {
                relevant.insert(identity.id)
            }
        }
        for record in records.values {
            var parent = record.parentID
            var visited = Set<String>()
            while let id = parent, visited.insert(id).inserted {
                relevant.insert(id)
                parent = records[id]?.parentID
            }
        }
        var result = candidates.filter { relevant.contains($0.id) }.map { project in
            let record = records[project.id]
            return Node(
                project: project,
                parentID: record?.parentID,
                purpose: record?.purpose ?? "",
                isContainer: project.id.hasPrefix("container::"),
                isLogicalProject: record != nil,
                directThreads: grouped[project.id] ?? []
            )
        }
        for index in result.indices where result[index].parentID == nil {
            let current = result[index]
            guard let path = current.project.canonicalPath else { continue }
            let ancestor = result.filter {
                $0.id != current.id
                    && !$0.isLogicalProject
                    && Self.isStrictAncestor($0.project.canonicalPath, of: path)
            }.max {
                ($0.project.canonicalPath?.count ?? 0) < ($1.project.canonicalPath?.count ?? 0)
            }
            result[index].parentID = ancestor?.id
        }

        // Add just the immediate shared parent of sibling roots. Do not build
        // meaningless /Volumes or /Users chains above the working roots.
        let rootsByParent = Dictionary(grouping: result.filter { $0.parentID == nil }) {
            $0.project.canonicalPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        }
        for (path, children) in rootsByParent.sorted(by: { $0.key < $1.key }) {
            guard children.count > 1,
                  path.split(separator: "/").count >= 3,
                  !result.contains(where: { $0.project.canonicalPath == path }) else { continue }
            let id = "container::\(path)"
            let identity = ManagedChatProjectIdentity(
                id: id,
                canonicalPath: path,
                displayPath: path,
                label: (path as NSString).lastPathComponent,
                resolution: children.contains { $0.project.resolution == .resolved } ? .resolved : .unresolved
            )
            result.append(Node(
                project: identity, parentID: nil, purpose: "", isContainer: true,
                isLogicalProject: false, directThreads: []
            ))
            let childIDs = Set(children.map(\.id))
            for index in result.indices where childIDs.contains(result[index].id) {
                result[index].parentID = id
            }
        }
        let identifiers = Set(result.map(\.id))
        for index in result.indices {
            if let parent = result[index].parentID, !identifiers.contains(parent) {
                // A temporarily missing parent must not hide an existing project.
                result[index].parentID = nil
            }
            result[index].isContainer = result[index].isContainer
                || (!result[index].isLogicalProject && result.contains { $0.parentID == result[index].id })
        }
        nodes = result.sorted {
            let comparison = $0.project.label.localizedStandardCompare($1.project.label)
            return comparison == .orderedAscending || (comparison == .orderedSame && $0.id < $1.id)
        }
    }

    func children(of id: String?) -> [Node] { nodes.filter { $0.parentID == id } }

    func node(_ id: String?) -> Node? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    func breadcrumb(to id: String?) -> [Node] {
        var chain: [Node] = []
        var cursor = id
        var visited = Set<String>()
        while let current = node(cursor), visited.insert(current.id).inserted {
            chain.append(current)
            cursor = current.parentID
        }
        return chain.reversed()
    }

    func descendantIDs(of id: String) -> Set<String> {
        var result: Set<String> = [id]
        var pending = [id]
        while let parent = pending.popLast() {
            for child in children(of: parent) where result.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return result
    }

    func threads(includingDescendantsOf id: String) -> [ManagedChatThread] {
        let descendants = descendantIDs(of: id)
        var seen = Set<String>()
        return nodes.filter { descendants.contains($0.id) }
            .flatMap(\.directThreads).filter { seen.insert($0.id).inserted }
    }

    static func participantCount(_ threads: [ManagedChatThread]) -> Int {
        Set(threads.map {
            // Only count an agent separately when the source exposes an identity.
            // Otherwise the visible statistic is a distinct source/account count.
            [$0.provider.rawValue, $0.sourceScope, $0.agentPath ?? $0.agentNickname ?? ""].joined(separator: "::")
        }).count
    }

    private static func isStrictAncestor(_ ancestor: String?, of path: String?) -> Bool {
        guard let ancestor, let path, ancestor != path else { return false }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}
