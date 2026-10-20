import Foundation
import XCTest
@testable import HarvisBar

final class CodexQuotaTests: XCTestCase {
    func testQuotaDecodesIndependentBucketsAndComputesRemainingPercent() throws {
        let payload = #"""
        {
          "ok": true,
          "schemaVersion": "harvis.codex-home-quota.v1",
          "homeId": "home-1",
          "available": true,
          "planType": "pro",
          "buckets": [
            {
              "limitId": "codex",
              "limitName": null,
              "planType": "pro",
              "primary": {
                "usedPercent": 89,
                "windowDurationMins": 10080,
                "resetsAt": 1787284685
              },
              "secondary": null
            },
            {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "planType": "pro",
              "primary": {
                "usedPercent": 5,
                "windowDurationMins": 300,
                "resetsAt": 1787285177
              },
              "secondary": null
            }
          ],
          "error": null
        }
        """#

        let quota = try JSONDecoder().decode(CodexHomeQuota.self, from: Data(payload.utf8))

        XCTAssertEqual(quota.compactSummary, "剩余 11%")
        XCTAssertEqual(quota.planLabel, "PRO")
        XCTAssertEqual(quota.buckets[0].displayName, "Codex")
        XCTAssertEqual(quota.buckets[0].primary?.durationLabel, "7天")
        XCTAssertEqual(quota.buckets[1].displayName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(quota.buckets[1].primary?.remainingPercent, 95)
        XCTAssertEqual(quota.buckets[1].primary?.durationLabel, "5小时")
    }

    func testUnavailableQuotaHasStableCompactLabel() {
        let quota = CodexHomeQuota(
            ok: true,
            schemaVersion: "harvis.codex-home-quota.v1",
            homeId: "home-2",
            available: false,
            planType: nil,
            buckets: [],
            error: "No subscription quota"
        )

        XCTAssertEqual(quota.compactSummary, "额度不可用")
        XCTAssertNil(quota.planLabel)
    }

    func testProxyHomeBlocksOfficialQuotaWithExplicitReason() throws {
        let payload = #"""
        {
          "id": "proxy-home",
          "label": "Proxy Account",
          "path": "/tmp/proxy-home",
          "source": "open-codex-launcher",
          "model": "gpt-5.4",
          "provider": "CodexManager",
          "endpointHost": "localhost",
          "hasAuth": true,
          "hasConfig": true,
          "skillCount": 1,
          "quotaMode": "proxy",
          "quotaNote": "代理 Home：请求经过本地网关，无法读取官方账号额度。"
        }
        """#

        let home = try JSONDecoder().decode(CodexHome.self, from: Data(payload.utf8))

        XCTAssertFalse(home.isSubscriptionHome)
        XCTAssertEqual(home.quotaMenuLabel, "自定义模型")
        XCTAssertEqual(home.officialQuotaBlockedReason, "使用自定义模型，不适用 ChatGPT 订阅额度。")
    }
}
