<!-- markdownlint-disable-next-line MD041 -->
# Integration Runbook (Real LVCompare)

Steps for validating a self-hosted Windows runner (or workstation) using the real LVCompare
CLI and the repository scripts.

## Phase summary

| Phase | Goal | Entry point |
| ----- | ---- | ----------- |
| 0 – Preconditions | PowerShell 7+, repo access | manual checks |
| 1 – Canonical CLI | Ensure LVCompare at default path | `scripts/Test-IntegrationEnvironment.ps1` |
| 2 – VI inputs | Verify `LV_BASE_VI` / `LV_HEAD_VI` exist and differ | inline |
| 3 – Single compare | Run one diff and capture metrics | `scripts/CompareVI.ps1` |
| 4 – Integration tests | Execute Pester with `-IncludeIntegration` | `Invoke-PesterTests.ps1` |
| 5 – Loop soak | Multi-iteration latency / diff loop | `scripts/Run-AutonomousIntegrationLoop.ps1` |
| 6 – Diagnostics | Optional raw CLI capture | inline |

`Invoke-IntegrationRunbook.ps1` orchestrates all phases with logging and artefact capture.

## Canonical LVCompare path

The action only accepts the default location:

```text
C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe
```

Quick validation:

```powershell
Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
```

## Environment variables

| Variable | Purpose |
| -------- | ------- |
| `LV_BASE_VI`, `LV_HEAD_VI` | Default VI inputs (used by scripts) |
| `LV_NO_ACTIVATE`, `LV_SUPPRESS_UI`, `LV_CURSOR_RESTORE` | Guard LV UI behaviour |
| `CLEAN_LV_BEFORE`, `CLEAN_LV_AFTER`, `CLEAN_LV_INCLUDE_COMPARE` | Runner unblock guard defaults |
| `LOOP_ITERATIONS`, `LOOP_TIMEOUT_SECONDS` | Control autonomous loop runs |

## Quick sequence

```powershell
pwsh -File scripts/Test-IntegrationEnvironment.ps1
pwsh -File scripts/CompareVI.ps1 -Base $env:LV_BASE_VI -Head $env:LV_HEAD_VI
./Invoke-PesterTests.ps1 -IncludeIntegration true
pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1 -MaxIterations 25
```

Artifacts land under `tests/results/` (compare evidence, loop JSON, Pester results).

## Helpful scripts

- `tools/Close-LVCompare.ps1` - closes LVCompare gracefully or kills after timeout.
- `tools/Detect-RogueLV.ps1` - scans for rogue LabVIEW/LVCompare processes.
- `tools/Invoke-DevDashboard.ps1` - publishes dashboard with loop/lock telemetry.
- `tools/Download-RunLogs.ps1` - pulls a workflow run's job logs (unzipped) into a tidy folder and emits a manifest.
- `tools/Validate-LVComparePreflight.ps1` - validates canonical LVCompare path, bitness policy (x64 on x64 OS), and optionally checks VI inputs.
- `scripts/CompareVI.LabVIEWCLI.ps1` (auto-invoked when `LVCI_COMPARE_MODE=labview-cli`) - wraps `LabVIEWCLI.exe CreateComparisonReport` to generate XML/HTML/TXT/DOCX compare artifacts without switching the required LVCompare gate.

## Troubleshooting quick wins

| Symptom | Suggestion |
| ------- | ---------- |
| LVCompare missing | Reinstall LabVIEW or copy canonical CLI from a known-good runner |
| Loop hang | Inspect loop log (`tests/results/loop/**`) and enable leak detection |
| Integration tests fail | Review Pester output, rerun single compare, confirm fixtures |
| x86 LVCompare on x64 OS | Run `tools/Validate-LVComparePreflight.ps1 -AppendStepSummary` and install 64-bit LVCompare |

## Branch protection and non-required checks

- Keep deterministic gates required per `tools/policy/branch-required-checks.json`.
- UI/Dispatcher Smoke (`.github/workflows/ui-smoke.yml`) is non-required by design; do not add it to required status checks. Use it for fast feedback without invoking LVCompare.
- LabVIEW CLI Compare (`.github/workflows/cli-compare.yml`) remains non-required; use it to vet `CreateComparisonReport` runs while the canonical LVCompare path stays required.

## References

- [`README.md`](../README.md)
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)
- [`docs/COMPARE_LOOP_MODULE.md`](./COMPARE_LOOP_MODULE.md)
- [`docs/FIXTURE_DRIFT.md`](./FIXTURE_DRIFT.md)
