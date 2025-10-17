<!-- markdownlint-disable-next-line MD041 -->
# Post-Release Follow-Up Items (v0.4.0 → v0.5.0 Planning)

**Status**: 4 of 10 issues completed and integrated into v0.5.0. Remaining six items are documented below for
future releases.

## Completed Issues (Implemented in v0.5.0)

### ✅ Issue 1 – Remove artifact fallback and expand guard

- Drop legacy `Base.vi`/`Head.vi` name resolution from compare scripts and tests.
- Extend guard coverage across scripts and key docs with migration messaging in the release notes.
- Guard test: `tests/Guard.LegacyArtifactNames.Tests.ps1`.

### ✅ Issue 4 – Documentation pruning and consolidation

- Remove legacy references across README and runbook documentation.
- Collapse duplicate guidance and ensure the migration note reflects the v0.5.0 breaking change.

### ✅ Issue 7 – HTML diff fragment hardening

- Add regression coverage for deterministic HTML list ordering and encoding.
- Fixture test: `tests/CompareLoop.HtmlDiffDeterminism.Tests.ps1` (five tests passing).

### ✅ Issue 8 – Percentile strategy documentation deep dive

- Expand streaming/hybrid quantile accuracy docs with examples and tuning guidance.
- Published in `docs/QUANTILE_ACCURACY.md` (linked from the README).

## Deferred Issues (Future Releases)

The remaining items live in `issues-drafts/` and can be implemented without blocking v0.5.0.

### ⏸️ Issue 2 – Outcome classification enhancements

- Enrich the outcome block with discovery vs. execution vs. infrastructure breakdowns.
- Evaluate severity rank refinements while keeping schema rules additive.

### ⏸️ Issue 3 – Coverage integration (optional)

- Explore lightweight PowerShell-based coverage or alternative tooling for Integration-tagged tests.
- Keep the feature opt-in to avoid unnecessary overhead.

### ⏸️ Issue 5 – Discovery strict mode re-evaluation

- Reassess the default strictness once false positives trend toward zero in v0.4.x telemetry.
- Maintain an escape hatch via environment configuration.

### ⏸️ Issue 6 – Additional loop telemetry

- Capture exit code distribution summaries and error pattern counts in the loop summary.
- Preserve deterministic JSON ordering when aggregating telemetry.

### ⏸️ Issue 9 – Runbook automation hooks

- Auto-upload raw CLI artifacts in the runbook script when running under GitHub Actions.
- Emit step-summary guidance to help operators share artifacts quickly.

### ⏸️ Issue 10 – CI diagnostics synthesis

- Consolidate discovery, outcome, and aggregation hints into a single diagnostics report artifact.
- Compose structured JSON for external dashboards once Issue 6 data is available.

---

## Summary

- **Completed**: Issues 01, 04, 07, 08 implemented in v0.5.0.
- **Deferred**: Issues 02, 03, 05, 06, 09, 10 queued for future releases.
- **Last updated**: 2025-10-03.
- **Implementation tracking**: See `IMPLEMENTATION_STATUS_v0.5.0.md` for detailed status.

### Recommended Implementation Order for Deferred Issues

1. **Issue 06** – Additional loop telemetry (additive schema, high value).
2. **Issue 10** – Diagnostics synthesis (builds on Issue 06).
3. **Issue 02** – Outcome classification (independent, moderate complexity).
4. **Issue 09** – Runbook automation (independent, low risk).
5. **Issue 05** – Discovery strict mode (requires production data review).
6. **Issue 03** – Coverage support (requires tool selection).
