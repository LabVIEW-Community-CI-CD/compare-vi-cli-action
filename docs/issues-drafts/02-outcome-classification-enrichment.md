# Enrich outcome block with deeper classification breakdown

**Labels:** telemetry, schema, enhancement

## Summary

Add additive structure to the dispatcher `outcome` block to clarify which dimensions triggered failure or elevated status (discovery vs execution vs infra vs timeout vs retry recovery).

## Rationale

- Improves triage automation (dashboards & bots can highlight primary fault domain).
- Reduces need for downstream log scraping to infer failure class.
- Keeps existing fields stable while allowing future expansion.

## Proposed Additions

- New nested object `classificationBreakdown` (optional):
  - `discoveryErrors`
  - `executionFailures`
  - `infrastructureErrors`
  - `timeouts`
  - `retryRecovered` (bool) – future ready
- Minor schema version bump only (additive).

## Acceptance Criteria

- [ ] Schema file updated with new optional object (minor bump).
- [ ] Tests verifying absence by default & presence when enabled.
- [ ] README / schema docs updated.
- [ ] No breaking changes to existing consumers (backward parse success).

## Backward Compatibility

- Unknown object must be safely ignored by clients not yet updated.
- Maintain existing `overallStatus`, `severityRank`, and `flags` semantics.

## Implementation Notes

- Populate fields during dispatcher final aggregation phase.
- Derive `discoveryErrors` from existing discovery failure counter if promoted.
- Infrastructure vs execution distinction: execution = assertion failures; infra = non-test errors / exceptions.

## Risks

- Misclassification if error mapping logic insufficiently granular (mitigate with tests & sample logs).

## Follow-Up Ideas

- Add `firstFailureType` field for ultra-fast classification in large runs.
