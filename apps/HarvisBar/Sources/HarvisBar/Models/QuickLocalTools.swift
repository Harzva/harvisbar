import Foundation

struct QuickCredentialMetadata: Equatable {
    let provider: String
    let envVariable: String
    let sourcePath: String
    let keywords: [String]

    static func parse(key: String, keywords: String) throws -> QuickCredentialMetadata {
        let rawKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else {
            throw QuickLocalToolError.invalidCredentialKey
        }

        let isPath = rawKey.hasPrefix("/") || rawKey.hasPrefix("~")
        let sourcePath = isPath ? (rawKey as NSString).expandingTildeInPath : ""
        let providerSeed: String
        let envVariable: String

        if isPath {
            let fileName = URL(fileURLWithPath: sourcePath)
                .deletingPathExtension()
                .lastPathComponent
            providerSeed = fileName
            envVariable = environmentVariable(from: fileName)
        } else {
            envVariable = environmentVariable(from: rawKey)
            providerSeed = rawKey
                .replacingOccurrences(of: "_API_KEY", with: "", options: [.caseInsensitive])
                .replacingOccurrences(of: "_KEY", with: "", options: [.caseInsensitive])
        }

        let provider = slug(providerSeed)
        guard !provider.isEmpty else {
            throw QuickLocalToolError.invalidCredentialKey
        }
        return QuickCredentialMetadata(
            provider: provider,
            envVariable: envVariable,
            sourcePath: sourcePath,
            keywords: splitKeywords(keywords)
        )
    }

    private static func environmentVariable(from value: String) -> String {
        let normalized = value.uppercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar))
                ? Character(String(scalar))
                : "_"
        }
        var result = String(normalized)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty {
            result = "HARVIS"
        }
        if result.first?.isNumber == true {
            result = "KEY_\(result)"
        }
        if !["_KEY", "_SECRET", "_TOKEN", "_PASSWORD"].contains(where: { result.hasSuffix($0) }) {
            result += "_API_KEY"
        }
        return result
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        var result = ""
        var previousWasDash = false
        for scalar in lowered.unicodeScalars {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash, !result.isEmpty {
                result.append("-")
                previousWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "local-key" : trimmed
    }

    private static func splitKeywords(_ value: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，;；\n")
        var seen = Set<String>()
        return value
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { keyword in
                guard !keyword.isEmpty else { return false }
                return seen.insert(keyword.lowercased()).inserted
            }
    }
}

struct QuickCredentialAgentHint: Equatable {
    let registryPath: String
    let reference: String
    let envVariable: String
    let keywords: [String]

    init(
        savedResponse: QuickCredentialSaveResponse,
        fallbackMetadata: QuickCredentialMetadata,
        registryPath: String
    ) throws {
        guard savedResponse.available == true,
              savedResponse.secretIncluded == false,
              let savedReference = savedResponse.reference?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              Self.isSafeReference(savedReference) else {
            throw QuickLocalToolError.unsafeCredentialResponse
        }
        self.registryPath = registryPath
        reference = savedReference
        envVariable = savedResponse.envVariable ?? fallbackMetadata.envVariable
        keywords = savedResponse.keywords ?? fallbackMetadata.keywords
    }

    var text: String {
        var lines = ["Harvis credential handoff: v1"]
        lines.append("Harvis reference: \(reference)")
        lines.append("Environment variable: \(envVariable)")
        if !keywords.isEmpty {
            lines.append("Keywords: \(keywords.joined(separator: ", "))")
        }
        lines.append("Local execution only: resolve through Harvis and inject into the required child command.")
        lines.append("Do not read source files, export, print, paste, or log the plaintext secret.")
        return lines.joined(separator: "\n")
    }

    private static func isSafeReference(_ value: String) -> Bool {
        let prefix = "harvis-credential://"
        guard value.hasPrefix(prefix) else { return false }
        let identifier = value.dropFirst(prefix.count)
        return !identifier.isEmpty && identifier.allSatisfy { character in
            character.isASCII
                && (character.isLowercase || character.isNumber || character == "-")
        }
    }
}

struct QuickCredentialSaveResponse: Decodable {
    let id: String?
    let reference: String?
    let available: Bool?
    let secretIncluded: Bool?
    let sourcePath: String?
    let keywords: [String]?
    let envVariable: String?

    enum CodingKeys: String, CodingKey {
        case id
        case reference
        case available
        case secretIncluded = "secret_included"
        case sourcePath = "source_path"
        case keywords
        case envVariable = "env_var"
    }
}

struct LocalCopySummary: Sendable {
    let copiedCount: Int
    let destination: String
}

enum QuickLocalToolError: LocalizedError, Equatable {
    case invalidCredentialKey
    case emptyCredentialValue
    case credentialServiceUnavailable
    case unsafeCredentialResponse
    case clipboardUnavailable
    case credentialJSONMissing
    case textEditorUnavailable
    case destinationUnavailable
    case noDroppedFiles
    case recursiveDirectoryCopy

    var errorDescription: String? {
        switch self {
        case .invalidCredentialKey:
            return "请填写 KEY 名称。"
        case .emptyCredentialValue:
            return "请填写 Value。"
        case .credentialServiceUnavailable:
            return "密钥未写入：本地 HTTP 服务未启用安全令牌，请重启 HTTP 服务后重试。"
        case .unsafeCredentialResponse:
            return "服务未确认安全引用，已禁止复制。"
        case .clipboardUnavailable:
            return "无法写入剪贴板。"
        case .credentialJSONMissing:
            return "本地 credentials.json 尚未创建，请先保存一个密钥。"
        case .textEditorUnavailable:
            return "找不到 macOS 文本编辑应用。"
        case .destinationUnavailable:
            return "目标目录不存在或不可写。"
        case .noDroppedFiles:
            return "没有可复制的文件。"
        case .recursiveDirectoryCopy:
            return "不能把文件夹复制到它自身内部。"
        }
    }
}

enum LocalFileCopy {
    static func copy(_ sources: [URL], to destination: URL) throws -> LocalCopySummary {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: destination.path) else {
            throw QuickLocalToolError.destinationUnavailable
        }

        let uniqueSources = Array(Set(sources.map(\.standardizedFileURL)))
        guard !uniqueSources.isEmpty else {
            throw QuickLocalToolError.noDroppedFiles
        }

        var copiedCount = 0
        for source in uniqueSources {
            var sourceIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else {
                continue
            }
            if sourceIsDirectory.boolValue {
                let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
                if destination.path == source.path || destination.path.hasPrefix(sourcePrefix) {
                    throw QuickLocalToolError.recursiveDirectoryCopy
                }
            }

            let target = availableTarget(
                for: source,
                in: destination,
                isDirectory: sourceIsDirectory.boolValue,
                fileManager: fileManager
            )
            try fileManager.copyItem(at: source, to: target)
            copiedCount += 1
        }
        return LocalCopySummary(copiedCount: copiedCount, destination: destination.path)
    }

    static func availableTarget(
        for source: URL,
        in destination: URL,
        isDirectory: Bool,
        fileManager: FileManager = .default
    ) -> URL {
        let original = destination.appendingPathComponent(
            source.lastPathComponent,
            isDirectory: isDirectory
        )
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let extensionName = isDirectory ? "" : source.pathExtension
        let stem = extensionName.isEmpty
            ? source.lastPathComponent
            : source.deletingPathExtension().lastPathComponent
        for index in 2...10_000 {
            let name = extensionName.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionName)"
            let candidate = destination.appendingPathComponent(name, isDirectory: isDirectory)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return destination.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
    }
}
