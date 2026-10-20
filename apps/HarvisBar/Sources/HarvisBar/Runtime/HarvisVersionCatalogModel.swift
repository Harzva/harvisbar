import Combine
import Darwin
import Foundation
import HarvisVersionCore

struct HarvisVersionCatalogDependencies: Sendable {
    typealias ReceiptInspector = @Sendable () async throws -> HarvisBundleReceiptInspection
    typealias SourceInspector = @Sendable (
        _ selectedDirectory: String?,
        _ receiptCommit: String?
    ) async throws -> HarvisSourceInspection
    typealias SourceValidator = @Sendable (
        _ candidateDirectory: String,
        _ receiptCommit: String?
    ) async throws -> HarvisSourceInspection
    typealias HelperInspector = @Sendable (
        _ receipt: HarvisBundleReceiptInspection
    ) async throws -> HarvisStableHelperSummary

    let inspectReceipt: ReceiptInspector
    let inspectSource: SourceInspector
    let validateSource: SourceValidator
    let inspectHelper: HelperInspector

    init(
        inspectReceipt: @escaping ReceiptInspector,
        inspectSource: @escaping SourceInspector,
        validateSource: SourceValidator? = nil,
        inspectHelper: @escaping HelperInspector
    ) {
        self.inspectReceipt = inspectReceipt
        self.inspectSource = inspectSource
        self.validateSource = validateSource ?? { candidate, receiptCommit in
            try await inspectSource(candidate, receiptCommit)
        }
        self.inspectHelper = inspectHelper
    }
}

@MainActor
/// Swift projection of the proven DSH MobileDeveloperController latest-only
/// contract: begin supersedes the prior request, and publication is guarded by
/// both request generation and current selection scope.
final class HarvisVersionCatalogModel: ObservableObject {
    @Published private(set) var receipt: HarvisBundleReceiptInspection
    @Published private(set) var source: HarvisSourceInspection
    @Published private(set) var helper: HarvisStableHelperSummary?
    @Published private(set) var alignment: HarvisVersionAlignment = .unknown
    @Published private(set) var selection: String?
    @Published private(set) var apiVersion: String?
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false

    let appIdentity: HarvisAppIdentity
    let stableHelperPath: String

    /// Exposed read-only for deterministic latest-wins barriers in tests.
    private(set) var refreshGeneration: UInt64 = 0
    private(set) var selectionEpoch: UInt64 = 0
    private(set) var refreshRequestID: UUID?

    private let preferences: any HarvisSourcePreferenceStoring
    private let dependencies: HarvisVersionCatalogDependencies
    private let apiVersionProvider: @MainActor () -> String?
    private let apiVersionUpdateSequencer = HarvisAPIVersionUpdateSequencer()
    private var apiVersionUpdatesCancellation: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var selectionRequestID: UUID?
    private var selectionRequestGeneration: UInt64 = 0

    init(
        appIdentity: HarvisAppIdentity,
        stableHelperPath: String,
        preferences: any HarvisSourcePreferenceStoring,
        dependencies: HarvisVersionCatalogDependencies,
        apiVersionProvider: @escaping @MainActor () -> String? = { nil },
        apiVersionUpdates: AnyPublisher<String?, Never>? = nil
    ) {
        self.appIdentity = appIdentity
        self.stableHelperPath = stableHelperPath
        self.preferences = preferences
        self.dependencies = dependencies
        self.apiVersionProvider = apiVersionProvider
        receipt = HarvisBundleReceiptInspection(status: .missing)
        helper = nil
        apiVersion = Self.normalizedAPIVersion(apiVersionProvider())

        do {
            let stored = try preferences.readSourceRoot()
            selection = stored
            source = stored.map {
                // Preserve the exact persisted identity until the inspector can
                // prove it ready or classify why it is unavailable. There is no
                // cwd/environment fallback at this boundary.
                HarvisSourceInspection(status: .offline, selectedPath: $0)
            } ?? HarvisSourceInspection(status: .unbound, selectedPath: nil)
        } catch {
            selection = nil
            source = HarvisSourceInspection(status: .unbound, selectedPath: nil)
            self.error = "无法读取源码目录设置，可刷新后重试。"
        }

        let updateSequencer = apiVersionUpdateSequencer
        apiVersionUpdatesCancellation = apiVersionUpdates?
            .map(Self.normalizedAPIVersion)
            .removeDuplicates()
            .sink { [weak self, updateSequencer] value in
                let generation = updateSequencer.next()
                // Combine does not encode the upstream actor in its type. The
                // runtime health source is MainActor-owned, while injected
                // tests may use any synchronous publisher. The generation
                // barrier makes those actor hops latest-wins even when
                // emissions arrive in a burst or from concurrent publishers.
                Task { @MainActor [weak self] in
                    guard
                        updateSequencer.isLatest(generation),
                        let self,
                        self.apiVersion != value
                    else { return }
                    self.apiVersion = value
                }
            }
    }

    static func production(
        apiVersionProvider: @escaping @MainActor () -> String? = { nil },
        apiVersionUpdates: AnyPublisher<String?, Never>? = nil
    ) -> HarvisVersionCatalogModel {
        let bundle = Bundle.main
        let version = HarvisBuildInfo.bundleVersion(bundle: bundle)
        let identity = HarvisAppIdentity(
            bundleIdentifier: "local.harzva.harvisbar",
            executable: "HarvisBar",
            version: version
        )
        let resourcesDirectory = bundle.resourceURL?.path
        let pluginRoot = bundle.resourceURL?
            .appendingPathComponent("HarvisPlugin", isDirectory: true).path
        let homeDirectory = Self.accountHomeDirectory()
        let helperPath = homeDirectory.map { $0 + "/.harvis/bin/harvis" }
            ?? "unavailable"

        let dependencies = HarvisVersionCatalogDependencies(
            inspectReceipt: {
                guard let resourcesDirectory else {
                    return HarvisBundleReceiptInspection(status: .missing)
                }
                return HarvisBundleReceiptReader().inspect(
                    resourcesDirectory: resourcesDirectory,
                    appIdentity: identity
                )
            },
            inspectSource: { selectedDirectory, receiptCommit in
                await HarvisSourceInspector().inspect(
                    selectedDirectory: selectedDirectory,
                    appPluginRoot: pluginRoot,
                    receiptCommit: receiptCommit
                )
            },
            inspectHelper: { receipt in
                guard let homeDirectory else {
                    return Self.unavailableHelper()
                }
                return HarvisStableHelperInspector().inspect(
                    homeDirectory: homeDirectory,
                    receipt: receipt
                )
            }
        )
        return HarvisVersionCatalogModel(
            appIdentity: identity,
            stableHelperPath: helperPath,
            preferences: HarvisSourcePreferenceStore(),
            dependencies: dependencies,
            apiVersionProvider: apiVersionProvider,
            apiVersionUpdates: apiVersionUpdates
        )
    }

    /// Starts a new refresh and immediately supersedes any older request. The
    /// existing snapshot stays visible until the new snapshot is complete.
    func refresh() {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let requestID = UUID()
        let epoch = selectionEpoch
        let selectedDirectory = selection
        let dependencies = dependencies
        refreshRequestID = requestID
        isRefreshing = true
        message = nil
        // A manual snapshot is newer than any publisher delivery already
        // queued for the MainActor. Invalidate those deliveries before
        // publishing the provider's current value.
        apiVersionUpdateSequencer.invalidate()
        apiVersion = Self.normalizedAPIVersion(apiVersionProvider())

        let task = Task { [weak self] in
            let loaded = await Self.loadSnapshot(
                selectedDirectory: selectedDirectory,
                dependencies: dependencies
            )
            guard let self else { return }
            guard
                !Task.isCancelled,
                self.refreshRequestID == requestID,
                self.refreshGeneration == generation,
                self.selectionEpoch == epoch
            else {
                return
            }
            self.publish(loaded, requestID: requestID)
        }
        refreshTask = task
    }

    func cancelRefresh() {
        refreshGeneration &+= 1
        refreshRequestID = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    /// Validates the candidate as a Harvis repository before crossing the only
    /// persistence mutation boundary. Invalid, cancelled, or superseded
    /// selections perform zero writes and leave the prior valid source intact.
    func chooseSource(path: String) async {
        selectionRequestGeneration &+= 1
        let generation = selectionRequestGeneration
        let requestID = UUID()
        selectionRequestID = requestID
        message = nil
        error = nil
        let receiptCommit = receipt.receipt?.provenance.sourceCommit
        let dependencies = dependencies

        let inspected: HarvisSourceInspection
        do {
            inspected = try await dependencies.validateSource(path, receiptCommit)
        } catch {
            guard isCurrentSelection(requestID: requestID, generation: generation) else { return }
            selectionRequestID = nil
            self.error = "无法验证所选目录，请确认它是 Harvis 源码仓库。"
            return
        }
        guard isCurrentSelection(requestID: requestID, generation: generation) else { return }
        guard
            inspected.status == .ready,
            let canonicalRoot = inspected.canonicalRepositoryRoot,
            !canonicalRoot.isEmpty
        else {
            selectionRequestID = nil
            error = Self.selectionFailureMessage(for: inspected.status)
            return
        }
        guard !Task.isCancelled else {
            selectionRequestID = nil
            return
        }

        do {
            // No await is allowed between the current-request guard and this
            // exactly-once write, making the MainActor boundary the linearizer.
            try preferences.writeSourceRoot(canonicalRoot)
        } catch {
            selectionRequestID = nil
            self.error = "源码目录已验证，但无法保存设置。"
            return
        }

        selectionRequestID = nil
        selection = canonicalRoot
        selectionEpoch &+= 1
        source = inspected
        alignment = inspected.alignment
        error = nil
        message = "源码目录已绑定。"
        refresh()
    }

    func clearSource() {
        selectionRequestGeneration &+= 1
        selectionRequestID = nil
        do {
            try preferences.writeSourceRoot(nil)
        } catch {
            self.error = "无法清除源码目录设置。"
            return
        }
        selection = nil
        selectionEpoch &+= 1
        source = HarvisSourceInspection(status: .unbound, selectedPath: nil)
        alignment = .unknown
        error = nil
        message = "已清除源码目录。"
        refresh()
    }

    private func isCurrentSelection(requestID: UUID, generation: UInt64) -> Bool {
        !Task.isCancelled
            && selectionRequestID == requestID
            && selectionRequestGeneration == generation
    }

    private func publish(_ loaded: LoadedSnapshot, requestID: UUID) {
        guard refreshRequestID == requestID else { return }
        receipt = loaded.receipt
        source = loaded.source
        helper = loaded.helper
        alignment = loaded.source.alignment
        error = loaded.hadFailure
            ? "部分版本信息暂不可用；其他已验证信息仍可查看。"
            : nil
        if !loaded.hadFailure, message == nil {
            message = "版本与源码信息已刷新。"
        }
        isRefreshing = false
        refreshRequestID = nil
        refreshTask = nil
    }

    private nonisolated static func loadSnapshot(
        selectedDirectory: String?,
        dependencies: HarvisVersionCatalogDependencies
    ) async -> LoadedSnapshot {
        let receiptResult: HarvisBundleReceiptInspection
        let receiptFailed: Bool
        do {
            receiptResult = try await dependencies.inspectReceipt()
            receiptFailed = false
        } catch {
            receiptResult = HarvisBundleReceiptInspection(status: .ioFailure)
            receiptFailed = true
        }

        async let sourceCapture: CapturedSource = captureSource(
            selectedDirectory: selectedDirectory,
            receiptCommit: receiptResult.receipt?.provenance.sourceCommit,
            inspector: dependencies.inspectSource
        )
        async let helperCapture: CapturedHelper = captureHelper(
            receipt: receiptResult,
            inspector: dependencies.inspectHelper
        )
        let (sourceResult, helperResult) = await (sourceCapture, helperCapture)
        return LoadedSnapshot(
            receipt: receiptResult,
            source: sourceResult.value,
            helper: helperResult.value,
            hadFailure: receiptFailed || sourceResult.failed || helperResult.failed
        )
    }

    private nonisolated static func captureSource(
        selectedDirectory: String?,
        receiptCommit: String?,
        inspector: HarvisVersionCatalogDependencies.SourceInspector
    ) async -> CapturedSource {
        do {
            return CapturedSource(
                value: try await inspector(selectedDirectory, receiptCommit),
                failed: false
            )
        } catch {
            return CapturedSource(
                value: selectedDirectory.map {
                    HarvisSourceInspection(status: .invalid, selectedPath: $0)
                } ?? HarvisSourceInspection(status: .unbound, selectedPath: nil),
                failed: true
            )
        }
    }

    private nonisolated static func captureHelper(
        receipt: HarvisBundleReceiptInspection,
        inspector: HarvisVersionCatalogDependencies.HelperInspector
    ) async -> CapturedHelper {
        do {
            return CapturedHelper(value: try await inspector(receipt), failed: false)
        } catch {
            return CapturedHelper(value: unavailableHelper(), failed: true)
        }
    }

    private nonisolated static func unavailableHelper() -> HarvisStableHelperSummary {
        HarvisStableHelperSummary(
            httpLaunchBindingStatus: .ioFailure,
            tickLaunchBindingStatus: .ioFailure,
            helperFileStatus: .ioFailure,
            receiptMatchStatus: .notEvaluated,
            sizeBytes: nil,
            sha256: nil
        )
    }

    private nonisolated static func accountHomeDirectory() -> String? {
        guard let entry = getpwuid(getuid()), let raw = entry.pointee.pw_dir else {
            return nil
        }
        let value = String(cString: raw)
        guard value.hasPrefix("/"), value != "/", !value.hasSuffix("/") else {
            return nil
        }
        let components = value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return value
    }

    private static func normalizedAPIVersion(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func selectionFailureMessage(for status: HarvisSourceStatus) -> String {
        switch status {
        case .notHarvis:
            return "所选目录不是 Harvis 源码仓库。"
        case .bundlePayload:
            return "不能把 App 内置运行时目录绑定为源码。"
        case .offline:
            return "所选源码目录当前不可访问。"
        case .unsafeGitConfig:
            return "仓库包含不安全的 Git 外部配置，请先移除后重试。"
        case .gitTimeout:
            return "Git 检查超时，请稍后重试。"
        case .gitOutputLimitExceeded:
            return "Git 检查输出超过安全上限。"
        case .ready, .unbound, .invalid:
            return "无法验证所选目录，请确认它是 Harvis 源码仓库。"
        }
    }
}

private final class HarvisAPIVersionUpdateSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func invalidate() {
        _ = next()
    }

    func isLatest(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == generation
    }
}

private struct LoadedSnapshot: Sendable {
    let receipt: HarvisBundleReceiptInspection
    let source: HarvisSourceInspection
    let helper: HarvisStableHelperSummary
    let hadFailure: Bool
}

private struct CapturedSource: Sendable {
    let value: HarvisSourceInspection
    let failed: Bool
}

private struct CapturedHelper: Sendable {
    let value: HarvisStableHelperSummary
    let failed: Bool
}
