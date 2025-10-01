# Copilot Instructions for this repository

## Important model preference

- Use Claude Sonnet 4 for all clients by default for coding, analysis, and refactors. If unavailable, ask for a fallback before proceeding.

## Confirmed architecture and purpose

- This repo is a composite GitHub Action that invokes NI's LabVIEW Compare VI CLI to diff two `.vi` files.
- Reference: <https://www.ni.com/docs/en-US/bundle/labview/page/compare-vi-cli.html>
- Supported LabVIEW: 2025 Q3 on self-hosted Windows runners with LabVIEW installed.
- Core implementation: Single PowerShell script in `action.yml` runs section with comprehensive error handling and path resolution.

## Developer workflow (PowerShell/pwsh)

- Shell for all steps: PowerShell (`pwsh`) - all commands, paths, and escaping follow Windows PowerShell conventions.
- Use composite action (`using: composite`) to call the CLI, capture exit code, and write outputs via `$GITHUB_OUTPUT`.
- Built-in policy: `fail-on-diff` defaults to `true` and fails the job if differences are detected.
- Always emit outputs (`diff`, `exitCode`, `cliPath`, `command`) before any failure for workflow branching and diagnostics.

## Inputs/outputs contract

- Inputs:
  - `base`: path to the base `.vi`
  - `head`: path to the head `.vi`
  - `lvComparePath` (optional): full path to `LVCompare.exe` if not on `PATH`
  - `lvCompareArgs` (optional): extra CLI flags, space-delimited; quotes supported
  - `working-directory` (optional): process CWD; relative `base`/`head` are resolved from here
  - `fail-on-diff` (optional, default `true`)
- Environment:
  - `LVCOMPARE_PATH` (optional): resolves the CLI before `PATH` and known install locations
- Outputs:
  - `diff`: `true|false` whether differences were detected (0=no diff, 1=diff)
  - `exitCode`: raw exit code from the CLI
  - `cliPath`: resolved path to the executable
  - `command`: exact quoted command line executed

## Composite action implementation notes

- Resolve CLI path priority: `lvComparePath` → `LVCOMPARE_PATH` env → `Get-Command LVCompare.exe` → common 2025 Q3 locations (`C:\Program Files\NI\LabVIEW 2025\LVCompare.exe`, `C:\Program Files\National Instruments\LabVIEW 2025\LVCompare.exe`). If not found, error with guidance.
- Path resolution: Relative `base`/`head` paths are resolved from `working-directory` if set, then converted to absolute paths before CLI invocation.
- Arguments parsing: `lvCompareArgs` supports space-delimited tokens with quoted strings (`"path with spaces"`), parsed via regex `"[^"]+"|\S+`.
- Command reconstruction: Build quoted command string for auditability using custom `Quote()` function that escapes as needed.
- Always set outputs before failing the step so workflows can branch on `diff`.
- API principle: expose full LVCompare functionality via `lvCompareArgs`. Do not hardcode opinionated flags.
- Step summary: Always write structured markdown summary to `$GITHUB_STEP_SUMMARY` with working directory, resolved paths, CLI path, command, exit code, and diff result.

## Example resources

- Smoke test workflow: `.github/workflows/smoke.yml` (manual dispatch; self-hosted Windows).
- Validation workflow: `.github/workflows/validate.yml` (markdownlint + actionlint on PRs).
- Test mock workflow: `.github/workflows/test-mock.yml` (GitHub-hosted runners, mocks CLI).
- Release workflow: `.github/workflows/release.yml` (reads matching section from `CHANGELOG.md` for tag body).
- Runner setup guide: `docs/runner-setup.md`.

## Testing patterns

- Manual testing via smoke test workflow: dispatch with real `.vi` file paths to validate on self-hosted runner.
- Validation uses `ubuntu-latest` for linting (markdownlint, actionlint) - no LabVIEW dependency.
- Mock testing simulates CLI on GitHub-hosted runners without LabVIEW installation.

## Operational constraints

- Requires LabVIEW on the runner; GitHub-hosted runners do not include it.
- Use Windows paths and escape backslashes properly in YAML.
- CLI exit code mapping: 0=no diff, 1=diff detected, other=failure with diagnostic outputs.

## Release workflow

- Tags follow semantic versioning (e.g., `v0.1.0`).
- Release workflow extracts changelog section matching tag name from `CHANGELOG.md`.
- Keep changelog format: `## [vX.Y.Z] - YYYY-MM-DD` for automated extraction.

## File structure

- `action.yml`: Composite action definition with PowerShell script
- `scripts/CompareVI.ps1`: Core PowerShell module with CLI resolution and execution logic
- `scripts/Render-CompareReport.ps1`: Optional report generation utilities
- `tests/*.Tests.ps1`: Pester test suites (unit tests run without CLI, integration tests require self-hosted runner)
- `tools/Run-Pester.ps1`: Test orchestration script
- `Invoke-PesterTests.ps1`: Local test dispatcher for development
- `.github/workflows/`: CI/CD workflows (validate, test-mock, smoke, release)
- `docs/`: Documentation including runner setup, CI/CD setup, and knowledge base

## Testing structure

- **Unit tests** (`tests/CompareVI.Tests.ps1`, `tests/CompareVI.InputOutput.Tests.ps1`): Mock-based, no CLI dependency, run on GitHub-hosted runners
- **Integration tests** (`tests/CompareVI.Integration.Tests.ps1`): Require self-hosted Windows runner with LabVIEW CLI installed at canonical path
- Use `./Invoke-PesterTests.ps1` locally or `./tools/Run-Pester.ps1 -IncludeIntegration` for full test suite
- Test results output to `tests/results/` directory

## Dependencies

- PowerShell 7+ (pwsh) - required for all scripts and action execution
- Pester 5.x - testing framework (auto-installed by test scripts if missing)
- LabVIEW 2025 Q3 with LVCompare.exe - required only for integration tests and production use
- markdownlint-cli2 - for markdown linting (installed via npx in CI)
- actionlint - for workflow validation (installed in CI)

## Tool calling

When making function calls that accept array or object parameters, structure them using JSON. For example:

```json
[{"key": "value", "nested": {"option": true}}, {"key": "value2"}]
```

When exploring repositories or validating changes, call multiple independent tools simultaneously rather than sequentially for efficiency.

## Next steps for contributors

- Tag a release (e.g., `v0.1.0`) and keep README usage in sync.
- Evolve `README.md` with commonly used LVCompare flag patterns while keeping full pass-through.
