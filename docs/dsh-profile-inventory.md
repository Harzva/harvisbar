# DSH management in B·DSH

The HarvisBar DSH section now offers three paths: launch environments, running
instances, and DSH sessions. Home selection scopes the panel. Profile cards
open their exact Home/Profile details instead of an unrelated default Home.
The independent DSH window preserves these three paths; it does not navigate
to Chat/Agent Managed or change its UI. Session history and sending reuse the
existing DSH Host client and delivery coordinator, including endpoint ownership,
archived/subagent checks and no automatic resend after uncertain delivery.
The DSH application menu can open the same B·DSH component in a persistent
quick window. Reopening the Bar when it has no visible window opens that view.

## Plugin inventory

The read-only Rust catalog expands package manifests, declared bundle patch
files, Profile root/patch files and the HOME shared patch. It reads loader row
names, group children and insert declarations. Ordinary dependencies are
separated from plugin and bundle packages. Installed metadata provides the
resolved version and description. Profile dependencies, shared node_modules
and canonical package ancestors support the existing pnpm layout.

Origin labels are evidence labels, not attestations: official requires both
an @deepseek-ai name and the exact official DSH repository metadata. Explicit
local overrides in that namespace remain unknown. Other scoped publishers or
identified nonofficial repositories are third party; unscoped packages without
source metadata remain unknown. The detail view explains each decision and
shows the declared installation spec and reference sources. Repository URLs
with userinfo, queries or non-HTTPS schemes are omitted.

This is a **declaration inventory**, not a claim that every listed plugin is
active. It does not execute plugin code or JavaScript configuration expressions,
merge overrides into an effective Loader graph, follow external include files,
scan all Presets, or include command-line/dynamic additions. A disabled or
conditional declaration is labeled as such without asserting final activation.
Unsupported/unreadable bundle declarations produce explicit scope warnings.
Configuration values and parse-error excerpts never enter the catalog.

The YAML parser is serde_yaml_ng (locked in Cargo.lock). Loader traversal was
checked against the installed DSH include/app-boot source; the implementation
intentionally does not duplicate its activation or patch-composition engine.
The source labels include core Cordis packages, not just dsh-prefixed packages.

## Verification scope

Narrow Rust tests cover bundle expansion, shared package resolution, missing
packages, source spoofing/local overrides, and omission of configuration data.
Swift checks cover legacy decoding, counts, search and unknown-source handling;
existing DSH Host, adapter and sender tests cover reused session boundaries.
No DSH profile plugin or credential configuration is modified by inventory.

### Local acceptance, 2026-09-08

The packaged 0.42.1 app passed the provenance, payload, and code-signature
verifier and replaced the local Bar, with the previous app retained for rollback.
The focused checks passed: 15 Rust DSH tests and 48 Swift catalog, transport,
Host client, adapter, and sender tests. Subsequent menu/reopen changes passed
the five catalog tests and production compilation.

Native clicks verified the persistent B·DSH entry, opening the independent DSH
catalog, the digital-me plugin detail sheet, official/third-party/unknown filters,
search and empty results, source disclosure, the running instance and its exact
port restart menu, and navigation from that instance to its Profile's sessions.
The session list showed the actual `harzva-digital-me` Preset; history opened in
the DSH-specific conversation sheet.

Clicking Send in the existing dedicated acceptance session submitted the unique
marker `HARVIS_DSH_MANAGER_20260908_0421_OK`. The UI showed acceptance. The
Host API independently returned a user message at sequence 414 and the exact
assistant reply at sequence 440 from `deepseek-v4-flash`, in the same session.
The Mac locked before the final native history refresh. Native reply rendering,
the compact HOME/layer selectors, and a fresh launch/restart cycle remain to be
verified after unlock; the daily instance was not restarted for this check.

The installed catalog initially timed out at its 20-second limit while the same
CLI completed from a terminal. A process sample located the scan in a system
file-open call; a later native refresh succeeded, showing 8 HOMEs and 31 Profiles.
The root cause of that transient blocking is not established. Quick-view errors
are now explicit and preserve the last successful inventory; an unsuccessful
scan must not be presented as evidence that no Profiles exist. Port labels use
literal decimal strings so locale grouping cannot alter their displayed value.
