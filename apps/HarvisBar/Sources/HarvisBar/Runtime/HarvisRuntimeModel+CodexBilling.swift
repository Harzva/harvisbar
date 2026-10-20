import Foundation

extension HarvisRuntimeModel {
    /// Provider usage is a separate opt-in read. Discovery and selection must
    /// not start the custom Codex CLI or send a prompt to a model.
    func refreshCodexHomeBilling(_ home: CodexHome) async {
        guard isCurrentCodexAccount(home),
              home.connections?.contains(where: { $0.accessMode == "api" }) == true,
              !codexHomeBillingLoadingIDs.contains(home.id),
              let request = codexHomeRequestToken(for: home) else { return }
        codexHomeBillingLoadingIDs.insert(home.id)
        codexHomeBillingAttemptedAt[home.id] = Date()
        defer {
            if isCurrentCodexRequestForCleanup(request) { codexHomeBillingLoadingIDs.remove(home.id) }
        }
        do {
            let output = try await runProcess(serviceManagerPath, [
                "codex", "billing", "--home", home.path
            ], timeout: 20)
            let result = try JSONDecoder().decode(CodexHomeBilling.self, from: Data(output.utf8))
            guard isCurrentCodexRequest(request) else { return }
            try acceptCodexAccountBilling(result, for: home, request: request)
        } catch {
            guard isCurrentCodexRequest(request) else { return }
            codexHomeBillingErrors[home.id] = "用量读取失败，请稍后刷新。"
        }
    }

    @discardableResult
    func acceptCodexAccountBilling(
        _ result: CodexHomeBilling, for home: CodexHome,
        request: CodexHomeRequestToken? = nil
    ) throws -> Bool {
        guard request.map({ isCurrentCodexRequest($0) }) ?? isCurrentCodexAccount(home) else { return false }
        guard result.ok, result.homeId == home.id else {
            throw HarvisBarError.api("Codex usage response did not match this Home")
        }
        let configuredIDs = Set((home.connections ?? []).map(\.id))
        let old = codexHomeBilling[home.id]
        let entries = result.connections.filter { configuredIDs.contains($0.id) }.map { entry in
            guard !entry.available,
                  let previous = old?.connections.first(where: { $0.id == entry.id }),
                  !previous.balances.isEmpty || !previous.allowances.isEmpty else { return entry }
            return CodexConnectionUsageSnapshot(
                id: entry.id, available: false, status: entry.status,
                serviceAvailable: entry.serviceAvailable, balances: previous.balances,
                allowances: previous.allowances, updatedAt: previous.updatedAt, error: entry.error
            )
        }
        codexHomeBilling[home.id] = CodexHomeBilling(
            ok: true, schemaVersion: result.schemaVersion, homeId: result.homeId, connections: entries
        )
        codexHomeBillingErrors.removeValue(forKey: home.id)
        return true
    }
}
