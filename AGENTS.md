# Repository Guidelines

## Primary Directive

- Proactively work on issue #88 until closed. Treat it as the top priority for all edits, CI runs, and PRs.
- Auth context: the human driving this session is logged into GitHub with an admin token. You may assume privileged operations are allowed (labels, dispatch, merge/tag) when appropriate and safe.
- Default behavior: operate autonomously (within this repo) to advance #88, while keeping runs deterministic and CI green. Always link commits/PRs to `#88`.
- Immediate actions when starting a session:
  - Pull issue details and confirm open tasks, acceptance criteria, and related PRs.
  - Create/update a working branch (e.g., `issue/88-<brief-slug>`), push minimal changes, and dispatch CI.
  - Open or update a PR referencing `#88`, apply required labels, and monitor until green. Merge when acceptance is met.

## Project Structure

- `scripts/` PowerShell modules/shims for compare/report/orchestrators (prefer `Import-Module`; avoid dot-sourcing).
- `tools/` Utilities for validation, summaries, telemetry, and dispatch.
- `tests/` Pester v5 suites; use `$TestDrive` for temp files; tag as `Unit`/`Integration`.
- `.github/workflows/` CI pipelines (self‑hosted Windows for LVCompare; hosted for preflight/lint).
- `Invoke-PesterTests.ps1` Local dispatcher for running tests and writing results.

## Build, Test, Develop

- Unit tests: `./Invoke-PesterTests.ps1`
- Include Integration: `./Invoke-PesterTests.ps1 -IncludeIntegration true`
- Custom paths: `./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results`
- Filter files: `./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI.*'`
- Quick smoke: `./tools/Quick-DispatcherSmoke.ps1 -Keep`

## Coding Style

- PowerShell 7+, Pester v5+. Match surrounding indentation (2–4 spaces).
- Do not spawn nested `pwsh`; invoke in‑process. Launch external tools via `ProcessStartInfo` (hidden, `UseShellExecute=false`).
- Only interface with `LVCompare.exe` (canonical path under Program Files); do not launch `LabVIEW.exe` directly.
- Default CI posture is non‑interactive; avoid popups and prompts.

## Testing Guidelines

- Prefer inline function shadowing inside each `It {}` and remove it after the test.
- Keep integration tests isolated and slower; unit tests fast.
- Results live under `tests/results/` (e.g., `pester-summary.json`, `pester-results.xml`, `session-index.json`).

## Wire Probes (Long-Wire v2)

- Probes are injected by `tools/workflows/update_workflows.py` into orchestrated/validate workflows.
- Toggle: set repository variable `WIRE_PROBES=0` to skip probe steps (default is enabled).
- Phases/anchors (all logged to `results/.../_wire/phase.json`):
  - `J1` / `J2`: before and after checkout.
  - `T1`: before Pester categories (`Run Pester tests via local dispatcher`, `Pester categories (serial, deterministic)`).
  - `C1` / `C2`: around fixture drift execution (orchestrated drift job).
  - `I1` / `I2`: around `Ensure Invoker (start/stop)`.
  - `S1`: immediately before `Session index post` (matrix categories use `tests/results/${{ matrix.category }}`; drift uses `results/fixture-drift`).
  - `G0` / `G1`: before/after `Runner Unblock Guard`.
  - `P1`: after final summaries (`Summarize orchestrated run`, `Append final summary (single)`).
- Inspect probes: `_wire` directory under job results and step summaries now show phase/timing markers.

## Commit & PRs

- Scope commits narrowly; use descriptive messages and link issues.
- PRs should explain what/why, list affected workflows, and attach result paths or artifacts.
- CI must be green (lint + Pester). On Windows, verify no console popups and no lingering processes.

### Local Gates (Pre-push)

- Before pushing, run `tools/PrePush-Checks.ps1` locally. It:
  - Installs `actionlint` (pinned via `vars.ACTIONLINT_VERSION`, default 1.7.7) if missing.
  - Runs `actionlint` across `.github/workflows` and fails non-zero on errors.
  - Optionally round-trips YAML via `ruamel.yaml` if Python is available.
- Optional hook (developer opt-in):
  - Enable hooks path: `git config core.hooksPath tools/hooks`
  - Copy `tools/hooks/pre-push.sample` to `tools/hooks/pre-push`.
  - The hook calls `tools/PrePush-Checks.ps1` and aborts on failures.

### Optional Hooks (Developer opt-in)

- Pre-commit: `tools/hooks/pre-commit.sample`
  - Runs PSScriptAnalyzer (if available) on staged PowerShell files.
  - Runs local linters: inline-if (-f) and dot-sourcing warnings.
  - Blocks commit if analyzers report errors.

- Commit-msg: `tools/hooks/commit-msg.sample`
  - Enforces commit subject <= 100 chars and presence of an issue reference (e.g., `(#88)`) unless `WIP`.
  - Blocks commit on policy violations.

### Required Checks (Develop/Main)

- Make `Validate` a required status on `develop` so broken workflows cannot merge.
- Suggested (one-time) GH CLI snippet (admin only):
  - `gh api repos/$REPO/branches/develop/protection -X PUT -f required_status_checks.strict=true -f required_status_checks.contexts[]=Validate -H "Accept: application/vnd.github+json"`

## Agent Notes (Pinned)

- One-shot invoker per job (ensure-invoker composite); guard snapshots include `node.exe` to diagnose terminal spikes.
- Workflows own timeboxing via job `timeout-minutes`; dispatcher has no implicit timeout. Optional `STUCK_GUARD=1` writes heartbeat/partial logs (notice-only).
- Self-hosted Windows is the only Windows variant for LVCompare; use hosted runners only for preflight/lint.

### Delay Language & Wait Etiquette

- "Brief delay" means ~90 seconds (up to 2 minutes). Use this when waiting for GitHub to propagate new workflow files or publish artifacts after job completion.
- Always embed the explicit wait hint in responses when asking a human to wait, e.g., "brief delay (~90 seconds)".

### Measuring Human Response Time

- Use `tools/Agent-Wait.ps1` to record wait windows around human responses.
- Start a wait when you inform the human you will pause (dot-source in the current pwsh session):
  - `. ./tools/Agent-Wait.ps1; Start-AgentWait -Reason 'workflow propagation' -ExpectedSeconds 90`
- When the human replies, end the wait and report the elapsed time:
  - `. ./tools/Agent-Wait.ps1; End-AgentWait`
- Artifacts are written to `tests/results/_agent/`:
  - `wait-marker.json` (start marker), `wait-last.json` (last result), `wait-log.ndjson` (append-only log)
- If running in GitHub Actions, both start and end steps append to the job summary automatically.

### Local Unit Test & Telemetry

- Run just the Agent-Wait unit test locally:
  - `pwsh -NoLogo -NoProfile -Command ". ./tools/Agent-Wait.ps1; Import-Module Pester; $c=New-PesterConfiguration; $c.Run.Path='tests/Agent-Wait.Tests.ps1'; $c.Output.Verbosity='Normal'; $c.Run.PassThru=$true; $r=Invoke-Pester -Configuration $c; \"Tests: total=$($r.TotalCount) passed=$($r.PassedCount) failed=$($r.FailedCount)\""`
- Expected telemetry (local):
  - The test uses `$TestDrive` for isolation; it does not write into the working tree.
  - If you use Start-AgentWait/End-AgentWait manually, artifacts are written under `tests/results/_agent/` (marker, last, log).
  - Standard Pester results (when running broader suites) are under `tests/results/` (`pester-summary.json`, `pester-results.xml`, `session-index.json`).

## LVCompare Observability & Leak Detection

- Notices (always-on)
  - CompareVI emits console + JSON notices at `tests/results/_lvcompare_notice/notice-*.json`.
  - Phases: `pre-launch`, `post-start` (includes `lvcomparePid`), `completed` (exitCode), `post-complete` (includes `labviewPids`).
  - If you see LVCompare/LabVIEW without a corresponding notice, that is a rogue execution.

- Local focus/mouse safeguards (opt‑in)
  - `LV_NO_ACTIVATE=1` (minimize/no‑activate), `LV_CURSOR_RESTORE=1` (restore pointer), `LV_IDLE_WAIT_SECONDS=2` (idle gate), `LV_IDLE_MAX_WAIT_SECONDS=5`.
  - Example: set env, then `Import-Module ./scripts/CompareVI.psm1; Invoke-CompareVI -Base ./VI1.vi -Head ./VI2.vi`.

- Rogue detector (manual)
  - `pwsh -File tools/Detect-RogueLV.ps1 -ResultsDir tests/results -LookBackSeconds 900 -AppendToStepSummary`
  - Adds a summary and JSON (live vs noticed PIDs). Use `-FailOnRogue` to break on leaks.

- CI guards (self‑hosted Windows)
- Pester (reusable) and Fixture Drift (Windows) include LV Guard pre/post snapshots; set `CLEAN_LV_BEFORE=true`, `CLEAN_LV_AFTER=true`, and `CLEAN_LV_INCLUDE_COMPARE=true` (repo defaults) to auto-clean LabVIEW/LVCompare.
  - Defaults for CompareVI from repo vars (override as needed): `LV_NO_ACTIVATE=1`, `LV_CURSOR_RESTORE=1`, `LV_IDLE_WAIT_SECONDS=2`, `LV_IDLE_MAX_WAIT_SECONDS=5`.

- Tests
  - PID tracking (Integration): `tests/CompareVI.PIDTracking.Tests.ps1` — verifies `lvcomparePid`/`labviewPids` and asserts no lingering LVCompare.
  - Run just this test locally: `pwsh -NoLogo -NoProfile -Command "Import-Module Pester; $c=New-PesterConfiguration; $c.Run.Path='tests/CompareVI.PIDTracking.Tests.ps1'; $c.Output.Verbosity='Normal'; Invoke-Pester -Configuration $c"`

Tip: Local terminals lack the GitHub UI’s visibility—rely on the `[lvcompare-notice]` console lines and the JSON notices to avoid confusion.

## Session Keywords (Agent Handoff & Telemetry)

- Keyword: `handoff`
  - When a human sends a message containing only `handoff`, the agent must:
    1) Read `AGENT_HANDOFF.txt` and acknowledge it will follow the roadmap therein.
    2) Set safe env toggles (local): `LV_SUPPRESS_UI=1`, `LV_NO_ACTIVATE=1`, `LV_CURSOR_RESTORE=1`, `LV_IDLE_WAIT_SECONDS=2`, `LV_IDLE_MAX_WAIT_SECONDS=5`.
    3) Run a quick rogue scan:
       - `pwsh -File tools/Detect-RogueLV.ps1 -ResultsDir tests/results -LookBackSeconds 900 -AppendToStepSummary`
    4) If rogues found and human approves, sweep LVCompare only; do not close LabVIEW unless instructed.
    5) Confirm timing etiquette: all pauses use “brief delay (~90 seconds)” and are recorded with agent‑wait tools.
    6) Proceed with the “First Actions for the Next Agent” from `AGENT_HANDOFF.txt`.

- Convenience (optional):
  - `pwsh -File tools/Print-AgentHandoff.ps1` prints `AGENT_HANDOFF.txt` to the console and suggests the next commands.

### Fast Path for #88

- Comment dispatch (on an open PR): `/run orchestrated single include_integration=true sample_id=<id>`
- Manual dispatch (CLI): `pwsh -File tools/Dispatch-WithSample.ps1 ci-orchestrated.yml -Ref develop -IncludeIntegration true`
- Merge policy: when all required checks are green and #88 acceptance is satisfied, proceed to merge (admin token available).

### Single Strategy Fallback (Reliability)

- Interactivity probe: orchestrated runs include a tiny `probe` job on self‑hosted Windows that detects if the session is interactive.
- Gating:
  - `windows-single` runs only when `probe.ok == true`.
  - If `strategy=single` but `probe.ok == false`, the workflow automatically falls back to the matrix path (`pester-category`).
- Hosted preflight stays notice‑only for LVCompare presence; enforcement happens only on self‑hosted jobs.

### Re‑run With Same Inputs

- Orchestrated summaries include a one‑click “Re‑run With Same Inputs” snippet populated from provenance (strategy/include_integration/sample_id).
- You can also use PR comment snippets (see `.github/PR_COMMENT_SNIPPETS.md`). The dispatcher accepts flexible forms:
  - `/run orchestrated strategy=single include_integration=true sample_id=<id>`
  - `/run orchestrated single include=true sample=<id>`
  - `/run orchestrated strategy single include true sample <id>`

## Workflow Maintenance (ruamel.yaml updater)

Use the Python-based updater only when you need consistent, mechanical edits across multiple workflows (preserving comments/formatting):

- Appropriate changes:
  - Add hosted Windows preflight note blocks.
  - Inject `session-index-post` steps (per job or matrix category).
  - Normalize Runner Unblock Guard placement/inputs.
  - Add/adjust pre‑init force_run gate wiring in self‑hosted Pester.

- Avoid it for one-off, semantic edits (e.g., changing job logic, needs graphs). In those cases, edit YAML manually and run `actionlint`.

- Prerequisites:
  - `python3 -m pip install ruamel.yaml`

- Dry run and apply:
  - Check: `python tools/workflows/update_workflows.py --check .github/workflows/ci-orchestrated.yml`
  - Write: `python tools/workflows/update_workflows.py --write .github/workflows/ci-orchestrated.yml`
  - Always validate after: `./bin/actionlint -color`

- Scope and PR hygiene:
  - Keep updater changes in small, focused PRs; include a summary of files touched and the transforms applied.
  - If the updater warns or skips a file, fall back to a manual edit and re-run `actionlint`.
