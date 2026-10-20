# DSH launch preview, 0.43.0

The B·DSH entry is a launcher and composition preview. Profile cards open a
preview before starting anything. The native window has a HOME → Profile tree,
Profile cards, and a two-to-four-Profile package comparison matrix. Instance
and session management remain available as secondary navigation.

## Model and ownership

- A **DSH program** is an executable installation. The current launcher resolves
  one default entry per HOME; this is its discovery/launch behavior, not a rule
  that the HOME can contain only one program version. The tree labels its version
  as an entry version. The program list covers resolved default entries only.
- A **HOME** is a shared configuration/data space. It owns multiple Profile
  directories and a shared patch. A program installation may serve multiple
  HOMEs, and using a different entry can change the program for the same HOME.
- A **Profile** is a composition, not a program version or a session Preset.
  The preview identifies its default launch base and declared packages. Starting
  a Profile creates/opens a runtime instance through the existing launcher.
- A **Preset** supplies agent-facing declarations when selected for an agent or
  session. Merely previewing one neither selects it nor changes a running session.

## Sharing is not one number

The selected Profile exposes separate filters:

1. HOME uniformly added: direct plugin references in the HOME shared patch.
2. Referenced by other Profiles: package names found in at least two Profiles
   of this HOME, including the selected Profile.
3. Unique to this Profile: package names found only here, with at least one
   other Profile available for comparison.
4. UI contribution declarations: installed package metadata has `dsh.client`.

The first two categories can overlap. Ordinary dependency libraries are excluded
from these package counts. References are not proof of physical file sharing or
effective activation. Details show which Profiles reference a package and the
configuration/bundle sources. Official/third-party/unknown provenance remains a
separate dimension in the inventory.

The matrix compares the selected columns only. Common package names with different
resolved versions remain in the differences filter. Each cell shows version,
origin, HOME versus composition reference, and observed conditional/disabled
declarations. Unknown versions never imply matching binaries.

## Offline Preset preview

The source-checked CLI profile boot contract supplies the installation's
`config/agent-presets`; the agent-presets provider normally appends the HOME's
`.agent-presets`. The preview scans these two conventional roots read-only, at
most 128 direct directories per root, and reads only bounded `agent.cordis.yml`
plugin declarations. Duplicate names from the two roots stay distinct.

This is not the effective roster for a specific Profile. Overrides of roots,
custom deployments, include files, JavaScript expressions, dynamically created
modes, and final Loader composition are not evaluated. Parse errors omit source
excerpts; prompt/configuration values never enter the result. Preset rows compare
names to the selected Profile and distinguish additional declarations from
same-name declarations. Actual availability is checked inside DSH.

Source contracts inspected: CLI `src/profile-boot.ts`, agent-presets
`src/discovery.ts`, `src/index.ts`, and `src/mount.ts` from the local default
installation; this preview does not alter those files.

## Validation and deployment

Automated checks cover HOME-sharing versus declaration co-occurrence, matrix
version differences, single-column semantics, separated Preset sources,
conditional declarations, and omission of configuration/parse-error values.
Existing DSH transport/sender checks cover the reused operations.

The focused checks passed: 16 Rust DSH tests and 40 Swift catalog, sender, Host
client, and bounded-transport tests. A real read-only catalog run completed in
2.72 seconds with 8 HOMEs, 31 Profiles, and a 3.3 MB result. The default HOME
contained 11 Preset files across the two inspected roots. Its digital-me Profile
had 159 package declarations shared with at least one other Profile, zero unique
package names in that HOME-wide comparison, and 63 client contribution metadata
entries. These are declaration statistics, not active-plugin or visual QA results.

Native installation, tree navigation, matrix filtering, and launch/restart
acceptance are pending: the native control tool reports that the Mac is locked.
The new build must not be described as installed or click-verified until that
acceptance is completed. The previous installed 0.42.1 remains the active app.
