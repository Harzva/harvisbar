import Foundation
@testable import HarvisBar

@MainActor
enum HarvisGroupOrchestrationTestSupport {
    static func make() async throws -> (root: URL, group: HarvisGroupCoordinator, delivery: CodexTaskDeliveryCoordinator) {
        let base = ProcessInfo.processInfo.environment["HARVIS_GROUP_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("orchestration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try CodexAppServerTestSupport.makeFakeExecutable(in: root)
        var script = try String(contentsOf: executable, encoding: .utf8)
        script = script.replacingOccurrences(of: "        elif method == \"thread/start\":", with: """
                elif method == "test/setIdentity":
                    test_identity = params["value"]
                    send({"id":request_id,"result":{}})
                elif method == "test/setHistoryFailure":
                    fail_history = True
                    send({"id":request_id,"result":{}})
                elif method == "test/historyCounters":
                    send({"id":request_id,"result":{"count":history_count}})
                elif method == "turn/interrupt":
                    thread_id = params["threadId"]
                    turn_id = params["turnId"]
                    turn = {"id":turn_id,"status":"interrupted","items":[]}
                    upsert_turn(thread_id, turn)
                    active_turns.pop(thread_id, None)
                    send({"method":"turn/completed","params":{"threadId":thread_id,"turn":turn}})
                    send({"id":request_id,"result":{}})
                elif method == "test/ignoreSettingsUpdates":
                    ignore_settings_updates = True
                    send({"id":request_id,"result":{}})
                elif method == "thread/settings/update":
                    thread_id = params["threadId"]
                    if thread_id not in thread_versions:
                        send({"id":request_id,"error":{"code":-32600,"message":"thread not loaded: " + thread_id}})
                        continue
                    if not ignore_settings_updates:
                        thread_sandboxes[thread_id] = "workspace-write" if params.get("sandboxPolicy", {}).get("type") == "workspaceWrite" else "read-only"
                    send({"id":request_id,"result":{}})
                elif method == "model/list":
                    send({"id":request_id,"result":{"data":[{"model":"gpt-test","isDefault":True,"hidden":False,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"medium"}]}],"nextCursor":None}})
                elif method == "test/blockNextIdentity":
                    identity_gate_at = identity_reads + 1
                    send({"id":request_id,"result":{}})
                elif method == "test/blockIdentityAt":
                    identity_gate_at = params["count"]
                    send({"id":request_id,"result":{}})
                elif method == "account/read":
                    identity_reads += 1
                    if identity_reads == identity_gate_at:
                        open(os.path.join(SCRIPT_DIRECTORY, "identity-blocked"), "w").close()
                        while not os.path.exists(os.path.join(SCRIPT_DIRECTORY, "identity-release")):
                            time.sleep(0.01)
                    account = None if os.environ.get("CODEX_HOME", "").endswith("bad-home") else {"type":"chatgpt","email":os.environ.get("CODEX_HOME", "test") + "@example.invalid","planType":"plus"}
                    send({"id":request_id,"result":{"account":account,"requiresOpenaiAuth":True}})
                elif method == "account/rateLimits/read":
                    send({"id":request_id,"result":{"accountId":test_identity or os.environ.get("CODEX_HOME", "test")}})
                elif method == "thread/start" or method == "thread/fork":
        """)
        script = script.replacingOccurrences(of: "        elif method == \"thread/turns/list\":", with: "        elif method == \"thread/turns/list\":\n            history_count += 1\n            if fail_history:\n                send({\"id\":request_id,\"error\":{\"code\":-32000,\"message\":\"history unavailable\"}})\n                continue")
        script = script.replacingOccurrences(of: "        elif method == \"thread/read\":\n            thread_id = params[\"threadId\"]", with: "        elif method == \"thread/read\":\n            thread_id = params[\"threadId\"]\n            if thread_id not in thread_versions:\n                send({\"id\":request_id,\"error\":{\"code\":-32600,\"message\":\"thread not loaded: \" + thread_id}})\n                continue")
        script = script.replacingOccurrences(of: "thread_turns[thread_id] = []", with: "thread_turns[thread_id] = list(thread_turns.get(params.get('threadId'), [])) if method == 'thread/fork' else []")
        script = script.replacingOccurrences(of: "thread_id = \"thread-handoff-\" + str(thread_counter)", with: "thread_id = \"thread-handoff-\" + str(os.getpid()) + \"-\" + str(thread_counter)")
        script = script.replacingOccurrences(of: "thread_counter = 0", with: "thread_counter = 0\nthread_sandboxes = {}\ntest_identity = None\nfail_history = False\nhistory_count = 0\nidentity_reads = 0\nidentity_gate_at = -1\nignore_settings_updates = False")
        script = script.replacingOccurrences(of: "        elif method == \"thread/resume\":", with: "        elif method == \"thread/resume\":\n            params[\"sandbox\"] = thread_sandboxes.get(params[\"threadId\"], \"read-only\")\n            if not thread_turns.get(params[\"threadId\"]):\n                send({\"id\":request_id,\"error\":{\"code\":-32600,\"message\":\"no rollout found for thread id\"}})\n                continue")
        script = script.replacingOccurrences(of: "            thread_versions[thread_id] = 1", with: "            thread_sandboxes[thread_id] = params.get(\"sandbox\", \"read-only\")\n            thread_versions[thread_id] = 1")
        script = script.replacingOccurrences(of: "\"sandbox\":{\"type\":\"dangerFullAccess\"}", with: "\"sandbox\":{\"type\":\"workspaceWrite\" if params.get(\"sandbox\") == \"workspace-write\" else \"readOnly\"}")
        script = script.replacingOccurrences(of: "\"approvalPolicy\":\"on-request\",", with: "\"approvalPolicy\":(\"on-request\" if params.get(\"sandbox\") == \"workspace-write\" else \"never\"),")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        // Match production RPC timing: fixture scripts and durable journals may live
        // on slow external storage. Timeout-specific tests must opt into a short bound.
        let pool = CodexAppServerPool(executableURL: executable, requestTimeout: 30)
        let delivery = CodexTaskDeliveryCoordinator(store: CodexTaskQueueStore(queueURL: root.appendingPathComponent("queue.json")), pool: pool,
            handoffStore: CodexConversationHandoffStore(storeURL: root.appendingPathComponent("handoffs.json")),
            activityProbe: ScriptedCodexActivityProbe([false]), monitorIntervalNanoseconds: 20_000_000)
        await delivery.activate(probeExecutablePath: "/bin/false")
        let group = HarvisGroupCoordinator(delivery: delivery, store: HarvisGroupStore(url: root.appendingPathComponent("groups.json")))
        await group.activate()
        return (root, group, delivery)
    }
}
