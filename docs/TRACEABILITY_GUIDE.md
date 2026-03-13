<!-- markdownlint-disable-next-line MD041 -->
# Traceability Matrix Guide

Maps Pester test files to requirements (`docs/requirements/**.md`) and ADRs (`docs/adr/**`).
Outputs JSON and optional HTML under `<ResultsRoot>/_trace/`
(`tests/results/_trace/` for the default root, or `tests/results/single/_trace/`
when the single-strategy job is active).

## Annotating tests

Preferred: Pester tags.

```powershell
Describe 'My Feature' -Tag 'Unit','REQ:REQ_FOO','ADR:0001' {
  It 'behaves' { 1 | Should -Be 1 }
}
```

Fallback: header comment (first 50 lines).

```powershell
# trace: req=REQ_FOO,REQ_BAR adr=0001|0002
Describe 'Legacy' -Tag 'Unit' { ... }
```

- Requirement IDs mirror filenames under `docs/requirements/` (case-insensitive).
- ADR IDs are four-digit prefixes (e.g., `0001`).

## Generating the matrix

```powershell
# JSON only
pwsh -File scripts/Invoke-PesterSingleLoop.ps1 -TraceMatrix

# JSON + HTML
pwsh -File scripts/Invoke-PesterSingleLoop.ps1 -TraceMatrix -RenderTraceMatrixHtml
```

Environment shortcuts:

- `TRACE_MATRIX=1` → JSON
- `TRACE_MATRIX_HTML=1` → HTML (+JSON)

## Outputs

- `<ResultsRoot>/_trace/trace-matrix.json` (schema `trace-matrix/v1`)
  - Covers summaries, per-test entries, uncovered requirements/ADRs.
- `<ResultsRoot>/_trace/trace-matrix.html`
  - Human-readable tables with status chips and links to docs/results.

## Validation

- `tests/Traceability.Matrix.Tests.ps1` exercises aggregation.
- Consider adding schema validation (`tools/Validate-TraceMatrix.ps1`) or strict mode failing
  on uncovered requirements.

## Best practices

- Tag each new test with at least one requirement (`REQ:`).
- Reference ADRs when tests verify architectural decisions.
- Review the HTML report locally before enabling traceability in CI.
- When a traceability self-test needs synthetic requirement IDs, construct those IDs at runtime inside the fixture
  content instead of leaving literal `REQ:` examples in the checked-in test file. That keeps production trace-matrix
  scans from reporting fixture-only unknown requirements.
