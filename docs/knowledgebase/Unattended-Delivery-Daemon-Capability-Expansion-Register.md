<!-- markdownlint-disable-next-line MD041 -->
# Unattended Delivery Daemon Capability Expansion Register

This register only keeps daemon expansion issues that materially improve one of
these outcomes:

- four-lane utilization
- standing reconciliation coverage
- RC determinism
- consumer-proving reliability

Closed prerequisite lanes are not repeated here unless they still explain why a
follow-up remains open.

## Active Capability Follow-Ups

### Cross-repo lane marketplace as a first-class broker

- Why it matters: when the current repository has no immediately actionable
  lane, the daemon needs a checked-in marketplace so idle capacity can move
  safely instead of going dark.
- Concrete evidence surfaces:
  - code: `tools/priority/lane-marketplace.mjs`,
    `tools/priority/lane-marketplace.json`,
    `tools/priority/cross-repo-lane-broker.mjs`, runtime projection in
    `tools/priority/delivery-agent.mjs` and `tools/priority/runtime-supervisor.mjs`
  - receipts: `tests/results/_agent/marketplace/lane-marketplace-snapshot.json`,
    `tests/results/_agent/runtime/cross-repo-lane-broker-decision.json`,
    `artifacts.marketplaceSnapshotPath`
  - tests: `tools/priority/__tests__/lane-marketplace.test.mjs`,
    `tools/priority/__tests__/cross-repo-lane-broker.test.mjs`,
    `tools/priority/__tests__/cross-repo-lane-broker-schema.test.mjs`,
    `tools/priority/__tests__/delivery-agent-schema.test.mjs`
- Follow-up issue: #1508

### Concurrent hosted/manual proof dispatch and slot release

- Why it matters: four-lane utilization depends on releasing waiting slots and
  dispatching safe hosted/manual proof bundles without stalling local coding
  work.
- Concrete evidence surfaces:
  - code: `tools/priority/concurrent-lane-status.mjs`,
    `tools/priority/throughput-scorecard.mjs`,
    `tools/priority/runtime-supervisor.mjs`
  - receipts: `tests/results/_agent/runtime/concurrent-lane-status-receipt.json`,
    `tests/results/_agent/throughput/throughput-scorecard.json`,
    `tests/results/_agent/runtime/delivery-agent-state.json`
  - tests: `tools/priority/__tests__/runtime-supervisor.test.mjs`,
    `tools/priority/__tests__/throughput-scorecard.test.mjs`
- Follow-up issue: #1482

### Downstream consumer-proving rail and deterministic RC gating

- Why it matters: RC readiness should come from immutable downstream promotion
  inputs plus a proving scorecard, not ad hoc release inference from
  integration receipts.
- Concrete evidence surfaces:
  - policy/docs: `docs/DOWNSTREAM_DEVELOP_PROMOTION_CONTRACT.md`,
    `tools/policy/downstream-promotion-contract.json`
  - code: `tools/priority/downstream-promotion-manifest.mjs`,
    `tools/priority/downstream-promotion-scorecard.mjs`,
    `tools/priority/resolve-downstream-proving-artifact.mjs`
  - receipts:
    `tests/results/_agent/promotion/downstream-develop-promotion-manifest.json`,
    `tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json`,
    `tests/results/_agent/release/downstream-proving-selection.json`
  - tests: `tools/priority/__tests__/downstream-promotion-contract.test.mjs`,
    `tools/priority/__tests__/downstream-promotion-scorecard.test.mjs`,
    `tools/priority/__tests__/resolve-downstream-proving-artifact.test.mjs`
- Follow-up issue: #1497

## Landed Prerequisites

- #1509 defined the worker-provider contract for local, hosted, and remote
  implementation lanes.
- #1512 landed deterministic work stealing and waiting-state slot release.
- #1632 reserved one coding lane for post-iteration template-agent verification.
- #1633 made proactive four-lane utilization the default operator posture.
