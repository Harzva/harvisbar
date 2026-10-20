import AppKit
import Darwin
import Foundation
import SwiftUI

struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: APIError?
}

struct APIError: Decodable {
    let code: String?
    let message: String?
}

struct APIErrorEnvelope: Decodable {
    let error: APIError?
}

struct HealthData: Decodable {
    let agent: String?
    let apiVersion: String?
    let mode: String?
    let autonomyLevel: Int?
    let authRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case agent
        case apiVersion = "api_version"
        case mode
        case autonomyLevel = "autonomy_level"
        case authRequired = "auth_required"
    }
}

struct BarStatus: Decodable {
    let generatedAt: String?
    let runtime: RuntimeInfo?
    let serviceHealth: ServiceHealth?
    let work: WorkInfo?
    let knowledge: KnowledgeInfo?
    let agentMail: AgentMailStatus?
    let agentHarnesses: AgentHarnesses?
    let codexhomeObservability: CodexHomeObservability?
    let ports: PortsStatus?
}

struct RuntimeInfo: Decodable {
    let state: String?
    let mode: String?
    let autonomyLevel: Int?
    let summary: String?
}

struct ServiceHealth: Decodable {
    let http: String?
    let tickRunner: String?
    let mcp: String?
}

struct WorkInfo: Decodable {
    let packets: Int?
    let blocked: Int?
    let pendingApprovals: Int?
    let runtimeErrors: Int?
    let runs: Int?
    let lastTickAt: String?
}

struct CodexHomeObservability: Decodable {
    let status: String?
    let summary: String?
    let eventCount: Int?
    let runs: Int?
    let attempts: Int?
    let totalTokens: Int?
    let cachedInputTokens: Int?
    let cacheHitRateBasisPoints: Int?
    let failureRateBasisPoints: Int?
    let durationMs: Int?
    let retries: Int?
    let estimatedCostMicrousd: Int?
}

struct KnowledgeInfo: Decodable {
    let hub: String?
    let wiki: String?
    let activeSources: [String]?
    let allowlistedSources: Int?
}

struct TaskProgressStatus: Decodable, Equatable, Sendable {
    let status: String?
    let summary: String?
    let activeCount: Int?
    let current: TaskProgressItem?
    let items: [TaskProgressItem]?
}

struct TaskProgressItem: Decodable, Equatable, Identifiable, Sendable {
    var id: String { taskId ?? title ?? "task-progress" }

    let taskId: String?
    let title: String?
    let kind: String?
    let status: String?
    let summary: String?
    let detail: String?
    let progress: TaskProgressValue?
    let metrics: TaskProgressMetrics?
    let startedAt: String?
    let updatedAt: String?
}

struct TaskProgressValue: Decodable, Equatable, Sendable {
    let percent: Double?
    let current: Int?
    let total: Int?
    let unit: String?
}

struct TaskProgressMetrics: Decodable, Equatable, Sendable {
    let elapsed: String?
    let eta: String?
    let speed: String?
    let itemsPerSecond: Double?
}

/// Closed, public-safe failure classes for the optional task-progress lane.
///
/// Raw HTTP bodies, server messages, POSIX paths, and bearer-token details must
/// never enter published SwiftUI state. The UI renders only the stable summary
/// below and keeps the last successful task snapshot intact.
enum HarvisTaskProgressFailure: String, Equatable, Sendable {
    case httpRejected
    case permissionDenied
    case ioFailure
    case invalidResponse
    case timeout
    case offline

    var localizedSummary: String {
        switch self {
        case .httpRejected:
            return "任务进度请求被本地服务拒绝。"
        case .permissionDenied:
            return "任务进度暂时没有本地读取权限。"
        case .ioFailure:
            return "任务进度存储暂时不可读。"
        case .invalidResponse:
            return "任务进度返回了无效的安全响应。"
        case .timeout:
            return "任务进度读取超时。"
        case .offline:
            return "任务进度服务暂时不可用。"
        }
    }
}

struct AgentMailStatus: Decodable {
    let available: Bool?
    let status: String?
    let loggedIn: Bool?
    let tokenStatus: String?
    let cliPresent: Bool?
    let account: AgentMailAccount?
    let unreadProbe: String?
    let unreadPreviewCount: Int?
    let summary: String?
}

struct AgentMailAccount: Decodable {
    let email: String?
    let name: String?
    let isPrimary: Bool?
}

struct AgentMailSummary: Decodable {
    let status: String?
    let count: Int?
    let hasMore: Bool?
    let items: [AgentMailMessage]
    let summary: String?
}

struct AgentMailMessage: Decodable, Identifiable {
    let messageId: String?
    let createdAt: String?
    let from: String?
    let subject: String?
    let snippet: String?
    let hasAttachments: Bool?
    let isRead: Bool?

    var id: String {
        messageId ?? "\(createdAt ?? "")-\(subject ?? UUID().uuidString)"
    }
}

struct ProxyManagerStatus: Decodable {
    let ok: Bool
    let activeNetworkService: ProxyNetworkService?
    let endpoints: [String: ProxyEndpointStatus]
    let routes: [String: String]
    let systemProxy: ProxySystemStatus
}

struct ProxyNetworkService: Decodable {
    let name: String
    let device: String
    let disabled: Bool
}

struct ProxyEndpointStatus: Decodable {
    let label: String
    let host: String
    let port: Int
    let available: Bool
}

struct ProxySystemStatus: Decodable {
    let route: String
    let desiredRoute: String
    let drift: Bool
}

struct PermissionProbe: Decodable {
    let ok: Bool
    let context: String?
    let redacted: Bool?
    let includesLocalAbsolutePaths: Bool?
    let checks: [PermissionProbeCheck]?
}

struct PermissionProbeCheck: Decodable, Identifiable {
    let label: String?
    let ok: Bool?
    let exists: Bool?
    let writable: Bool?

    var id: String {
        label ?? UUID().uuidString
    }
}

struct FirstRunStep: Identifiable {
    let title: String
    let detail: String
    let ok: Bool
    let systemImage: String

    var id: String { title }
}

enum CodexProcessKind: String {
    case worker
    case renderer
    case service
    case host
}

struct CodexProcessItem: Identifiable {
    let pid: pid_t
    let name: String
    let kind: CodexProcessKind

    var id: pid_t { pid }
}

struct CodexProcessSnapshot {
    let workers: Int
    let renderers: Int
    let services: Int
    let hosts: Int
    let items: [CodexProcessItem]

    static let empty = CodexProcessSnapshot(
        workers: 0,
        renderers: 0,
        services: 0,
        hosts: 0,
        items: []
    )

    var total: Int { items.count }
}

struct CPUTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

struct SystemHardwareInfo: Equatable {
    let modelIdentifier: String
    let chipName: String
    let physicalMemoryBytes: UInt64
    let physicalCPUCount: Int
    let performanceCPUCount: Int?
    let efficiencyCPUCount: Int?
    let gpuName: String?
    let gpuCoreCount: Int?

    static let unknown = SystemHardwareInfo(
        modelIdentifier: "Mac",
        chipName: "Apple silicon",
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        physicalCPUCount: ProcessInfo.processInfo.processorCount,
        performanceCPUCount: nil,
        efficiencyCPUCount: nil,
        gpuName: nil,
        gpuCoreCount: nil
    )

    var memoryLabel: String {
        let gibibytes = Double(physicalMemoryBytes) / 1_073_741_824
        return "\(Int(gibibytes.rounded())) GB unified"
    }

    var cpuConfigurationLabel: String {
        guard let performanceCPUCount, let efficiencyCPUCount else {
            return "\(physicalCPUCount)C CPU"
        }
        return "\(physicalCPUCount)C CPU · \(performanceCPUCount)P + \(efficiencyCPUCount)E"
    }

    var gpuLabel: String {
        guard let gpuCoreCount else { return gpuName ?? "GPU unavailable" }
        return "\(gpuCoreCount)C GPU"
    }
}

struct GPUMetrics: Equatable {
    let utilizationPercent: Double?
    let rendererPercent: Double?
    let tilerPercent: Double?
    let allocatedMemoryBytes: UInt64?
    let inUseMemoryBytes: UInt64?

    static let unavailable = GPUMetrics(
        utilizationPercent: nil,
        rendererPercent: nil,
        tilerPercent: nil,
        allocatedMemoryBytes: nil,
        inUseMemoryBytes: nil
    )

    var utilizationLabel: String {
        guard let utilizationPercent else { return "--" }
        return "\(Int(utilizationPercent.rounded()))%"
    }

    var memoryLabel: String? {
        let bytes = inUseMemoryBytes ?? allocatedMemoryBytes
        guard let bytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

struct SystemInfo {
    let cpuPercent: Double?
    let perCorePercent: [Double?]
    let thermalState: ProcessInfo.ThermalState
    let cpuTemperatureCelsius: Double?
    let hardware: SystemHardwareInfo
    let gpu: GPUMetrics

    var logicalCPUCount: Int {
        perCorePercent.isEmpty ? ProcessInfo.processInfo.processorCount : perCorePercent.count
    }

    var cpuLabel: String {
        guard let cpuPercent else { return "--" }
        return "\(Int(cpuPercent.rounded()))%"
    }

    var cpuDetail: String {
        guard let cpuPercent else {
            return "CPU usage is warming up; wait for the next refresh tick."
        }
        return "CPU usage: \(String(format: "%.1f", cpuPercent))%"
    }

    var cpuColor: Color {
        cpuColor(for: cpuPercent)
    }

    func cpuColor(for percent: Double?) -> Color {
        guard let percent else { return Color(hex: 0x64748B) }
        if percent >= 85 { return Color(hex: 0xDC2626) }
        if percent >= 65 { return Color(hex: 0xB45309) }
        return Color(hex: 0x15803D)
    }

    var thermalLabel: String {
        switch thermalState {
        case .nominal:
            return "ok"
        case .fair:
            return "fair"
        case .serious:
            return "hot"
        case .critical:
            return "crit"
        @unknown default:
            return "?"
        }
    }

    var thermalDetail: String {
        switch thermalState {
        case .nominal:
            return "Thermal state: nominal."
        case .fair:
            return "Thermal state: fair; macOS is starting to manage heat."
        case .serious:
            return "Thermal state: serious; CPU may throttle."
        case .critical:
            return "Thermal state: critical; reduce workload."
        @unknown default:
            return "Thermal state is unknown."
        }
    }

    var thermalColor: Color {
        switch thermalState {
        case .nominal:
            return Color(hex: 0x15803D)
        case .fair:
            return Color(hex: 0xB45309)
        case .serious, .critical:
            return Color(hex: 0xDC2626)
        @unknown default:
            return Color(hex: 0x64748B)
        }
    }

    var temperatureLabel: String {
        guard let cpuTemperatureCelsius else { return "--°C" }
        return "\(Int(cpuTemperatureCelsius.rounded()))°C"
    }

    var temperatureDetail: String {
        guard let cpuTemperatureCelsius else {
            return "CPU temperature sensor is not available from the current sandbox-safe macOS APIs. Thermal state is shown instead."
        }
        return "CPU temperature: \(String(format: "%.1f", cpuTemperatureCelsius))°C"
    }

    var temperatureColor: Color {
        guard let cpuTemperatureCelsius else { return Color(hex: 0x64748B) }
        if cpuTemperatureCelsius >= 95 { return Color(hex: 0xDC2626) }
        if cpuTemperatureCelsius >= 80 { return Color(hex: 0xB45309) }
        return Color(hex: 0x15803D)
    }
}

struct RemoteStudioMetrics: Decodable, Equatable {
    let alias: String?
    let available: Bool?
    let remote: String?
    let safeForWebview: Bool?
    let sampledAt: String?
    let host: RemoteHost?
    let load: RemoteLoad?
    let cpu: RemoteCPU?
    let memory: RemoteMemory?
    let disk: RemoteDisk?
    let gpu: RemoteGPU?
    let processes: [RemoteProcess]
    let source: String?

    enum CodingKeys: String, CodingKey {
        case alias
        case available
        case remote
        case safeForWebview
        case sampledAt = "sampled_at"
        case host
        case load
        case cpu
        case memory
        case disk
        case gpu
        case processes
        case source
    }

    var isAvailable: Bool { available == true }

    var cpuPercent: Double? { cpu?.percent }

    var cpuLabel: String {
        guard let cpuPercent else { return "--" }
        return Self.percentLabel(cpuPercent)
    }

    var cpuDetail: String {
        let model = cpu?.model ?? "Remote CPU"
        guard let logicalCount = cpu?.logicalCount else { return model }
        return "\(model) · \(logicalCount) logical"
    }

    var memoryPercent: Double? { memory?.percent }

    var memoryLabel: String {
        guard let memory, let usedBytes = memory.usedBytes, let totalBytes = memory.totalBytes else {
            return "--"
        }
        return "\(Self.formatBytes(usedBytes)) / \(Self.formatBytes(totalBytes))"
    }

    var memoryDetail: String {
        guard let memoryPercent else { return "Memory usage unavailable" }
        return "Memory usage: \(Self.percentLabel(memoryPercent))"
    }

    var diskPercent: Double? { disk?.root?.percent }

    var diskLabel: String {
        guard let root = disk?.root else { return "--" }
        let percent = root.percent.map(Self.percentLabel) ?? "--"
        guard let freeBytes = root.freeBytes else { return percent }
        return "\(percent) · \(Self.formatBytes(freeBytes)) free"
    }

    var diskDetail: String {
        guard let root = disk?.root,
              let usedBytes = root.usedBytes,
              let totalBytes = root.totalBytes
        else {
            return "Remote root disk usage unavailable"
        }
        return "Root: \(Self.formatBytes(usedBytes)) / \(Self.formatBytes(totalBytes))"
    }

    var gpuDetail: String {
        guard let gpu = gpu, let device = gpu.gpus?.first else {
            return "Apple GPU information unavailable"
        }
        let coreLabel = device.cores.map { "\($0)C" } ?? "Apple GPU"
        guard let utilization = device.utilizationPercent else {
            return "\(device.name ?? "Apple GPU") · \(coreLabel) · utilization unavailable over SSH"
        }
        return "\(device.name ?? "Apple GPU") · \(coreLabel) · \(Self.percentLabel(utilization))"
    }

    var gpuLabel: String {
        guard let device = gpu?.gpus?.first else { return "--" }
        let coreLabel = device.cores.map { "\($0)C" } ?? "GPU"
        guard let utilization = device.utilizationPercent else {
            return "\(coreLabel) · n/a"
        }
        return "\(coreLabel) · \(Self.percentLabel(utilization))"
    }

    var processSummary: String? {
        let names = processes
            .compactMap(\.name)
            .filter { !$0.isEmpty }
            .prefix(3)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: " · ")
    }

    var sampleTimeLabel: String {
        guard let sampledAt,
              let date = ISO8601DateFormatter().date(from: sampledAt)
        else {
            return sampledAt ?? "waiting"
        }
        return date.formatted(date: .omitted, time: .standard)
    }

    private static func percentLabel(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

struct RemoteHost: Decodable, Equatable {
    let hostname: String?
    let system: String?
    let release: String?
    let machine: String?
}

struct RemoteLoad: Decodable, Equatable {
    let oneMinute: Double?
    let fiveMinutes: Double?
    let fifteenMinutes: Double?
    let cpuCount: Int?

    enum CodingKeys: String, CodingKey {
        case oneMinute = "1m"
        case fiveMinutes = "5m"
        case fifteenMinutes = "15m"
        case cpuCount = "cpu_count"
    }
}

struct RemoteCPU: Decodable, Equatable {
    let logicalCount: Int?
    let model: String?
    let percent: Double?

    enum CodingKeys: String, CodingKey {
        case logicalCount = "logical_count"
        case model
        case percent
    }
}

struct RemoteMemory: Decodable, Equatable {
    let availableBytes: UInt64?
    let percent: Double?
    let swapTotalBytes: UInt64?
    let swapUsedBytes: UInt64?
    let totalBytes: UInt64?
    let usedBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case availableBytes = "available_bytes"
        case percent
        case swapTotalBytes = "swap_total_bytes"
        case swapUsedBytes = "swap_used_bytes"
        case totalBytes = "total_bytes"
        case usedBytes = "used_bytes"
    }
}

struct RemoteDisk: Decodable, Equatable {
    let root: RemoteDiskUsage?
}

struct RemoteDiskUsage: Decodable, Equatable {
    let freeBytes: UInt64?
    let percent: Double?
    let totalBytes: UInt64?
    let usedBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case freeBytes = "free_bytes"
        case percent
        case totalBytes = "total_bytes"
        case usedBytes = "used_bytes"
    }
}

struct RemoteGPU: Decodable, Equatable {
    let activitySupported: Bool?
    let driverVersion: String?
    let gpus: [RemoteGPUDevice]?
    let platform: String?

    enum CodingKeys: String, CodingKey {
        case activitySupported = "activity_supported"
        case driverVersion = "driver_version"
        case gpus
        case platform
    }
}

struct RemoteGPUDevice: Decodable, Equatable {
    let cores: Int?
    let index: Int?
    let memoryTotalMiB: UInt64?
    let memoryUsedMiB: UInt64?
    let metalSupport: String?
    let name: String?
    let powerW: Double?
    let temperatureC: Double?
    let utilizationPercent: Double?

    enum CodingKeys: String, CodingKey {
        case cores
        case index
        case memoryTotalMiB = "memory_total_mib"
        case memoryUsedMiB = "memory_used_mib"
        case metalSupport = "metal_support"
        case name
        case powerW = "power_w"
        case temperatureC = "temperature_c"
        case utilizationPercent = "utilization_percent"
    }
}

struct RemoteProcess: Decodable, Equatable {
    let cpuPercent: Double?
    let elapsed: String?
    let memoryPercent: Double?
    let name: String?
    let pid: Int?
    let user: String?

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "cpu_percent"
        case elapsed
        case memoryPercent = "memory_percent"
        case name
        case pid
        case user
    }
}

struct DiskInfo: Identifiable, Sendable {
    let name: String
    let volumeURL: URL
    let totalBytes: Int64
    let availableBytes: Int64
    let usedBytes: Int64
    let isInternal: Bool?
    let isRemovable: Bool?

    var id: String { volumeURL.path }

    var usedPercent: Int {
        guard totalBytes > 0 else { return 0 }
        return min(100, max(0, Int((Double(usedBytes) / Double(totalBytes) * 100).rounded())))
    }

    var compactLabel: String {
        "\(name) \(usedPercent)%"
    }

    var typeLabel: String {
        if isInternal == true { return "Internal" }
        if isRemovable == true { return "Removable" }
        return "External"
    }

    var usageLabel: String {
        "\(Self.formatBytes(usedBytes)) / \(Self.formatBytes(totalBytes))"
    }

    var availablePercent: Int {
        guard totalBytes > 0 else { return 0 }
        return min(100, max(0, Int((Double(availableBytes) / Double(totalBytes) * 100).rounded())))
    }

    var warningColor: Color {
        if availablePercent <= 15 { return Color(hex: 0xDC2626) }
        if availablePercent <= 25 { return Color(hex: 0xB45309) }
        return Color(hex: 0x15803D)
    }

    var detailText: String {
        [
            "\(name) disk usage",
            "Used: \(Self.formatBytes(usedBytes)) / \(Self.formatBytes(totalBytes)) (\(usedPercent)%)",
            "Free: \(Self.formatBytes(availableBytes))",
            "Mount: \(volumeURL.path)"
        ].joined(separator: "\n")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}

extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

struct AgentHarnesses: Decodable {
    let status: String?
    let summary: String?
    let testPolicy: String?
    let includesModelCalls: Bool?
    let items: [AgentHarnessItem]?

    var detailedSummary: String {
        let itemSummaries = (items ?? [])
            .filter { $0.test?.status != nil && $0.test?.status != "not-run" }
            .map { "\($0.id): \($0.test?.status ?? "unknown")" }
        if itemSummaries.isEmpty {
            return summary ?? "Harness preflight finished."
        }
        return [summary, itemSummaries.joined(separator: ", ")]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")
    }
}

struct AgentHarnessItem: Decodable, Identifiable {
    let id: String
    let label: String?
    let runtime: String?
    let model: String?
    let status: String?
    let summary: String?
    let skillPresent: Bool?
    let wrapperPresent: Bool?
    let nativeWrapperPresent: Bool?
    let reviewMarkerPresent: Bool?
    let cliPresent: Bool?
    let cliCommand: String?
    let launch: AgentHarnessLaunchDescriptor?
    let pendingReviews: Int?
    let reviewedRuns: Int?
    let testTarget: Bool?
    let test: AgentHarnessTest?

    var effectiveStatus: String {
        if let testStatus = test?.status, testStatus != "not-run" {
            return testStatus
        }
        return status ?? "unknown"
    }

    var detailSummary: String {
        if let test {
            let base = test.summary ?? summary ?? model ?? "-"
            if let exitCode = test.exitCode {
                return "\(base) exit=\(exitCode)"
            }
            return base
        }
        return summary ?? model ?? "-"
    }

    var shortLabel: String {
        switch id {
        case "cxspark":
            return "Spark"
        case "cckimi":
            return "Kimi"
        case "mimocode":
            return "Mimo"
        default:
            return label ?? id
        }
    }

    var routeLabel: String {
        let runtimeText = runtime ?? "-"
        let modelText = model ?? "-"
        return "\(runtimeText) · \(modelText)"
    }
}

/// A capability descriptor from the local Harvis runtime.
///
/// The descriptor intentionally carries only stable identifiers and enum-like
/// policy values. It never carries an executable path, arguments, or shell
/// text. All fields remain optional so an older or partially upgraded local
/// runtime cannot make the entire status response undecodable.
struct AgentHarnessLaunchDescriptor: Decodable, Equatable {
    let launcherID: String?
    let productID: String?
    let kind: String?
    let mode: String?
    let workingDirectoryPolicy: String?
}

struct AgentHarnessTest: Decodable {
    let status: String?
    let exitCode: Int?
    let summary: String?
}

struct PortsStatus: Decodable {
    let status: String?
    let summary: String?
    let counts: PortCounts?
    let items: [PortStatusItem]?
}

struct PortCounts: Decodable {
    let listeners: Int?
    let important: Int?
    let importantRunning: Int?
    let importantAutostartReady: Int?
}

struct PortStatusItem: Decodable, Identifiable {
    let id: String
    let label: String?
    let port: Int?
    let url: String?
    let function: String?
    let known: Bool?
    let important: Bool?
    let availability: String?
    let expectedListening: Bool?
    let listening: Bool?
    let process: String?
    let pid: Int?
    let uptime: String?
    let serviceGroup: String?
    let profile: String?
    let restartable: Bool?
    let autostart: PortAutostart?

    var shortLabel: String {
        label ?? id
    }

    var dshProfileLabel: String {
        profile ?? shortLabel
    }

    var autostartLabel: String {
        if availability == "on-demand" && listening != true {
            return "on demand"
        }
        guard let autostart else {
            return "manual"
        }
        if autostart.loaded == true && autostart.plistPresent == true {
            return "auto"
        }
        if autostart.plistPresent == true {
            return "plist"
        }
        return "manual"
    }

    var detailSummary: String {
        [
            function,
            process.map { "process \($0)" },
            uptime.map { "up \($0)" },
            availability.map { $0 },
            autostartLabel == "auto" ? "autostart ready" : autostartLabel
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

struct PortAutostart: Decodable {
    let label: String?
    let loaded: Bool?
    let running: Bool?
    let plistPresent: Bool?
}

struct ServiceManagerStatus: Decodable {
    let services: [ManagedService]

    func service(named name: String) -> ManagedService? {
        services.first { $0.service == name }
    }
}

struct ManagedService: Decodable {
    let service: String
    let label: String?
    let loaded: Bool?
    let running: Bool?
    let listening: Bool?
}

enum HarvisBarError: LocalizedError {
    case invalidURL
    case timeout(String)
    case offline(String)
    case unauthorized(String)
    case network(String, String)
    case httpStatus(Int, String?)
    case api(String)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid local API URL."
        case .timeout(let path):
            return "Local API request timed out: \(path)."
        case .offline(let path):
            return "Local API is not reachable for \(path). Start or restart H.A.R.V.I.S. services."
        case .unauthorized(let path):
            return "Local API rejected \(path): bearer token is missing or invalid."
        case .network(let path, let message):
            return "Local API request failed for \(path): \(message)"
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "Local API returned HTTP \(status): \(message)"
            }
            return "Local API returned HTTP \(status)."
        case .api(let message):
            return message
        case .process(let message):
            return message
        }
    }
}
