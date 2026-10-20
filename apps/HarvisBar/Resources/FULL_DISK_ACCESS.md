# H.A.R.V.I.S. Full Disk Access

H.A.R.V.I.S. services run as local LaunchAgents. macOS may block protected or
external-volume workspaces until the user grants Full Disk Access to the
installed `HarvisBar.app` identity. The switch is only a user choice; the full
permission probe is the authority for whether access actually works.

## Current runtime identities

The installed system has four distinct roles:

- `HarvisBar.app` is the user-visible application and the only current
  H.A.R.V.I.S. entry that should be rebound in Full Disk Access.
- `HarvisBar.app/Contents/Resources/HarvisPlugin/bin/harvis` is the
  receipt-bound deployment source bundled with that application.
- `~/.harvis/bin/harvis` is the fixed resident helper. Both the HTTP and Tick
  LaunchAgents must use this exact executable as `ProgramArguments[0]`.
- `scripts/harvis` is an interactive command wrapper. It is not the resident
  LaunchAgent or Full Disk Access authority.

`HarvisRuntime.app` belongs to a legacy installation model. Do not select it as
the current authority, add it to Full Disk Access, or delete an existing copy
as part of this repair. Cargo target and repository build paths are also not
valid resident identities.

## Signing and identity continuity

A certificate-signed build with a stable designated requirement is preferred
for distribution. A local ad-hoc candidate may be installed only after the
user explicitly approves that local replacement. It must not be published,
notarized, or represented as preserving identity continuity.

For an ad-hoc candidate, `continuityClaim=false`: replacing the application can
change the code identity even when its path is unchanged. After every such
replacement, explicitly rebind the HarvisBar Full Disk Access entry and run the
full permission probe again. Never infer success from the visible switch alone.

## Scoped Full Disk Access rebind

1. From HarvisBar, open **Full Disk Access**. HarvisBar uses the macOS
   `Privacy_AllFiles` settings route and its compatibility fallback.
2. Change only the `HarvisBar` entry. Turn it off and back on, or remove and add
   the installed `HarvisBar.app` again if macOS still retains a stale identity.
3. Accept a HarvisBar restart if macOS requires it, then restart H.A.R.V.I.S.
   services so both LaunchAgents execute the fixed helper.
4. Run the full permission probe and require every protected-workspace check to
   pass. Then confirm the local status APIs succeed before declaring recovery.

Do not run a broad `tccutil reset`, reset the entire privacy service, or modify
unrelated applications' Full Disk Access choices. A privacy change must happen
only after the user explicitly confirms it at action time.

Keep this permission narrow and reviewable. HarvisBar is a service-control and
inspection surface; it does not bypass approvals.
