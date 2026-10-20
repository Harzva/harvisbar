import CryptoKit
import Darwin
import Foundation

public struct HarvisVersionCommandExecutor {
    private let operation: (HarvisVersionProcessRequest) async throws -> HarvisVersionProcessDataResult

    public init(operation: @escaping (HarvisVersionProcessRequest) async throws -> HarvisVersionProcessDataResult) {
        self.operation = operation
    }

    public init(runner: HarvisVersionProcessRunner = HarvisVersionProcessRunner()) {
        operation = { request in try await runner.run(request) }
    }

    public func run(_ request: HarvisVersionProcessRequest) async throws -> HarvisVersionProcessDataResult {
        try await operation(request)
    }
}

public struct HarvisVersionFileReader {
    private let operation: (String, Int, Bool) throws -> HarvisBoundedFileRead

    public init(operation: @escaping (String, Int, Bool) throws -> HarvisBoundedFileRead) {
        self.operation = operation
    }

    public init(reader: HarvisBoundedFileReader = HarvisBoundedFileReader()) {
        operation = { path, maximumBytes, requireNonEmpty in
            try reader.readFile(
                atCanonicalAbsolutePath: path,
                maximumBytes: maximumBytes,
                requireNonEmpty: requireNonEmpty
            )
        }
    }

    public func read(_ path: String, maximumBytes: Int, requireNonEmpty: Bool = true) throws -> HarvisBoundedFileRead {
        try operation(path, maximumBytes, requireNonEmpty)
    }
}

public struct HarvisBundleReceiptReader {
    public static let schemaVersion = "harvis.app-bundle-receipt.v1"
    public static let receiptBasename = "harvis-bundle-receipt.json"

    private let files: HarvisVersionFileReader

    public init(files: HarvisVersionFileReader = HarvisVersionFileReader()) {
        self.files = files
    }

    public func inspect(resourcesDirectory: String, appIdentity: HarvisAppIdentity) -> HarvisBundleReceiptInspection {
        guard let resources = Self.lexicallyStandardizedAbsolutePath(resourcesDirectory) else {
            return HarvisBundleReceiptInspection(status: .invalidContract)
        }
        let path = resources + "/" + Self.receiptBasename
        let raw: HarvisBoundedFileRead
        do {
            raw = try files.read(path, maximumBytes: 1_048_576)
        } catch let error as HarvisBoundedFileReaderError {
            return HarvisBundleReceiptInspection(status: Self.map(error))
        } catch {
            return HarvisBundleReceiptInspection(status: .ioFailure)
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: raw.data)
        } catch {
            return HarvisBundleReceiptInspection(status: .invalidJSON)
        }
        guard
            let dictionary = object as? [String: Any],
            let schema = dictionary["schemaVersion"] as? String
        else {
            return HarvisBundleReceiptInspection(status: .invalidContract)
        }
        guard schema == Self.schemaVersion else {
            return HarvisBundleReceiptInspection(status: .unsupportedSchema)
        }

        let value: RawReceipt
        do {
            value = try JSONDecoder().decode(RawReceipt.self, from: raw.data)
        } catch {
            return HarvisBundleReceiptInspection(status: .invalidContract)
        }
        guard let receipt = Self.validate(value, appIdentity: appIdentity) else {
            return HarvisBundleReceiptInspection(status: .invalidContract)
        }
        return HarvisBundleReceiptInspection(status: .valid, receipt: receipt)
    }

    private static func validate(_ value: RawReceipt, appIdentity: HarvisAppIdentity) -> HarvisBundleReceiptSummary? {
        guard
            value.schemaVersion == schemaVersion,
            value.pluginRootMarker == "HarvisPlugin",
            value.app.bundleIdentifier == "local.harzva.harvisbar",
            value.app.executable == "HarvisBar",
            value.app.variant == "bar",
            value.app.version == appIdentity.version,
            value.app.bundleIdentifier == appIdentity.bundleIdentifier,
            value.app.executable == appIdentity.executable,
            isVersion(value.app.version),
            isSHA(value.artifacts.runtimeSha256),
            isSHA(value.artifacts.appUnsignedSha256),
            isSHA(value.artifacts.systemExtensionUnsignedSha256),
            isSHA(value.appRuntimeAllowlist.sha256),
            value.appRuntimeAllowlist.relativePath == "packaging/app-runtime-allowlist-v1.txt",
            value.payload.digestAlgorithm == "sha256(path\\0mode\\0size\\0sha256\\0\\n)",
            value.payload.digestScope == "all files under HarvisPlugin",
            value.payload.fileCount > 0,
            isSHA(value.payload.sha256),
            isSHA(value.provenance.sha256),
            isSHA(value.provenance.stagedPayloadSha256),
            isObjectID(value.provenance.sourceCommit),
            isObjectID(value.provenance.sourceTree),
            isCacheKey(value.provenance.cacheKey),
            value.systemExtension.bundleIdentifier == "com.harzva.harvisbar.per-app-proxy",
            value.systemExtension.bundleName == "HarvisPerAppProxyExtension.systemextension",
            value.systemExtension.executable == "HarvisPerAppProxyExtension",
            value.systemExtension.version == value.app.version,
            value.artifacts.records.count == 3
        else { return nil }

        let expected: [String: (String, String)] = [
            "harvis-runtime": ("bin/harvis", value.artifacts.runtimeSha256),
            "harvisbar-main": ("artifacts/HarvisBar", value.artifacts.appUnsignedSha256),
            "harvis-system-extension": ("artifacts/HarvisPerAppProxyExtension", value.artifacts.systemExtensionUnsignedSha256),
        ]
        var roles = Set<String>()
        for record in value.artifacts.records {
            guard
                roles.insert(record.role).inserted,
                let pair = expected[record.role],
                record.relativePath == pair.0,
                record.sha256 == pair.1,
                record.mode == "0755",
                record.sizeBytes > 0,
                isSHA(record.sha256)
            else { return nil }
        }
        guard roles == Set(expected.keys) else { return nil }

        let app = HarvisAppIdentity(
            bundleIdentifier: value.app.bundleIdentifier,
            executable: value.app.executable,
            version: value.app.version
        )
        return HarvisBundleReceiptSummary(
            schemaVersion: value.schemaVersion,
            pluginRootMarker: value.pluginRootMarker,
            app: app,
            artifacts: HarvisReceiptArtifacts(
                runtimeSha256: value.artifacts.runtimeSha256,
                appUnsignedSha256: value.artifacts.appUnsignedSha256,
                systemExtensionUnsignedSha256: value.artifacts.systemExtensionUnsignedSha256,
                records: value.artifacts.records.map {
                    HarvisReceiptArtifactRecord(
                        role: $0.role,
                        relativePath: $0.relativePath,
                        mode: $0.mode,
                        sizeBytes: $0.sizeBytes,
                        sha256: $0.sha256
                    )
                }
            ),
            provenance: HarvisReceiptProvenance(
                cacheKey: value.provenance.cacheKey,
                sha256: value.provenance.sha256,
                sourceCommit: value.provenance.sourceCommit,
                sourceTree: value.provenance.sourceTree,
                stagedPayloadSha256: value.provenance.stagedPayloadSha256
            ),
            payload: HarvisReceiptPayload(
                digestAlgorithm: value.payload.digestAlgorithm,
                digestScope: value.payload.digestScope,
                fileCount: value.payload.fileCount,
                sha256: value.payload.sha256
            ),
            appRuntimeAllowlist: HarvisReceiptAllowlist(
                relativePath: value.appRuntimeAllowlist.relativePath,
                sha256: value.appRuntimeAllowlist.sha256
            ),
            systemExtension: HarvisReceiptSystemExtension(
                bundleIdentifier: value.systemExtension.bundleIdentifier,
                bundleName: value.systemExtension.bundleName,
                executable: value.systemExtension.executable,
                version: value.systemExtension.version
            )
        )
    }

    private static func isSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(components.count)
            && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isCacheKey(_ value: String) -> Bool {
        guard value.hasPrefix("personal/harvis/"), let separator = value.range(of: "+codex.p2-") else { return false }
        let version = value[value.index(value.startIndex, offsetBy: 16)..<separator.lowerBound]
        let digest = String(value[separator.upperBound...])
        guard let first = version.utf8.first else { return false }
        let validFirst = (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first)
        let validRest = version.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45
        }
        return validFirst && validRest && isSHA(digest)
    }

    private static func lexicallyStandardizedAbsolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/"), value != "/", !value.contains("\0"), !value.hasSuffix("/") else { return nil }
        let components = value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return value
    }

    private static func map(_ error: HarvisBoundedFileReaderError) -> HarvisBundleReceiptStatus {
        switch error {
        case .invalidPath: return .invalidContract
        case .missing: return .missing
        case .symlink: return .symlink
        case .notRegular: return .notRegular
        case .empty: return .empty
        case .tooLarge: return .tooLarge
        case .unreadable: return .unreadable
        case .ioFailure: return .ioFailure
        case .changedDuringRead: return .changedDuringRead
        }
    }
}

private struct RawReceipt: Decodable {
    let schemaVersion: String
    let pluginRootMarker: String
    let app: RawApp
    let artifacts: RawArtifacts
    let provenance: RawProvenance
    let payload: RawPayload
    let appRuntimeAllowlist: RawAllowlist
    let systemExtension: RawSystemExtension

    struct RawApp: Decodable { let bundleIdentifier: String; let executable: String; let variant: String; let version: String }
    struct RawArtifacts: Decodable { let runtimeSha256: String; let appUnsignedSha256: String; let systemExtensionUnsignedSha256: String; let records: [RawRecord] }
    struct RawRecord: Decodable { let role: String; let relativePath: String; let mode: String; let sizeBytes: UInt64; let sha256: String }
    struct RawProvenance: Decodable { let cacheKey: String; let sha256: String; let sourceCommit: String; let sourceTree: String; let stagedPayloadSha256: String }
    struct RawPayload: Decodable { let digestAlgorithm: String; let digestScope: String; let fileCount: UInt64; let sha256: String }
    struct RawAllowlist: Decodable { let relativePath: String; let sha256: String }
    struct RawSystemExtension: Decodable { let bundleIdentifier: String; let bundleName: String; let executable: String; let version: String }
}

public enum HarvisGitParseError: Error, Equatable, Sendable {
    case malformed
}

public enum HarvisGitParsers {
    public static func changedEntryCount(status data: Data) throws -> Int {
        let records = try nulRecords(data, allowTerminalEmpty: false)
        var index = 0
        var count = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 4, record[2] == 0x20 else { throw HarvisGitParseError.malformed }
            let x = record[0]
            let y = record[1]
            guard validStatusPair(x, y), !record[3...].isEmpty else { throw HarvisGitParseError.malformed }
            count += 1
            index += 1
            if x == 0x52 || x == 0x43 || y == 0x52 || y == 0x43 {
                guard index < records.count, !records[index].isEmpty else { throw HarvisGitParseError.malformed }
                index += 1
            }
        }
        return count
    }

    public static func markerMembership(_ data: Data) throws {
        let expected: [(String, String)] = [
            ("Cargo.toml", "100644"),
            ("apps/HarvisBar/Package.swift", "100644"),
            ("schemas/bar-status.schema.json", "100644"),
            ("scripts/harvis", "100755"),
        ]
        let records = try nulRecords(data, allowTerminalEmpty: false)
        guard records.count == expected.count else { throw HarvisGitParseError.malformed }
        for (record, item) in zip(records, expected) {
            guard let tab = record.firstIndex(of: 0x09) else { throw HarvisGitParseError.malformed }
            let metadata = record[..<tab]
            let pathBytes = record[record.index(after: tab)...]
            guard
                let metadataString = String(data: metadata, encoding: .ascii),
                let path = String(data: pathBytes, encoding: .utf8),
                path == item.0
            else { throw HarvisGitParseError.malformed }
            let parts = metadataString.split(separator: " ", omittingEmptySubsequences: false)
            guard
                parts.count == 3,
                parts[0] == Substring(item.1),
                (parts[1].utf8.count == 40 || parts[1].utf8.count == 64),
                parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                parts[1].contains(where: { $0 != "0" }),
                parts[2] == "0"
            else { throw HarvisGitParseError.malformed }
        }
    }

    public static func worktrees(_ data: Data) throws -> [HarvisGitWorktreeSummary] {
        guard !data.isEmpty, data.last == 0 else { throw HarvisGitParseError.malformed }
        let bytes = [UInt8](data)
        var records: [[Data]] = []
        var current: [Data] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0 {
            let field = Data(bytes[start..<index])
            start = index + 1
            if field.isEmpty {
                guard !current.isEmpty else { throw HarvisGitParseError.malformed }
                records.append(current)
                current = []
            } else {
                current.append(field)
            }
        }
        guard start == bytes.count, current.isEmpty, !records.isEmpty else { throw HarvisGitParseError.malformed }
        return try records.map(parseWorktreeRecord)
    }

    public static func remoteNames(_ data: Data) throws -> [String] {
        guard !data.isEmpty else { return [] }
        guard data.last == 0x0A else { throw HarvisGitParseError.malformed }
        guard let string = String(data: data, encoding: .ascii), !string.contains("\r"), !string.contains("\0") else {
            throw HarvisGitParseError.malformed
        }
        let names = string.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !names.contains(where: { $0.isEmpty }), Set(names).count == names.count, names.allSatisfy(validRemoteName) else {
            throw HarvisGitParseError.malformed
        }
        return names
    }

    public static func githubBrowseURL(from rawRemote: String) -> String? {
        guard
            !rawRemote.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
            !rawRemote.contains("%"),
            let components = URLComponents(string: rawRemote),
            components.scheme == "https",
            components.host == "github.com",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.query == nil,
            components.fragment == nil
        else { return nil }
        let rawPath = components.percentEncodedPath
        guard rawPath.hasPrefix("/"), !rawPath.hasSuffix("/") else { return nil }
        let pieces = rawPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let owner = String(pieces[0])
        var repository = String(pieces[1])
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        guard validOwner(owner), validRepository(repository) else { return nil }
        return "https://github.com/\(owner)/\(repository)"
    }

    public static func terminalLine(_ data: Data, allowInteriorLineFeed: Bool = false) throws -> String {
        guard data.count >= 2, data.last == 0x0A else { throw HarvisGitParseError.malformed }
        let payload = data.dropLast()
        guard !payload.isEmpty, !payload.contains(0), !payload.contains(0x0D), allowInteriorLineFeed || !payload.contains(0x0A) else {
            throw HarvisGitParseError.malformed
        }
        guard let value = String(data: payload, encoding: .utf8) else { throw HarvisGitParseError.malformed }
        return value
    }

    public static func objectIDLine(_ data: Data) throws -> String {
        let value = try terminalLine(data)
        guard isObjectID(value), value.contains(where: { $0 != "0" }) else { throw HarvisGitParseError.malformed }
        return value
    }

    public static func aheadBehind(_ data: Data) throws -> (ahead: UInt64, behind: UInt64) {
        guard let string = String(data: data, encoding: .ascii), string.hasSuffix("\n"), !string.dropLast().contains("\n") else {
            throw HarvisGitParseError.malformed
        }
        let fields = string.dropLast().split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2, let ahead = UInt64(fields[0]), let behind = UInt64(fields[1]) else {
            throw HarvisGitParseError.malformed
        }
        return (ahead, behind)
    }

    private static func nulRecords(_ data: Data, allowTerminalEmpty: Bool) throws -> [Data] {
        guard !data.isEmpty else { return [] }
        guard data.last == 0 else { throw HarvisGitParseError.malformed }
        var records: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            let record = data[start..<index]
            if record.isEmpty && !allowTerminalEmpty { throw HarvisGitParseError.malformed }
            records.append(Data(record))
            start = data.index(after: index)
        }
        guard start == data.endIndex else { throw HarvisGitParseError.malformed }
        return records
    }

    private static func validStatusPair(_ x: UInt8, _ y: UInt8) -> Bool {
        if x == 0x3f && y == 0x3f { return true }
        if x == 0x21 && y == 0x21 { return false }
        let allowed = Set(" MTADRCU".utf8)
        return allowed.contains(x) && allowed.contains(y) && !(x == 0x20 && y == 0x20)
    }

    private static func parseWorktreeRecord(_ fields: [Data]) throws -> HarvisGitWorktreeSummary {
        guard let first = fields.first, let firstString = String(data: first, encoding: .utf8), firstString.hasPrefix("worktree ") else {
            throw HarvisGitParseError.malformed
        }
        let path = String(firstString.dropFirst(9))
        guard validAbsoluteWorktreePath(path), fields.count >= 2 else { throw HarvisGitParseError.malformed }
        var index = 1
        var state: HarvisGitWorktreeHeadState
        var head: String?
        var branch: String?
        let headField = try strictUTF8(fields[index])
        if headField == "bare" {
            state = .bare
            index += 1
        } else if headField.hasPrefix("HEAD ") {
            let oid = String(headField.dropFirst(5))
            guard isObjectID(oid) else { throw HarvisGitParseError.malformed }
            index += 1
            guard index < fields.count else { throw HarvisGitParseError.malformed }
            let form = try strictUTF8(fields[index])
            if form == "detached" {
                guard oid.contains(where: { $0 != "0" }) else { throw HarvisGitParseError.malformed }
                state = .detached
                head = oid
            } else if form.hasPrefix("branch ") {
                let ref = String(form.dropFirst(7))
                guard !ref.isEmpty, !ref.contains("\n"), !ref.contains("\r") else { throw HarvisGitParseError.malformed }
                branch = ref
                if oid.allSatisfy({ $0 == "0" }) {
                    state = .unborn
                } else {
                    state = .attached
                    head = oid
                }
            } else {
                throw HarvisGitParseError.malformed
            }
            index += 1
        } else {
            throw HarvisGitParseError.malformed
        }

        var locked: String?
        var prunable: String?
        while index < fields.count {
            let field = try strictUTF8(fields[index])
            if field == "locked" || field.hasPrefix("locked ") {
                guard locked == nil else { throw HarvisGitParseError.malformed }
                locked = field == "locked" ? "" : String(field.dropFirst(7))
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                guard prunable == nil else { throw HarvisGitParseError.malformed }
                prunable = field == "prunable" ? "" : String(field.dropFirst(9))
            } else {
                throw HarvisGitParseError.malformed
            }
            index += 1
        }
        return HarvisGitWorktreeSummary(
            path: path,
            headState: state,
            headCommit: head,
            branch: branch,
            lockedReason: locked,
            prunableReason: prunable
        )
    }

    private static func strictUTF8(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else { throw HarvisGitParseError.malformed }
        return value
    }

    private static func validAbsoluteWorktreePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.contains("\0") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func validRemoteName(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count), let first = value.utf8.first else { return false }
        let alphanumeric: (UInt8) -> Bool = { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        return alphanumeric(first) && value.utf8.allSatisfy { alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    private static func validOwner(_ value: String) -> Bool {
        guard (1...39).contains(value.utf8.count), let first = value.utf8.first, let last = value.utf8.last else { return false }
        let alphanumeric: (UInt8) -> Bool = { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        return alphanumeric(first) && alphanumeric(last) && value.utf8.allSatisfy { alphanumeric($0) || $0 == 45 }
    }

    private static func validRepository(_ value: String) -> Bool {
        guard (1...100).contains(value.utf8.count), value != ".", value != "..", let first = value.utf8.first else { return false }
        let alphanumeric: (UInt8) -> Bool = { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        return alphanumeric(first) && value.utf8.allSatisfy { alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum HarvisVersionAlignmentResolver {
    public static func resolve(_ evidence: HarvisAlignmentEvidence) -> HarvisVersionAlignment {
        guard let source = evidence.sourceCommit, let receipt = evidence.receiptCommit else { return .unknown }
        if source == receipt { return .exact }
        guard evidence.receiptObject != .unavailable else { return .unknown }
        if evidence.receiptObject == .negative { return .missingCommit }
        if evidence.receiptIsAncestorOfSource == .positive { return .sourceAhead }
        if evidence.sourceIsAncestorOfReceipt == .positive { return .installedAhead }
        guard
            evidence.receiptIsAncestorOfSource == .negative,
            evidence.sourceIsAncestorOfReceipt == .negative,
            evidence.sourceIsShallow == false
        else { return .unknown }
        return .diverged
    }
}

public struct HarvisStableHelperInspector {
    private let files: HarvisVersionFileReader

    public init(files: HarvisVersionFileReader = HarvisVersionFileReader()) {
        self.files = files
    }

    public func inspect(homeDirectory: String, receipt: HarvisBundleReceiptInspection) -> HarvisStableHelperSummary {
        guard let home = standardizedHome(homeDirectory) else {
            return HarvisStableHelperSummary(
                httpLaunchBindingStatus: .programPathMismatch,
                tickLaunchBindingStatus: .programPathMismatch,
                helperFileStatus: .missing,
                receiptMatchStatus: .notEvaluated,
                sizeBytes: nil,
                sha256: nil
            )
        }
        let expectedHelper = home + "/.harvis/bin/harvis"
        let http = launchBinding(
            path: home + "/Library/LaunchAgents/local.harzva.harvis.http.plist",
            expectedLabel: "local.harzva.harvis.http",
            expectedHelper: expectedHelper
        )
        let tick = launchBinding(
            path: home + "/Library/LaunchAgents/local.harzva.harvis.tick.plist",
            expectedLabel: "local.harzva.harvis.tick",
            expectedHelper: expectedHelper
        )

        let helperRead: HarvisBoundedFileRead
        do {
            helperRead = try files.read(expectedHelper, maximumBytes: 134_217_728)
        } catch let error as HarvisBoundedFileReaderError {
            return HarvisStableHelperSummary(
                httpLaunchBindingStatus: http,
                tickLaunchBindingStatus: tick,
                helperFileStatus: mapFile(error),
                receiptMatchStatus: .notEvaluated,
                sizeBytes: nil,
                sha256: nil
            )
        } catch {
            return HarvisStableHelperSummary(
                httpLaunchBindingStatus: http,
                tickLaunchBindingStatus: tick,
                helperFileStatus: .ioFailure,
                receiptMatchStatus: .notEvaluated,
                sizeBytes: nil,
                sha256: nil
            )
        }
        guard helperRead.fileIdentity.isUserExecutable else {
            return HarvisStableHelperSummary(
                httpLaunchBindingStatus: http,
                tickLaunchBindingStatus: tick,
                helperFileStatus: .notExecutable,
                receiptMatchStatus: .notEvaluated,
                sizeBytes: nil,
                sha256: nil
            )
        }
        let digest = SHA256.hash(data: helperRead.data).map { String(format: "%02x", $0) }.joined()
        let receiptMatch: HarvisHelperReceiptMatchStatus
        if receipt.status != .valid || receipt.receipt == nil {
            receiptMatch = .receiptUnavailable
        } else if let record = receipt.receipt?.artifacts.runtimeRecord {
            if record.sizeBytes != helperRead.fileIdentity.size {
                receiptMatch = .sizeMismatch
            } else if record.sha256 != digest {
                receiptMatch = .hashMismatch
            } else {
                receiptMatch = .matched
            }
        } else {
            receiptMatch = .receiptUnavailable
        }
        return HarvisStableHelperSummary(
            httpLaunchBindingStatus: http,
            tickLaunchBindingStatus: tick,
            helperFileStatus: .valid,
            receiptMatchStatus: receiptMatch,
            sizeBytes: helperRead.fileIdentity.size,
            sha256: digest
        )
    }

    private func launchBinding(path: String, expectedLabel: String, expectedHelper: String) -> HarvisLaunchBindingStatus {
        let read: HarvisBoundedFileRead
        do {
            read = try files.read(path, maximumBytes: 1_048_576)
        } catch let error as HarvisBoundedFileReaderError {
            return mapBinding(error)
        } catch {
            return .ioFailure
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: read.data, options: [], format: nil)
        } catch {
            return .invalidPlist
        }
        guard let dictionary = plist as? [String: Any] else { return .invalidPlist }
        guard dictionary["Label"] as? String == expectedLabel else { return .labelMismatch }
        guard dictionary["Program"] == nil else { return .programPathMismatch }
        guard
            let arguments = dictionary["ProgramArguments"] as? [String],
            let first = arguments.first,
            first == expectedHelper,
            isLexicallyCanonicalAbsolute(first)
        else { return .programPathMismatch }
        return .valid
    }

    private func isLexicallyCanonicalAbsolute(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", !value.contains("\0"), !value.hasSuffix("/") else { return false }
        return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func standardizedHome(_ value: String) -> String? {
        guard value.hasPrefix("/"), value != "/", !value.contains("\0"), !value.hasSuffix("/") else { return nil }
        let components = value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return value
    }

    private func mapBinding(_ error: HarvisBoundedFileReaderError) -> HarvisLaunchBindingStatus {
        switch error {
        case .invalidPath: return .invalidPlist
        case .missing: return .missing
        case .symlink: return .symlink
        case .notRegular: return .notRegular
        case .empty: return .empty
        case .tooLarge: return .tooLarge
        case .unreadable: return .unreadable
        case .ioFailure: return .ioFailure
        case .changedDuringRead: return .changedDuringRead
        }
    }

    private func mapFile(_ error: HarvisBoundedFileReaderError) -> HarvisHelperFileStatus {
        switch error {
        case .invalidPath: return .missing
        case .missing: return .missing
        case .symlink: return .symlink
        case .notRegular: return .notRegular
        case .empty: return .empty
        case .tooLarge: return .tooLarge
        case .unreadable: return .unreadable
        case .ioFailure: return .ioFailure
        case .changedDuringRead: return .changedDuringRead
        }
    }
}

public struct HarvisSourceInspector {
    public static let inspectionTimeout: TimeInterval = 5

    private let commands: HarvisVersionCommandExecutor
    private let files: HarvisVersionFileReader

    public init(
        commands: HarvisVersionCommandExecutor = HarvisVersionCommandExecutor(),
        files: HarvisVersionFileReader = HarvisVersionFileReader()
    ) {
        self.commands = commands
        self.files = files
    }

    public func inspect(
        selectedDirectory: String?,
        appPluginRoot: String? = nil,
        receiptCommit: String? = nil
    ) async -> HarvisSourceInspection {
        guard let selectedDirectory, !selectedDirectory.isEmpty else {
            return HarvisSourceInspection(status: .unbound, selectedPath: nil)
        }
        // Pure lexical validation must precede every syscall. `realpath`,
        // `lstat`, and `openat` can all wait on a removable-volume TCC
        // decision, so none of them may run before the killable child probe.
        guard Self.isLexicallyCanonicalAbsolutePath(selectedDirectory) else {
            return HarvisSourceInspection(status: .offline, selectedPath: selectedDirectory)
        }
        let budget = RefreshBudget(timeout: Self.inspectionTimeout)
        do {
            try await preflight(selected: selectedDirectory, budget: budget)
        } catch let failure as SourceFailure {
            return HarvisSourceInspection(status: failure.status, selectedPath: selectedDirectory)
        } catch {
            return HarvisSourceInspection(status: .invalid, selectedPath: selectedDirectory)
        }
        guard let selected = Self.canonicalDirectory(selectedDirectory) else {
            return HarvisSourceInspection(status: .offline, selectedPath: selectedDirectory)
        }
        let selectedChain: DirectoryChainEvidence
        do {
            selectedChain = try Self.captureDirectoryChain(selected)
        } catch let failure as SourceFailure {
            return HarvisSourceInspection(status: failure.status, selectedPath: selectedDirectory)
        } catch {
            return HarvisSourceInspection(status: .invalid, selectedPath: selectedDirectory)
        }
        let selectedFD = Darwin.open(selected, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard selectedFD >= 0 else {
            return HarvisSourceInspection(status: .offline, selectedPath: selectedDirectory)
        }
        defer { Darwin.close(selectedFD) }
        guard (try? Self.fileDescriptorIdentity(selectedFD)) == selectedChain.finalIdentity else {
            return HarvisSourceInspection(status: .invalid, selectedPath: selectedDirectory)
        }
        let rootCapture: GitCapture
        do {
            rootCapture = try await run(
                query: .showTopLevel,
                phase: .bootstrap,
                directoryFD: selectedFD,
                budget: budget,
                identity: nil
            )
        } catch let failure as SourceFailure {
            return HarvisSourceInspection(status: failure.status, selectedPath: selectedDirectory)
        } catch {
            return HarvisSourceInspection(status: .invalid, selectedPath: selectedDirectory)
        }
        guard rootCapture.status == 0, rootCapture.stderr.isEmpty,
              let rootRaw = try? HarvisGitParsers.terminalLine(rootCapture.stdout, allowInteriorLineFeed: true),
              let root = Self.canonicalDirectory(rootRaw),
              root == rootRaw,
              Self.isAncestor(root, of: selected)
        else {
            return HarvisSourceInspection(status: .notHarvis, selectedPath: selectedDirectory)
        }

        let rootChain: DirectoryChainEvidence
        do {
            rootChain = try Self.captureDirectoryChain(root)
            guard rootChain.isIdentityPrefix(of: selectedChain) else { throw SourceFailure.invalid }
        } catch let failure as SourceFailure {
            return HarvisSourceInspection(status: failure.status, selectedPath: selectedDirectory)
        } catch {
            return HarvisSourceInspection(status: .invalid, selectedPath: selectedDirectory)
        }
        if let appPluginRoot, let plugin = Self.canonicalDirectory(appPluginRoot), Self.isAncestor(plugin, of: root) {
            return HarvisSourceInspection(status: .bundlePayload, selectedPath: selectedDirectory)
        }
        let rootFD = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else {
            return HarvisSourceInspection(status: .offline, selectedPath: selectedDirectory)
        }
        defer { Darwin.close(rootFD) }
        guard (try? Self.fileDescriptorIdentity(rootFD)) == rootChain.finalIdentity else {
            return HarvisSourceInspection(status: .invalid, selectedPath: selectedDirectory)
        }

        let markerBefore: [MarkerEvidence]
        do {
            markerBefore = try markerEvidence(root: root)
        } catch let failure as SourceFailure {
            return HarvisSourceInspection(status: failure.status, selectedPath: selectedDirectory)
        } catch {
            return HarvisSourceInspection(status: .notHarvis, selectedPath: selectedDirectory)
        }
        do {
            let identity = try await captureRepositoryIdentity(
                selectedChain: selectedChain,
                rootChain: rootChain,
                rootFD: rootFD,
                budget: budget
            )
            guard markerBefore == (try markerEvidence(root: root)) else { throw SourceFailure.invalid }

            let first = try await capturePass(
                rootFD: rootFD,
                root: root,
                budget: budget,
                identity: identity,
                membershipFailure: .notHarvis
            )
            try identity.validate(files: files)
            let second = try await capturePass(
                rootFD: rootFD,
                root: root,
                budget: budget,
                identity: identity,
                membershipFailure: .invalid
            )
            guard first.captures == second.captures else { throw SourceFailure.invalid }
            let alignmentEvidence = await captureAlignment(
                source: first.summary,
                receiptCommit: receiptCommit,
                rootFD: rootFD,
                budget: budget,
                identity: identity
            )
            try identity.validate(files: files)
            let markerAfter = try markerEvidence(root: root)
            guard markerBefore == markerAfter else { throw SourceFailure.invalid }
            return HarvisSourceInspection(
                status: .ready,
                selectedPath: selectedDirectory,
                canonicalRepositoryRoot: root,
                git: first.summary,
                alignmentEvidence: alignmentEvidence
            )
        } catch let failure as SourceFailure {
            return HarvisSourceInspection(status: failure.status, selectedPath: selectedDirectory)
        } catch {
            return HarvisSourceInspection(status: .invalid, selectedPath: selectedDirectory)
        }
    }

    private func captureRepositoryIdentity(
        selectedChain: DirectoryChainEvidence,
        rootChain: DirectoryChainEvidence,
        rootFD: Int32,
        budget: RefreshBudget
    ) async throws -> RepositoryIdentityEvidence {
        try selectedChain.validate()
        try rootChain.validate()

        let topLevel = try await run(
            query: .showTopLevel,
            phase: .repository,
            directoryFD: rootFD,
            budget: budget,
            identity: nil
        )
        try Self.requireSuccess(topLevel)
        guard try HarvisGitParsers.terminalLine(topLevel.stdout, allowInteriorLineFeed: true) == rootChain.path else {
            throw SourceFailure.invalid
        }

        let gitMarker = try Self.captureGitMarker(root: rootChain.path, files: files)
        let gitDirectoryCapture = try await run(
            query: .absoluteGitDirectory,
            phase: .repository,
            directoryFD: rootFD,
            budget: budget,
            identity: nil
        )
        try Self.requireSuccess(gitDirectoryCapture)
        guard gitMarker.matches(try Self.captureGitMarker(root: rootChain.path, files: files)) else { throw SourceFailure.invalid }
        let gitDirectoryPath = try Self.canonicalPathLine(gitDirectoryCapture.stdout)
        guard gitDirectoryPath == gitMarker.expectedGitDirectoryPath else { throw SourceFailure.invalid }
        let gitDirectory = try Self.captureDirectoryChain(gitDirectoryPath)

        guard gitMarker.matches(try Self.captureGitMarker(root: rootChain.path, files: files)),
              gitDirectory.matches(try Self.captureDirectoryChain(gitDirectoryPath))
        else { throw SourceFailure.invalid }
        let commonDirectoryCapture = try await run(
            query: .commonGitDirectory,
            phase: .repository,
            directoryFD: rootFD,
            budget: budget,
            identity: nil
        )
        try Self.requireSuccess(commonDirectoryCapture)
        let commonDirectoryPath = try Self.canonicalPathLine(commonDirectoryCapture.stdout)
        let commonDirectory = try Self.captureDirectoryChain(commonDirectoryPath)

        let identity = RepositoryIdentityEvidence(
            selected: selectedChain,
            root: rootChain,
            gitMarker: gitMarker,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory
        )
        try identity.validate(files: files)

        for (query, expected) in [
            (HarvisGitQuery.showTopLevel, rootChain.path),
            (.absoluteGitDirectory, gitDirectoryPath),
            (.commonGitDirectory, commonDirectoryPath),
        ] {
            let capture = try await run(
                query: query,
                phase: .repository,
                directoryFD: rootFD,
                budget: budget,
                identity: identity
            )
            try Self.requireSuccess(capture)
            guard try Self.canonicalPathLine(capture.stdout) == expected else { throw SourceFailure.invalid }
        }
        try identity.validate(files: files)
        return identity
    }

    private func capturePass(
        rootFD: Int32,
        root: String,
        budget: RefreshBudget,
        identity: RepositoryIdentityEvidence,
        membershipFailure: SourceFailure
    ) async throws -> GitPass {
        var captures: [GitCapture] = []
        func query(_ query: HarvisGitQuery) async throws -> GitCapture {
            let value = try await run(
                query: query,
                phase: .repository,
                directoryFD: rootFD,
                budget: budget,
                identity: identity
            )
            captures.append(value)
            return value
        }

        let config = try await query(.unsafeConfiguration)
        guard config.stderr.isEmpty else { throw SourceFailure.invalid }
        if config.status == 0 {
            guard !config.stdout.isEmpty, (try? Self.nonemptyNULTerminatedASCII(config.stdout)) != nil else {
                throw SourceFailure.invalid
            }
            throw SourceFailure.unsafeGitConfig
        }
        guard config.status == 1, config.stdout.isEmpty else { throw SourceFailure.invalid }

        let membership = try await query(.markerMembership)
        try Self.requireSuccess(membership)
        do {
            try HarvisGitParsers.markerMembership(membership.stdout)
        } catch {
            throw membershipFailure
        }

        let symbolic = try await query(.symbolicHead)
        let head = try await query(.headCommit)
        let headState: HarvisGitHeadState
        let branch: String?
        let headCommit: String?
        if symbolic.status == 0, symbolic.stderr.isEmpty, let value = try? HarvisGitParsers.terminalLine(symbolic.stdout) {
            branch = value
            if head.status == 0, head.stderr.isEmpty {
                headCommit = try HarvisGitParsers.objectIDLine(head.stdout)
                headState = .attached
            } else if head.status == 1, head.stdout.isEmpty, head.stderr.isEmpty {
                headCommit = nil
                headState = .unborn
            } else { throw SourceFailure.invalid }
        } else if symbolic.status == 1, symbolic.stdout.isEmpty, symbolic.stderr.isEmpty,
                  head.status == 0, head.stderr.isEmpty {
            branch = nil
            headCommit = try HarvisGitParsers.objectIDLine(head.stdout)
            headState = .detached
        } else { throw SourceFailure.invalid }

        let shallowCapture = try await query(.shallow)
        try Self.requireSuccess(shallowCapture)
        let isShallow: Bool
        if shallowCapture.stdout == Data("true\n".utf8) { isShallow = true }
        else if shallowCapture.stdout == Data("false\n".utf8) { isShallow = false }
        else { throw SourceFailure.invalid }

        let status = try await query(.status)
        try Self.requireSuccess(status)
        let changedCount = try HarvisGitParsers.changedEntryCount(status: status.stdout)

        let remoteCapture = try await query(.remoteNames)
        try Self.requireSuccess(remoteCapture)
        let remoteNames = try HarvisGitParsers.remoteNames(remoteCapture.stdout)
        var remotes: [HarvisGitRemoteSummary] = []
        for name in remoteNames {
            let capture = try await query(.remoteURL(name))
            try Self.requireSuccess(capture)
            let rawURL = try HarvisGitParsers.terminalLine(capture.stdout)
            remotes.append(HarvisGitRemoteSummary(name: name, githubBrowseURL: HarvisGitParsers.githubBrowseURL(from: rawURL)))
        }

        let worktreeCapture = try await query(.worktrees)
        try Self.requireSuccess(worktreeCapture)
        let worktrees = try HarvisGitParsers.worktrees(worktreeCapture.stdout)

        var upstream: String?
        var ahead: UInt64?
        var behind: UInt64?
        if headState != .unborn {
            let upstreamCapture = try await query(.upstreamName)
            if upstreamCapture.status == 0, upstreamCapture.stderr.isEmpty {
                upstream = try HarvisGitParsers.terminalLine(upstreamCapture.stdout)
                let upstreamOIDCapture = try await query(.upstreamCommit)
                try Self.requireSuccess(upstreamOIDCapture)
                let upstreamOID = try HarvisGitParsers.objectIDLine(upstreamOIDCapture.stdout)
                if !isShallow, let headCommit {
                    let countCapture = try await query(.aheadBehind(headCommit, upstreamOID))
                    try Self.requireSuccess(countCapture)
                    let counts = try HarvisGitParsers.aheadBehind(countCapture.stdout)
                    ahead = counts.ahead
                    behind = counts.behind
                }
            } else if upstreamCapture.status == 1, upstreamCapture.stdout.isEmpty, upstreamCapture.stderr.isEmpty {
                upstream = nil
            } else { throw SourceFailure.invalid }
        }

        let summary = HarvisSourceGitSummary(
            repositoryRoot: root,
            headState: headState,
            branch: branch,
            headCommit: headCommit,
            changedFileCount: changedCount,
            upstream: upstream,
            aheadCount: ahead,
            behindCount: behind,
            isShallow: isShallow,
            trackingSnapshotIncomplete: isShallow,
            observedAt: Date(),
            remotes: remotes,
            worktrees: worktrees
        )
        return GitPass(captures: captures, summary: summary)
    }

    private func captureAlignment(
        source: HarvisSourceGitSummary,
        receiptCommit: String?,
        rootFD: Int32,
        budget: RefreshBudget,
        identity: RepositoryIdentityEvidence
    ) async -> HarvisAlignmentEvidence {
        guard let sourceCommit = source.headCommit,
              let receiptCommit,
              Self.isObjectID(receiptCommit)
        else {
            return HarvisAlignmentEvidence(
                sourceCommit: source.headCommit,
                receiptCommit: nil,
                receiptObject: .unavailable,
                receiptIsAncestorOfSource: .unavailable,
                sourceIsAncestorOfReceipt: .unavailable,
                sourceIsShallow: source.isShallow
            )
        }
        if sourceCommit == receiptCommit {
            return HarvisAlignmentEvidence(
                sourceCommit: sourceCommit,
                receiptCommit: receiptCommit,
                receiptObject: .unavailable,
                receiptIsAncestorOfSource: .unavailable,
                sourceIsAncestorOfReceipt: .unavailable,
                sourceIsShallow: source.isShallow
            )
        }

        let object = await alignmentProof(
            .receiptObject(receiptCommit),
            kind: .object,
            rootFD: rootFD,
            budget: budget,
            identity: identity
        )
        guard object == .positive else {
            return HarvisAlignmentEvidence(
                sourceCommit: sourceCommit,
                receiptCommit: receiptCommit,
                receiptObject: object,
                receiptIsAncestorOfSource: .unavailable,
                sourceIsAncestorOfReceipt: .unavailable,
                sourceIsShallow: source.isShallow
            )
        }
        let installedAncestor = await alignmentProof(
            .ancestry(receiptCommit, sourceCommit),
            kind: .ancestry,
            rootFD: rootFD,
            budget: budget,
            identity: identity
        )
        let sourceAncestor: HarvisGitProof
        if installedAncestor == .negative {
            sourceAncestor = await alignmentProof(
                .ancestry(sourceCommit, receiptCommit),
                kind: .ancestry,
                rootFD: rootFD,
                budget: budget,
                identity: identity
            )
        } else {
            sourceAncestor = .unavailable
        }
        return HarvisAlignmentEvidence(
            sourceCommit: sourceCommit,
            receiptCommit: receiptCommit,
            receiptObject: object,
            receiptIsAncestorOfSource: installedAncestor,
            sourceIsAncestorOfReceipt: sourceAncestor,
            sourceIsShallow: source.isShallow
        )
    }

    private enum AlignmentProbeKind { case object, ancestry }

    private func alignmentProof(
        _ query: HarvisGitQuery,
        kind: AlignmentProbeKind,
        rootFD: Int32,
        budget: RefreshBudget,
        identity: RepositoryIdentityEvidence
    ) async -> HarvisGitProof {
        do {
            let first = try await run(
                query: query,
                phase: .repository,
                directoryFD: rootFD,
                budget: budget,
                identity: identity
            )
            let second = try await run(
                query: query,
                phase: .repository,
                directoryFD: rootFD,
                budget: budget,
                identity: identity
            )
            guard first == second else { return .unavailable }
            switch kind {
            case .object:
                if first.status == 0, first.stderr.isEmpty,
                   (try? HarvisGitParsers.objectIDLine(first.stdout)) != nil {
                    return .positive
                }
                if first.status == 1, first.stdout.isEmpty, first.stderr.isEmpty { return .negative }
            case .ancestry:
                if first.stdout.isEmpty, first.stderr.isEmpty {
                    if first.status == 0 { return .positive }
                    if first.status == 1 { return .negative }
                }
            }
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    private func preflight(selected: String, budget: RefreshBudget) async throws {
        // A trailing slash makes both probes operate on the resolved directory
        // while preserving the supported leaf-symlink alias contract.
        let probePath = selected + "/"
        let metadata = try await runPreflightProcess(
            executable: "/usr/bin/stat",
            arguments: ["-f", "%HT", "--", probePath],
            standardOutputLimit: 64,
            budget: budget
        )
        // Under the closed C locale, `%HT` has exactly one accepted value for
        // a directory. A permissive parse here would let malformed preflight
        // output authorize the in-process `openat` that this guard protects.
        guard metadata.standardOutput == Data("Directory\n".utf8) else {
            throw SourceFailure.offline
        }

        // `stat` proves the node type but removable-volume TCC can still allow
        // metadata while blocking directory enumeration. Force the directory
        // open in another killable child before any in-process realpath/lstat/
        // openat call. `find` emits at most one bounded, opaque path and empty
        // directories succeed without output; captured bytes are never logged
        // or projected into the inspector DTO.
        _ = try await runPreflightProcess(
            executable: "/usr/bin/find",
            arguments: [probePath, "-mindepth", "1", "-maxdepth", "1", "-print", "-quit"],
            standardOutputLimit: 4_096,
            budget: budget
        )
    }

    private func runPreflightProcess(
        executable: String,
        arguments: [String],
        standardOutputLimit: Int,
        budget: RefreshBudget
    ) async throws -> HarvisVersionProcessDataResult {
        guard let remaining = budget.remaining else { throw SourceFailure.gitTimeout }
        let result: HarvisVersionProcessDataResult
        do {
            result = try await commands.run(
                HarvisVersionProcessRequest(
                    executable: executable,
                    arguments: arguments,
                    environment: Self.preflightEnvironment,
                    timeout: remaining,
                    standardOutputLimit: standardOutputLimit,
                    standardErrorLimit: 4_096,
                    aggregateBytesBefore: budget.capturedBytes,
                    aggregateLimit: 4_194_304
                )
            )
        } catch let failure as SourceFailure {
            throw failure
        } catch let error as HarvisVersionProcessError {
            switch error {
            case .timedOut, .cancelled:
                throw SourceFailure.gitTimeout
            case .outputLimitExceeded:
                throw SourceFailure.gitOutputLimitExceeded
            default:
                throw SourceFailure.offline
            }
        } catch {
            throw SourceFailure.offline
        }
        budget.capturedBytes += result.capturedByteCount
        guard result.terminationStatus == 0 else {
            throw SourceFailure.offline
        }
        guard result.standardError.isEmpty else {
            throw SourceFailure.offline
        }
        return result
    }

    private func run(
        query: HarvisGitQuery,
        phase: GitQueryPhase,
        directoryFD: Int32,
        budget: RefreshBudget,
        identity: RepositoryIdentityEvidence?
    ) async throws -> GitCapture {
        if let identity { try identity.validate(files: files) }
        guard let remaining = budget.remaining else { throw SourceFailure.gitTimeout }
        do {
            let result = try await commands.run(HarvisVersionProcessRequest(
                executable: "/usr/bin/git",
                arguments: phase.prefix + query.tail,
                environment: Self.gitEnvironment,
                workingDirectoryFileDescriptor: directoryFD,
                timeout: remaining,
                standardOutputLimit: 1_048_576,
                standardErrorLimit: 1_048_576,
                aggregateBytesBefore: budget.capturedBytes,
                aggregateLimit: 4_194_304
            ))
            budget.capturedBytes += result.capturedByteCount
            if let identity { try identity.validate(files: files) }
            return GitCapture(query: query, status: result.terminationStatus, stdout: result.standardOutput, stderr: result.standardError)
        } catch let failure as SourceFailure {
            throw failure
        } catch let error as HarvisVersionProcessError {
            switch error {
            case .timedOut, .cancelled: throw SourceFailure.gitTimeout
            case .outputLimitExceeded: throw SourceFailure.gitOutputLimitExceeded
            default: throw SourceFailure.invalid
            }
        } catch {
            throw SourceFailure.invalid
        }
    }

    private func markerEvidence(root: String) throws -> [MarkerEvidence] {
        let markers: [(String, Bool)] = [
            ("Cargo.toml", false),
            ("apps/HarvisBar/Package.swift", false),
            ("schemas/bar-status.schema.json", false),
            ("scripts/harvis", true),
        ]
        return try markers.map { relative, executable in
            let read: HarvisBoundedFileRead
            do {
                read = try files.read(root + "/" + relative, maximumBytes: 1_048_576)
            } catch let error as HarvisBoundedFileReaderError {
                switch error {
                case .missing: throw SourceFailure.notHarvis
                default: throw SourceFailure.invalid
                }
            }
            guard read.fileIdentity.userID == getuid(), read.fileIdentity.linkCount == 1,
                  !executable || read.fileIdentity.isUserExecutable
            else { throw SourceFailure.invalid }
            return MarkerEvidence(
                relativePath: relative,
                fileIdentity: read.fileIdentity,
                directoryChain: read.directoryChain,
                digest: SHA256.hash(data: read.data).map { String(format: "%02x", $0) }.joined()
            )
        }
    }

    private static func requireSuccess(_ capture: GitCapture) throws {
        guard capture.status == 0, capture.stderr.isEmpty else { throw SourceFailure.invalid }
    }

    private static func nonemptyNULTerminatedASCII(_ data: Data) throws -> [String] {
        guard !data.isEmpty, data.last == 0, String(data: data, encoding: .ascii) != nil else { throw SourceFailure.invalid }
        let values = data.dropLast().split(separator: 0, omittingEmptySubsequences: false)
        guard !values.contains(where: { $0.isEmpty }) else { throw SourceFailure.invalid }
        return values.compactMap { String(data: $0, encoding: .ascii) }
    }

    private static func canonicalDirectory(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.contains("\0") else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(value, &buffer) != nil else { return nil }
        guard let terminator = buffer.firstIndex(of: 0) else { return nil }
        let canonical = String(decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var metadata = stat()
        let status = canonical.withCString { Darwin.lstat($0, &metadata) }
        guard status == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return canonical
    }

    private static func isLexicallyCanonicalAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", !value.contains("\0"), !value.hasSuffix("/") else {
            return false
        }
        return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        ancestor == path || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    fileprivate static func captureGitMarker(root: String, files: HarvisVersionFileReader) throws -> GitMarkerEvidence {
        let path = root + "/.git"
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            if Self.isOfflineErrno(errno) { throw SourceFailure.offline }
            throw SourceFailure.invalid
        }
        let kind = metadata.st_mode & S_IFMT
        if kind == S_IFDIR {
            let directory = try Self.captureDirectoryChain(path)
            return GitMarkerEvidence(
                kind: .directory,
                identity: directory.finalIdentity,
                parentChain: Array(directory.identities.dropLast()),
                contentDigest: nil,
                expectedGitDirectoryPath: path
            )
        }
        guard kind == S_IFREG else { throw SourceFailure.invalid }
        let read: HarvisBoundedFileRead
        do {
            read = try files.read(path, maximumBytes: 4_096)
        } catch let error as HarvisBoundedFileReaderError {
            if error == .missing { throw SourceFailure.offline }
            throw SourceFailure.invalid
        }
        guard read.fileIdentity.userID == getuid(), read.fileIdentity.linkCount == 1,
              let target = Self.gitFileTarget(read.data)
        else { throw SourceFailure.invalid }
        return GitMarkerEvidence(
            kind: .gitFile,
            identity: read.fileIdentity,
            parentChain: read.directoryChain,
            contentDigest: SHA256.hash(data: read.data).map { String(format: "%02x", $0) }.joined(),
            expectedGitDirectoryPath: target
        )
    }

    private static func gitFileTarget(_ data: Data) -> String? {
        guard data.count > 9, data.last == 0x0A, !data.dropLast().contains(0x0A),
              !data.contains(0), !data.contains(0x0D),
              let line = String(data: data.dropLast(), encoding: .utf8),
              line.hasPrefix("gitdir: ")
        else { return nil }
        let path = String(line.dropFirst(8))
        guard let canonical = canonicalDirectory(path), canonical == path else { return nil }
        return path
    }

    private static func canonicalPathLine(_ data: Data) throws -> String {
        let raw = try HarvisGitParsers.terminalLine(data, allowInteriorLineFeed: true)
        guard let canonical = canonicalDirectory(raw), canonical == raw else { throw SourceFailure.invalid }
        return raw
    }

    fileprivate static func captureDirectoryChain(_ path: String) throws -> DirectoryChainEvidence {
        guard path.hasPrefix("/"), !path.contains("\0"), path != "/" else { throw SourceFailure.invalid }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SourceFailure.invalid
        }
        let io = HarvisDarwinPOSIXFileIO()
        var descriptors: [Int32] = []
        do {
            let rootFD = try io.openRootDirectory()
            descriptors.append(rootFD)
            var identities = [try io.metadata(forFileDescriptor: rootFD)]
            var parent = rootFD
            for component in components {
                let next = try io.openDirectory(relativeTo: parent, component: component)
                descriptors.append(next)
                identities.append(try io.metadata(forFileDescriptor: next))
                parent = next
            }
            descriptors.reversed().forEach { io.close(fileDescriptor: $0) }
            return DirectoryChainEvidence(path: path, components: components, identities: identities)
        } catch let error as HarvisPOSIXCallError {
            descriptors.reversed().forEach { io.close(fileDescriptor: $0) }
            if isOfflineErrno(error.errnoCode) { throw SourceFailure.offline }
            throw SourceFailure.invalid
        } catch {
            descriptors.reversed().forEach { io.close(fileDescriptor: $0) }
            throw error
        }
    }

    private static func fileDescriptorIdentity(_ fd: Int32) throws -> HarvisPOSIXFileIdentity {
        try HarvisDarwinPOSIXFileIO().metadata(forFileDescriptor: fd)
    }

    private static func isOfflineErrno(_ value: Int32) -> Bool {
        value == ENOENT || value == ENOTDIR || value == ENXIO || value == ESTALE || value == ENODEV
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && value.contains(where: { $0 != "0" })
    }

    private static let gitEnvironment = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/var/empty",
        "XDG_CONFIG_HOME": "/var/empty",
        "LC_ALL": "C",
        "LANG": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
    ]

    private static let preflightEnvironment = [
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "LANG": "C",
    ]
}

private final class RefreshBudget {
    let deadline: TimeInterval
    var capturedBytes = 0

    init(timeout: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
    }

    var remaining: TimeInterval? {
        let value = deadline - ProcessInfo.processInfo.systemUptime
        return value > 0 ? value : nil
    }
}

private struct GitCapture: Equatable {
    let query: HarvisGitQuery
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private struct GitPass {
    let captures: [GitCapture]
    let summary: HarvisSourceGitSummary
}

private struct MarkerEvidence: Equatable {
    let relativePath: String
    let fileIdentity: HarvisPOSIXFileIdentity
    let directoryChain: [HarvisPOSIXFileIdentity]
    let digest: String
}

private enum GitQueryPhase {
    case bootstrap
    case repository

    var prefix: [String] {
        let bootstrap = [
            "--no-pager", "--no-replace-objects", "--no-optional-locks",
            "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
            "-c", "protocol.allow=never", "-C", ".",
        ]
        switch self {
        case .bootstrap: return bootstrap
        case .repository: return bootstrap + ["--work-tree=."]
        }
    }
}

private enum HarvisGitQuery: Equatable {
    case showTopLevel
    case absoluteGitDirectory
    case commonGitDirectory
    case unsafeConfiguration
    case markerMembership
    case symbolicHead
    case headCommit
    case shallow
    case status
    case remoteNames
    case remoteURL(String)
    case worktrees
    case upstreamName
    case upstreamCommit
    case aheadBehind(String, String)
    case receiptObject(String)
    case ancestry(String, String)

    var tail: [String] {
        switch self {
        case .showTopLevel:
            return ["rev-parse", "--show-toplevel"]
        case .absoluteGitDirectory:
            return ["rev-parse", "--absolute-git-dir"]
        case .commonGitDirectory:
            return ["rev-parse", "--path-format=absolute", "--git-common-dir"]
        case .unsafeConfiguration:
            return [
                "config", "--includes", "--null", "--name-only", "--get-regexp",
                "^(filter\\..*\\.(clean|process|required)|diff\\.(external|.*\\.(command|textconv))|core\\.(attributesfile|worktree|excludesfile|splitindex)|index\\.sparse)$",
            ]
        case .markerMembership:
            return [
                "--literal-pathspecs", "ls-files", "-z", "--cached", "--stage", "--",
                "Cargo.toml", "apps/HarvisBar/Package.swift", "scripts/harvis", "schemas/bar-status.schema.json",
            ]
        case .symbolicHead:
            return ["symbolic-ref", "--short", "-q", "HEAD"]
        case .headCommit:
            return ["rev-parse", "--verify", "--quiet", "HEAD"]
        case .shallow:
            return ["rev-parse", "--is-shallow-repository"]
        case .status:
            return ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=all"]
        case .remoteNames:
            return ["remote"]
        case let .remoteURL(name):
            return ["remote", "get-url", name]
        case .worktrees:
            return ["worktree", "list", "--porcelain", "-z"]
        case .upstreamName:
            return ["rev-parse", "--verify", "--quiet", "--symbolic-full-name", "@{upstream}"]
        case .upstreamCommit:
            return ["rev-parse", "--verify", "--quiet", "@{upstream}^{commit}"]
        case let .aheadBehind(head, upstream):
            return ["rev-list", "--left-right", "--count", "\(head)...\(upstream)"]
        case let .receiptObject(objectID):
            return ["rev-parse", "--verify", "--quiet", "\(objectID)^{commit}"]
        case let .ancestry(left, right):
            return ["merge-base", "--is-ancestor", left, right]
        }
    }
}

private struct DirectoryChainEvidence: Equatable {
    let path: String
    let components: [String]
    let identities: [HarvisPOSIXFileIdentity]

    var finalIdentity: HarvisPOSIXFileIdentity? { identities.last }

    func isIdentityPrefix(of other: DirectoryChainEvidence) -> Bool {
        guard components.count <= other.components.count,
              Array(other.components.prefix(components.count)) == components,
              identities.count <= other.identities.count
        else { return false }
        return zip(identities, other.identities).allSatisfy(Self.sameDirectoryIdentity)
    }

    func validate() throws {
        let current = try HarvisSourceInspector.captureDirectoryChain(path)
        guard matches(current) else {
            throw SourceFailure.invalid
        }
    }

    func matches(_ other: DirectoryChainEvidence) -> Bool {
        path == other.path
            && components == other.components
            && identities.count == other.identities.count
            && zip(identities, other.identities).allSatisfy(Self.sameDirectoryIdentity)
    }

    fileprivate static func sameDirectoryIdentity(
        _ left: HarvisPOSIXFileIdentity,
        _ right: HarvisPOSIXFileIdentity
    ) -> Bool {
        // HarvisPOSIXFileIdentity intentionally omits atime. Exact equality
        // therefore binds device/inode/ownership/mode/link-count/size plus
        // mtime and ctime without treating ordinary read access as drift.
        left == right
    }
}

private enum GitMarkerKind: Equatable { case directory, gitFile }

private struct GitMarkerEvidence: Equatable {
    let kind: GitMarkerKind
    let identity: HarvisPOSIXFileIdentity?
    let parentChain: [HarvisPOSIXFileIdentity]
    let contentDigest: String?
    let expectedGitDirectoryPath: String

    func matches(_ other: GitMarkerEvidence) -> Bool {
        self == other
    }
}

private struct RepositoryIdentityEvidence {
    let selected: DirectoryChainEvidence
    let root: DirectoryChainEvidence
    let gitMarker: GitMarkerEvidence
    let gitDirectory: DirectoryChainEvidence
    let commonDirectory: DirectoryChainEvidence

    func validate(files: HarvisVersionFileReader) throws {
        try selected.validate()
        try root.validate()
        guard root.isIdentityPrefix(of: selected),
              gitDirectory.matches(try HarvisSourceInspector.captureDirectoryChain(gitDirectory.path)),
              commonDirectory.matches(try HarvisSourceInspector.captureDirectoryChain(commonDirectory.path)),
              gitMarker.matches(try HarvisSourceInspector.captureGitMarker(root: root.path, files: files))
        else { throw SourceFailure.invalid }
    }
}

private enum SourceFailure: Error {
    case invalid
    case notHarvis
    case offline
    case unsafeGitConfig
    case gitTimeout
    case gitOutputLimitExceeded

    var status: HarvisSourceStatus {
        switch self {
        case .invalid: return .invalid
        case .notHarvis: return .notHarvis
        case .offline: return .offline
        case .unsafeGitConfig: return .unsafeGitConfig
        case .gitTimeout: return .gitTimeout
        case .gitOutputLimitExceeded: return .gitOutputLimitExceeded
        }
    }
}
