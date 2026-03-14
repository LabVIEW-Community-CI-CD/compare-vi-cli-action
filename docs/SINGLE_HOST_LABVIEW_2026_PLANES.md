# Single-Host LabVIEW 2026 Planes

This runbook defines how to reason about one Windows host that can operate across four explicit LabVIEW 2026 execution
planes. Use it when you need to diagnose fast-loop output, explain provenance to another operator, or decide which host
surface should run next.

## Plane model

Treat these four planes as distinct:

- `docker-desktop/windows-container-2026`
- `docker-desktop/linux-container-2026`
- `native-labview-2026-64`
- `native-labview-2026-32`

Do not collapse them into a generic “LabVIEW 2026 host” concept. The repo contracts and artifacts are written so future
agents can tell which plane actually produced the evidence.

## Mutual-exclusion rule

The two Docker Desktop planes are mutually exclusive:

- `docker-desktop/windows-container-2026`
- `docker-desktop/linux-container-2026`

That exclusivity must be visible in diagnostics output. If a run does not make it clear which Docker plane was selected,
do not trust the result as replayable evidence.

The native planes are also distinct:

- `native-labview-2026-64`
- `native-labview-2026-32`

They may share supporting tooling paths, but they remain different host planes and must not be reported as one surface.

## Authoritative entry points

Use these commands as the checked-in operator surfaces:

1. Host-plane report:
   - `node tools/npm/run-script.mjs env:labview:2026:host-planes`
2. Fast Docker Desktop lane loops:
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope linux -StepTimeoutSeconds 600`
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope windows -StepTimeoutSeconds 600`
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope both -StepTimeoutSeconds 600`
3. Differentiated diagnostics replay:
   - `node tools/npm/run-script.mjs history:diagnostics:show -- --ResultsRoot tests/results/local-parity/windows`

The replay helper is the fastest operator readback. It prints the host-plane report first and then the differentiated
Docker fast-loop diagnostics for the selected results root.

The host-plane diagnostics helper also writes a companion markdown summary:

- `tests/results/_agent/host-planes/labview-2026-host-plane-summary.md`

Treat that summary as the operator-facing shorthand for the full report. The fast-loop readiness, proof, and replay
surfaces all project provenance back to this file.

## Authoritative artifacts

Use these artifacts as the machine-readable source of truth:

1. Host-plane report:
   - `tests/results/_agent/host-planes/labview-2026-host-plane-report.json`
   - `tests/results/_agent/host-planes/labview-2026-host-plane-summary.md`
2. Fast-loop readiness envelope:
   - `docker-runtime-fastloop-readiness.json`
   - `docker-runtime-fastloop-readiness.md`
3. Fast-loop proof bundle when produced:
   - `docker-fast-loop-proof-*.json`

When the local fast loop runs, prefer the readiness envelope for lane verdicts and the host-plane report for the native
64-bit versus native 32-bit split. For Docker lane replay, use the readiness envelope together with
`history:diagnostics:show`.

## Reading the evidence

Use the artifacts in this order:

1. `labview-2026-host-plane-report.json`
   - confirms the native `x64` and `x32` plane readiness
   - shows the host/runner identity
   - records the mutually exclusive Docker pair and the candidate parallel pairs
2. `labview-2026-host-plane-summary.md`
   - records the operator-facing summary paired with the report
   - is projected into the fast-loop readiness/proof/replay surfaces as provenance
   - should remain hash-stable for a given report payload
3. `docker-runtime-fastloop-readiness.json`
   - records the fast-loop verdict and lane outcomes
   - carries the differentiated Docker Desktop plane projection
   - records `hostPlaneSummary.path`, `hostPlaneSummary.status`, and `hostPlaneSummary.sha256`
   - records whether Docker exclusivity was required and whether it was satisfied
4. `docker-fast-loop-proof-*.json`
   - records `hostPlaneSummaryPath`
   - records `hostPlaneSummaryProvenance`
   - records `hashes.hostPlaneSummarySha256`
   - projects GitHub outputs:
     - `docker-fast-loop-proof-host-plane-summary-path`
     - `docker-fast-loop-proof-host-plane-summary-sha256`
5. `history:diagnostics:show`
   - replays the same distinction in console form for the operator
   - prints `[host-plane-split][summary] <path> status=<status> sha256=<sha256>` when summary provenance exists

If any of those surfaces disagree on the selected plane or exclusivity state, stop and treat the run as not yet
trustworthy.

## Practical rules for future agents

1. Use `-LaneScope linux` or `-LaneScope windows` when you want one Docker plane only.
2. Use `-LaneScope both` only when the run is explicitly about the dual-lane contract.
3. Do not infer the active Docker plane from filenames alone; rely on the readiness envelope and replay helper.
4. Do not infer the active native plane from a generic LabVIEW path; use the host-plane report.
5. When summarizing a run, name the exact plane identifier instead of saying “host” or “Docker” without qualification.

## Related contracts

- [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)
- [labview-2026-host-plane-report-v1.schema.json](schemas/labview-2026-host-plane-report-v1.schema.json)
- [Write-LabVIEW2026HostPlaneDiagnostics.ps1](../tools/Write-LabVIEW2026HostPlaneDiagnostics.ps1)
- [Test-DockerDesktopFastLoop.ps1](../tools/Test-DockerDesktopFastLoop.ps1)
- [Show-DockerFastLoopDiagnostics.ps1](../tools/Show-DockerFastLoopDiagnostics.ps1)
