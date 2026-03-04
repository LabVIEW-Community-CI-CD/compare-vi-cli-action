# Release VI History Policy Gate

This document defines policy enforcement for release-time VI history review outputs.

## Files

- Policy: `configs/release-vi-history-policy.json`
- Schema: `docs/schemas/release-vi-history-policy-v1.schema.json`

## Policy Selection

Policy mode is selected by the resolved review profile.

- Profile-specific policy is loaded from `profilePolicies` when available.
- Otherwise, `defaultProfilePolicy` is used.

Policy mode values:

- `strict`: policy violations fail the `release-vi-history-review-index` job.
- `warn`: policy violations are reported in the summary and artifact, but do not fail the job.

## Evaluation Contract

For each required `(os, scenario)` pair:

- A row must exist in `release-vi-history-review.json`.
- `gateOutcome` must be one of `allowedGateOutcomes`.
- `resultClass` must be one of `allowedResultClasses`.

The evaluator writes `tests/results/release-vi-history-index/release-vi-history-policy.json` with:

- selected profile and mode,
- required scenarios and OS targets,
- pass/warn/fail outcome,
- violation list and row counts.
