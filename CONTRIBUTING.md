# Contributing

Open an issue describing the concrete behavior you want to change, or submit a
focused pull request with a reproducible example and the checks you ran. Use
synthetic data in examples, screenshots, and fixtures.

## Working locally

Read the build and test commands in [README.md](README.md). Keep changes scoped
to their owning layer: the Swift UI, Rust runtime, integration helper, or
versioned schema. Preserve existing runtime and account boundaries. Do not
silently create a Home, copy credentials, send a prompt, or mutate a user's
conversation state during discovery or UI refresh.

Run the checks appropriate to the change. The default CI uses unit and
contract tests without provider keys. Live API, signing, GUI, and production
installation checks must remain explicit and separate. Document any test that
requires a service, local client, or macOS entitlement.

## Privacy before committing

Review both `git diff --cached` and the names of all new files. Do not commit:

- API keys, bearer tokens, cookies, passwords, or real authentication files.
- Personal `CODEX_HOME` directories, session JSONL, chat databases, logs, or
  account exports.
- Private keys, signing identities, provisioning profiles, or keychain exports.
- Personal machine paths, private hostnames, internal IPs, or private project
  details in diagnostics and screenshots.
- Build outputs, application bundles, DMGs, package caches, or local evidence.

Use `example.test`, `example.invalid`, loopback addresses, temporary directories,
and clearly dummy credentials for fixtures. An ignore rule does not remove a
secret already committed to Git history. If a credential is exposed, revoke it
and report the incident privately rather than adding another public copy.

Before publishing a branch, run Gitleaks against both files and reachable Git
history (`gitleaks dir .` and `gitleaks git .`). The few inline `gitleaks:allow`
annotations identify deterministic dummy values in regression tests; they do
not exempt a directory or permit real credentials in fixtures.

## Pull requests

Explain the problem, the resulting behavior, and relevant validation. Call out
schema or compatibility changes. Preserve third-party attribution and include
license notices for any newly incorporated material. Contributions are made
under the repository's MIT license unless a file explicitly states otherwise.
