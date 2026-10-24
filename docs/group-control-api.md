# HarvisBar background group control

The running HarvisBar Swift process owns group state, native Codex app-server threads and the durable delivery queue. HTTP and MCP are clients of that process, not independent group engines. Closing or hiding a group window does not stop its runtime. Quitting HarvisBar makes these interfaces unavailable; the existing Rust HTTP/tick LaunchAgents do not take over native group execution.

Enable background access for each group in HarvisBar. Set the group owner and project permission there. External callers cannot change these grants, select a profile/home, replace native bindings or approve human approval requests.

## MCP

Use the existing `harvis mcp` command, with an absolute path to the packaged runtime:

```json
{"mcpServers":{"harvis":{"command":"/absolute/path/to/harvis","args":["mcp"]}}}
```

The tools are `harvis_group_list`, `harvis_group_status`, `harvis_group_send`, `harvis_group_results`, `harvis_group_cancel` and `harvis_group_recover`. Existing `harvis_agent_room_*` tools retain their separate record-only Agent Room behavior.

## HTTP

POST JSON parameters to `http://127.0.0.1:8765/group-chat/{list,status,send,results,cancel,recover}`. All group routes require a configured bearer token of at least 32 bytes, a loopback-only server and an `Authorization: Bearer <configured-token>` header. Browser Origin requests are rejected. Group execution remains disabled when the existing general HTTP service runs without authentication.

Successful responses contain `{"ok":true,"data":...}`; errors contain `{"ok":false,"error":{"code":"...","message":"..."}}`. Send returns HTTP 202 only after its receipt is durable. It does not mean a model turn completed.

## Parameters

| Method | Parameters |
| --- | --- |
| list | `{}`; returns only groups with background access enabled |
| status | `groupID`; summary, members, latest 100 dispatches and runs |
| send | `groupID`, `text`, stable `requestID`; optional `mode`, `memberIDs` |
| results | `groupID`; optional `afterSequence` (default 0), `limit` (default 20, max 100) |
| cancel | `groupID` and either `runID` or `memberID` |
| recover | `groupID`; schedules native history reconciliation, never resubmits unknown execution |

Send defaults to `coordinated`, which delegates to the configured group owner. `direct` requires explicit nonempty memberIDs. `recordOnly` has no recipients and records a user message without execution. Text mentions do not silently add direct-mode recipients. Permission comes from the group project grant, never a caller-supplied permission or filesystem path.

Generate a requestID before sending. After any timeout or lost response, retry with the same ID and exactly the same payload. The group store returns the original receipt (`groupID`, `messageID`, optional `runID`, `dispatchIDs`) without re-execution. Reusing an ID with a different payload returns conflict (HTTP 409). Poll status/results to follow completion.

Results return complete messages within a bounded page, `nextSequence` and `hasMore`. If one message exceeds the transport limit, an explicit error directs the user to native history; it is not silently truncated. Status deliberately excludes private home paths, account fingerprints, credentials and raw native errors. Cancelling a member requests stopping all of that member's queued/current work, not just one dispatch. Native interruption is best effort; already committed filesystem effects are not rolled back.

## Use a group as an agent service

An external agent can use the copied MCP entry as a service without managing its internal conversations:

1. Call `harvis_group_list` and choose the service. Each enabled group has a `service` descriptor object advertising `schemaVersion: "harvis.agent-service.v1"`, `serviceID: "harvis-group:<UUID>"`, `name`, `description`, capabilities (`task.submit`, `task.status`, `task.results`, `task.cancel`), `defaultMode: "coordinated"`, supported `transports`, `requiresRunningApp: true` and `ownerConfigured`. The descriptor’s `responsibilities` lists each member’s `memberID`, `name`, `role` and `isOwner`, so callers can discover the team’s assigned responsibilities separately from protocol capabilities. Keep the group’s existing top-level `id` as the `groupID` for calls. If `ownerConfigured` is false, a human must configure the owner in HarvisBar.
2. Submit a goal with `harvis_group_send` using `groupID`, `text` and a stable `requestID`. Leave the default coordinated mode. Store the receipt's `runID`; it identifies this goal, not a native chat to manage.
3. Poll `harvis_group_status`. Match the run by `id`; use its `state`, `summary`, `rootMessageID`, `ownerRound`, `taskCount` and `finishedTaskCount`. Members expose `role`, `isOwner`, `state` (`idle`, `queued`, `running`, `awaitingApproval`, `blocked`, `completed`, `failed`, `cancelled`), `currentTask`, `queuedTaskCount` and `completedTaskCount`. A finished step may have failed, and a member finishing does not mean the service has finished. `needsInput`, `deliveryUnknown`, `failed` and `cancelled` are not successful delivery.
4. Once the coordinated run is `completed`, collect its `summary` and call `harvis_group_results` for `deliveries`. A delivery contains `runID`, `rootMessageID`, the final owner `summary`, `finalMessageID` and `finalSequence`. It is emitted only when that run is completed and its final owner dispatch is completed with a natively verified reply. Do not infer service delivery from a member's completed status. Direct-mode runs retain ordinary `messages` and do not manufacture an owner delivery.
5. To stop this goal, call `harvis_group_cancel` with its `runID`. Native thread IDs remain available for auditing but are unnecessary for normal submit/status/results/cancel use.

`deliveries` follows message pagination: only final owner replies with sequence greater than `afterSequence` and at most the returned `nextSequence` are included. Messages and their delivery summaries share one response size budget. For the ordinary service workflow, first wait for run completion, then read results from `afterSequence: 0` and follow `nextSequence` while `hasMore` is true. If an agent already consumed streamed messages before final verification completed, it must reread from 0 after run completion; verification can update an existing reply without allocating a new sequence. Deduplicate deliveries by `runID`. The status run's `summary` is also available after completion, so service callers never need to resume or inspect an internal native thread to collect the final summary.

## Private transport

The default endpoint is `~/Library/Application Support/HarvisBar/GroupChat/control.sock`. A private test deployment may set `HARVIS_GROUP_SOCKET` in both processes. Use a dedicated 0700 directory and a socket path no longer than 103 UTF-8 bytes on macOS. A same-user peer check and 0600 socket restrict access to the current OS user; this does not claim to sandbox other processes running as that same user.

Each Unix connection carries one newline-terminated JSON-RPC 2.0 request and one response, at most 1 MiB each. Methods use the `groups.` prefix, such as `groups.send`. Connections have bounded timeouts. A process ownership lock protects the listener; shutdown removes only the socket inode that server created. No bridge reads or writes the group's JSON ledger directly.
