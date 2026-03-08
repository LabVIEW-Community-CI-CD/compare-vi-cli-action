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

## Mixed-Shell Guidance

For issue and PR creation in mixed WSL/Windows shells, prefer `--body-file` over inline multiline `--body` strings.
That keeps quoting deterministic and aligns with the guidance in `AGENTS.md`.
