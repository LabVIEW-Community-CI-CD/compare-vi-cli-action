# Release VI History Trends

This document defines Phase 7 historical analytics outputs for release-time VI history review.

## Builder

- Script: `tools/Build-ReleaseVIHistoryTrend.ps1`

## Inputs

- `tests/results/release-vi-history-index/release-vi-history-review.json`
- `tests/results/release-vi-history-index/release-vi-history-policy.json`
- Resolved profile, tag, and run URL

## Outputs

- Normalized historical summary snapshot:
  - `tests/results/release-vi-history-index/history/summary-<tag>.json`
- Trend JSON:
  - `tests/results/release-vi-history-index/release-vi-history-trend.json`
- Trend markdown:
  - `tests/results/release-vi-history-index/release-vi-history-trend.md`

## Schema Validation

- Schema: `docs/schemas/release-vi-history-trend-v1.schema.json`
- Validation command:
  - `node tools/npm/run-script.mjs release:vi-history:trend:schema`

## Workflow Integration

- `release-vi-history-review-index` now builds trend artifacts on every release tag run.
- Trend files are included in the existing `release-vi-history-review-index` artifact bundle.
