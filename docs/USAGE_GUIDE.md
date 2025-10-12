<!-- markdownlint-disable-next-line MD041 -->
# Usage Guide

Configuration patterns for the LVCompare GitHub Action.

## lvCompareArgs

The `lvCompareArgs` input accepts a raw string or array of flags passed directly to LVCompare.
Quotes and spaces are preserved.

Common noise filters:

```yaml
lvCompareArgs: "-nobdcosm -nofppos -noattr"
```

- `-nobdcosm` – ignore block diagram cosmetic changes.
- `-nofppos` – ignore front panel position/size changes.
- `-noattr` – ignore VI attribute changes.

Specify a LabVIEW path:

```yaml
lvCompareArgs: '-lvpath "C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe"'
```

Log to a temporary path:

```yaml
lvCompareArgs: '--log "${{ runner.temp }}\\lvcompare.log"'
```

Arrays keep each element as a single token, useful when mixing strings and script blocks.

## Working directory

If your VIs live under a subfolder, set `working-directory` to avoid long relative paths:

```yaml
- name: Compare VIs
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.5.0
  with:
    working-directory: my-project
    base: src/VI1.vi
    head: src/VI2.vi
    lvCompareArgs: "-nobdcosm -nofppos -noattr"
```

## Path resolution tips

- `base` and `head` are resolved to absolute paths before invoking LVCompare.
- Relative paths respect `working-directory` (defaults to repository root).
- UNC paths (`\\server\share`) pass through unchanged; no extra escaping required.
- For long paths on Windows, consider mapping a drive or shortening workspace paths.

## HTML comparison reports

Generate a standalone HTML diff via LabVIEWCLI (LabVIEW 2025 Q3+):

```powershell
LabVIEWCLI -OperationName CreateComparisonReport `
  -vi1 "C:\path\VI1.vi" -vi2 "C:\path\VI2.vi" `
  -reportType HTMLSingleFile -reportPath "CompareReport.html" `
  -nobdcosm -nofppos -noattr
```

Benefits: artefact-friendly, visual review, honours noise filters.

Repository helper:

```powershell
pwsh -File scripts/Render-CompareReport.ps1 `
  -Command $env:COMPARE_COMMAND `
  -ExitCode $env:COMPARE_EXIT_CODE `
  -Diff $env:COMPARE_DIFF `
  -CliPath $env:COMPARE_CLI_PATH `
  -DurationSeconds $env:COMPARE_DURATION_SECONDS `
  -OutputPath _staging/compare/compare-report.html
```

## Workflow branching

Basic success/failure handling:

```yaml
- name: Compare VIs
  id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.5.0
  with:
    base: VI1.vi
    head: VI2.vi
    fail-on-diff: false

- name: React to differences
  if: steps.compare.outputs.diff == 'true'
  run: echo "Differences found"
```

Exit code switch:

```yaml
- name: Inspect exit code
  shell: pwsh
  run: |
    $code = [int]'${{ steps.compare.outputs.exitCode }}'
    switch ($code) {
      0 { "No differences" }
      1 { "Differences found" }
      default { Write-Error "LVCompare error" }
    }
```

Short-circuit detection (`base == head`):

```yaml
- name: Check shortcut
  if: steps.compare.outputs.shortCircuitedIdentical == 'true'
  run: echo "Comparison skipped (identical paths)"
```

## Related docs

- [`COMPARE_LOOP_MODULE.md`](./COMPARE_LOOP_MODULE.md) – loop mode and autonomous runner.
- [`FIXTURE_DRIFT.md`](./FIXTURE_DRIFT.md) – manifest requirements and evidence capture.
- [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) – leak detection, recovery, environment setup.
- [`DEVELOPER_GUIDE.md`](./DEVELOPER_GUIDE.md) – local testing and build commands.
- [`ENVIRONMENT.md`](./ENVIRONMENT.md) – environment variables for loop mode, leaks, fixtures.
