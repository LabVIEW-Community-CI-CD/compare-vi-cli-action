# ADR 0001: Adopt Step-Based Pester Invoker Module

## Status

Accepted — 2025-10-08

## Context

We need deterministic, observable Pester execution that cooperates with higher-level automation.
The legacy dispatcher owned the entire Unit → Integration loop internally, making it difficult
to stream per-file results, enforce timeouts, or let other orchestrators schedule work.

## Decision

- Introduce `scripts/Pester-Invoker.psm1` exposing three primitives:
  `New-PesterInvokerSession`, `Invoke-PesterFile`, and `Complete-PesterInvokerSession`.
- Execute each file in an isolated runspace while staying in-process (no nested `pwsh`).
- Emit `pester-invoker/v1` crumbs (`plan`, `file-start`, `file-end`, `summary`).
- Store per-file results under `tests/results/pester/<slug>/pester-results.xml`.
- Keep `Invoke-PesterTests.ps1` backward-compatible; `-SingleInvoker` simply imports the module
  and defers control to the caller.

## Consequences

- **Benefits**
  - Outer loops control Unit/Integration ordering, retries, and diagnostics while reusing a shared invoker.
  - Deterministic artifacts enable dashboards/tests without scraping console output.
  - Module is reusable by local runbooks or future CI steps.
- **Trade-offs**
  - Slightly more complexity via runspace management.
  - Callers must enforce category policy and aggregate results.

## References

- Requirements: [`docs/requirements/PESTER_SINGLE_INVOKER.md`](../requirements/PESTER_SINGLE_INVOKER.md)
- System Definition: [`docs/requirements/SINGLE_INVOKER_SYSTEM_DEFINITION.md`](../requirements/SINGLE_INVOKER_SYSTEM_DEFINITION.md)
- Implementation: `scripts/Pester-Invoker.psm1`, `scripts/Invoke-PesterSingleLoop.ps1`

