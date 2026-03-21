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

## Shadow policy

`native-labview-2026-32` is a shadow acceleration surface, not an authoritative
proof plane.

- role: manual opt-in acceleration fallback
- authoritative: false
- hosted CI: forbidden
- promotion prerequisites:
  - `docker-desktop/linux-container-2026`
  - `docker-desktop/windows-container-2026`

That means the host-native 32-bit plane can help reduce idle time for agents or
humans on a prepared Windows host, but it does not replace the image-backed
Linux or Windows proof lanes. Use it only after the same scenario has an image
proof path.

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
2. Concurrent lane planner:
   - `node tools/npm/run-script.mjs priority:lane:concurrency:plan`
   - Optional Docker runtime input:
     - `node tools/npm/run-script.mjs priority:lane:concurrency:plan -- --docker-runtime-snapshot tests/results/ni-linux-container/runtime-determinism.json`
3. Concurrent lane apply helper:
   - `node tools/npm/run-script.mjs priority:lane:concurrency:apply -- --dry-run`
   - Use this after planning when you need a first-class receipt that records
     which hosted lanes were dispatched and which manual/shadow lanes remained
     explicitly deferred.
4. Concurrent lane status helper:
   - `node tools/npm/run-script.mjs priority:lane:concurrency:status`
   - Use this after apply when you need the current hosted workflow status,
     merge-queue observation, and explicit deferred manual/shadow obligations
     in one receipt.
5. Fast Docker Desktop lane loops:
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope linux -StepTimeoutSeconds 600`
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope windows -StepTimeoutSeconds 600`
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope both -StepTimeoutSeconds 600`
6. Differentiated diagnostics replay:
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
2. Concurrent lane planner:
   - `tests/results/_agent/runtime/concurrent-lane-plan.json`
3. Concurrent lane apply receipt:
   - `tests/results/_agent/runtime/concurrent-lane-apply-receipt.json`
4. Concurrent lane status receipt:
   - `tests/results/_agent/runtime/concurrent-lane-status-receipt.json`
5. Fast-loop readiness envelope:
   - `docker-runtime-fastloop-readiness.json`
   - `docker-runtime-fastloop-readiness.md`
6. Fast-loop proof bundle when produced:
   - `docker-fast-loop-proof-*.json`
7. Top-level fast-loop GitHub outputs when `tools/Test-DockerDesktopFastLoop.ps1` runs inside GitHub Actions:
   - `docker-fast-loop-summary-path`
   - `docker-fast-loop-status-path`
   - `docker-fast-loop-host-plane-summary-path`
   - `docker-fast-loop-host-plane-summary-status`
   - `docker-fast-loop-host-plane-summary-sha256`
   - `docker-fast-loop-host-plane-summary-reason`
8. Top-level fast-loop Step Summary when `tools/Test-DockerDesktopFastLoop.ps1` receives `-StepSummaryPath`:
   - `Summary Path`
   - `Status Path`
   - `Host Plane Summary Path`
   - `Host Plane Summary Status`
   - `Host Plane Summary SHA-256`
   - `Host Plane Summary Reason`

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
3. `concurrent-lane-plan.json`
   - records the current hosted/manual/shadow lane availability
   - projects the host-native 32-bit shadow policy into lane metadata
   - ranks safe concurrent bundles for the present host, RAM, and Docker-runtime state
   - keeps the mutually exclusive local Docker planes out of the same recommended bundle
4. `concurrent-lane-apply-receipt.json`
   - records the selected concurrent bundle actually applied for the current turn
   - records the hosted Validate dispatch helper command and dispatch report path when hosted proof lanes were launched
   - records manual Docker and host-native shadow lanes as explicitly deferred when they remain operator-required
5. `concurrent-lane-status-receipt.json`
   - records the current hosted workflow-run state for an applied bundle when a hosted Validate run id exists
   - records merge-queue-backed PR state when a PR can be resolved from the applied branch or explicit selector
   - keeps deferred manual Docker and host-native shadow lanes explicit for the orchestrator
   - records an orchestrator disposition so worker-slot release decisions do not depend on ad hoc GitHub polling
6. `docker-runtime-fastloop-readiness.json`
   - records the fast-loop verdict and lane outcomes
   - carries the differentiated Docker Desktop plane projection
   - records `hostPlaneSummary.path`, `hostPlaneSummary.status`, and `hostPlaneSummary.sha256`
   - records whether Docker exclusivity was required and whether it was satisfied
7. `docker-fast-loop-proof-*.json`
   - records `hostPlaneSummaryPath`
   - records `hostPlaneSummaryProvenance`
   - records `hashes.hostPlaneSummarySha256`
   - projects GitHub outputs:
     - `docker-fast-loop-proof-host-plane-summary-path`
     - `docker-fast-loop-proof-host-plane-summary-sha256`
8. Top-level `tools/Test-DockerDesktopFastLoop.ps1` GitHub outputs
   - project `docker-fast-loop-summary-path` and `docker-fast-loop-status-path`
   - project `docker-fast-loop-host-plane-summary-path`
   - project `docker-fast-loop-host-plane-summary-status`
   - project `docker-fast-loop-host-plane-summary-sha256`
   - project `docker-fast-loop-host-plane-summary-reason`
   - keep success and fail-closed summary provenance available to downstream workflow consumers without reopening JSON
9. Top-level `tools/Test-DockerDesktopFastLoop.ps1` Step Summary
   - appends `### Docker Fast Loop Summary`
   - prints the same summary path and status path surfaced through GitHub outputs
   - prints host-plane summary path, status, SHA-256, and fail-closed reason
   - preserves the missing-summary reason before the script throws
10. `history:diagnostics:show`
   - replays the same distinction in console form for the operator
   - prints `[host-plane-split][summary] <path> status=<status> sha256=<sha256>` when summary provenance exists

If any of those surfaces disagree on the selected plane or exclusivity state, stop and treat the run as not yet
trustworthy.

## Practical rules for future agents

1. Use `-LaneScope linux` or `-LaneScope windows` when you want one Docker plane only.
2. Use `-LaneScope both` only when the run is explicitly about the dual-lane contract.
3. Do not infer the active Docker plane from filenames alone; rely on the readiness envelope and replay helper.
4. Do not infer the active native plane from a generic LabVIEW path; use the host-plane report.
5. Use `priority:lane:concurrency:plan` before dispatching hosted Windows/Linux plus manual lanes so the plan stays
   explicit and replayable.
6. Use `priority:lane:concurrency:apply` when you need the plan projected into a machine-readable execution receipt
   instead of leaving the launched hosted lanes and deferred manual/shadow lanes implicit.
7. Use `priority:lane:concurrency:status` when you need to answer whether the applied hosted lane is still active,
   merge-queued, or fully settled without raw GitHub polling.
8. When summarizing a run, name the exact plane identifier instead of saying “host” or “Docker” without qualification.
9. Do not treat `native-labview-2026-32` as a release or CI authority surface; it is a shadow accelerator only.

## Related contracts

- [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)
- [concurrent-lane-apply-receipt-v1.schema.json](schemas/concurrent-lane-apply-receipt-v1.schema.json)
- [concurrent-lane-status-receipt-v1.schema.json](schemas/concurrent-lane-status-receipt-v1.schema.json)
- [concurrent-lane-plan-v1.schema.json](schemas/concurrent-lane-plan-v1.schema.json)
- [labview-2026-host-plane-report-v1.schema.json](schemas/labview-2026-host-plane-report-v1.schema.json)
- [Write-LabVIEW2026HostPlaneDiagnostics.ps1](../tools/Write-LabVIEW2026HostPlaneDiagnostics.ps1)
- [concurrent-lane-apply.mjs](../tools/priority/concurrent-lane-apply.mjs)
- [concurrent-lane-status.mjs](../tools/priority/concurrent-lane-status.mjs)
- [concurrent-lane-plan.mjs](../tools/priority/concurrent-lane-plan.mjs)
- [Test-DockerDesktopFastLoop.ps1](../tools/Test-DockerDesktopFastLoop.ps1)
- [Show-DockerFastLoopDiagnostics.ps1](../tools/Show-DockerFastLoopDiagnostics.ps1)
