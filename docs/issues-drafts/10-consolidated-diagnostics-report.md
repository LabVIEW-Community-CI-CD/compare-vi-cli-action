# Consolidated diagnostics report artifact

**Labels:** diagnostics, enhancement

## Summary

Provide a single consolidated diagnostics JSON (and optional HTML) artifact aggregating: run summary, loop metrics, stray process events, percentile strategy, environment discovery notes, and any non-fatal warnings.

## Motivation

- Easier one-file triage vs. collecting multiple artifacts.
- Enables downstream tooling to parse a stable schema for dashboards.

## Scope

- New script: `scripts/Generate-ConsolidatedDiagnostics.ps1`.
- Input sources:
  - Existing `compare-loop-summary.json` (if loop mode).
  - NDJSON event stream (aggregate counts + first/last timestamps per event type).
  - Run summary schema (recorded percentiles, diff counts).
  - Discovery classification results (soft vs strict, suppressed failures list).
- Outputs:
  - `consolidated-diagnostics.json` (always when invoked).
  - Optional `consolidated-diagnostics.html` (switch `-Html`).

## Schema Strategy

- New schema file: `docs/schemas/consolidated-diagnostics.schema.json` (versioned, additive forward strategy).
- Top-level fields (stable ordering):
  1. `schema`
  2. `version`
  3. `generatedAtUtc`
  4. `sourceMode` (`single`|`loop`)
  5. `quantileStrategy`
  6. `run`
  7. `events`
  8. `warnings`

## Acceptance Criteria

- [ ] JSON passes schema validation test.
- [ ] HTML (if generated) deterministic ordering & HTML-encoded.
- [ ] Unit tests cover empty event stream, populated stream, loop vs single.
- [ ] Documentation: README diagnostics section + schema helper updated.
- [ ] Action optionally emits path as output when enabled.

## Risks

- Schema creep; mitigate with strict additive policy and version bump discipline.
- Large NDJSON streams; mitigate by summarizing counts + exemplar samples only.
