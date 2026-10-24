# HarvisBar permissions

Open **权限与个性化** from the gear button or Settings. The guide also opens
before the first background refresh. You can continue with basic features and
configure optional access later.

## Choose what HarvisBar may read

Workspace monitoring is disabled until you explicitly enable the displayed
workspace and profile directories or complete a successful check. Choosing a
folder alone changes the path. Consent is tied to both paths;
changing a path requires a new choice. Other launchers’ Homes and historical
project reads have separate switches, both initially off.

**验证并启用** performs a write check only when clicked. It checks the
workspace, its state directory and the configured profile through the running
local service. Success is evidence for those paths, not a test of Full Disk
Access. A successful check enables background reads for those paths; you can
turn this off at any time. A denied check disables reading until you choose
to try again. Opening this guide and refreshing its system status do not run a
write check.

## Enable optional macOS permissions

- Accessibility: needed to position or control another app’s windows.
- Screen Recording: needed for screenshot-based recognition.
- Full Disk Access: may be needed for protected locations used by a selected
  workflow. macOS manages this permission; HarvisBar does not infer it by reading
  unrelated private files.
- Automation: macOS asks separately for each target app when a chosen action
  sends Apple Events, such as opening a task in Terminal.

Use the guide’s System Settings buttons. For Accessibility or Full Disk Access,
drag the displayed app icon into the corresponding app list if it is absent,
then enable the app yourself. **Show in Finder** locates the exact running app.
If macOS asks you to restart HarvisBar, finish or preserve active work first.
The personal Bar name changes the menu bar and window titles; System Settings
continues to show the product name HarvisBar.

Local services are distinct processes. A successful app-level grant is not
proof that a separate helper can access a path. If the workspace check still
fails, inspect the current service and its reported error before changing any
other application’s permissions. Do not use a broad `tccutil reset`.

## Updates and signing

Keep the installed app path, bundle identifier and signing identity stable.
Ad-hoc builds can have different code identities after replacement; macOS may
ask for access again. The guide cannot make grants permanent or replace code
signing. A locally signed build is not necessarily Developer ID notarized.
See `docs/local-stable-signing.md` in the source repository for the signing
contract and its limits.

References: [Apple file access guidance](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
and [Apple code signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/).
