import XCTest
@testable import HarvisBar

final class CodexApprovalResponseTests: XCTestCase {
    func testCommandAndFileApprovalsUseExactModernDecisions() throws {
        let command = approval(method: "item/commandExecution/requestApproval")
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: command,
                decision: .accept
            ),
            .object(["decision": .string("accept")])
        )
        let file = approval(method: "item/fileChange/requestApproval")
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: file,
                decision: .decline
            ),
            .object(["decision": .string("decline")])
        )
    }

    func testPermissionApprovalReturnsRequestedProfileAndDeclineReturnsEmpty() throws {
        let permissions: CodexJSONValue = .object([
            "network": .object(["enabled": .bool(true)]),
        ])
        let approval = self.approval(
            method: "item/permissions/requestApproval",
            params: .object([
                "threadId": .string("thread-a"),
                "permissions": permissions,
            ])
        )
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: approval,
                decision: .accept
            ),
            .object([
                "permissions": permissions,
                "scope": .string("turn"),
            ])
        )
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: approval,
                decision: .decline
            ),
            .object([
                "permissions": .object([:]),
                "scope": .string("turn"),
            ])
        )
    }

    func testRequestUserInputRequiresAndEncodesEveryQuestion() throws {
        let request = CodexServerRequest(
            id: .integer(9),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string("turn-a"),
                "questions": .array([
                    .object([
                        "id": .string("scope"),
                        "header": .string("Scope"),
                        "question": .string("Which scope?"),
                        "isOther": .bool(true),
                        "isSecret": .bool(true),
                        "options": .array([
                            .object([
                                "label": .string("Safe"),
                                "description": .string("Use safe scope"),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )
        let presentation = CodexApprovalResponseBuilder.presentation(
            request: request,
            connectionID: UUID()
        )
        XCTAssertEqual(presentation.questions.first?.id, "scope")
        XCTAssertEqual(presentation.questions.first?.isOther, true)
        XCTAssertEqual(presentation.questions.first?.isSecret, true)
        XCTAssertThrowsError(
            try CodexApprovalResponseBuilder.result(
                for: presentation,
                decision: .accept
            )
        )
        let emptyResponse: CodexJSONValue = .object([
            "answers": .object([:]),
        ])
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: presentation,
                decision: .decline
            ),
            emptyResponse
        )
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: presentation,
                decision: .cancel
            ),
            emptyResponse
        )
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: presentation,
                decision: .accept,
                answers: ["scope": ["Safe"]]
            ),
            .object([
                "answers": .object([
                    "scope": .object([
                        "answers": .array([.string("Safe")]),
                    ]),
                ]),
            ])
        )
    }

    func testCommandApprovalHonorsAvailableDecisions() throws {
        let request = CodexServerRequest(
            id: .integer(10),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-a"),
                "turnId": .string("turn-a"),
                "availableDecisions": .array([
                    .string("accept"),
                    .string("decline"),
                ]),
            ])
        )
        let presentation = CodexApprovalResponseBuilder.presentation(
            request: request,
            connectionID: UUID()
        )
        XCTAssertEqual(
            presentation.availableDecisions,
            [.accept, .decline]
        )
        XCTAssertThrowsError(
            try CodexApprovalResponseBuilder.result(
                for: presentation,
                decision: .acceptForSession
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexApprovalResponseError,
                .unavailableDecision("acceptForSession")
            )
        }
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: presentation,
                decision: .accept
            ),
            .object(["decision": .string("accept")])
        )
    }

    func testFileChangesAreConcreteAndBounded() {
        let oversizedDiff = String(repeating: "+line\n", count: 1_000)
        let changes = CodexApprovalResponseBuilder.fileChanges(
            from: .object([
                "changes": .array([
                    .object([
                        "path": .string("Sources/App.swift"),
                        "kind": .string("update"),
                        "diff": .string(oversizedDiff),
                    ]),
                ]),
            ])
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].path, "Sources/App.swift")
        XCTAssertEqual(changes[0].kind, "update")
        XCTAssertEqual(changes[0].diff.count, 4_000)
    }

    func testLegacyFileApprovalUsesConversationAndConcreteChanges() {
        let request = CodexServerRequest(
            id: .string("legacy-file"),
            method: "applyPatchApproval",
            params: .object([
                "conversationId": .string("thread-legacy"),
                "fileChanges": .object([
                    "Sources/Legacy.swift": .object([
                        "type": .string("update"),
                        "unified_diff": .string("@@ -1 +1 @@"),
                    ]),
                ]),
            ])
        )
        let presentation = CodexApprovalResponseBuilder.presentation(
            request: request,
            connectionID: UUID()
        )
        XCTAssertEqual(presentation.threadID, "thread-legacy")
        XCTAssertEqual(
            presentation.fileChanges.first?.path,
            "Sources/Legacy.swift"
        )
        XCTAssertEqual(
            presentation.fileChanges.first?.diff,
            "@@ -1 +1 @@"
        )
    }

    func testMCPApprovalCarriesOnlyUserProvidedStructuredContent() throws {
        let approval = self.approval(
            method: "mcpServer/elicitation/request"
        )
        let content: CodexJSONValue = .object(["choice": .string("yes")])
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: approval,
                decision: .accept,
                mcpContent: content
            ),
            .object([
                "action": .string("accept"),
                "content": content,
            ])
        )
        XCTAssertEqual(
            try CodexApprovalResponseBuilder.result(
                for: approval,
                decision: .decline
            ),
            .object(["action": .string("decline")])
        )
    }

    private func approval(
        method: String,
        params: CodexJSONValue = .object([
            "threadId": .string("thread-a"),
        ])
    ) -> CodexPendingApproval {
        CodexPendingApproval(
            id: .string("approval"),
            connectionID: UUID(),
            method: method,
            threadID: "thread-a",
            turnID: "turn-a",
            title: "Approval",
            detail: "",
            params: params,
            questions: []
        )
    }
}
