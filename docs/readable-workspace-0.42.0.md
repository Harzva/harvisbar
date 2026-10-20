# Readable workspace and supervision scope — 0.42.0

The manager now offers small, medium, and large text from its header. Medium is the default: normal body text is 15 pt, compared with 13 pt in small and 18 pt in large. Secondary text has a minimum size of 11 / 13 / 15 pt. Cards, native message inputs, and their reserved slots grow with the selection. Other application windows retain their existing font unless they inherit the manager's size preference.

The project sidebar and workbench have draggable 12 pt divider targets, keyboard accessibility adjustment, and double-click reset. Workbench placement supports automatic, right, and bottom. Width and height preferences are retained separately. A narrow window clamps the visible pane sizes without overwriting saved dimensions; the sidebar can collapse into a popover. Layout reset changes layout preferences only.

Project management now explains its exact supervision scope and offers a searchable complete roster from the management snapshot. Each entry shows its source, session identity, inclusion status, and reason. Presentation filters do not determine the management roster. Child projects and adjacent directories are not implicitly included. Stale or disconnected records remain visible for inspection but cannot become dispatch candidates.

Codex main sessions and persisted subagents enter approval candidates only when the current projector allowlist and effective Enrollment permit them. A candidate still needs a valid task plan, evidence checks, and individual approval. Project-brain enabled state is shown independently. DSH and WorkBuddy entries are observation records for this project workflow. DSH's own Supervisor controls apply to exactly the selected DSH session; its scope explanation appears above the controls. A dedicated DSH analysis service is not a supervised target.

This release changes presentation, local appearance preferences, and read-only scope projection. It does not change provider dispatch authorization or enable any Supervisor.

Validation covers font mapping, composer geometry, split bounds and invalid persisted values, project/source matching, Enrollment exclusions, disconnected records, and exact child-project exclusion. Native render fixtures include 480 px and 640 px windows, all font sizes, complete large cards, and both workbench placements. Existing Supervisor behavior is included in regression testing.

Verification result: the full Swift suite passed 743 tests with 4 conditional skips and no failures. Subsequent UI-focused checks passed 13 tests with no failures and 15 tests with 1 conditional wire-fixture skip and no failures after the final row-height fixes. Native render review confirmed readable large text, complete card footer alignment, narrow account action visibility, both splitter orientations, and explicit DSH/session and Codex/project scope panels.
