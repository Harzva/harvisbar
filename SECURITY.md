# Security policy

HarvisBar handles local accounts, configuration, and conversation state.
Treat a published diagnostic, screenshot, or exported report as potentially
sensitive even when API keys have been redacted.

## Reporting a vulnerability

Do not put credentials, private conversations, exploit details against a live
account, or personal filesystem exports in a public issue.

Use GitHub's **Report a vulnerability** option on the repository's Security
page when private reporting is available. If that option is unavailable, open
a minimal issue requesting a private reporting channel without including the
sensitive details. A maintainer will arrange an appropriate channel.

Include the affected commit or release, platform, a synthetic reproduction,
expected and actual behavior, and the scope of the issue. Never send a real
provider key to demonstrate a parsing or routing problem.

## Supported versions

Security fixes target the current `main` branch. There is not yet a supported
release maintenance matrix or a guaranteed response SLA.

## Local use

- Keep Homes, runtime state, local tokens, and signing material outside the
  repository and restrict access to them with operating system permissions.
- Review provider destinations and the data submitted by optional AI or agent
  operations. Configured external services have their own retention policies.
- Do not expose local HTTP or MCP services to untrusted clients without
  reviewing their authentication, network binding, and allowed operations.
- Grant macOS permissions only for the functionality you intend to use.
- The source release includes no shared signing identity, notarization ticket,
  provider credentials, or personal runtime data.
