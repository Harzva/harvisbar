# Harvis native workspace usability and themes

Harvis 0.38.0 makes the conversation manager easier to read and operate while
retaining the complete conversation cards restored in 0.37.1.

## Design decisions

- Keep the three source rows the user selected: Codex with its accounts, DSH
  with its configurations, and WorkBuddy with its sources. Short labels remain
  content-sized; selection, account details, quota, CLI and Desktop actions keep
  their existing owners.
- Keep input, Workbench and refresh visible. Group window pinning, docking and
  following under a native Window menu with explicit checked state.
- Put theme selection in the conversation manager as well as the existing
  theme entry points. Preserve all six existing theme identifiers; add Paper,
  Ink and Forest through the shared semantic palette and existing preference.
- Use the system font, readable titles, quieter metadata, restrained borders
  and consistent spacing. Project icons, tree indentation, breadcrumbs and
  labelled counts explain structure. Color remains supplementary.
- Use flat surfaces for the new themes in the manager, Desktop and menu-bar
  overview. Existing themes keep their previous color tokens and styling.
- Make search keyboard accessible with Command-F and an explicit clear action.
  A provider-open arrow and accessibility hint identify clickable session titles.

## Reuse boundaries

The structure and relationship layouts continue to inject
`managerThreadMatrixCard`. They do not replace it with a display-only row.
Codex and DSH composers, account-scoped draft identity, send eligibility,
Desktop routing, tags, pinning, task binding and Inspector actions remain owned
by their existing implementations. Theme changes do not start analysis, send
messages, change source filters or apply project organization.

The design guidance was reviewed from these pinned upstream sources:

- [Uncodixfy](https://github.com/cyxzdev/Uncodixfy/tree/e0e028058b5259debdd94b78147c6d6c77bf7da2):
  restrained surfaces, ordinary controls, less repetitive decorative chrome.
- [UI UX Pro Max 2.13.0](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/tree/4aad0584d92131626b16d4ff4d77f0455385013c):
  semantic colors, readable compact labels, accessible interaction and
  stack-specific guidance. The exact product search matched Developer Tool / IDE.
  Its generated documentation landing-page pattern was unsuitable for this
  native workspace and was excluded from the design.
- [AionUi](https://github.com/iOfficeAI/AionUi/tree/66c2e6d52348621dc07ae40ae2e63985373318a7):
  shared composer and separated project/session state, as documented in the
  [0.37.1 card correction](session-card-parity-0.37.1.md).

These skills are development tools. They add no external UI runtime, remote
fonts, analytics, sender or conversation database to the application.

## Acceptance

The full native suite passed 676 tests with three conditional skips. Final
targeted verification passed 153 tests with one conditional skip. Seven actual
manager renders cover all three new themes, a 640-point window, many accounts,
one selected account and no selected providers. Text, secondary text and accent
colors exceed 4.5:1 against each new theme's background, surface and alternate
surface; selection and positive text pairs also exceed 4.5:1.

Verify the new semantic text pairs against their actual surfaces, then render
the real manager with synthetic accounts and sessions in Paper, Ink and Forest.
Include a narrow window, many accounts, selected accounts and no selected
sources. Check native input controls and project navigation together.

In the installed app, verify theme changes, search focus/clear, source-account
details, Window menu state, project navigation, and full Codex/DSH card actions.
Use only a synthetic draft for editing and clear it afterward. Do not send real
messages or apply project organization for appearance acceptance. Preserve
existing source filters and organization state, and retain the previous app
bundle for rollback.
