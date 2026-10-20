import Foundation

/// DSH exposes exact-session hash links; never open the instance root and
/// silently leave the user in whichever conversation the browser last selected.
enum ManagedChatOpenTarget {
    static func dshSessionURL(sessionID: String, sourceScope: String, endpoints: [DshRuntimeEndpoint]) -> URL? {
        let matches = endpoints.filter { $0.sourceScope == sourceScope && (1...65535).contains($0.port) }
        guard !sessionID.isEmpty, !sourceScope.isEmpty, Set(matches.map(\.port)).count == 1,
              let endpoint = matches.first else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let id = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "http://127.0.0.1:\(endpoint.port)/#/session/\(id)")
    }
}
