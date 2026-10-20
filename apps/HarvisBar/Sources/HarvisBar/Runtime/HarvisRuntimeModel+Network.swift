import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

extension HarvisRuntimeModel {
    func networkConsoleSnapshot() async -> String {
        do {
            let status = try await networkManagerJSON(["network-status"])
            return Self.jsonString(["status": status])
        } catch {
            return Self.jsonString(["error": clean(error.localizedDescription)])
        }
    }

    func performNetworkConsoleAction(_ message: [String: Any]) async -> String {
        guard !isNetworkActionRunning else {
            return Self.jsonString(["error": "Another network action is still running."])
        }
        isNetworkActionRunning = true
        defer { isNetworkActionRunning = false }

        let action = message["action"] as? String ?? "refresh"
        var actionResult: Any?
        var actionError: String?
        do {
            switch action {
            case "refresh":
                break
            case "switch-system":
                let profile = message["profile"] as? String ?? ""
                guard ["clash", "v2ray", "off"].contains(profile) else {
                    throw HarvisBarError.api("Unknown system proxy profile.")
                }
                actionResult = try await networkManagerJSON(["switch", profile])
                await refreshProxyStatus(force: true)
            case "test-route":
                let route = message["route"] as? String ?? "codex"
                actionResult = try await networkManagerJSON(["test", route])
            case "speed-route":
                let route = message["route"] as? String ?? "codex"
                actionResult = try await networkManagerJSON(["speed", route])
            case "ip-route":
                let route = message["route"] as? String ?? "codex"
                actionResult = try await networkManagerJSON(["ip", route])
            case "apply-route":
                let routeID = message["routeId"] as? String ?? ""
                let label = message["label"] as? String ?? routeID
                let profile = message["profile"] as? String ?? ""
                let domains = message["domains"] as? [String] ?? []
                guard !routeID.isEmpty, !profile.isEmpty, !domains.isEmpty else {
                    throw HarvisBarError.api("Route ID, subscription, and domains are required.")
                }
                var arguments = [
                    "route", "apply", "--id", routeID,
                    "--label", label, "--profile", profile,
                ]
                for domain in domains {
                    arguments += ["--domain", domain]
                }
                actionResult = try await networkManagerJSON(arguments)
                await refreshProxyStatus(force: true)
            case "remove-route":
                let routeID = message["routeId"] as? String ?? ""
                guard !routeID.isEmpty else {
                    throw HarvisBarError.api("Route ID is required.")
                }
                actionResult = try await networkManagerJSON(["route", "remove", "--id", routeID])
                await refreshProxyStatus(force: true)
            case "open-url":
                let raw = message["url"] as? String ?? ""
                guard let url = URL(string: raw),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
                else {
                    throw HarvisBarError.api("Only localhost web ports can be opened.")
                }
                NSWorkspace.shared.open(url)
                actionResult = ["ok": true, "action": "open-url", "url": raw]
            default:
                throw HarvisBarError.api("Unknown network action: \(action)")
            }
        } catch {
            actionError = clean(error.localizedDescription)
        }

        do {
            let status = try await networkManagerJSON(["network-status"])
            let renderedAction: Any
            if let actionError {
                renderedAction = ["error": actionError]
                networkActionSummary = actionError
            } else if let actionResult {
                renderedAction = actionResult
                networkActionSummary = Self.networkActionLabel(actionResult)
            } else {
                renderedAction = NSNull()
                networkActionSummary = "Network status refreshed"
            }
            return Self.jsonString(["status": status, "action": renderedAction])
        } catch {
            let message = actionError ?? clean(error.localizedDescription)
            networkActionSummary = message
            return Self.jsonString(["error": message])
        }
    }

    func networkManagerJSON(_ arguments: [String]) async throws -> Any {
        let timeout: TimeInterval
        switch arguments.first {
        case "speed": timeout = 60
        case "test": timeout = 30
        default: timeout = BoundedProcessRunner.defaultTimeout
        }
        let output = try await runProcess(
            "/usr/bin/python3",
            [proxyManagerPath] + arguments,
            timeout: timeout
        )
        return try JSONSerialization.jsonObject(with: Data(output.utf8), options: [])
    }

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [])
        else {
            return "{\"error\":\"Network response encoding failed.\"}"
        }
        return String(data: data, encoding: .utf8) ?? "{\"error\":\"Network response encoding failed.\"}"
    }

    static func networkActionLabel(_ value: Any) -> String {
        guard let object = value as? [String: Any] else { return "Network action complete" }
        if let speed = object["megabitsPerSecond"] as? Double {
            return String(format: "%.2f Mbps", speed)
        }
        if let ip = object["ip"] as? String, !ip.isEmpty {
            return "IP \(ip)"
        }
        if let tests = object["tests"] as? [[String: Any]], let first = tests.first {
            let endpoint = first["endpoint"] as? String ?? "route"
            let duration = first["durationMs"] as? Int ?? 0
            return "\(endpoint) \(duration) ms"
        }
        if let action = object["action"] as? String {
            return action.replacingOccurrences(of: "-", with: " ")
        }
        if let systemProxy = object["systemProxy"] as? [String: Any],
           let route = systemProxy["route"] as? String {
            return "System proxy: \(route)"
        }
        return "Network action complete"
    }

    func refreshProxyStatus(force: Bool = false) async {
        guard !isProxyRefreshing else { return }
        if !force,
           let lastProxyRefreshAt,
           Date().timeIntervalSince(lastProxyRefreshAt) < 10 {
            return
        }
        isProxyRefreshing = true
        defer { isProxyRefreshing = false }
        do {
            let output = try await runProcess("/usr/bin/python3", [proxyManagerPath, "status"])
            proxyStatus = try JSONDecoder().decode(ProxyManagerStatus.self, from: Data(output.utf8))
            lastProxyRefreshAt = Date()
        } catch {
            proxyStatus = nil
        }
    }

    func runProxyCommand(_ command: String, profile: String) async {
        guard !isProxyRefreshing else { return }
        isProxyRefreshing = true
        defer { isProxyRefreshing = false }
        do {
            let output = try await runProcess(
                "/usr/bin/python3",
                [proxyManagerPath, command, profile],
                timeout: 30
            )
            let status = try JSONDecoder().decode(ProxyManagerStatus.self, from: Data(output.utf8))
            proxyStatus = status
            lastProxyRefreshAt = Date()
            lastActionOutput = "System proxy: \(status.systemProxy.route)"
            lastError = nil
        } catch {
            lastError = clean(error.localizedDescription)
        }
    }

    func runServiceCommand(_ command: String, service: String, ensureToken: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let output = try await runServiceManager(command, service: service, ensureToken: ensureToken)
            lastActionOutput = output
            lastError = nil
        } catch {
            lastError = clean(error.localizedDescription)
        }
        await refreshAll()
    }

}
