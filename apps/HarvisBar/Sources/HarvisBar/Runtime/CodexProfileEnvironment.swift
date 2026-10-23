import CryptoKit
import Foundation

enum CodexProfileEnvironmentPolicy: Sendable {
    /// Existing provider integrations may intentionally use an env_key.
    case inherited
    /// A group member selected a ChatGPT login in its own CODEX_HOME.
    case chatGPTProfile

    func environment(homePath: String, parent: [String: String]) -> [String: String] {
        var environment = parent
        if self == .chatGPTProfile {
            for key in environment.keys {
                let name = key.uppercased()
                if name.hasPrefix("OPENAI_") || name.hasPrefix("ANTHROPIC_")
                    || name.hasSuffix("_API_KEY") || name.hasSuffix("_API_TOKEN")
                    || ["CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CHATGPT_BASE_URL"].contains(name) {
                    environment.removeValue(forKey: key)
                }
            }
        }
        environment["CODEX_HOME"] = homePath
        return environment
    }

    /// Tokens rotate normally. Compare stable login/workspace claims and
    /// configuration instead of the raw token bytes so refresh is harmless.
    func fingerprint(homePath: String) -> String? {
        guard self == .chatGPTProfile else { return nil }
        let root = URL(fileURLWithPath: homePath, isDirectory: true)
        let configuration = (try? Data(contentsOf: root.appendingPathComponent("config.toml"))) ?? Data()
        let authData = (try? Data(contentsOf: root.appendingPathComponent("auth.json"))) ?? Data()
        var identity = "missing"
        if let auth = (try? JSONSerialization.jsonObject(with: authData)) as? [String: Any] {
            let tokens = auth["tokens"] as? [String: Any] ?? [:]
            var fields = [auth["auth_mode"] as? String ?? "", tokens["account_id"] as? String ?? ""]
            if let token = tokens["id_token"] as? String,
               let payload = Self.claims(token) {
                let account = payload["https://api.openai.com/auth"] as? [String: Any] ?? [:]
                fields += [payload["sub"] as? String ?? "", payload["email"] as? String ?? "",
                           account["chatgpt_account_id"] as? String ?? ""]
            }
            identity = fields.joined(separator: "\n")
        } else if !authData.isEmpty {
            identity = Self.digest(authData)
        }
        return Self.digest(configuration + Data(identity.utf8))
    }

    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
