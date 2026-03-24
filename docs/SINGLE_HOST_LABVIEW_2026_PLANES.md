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

Treat the TestStand harness as a host-plane consumer, not a fifth plane. It is a deterministic wrapper around native
LabVIEW warmup and LVCompare session capture, so its receipts still belong to one of the native planes rather than to a
separate execution category.

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

## Lease-backed lane protocol

Shared host surfaces must use a software four-phase handshake before an agent treats a Docker or premium native lane as
owned:

1. `request`
2. `grant`
3. `commit` plus `heartbeat`
4. `release`

Use the checked-in helper when you need a replayable lease receipt:

- `node tools/npm/run-script.mjs priority:lane:docker:handshake -- --action request --lane-id docker-agent-epicurus-linux-01 --agent-id epicurus --agent-class subagent --capability docker-lane`

The resulting report is written to:

- `tests/results/_agent/runtime/docker-lane-handshake.json`

The durable handshake state lives under the Git common-dir so clean worktrees share one lease view.

### Premium Sagan dual-lane rule

Only `sagan` may lease `docker-lane` and `native-labview-2026-32` simultaneously.

- required capabilities:
  - `docker-lane`
  - `native-labview-2026-32`
- required authorization:
  - `operatorAuthorizationRef`
- billable multiplier:
  - `1.5x` the configured operator labor rate

Subagents may lease isolated Docker lanes, but they must not activate the premium dual-lane combination.

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
     in one receipt. The status receipt now also carries the plan provenance
     fields (`plan.path`, `plan.schema`, `plan.source`,
     `plan.recommendedBundleId`, `plan.selectedBundleId`) so agents can trace
     the recommendation that led to the applied bundle without leaving the
     checked-in report chain.
5. Fast Docker Desktop lane loops:
   - `node tools/npm/run-script.mjs priority:lane:docker:handshake -- --action inspect --lane-id <lane-id>`
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope linux -StepTimeoutSeconds 600`
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope windows -StepTimeoutSeconds 600`
   - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope both -StepTimeoutSeconds 600`
6. TestStand harness session wrapper:
   - `pwsh -NoLogo -NoProfile -File tools/TestStand-CompareHarness.ps1 -BaseVi <base> -HeadVi <head> -OutputRoot tests/results/teststand-session -Warmup detect -RenderReport`
   - Use this when the host plane needs a deterministic native compare session with a replayable `session-index.json`.
   - For native LabVIEW 2026 x64/x32 parity on the same host, add:
     - `-SuiteClass dual-plane-parity -LabVIEW64ExePath <x64-labview-exe> -LabVIEW32ExePath <x32-labview-exe>`
   - Dual-plane parity still treats the harness as a host-plane consumer. It does not create a new authority plane;
     it produces a parity receipt across the two existing native planes.
7. Differentiated diagnostics replay:
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
5. Docker lane handshake receipt:
   - `tests/results/_agent/runtime/docker-lane-handshake.json`
6. Fast-loop readiness envelope:
   - `docker-runtime-fastloop-readiness.json`
   - `docker-runtime-fastloop-readiness.md`
7. Fast-loop proof bundle when produced:
   - `docker-fast-loop-proof-*.json`
8. Top-level fast-loop GitHub outputs when `tools/Test-DockerDesktopFastLoop.ps1` runs inside GitHub Actions:
   - `docker-fast-loop-summary-path`
   - `docker-fast-loop-status-path`
   - `docker-fast-loop-host-plane-summary-path`
   - `docker-fast-loop-host-plane-summary-status`
   - `docker-fast-loop-host-plane-summary-sha256`
   - `docker-fast-loop-host-plane-summary-reason`
9. Top-level fast-loop Step Summary when `tools/Test-DockerDesktopFastLoop.ps1` receives `-StepSummaryPath`:
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
   - records `host.osFingerprint` as the canonical Windows upgrade baseline for
     the isolated lane group
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
6. `docker-lane-handshake.json`
   - records request, grant, commit/heartbeat, and release state for one isolated Docker lane
   - projects `host.osFingerprint.isolatedLaneGroupId` into the lease
   - records whether premium Sagan dual-lane mode was requested or granted
   - records the billable operator-equivalent rate derived from the operator cost profile
7. `docker-runtime-fastloop-readiness.json`
   - records the fast-loop verdict and lane outcomes
   - carries the differentiated Docker Desktop plane projection
   - records `hostPlaneSummary.path`, `hostPlaneSummary.status`, and `hostPlaneSummary.sha256`
   - records whether Docker exclusivity was required and whether it was satisfied
8. `docker-fast-loop-proof-*.json`
   - records `hostPlaneSummaryPath`
   - records `hostPlaneSummaryProvenance`
   - records `hashes.hostPlaneSummarySha256`
   - projects GitHub outputs:
     - `docker-fast-loop-proof-host-plane-summary-path`
     - `docker-fast-loop-proof-host-plane-summary-sha256`
9. Top-level `tools/Test-DockerDesktopFastLoop.ps1` GitHub outputs
   - project `docker-fast-loop-summary-path` and `docker-fast-loop-status-path`
   - project `docker-fast-loop-host-plane-summary-path`
   - project `docker-fast-loop-host-plane-summary-status`
   - project `docker-fast-loop-host-plane-summary-sha256`
   - project `docker-fast-loop-host-plane-summary-reason`
   - keep success and fail-closed summary provenance available to downstream workflow consumers without reopening JSON
10. Top-level `tools/Test-DockerDesktopFastLoop.ps1` Step Summary
   - appends `### Docker Fast Loop Summary`
   - prints the same summary path and status path surfaced through GitHub outputs
   - prints host-plane summary path, status, SHA-256, and fail-closed reason
   - preserves the missing-summary reason before the script throws
11. `history:diagnostics:show`
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
   explicit and replayable. The resulting report now includes `dockerRuntimeCutover`, which tells you whether the
   current Docker state is already reusable as a Linux daemon (`pinned-wsl2-linux-daemon` or `desktop-linux-engine`)
   or whether the host still needs an explicit cutover before you can safely reuse it from unknown operator state.
   The same contract also carries the restore mode (`wsl-shutdown`, `desktop-engine-switch-to-windows`, `none`, or
   `manual`) so the cleanup path stays machine-readable.
6. Use `priority:lane:concurrency:apply` when you need the plan projected into a machine-readable execution receipt
   instead of leaving the launched hosted lanes and deferred manual/shadow lanes implicit.
7. Use `priority:lane:concurrency:status` when you need to answer whether the applied hosted lane is still active,
   merge-queued, or fully settled without raw GitHub polling.
8. When summarizing a run, name the exact plane identifier instead of saying “host” or “Docker” without qualification.
9. Do not treat `native-labview-2026-32` as a release or CI authority surface; it is a shadow accelerator only.
10. Treat `tools/TestStand-CompareHarness.ps1` as a deterministic consumer of a native plane. Its `session-index.json`
    is useful evidence, but it does not create a new authority plane.
11. Use the Docker-lane handshake before assigning an isolated Docker lane to a background agent so exclusivity,
    billable rate, and host fingerprint stay replayable.
12. When a parity run needs both native LabVIEW 2026 planes at once, use `-SuiteClass dual-plane-parity` and keep the
    output tied to the same `host.osFingerprint.isolatedLaneGroupId` as the surrounding host-plane receipts.
12. Only Sagan may request simultaneous `docker-lane` plus `native-labview-2026-32`, and that request must carry an
    explicit `operatorAuthorizationRef`.
13. Compare `host.osFingerprint.fingerprintSha256` before and after host
    upgrades. If it changes, treat the new value as a moved canonical host OS
    baseline rather than attributing the drift to the workload first.
14. Use `host.osFingerprint.isolatedLaneGroupId` as the replayable identifier
    for this canonical Windows baseline when documenting or comparing isolated
    local lane groups.

## Related contracts

- [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)
- [concurrent-lane-apply-receipt-v1.schema.json](schemas/concurrent-lane-apply-receipt-v1.schema.json)
- [concurrent-lane-status-receipt-v1.schema.json](schemas/concurrent-lane-status-receipt-v1.schema.json)
- [concurrent-lane-plan-v1.schema.json](schemas/concurrent-lane-plan-v1.schema.json)
- [docker-lane-handshake-v1.schema.json](schemas/docker-lane-handshake-v1.schema.json)
- [docker-lane-handshake-report-v1.schema.json](schemas/docker-lane-handshake-report-v1.schema.json)
- [labview-2026-host-plane-report-v1.schema.json](schemas/labview-2026-host-plane-report-v1.schema.json)
- [Write-LabVIEW2026HostPlaneDiagnostics.ps1](../tools/Write-LabVIEW2026HostPlaneDiagnostics.ps1)
- [concurrent-lane-apply.mjs](../tools/priority/concurrent-lane-apply.mjs)
- [concurrent-lane-status.mjs](../tools/priority/concurrent-lane-status.mjs)
- [concurrent-lane-plan.mjs](../tools/priority/concurrent-lane-plan.mjs)
- [docker-lane-handshake.mjs](../tools/priority/docker-lane-handshake.mjs)
- [Test-DockerDesktopFastLoop.ps1](../tools/Test-DockerDesktopFastLoop.ps1)
- [TestStand-CompareHarness.ps1](../tools/TestStand-CompareHarness.ps1)
- [Show-DockerFastLoopDiagnostics.ps1](../tools/Show-DockerFastLoopDiagnostics.ps1)
