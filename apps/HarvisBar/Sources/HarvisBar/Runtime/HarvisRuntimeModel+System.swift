import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

extension HarvisRuntimeModel {
    func sampleSystemInfo(
        diskLoader: @escaping @Sendable () -> [DiskInfo] = {
            HarvisRuntimeModel.diskInfos()
        }
    ) {
        let now = Date()
        let diskSampleIsDue = disks.isEmpty
            || lastDiskSampleAt.map({ now.timeIntervalSince($0) >= 10 }) != false
        if diskSampleIsDue, diskRefreshTask == nil {
            lastDiskSampleAt = now
            diskRefreshTask = Task { [weak self] in
                let nextDisks = await Task.detached(priority: .utility) {
                    diskLoader()
                }.value
                guard let self else { return }
                disks = nextDisks
                diskRefreshTask = nil
            }
        }
        systemInfo = SystemInfo(
            cpuPercent: sampleCPUPercent(),
            perCorePercent: samplePerCoreCPUPercent(),
            thermalState: ProcessInfo.processInfo.thermalState,
            cpuTemperatureCelsius: nil,
            hardware: systemHardware,
            gpu: SystemHardwareSampler.gpuMetrics()
        )
        codexProcesses = Self.codexProcessSnapshot()
    }

    static func codexProcessSnapshot() -> CodexProcessSnapshot {
        let capacity = max(Int(proc_listallpids(nil, 0)), 0)
        guard capacity > 0 else { return .empty }

        var pids = [pid_t](repeating: 0, count: capacity)
        let byteCount = pids.count * MemoryLayout<pid_t>.stride
        let processCount = pids.withUnsafeMutableBytes { buffer in
            Int(proc_listallpids(buffer.baseAddress, Int32(byteCount)))
        }
        guard processCount > 0 else { return .empty }

        var workers = 0
        var renderers = 0
        var services = 0
        var hosts = 0
        var items: [CodexProcessItem] = []

        for pid in pids.prefix(min(processCount, pids.count)) where pid > 0 {
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = nameBuffer.withUnsafeMutableBytes { buffer in
                proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            guard length > 0 else { continue }
            let nameBytes = nameBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let normalized = name.lowercased()
            guard normalized.contains("codex") else { continue }

            let kind: CodexProcessKind
            if normalized.contains("renderer") {
                renderers += 1
                kind = .renderer
            } else if normalized.contains("service") {
                services += 1
                kind = .service
            } else if normalized == "codex" {
                workers += 1
                kind = .worker
            } else {
                hosts += 1
                kind = .host
            }
            items.append(CodexProcessItem(pid: pid, name: name, kind: kind))
        }

        return CodexProcessSnapshot(
            workers: workers,
            renderers: renderers,
            services: services,
            hosts: hosts,
            items: items.sorted { $0.pid < $1.pid }
        )
    }

    func sampleCPUPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        guard let previous = previousCPUTicks else {
            previousCPUTicks = ticks
            return nil
        }
        previousCPUTicks = ticks

        let user = ticks.user.saturatingSubtract(previous.user)
        let system = ticks.system.saturatingSubtract(previous.system)
        let idle = ticks.idle.saturatingSubtract(previous.idle)
        let nice = ticks.nice.saturatingSubtract(previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return Double(user + system + nice) / Double(total) * 100
    }

    func samplePerCoreCPUPercent() -> [Double?] {
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else {
            return Array(repeating: nil, count: ProcessInfo.processInfo.processorCount)
        }
        defer {
            let byteCount = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: processorInfo), byteCount)
        }

        let values = UnsafeBufferPointer(start: processorInfo, count: Int(processorInfoCount))
        let ticks = (0..<Int(processorCount)).map { index -> CPUTicks in
            let offset = index * Int(CPU_STATE_MAX)
            return CPUTicks(
                user: UInt64(values[offset + Int(CPU_STATE_USER)]),
                system: UInt64(values[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(values[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt64(values[offset + Int(CPU_STATE_NICE)])
            )
        }

        guard let previous = previousPerCoreTicks, previous.count == ticks.count else {
            previousPerCoreTicks = ticks
            return Array(repeating: nil, count: ticks.count)
        }
        previousPerCoreTicks = ticks

        return zip(ticks, previous).map { current, prior -> Double? in
            let user = current.user.saturatingSubtract(prior.user)
            let system = current.system.saturatingSubtract(prior.system)
            let idle = current.idle.saturatingSubtract(prior.idle)
            let nice = current.nice.saturatingSubtract(prior.nice)
            let total = user + system + idle + nice
            guard total > 0 else { return nil }
            return Double(user + system + nice) / Double(total) * 100
        }
    }

    func openFullDiskAccessSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

}
