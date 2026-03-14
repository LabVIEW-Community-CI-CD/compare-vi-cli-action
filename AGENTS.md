<!-- markdownlint-disable-next-line MD041 -->
# Agent Handbook

This file is the bounded agent entrypoint for `compare-vi-cli-action`.
Keep it short, stable, and focused on the contract every session needs.
Deep runbook material belongs in the referenced docs and machine-generated
artifacts under `tests/results/_agent/`.

## Primary Directive

- The top objective is the issue carrying the active standing-priority label for
  the current repository context:
  - canonical/upstream: `standing-priority`
  - forks: `fork-standing-priority` with fallback to `standing-priority`
- Start with `pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1` so the
  workspace is anchored to `develop` and the standing-priority cache/router are
  refreshed.
- Treat `queue-empty` as a valid idle state. If bootstrap emits
  `tests/results/_agent/issue/no-standing-priority.json` with
  `reason = queue-empty`, do not invent new work.
- The operator is signed in with an admin GitHub token. Privileged operations
  are allowed when they are safe and within repo policy.
- Reference `#<standing-number>` in automation-authored commits and PRs.
- Scope boundary: this repository is for compare-vi CLI action workflows only.
  LabVIEW icon editor development now lives in
  `svelderrainruiz/labview-icon-editor`.

## First Actions

1. Run `pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1`.
2. Inspect `.agent_priority_cache.json` and `tests/results/_agent/issue/`.
3. Run `node tools/npm/run-script.mjs priority:project:portfolio:check` when
   project-board visibility matters.
4. Run `node tools/npm/run-script.mjs priority:develop:sync` before creating or
   refreshing a work lane.
5. Work from a branch shaped like
   `issue/<fork-remote>-<standing-number>-<slug>` when a fork lane is involved.

## Core Commands

- Prefer sanitized wrappers:
  - `node tools/npm/cli.mjs <command>`
  - `node tools/npm/run-script.mjs <script>`
- Prefer `node tools/npm/run-script.mjs priority:pr` over raw `gh pr create`.
- Prefer `node tools/npm/run-script.mjs priority:validate -- --ref <branch>`
  over manual Validate dispatches.
- Prefer the local Docker/Desktop parity loop before spending repeated GitHub
  Actions cycles on the same defect class:
  - `pwsh -NoLogo -NoProfile -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage`
  - `pwsh -NoLogo -NoProfile -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage -NILinuxReviewSuite`
- Detached unattended delivery surfaces:
  - `node tools/npm/run-script.mjs priority:delivery:agent:ensure`
  - `node tools/npm/run-script.mjs priority:delivery:agent:status`
  - `node tools/npm/run-script.mjs priority:delivery:agent:stop`
- Codex state hygiene surfaces:
  - `node tools/npm/run-script.mjs priority:codex:state:hygiene`
  - `node tools/npm/run-script.mjs priority:codex:state:hygiene:apply`

## Workflow Maintenance

- `ruamel.yaml` is the canonical workflow rewrite engine for this repo.
- Python workflow mutation is confined to `tools/workflows/**`.
- Use `pwsh -File tools/Check-WorkflowDrift.ps1` as the supported operator
  entrypoint.
- Repo-native command surfaces are:
  - `node tools/npm/run-script.mjs workflow:drift:ensure`
  - `node tools/npm/run-script.mjs workflow:drift:check`
  - `node tools/npm/run-script.mjs workflow:drift:write`
  - `node tools/npm/run-script.mjs lint:md`
- The managed workflow set lives in `tools/workflows/workflow-manifest.json`.
- `python tools/workflows/update_workflows.py --check|--write ...` remains the
  low-level compatibility surface, not a free-form scripting escape hatch.

## Intake And PR Flow

- Use the GitHub intake catalog in
  `tools/priority/github-intake-catalog.json` before selecting issue forms or
  PR templates by hand.
- Prefer these helpers over ad-hoc GitHub CLI calls:
  - `pwsh -File tools/Resolve-GitHubIntakeRoute.ps1 -ListScenarios`
  - `pwsh -File tools/New-GitHubIntakeDraft.ps1 -Scenario <name> -OutputPath <path>`
  - `pwsh -File tools/Invoke-GitHubIntakeScenario.ps1 -Scenario <name> -AsJson`
  - `pwsh -File tools/Write-GitHubIntakeAtlas.ps1`
- Use `pwsh -File tools/Branch-Orchestrator.ps1 -Issue <number> -Execute` for
  branch + PR orchestration and switch templates with
  `-PRTemplate workflow-policy|human-change` when needed.
- `New-IssueBody.ps1` and `New-PullRequestBody.ps1` remain the lower-level body
  helpers; prefer the scenario-driven layer first.
- Treat the GitHub wiki as a curated portal only. Checked-in repo docs remain
  authoritative, and published wiki history lives in
  `LabVIEW-Community-CI-CD/compare-vi-cli-action.wiki.git`.
- Repo-owned GitHub instructions live under
  `.github/instructions/*.instructions.md`. Keep them aligned with the
  draft-only Copilot review contract: draft is the only Copilot iteration
  state, and `ready_for_review` means final validation / promotion intent only.
- Repo-owned Copilot CLI instructions live in `.github/copilot-instructions.md`.
  Use the local Copilot CLI review plane only for draft-review acceleration and
  keep hosted validation authoritative for final promotion.
- GitHub-native automatic Copilot review is intentionally disabled here.
  Hosted workflow policy must validate local review receipts and promotion
  state, not request a second GitHub-side Copilot pass.
- Instruction precedence for future agents:
  - `AGENTS.md` is the repo-wide policy and standing-priority authority.
  - `.github/copilot-instructions.md` narrows GitHub Copilot CLI behavior for
    the local draft-review plane only.
  - `.github/instructions/*.instructions.md` are GitHub-native phase overlays
    and must not widen review, queue, or promotion authority beyond `AGENTS.md`
    and `.github/copilot-instructions.md`.

## Working Rules

- Issues, labels, policy files, and checked-in docs are the source of truth.
  The project board is visibility only.
- Keep workflows deterministic and green. Required status contexts are defined
  in `tools/policy/branch-required-checks.json`.
- Use safe repo helpers instead of hand-rolled git mutation flows whenever a
  helper exists.
- For second and later review passes on markdown, workflow drift, NI Linux
  smoke, or VI history artifact quality, iterate locally through Docker
  Desktop first and use GitHub Actions for confirmation only after the local
  parity loop is green.
- For targeted VI History review on deep branches, prefer the Docker/Desktop
  single-VI path via `tools/Run-NonLVChecksInDocker.ps1` with
  `-NILinuxReviewSuiteHistoryTargetPath`,
  `-NILinuxReviewSuiteHistoryBranchRef`,
  `-NILinuxReviewSuiteHistoryBaselineRef`, and
  `-NILinuxReviewSuiteHistoryMaxCommitCount`. Read
  `tests/results/docker-tools-parity/review-loop-receipt.json` first after
  compaction; it now also mirrors the current requirements-verification state to
  `tests/results/_agent/verification/docker-review-loop-summary.json` and points to
  `tests/results/docker-tools-parity/ni-linux-review-suite/vi-history-review-loop-receipt.json`
  and the rest of the authoritative local review artifacts. The receipt now
  includes `git.headSha`, `git.branch`, and `git.upstreamDevelopMergeBase`; use
  those fields to confirm the local parity result belongs to the current branch
  head before trusting it. When the daemon is
  active, the same summary is mirrored into
  `tests/results/_agent/runtime/delivery-agent-state.json` and
  `tests/results/_agent/runtime/delivery-agent-lanes/*.json` under the
  `localReviewLoop` node so future agents can resume from runtime state before
  reopening deeper receipts.
- Keep bulky diagnostics out of source. Large logs and artifacts belong in
  issue attachments or generated artifact folders, not in committed history.
- Use vendor resolvers from `tools/VendorTools.psm1` rather than ad-hoc PATH
  lookups for `actionlint`, markdownlint, and LVCompare.
- For multiline GitHub bodies in mixed Windows/WSL shells, use `--body-file`.

## Handoff And Live State

- `AGENT_HANDOFF.txt` is the stable handoff entrypoint.
- `node tools/npm/run-script.mjs handoff:entrypoint:check` validates the
  handoff entrypoint and refreshes the machine-readable index at
  `tests/results/_agent/handoff/entrypoint-status.json`.
- `node tools/npm/run-script.mjs priority:handoff` prints the current handoff
  bundle, including that machine-readable index.
- Primary live-state artifacts:
  - `.agent_priority_cache.json`
  - `tests/results/_agent/issue/router.json`
  - `tests/results/_agent/issue/no-standing-priority.json`
  - `tests/results/_agent/handoff/entrypoint-status.json`
  - `tests/results/_agent/runtime/`

## References

- `docs/DEVELOPER_GUIDE.md`
- `docs/SESSION_LOCK_HANDOFF.md`
- `docs/INTEGRATION_RUNBOOK.md`
- `docs/RELEASE_OPERATIONS_RUNBOOK.md`
- `docs/knowledgebase/DOCKER_TOOLS_PARITY.md`
- `docs/knowledgebase/GitHub-Intake-Layer.md`
- `docs/knowledgebase/Agent-Handoff-Surfaces.md`
