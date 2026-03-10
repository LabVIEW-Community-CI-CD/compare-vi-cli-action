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
- publication is blocked on stabilizing the adapter surface

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

The observer persists scheduler evidence under the runtime directory:

- `scheduler-decision.json` for the latest decision
- `scheduler-decisions/*.json` for per-cycle decision history
- `observer-heartbeat.json` now includes the latest scheduler decision summary

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
