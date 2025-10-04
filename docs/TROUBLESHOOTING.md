# Troubleshooting Guide

This guide covers common issues and solutions when using the compare-vi-cli-action.

## Table of Contents

- [Installation and Path Issues](#installation-and-path-issues)
- [Exit Codes and Behavior](#exit-codes-and-behavior)
- [Performance Issues](#performance-issues)
- [Path Resolution Problems](#path-resolution-problems)
- [Loop Mode Issues](#loop-mode-issues)
- [Test Environment Issues](#test-environment-issues)

## Installation and Path Issues

### LVCompare.exe Not Found

**Symptom:** Action fails with "LVCompare.exe not found at canonical path"

**Resolution:**

1. Verify LVCompare is installed at the exact canonical path:

   ```powershell
   Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
   ```

2. Only the canonical path is supported. If using `LVCOMPARE_PATH` or `lvComparePath`, they must resolve to this exact location.

3. Ensure LabVIEW 2025 Q3 or later is installed with the Compare feature enabled.

### Custom Path Not Recognized

**Symptom:** Setting `lvComparePath` or `LVCOMPARE_PATH` doesn't work

**Resolution:**

The action requires the CLI to exist at the canonical path. Custom paths are validated but must ultimately resolve to:

```text
C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe
```

This design ensures consistent behavior across runners and prevents PATH pollution issues.

## Exit Codes and Behavior

### Understanding Exit Code Mapping

The action maps LVCompare exit codes to outputs:

- **Exit code 0** → `diff=false` (no differences)
- **Exit code 1** → `diff=true` (differences detected)
- **Any other code** → Error (comparison failed)

### Unexpected Exit Codes

**Symptom:** Exit code is neither 0 nor 1 (e.g., 2, -1, 127)

**Resolution:**

1. Check the action step summary for error details
2. Verify both VI files are valid and accessible
3. Ensure LabVIEW version supports the VI file format
4. Check for file permission issues
5. Review LVCompare CLI documentation for specific error codes

### Diff Output is Blank or Unexpected

**Symptom:** `diff` output is empty or doesn't match expected result

**Resolution:**

- Inspect `exitCode` output first
- Only exit codes 0 and 1 map to semantic diff states
- Other exit codes indicate errors that should be investigated
- Review `command` output to see exact CLI invocation

## Performance Issues

### Comparison Takes Too Long

**Symptom:** Comparison exceeds expected duration

**Possible Causes and Solutions:**

1. **Large or complex VIs**
   - Consider using `-nobdcosm -nofppos -noattr` to skip cosmetic comparisons
   - Profile with `compareDurationSeconds` output

2. **Network/UNC path overhead**
   - Use `working-directory` for shorter relative paths
   - Consider mapping network drives on self-hosted runners

3. **Antivirus scanning**
   - Add LabVIEW and LVCompare directories to AV exclusions
   - Exclude workspace directory from real-time scanning

### Loop Mode Performance

**Symptom:** Loop iterations are slower than expected

**Resolution:**

1. Use `loop-interval-seconds: 0` for maximum throughput

2. Consider streaming percentile strategy for lower memory overhead

3. Check system resources (CPU, memory, disk I/O)

4. Review `averageSeconds` and `totalSeconds` outputs for bottlenecks

## Path Resolution Problems

### Relative Paths Not Resolving

**Symptom:** Action can't find VI files specified with relative paths

**Resolution:**

1. Verify current working directory:

   ```yaml
   - name: Show working directory
     run: pwd
   ```

2. Use `working-directory` input to set base path:

   ```yaml
   with:
     working-directory: my-project
     base: src/VI1.vi
     head: src/VI2.vi
   ```

3. Or use absolute paths from `${{ github.workspace }}`

### UNC Paths Failing

**Symptom:** Long UNC paths cause errors

**Resolution:**

1. Map a drive letter on self-hosted runner:

   ```powershell
   net use Z: \\server\share
   ```

2. Enable long path support in Windows:

   ```powershell
   New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
     -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force
   ```

3. Use shorter workspace-relative paths via `working-directory`

### Paths with Spaces

**Symptom:** Paths containing spaces cause parsing errors

**Resolution:**

The action handles space-containing paths automatically. For `lvCompareArgs`, use quotes:

```yaml
lvCompareArgs: '-lvpath "C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe"'
```

## Loop Mode Issues

### Loop Percentiles Empty or Incorrect

**Symptom:** `p50`, `p90`, `p99` outputs are empty or zero

**Possible Causes:**

1. **Insufficient iterations** - Increase `loop-max-iterations`
2. **All iterations skipped** - Check for validation errors
3. **Simulation mode** - Ensure not using simulation with zero delay causing skips

**Resolution:**

```yaml
with:
  loop-enabled: true
  loop-max-iterations: 100  # Increase for better percentile accuracy
  loop-interval-seconds: 0.1  # Add small delay if needed
```

### HTML Diff Summary Missing

**Symptom:** Expected diff summary file not created

**Expected Behavior:**

The HTML diff summary fragment is only written when `DiffCount > 0`. If no diff iterations occurred, the file will not be created (this is intentional).

**Resolution:**

Check the `diffCount` output. If it's 0, no summary is expected.

### Histogram Not Generated

**Symptom:** `histogramPath` output is empty

**Resolution:**

Histogram generation requires `histogram-bins` input to be set:

```yaml
with:
  loop-enabled: true
  histogram-bins: 20  # Must be > 0
```

### Reservoir Metrics Unstable

**Symptom:** Percentile values (especially p99) swing unexpectedly between runs

**Resolution:**

1. Increase `stream-capacity`:

   ```yaml
   with:
     quantile-strategy: StreamingReservoir
     stream-capacity: 2000  # Increase from default
   ```

2. Enable periodic reconciliation:

   ```yaml
   with:
     quantile-strategy: Hybrid
     reconcile-every: 100
   ```

3. Use `Exact` strategy for small iteration counts (< 500)

## Test Environment Issues

### Integration Tests Skipped

**Symptom:** All CompareVI integration tests show as skipped

**Resolution:**

Prerequisites are missing. Verify:

1. **LVCompare installed at canonical path:**

   ```powershell
   Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
   ```

2. **Environment variables set:**

   ```powershell
   $env:LV_BASE_VI = 'C:\Path\To\VI1.vi'
   $env:LV_HEAD_VI = 'C:\Path\To\VI2.vi'
   ```

3. **VI files exist:**

   ```powershell
   Test-Path $env:LV_BASE_VI
   Test-Path $env:LV_HEAD_VI
   ```

See [Integration Tests Guide](./INTEGRATION_TESTS.md) for complete prerequisites.

### Test Discovery Failures

**Symptom:** `discoveryFailures > 0` in JSON summary

**Common Causes:**

1. **Uninitialized variables in `-Skip:` expressions**
   - Move variable initialization out of `BeforeAll` to script level
   - Or use `BeforeDiscovery` hook

2. **Filesystem operations at script top-level**
   - Move file creation/deletion into `BeforeAll` or `It` blocks

**Diagnostic Workflow:**

```powershell
$env:DEBUG_DISCOVERY_SCAN = '1'
./Invoke-PesterTests.ps1 -EmitDiscoveryDetail
Get-Content tests/results/discovery-debug.log
```

### Binding Anomalies

**Symptom:** Tests fail with parameter binding errors

**Known Issue:**

PowerShell parameter binding anomaly can inject null values during Pester discovery. This has been resolved in current tests by avoiding top-level `$TestDrive` operations.

**Resolution:**

Ensure all `$TestDrive` and dynamic file creation occurs inside `BeforeAll` or `It` blocks, never at script top-level during discovery.

### Leak Detection and Cleanup

Symptom: LabVIEW or LVCompare processes remain running after tests, or background Pester jobs persist between runs.

Resolution:

- The dispatcher (`Invoke-PesterTests.ps1`) supports opt-in leak detection and cleanup.
- Enable detection and (optionally) auto-kill with new switches or environment variables.

Parameters (PowerShell):

- `-DetectLeaks` — emit `tests/results/pester-leak-report.json` describing leaked processes/jobs.
- `-FailOnLeaks` — fail the run if leaks are detected.
- `-LeakProcessPatterns` — array of process name patterns (wildcards allowed) to treat as leaks. Default: `LVCompare`, `LabVIEW`.
- `-LeakGraceSeconds` — wait this many seconds before final leak check to allow natural shutdown.
- `-KillLeaks` — attempt to stop leaked processes and Pester jobs automatically before reporting.
- `-CleanLabVIEW` / `-CleanAfter` — best-effort pre/post cleanup of `LabVIEW` and `LVCompare`.

For a comprehensive environment variables table covering leak detection, cleanup, and artifact tracking, see the Environment appendix: `docs/ENVIRONMENT.md`.

Example (unit tests only):

```powershell
pwsh -File ./Invoke-PesterTests.ps1 `
   -IncludeIntegration false `
   -CleanLabVIEW -CleanAfter `
   -DetectLeaks -FailOnLeaks -KillLeaks `
   -LeakProcessPatterns LVCompare,LabVIEW `
   -LeakGraceSeconds 0.25
```

Recommended CI defaults (integration): set `CLEAN_AFTER=1`, `KILL_LEAKS=1`, and consider `LEAK_GRACE_SECONDS=1.0` to minimize stragglers. These can also be passed as switches (`-CleanAfter -KillLeaks -LeakGraceSeconds 1.0`).

Artifacts:

- `tests/results/pester-leak-report.json` — rich report with before/after process/job state, actions taken, and detection result (schema: `docs/schemas/pester-leak-report-v1.schema.json`).
- `tests/results/pester-artifacts-trail.json` — optional when `-TrackArtifacts` is enabled; includes `procsBefore`/`procsAfter` snapshots for additional diagnostics.

## Capturing Diagnostic Logs

### LVCompare stderr/stdout

To diagnose unexpected exit codes, capture LVCompare output:

```yaml
- name: Compare VIs
  id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
  with:
    base: VI1.vi
    head: VI2.vi
    fail-on-diff: false

- name: Capture CLI logs
  if: always()
  shell: pwsh
  run: |
    $cmd = '${{ steps.compare.outputs.command }}'
    # Re-run with redirected streams
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.ArgumentList = '-NoLogo','-NoProfile','-Command',$cmd
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    Set-Content raw-stdout.txt $stdout
    Set-Content raw-stderr.txt $stderr
    
- name: Upload logs
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: compare-logs
    path: |
      raw-stdout.txt
      raw-stderr.txt
```

## Getting Help

If you encounter issues not covered here:

1. Check the [Usage Guide](./USAGE_GUIDE.md) for configuration details
2. Review [Integration Tests documentation](./INTEGRATION_TESTS.md)
3. Search existing [GitHub Issues](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues)
4. Open a new issue with:
   - Action version
   - LabVIEW version
   - Complete workflow YAML
   - Error messages and logs
   - `command` and `exitCode` outputs

## Related Documentation

- [Usage Guide](./USAGE_GUIDE.md) - Advanced configuration
- [Developer Guide](./DEVELOPER_GUIDE.md) - Testing and building
- [Integration Tests](./INTEGRATION_TESTS.md) - Test prerequisites
- [Loop Mode Guide](./COMPARE_LOOP_MODULE.md) - Loop mode details
