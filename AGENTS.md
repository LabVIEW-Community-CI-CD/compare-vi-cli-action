<!-- markdownlint-disable-next-line MD041 -->
# Agent Handbook

This document summarizes the expectations for automation agents working in the
`compare-vi-cli-action` repository. The style mirrors the reflowed `README.md` so
`markdownlint` remains quiet (120-column guideline, explicit headings, blank-line buffers).

## Primary directive

- Issue **#88** is the standing priority. Treat progress on #88 as the top objective for edits,
  CI runs, and PRs.
- The human operator is signed in with an admin GitHub token; assume privileged operations
  (labels, reruns, merges) are allowed when safe.
- Default behaviour:
  - Operate inside this repository unless the human asks otherwise.
  - Keep workflows deterministic and green.
  - Reference `#88` in commit and PR descriptions.
- First actions in a session:
  1. Run `pwsh -File tools/Sync-Develop.ps1` to fetch/fast-forward `develop`.
     Set `SKIP_SYNC_DEVELOP=1` or pass `-NoFastForward` when a frozen snapshot is required.
  2. Pull #88 details (tasks, acceptance, linked PRs).
  3. Create or sync a working branch (`issue/88-<slug>`), push minimal changes, dispatch CI.
  4. Open or update the PR, apply required labels, monitor to green, merge when acceptance is met.

## Repository layout

- `scripts/` – PowerShell modules and shims (prefer `Import-Module`, avoid dot-sourcing).
- `tools/` – local/CI utilities; telemetry collectors; workflow helpers.
- `tests/` – Pester v5 suites (`Unit`, `Integration`); use `$TestDrive` for temp files.
- `.github/workflows/` – self-hosted and hosted pipelines; see README for highlights.
- `Invoke-PesterTests.ps1` – entry point for local runs and CI orchestration.

## Build / test / develop

- Unit tests: `./Invoke-PesterTests.ps1`
- Integration: `./Invoke-PesterTests.ps1 -IncludeIntegration true`
- Custom paths: `./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results`
- Pattern filter: `./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI.*'`
- Quick smoke: `./tools/Quick-DispatcherSmoke.ps1 -Keep`
- Containerized non-LV checks: `pwsh -File tools/Run-NonLVChecksInDocker.ps1` (pulls pinned
  images, honours `DETERMINISTIC=1`).
- Orchestrated gate: Run Task → `Integration (#88): Auto Push + Start + Watch`. The task pushes
  the current branch with the admin token (env or `C:\github_token.txt`), dispatches
  `ci-orchestrated.yml`, and streams the run via Docker watcher. Allowed issues live in
  `tools/policy/allowed-integration-issues.json`.
- Phase vars manifest: produced by `tools/Write-PhaseVars.ps1` in `tests/results/_phase/vars.json`;
  consumers run `tools/Validate-PhaseVars.ps1` + `tools/Export-PhaseVars.ps1` prior to
  unit/integration phases.
- Docker rebuilds & retests: rerun `tools/Run-NonLVChecksInDocker.ps1` (add `-Skip*` switches as
  needed) to refresh actionlint/markdownlint/docs/workflow checks. After image or workflow updates,
  trigger `Integration (#88): Auto Push + Start + Watch` to retest the deterministic pipeline
  end-to-end.
- Watcher hygiene: `tools/Watch-OrchestratedRun.ps1` trims old `.tmp/watch-run` folders, warns on
  stalled run/dispatcher status, and flags digest-identical dispatcher logs (possible repeated
  failures).

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

- Keep commits focused; include `#88` in subjects.
- PRs should describe rationale, list affected workflows, and link to artifacts.
- Ensure CI is green (lint + Pester). Verify no lingering processes on self-hosted runners.

## Local gates (pre-push)

- `tools/Get-BranchState.ps1` – prints branch/upstream divergence and working tree cleanliness.
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
  - Enforces subject ≤100 characters and issue reference (e.g., `(#88)`) unless `WIP`.

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
- `tools/Update-SessionIndexBranchProtection.ps1` injects the verification block into
  `session-index.json` and emits a step-summary entry.
- When running smoke tests locally:

  ```powershell
  pwsh -File tools/Quick-DispatcherSmoke.ps1 -PreferWorkspace -ResultsPath .tmp/sessionindex
  pwsh -File tools/Update-SessionIndexBranchProtection.ps1 -ResultsDir .tmp/sessionindex `
    -PolicyPath tools/policy/branch-required-checks.json `
    -Branch (git branch --show-current)
  ```

- Confirm `session-index.json` contains `branchProtection.result.status = "ok"`; mismatches should be
  logged in `branchProtection.notes`.
- If CI reports `warn`/`fail`, inspect the Step Summary and the session index artifact from that
  job. Update branch protection or the mapping file as needed to realign.

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

## Agent toggle catalog

- Toggle definitions live in `src/config/toggles.ts`; build artifacts land under `dist/src/config/`.
- The contract types (manifest, values payload, schema identifiers) live in `src/types/agent-toggles.ts`; update the Node tests in `src/config/__tests__/toggles-contract.test.ts` whenever the schema changes so the manifest digest stays deterministic.
- Generate machine-readable output via `node dist/src/config/toggles-cli.js`:
  - `node dist/src/config/toggles-cli.js --format values --profile ci-orchestrated --pretty`
  - `node dist/src/config/toggles-cli.js --format env --profile dev-workstation`
  - `node dist/src/config/toggles-cli.js --format psd1 --profile labview-diagnostics`
- `--format env` emits `AGENT_TOGGLE_MANIFEST_DIGEST` and `AGENT_TOGGLE_PROFILES` alongside
  per-toggle values; surface them in logs to prove configuration lineage.
- PowerShell helpers: `Import-Module tools/AgentToggles.psm1` then call `Get-AgentToggleValue` /
  `Get-AgentToggleValues`.
- Need the manifest metadata? Call `Get-AgentToggleContract` to retrieve the schema id, generated
  timestamp, and canonical digest in one shot—the hand-off flow and session-index tooling depend on it.
- Determinism guard: `Assert-AgentToggleDeterminism` throws when unexpected environment overrides
  are detected (pass `-AllowEnvironmentOverrides` only when intentionally deviating).
- Profiles apply in order; variants can target Describe/It names or tags for fine-grained
  overrides.
- Environment values still win: set `SKIP_SYNC_DEVELOP`, `HANDOFF_AUTOTRIM`, etc., before resolving
  to force overrides.
- Session index v2 records the resolved payload under `environment.toggles`; dashboards rely on the
  manifest digest to correlate runs.
- Reference implementation: `tests/AgentToggles.Tests.ps1`.

## Agent hand-off & telemetry

- Keyword **handoff**:
  1. Read `AGENT_HANDOFF.txt`, confirm plan.
  2. Preferred: `node dist/src/config/toggles-cli.js --format env --profile ci-orchestrated`
     (pipe into your shell's export or `$GITHUB_ENV`).
     - PowerShell option: `Import-Module tools/AgentToggles.psm1; Get-AgentToggleValues -Profiles 'ci-orchestrated'`.
     - Guardrail: `Assert-AgentToggleDeterminism` to ensure no unexpected environment overrides
       slipped in before continuing.
     - Manual fallback (when compiled assets unavailable):
       - `LV_SUPPRESS_UI=1`
       - `LV_NO_ACTIVATE=1`
       - `LV_CURSOR_RESTORE=1`
       - `LV_IDLE_WAIT_SECONDS=2`
       - `LV_IDLE_MAX_WAIT_SECONDS=5`
     - `tools/Write-SessionIndexSummary.ps1` and `tools/Write-AgentContext.ps1` automatically capture the toggle
       contract (schema id, version, generated timestamp, digest, profiles) in the step summary and agent context
       artifacts, so you always have lineage for the active manifest.
  3. Rogue scan:

     ```powershell
     pwsh -File tools/Detect-RogueLV.ps1 -ResultsDir tests/results `
       -LookBackSeconds 900 -AppendToStepSummary
     ```

  4. Sweep LVCompare (only) if rogues found and human approves.
  5. Honour pause etiquette ("brief delay (~90 seconds)") and log waits.
  6. Execute "First Actions for the Next Agent" from `AGENT_HANDOFF.txt`.
- Convenience helpers:
  - `pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles`
  - `pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim`
    - Prints a concise watcher summary (state, heartbeatFresh, needsTrim) and
      emits a compact JSON block to `tests/results/_agent/handoff/watcher-telemetry.json`.
    - When `-AutoTrim` (or `HANDOFF_AUTOTRIM=1`) is set, trims oversized watcher logs if eligible
      and appends notes to the GitHub Step Summary when available.

## Fast path for issue #88

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
