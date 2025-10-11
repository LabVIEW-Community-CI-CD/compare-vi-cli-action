<!-- markdownlint-disable-next-line MD041 -->
# Integration Runbook (Real LVCompare)

Steps for validating a self-hosted Windows runner (or workstation) using the real LVCompare
CLI and the repository scripts.

## Phase summary

| Phase | Goal | Entry point |
| ----- | ---- | ----------- |
| Prereqs | PowerShell 7+, repo access, baseline env | `Invoke-PhasePrereqs` |
| CanonicalCli | Ensure LVCompare canonical path is reachable | `Invoke-PhaseCanonicalCli` |
| ViInputs | Validate `LV_BASE_VI` / `LV_HEAD_VI` exist and differ | `Invoke-PhaseViInputs` |
| Compare | Run one LVCompare diff and capture metrics | `Invoke-PhaseCompare` |
| Tests | Execute dispatcher tests (unit + optional integration component) | `Invoke-PhaseTests` |
| Loop | Multi-iteration latency / diff loop (autonomous harness) | `Invoke-PhaseLoop` |
| Diagnostics | Optional raw CLI capture & console watcher | `Invoke-PhaseDiagnostics` |

`Invoke-IntegrationRunbook.ps1` orchestrates all phases with logging and artefact capture. The Tests
phase now emits a per-component breakdown:

- **Unit** always runs unless explicitly excluded and surfaces its own result folder
  (`tests/results/runbook-tests-*/unit`). The runbook JSON captures test totals, failures, and example paths.
- **Integration** runs only when `-IncludeIntegrationTests` (or `RUNBOOK` env toggles) are set. When no files
  are discovered the component is explicitly skipped with a reason, so dashboards/agents know whether the
  omission was intentional.
- Each component records summary insight (exit code, duration, flags), discovery samples from the manifest,
  and the first few failures when present. The runbook step summary renders a table with this metadata to
  aid triage without digging through artifacts.
- The smoke suites pulled in by default live in `tools/runbook-tests.manifest.json`, pairing
  `Runbook.Unit.Smoke.Tests.ps1` with an optional integration companion. Override the manifest or supply
  `RUNBOOK_*` toggles when you need a broader slice. The manifest also supports coarse `timeoutSeconds`
  and `perTestSeconds` hints which the runbook converts into `TimeoutSeconds` when invoking the dispatcher,
  keeping quick samples from stalling.

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

- `tools/Close-LVCompare.ps1` – closes LVCompare gracefully or kills after timeout.
- `tools/Detect-RogueLV.ps1` – scans for rogue LabVIEW/LVCompare processes.
- `tools/Invoke-DevDashboard.ps1` – publishes dashboard with loop/lock telemetry.

## Troubleshooting quick wins

| Symptom | Suggestion |
| ------- | ---------- |
| LVCompare missing | Reinstall LabVIEW or copy canonical CLI from a known-good runner |
| Loop hang | Inspect loop log (`tests/results/loop/**`) and enable leak detection |
| Integration tests fail | Review Pester output, rerun single compare, confirm fixtures |

## References

- [`README.md`](../README.md)
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)
- [`docs/COMPARE_LOOP_MODULE.md`](./COMPARE_LOOP_MODULE.md)
- [`docs/FIXTURE_DRIFT.md`](./FIXTURE_DRIFT.md)
