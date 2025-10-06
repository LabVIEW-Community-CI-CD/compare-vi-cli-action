# Repository Guidelines

## Project Structure & Modules

- `scripts/` — core PowerShell modules/shims (compare/report/orchestrators). Prefer `Import-Module` over dot-sourcing.
- `tools/` — developer utilities (smoke runs, validation, summaries, telemetry helpers).
- `tests/` — Pester v5 suites. Use `$TestDrive` for temp files; tag tests as `Unit` or `Integration`.
- `.github/workflows/` — CI jobs (self‑hosted Windows for LVCompare; hosted jobs for preflight/lint).
- `Invoke-PesterTests.ps1` — local dispatcher for running tests with paths/filters and result outputs.

## Build, Test, and Development

- Unit tests (default): `./Invoke-PesterTests.ps1`
- Include Integration: `./Invoke-PesterTests.ps1 -IncludeIntegration true`
- Custom paths: `./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results`
- Filter by pattern: `./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI.*'`
- Quick smoke: `./tools/Quick-DispatcherSmoke.ps1 -Keep` (writes a minimal suite to a temp dir)
- Per-category (local): use patterns that mirror CI categories, e.g.
  - Dispatcher: `-IncludePatterns 'Invoke-PesterTests*.ps1','PesterAvailability.Tests.ps1','NestedDispatcher*.Tests.ps1'`
  - Fixtures: `-IncludePatterns 'Fixtures.*.ps1','FixtureValidation*.ps1','ViBinaryHandling.Tests.ps1'`
  - Workflow: `-IncludePatterns 'Workflow*.ps1','On-FixtureValidationFail.Tests.ps1'`

## Coding Style & Naming

- PowerShell 7+; Pester v5+. 2–4 spaces indentation (match surrounding code).
- Prefer modules (`Import-Module`) over dot-sourcing. Avoid nested `pwsh` spawns.
- Only interface with `LVCompare.exe`; do not launch `LabVIEW.exe` directly.
- Non-interactive by default in CI; avoid UI prompts/popups. Use hidden process start when feasible.
- Functions use verb‑noun; tests use clear, behavior‑driven names.

## Testing Guidelines

- Tag tests: `-Tag 'Unit'` or `-Tag 'Integration'`. Keep integration slow/isolated.
- Use `$TestDrive` and per-test cleanup to prevent leftover files/processes.
- For probe scenarios, prefer inline function shadowing inside `It {}` and remove afterwards.
- Results live under `tests/results/` (e.g., `pester-summary.json`, `pester-results.xml`).

## Commit & PR Guidelines

- Keep commits scoped and descriptive. Reference issues where applicable.
- PRs should include: what/why, test evidence (summary or artifact paths), and any workflow impacts.
- Ensure CI is green (lint + Pester). On Windows, verify no console popups and no lingering processes.

## Agent Runbook (Pinned)

- Windows policy: self‑hosted Windows is the only variant used for LVCompare; hosted runners are for preflight/lint only.
- LVCompare: canonical path `C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe`.
- Invoker path: when present, prefer the invoker RPC (single execution path, hidden process, telemetry). Handshake phases: Reset → Start → Ready → Done. Artifacts include `tests/results/<phase>/console-spawns.ndjson` and `_handshake/*.json`.
- Safe toggles: `LV_SUPPRESS_UI=1`, `WATCH_CONSOLE=1`, and non‑interactive flags in nested calls.
- If blocked: check recent job step summary, confirm no `LabVIEW.exe` is left running, inspect `tests/results/*/pester-summary.json`, and review any compare/report artifacts.
