# GitHub Intake Layer

This repository now treats GitHub issues, pull requests, and reviewer-routing metadata as one intake surface instead of
separate ad-hoc markdown fragments.

## Web Intake

- Web issue creation uses structured forms under `.github/ISSUE_TEMPLATE/`.
- Blank issues are disabled in the GitHub UI so new intake starts from one of the repository's supported shapes.
- Web PR creation keeps `.github/pull_request_template.md` as the default automation-friendly template.
- Specialized PR variants live under `.github/PULL_REQUEST_TEMPLATE/`:
  - `agent-maintenance.md`
  - `workflow-policy.md`
  - `human-change.md`

## Wiki Portal

- The GitHub wiki is the public docs portal: <https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/wiki>
- The wiki is for navigation and summaries; checked-in repo docs remain authoritative.
- The published wiki pages live in the separate wiki backing repo:
  <https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action.wiki.git>
- Every wiki page should include an `Authoritative repo docs` section pointing back to the repo.
- The maintained contract for this split lives in
  [`docs/knowledgebase/GitHub-Wiki-Portal.md`](./GitHub-Wiki-Portal.md).

## CLI Intake

When agents or operators create issues and PRs from the terminal, the repository favors generated markdown bodies over
hand-written ad-hoc text.

The supported issue forms, PR templates, contact links, and common route recommendations now live in the
machine-readable catalog `tools/priority/github-intake-catalog.json`. Future agents should consult that catalog first
instead of inferring the correct path from prose alone.

- Route discovery:

  ```powershell
  pwsh -File tools/Resolve-GitHubIntakeRoute.ps1 -ListScenarios
  pwsh -File tools/Resolve-GitHubIntakeRoute.ps1 -Scenario workflow-policy
  ```

- Scenario-driven draft generation:

  ```powershell
  pwsh -File tools/New-GitHubIntakeDraft.ps1 -Scenario workflow-policy -OutputPath issue-body.md
  pwsh -File tools/New-GitHubIntakeDraft.ps1 -Scenario human-pr -Issue 921 -OutputPath pr-body.md
  ```

  For PR scenarios, the draft helper can auto-populate the issue title, issue URL, and standing-priority marker from
  the current issue snapshot under `tests/results/_agent/issue/`, so future agents do not need to restate that context
  after bootstrap has already synced it. When an explicit issue is outside the standing-priority cache, the helper also
  falls back to `gh issue view` so non-standing issue PRs still hydrate title/URL cleanly on a fresh clone.

- Default dry-run execution plan:

  ```powershell
  pwsh -File tools/Invoke-GitHubIntakeScenario.ps1 -Scenario workflow-policy -Title "GitHub Intake: execution planner"
  pwsh -File tools/Invoke-GitHubIntakeScenario.ps1 -Scenario human-pr -Issue 923 -AsJson
  ```

  This helper reads the new machine-readable `execution` block from the catalog and emits a default dry-run execution
  plan before anything mutates GitHub state. Use `-Apply` only when the plan is correct. Issue routes still require an
  explicit title input, while PR routes can derive issue context from the current snapshot and branch state.

- Atlas report generation:

  ```powershell
  pwsh -File tools/Write-GitHubIntakeAtlas.ps1
  ```

  This writes a Markdown and JSON atlas under `tests/results/_agent/intake/` so humans and future agents can inspect
  the entire supported intake surface from one artifact instead of opening each template file individually.

- Project portfolio field application:

  ```powershell
  node tools/npm/run-script.mjs priority:project:portfolio:apply -- `
    --url https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/948 `
    --use-config

  node tools/npm/run-script.mjs priority:project:portfolio:apply -- `
    --url https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/948 `
    --status "In Progress" `
    --program "Shared Infra" `
    --phase "Helper Workflow" `
    --environment-class "Infra" `
    --blocking-signal "Scope" `
    --evidence-state "Ready" `
    --portfolio-track "Agent UX"
  ```

  The helper reads the checked-in field catalog from `tools/priority/project-portfolio.json`, adds the issue/PR to
  project `LabVIEW-Community-CI-CD#2` when missing, applies the requested single-select fields through the GitHub
  GraphQL API, and writes `tests/results/_agent/project/portfolio-apply-report.json`. Live apply mode now resolves the
  target through a resource-scoped project lookup, batches single-select mutations into one GraphQL call, and reuses the
  post-apply verification payload instead of reloading the full board. The report still includes a projected post-apply
  snapshot plus normalized board context for built-in metadata such as `Type`, `Milestone`, `Reviewers`, linked PRs,
  parent issue, and `Sub-issues progress`, so future agents do not need a second board scrape just to reason about
  intake state. Use this instead of ad hoc `gh project item-add` plus repeated `gh project item-edit` sequences.

- Canonical GitHub metadata application:

  ```powershell
  node tools/npm/run-script.mjs priority:github:metadata:apply -- `
    --url https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/949 `
    --issue-type Feature `
    --milestone "LabVIEW CI Platform v1 (2026Q2)"

  node tools/npm/run-script.mjs priority:github:metadata:apply -- `
    --url https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/950 `
    --assignee svelderrainruiz `
    --reviewer copilot-swe-agent `
    --reviewer LabVIEW-Community-CI-CD/maintainers
  ```

  This helper mutates the real issue/PR metadata future agents actually reason about: issue type, milestone,
  assignees, requested reviewers, parent issue linkage, and sub-issue linkage. It writes
  `tests/results/_agent/issue/github-metadata-apply-report.json` with requested, resolved, projected, observed, and
  verification state. Inputs are explicit by design: passing assignees/reviewers/sub-issues means the full desired set
  for that surface, while `--clear-*` flags intentionally drive the empty state.

- Issue bodies:

  ```powershell
  pwsh -File tools/New-IssueBody.ps1 -Template feature-program -OutputPath issue-body.md
  gh issue create --title "<title>" --body-file issue-body.md
  ```

- Issue comments:

  ```powershell
  pwsh -File tools/Post-IssueComment.ps1 -Issue 875 -BodyFile issue-comment.md
  gh issue comment 875 --body-file issue-comment.md
  ```

- PR bodies:

  ```powershell
  pwsh -File tools/New-PullRequestBody.ps1 -Template workflow-policy -Issue 875 `
    -IssueTitle "Epic: modernize the GitHub intake layer for future agents" `
    -IssueUrl "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/875" `
    -Base develop -Branch issue/875-modernize-github-intake-layer -OutputPath pr-body.md
  node tools/npm/run-script.mjs priority:pr -- --issue <number> --repo <owner/repo> --branch <branch> --base <base> --title "<title>" --body-file pr-body.md
  ```

- Branch + PR bootstrap:

  ```powershell
  pwsh -File tools/Branch-Orchestrator.ps1 -Issue 875 -Execute -PRTemplate workflow-policy
  ```

The helper script derives the PR title from linked issue metadata when available, falls back to the current branch's
head commit subject when necessary, and then calls `priority:pr` with the rendered intake document. For user-owned
forks, the helper still routes through `gh pr create`. For same-owner renamed forks, it switches to GitHub GraphQL
`createPullRequest` with `headRepositoryId` so future agents do not need an upstream-mirror workaround just to open
the PR. Use `--head-remote origin|personal` (or `AGENT_PRIORITY_ACTIVE_FORK_REMOTE`) when the local clone can push to
multiple forks, and use `priority:issue:mirror` when you need a fork-local standing issue that still points back to the
upstream child issue. When the branch is tied to a non-standing issue, pass `--issue <number>` so the helper does not
need to infer intent from the standing-priority cache.

## Idle Repository Mode

The standing-priority intake layer now distinguishes between:

- a real standing issue
- a misconfigured standing lane (missing/duplicate labels)
- an intentionally idle repository with zero open issues

When sync writes `tests/results/_agent/issue/no-standing-priority.json` with
`reason = queue-empty`, treat that as a first-class idle state. Bootstrap should
complete, the router should expose `issue = null`, and helpers that open new
standing-priority branches/PRs should stop with a clear message instead of
inventing a null issue context. The correct next action is to create or label
the next tracked issue, then rerun bootstrap. Future-agent handoff helpers
should also honor this mode: `tools/Print-AgentHandoff.ps1` should emit an idle
summary and copy the queue-empty report instead of treating stale numeric
snapshots as a cache mismatch.

## Agent Metadata Contract

Automation-authored PRs still use the `Agent Metadata` block:

- `Agent-ID`
- `Operator`
- `Reviewer-Required`
- `Emergency-Bypass-Label`

Reviewer routing currently treats the `Agent-ID:` marker as the machine-usable signal that the PR is automation-authored.
Human-authored PRs should use the `human-change` template so they do not accidentally opt into the agent-review flow.

## Intake Strategy

- Use issue forms for web-first intake because they keep headings and evidence prompts consistent.
- Use `tools/New-IssueBody.ps1` for CLI issue creation because `gh issue create` does not consume GitHub issue forms.
- Use the default PR template for normal standing-priority maintenance work.
- Use the `workflow-policy` PR template when the main review focus is permissions, required checks, queue behavior, or
  reviewer-routing semantics.
- Use the `human-change` PR template when the PR is not automation-authored and should not carry the agent metadata
  contract.
- Prefer `priority:pr` with explicit `--title` plus `--body-file` over raw `gh pr create --fill`; the title/body
  contract stays deterministic, avoids GitHub CLI flag conflicts, and keeps same-owner fork PR creation on one helper
  path.
- Use the wiki as a public portal for discoverability, not as a substitute for checked-in docs.
- Prefer the checked-in intake catalog plus `Resolve-GitHubIntakeRoute.ps1` when deciding which supported issue or PR
  surface to use.
- Prefer `New-GitHubIntakeDraft.ps1` when you want a single scenario-led entrypoint that renders the correct issue or
  PR draft from the catalog.
- Prefer `Invoke-GitHubIntakeScenario.ps1` when you want the planner/apply surface for future agents; it emits a
  structured execution plan, keeps dry-run as the default mode, and only performs the route's GitHub mutation when
  `-Apply` is explicit. Use `-HeadRemote origin|personal` (and `-ForkRemote ...` for branch orchestration routes) when
  the PR should open from a specific fork without an upstream mirror branch.
- Prefer `priority:project:portfolio:apply` when you need deterministic project-field stamping for issues or PRs; the
  board remains a visibility layer, but the helper removes the manual CLI mutation seam and emits richer built-in board
  metadata for future-agent routing.
- Prefer `priority:github:metadata:apply` when the source of truth must change on the issue or PR itself. Use it for
  issue type, milestone, assignee, reviewer, parent, and sub-issue mutations; do not try to treat project board fields
  as a substitute for those canonical surfaces.
- Use `Write-GitHubIntakeAtlas.ps1` when you need a single human-readable and machine-readable snapshot of the entire
  intake layer.

## Mixed-Shell Guidance

For issue creation, issue comments, and PR creation in mixed WSL/Windows shells, prefer `--body-file` over inline
multiline `--body` strings. For issue comments, prefer `tools/Post-IssueComment.ps1` so PowerShell lanes always route
through a temporary or explicit body file. That keeps quoting deterministic and aligns with the guidance in
`AGENTS.md`.
