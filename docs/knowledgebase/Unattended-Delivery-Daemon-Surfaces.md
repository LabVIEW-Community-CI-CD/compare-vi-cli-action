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
- `node tools/npm/run-script.mjs priority:jarvis:status`

Prefer `priority:delivery:agent:status` as the first read. That surface already
normalizes manager state, heartbeat fallback, and lane/runtime evidence into one
bounded status payload.

Use `priority:jarvis:status` when Sagan needs a bounded live watch surface for
the Windows Docker specialty lane family. It emits
`tests/results/_agent/runtime/jarvis-session-observer.json`, summarizes any
active Jarvis sessions, and tails the daemon logs that matter for fast operator
triage.

## Canonical Receipt Read Order

When a daemon lane needs diagnosis, read receipts in this order:

1. `tests/results/_agent/runtime/delivery-agent-state.json`
2. `tests/results/_agent/runtime/delivery-agent-lanes/<lane-id>.json`
3. `tests/results/_agent/runtime/delivery-memory.json`
4. `tests/results/_agent/runtime/jarvis-session-observer.json`
5. `tests/results/_agent/runtime/observer-heartbeat.json`
6. `tests/results/_agent/runtime/task-packet.json`
7. `tests/results/_agent/runtime/codex-state-hygiene.json`
8. `tests/results/_agent/marketplace/lane-marketplace-snapshot.json`

Secondary control-plane receipts worth checking only when the main runtime view
looks stale:

- `tests/results/_agent/runtime/delivery-agent-manager-state.json`
- `tests/results/_agent/runtime/delivery-agent-manager-pid.json`
- `tests/results/_agent/runtime/delivery-agent-manager-stop.json`
- `tests/results/_agent/runtime/delivery-agent-wsl-daemon-pid.json`
- `tests/results/_agent/runtime/daemon-host-signal.json`
- `tests/results/_agent/runtime/docker-daemon-engine.json`

When delivery policy expects `dockerRuntime.provider = native-wsl`,
`daemon-host-signal.json` is the authority for whether the Linux daemon-first
plane is reusable. If it reports `desktop-backed`, WSL still resolves to Docker
Desktop and a distro-owned Linux daemon cutover is required before reusing the
daemon-first Linux plane.

## Audit Registers

Use these checked-in audit registers instead of rebuilding daemon debt and
platform-expansion context from session notes:

- [Unattended-Delivery-Daemon-Debt-Register.md](./Unattended-Delivery-Daemon-Debt-Register.md)
- [Unattended-Delivery-Daemon-Capability-Expansion-Register.md](./Unattended-Delivery-Daemon-Capability-Expansion-Register.md)

The registers only keep follow-up issues that still threaten RC determinism,
standing reconciliation, four-lane utilization, or consumer-proving
reliability.

## Behavior Authority

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
- [Unattended-Delivery-Daemon-Debt-Register.md](./Unattended-Delivery-Daemon-Debt-Register.md)
- [Unattended-Delivery-Daemon-Capability-Expansion-Register.md](./Unattended-Delivery-Daemon-Capability-Expansion-Register.md)
