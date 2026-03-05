<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.4 - Summary & Checklist

Summary

- Bucket-aware VI compare summaries. The helpers
  (`tools/VICategoryBuckets.psm1`, `tools/Summarize-VIStaging.ps1`, `tools/Compare-VIHistory.ps1`,
  `tools/Render-VIHistoryReport.ps1`) now surface Functional behavior / UI & visual / Metadata bucket totals across
  Markdown, HTML, and GitHub outputs so reviewers can triage diffs without downloading artifacts.
- Reporter coverage & docs alignment. New unit suites (`tests/VICategoryBuckets.Tests.ps1`,
  `tests/Render-VIHistoryReport.Tests.ps1`, expanded staging/history tests) and updated docs/acceptance checklists keep
  the new bucket signals under test.

Release Artifacts

- Notes: `RELEASE_NOTES_v0.5.4.md`
- Changelog section: `CHANGELOG.md` (`v0.5.4`)

Validation (must be green)

- [x] Pester (hosted Windows) - `Invoke-PesterTests.ps1`, 2025-10-31.
- [x] Pester (self-hosted, IntegrationMode include) - `Invoke-PesterTests.ps1 -IntegrationMode include`, 2025-10-31
  (Integration Runbook Validation).
- [x] Fixture Drift (Windows/Ubuntu) - Fixture Drift Validation run `18963669363`.
- [x] Validate workflow (release/v0.5.4) - `Validate` workflow (workflow_dispatch) on `release/v0.5.4`.
- [x] Manual VI Compare refs (`vi-compare-refs.yml`) - run `18963732460`.
- [x] Session-index leak report clean - `tools/Detect-RogueLV.ps1 -FailOnRogue` (no processes detected).

Upgrade Notes

- Downstream automation can now consume `bucket-counts-json` and bucket columns from staging/history reports; update any
  dashboards parsing category-only data to use the new fields.
- Report fixtures and acceptance checklists expect bucket terminology (Functional behavior, UI / visual, Metadata); keep
  new tests in sync when adding fixtures.

Post-Release

- Tag v0.5.4 on `main`.
- Monitor release workflows (`Validate`, `vi-compare-refs`, staging smoke) to ensure bucket totals render as expected.
- Fast-forward `develop` from `release/v0.5.4` (handled via `node tools/npm/run-script.mjs release:finalize -- 0.5.4`) and track any follow-up
  fixes (fixture drift, additional bucket coverage).
