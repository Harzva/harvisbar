import Combine
import Foundation

enum CodexConversationHandoffWorkflowError: LocalizedError, Equatable {
    case unsupportedCard(CodexTaskCardType)
    case deliveryUnavailable
    case summaryCommandMissing
    case summaryMissing(String)
    case malformedResponse(String)
    case destinationMismatch(String)
    case sourceAdvanced(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedCard(cardType):
            return "\(cardType.rawValue) cards cannot be handed off through Codex."
        case .deliveryUnavailable:
            return "Codex task delivery is not active."
        case .summaryCommandMissing:
            return "The persisted handoff summary command is missing."
        case let .summaryMissing(reason):
            return "The source task did not produce a usable handoff packet: \(reason)"
        case let .malformedResponse(reason):
            return "Codex app-server returned an incomplete handoff response: \(reason)"
        case let .destinationMismatch(reason):
            return "The new Codex task did not preserve the source settings: \(reason)"
        case let .sourceAdvanced(reason):
            return "The source task changed after its handoff packet was created: \(reason)"
        }
    }
}

/// Transactional orchestration for a clean Codex-to-Codex handoff.
///
/// This intentionally does not use `thread/fork`: the destination starts with
/// no inherited conversation history and receives only a bounded packet. Every
/// write-capable RPC is preceded by durable transaction state, and no active
/// transaction is replayed after restart.
@MainActor
final class CodexConversationHandoffCoordinator: ObservableObject {
    @Published private(set) var transactions: [CodexConversationHandoff] = []
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?

    private weak var delivery: CodexTaskDeliveryCoordinator?
    private let pool: CodexAppServerPool
    private let store: any CodexConversationHandoffStoring
    private let pollIntervalNanoseconds: UInt64
    private let phaseTimeout: TimeInterval
    private var workflowTasks: [UUID: Task<Void, Never>] = [:]
    private var verificationCallbacks: [
        UUID: (CodexVerifiedHandoff) -> Void
    ] = [:]
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        delivery: CodexTaskDeliveryCoordinator,
        pool: CodexAppServerPool,
        store: any CodexConversationHandoffStoring = CodexConversationHandoffStore(),
        pollIntervalNanoseconds: UInt64 = 100_000_000,
        phaseTimeout: TimeInterval = 20 * 60
    ) {
        self.delivery = delivery
        self.pool = pool
        self.store = store
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.phaseTimeout = phaseTimeout
    }

    func activate() async {
        guard !isReady else { return }
        do {
            transactions = try await store.load()
            isReady = true
            lastError = nil
            // The transaction store fails every interrupted workflow closed.
            // A linked summary command may still be generically recoverable as
            // `waiting`; cancel it before the delivery monitor starts so an
            // unknown handoff can never replay after restart.
            if let delivery {
                for transaction in transactions
                    where transaction.state == .deliveryUnknown {
                    await delivery.cancelQueuedCommand(
                        transaction.summaryCommandID
                    )
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deactivate() async {
        for task in workflowTasks.values { task.cancel() }
        workflowTasks.removeAll()
        verificationCallbacks.removeAll()
        isReady = false
    }

    func activeHandoff(
        homePath: String,
        sourceThreadID: String
    ) -> CodexConversationHandoff? {
        let normalizedHome = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL.path
        return transactions.first {
            $0.homePath == normalizedHome
                && $0.sourceThreadID == sourceThreadID
                && !$0.state.isTerminal
        }
    }

    func latestHandoff(
        homePath: String,
        sourceThreadID: String
    ) -> CodexConversationHandoff? {
        let normalizedHome = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL.path
        return transactions.last {
            $0.homePath == normalizedHome
                && $0.sourceThreadID == sourceThreadID
        }
    }

    @discardableResult
    func begin(
        homeID: String,
        homePath: String,
        sourceThreadID: String,
        sourceTitle: String,
        cardType: CodexTaskCardType,
        onVerified: @escaping (CodexVerifiedHandoff) -> Void
    ) async -> UUID? {
        if !isReady { await activate() }
        guard isReady, delivery?.isReady == true else {
            lastError = CodexConversationHandoffWorkflowError
                .deliveryUnavailable.localizedDescription
            return nil
        }
        guard CodexConversationHandoffPolicy.supports(cardType) else {
            lastError = CodexConversationHandoffWorkflowError
                .unsupportedCard(cardType).localizedDescription
            return nil
        }
        let normalizedHome = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL.path
        let trimmedThreadID = sourceThreadID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !homeID.isEmpty, !trimmedThreadID.isEmpty else {
            lastError = "A Codex home and source task are required for handoff."
            return nil
        }
        if let existing = activeHandoff(
            homePath: normalizedHome,
            sourceThreadID: trimmedThreadID
        ) {
            return existing.id
        }

        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let transaction = CodexConversationHandoff(
            homeID: homeID,
            homePath: normalizedHome,
            sourceThreadID: trimmedThreadID,
            sourceTitle: title.isEmpty ? "Codex task" : title,
            cardType: cardType
        )
        await acquireMutationSlot()
        if let existing = activeHandoff(
            homePath: normalizedHome,
            sourceThreadID: trimmedThreadID
        ) {
            releaseMutationSlot()
            return existing.id
        }
        var candidate = transactions
        candidate.append(transaction)
        do {
            try await store.save(candidate)
            transactions = candidate
            releaseMutationSlot()
        } catch {
            releaseMutationSlot()
            lastError =
                "Handoff was not started because its transaction could not be persisted: \(error.localizedDescription)"
            return nil
        }

        verificationCallbacks[transaction.id] = onVerified
        guard let delivery,
              await delivery.submitFreshTurn(
                  commandID: transaction.summaryCommandID,
                  homeID: transaction.homeID,
                  homePath: transaction.homePath,
                  sourceThreadID: transaction.sourceThreadID,
                  targetThreadID: transaction.sourceThreadID,
                  cardType: transaction.cardType,
                  text: CodexConversationHandoffPolicy.summaryPrompt
              ) != nil else {
            verificationCallbacks.removeValue(forKey: transaction.id)
            await finish(
                transaction.id,
                state: .failed,
                error: delivery?.lastError
                    ?? "The handoff summary command was not durably queued."
            )
            return transaction.id
        }

        workflowTasks[transaction.id] = Task { [weak self] in
            await self?.run(transactionID: transaction.id)
        }
        return transaction.id
    }

    private func run(transactionID: UUID) async {
        defer { workflowTasks.removeValue(forKey: transactionID) }
        do {
            let packet = try await waitForSummary(transactionID: transactionID)
            try Task.checkCancellation()
            let verified = try await createAndVerifyDestination(
                transactionID: transactionID,
                packet: packet
            )
            guard await commitVerified(
                transactionID: transactionID,
                verified: verified
            ) else {
                return
            }
            if let warning = await setDestinationNameBestEffort(
                verified,
                sourceTitle: transaction(id: transactionID)?.sourceTitle
                    ?? "Codex task"
            ) {
                // Naming is non-critical metadata and happens only after the
                // verified marker is durable. A definite failure or uncertain
                // write is surfaced once and is never replayed automatically.
                _ = await mutate(transactionID) { transaction in
                    transaction.warning = warning
                }
            }
            lastError = nil
            let callback = verificationCallbacks.removeValue(
                forKey: transactionID
            )
            callback?(verified)
        } catch is CancellationError {
            await finish(
                transactionID,
                state: .deliveryUnknown,
                error: "Handoff monitoring stopped before delivery could be reconciled. Nothing was replayed."
            )
        } catch {
            await finish(
                transactionID,
                state: terminalState(for: error),
                error: error.localizedDescription
            )
        }
    }

    private func waitForSummary(transactionID: UUID) async throws -> String {
        guard let transaction = transaction(id: transactionID) else {
            throw CodexConversationHandoffWorkflowError.summaryCommandMissing
        }
        let deadline = Date().addingTimeInterval(phaseTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard let delivery,
                  let item = delivery.queueItems.first(where: {
                      $0.id == transaction.summaryCommandID
                  }) else {
                throw CodexConversationHandoffWorkflowError.summaryCommandMissing
            }
            switch item.state {
            case .queued, .waiting, .dispatching:
                await transitionIfNeeded(transactionID, to: .queuedSummary)
            case .running:
                let live = delivery.liveState(
                    homePath: transaction.homePath,
                    threadID: transaction.sourceThreadID
                )
                if live.pendingApproval?.turnID == item.ownership?.turnID {
                    await transitionIfNeeded(
                        transactionID,
                        to: .summaryWaitingApproval
                    )
                } else {
                    await transitionIfNeeded(transactionID, to: .summarizing)
                }
            case .waitingApproval:
                await transitionIfNeeded(
                    transactionID,
                    to: .summaryWaitingApproval
                )
            case .completed:
                guard case let .manager(turnID, _) = item.ownership else {
                    throw CodexConversationHandoffWorkflowError.summaryMissing(
                        "the exact Manager-owned summary turn was not retained"
                    )
                }
                let live = delivery.liveState(
                    homePath: transaction.homePath,
                    threadID: transaction.sourceThreadID
                )
                guard live.lastCompletedTurnID == turnID,
                      live.lastCompletedTurnStatus == "completed" else {
                    throw CodexConversationHandoffWorkflowError.summaryMissing(
                        "the completion event did not match the queued summary turn"
                    )
                }
                let packet = (live.finalSummary ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !packet.isEmpty else {
                    throw CodexConversationHandoffWorkflowError.summaryMissing(
                        "the completed turn returned no final packet"
                    )
                }
                guard await mutate(transactionID, { value in
                    value.sourceSummaryTurnID = turnID
                    value.state = .creatingDestination
                    value.lastError = nil
                }) else {
                    throw CodexAppServerError.deliveryUncertain(
                        method: "thread/start",
                        reason: "handoff state could not be persisted before destination creation"
                    )
                }
                return String(packet.prefix(12_000))
            case .deliveryUnknown:
                throw CodexAppServerError.deliveryUncertain(
                    method: "turn/start",
                    reason: item.lastError ?? "summary turn delivery is unknown"
                )
            case .failed:
                throw CodexConversationHandoffWorkflowError.summaryMissing(
                    item.lastError ?? "summary turn failed"
                )
            case .cancelled:
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw CodexAppServerError.deliveryUncertain(
            method: "turn/start",
            reason: "timed out waiting for the exact summary turn; it was not replayed"
        )
    }

    private func createAndVerifyDestination(
        transactionID: UUID,
        packet: String
    ) async throws -> CodexVerifiedHandoff {
        guard let transaction = transaction(id: transactionID) else {
            throw CodexConversationHandoffWorkflowError.summaryCommandMissing
        }
        let connection = await pool.connection(for: transaction.homePath)
        let connectionID = try await connection.connect()

        let source = try await connection.request(
            method: "thread/resume",
            params: .object([
                "threadId": .string(transaction.sourceThreadID),
            ])
        )
        guard await connection.connectionID() == connectionID else {
            throw CodexAppServerError.deliveryUncertain(
                method: "thread/resume",
                reason: "connection lifecycle changed after the source settings response"
            )
        }
        let startParams = try destinationThreadStartParams(from: source)
        let expectedCWD = try requiredString("cwd", in: source)
        let expectedModel = try requiredString("model", in: source)
        let sourceUpdatedAt = try requiredInt64(
            "updatedAt",
            in: source["thread"] ?? .null
        )
        guard await mutate(transactionID, { value in
            value.sourceUpdatedAt = sourceUpdatedAt
            value.lastError = nil
        }) else {
            throw CodexAppServerError.deliveryUncertain(
                method: "thread/start",
                reason: "the source handoff snapshot could not be persisted"
            )
        }

        let started = try await connection.request(
            method: "thread/start",
            params: .object(startParams)
        )
        guard await connection.connectionID() == connectionID else {
            throw CodexAppServerError.deliveryUncertain(
                method: "thread/start",
                reason: "connection lifecycle changed after the destination response"
            )
        }
        guard let destinationThreadID = started["thread"]?["id"]?.stringValue,
              !destinationThreadID.isEmpty,
              destinationThreadID != transaction.sourceThreadID else {
            throw CodexAppServerError.deliveryUncertain(
                method: "thread/start",
                reason: "response did not contain a distinct destination thread id"
            )
        }
        guard await mutate(transactionID, { value in
            value.destinationThreadID = destinationThreadID
            value.state = .creatingDestination
        }) else {
            throw CodexAppServerError.deliveryUncertain(
                method: "thread/start",
                reason: "the returned destination id could not be persisted"
            )
        }
        try validateDestination(
            started,
            expectedCWD: expectedCWD,
            expectedModel: expectedModel,
            requestedParams: startParams
        )

        guard await mutate(transactionID, { value in
            value.state = .seedingDestination
            value.lastError = nil
        }) else {
            throw CodexAppServerError.deliveryUncertain(
                method: "turn/start",
                reason: "handoff state could not be persisted before seeding the destination"
            )
        }
        let seedResult = try await connection.request(
            method: "turn/start",
            params: .object([
                "threadId": .string(destinationThreadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(
                            CodexConversationHandoffPolicy.destinationPrompt(
                                packet: packet
                            )
                        ),
                    ]),
                ]),
                "clientUserMessageId": .string(
                    "harvis-handoff-\(transactionID.uuidString)"
                ),
                "approvalsReviewer": .string("user"),
            ])
        )
        guard await connection.connectionID() == connectionID,
              let destinationTurnID = seedResult["turn"]?["id"]?.stringValue,
              !destinationTurnID.isEmpty else {
            throw CodexAppServerError.deliveryUncertain(
                method: "turn/start",
                reason: "response did not retain the destination connection and exact turn id"
            )
        }
        guard await mutate(transactionID, { value in
            value.destinationTurnID = destinationTurnID
            value.state = .seedingDestination
        }) else {
            throw CodexAppServerError.deliveryUncertain(
                method: "turn/start",
                reason: "the exact destination turn id could not be persisted"
            )
        }

        try await waitForDestinationTurn(
            transactionID: transactionID,
            homePath: transaction.homePath,
            threadID: destinationThreadID,
            turnID: destinationTurnID,
            connectionID: connectionID,
            connection: connection
        )
        try await verifySourceUnchanged(
            transactionID: transactionID,
            connection: connection
        )
        return CodexVerifiedHandoff(
            transactionID: transactionID,
            homeID: transaction.homeID,
            homePath: transaction.homePath,
            sourceThreadID: transaction.sourceThreadID,
            destinationThreadID: destinationThreadID,
            destinationTurnID: destinationTurnID
        )
    }

    private func waitForDestinationTurn(
        transactionID: UUID,
        homePath: String,
        threadID: String,
        turnID: String,
        connectionID: UUID,
        connection: CodexAppServerConnection
    ) async throws {
        let deadline = Date().addingTimeInterval(phaseTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard let delivery else {
                throw CodexAppServerError.deliveryUncertain(
                    method: "turn/start",
                    reason: "Manager delivery state was released before destination completion"
                )
            }
            let live = delivery.liveState(homePath: homePath, threadID: threadID)
            if live.pendingApproval?.turnID == turnID {
                await transitionIfNeeded(
                    transactionID,
                    to: .destinationWaitingApproval
                )
            } else if live.activeTurnID == turnID {
                await transitionIfNeeded(
                    transactionID,
                    to: .seedingDestination
                )
            }
            if live.lastCompletedTurnID == turnID {
                guard live.lastCompletedTurnStatus == "completed" else {
                    throw CodexConversationHandoffWorkflowError.summaryMissing(
                        "destination acceptance turn ended with status \(live.lastCompletedTurnStatus ?? "unknown")"
                    )
                }
                return
            }
            guard await connection.connectionID() == connectionID else {
                throw CodexAppServerError.deliveryUncertain(
                    method: "turn/start",
                    reason: "destination connection closed before exact completion; the turn was not replayed"
                )
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw CodexAppServerError.deliveryUncertain(
            method: "turn/start",
            reason: "timed out waiting for destination acceptance; the turn was not replayed"
        )
    }

    private func verifySourceUnchanged(
        transactionID: UUID,
        connection: CodexAppServerConnection
    ) async throws {
        guard let transaction = transaction(id: transactionID),
              let summaryTurnID = transaction.sourceSummaryTurnID,
              let expectedUpdatedAt = transaction.sourceUpdatedAt else {
            throw CodexConversationHandoffWorkflowError.sourceAdvanced(
                "the persisted source snapshot is incomplete"
            )
        }
        guard let delivery else {
            throw CodexConversationHandoffWorkflowError.sourceAdvanced(
                "Manager delivery state is unavailable"
            )
        }
        let live = delivery.liveState(
            homePath: transaction.homePath,
            threadID: transaction.sourceThreadID
        )
        guard live.activeTurnID == nil,
              live.pendingApproval == nil,
              live.lastCompletedTurnID == summaryTurnID,
              live.lastCompletedTurnStatus == "completed" else {
            throw CodexConversationHandoffWorkflowError.sourceAdvanced(
                "a newer or still-running source turn was observed"
            )
        }

        let verificationConnectionID = try await connection.connect()
        let response = try await connection.request(
            method: "thread/read",
            params: .object([
                "threadId": .string(transaction.sourceThreadID),
                "includeTurns": .bool(false),
            ])
        )
        guard await connection.connectionID() == verificationConnectionID else {
            throw CodexAppServerError.deliveryUncertain(
                method: "thread/read",
                reason: "connection lifecycle changed during final source verification"
            )
        }
        guard response["thread"]?["id"]?.stringValue
                == transaction.sourceThreadID,
              let actualUpdatedAt = response["thread"]?["updatedAt"]?.intValue,
              Int64(actualUpdatedAt) == expectedUpdatedAt else {
            throw CodexConversationHandoffWorkflowError.sourceAdvanced(
                "the source update marker no longer matches the handoff packet"
            )
        }
        let status = response["thread"]?["status"]?["type"]?.stringValue
        guard status == "idle" || status == "notLoaded" else {
            throw CodexConversationHandoffWorkflowError.sourceAdvanced(
                "the source is no longer idle"
            )
        }

        let turnsResponse = try await connection.request(
            method: "thread/turns/list",
            params: .object([
                "threadId": .string(transaction.sourceThreadID),
                "sortDirection": .string("desc"),
                "limit": .number(1),
                "itemsView": .string("notLoaded"),
            ])
        )
        guard await connection.connectionID() == verificationConnectionID else {
            throw CodexAppServerError.deliveryUncertain(
                method: "thread/turns/list",
                reason: "connection lifecycle changed during exact source-turn verification"
            )
        }
        guard let latestTurn = turnsResponse["data"]?.arrayValue?.first,
              latestTurn["id"]?.stringValue == summaryTurnID,
              latestTurn["status"]?.stringValue == "completed" else {
            throw CodexConversationHandoffWorkflowError.sourceAdvanced(
                "the persisted latest source turn is no longer the exact completed handoff summary turn"
            )
        }
    }

    private func destinationThreadStartParams(
        from source: CodexJSONValue
    ) throws -> [String: CodexJSONValue] {
        let cwd = try requiredString("cwd", in: source)
        let model = try requiredString("model", in: source)
        var params: [String: CodexJSONValue] = [
            "cwd": .string(cwd),
            "model": .string(model),
            "ephemeral": .bool(false),
            "approvalsReviewer": .string("user"),
            "allowProviderModelFallback": .bool(false),
        ]
        copy("modelProvider", from: source, into: &params)
        copy("approvalPolicy", from: source, into: &params)
        copy("serviceTier", from: source, into: &params)
        copy("runtimeWorkspaceRoots", from: source, into: &params)
        if let projectID = source["thread"]?["projectId"]?.stringValue,
           !projectID.isEmpty {
            params["projectId"] = .string(projectID)
        }

        if let permissionsID = source["activePermissionProfile"]?["id"]?
            .stringValue,
           !permissionsID.isEmpty {
            params["permissions"] = .string(permissionsID)
        } else {
            guard let sandboxMode = sandboxMode(from: source["sandbox"]) else {
                throw CodexConversationHandoffWorkflowError.destinationMismatch(
                    "the active permission profile was unavailable and the source sandbox cannot be represented safely"
                )
            }
            params["sandbox"] = .string(sandboxMode)
        }
        return params
    }

    private func setDestinationNameBestEffort(
        _ verified: CodexVerifiedHandoff,
        sourceTitle: String
    ) async -> String? {
        let trimmed = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Codex task" : trimmed
        let name = String("\(base) · 接手".prefix(80))
        let connection = await pool.connection(for: verified.homePath)
        do {
            _ = try await connection.request(
                method: "thread/name/set",
                params: .object([
                    "threadId": .string(verified.destinationThreadID),
                    "name": .string(name),
                ])
            )
            return nil
        } catch let error as CodexAppServerError {
            if case .deliveryUncertain = error {
                return "新任务已验证，但命名交付状态未知；为避免重复写入，未自动重试。"
            }
            return "新任务已验证，但自动命名失败：\(error.localizedDescription)"
        } catch {
            return "新任务已验证，但自动命名失败：\(error.localizedDescription)"
        }
    }

    private func validateDestination(
        _ response: CodexJSONValue,
        expectedCWD: String,
        expectedModel: String,
        requestedParams: [String: CodexJSONValue]
    ) throws {
        guard let cwd = response["cwd"]?.stringValue,
              URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
                == URL(fileURLWithPath: expectedCWD, isDirectory: true)
                    .standardizedFileURL.path else {
            throw CodexConversationHandoffWorkflowError.destinationMismatch(
                "working directory differs"
            )
        }
        guard response["model"]?.stringValue == expectedModel else {
            throw CodexConversationHandoffWorkflowError.destinationMismatch(
                "model differs"
            )
        }
        guard response["thread"]?["ephemeral"]?.boolValue == false else {
            throw CodexConversationHandoffWorkflowError.destinationMismatch(
                "destination is not durable"
            )
        }
        guard response["approvalsReviewer"]?.stringValue == "user" else {
            throw CodexConversationHandoffWorkflowError.destinationMismatch(
                "approvals are not routed to the user"
            )
        }
        if let expectedProvider = requestedParams["modelProvider"]?.stringValue,
           response["modelProvider"]?.stringValue != expectedProvider {
            throw CodexConversationHandoffWorkflowError.destinationMismatch(
                "model provider differs"
            )
        }
        if let expectedProfile = requestedParams["permissions"]?.stringValue,
           response["activePermissionProfile"]?["id"]?.stringValue
                != expectedProfile {
            throw CodexConversationHandoffWorkflowError.destinationMismatch(
                "active permission profile differs"
            )
        }
        if let expectedSandbox = requestedParams["sandbox"]?.stringValue,
           sandboxMode(from: response["sandbox"]) != expectedSandbox {
            throw CodexConversationHandoffWorkflowError.destinationMismatch(
                "sandbox differs"
            )
        }
        if let expectedPolicy = requestedParams["approvalPolicy"],
           response["approvalPolicy"] != expectedPolicy {
            throw CodexConversationHandoffWorkflowError.destinationMismatch(
                "approval policy differs"
            )
        }
    }

    private func requiredString(
        _ key: String,
        in value: CodexJSONValue
    ) throws -> String {
        guard let result = value[key]?.stringValue,
              !result.isEmpty else {
            throw CodexConversationHandoffWorkflowError.malformedResponse(
                "missing \(key)"
            )
        }
        return result
    }

    private func requiredInt64(
        _ key: String,
        in value: CodexJSONValue
    ) throws -> Int64 {
        guard let result = value[key]?.intValue else {
            throw CodexConversationHandoffWorkflowError.malformedResponse(
                "missing \(key)"
            )
        }
        return Int64(result)
    }

    private func copy(
        _ key: String,
        from source: CodexJSONValue,
        into destination: inout [String: CodexJSONValue]
    ) {
        guard let value = source[key], value != .null else { return }
        destination[key] = value
    }

    private func sandboxMode(from policy: CodexJSONValue?) -> String? {
        switch policy?["type"]?.stringValue {
        case "readOnly": return "read-only"
        case "workspaceWrite": return "workspace-write"
        case "dangerFullAccess": return "danger-full-access"
        default: return nil
        }
    }

    private func transaction(id: UUID) -> CodexConversationHandoff? {
        transactions.first { $0.id == id }
    }

    private func transitionIfNeeded(
        _ id: UUID,
        to state: CodexConversationHandoffState
    ) async {
        guard transaction(id: id)?.state != state else { return }
        _ = await mutate(id) { transaction in
            transaction.state = state
            transaction.lastError = nil
        }
    }

    /// The destination ids are already durable in the non-terminal
    /// `seedingDestination` snapshot. Recheck the exact source boundary before
    /// writing the terminal marker, so a crash before this check can only
    /// recover as `deliveryUnknown`, never as a verified/done handoff.
    private func commitVerified(
        transactionID: UUID,
        verified: CodexVerifiedHandoff
    ) async -> Bool {
        await acquireMutationSlot()
        defer { releaseMutationSlot() }
        guard let index = transactions.firstIndex(where: {
            $0.id == transactionID
        }) else {
            return false
        }

        do {
            let connection = await pool.connection(
                for: transactions[index].homePath
            )
            try await verifySourceUnchanged(
                transactionID: transactionID,
                connection: connection
            )
        } catch {
            let message = error.localizedDescription
            var rejected = transactions
            guard let rejectedIndex = rejected.firstIndex(where: {
                $0.id == transactionID
            }) else {
                forceUnknownInMemory(transactionID, message)
                return false
            }
            rejected[rejectedIndex].state = terminalState(for: error)
            rejected[rejectedIndex].destinationThreadID =
                verified.destinationThreadID
            rejected[rejectedIndex].destinationTurnID =
                verified.destinationTurnID
            rejected[rejectedIndex].updatedAt = Date()
            rejected[rejectedIndex].lastError = message
            do {
                try await store.save(rejected)
                transactions = rejected
                lastError = message
                verificationCallbacks.removeValue(forKey: transactionID)
            } catch {
                forceUnknownInMemory(
                    transactionID,
                    "The source could not be re-verified at the final handoff boundary, and the rejection marker could not be persisted. Treat delivery as unknown."
                )
            }
            return false
        }

        var candidate = transactions
        candidate[index].state = .verified
        candidate[index].destinationThreadID = verified.destinationThreadID
        candidate[index].destinationTurnID = verified.destinationTurnID
        candidate[index].updatedAt = Date()
        candidate[index].lastError = nil
        do {
            try await store.save(candidate)
            transactions = candidate
            return true
        } catch {
            forceUnknownInMemory(
                transactionID,
                "The destination completed, but the verified transaction could not be persisted: \(error.localizedDescription)"
            )
            return false
        }
    }

    @discardableResult
    private func mutate(
        _ id: UUID,
        _ body: (inout CodexConversationHandoff) -> Void
    ) async -> Bool {
        await acquireMutationSlot()
        defer { releaseMutationSlot() }
        guard let index = transactions.firstIndex(where: { $0.id == id }) else {
            return false
        }
        var candidate = transactions
        body(&candidate[index])
        candidate[index].updatedAt = Date()
        do {
            try await store.save(candidate)
            transactions = candidate
            return true
        } catch {
            lastError = "Handoff persistence failed: \(error.localizedDescription)"
            return false
        }
    }

    private func acquireMutationSlot() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationSlot() {
        guard !mutationWaiters.isEmpty else {
            mutationInProgress = false
            return
        }
        let next = mutationWaiters.removeFirst()
        next.resume()
    }

    private func finish(
        _ id: UUID,
        state: CodexConversationHandoffState,
        error: String
    ) async {
        verificationCallbacks.removeValue(forKey: id)
        let saved = await mutate(id) { transaction in
            transaction.state = state
            transaction.lastError = error
        }
        if saved { lastError = error }
    }

    private func forceUnknownInMemory(_ id: UUID, _ error: String) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else {
            return
        }
        transactions[index].state = .deliveryUnknown
        transactions[index].updatedAt = Date()
        transactions[index].lastError = error
        lastError = error
        verificationCallbacks.removeValue(forKey: id)
    }

    private func terminalState(
        for error: Error
    ) -> CodexConversationHandoffState {
        if error is CancellationError { return .cancelled }
        if case CodexAppServerError.deliveryUncertain = error {
            return .deliveryUnknown
        }
        return .failed
    }
}
