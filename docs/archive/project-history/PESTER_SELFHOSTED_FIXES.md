<!-- markdownlint-disable-next-line MD041 -->
# Pester Self-Hosted Setup Notes

Summary of fixes and requirements for running Pester on self-hosted Windows runners.

## Recent fixes

- **Workflow parameter passing** (`.github/workflows/test-pester.yml`)
  - Replaced incorrect hashtable syntax with conditional invocation of `tools/Run-Pester.ps1`.
  - Integration flag honoured correctly.

## Integration test prerequisites

| Requirement | Details |
| ----------- | ------- |
| PowerShell | `#Requires -Version 7.0` |
| LVCompare | Canonical path: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe` |
| Environment | `LV_BASE_VI`, `LV_HEAD_VI` point to sample VIs |
| Runner | Labels `[self-hosted, Windows, X64]` |

## Running tests

- **Workflow dispatch**: run "Pester (self-hosted, real CLI)" with `include_integration=true`.
- **PR comment**: `/run pester-selfhosted`.
- **PR label**: add `test-integration` to trigger automatically.

Integration coverage includes CLI presence, diff/no-diff exit codes, and `fail-on-diff` behaviour.

## Next steps

1. Provision/verify self-hosted runner with LabVIEW + LVCompare.
2. Configure repository variables (`LV_BASE_VI`, `LV_HEAD_VI`).
3. Dispatch integration workflow and confirm passing results.

## Current status

- Unit tests: pass (20 run, 2 skipped where CLI absent).
- Markdownlint / actionlint: clean.
- Integration tests: ready (require configured runner).
