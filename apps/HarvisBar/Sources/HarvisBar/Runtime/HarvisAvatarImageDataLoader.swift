import Foundation

enum HarvisAvatarImageDataLoader {
    static func readHeapBackedData(from url: URL) throws -> Data {
        let source = try Data(contentsOf: url, options: [.uncached])
        // Force a byte copy before crossing back to MainActor. This prevents a
        // mapped file from faulting removable-volume pages during rendering.
        return source.withUnsafeBytes { Data($0) }
    }

    static func firstReadableData(
        candidatePaths: [String],
        readData: (URL) throws -> Data = {
            try readHeapBackedData(from: $0)
        }
    ) -> Data? {
        for path in candidatePaths where !path.isEmpty {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard let data = try? readData(url), !data.isEmpty else { continue }
            return data
        }
        return nil
    }
}

/// Coalesces avatar reads across the menu-bar popover and desktop rail.
///
/// A detached read cannot reliably be cancelled while a filesystem is stalled.
/// Keeping one task per candidate set prevents repeated popover openings from
/// accumulating blocked reads while still keeping all path I/O off the main
/// actor.
actor HarvisAvatarImageLoadCache {
    private var load: Task<Data?, Never>?

    func data(
        candidatePaths: [String],
        readData: @escaping @Sendable (URL) throws -> Data = {
            try HarvisAvatarImageDataLoader.readHeapBackedData(from: $0)
        }
    ) async -> Data? {
        if let existing = load {
            return await existing.value
        }

        let load = Task.detached(priority: .utility) {
            HarvisAvatarImageDataLoader.firstReadableData(
                candidatePaths: candidatePaths,
                readData: readData
            )
        }
        self.load = load
        return await load.value
    }
}
