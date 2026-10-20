import Foundation
import XCTest
@testable import HarvisBar

final class RemoteStudioMetricsTests: XCTestCase {
    func testDecodesStudioMonitorSnapshotAndKeepsGPUUnavailableDistinctFromZero() throws {
        let data = Data(
            """
            {
              "alias": "studio",
              "available": true,
              "remote": "studio",
              "safeForWebview": true,
              "sampled_at": "2026-08-21T08:08:14Z",
              "host": {
                "hostname": "Macs-Mac-Studio-2.local",
                "system": "Darwin",
                "release": "22.4.0",
                "machine": "arm64"
              },
              "load": {
                "1m": 0.98,
                "5m": 1.12,
                "15m": 1.08,
                "cpu_count": 10
              },
              "cpu": {
                "logical_count": 10,
                "model": "Apple M1 Max",
                "percent": 11.76
              },
              "memory": {
                "available_bytes": 1099511628,
                "percent": 96.58,
                "swap_total_bytes": 0,
                "swap_used_bytes": 0,
                "total_bytes": 34359738368,
                "used_bytes": 33135067136
              },
              "disk": {
                "root": {
                  "free_bytes": 219000000000,
                  "percent": 52.43,
                  "total_bytes": 494384795648,
                  "used_bytes": 275384795648
                }
              },
              "gpu": {
                "activity_supported": false,
                "driver_version": null,
                "platform": "apple",
                "gpus": [
                  {
                    "cores": 24,
                    "index": 0,
                    "memory_total_mib": null,
                    "memory_used_mib": null,
                    "metal_support": "spdisplays_metal3",
                    "name": "Apple M1 Max",
                    "power_w": null,
                    "temperature_c": null,
                    "utilization_percent": null
                  }
                ],
                "compute_processes": []
              },
              "processes": [
                {
                  "cpu_percent": 14.1,
                  "elapsed": "01:20",
                  "memory_percent": 4.2,
                  "name": "wpsoffice",
                  "pid": 101,
                  "user": "mac"
                },
                {
                  "cpu_percent": 2.3,
                  "elapsed": "02:10",
                  "memory_percent": 1.1,
                  "name": "launchd",
                  "pid": 1,
                  "user": "root"
                }
              ],
              "source": "ssh-remote-suite monitor cache"
            }
            """.utf8
        )

        let metrics = try JSONDecoder().decode(RemoteStudioMetrics.self, from: data)

        XCTAssertTrue(metrics.isAvailable)
        XCTAssertEqual(metrics.cpuLabel, "12%")
        XCTAssertEqual(metrics.cpuDetail, "Apple M1 Max · 10 logical")
        XCTAssertEqual(metrics.memoryPercent, 96.58)
        XCTAssertEqual(metrics.diskPercent, 52.43)
        XCTAssertEqual(metrics.gpuLabel, "24C · n/a")
        XCTAssertTrue(metrics.gpuDetail.contains("unavailable over SSH"))
        XCTAssertEqual(metrics.processSummary, "wpsoffice · launchd")
        XCTAssertFalse(metrics.sampleTimeLabel.isEmpty)
    }
}
