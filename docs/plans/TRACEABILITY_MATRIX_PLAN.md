# Traceability Matrix Plan — v1.0.0

## Overview

Deliver a deterministic test traceability matrix that maps requirements (`docs/requirements`) and ADRs (`docs/adr`) to Pester test files, producing both machine-readable (`trace-matrix.json`) and optional human-readable (`trace-matrix.html`) outputs. Integrate the matrix with the new single-invoker workflow while keeping the feature opt-in for CI.

## Scope

- Build `tools/Traceability-Matrix.ps1` to aggregate annotations, test results, and documentation into a coverage matrix.
- Extend `scripts/Invoke-PesterSingleLoop.ps1` with `-TraceMatrix` and `-RenderTraceMatrixHtml`.
- Document annotation conventions and artifact locations for contributors.
- Provide initial validation (unit/integration tests) without enforcing coverage failures.
- Leave dashboard/CI adoption as a follow-up phase.

## Design Summary

1. **Annotations**
   - Prefer Pester tags (`REQ:ID`, `ADR:ID`); allow `# trace:` comments as fallback.
   - Support multiple IDs per test; merge tag/comment keys.

2. **Matrix Outputs**
   - JSON: `tests/results/_trace/trace-matrix.json` (`trace-matrix/v1` schema).
   - Optional HTML: `tests/results/_trace/trace-matrix.html` with status chips and links to docs/results.

3. **Outer Loop Integration**
   - Accept CLI flags/env toggles to trigger matrix generation after the Pester invoker loop completes.
   - Pass run ID/seed from session to builder for provenance.

4. **Validation & Testing**
   - Unit tests for annotation parsing, result aggregation, and gap detection.
   - Integration smoke test invoking the outer loop with `-TraceMatrix`.

5. **Documentation**
   - README update + dedicated `docs/TRACEABILITY_GUIDE.md` covering annotations, artifacts, and CLI usage.

## Implementation Steps

1. Implement `tools/Traceability-Matrix.ps1` per the design (JSON + optional HTML).
2. Wire `scripts/Invoke-PesterSingleLoop.ps1` to call the builder when `-TraceMatrix`/env toggles are set.
3. Add new documentation and examples for annotations and artifact inspection.
4. Add unit/integration tests to ensure deterministic outputs and schema compliance.
5. (Optional) Publish `docs/schemas/trace-matrix-v1.schema.json` and helper validation script.
6. Merge behind opt-in flags; plan CI adoption in a follow-up once feedback is gathered.

## Out of Scope (v1.0.0)

- Enforcing coverage failures (`TraceMatrixStrict`).
- Dashboard integration and automatic CI adoption.
- Rich metadata beyond requirement/ADR IDs (e.g., ownership, area tags).

## Future Considerations

- CI enablement on key workflows once telemetry proves stable.
- Dashboard panel rendering of the JSON matrix.
- Strict mode or policy gates for uncovered requirements/ADRs.

