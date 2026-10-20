import Darwin
import Foundation
import IOKit

enum SystemHardwareSampler {
    static func hardwareInfo() -> SystemHardwareInfo {
        let accelerator = acceleratorProperties()
        return SystemHardwareInfo(
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            physicalMemoryBytes: sysctlInteger("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory,
            physicalCPUCount: Int(sysctlInteger("hw.physicalcpu") ?? UInt64(ProcessInfo.processInfo.processorCount)),
            performanceCPUCount: sysctlInteger("hw.perflevel0.physicalcpu").map(Int.init),
            efficiencyCPUCount: sysctlInteger("hw.perflevel1.physicalcpu").map(Int.init),
            gpuName: stringValue(accelerator?["model"]),
            gpuCoreCount: integerValue(accelerator?["gpu-core-count"]).map(Int.init)
        )
    }

    static func gpuMetrics() -> GPUMetrics {
        guard let statistics = acceleratorProperties()?["PerformanceStatistics"] as? [String: Any] else {
            return .unavailable
        }
        return gpuMetrics(from: statistics)
    }

    static func gpuMetrics(from statistics: [String: Any]) -> GPUMetrics {
        GPUMetrics(
            utilizationPercent: percentValue(statistics["Device Utilization %"]),
            rendererPercent: percentValue(statistics["Renderer Utilization %"]),
            tilerPercent: percentValue(statistics["Tiler Utilization %"]),
            allocatedMemoryBytes: integerValue(statistics["Alloc system memory"]),
            inUseMemoryBytes: integerValue(statistics["In use system memory"])
        )
    }

    private static func acceleratorProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func sysctlInteger(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<UInt32>.size {
            return UInt64(UInt32(truncatingIfNeeded: value))
        }
        return value
    }

    private static func percentValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return min(100, max(0, number.doubleValue))
    }

    private static func integerValue(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.doubleValue >= 0 else { return nil }
        return number.uint64Value
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let data = value as? Data {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }
}
