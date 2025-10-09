# System Definition – Pester Single-Invoker

## Purpose

Provide a deterministic, observable mechanism to execute Pester test files one
at a time while staying within a single PowerShell process. The system enables
higher-level automation (outer loops, CI workflows, local tooling) to control
sequencing and policy without modifying the dispatcher core.

## Components

1. **Invoker Module (`scripts/Pester-Invoker.psm1`)**
   - `New-PesterInvokerSession`: Initializes a session, assigns `runId`/`seed`,
     and emits a `plan` crumb.
   - `Invoke-PesterFile`: Runs a single test file in an isolated runspace,
     writes `file-start`/`file-end` crumbs, returns per-file results.
   - `Complete-PesterInvokerSession`: Emits a `summary` crumb and finalizes the
     session metadata.
   - Outputs: `tests/results/_diagnostics/pester-invoker.ndjson`, per-file
     `tests/results/pester/<slug>/pester-results.xml`.

2. **Outer Loop Script (`scripts/Invoke-PesterSingleLoop.ps1`)**
   - Discovers Unit/Integration test files deterministically (optional
     include filters).
   - Sequentially calls `Invoke-PesterFile` (Unit first, Integration second if
     Unit passes), tracks failures/timeouts, prints slowest files, and exits
     non-zero on failure.

3. **Existing Dispatcher (`Invoke-PesterTests.ps1`)**
   - Backward-compatible; when `-SingleInvoker` or `SINGLE_INVOKER=1` is set, it
     imports the invoker module but leaves control to the outer loop.

## Interfaces

```powershell
$session = New-PesterInvokerSession -ResultsRoot 'tests/results' -Isolation soft
$result  = Invoke-PesterFile -Session $session -File 'tests/Unit.Tests.ps1' -Category 'Unit' -MaxSeconds 300
Complete-PesterInvokerSession -Session $session -FailedFiles @($result.File)
```

Returned object (`Invoke-PesterFile`):

```text
File        : <absolute path>
Category    : Unit|Integration
Slug        : <normalized file name>
DurationMs  : <int>
TimedOut    : <bool>
Counts      : @{passed=..; failed=..; skipped=..; errors=..}
ResultsXml  : <results path>
ArtifactDir : <directory>
```

## Data Flows

1. Outer loop calls `New-PesterInvokerSession`; module writes a `plan` record
   (seed, Pester version, isolation).
2. For each file: outer loop -> `Invoke-PesterFile` -> runspace executes Pester
   -> crumb events + per-file XML -> result returned to outer loop.
3. After all files: outer loop -> `Complete-PesterInvokerSession`; writes
   summary crumb referencing failed files and top slow entries.

## Non-Functional Requirements

- In-process execution only; no nested `pwsh` or external processes.
- Deterministic file ordering and count aggregation; outer loop is expected to
  provide deterministic sequencing (Unit then Integration).
- Observability: crumb log must contain `plan`, `file-start`, `file-end`,
  `summary` events; per-file artifacts must exist for each execution.
- Extensibility: invoker module can be reused by other tools (dashboards,
  runbooks) without changes to the dispatcher CLI.

## Traceability

- Architectural Decision Record: [`ADR 0001`](../adr/0001-single-invoker-step-module.md)

