import Foundation

extension HarvisRuntimeModel {
    var codexCLIAlignmentScriptPath: String {
        expanded("\(pluginRoot)/scripts/harvis_codex_cli_alignment.sh")
    }

    func refreshCodexCLIAlignment(force: Bool = false) async {
        guard !isCodexCLIAligning, !isCodexCLIRefreshing else { return }
        if !force,
           let lastCodexCLIAlignmentRefreshAt,
           Date().timeIntervalSince(lastCodexCLIAlignmentRefreshAt) < 15 {
            return
        }

        isCodexCLIRefreshing = true
        defer { isCodexCLIRefreshing = false }
        do {
            let output = try await runProcess(
                "/bin/bash",
                [codexCLIAlignmentScriptPath, "--status"]
            )
            let status = try Self.decodeCodexCLIAlignmentStatus(output)
            codexCLIAlignment = status
            if !status.aligned {
                codexCLIAlignmentMessage = nil
            }
            codexCLIAlignmentError = nil
            lastCodexCLIAlignmentRefreshAt = Date()
        } catch {
            codexCLIAlignmentError = clean(error.localizedDescription)
        }
    }

    func requestCodexCLIAlignment() {
        guard !isCodexCLIAligning, !isCodexCLIRefreshing else { return }
        Task {
            isCodexCLIAligning = true
            codexCLIAlignmentError = nil
            defer { isCodexCLIAligning = false }

            do {
                let output = try await runProcess(
                    "/bin/bash",
                    [codexCLIAlignmentScriptPath, "--align"],
                    timeout: 120
                )
                let status = try Self.decodeCodexCLIAlignmentStatus(output)
                guard status.aligned else {
                    throw HarvisBarError.process(
                        "Alignment finished, but the Mini and Studio versions still differ."
                    )
                }
                codexCLIAlignment = status
                codexCLIAlignmentMessage = status.actionMessage ?? "终端 Codex CLI 已对齐。"
                lastCodexCLIAlignmentRefreshAt = Date()
            } catch {
                codexCLIAlignmentError = clean(error.localizedDescription)
                codexCLIAlignmentMessage = nil
            }
        }
    }

    nonisolated static func decodeCodexCLIAlignmentStatus(
        _ output: String
    ) throws -> CodexCLIAlignmentStatus {
        guard let data = output.data(using: .utf8) else {
            throw HarvisBarError.process("Codex CLI status output was not UTF-8.")
        }
        let status = try JSONDecoder().decode(CodexCLIAlignmentStatus.self, from: data)
        guard status.schema == "harvis.codex-cli-alignment.v1" else {
            throw HarvisBarError.process("Unsupported Codex CLI alignment status schema.")
        }
        return status
    }
}
