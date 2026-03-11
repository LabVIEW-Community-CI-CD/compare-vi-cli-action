<!-- markdownlint-disable-next-line MD041 -->
# Runtime Harness Core

This package is the start of the repo-agnostic orchestration core described in
the external runtime design.

It is intentionally not the `compare-vi-cli-action` adapter. The core owns:

- runtime state artifacts
- supervisor state and control flow
- worker step/status/stop/resume execution
- observer/daemon loop orchestration
- scheduler decision artifacts and planner handoff
- bounded worker task-packet artifacts and adapter handoff
- lease-aware turn execution
- deterministic event, lane, blocker, and turn artifacts

The adapter owns repository-specific policy:

- repo root resolution
- owner identity
- lease backend
- repository identity
- scheduler inputs such as issue ranking, PR promotion, and queue policy hooks

## Current state

- package boundary exists
- worker helpers live in `packages/runtime-harness/worker.mjs`
- observer/daemon helpers live in `packages/runtime-harness/observer.mjs`
- compare-vi wrapper still lives at
  `tools/priority/runtime-supervisor.mjs`
- compare-vi Linux-only daemon wrapper lives at
  `tools/priority/runtime-daemon.mjs`
- Docker Desktop launcher scaffolding lives at
  `tools/priority/Start-RuntimeDaemonInDocker.ps1`
- Docker Desktop lifecycle control lives at
  `tools/priority/Manage-RuntimeDaemonInDocker.ps1`
- org-fork release rehearsal now stages and verifies the package through
  `tools/priority/js-package-release.mjs` and
  `.github/workflows/runtime-harness-package-rehearsal.yml`
- upstream is still the only final ship authority for the package surface

## Adapter contract

Adapters must provide:

- `resolveRepoRoot(context)`
- `resolveOwner(context)`
- `resolveRepository(context)` or rely on the default slug resolution
- `acquireLease(options, context)`
- `releaseLease(options, context)`

Adapters may also provide:

- `planStep(context)` to turn repo-native backlog state into the next worker
  step before each daemon cycle
- `prepareWorker(context)` to create or reuse a deterministic worker checkout
  for the selected lane before the worker step runs
- `bootstrapWorker(context)` to bootstrap that allocated checkout into a ready
  lane state before later worker cycles reuse it
- `activateWorker(context)` to attach that ready checkout onto its deterministic
  lane branch before real repo-native work runs
- `buildTaskPacket(context)` to compile the one-turn worker packet that the next
  execution seam should consume from durable runtime state
- `executeTurn(context)` to consume that packet after a successful worker step
  and emit a durable execution receipt when the adapter owns a real unattended
  action

The observer persists scheduler evidence under the runtime directory:

- `scheduler-decision.json` for the latest decision
- `scheduler-decisions/*.json` for per-cycle decision history
- `observer-heartbeat.json` now includes the latest scheduler decision summary
- `worker-checkout.json` for the latest prepared worker checkout
- `workers/*.json` for per-lane worker checkout state
- `worker-ready.json` for the latest worker readiness state
- `workers-ready/*.json` for per-lane worker readiness history
- `worker-branch.json` for the latest worker branch-activation state
- `workers-branch/*.json` for per-lane worker branch attachment history
- `task-packet.json` for the latest bounded worker packet
- `task-packets/*.json` for per-cycle task-packet history
- `execution-receipt.json` for the latest adapter execution result
- `execution-receipts/*.json` for per-cycle execution receipt history

Observer loop control flags:

- `--stop-on-idle` exits cleanly after the planner reports no actionable work
  instead of sleeping forever.
- `--execute-turn` invokes the adapter execution hook after each successful
  worker step.

The compare-vi adapter now uses those controls for guarded fork-mirror drain
mode:

- planner preference is live standing-priority state for the target repo
- canonical upstream issues still remain read-only
- fork mirror issues can be closed and advanced deterministically
- cadence-only standing issues stop the loop cleanly instead of spinning

The compare-vi repository is the first adapter implementation.

## Linux daemon surface

The portable observer loop is intentionally Linux-only. The repo wrapper can run
it directly on a Linux host or inside a Linux container while reusing the same
runtime artifact layout under `tests/results/_agent/runtime/`.

On Windows hosts using Docker Desktop, the repo-level Docker manager now
acquires the Linux context automatically under a host-wide engine lock before
issuing lifecycle commands.

That manager also classifies detached daemons from the observer heartbeat as
`healthy`, `stale`, `wedged`, or `not-running`, persists a health artifact, and
restarts stale or wedged running containers deterministically on `start`.
It also exposes a `reconcile` control path that scans persisted lane state under
`tests/results/_agent/`, replays `start` as the repair primitive per lane, and
writes an aggregate `docker-daemon-reconcile.json` report.
