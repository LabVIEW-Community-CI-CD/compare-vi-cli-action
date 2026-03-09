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
  after bootstrap has already synced it.

- Atlas report generation:

  ```powershell
  pwsh -File tools/Write-GitHubIntakeAtlas.ps1
  ```

  This writes a Markdown and JSON atlas under `tests/results/_agent/intake/` so humans and future agents can inspect
  the entire supported intake surface from one artifact instead of opening each template file individually.

- Issue bodies:

  ```powershell
  pwsh -File tools/New-IssueBody.ps1 -Template feature-program -OutputPath issue-body.md
  gh issue create --title "<title>" --body-file issue-body.md
  ```

- PR bodies:

  ```powershell
  pwsh -File tools/New-PullRequestBody.ps1 -Template workflow-policy -Issue 875 `
    -IssueTitle "Epic: modernize the GitHub intake layer for future agents" `
    -IssueUrl "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/875" `
    -Base develop -Branch issue/875-modernize-github-intake-layer -OutputPath pr-body.md
  gh pr create --title "<title>" --body-file pr-body.md
  ```

- Branch + PR bootstrap:

  ```powershell
  pwsh -File tools/Branch-Orchestrator.ps1 -Issue 875 -Execute -PRTemplate workflow-policy
  ```

The helper script derives the PR title from linked issue metadata when available, falls back to the current branch's
head commit subject when necessary, and then calls `gh pr create --title ... --body-file ...` with the rendered intake
document.

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
- Prefer explicit `--title` plus `--body-file` over `gh pr create --fill`; the title/body contract stays deterministic
  and avoids GitHub CLI flag conflicts.
- Use the wiki as a public portal for discoverability, not as a substitute for checked-in docs.
- Prefer the checked-in intake catalog plus `Resolve-GitHubIntakeRoute.ps1` when deciding which supported issue or PR
  surface to use.
- Prefer `New-GitHubIntakeDraft.ps1` when you want a single scenario-led entrypoint that renders the correct issue or
  PR draft from the catalog.
- Use `Write-GitHubIntakeAtlas.ps1` when you need a single human-readable and machine-readable snapshot of the entire
  intake layer.

## Mixed-Shell Guidance

For issue and PR creation in mixed WSL/Windows shells, prefer `--body-file` over inline multiline `--body` strings.
That keeps quoting deterministic and aligns with the guidance in `AGENTS.md`.
