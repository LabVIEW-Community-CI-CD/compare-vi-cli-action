<!-- markdownlint-disable-next-line MD041 -->
# Testing Patterns

Patterns for structuring Pester tests in this repository.

## Function shadowing

- Shadow helper functions inside `It {}` blocks when mocking external tools.
- Remove shadows at end of block to avoid leakage across tests.

## Categories & tagging

- Keep tags concise and meaningful; prefer a small curated set.
- Common tags by dimension:
  - Component: `IconEditor`, `CompareVI`, `Watcher`
  - Feature: `DevMode`, `INI`, `Manifest`, `VIPC`, `Build`
  - Layer: `Unit`, `Integration`, `E2E`, `Smoke`
  - Environment: `RequiresGCLI`, `RequiresLabVIEW`, `RequiresLabVIEW2025`, `RequiresVIPM`, `SelfHosted`
  - Speed: `Slow` (mark long/expensive paths)
- Traceability: add `REQ:XYZ`, `ADR:0001` when linking to requirements or design records.

Examples (Icon Editor):
- Suite: `Describe 'IconEditor …' -Tag 'IconEditor'`
- Unit context (no external tools): `-Tag 'IconEditor','DevMode','Unit'`
- Package validation (VIP smoke): `-Tag 'IconEditor','Packaging','Unit'`
- INI round-trip (real installs): `-Tag 'IconEditor','DevMode','INI','Integration','E2E','RequiresGCLI','RequiresLabVIEW'`

## Dispatcher behaviour

- Prefer the step-based invoker: `scripts/Pester-Invoker.psm1`.
- Use per-file `Invoke-PesterFile` for deterministic artefacts.
- Use `tools/Trace-PesterRun.ps1` to inspect crumbs.

## Skipping & retries

- Gate flaky tests via environment checks (`if (-not $env:RUN_FLAKY) { Skip }`).
- Use watcher options (`-RerunFailedAttempts`) for targeted reruns in local loops.

Further reading: [`docs/SCHEMA_HELPER.md`](./SCHEMA_HELPER.md), [`docs/TRACEABILITY_GUIDE.md`](./TRACEABILITY_GUIDE.md).
