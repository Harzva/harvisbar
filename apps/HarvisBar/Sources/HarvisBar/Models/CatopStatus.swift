import Foundation

/// A privacy-safe local summary emitted by `catop --once --status-json`.
struct CatopStatus: Decodable {
    let schemaVersion: Int
    let generatedAt: String
    let status: String
    let window: String
    let requestCount: Int
    let activeSessions: Int
    let inputTokens: Int
    let cachedTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let cacheHitRate: Double
    let estimatedCostUSD: Double
    let savedUSD: Double
    let observedCostUSD: Double
    let alertCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case status
        case window
        case requestCount = "request_count"
        case activeSessions = "active_sessions"
        case inputTokens = "input_tokens"
        case cachedTokens = "cached_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case outputTokens = "output_tokens"
        case cacheHitRate = "cache_hit_rate"
        case estimatedCostUSD = "estimated_cost_usd"
        case savedUSD = "saved_usd"
        case observedCostUSD = "observed_cost_usd"
        case alertCount = "alert_count"
    }
}
