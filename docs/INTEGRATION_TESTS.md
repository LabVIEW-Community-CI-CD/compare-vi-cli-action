# Integration Tests for compare-vi-cli-action

The integration test suite exercises the real LabVIEW Compare CLI (`LVCompare.exe`) and optionally `LabVIEWCLI.exe` for HTML report generation. These tests are skipped automatically when prerequisites are not present.

## Prerequisites

| Requirement | Purpose | Default Path / Source |
|-------------|---------|------------------------|
| LVCompare.exe | Core compare engine | `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe` |
| LabVIEWCLI.exe (optional) | HTML comparison report operations | `C:\Program Files\National Instruments\LabVIEW 2025\LabVIEWCLI.exe` (or 32-bit equivalent) |
| Environment variable `LV_BASE_VI` | Path to a baseline VI file | Your repository or test assets |
| Environment variable `LV_HEAD_VI` | Path to a modified VI file | Your repository or test assets |

Both `LV_BASE_VI` and `LV_HEAD_VI` must point to existing files; they should be different when validating diff scenarios.

See also: [Environment appendix](./ENVIRONMENT.md) for a consolidated list of environment variables used across tests and scripts.

## Skip Behavior

The file `tests/CompareVI.Integration.Tests.ps1` computes a boolean `$script:CompareVIPrereqsAvailable`. If prerequisites are missing:

- A single prerequisite test is marked skipped.
- All dependent CompareVI integration tests use `-Skip:(-not $script:CompareVIPrereqsAvailable)` to avoid failures.
- LabVIEWCLI-specific tests similarly use `$script:LabVIEWCLIAvailable`.

This design prevents container-level failures during discovery and keeps CI green on runners without LabVIEW installed.

## Enabling Full Integration Run

1. Install LabVIEW with the Compare feature (LVCompare) and (optionally) LabVIEW CLI.

1. Set environment variables:

  ```powershell
  $env:LV_BASE_VI = 'C:\Path\To\VI1.vi'
  $env:LV_HEAD_VI = 'C:\Path\To\VI2.vi'
  ```

1. Verify paths:

  ```powershell
  Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  Test-Path $env:LV_BASE_VI
  Test-Path $env:LV_HEAD_VI
  ```

1. Run the dispatcher including integration tests:

  ```powershell
  # Recommended CI leak defaults
  $env:CLEAN_AFTER = '1'
  $env:KILL_LEAKS = '1'
  $env:LEAK_GRACE_SECONDS = '1.0'
  ./Invoke-PesterTests.ps1 -IncludeIntegration true -DetectLeaks
  ```

To include HTML report tests also verify:

```powershell
Test-Path 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEWCLI.exe'
```

## Initialization Approach

The integration test script (`tests/CompareVI.Integration.Tests.ps1`) now performs prerequisite checks and initialization directly, without a separate helper function.

- Canonical paths and environment variable values are captured in the script.
- Existence of required files is evaluated inline.
- The boolean `$script:CompareVIPrereqsAvailable` is set for skip gating.

## Local Development Tips

### Timing Metrics

When using the action or calling `Invoke-CompareVI` directly, an execution duration (seconds) is recorded and surfaced as:

- Return object property `CompareDurationSeconds` (renamed from `DurationSeconds`)
- Step summary line `Duration (s): <value>`
- Output file key `compareDurationSeconds=<value>` when `GitHubOutputPath` is used
- HTML report field when `Render-CompareReport.ps1` is passed `-DurationSeconds`

```powershell
./scripts/Test-IntegrationEnvironment.ps1 -JsonPath tests/results/integration-env.json
```

Exit code `0` = ready, `1` = missing one or more prerequisites (informational).

- You can create lightweight placeholder `.vi` files just to satisfy path checks, but real diff semantics require actual LabVIEW VI files.
- Keep large binary VIs out of the repo; store test assets in an internal location or generate them during CI provisioning.
- Use a self-hosted Windows runner with LabVIEW installed for full coverage.

## Troubleshooting

| Issue | Symptom | Resolution |
|-------|---------|-----------|
| Prereqs reported missing | All CompareVI tests skipped | Verify LVCompare.exe path and env vars set before dispatch run |
| Unexpected failures in CompareVI tests | Error binding Base/Head parameters | Ensure env vars are non-empty valid file paths |
| HTML report tests skipped | Skip message about LabVIEWCLI not installed | Install LabVIEW CLI or ignore if not needed |

## Roadmap Ideas

- Add a PowerShell script to validate/prime integration environment (checking versions, printing diagnostics).
- Parameterize canonical LVCompare path via env var (e.g., `LVCOMPARE_PATH`) for flexibility across LabVIEW versions.
- Collect performance timing for compare operations when enabled.

---
Maintained with the test dispatcher architecture. See `AGENTS.md` and `PESTER_DISPATCHER_REFINEMENT.md` for broader context.
