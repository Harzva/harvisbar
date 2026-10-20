# H.A.R.V.I.S. Agent Roster Interface

Harvis Agent Roster is the single source of truth for roundtable agent identity.
External systems such as Feishu, Agent Mail, Slack, WeChat, Studio UI, and daily
report schedulers must treat roster entries as transport projections, not as
separate agent definitions.

## Goal

Adding or replacing an agent should be a registry operation:

1. Add one `agents[]` entry.
2. Point it at a backend provider, Codex model, local harness, or manual identity.
   Backend references should resolve through the Harness Pool and Model Pool
   described in `docs/agent-pools-interface.md`.
3. Configure one or more transport projections.
4. Run roster validation.
5. Restart or refresh consumers that read the roster.

No dispatcher should hard-code the number or names of roundtable agents.

## Required Agent Contract

Every enabled agent must include these fields:

```json
{
  "agent_id": "agent:example",
  "display_name": "Harvis Example",
  "role": "planner",
  "enabled": true,
  "roundtable": true,
  "capabilities": ["planning", "review"],
  "safety": "review-gated",
  "context_policy": {
    "harvis_knowledge": {
      "enabled": true,
      "mode": "read-only",
      "max_results": 3
    },
    "harvis_webview": {
      "enabled": true,
      "mode": "read-only",
      "routes": [
        "http://127.0.0.1:8765/webview/status",
        "http://127.0.0.1:8765/studio/roundtable",
        "http://127.0.0.1:8765/agent-room/live"
      ]
    }
  },
  "backend": {
    "kind": "provider",
    "model_or_harness": "example-model",
    "harness_id": "codex",
    "model_id": "openai:gpt-5-codex",
    "preset_id": "cxspark",
    "fallback_harness_ids": ["kimicode"],
    "fallback_preset_ids": ["cxspark"],
    "fallback_model_ids": ["deepseek:deepseek-reasoner"]
  },
  "transport": {
    "feishu": {
      "enabled": true,
      "profile": "harvis-example-bot",
      "bot_name": "Harvis Example",
      "status": "pending"
    }
  },
  "sync_policy": {
    "required_transport": true,
    "review_gated": true
  }
}
```

## Field Rules

- `agent_id`: stable ID, format `agent:<slug>`. Never rename after messages have
  been written to Agent Room.
- `display_name`: human-facing name shown in Studio UI and transports.
- `role`: coordination role, such as `planner`, `reviewer`, `coding-executor`, or
  `frontier-reasoner`.
- `capabilities`: bounded capability labels used for routing and safety display.
- `safety`: must be `review-gated`, `record-only`, or `approval-required`.
- `context_policy.harvis_knowledge`: read-only access to Harvis-provided
  knowledge context such as hub status, hub search, and knowledge graph summaries.
- `context_policy.harvis_webview`: read-only access to WebView state through
  Harvis gateway routes. Agents must not treat the WebView itself as an
  independent entrypoint.
- `backend.kind`: one of `provider`, `codex`, `harness`, or `manual`.
- `backend.model_or_harness`: backward-compatible canonical backend selector
  for routing.
- `backend.harness_id`: optional Harness Pool reference. Prefer this for new
  integrations.
- `backend.model_id`: optional Model Pool reference. Prefer this for new
  integrations.
- `backend.preset_id`: optional Runtime Preset Pool reference for named
  harness+model bindings such as `cxspark`.
- `backend.fallback_harness_ids` and `backend.fallback_model_ids`: ordered
  fallback references. These do not grant execution authority; agent safety and
  approval gates still apply.
- `backend.fallback_preset_ids`: ordered fallback preset references. Do not put
  presets in `fallback_harness_ids`.
- `transport.feishu.profile`: lark-cli profile name. It must exist in local
  lark-cli config before the projection can become active.
- `transport.feishu.status`: `pending`, `active`, or `disabled`.
- `sync_policy.review_gated`: must stay true for agents that can influence tasks,
  code, publishing, deletion, or external side effects.

## Feishu Projection Rules

When global sync policy is strict:

- Every enabled roundtable agent with `required_transport=true` must have one
  Feishu bot projection.
- The lark-cli profile named by `transport.feishu.profile` must exist.
- Active Feishu projections must have both app identity and bot open ID.
- Any local Feishu profile whose name starts with `harvis-` must map back to one
  roster agent, otherwise validation fails as an orphan profile.
- Feishu message dispatchers must read `agents[]` from the roster and must not
  hard-code bot lists.
- Dispatchers may use one or more Feishu bots as ingress consumers, but routing
  is roster fan-out: a deduplicated inbound user message must be routed to every
  active roundtable agent. This avoids coupling agent membership to per-app event
  subscription quirks while keeping one Feishu bot projection per agent.

## Agent Room Event Contract

Every Feishu inbound message and every agent reply should write Agent Room JSONL
records with:

- `chat_id`
- `source_message_id`
- `message_id` when available
- `agent_id`
- `route_reason`
- `transport`: `feishu`
- `profile`
- `sender_id` or `bot_open_id` when available

The local Agent Room record is the audit trail. Feishu is only a transport.

## Harvis Context Gateway

Harvis is the only runtime entrypoint for agent context. External surfaces such
as the local WebView must register through Harvis and be exposed to agents only
as redacted read-only context.

- Agents read Harvis context, not raw WebView state.
- WebView status is exposed through `GET /webview/status`, not by letting an
  agent browse or control `http://127.0.0.1:7861/` directly.
- `GET /webview/status` must only proxy localhost WebView URLs, must redact local
  absolute paths, and must return `includesLocalAbsolutePaths=false`.
- Feishu dispatchers may include Harvis context in prompts, but must label it as
  read-only and must record `context_access` metadata in Agent Room events.
- Context access does not grant command execution, UI clicking, file edits,
  network browsing, token reads, or external side effects.

## Add-Agent Checklist

1. Choose `agent_id`, `display_name`, `role`, `capabilities`, and `backend`.
2. Add the agent to `.harvis/agent-roster.json` with Feishu `status=pending`.
3. Create the matching lark-cli bot profile.
4. Resolve app ID and bot open ID, then set Feishu `status=active`.
5. Run the local sync helper to compare roster and lark-cli state:
   `node <path-to-harvis-lark-roster-sync.mjs>`.
6. When profile and open ID are known, apply the projection:
   `node <path-to-harvis-lark-roster-sync.mjs> --write --open-id <profile>=<open_id>`.
7. Run `harvis agent-roster validate --root <workspace>`.
8. Restart or refresh the Feishu dispatcher.
9. Send a roundtable test message.
10. Verify replies and Agent Room JSONL records.

## Next-Step Prompt

Use this prompt when asking another Harvis/Codex session to extend the roster:

```text
请按 Harvis Agent Roster 规范新增一个 roundtable agent。

要求：
1. 只把 .harvis/agent-roster.json 作为身份源，飞书只是 transport projection。
2. 新增 agent 必须包含 agent_id、display_name、role、enabled、roundtable、
   capabilities、safety、context_policy、backend.kind、backend.model_or_harness、
   transport.feishu、sync_policy。
3. 新增后运行 harvis agent-roster validate --root <workspace>。
4. 如果 transport.feishu.status 还是 pending，必须明确列出缺少的 lark-cli
   profile/app_id/open_id，不要伪装成已完成。
5. dispatcher 必须从 roster 读取 active bots，不允许手写 bot 数量。
6. 闭环测试必须包含：发送飞书消息、确认所有 active agent 回复、确认 Agent Room
   JSONL 写入 chat_id/message_id/agent_id/route_reason。
7. review gate 必须保留，任何危险任务都不能自动执行。
8. Harvis 必须是 agent context 的唯一入口；WebView 只通过 Harvis
   /webview/status 以只读、脱敏摘要形式暴露。
```
