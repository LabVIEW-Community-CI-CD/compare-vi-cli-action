# Pester Single-Invoker Requirements

## Scope

Provide a deterministic, step-based wrapper around Pester that allows an outer
automation loop to execute test files one-at-a-time (Unit first, Integration
second) without launching nested PowerShell processes. The design must favor
observability and reproducibility over raw throughput.

## Functional Requirements

1. **Session Lifecycle**
   - Expose `New-PesterInvokerSession`, `Invoke-PesterFile`, and
     `Complete-PesterInvokerSession` cmdlets in `scripts/Pester-Invoker.psm1`.
   - `Invoke-PesterFile` executes exactly one test file per call, returning
     immediately to the caller (no internal loops).
   - The API operates in-process (runspace-based) and never launches `pwsh` as
     a child process.

2. **Deterministic Execution**
   - Each call uses a dedicated PowerShell runspace to avoid module/global
     state bleed while remaining in the current process.
   - The invoker captures a stable run ID and seed (defaulting to
     `GITHUB_SHA` or timestamp) and writes them to every crumb.
   - The outer loop controls ordering; documentation must provide a canonical
     Unit-then-Integration example.

3. **Artifacts & Crumbs**
   - Per-file results: `tests/results/pester/<slug>/pester-results.xml` (NUnit).
   - Crumb log: `tests/results/_diagnostics/pester-invoker.ndjson` using
     `pester-invoker/v1` events (`plan`, `file-start`, `file-end`, `summary`).
   - `Invoke-PesterFile` returns `File`, `Category`, `DurationMs` and aggregated
     counts (`passed`, `failed`, `skipped`, `errors`) matching Pester results.

4. **Timeout & Error Handling**
   - Support per-file timeout (seconds). On timeout, mark the result, emit a
     crumb, and return control without terminating the session.
   - Never swallow errors: surfaced via `TimedOut` or non-zero counts and must
     be reflected in the crumb log and the returned object.

5. **Outer Loop Scaffold**
   - Provide `scripts/Invoke-PesterSingleLoop.ps1` to demonstrate the API.
   - Script discovers Unit/Integration files deterministically (lexicographic
     order, optional `IncludePatterns`), runs Unit first, gates Integration on
     Unit success, and reports failures/top slow files to the console.

## Observability Requirements

1. Crumb log must include:
   - `plan`: Pester version, isolation mode, run ID, seed.
   - `file-start` / `file-end`: absolute file path, slug, category, duration,
     counts, timeout flag.
   - `summary`: list of failed files and the top-N slowest entries supplied by
     the outer loop.
2. Step-based invoker must co-exist with existing diagnostics (guard crumbs,
   LV closure crumbs) without conflict.
3. Provide README usage section explaining how to import the module and how
   artifacts are laid out.

## Quality Gates

1. Manual smoke test: running
   `Import-Module ./scripts/Pester-Invoker.psm1; $s=New-PesterInvokerSession;`
   `Invoke-PesterFile; Complete-PesterInvokerSession` must produce:
   - Non-empty crumb log.
   - Per-file results under `tests/results/pester/<slug>/`.
   - Counts reflecting Pester’s PassThru object (e.g., `PassedCount` = 1).
2. `scripts/Invoke-PesterSingleLoop.ps1 -DryRun` lists the deterministic file
   order; executing without `-DryRun` returns non-zero only when any file
   fails or times out.
3. Unit tests (future) should validate crumb schema, timeout handling, and
   soft vs strict isolation parity on a green suite.

## Traceability

- Architectural Decision Record: [ADR 0001](../adr/0001-single-invoker-step-module.md)
- Architectural Decision Record: [`ADR 0001`](../adr/0001-single-invoker-step-module.md)

