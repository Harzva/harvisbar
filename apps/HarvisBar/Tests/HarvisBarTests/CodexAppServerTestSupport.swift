import Foundation
@testable import HarvisBar

enum CodexAppServerTestSupport {
    static func makeFakeExecutable(
        in directory: URL,
        initializeDelaySeconds: Double = 0
    ) throws -> URL {
        let scriptURL = directory.appendingPathComponent("fake-codex.py")
        let script = #"""
#!/usr/bin/python3
import json
import os
import select
import sys
import time

INITIALIZE_DELAY_SECONDS = \#(initializeDelaySeconds)
SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(SCRIPT_DIRECTORY, "launch-log.txt"), "a", encoding="utf-8") as log:
    log.write(str(os.getpid()) + "\n")

def send(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()

buffer = b""
approval_responses = []
turn_counter = 0
thread_counter = 0
active_turns = {}
thread_versions = {"thread-a": 1}
thread_turns = {"thread-a": []}
external_turn_counter = 0

def upsert_turn(thread_id, turn):
    turns = thread_turns.setdefault(thread_id, [])
    for index, existing in enumerate(turns):
        if existing.get("id") == turn.get("id"):
            turns[index] = turn
            return
    turns.append(turn)

while True:
    readable, _, _ = select.select([0], [], [], 0.1)
    if not readable:
        continue
    chunk = os.read(0, 4096)
    if not chunk:
        break
    buffer += chunk
    while b"\n" in buffer:
        raw, buffer = buffer.split(b"\n", 1)
        if not raw:
            continue
        message = json.loads(raw)
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params") or {}
        with open(os.path.join(SCRIPT_DIRECTORY, "request-log.txt"), "a", encoding="utf-8") as log:
            log.write(str(method) + "\n")
        with open(os.path.join(SCRIPT_DIRECTORY, "rpc-log.jsonl"), "a", encoding="utf-8") as log:
            log.write(json.dumps(message, separators=(",", ":")) + "\n")

        if method is None and request_id is not None and ("result" in message or "error" in message):
            approval_responses.append(message)
        elif method == "initialize":
            time.sleep(INITIALIZE_DELAY_SECONDS)
            send({"method":"thread/status/changed","params":{"threadId":"thread-a","status":{"type":"idle"}}})
            send({"id":request_id,"result":{"capabilities":{}}})
        elif method == "initialized":
            continue
        elif method == "thread/resume":
            send({"id":request_id,"result":{
                "thread":{"id":params["threadId"],"ephemeral":False,"projectId":"project-a","updatedAt":thread_versions.get(params["threadId"], 1),"status":{"type":"active" if params["threadId"] in active_turns else "idle"}},
                "cwd":SCRIPT_DIRECTORY,
                "model":"gpt-test",
                "modelProvider":"openai",
                "approvalPolicy":"on-request",
                "approvalsReviewer":"user",
                "sandbox":{"type":"dangerFullAccess"},
                "activePermissionProfile":{"id":":danger-full-access"},
                "runtimeWorkspaceRoots":[SCRIPT_DIRECTORY],
                "serviceTier":"priority"
            }})
        elif method == "thread/start":
            thread_counter += 1
            thread_id = "thread-handoff-" + str(thread_counter)
            thread_versions[thread_id] = 1
            thread_turns[thread_id] = []
            send({"id":request_id,"result":{
                "thread":{"id":thread_id,"ephemeral":bool(params.get("ephemeral", False)),"projectId":params.get("projectId"),"updatedAt":thread_versions[thread_id],"status":{"type":"idle"}},
                "cwd":params.get("cwd") or SCRIPT_DIRECTORY,
                "model":params.get("model") or "gpt-test",
                "modelProvider":params.get("modelProvider") or "openai",
                "approvalPolicy":params.get("approvalPolicy") or "on-request",
                "approvalsReviewer":params.get("approvalsReviewer") or "user",
                "sandbox":{"type":"dangerFullAccess"},
                "activePermissionProfile":{"id":params.get("permissions") or ":danger-full-access"},
                "runtimeWorkspaceRoots":params.get("runtimeWorkspaceRoots") or [SCRIPT_DIRECTORY]
            }})
        elif method == "thread/read":
            thread_id = params["threadId"]
            send({"id":request_id,"result":{"thread":{
                "id":thread_id,
                "ephemeral":False,
                "projectId":"project-a",
                "updatedAt":thread_versions.get(thread_id, 1),
                "status":{"type":"active" if thread_id in active_turns else "idle"},
                "turns":[]
            }}})
        elif method == "thread/turns/list":
            thread_id = params["threadId"]
            turns = list(thread_turns.get(thread_id, []))
            if params.get("sortDirection", "desc") == "desc":
                turns.reverse()
            limit = params.get("limit")
            if limit is not None:
                turns = turns[:limit]
            if params.get("itemsView") == "notLoaded":
                turns = [dict(turn, items=[]) for turn in turns]
            send({"id":request_id,"result":{"data":turns,"nextCursor":None,"backwardsCursor":None}})
        elif method == "thread/name/set":
            send({"id":request_id,"result":{}})
        elif method == "turn/start":
            turn_counter += 1
            turn_id = "turn-manager" if turn_counter == 1 else "turn-manager-" + str(turn_counter)
            turn = {"id":turn_id,"status":"inProgress","items":[]}
            active_turns[params["threadId"]] = turn_id
            upsert_turn(params["threadId"], turn)
            send({"method":"turn/started","params":{"threadId":params["threadId"],"turn":turn}})
            prompt = (((params.get("input") or [{}])[0]).get("text") or "")
            if prompt == "__complete_before_response__":
                completed = {"id":turn_id,"status":"completed","items":[{"id":"message-early","type":"agentMessage","text":"early finished"}]}
                upsert_turn(params["threadId"], completed)
                send({"method":"turn/completed","params":{"threadId":params["threadId"],"turn":completed}})
                active_turns.pop(params["threadId"], None)
            send({"id":request_id,"result":{"turn":turn}})
        elif method == "turn/steer":
            send({"id":request_id,"result":{"turnId":params["expectedTurnId"]}})
        elif method == "test/emitApproval":
            send({"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-a","turnId":"turn-manager","itemId":"item-1","startedAtMs":1,"command":"echo test","reason":"test approval"}})
            send({"id":request_id,"result":{}})
        elif method == "test/emitApprovalFor":
            approval_thread = params.get("threadId") or "thread-a"
            approval_turn = params.get("turnId") or active_turns.get(approval_thread) or "turn-manager"
            send({"id":"approval-target","method":"item/commandExecution/requestApproval","params":{"threadId":approval_thread,"turnId":approval_turn,"itemId":"item-target","startedAtMs":1,"command":"echo target","reason":"target approval"}})
            send({"id":request_id,"result":{}})
        elif method == "test/emitApprovalPair":
            file_item = {"id":"item-file","type":"fileChange","status":"inProgress","changes":[{"path":"Sources/App.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}]}
            send({"method":"item/started","params":{"threadId":"thread-a","turnId":"turn-manager","item":file_item}})
            send({"id":"approval-first","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-a","turnId":"turn-manager","itemId":"item-command","startedAtMs":2,"command":"echo first","availableDecisions":["accept","decline"]}})
            send({"id":"approval-second","method":"item/fileChange/requestApproval","params":{"threadId":"thread-a","turnId":"turn-manager","itemId":"item-file","startedAtMs":3,"reason":"apply concrete changes"}})
            send({"id":request_id,"result":{}})
        elif method == "test/emitUserInputApproval":
            send({"id":"approval-input","method":"item/tool/requestUserInput","params":{"threadId":"thread-a","turnId":"turn-manager","itemId":"item-input","isBlocking":True,"questions":[{"id":"scope","header":"Scope","question":"Which scope?","options":[{"label":"Safe","description":"Safe scope"}]}]}})
            send({"id":request_id,"result":{}})
        elif method == "test/getApprovalResponses":
            send({"id":request_id,"result":{"responses":approval_responses}})
        elif method == "test/emitCompletion":
            thread_id = params.get("threadId") or "thread-a"
            turn_id = params.get("turnId") or active_turns.get(thread_id) or "turn-manager"
            status = params.get("status") or "completed"
            message = params.get("message") or "finished"
            turn = {"id":turn_id,"items":[{"id":"message-1","type":"agentMessage","text":message}]}
            if not params.get("omitStatus"):
                turn["status"] = status
            upsert_turn(thread_id, turn)
            send({"method":"turn/completed","params":{"threadId":thread_id,"turn":turn}})
            if active_turns.get(thread_id) == turn_id:
                active_turns.pop(thread_id, None)
            thread_versions[thread_id] = thread_versions.get(thread_id, 1) + 1
            send({"id":request_id,"result":{}})
        elif method == "test/advanceThreadSilently":
            thread_id = params.get("threadId") or "thread-a"
            external_turn_counter += 1
            upsert_turn(thread_id, {
                "id":params.get("turnId") or "turn-external-" + str(external_turn_counter),
                "status":"completed",
                "items":[]
            })
            if not params.get("preserveUpdatedAt"):
                thread_versions[thread_id] = thread_versions.get(thread_id, 1) + 1
            send({"id":request_id,"result":{}})
        elif method == "test/emitDeltaBurst":
            for _ in range(100):
                send({"method":"item/agentMessage/delta","params":{"threadId":"thread-a","turnId":"turn-manager","itemId":"message-live","delta":"x"}})
            send({"id":request_id,"result":{}})
        elif method == "test/disconnect":
            sys.exit(0)
        else:
            send({"id":request_id,"error":{"code":-32601,"message":"unknown method"}})
"""#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }
}

actor ScriptedCodexActivityProbe: CodexThreadActivityProbing {
    private var values: [Bool]
    private(set) var callCount = 0

    init(_ values: [Bool]) {
        self.values = values
    }

    func replaceValues(_ values: [Bool]) {
        self.values = values
    }

    func isThreadRunning(
        homePath _: String,
        threadID _: String
    ) async throws -> Bool {
        callCount += 1
        guard !values.isEmpty else { return false }
        if values.count == 1 {
            return values[0]
        }
        return values.removeFirst()
    }
}

actor BlockingCodexActivityProbe: CodexThreadActivityProbing {
    private let blockedCall: Int
    private var callCount = 0
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(blockedCall: Int) {
        self.blockedCall = blockedCall
    }

    func isThreadRunning(
        homePath _: String,
        threadID _: String
    ) async throws -> Bool {
        callCount += 1
        if callCount == blockedCall {
            isBlocked = true
            for waiter in blockedWaiters { waiter.resume() }
            blockedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return false
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum PhaseBlockingQueueStoreError: LocalizedError {
    case blocked(CodexDispatchPhase)

    var errorDescription: String? {
        switch self {
        case let .blocked(phase):
            return "Test queue store blocked dispatch phase \(phase.rawValue)."
        }
    }
}

actor PhaseBlockingCodexTaskQueueStore: CodexTaskQueueStoring {
    private var items: [CodexTaskQueueItem] = []
    private var blockedPhase: CodexDispatchPhase?
    private(set) var blockedAttemptCount = 0

    func setBlockedPhase(_ phase: CodexDispatchPhase?) {
        blockedPhase = phase
    }

    func load() throws -> [CodexTaskQueueItem] {
        items
    }

    func save(_ items: [CodexTaskQueueItem]) throws {
        if let blockedPhase,
           items.contains(where: {
               $0.state == .dispatching
                   && $0.dispatchPhase == blockedPhase
           }) {
            blockedAttemptCount += 1
            throw PhaseBlockingQueueStoreError.blocked(blockedPhase)
        }
        self.items = items
    }

    func savedItems() -> [CodexTaskQueueItem] {
        items
    }
}

final class CodexQueueLoadGate: @unchecked Sendable {
    private let loadStarted = DispatchSemaphore(value: 0)
    private let releaseLoad = DispatchSemaphore(value: 0)

    func signalLoadStarted() {
        loadStarted.signal()
    }

    func waitUntilLoadStarts(timeout: TimeInterval = 1) -> Bool {
        loadStarted.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        releaseLoad.signal()
    }

    func waitForRelease() {
        releaseLoad.wait()
    }
}

actor BlockingLoadCodexTaskQueueStore: CodexTaskQueueStoring {
    nonisolated let gate = CodexQueueLoadGate()
    private var items: [CodexTaskQueueItem]
    private(set) var saveCount = 0

    init(items: [CodexTaskQueueItem]) {
        self.items = items
    }

    func load() throws -> [CodexTaskQueueItem] {
        gate.signalLoadStarted()
        gate.waitForRelease()
        return items
    }

    func save(_ items: [CodexTaskQueueItem]) throws {
        self.items = items
        saveCount += 1
    }

    func savedItems() -> [CodexTaskQueueItem] {
        items
    }
}

actor CountingCodexTaskQueueStore: CodexTaskQueueStoring {
    private var items: [CodexTaskQueueItem] = []
    private(set) var saveCount = 0

    func load() throws -> [CodexTaskQueueItem] {
        items
    }

    func save(_ items: [CodexTaskQueueItem]) throws {
        self.items = items
        saveCount += 1
    }
}

private enum StateBlockingQueueStoreError: LocalizedError {
    case blocked(CodexDeliveryState)

    var errorDescription: String? {
        switch self {
        case let .blocked(state):
            return "Test queue store blocked delivery state \(state.rawValue)."
        }
    }
}

/// Test store that preserves its last successful snapshot while rejecting a
/// selected state. This makes pre-persistence `@Published` mutations visible
/// without accidentally making them durable.
actor StateBlockingCodexTaskQueueStore: CodexTaskQueueStoring {
    private var items: [CodexTaskQueueItem] = []
    private var blockedState: CodexDeliveryState?
    private(set) var blockedAttemptCount = 0

    func setBlockedState(_ state: CodexDeliveryState?) {
        blockedState = state
    }

    func load() throws -> [CodexTaskQueueItem] {
        items
    }

    func save(_ items: [CodexTaskQueueItem]) throws {
        if let blockedState,
           items.contains(where: { $0.state == blockedState }) {
            blockedAttemptCount += 1
            throw StateBlockingQueueStoreError.blocked(blockedState)
        }
        self.items = items
    }

    func savedItems() -> [CodexTaskQueueItem] {
        items
    }
}

actor InMemoryCodexConversationHandoffStore:
    CodexConversationHandoffStoring {
    private var transactions: [CodexConversationHandoff]
    private(set) var saveCount = 0
    private let failWhenVerified: Bool
    private let saveDelay: TimeInterval

    init(
        _ transactions: [CodexConversationHandoff] = [],
        failWhenVerified: Bool = false,
        saveDelay: TimeInterval = 0
    ) {
        self.transactions = transactions
        self.failWhenVerified = failWhenVerified
        self.saveDelay = saveDelay
    }

    func load() throws -> [CodexConversationHandoff] {
        transactions
    }

    func save(_ transactions: [CodexConversationHandoff]) throws {
        if saveDelay > 0 {
            Thread.sleep(forTimeInterval: saveDelay)
        }
        if failWhenVerified,
           transactions.contains(where: { $0.state == .verified }) {
            throw InMemoryHandoffStoreError.verifiedSaveRejected
        }
        self.transactions = transactions
        saveCount += 1
    }

    func savedTransactions() -> [CodexConversationHandoff] {
        transactions
    }
}

private enum InMemoryHandoffStoreError: Error {
    case verifiedSaveRejected
}
