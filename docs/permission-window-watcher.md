# Harvis Permission Window Watcher

HarvisBar and HarvisDesk expose an opt-in local helper for Harvis-attributed
macOS access dialogs. It uses a user-captured image template as the primary
detector and remains disabled after every app launch.

## Setup

1. Open the **System** section in HarvisBar, or the control rail in HarvisDesk.
2. Choose **请求授权** and grant Screen Recording plus Accessibility to the
   installed, stably signed HarvisBar/HarvisDesk app.
3. When the target dialog is visible, choose **截取模板** and tightly select the
   complete foreground dialog. Do not select only the Allow button and do not
   include the changing background application.
4. Use **检测一次** while the dialog is visible. Confirm that Harvis reports a
   stable match above 90%.
5. Enable **监视** for detect-only operation. Enable **自动点击** only when the
   current task explicitly permits this local assistance.

Templates and the redacted event ledger stay under the current user's
Application Support directory. They are not copied into the plugin repository,
profile, workspace, or public release artifacts.

## Mandatory action gates

Every automatic action must pass all of these gates:

- the user enabled the watcher in the current app session;
- keyboard and pointer activity have both been idle for the configured period;
- Screen Recording and Accessibility are currently authorized;
- the frontmost candidate window matches a local template at 90% or higher for
  three consecutive samples;
- accessible dialog text contains `harvis` or `H.A.R.V.I.S.` and access-related
  wording;
- the same accessible window exposes a button titled exactly `允许` or `Allow`;
- the 30-second cooldown and three-actions-per-ten-minutes limit permit action.

The watcher presses the verified Accessibility button. It does not inject a
blind coordinate click. Single-action mode stops immediately after a successful
press; continuous mode is a separate explicit toggle.

## Safety boundary

This helper is a human-enabled foreground assistance mode, not part of the
unattended Level 1 tick/runtime authority. It must never broaden matching to a
generic Allow button, infer approval from a theme or runtime state, auto-enable
itself at login, or store captured dialog text in the audit ledger.

If a macOS update, display scale, language, appearance, or signing identity
changes the dialog, capture a new template and repeat detect-only calibration.
