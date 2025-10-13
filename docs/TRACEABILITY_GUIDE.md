<!-- markdownlint-disable-next-line MD041 -->
# Traceability Matrix Guide

Maps Pester test files to requirements (`docs/requirements/**.md`) and ADRs (`docs/adr/**`).
Outputs JSON and optional HTML under `tests/results/_trace/`.

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

Cross-platform option (no PowerShell dependency):

```bash
dotnet run --project src/CompareVi.Tools.Cli -- trace build --tests tests --results tests/results --out-dir tests/results/_trace --html
```

Environment shortcuts:

- `TRACE_MATRIX=1` → JSON
- `TRACE_MATRIX_HTML=1` → HTML (+JSON)

## Outputs

- `tests/results/_trace/trace-matrix.json` (schema `trace-matrix/v1`)
  - Covers summaries, per-test entries, uncovered requirements/ADRs.
- `tests/results/_trace/trace-matrix.html`
  - Human-readable tables with status chips and links to docs/results.

## Validation

- `tests/Traceability.Matrix.Tests.ps1` exercises aggregation.
- Consider adding schema validation (`tools/Validate-TraceMatrix.ps1`) or strict mode failing
  on uncovered requirements.

## Best practices

- Tag each new test with at least one requirement (`REQ:`).
- Reference ADRs when tests verify architectural decisions.
- Review the HTML report locally before enabling traceability in CI.
