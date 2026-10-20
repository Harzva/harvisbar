import Foundation

public enum HarvisBundleReceiptStatus: String, Codable, CaseIterable, Sendable {
    case valid
    case missing
    case symlink
    case notRegular
    case empty
    case tooLarge
    case unreadable
    case ioFailure
    case changedDuringRead
    case invalidJSON
    case unsupportedSchema
    case invalidContract
}

public struct HarvisAppIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let executable: String
    public let version: String

    public init(bundleIdentifier: String, executable: String, version: String) {
        self.bundleIdentifier = bundleIdentifier
        self.executable = executable
        self.version = version
    }
}

public struct HarvisReceiptArtifactRecord: Codable, Equatable, Sendable {
    public let role: String
    public let relativePath: String
    public let mode: String
    public let sizeBytes: UInt64
    public let sha256: String

    public init(role: String, relativePath: String, mode: String, sizeBytes: UInt64, sha256: String) {
        self.role = role
        self.relativePath = relativePath
        self.mode = mode
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public struct HarvisReceiptArtifacts: Codable, Equatable, Sendable {
    public let runtimeSha256: String
    public let appUnsignedSha256: String
    public let systemExtensionUnsignedSha256: String
    public let records: [HarvisReceiptArtifactRecord]

    public init(
        runtimeSha256: String,
        appUnsignedSha256: String,
        systemExtensionUnsignedSha256: String,
        records: [HarvisReceiptArtifactRecord]
    ) {
        self.runtimeSha256 = runtimeSha256
        self.appUnsignedSha256 = appUnsignedSha256
        self.systemExtensionUnsignedSha256 = systemExtensionUnsignedSha256
        self.records = records
    }

    public var runtimeRecord: HarvisReceiptArtifactRecord? {
        records.first { $0.role == "harvis-runtime" }
    }
}

public struct HarvisReceiptProvenance: Codable, Equatable, Sendable {
    public let cacheKey: String
    public let sha256: String
    public let sourceCommit: String
    public let sourceTree: String
    public let stagedPayloadSha256: String

    public init(cacheKey: String, sha256: String, sourceCommit: String, sourceTree: String, stagedPayloadSha256: String) {
        self.cacheKey = cacheKey
        self.sha256 = sha256
        self.sourceCommit = sourceCommit
        self.sourceTree = sourceTree
        self.stagedPayloadSha256 = stagedPayloadSha256
    }
}

public struct HarvisReceiptPayload: Codable, Equatable, Sendable {
    public let digestAlgorithm: String
    public let digestScope: String
    public let fileCount: UInt64
    public let sha256: String

    public init(digestAlgorithm: String, digestScope: String, fileCount: UInt64, sha256: String) {
        self.digestAlgorithm = digestAlgorithm
        self.digestScope = digestScope
        self.fileCount = fileCount
        self.sha256 = sha256
    }
}

public struct HarvisReceiptAllowlist: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String

    public init(relativePath: String, sha256: String) {
        self.relativePath = relativePath
        self.sha256 = sha256
    }
}

public struct HarvisReceiptSystemExtension: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let bundleName: String
    public let executable: String
    public let version: String

    public init(bundleIdentifier: String, bundleName: String, executable: String, version: String) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.executable = executable
        self.version = version
    }
}

public struct HarvisBundleReceiptSummary: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let pluginRootMarker: String
    public let app: HarvisAppIdentity
    public let artifacts: HarvisReceiptArtifacts
    public let provenance: HarvisReceiptProvenance
    public let payload: HarvisReceiptPayload
    public let appRuntimeAllowlist: HarvisReceiptAllowlist
    public let systemExtension: HarvisReceiptSystemExtension

    public init(
        schemaVersion: String,
        pluginRootMarker: String,
        app: HarvisAppIdentity,
        artifacts: HarvisReceiptArtifacts,
        provenance: HarvisReceiptProvenance,
        payload: HarvisReceiptPayload,
        appRuntimeAllowlist: HarvisReceiptAllowlist,
        systemExtension: HarvisReceiptSystemExtension
    ) {
        self.schemaVersion = schemaVersion
        self.pluginRootMarker = pluginRootMarker
        self.app = app
        self.artifacts = artifacts
        self.provenance = provenance
        self.payload = payload
        self.appRuntimeAllowlist = appRuntimeAllowlist
        self.systemExtension = systemExtension
    }
}

public struct HarvisBundleReceiptInspection: Codable, Equatable, Sendable {
    public let status: HarvisBundleReceiptStatus
    public let receipt: HarvisBundleReceiptSummary?

    public init(status: HarvisBundleReceiptStatus, receipt: HarvisBundleReceiptSummary? = nil) {
        if status == .valid, let receipt {
            self.status = .valid
            self.receipt = receipt
        } else {
            self.status = status == .valid ? .invalidContract : status
            self.receipt = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case receipt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            status: try container.decode(HarvisBundleReceiptStatus.self, forKey: .status),
            receipt: try container.decodeIfPresent(HarvisBundleReceiptSummary.self, forKey: .receipt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(receipt, forKey: .receipt)
    }
}

public enum HarvisSourceStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case unbound
    case notHarvis
    case bundlePayload
    case offline
    case invalid
    case unsafeGitConfig
    case gitTimeout
    case gitOutputLimitExceeded
}

public enum HarvisGitHeadState: String, Codable, CaseIterable, Sendable {
    case attached
    case detached
    case unborn
}

public struct HarvisGitRemoteSummary: Codable, Equatable, Sendable {
    public let name: String
    public let githubBrowseURL: String?

    public init(name: String, githubBrowseURL: String?) {
        self.name = name
        self.githubBrowseURL = githubBrowseURL
    }
}

public enum HarvisGitWorktreeHeadState: String, Codable, CaseIterable, Sendable {
    case attached
    case detached
    case unborn
    case bare
}

public struct HarvisGitWorktreeSummary: Codable, Equatable, Sendable {
    public let path: String
    public let headState: HarvisGitWorktreeHeadState
    public let headCommit: String?
    public let branch: String?
    public let lockedReason: String?
    public let prunableReason: String?

    public init(
        path: String,
        headState: HarvisGitWorktreeHeadState,
        headCommit: String?,
        branch: String?,
        lockedReason: String?,
        prunableReason: String?
    ) {
        self.path = path
        self.headState = headState
        self.headCommit = headCommit
        self.branch = branch
        self.lockedReason = lockedReason
        self.prunableReason = prunableReason
    }
}

public struct HarvisSourceGitSummary: Codable, Equatable, Sendable {
    public let repositoryRoot: String
    public let headState: HarvisGitHeadState
    public let branch: String?
    public let headCommit: String?
    public let changedFileCount: Int
    public let upstream: String?
    public let aheadCount: UInt64?
    public let behindCount: UInt64?
    public let isShallow: Bool
    public let trackingSnapshotMayBeStale: Bool
    public let trackingSnapshotIncomplete: Bool
    public let observedAt: Date
    public let remotes: [HarvisGitRemoteSummary]
    public let worktrees: [HarvisGitWorktreeSummary]

    public init(
        repositoryRoot: String,
        headState: HarvisGitHeadState,
        branch: String?,
        headCommit: String?,
        changedFileCount: Int,
        upstream: String?,
        aheadCount: UInt64?,
        behindCount: UInt64?,
        isShallow: Bool,
        trackingSnapshotMayBeStale: Bool = true,
        trackingSnapshotIncomplete: Bool,
        observedAt: Date,
        remotes: [HarvisGitRemoteSummary],
        worktrees: [HarvisGitWorktreeSummary]
    ) {
        self.repositoryRoot = repositoryRoot
        self.headState = headState
        self.branch = branch
        self.headCommit = headCommit
        self.changedFileCount = changedFileCount
        self.upstream = upstream
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.isShallow = isShallow
        self.trackingSnapshotMayBeStale = trackingSnapshotMayBeStale
        self.trackingSnapshotIncomplete = trackingSnapshotIncomplete
        self.observedAt = observedAt
        self.remotes = remotes
        self.worktrees = worktrees
    }

    public var isDirty: Bool { changedFileCount > 0 }
}

public struct HarvisSourceInspection: Codable, Equatable, Sendable {
    public let status: HarvisSourceStatus
    public let selectedPath: String?
    public let canonicalRepositoryRoot: String?
    public let git: HarvisSourceGitSummary?
    public let alignmentEvidence: HarvisAlignmentEvidence?

    public init(
        status: HarvisSourceStatus,
        selectedPath: String?,
        canonicalRepositoryRoot: String? = nil,
        git: HarvisSourceGitSummary? = nil,
        alignmentEvidence: HarvisAlignmentEvidence? = nil
    ) {
        if status == .ready,
           let selectedPath,
           !selectedPath.isEmpty,
           let canonicalRepositoryRoot,
           !canonicalRepositoryRoot.isEmpty,
           let git,
           git.repositoryRoot == canonicalRepositoryRoot {
            self.status = .ready
            self.selectedPath = selectedPath
            self.canonicalRepositoryRoot = canonicalRepositoryRoot
            self.git = git
            self.alignmentEvidence = alignmentEvidence
        } else {
            self.status = status == .ready ? .invalid : status
            self.selectedPath = status == .unbound ? nil : selectedPath
            self.canonicalRepositoryRoot = nil
            self.git = nil
            self.alignmentEvidence = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case selectedPath
        case canonicalRepositoryRoot
        case git
        case alignmentEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            status: try container.decode(HarvisSourceStatus.self, forKey: .status),
            selectedPath: try container.decodeIfPresent(String.self, forKey: .selectedPath),
            canonicalRepositoryRoot: try container.decodeIfPresent(
                String.self,
                forKey: .canonicalRepositoryRoot
            ),
            git: try container.decodeIfPresent(HarvisSourceGitSummary.self, forKey: .git),
            alignmentEvidence: try container.decodeIfPresent(
                HarvisAlignmentEvidence.self,
                forKey: .alignmentEvidence
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(selectedPath, forKey: .selectedPath)
        try container.encodeIfPresent(canonicalRepositoryRoot, forKey: .canonicalRepositoryRoot)
        try container.encodeIfPresent(git, forKey: .git)
        try container.encodeIfPresent(alignmentEvidence, forKey: .alignmentEvidence)
    }

    public var alignment: HarvisVersionAlignment {
        guard let alignmentEvidence else { return .unknown }
        return HarvisVersionAlignmentResolver.resolve(alignmentEvidence)
    }
}

public enum HarvisLaunchBindingStatus: String, Codable, CaseIterable, Sendable {
    case valid
    case missing
    case symlink
    case notRegular
    case empty
    case tooLarge
    case unreadable
    case ioFailure
    case changedDuringRead
    case invalidPlist
    case labelMismatch
    case programPathMismatch
}

public enum HarvisHelperFileStatus: String, Codable, CaseIterable, Sendable {
    case valid
    case missing
    case symlink
    case notRegular
    case empty
    case notExecutable
    case tooLarge
    case unreadable
    case ioFailure
    case changedDuringRead
}

public enum HarvisHelperReceiptMatchStatus: String, Codable, CaseIterable, Sendable {
    case matched
    case receiptUnavailable
    case notEvaluated
    case sizeMismatch
    case hashMismatch
}

public enum HarvisStableHelperStatus: String, Codable, CaseIterable, Sendable {
    case matched
    case launchBindingInvalid
    case missing
    case symlink
    case notRegular
    case empty
    case notExecutable
    case tooLarge
    case unreadable
    case ioFailure
    case changedDuringRead
    case receiptUnavailable
    case sizeMismatch
    case hashMismatch
}

public struct HarvisStableHelperSummary: Codable, Equatable, Sendable {
    public let status: HarvisStableHelperStatus
    public let httpLaunchBindingStatus: HarvisLaunchBindingStatus
    public let tickLaunchBindingStatus: HarvisLaunchBindingStatus
    public let helperFileStatus: HarvisHelperFileStatus
    public let receiptMatchStatus: HarvisHelperReceiptMatchStatus
    public let sizeBytes: UInt64?
    public let sha256: String?

    public init(
        httpLaunchBindingStatus: HarvisLaunchBindingStatus,
        tickLaunchBindingStatus: HarvisLaunchBindingStatus,
        helperFileStatus: HarvisHelperFileStatus,
        receiptMatchStatus: HarvisHelperReceiptMatchStatus,
        sizeBytes: UInt64?,
        sha256: String?
    ) {
        self.httpLaunchBindingStatus = httpLaunchBindingStatus
        self.tickLaunchBindingStatus = tickLaunchBindingStatus
        self.helperFileStatus = helperFileStatus
        self.receiptMatchStatus = receiptMatchStatus
        self.sizeBytes = helperFileStatus == .valid ? sizeBytes : nil
        self.sha256 = helperFileStatus == .valid ? sha256 : nil
        self.status = Self.aggregate(
            http: httpLaunchBindingStatus,
            tick: tickLaunchBindingStatus,
            file: helperFileStatus,
            receipt: receiptMatchStatus
        )
    }

    public static func aggregate(
        http: HarvisLaunchBindingStatus,
        tick: HarvisLaunchBindingStatus,
        file: HarvisHelperFileStatus,
        receipt: HarvisHelperReceiptMatchStatus
    ) -> HarvisStableHelperStatus {
        guard http == .valid, tick == .valid else { return .launchBindingInvalid }
        switch file {
        case .valid: break
        case .missing: return .missing
        case .symlink: return .symlink
        case .notRegular: return .notRegular
        case .empty: return .empty
        case .notExecutable: return .notExecutable
        case .tooLarge: return .tooLarge
        case .unreadable: return .unreadable
        case .ioFailure: return .ioFailure
        case .changedDuringRead: return .changedDuringRead
        }
        switch receipt {
        case .matched: return .matched
        case .receiptUnavailable, .notEvaluated: return .receiptUnavailable
        case .sizeMismatch: return .sizeMismatch
        case .hashMismatch: return .hashMismatch
        }
    }
}

public enum HarvisVersionAlignment: String, Codable, CaseIterable, Sendable {
    case exact
    case sourceAhead
    case installedAhead
    case diverged
    case missingCommit
    case unknown
}

public enum HarvisGitProof: String, Codable, CaseIterable, Sendable {
    case positive
    case negative
    case unavailable
}

public struct HarvisAlignmentEvidence: Codable, Equatable, Sendable {
    public let sourceCommit: String?
    public let receiptCommit: String?
    public let receiptObject: HarvisGitProof
    public let receiptIsAncestorOfSource: HarvisGitProof
    public let sourceIsAncestorOfReceipt: HarvisGitProof
    public let sourceIsShallow: Bool?

    public init(
        sourceCommit: String?,
        receiptCommit: String?,
        receiptObject: HarvisGitProof,
        receiptIsAncestorOfSource: HarvisGitProof,
        sourceIsAncestorOfReceipt: HarvisGitProof,
        sourceIsShallow: Bool?
    ) {
        self.sourceCommit = sourceCommit
        self.receiptCommit = receiptCommit
        self.receiptObject = receiptObject
        self.receiptIsAncestorOfSource = receiptIsAncestorOfSource
        self.sourceIsAncestorOfReceipt = sourceIsAncestorOfReceipt
        self.sourceIsShallow = sourceIsShallow
    }
}
