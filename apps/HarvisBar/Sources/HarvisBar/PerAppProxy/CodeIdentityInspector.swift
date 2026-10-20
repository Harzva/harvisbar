import Foundation
import HarvisProxyCore
import Security

enum CodeIdentityInspectorError: Error, LocalizedError {
    case executableNotFound(URL)
    case unsignedCode(URL)
    case missingSigningIdentifier(URL)
    case missingCodeDirectoryHash(URL)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(url): return "找不到可执行文件：\(url.lastPathComponent)"
        case let .unsignedCode(url): return "应用没有可验证的代码签名：\(url.lastPathComponent)"
        case let .missingSigningIdentifier(url): return "代码签名缺少 Signing Identifier：\(url.lastPathComponent)"
        case let .missingCodeDirectoryHash(url): return "代码签名缺少 Code Directory Hash：\(url.lastPathComponent)"
        }
    }
}

struct CodeIdentityInspector {
    func inspect(_ selectedURL: URL) throws -> AppCodeIdentity {
        let executableURL = try resolveExecutable(selectedURL)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw CodeIdentityInspectorError.unsignedCode(executableURL)
        }

        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard copyStatus == errSecSuccess,
              let values = information as? [String: Any]
        else {
            throw CodeIdentityInspectorError.unsignedCode(executableURL)
        }
        guard let signingIdentifier = values[kSecCodeInfoIdentifier as String] as? String,
              !signingIdentifier.isEmpty
        else {
            throw CodeIdentityInspectorError.missingSigningIdentifier(executableURL)
        }
        guard let unique = values[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else {
            throw CodeIdentityInspectorError.missingCodeDirectoryHash(executableURL)
        }

        let displayName: String
        if selectedURL.pathExtension.lowercased() == "app" {
            displayName = Bundle(url: selectedURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle(url: selectedURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? selectedURL.deletingPathExtension().lastPathComponent
        } else {
            displayName = selectedURL.lastPathComponent
        }

        return try AppCodeIdentity(
            displayName: displayName,
            signingIdentifier: signingIdentifier,
            codeDirectoryHashHex: unique.map { String(format: "%02x", $0) }.joined()
        )
    }

    func locateCommand(named name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard !name.contains("/") else { return nil }
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackDirectories = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        var visited = Set<String>()
        for directory in pathDirectories + fallbackDirectories where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    private func resolveExecutable(_ selectedURL: URL) throws -> URL {
        if selectedURL.pathExtension.lowercased() == "app",
           let executableURL = Bundle(url: selectedURL)?.executableURL {
            return executableURL
        }
        guard FileManager.default.isExecutableFile(atPath: selectedURL.path) else {
            throw CodeIdentityInspectorError.executableNotFound(selectedURL)
        }
        return selectedURL.resolvingSymlinksInPath()
    }
}
