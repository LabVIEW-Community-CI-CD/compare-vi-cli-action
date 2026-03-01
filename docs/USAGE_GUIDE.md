<!-- markdownlint-disable-next-line MD041 -->
# Usage Guide

Configuration patterns for the LVCompare GitHub Action.

## lvCompareArgs

The `lvCompareArgs` input accepts a raw string or array of flags passed directly to LVCompare.
Quotes and spaces are preserved. The action now defaults to full-detail compares; provide
`lvCompareArgs` only when you need to reapply noise filters.

Common noise filters:

```yaml
lvCompareArgs: "-noattr -nofp -nofppos -nobd -nobdcosm"
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
    lvCompareArgs: "-noattr -nofp -nofppos -nobd -nobdcosm"
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
    -VI1 "C:\path\VI1.vi" -VI2 "C:\path\VI2.vi" `
    -ReportType HTMLSingleFile -ReportPath "CompareReport.html" `
  -noattr -nofp -nofppos -nobd -nobdcosm
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
  -OutputPath compare-report.html
```

## NI Windows container compare (local)

Use the local helper when you want deterministic compare execution against NI's Windows image without changing the
composite action default path.

Preflight Docker mode/image:

```powershell
node tools/npm/run-script.mjs compare:docker:ni:windows:probe
```

Expected probe prerequisites:

- Docker Desktop daemon mode is `windows`.
- Image is present locally (default: `nationalinstruments/labview:2026q1-windows`).

Run compare (base/head provided by environment):

```powershell
$env:LV_BASE_VI = (Resolve-Path .\VI1.vi).Path
$env:LV_HEAD_VI = (Resolve-Path .\VI2.vi).Path
node tools/npm/run-script.mjs compare:docker:ni:windows
```

Direct invocation with optional overrides:

```powershell
pwsh -File tools/Run-NIWindowsContainerCompare.ps1 `
  -BaseVi .\VI1.vi `
  -HeadVi .\VI2.vi `
  -Image nationalinstruments/labview:2026q1-windows `
  -ReportType html `
  -TimeoutSeconds 600
```

The helper writes deterministic artifacts beside the report:

- `ni-windows-container-capture.json`
- `ni-windows-container-stdout.txt`
- `ni-windows-container-stderr.txt`

Capture diagnostics include:

- `classification` (`ok`, `diff`, `timeout`, `preflight-error`, `labview-cli-connection`, `run-error`)
- `labviewCliErrorCode` (parsed NI CLI error code when present)
- `recommendation` (actionable remediation text for known failure classes)
- `reportExists` (whether the expected report file was produced)

Exit semantics:

- `0`: no differences (or probe success).
- `1`: differences detected (or CLI-level compare error; inspect capture `status/message`).
- `2`: preflight/configuration error (mode/image/path).
- `124`: timeout.

Known runtime issue:

- If capture `classification` is `labview-cli-connection` with `labviewCliErrorCode=-350000`, the NI image runtime on
  that host could not establish LabVIEW CLI connectivity for the operation. Use the emitted stdout/stderr artifacts for
  remediation and image validation.

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

## Composite action limitations

- The composite action always invokes LVCompare directly; it does not honor `LVCI_COMPARE_MODE` or
  `LVCI_COMPARE_POLICY`. Those toggles apply to harness/workflow helpers only.
- LVCompare cannot compare two different files that share the same filename (e.g., `.../A/Thing.vi` vs
  `.../B/Thing.vi`). The composite action will surface this limitation. Use the CLI‑based harness workflows if you need
  to handle same‑filename compares (they generate an HTML report via LabVIEW CLI).
