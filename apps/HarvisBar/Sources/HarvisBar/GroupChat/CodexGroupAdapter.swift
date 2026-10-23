import CryptoKit
import Foundation

struct CodexGroupAdapter: Sendable {
    let pool: CodexAppServerPool
    let preparedThreads = CodexGroupPreparedThreads()

    func identity(homePath: String) async throws -> String {
        let connection = await pool.connection(for: homePath)
        let generation = try await connection.connect()
        let response = try await connection.request(method: "account/read", params: .object(["refreshToken": .bool(false)]))
        guard await connection.connectionID() == generation,
              let account = response["account"], account != .null,
              account["type"]?.stringValue == "chatgpt" else {
            throw HarvisGroupError.invalid("This profile has no verifiable ChatGPT account. Sign in to the selected Codex home.")
        }
        var accountID = response["workspaceRouting"]?["chatgptAccountId"]?.stringValue
        if accountID?.isEmpty != false {
            let limits = try await connection.request(method: "account/rateLimits/read", params: .object([:]))
            accountID = limits["accountId"]?.stringValue
        }
        guard await connection.connectionID() == generation,
              let accountID, !accountID.isEmpty else {
            throw HarvisGroupError.invalid("Could not verify this profile's workspace account identity. No turn was submitted.")
        }
        // Server account ID distinguishes workspaces even when their displayed email is identical.
        // Persist only a comparison fingerprint, never tokens or the complete account response.
        return SHA256.hash(data: Data(("chatgpt\n" + accountID).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func availableModel(connection: CodexAppServerConnection) async throws -> (model: String, effort: String) {
        var cursor: String?
        var models: [CodexJSONValue] = []
        for _ in 0 ..< 4 {
            var params: [String: CodexJSONValue] = ["includeHidden": .bool(false), "limit": .number(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await connection.request(method: "model/list", params: .object(params))
            models += (page["data"]?.arrayValue ?? []).filter { $0["hidden"]?.boolValue != true && $0["model"]?.stringValue?.isEmpty == false }
            cursor = page["nextCursor"]?.stringValue
            if cursor == nil || models.contains(where: { $0["isDefault"]?.boolValue == true }) { break }
        }
        guard let selected = models.first(where: { $0["isDefault"]?.boolValue == true }) ?? models.first,
              let model = selected["model"]?.stringValue else {
            throw HarvisGroupError.invalid("This account exposes no available Codex model.")
        }
        let supported = selected["supportedReasoningEfforts"]?.arrayValue?.compactMap { $0["reasoningEffort"]?.stringValue } ?? []
        let preferred = selected["defaultReasoningEffort"]?.stringValue
        guard let effort = supported.contains("medium") ? "medium" : (preferred.flatMap { supported.contains($0) ? $0 : nil } ?? supported.first) else {
            throw HarvisGroupError.invalid("Selected model did not advertise a supported reasoning effort.")
        }
        return (model, effort)
    }

    func start(homePath: String, projectPath: String, permission: HarvisGroupPermission,
               predecessor: HarvisGroupBinding? = nil, fork: Bool = false) async throws -> HarvisGroupBinding {
        let identity = try await identity(homePath: homePath)
        let connection = await pool.connection(for: homePath)
        let generation = try await connection.connect()
        let selection = try await availableModel(connection: connection)
        var params: [String: CodexJSONValue] = [
            "modelProvider": .string("openai"), "model": .string(selection.model),
            "config": .object(["model_reasoning_effort": .string(selection.effort)]),
            "cwd": .string(projectPath), "sandbox": .string(permission.sandbox),
            "approvalPolicy": .string(permission == .discussion ? "never" : "on-request"), "approvalsReviewer": .string("user"),
            "ephemeral": .bool(false), "allowProviderModelFallback": .bool(false),
        ]
        if fork, let predecessor { params["threadId"] = .string(predecessor.threadID) }
        let result = try await connection.request(method: fork ? "thread/fork" : "thread/start", params: .object(params))
        guard await connection.connectionID() == generation,
              let threadID = result["thread"]?["id"]?.stringValue, !threadID.isEmpty,
              result["model"]?.stringValue == selection.model,
              result["modelProvider"]?.stringValue == "openai",
              result["reasoningEffort"]?.stringValue.map({ $0 == selection.effort }) ?? true,
              result["thread"]?["ephemeral"]?.boolValue == false,
              result["approvalsReviewer"]?.stringValue == "user",
              result["approvalPolicy"]?.stringValue == (permission == .discussion ? "never" : "on-request"),
              result["cwd"]?.stringValue.map(Self.normalize) == Self.normalize(projectPath),
              result["sandbox"]?["type"]?.stringValue == (permission == .discussion ? "readOnly" : "workspaceWrite") else {
            throw HarvisGroupError.invalid("Native thread response did not confirm the requested project and sandbox. No turn was submitted.")
        }
        await preparedThreads.remember(homePath: Self.normalize(homePath), threadID: threadID, generation: generation, response: result)
        return HarvisGroupBinding(homePath: Self.normalize(homePath), accountIdentity: identity,
            threadID: threadID, permission: permission, model: selection.model, reasoningEffort: selection.effort, predecessorThreadID: predecessor?.threadID,
            predecessorHomePath: predecessor?.homePath,
            lineage: fork ? "native-fork" : (predecessor == nil ? "native-start" : "context-handoff"))
    }

    func prepare(_ binding: HarvisGroupBinding, projectPath: String, connection: CodexAppServerConnection) async throws -> CodexJSONValue {
        let generation = try await connection.connect()
        if let prepared = await preparedThreads.response(homePath: binding.homePath, threadID: binding.threadID, generation: generation) {
            return prepared
        }
        var params: [String: CodexJSONValue] = [
            "threadId": .string(binding.threadID), "cwd": .string(projectPath),
            "sandbox": .string(binding.permission.sandbox), "modelProvider": .string("openai"),
            "approvalPolicy": .string(binding.permission == .discussion ? "never" : "on-request"),
            "approvalsReviewer": .string("user"), "allowProviderModelFallback": .bool(false),
        ]
        if let model = binding.model { params["model"] = .string(model) }
        if let effort = binding.reasoningEffort { params["config"] = .object(["model_reasoning_effort": .string(effort)]) }
        let resumed = try await connection.request(method: "thread/resume", params: .object(params))
        guard await connection.connectionID() == generation else {
            throw HarvisGroupError.invalid("Native thread preparation belongs to an expired connection.")
        }
        // The coordinator's submission validator checks the entire response before turn/start.
        await preparedThreads.remember(homePath: binding.homePath, threadID: binding.threadID, generation: generation, response: resumed)
        return resumed
    }

    func turns(_ binding: HarvisGroupBinding, cursor: String? = nil) async throws -> CodexJSONValue {
        try Task.checkCancellation()
        guard try await identity(homePath: binding.homePath) == binding.accountIdentity else {
            throw HarvisGroupError.invalid("Selected profile identity changed; explicitly hand off to a new binding.")
        }
        let connection = await pool.connection(for: binding.homePath)
        let generation = await connection.connectionID()
        var params: [String: CodexJSONValue] = ["threadId": .string(binding.threadID), "limit": .number(50),
            "sortDirection": .string("desc"), "itemsView": .string("full")]
        if let cursor { params["cursor"] = .string(cursor) }
        let result = try await connection.request(method: "thread/turns/list", params: .object(params))
        guard generation != nil, await connection.connectionID() == generation else {
            throw HarvisGroupError.invalid("Profile connection changed while reading native history; recovery evidence was ignored.")
        }
        return result
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func text(in turn: CodexJSONValue) -> String {
        (turn["items"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "agentMessage" }
            .compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
    }
}

/// A newly started native thread can exist in memory before its first rollout exists on disk.
/// Its verified preparation response is valid only on the exact app-server generation that created it.
actor CodexGroupPreparedThreads {
    struct Entry: Sendable { let generation: UUID; let response: CodexJSONValue }
    private var entries: [String: Entry] = [:]
    private func key(_ homePath: String, _ threadID: String) -> String { homePath + "\n" + threadID }
    func response(homePath: String, threadID: String, generation: UUID) -> CodexJSONValue? {
        let value = entries[key(homePath, threadID)]
        return value?.generation == generation ? value?.response : nil
    }
    func remember(homePath: String, threadID: String, generation: UUID, response: CodexJSONValue) {
        entries[key(homePath, threadID)] = Entry(generation: generation, response: response)
    }
}
