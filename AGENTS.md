# Repository Guidelines

## Project Structure & Modules

- Root dispatcher: `Invoke-PesterTests.ps1` (runs Pester, writes results to `tests/results/`).
- Action definition: `action.yml`.
- PowerShell scripts/modules: `scripts/` (integration loop, helpers) and `module/`.
- Developer tools: `tools/` (Run/Watch Pester, smoke tests, schema utilities).
- Tests: `tests/` with `*.Tests.ps1` plus `tests/helpers/` and `tests/support/`.
- TypeScript utilities: `ts/` compiled to `dist/` via `tsc`.
- Docs: `docs/` (usage, testing, CI) and workflows in `.github/`.

## Build, Test, and Development Commands

- Unit tests (exclude Integration): `pwsh -File ./Invoke-PesterTests.ps1`.
- All tests (incl. Integration): `pwsh -File ./Invoke-PesterTests.ps1 -IncludeIntegration true`.
- Focus a test file: `pwsh -File ./tools/Run-Pester.ps1 -Path tests/CompareVI.Tests.ps1`.
- Quick smoke: `pwsh -File ./tools/Quick-DispatcherSmoke.ps1`.
- Build TS: `npm ci && npm run build` (outputs to `dist/`).
- Lint Markdown: `npm run lint:md`. Workflow lint (if installed): `actionlint .github/workflows/*.yml`.

## Coding Style & Naming Conventions

- PowerShell (PS 7+, Pester 5+): Verb-Noun with approved verbs, PascalCase identifiers, 2-space indent, use splatting for readability. Place reusable code in `scripts/` or `module/`.
- Tests: name as `Something.Tests.ps1`; group helpers in `tests/helpers/`.
- TypeScript: ESM, 2-space indent, sources in `ts/`, build artifacts in `dist/` (do not edit `dist/`).

## Testing Guidelines

- Framework: Pester v5. Default run excludes `Integration`-tagged tests.
- Integration prerequisites: LVCompare at `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe` and env vars `LV_BASE_VI`, `LV_HEAD_VI`.
- Isolation: prefer `$TestDrive` for temp files and keep fixtures local to the repo.
- Results: `tests/results/pester-results.xml` and `tests/results/pester-summary.txt`.

## Commit & Pull Request Guidelines

- Commits: concise, imperative subject; reference issues (e.g., `Fix summary aggregation (#123)`).
- PRs: describe problem, approach, and risks; include test evidence (summary snippet or failing/passing case); link issues.
- Required before merge: unit tests green; integration tests green when applicable; docs updated when flags or behavior change; `npm run lint:md` clean.

## Security & Configuration Tips

- Do not commit secrets or machine paths. Use sample env and scripts in `tools/` or `docs/`.
- Integration workflows should write only to `$TestDrive`/`tests/results/`. Avoid modifying files outside the workspace.

