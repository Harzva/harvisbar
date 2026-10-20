#if HARVIS_VERSION_UI_TESTING
import CryptoKit
import Foundation
import HarvisVersionCore

enum HarvisVersionFixtureID: String, CaseIterable, Sendable {
    case baselineUnbound = "baseline-unbound"
    case readyExact = "ready-exact"
    case invalidSourceSelection = "invalid-source-selection"
    case safeRemote = "safe-remote"
    case unsafeRemote = "unsafe-remote"
    case noRemote = "no-remote"
    case apiOffline = "api-offline"
    case gitTimeout = "git-timeout"
    case gitOutputOverflow = "git-output-overflow"
    case unsafeGitConfig = "unsafe-git-config"
    case receiptInvalid = "receipt-invalid"
    case helperHashMismatch = "helper-hash-mismatch"
    case helperMismatch = "helper-mismatch"
    case sourceRemovedAfterReady = "source-removed-after-ready"
    case sourceOffline = "source-offline"
    case persistedSourceOffline = "persisted-source-offline"
    case latestWins = "latest-wins"
    case taskProgressHTTP400 = "task-progress-http400"
    case taskProgressPermissionFailed = "task-progress-permission-failed"
}

enum HarvisVersionFixtureProviderError: Error, Equatable, Sendable {
    case invalidArguments
    case unknownFixture
    case defaultsUnavailable
    case defaultsSynchronizationFailed
}

enum HarvisVersionFixtureBootEvent: Equatable, Sendable {
    case defaultsCleared
    case defaultsSeeded
    case receiptAcknowledged
}

struct HarvisVersionFixtureBootPolicy: Equatable, Sendable {
    let startsRuntime: Bool
    let startsRefresh: Bool
    let startsTimer: Bool
    let opensSocket: Bool
    let spawnsProcess: Bool

    static let isolated = Self(
        startsRuntime: false,
        startsRefresh: false,
        startsTimer: false,
        opensSocket: false,
        spawnsProcess: false
    )
}

struct HarvisVersionFixtureSnapshot: Equatable, Sendable {
    let appIdentity: HarvisAppIdentity
    let apiVersion: String?
    let apiIsReady: Bool
    let receipt: HarvisBundleReceiptInspection
    let source: HarvisSourceInspection
    let helper: HarvisStableHelperSummary
    let stableHelperPath: String
}

enum HarvisVersionFixtureClipboardKind: String, Sendable {
    case source
    case commit
}

@MainActor
final class HarvisVersionFixtureEffectSinks {
    private(set) var openerReceipt: String?
    private(set) var clipboardReceipt: String?
    private(set) var finderReceipt: String?

    private var openerCount = 0
    private var clipboardCount = 0
    private var finderCount = 0

    @discardableResult
    func openGitHub(_ candidate: String) -> Bool {
        guard let sanitized = HarvisGitParsers.githubBrowseURL(from: candidate) else {
            return false
        }
        openerCount += 1
        openerReceipt = "count=\(openerCount) url=\(sanitized)"
        return true
    }

    func copy(_ value: String, kind: HarvisVersionFixtureClipboardKind) {
        clipboardCount += 1
        clipboardReceipt = "count=\(clipboardCount) kind=\(kind.rawValue) valueSha256=\(Self.sha256(value))"
    }

    @discardableResult
    func showInFinder(canonicalPath: String) -> Bool {
        guard Self.isLexicallyCanonicalAbsolute(canonicalPath) else { return false }
        finderCount += 1
        finderReceipt = "count=\(finderCount) canonicalPathSha256=\(Self.sha256(canonicalPath))"
        return true
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isLexicallyCanonicalAbsolute(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", !value.contains("\0"), !value.hasSuffix("/") else {
            return false
        }
        return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

@MainActor
final class HarvisVersionFixtureProvider {
    nonisolated static let argumentName = "--harvis-version-fixture"
    nonisolated static let bundleIdentifier = "local.harzva.harvisbar.version-ui-test"
    nonisolated static let defaultsSuiteName = "local.harzva.harvisbar.version-ui-test.fixtures"
    nonisolated static let fixtureSourcePreferenceKey = "harvisVersionFixture.sourceRoot"

    let fixtureID: HarvisVersionFixtureID
    let bootPolicy = HarvisVersionFixtureBootPolicy.isolated
    let effects = HarvisVersionFixtureEffectSinks()
    let initialSnapshot: HarvisVersionFixtureSnapshot
    private(set) var bootEvents: [HarvisVersionFixtureBootEvent]

    private(set) var fixtureReceipt: String?
    private(set) var sourceInspectionCallCount = 0
    var onFixtureReceiptChange: ((String) -> Void)?
    var onSourceInspectionCall: ((Int) -> Void)?

    private let defaults: any HarvisVersionFixtureDefaultsWriting
    private let latestWinsA: HarvisVersionDeferredSourceInspection?
    private let readySource: HarvisSourceInspection
    private var didRemoveSource = false
    private var taskProgressRequestCount = 0
    private var taskProgressSuccessContinuation: CheckedContinuation<TaskProgressStatus, Never>?

    convenience init(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        let fixtureID = try Self.parseFixtureID(arguments: arguments)
        guard let defaults = HarvisVersionUserDefaultsWriter(suiteName: Self.defaultsSuiteName) else {
            throw HarvisVersionFixtureProviderError.defaultsUnavailable
        }
        try self.init(fixtureID: fixtureID, defaults: defaults)
    }

    static func parseFixtureID(arguments: [String]) throws -> HarvisVersionFixtureID {
        guard arguments.count == 2, arguments[0] == Self.argumentName else {
            throw HarvisVersionFixtureProviderError.invalidArguments
        }
        guard let fixtureID = HarvisVersionFixtureID(rawValue: arguments[1]) else {
            throw HarvisVersionFixtureProviderError.unknownFixture
        }
        return fixtureID
    }

    init(
        fixtureID: HarvisVersionFixtureID,
        defaults: HarvisVersionFixtureDefaultsWriting
    ) throws {
        self.fixtureID = fixtureID
        self.defaults = defaults
        readySource = Self.source(root: "/fixture/harvis/main")
        latestWinsA = fixtureID == .latestWins ? HarvisVersionDeferredSourceInspection() : nil

        defaults.clearPersistentDomain()
        guard defaults.synchronize() else {
            throw HarvisVersionFixtureProviderError.defaultsSynchronizationFailed
        }
        var events: [HarvisVersionFixtureBootEvent] = [.defaultsCleared]
        defaults.replacePersistentDomain(with: Self.seed(for: fixtureID))
        guard defaults.synchronize() else {
            throw HarvisVersionFixtureProviderError.defaultsSynchronizationFailed
        }
        events.append(.defaultsSeeded)

        initialSnapshot = Self.snapshot(for: fixtureID)
        fixtureReceipt = fixtureID == .latestWins
            ? nil
            : "\(fixtureID.rawValue):ready"
        if fixtureReceipt != nil {
            events.append(.receiptAcknowledged)
        }
        bootEvents = events
    }

    /// Builds the same Catalog model used by the production window, but with
    /// closed in-memory inspectors and the fixed test-only defaults suite. None
    /// of these dependencies can touch Git, launchd, a socket, or a process.
    func makeCatalogModel() -> HarvisVersionCatalogModel {
        let snapshot = initialSnapshot
        let dependencies = HarvisVersionCatalogDependencies(
            inspectReceipt: {
                snapshot.receipt
            },
            inspectSource: { [self] selectedDirectory, _ in
                await inspectPersistedSource(selectedDirectory: selectedDirectory)
            },
            validateSource: { [self] candidateDirectory, _ in
                await validateSelection(candidateDirectory: candidateDirectory)
            },
            inspectHelper: { _ in
                snapshot.helper
            }
        )
        return HarvisVersionCatalogModel(
            appIdentity: snapshot.appIdentity,
            stableHelperPath: snapshot.stableHelperPath,
            preferences: defaults,
            dependencies: dependencies,
            apiVersionProvider: { snapshot.apiVersion }
        )
    }

    var isTaskProgressFixture: Bool {
        fixtureID == .taskProgressHTTP400 || fixtureID == .taskProgressPermissionFailed
    }

    var taskProgressInitialSnapshot: TaskProgressStatus? {
        isTaskProgressFixture ? Self.taskProgressSnapshot(taskID: "retained-task", percent: 35) : nil
    }

    func makeTaskProgressLoader() -> (any HarvisTaskProgressLoading)? {
        guard isTaskProgressFixture else { return nil }
        return HarvisVersionTaskProgressFixtureLoader(provider: self)
    }

    func seedTaskProgressRuntimeBaseline(on model: HarvisRuntimeModel) {
        guard isTaskProgressFixture else { return }
        model.health = HealthData(
            agent: "harvis",
            apiVersion: "v0.40-rust-alpha",
            mode: "local",
            autonomyLevel: 1,
            authRequired: true
        )
        model.barStatus = BarStatus(
            generatedAt: "2026-08-30T00:00:00Z",
            runtime: RuntimeInfo(
                state: "verified",
                mode: "local",
                autonomyLevel: 1,
                summary: "Runtime healthy; task lane isolated."
            ),
            serviceHealth: ServiceHealth(http: "running", tickRunner: "running", mcp: "ready"),
            work: WorkInfo(
                packets: 0,
                blocked: 0,
                pendingApprovals: 0,
                runtimeErrors: 0,
                runs: 0,
                lastTickAt: "2026-08-30T00:00:00Z"
            ),
            knowledge: nil,
            agentMail: nil,
            agentHarnesses: nil,
            codexhomeObservability: nil,
            ports: nil
        )
    }

    func acceptTaskProgressPublication(_ event: HarvisTaskProgressPublishEvent) {
        guard isTaskProgressFixture else { return }
        switch event {
        case .failure where taskProgressRequestCount == 1:
            publishReceipt("\(fixtureID.rawValue):degraded:count=1")
        case .success where taskProgressRequestCount == 2:
            publishReceipt("\(fixtureID.rawValue):recovered:count=2")
        case .success, .failure, .cancelled:
            break
        }
    }

    @discardableResult
    func releaseTaskProgressSuccess() -> Bool {
        guard isTaskProgressFixture,
              taskProgressRequestCount == 2,
              let continuation = taskProgressSuccessContinuation else {
            return false
        }
        taskProgressSuccessContinuation = nil
        continuation.resume(
            returning: Self.taskProgressSnapshot(taskID: "recovered-task", percent: 85)
        )
        return true
    }

    fileprivate func loadTaskProgressFixture() async throws -> TaskProgressStatus {
        precondition(isTaskProgressFixture, "task loader is closed to task fixtures")
        taskProgressRequestCount += 1
        switch taskProgressRequestCount {
        case 1:
            if fixtureID == .taskProgressHTTP400 {
                throw HarvisTaskProgressClientError.httpStatus(400)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        case 2:
            return await withCheckedContinuation { continuation in
                precondition(taskProgressSuccessContinuation == nil)
                taskProgressSuccessContinuation = continuation
                // Publish only after the release continuation exists; the AX
                // receipt is a synchronization barrier, not a progress hint.
                publishReceipt("\(fixtureID.rawValue):retrying:count=2")
            }
        default:
            throw HarvisTaskProgressClientError.invalidEnvelope
        }
    }

    /// Closed replacement for NSOpenPanel in the fixture build.
    var sourceSelectionCandidate: String? {
        switch fixtureID {
        case .invalidSourceSelection:
            return "/fixture/invalid-selection"
        case .latestWins:
            return "/fixture/harvis/b"
        default:
            return "/fixture/harvis/main"
        }
    }

    /// Synthetic selection/inspection seam. It never opens a panel, touches a
    /// repository, starts a timer, opens a socket, or spawns a process.
    func inspectSelectedSource() async -> HarvisSourceInspection {
        sourceInspectionCallCount += 1
        onSourceInspectionCall?(sourceInspectionCallCount)

        guard fixtureID == .latestWins, let latestWinsA else {
            return await validateSelection(candidateDirectory: sourceSelectionCandidate ?? "")
        }

        if sourceInspectionCallCount == 1 {
            let sourceA = await latestWinsA.value { [self] in
                publishReceipt("latest-wins:a-pending")
            }
            // By construction B has already superseded the only A waiter
            // before the test can expose the release control. Returning A can
            // therefore only reach the model's cancelled/stale guard.
            publishReceipt("latest-wins:a-completed-discarded")
            return sourceA
        }
        let sourceB = Self.source(
            root: "/fixture/harvis/b",
            branch: "codex/fixture-b",
            commit: String(repeating: "4", count: 40)
        )
        // Call 2 is selection validation. The model synchronously publishes B
        // and starts call 3 only after it has cancelled A; call 3 is therefore
        // the observable barrier for both B publication and A supersession.
        if sourceInspectionCallCount >= 3 {
            publishReceipt("latest-wins:b-published")
        }
        return sourceB
    }

    @discardableResult
    func removeSourceAfterReady() -> Bool {
        guard fixtureID == .sourceRemovedAfterReady, !didRemoveSource else { return false }
        didRemoveSource = true
        publishReceipt("source-removed-after-ready:removed")
        return true
    }

    @discardableResult
    func releaseLatestWinsA() -> Bool {
        guard fixtureID == .latestWins,
              fixtureReceipt == "latest-wins:b-published",
              let latestWinsA,
              latestWinsA.hasWaiter else { return false }
        return latestWinsA.resolve(
            Self.source(
                root: "/fixture/harvis/a",
                branch: "codex/fixture-a",
                commit: String(repeating: "3", count: 40)
            )
        )
    }

    @discardableResult
    func markLatestWinsACompletedDiscarded() -> Bool {
        guard fixtureID == .latestWins, latestWinsA?.isResolved == true else { return false }
        if fixtureReceipt == "latest-wins:a-completed-discarded" { return true }
        guard fixtureReceipt == "latest-wins:b-published" else { return false }
        publishReceipt("latest-wins:a-completed-discarded")
        return true
    }

    private func publishReceipt(_ value: String) {
        if fixtureReceipt == nil, !bootEvents.contains(.receiptAcknowledged) {
            bootEvents.append(.receiptAcknowledged)
        }
        fixtureReceipt = value
        onFixtureReceiptChange?(value)
    }

    private func inspectPersistedSource(
        selectedDirectory: String?
    ) async -> HarvisSourceInspection {
        guard let selectedDirectory else {
            return HarvisSourceInspection(status: .unbound, selectedPath: nil)
        }
        if fixtureID == .latestWins {
            return await inspectSelectedSource()
        }
        switch fixtureID {
        case .sourceOffline, .persistedSourceOffline:
            return HarvisSourceInspection(status: .offline, selectedPath: selectedDirectory)
        case .sourceRemovedAfterReady where didRemoveSource:
            return HarvisSourceInspection(status: .offline, selectedPath: selectedDirectory)
        case .unsafeGitConfig:
            return HarvisSourceInspection(status: .unsafeGitConfig, selectedPath: selectedDirectory)
        case .gitTimeout:
            return HarvisSourceInspection(status: .gitTimeout, selectedPath: selectedDirectory)
        case .gitOutputOverflow:
            return HarvisSourceInspection(
                status: .gitOutputLimitExceeded,
                selectedPath: selectedDirectory
            )
        case .invalidSourceSelection:
            return Self.source(root: "/fixture/harvis/a")
        case .noRemote:
            return Self.source(root: selectedDirectory, remotes: [])
        case .unsafeRemote:
            return Self.source(
                root: selectedDirectory,
                remotes: [HarvisGitRemoteSummary(name: "origin", githubBrowseURL: nil)]
            )
        default:
            return Self.source(root: selectedDirectory)
        }
    }

    private func validateSelection(
        candidateDirectory: String
    ) async -> HarvisSourceInspection {
        switch fixtureID {
        case .invalidSourceSelection:
            return HarvisSourceInspection(status: .notHarvis, selectedPath: candidateDirectory)
        case .sourceOffline, .persistedSourceOffline:
            return HarvisSourceInspection(status: .offline, selectedPath: candidateDirectory)
        case .latestWins:
            return await inspectSelectedSource()
        default:
            return readySource
        }
    }

    private static func seed(for fixtureID: HarvisVersionFixtureID) -> [String: Any] {
        switch fixtureID {
        case .persistedSourceOffline, .sourceOffline:
            return [fixtureSourcePreferenceKey: "/fixture/offline/source"]
        case .invalidSourceSelection:
            return [fixtureSourcePreferenceKey: "/fixture/harvis/a"]
        case .latestWins:
            return [fixtureSourcePreferenceKey: "/fixture/harvis/a"]
        case .baselineUnbound:
            return [:]
        default:
            return [fixtureSourcePreferenceKey: "/fixture/harvis/main"]
        }
    }

    private static func snapshot(for fixtureID: HarvisVersionFixtureID) -> HarvisVersionFixtureSnapshot {
        let source: HarvisSourceInspection
        switch fixtureID {
        case .baselineUnbound:
            source = HarvisSourceInspection(status: .unbound, selectedPath: nil)
        case .sourceOffline, .persistedSourceOffline:
            source = HarvisSourceInspection(status: .offline, selectedPath: "/fixture/offline/source")
        case .invalidSourceSelection:
            source = Self.source(root: "/fixture/harvis/a")
        case .unsafeGitConfig:
            source = HarvisSourceInspection(
                status: .unsafeGitConfig,
                selectedPath: "/fixture/harvis/main"
            )
        case .gitTimeout:
            source = HarvisSourceInspection(
                status: .gitTimeout,
                selectedPath: "/fixture/harvis/main"
            )
        case .gitOutputOverflow:
            source = HarvisSourceInspection(
                status: .gitOutputLimitExceeded,
                selectedPath: "/fixture/harvis/main"
            )
        case .noRemote:
            source = Self.source(root: "/fixture/harvis/main", remotes: [])
        case .unsafeRemote:
            source = Self.source(
                root: "/fixture/harvis/main",
                remotes: [HarvisGitRemoteSummary(name: "origin", githubBrowseURL: nil)]
            )
        default:
            source = Self.source(root: "/fixture/harvis/main")
        }

        let receipt: HarvisBundleReceiptInspection = fixtureID == .receiptInvalid
            ? HarvisBundleReceiptInspection(status: .invalidContract)
            : HarvisBundleReceiptInspection(status: .valid, receipt: Self.receipt())
        let helperMismatch = fixtureID == .helperMismatch || fixtureID == .helperHashMismatch
        let receiptUnavailable = fixtureID == .receiptInvalid
        let helper = HarvisStableHelperSummary(
            httpLaunchBindingStatus: .valid,
            tickLaunchBindingStatus: .valid,
            helperFileStatus: .valid,
            receiptMatchStatus: receiptUnavailable
                ? .receiptUnavailable
                : (helperMismatch ? .hashMismatch : .matched),
            sizeBytes: 1_048_576,
            sha256: helperMismatch
                ? String(repeating: "c", count: 64)
                : String(repeating: "a", count: 64)
        )
        return HarvisVersionFixtureSnapshot(
            appIdentity: HarvisAppIdentity(
                bundleIdentifier: bundleIdentifier,
                executable: "HarvisBar",
                version: "0.36.0"
            ),
            apiVersion: fixtureID == .apiOffline ? nil : "v0.40-rust-alpha",
            apiIsReady: fixtureID != .apiOffline,
            receipt: receipt,
            source: source,
            helper: helper,
            stableHelperPath: "/fixture/home/.harvis/bin/harvis"
        )
    }

    private static func source(
        root: String,
        branch: String = "codex/fixture-main",
        commit: String = String(repeating: "1", count: 40),
        remotes: [HarvisGitRemoteSummary]? = nil
    ) -> HarvisSourceInspection {
        let resolvedRemotes = remotes ?? [
            HarvisGitRemoteSummary(
                name: "origin",
                githubBrowseURL: "https://github.com/octocat/harvis-fixture"
            )
        ]
        let worktrees = [
            HarvisGitWorktreeSummary(
                path: root == "/fixture/harvis/main" ? "/fixture/harvis/linked" : root + "-linked",
                headState: .detached,
                headCommit: String(repeating: "3", count: 40),
                branch: nil,
                lockedReason: "fixture lock\nreason",
                prunableReason: nil
            ),
            HarvisGitWorktreeSummary(
                path: root,
                headState: .attached,
                headCommit: commit,
                branch: "refs/heads/\(branch)",
                lockedReason: nil,
                prunableReason: nil
            ),
        ]
        let git = HarvisSourceGitSummary(
            repositoryRoot: root,
            headState: .attached,
            branch: branch,
            headCommit: commit,
            changedFileCount: 2,
            upstream: "refs/remotes/origin/\(branch)",
            aheadCount: 2,
            behindCount: 1,
            isShallow: false,
            trackingSnapshotMayBeStale: true,
            trackingSnapshotIncomplete: false,
            observedAt: Date(timeIntervalSince1970: 1_787_961_600),
            remotes: resolvedRemotes,
            worktrees: worktrees
        )
        return HarvisSourceInspection(
            status: .ready,
            selectedPath: root,
            canonicalRepositoryRoot: root,
            git: git,
            alignmentEvidence: HarvisAlignmentEvidence(
                sourceCommit: commit,
                receiptCommit: commit,
                receiptObject: .positive,
                receiptIsAncestorOfSource: .positive,
                sourceIsAncestorOfReceipt: .positive,
                sourceIsShallow: false
            )
        )
    }

    private static func receipt() -> HarvisBundleReceiptSummary {
        let runtimeSHA = String(repeating: "a", count: 64)
        let appSHA = String(repeating: "c", count: 64)
        let extensionSHA = String(repeating: "d", count: 64)
        return HarvisBundleReceiptSummary(
            schemaVersion: "harvis.app-bundle-receipt.v1",
            pluginRootMarker: "HarvisPlugin",
            app: HarvisAppIdentity(
                bundleIdentifier: bundleIdentifier,
                executable: "HarvisBar",
                version: "0.36.0"
            ),
            artifacts: HarvisReceiptArtifacts(
                runtimeSha256: runtimeSHA,
                appUnsignedSha256: appSHA,
                systemExtensionUnsignedSha256: extensionSHA,
                records: [
                    HarvisReceiptArtifactRecord(
                        role: "harvis-runtime",
                        relativePath: "bin/harvis",
                        mode: "0755",
                        sizeBytes: 1_048_576,
                        sha256: runtimeSHA
                    ),
                    HarvisReceiptArtifactRecord(
                        role: "harvisbar-main",
                        relativePath: "artifacts/HarvisBar",
                        mode: "0755",
                        sizeBytes: 1,
                        sha256: appSHA
                    ),
                    HarvisReceiptArtifactRecord(
                        role: "harvis-system-extension",
                        relativePath: "artifacts/HarvisPerAppProxyExtension",
                        mode: "0755",
                        sizeBytes: 1,
                        sha256: extensionSHA
                    ),
                ]
            ),
            provenance: HarvisReceiptProvenance(
                cacheKey: "personal/harvis/0.36.0+codex.p2-\(String(repeating: "e", count: 64))",
                sha256: String(repeating: "b", count: 64),
                sourceCommit: String(repeating: "1", count: 40),
                sourceTree: String(repeating: "2", count: 40),
                stagedPayloadSha256: String(repeating: "f", count: 64)
            ),
            payload: HarvisReceiptPayload(
                digestAlgorithm: "sha256(path\\0mode\\0size\\0sha256\\0\\n)",
                digestScope: "all files under HarvisPlugin",
                fileCount: 4,
                sha256: String(repeating: "6", count: 64)
            ),
            appRuntimeAllowlist: HarvisReceiptAllowlist(
                relativePath: "packaging/app-runtime-allowlist-v1.txt",
                sha256: String(repeating: "7", count: 64)
            ),
            systemExtension: HarvisReceiptSystemExtension(
                bundleIdentifier: "com.harzva.harvisbar.per-app-proxy",
                bundleName: "HarvisPerAppProxyExtension.systemextension",
                executable: "HarvisPerAppProxyExtension",
                version: "0.36.0"
            )
        )
    }

    private static func taskProgressSnapshot(
        taskID: String,
        percent: Double
    ) -> TaskProgressStatus {
        TaskProgressStatus(
            status: "active",
            summary: "1 synthetic task",
            activeCount: 1,
            current: TaskProgressItem(
                taskId: taskID,
                title: "Harvis candidate",
                kind: "build",
                status: "active",
                summary: "Synthetic local progress",
                detail: "Closed fixture",
                progress: TaskProgressValue(
                    percent: percent,
                    current: Int(percent),
                    total: 100,
                    unit: "percent"
                ),
                metrics: TaskProgressMetrics(
                    elapsed: "1m",
                    eta: "1m",
                    speed: "fixture",
                    itemsPerSecond: nil
                ),
                startedAt: "2026-08-30T00:00:00Z",
                updatedAt: "2026-08-30T00:01:00Z"
            ),
            items: []
        )
    }
}

private struct HarvisVersionTaskProgressFixtureLoader: HarvisTaskProgressLoading {
    let provider: HarvisVersionFixtureProvider

    func load(_ request: HarvisTaskProgressLoadRequest) async throws -> TaskProgressStatus {
        try await provider.loadTaskProgressFixture()
    }
}

@MainActor
private final class HarvisVersionDeferredSourceInspection {
    private var continuation: CheckedContinuation<HarvisSourceInspection, Never>?
    private var resolvedValue: HarvisSourceInspection?

    var isResolved: Bool { resolvedValue != nil }
    var hasWaiter: Bool { continuation != nil }

    func value(onPending: @MainActor () -> Void) async -> HarvisSourceInspection {
        if let resolvedValue { return resolvedValue }
        return await withCheckedContinuation { continuation in
            precondition(self.continuation == nil, "latest-wins A may only have one waiter")
            self.continuation = continuation
            onPending()
        }
    }

    @discardableResult
    func resolve(_ value: HarvisSourceInspection) -> Bool {
        guard resolvedValue == nil else { return false }
        resolvedValue = value
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
        return true
    }
}

protocol HarvisVersionFixtureDefaultsWriting: AnyObject, HarvisSourcePreferenceStoring {
    func clearPersistentDomain()
    func replacePersistentDomain(with values: [String: Any])
    func synchronize() -> Bool
}

private final class HarvisVersionUserDefaultsWriter: HarvisVersionFixtureDefaultsWriting {
    private let suiteName: String
    private let defaults: UserDefaults

    init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.suiteName = suiteName
        self.defaults = defaults
    }

    func clearPersistentDomain() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func replacePersistentDomain(with values: [String: Any]) {
        defaults.setPersistentDomain(values, forName: suiteName)
    }

    func synchronize() -> Bool {
        defaults.synchronize()
    }

    func readSourceRoot() throws -> String? {
        guard synchronize() else {
            throw HarvisSourcePreferenceError.synchronizationFailed
        }
        guard let value = defaults.object(
            forKey: HarvisVersionFixtureProvider.fixtureSourcePreferenceKey
        ) else {
            return nil
        }
        guard let value = value as? String else {
            throw HarvisSourcePreferenceError.invalidStoredValue
        }
        return value
    }

    func writeSourceRoot(_ sourceRoot: String?) throws {
        if let sourceRoot {
            defaults.set(
                sourceRoot,
                forKey: HarvisVersionFixtureProvider.fixtureSourcePreferenceKey
            )
        } else {
            defaults.removeObject(
                forKey: HarvisVersionFixtureProvider.fixtureSourcePreferenceKey
            )
        }
        guard synchronize() else {
            throw HarvisSourcePreferenceError.synchronizationFailed
        }
    }
}
#endif
