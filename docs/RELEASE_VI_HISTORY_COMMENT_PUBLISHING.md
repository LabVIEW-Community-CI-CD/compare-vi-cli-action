# Release VI History Comment Publishing

This document defines the unified renderer/publisher used by release-time VI history review workflows.

## Utility

- Script: `tools/Publish-ReleaseVIHistoryComment.ps1`

## Inputs

- Review index JSON: `tests/results/release-vi-history-index/release-vi-history-review.json`
- Policy summary JSON: `tests/results/release-vi-history-index/release-vi-history-policy.json`
- Resolved profile id
- Workflow run URL

## Output

- Comment markdown body: `tests/results/release-vi-history-index/release-vi-history-comment.md`

The body includes:

- profile, policy mode, and policy outcome,
- standardized OS/scenario status table,
- optional violation details block,
- workflow run link.

## Truncation Guard

- Default max comment size: 58,000 characters.
- When exceeded, body is truncated and appends:
  - `NOTE - Comment body truncated for GitHub size safety.`

## Workflow Integration

- `release-vi-history-review-index` always builds the comment body artifact.
- Optional issue publishing is enabled with repo variable:
  - `RELEASE_VI_HISTORY_NOTIFY_ISSUE=<issue-number>`
