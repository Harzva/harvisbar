# H.A.R.V.I.S. Agent Pools Interface

H.A.R.V.I.S. uses two separate base pools behind the Agent Roster, plus a preset
binding list:

- **Harness Pool**: execution runtimes that can run an agent loop, call tools,
  read/write approved workspace files, and produce logs.
- **Model Pool**: model backends that provide reasoning or coding capability.
- **Runtime Preset Pool**: named convenience bindings of one harness plus one
  model, such as `cxspark`.

An agent is not the same thing as a model or harness. An agent is the durable
identity, role, policy, memory/context boundary, and transport projection. A
harness is how the agent acts. A model is what the harness asks for reasoning.
Runtime presets are shortcuts; they are not new harness families.

```text
Feishu / WeChat / WebView
  -> Harvis Router
  -> Agent Roster
  -> Harness Pool
  -> Model Pool
  -> Runtime Preset Pool when a named binding is requested
  -> approvals, logs, Agent Room, result callback
```

## Design Goal

Adding Kimi Code, Claude Code, Codex, LikeCode, DeepSeek, or another model must
not require rewriting Feishu, WeChat, or WebView adapters. Transport adapters
send the message to Harvis Router. Harvis selects:

1. the agent identity from Agent Roster,
2. the harness from Harness Pool,
3. the model from Model Pool,
4. the runtime preset, when the user requests a preset name,
5. the approval policy from the selected agent and harness,
6. the callback transport for status and final result.

## Harness Pool Contract

Harness entries describe execution capability, not personality and not a
prebound model choice.

```json
{
  "harness_id": "kimicode",
  "label": "Kimi Code",
  "kind": "kimi-code",
  "status": "active",
  "command_aliases": ["kimicode", "kimi"],
  "adapter": {
    "mode": "cli",
    "prompt_input": "arg",
    "result_output": "stdout"
  },
  "supports_model_override": true,
  "default_model_id": "moonshot-kimi:kimi-code/kimi-for-coding",
  "allowed_model_ids": ["moonshot-kimi:kimi-code/kimi-for-coding"],
  "review_gate": "required"
}
```

Rules:

- `harness_id` is stable and may be referenced by Agent Roster, handoffs, and
  execution logs.
- `kind` names the runtime family. Keep the core set small: `codex`,
  `kimi-code`, `claude-code`, and `likecode`.
- `command_aliases` are executable names only. Do not include command arguments
  that reveal tokens or local access files.
- `supports_model_override=false` means the harness wrapper owns model choice.
- `review_gate=required` means task execution must remain approval-gated.

## Model Pool Contract

Model entries describe provider capability and credential lookup, not execution.

```json
{
  "model_id": "deepseek:deepseek-v4-pro",
  "label": "DeepSeek v4 Pro",
  "provider": "deepseek",
  "status": "active",
  "credential_ref": {
    "kind": "local-access-note",
    "ref": "deepseek-api-config",
    "contains_secret_value": false
  },
  "capabilities": ["coding", "fast-reply", "summarization"],
  "preferred_harness_ids": ["likecode", "claude-code"]
}
```

Rules:

- `model_id` is provider-scoped. Use `<provider>:<model-name>`.
- `credential_ref` must never contain a key value, cookie, token, or raw config
  dump.
- `local-access-note` means a machine-local operator note explains how to
  configure the provider. The pool stores only the reference label.
- `preferred_harness_ids` defines where this model can normally run.
- A model can be used by many agents. An agent can switch models by task.

## Runtime Preset Contract

Runtime presets describe known local command shortcuts that bind one harness to
one model.

```json
{
  "preset_id": "cxspark",
  "label": "CX Spark",
  "harness_id": "codex",
  "model_id": "openai:gpt-5.3-codex-spark",
  "status": "active",
  "command_aliases": ["cxspark"],
  "wrapper_skill_id": "cxspark",
  "review_gate": "required"
}
```

Rules:

- A preset must reference exactly one `harness_id` from Harness Pool and one
  `model_id` from Model Pool.
- `cxspark` means `codex` harness plus Spark/Codex-Spark model.
- Presets can have wrapper commands and review scripts, but they do not become
  separate harness families.

## Agent Roster Relationship

Agent Roster remains the identity source. Pool references should appear inside
the agent backend:

```json
{
  "agent_id": "agent:d4p",
  "backend": {
    "kind": "harness",
    "model_or_harness": "codex",
    "harness_id": "codex",
    "model_id": "openai:gpt-5-codex",
    "fallback_harness_ids": ["kimicode"],
    "fallback_preset_ids": ["cxspark"],
    "fallback_model_ids": ["deepseek:deepseek-reasoner"]
  }
}
```

This keeps all transports synchronized:

```text
one Harvis agent identity
  -> one or more transport projections
  -> one default harness
  -> one default model
  -> ordered fallbacks
```

## Current Local Families

The current local design recognizes these harness families:

- `codex`: direct Codex CLI execution.
- `kimicode`: Kimi Code CLI execution.
- `claude-code`: Claude Code CLI execution.
- `likecode`: independent LikeCode framework harness, typically routed through
  the local `d4p` alias for `deepseek:deepseek-v4-pro`.

The current local design recognizes these runtime presets:

- `cxspark`: `codex` + `openai:gpt-5.3-codex-spark`.

The current model families are:

- OpenAI/Codex models through the Codex login/profile.
- Moonshot/Kimi models through Kimi Code or local Kimi provider config.
- DeepSeek models through local DeepSeek provider config.
- Mimo through Claude Code-compatible local settings.

## Safety Rules

- Pool files must not contain API keys, tokens, cookies, `.env` values, raw
  access-file contents, or credential dumps.
- Pool files should avoid machine-specific secret file paths. Use reference
  labels such as `kimi-api-config` or `deepseek-api-config`.
- Harness execution must write logs under `.harvis/executions/` or the
  harness-specific run folder.
- Any task that can edit files, execute commands, publish, deploy, delete, or
  call external systems must remain approval-gated.
- Transports are not agents. Feishu, WeChat, and WebView are ingress/egress
  surfaces that call Harvis Router.

## Done Definition

The two-pool integration is considered stable when:

1. `schemas/agent-pools.schema.json` validates the pool file.
2. Agent Roster validates every referenced `harness_id` and `model_id`.
3. Runtime presets validate against existing harness and model IDs.
4. Harvis status can report both pools without model calls.
5. A smoke test can run selected harnesses in a temporary empty directory.
6. Feishu, WeChat, and WebView can all submit the same task to Harvis Router.
7. Execution status is visible in Agent Room and callback transport.
