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

- Resolve CLI path priority: `lvComparePath` → `LVCOMPARE_PATH` env → canonical path (`C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`). All paths must resolve to the canonical location; non-canonical paths are rejected with clear error messages.
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
- **Deterministic release requirement**: Each tagged release must produce identical artifacts when rebuilt from the same commit. See "Deterministic Release Verification" section below for verification procedures and hashing snippets to validate reproducibility.

## Next steps for contributors

- Tag a release (e.g., `v0.1.0`) and keep README usage in sync.
- Evolve `README.md` with commonly used LVCompare flag patterns while keeping full pass-through.

## Gotchas & Quoting Nuances

### Quoting and Escaping (PowerShell + YAML)

- **YAML string quoting**: Use double quotes for Windows paths with backslashes. Escape literal backslashes with `\\` in YAML strings.
- **PowerShell Quote() function**: Located in `scripts/CompareVI.ps1`, wraps arguments containing spaces or quotes. Escapes embedded quotes as `\"`.
- **Argument tokenization regex**: The canonical pattern `"[^"]+"|\S+` matches quoted strings (including quotes) or non-whitespace sequences. This pattern is centralized in `scripts/ArgTokenization.psm1` and imported by `CompareVI.ps1`, `CompareLoop.psm1`, `Render-CompareReport.ps1`, and `Integration-ControlLoop.Functions.psm1`. Use `Get-LVCompareArgTokenPattern` to access it.
- **Preserving quotes in command line**: The `command` output preserves original quoting for auditability. Do not modify the Quote() function without updating tests and documentation.

### Path Resolution

- **Canonical CLI path**: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe` - this is the only supported installation path. Reject all other paths with clear error messages.
- **Relative path resolution**: Relative `base`/`head` paths are resolved from `working-directory` if set, then converted to absolute paths via `Resolve-Path -LiteralPath`.
- **Case-insensitive comparison**: Windows paths are compared case-insensitively (`-ieq` operator) to handle drive letter and path casing variations.

### Output Ordering

- **Output file write order**: Always write outputs in this exact order to `$GITHUB_OUTPUT`: `exitCode`, `cliPath`, `command`, `diff`. This ordering is a contract for downstream workflows.
- **Summary key order**: Step summary keys must appear in this order: "Working directory", "Base", "Head", "CLI", "Command", "Exit code", "Diff". This ensures consistent formatting and parsing.

### Common Pitfalls

- **Forgetting to set outputs on error paths**: Always emit all four outputs (`exitCode`, `cliPath`, `command`, `diff`) even when throwing an exception, to enable workflow branching.
- **Modifying tokenization regex**: The pattern is centralized in `scripts/ArgTokenization.psm1` and accessed via `Get-LVCompareArgTokenPattern`. It is intentionally simple and must not be changed without comprehensive test coverage for edge cases (nested quotes, escaped quotes, etc.). Any changes must be made in the shared module to maintain consistency across all scripts.
- **Hardcoding CLI flags**: Never add default CLI flags to `CompareVI.ps1`. All flags must be passed via `lvCompareArgs` to preserve pass-through semantics.

## HTML Report Artifact Publishing

### Workflow Snippet

To generate and upload HTML comparison reports as workflow artifacts:

```yaml
jobs:
  compare-with-report:
    runs-on: [self-hosted, Windows]
    steps:
      - uses: actions/checkout@v5
      
      - name: Compare VIs
        id: compare
        uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.1.0
        continue-on-error: true
        with:
          base: path/to/base.vi
          head: path/to/head.vi
          fail-on-diff: false
      
      - name: Generate HTML Report
        if: always()
        shell: pwsh
        run: |
          $reportPath = Join-Path $env:RUNNER_TEMP "compare-report.html"
          & ./scripts/Render-CompareReport.ps1 `
            -Command "${{ steps.compare.outputs.command }}" `
            -ExitCode ${{ steps.compare.outputs.exitCode }} `
            -Diff "${{ steps.compare.outputs.diff }}" `
            -CliPath "${{ steps.compare.outputs.cliPath }}" `
            -OutputPath $reportPath
      
      - name: Upload Report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: compare-report
          path: ${{ runner.temp }}/compare-report.html
          retention-days: 30
```

### Report Rendering Notes

- **Script location**: `scripts/Render-CompareReport.ps1` generates self-contained HTML reports.
- **Required inputs**: All four outputs from the action (`command`, `exitCode`, `diff`, `cliPath`) must be passed to the renderer.
- **Optional inputs**: `Base` and `Head` can be extracted from `command` if not provided explicitly.
- **Styling**: Report uses inline CSS for portability (no external dependencies).
- **Encoding**: Always use UTF-8 encoding (`-Encoding utf8`) for HTML output.

## Potential Future Enhancements

### Backlog (Safe Extensions)

These enhancements maintain backward compatibility and do not alter existing contracts:

1. **Additional outputs** (non-breaking):
   - `baseResolved`: Absolute path to base VI after resolution
   - `headResolved`: Absolute path to head VI after resolution
   - `workingDirectoryResolved`: Absolute path to working directory (if set)

2. **Optional report generation** (new input):
   - `generate-html-report: true|false` (default `false`)
   - Output: `reportPath` - path to generated HTML report

3. **Artifact upload integration** (new input):
   - `upload-report-artifact: true|false` (default `false`)
   - Automatically uploads HTML report using `actions/upload-artifact`

4. **Summary customization** (new input):
   - `summary-format: compact|detailed` (default `detailed`)
   - Compact format omits working directory and absolute paths

### Guardrails (Do Not Implement)

These changes would break existing contracts or violate design principles:

1. **❌ Default CLI flags**: Never add hardcoded flags to the action. All flags must be explicit via `lvCompareArgs`.
2. **❌ Alternative canonical paths**: Do not add support for multiple installation locations. Canonical path is a deliberate constraint for consistency.
3. **❌ Automatic diff suppression**: Do not add logic to suppress diffs based on content analysis. The action is a thin wrapper; policy belongs in workflows.
4. **❌ Changing output names**: Output names (`diff`, `exitCode`, `cliPath`, `command`) are part of the public contract and must not be renamed.
5. **❌ Modifying Quote() or tokenization regex**: These are critical invariants with precise test coverage.

## Test Dispatcher & Env Var Nuances

### Invoke-PesterTests.ps1 vs tools/Run-Pester.ps1

- **Invoke-PesterTests.ps1**: Root-level dispatcher called directly by workflows. Accepts string parameters (`'true'`/`'false'`) for compatibility with workflow inputs.
- **tools/Run-Pester.ps1** (if exists): Internal helper that may use native PowerShell types (e.g., `[switch]` parameters).
- **Parameter conversion**: Dispatcher converts string `'true'`/`'false'` to boolean before passing to Pester or internal scripts.

### Environment Variable Behavior

- **LVCOMPARE_PATH**: Checked only if `lvComparePath` input is not provided. Must point to the canonical path; any other value is rejected with a clear error.
- **LV_BASE_VI / LV_HEAD_VI**: Repository variables used by integration tests on self-hosted runners. These point to real `.vi` files for end-to-end validation.
- **FORCE_EXIT**: Internal test environment variable to simulate specific exit codes in unit tests. Never used in production code.

### Test Tag Semantics

- **Unit**: Tests that use mocks and do not require LabVIEW CLI or real `.vi` files. Run on any platform.
- **Integration**: Tests that require LabVIEW CLI at canonical path and real `.vi` files (via `LV_BASE_VI`/`LV_HEAD_VI`). Run only on self-hosted Windows runners.
- **Mock**: Tests that simulate CLI behavior for GitHub-hosted runners. Use mocked executors.

### Running Tests

```powershell
# Unit tests only (no LabVIEW required)
./Invoke-PesterTests.ps1 -IncludeIntegration false

# Include integration tests (requires self-hosted runner)
./Invoke-PesterTests.ps1 -IncludeIntegration true
```

## Decision Tree for Adding Inputs/Outputs Safely

### Adding a New Input

1. **Evaluate necessity**: Does this input enable a new use case, or can it be achieved with existing inputs?
2. **Check backward compatibility**: Can the input have a sensible default that preserves existing behavior?
3. **Update action.yml**: Add the input with description, required status, and default value.
4. **Update scripts/CompareVI.ps1**: Add parameter to `Invoke-CompareVI` function signature.
5. **Update tests**: Add unit tests verifying the new input's behavior with and without explicit values.
6. **Update documentation**: Add input to README and copilot instructions with examples.
7. **Update workflows**: Add smoke test scenario exercising the new input.
8. **Validate contracts**: Ensure no existing outputs or summary keys are affected.

### Adding a New Output

1. **Evaluate necessity**: Is this output actionable by downstream workflows, or purely informational?
2. **Check backward compatibility**: New outputs are always backward compatible (consumers can ignore them).
3. **Update scripts/CompareVI.ps1**: Add output to all code paths (success, diff, and error).
4. **Maintain output order**: Append new outputs after existing ones (`exitCode`, `cliPath`, `command`, `diff`).
5. **Update action.yml**: Add the output with description.
6. **Update tests**: Verify the new output is present in all scenarios (unit and integration tests).
7. **Update documentation**: Add output to README and copilot instructions with usage examples.
8. **Update summary**: Consider adding the new output to `$GITHUB_STEP_SUMMARY` if relevant.

### Checklist Before Committing

- [ ] Input/output added to `action.yml` with clear description
- [ ] `scripts/CompareVI.ps1` updated with parameter/output logic
- [ ] All code paths emit the output (success, diff, error)
- [ ] Unit tests verify new behavior with default and explicit values
- [ ] README updated with usage examples
- [ ] Copilot instructions updated with contract details
- [ ] Smoke test workflow includes scenario exercising the change
- [ ] Markdown linting passes (`markdownlint .`)
- [ ] Action linting passes (`actionlint`)
- [ ] Existing tests pass (unit tests without integration)

## Deterministic Release Verification

### Requirement

Each tagged release must produce identical artifacts when rebuilt from the same commit. This ensures:

- **Reproducibility**: Anyone can verify the release matches the source code.
- **Security**: Tampering with releases is detectable via hash comparison.
- **Confidence**: Users can trust that published releases are genuine.

### Verification Checklist

When creating a release (or verifying an existing one):

- [ ] Checkout the exact tagged commit (`git checkout v0.1.0`)
- [ ] Verify no uncommitted changes (`git status --porcelain` is empty)
- [ ] Record commit SHA (`git rev-parse HEAD`)
- [ ] Generate artifact hashes (see snippet below)
- [ ] Compare with published release hashes (if re-verifying)
- [ ] Document hashes in release notes or separate verification file

### Automation Snippet

Add this script to `scripts/Verify-ReleaseDeterminism.ps1`:

```powershell
param(
  [Parameter(Mandatory=$true)]
  [string]$Tag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Checkout tag
git checkout $Tag
if ($LASTEXITCODE -ne 0) { throw "Failed to checkout tag $Tag" }

# Verify clean state
$status = git status --porcelain
if ($status) { throw "Working directory is not clean" }

# Get commit SHA
$sha = git rev-parse HEAD
Write-Host "Commit SHA: $sha"

# Hash all action files
$files = @(
  'action.yml',
  'scripts/CompareVI.ps1',
  'scripts/Render-CompareReport.ps1'
)

$hashes = @{}
foreach ($file in $files) {
  $hash = (Get-FileHash -Path $file -Algorithm SHA256).Hash
  $hashes[$file] = $hash
  Write-Host "$file : $hash"
}

# Output JSON for programmatic verification
$output = @{
  tag = $Tag
  commit = $sha
  timestamp = (Get-Date -Format 'o')
  hashes = $hashes
} | ConvertTo-Json

$outputPath = "release-verification-$Tag.json"
$output | Out-File -FilePath $outputPath -Encoding utf8
Write-Host "Verification data written to $outputPath"
```

### Usage

```powershell
# Verify determinism for v0.1.0
./scripts/Verify-ReleaseDeterminism.ps1 -Tag v0.1.0

# Compare two verification files
$v1 = Get-Content release-verification-v0.1.0.json | ConvertFrom-Json
$v2 = Get-Content release-verification-v0.1.0-rebuild.json | ConvertFrom-Json
Compare-Object $v1.hashes.PSObject.Properties $v2.hashes.PSObject.Properties
```

### Integration with Release Workflow

Consider adding deterministic verification as a release workflow step:

```yaml
- name: Verify Determinism
  shell: pwsh
  run: |
    ./scripts/Verify-ReleaseDeterminism.ps1 -Tag ${{ github.ref_name }}
    
- name: Upload Verification
  uses: actions/upload-artifact@v4
  with:
    name: release-verification
    path: release-verification-*.json
```
