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

- One‑shot invoker per job (ensure‑invoker composite); guard snapshots include `node.exe` to diagnose terminal spikes.
- Workflows own timeboxing via job `timeout-minutes`; dispatcher has no implicit timeout. Optional `STUCK_GUARD=1` writes heartbeat/partial logs (notice‑only).
- Self‑hosted Windows is the only Windows variant for LVCompare; use hosted runners only for preflight/lint.

