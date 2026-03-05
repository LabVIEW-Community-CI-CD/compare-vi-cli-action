# Release Review Platform Plan

This plan is the source of truth for standing priority issue #216 and must stay synchronized with that issue.

## Objective

Turn release validation into a structured review platform where every tag produces:

- independent Windows and Linux review evidence,
- multiple scenario reports per OS,
- policy-driven quality decisions,
- reviewer-facing summary artifacts,
- trendable historical outputs.

## Phase Checklist (Issue-synced)

- [ ] Phase 1 - Contracts and Foundations
- [ ] Phase 2 - Scenario Strategy as Data
- [x] Phase 3 - Evidence Producers (OS x Scenario)
- [x] Phase 4 - Review Index and Reviewer UX
- [ ] Phase 5 - Policy Gate and Promotion Controls
- [ ] Phase 6 - Unified Comment Publishing
- [ ] Phase 7 - Historical Analytics
- [ ] Phase 8 - Hardening and Migration

## Immediate Backlog Status

- [x] Add schema files for release review scenario summaries.
- [x] Add schema validation step(s) for release review outputs.
- [x] Add profile manifest for release review scenario sets.
- [x] Add policy file for required scenario gates.
- [x] Wire policy evaluator into release review index job.
- [x] Add standardized reviewer comment output for release runs.

## Artifacts

- Scenario summary schema: `docs/schemas/release-review-scenario-summary-v1.schema.json`
- Review index schema: `docs/schemas/release-review-index-v1.schema.json`
- Scenario profiles: `tools/release-review/scenario-profiles.json`
- Policy gate file: `tools/policy/release-review-gates.json`
- Scenario writer: `tools/release-review/Write-ReleaseReviewScenarioSummary.ps1`
- Policy evaluator + reviewer output: `tools/release-review/Evaluate-ReleaseReviewPolicy.ps1`
- Workflow wiring: `.github/workflows/release.yml`
