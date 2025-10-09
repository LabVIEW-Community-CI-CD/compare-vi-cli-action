# Traceability Matrix Guide

The traceability matrix links Pester test files to requirements (`docs/requirements`) and
architecture decision records (`docs/adr`). It produces both a structured JSON artifact and an optional
HTML report; both live under `tests/results/_trace/`.

## Annotating Tests

Add requirement and ADR identifiers using either approach:

1. **Pester tags** (preferred):

```powershell
Describe 'My Feature' -Tag 'Unit','REQ:REQ_ID','ADR:0001' {
  It 'does something' { 1 | Should -Be 1 }
}
```

2. **Header comment** (first 50 lines; comma or pipe separated):

```powershell
# trace: req=REQ_FOO,REQ_BAR adr=0001|0002
Describe 'Legacy' -Tag 'Unit' { ... }
```

- Requirement IDs match filenames in `docs/requirements/*.md` (case-insensitive).
- ADR IDs are four-digit prefixes (e.g., `0001`).

## Running the Outer Loop

```powershell
# JSON only
pwsh -File scripts/Invoke-PesterSingleLoop.ps1 -TraceMatrix

# JSON + HTML
pwsh -File scripts/Invoke-PesterSingleLoop.ps1 -TraceMatrix -RenderTraceMatrixHtml
```

Environment overrides:
- `TRACE_MATRIX=1` enables JSON.
- `TRACE_MATRIX_HTML=1` enables HTML (implies JSON).

## Outputs

- `tests/results/_trace/trace-matrix.json` (`trace-matrix/v1`):
  - Summaries, per-test entries, requirement/ADR coverage, and gaps.
- `tests/results/_trace/trace-matrix.html`:
  - Human-readable tables with status chips, links to requirements/ADRs and per-file results.

## Validation & Tooling

- `tests/Traceability.Matrix.Tests.ps1` covers JSON aggregation.
- JSON schema: `trace-matrix/v1` (see plan; add schema file if enforcement needed).
- Optional future ideas:
  - `tools/Validate-TraceMatrix.ps1` schema check.
  - `TraceMatrixStrict` mode to fail on uncovered requirements.

## Best Practices

- Tag each new test with at least one requirement (`REQ:`).
- Prefer direct association with ADRs when tests validate architectural decisions.
- Review `trace-matrix.html` locally before enabling the feature in CI.

