<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.4 - PR Checklist

## Scope

- Bucket metadata module (`tools/VICategoryBuckets.psm1`) wired through staging/history helpers and GitHub outputs.
- Markdown/HTML history reports and staging summaries now list Functional behavior / UI & visual / Metadata buckets.
- New bucket-focused unit tests (`tests/VICategoryBuckets.Tests.ps1`, `tests/Render-VIHistoryReport.Tests.ps1`) and
  updated report fixtures/docs.
- Developer guide / VI compare knowledge base refreshed with bucket acceptance checklist.

## Pre-merge

- [x] Pester tests (windows-latest) green - `Invoke-PesterTests.ps1` (419 tests) 2025-10-31.
- [x] Pester (self-hosted, IntegrationMode include) green - `Invoke-PesterTests.ps1 -IntegrationMode include`
  2025-10-31 (Integration Runbook Validation).
- [x] Fixture Drift (Windows/Ubuntu) green - Fixture Drift Validation run `18963669363`.
- [x] Validate: mergeability probe OK; branch-policy guard OK; docs link check OK - `Validate` workflow
  (workflow_dispatch) on `release/v0.5.4`.
- [x] `vi-compare-refs` auto-publish workflow green for `release/v0.5.4` - run `18963732460`.
- [x] Session-index leak report clean (no rogue LabVIEW/LVCompare after runs) -
  `tools/Detect-RogueLV.ps1 -FailOnRogue`.

## Post-merge

- [ ] Tag v0.5.4 on `main`.
- [ ] Monitor release workflows (`Validate`, `vi-compare-refs`, staging smoke)
  after the tag.
- [ ] Back-merge `release/v0.5.4` into `develop` via `node tools/npm/run-script.mjs release:finalize -- 0.5.4`
  and ensure bucket telemetry docs stay in sync.
