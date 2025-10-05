# Repository Guidelines

## Project Structure & Module Organization

- `scripts/` core PowerShell modules/shims (compare/report/orchestrators). Use `Import-Module`, avoid dot-sourcing.
- `tools/` developer utilities (smoke runs, validators, summaries, telemetry).
- `module/` reusable PS modules and action helpers.
- `tests/` Pester v5 suites; keep temp I/O in `$TestDrive`.
- `.github/workflows/` CI jobs (self-hosted Windows for LVCompare; hosted for preflight/lint).
- `Invoke-PesterTests.ps1` local dispatcher; results under `tests/results/`.

## Build, Test, and Development Commands

- Unit tests: `./Invoke-PesterTests.ps1`
- Include integration: `./Invoke-PesterTests.ps1 -IncludeIntegration true`
- Custom paths: `./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results`
- Filter by name: `./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI.*'`
- Quick smoke: `./tools/Quick-DispatcherSmoke.ps1 -Keep`

## Coding Style & Naming Conventions

- PowerShell 7+; Pester v5+. Use 2 spaces (match surrounding code if different).
- Functions: Verb-Noun with approved verbs; variables camelCase.
- Prefer modules over dot-sourcing; avoid nested `pwsh` spawns.
- CI must be non-interactive; suppress UI/popups (hidden process start when applicable).
- Only interface with `LVCompare.exe` (do not launch `LabVIEW.exe`).

## Testing Guidelines

- Tags: `Unit` (fast) and `Integration` (requires LVCompare). Env for integration: `LV_BASE_VI`, `LV_HEAD_VI`.
- Keep temp files in `$TestDrive`; clean up per test.
- Probe older Pester via inline function shadowing inside `It {}`; remove with `Remove-Item Function:Get-Module`.
- Results: `tests/results/pester-results.xml`, `tests/results/pester-summary.txt|json`.

## Commit & Pull Request Guidelines

- Write scoped, descriptive commits; reference issues.
- PRs: what/why, test evidence (paths to results/artifacts), workflow impacts.
- CI expectations: actionlint + markdownlint pass; Pester green; no console popups or lingering processes on Windows.

## Agent-Specific Notes

- Self-hosted Windows is the only Windows variant used for LVCompare. Hosted jobs are used for preflight/lint.
- If available, prefer the invoker RPC path; handshake: Reset → Start → Ready → Done. Key artifacts: `tests/results/<phase>/console-spawns.ndjson`, `_handshake/*.json`.

