# Codex account details — 0.36.11

The Codex row keeps two distinct actions inside each compact account chip. The checkmark shows or hides that account's conversations; the name opens a popover anchored to the chip. The hover tooltip summarizes the cached identity, authentication state and quota without starting a process or changing the selected management account.

The popover shows full account identity, plan, authentication status, conversation count, all available quota windows with remaining percentages and reset times, and a refresh action. Environment details expand on demand. Open CLI launches with that account's home and workspace; Open Desktop reuses or starts an instance whose home identity matches the account. Progress and results stay associated with the originating account.

Opening details may refresh data older than one minute; repeated clicks and failed attempts share the same throttle. Explicit refresh remains available. Unknown quota never becomes zero, failures preserve and label cached values, and a reached reset time requests confirmation by refresh rather than inventing a new allowance. Cached data and action feedback are cleared if the same home is discovered with a different account identity; late quota responses cannot overwrite the new identity.

Request generations also prevent old completions from clearing a replacement account's loading state or changing its action feedback. Unauthorized quota responses explain that the account needs to log in again without exposing raw server responses. The Terminal launcher captures AppleScript output so its JSON response remains valid.

Validation includes independent-account projection, mismatched and late responses, identity-change invalidation, stale/reset quota, loading/unknown/error states and hidden-account rejection. Synthetic renders cover ready, loading, cached failure, unknown and wide/narrow account rows. Native acceptance exercises the visibility/detail split, refresh, close/reopen, and account-specific launch actions. Local receipts and actual account observations remain outside the repository.
