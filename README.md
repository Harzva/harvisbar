# HarvisBar

A native macOS menu bar app and local runtime for working with Codex Homes,
accounts, conversations, and agent workflows.

**中文简介：** HarvisBar 是原生 macOS 菜单栏工具，用于发现和管理本机的 Codex
Home、订阅账号、自定义 API 配置及会话。每个 Home 保留自己的配置与历史；
自定义模型配置也能显示，不要求先登录 OpenAI 订阅账号。

This repository contains the HarvisBar Swift application, the `harvis` Rust
runtime, Python integration helpers, local web surfaces, plugin adapters, tests,
and design documentation. It is a source release; it does not include personal
Homes, credentials, conversation databases, signing identities, or a notarized
application download.

## What it does

- Discover the default `CODEX_HOME`, launcher-managed Homes, and explicitly
  supplied Home directories.
- Show subscription and custom API configurations together, including the
  selected model, provider host, settings, account status, and available quota
  information. A custom API Home is not presented as an OpenAI subscription.
- Inspect conversations in the selected account or Home and provide explicit
  actions to open, resume, or launch supported local clients.
- Provide a native conversation workspace with project organization, search,
  task and supervisor views, and reviewable local workflow state.
- Expose the supporting Harvis runtime through CLI, local HTTP, and MCP
  adapters, with additional opt-in integrations for other local agent tools.

Availability varies by the installed client, account, configured integration,
and macOS permissions. Features that send a prompt or perform a local mutation
are separate from configuration discovery.

### Homes and models

A Home is a configuration and history boundary, not a required directory for
every model. An existing custom Home can use a provider or a compatible gateway
that exposes multiple models. HarvisBar discovers that Home and opens its
configuration; it does not automatically copy it into one Home per model.

This source release does **not** bundle a preconfigured multi-provider gateway,
API subscriptions, or provider keys. Configure Codex and any chosen gateway
separately. Custom API credential presence and service availability are separate
facts; discovering a configuration does not verify that its key works.

Account details distinguish configured model options from verified access,
ChatGPT Credits from API balances, and API access from usage-based or monthly
subscription billing. Supported provider usage reads are scoped to the selected
Home and connection; discovery does not query billing services. Missing values
stay unknown, and cached data retains its source and read time. See the
[account models and billing contract](docs/codex-account-billing.md) for local
metadata, explicit refresh behavior, and supported adapters.

[CodexHome Manager](https://github.com/Harzva/codexhome-manager) is a separate
project. HarvisBar currently implements its own Home discovery and launch
integration; it does not yet depend on that project's core library.

## Build and run from source

Requirements:

- macOS 13 or later.
- Xcode Command Line Tools with a Swift 6.0 or newer toolchain.
- A current stable Rust toolchain, including Cargo. No Rust MSRV is declared
  yet; the checked-in lockfile uses Cargo lockfile version 4.
- Python 3.11 or newer for the supporting scripts and tests.
- Git. Node.js 22.19 or 24+ is optional for the DSH bridge tests.
- Codex installed locally for Codex launch and conversation integrations.
  Other integrations require their respective local tools and configurations.

```sh
git clone https://github.com/Harzva/harvisbar.git
cd harvisbar
cargo build --locked --release -p harvis-cli
./scripts/harvis_bar_build.sh
./scripts/harvis_bar_run.sh
```

The run script sets `HARVIS_PLUGIN_ROOT` to the checkout. Build outputs stay in
`target/` and `apps/HarvisBar/.build/`; they are ignored by Git. Running from
source does not install or replace an application in `/Applications`.

Inspect the runtime commands without starting an interactive agent session:

```sh
./scripts/harvis --help
./scripts/harvis codex homes
```

Discovery output can contain account labels, email addresses, provider hosts,
and local paths. Review and redact it before sharing.

### Include an existing custom Home

Use a platform path list in `HARVIS_CODEX_HOMES` when starting HarvisBar. On
macOS the separator is `:`:

```sh
HARVIS_CODEX_HOMES="$HOME/.codex-custom:$HOME/.codex-work" \
  ./scripts/harvis_bar_run.sh
```

Use directories you have already configured. This example does not create,
copy, authenticate, or modify a Home. The variable is scoped to that process;
the same setting must be supplied when launching a packaged app if needed.

### Packaging and signing

The repository includes provenance-checked app packaging scripts. Packaging
requires a clean committed source tree, a verified release stage, and an
externally retained provenance digest. Read the scripts' help before creating
an app:

```sh
python3 scripts/harvis_release_provenance.py --help
./scripts/harvis_bar_package_app.sh --help
```

There is no shared signing identity in the repository. An ad-hoc local package
can be requested explicitly with `--sign-identity -` when no conflicting pinned
local identity is configured. Developer signing, notarization, and the optional
Network Extension require your own setup and applicable entitlements. A source
build is not a notarized distribution and does not automatically enable a
system extension or grant macOS permissions.

## Development checks

```sh
cargo test --locked --workspace
swift test --package-path apps/HarvisBar
python3 -m pip install -r requirements-dev.txt
python3 -m unittest discover -s tests -p 'test_*.py'
(cd plugins/dsh-harvis-bridge && node --test)
```

Some native integration tests are conditional on platform capabilities or
explicit test flags. Live provider, service, GUI, and packaging acceptance
checks are separate from the default unit tests. Tests should use temporary
directories, dummy credentials, and synthetic conversations.

CI explicitly selects Xcode 26.3 and checks the system Git's quiet upstream
lookup before testing. Git-based source/version inspection needs the behavior
[fixed in Git 2.41](https://github.com/git/git/commit/dfbfdc5); older system Git
versions can cause that inspection to fail closed. The inspector deliberately
uses `/usr/bin/git`, so changing only `PATH` does not select another Git for it.

## Repository map

| Path | Purpose |
| --- | --- |
| `apps/HarvisBar/` | Swift application, native core libraries, and tests |
| `crates/` | Rust runtime, integrations, CLI, HTTP, and MCP components |
| `scripts/` | Build, packaging, local workflow, and adapter helpers |
| `schemas/` and `fixtures/` | Versioned contracts and synthetic examples |
| `mcp/` and `.mcp.json` | MCP adapters and local server configuration |
| `plugins/` and `skills/` | Optional agent integration surfaces |
| `panel/`, `presence/`, `studio/`, `ui/` | Supporting local web surfaces |
| `docs/` | Feature contracts, architecture, and development notes |
| `tests/` | Python, packaging, and contract tests |

## Privacy and contributions

The app works with local account and conversation data. Optional AI analysis,
agent execution, or external integrations can send data to the service you
configure. Inspect their settings before use. Screenshots, exported reports,
diagnostics, and test artifacts can still reveal private information even when
they contain no API key.

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability and
[CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Real `auth.json`,
API keys, Home directories, conversation history, private certificates, and
personal acceptance evidence do not belong in pull requests.

## License and naming

Project-authored material is released under the [MIT License](LICENSE).
Third-party components retain their own terms; see [NOTICE.md](NOTICE.md).

HarvisBar is an independent community project. It is not affiliated with or
endorsed by OpenAI or other model providers. Product names and trademarks
belong to their respective owners.
