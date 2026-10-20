# Third-party components and references

The root MIT license covers project-authored HarvisBar material. It does not
replace the licenses of dependencies, optional integrations, operating system
frameworks, or external tools.

## Build dependencies

- Rust dependencies are declared in the workspace and crate `Cargo.toml`
  files. `Cargo.lock` records the exact resolved versions and registry checksums.
  The [resolved dependency license inventory](docs/dependency-licenses.json)
  records the metadata of the 218 third-party packages resolved by the lockfile.
  This inventory is informational and does not replace upstream license texts.
  Their upstream packages include their respective license and copyright
  notices. Preserve the applicable notices when redistributing a binary or a
  vendored dependency tree.
- The Swift package uses Apple system frameworks and project-local targets;
  its manifest is `apps/HarvisBar/Package.swift`.
- The optional DSH bridge declares its Node.js compatibility and peer
  dependency in `plugins/dsh-harvis-bridge/package.json`. The peer dependency is
  not relicensed by this repository.
- Optional test-only Python dependencies are declared in
  `tests/requirements-version-agent.txt` and retain their upstream licenses.

This source repository does not vendor a general Rust, Python, or Node package
cache. A downstream binary distributor must review the licenses of the exact
dependency versions used for that distribution; this notice is not a claim
that every dependency is MIT licensed.

## Design and interoperability references

Feature documents preserve links to reference projects and pinned revisions.
For example, the project-organization and conversation-card notes identify
BattleLab, agentsview, AgentHub, and AionUi as references. Those documents
describe the reuse boundary; a design reference does not grant a license to
copy its code. Development skills and design guidance are not runtime
dependencies.

Codex, DeepSeek Harness, WorkBuddy, and other external tools are independently
licensed products. Their executables, user subscriptions, API credentials, and
personal runtime data are not supplied by this project. HarvisBar's root
license does not grant rights to third-party product names or trademarks.
