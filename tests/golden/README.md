# H.A.R.V.I.S. Golden Outputs

This directory stores public-safe protocol fixtures used to prove Rust parity
with the existing Python runtime.

Fixtures must not contain tokens, private memory, raw chat logs, environment
secret values, or absolute local paths. Use temporary workspaces only, and
sanitize transient paths to `<tmp>` before committing or publishing any fixture.
