# Usage Guide

This guide covers advanced configuration and usage patterns for the compare-vi-cli-action.

## Table of Contents

- [Working with lvCompareArgs](#working-with-lvcompareargs)
- [Using working-directory](#using-working-directory)
- [Path Resolution and UNC Paths](#path-resolution-and-unc-paths)
- [HTML Comparison Reports](#html-comparison-reports)
- [Workflow Branching Examples](#workflow-branching-examples)

## Working with lvCompareArgs

The `lvCompareArgs` input accepts space-delimited CLI flags with full quote support for paths containing spaces.

For comprehensive documentation on LVCompare CLI flags and Git integration, see [`knowledgebase/LVCompare-Git-CLI-Guide_Windows-LabVIEW-2025Q3.md`](./knowledgebase/LVCompare-Git-CLI-Guide_Windows-LabVIEW-2025Q3.md).

### Recommended Noise Filters

Reduce cosmetic diff churn with these flags:

```yaml
lvCompareArgs: "-nobdcosm -nofppos -noattr"
```

- `-nobdcosm` - Ignore block diagram cosmetic changes (position/size/appearance)
- `-nofppos` - Ignore front panel object position/size changes
- `-noattr` - Ignore VI attribute changes

### LabVIEW Version Selection

Specify which LabVIEW version to use for comparison:

```yaml
lvCompareArgs: '-lvpath "C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe"'
```

### Common Patterns

**Path with spaces:**

```yaml
lvCompareArgs: "--flag \"C:\\Path With Spaces\\out.txt\""
```

**Multiple flags:**

```yaml
lvCompareArgs: "-nobdcosm -nofppos -noattr -lvpath \"C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe\""
```

**Environment-driven values:**

```yaml
lvCompareArgs: "--log \"${{ runner.temp }}\\lvcompare.log\""
```

## Using working-directory

When your VIs are in a subdirectory, use `working-directory` to avoid repeating path prefixes:

```yaml
- name: Compare VIs
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
  with:
    working-directory: my-labview-project
    base: src/VI1.vi
    head: src/VI2.vi
    lvCompareArgs: "-nobdcosm -nofppos -noattr"
```

## Path Resolution and UNC Paths

- The action resolves `base`/`head` to absolute paths before invoking LVCompare
- Relative paths are resolved from `working-directory` if set, otherwise from the repository root
- UNC tokens passed through `lvCompareArgs` keep their double leading backslashes (e.g. `\\server\share`) and quoted values remain intact, so there is no need to double-escape them.
- Array-based `lvCompareArgs` inputs preserve each element as a single token—even when the value contains spaces or Unix-style paths—allowing you to mix string and script-block inputs safely.
- For long-path or UNC issues, consider:
  - Using shorter workspace-relative paths via `working-directory`
  - Mapping a drive on self-hosted runners for long UNC prefixes
  - Ensuring your LabVIEW/Windows environment supports long paths

## HTML Comparison Reports

For CI/CD pipelines and code reviews, you can generate HTML comparison reports using **LabVIEWCLI** (requires LabVIEW 2025 Q3 or later):

```powershell
# Generate single-file HTML report
LabVIEWCLI -OperationName CreateComparisonReport `
  -vi1 "path\to\VI1.vi" -vi2 "path\to\VI2.vi" `
  -reportType HTMLSingleFile -reportPath "CompareReport.html" `
  -nobdcosm -nofppos -noattr
```

**Benefits:**

- Self-contained HTML file suitable for artifact upload
- Visual diff output for code reviews
- Works with recommended noise filter flags
- Can be integrated into workflows for automated comparison reporting

See the knowledgebase guide for more details on HTML report generation.

### Internal HTML Report Script

The repository includes a PowerShell script for generating HTML metadata wrappers:

```powershell
pwsh -File scripts/Render-CompareReport.ps1 `
  -Command "$($env:COMPARE_COMMAND)" `
  -ExitCode $env:COMPARE_EXIT_CODE `
  -Diff $env:COMPARE_DIFF `
  -CliPath $env:COMPARE_CLI_PATH `
  -DurationSeconds $env:COMPARE_DURATION_SECONDS `
  -OutputPath compare-report.html
```

This generates a self-contained HTML file with:

- UTF-8 encoding
- Deterministic key ordering
- HTML-encoded command values
- Comparison metadata

## Workflow Branching Examples

### Basic Conditional Steps

```yaml
- name: Compare VIs
  id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
  with:
    base: VI1.vi
    head: VI2.vi
    fail-on-diff: false

- name: Handle differences
  if: steps.compare.outputs.diff == 'true'
  run: echo "Differences detected"

- name: Handle identical VIs
  if: steps.compare.outputs.diff == 'false'
  run: echo "VIs are identical"
```

### Exit Code Based Branching

```yaml
- name: Compare VIs
  id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
  with:
    base: VI1.vi
    head: VI2.vi
    fail-on-diff: false

- name: Check exit code
  shell: pwsh
  run: |
    $exitCode = [int]'${{ steps.compare.outputs.exitCode }}'
    Write-Host "Exit code: $exitCode"
    
    switch ($exitCode) {
      0 { Write-Host "No differences" }
      1 { Write-Host "Differences found" }
      default { Write-Host "Error occurred"; exit 1 }
    }
```

### Short-Circuit Detection

When base and head resolve to the same path, the action short-circuits without invoking LVCompare:

```yaml
- name: Compare VIs
  id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
  with:
    base: MyVI.vi
    head: MyVI.vi
    fail-on-diff: false

- name: Check short-circuit
  if: steps.compare.outputs.shortCircuitedIdentical == 'true'
  run: echo "Short-circuited - identical paths"
```

## Related Documentation

- [Loop Mode Guide](./COMPARE_LOOP_MODULE.md) - Experimental loop mode for performance testing
- [Integration Tests](./INTEGRATION_TESTS.md) - Running tests with real LabVIEW
- [Troubleshooting](./TROUBLESHOOTING.md) - Common issues and solutions
  - See “Leak Detection and Cleanup” for enabling leak scans (-DetectLeaks), always-on final-sweep reports, and cleanups; direct link: [Troubleshooting#leak-detection-and-cleanup](./TROUBLESHOOTING.md#leak-detection-and-cleanup)
- [Developer Guide](./DEVELOPER_GUIDE.md) - Testing and building the action
- [Environment appendix](./ENVIRONMENT.md) - Environment variables for tests, leak detection, loop mode, and fixture validation
