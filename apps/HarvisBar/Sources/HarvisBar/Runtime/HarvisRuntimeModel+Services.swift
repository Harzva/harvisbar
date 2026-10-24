import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

extension HarvisRuntimeModel {
    func runCodexArchive() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let output = try await runProcess(
                serviceManagerPath,
                ["codex", "archive-automation-threads"],
                timeout: 120
            )
            let result = try JSONDecoder().decode(CodexArchiveResult.self, from: Data(output.utf8))
            guard result.ok else {
                throw HarvisBarError.api(result.error ?? "Codex thread archive failed")
            }
            codexArchiveResult = result
            lastActionOutput = output
            lastError = nil
        } catch {
            lastError = clean(error.localizedDescription)
        }
    }

    func refreshCodexHomes() async {
        guard !isCodexHomeRefreshing else { return }
        isCodexHomeRefreshing = true
        defer { isCodexHomeRefreshing = false }
        do {
            let includeExternal = accessPreferences.externalHomeDiscoveryEnabled
            let output = try await runProcess(serviceManagerPath,
                Self.codexHomeDiscoveryArguments(includeExternalLaunchers: includeExternal))
            let result = try JSONDecoder().decode(CodexHomeList.self, from: Data(output.utf8))
            guard result.ok else {
                throw HarvisBarError.api("CODEX_HOME discovery failed")
            }
            // A preference change while the helper was running invalidates that scope.
            guard includeExternal == accessPreferences.externalHomeDiscoveryEnabled else { return }
            let permitted = result.items.filter(permitsDiscoveredCodexHome)
            codexHomes = permitted
            codexHomeWarnings = result.warnings
            lastCodexHomeDiscoveryFingerprint = Self.codexHomeDiscoveryFingerprint(
                additionalHomePaths: permitted.map(\.path),
                includeExternalLaunchers: includeExternal, explicitHomePaths: Self.explicitCodexHomePaths
            )
            let visibleItems = visibleCodexHomes
            if !visibleItems.contains(where: { $0.id == selectedCodexHomeID }) {
                selectedCodexHomeID = visibleItems.first?.id
            }
            let validHomeIDs = Set(result.items.map(\.id))
            codexHomeQuotas = codexHomeQuotas.filter { validHomeIDs.contains($0.key) }
            codexHomeQuotaErrors = codexHomeQuotaErrors.filter { validHomeIDs.contains($0.key) }
            let selectedID = selectedCodexHomeID
            let homesForQuotaRefresh = visibleItems.filter {
                $0.officialQuotaBlockedReason == nil
            }.sorted { left, right in
                if left.id == selectedID, right.id != selectedID { return true }
                if right.id == selectedID, left.id != selectedID { return false }
                return left.label.localizedCaseInsensitiveCompare(right.label) == .orderedAscending
            }
            Task { [weak self] in
                await self?.refreshCodexHomeQuotas(homesForQuotaRefresh)
            }
            if let home = selectedCodexHome {
                await refreshCodexThreads(home)
            }
            let homesToWarm = visibleItems.filter { $0.id != selectedID }
            Task { [weak self] in
                guard let self else { return }
                // Keep cold-start pressure bounded. Each successful result is
                // cached, so the next account switch can project immediately.
                for home in homesToWarm {
                    await refreshCodexThreads(home)
                }
            }
            lastError = nil
        } catch {
            lastError = clean(error.localizedDescription)
        }
    }

    func refreshCodexHomesIfFilesystemChanged() async {
        guard !isCodexHomeRefreshing else { return }
        let fingerprint = Self.codexHomeDiscoveryFingerprint(
            additionalHomePaths: codexHomes.filter(permitsDiscoveredCodexHome).map(\.path),
            includeExternalLaunchers: accessPreferences.externalHomeDiscoveryEnabled,
            explicitHomePaths: Self.explicitCodexHomePaths
        )
        guard fingerprint != lastCodexHomeDiscoveryFingerprint else { return }
        await refreshCodexHomes()
    }

    func refreshCodexHomeQuotas(_ homes: [CodexHome]) async {
        for home in homes {
            await refreshCodexHomeQuota(home)
        }
    }

    func restoreCodexThreadSnapshots() async {
        do {
            let snapshots = try await codexThreadSnapshotStore.load(now: Date())
            codexThreadSnapshotsByHomeID = snapshots
            lastCodexThreadRefreshAtByHomeID = snapshots.mapValues(\.updatedAt)
            projectCodexThreadSnapshot(for: selectedCodexHomeID)
        } catch {
            // A cache is an acceleration layer, never the authority. Ignore a
            // missing/corrupt/old snapshot and continue with live discovery.
            codexThreadSnapshotsByHomeID = [:]
            lastCodexThreadRefreshAtByHomeID = [:]
            projectCodexThreadSnapshot(for: selectedCodexHomeID)
        }
    }

    func refreshManagedChatProviders() async {
        ManagedProjectPathCache.shared.removeAll()
        async let codexHomes: Void = refreshCodexHomes()
        async let dshThreads: Void = refreshDshThreads()
        async let workBuddyThreads: Void = refreshWorkBuddyThreads()
        _ = await (codexHomes, dshThreads, workBuddyThreads)

        // This gate must precede project resolution: the resolver stats/canonicalizes cwd.
        guard accessPreferences.historicalProjectAccessEnabled else { return }
        let completeThreads = managedChatThreads
        let projects = Dictionary(
            grouping: completeThreads,
            by: { ManagedChatProjectResolver.resolve(thread: $0).id }
        ).values.compactMap { threads in
            threads.first.map {
                ManagedChatProjectResolver.resolve(thread: $0)
            }
        }
        await refreshManagedChatGovernance(
            threads: completeThreads,
            projects: projects
        )
    }

    func refreshCodexHomeQuota(_ home: CodexHome) async {
        guard isCurrentCodexAccount(home) else { return }
        guard home.officialQuotaBlockedReason == nil else {
            codexHomeQuotas.removeValue(forKey: home.id)
            codexHomeQuotaErrors.removeValue(forKey: home.id)
            codexHomeQuotaUpdatedAt.removeValue(forKey: home.id)
            return
        }
        guard let request = beginCodexHomeQuotaRequest(home) else { return }
        defer { endCodexHomeQuotaRequest(request) }
        do {
            let output = try await runProcess(serviceManagerPath, [
                "codex", "quota", "--home", home.path
            ], timeout: CodexCLIThreadActivityProbe.defaultTimeoutSeconds)
            let result = try JSONDecoder().decode(CodexHomeQuota.self, from: Data(output.utf8))
            guard isCurrentCodexRequest(request) else { return }
            try acceptCodexAccountQuota(result, for: home, request: request)
        } catch {
            guard isCurrentCodexRequest(request) else { return }
            codexHomeQuotaErrors[home.id] = clean(error.localizedDescription)
        }
    }

    func refreshCodexThreads(_ home: CodexHome, userInitiated: Bool = false) async {
        // Custom launchers may supply credentials or provider-specific startup
        // context. Discovery and selection must not implicitly probe that CLI.
        guard !home.isCustomModelHome || userInitiated else { return }
        guard codexThreadRefreshingHomeIDs.insert(home.id).inserted else { return }
        defer { codexThreadRefreshingHomeIDs.remove(home.id) }
        do {
            let output = try await runProcess(serviceManagerPath, [
                "codex", "chats", "--home", home.path, "--limit", "100"
            ], timeout: CodexCLIThreadActivityProbe.defaultTimeoutSeconds)
            let result = try JSONDecoder().decode(CodexThreadList.self, from: Data(output.utf8))
            guard result.ok else {
                throw HarvisBarError.api("Codex chat discovery failed")
            }
            let now = Date()
            codexThreadSnapshotsByHomeID[home.id] = CodexThreadSnapshot(
                updatedAt: now,
                threads: result.items
            )
            lastCodexThreadRefreshAtByHomeID[home.id] = now
            if selectedCodexHomeID == home.id {
                acceptCodexThreads(result.items, sourceHomeID: home.id)
                codexThreadError = nil
            }
            let store = codexThreadSnapshotStore
            let threads = result.items
            Task {
                try? await store.save(threads, for: home.id, now: now)
            }
        } catch {
            lastCodexThreadRefreshAtByHomeID[home.id] = Date()
            if selectedCodexHomeID == home.id {
                codexThreadError = clean(error.localizedDescription)
            }
        }
    }

    func refreshCodexThreadsIfDue() async {
        let homesDue = visibleCodexHomes.filter { home in
            lastCodexThreadRefreshAtByHomeID[home.id]
                .map({ Date().timeIntervalSince($0) >= 60 }) != false
        }
        for home in homesDue {
            await refreshCodexThreads(home)
        }
    }

    func refreshWorkBuddyThreads() async {
        guard !isWorkBuddyThreadRefreshing else { return }
        isWorkBuddyThreadRefreshing = true
        defer { isWorkBuddyThreadRefreshing = false }
        do {
            let output = try await runProcess(serviceManagerPath, [
                "workbuddy", "chats", "--home", expanded("~/.workbuddy"), "--limit", "100"
            ])
            let result = try JSONDecoder().decode(WorkBuddyThreadList.self, from: Data(output.utf8))
            guard result.ok else {
                throw HarvisBarError.api("WorkBuddy chat discovery failed")
            }
            workBuddyThreads = result.items
            workBuddyThreadError = nil
        } catch {
            workBuddyThreads = []
            workBuddyThreadError = clean(error.localizedDescription)
        }
    }

    func refreshDshThreads() async {
        guard !isDshThreadRefreshing else { return }
        isDshThreadRefreshing = true
        defer {
            isDshThreadRefreshing = false
            lastDshThreadRefreshAt = Date()
        }

        do {
            let output = try await runProcess(
                serviceManagerPath,
                ["dsh-web", "running"]
            )
            let catalog = try JSONDecoder().decode(
                DshRunningEndpointCatalog.self,
                from: Data(output.utf8)
            )
            guard catalog.ok, !catalog.includesSecrets else {
                throw HarvisBarError.api("DSH Runtime Catalog returned an unsafe response")
            }

            let endpoints = try catalog.validatedEndpoints()
            dshRunningEndpoints = endpoints
            var activeEndpointByScope: [String: DshRuntimeEndpoint] = [:]
            for endpoint in endpoints where activeEndpointByScope[endpoint.sourceScope] == nil {
                activeEndpointByScope[endpoint.sourceScope] = endpoint
            }
            var outcomes: [DshEndpointDiscoveryOutcome] = []
            for endpoint in endpoints {
                do {
                    let discovery = try await DshHostApiClient(
                        endpoint: endpoint
                    ).discover()
                    outcomes.append(.success(discovery))
                } catch {
                    outcomes.append(.failure(
                        endpoint: endpoint,
                        message: clean(error.localizedDescription)
                    ))
                }
            }

            let state = DshManagedChatAdapter.refreshState(
                activeEndpoints: endpoints,
                previousThreadsByScope: dshThreadCacheByScope,
                outcomes: outcomes
            )
            dshThreadCacheByScope = state.threadsByScope
            dshThreads = state.threads
            dshRuntimeEndpointsByScope = activeEndpointByScope
            dshThreadErrorsByEndpoint = state.errorsByEndpoint
            dshThreadError = state.errorsByEndpoint.isEmpty
                ? nil
                : "\(state.errorsByEndpoint.count) DSH endpoint(s) unavailable; showing cached metadata where available."
            await refreshDshCapabilities(endpoints: endpoints)
        } catch {
            let message = clean(error.localizedDescription)
            // Catalog failure revokes endpoint authority. Cached conversation
            // metadata may remain visible, but no stale endpoint can be used
            // as the dedicated project brain.
            dshRunningEndpoints = []
            dshRuntimeEndpointsByScope = [:]
            dshBridgeStatesByScope = [:]
            dshThreadError = message
            dshThreadErrorsByEndpoint = ["catalog": message]
        }
    }

    func refreshDshThreadsIfDue() async {
        guard lastDshThreadRefreshAt.map({ Date().timeIntervalSince($0) >= 10 }) != false else {
            return
        }
        await refreshDshThreads()
    }

    /// All account actions share activity ownership, including CLI/login and
    /// desktop navigation. One completion cannot hide another active request.
    func beginCodexHomeQuotaRequest(_ home: CodexHome) -> CodexHomeRequestToken? {
        guard let request = codexHomeRequestToken(for: home),
              !codexHomeQuotaLoadingIDs.contains(home.id) else { return nil }
        codexHomeQuotaLoadingIDs.insert(home.id)
        codexHomeQuotaAttemptedAt[home.id] = Date()
        return request
    }

    func endCodexHomeQuotaRequest(_ request: CodexHomeRequestToken) {
        guard isCurrentCodexRequestForCleanup(request) else { return }
        codexHomeQuotaLoadingIDs.remove(request.homeID)
    }

    func beginCodexHomeAction(for home: CodexHome) -> CodexHomeRequestToken? {
        guard let request = codexHomeRequestToken(for: home) else { return nil }
        beginCodexHomeAction(home.id)
        return request
    }

    func endCodexHomeAction(_ request: CodexHomeRequestToken) {
        guard isCurrentCodexRequestForCleanup(request) else { return }
        endCodexHomeAction(request.homeID)
    }

    func beginCodexHomeAction(_ homeID: String) {
        codexHomeActionCounts[homeID, default: 0] += 1
        if codexHomeActionCounts[homeID] == 1 {
            codexHomeActionIDs.insert(homeID)
            codexHomeActionFeedback.removeValue(forKey: homeID)
        }
    }

    func endCodexHomeAction(_ homeID: String) {
        guard let count = codexHomeActionCounts[homeID] else { return }
        if count > 1 { codexHomeActionCounts[homeID] = count - 1 }
        else {
            codexHomeActionCounts.removeValue(forKey: homeID)
            codexHomeActionIDs.remove(homeID)
        }
    }

    func runCodexHomeAction(_ action: String, home: CodexHome) async -> Bool {
        if action == "launch-desktop" { return await performCodexDesktopOpen(home: home) }
        guard isCurrentCodexAccount(home),
              let request = beginCodexHomeAction(for: home) else { return false }
        let authBaseline = action == "login"
            ? Self.codexAuthFileSnapshot(homePath: home.path)
            : nil
        defer { endCodexHomeAction(request) }
        do {
            var args = ["codex", action, "--home", home.path]
            if action == "launch-cli" {
                args += ["--cwd", codexWorkspacePath(for: home)]
            }
            let output = try await runProcess(serviceManagerPath, args)
            let result = try JSONDecoder().decode(CodexHomeLaunchResult.self, from: Data(output.utf8))
            guard result.ok else {
                throw HarvisBarError.api(result.message)
            }
            guard result.homeId == home.id else {
                throw HarvisBarError.api("Codex 启动结果与目标账号不匹配。")
            }
            guard isCurrentCodexRequest(request) else { return true }
            lastActionOutput = result.message
            lastError = nil
            codexHomeActionFeedback[home.id] = .init(
                message: action == "login" ? "已请求打开此账号的登录窗口。" : "已请求在此账号的工作区打开 Codex CLI。",
                isError: false
            )
            if action == "login" {
                Task { [weak self] in
                    await self?.refreshCodexHomeAfterLogin(
                        home: home,
                        baseline: authBaseline
                    )
                }
            }
            return true
        } catch {
            guard isCurrentCodexRequest(request) else { return false }
            lastError = clean(error.localizedDescription)
            codexHomeActionFeedback[home.id] = .init(message: clean(error.localizedDescription), isError: true)
            return false
        }
    }

    func runCodexThreadAction(
        _ action: String,
        home: CodexHome,
        threadID: String,
        workingDirectory: String
    ) async -> Bool {
        guard action == "resume-cli",
              !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isCurrentCodexAccount(home),
              let request = beginCodexHomeAction(for: home) else { return false }
        defer { endCodexHomeAction(request) }
        do {
            let output = try await runProcess(serviceManagerPath, [
                "codex", "resume-cli",
                "--home", home.path,
                "--cwd", workingDirectory,
                "--thread-id", threadID
            ])
            let result = try JSONDecoder().decode(CodexHomeLaunchResult.self, from: Data(output.utf8))
            guard result.ok else {
                throw HarvisBarError.api(result.message)
            }
            guard result.action == "resume-cli" else {
                throw HarvisBarError.api("Codex 启动结果不是请求的会话恢复操作。")
            }
            guard result.homeId == home.id else {
                throw HarvisBarError.api("Codex 启动结果与目标账号不匹配。")
            }
            guard isCurrentCodexRequest(request) else { return true }
            lastActionOutput = "已请求在 \(home.accountDisplayLabel) 的 Terminal 恢复 \(threadID)"
            lastError = nil
            codexHomeActionFeedback[home.id] = .init(
                message: "已请求在此账号的工作目录恢复 Codex 会话。",
                isError: false
            )
            return true
        } catch {
            guard isCurrentCodexRequest(request) else { return false }
            lastError = clean(error.localizedDescription)
            codexHomeActionFeedback[home.id] = .init(message: clean(error.localizedDescription), isError: true)
            return false
        }
    }

    func runHarnessPreflightTests() async {
        isBusy = true
        let targets = (displayedHarnesses?.items ?? [])
            .filter { $0.testTarget == true }
            .map(\.id)
        harnessTestingIDs = Set(targets.isEmpty ? ["cxspark", "cckimi", "mimocode"] : targets)
        defer {
            isBusy = false
            harnessTestingIDs = []
        }
        do {
            let payload: [String: Any] = [
                "root": expanded(workspaceRoot),
                "timeout_seconds": 90
            ]
            let result = try await post("/agent-harnesses/test", body: payload, as: AgentHarnesses.self)
            harnessTestResult = result
            lastActionOutput = result.detailedSummary
            lastError = nil
        } catch {
            lastError = clean(error.localizedDescription)
        }
        await refreshAll()
    }

    func runAgentMailSummary() async {
        isMailRefreshing = true
        defer { isMailRefreshing = false }
        do {
            let payload: [String: Any] = ["limit": 8]
            let result = try await post("/agent-mail/unread-summary", body: payload, as: AgentMailSummary.self)
            agentMailSummary = result
            lastActionOutput = result.summary
            lastError = nil
        } catch {
            lastError = clean(error.localizedDescription)
        }
        await refreshAll()
    }

    func runFirstRunInitialization() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let profileOutput = try await runProcess(serviceManagerPath, [
                "init-profile",
                "--profile-root", profileRoot
            ], timeout: 120)
            let workspaceOutput = try await runProcess(serviceManagerPath, [
                "init-workspace",
                "--root", expanded(workspaceRoot)
            ], timeout: 120)
            lastActionOutput = [profileOutput, workspaceOutput]
                .map { clean($0) }
                .joined(separator: "\n")
            lastError = nil
        } catch {
            lastError = clean(error.localizedDescription)
        }
        await runServiceCommand("start", service: "both", ensureToken: true)
    }

    func runServiceManager(_ command: String, service: String, ensureToken: Bool) async throws -> String {
        var args = [
            "service-manager",
            command,
            "--service", service,
            "--port", String(port),
            "--root", expanded(workspaceRoot),
            "--profile-root", profileRoot,
            "--plugin-root", expanded(pluginRoot)
        ]
        if ensureToken {
            args.append("--ensure-token-file")
        }
        return try await runProcess(serviceManagerPath, args, timeout: 120)
    }

}
