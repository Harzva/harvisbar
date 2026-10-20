import Foundation
import XCTest
@testable import HarvisBar

final class SystemHardwareTests: XCTestCase {
    func testParsesGPUPerformanceStatistics() {
        let metrics = SystemHardwareSampler.gpuMetrics(from: [
            "Device Utilization %": 55,
            "Renderer Utilization %": 53,
            "Tiler Utilization %": 54,
            "Alloc system memory": 2_229_354_496,
            "In use system memory": 639_025_152
        ])

        XCTAssertEqual(metrics.utilizationPercent, 55)
        XCTAssertEqual(metrics.rendererPercent, 53)
        XCTAssertEqual(metrics.tilerPercent, 54)
        XCTAssertEqual(metrics.allocatedMemoryBytes, 2_229_354_496)
        XCTAssertEqual(metrics.inUseMemoryBytes, 639_025_152)
    }

    func testClampsGPUUtilizationToDisplayRange() {
        let high = SystemHardwareSampler.gpuMetrics(from: ["Device Utilization %": 140])
        let low = SystemHardwareSampler.gpuMetrics(from: ["Device Utilization %": -4])

        XCTAssertEqual(high.utilizationPercent, 100)
        XCTAssertEqual(low.utilizationPercent, 0)
    }

    func testHardwareLabelsDescribeUnifiedAppleSilicon() {
        let hardware = SystemHardwareInfo(
            modelIdentifier: "Mac16,10",
            chipName: "Apple M4",
            physicalMemoryBytes: 17_179_869_184,
            physicalCPUCount: 10,
            performanceCPUCount: 4,
            efficiencyCPUCount: 6,
            gpuName: "Apple M4",
            gpuCoreCount: 10
        )

        XCTAssertEqual(hardware.memoryLabel, "16 GB unified")
        XCTAssertEqual(hardware.cpuConfigurationLabel, "10C CPU · 4P + 6E")
        XCTAssertEqual(hardware.gpuLabel, "10C GPU")
    }

    func testDiskScannerSkipsNetworkAndNonBrowsableVolumesBeforeCapacityProbe() {
        XCTAssertFalse(
            HarvisRuntimeModel.shouldInspectVolume(
                isLocal: false,
                isBrowsable: true,
                isReadOnly: false,
                isInternal: false
            )
        )
        XCTAssertFalse(
            HarvisRuntimeModel.shouldInspectVolume(
                isLocal: true,
                isBrowsable: false,
                isReadOnly: false,
                isInternal: false
            )
        )
        XCTAssertFalse(
            HarvisRuntimeModel.shouldInspectVolume(
                isLocal: true,
                isBrowsable: true,
                isReadOnly: true,
                isInternal: false
            )
        )
        XCTAssertFalse(
            HarvisRuntimeModel.shouldInspectVolume(
                isLocal: nil,
                isBrowsable: true,
                isReadOnly: false,
                isInternal: false
            )
        )
        XCTAssertFalse(
            HarvisRuntimeModel.shouldInspectVolume(
                isLocal: true,
                isBrowsable: nil,
                isReadOnly: false,
                isInternal: false
            )
        )
        XCTAssertTrue(
            HarvisRuntimeModel.shouldInspectVolume(
                isLocal: true,
                isBrowsable: true,
                isReadOnly: false,
                isInternal: false
            )
        )
        XCTAssertTrue(
            HarvisRuntimeModel.shouldInspectVolume(
                isLocal: true,
                isBrowsable: true,
                isReadOnly: true,
                isInternal: true
            )
        )
    }
}
