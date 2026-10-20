import Foundation

extension HarvisRuntimeModel {
    func evidenceState(for thread: CodexThreadSummary) -> CodexInspectorTimelineState {
        codexEvidenceStates[codexThreadStorageKey(thread)] ?? CodexInspectorTimelineState()
    }

    func evidenceError(for thread: CodexThreadSummary) -> String? {
        codexEvidenceErrors[codexThreadStorageKey(thread)]
    }

    func isEvidenceLoading(for thread: CodexThreadSummary) -> Bool {
        codexEvidenceLoadingKeys.contains(codexThreadStorageKey(thread))
    }

    func refreshEvidence(for thread: CodexThreadSummary) {
        loadEvidence(for: thread, reset: true)
    }

    func loadMoreEvidence(for thread: CodexThreadSummary) {
        loadEvidence(for: thread, reset: false)
    }

    private func loadEvidence(for thread: CodexThreadSummary, reset: Bool) {
        guard let home = selectedCodexHome else { return }
        let key = codexThreadStorageKey(thread)
        guard !codexEvidenceLoadingKeys.contains(key) else { return }
        let state = codexEvidenceStates[key]
        if !reset && state != nil && state?.canLoadMore != true { return }
        let cursor = reset ? nil : state?.nextCursor

        codexEvidenceLoadingKeys.insert(key)
        codexEvidenceErrors.removeValue(forKey: key)
        Task {
            defer { codexEvidenceLoadingKeys.remove(key) }
            do {
                var arguments = [
                    "codex", "evidence",
                    "--home", home.path,
                    "--thread", thread.id,
                    "--limit", "24"
                ]
                if let cursor {
                    arguments += ["--cursor", cursor]
                }
                let output = try await runProcess(serviceManagerPath, arguments)
                let page = try JSONDecoder().decode(
                    CodexThreadEvidencePage.self,
                    from: Data(output.utf8)
                )
                guard page.ok else {
                    throw HarvisBarError.api("Codex evidence query failed")
                }
                guard selectedCodexHomeID == home.id else { return }
                var nextState = codexEvidenceStates[key] ?? CodexInspectorTimelineState()
                nextState.apply(page, reset: reset)
                codexEvidenceStates[key] = nextState
                codexEvidenceErrors.removeValue(forKey: key)
            } catch {
                guard selectedCodexHomeID == home.id else { return }
                codexEvidenceErrors[key] = clean(error.localizedDescription)
            }
        }
    }
}
