# Prune outdated examples & consolidate migration notes

**Labels:** docs, cleanup

## Summary

Remove residual transitional migration text after legacy fallback removal and consolidate overlapping guidance across README, runbook, and testing docs.

## Motivation

- Reduce cognitive load for new adopters.
- Eliminate duplicated maintenance surfaces.

## Scope

- Remove migration warning blocks referencing fallback (keep historical CHANGELOG intact).
- Merge duplicate sections (e.g., short-circuit explanation) into single canonical location.
- Ensure troubleshooting content remains but cross-links rather than repeats.

## Acceptance Criteria

- [ ] No deprecated migration note remaining in README (unless in historical version section).
- [ ] Runbook + README have distinct, non-duplicated scopes (overview vs procedural flow).
- [ ] Lint passes (markdownlint).
- [ ] Search for `Migration Note` returns only historical context entries.

## Risks

- Accidental removal of still-referenced instructions (mitigate via targeted search & PR review).
