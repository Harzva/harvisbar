# H.A.R.V.I.S. Jira Bridge Interface

The Jira bridge keeps Jira as an external issue tracker and H.A.R.V.I.S. as the
local execution control plane.

## Flow

```text
Jira issue JSON
  -> harvis_jira_bridge.py issue-to-work-item
  -> .harvis/inbox.md
  -> .harvis/outbox/*.md
  -> .harvis/runs/*.json
  -> .harvis/agent-room/tasks.jsonl
  -> approval / handoff / runner / review
  -> harvis_jira_bridge.py result-export
  -> .harvis/jira/exports/*.json
```

## Boundaries

- The bridge does not replace Jira issue tracking.
- The bridge does not write Jira by itself.
- The bridge does not create commits, push branches, deploy, or open PRs.
- Jira and GitHub writeback payloads are approval-gated.

## Commands

Import a Jira issue fixture:

```bash
python3 scripts/harvis_jira_bridge.py issue-to-work-item \
  --root <workspace-root> \
  --issue-json /path/to/issue.json
```

Generate a Jira-ready result export:

```bash
python3 scripts/harvis_jira_bridge.py result-export \
  --root <workspace-root> \
  --issue-key ABC-123 \
  --summary "Codex inspected the issue and produced a reviewed result."
```

Actual Jira REST calls should use the local `jira-minimal` skill helper after
explicit approval.

## GitHub Reuse

The bridge does not add another GitHub client. Reuse the existing local GitHub
skills and `gh` workflows:

```text
<github-skill-path>
github
gh-fix-ci
gh-address-comments
yeet
```

First-phase Jira exports may include `github_pr_ready`, but it must remain a
payload only. Commit, push, draft PR creation, and PR comment writes require a
separate explicit approval and should use the existing GitHub skill flow.
