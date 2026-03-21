<!-- markdownlint-disable-next-line MD041 -->
# Unattended Delivery Daemon Surfaces

This page is the bounded daemon-first entrypoint for future agents auditing or
resuming unattended delivery. Use it before opening the larger runtime design
docs or digging through `tools/priority/*`.

## Stable Operator Entry Points

Use these checked-in commands first instead of reaching for ad hoc
`node`/`pwsh` invocations:

- `node tools/npm/run-script.mjs priority:delivery:agent:ensure`
- `node tools/npm/run-script.mjs priority:delivery:agent:status`
- `node tools/npm/run-script.mjs priority:delivery:agent:stop`
- `node tools/npm/run-script.mjs priority:runtime:daemon`
- `node tools/npm/run-script.mjs priority:runtime:daemon:docker`
- `node tools/npm/run-script.mjs priority:runtime:daemon:docker:status`

Prefer `priority:delivery:agent:status` as the first read. That surface already
normalizes manager state, heartbeat fallback, and lane/runtime evidence into one
bounded status payload.

## Canonical Receipt Read Order

When a daemon lane needs diagnosis, read receipts in this order:

1. `tests/results/_agent/runtime/delivery-agent-state.json`
2. `tests/results/_agent/runtime/delivery-agent-lanes/<lane-id>.json`
3. `tests/results/_agent/runtime/delivery-memory.json`
4. `tests/results/_agent/runtime/observer-heartbeat.json`
5. `tests/results/_agent/runtime/task-packet.json`
6. `tests/results/_agent/runtime/codex-state-hygiene.json`
7. `tests/results/_agent/marketplace/lane-marketplace-snapshot.json`

Secondary control-plane receipts worth checking only when the main runtime view
looks stale:

- `tests/results/_agent/runtime/delivery-agent-manager-state.json`
- `tests/results/_agent/runtime/delivery-agent-manager-pid.json`
- `tests/results/_agent/runtime/delivery-agent-manager-stop.json`
- `tests/results/_agent/runtime/delivery-agent-wsl-daemon-pid.json`
- `tests/results/_agent/runtime/daemon-host-signal.json`

## Current Compatibility And Debt Register

### Runtime-state naming split

- `delivery-agent-state.json` is the intended primary runtime receipt.
- `runtime-state.json` is legacy compatibility-only and should only be used as
  a fallback by readers that have not been migrated yet.
- Do not write new primary state to `runtime-state.json`; treat it as tracked
  compatibility debt, not a cue to invent a third receipt family.
- Owner lane: `#1634`.

### Marketplace snapshot contract

- `lane-marketplace-snapshot.json` is already persisted and referenced through
  `artifacts.marketplaceSnapshotPath`.
- The surface is test-backed, but it does not yet have its own checked-in docs
  schema entry.
- Until that is split, trust the persisted path plus the lane-marketplace tests
  over any inferred file naming.

### Thin daemon entrypoint

- `tools/priority/runtime-daemon.mjs` is intentionally a thin CLI wrapper.
- The behavioral authority lives in:
  - `tools/priority/runtime-supervisor.mjs`
  - `tools/priority/delivery-agent.mjs`
  - `tools/priority/lib/delivery-agent-common.ts`
- When behavior and docs disagree, prefer the contract tests below before
  changing runtime code.

## Authoritative Tests

These tests are the fastest way to confirm the daemon contract without opening a
large hosted run:

- `tools/priority/__tests__/runtime-daemon.test.mjs`
- `tools/priority/__tests__/runtime-daemon-docker.test.mjs`
- `tools/priority/__tests__/runtime-supervisor.test.mjs`
- `tools/priority/__tests__/delivery-agent-schema.test.mjs`
- `tools/priority/__tests__/delivery-agent-manager-contract.test.mjs`
- `tools/priority/__tests__/agent-writer-lease.test.mjs`
- `tools/priority/__tests__/codex-state-hygiene.test.mjs`

## Related Runbooks

- [External-Agent-Runtime.md](./External-Agent-Runtime.md)
- [Agent-Handoff-Surfaces.md](./Agent-Handoff-Surfaces.md)
- [DOCKER_TOOLS_PARITY.md](./DOCKER_TOOLS_PARITY.md)
