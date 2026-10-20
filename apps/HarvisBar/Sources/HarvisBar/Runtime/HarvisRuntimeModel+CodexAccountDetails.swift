import Foundation

extension HarvisRuntimeModel {
    var managedCodexAccountDetails: [String: CodexAccountDetails] {
        let counts = Dictionary(uniqueKeysWithValues: managedChatDisplayAccounts
            .filter { $0.provider == .codex }
            .map { ($0.sourceScope, $0.threadCount) })
        return Dictionary(uniqueKeysWithValues: visibleCodexHomes.map { home in
            (home.id, codexAccountDetails(for: home, threadCount: counts[home.id, default: 0]))
        })
    }

    func codexAccountDetails(for home: CodexHome, threadCount: Int? = nil) -> CodexAccountDetails {
        CodexAccountDetails(
            home: home, workspacePath: codexWorkspacePath(for: home),
            threadCount: threadCount ?? managedChatDisplayAccounts.first(where: { $0.sourceScope == home.id })?.threadCount ?? 0,
            quota: codexHomeQuotas[home.id], quotaError: codexHomeQuotaErrors[home.id],
            quotaUpdatedAt: codexHomeQuotaUpdatedAt[home.id],
            isQuotaLoading: codexHomeQuotaLoadingIDs.contains(home.id),
            isActionRunning: codexHomeActionIDs.contains(home.id),
            actionFeedback: codexHomeActionFeedback[home.id],
            billing: codexHomeBilling[home.id], billingError: codexHomeBillingErrors[home.id],
            isBillingLoading: codexHomeBillingLoadingIDs.contains(home.id)
        )
    }

    func isCurrentCodexAccount(_ expected: CodexHome) -> Bool {
        visibleCodexHomes.contains { CodexAccountIdentity($0) == CodexAccountIdentity(expected) }
    }

    func codexHomeRequestToken(for home: CodexHome) -> CodexHomeRequestToken? {
        guard isCurrentCodexAccount(home) else { return nil }
        return CodexHomeRequestToken(
            homeID: home.id,
            identity: CodexAccountIdentity(home),
            generation: codexHomeRequestGenerations[home.id, default: 0]
        )
    }

    func isCurrentCodexRequest(_ request: CodexHomeRequestToken) -> Bool {
        guard codexHomeRequestGenerations[request.homeID, default: 0] == request.generation,
              let current = visibleCodexHomes.first(where: { $0.id == request.homeID }) else {
            return false
        }
        return CodexAccountIdentity(current) == request.identity
    }

    /// Cleanup must still run while an account is temporarily hidden. Result
    /// publication remains visible-only, but activity ownership is based on
    /// the loaded account list so hiding cannot strand a request as busy.
    func isCurrentCodexRequestForCleanup(_ request: CodexHomeRequestToken) -> Bool {
        guard codexHomeRequestGenerations[request.homeID, default: 0] == request.generation,
              let current = codexHomes.first(where: { $0.id == request.homeID }) else {
            return false
        }
        return CodexAccountIdentity(current) == request.identity
    }

    /// Only opening the popover requests data; hovering remains a cached read.
    /// Failed attempts are throttled too, so repeated clicks cannot hammer CLI.
    func prepareCodexAccountDetails(_ home: CodexHome, now: Date = Date()) {
        guard isCurrentCodexAccount(home) else { return }
        if home.officialQuotaBlockedReason == nil,
           !codexHomeQuotaLoadingIDs.contains(home.id),
           codexHomeQuotaAttemptedAt[home.id].map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            Task { await refreshCodexHomeQuota(home) }
        }
        if home.connections?.contains(where: { $0.accessMode == "api" }) == true,
           !codexHomeBillingLoadingIDs.contains(home.id),
           codexHomeBillingAttemptedAt[home.id].map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            Task { await refreshCodexHomeBilling(home) }
        }
    }

    func performCodexAccountDetailAction(_ action: CodexAccountDetailAction, home: CodexHome) {
        guard isCurrentCodexAccount(home) else {
            lastError = "目标 Codex 账号已变化，请重新打开账号详情。"
            return
        }
        switch action {
        case .refreshQuota:
            Task {
                async let quota: Void = refreshCodexHomeQuota(home)
                async let billing: Void = refreshCodexHomeBilling(home)
                _ = await (quota, billing)
            }
        case .openCLI, .openDesktop:
            Task {
                guard isCurrentCodexAccount(home), !codexHomeActionIDs.contains(home.id) else { return }
                _ = await runCodexHomeAction(action == .openCLI ? "launch-cli" : "launch-desktop", home: home)
            }
        }
    }

    @discardableResult
    func acceptCodexAccountQuota(
        _ result: CodexHomeQuota,
        for home: CodexHome,
        at date: Date = Date(),
        request: CodexHomeRequestToken? = nil
    ) throws -> Bool {
        guard request.map({ isCurrentCodexRequest($0) }) ?? isCurrentCodexAccount(home) else {
            return false
        }
        guard result.ok, result.homeId == home.id else {
            throw HarvisBarError.api("Codex quota response did not match this Home")
        }
        codexHomeQuotas[home.id] = result
        codexHomeQuotaUpdatedAt[home.id] = date
        if result.available {
            codexHomeQuotaErrors.removeValue(forKey: home.id)
        } else {
            codexHomeQuotaErrors[home.id] = result.error ?? "额度暂不可用"
        }
        return true
    }

    /// A directory can be logged into another account without changing its id.
    /// Do not continue showing the former account's quota or launch feedback.
    func invalidateChangedCodexAccountDetails(previous: [CodexHome]) {
        let unchanged = Set(codexHomes.filter { current in
            previous.contains { CodexAccountIdentity($0) == CodexAccountIdentity(current) }
        }.map(\.id))
        let allIDs = Set(previous.map(\.id)).union(codexHomes.map(\.id))
        for homeID in allIDs where !unchanged.contains(homeID) {
            codexHomeRequestGenerations[homeID, default: 0] &+= 1
            codexHomeQuotaLoadingIDs.remove(homeID)
            codexHomeBillingLoadingIDs.remove(homeID)
            codexHomeActionCounts.removeValue(forKey: homeID)
            codexHomeActionIDs.remove(homeID)
        }
        codexHomeQuotas = codexHomeQuotas.filter { unchanged.contains($0.key) }
        codexHomeQuotaErrors = codexHomeQuotaErrors.filter { unchanged.contains($0.key) }
        codexHomeQuotaUpdatedAt = codexHomeQuotaUpdatedAt.filter { unchanged.contains($0.key) }
        codexHomeQuotaAttemptedAt = codexHomeQuotaAttemptedAt.filter { unchanged.contains($0.key) }
        codexHomeBilling = codexHomeBilling.filter { unchanged.contains($0.key) }
        codexHomeBillingErrors = codexHomeBillingErrors.filter { unchanged.contains($0.key) }
        codexHomeBillingAttemptedAt = codexHomeBillingAttemptedAt.filter { unchanged.contains($0.key) }
        codexHomeActionFeedback = codexHomeActionFeedback.filter { unchanged.contains($0.key) }
    }
}
