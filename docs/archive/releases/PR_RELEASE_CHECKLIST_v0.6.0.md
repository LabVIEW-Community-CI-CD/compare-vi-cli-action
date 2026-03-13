<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.0 - PR Checklist

## Scope

- LVCompare auto-config helper (`tools/New-LVCompareConfig.ps1`) and wrapper (`tools/Run-LocalDiffSession.ps1`) wired
  through `Verify-LocalDiffSession.ps1`, VS Code tasks, and new stateless mode.
- Compare harnesses (`Run-HeadlessCompare`, `Run-DX`, `TestStand-CompareHarness`, `Run-StagedLVCompare`, CompareLoop)
  default to the full-detail noise profile while keeping the legacy suppression bundle opt-in.
- README, Usage Guide, troubleshooting notes, and investigation docs updated; new unit coverage for the auto-config flow.

## Pre-merge

- [x] Pester tests (windows-latest) green - `Invoke-PesterTests.ps1` (445 tests) 2025-11-02.
- [x] Pester (self-hosted, IntegrationMode include) green - `Invoke-PesterTests.ps1 -IntegrationMode include`
  2025-11-02 (Integration Runbook Validation).
- [ ] Fixture Drift (Windows/Ubuntu) green - Fixture Drift Validation run for `release/v0.6.0`.
- [ ] Validate: mergeability probe OK; branch-policy guard OK; docs link check OK - `Validate` workflow
  (workflow_dispatch) on `release/v0.6.0`.
- [ ] `vi-compare-refs` auto-publish workflow green for `release/v0.6.0`.
- [ ] Session-index leak report clean (no rogue LabVIEW/LVCompare after runs) -
  `tools/Detect-RogueLV.ps1 -FailOnRogue`.

## Post-merge

- [ ] Tag v0.6.0 on `main`.
- [ ] Monitor release workflows (`Validate`, `vi-compare-refs`, staging smoke) after the tag.
- [ ] Back-merge `release/v0.6.0` into `develop` via `node tools/npm/run-script.mjs release:finalize -- 0.6.0`
  and ensure auto-config docs stay in sync.
