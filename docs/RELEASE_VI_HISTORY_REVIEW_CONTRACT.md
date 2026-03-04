# Release VI History Review Contract

This document defines the Phase 1 contract for release-time VI history review outputs.

## Schemas

- Scenario summary: `docs/schemas/release-vi-history-review-scenario-v1.schema.json`
- Review index: `docs/schemas/release-vi-history-review-index-v1.schema.json`

## Scenario Summary (`scenario-summary.json`)

Each OS/scenario lane publishes one summary file with:

- `schema`: constant `release-vi-history-review/scenario@v1`
- `generatedAt`: UTC timestamp (`date-time`)
- `tag`: release tag
- `os`: `linux` or `windows`
- `scenario`: scenario id (`baseline`, `noattr`, `layout-and-position`, or future ids)
- `flags`: CLI flags string used for this scenario
- `image`: NI container image used for execution
- `compareExit`: compare script process exit code
- `captureExit`: capture payload exit code
- `gateOutcome`: lane policy outcome (`pass`, `warn`, `fail`, or empty when unavailable)
- `resultClass`: result class reported by capture payload
- `status`: lane status string from capture payload
- `message`: lane status message from capture payload
- `reportPath`: local report path produced in job workspace
- `reportExists`: whether the report file exists
- `capturePath`: capture JSON path produced in job workspace

## Review Index (`release-vi-history-review.json`)

The index job publishes a JSON array where each item corresponds to one discovered scenario summary.

Each row includes:

- `os`
- `scenario`
- `flags`
- `status`
- `gateOutcome`
- `resultClass`
- `compareExit`
- `reportExists`
- `artifactPath`

## Validation Hooks

- CI: release workflow validates both schemas in the `release-vi-history-review-index` job.
- Local/pre-push: `tools/PrePush-Checks.ps1` runs `release:vi-history:schema` using the repo npm wrapper.

## Migration Compatibility (Phase 8)

The release index job runs `tools/Normalize-ReleaseVIHistorySummaries.ps1` before index/policy evaluation.

- Purpose: adapt older summary payload aliases to canonical contract fields.
- Behavior: normalization is additive (missing canonical fields are backfilled; existing canonical values are preserved).
- Scope: release artifact processing only; source fixtures and harness outputs are unchanged.
