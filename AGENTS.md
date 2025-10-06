# Repository Guidelines

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

## Commit & PRs

- Scope commits narrowly; use descriptive messages and link issues.
- PRs should explain what/why, list affected workflows, and attach result paths or artifacts.
- CI must be green (lint + Pester). On Windows, verify no console popups and no lingering processes.

## Agent Notes (Pinned)

- One-shot invoker per job (ensure-invoker composite); guard snapshots include `node.exe` to diagnose terminal spikes.
- Workflows own timeboxing via job `timeout-minutes`; dispatcher has no implicit timeout. Optional `STUCK_GUARD=1` writes heartbeat/partial logs (notice-only).
- Self-hosted Windows is the only Windows variant for LVCompare; use hosted runners only for preflight/lint.

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

## Orchestrated CI (Unified)

- Single workflow: `.github/workflows/ci-orchestrated.yml` supports two strategies via input `strategy`:
  - `matrix` (default): category matrix → drift → publish summary
  - `single`: one Windows job (interactivity probe → warmup → serial categories → drift → guard)
- Trigger examples (GitHub UI): set `include_integration=true`, `strategy`, and `sample_id` (unique) to avoid cancels.
- Trigger via GH CLI (from your terminal):
  - Matrix: `gh workflow run ci-orchestrated.yml -r develop -f include_integration=true -f strategy=matrix -f sample_id=$(Get-Date -Format yyyyMMdd-HHmmss)-mx`
  - Single: `gh workflow run ci-orchestrated.yml -r develop -f include_integration=true -f strategy=single -f sample_id=$(Get-Date -Format yyyyMMdd-HHmmss)-sg`
- Defaults:
  - Hosted preflight (windows-latest) is notice-only; strict LVCompare checks occur on self-hosted steps.
  - Keep one Windows variant (self-hosted) for compare/drift; use hosted for preflight/lint only.

## PR Comment Commands (Agent Tooling)

Agents should drive CI by posting PR comments (do not wait for a human to run them). Use these commands to dispatch the unified orchestrated workflow:

- Orchestrated (single):
  - `/run orchestrated single include_integration=true sample_id=YYYYMMDD-HHMMSS-oc`
- Orchestrated (matrix):
  - `/run orchestrated matrix include_integration=true sample_id=YYYYMMDD-HHMMSS-oc`

Notes:
- The command-dispatch workflow listens on PR comments and will dispatch to `ci-orchestrated.yml`.
- Authorization: OWNER/MEMBER/COLLABORATOR; the workflow uses `XCLI_PAT` to call the GitHub API.
- Agents should post the command comment themselves (via `gh pr comment` or REST) and then monitor the run to completion.

Optional local helper (human/dev):
- `pwsh -File tools/Dispatch-Orchestrated.ps1 -Strategy single -IncludeIntegration true -Ref develop -Open`
- `pwsh -File tools/Dispatch-Orchestrated.ps1 -Strategy matrix -IncludeIntegration true -Ref develop -Open`

