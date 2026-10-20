import Foundation

public enum PerAppProxyContractError: Error, Equatable, Sendable {
    case nonLoopbackProxyHost(String)
    case invalidProxyPort(Int)
    case emptyDisplayName
    case emptySigningIdentifier
    case invalidCodeDirectoryHash
    case duplicateRuleID(UUID)
}

public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) throws {
        let normalizedHost = Self.normalize(host)
        guard Self.loopbackHosts.contains(normalizedHost) else {
            throw PerAppProxyContractError.nonLoopbackProxyHost(host)
        }
        guard (1...65_535).contains(port) else {
            throw PerAppProxyContractError.invalidProxyPort(port)
        }

        self.host = normalizedHost
        self.port = port
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    private static func normalize(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

public struct AppCodeIdentity: Codable, Equatable, Sendable {
    public let displayName: String
    public let signingIdentifier: String
    public let codeDirectoryHash: [UInt8]

    public init(
        displayName: String,
        signingIdentifier: String,
        codeDirectoryHashHex: String
    ) throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIdentifier = signingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw PerAppProxyContractError.emptyDisplayName
        }
        guard !trimmedIdentifier.isEmpty else {
            throw PerAppProxyContractError.emptySigningIdentifier
        }
        guard let decodedHash = Self.decodeHex(codeDirectoryHashHex), !decodedHash.isEmpty else {
            throw PerAppProxyContractError.invalidCodeDirectoryHash
        }

        self.displayName = trimmedName
        self.signingIdentifier = trimmedIdentifier
        self.codeDirectoryHash = decodedHash
    }

    public var codeDirectoryHashHex: String {
        codeDirectoryHash.map { String(format: "%02x", $0) }.joined()
    }

    public func matches(_ flow: SourceApplicationIdentity) -> Bool {
        signingIdentifier == flow.signingIdentifier
            && Self.constantTimeEqual(codeDirectoryHash, flow.codeDirectoryHash)
    }

    private static func decodeHex(_ value: String) -> [UInt8]? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        guard !normalized.isEmpty, normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var result: [UInt8] = []
        result.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt(lhs.count ^ rhs.count)
        let comparedCount = max(lhs.count, rhs.count)
        for index in 0..<comparedCount {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= UInt(left ^ right)
        }
        return difference == 0
    }
}

public struct SourceApplicationIdentity: Equatable, Sendable {
    public let signingIdentifier: String
    public let codeDirectoryHash: [UInt8]

    public init(signingIdentifier: String, codeDirectoryHash: [UInt8]) {
        self.signingIdentifier = signingIdentifier
        self.codeDirectoryHash = codeDirectoryHash
    }
}

public struct PerAppProxyRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var isEnabled: Bool
    public var application: AppCodeIdentity

    public init(id: UUID = UUID(), isEnabled: Bool = true, application: AppCodeIdentity) {
        self.id = id
        self.isEnabled = isEnabled
        self.application = application
    }
}

public struct PerAppProxyConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var endpoint: ProxyEndpoint
    public var rules: [PerAppProxyRule]

    public init(
        isEnabled: Bool = false,
        endpoint: ProxyEndpoint,
        rules: [PerAppProxyRule] = []
    ) throws {
        var seenIDs = Set<UUID>()
        for rule in rules where !seenIDs.insert(rule.id).inserted {
            throw PerAppProxyContractError.duplicateRuleID(rule.id)
        }

        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.rules = rules
    }

    public func matchingRule(for flow: SourceApplicationIdentity) -> PerAppProxyRule? {
        guard isEnabled else { return nil }
        return rules.first { $0.isEnabled && $0.application.matches(flow) }
    }
}
