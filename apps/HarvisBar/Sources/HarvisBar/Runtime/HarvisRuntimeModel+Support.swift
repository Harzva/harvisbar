import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

extension HarvisRuntimeModel {
    static func normalizeState(_ value: String) -> String {
        let label = value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ["idle", "reading", "thinking", "acting", "verified", "blocked"].contains(label) {
            return label
        }
        if ["online", "ready", "healthy", "ok", "seen"].contains(label) {
            return "verified"
        }
        if ["degraded", "offline", "down", "failed", "error", "warn", "approval-required", "waiting-approval"].contains(label) {
            return "blocked"
        }
        if ["scanning", "loading", "refreshing", "probing"].contains(label) {
            return "reading"
        }
        if ["planning", "reasoning", "queued", "pending"].contains(label) {
            return "thinking"
        }
        if ["running", "executing", "initializing", "writing", "working"].contains(label) {
            return "acting"
        }
        return healthStateFallback(value)
    }

    static func serviceManagerStatus(from health: ServiceHealth?) -> ServiceManagerStatus? {
        guard let health else { return nil }
        let httpRunning = serviceStateIsReady(health.http)
        let tickRunning = serviceStateIsReady(health.tickRunner)
        return ServiceManagerStatus(services: [
            ManagedService(
                service: "http",
                label: nil,
                loaded: httpRunning,
                running: httpRunning,
                listening: httpRunning
            ),
            ManagedService(
                service: "tick",
                label: nil,
                loaded: tickRunning,
                running: tickRunning,
                listening: nil
            )
        ])
    }

    static func serviceStateIsReady(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["available", "idle", "loaded", "online", "ready", "running", "verified"]
            .contains(value.lowercased())
    }

    static func healthStateFallback(_ value: String) -> String {
        value.isEmpty ? "idle" : "thinking"
    }

    static func detectBundledPluginRoot(
        resourceURL: URL? = Bundle.main.resourceURL
    ) -> String? {
        guard let resourceURL else { return nil }
        let markerURL = resourceURL.appendingPathComponent("harvis-plugin-root.txt")
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8) else {
            return nil
        }
        return resolveBundledPluginRoot(
            resourcePath: resourceURL.path,
            marker: marker
        )
    }

    static func detectPluginRoot(bundledPluginRoot: String? = nil) -> String {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath

        let candidates = [
            bundledPluginRoot,
            ProcessInfo.processInfo.environment["HARVIS_PLUGIN_ROOT"],
            cwd,
            "\(cwd)/../..",
            "\(cwd)/../../.."
        ].compactMap { $0 }

        return resolvePluginRoot(
            candidates: candidates,
            fallbackCandidates: [
                Bundle.main.resourceURL?.path,
                Bundle.main.bundleURL.path,
                cwd
            ].compactMap { $0 },
            scriptExists: fm.fileExists(atPath:)
        )
    }

    static func resolvePluginRoot(
        candidates: [String],
        fallbackCandidates: [String],
        scriptExists: (String) -> Bool
    ) -> String {
        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            guard !isLegacyPluginRoot(expanded) else { continue }
            if scriptExists("\(expanded)/scripts/harvis") {
                return expanded
            }
        }

        // A missing marker should fail within this app bundle (or another
        // explicitly safe candidate), where the runtime can surface a
        // configuration error without probing or executing retired sources.
        if let safeFallback = fallbackCandidates
            .map({ ($0 as NSString).expandingTildeInPath })
            .first(where: { !isLegacyPluginRoot($0) }) {
            return safeFallback
        }
        return FileManager.default.temporaryDirectory.path
    }

    static func resolveBundledPluginRoot(resourcePath: String, marker: String) -> String? {
        let value = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("~") else { return nil }
        guard !value.hasPrefix("/") else { return nil }

        let base = (resourcePath as NSString).standardizingPath
        let candidate = ((base as NSString).appendingPathComponent(value) as NSString)
            .standardizingPath
        guard candidate.hasPrefix("\(base)/") else { return nil }
        return candidate
    }

    static func resolveInitialPluginRoot(
        stored: String?,
        detected: String,
        bundledPluginRoot: String?
    ) -> String {
        let normalizedDetected = (detected as NSString).standardizingPath
        let normalizedBundledRoot = bundledPluginRoot.map {
            ($0 as NSString).standardizingPath
        }
        let detectedIsBundled = normalizedBundledRoot == normalizedDetected

        // A packaged app must use the payload covered by its receipt and
        // provenance. Persisted development roots can be stale, unmounted, or
        // a different version, and must never outrank the bundled payload.
        if detectedIsBundled {
            return detected
        }
        guard let stored else { return detected }
        if isLegacyPluginRoot(stored) {
            return detected
        }
        if stored.contains("/.codex/plugins/cache/personal/harvis/"),
           detected.contains("/.codex/plugins/cache/personal/harvis/"),
           stored != detected {
            return detected
        }
        return stored
    }

    static func isLegacyPluginRoot(_ path: String) -> Bool {
        let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        let retiredRoot = ("\(NSHomeDirectory())/plugins/harvis" as NSString).standardizingPath
        return expanded == retiredRoot
            || expanded.hasPrefix("\(retiredRoot)/")
    }

    static func diskInfo(for path: String) -> DiskInfo? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path)
        while !fm.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeURLKey])
        let volumeURL = values?.volume ?? url
        let volumeValues = try? volumeURL.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let totalInt = volumeValues?.volumeTotalCapacity, totalInt > 0 else {
            return nil
        }
        let total = Int64(totalInt)
        let available = volumeValues?.volumeAvailableCapacity.map(Int64.init)
            ?? volumeValues?.volumeAvailableCapacityForImportantUsage
            ?? 0
        let used = max(total - available, 0)
        let name = volumeValues?.volumeName?.isEmpty == false
            ? volumeValues?.volumeName ?? volumeURL.lastPathComponent
            : volumeURL.lastPathComponent
        return DiskInfo(
            name: name.isEmpty ? "Disk" : name,
            volumeURL: volumeURL,
            totalBytes: total,
            availableBytes: max(available, 0),
            usedBytes: used,
            isInternal: nil,
            isRemovable: nil
        )
    }

    nonisolated static func diskInfos() -> [DiskInfo] {
        let classificationKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsBrowsableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey
        ]
        let capacityKeys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(classificationKeys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { volumeURL -> DiskInfo? in
            guard let classification = try? volumeURL.resourceValues(
                forKeys: classificationKeys
            ),
                  shouldInspectVolume(
                    isLocal: classification.volumeIsLocal,
                    isBrowsable: classification.volumeIsBrowsable,
                    isReadOnly: classification.volumeIsReadOnly,
                    isInternal: classification.volumeIsInternal
                  ),
                  let capacity = try? volumeURL.resourceValues(forKeys: capacityKeys),
                  let totalInt = capacity.volumeTotalCapacity,
                  totalInt > 0
            else {
                return nil
            }
            let total = Int64(totalInt)
            let available = capacity.volumeAvailableCapacity.map(Int64.init)
                ?? capacity.volumeAvailableCapacityForImportantUsage
                ?? 0
            let name = classification.volumeName?.isEmpty == false
                ? classification.volumeName ?? volumeURL.lastPathComponent
                : volumeURL.lastPathComponent
            return DiskInfo(
                name: name.isEmpty ? "Disk" : name,
                volumeURL: volumeURL,
                totalBytes: total,
                availableBytes: max(available, 0),
                usedBytes: max(total - available, 0),
                isInternal: classification.volumeIsInternal,
                isRemovable: classification.volumeIsRemovable
            )
        }
        .sorted { left, right in
            if left.isInternal != right.isInternal {
                return left.isInternal == true
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    nonisolated static func shouldInspectVolume(
        isLocal: Bool?,
        isBrowsable: Bool?,
        isReadOnly: Bool?,
        isInternal: Bool?
    ) -> Bool {
        isLocal == true
            && isBrowsable == true
            && (isReadOnly != true || isInternal == true)
    }
}
