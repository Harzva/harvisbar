# Explicit Codex card navigation

Codex conversation cards now show a labelled **Open Codex** button rather than
requiring users to discover the existing title link. Standard cards place it
next to the pin control; Sidechat cards use the second header row.

The button calls the existing account-scoped `openManagedThread` path. It does
not route through the globally selected management account or through Inspector.
Title navigation and all existing composer and footer actions remain available.
Card height and the shared input baseline are unchanged.

Verification covers the existing source-account and Desktop coordinator tests,
actual manager renders across themes and narrow windows, and native acceptance
using a synthetic conversation. No message needs to be sent to check navigation.
