# Add exit code distribution & error pattern counts to loop summary

**Labels:** telemetry, enhancement

## Summary

Augment loop summary JSON with aggregated `exitCodeCounts` and optional `errorPatternCounts` to provide visibility into iteration exit diversity and recurring errors.

## Rationale

- Supports dashboards (diff vs no-diff ratio, unexpected error prevalence).
- Simplifies post-run forensic analysis without scanning raw logs.

## Proposed Fields

- `exitCodeCounts`: object mapping numeric exit codes to counts (always emitted, empty object if none?).
- `errorPatternCounts` (optional): keyed by normalized pattern id (e.g. `timeout`, `launchFailure`). Only when non-zero.

## Acceptance Criteria

- [ ] Fields added additively; deterministic key ordering when serialized.
- [ ] Tests: (a) no errors (exit 0/1 only), (b) mixed errors, (c) empty distribution edge.
- [ ] README / module docs updated.
- [ ] Performance impact negligible (<2% overhead in synthetic perf test).

## Implementation Notes

- Gather stats inline during iteration rather than post-pass re-scan.
- Consider hashing long stderr lines into category buckets (future enhancement) but start simple.

## Risks

- Over-classification may encourage brittle pattern matching (keep initial patterns minimal & well-documented).
