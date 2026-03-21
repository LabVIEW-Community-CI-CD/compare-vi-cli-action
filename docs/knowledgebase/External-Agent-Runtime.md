<!-- markdownlint-disable-next-line MD041 -->
# External Agent Runtime

This document defines the persistent supervisor needed to make the agent behave
continuously outside a single chat/API turn.

The model does not "run forever". The runtime does. It does that by repeatedly
loading fresh state, giving the model a bounded task packet, executing the
checked-in helper surface, persisting evidence, and immediately scheduling the
next turn until one of two stop conditions is true:

- a human explicitly stops the runtime
- no open upstream epics remain in
  `LabVIEW-Community-CI-CD/compare-vi-cli-action`

## Goals

- Drain upstream epic backlog without relying on manual "continue" prompts.
- Keep upstream as the only ship/no-ship authority.
- Reuse repo-native helpers instead of inventing a parallel mutation surface.
- Preserve single-writer safety for files, branches, and GitHub mutations.
- Make every turn restartable from durable state instead of transcript memory.
- Advance a different lane while CI, review, or merge queue waits.

## Non-Goals

- Replacing the checked-in `tools/priority/*` helper layer.
- Bypassing GitHub protections, required checks, or review policy.
- Letting the model hold an unbounded transcript or unmanaged background job.
- Using a single shared mutable checkout for all fork lanes.

## Runtime Topology

| Component | Responsibility | Existing repo surface |
| --- | --- | --- |
| Supervisor | Owns the event loop, stop conditions, ranking, and lease renewal. | `tools/priority/queue-supervisor.mjs` |
| State mirror | Refreshes live GitHub epics, child issues, PRs, checks, and project metadata. | `gh`, `priority:project:portfolio:check` |
| Marketplace registry | Enumerates cross-repo integration, fork, and consumer rails for rankable work stealing. | `tools/priority/lane-marketplace.json`, `priority:lane:marketplace` |
| Lease broker | Prevents overlapping writers in the same repo scope. | `tools/priority/agent-writer-lease.mjs` |
| Worker pool | Maintains isolated worktrees per lane/fork. | git worktrees + `priority:develop:sync` |
| Command broker | Executes repo-native helpers and records fallback evidence. | `bootstrap.ps1`, `priority:pr`, `priority:issue:mirror` |
| CI watcher | Watches hosted/self-hosted checks and wakes waiting lanes. | `ci:watch:rest`, `ci:watch:safe` |
| Evidence sink | Writes runtime state, events, and lane checkpoints. | `tests/results/_agent/` |

## Core Idea

The runtime is an external supervisor process, not a longer prompt. It runs a
bounded loop:

1. Acquire the writer lease for the repo and lane scopes.
2. Refresh live GitHub state from upstream and both fork planes.
3. Recompute open epics, child issues, PRs, blockers, and free fork lanes.
4. Select exactly one highest-value next action.
5. Materialize a dedicated worker checkout for that lane.
6. Call the model with a compact task packet for that one action.
7. Execute the resulting helper/tool calls.
8. Persist evidence and update runtime state.
9. Re-enter the scheduler immediately.

The model stays stateless between turns. The runtime owns continuity.

## Durable State

The runtime should keep its own durable state outside the model transcript and
mirror a compact copy into the repository evidence tree.

Recommended persistent store:

- SQLite for scheduler state and event indexes
- NDJSON append log for operator replay
- repo evidence files under `tests/results/_agent/runtime/`

Recommended repo-visible artifacts:

- `tests/results/_agent/runtime/runtime-state.json`
- `tests/results/_agent/runtime/runtime-events.ndjson`
- `tests/results/_agent/runtime/lanes/<lane-id>.json`
- `tests/results/_agent/runtime/turns/<timestamp>-<lane-id>.json`
- `tests/results/_agent/runtime/last-blocker.json`

Each lane record should include:

- upstream issue number
- parent epic number
- fork remote (`origin`, `personal`, or `upstream`)
- branch name
- PR URL if present
- current blocker class
- worker path
- last heartbeat time
- last meaningful change

## Fork Plane Split

The runtime should treat the fork planes as different delivery roles, not just
different remotes:

- `personal` is the fast hosted code-iteration plane
- `origin` is the org-namespace release rehearsal and post-publish verification
  plane
- `upstream` is the final merge and ship authority

That means the runtime should not send generic feature throughput to `origin`
just because a fork slot is free. The org fork should be reserved for work that
needs the organization namespace itself, such as package publication, GHCR
image rehearsal, provenance checks, and post-publish consumer verification.

## Lease Model

`tools/priority/agent-writer-lease.mjs` already provides the base lock
primitive. The runtime should layer named scopes on top of it instead of adding
new locking rules.

Required logical scopes:

- `workspace` for repo-wide bootstrap and develop-sync activity
- `fork/<remote>` for one active PR lane per fork
- `issue/<number>` for one active lane per child issue
- `upstream-promotion` for the single upstream merge/admission lane

Lease rules:

- renew heartbeat every 30 to 60 seconds
- treat stale leases as recoverable after the configured timeout
- on lease loss, stop writes, persist a checkpoint, and reschedule
- never let two workers mutate the same fork lane or issue lane

## Worker Model

Each active lane gets its own checkout rooted under a runtime-managed working
directory. A worker should never share a mutable checkout with another lane.

Recommended layout:

```text
.runtime/
  bare/
  worktrees/
    origin-977/
    personal-978/
    upstream-981/
```

Worker bootstrap sequence:

1. fetch `upstream`, `origin`, and `personal`
2. sync `develop` with
   `node tools/npm/run-script.mjs priority:develop:sync -- --fork-remote <remote>`
3. check out or reattach the lane branch
4. run `pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1`
5. record the worker as `ready`
6. attach the ready checkout onto the deterministic lane branch
7. refresh local handoff and standing-priority artifacts

Release-rehearsal workers on `origin` may skip the generic PR lane entirely
when the value is in workflow-dispatch publication and consumer verification
rather than ordinary feature CI.

## Model Turn Contract

The runtime should never pass the full historical conversation back to the
model. It should compile a bounded task packet from durable state.

Each task packet should contain:

- repo identity and active lane
- exact objective for this turn
- current branch, PR, and check status
- relevant file paths and prior evidence artifacts
- the last small set of runtime events for this lane
- allowed helper surfaces and known fallbacks

Each turn should have a hard budget, for example:

- one lane
- one primary objective
- one promotion attempt or one blocker fix
- a bounded tool-call count
- a bounded wall-clock timeout

When the budget expires, the runtime persists the result and schedules the next
turn. That is how it behaves continuously without pretending a single reply is
infinite.

## Scheduling Policy

The scheduler should implement the repo's backlog policy directly.

Refresh phase:

1. run bootstrap and standing-priority sync
2. read live upstream issues and PRs
3. repair missing epic or child links before feature work
4. refresh fork mirror issues and fork PR state
5. refresh the cross-repo lane marketplace snapshot when multiple repo rails are enabled

Selection phase:

1. candidate epics are all open upstream epics
2. candidate children are all open non-epic issues attached to open epics
3. rank epics and children using the repo's selection algorithm
4. when the active repo has no immediately actionable lane, consult the cross-repo marketplace ranking
5. choose one action type in this order:
   - fix blocker on an existing upstream PR
   - advance a different child issue on a free fork while upstream waits
   - finish a fork PR that is one iteration from promotion
   - split or repair an open epic with no executable children
   - start the highest-ranked unblocked child issue

Execution phase:

1. acquire required scopes
2. run the bounded model turn
3. watch CI asynchronously
4. on any meaningful state change, reschedule immediately

## Command Surface

The runtime should treat repo helpers as the default mutation API.

Preferred commands:

- `pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1`
- `node tools/npm/run-script.mjs priority:develop:sync`
- `node tools/npm/run-script.mjs priority:project:portfolio:apply`
- `node tools/npm/run-script.mjs priority:github:metadata:apply`
- `node tools/npm/run-script.mjs priority:issue:mirror`
- `node tools/npm/run-script.mjs priority:pr`
- `node tools/npm/run-script.mjs priority:queue:supervisor`
- `node tools/npm/run-script.mjs priority:js-package:release`
- `node tools/npm/run-script.mjs ci:watch:rest`
- `node tools/npm/run-script.mjs ci:watch:safe`

Fallback rule:

- raw `gh` is allowed only when no checked-in helper can perform the action, or
  when reproducing a helper bug with explicit evidence written to the runtime
  event log

## Event Sources

The supervisor should combine polling with GitHub webhooks.

Wake-up sources:

- issue opened, edited, labeled, or relinked
- PR opened, synchronized, reviewed, merged, or closed
- check suite and workflow run state changes
- queue-supervisor readiness changes
- lease stale or worker crash events
- explicit human stop or priority override

Polling is still required as the recovery path when webhooks are missed.

## Failure Handling

Expected failure classes:

- merge blocker
- review blocker
- CI blocker
- scope blocker
- helper/runtime bug
- auth or policy drift

Runtime response:

- classify the blocker explicitly
- attach it to the correct epic if it reveals new scope
- persist evidence paths and API error details
- start the next-best unblocked lane immediately

If a helper bug is discovered, the runtime should create a focused upstream
issue, parent it under the correct epic, and keep moving.

## Human Control Surface

The external runtime needs explicit controls outside the model:

- `start` with repo, model, token source, and workspace root
- `stop` for graceful drain and checkpoint
- `pause` to stop new mutations but keep observing
- `resume` to continue from durable state
- `status` to print current lane, blockers, leases, and recent events

Recommended stop file or command channel:

- `tests/results/_agent/runtime/stop-request.json`

The runtime should check that file before starting a new turn.

## Deployment Shape

Recommended first deployment:

- one always-on supervisor process for the canonical repo
- one host with git, `gh`, Node.js, PowerShell, and token access
- one bare mirror plus per-lane worktrees
- one durable state directory outside the repo checkout

Suitable hosts:

- a Windows service on the existing self-hosted runner
- a long-lived VM with the repo mounted locally
- a containerized worker host if LabVIEW-specific tasks stay on separate runners

## Incremental Rollout

Phase 1:

- single supervisor
- one active fork lane at a time
- polling only
- JSON evidence + SQLite state
- bounded model auto-resume

Phase 2:

- parallel fork lanes with per-fork mutexes
- upstream-promotion mutex
- CI watcher wake-ups
- blocker issue auto-creation
- explicit fork-lane identity receipts carried by priority PR and validate-dispatch reports so workers can resume,
  steal, or hand off work without re-deriving provenance from mutable branch names alone. Current identities are
  `upstream-standing`, `fork-plane-branch`, and `fork-standing-mirror`.

Phase 3:

- webhook ingestion
- adaptive scheduling from queue and SLO artifacts
- richer operator dashboard

## Minimal Pseudocode

```text
while not stopRequested():
  refreshState()
  repairMetadata()
  lane = selectNextLane()
  if lane is None:
    if noOpenUpstreamEpics():
      exit("no-open-epics")
    sleep(shortInterval)
    continue
  with acquireScopes(lane):
    task = compileTaskPacket(lane)
    result = runBoundedModelTurn(task)
    persist(result)
    if result.startedCiWatch:
      armWatcher(lane)
```

## Design Decision

The runtime should be built as a thin external supervisor around the existing
repo contracts, not as a new agent framework embedded in prompts. The repository
already has the right mutation helpers, watcher outputs, lease primitive, and
handoff artifacts. The missing piece is the always-on scheduler that keeps
calling them.

Initial extraction note:

- the portable core now starts in `packages/runtime-harness/`
- the worker and observer loop seams now live in
  `packages/runtime-harness/worker.mjs` and
  `packages/runtime-harness/observer.mjs`
- the observer now calls an adapter scheduler hook before each worker turn and
  persists `scheduler-decision.json` plus per-cycle
  `scheduler-decisions/*.json` artifacts under the runtime directory
- the observer/adapter surface now also has a worker preparation hook so the
  daemon can create or reuse one deterministic checkout per selected lane and
  persist `worker-checkout.json` plus `workers/*.json` metadata
- the next worker lifecycle seam now bootstraps an allocated checkout into a
  ready lane state and persists `worker-ready.json` plus
  `workers-ready/*.json` metadata for resumed daemon turns
- the next daemon seam now also attaches that ready checkout onto the lane's
  deterministic issue branch and persists `worker-branch.json` plus
  `workers-branch/*.json` metadata so later turns can resume from a real lane
  workspace instead of a detached checkout
- the worker/observer seam now also compiles a bounded per-cycle task packet
  from durable runtime state, persists `task-packet.json` plus
  `task-packets/*.json`, and leaves an adapter hook for repo-specific
  objective/helper context before the execution layer is added
- the compare-vi repository wrapper remains at
  `tools/priority/runtime-supervisor.mjs`
- that wrapper now includes the first compare-vi scheduler cut: when no manual
  lane is supplied, it plans from the bootstrapped standing-priority cache or
  router artifacts instead of acting as a heartbeat-only shell
- the compare-vi Linux-only daemon wrapper lives at
  `tools/priority/runtime-daemon.mjs`
- the Docker Desktop Linux launcher now starts at
  `tools/priority/Start-RuntimeDaemonInDocker.ps1`
- the Docker Desktop lifecycle controller now lives at
  `tools/priority/Manage-RuntimeDaemonInDocker.ps1`
  and now acquires the Linux Docker Desktop context automatically under a
  host-wide engine lock before running lifecycle commands
- the Docker manager also now classifies detached daemon health from
  `observer-heartbeat.json`, persists a health artifact, and restarts stale or
  wedged running containers deterministically on `start`
- that same manager now exposes `reconcile`, which scans persisted lane state,
  reapplies `start` as the repair primitive per lane, and writes a shared
  `docker-daemon-reconcile.json` artifact for operator-free recovery
- the first org-fork release-plane slice now stages, packs, optionally
  publishes, and then re-verifies
  `@labview-community-ci-cd/runtime-harness` from a clean consumer context
  through `tools/priority/js-package-release.mjs` and
  `.github/workflows/runtime-harness-package-rehearsal.yml`
