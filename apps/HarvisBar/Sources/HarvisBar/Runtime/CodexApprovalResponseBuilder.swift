import Foundation

enum CodexApprovalDecision: Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

enum CodexApprovalResponseError: LocalizedError, Equatable {
    case unsupportedMethod(String)
    case unavailableDecision(String)
    case missingAnswer(String)
    case invalidMCPContent

    var errorDescription: String? {
        switch self {
        case let .unsupportedMethod(method):
            return "Unsupported Codex approval request: \(method)"
        case let .unavailableDecision(decision):
            return "Codex did not offer the approval decision: \(decision)"
        case let .missingAnswer(questionID):
            return "A response is required for question \(questionID)."
        case .invalidMCPContent:
            return "MCP elicitation content must be a JSON object."
        }
    }
}

enum CodexApprovalResponseBuilder {
    static func presentation(
        request: CodexServerRequest,
        connectionID: UUID
    ) -> CodexPendingApproval {
        let params = request.params
        let threadID = params["threadId"]?.stringValue
            ?? params["conversationId"]?.stringValue
            ?? ""
        let turnID = params["turnId"]?.stringValue
        let reason = params["reason"]?.stringValue
        let command = params["command"]?.stringValue
            ?? params["command"]?.arrayValue?
                .compactMap(\.stringValue)
                .joined(separator: " ")
        let message = params["message"]?.stringValue

        let title: String
        switch request.method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            title = "Command approval"
        case "item/fileChange/requestApproval", "applyPatchApproval":
            title = "File change approval"
        case "item/permissions/requestApproval":
            title = "Permission request"
        case "item/tool/requestUserInput":
            title = "Agent needs input"
        case "mcpServer/elicitation/request":
            title = "MCP request"
        default:
            title = "Unsupported agent request"
        }

        let detail = [
            command,
            reason,
            message,
            params["cwd"]?.stringValue,
        ]
        .compactMap { value -> String? in
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
        .joined(separator: "\n")

        return CodexPendingApproval(
            id: request.id,
            connectionID: connectionID,
            method: request.method,
            threadID: threadID,
            turnID: turnID,
            title: title,
            detail: detail.isEmpty ? request.method : String(detail.prefix(2_000)),
            params: params,
            questions: questions(from: params),
            availableDecisions: availableDecisions(from: params),
            fileChanges: fileChanges(from: params)
        )
    }

    static func result(
        for approval: CodexPendingApproval,
        decision: CodexApprovalDecision,
        answers: [String: [String]] = [:],
        mcpContent: CodexJSONValue? = nil
    ) throws -> CodexJSONValue {
        switch approval.method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            try validateAvailableDecision(decision, for: approval)
            return .object([
                "decision": .string(decisionString(decision)),
            ])

        case "item/permissions/requestApproval":
            let permissions: CodexJSONValue
            switch decision {
            case .accept, .acceptForSession:
                permissions = approval.params["permissions"] ?? .object([:])
            case .decline, .cancel:
                permissions = .object([:])
            }
            return .object([
                "permissions": permissions,
                "scope": .string(
                    decision == .acceptForSession ? "session" : "turn"
                ),
            ])

        case "item/tool/requestUserInput":
            if decision == .decline || decision == .cancel {
                // Codex 0.149 defines no action/decision field for this
                // response. An empty answers map is the schema-valid way for
                // a client to decline or cancel without fabricating answers.
                return .object(["answers": .object([:])])
            }
            var responseAnswers: [String: CodexJSONValue] = [:]
            for question in approval.questions {
                guard let values = answers[question.id],
                      !values.isEmpty else {
                    throw CodexApprovalResponseError.missingAnswer(question.id)
                }
                responseAnswers[question.id] = .object([
                    "answers": .array(values.map(CodexJSONValue.string)),
                ])
            }
            return .object(["answers": .object(responseAnswers)])

        case "mcpServer/elicitation/request":
            switch decision {
            case .decline:
                return .object(["action": .string("decline")])
            case .cancel:
                return .object(["action": .string("cancel")])
            case .accept, .acceptForSession:
                var result: [String: CodexJSONValue] = [
                    "action": .string("accept"),
                ]
                if let mcpContent {
                    guard mcpContent.objectValue != nil else {
                        throw CodexApprovalResponseError.invalidMCPContent
                    }
                    result["content"] = mcpContent
                }
                return .object(result)
            }

        case "execCommandApproval", "applyPatchApproval":
            return .object([
                "decision": .string(
                    decision == .accept || decision == .acceptForSession
                        ? "approved"
                        : "denied"
                ),
            ])

        default:
            throw CodexApprovalResponseError.unsupportedMethod(approval.method)
        }
    }

    private static func decisionString(
        _ decision: CodexApprovalDecision
    ) -> String {
        switch decision {
        case .accept: return "accept"
        case .acceptForSession: return "acceptForSession"
        case .decline: return "decline"
        case .cancel: return "cancel"
        }
    }

    private static func validateAvailableDecision(
        _ decision: CodexApprovalDecision,
        for approval: CodexPendingApproval
    ) throws {
        guard let availableDecisions = approval.availableDecisions else {
            return
        }
        let option = decision.option
        guard availableDecisions.contains(option) else {
            throw CodexApprovalResponseError.unavailableDecision(
                option.rawValue
            )
        }
    }

    private static func availableDecisions(
        from params: CodexJSONValue
    ) -> [CodexApprovalDecisionOption]? {
        guard let value = params["availableDecisions"] else { return nil }
        guard let values = value.arrayValue else { return nil }
        return values.compactMap { value in
            guard let rawValue = value.stringValue else { return nil }
            return CodexApprovalDecisionOption(rawValue: rawValue)
        }
    }

    static func fileChanges(
        from params: CodexJSONValue,
        maximumCount: Int = 12,
        maximumDiffLength: Int = 4_000
    ) -> [CodexFileApprovalChange] {
        if let legacyChanges = params["fileChanges"]?.objectValue {
            return legacyChanges.keys.sorted().prefix(maximumCount).compactMap {
                path -> CodexFileApprovalChange? in
                guard let value = legacyChanges[path],
                      let object = value.objectValue else {
                    return nil
                }
                let kind = object["type"]?.stringValue ?? "update"
                let diff = object["unified_diff"]?.stringValue
                    ?? object["content"]?.stringValue
                    ?? value.encodedString()
                    ?? ""
                let destination = object["move_path"]?.stringValue
                let displayPath = destination.map { "\(path) → \($0)" }
                    ?? path
                return CodexFileApprovalChange(
                    path: String(displayPath.prefix(1_000)),
                    kind: String(kind.prefix(80)),
                    diff: String(diff.prefix(maximumDiffLength))
                )
            }
        }
        let rawChanges = params["changes"]?.arrayValue
            ?? params["fileChanges"]?.arrayValue
            ?? params["item"]?["changes"]?.arrayValue
            ?? []
        var changes = rawChanges.prefix(maximumCount).compactMap {
            value -> CodexFileApprovalChange? in
            guard let object = value.objectValue else { return nil }
            let path = object["path"]?.stringValue ?? "Unknown path"
            let kind = object["kind"]?.stringValue ?? "update"
            let diff = object["diff"]?.stringValue
                ?? object["patch"]?.stringValue
                ?? value.encodedString()
                ?? ""
            return CodexFileApprovalChange(
                path: String(path.prefix(1_000)),
                kind: String(kind.prefix(80)),
                diff: String(diff.prefix(maximumDiffLength))
            )
        }
        if changes.isEmpty,
           let diff = params["diff"]?.stringValue
                ?? params["patch"]?.stringValue {
            changes = [CodexFileApprovalChange(
                path: String(
                    (params["path"]?.stringValue ?? "Unknown path")
                        .prefix(1_000)
                ),
                kind: "update",
                diff: String(diff.prefix(maximumDiffLength))
            )]
        }
        return changes
    }

    private static func questions(
        from params: CodexJSONValue
    ) -> [CodexUserInputQuestion] {
        (params["questions"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let question = object["question"]?.stringValue else {
                return nil
            }
            let options = (object["options"]?.arrayValue ?? []).compactMap {
                option -> CodexUserInputOption? in
                guard let optionObject = option.objectValue,
                      let label = optionObject["label"]?.stringValue else {
                    return nil
                }
                return CodexUserInputOption(
                    label: label,
                    description: optionObject["description"]?.stringValue
                )
            }
            return CodexUserInputQuestion(
                id: id,
                header: object["header"]?.stringValue,
                question: question,
                options: options,
                isOther: object["isOther"]?.boolValue ?? false,
                isSecret: object["isSecret"]?.boolValue ?? false
            )
        }
    }
}

private extension CodexApprovalDecision {
    var option: CodexApprovalDecisionOption {
        switch self {
        case .accept: return .accept
        case .acceptForSession: return .acceptForSession
        case .decline: return .decline
        case .cancel: return .cancel
        }
    }
}
