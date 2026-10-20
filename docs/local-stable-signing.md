# Local HarvisBar signing and permission continuity

HarvisBar packaging uses `auto` by default. When the current user's
`~/Library/Application Support/Harvis/signing/local-signing.json` exists, it
pins the certificate fingerprint for `local.harzva.harvisbar`. The public
certificate is checked against both recorded fingerprints. The private key
stays in the login Keychain; credentials and machine signing configuration must
never enter Git, a provenance stage, or an app payload.

The app's explicit designated requirement includes the bundle identifier and
the pinned leaf certificate. It does not include the executable's changing
`cdhash`. Both app and DMG packaging reject `--sign-identity -` or another
identity when the local pin exists. Missing private keys cause signing to fail;
there is no ad-hoc retry. A malformed configuration also fails closed.
Without a pin, `auto` also fails; an unconfigured test machine must explicitly
request `--sign-identity -` to produce an ad-hoc candidate.

Use the existing provenance stage and app/DMG package entrypoints, omitting
`--sign-identity` or specifying `auto`. Existing provenance, receipt, entitlement,
signature-only derivative, and strict code-signature checks remain required.
`python3 scripts/harvis_local_signing.py verify --app <candidate.app>` additionally
checks the pinned identity and exact designated requirement. The DMG reuse path
performs this check too.

This local certificate is not Developer ID notarization, an Apple Team, or
authorization to activate a Network Extension. Local packaging retains the
existing ad-hoc system extension and runtime artifacts and their provenance
checks. It does not manufacture a Team ID or change system trust, Gatekeeper,
SIP, TCC databases, or privacy entitlements.

On migration from ad-hoc signing, macOS may require one fresh grant because the
old code-hash identity cannot match a new stable certificate identity. The user
may also need to authorize `codesign` to use the signing key in Keychain. Future
builds must preserve the certificate, bundle identifier, and designated
requirement. Keep the same formal app path when replacing/reinstalling it and
retain the prior app for rollback.

Existing grants normally have a stable identity to follow across updates and
reinstallation on the same Mac. This is not an irrevocable or universal grant:
permission resets/removal, a new user/Mac, changed signing identity, newly
requested resources, and macOS policy changes can require fresh consent. The
local non-extractable private key survives app replacement, but cannot be
recreated with the same identity if the Keychain is lost. Other Harvis apps have
different bundle identifiers and retain separate permissions.

Evidence must distinguish code identity continuity from actual TCC retention.
Test two different signed binaries against the same requirement, reject an
ad-hoc impostor with the same identifier, verify the real installed app, then
check the permitted resource through native UI after replacement. A successful
signature verification alone is not proof that macOS granted disk access.

Reference: [Apple TN2206: Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/).
