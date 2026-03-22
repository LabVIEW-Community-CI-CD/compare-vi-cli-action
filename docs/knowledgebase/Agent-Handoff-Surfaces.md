# Agent Handoff Surfaces

This repository treats agent handoff as a split between a stable checked-in
entrypoint and machine-generated live state.

## Stable Entrypoint

- `AGENT_HANDOFF.txt` is the evergreen human entrypoint.
- It should stay short, stable, and bounded.
- It must not become a rolling execution log or a history dump.

## Live State

- `tools/Print-AgentHandoff.ps1` is the standard producer for current handoff
  output.
- It refreshes `tests/results/_agent/handoff/entrypoint-status.json`, which is
  the canonical machine-readable index for future agents.
- It refreshes `tests/results/_agent/runtime/continuity-telemetry.json` and the
  mirrored handoff summary `tests/results/_agent/handoff/continuity-summary.json`
  so operator quiet periods can be measured without being mistaken for a reset.
- It refreshes `tests/results/_agent/handoff/monitoring-mode.json`, which is the
  machine-readable receipt for compare safe-idle monitoring and future-agent
  template pivot readiness.
- It refreshes `tests/results/_agent/handoff/autonomous-governor-summary.json`,
  which is the top-level machine-readable rollup for the autonomous governor's
  current mode, wake disposition, funding-quality posture, and next owner.
- It refreshes `tests/results/_agent/handoff/downstream-repo-graph-truth.json`,
  which is the machine-readable repo/branch-role map for producer lineage,
  canonical development, and consumer proving across the supervised repos.
- It also refreshes the standing-priority summary, router copy, watcher
  telemetry, Docker/Desktop verification summary mirror, and session capsule
  surfaces under `tests/results/_agent/`.

## Consumer Paths

- `node tools/npm/run-script.mjs handoff:entrypoint:check`
  validates the checked-in entrypoint contract and rewrites the machine-readable
  index.
- `node tools/npm/run-script.mjs priority:handoff`
  imports the handoff bundle and prints the entrypoint index, standing-priority
  snapshot, and other current summaries.
- `node tools/npm/run-script.mjs priority:handoff-tests`
  exercises the contract lane used to keep these handoff surfaces from drifting.

## Canonical Artifacts

- `.agent_priority_cache.json`
- `tests/results/_agent/issue/router.json`
- `tests/results/_agent/issue/standing-lane-reconciliation-*.json`
- `tests/results/_agent/issue/no-standing-priority.json`
- `tests/results/_agent/verification/docker-review-loop-summary.json`
- `tests/results/_agent/runtime/continuity-telemetry.json`
- `tests/results/_agent/handoff/continuity-summary.json`
- `tests/results/_agent/handoff/entrypoint-status.json`
- `tests/results/_agent/handoff/monitoring-mode.json`
- `tests/results/_agent/handoff/autonomous-governor-summary.json`
- `tests/results/_agent/handoff/downstream-repo-graph-truth.json`
- `tests/results/_agent/handoff/docker-review-loop-summary.json`
- `tests/results/_agent/handoff/*.json`
- `tests/results/_agent/sessions/*.json`

## Idle Repository Mode

- `queue-empty` is a valid first-class idle state.
- In that mode, handoff tools should report `issue: none (queue empty)` instead
  of inventing a null issue context or failing on stale numeric snapshots.
- When compare is `queue-empty`, continuity is `maintained` with a `safe-idle`
  turn boundary, and `priority:pivot:template` is `ready`, that is a supported
  handoff state rather than a prompt for operator confirmation.
- In that state, future agents may pivot to canonical
  `LabviewGitHubCiTemplate` from repo evidence alone.

## Monitoring Mode

- `tests/results/_agent/handoff/monitoring-mode.json` is the handoff receipt for
  event-driven monitoring mode.
- `tests/results/_agent/handoff/autonomous-governor-summary.json` is the
  top-level operating summary for the autonomous governor.
- `tests/results/_agent/handoff/downstream-repo-graph-truth.json` is the
  canonical branch-role truth surface for downstream supervision.
- It summarizes:
  - compare queue state
  - continuity state
  - template pivot readiness
  - current governor mode and next owner
  - latest wake lifecycle terminal state
  - funding-quality posture for the latest wake
  - repo graph truth for producer lineage, canonical development, and consumer proving
  - wake conditions that should reopen compare or template work
  - supported downstream monitoring for canonical template and consumer forks
- Template-side monitoring remains passive:
  - canonical template open-issue health
  - fork `develop` alignment to canonical template
  - latest supported `workflow_dispatch` `template-smoke` proof on each fork
- Unsupported fork-local PR validation remains documented but must not reopen
  work by itself.

## Maintenance Rule

- Add current state to generated artifacts, issue comments, or repo docs as
  appropriate.
- Do not append dated execution history back into `AGENT_HANDOFF.txt`.
- For the persistent supervisor design that consumes these surfaces, see
  [`External-Agent-Runtime.md`](./External-Agent-Runtime.md).
