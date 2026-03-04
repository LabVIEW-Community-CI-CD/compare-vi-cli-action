<!-- markdownlint-disable-next-line MD041 -->
# Requirements Coverage Test Plan

## Objective

Validate requirements-trace coverage changes deterministically before any additional commit activity.

## Scope

- Requirement catalog and threshold policy validation.
- Companion trace test validation.
- Gate behavior and regression safety checks.
- Hook-level enforcement regression checks.

## Preconditions

- Repository root is clean or intentionally staged.
- Baseline policy file exists at `tools/policy/requirements-verification-baseline.json`.
- PowerShell 7 and Node tooling are available.

## Execution order

1. **Companion trace suite**
   - Command:
     - `pwsh -NoLogo -NoProfile -File Invoke-PesterTests.ps1 -TestsPath tests/RequirementsCoverageCompanion.Tests.ps1 -IntegrationMode exclude -ResultsPath tests/results`
   - Pass criteria:
     - 0 failed tests.

2. **Requirements verification gate**
   - Command:
     - `pwsh -NoLogo -NoProfile -File tools/Verify-RequirementsGate.ps1 -OutDir tests/results/_agent/verification-drive-50`
   - Pass criteria:
     - `outcome.status = pass`
     - `metrics.requirementCoveragePercent >= metrics.requirementCoverageTargetPercent`

3. **Gate regression suite**
   - Command:
     - `pwsh -NoLogo -NoProfile -File Invoke-PesterTests.ps1 -TestsPath tests/RequirementsVerificationGate.Tests.ps1 -IntegrationMode exclude -ResultsPath tests/results`
   - Pass criteria:
     - 0 failed tests.

4. **Hook regression suite**
   - Command:
     - `node --test tools/hooks/__tests__/*.mjs`
   - Pass criteria:
     - 0 failed tests.

## Commit guard

Do not create additional commits until all four stages pass.

## Evidence

- `tests/results/_agent/verification-drive-50/verification-summary.json`
- `tests/results/pester-summary.json`
- Terminal output for `tools/hooks/__tests__`
