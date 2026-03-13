<!-- markdownlint-disable-next-line MD041 -->
# Testing Patterns

Patterns for structuring Pester tests in this repository.

## Function shadowing

- Shadow helper functions inside `It {}` blocks when mocking external tools.
- Remove shadows at end of block to avoid leakage across tests.

## Categories & tagging

- Keep tags concise and meaningful; prefer a small curated set.
- Common tags by dimension:
  - Component: `CompareVI`, `Watcher`, `Dispatcher`
  - Feature: `CLI`, `History`, `Routing`, `Build`
  - Layer: `Unit`, `Integration`, `E2E`, `Smoke`
  - Environment: `RequiresGCLI`, `RequiresLabVIEW`, `RequiresLabVIEW2025`, `SelfHosted`
  - Speed: `Slow` (mark long/expensive paths)
- Traceability: add `REQ:XYZ`, `ADR:0001` when linking to requirements or design records.

Examples (CompareVI):

- Suite: `Describe 'CompareVI CLI session index' -Tag 'CompareVI'`
- Unit context (no external tools): `-Tag 'CompareVI','CLI','Unit'`
- History routing coverage: `-Tag 'CompareVI','History','Unit'`
- Hosted integration path: `-Tag 'CompareVI','Routing','Integration','RequiresGCLI','RequiresLabVIEW'`

## Dispatcher behaviour

- Prefer the step-based invoker: `scripts/Pester-Invoker.psm1`.
- Use per-file `Invoke-PesterFile` for deterministic artefacts.
- Use `tools/Trace-PesterRun.ps1` to inspect crumbs.

## Skipping & retries

- Gate flaky tests via environment checks (`if (-not $env:RUN_FLAKY) { Skip }`).
- Use watcher options (`-RerunFailedAttempts`) for targeted reruns in local loops.

Further reading: [`docs/SCHEMA_HELPER.md`](./SCHEMA_HELPER.md), [`docs/TRACEABILITY_GUIDE.md`](./TRACEABILITY_GUIDE.md).
