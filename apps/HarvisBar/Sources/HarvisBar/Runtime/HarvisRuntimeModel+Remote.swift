import Foundation

extension HarvisRuntimeModel {
    func refreshRemoteStudio(force: Bool = false) async {
        let now = Date()
        if !force,
           let lastRemoteStudioRefreshAt,
           now.timeIntervalSince(lastRemoteStudioRefreshAt) < 5
        {
            return
        }
        lastRemoteStudioRefreshAt = now

        do {
            remoteStudio = try await fetch(
                "/remote/metrics",
                query: [URLQueryItem(name: "remote", value: "studio")],
                as: RemoteStudioMetrics.self
            )
        } catch {
            remoteStudio = nil
        }
    }
}
