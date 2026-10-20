import AppKit
import Foundation

extension HarvisRuntimeModel {
    var quickCredentialRegistryPath: String {
        URL(fileURLWithPath: expanded(profileRoot), isDirectory: true)
            .appendingPathComponent("credentials/credentials.json")
            .path
    }

    static func defaultFavoriteFolderPaths() -> [String] {
        let fileManager = FileManager.default
        return [
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        ]
        .compactMap { $0?.standardizedFileURL.path }
        .filter { fileManager.fileExists(atPath: $0) }
    }

    func saveQuickCredential(key: String, value: String, keywords: String = "") async -> Bool {
        quickCredentialAgentHint = nil
        do {
            let explicitKeywords = keywords.trimmingCharacters(in: .whitespacesAndNewlines)
            let keywordInput = explicitKeywords.isEmpty ? key : "\(key),\(explicitKeywords)"
            let metadata = try QuickCredentialMetadata.parse(key: key, keywords: keywordInput)
            let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else {
                throw QuickLocalToolError.emptyCredentialValue
            }
            isCredentialSaving = true
            defer { isCredentialSaving = false }

            let body: [String: Any] = [
                "profile_root": expanded(profileRoot),
                "provider": metadata.provider,
                "label": "default",
                "env_var": metadata.envVariable,
                "secret": secret,
                "source_path": metadata.sourcePath,
                "keywords": metadata.keywords,
                "note": "Saved from HarvisBar quick entry"
            ]
            let response: QuickCredentialSaveResponse
            do {
                response = try await post(
                    "/credentials",
                    body: body,
                    as: QuickCredentialSaveResponse.self
                )
            } catch HarvisBarError.httpStatus(412, _) {
                credentialActionMessage = "正在启用安全本地保存…"
                try await repairCredentialHTTPProtection()
                response = try await post(
                    "/credentials",
                    body: body,
                    as: QuickCredentialSaveResponse.self
                )
            }
            quickCredentialAgentHint = try QuickCredentialAgentHint(
                savedResponse: response,
                fallbackMetadata: metadata,
                registryPath: quickCredentialRegistryPath
            )
            credentialActionMessage = "已保存 · 可复制 Agent 引用"
            credentialActionSucceeded = true
            lastError = nil
            return true
        } catch {
            isCredentialSaving = false
            quickCredentialAgentHint = nil
            credentialActionMessage = clean(error.localizedDescription)
            credentialActionSucceeded = false
            return false
        }
    }

    private func repairCredentialHTTPProtection() async throws {
        _ = try await runServiceManager("restart", service: "http", ensureToken: true)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(150))
            if readAuthToken() != nil,
               let health = try? await fetch("/health", as: HealthData.self),
               health.authRequired == true {
                return
            }
        }
        throw QuickLocalToolError.credentialServiceUnavailable
    }

    func copyQuickCredentialRegistryPath() {
        do {
            try copyQuickCredentialText(
                quickCredentialRegistryPath,
                successMessage: "已复制本地 JSON 路径"
            )
        } catch {
            credentialActionMessage = clean(error.localizedDescription)
            credentialActionSucceeded = false
        }
    }

    func openQuickCredentialJSONInTextEdit() {
        do {
            let fileURL = URL(fileURLWithPath: quickCredentialRegistryPath)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: fileURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                throw QuickLocalToolError.credentialJSONMissing
            }
            guard let textEditURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.TextEdit"
            ) else {
                throw QuickLocalToolError.textEditorUnavailable
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: textEditURL,
                configuration: configuration
            ) { [weak self] _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        credentialActionMessage = clean(error.localizedDescription)
                        credentialActionSucceeded = false
                    } else {
                        credentialActionMessage = "已用文本编辑打开本地 JSON"
                        credentialActionSucceeded = true
                        lastError = nil
                    }
                }
            }
        } catch {
            credentialActionMessage = clean(error.localizedDescription)
            credentialActionSucceeded = false
        }
    }

    func copyQuickCredentialAgentHint() {
        do {
            guard let hint = quickCredentialAgentHint,
                  hint.registryPath == quickCredentialRegistryPath else {
                throw QuickLocalToolError.unsafeCredentialResponse
            }
            try copyQuickCredentialText(
                hint.text,
                successMessage: "已复制 Agent 引用 · 不含 VALUE"
            )
        } catch {
            credentialActionMessage = clean(error.localizedDescription)
            credentialActionSucceeded = false
        }
    }

    private func copyQuickCredentialText(
        _ value: String,
        successMessage: String
    ) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(value, forType: .string) else {
            throw QuickLocalToolError.clipboardUnavailable
        }
        credentialActionMessage = successMessage
        credentialActionSucceeded = true
        lastError = nil
    }

    func chooseFavoriteFolder() {
        let panel = NSOpenPanel()
        panel.title = "添加 Harvis 常用目录"
        panel.prompt = "添加"
        panel.message = "拖入文件后，可一键复制到这些目录。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFavoriteFolder(url.path)
    }

    func addFavoriteFolder(_ path: String) {
        let normalized = URL(fileURLWithPath: expanded(path), isDirectory: true)
            .standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: normalized),
              !favoriteFolderPaths.contains(normalized) else { return }
        favoriteFolderPaths.append(normalized)
        fileCopyMessage = "已添加常用目录：\(URL(fileURLWithPath: normalized).lastPathComponent)"
        fileCopySucceeded = true
    }

    func removeFavoriteFolder(_ path: String) {
        favoriteFolderPaths.removeAll { $0 == path }
    }

    func copyDroppedItems(_ urls: [URL], to destinationPath: String) async -> Bool {
        isFileCopying = true
        defer { isFileCopying = false }
        do {
            let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
                .standardizedFileURL
            let summary = try await Task.detached {
                try LocalFileCopy.copy(urls, to: destination)
            }.value
            fileCopyMessage = "已复制 \(summary.copiedCount) 项到 \(destination.lastPathComponent)"
            fileCopySucceeded = true
            lastError = nil
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return true
        } catch {
            fileCopyMessage = clean(error.localizedDescription)
            fileCopySucceeded = false
            return false
        }
    }
}
