import Foundation

/// Bounded, short-lived memoization for repeated render-time path checks.
/// No lock is held during filesystem work. Explicit/custom resolvers bypass it.
final class ManagedProjectPathCache: @unchecked Sendable {
    static let shared = ManagedProjectPathCache()
    private let lock = NSLock()
    private var entries: [String: (value: ManagedChatProjectIdentity, createdAt: TimeInterval)] = [:]
    private let capacity: Int
    private let lifetime: TimeInterval

    init(capacity: Int = 1024, lifetime: TimeInterval = 5) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }

    func value(for path: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ManagedChatProjectIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path] else { return nil }
        guard now - entry.createdAt < lifetime else {
            entries.removeValue(forKey: path)
            return nil
        }
        return entry.value
    }

    func insert(_ value: ManagedChatProjectIdentity, for path: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        if entries[path] == nil && entries.count >= capacity {
            entries = entries.filter { now - $0.value.createdAt < lifetime }
            if entries.count >= capacity,
               let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
        entries[path] = (value, now)
    }
}

struct ManagedInsightCatalogSnapshot {
    let createdAt: TimeInterval
    let projects: [ManagedChatProjectIdentity]
    let candidates: [ManagedConversationProjectCandidate]
    let candidateMap: [String: ManagedChatProjectIdentity]
}
