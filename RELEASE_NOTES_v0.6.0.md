<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.0

Highlights

- LVCompare auto-config helper
  - `tools/New-LVCompareConfig.ps1` discovers LabVIEW/LVCompare/LabVIEWCLI installs, scaffolds
    `configs/labview-paths.local.json`, and verifies the setup so local diff sessions can run without manual edits.
    `tools/Run-LocalDiffSession.ps1` wraps the flow, archives artifacts under `tests/results/_agent/local-diff/latest*`,
    and powers the refreshed VS Code tasks (including a stateless option).
  - `Verify-LocalDiffSession.ps1` now offers `-AutoConfig`/`-Stateless`, improved diagnostics, and dedicated coverage to
    guard the helper pipeline.
- Full-detail compare defaults
  - `tools/Run-HeadlessCompare.ps1`, `tools/Run-DX.ps1`, `tools/TestStand-CompareHarness.ps1`,
    `tools/Run-StagedLVCompare.ps1`, and `module/CompareLoop/CompareLoop.psm1` default to `-NoiseProfile full`, keeping
    the historical suppression bundle available via `-NoiseProfile legacy`.
  - README, Usage Guide, troubleshooting notes, and VS Code tasks were updated to explain the new defaults and the
    optional legacy mode.

Upgrade Notes

- Local diff tooling now writes `configs/labview-paths.local.json` when auto-config succeeds; opt into `-Stateless` (or
  use the dedicated VS Code task) if you prefer to re-discover LabVIEW/LVCompare paths on every run.
- Compare harnesses emit unsuppressed diffs by default. Pass `-NoiseProfile legacy` (or use the “legacy noise” VS Code
  task) when you need quieter diffs during manual reviews.

Validation Checklist

- [ ] Pester (hosted Windows) - `Invoke-PesterTests.ps1`, 2025-11-02.
- [ ] Pester (self-hosted, IntegrationMode include) - `Invoke-PesterTests.ps1 -IntegrationMode include`, 2025-11-02.
- [ ] Fixture Drift (Windows/Ubuntu) - Fixture Drift Validation run.
- [ ] Validate workflow (`Validate / lint`, `Validate / fixtures`, `Validate / session-index`) for `release/v0.6.0` -
  `Validate` workflow (workflow_dispatch) on `release/v0.6.0`.
- [ ] Manual VI Compare refs (`vi-compare-refs.yml`) on `release/v0.6.0`.
- [ ] Session-index leak report clean - `tools/Detect-RogueLV.ps1 -FailOnRogue`.

Post-Release

- Tag `v0.6.0` on `main` once required checks complete.
- Monitor release workflows (`Validate`, `vi-compare-refs`, staging smoke) and ensure the auto-config tasks surface in
  summaries.
- Run `node tools/npm/run-script.mjs release:finalize -- 0.6.0` to fast-forward `main`/`develop`, draft the GitHub release, and archive the
  finalize metadata.
