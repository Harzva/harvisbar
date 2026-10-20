# Conversation actions in project views

## Regression and correction

HarvisBar 0.37.0 replaced the project view's existing conversation cards with
presentation-only rows. Their primary action selected the Inspector. The old
list still had its input controls and provider-specific open action, but the
new structure and relationship views did not expose the same operations.

HarvisBar 0.37.1 injects the existing `managerThreadMatrixCard` into both
project views. A conversation title opens its original provider session;
the inline composer and the separate Inspector action retain their existing
behavior. Tags, pinning, task binding, attention, context menus and source
indicators also come from that same card. The project tree, breadcrumbs,
properties and relationship projection remain in place.

The layout owns grouping and placement. The existing card owns its controls.
The existing Codex/DSH adapters own sending, draft state and Desktop routing.
No second sender, conversation database or Desktop launcher is introduced.

Card identity includes provider, source scope and source session ID. A layout
switch must not move a draft or command to another account. Codex input
visibility continues to follow the user's input/tag settings. Unsupported or
observation-only sessions retain their existing restrictions; a visible card
does not imply that every provider accepts inline commands.

## Reference and reuse

The reference source is [AionUi at 66c2e6d](https://github.com/iOfficeAI/AionUi/tree/66c2e6d52348621dc07ae40ae2e63985373318a7),
under Apache-2.0. Its relevant patterns are:

- A shared composer with backend-owned execution handlers:
  `packages/desktop/src/renderer/components/chat/SendBox/index.tsx`.
- Draft state keyed by backend and conversation:
  `packages/desktop/src/renderer/hooks/chat/useSendBoxDraft.ts`.
- Native deep-link delivery separated from validated renderer navigation:
  `packages/desktop/src/process/utils/deepLink.ts` and
  `packages/desktop/src/renderer/hooks/system/useDeepLink.ts`.
- Project-level state distinct from conversation-level state:
  `packages/desktop/src/renderer/components/layout/ProjectPanelHost.tsx`.

These are architectural references. This correction reuses Harvis's existing
SwiftUI card and native adapters; it copies no AionUi source or Electron runtime.

## Acceptance

Check list, structure and relationship views for the same applicable
conversation controls. Verify the title's provider-open route independently
from the Inspector action. Check a synthetic conversation's composer and
source identity, including an account switch and a view remount. Keep real
conversation drafts and organization assignments unchanged during acceptance.

Targeted regression coverage includes Desktop identity/window reuse,
source-bound sender drafts, send eligibility, composer visibility and project
hierarchy. Native acceptance must inspect the live card controls as well as
project navigation; navigation-only acceptance missed the 0.37.0 regression.
