<!-- markdownlint-disable-next-line MD041 -->
# Agent Handbook

This is the bounded agent entrypoint for `compare-vi-cli-action`.
Keep it short, stable, and helper-oriented. Deep runbooks belong in checked-in docs or generated
`tests/results/_agent/` artifacts.

## Primary Directive

- The top objective is the issue carrying the active standing-priority label:
  - upstream: `standing-priority`
  - forks: `fork-standing-priority` with fallback to `standing-priority`
- Start every session with `pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1`.
- If bootstrap writes `tests/results/_agent/issue/no-standing-priority.json` with `reason = queue-empty`, treat the
  repo as intentionally idle until a real tracked issue exists. If release summary evidence also shows an RC build,
  evaluate `node tools/npm/run-script.mjs priority:pivot:template`; only a future agent may pivot to
  `LabviewGitHubCiTemplate` when that report is `ready`.
- The operator token is admin-capable; privileged GitHub actions are allowed when they are safe and policy-aligned.
- Reference `#<standing-number>` in automation-authored commits and PRs.
- Scope boundary: this repo is for compare-vi CLI action workflows only. LabVIEW icon editor development lives in `svelderrainruiz/labview-icon-editor`.

## First Actions

1. Run `pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1`.
2. Inspect `.agent_priority_cache.json` and `tests/results/_agent/issue/`.
3. Run `node tools/npm/run-script.mjs priority:project:portfolio:check` when project-board visibility matters.
4. Run `node tools/npm/run-script.mjs priority:develop:sync` before creating or refreshing a work lane.
5. Work from a clean branch shaped like `issue/<fork-remote>-<standing-number>-<slug>` when a fork lane is involved.

## Core Commands

- Prefer sanitized wrappers: `node tools/npm/cli.mjs <command>` and `node tools/npm/run-script.mjs <script>`.
- Prefer `node tools/npm/run-script.mjs priority:pr` over raw `gh pr create`.
- Prefer `node tools/npm/run-script.mjs priority:validate -- --ref <branch>` over manual Validate dispatches.
- Prefer the local parity loop before repeated GitHub Actions cycles:
  - `pwsh -NoLogo -NoProfile -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage`
  - `pwsh -NoLogo -NoProfile -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage -NILinuxReviewSuite`
  - Treat `tools/PrePush-Checks.ps1` as the blocking rendered-review gate and `-NILinuxReviewSuite` as the broad
    flag-combination certification lane.
- Detached unattended delivery surfaces:
  - `node tools/npm/run-script.mjs priority:delivery:agent:ensure`
  - `node tools/npm/run-script.mjs priority:delivery:agent:status`
  - `node tools/npm/run-script.mjs priority:delivery:agent:stop`
- Codex state hygiene surfaces:
  - `node tools/npm/run-script.mjs priority:codex:state:hygiene`
  - `node tools/npm/run-script.mjs priority:codex:state:hygiene:apply`

## Workflow Maintenance

- `ruamel.yaml` is the canonical workflow rewrite engine; Python workflow mutation is confined to `tools/workflows/**`.
- Use `pwsh -File tools/Check-WorkflowDrift.ps1` as the supported operator entrypoint.
- Repo-native workflow surfaces:
  - `node tools/npm/run-script.mjs workflow:drift:ensure`
  - `node tools/npm/run-script.mjs workflow:drift:check`
  - `node tools/npm/run-script.mjs workflow:drift:write`
  - `node tools/npm/run-script.mjs lint:md`
- The managed workflow set lives in `tools/workflows/workflow-manifest.json`.
- `python tools/workflows/update_workflows.py --check|--write ...` is the low-level compatibility surface only.

## Intake And PR Flow

- Use `tools/priority/github-intake-catalog.json` before selecting issue forms or PR templates by hand.
- Prefer these helper surfaces over ad-hoc GitHub CLI calls:
  - `pwsh -File tools/Resolve-GitHubIntakeRoute.ps1 -ListScenarios`
  - `pwsh -File tools/New-GitHubIntakeDraft.ps1 -Scenario <name> -OutputPath <path>`
  - `pwsh -File tools/Invoke-GitHubIntakeScenario.ps1 -Scenario <name> -AsJson`
  - `pwsh -File tools/Write-GitHubIntakeAtlas.ps1`
- Use `pwsh -File tools/Branch-Orchestrator.ps1 -Issue <number> -Execute -PRTemplate workflow-policy|human-change`
  when the review surface needs a non-default template.
- `New-IssueBody.ps1` and `New-PullRequestBody.ps1` remain the lower-level body helpers.
- Treat the GitHub wiki as a curated portal only. Checked-in repo docs remain authoritative.
- Repo-owned GitHub instructions live under `.github/instructions/*.instructions.md`, and repo-owned Copilot CLI
  instructions live in `.github/copilot-instructions.md`.
- `AGENTS.md` is the repo-wide policy and standing-priority authority.
- Under the draft-only Copilot review contract, use local Copilot CLI review plane only for draft-review acceleration.
- Draft is the only Copilot iteration state here; `ready_for_review` means final validation and promotion intent only.
- After `ready_for_review`, do not request or wait for a second GitHub-side Copilot pass; return to draft if the head changes.
- GitHub-native automatic Copilot review is disabled here; hosted policy validates local review receipts instead of
  requesting another GitHub-side Copilot pass.
- These instruction overlays must not widen review, queue, or promotion authority.

## Working Rules

- Issues, labels, policy files, and checked-in docs are the source of truth; the project board is visibility only.
- Keep workflows deterministic and green. Required status contexts live in `tools/policy/branch-required-checks.json`.
- Use safe repo helpers instead of ad-hoc git mutation when a helper exists.
- For repeat passes, iterate locally through Docker Desktop first.
- Before trusting prior local review evidence, verify the current branch head against
  `tests/results/docker-tools-parity/review-loop-receipt.json`,
  `tests/results/_agent/verification/docker-review-loop-summary.json`, or daemon-mirrored `localReviewLoop` state.
- Confirm receipt freshness with `git.headSha`, `git.branch`, and `git.upstreamDevelopMergeBase`, not head SHA alone.
- Keep bulky diagnostics out of source; prefer issue attachments or generated artifact folders.
- Use vendor resolvers from `tools/VendorTools.psm1` rather than ad-hoc PATH lookups.
- For multiline GitHub bodies in mixed Windows/WSL shells, use `--body-file`.
  For issue comments, prefer `pwsh -File tools/Post-IssueComment.ps1 -Issue <number> -BodyFile <path>`
  over inline `gh issue comment --body "..."`.

## Handoff And Live State

- `AGENT_HANDOFF.txt` is the stable handoff entrypoint.
- `node tools/npm/run-script.mjs handoff:entrypoint:check` refreshes the machine-readable index at `tests/results/_agent/handoff/entrypoint-status.json`.
- `node tools/npm/run-script.mjs priority:handoff` prints that machine-readable index and
  `tests/results/_agent/verification/docker-review-loop-summary.json`.
- `node tools/npm/run-script.mjs priority:continuity` refreshes the continuity receipts at
  `tests/results/_agent/runtime/continuity-telemetry.json` and
  `tests/results/_agent/handoff/continuity-summary.json`.
- `node tools/npm/run-script.mjs priority:pivot:template` evaluates the future-agent-only pivot from queue-empty
  release-candidate state into `LabviewGitHubCiTemplate`.
- Primary live-state artifacts:
  - `.agent_priority_cache.json`
  - `tests/results/_agent/issue/router.json`
  - `tests/results/_agent/issue/no-standing-priority.json`
  - `tests/results/_agent/handoff/continuity-summary.json`
  - `tests/results/_agent/handoff/entrypoint-status.json`
  - `tests/results/_agent/runtime/`

## Local Gates

- `tools/PrePush-Checks.ps1` consumes `tools/policy/prepush-known-flag-scenarios.json`.
- Exactly one active scenario pack is allowed in that checked-in contract at a time.
- Deterministic top-level receipts:
  - `tests/results/_agent/pre-push-ni-image/known-flag-scenario-report.json`
  - `tests/results/_agent/pre-push-ni-image/post-results-rendering-certification-report.json`
  - `tests/results/_agent/pre-push-ni-image/transport-smoke-report.json`
  - `tests/results/_agent/pre-push-ni-image/vi-history-smoke-report.json`
- The post-results rendering certification report is the explicit semantic gate for the
  active scenario pack; transport and VI-history reports remain separate support lanes.
- The pre-push transport smoke lane is intentionally minimal. Broad flag-combination sweeps now belong in
  `tests/results/docker-tools-parity/ni-linux-review-suite/flag-combination-certification.json` and the companion
  Markdown/HTML artifacts emitted by `tools/Invoke-NILinuxReviewSuite.ps1`.

## References

- `docs/DEVELOPER_GUIDE.md`
- `docs/SESSION_LOCK_HANDOFF.md`
- `docs/INTEGRATION_RUNBOOK.md`
- `docs/RELEASE_OPERATIONS_RUNBOOK.md`
- `docs/knowledgebase/DOCKER_TOOLS_PARITY.md`
- `docs/knowledgebase/GitHub-Intake-Layer.md`
- `docs/knowledgebase/Agent-Handoff-Surfaces.md`
