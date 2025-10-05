# Repository Guidelines

## Project Structure & Module Organization

- `scripts/` orchestration and helpers (compare, drift, runbook, dispatcher glue).
- `tools/` developer utilities (manifest validate/update, link checks, schema-lite).
- `tests/` Pester suites (`*.Tests.ps1`) tagged `Unit`/`Integration`.
- `module/` reusable PowerShell modules (e.g., compare loop).
- `docs/` guides and JSON schemas. Fixtures: `VI1.vi`, `VI2.vi` + `fixtures.manifest.json`.
- CI: `.github/workflows/*` and local composites under `.github/actions/*`.

## Build, Test, and Development Commands

- Unit tests: `./Invoke-PesterTests.ps1`
- Include integration: `./Invoke-PesterTests.ps1 -IncludeIntegration true`
- Filter by file pattern(s): `./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI*Tests.ps1'`
- Quick smoke (workspace temp): `./tools/Quick-DispatcherSmoke.ps1 -PreferWorkspace`
- Validate fixtures: `pwsh -NonInteractive -File tools/Validate-Fixtures.ps1 -Json`
- Orchestrated CI: preflight → pester (per-category, serial) → drift → publish.

## Coding Style & Naming Conventions

- PowerShell 7+, Pester 5+. Indent 2 spaces; UTF‑8.
- Functions PascalCase (approved verbs); locals camelCase; clear names.
- Keep code non-interactive in CI: use `pwsh -NonInteractive` for nested calls.
- Avoid writing outside `tests/results/`; prefer per-category subfolders in CI.

## Testing Guidelines

- Single Pester workflow (self-hosted Windows): `.github/workflows/pester-selfhosted.yml`.
- Categories in CI: dispatcher, fixtures, schema, comparevi, loop, runbook, orchestrator.
- Each category emits `tests/results/<category>/session-index.json` and artifacts.
- Timeouts are per-category and configurable via repo Variables (seconds):
  `PESTER_TIMEOUT_DISPATCHER`, `PESTER_TIMEOUT_FIXTURES`, `PESTER_TIMEOUT_SCHEMA`,
  `PESTER_TIMEOUT_COMPAREVI`, `PESTER_TIMEOUT_LOOP`, `PESTER_TIMEOUT_RUNBOOK`,
  `PESTER_TIMEOUT_ORCHESTRATOR`. Defaults to 150 if unset.
  Example: set `PESTER_TIMEOUT_FIXTURES=180` in Settings → Variables to extend fixtures.
  Locally, override with `-TimeoutSeconds`:
  `./Invoke-PesterTests.ps1 -IncludePatterns 'Fixtures*Tests.ps1' -TimeoutSeconds 180`.
  Session index is always written.
- LVCompare canonical path: `C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe`.
- Integration needs `LV_BASE_VI` and `LV_HEAD_VI`. Do not orchestrate `LabVIEW.exe`.

### Pre-Init Gate (Docs-only fast path)
- A pre-init gate detects docs-only changes (e.g., `docs/**`, `**/*.md`) and skips heavy Windows jobs.
- Exceptions (still run Windows where needed): `docs/schemas/**`.
- Workflow: first job `pre-init` computes `docs_only` and gates `preflight`/`pester` via `needs`/`if`.

## Commit & Pull Request Guidelines

- Commits: imperative and scoped (e.g., `validator: enforce bytes`).
- PRs: include summary, risks, validation steps, linked issues; keep markdownlint and actionlint green.
- Never start tests with `LabVIEW.exe` running; preflight/guard enforces this.

## Security & Configuration Tips

- LVCompare‑only interface; no `LabVIEW.exe` launches from tools.
- Manifest enforces exact `bytes` and `sha256`; run validator before pushing.
- Optional leak/cleanup flags: `DETECT_LEAKS=1`, `CLEAN_AFTER=1`, `CLEAN_LVCOMPARE=1`.

## Agent Notes

- Prefer `Invoke-PesterTests.ps1` locally and in CI. Use `-IncludePatterns` to target files.
- For docs hygiene, run `tools/Check-DocsLinks.ps1` and keep markdownlint clean before PRs.
