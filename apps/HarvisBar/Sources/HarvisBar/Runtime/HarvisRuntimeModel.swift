import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

private let defaultPort = 8765

@MainActor
struct HarvisStartupTasks {
    let deliveryRecovery: Task<Void, Never>
    let managedChatDiscovery: Task<Void, Never>
    let systemRefresh: Task<Void, Never>

    func cancel() {
        deliveryRecovery.cancel()
        managedChatDiscovery.cancel()
        systemRefresh.cancel()
    }
}

@MainActor
enum HarvisStartupScheduler {
    /// Launch startup responsibilities as independent lanes.
    ///
    /// Managed-chat discovery is UI-critical local state and must not wait for
    /// runtime health, proxy, network, or durable delivery recovery work.
    static func launch(
        recoverDelivery: @escaping @MainActor @Sendable () async -> Void,
        discoverManagedChats: @escaping @MainActor @Sendable () async -> Void,
        refreshSystem: @escaping @MainActor @Sendable () async -> Void
    ) -> HarvisStartupTasks {
        HarvisStartupTasks(
            deliveryRecovery: Task { await recoverDelivery() },
            managedChatDiscovery: Task { await discoverManagedChats() },
            systemRefresh: Task { await refreshSystem() }
        )
    }
}

enum HarvisPermissionVerificationState: Equatable, Sendable {
    case unverified
    case verifiedReady
    case verifiedBlocked
    case stale
}

/// Identifies one asynchronous operation against one observed Codex account.
///
/// A Home ID is stable across account replacements, so it cannot by itself
/// own loading or action state. The generation is bumped whenever the account
/// identity at that ID changes; late completions from an earlier generation
/// must not clear or publish state for the replacement account.
struct CodexHomeRequestToken: Equatable {
    let homeID: String
    let identity: CodexAccountIdentity
    let generation: UInt64
}

/// Closed projection for the write-backed permission probe.
///
/// The regular two-second runtime refresh must not mistake the API's
/// lightweight `ok=true` response for a Full Disk Access verification. Keep
/// `writesSkipped` and the exact three checks until the response has crossed
/// this boundary, then project it into the legacy UI model.
struct HarvisFullPermissionProbePayload: Decodable, Equatable, Sendable {
    struct Check: Decodable, Equatable, Sendable {
        let label: String?
        let ok: Bool?
        let exists: Bool?
        let writable: Bool?
    }

    let ok: Bool
    let context: String?
    let redacted: Bool?
    let includesLocalAbsolutePaths: Bool?
    let writesSkipped: Bool?
    let checks: [Check]?

    private static let expectedLabels = [
        "workspace-root",
        "workspace-harvis",
        "profile-root",
    ]

    var isCompleteFullProbe: Bool {
        guard context == "rust-http-api",
              writesSkipped != true,
              redacted == true,
              includesLocalAbsolutePaths == false,
              let checks,
              checks.count == Self.expectedLabels.count,
              checks.map(\.label).allSatisfy({ $0 != nil }),
              checks.compactMap(\.label) == Self.expectedLabels else {
            return false
        }
        return checks.allSatisfy {
            $0.ok != nil && $0.exists != nil && $0.writable != nil
        }
    }

    var isVerifiedReady: Bool {
        guard isCompleteFullProbe, ok, let checks else { return false }
        return checks.allSatisfy {
            $0.ok == true && $0.exists == true && $0.writable == true
        }
    }

    var legacyProjection: PermissionProbe {
        PermissionProbe(
            ok: ok,
            context: context,
            redacted: redacted,
            includesLocalAbsolutePaths: includesLocalAbsolutePaths,
            checks: checks?.map {
                PermissionProbeCheck(
                    label: $0.label,
                    ok: $0.ok,
                    exists: $0.exists,
                    writable: $0.writable
                )
            }
        )
    }
}

@MainActor
final class HarvisRuntimeModel: ObservableObject {
    typealias PermissionProbeLoader = @MainActor @Sendable (
        _ query: [URLQueryItem]
    ) async throws -> HarvisFullPermissionProbePayload

    static let fullPermissionProbeRefreshInterval: TimeInterval = 300

    let perAppProxy = PerAppProxyModel()
    @Published var workspaceRoot: String {
        didSet {
            defaults.set(workspaceRoot, forKey: Keys.workspaceRoot)
            if workspaceRoot != oldValue { invalidatePermissionProbeScope() }
        }
    }
    @Published var profileRoot: String {
        didSet {
            defaults.set(profileRoot, forKey: Keys.profileRoot)
            if profileRoot != oldValue { invalidatePermissionProbeScope() }
        }
    }
    @Published var pluginRoot: String {
        didSet { defaults.set(pluginRoot, forKey: Keys.pluginRoot) }
    }
    @Published var portText: String {
        didSet {
            defaults.set(portText, forKey: Keys.portText)
            if portText != oldValue { invalidatePermissionProbeScope() }
        }
    }
    @Published var themeID: String {
        didSet { defaults.set(themeID, forKey: Keys.themeID) }
    }
    @Published var catopCommand: String {
        didSet { defaults.set(catopCommand, forKey: Keys.catopCommand) }
    }
    @Published var favoriteFolderPaths: [String] {
        didSet { defaults.set(favoriteFolderPaths, forKey: Keys.favoriteFolderPaths) }
    }
    @Published var health: HealthData?
    @Published var barStatus: BarStatus?
    @Published private(set) var taskProgressLastSuccess: TaskProgressStatus?
    @Published private(set) var taskProgressFailure: HarvisTaskProgressFailure?
    @Published private(set) var taskProgressLastSuccessAt: Date?
    @Published private(set) var isTaskProgressRefreshing = false
    @Published var permissionProbe: PermissionProbe?
    @Published private(set) var permissionVerificationState: HarvisPermissionVerificationState = .unverified
    @Published private(set) var isPermissionProbeRefreshing = false
    @Published var services: ServiceManagerStatus?
    @Published var harnessTestResult: AgentHarnesses?
    @Published var agentMailSummary: AgentMailSummary?
    @Published var proxyStatus: ProxyManagerStatus?
    @Published var systemInfo = SystemInfo(
        cpuPercent: nil,
        perCorePercent: [],
        thermalState: .nominal,
        cpuTemperatureCelsius: nil,
        hardware: .unknown,
        gpu: .unavailable
    )
    @Published var remoteStudio: RemoteStudioMetrics?
    @Published var disks: [DiskInfo] = []
    @Published var codexProcesses = CodexProcessSnapshot.empty
    @Published var codexCLIAlignment: CodexCLIAlignmentStatus?
    @Published var codexCLIAlignmentError: String?
    @Published var codexCLIAlignmentMessage: String?
    @Published var isCodexCLIRefreshing = false
    @Published var isCodexCLIAligning = false
    @Published var harnessTestingIDs: Set<String> = []
    @Published var agentLauncherOpeningIDs: Set<String> = []
    @Published var lastError: String?
    @Published var lastActionOutput: String?
    @Published var codexArchiveResult: CodexArchiveResult?
    @Published var codexHomes: [CodexHome] = [] {
        didSet {
            invalidateManagedChatCatalog()
            invalidateChangedCodexAccountDetails(previous: oldValue)
        }
    }
    @Published var codexHomeQuotas: [String: CodexHomeQuota] = [:]
    @Published var codexHomeQuotaErrors: [String: String] = [:]
    @Published var codexHomeQuotaLoadingIDs: Set<String> = []
    @Published var codexHomeQuotaUpdatedAt: [String: Date] = [:]
    var codexHomeQuotaAttemptedAt: [String: Date] = [:]
    @Published var codexHomeActionFeedback: [String: CodexAccountActionFeedback] = [:]
    @Published var selectedCodexHomeID: String? {
        didSet {
            defaults.set(selectedCodexHomeID, forKey: Keys.selectedCodexHomeID)
            guard oldValue != selectedCodexHomeID else { return }
            projectCodexThreadSnapshot(for: selectedCodexHomeID)
        }
    }
    @Published var codexHomeWorkspaces: [String: String] {
        didSet { defaults.set(codexHomeWorkspaces, forKey: Keys.codexHomeWorkspaces) }
    }
    @Published var hiddenCodexHomeIDs: Set<String> {
        didSet {
            defaults.set(hiddenCodexHomeIDs.sorted(), forKey: Keys.hiddenCodexHomeIDs)
            invalidateManagedChatCatalog()
        }
    }
    @Published var codexThreads: [CodexThreadSummary] = [] {
        didSet { invalidateManagedChatCatalog() }
    }
    @Published var codexThreadSnapshotsByHomeID: [String: CodexThreadSnapshot] = [:] {
        didSet { invalidateManagedChatCatalog() }
    }
    @Published var codexThreadRefreshingHomeIDs: Set<String> = []
    /// Immutable provenance for the currently accepted `codexThreads` batch.
    ///
    /// Thread IDs are not globally unique across CODEX_HOME directories. Keep
    /// the fetch scope beside the batch so an account switch can never relabel
    /// an old result with the newly selected Home.
    @Published private(set) var codexThreadsSourceHomeID: String? {
        didSet { invalidateManagedChatCatalog() }
    }
    let dshConversationSender = DshConversationSender()
    let codexDesktopCoordinator = CodexDesktopCoordinator()
    var codexHomeActionCounts: [String: Int] = [:]
    var codexHomeRequestGenerations: [String: UInt64] = [:]
    @Published var dshThreads: [ManagedChatThread] = [] {
        didSet { invalidateManagedChatCatalog() }
    }
    /// Complete catalog of currently running DSH endpoints, retaining every
    /// port. The scope-indexed map below intentionally serves conversation
    /// actions and cannot represent same-scope ambiguity safely.
    @Published var dshRunningEndpoints: [DshRuntimeEndpoint] = [] {
        didSet { managedDisplayAccountCache = nil }
    }
    @Published var dshRuntimeEndpointsByScope: [String: DshRuntimeEndpoint] = [:]
    @Published var dshBridgeStatesByScope: [String: DshBridgeEndpointState] = [:]
    @Published var supervisorSnapshots: [String: ManagedSupervisorSnapshot] = [:]
    @Published var supervisorErrors: [String: String] = [:]
    @Published var supervisorIssueKinds: [String: ManagedSupervisorIssueKind] = [:]
    @Published var supervisorBusyThreadIDs: Set<String> = []
    var makeDshBridgeClient: @Sendable (DshRuntimeEndpoint) -> DshCapabilityBridgeClient = {
        DshCapabilityBridgeClient(endpoint: $0)
    }
    @Published var dshThreadErrorsByEndpoint: [String: String] = [:]
    @Published var workBuddyThreads: [WorkBuddyThreadSummary] = [] {
        didSet { invalidateManagedChatCatalog() }
    }
    @Published var codexThreadTags: [String: [String]] = [:]
    @Published var pinnedCodexThreadKeys: Set<String> = []
    @Published var visibleUnnamedSubagentKeys: Set<String> = []
    @Published var managedProjectAttention: [String: ManagedAttentionPreference] = [:]
    @Published var managedConversationAttention: [String: ManagedAttentionPreference] = [:]
    @Published var managedProjectOrganization = ManagedProjectOrganizationState() {
        didSet { invalidateManagedChatCatalog() }
    }
    var managedConversationProjectAssignments: [String: ManagedChatProjectAssignment] {
        managedProjectOrganization.assignments
    }
    @Published var projectOrganizerProposal: ManagedProjectOrganizerProposal?
    @Published var projectOrganizerIsAnalyzing = false
    @Published var projectOrganizerIsApplying = false
    @Published var projectOrganizerProgress = ""
    @Published var projectOrganizerCoverage = "尚未分析"
    @Published var projectOrganizerError: String?
    @Published var projectOrganizerFeedback: String?
    @Published var projectOrganizationLoadError: String?
    var projectOrganizerTask: Task<Void, Never>?
    var projectOrganizerGeneration: UUID?
    var projectOrganizerScopeConversationIDs: [String] = []
    @Published var projectGroupxReviewJob: DshGroupxReviewJob?
    @Published var projectGroupxReviewMessage: String?
    @Published var projectGroupxReviewBusy = false
    var projectGroupxReviewIdentity: DshGroupxReviewIdentity?
    var projectGroupxReviewEndpoint: DshRuntimeEndpoint?
    var projectGroupxReviewAuthority: DshBridgeAuthority?
    var projectGroupxReviewFingerprint: String?
    var projectGroupxReviewTask: Task<Void, Never>?
    var projectGroupxReviewGeneration: UUID?
    @Published var projectGroupxReviewSelectedScope: String?
    @Published var managedProjectTaskPlans: [String: ManagedProjectTaskPlan] = [:] {
        didSet { managedInsightCatalogCache = nil }
    }
    @Published var managedProjectTaskPlanFreshness: [String: ManagedGovernanceFreshness] = [:] {
        didSet { managedInsightCatalogCache = nil }
    }
    @Published var managedProjectTaskSummaries: [String: ManagedProjectTaskSummary] = [:]
    @Published var managedProjectTaskSummaryFreshness: [String: ManagedGovernanceFreshness] = [:]
    @Published var codexConversationMetrics: [String: CodexConversationMetrics] = [:]
    @Published var codexConversationMetricsFreshness: [String: ManagedGovernanceFreshness] = [:]
    @Published var codexConversationMetricsLoadingKeys: Set<String> = []
    @Published var managedGovernanceErrors: [String: String] = [:]
    @Published var conversationManagementErrors: [String: String] = [:]
    @Published private(set) var conversationManagementSnapshots: [
        String: ConversationManagementSnapshotV1
    ] = [:]
    @Published private(set) var conversationManagementProjectStatuses: [
        String: DshMetaAgentProjectStatus
    ] = [:]
    @Published private(set) var conversationManagementLatestLedgers: [
        String: ConversationManagementProgressLedgerV1
    ] = [:]
    @Published var codexEvidenceStates: [String: CodexInspectorTimelineState] = [:]
    @Published var codexEvidenceLoadingKeys: Set<String> = []
    @Published var codexEvidenceErrors: [String: String] = [:]
    @Published var managedConversationInputStates: [
        String: ManagedConversationUserInputState
    ] = [:]
    /// Bumps after durable insight state changes so task cards can refresh
    /// their relevance badge without retaining raw conversation bodies.
    @Published var managedConversationInsightRevision: UInt64 = 0
    @Published var isCodexChatWindowPinned: Bool {
        didSet {
            defaults.set(isCodexChatWindowPinned, forKey: Keys.codexChatWindowPinned)
            HarvisCodexChatWindowController.shared.setPinned(isCodexChatWindowPinned)
        }
    }
    @Published var isCodexChatWindowDockingEnabled: Bool {
        didSet {
            defaults.set(isCodexChatWindowDockingEnabled, forKey: Keys.codexChatWindowDockingEnabled)
            HarvisCodexChatWindowController.shared.setDockingEnabled(isCodexChatWindowDockingEnabled)
        }
    }
    @Published var isCodexChatWindowAttachmentLocked: Bool {
        didSet {
            defaults.set(
                isCodexChatWindowAttachmentLocked,
                forKey: Keys.codexChatWindowAttachmentLocked
            )
            HarvisCodexChatWindowController.shared.setAttachmentLocked(
                isCodexChatWindowAttachmentLocked
            )
        }
    }
    @Published var isCodexChatWindowDocked = false
    @Published var codexChatWindowDockSide: String?
    @Published var codexThreadError: String?
    @Published var dshThreadError: String?
    @Published var workBuddyThreadError: String?
    @Published var codexHomeWarnings: [String] = []
    @Published var codexHomeActionIDs: Set<String> = []
    @Published var isBusy = false
    @Published var isRefreshing = false
    @Published var isMailRefreshing = false
    @Published var isCodexHomeRefreshing = false
    @Published var isDshThreadRefreshing = false
    @Published var isWorkBuddyThreadRefreshing = false
    @Published var isProxyRefreshing = false
    @Published var catopStatus: CatopStatus?
    @Published var catopError: String?
    @Published var isCatopRefreshing = false
    @Published var isNetworkActionRunning = false
    @Published var networkActionSummary = "Ready"
    @Published var isCredentialSaving = false
    @Published var credentialActionMessage = "只保存到本地私有 JSON · 不调用模型"
    @Published var credentialActionSucceeded = true
    @Published var quickCredentialAgentHint: QuickCredentialAgentHint?
    @Published var isFileCopying = false
    @Published var fileCopyMessage = "拖入文件后选择目标目录"
    @Published var fileCopySucceeded = true

    enum Keys {
        static let workspaceRoot = "harvisBar.workspaceRoot"
        static let profileRoot = "harvisBar.profileRoot"
        static let pluginRoot = "harvisBar.pluginRoot"
        static let portText = "harvisBar.portText"
        static let themeID = "harvisBar.themeID"
        static let catopCommand = "harvisBar.catopCommand"
        static let favoriteFolderPaths = "harvisBar.favoriteFolderPaths"
        static let selectedCodexHomeID = "harvisBar.selectedCodexHomeID"
        static let codexHomeWorkspaces = "harvisBar.codexHomeWorkspaces"
        static let hiddenCodexHomeIDs = "harvisBar.hiddenCodexHomeIDs"
        static let codexChatWindowPinned = "harvisBar.codexChatWindowPinned"
        static let codexChatWindowDockingEnabled = "harvisBar.codexChatWindowDockingEnabled"
        static let codexChatWindowAttachmentLocked = "harvisBar.codexChatWindowAttachmentLocked"
    }

    let defaults: UserDefaults
    /// Immutable asset source selected at launch. Runtime configuration edits
    /// must not turn avatar rendering into repeated reads from removable or
    /// network volumes.
    let personaAssetRoot: String
    let avatarImageLoadCache = HarvisAvatarImageLoadCache()
    let codexPreferences: CodexThreadPreferences
    let projectOrganizationStore: ManagedProjectOrganizationStore
    let codexTaskDelivery: CodexTaskDeliveryCoordinator
    let codexThreadSnapshotStore: any CodexThreadSnapshotStoring
    let dshMetaAgentCoordinator: DshMetaAgentCoordinator
    let managedConversationInsights: ManagedConversationInsightCoordinator
    let taskProgressLoader: any HarvisTaskProgressLoading
    let taskProgressDidPublish: (@MainActor @Sendable (HarvisTaskProgressPublishEvent) -> Void)?
    let permissionProbeLoader: PermissionProbeLoader?
    var timer: AnyCancellable?
    var conversationManagementStateObserver: AnyCancellable?
    var conversationManagementDeliveryObserver: AnyCancellable?
    var conversationManagementReconcileTask: Task<Void, Never>?
    var conversationManagementReconcilePending = false
    var conversationManagementReconcileGeneration: UInt64 = 0
    var startupTasks: HarvisStartupTasks?
    var taskProgressLoadTask: Task<TaskProgressStatus, Error>?
    var taskProgressLoadGeneration: UInt64 = 0
    var permissionProbeLoadTask: Task<HarvisFullPermissionProbePayload, Error>?
    var permissionProbeLoadGeneration: UInt64 = 0
    var lastFullPermissionProbeAttemptAt: Date?
    var lastCompletePermissionProbeAt: Date?
    var previousCPUTicks: CPUTicks?
    var previousPerCoreTicks: [CPUTicks]?
    var lastDiskSampleAt: Date?
    var diskRefreshTask: Task<Void, Never>?
    var lastProxyRefreshAt: Date?
    var lastRemoteStudioRefreshAt: Date?
    var lastCodexThreadRefreshAtByHomeID: [String: Date] = [:]
    var lastCodexHomeDiscoveryFingerprint: CodexHomeDiscoveryFingerprint?
    var lastDshThreadRefreshAt: Date?
    var dshThreadCacheByScope: [String: [ManagedChatThread]] = [:]
    var codexConversationMetricsUpdatedAt: [String: Int64] = [:]
    var codexConversationMetricsAttemptedAt: [String: Date] = [:]
    var managedProjectTaskPlansUpdatedAt: [String: Date] = [:]
    var managedProjectTaskPlanRefreshTasks: [String: Task<Void, Never>] = [:]
    var managedConversationInputLoadGenerations: [String: Int] = [:]
    /// Test seam for the authoritative task-plan read. Production leaves this
    /// nil and executes the bundled `harvis agent-room ... task-plan` command.
    var projectTaskPlanAuthorityLoader: ((
        ManagedChatProjectIdentity
    ) async throws -> ManagedProjectTaskPlan)?
    var lastCatopRefreshAt: Date?
    var lastCodexCLIAlignmentRefreshAt: Date?
    let systemHardware = SystemHardwareSampler.hardwareInfo()

    init(
        defaults: UserDefaults = .standard,
        codexPreferences: CodexThreadPreferences? = nil,
        codexTaskDelivery: CodexTaskDeliveryCoordinator? = nil,
        codexThreadSnapshotStore: (any CodexThreadSnapshotStoring)? = nil,
        dshMetaAgentCoordinator: DshMetaAgentCoordinator? = nil,
        managedConversationInsights: ManagedConversationInsightCoordinator? = nil,
        taskProgressLoader: any HarvisTaskProgressLoading = HarvisTaskProgressClient(),
        taskProgressInitialSnapshot: TaskProgressStatus? = nil,
        taskProgressDidPublish: (@MainActor @Sendable (HarvisTaskProgressPublishEvent) -> Void)? = nil,
        permissionProbeLoader: PermissionProbeLoader? = nil
    ) {
        let delivery = codexTaskDelivery ?? CodexTaskDeliveryCoordinator()
        self.defaults = defaults
        self.codexPreferences = codexPreferences ?? CodexThreadPreferences(defaults: defaults)
        self.projectOrganizationStore = ManagedProjectOrganizationStore(defaults: defaults)
        self.codexTaskDelivery = delivery
        self.codexThreadSnapshotStore = codexThreadSnapshotStore ?? CodexThreadSnapshotStore()
        self.dshMetaAgentCoordinator = dshMetaAgentCoordinator
            ?? DshMetaAgentCoordinator(codexDispatcher: delivery)
        self.managedConversationInsights = managedConversationInsights
            ?? ManagedConversationInsightCoordinator()
        self.taskProgressLoader = taskProgressLoader
        self.taskProgressDidPublish = taskProgressDidPublish
        self.permissionProbeLoader = permissionProbeLoader
        taskProgressLastSuccess = taskProgressInitialSnapshot
        taskProgressLastSuccessAt = taskProgressInitialSnapshot == nil ? nil : Date()
        workspaceRoot = defaults.string(forKey: Keys.workspaceRoot)
            ?? ProcessInfo.processInfo.environment["HARVIS_WORKSPACE_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        profileRoot = defaults.string(forKey: Keys.profileRoot)
            ?? ProcessInfo.processInfo.environment["HARVIS_PROFILE_ROOT"]
            ?? "~/.harvis"
        let bundledPluginRoot = Self.detectBundledPluginRoot()
        let detectedPluginRoot = Self.detectPluginRoot(
            bundledPluginRoot: bundledPluginRoot
        )
        let storedPluginRoot = defaults.string(forKey: Keys.pluginRoot)
        let resolvedPluginRoot = Self.resolveInitialPluginRoot(
            stored: storedPluginRoot,
            detected: detectedPluginRoot,
            bundledPluginRoot: bundledPluginRoot
        )
        pluginRoot = resolvedPluginRoot
        personaAssetRoot = resolvedPluginRoot
        if storedPluginRoot != nil, storedPluginRoot != resolvedPluginRoot {
            defaults.set(resolvedPluginRoot, forKey: Keys.pluginRoot)
        }
        portText = defaults.string(forKey: Keys.portText) ?? String(defaultPort)
        themeID = defaults.string(forKey: Keys.themeID) ?? HarvisTheme.glass.rawValue
        catopCommand = defaults.string(forKey: Keys.catopCommand)
            ?? ProcessInfo.processInfo.environment["HARVIS_CATOP_COMMAND"]
            ?? "catop"
        favoriteFolderPaths = defaults.stringArray(forKey: Keys.favoriteFolderPaths)
            ?? Self.defaultFavoriteFolderPaths()
        selectedCodexHomeID = defaults.string(forKey: Keys.selectedCodexHomeID)
        codexHomeWorkspaces = defaults.dictionary(forKey: Keys.codexHomeWorkspaces) as? [String: String]
            ?? [:]
        hiddenCodexHomeIDs = Set(defaults.stringArray(forKey: Keys.hiddenCodexHomeIDs) ?? [])
        isCodexChatWindowPinned = defaults.bool(forKey: Keys.codexChatWindowPinned)
        isCodexChatWindowDockingEnabled =
            defaults.object(forKey: Keys.codexChatWindowDockingEnabled) as? Bool ?? true
        isCodexChatWindowAttachmentLocked =
            defaults.bool(forKey: Keys.codexChatWindowAttachmentLocked)
        codexThreadTags = self.codexPreferences.loadTags()
        pinnedCodexThreadKeys = self.codexPreferences.loadPins()
        visibleUnnamedSubagentKeys = self.codexPreferences.loadVisibleUnnamedSubagents()
        managedProjectAttention = self.codexPreferences.loadProjectAttention()
        managedConversationAttention = self.codexPreferences.loadConversationAttention()
        do {
            managedProjectOrganization = try projectOrganizationStore.load(
                legacyAssignments: self.codexPreferences.loadProjectAssignments()
            )
        } catch {
            // Preserve the source store and disable organization writes. A
            // corrupt new envelope must never be replaced by an empty one.
            projectOrganizationLoadError = error.localizedDescription
        }
    }

    /// Centralizes mutation of the published management cache while allowing
    /// the runtime integration to live in a focused extension file.
    func replaceConversationManagementPublishedState(
        snapshots: [String: ConversationManagementSnapshotV1],
        statuses: [String: DshMetaAgentProjectStatus],
        latestLedgers: [String: ConversationManagementProgressLedgerV1]
    ) {
        conversationManagementSnapshots = snapshots
        conversationManagementProjectStatuses = statuses
        conversationManagementLatestLedgers = latestLedgers
    }

    var port: Int {
        let value = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultPort
        return max(1, min(value, 65535))
    }

    var rawRuntimeState: String {
        if let state = barStatus?.runtime?.state, !state.isEmpty {
            return state
        }
        if health != nil {
            return "verified"
        }
        return "blocked"
    }

    var currentState: String {
        Self.normalizeState(rawRuntimeState)
    }

    var stateCaption: String {
        switch currentState {
        case "idle": return "standing by"
        case "reading": return "scanning local state"
        case "thinking": return "planning safely"
        case "acting": return "running approved work"
        case "verified": return "checked and ready"
        case "blocked": return "needs human review"
        default: return "watching runtime"
        }
    }

    var shortSummary: String {
        if let summary = barStatus?.runtime?.summary, !summary.isEmpty {
            return summary
        }
        if health != nil {
            return "HTTP API is reachable."
        }
        return "HTTP API is offline or needs start."
    }

    var tintColor: Color {
        switch currentState {
        case "idle": return Color(hex: 0x0891B2)
        case "reading": return Color(hex: 0x0E7490)
        case "thinking": return Color(hex: 0xB45309)
        case "acting": return .purple
        case "verified": return Color(hex: 0x15803D)
        case "blocked": return Color(hex: 0xDC2626)
        default: return .secondary
        }
    }

    var theme: HarvisTheme {
        HarvisTheme(rawValue: themeID) ?? .glass
    }

    var displayedHarnesses: AgentHarnesses? {
        harnessTestResult ?? barStatus?.agentHarnesses
    }

    var importantPorts: [PortStatusItem] {
        (barStatus?.ports?.items ?? [])
            .filter { $0.important == true }
            .sorted { ($0.port ?? 0) < ($1.port ?? 0) }
    }

    var dshInstances: [PortStatusItem] {
        (barStatus?.ports?.items ?? [])
            .filter { $0.serviceGroup == "dsh" && $0.listening == true }
            .sorted { ($0.port ?? 0) < ($1.port ?? 0) }
    }

    var serviceManagerPath: String {
        Self.resolveServiceManagerPath(
            pluginRoot: expanded(pluginRoot),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    static func resolveServiceManagerPath(
        pluginRoot: String,
        homeDirectory: String,
        isExecutable: (String) -> Bool
    ) -> String {
        let pluginWrapper = URL(fileURLWithPath: pluginRoot, isDirectory: true)
            .appendingPathComponent("scripts/harvis")
            .path
        if isExecutable(pluginWrapper) {
            return pluginWrapper
        }
        let stableHelper = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".harvis/bin/harvis")
            .path
        if isExecutable(stableHelper) {
            return stableHelper
        }
        return pluginWrapper
    }

    var proxyManagerPath: String {
        expanded("\(pluginRoot)/scripts/harvis_proxy_manager.py")
    }

    var selectedCodexHome: CodexHome? {
        if let selectedCodexHomeID,
           let selected = visibleCodexHomes.first(where: { $0.id == selectedCodexHomeID }) {
            return selected
        }
        return visibleCodexHomes.first
    }

    var isCodexThreadRefreshing: Bool {
        guard let selectedCodexHomeID else { return false }
        return codexThreadRefreshingHomeIDs.contains(selectedCodexHomeID)
    }

    var hasSelectedCodexThreadSnapshot: Bool {
        guard let selectedCodexHomeID else { return false }
        return codexThreadSnapshotsByHomeID[selectedCodexHomeID] != nil
    }

    var visibleCodexHomes: [CodexHome] {
        canonicalCodexAccounts(
            codexHomes.filter {
                $0.isCodexAccountCandidate && !hiddenCodexHomeIDs.contains($0.id)
            }
        )
    }

    var hiddenCodexHomes: [CodexHome] {
        canonicalCodexAccounts(
            codexHomes.filter {
                $0.isCodexAccountCandidate && hiddenCodexHomeIDs.contains($0.id)
            }
        )
    }

    var invalidVisibleCodexHomes: [CodexHome] {
        visibleCodexHomes.filter(\.isAuthInvalid)
    }

    func codexWorkspacePath(for home: CodexHome) -> String {
        codexHomeWorkspaces[home.id] ?? expanded(workspaceRoot)
    }

    func codexWorkspaceLabel(for home: CodexHome) -> String {
        let path = codexWorkspacePath(for: home)
        let label = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return label.isEmpty ? path : label
    }

    func hasDedicatedCodexWorkspace(for home: CodexHome) -> Bool {
        codexHomeWorkspaces[home.id] != nil
    }

    func codexHomeIDs(forAccount home: CodexHome) -> Set<String> {
        let accountGroupingKey = home.accountGroupingKey
        return Set(codexHomes.filter { $0.accountGroupingKey == accountGroupingKey }.map(\.id))
    }

    private func canonicalCodexAccounts(_ homes: [CodexHome]) -> [CodexHome] {
        Dictionary(grouping: homes, by: \.accountGroupingKey)
        .values
        .compactMap { homes in
            if let defaultHome = homes.first(where: { $0.source == "default" }) {
                return defaultHome
            }
            if let selectedCodexHomeID,
               let selected = homes.first(where: { $0.id == selectedCodexHomeID }) {
                return selected
            }
            return homes.sorted(by: preferredCodexAccountHome).first
        }
        .sorted {
            $0.accountDisplayLabel.localizedCaseInsensitiveCompare($1.accountDisplayLabel)
                == .orderedAscending
        }
    }

    private func preferredCodexAccountHome(_ left: CodexHome, _ right: CodexHome) -> Bool {
        let authRanks = [
            "valid": 0,
            "configured": 1,
            "refresh-needed": 2,
            "unknown": 3,
            "expired": 4,
            "invalid": 5,
            "missing": 6
        ]
        let leftAuth = authRanks[left.normalizedAuthStatus] ?? 3
        let rightAuth = authRanks[right.normalizedAuthStatus] ?? 3
        if leftAuth != rightAuth { return leftAuth < rightAuth }

        let sourceRanks = [
            "default": 0,
            "open-codex-launcher": 1,
            "managed-agent": 2,
            "codexuse-desktop": 3
        ]
        let leftSource = sourceRanks[left.source] ?? 4
        let rightSource = sourceRanks[right.source] ?? 4
        if leftSource != rightSource { return leftSource < rightSource }
        return left.path < right.path
    }

    var runningCodexThreads: [CodexThreadSummary] {
        codexThreads.filter(\.isCardRunning)
    }

    var recentCodexThreads: [CodexThreadSummary] {
        codexThreads.filter { !$0.isCardRunning }
    }

    private var unmanagedChatThreads: [ManagedChatThread] {
        let codexProjection = visibleCodexHomes.flatMap { home in
            let threads = codexThreadSnapshotsByHomeID[home.id]?.threads
                ?? (codexThreadsSourceHomeID == home.id ? codexThreads : [])
            return threads.map { ManagedChatThread(codex: $0, sourceScope: home.id) }
        }
        return codexProjection
            + dshThreads
            + workBuddyThreads.map(ManagedChatThread.init(workBuddy:))
    }

    private var managedInsightCatalogCache: ManagedInsightCatalogSnapshot?
    private var managedChatProjectionCache: (createdAt: TimeInterval, threads: [ManagedChatThread])?
    private var managedDisplayAccountCache: [ManagedChatDisplayAccount]?

    private func invalidateManagedChatCatalog() {
        managedInsightCatalogCache = nil
        managedChatProjectionCache = nil
        managedDisplayAccountCache = nil
    }

    var managedChatDisplayAccounts: [ManagedChatDisplayAccount] {
        if let cached = managedDisplayAccountCache { return cached }
        let catalog = ManagedChatDisplayAccount.catalog(
            homes: visibleCodexHomes,
            dshEndpoints: dshRunningEndpoints,
            threads: managedChatThreads
        )
        managedDisplayAccountCache = catalog
        return catalog
    }

    var cachedManagedInsightCatalog: ManagedInsightCatalogSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = managedInsightCatalogCache, now - cached.createdAt < 5 {
            return cached
        }
        let projects = managedChatProjectCatalog
        let snapshot = ManagedInsightCatalogSnapshot(
            createdAt: now,
            projects: projects,
            candidates: ManagedConversationInsightProjectCatalog.candidates(
                projects: projects, threads: managedChatThreads,
                taskPlans: managedProjectTaskPlans, taskFreshness: managedProjectTaskPlanFreshness
            ),
            candidateMap: ManagedConversationInsightProjectCatalog.candidateMap(projects: projects)
        )
        managedInsightCatalogCache = snapshot
        return snapshot
    }

    var managedChatThreads: [ManagedChatThread] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = managedChatProjectionCache, now - cached.createdAt < 5 {
            return cached.threads
        }
        let threads = unmanagedChatThreads.map { source in
            var projected = source
            projected.managementProjectAssignment =
                managedConversationProjectAssignments[managedChatStorageKey(source)]
            return projected
        }
        // Data changes invalidate immediately; the short lifetime also keeps
        // time-derived trust labels fresh without rebuilding on every keypress.
        managedChatProjectionCache = (now, threads)
        return threads
    }

    /// All project identities that can be selected as a Harvis management
    /// destination. Source projects remain in the catalog even when every card
    /// has temporarily been organized elsewhere.
    var managedChatProjectCatalog: [ManagedChatProjectIdentity] {
        var projects: [String: ManagedChatProjectIdentity] = [:]
        for thread in unmanagedChatThreads {
            let source = ManagedChatProjectResolver.resolveSource(thread: thread)
            projects[source.id] = source
        }
        for assignment in managedConversationProjectAssignments.values {
            projects[assignment.project.id] = assignment.project
        }
        for record in managedProjectOrganization.projects.values {
            projects[record.id] = record.identity
        }
        let hierarchy = ManagedProjectHierarchy(
            catalog: Array(projects.values),
            records: managedProjectOrganization.projects,
            threads: managedChatThreads
        )
        for node in hierarchy.nodes where node.isContainer {
            projects[node.id] = node.project
        }
        return projects.values.sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedAscending
                || (order == .orderedSame && $0.id < $1.id)
        }
    }

    func acceptCodexThreads(
        _ threads: [CodexThreadSummary],
        sourceHomeID: String
    ) {
        // Every account keeps its own batch; management selection only affects
        // the legacy single-account popover, never the combined card catalog.
        codexThreadSnapshotsByHomeID[sourceHomeID] = CodexThreadSnapshot(
            updatedAt: Date(), threads: threads
        )
        guard selectedCodexHomeID == sourceHomeID else { return }
        // Publish provenance first. If this is a same-Home refresh, the old
        // batch already has the same identity; after a switch it was cleared.
        codexThreadsSourceHomeID = sourceHomeID
        codexThreads = threads
    }

    func projectCodexThreadSnapshot(for homeID: String?) {
        codexThreadError = nil
        guard let homeID,
              let snapshot = codexThreadSnapshotsByHomeID[homeID] else {
            codexThreads = []
            codexThreadsSourceHomeID = nil
            return
        }
        codexThreadsSourceHomeID = homeID
        codexThreads = snapshot.threads
    }

    /// Resolve the card's origin, never fall back to the management account.
    func codexHome(for thread: ManagedChatThread) -> CodexHome? {
        guard thread.isCodex,
              let home = visibleCodexHomes.first(where: { $0.id == thread.sourceScope }) else {
            return nil
        }
        let threads = codexThreadSnapshotsByHomeID[home.id]?.threads
            ?? (codexThreadsSourceHomeID == home.id ? codexThreads : [])
        guard threads.contains(where: { $0.id == thread.sourceID }) else { return nil }
        return home
    }

    func selectedCodexHome(for thread: ManagedChatThread) -> CodexHome? {
        guard thread.isCodex,
              let home = selectedCodexHome,
              home.id == thread.sourceScope,
              codexThreadsSourceHomeID == thread.sourceScope else {
            return nil
        }
        return home
    }

    var runningManagedChatThreads: [ManagedChatThread] {
        managedChatThreads.filter(\.isCardRunning)
    }

    var recentManagedChatThreads: [ManagedChatThread] {
        managedChatThreads.filter { !$0.isCardRunning }
    }

    var tokenFilePath: String {
        expanded("~/.harvis/auth/http.token")
    }

    var tokenConfigured: Bool {
        readAuthToken() != nil
    }

    var workspaceDiskInfo: DiskInfo? {
        Self.diskInfo(for: expanded(workspaceRoot))
    }

    var firstRunSteps: [FirstRunStep] {
        let workspaceConfigured = !workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let profileConfigured = !profileRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let permissionOK = permissionVerificationState == .verifiedReady
        let httpService = services?.service(named: "http")
        let tickService = services?.service(named: "tick")
        let httpReady = httpService?.listening ?? httpService?.running ?? false
        let tickReady = tickService?.running ?? false
        return [
            FirstRunStep(
                title: "Workspace",
                detail: workspaceConfigured ? "Workspace root is selected." : "Choose the local workspace H.A.R.V.I.S. should observe.",
                ok: workspaceConfigured,
                systemImage: "folder"
            ),
            FirstRunStep(
                title: "Profile",
                detail: profileConfigured ? "Profile root is selected." : "Choose the local profile for identity and policy.",
                ok: profileConfigured,
                systemImage: "person.text.rectangle"
            ),
            FirstRunStep(
                title: "HTTP Token",
                detail: tokenConfigured ? "Bearer token file is present." : "Start services to create the local HTTP token file.",
                ok: tokenConfigured,
                systemImage: "key"
            ),
            FirstRunStep(
                title: "Full Disk Access",
                detail: permissionSummary,
                ok: permissionOK,
                systemImage: "lock.shield"
            ),
            FirstRunStep(
                title: "LaunchAgent",
                detail: httpReady && tickReady ? "HTTP and tick services are running." : "Start or restart resident services.",
                ok: httpReady && tickReady,
                systemImage: "bolt.horizontal"
            )
        ]
    }

    var firstRunReadyCount: Int {
        firstRunSteps.filter(\.ok).count
    }

    var firstRunSummary: String {
        "\(firstRunReadyCount)/\(firstRunSteps.count) ready"
    }

    private var permissionSummary: String {
        switch permissionVerificationState {
        case .verifiedReady:
            return "Workspace/profile full permission probe passed."
        case .verifiedBlocked:
            return "Full permission probe found a blocked workspace or profile path."
        case .stale:
            return "The last full permission result is stale; retry verification."
        case .unverified:
            return "Full permission access has not been verified."
        }
    }

    var personaImageCandidatePaths: [String] {
        Self.personaImageCandidatePaths(assetRoot: personaAssetRoot)
    }

    static func personaImageCandidatePaths(assetRoot: String) -> [String] {
        let root = (assetRoot as NSString).expandingTildeInPath
        return [
            "\(root)/studio/assets/harvis-core-male.png",
            "\(root)/studio/assets/harvis-persona-system.png"
        ]
    }

    var personaImagePath: String {
        personaImageCandidatePaths[0]
    }

    func start() {
        guard timer == nil else { return }
        startupTasks = HarvisStartupScheduler.launch(
            recoverDelivery: { [weak self] in
                guard let self else { return }
                await codexTaskDelivery.activate(
                    probeExecutablePath: serviceManagerPath
                )
                await activateConversationManagement()
            },
            discoverManagedChats: { [weak self] in
                guard let self else { return }
                await restoreCodexThreadSnapshots()
                await refreshManagedChatProviders()
            },
            refreshSystem: { [weak self] in
                guard let self else { return }
                await refreshAll()
                await refreshProxyStatus(force: true)
            }
        )
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.dshConversationSender.refreshPending(
                        threads: self.dshThreads, endpoints: self.dshRunningEndpoints
                    )
                    await self.refreshAll()
                    await self.refreshCodexHomesIfFilesystemChanged()
                    await self.refreshCodexThreadsIfDue()
                    await self.refreshDshThreadsIfDue()
                }
            }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        sampleSystemInfo()
        if lastProxyRefreshAt.map({ Date().timeIntervalSince($0) >= 10 }) != false {
            await refreshProxyStatus(force: true)
        }
        await refreshCatopStatus()

        do {
            health = try await fetch("/health", as: HealthData.self)
        } catch {
            health = nil
            barStatus = nil
            lastError = clean(error.localizedDescription)
            return
        }

        // Keep the optional task lane concurrent with the remaining full
        // refresh. A slow task store must not delay bar/status or permission
        // projection, while refreshAll still owns one bounded refresh cycle.
        async let taskProgressRefresh: Void = refreshTaskProgress()

        await refreshRemoteStudio()

        do {
            let query = [
                URLQueryItem(name: "root", value: expanded(workspaceRoot)),
                URLQueryItem(name: "profile_root", value: expanded(profileRoot)),
                URLQueryItem(name: "full", value: "true")
            ]
            let status = try await fetch("/bar/status", query: query, as: BarStatus.self)
            barStatus = status
            services = Self.serviceManagerStatus(from: status.serviceHealth)
            lastError = nil
        } catch {
            barStatus = nil
            lastError = clean(error.localizedDescription)
        }

        await refreshPermissionProbe()

        // Task progress deliberately does not use BarStatus.taskProgress as UI
        // authority and never mutates health, barStatus, permissionProbe, or
        // the global Attention message.
        await taskProgressRefresh

    }

    static func fullPermissionProbeQuery(
        workspaceRoot: String,
        profileRoot: String
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "root", value: workspaceRoot),
            URLQueryItem(name: "profile_root", value: profileRoot),
            URLQueryItem(name: "full", value: "true"),
        ]
    }

    private func invalidatePermissionProbeScope() {
        permissionProbeLoadGeneration &+= 1
        permissionProbeLoadTask?.cancel()
        permissionProbeLoadTask = nil
        isPermissionProbeRefreshing = false
        lastFullPermissionProbeAttemptAt = nil
        lastCompletePermissionProbeAt = nil
        permissionProbe = nil
        permissionVerificationState = .unverified
    }

    /// Runs the write-backed permission probe at most once per interval.
    ///
    /// `force=true` is reserved for an explicit user retry and supersedes an
    /// older probe. Periodic refreshes never cancel an in-flight explicit
    /// probe and never perform the lightweight request as FDA authority.
    func refreshPermissionProbe(
        force: Bool = false,
        now: Date = Date()
    ) async {
        if !force {
            guard !isPermissionProbeRefreshing else { return }
            if let attemptedAt = lastFullPermissionProbeAttemptAt {
                let elapsed = now.timeIntervalSince(attemptedAt)
                if elapsed >= 0,
                   elapsed < Self.fullPermissionProbeRefreshInterval {
                    return
                }
            }
        }

        permissionProbeLoadGeneration &+= 1
        let generation = permissionProbeLoadGeneration
        permissionProbeLoadTask?.cancel()
        isPermissionProbeRefreshing = true
        lastFullPermissionProbeAttemptAt = now

        let query = Self.fullPermissionProbeQuery(
            workspaceRoot: expanded(workspaceRoot),
            profileRoot: expanded(profileRoot)
        )
        let injectedLoader = permissionProbeLoader
        let task = Task {
            if let injectedLoader {
                return try await injectedLoader(query)
            }
            return try await fetch(
                "/permission-probe",
                query: query,
                as: HarvisFullPermissionProbePayload.self
            )
        }
        permissionProbeLoadTask = task

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }

        guard generation == permissionProbeLoadGeneration else { return }
        permissionProbeLoadTask = nil
        isPermissionProbeRefreshing = false
        guard !Task.isCancelled else {
            lastFullPermissionProbeAttemptAt = nil
            return
        }

        switch result {
        case .success(let payload):
            if payload.isCompleteFullProbe {
                permissionProbe = payload.legacyProjection
                lastCompletePermissionProbeAt = now
                permissionVerificationState = payload.isVerifiedReady
                    ? .verifiedReady
                    : .verifiedBlocked
            } else {
                retainRecentPermissionVerificationOrDegrade(at: now)
            }
        case .failure(let error):
            guard !(error is CancellationError) else {
                lastFullPermissionProbeAttemptAt = nil
                return
            }
            retainRecentPermissionVerificationOrDegrade(at: now)
        }
    }

    private func retainRecentPermissionVerificationOrDegrade(at now: Date) {
        guard let completedAt = lastCompletePermissionProbeAt else {
            permissionVerificationState = .unverified
            return
        }
        let elapsed = now.timeIntervalSince(completedAt)
        guard elapsed < 0 || elapsed >= Self.fullPermissionProbeRefreshInterval else {
            // A lightweight/failed explicit retry must not erase a recent
            // complete result. The stored projection remains the authority.
            return
        }
        permissionVerificationState = .stale
    }

    func refreshTaskProgress() async {
        taskProgressLoadGeneration &+= 1
        let generation = taskProgressLoadGeneration
        taskProgressLoadTask?.cancel()
        isTaskProgressRefreshing = true

        let request = HarvisTaskProgressLoadRequest(
            port: port,
            workspaceRoot: expanded(workspaceRoot),
            tokenFilePath: tokenFilePath
        )
        let loader = taskProgressLoader
        let task = Task {
            try await loader.load(request)
        }
        taskProgressLoadTask = task

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }

        guard generation == taskProgressLoadGeneration else { return }
        taskProgressLoadTask = nil
        isTaskProgressRefreshing = false
        guard !Task.isCancelled else {
            taskProgressDidPublish?(.cancelled)
            return
        }

        switch result {
        case .success(let snapshot):
            taskProgressLastSuccess = snapshot
            taskProgressLastSuccessAt = Date()
            taskProgressFailure = nil
            taskProgressDidPublish?(.success)
        case .failure(let error):
            guard let failure = HarvisTaskProgressFailure.classify(error) else {
                taskProgressDidPublish?(.cancelled)
                return
            }
            taskProgressFailure = failure
            taskProgressDidPublish?(.failure(failure))
        }
    }

}
