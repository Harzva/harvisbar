import Foundation
import SwiftUI

extension HarvisPopoverView {
    var quickCredentialBank: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal.fill")
                    .foregroundColor(theme.accent)
                Text("Credential Bank")
                    .font(.caption.bold())
                Spacer()
                Text("本地 JSON")
                    .font(.caption2.monospaced())
                    .foregroundColor(theme.muted)
            }

            Text("KEY 是名称；真正的共享密钥只填在下面 VALUE。")
                .font(.caption2)
                .foregroundColor(theme.muted)

            TextField("KEY / 名称（不是密钥）", text: $quickCredentialKey)
                .textFieldStyle(.roundedBorder)
                .help("填写凭据名称或环境变量名，例如 VPN_IPSEC_SHARED_SECRET；不要把实际密钥填在这里")
                .onChange(of: quickCredentialKey) { _ in
                    model.quickCredentialAgentHint = nil
                }
            SecureField("VALUE / 实际共享密钥", text: $quickCredentialValue)
                .textFieldStyle(.roundedBorder)
                .help("这里填写实际的 VPN/IPSec 共享密钥")
            TextField("KEYWORDS / 关键词（可选）", text: $quickCredentialKeywords)
                .textFieldStyle(.roundedBorder)
                .help("多个关键词用逗号分隔；保存时会追加到原记录，不覆盖原有关键词或 VALUE")
                .onChange(of: quickCredentialKeywords) { _ in
                    model.quickCredentialAgentHint = nil
                }

            HStack(spacing: 4) {
                Text("文件：\(model.quickCredentialRegistryPath)")
                    .font(.caption2.monospaced())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Button {
                    model.openQuickCredentialJSONInTextEdit()
                } label: {
                    Label("记事本", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("用 macOS 文本编辑打开本地 credentials.json；文件包含明文密钥")
                Button {
                    model.copyQuickCredentialRegistryPath()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制本地 credentials.json 路径；该文件包含密钥，请勿发给 Agent")
            }

            HStack(spacing: 6) {
                Text(model.credentialActionMessage)
                    .font(.caption2)
                    .foregroundColor(model.credentialActionSucceeded ? theme.muted : Color.red)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    model.openCredentialBank()
                } label: {
                    Label("网页保存", systemImage: "safari")
                }
                .help("打开 Studio 网页保存页；所有凭据只写入本地 credentials.json")
                Button {
                    model.copyQuickCredentialAgentHint()
                } label: {
                    Label("复制引用", systemImage: "link")
                }
                .disabled(
                    model.quickCredentialAgentHint?.registryPath
                        != model.quickCredentialRegistryPath
                )
                .help("保存成功后复制服务确认的 Agent 引用；不包含 VALUE")
                Button {
                    Task {
                        if await model.saveQuickCredential(
                            key: quickCredentialKey,
                            value: quickCredentialValue,
                            keywords: quickCredentialKeywords
                        ) {
                            quickCredentialValue = ""
                            quickCredentialKeywords = ""
                        }
                    }
                } label: {
                    Label(model.isCredentialSaving ? "保存中" : "本机保存", systemImage: "lock.shield")
                }
                .disabled(
                    model.isCredentialSaving
                        || quickCredentialKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || quickCredentialValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .help("KEY、关键词、引用和 VALUE 只保存到权限 0600 的本地 credentials.json；重复保存会增量合并关键词并保留原 VALUE")
    }

    var quickFileDrop: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .foregroundColor(theme.accent)
                Text("文件快捷复制")
                    .font(.caption.bold())
                Spacer()
                Button {
                    model.chooseFavoriteFolder()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加常用目录")
            }

            VStack(spacing: 3) {
                Image(systemName: isFileDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isFileDropTargeted ? theme.accent : theme.muted)
                Text(droppedFileURLs.isEmpty ? "把文件拖到这里" : droppedFilesLabel)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(droppedFileURLs.isEmpty ? "随后选择常用目录复制" : "选择下面一个目录")
                    .font(.caption2)
                    .foregroundColor(theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                (isFileDropTargeted ? theme.accent : theme.surfaceAlt)
                    .opacity(isFileDropTargeted ? 0.16 : 0.72)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isFileDropTargeted ? theme.accent : theme.line,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .dropDestination(for: URL.self) { urls, _ in
                let existing = urls
                    .map(\.standardizedFileURL)
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !existing.isEmpty else { return false }
                droppedFileURLs = existing
                model.fileCopyMessage = "已接收 \(existing.count) 项，请选择目标目录"
                model.fileCopySucceeded = true
                return true
            } isTargeted: { targeted in
                isFileDropTargeted = targeted
            }

            if !droppedFileURLs.isEmpty {
                VStack(spacing: 3) {
                    ForEach(model.favoriteFolderPaths, id: \.self) { path in
                        favoriteFolderRow(path)
                    }
                    if model.favoriteFolderPaths.isEmpty {
                        Button {
                            model.chooseFavoriteFolder()
                        } label: {
                            Label("先添加一个常用目录", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            Text(model.fileCopyMessage)
                .font(.caption2)
                .foregroundColor(model.fileCopySucceeded ? theme.muted : Color.red)
                .lineLimit(2)
        }
    }

    func favoriteFolderRow(_ path: String) -> some View {
        HStack(spacing: 4) {
            Button {
                let items = droppedFileURLs
                Task {
                    if await model.copyDroppedItems(items, to: path) {
                        droppedFileURLs = []
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "doc.on.doc")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.isFileCopying || droppedFileURLs.isEmpty)
            .help("复制到 \(path)")

            Button {
                model.removeFavoriteFolder(path)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("移除这个快捷目录")
        }
    }

    var droppedFilesLabel: String {
        if droppedFileURLs.count == 1 {
            return droppedFileURLs[0].lastPathComponent
        }
        return "\(droppedFileURLs.count) 个项目"
    }
}
