<!-- markdownlint-disable-next-line MD041 -->
# Agent Handbook

This document summarizes the expectations for automation agents working in the
`compare-vi-cli-action` repository. The style mirrors the reflowed `README.md` so
`markdownlint` remains quiet (120-column guideline, explicit headings, blank-line buffers).

## Primary directive

- The standing priority is whichever issue carries the `standing-priority` label. Run
  `npm run priority:sync` at session start so `.agent_priority_cache.json` and
  `tests/results/_agent/issue/` reflect the latest snapshot; treat that issue as the top objective for
  edits, CI runs, and PRs.
- The human operator is signed in with an admin GitHub token; assume privileged operations
  (labels, reruns, merges) are allowed when safe.
- Default behaviour:
  - Operate inside this repository unless the human asks otherwise.
  - Keep workflows deterministic and green.
  - Reference `#127` in commit and PR descriptions.
- First actions in a session:
  1. `npm run priority:sync` to refresh the standing-priority snapshot and router artifacts.
  2. Review `.agent_priority_cache.json` / `tests/results/_agent/issue/` for tasks, acceptance, and
     linked PRs on the standing issue.
  3. Create or sync a working branch (`issue/<standing-number>-<slug>`), push minimal changes,
     dispatch CI, update the PR (reference `#<standing-number>`), monitor to green, merge when
     acceptance is met.

## Repository layout

- `scripts/` – PowerShell modules and shims (prefer `Import-Module`, avoid dot-sourcing).
- `tools/` – local/CI utilities; telemetry collectors; workflow helpers.
- `tests/` – Pester v5 suites (`Unit`, `Integration`); use `$TestDrive` for temp files.
- `.github/workflows/` – self-hosted and hosted pipelines; see README for highlights.
- `Invoke-PesterTests.ps1` – entry point for local runs and CI orchestration.

## Build / test / develop

- Unit tests: `./Invoke-PesterTests.ps1`
- Integration: `./Invoke-PesterTests.ps1 -IntegrationMode include`
- Custom paths: `./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results`
- Pattern filter: `./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI.*'`
- Quick smoke: `./tools/Quick-DispatcherSmoke.ps1 -Keep`
- Containerized non-LV checks: `pwsh -File tools/Run-NonLVChecksInDocker.ps1`

## Coding style

- PowerShell 7+, Pester v5+. Match surrounding indentation (2–4 spaces).
- Avoid nested `pwsh`; use in-process execution or `ProcessStartInfo` with `UseShellExecute=false`.
- Call **LVCompare** only (canonical path under Program Files). Do not launch `LabVIEW.exe` directly.
- CI is non-interactive; avoid prompts and pop-ups.

## Testing guidelines

- Shadow helpers inline inside `It {}` blocks, then remove.
- Keep integration tests isolated; unit tests should be fast.
- Standard results live under `tests/results/` (summary JSON, XML, session index).

## Wire probes (Long-Wire v2)

- Probes are injected by `tools/workflows/update_workflows.py`.
- Toggle with repo variable `WIRE_PROBES=0` (default enabled).
- Phase markers (`_wire/phase.json`):
  - `J1` / `J2` – before/after checkout.
  - `T1` – before Pester categories.
  - `C1` / `C2` – fixture drift job.
  - `I1` / `I2` – invoker start/stop.
  - `S1` – session index post.
  - `G0` / `G1` – runner unblock guard.
  - `P1` – final summary append.
- Inspect `_wire` directories or step summaries for timing markers.

## Commits & PRs

- Keep commits focused; include `#127` in subjects.
- PRs should describe rationale, list affected workflows, and link to artifacts.
- Ensure CI is green (lint + Pester). Verify no lingering processes on self-hosted runners.

## Local gates (pre-push)

- Run `tools/PrePush-Checks.ps1` before pushing:
  - Installs `actionlint` (`vars.ACTIONLINT_VERSION`, default 1.7.7) if missing.
  - Runs `actionlint` across `.github/workflows`.
  - Optionally round-trips YAML with `ruamel.yaml` (if Python available).
- Optional hook workflow:
  1. `git config core.hooksPath tools/hooks`
  2. Copy `tools/hooks/pre-push.sample` to `tools/hooks/pre-push`
  3. The hook runs the script and blocks on failure.

## Optional hooks (developer opt-in)

- `tools/hooks/pre-commit.sample`
  - Runs PSScriptAnalyzer (if installed) on staged PS files.
  - Warns on inline `-f` and dot-sourcing.
  - Blocks on analyzer errors.
- `tools/hooks/commit-msg.sample`
  - Enforces subject ≤100 characters and issue reference (e.g., `(#127)`) unless `WIP`.

## Required checks (develop/main)

- Set `Validate` as a required status on `develop`.
- One-time GitHub CLI snippet (admin only):

  ```bash
  gh api repos/$REPO/branches/develop/protection \
    -X PUT \
    -f required_status_checks.strict=true \
    -f required_status_checks.contexts[]=Validate \
    -H "Accept: application/vnd.github+json"
  ```

## Branch protection contract (#118)

- Canonical required-status mapping lives in `tools/policy/branch-required-checks.json` (hash = contract digest).
- `tools/Update-SessionIndexBranchProtection.ps1` injects the verification block into `session-index.json` and emits a step-summary entry.
- When running smoke tests locally:
  ```powershell
  pwsh -File tools/Quick-DispatcherSmoke.ps1 -PreferWorkspace -ResultsPath .tmp/sessionindex
  pwsh -File tools/Update-SessionIndexBranchProtection.ps1 -ResultsDir .tmp/sessionindex `
    -PolicyPath tools/policy/branch-required-checks.json `
    -Branch (git branch --show-current)
  ```
- Confirm `session-index.json` contains `branchProtection.result.status = "ok"`; mismatches should be logged in `branchProtection.notes`.
- If CI reports `warn`/`fail`, inspect the Step Summary and the session index artifact from that job. Update branch protection or the mapping file as needed to realign.

## Workflow maintenance

Use `tools/workflows/update_workflows.py` for mechanical updates (comment-preserving).

- Suitable tasks:
  - Add hosted Windows notes.
  - Inject `session-index-post` steps.
  - Normalize Runner Unblock Guard placement.
  - Adjust pre-init `force_run` gates.
- Avoid for logical edits (needs graphs, job logic). Modify manually, then run `actionlint`.
- Usage:

  ```bash
  python tools/workflows/update_workflows.py --check .github/workflows/ci-orchestrated.yml
  python tools/workflows/update_workflows.py --write .github/workflows/ci-orchestrated.yml
  ./bin/actionlint -color
  ```

## Agent hand-off & telemetry

- Keyword **handoff**:
  1. Read `AGENT_HANDOFF.txt`, confirm plan.
  2. Set safe env toggles:
     - `LV_SUPPRESS_UI=1`
     - `LV_NO_ACTIVATE=1`
     - `LV_CURSOR_RESTORE=1`
     - `LV_IDLE_WAIT_SECONDS=2`
     - `LV_IDLE_MAX_WAIT_SECONDS=5`
  3. Rogue scan: `pwsh -File tools/Detect-RogueLV.ps1 -ResultsDir tests/results -LookBackSeconds 900 -AppendToStepSummary`
  4. Sweep LVCompare (only) if rogues found and human approves.
  5. Honour pause etiquette (“brief delay (~90 seconds)”) and log waits.
  6. Execute “First Actions for the Next Agent” from `AGENT_HANDOFF.txt`.
- Convenience helpers:
  - `pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles`
  - `pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim`
    - Prints a concise watcher summary (state, heartbeatFresh, needsTrim) and
      emits a compact JSON block to `tests/results/_agent/handoff/watcher-telemetry.json`.
    - When `-AutoTrim` (or `HANDOFF_AUTOTRIM=1`) is set, trims oversized watcher logs if eligible
      and appends notes to the GitHub Step Summary when available.
    - Each invocation also drops a session capsule under `tests/results/_agent/sessions/`
      (schema `agent-handoff/session@v1`) capturing branch/head/status snapshots for determinism.
- Capture quick regression coverage with `npm run priority:handoff-tests`; the script runs
  `priority:test`, `hooks:test`, and `semver:check`, then writes `tests/results/_agent/handoff/test-summary.json`
  so subsequent agents (or CI summaries) can replay the outcomes.

## Fast path for issue #127

- PR comment dispatch: `/run orchestrated single include_integration=true sample_id=<id>`
- CLI dispatch: `pwsh -File tools/Dispatch-WithSample.ps1 ci-orchestrated.yml -Ref develop -IncludeIntegration true`
- Merge policy: once required checks pass and acceptance criteria satisfied, merge (admin token available).

## Single-strategy fallback

- `probe` job detects interactivity.
- `windows-single` runs only when `probe.ok == true`.
- If `strategy=single` but `probe.ok == false`, fall back to `pester-category`.
- Hosted preflight remains notice-only for LVCompare presence.

## Re-run with same inputs

- Summaries include a copy/pastable `gh workflow run` command.
- Comment snippets documented in `.github/PR_COMMENT_SNIPPETS.md`.

## Watching orchestrated runs

- Prefer the REST watcher when monitoring workflows: `npm run ci:watch:rest -- --run-id <id>` streams job status and exits non-zero if
  the run fails. Passing `--branch <name>` auto-selects the latest run. The VS Code task “CI Watch (REST)” prompts for a run id.
- Use the Docker watcher (`tools/Watch-InDocker.ps1`) when you need dispatcher logs or artifact download mirrors. Both watchers honor
  `GH_TOKEN`/`GITHUB_TOKEN` and fall back to `C:\github_token.txt` on Windows.
- Keep watcher summaries in `tests/results/_agent/` up to date so downstream agents inherit telemetry context.
- `tools/Update-SessionIndexWatcher.ps1` merges `watcher-rest.json` into `session-index.json`, exposing the REST watcher status under
  the `watchers.rest` node. Run it after the watcher step if you update the workflow or run the watcher manually.

## LVCompare observability

- Notices are written to `tests/results/_lvcompare_notice/notice-*.json` (phases: pre-launch,
  post-start, completed, post-complete).
- `tools/Detect-RogueLV.ps1` checks for untracked LVCompare/LabVIEW processes.
- Environment safeguards: `LV_NO_ACTIVATE=1`, `LV_CURSOR_RESTORE=1`, `LV_IDLE_WAIT_SECONDS=2`,
  `LV_IDLE_MAX_WAIT_SECONDS=5`.

## Telemetry & wait etiquette

- Use `tools/Agent-Wait.ps1` to record wait windows:

  ```powershell
  . ./tools/Agent-Wait.ps1
  Start-AgentWait -Reason 'workflow propagation' -ExpectedSeconds 90
  # ... after human responds
  End-AgentWait
  ```

- Artifacts land in `tests/results/_agent/`. Summaries update automatically in CI.

## Troubleshooting quick links

- Rogue LVCompare: `tools/Detect-RogueLV.ps1 -FailOnRogue`
- Session lock: `docs/SESSION_LOCK_HANDOFF.md`
- Runbook: `docs/INTEGRATION_RUNBOOK.md`
- Fixture drift: `docs/FIXTURE_DRIFT.md`
- Loop mode: `docs/COMPARE_LOOP_MODULE.md`

## Vendor tool resolvers

Use the shared resolver module to locate vendor CLIs consistently across OSes and self-hosted runners. This avoids
PATH drift and issues like picking a non-Windows binary on Windows.

- Module: `tools/VendorTools.psm1`
- Functions:
  - `Resolve-ActionlintPath` – returns `bin/actionlint.exe` on Windows or `bin/actionlint` elsewhere.
  - `Resolve-MarkdownlintCli2Path` – returns local CLI from `node_modules/.bin` (cmd/ps1 on Windows).
  - `Get-MarkdownlintCli2Version` – reads installed or declared version (no network).
  - `Resolve-LVComparePath` – returns canonical `LVCompare.exe` under Program Files (Windows only).

Examples:

```powershell
# In tools/* scripts
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'VendorTools.psm1') -Force
$alPath = Resolve-ActionlintPath
$mdCli  = Resolve-MarkdownlintCli2Path
$mdVer  = Get-MarkdownlintCli2Version
```

```powershell
# In scripts/* modules (one directory up from tools/)
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'VendorTools.psm1') -Force
$lvCompare = Resolve-LVComparePath
```

Guidance:

- Prefer resolvers over hardcoded paths or PATH lookups in local scripts.
- For markdownlint, try `Resolve-MarkdownlintCli2Path`; only fall back to `npx --no-install` when necessary.
- For LVCompare, continue to enforce the canonical path; pass `-lvpath` to LVCompare and never launch `LabVIEW.exe`.
- Do not lint or link-check vendor documentation under `bin/`; scope link checks to `docs/` or ignore `bin/**`.

