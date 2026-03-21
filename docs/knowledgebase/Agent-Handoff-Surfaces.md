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
- `tests/results/_agent/handoff/entrypoint-status.json`
- `tests/results/_agent/handoff/docker-review-loop-summary.json`
- `tests/results/_agent/handoff/*.json`
- `tests/results/_agent/sessions/*.json`

## Idle Repository Mode

- `queue-empty` is a valid first-class idle state.
- In that mode, handoff tools should report `issue: none (queue empty)` instead
  of inventing a null issue context or failing on stale numeric snapshots.

## Maintenance Rule

- Add current state to generated artifacts, issue comments, or repo docs as
  appropriate.
- Do not append dated execution history back into `AGENT_HANDOFF.txt`.
- For the persistent supervisor design that consumes these surfaces, see
  [`External-Agent-Runtime.md`](./External-Agent-Runtime.md).
