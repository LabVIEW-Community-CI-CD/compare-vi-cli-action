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

## Migration Enforcement Mode (Phase 8)

Migration rollout is controlled by `configs/release-vi-history-migration.json`:

- `hard`: preserve current behavior; policy `fail` fails the job.
- `soft`: downgrade policy `fail` to warning while preserving violation reporting.
- `observe`: record-only mode; policy `fail` is reported but does not fail the job.

When migration mode downgrades a fail, the policy summary includes:

- `rawOutcome`: policy result before migration enforcement,
- `outcome`: effective post-enforcement result,
- `enforcementMode`: active migration mode.

Phase 8 tag-class adoption adds:

- `tagClass`: resolved class for the current tag (`rc` or `stable`),
- `enforcementSource`: where effective mode came from (`migration.policyEnforcementMode` or `migration.tagClassEnforcement.<tagClass>`).

Current rollout policy:

- RC tags default to `soft` enforcement.
- Stable tags default to `hard` enforcement.

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
