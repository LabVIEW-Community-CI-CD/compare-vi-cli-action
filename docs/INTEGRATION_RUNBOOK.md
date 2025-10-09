# Integration Runbook (LVCompare Real Mode)

This runbook standardizes bringing a self‑hosted Windows runner (or local workstation) into a fully validated state for real (non‑simulated) LabVIEW VI diff comparisons using the composite action and supporting scripts.

## Phases Overview

| Phase | Name | Goal | Core Script(s) |
|-------|------|------|----------------|
| 0 | Preconditions | Confirm PowerShell 7+ and repo accessibility | (inline) |
| 1 | Canonical CLI | Validate `LVCompare.exe` at canonical path | `scripts/Test-IntegrationEnvironment.ps1` |
| 2 | VI Inputs | Ensure `LV_BASE_VI` & `LV_HEAD_VI` exist & distinct | (inline) |
| 3 | Single Compare | One real comparison; capture diff + timings | `scripts/CompareVI.ps1` |
| 4 | Integration Tests | Run Pester suite with `-IncludeIntegration` | `Invoke-PesterTests.ps1` |
| 5 | Loop (Real) | Multi‑iteration latency/diff soak | `scripts/Run-AutonomousIntegrationLoop.ps1` |
| 6 | Diagnostics (Optional) | Capture raw CLI streams / artifacts | (inline) |

You can automate these via `scripts/Invoke-IntegrationRunbook.ps1`.

---

## Canonical Path Policy

LVCompare must exist at:

```text
C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe
```

No alternative path overrides are accepted – the composite action enforces this.

Validation quick check:

```pwsh
Test-Path 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
```

---

## Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `LV_BASE_VI` | Absolute path to baseline VI | Yes |
| `LV_HEAD_VI` | Absolute path to head VI | Yes |
| `LOOP_SIMULATE` | When `1` forces simulation (disable for real loop) | Optional |
| `LOOP_MAX_ITERATIONS` | Loop iteration count (`0` = infinite) | Optional |

Both VI paths must exist. If they resolve to the same absolute path the compare short‑circuits (no CLI call, diff=false).

---

## Orchestration Script (Quick Start)

```pwsh
pwsh -File scripts/Invoke-IntegrationRunbook.ps1 -All -JsonReport runbook-result.json
```

Selective phases:

```pwsh
pwsh -File scripts/Invoke-IntegrationRunbook.ps1 -Phases Prereqs,Compare,Tests
```

JSON result schema (excerpt):

```jsonc
{
  "schema": "integration-runbook-v1",
  "phases": [
    { "name": "Prereqs", "status": "Passed", "details": { "lvComparePresent": true } },
    { "name": "Compare", "status": "Passed", "details": { "exitCode": 1, "diff": true } }
  ]
}
```

Status values: `Passed | Failed | Skipped`.

---

### Runbook Automation Cheatsheet

| Scenario | Command | Notes |
|----------|---------|-------|
| Local quick sanity (prereqs → compare) | `pwsh -File tools/Local-Runbook.ps1` | Uses the `quick` profile (Prereqs, ViInputs, Compare). |
| Include real loop soak | `pwsh -File tools/Local-Runbook.ps1 -IncludeLoop` | Adds the loop phase with default single iteration. |
| CI single-run validation | `pwsh -File scripts/Invoke-IntegrationRunbook.ps1 -All -JsonReport tests/results/runbook/runbook.json` | When `GITHUB_STEP_SUMMARY` is present, a markdown summary is appended automatically. |
| Custom phase list | `pwsh -File scripts/Invoke-IntegrationRunbook.ps1 -Phases Prereqs,Compare -FailOnDiff` | Phases are case-insensitive; `-FailOnDiff` elevates diffs to failures. |

### Outputs & Telemetry

- **Runbook JSON** – Supplying `-JsonReport` writes an `integration-runbook-v1` artifact. The resolved path is linked in the step summary when running inside GitHub Actions.
- **Compare outcome summary** – The compare phase surfaces exit code, diff state, duration, and report path in both console output and the step summary.
- **LV closure crumbs** – Set `EMIT_LV_CLOSURE_CRUMBS=1` to append `tests/results/_diagnostics/lv-closure.ndjson`, capturing LabVIEW/LVCompare PIDs before and after invoker shutdown. Orchestrated workflows set this automatically.
- **Loop artifacts** – Loop phase honours `RUNBOOK_LOOP_ITERATIONS`, `RUNBOOK_LOOP_FAIL_ON_DIFF`, etc., and writes telemetry under `tests/results/_loop`.

---

## Single Compare (Manual)

```pwsh
. scripts/CompareVI.ps1
$res = Invoke-CompareVI -Base $env:LV_BASE_VI -Head $env:LV_HEAD_VI -LvCompareArgs '-nobdcosm -nofppos -noattr' -FailOnDiff:$false
$res | Format-List
```

Key fields: `ExitCode` (0|1), `Diff` (bool), `CompareDurationSeconds`, `ShortCircuitedIdenticalPath`.

---

## Running Integration Tests

```pwsh
pwsh -File Invoke-PesterTests.ps1 -IncludeIntegration true
```

Result summary is written to `tests/results/pester-summary.txt`.

---

## Real Loop Mode

```pwsh
Remove-Item Env:LOOP_SIMULATE -ErrorAction SilentlyContinue
$env:LOOP_MAX_ITERATIONS='25'
$env:LOOP_INTERVAL_SECONDS='0.1'
$env:LOOP_FAIL_ON_DIFF='false'
pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1
```

Add optional metrics:

```pwsh
$env:LOOP_CUSTOM_PERCENTILES='95 97.5'
$env:LOOP_HISTOGRAM_BINS='20'
```

---

## Diagnostics Capture (Manual)

```pwsh
$cmd = '"C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe" "{0}" "{1}" -nobdcosm -nofppos -noattr' -f $env:LV_BASE_VI,$env:LV_HEAD_VI
$psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName='pwsh'; ArgumentList='-NoLogo','-NoProfile','-Command',$cmd; RedirectStandardError=$true; RedirectStandardOutput=$true; UseShellExecute=$false }
$p = [System.Diagnostics.Process]::Start($psi)
$stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit()
Set-Content lvcompare-stdout.txt $stdout -Encoding utf8
Set-Content lvcompare-stderr.txt $stderr -Encoding utf8
"$($p.ExitCode)" | Set-Content lvcompare-exitcode.txt
```

---

## Troubleshooting Quick Table

| Symptom | Cause | Action |
|---------|-------|--------|
| LVCompare missing | Not installed at canonical path | Install to canonical path |
| Exit code > 1 | CLI internal failure | Capture stderr; verify VI opens manually |
| Short-circuited unexpectedly | Same resolved Base/Head path | Correct env var values |
| Loop stops at 1 iteration | FailOnDiff true and diff found | Set `LOOP_FAIL_ON_DIFF=false` |
| Percentiles empty | Too few iterations or errors | Increase iterations / fix errors |
| Histogram absent | `LOOP_HISTOGRAM_BINS` unset | Set a positive bin count |

---

## Orchestration Script Reference

See `scripts/Invoke-IntegrationRunbook.ps1 -Help` for parameters.

---

## Schema & Versioning

Runbook JSON schema: `integration-runbook-v1` (additive fields allowed; do not rename existing keys without a major schema bump).

---

## Next Enhancements (Future Ideas)

* Optional code coverage integration for integration-tagged tests.
* Automatic artifact upload hooks when running under GitHub Actions (detect `GITHUB_ACTIONS`).
* Export loop latency distribution sparkline to Markdown.

---
Maintainers: Update this document if core phase ordering or output keys change.
