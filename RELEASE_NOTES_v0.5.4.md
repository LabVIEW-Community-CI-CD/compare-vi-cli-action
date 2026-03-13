<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.4

Highlights

- Bucket-aware VI compare summaries
  - `tools/VICategoryBuckets.psm1`, `tools/Summarize-VIStaging.ps1`, `tools/Compare-VIHistory.ps1`, and
    `tools/Render-VIHistoryReport.ps1` surface Functional behavior / UI & visual / Metadata bucket totals across
    Markdown, HTML, JSON outputs, and GitHub telemetry so reviewers can triage diffs without downloading artifacts.
  - Staging PR comments and history reports now display bucket columns next to the existing category badges, keeping the
    automation signal consistent with the new acceptance checklist.
- Reporter coverage & docs alignment
  - New unit coverage (`tests/VICategoryBuckets.Tests.ps1`, `tests/Render-VIHistoryReport.Tests.ps1`, expanded history
    and staging suites) guards the bucket mapping and ensures fixtures track canonical slugs/classifications.
  - `docs/knowledgebase/VICompare-Refs-Workflow.md` documents the bucket terminology, acceptance checks, and telemetry
    expectations for downstream dashboards.

Upgrade Notes

- Plan to ingest `bucket-counts-json` (in addition to `category-counts-json`) from CompareVI history/staging outputs.
  The older category-only feeds remain but the new bucket summaries carry the primary signal.
- Report fixtures now rely on normalized slugs (`vi-attribute`, `block-diagram-cosmetic`, etc.); regenerate or update
  local fixtures when extending the bucket catalog.

Validation Checklist

- [x] Pester (hosted Windows) - `Invoke-PesterTests.ps1`, 2025-10-31.
- [x] Pester (self-hosted, IntegrationMode include) - `Invoke-PesterTests.ps1 -IntegrationMode include`, 2025-10-31
  (Integration Runbook Validation).
- [x] Fixture Drift (Windows/Ubuntu) - Fixture Drift Validation run `18963669363`.
- [x] Validate workflow (`Validate / lint`, `Validate / fixtures`, `Validate / session-index`) for `release/v0.5.4` -
  `Validate` workflow (workflow_dispatch) on `release/v0.5.4`.
- [x] Manual VI Compare refs (`vi-compare-refs.yml`) on `release/v0.5.4` - run `18963732460`.
- [x] Session-index leak report clean - `tools/Detect-RogueLV.ps1 -FailOnRogue` (no rogue processes).

Post-Release

- Tag `v0.5.4` on `main` once required checks complete.
- Monitor release workflows (`Validate`, `vi-compare-refs`, staging smoke) and ensure bucket totals render in summaries.
- Run `node tools/npm/run-script.mjs release:finalize -- 0.5.4` to fast-forward `main`/`develop`, draft the GitHub
  release, and archive the finalize metadata.
